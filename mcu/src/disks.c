#include "disks.h"
#include "nibble.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include "esp_log.h"
#include "nvs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define TAG "disks"

typedef struct {
    FILE *f;
    bool writable, po;
    char name[DISK_NAME_MAX + 1];   // library file name
    uint8_t gen;      // 0 = no image (f == NULL); changes on every mount
} disk_t;

bool sd_ok;
static disk_t D[2];
static SemaphoreHandle_t mu;
static const uint8_t DOS_TO_PHYS[16] = {0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
                                        0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf};
static uint8_t PHYS_TO_DOS[16];
static uint8_t secbuf[16][256];   // used under mu only

const char *const DISK_EXTS[3] = {"dsk", "do", "po"};

bool disk_name_ok(const char *name) {
    size_t n = strlen(name);
    if (n == 0 || n > DISK_NAME_MAX || name[0] == '.') return false;
    for (size_t i = 0; i < n; i++)
        if (!isalnum((unsigned char)name[i]) && !strchr("._-", name[i])) return false;
    const char *ext = strrchr(name, '.');
    for (int e = 0; ext && e < 3; e++)
        if (!strcasecmp(ext + 1, DISK_EXTS[e])) return true;
    return false;
}

void disk_path(char *out, size_t n, const char *name) { snprintf(out, n, DISK_DIR "/%s", name); }

// The name each drive held, so a reset brings the same images back.
static void remember(int d, const char *name) {
    nvs_handle_t h;
    if (nvs_open("disks", NVS_READWRITE, &h) != ESP_OK) return;
    char key[3] = {'d', (char)('0' + d), 0};
    if (name) nvs_set_str(h, key, name); else nvs_erase_key(h, key);
    nvs_commit(h);
    nvs_close(h);
}

static bool bad(int d, int t) { return d < 0 || d > 1 || t < 0 || t >= DISK_TRACKS; }

// File sector holding physical position p: .po is already physical, DOS order is not.
static int sector_slot(const disk_t *k, int p) { return k->po ? p : PHYS_TO_DOS[p]; }

void disk_eject(int d) {
    xSemaphoreTake(mu, portMAX_DELAY);
    if (D[d].f) { fclose(D[d].f); D[d].f = NULL; }
    D[d].gen = 0;
    xSemaphoreGive(mu);
    remember(d, NULL);
}

static bool mount_file(int d, const char *name) {
    char path[48];
    disk_path(path, sizeof path, name);
    xSemaphoreTake(mu, portMAX_DELAY);
    disk_t *k = &D[d];
    if (k->f) { fclose(k->f); k->f = NULL; }
    k->gen = 0;
    k->writable = false;
    bool rw = true;
    FILE *f = fopen(path, "r+b");
    if (!f) { rw = false; f = fopen(path, "rb"); }
    bool ok = false;
    if (f) {
        fseek(f, 0, SEEK_END);
        if (ftell(f) == DISK_BYTES) {
            const char *ext = strrchr(path, '.');
            k->po = ext && !strcasecmp(ext, ".po");
            snprintf(k->name, sizeof k->name, "%s", name);
            k->f = f; k->writable = rw; ok = true;
            static uint8_t g;
            g = (uint8_t)(g % 255 + 1);       // never 0
            k->gen = g;
            ESP_LOGI(TAG, "drive %d: %s (%s, %s)", d + 1, path, k->po ? "po" : "dos order",
                     rw ? "rw" : "ro");
        } else {
            ESP_LOGW(TAG, "%s: not a 143360-byte image", path);
            fclose(f);
        }
    }
    xSemaphoreGive(mu);
    return ok;
}

bool disk_mount(int d, const char *name) {
    if (!disk_name_ok(name) || (D[1 - d].f && !strcmp(D[1 - d].name, name))) return false;   // one writer per file
    bool ok = mount_file(d, name);
    remember(d, ok ? name : NULL);   // a failed mount leaves the drive empty
    return ok;
}

bool disk_delete(const char *name) {
    if (!disk_name_ok(name)) return false;
    for (int d = 0; d < 2; d++)
        if (D[d].f && !strcmp(D[d].name, name)) disk_eject(d);   // FatFS will not delete an open file
    char path[48];
    disk_path(path, sizeof path, name);
    return remove(path) == 0;
}

void disks_init(void) {
    mu = xSemaphoreCreateMutex();
    for (int p = 0; p < 16; p++) PHYS_TO_DOS[DOS_TO_PHYS[p]] = (uint8_t)p;
    mkdir(DISK_DIR, 0777);
    nvs_handle_t h;
    if (nvs_open("disks", NVS_READONLY, &h) != ESP_OK) return;
    for (int d = 0; d < 2; d++) {
        char key[3] = {'d', (char)('0' + d), 0}, name[DISK_NAME_MAX + 1];
        size_t n = sizeof name;
        if (nvs_get_str(h, key, name, &n) == ESP_OK && disk_name_ok(name) && !mount_file(d, name))
            ESP_LOGW(TAG, "drive %d: %s is gone", d + 1, name);
    }
    nvs_close(h);
}

void disks_status(uint8_t *gen0, uint8_t *gen1, uint8_t *flags) {
    *gen0 = D[0].gen;
    *gen1 = D[1].gen;
    *flags = (uint8_t)((D[0].writable ? 1 : 0) | (D[1].writable ? 2 : 0));
}

const char *disk_name(int d) { return D[d].f ? D[d].name : NULL; }

bool disk_read_track(int d, int t, uint8_t *out) {
    if (bad(d, t)) return false;
    xSemaphoreTake(mu, portMAX_DELAY);
    disk_t *k = &D[d];
    // One 4 KB read of the whole track (16 seeks of 256 B each are ~10x slower on SD),
    // then pick the sectors out in physical order.
    bool ok = k->f && fseek(k->f, (long)t * 16 * 256, SEEK_SET) == 0 &&
              fread(secbuf, 1, sizeof secbuf, k->f) == sizeof secbuf;
    if (ok) {
        const uint8_t *sp[16];
        for (int p = 0; p < 16; p++) sp[p] = secbuf[sector_slot(k, p)];
        nib_encode_track(t, sp, out);
    }
    xSemaphoreGive(mu);
    return ok;
}

void disk_write_track(int d, int t, const uint8_t *in) {
    if (bad(d, t)) return;
    xSemaphoreTake(mu, portMAX_DELAY);
    disk_t *k = &D[d];
    if (k->f && k->writable) {
        uint16_t mask = nib_decode_track(in, secbuf);
        for (int p = 0; p < 16; p++) {
            if (!(mask & (1u << p))) continue;
            if (fseek(k->f, (long)((t * 16 + sector_slot(k, p)) * 256), SEEK_SET) ||
                fwrite(secbuf[p], 1, 256, k->f) != 256)
                ESP_LOGE(TAG, "drive %d track %d sector %d: SD write failed", d + 1, t, p);
        }
        fflush(k->f);
        ESP_LOGI(TAG, "drive %d track %d: %d sectors written", d + 1, t, __builtin_popcount(mask));
    }
    xSemaphoreGive(mu);
}
