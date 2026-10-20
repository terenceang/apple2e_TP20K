#include "oled.h"
#include "disks.h"
#include "qr.h"
#include "web.h"
#include <stdio.h>
#include <string.h>
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TAG "oled"
#define SDA_PIN 21
#define SCL_PIN 22
#define COLS 21                   // 128 / 6
#define ROWS 8                    // 64 / 8: one text row per SSD1306 page

static i2c_master_dev_handle_t dev;
static uint8_t fb[1 + 128 * ROWS];   // fb[0] is the I2C data control byte (0x40)

// 5x7 ASCII 0x20..0x7E, one byte per column, bit 0 on top.
static const uint8_t FONT[95][5] = {
    {0x00, 0x00, 0x00, 0x00, 0x00},
    {0x00, 0x00, 0x5F, 0x00, 0x00},
    {0x00, 0x07, 0x00, 0x07, 0x00},
    {0x14, 0x7F, 0x14, 0x7F, 0x14},
    {0x24, 0x2A, 0x7F, 0x2A, 0x12},
    {0x23, 0x13, 0x08, 0x64, 0x62},
    {0x36, 0x49, 0x55, 0x22, 0x50},
    {0x00, 0x05, 0x03, 0x00, 0x00},
    {0x00, 0x1C, 0x22, 0x41, 0x00},
    {0x00, 0x41, 0x22, 0x1C, 0x00},
    {0x14, 0x08, 0x3E, 0x08, 0x14},
    {0x08, 0x08, 0x3E, 0x08, 0x08},
    {0x00, 0x50, 0x30, 0x00, 0x00},
    {0x08, 0x08, 0x08, 0x08, 0x08},
    {0x00, 0x60, 0x60, 0x00, 0x00},
    {0x20, 0x10, 0x08, 0x04, 0x02},
    {0x3E, 0x51, 0x49, 0x45, 0x3E},
    {0x00, 0x42, 0x7F, 0x40, 0x00},
    {0x42, 0x61, 0x51, 0x49, 0x46},
    {0x21, 0x41, 0x45, 0x4B, 0x31},
    {0x18, 0x14, 0x12, 0x7F, 0x10},
    {0x27, 0x45, 0x45, 0x45, 0x39},
    {0x3C, 0x4A, 0x49, 0x49, 0x30},
    {0x01, 0x71, 0x09, 0x05, 0x03},
    {0x36, 0x49, 0x49, 0x49, 0x36},
    {0x06, 0x49, 0x49, 0x29, 0x1E},
    {0x00, 0x36, 0x36, 0x00, 0x00},
    {0x00, 0x56, 0x36, 0x00, 0x00},
    {0x08, 0x14, 0x22, 0x41, 0x00},
    {0x14, 0x14, 0x14, 0x14, 0x14},
    {0x00, 0x41, 0x22, 0x14, 0x08},
    {0x02, 0x01, 0x51, 0x09, 0x06},
    {0x32, 0x49, 0x79, 0x41, 0x3E},
    {0x7E, 0x11, 0x11, 0x11, 0x7E},
    {0x7F, 0x49, 0x49, 0x49, 0x36},
    {0x3E, 0x41, 0x41, 0x41, 0x22},
    {0x7F, 0x41, 0x41, 0x22, 0x1C},
    {0x7F, 0x49, 0x49, 0x49, 0x41},
    {0x7F, 0x09, 0x09, 0x09, 0x01},
    {0x3E, 0x41, 0x49, 0x49, 0x7A},
    {0x7F, 0x08, 0x08, 0x08, 0x7F},
    {0x00, 0x41, 0x7F, 0x41, 0x00},
    {0x20, 0x40, 0x41, 0x3F, 0x01},
    {0x7F, 0x08, 0x14, 0x22, 0x41},
    {0x7F, 0x40, 0x40, 0x40, 0x40},
    {0x7F, 0x02, 0x0C, 0x02, 0x7F},
    {0x7F, 0x04, 0x08, 0x10, 0x7F},
    {0x3E, 0x41, 0x41, 0x41, 0x3E},
    {0x7F, 0x09, 0x09, 0x09, 0x06},
    {0x3E, 0x41, 0x51, 0x21, 0x5E},
    {0x7F, 0x09, 0x19, 0x29, 0x46},
    {0x46, 0x49, 0x49, 0x49, 0x31},
    {0x01, 0x01, 0x7F, 0x01, 0x01},
    {0x3F, 0x40, 0x40, 0x40, 0x3F},
    {0x1F, 0x20, 0x40, 0x20, 0x1F},
    {0x3F, 0x40, 0x38, 0x40, 0x3F},
    {0x63, 0x14, 0x08, 0x14, 0x63},
    {0x07, 0x08, 0x70, 0x08, 0x07},
    {0x61, 0x51, 0x49, 0x45, 0x43},
    {0x00, 0x7F, 0x41, 0x41, 0x00},
    {0x02, 0x04, 0x08, 0x10, 0x20},
    {0x00, 0x41, 0x41, 0x7F, 0x00},
    {0x04, 0x02, 0x01, 0x02, 0x04},
    {0x40, 0x40, 0x40, 0x40, 0x40},
    {0x00, 0x01, 0x02, 0x04, 0x00},
    {0x20, 0x54, 0x54, 0x54, 0x78},
    {0x7F, 0x48, 0x44, 0x44, 0x38},
    {0x38, 0x44, 0x44, 0x44, 0x20},
    {0x38, 0x44, 0x44, 0x48, 0x7F},
    {0x38, 0x54, 0x54, 0x54, 0x18},
    {0x08, 0x7E, 0x09, 0x01, 0x02},
    {0x0C, 0x52, 0x52, 0x52, 0x3E},
    {0x7F, 0x08, 0x04, 0x04, 0x78},
    {0x00, 0x44, 0x7D, 0x40, 0x00},
    {0x20, 0x40, 0x44, 0x3D, 0x00},
    {0x7F, 0x10, 0x28, 0x44, 0x00},
    {0x00, 0x41, 0x7F, 0x40, 0x00},
    {0x7C, 0x04, 0x18, 0x04, 0x78},
    {0x7C, 0x08, 0x04, 0x04, 0x78},
    {0x38, 0x44, 0x44, 0x44, 0x38},
    {0x7C, 0x14, 0x14, 0x14, 0x08},
    {0x08, 0x14, 0x14, 0x18, 0x7C},
    {0x7C, 0x08, 0x04, 0x04, 0x08},
    {0x48, 0x54, 0x54, 0x54, 0x20},
    {0x04, 0x3F, 0x44, 0x40, 0x20},
    {0x3C, 0x40, 0x40, 0x20, 0x7C},
    {0x1C, 0x20, 0x40, 0x20, 0x1C},
    {0x3C, 0x40, 0x30, 0x40, 0x3C},
    {0x44, 0x28, 0x10, 0x28, 0x44},
    {0x0C, 0x50, 0x50, 0x50, 0x3C},
    {0x44, 0x64, 0x54, 0x4C, 0x44},
    {0x00, 0x08, 0x36, 0x41, 0x00},
    {0x00, 0x00, 0x7F, 0x00, 0x00},
    {0x00, 0x41, 0x36, 0x08, 0x00},
    {0x10, 0x08, 0x08, 0x10, 0x08},
};

static void cmd(const uint8_t *c, size_t n) {
    uint8_t b[32] = {0x00};          // control byte 0x00: commands follow
    memcpy(b + 1, c, n);
    esp_err_t e = i2c_master_transmit(dev, b, n + 1, 100);
    if (e != ESP_OK) ESP_LOGW(TAG, "command write failed: %s", esp_err_to_name(e));
}

// Text row `row` (one page), starting at pixel column x; the caller clears the frame.
static void putx(int row, int x, const char *s) {
    uint8_t *p = fb + 1 + row * 128 + x;
    for (int c = 0; s[c] && x + c * 6 + 5 <= 128; c++) {
        unsigned ch = (uint8_t)s[c];
        memcpy(p + c * 6, FONT[ch < 0x20 || ch > 0x7e ? '?' - 0x20 : ch - 0x20], 5);
    }
}
#define put(row, s) putx(row, 0, s)

// A QR code on the left: dark modules are unlit pixels on a lit 64x64 square (scanners want dark
// on light), 2x2 pixels per module. False if the text is too long.
static bool qr_draw(const char *text) {
    static uint8_t m[QR_SIZE][QR_SIZE];
    if (!qr_encode(text, m)) { put(0, "QR too long"); return false; }
    for (int pg = 0; pg < ROWS; pg++) memset(fb + 1 + pg * 128, 0xff, 64);
    for (int y = 0; y < QR_SIZE; y++)
        for (int x = 0; x < QR_SIZE; x++)
            if (m[y][x])
                for (int k = 0; k < 4; k++) {
                    int px = 3 + 2 * x + (k & 1), py = 3 + 2 * y + (k >> 1);
                    fb[1 + (py >> 3) * 128 + px] &= (uint8_t)~(1 << (py & 7));
                }
    return true;
}

// No router yet: the board's access point as a Wi-Fi QR code, to join it from a phone.
static void qr_join_screen(void) {
    char t[48];
    snprintf(t, sizeof t, "WIFI:T:WPA;S:%s;P:%s;;", web_ap_ssid(), web_ap_pass());
    if (!qr_draw(t)) return;
    putx(0, 66, "Scan to");
    putx(1, 66, "join Wi-Fi");
    putx(3, 66, web_ap_ssid());
    putx(4, 66, web_ap_pass());
    putx(5, 66, "then open");
    putx(6, 66, "192.168.");   // 192.168.4.1 is 11 characters: one too many for the right half
    putx(7, 66, "4.1");
}

// On the router: a QR code of the control page's address.
static void qr_control_screen(void) {
    char t[32];
    snprintf(t, sizeof t, "http://%s/", web_ip());
    if (!qr_draw(t)) return;
    putx(0, 66, "Scan to");
    putx(1, 66, "open the");
    putx(2, 66, "controls");
    const char *ip = web_ip(), *dot = strchr(ip, '.');
    dot = dot ? strchr(dot + 1, '.') : NULL;   // the IP will not fit one line: split after the second dot
    char a[16];
    snprintf(a, sizeof a, "%.*s", dot ? (int)(dot + 1 - ip) : (int)strlen(ip), ip);
    putx(4, 66, a);
    if (dot) putx(5, 66, dot + 1);
}

static void flush(void) {
    static const uint8_t win[] = {0x21, 0, 127, 0x22, 0, ROWS - 1};   // column and page window
    cmd(win, sizeof win);
    esp_err_t e = i2c_master_transmit(dev, fb, sizeof fb, 200);
    if (e != ESP_OK) ESP_LOGW(TAG, "frame write failed: %s", esp_err_to_name(e));
}

static void drive_line(int row, int d) {
    char s[COLS + 1];
    const char *n = disk_name(d);
    uint8_t g0, g1, fl;
    disks_status(&g0, &g1, &fl);
    snprintf(s, sizeof s, "%d %s %s", d + 1, n ? ((fl >> d) & 1 ? "rw" : "ro") : "--", n ? n : "empty");
    put(row, s);
}

static volatile bool qr_asked;
void oled_show_qr(void) { qr_asked = true; }

static void screen(void *arg) {
    fb[0] = 0x40;
    gpio_set_direction(GPIO_NUM_0, GPIO_MODE_INPUT);     // the BOOT button: an ordinary input once running
    gpio_set_pull_mode(GPIO_NUM_0, GPIO_PULLUP_ONLY);
    memset(fb + 1, 0, sizeof fb - 1);                    // splash
    putx(2, 37, "APPLE //e");
    putx(4, 25, "Tang Nano 20K");
    flush();
    vTaskDelay(pdMS_TO_TICKS(2000));
    int qr_until = 0;                                   // QR code until this tick (100 ms each)
    for (int tick = 0;; tick++, vTaskDelay(pdMS_TO_TICKS(100))) {
        bool asked = qr_asked || !gpio_get_level(GPIO_NUM_0);   // from the web page, or BOOT pressed
        if (asked) { qr_asked = false; qr_until = tick + 300; }
        if (tick % 10 && !asked) continue;               // redraw once a second, or at once when asked
        memset(fb + 1, 0, sizeof fb - 1);
        wifi_sta_list_t sta;                             // phones joined to our access point
        bool joined = esp_wifi_ap_get_sta_list(&sta) == ESP_OK && sta.num > 0;
        bool show_qr = tick < qr_until || (tick / 50 % 2);   // asked for, or the QR half of the 10 s cycle
        if (!web_online() && !joined) {                  // nobody connected: the join code stays up
            qr_join_screen();
        } else if (show_qr) {
            if (web_online()) qr_control_screen(); else qr_join_screen();
        } else {
            put(0, "APPLE //E DISKS");
            drive_line(2, 0);
            drive_line(3, 1);
            put(5, sd_ok ? "SD card ok" : "NO SD CARD");
            put(7, web_ip());
        }
        flush();
    }
}

static bool oled_init(void) {
    i2c_master_bus_handle_t bus;
    i2c_master_bus_config_t bc = {.i2c_port = I2C_NUM_0, .sda_io_num = SDA_PIN, .scl_io_num = SCL_PIN,
                                  .clk_source = I2C_CLK_SRC_DEFAULT, .glitch_ignore_cnt = 7,
                                  .flags.enable_internal_pullup = true};
    ESP_ERROR_CHECK(i2c_new_master_bus(&bc, &bus));
    const uint8_t addr = 0x3C;
    if (i2c_master_probe(bus, addr, 50) != ESP_OK) {
        i2c_master_bus_reset(bus);            // a reset mid-transfer can leave the display holding SDA low
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (i2c_master_probe(bus, addr, 50) != ESP_OK) { ESP_LOGW(TAG, "no SSD1306 on 0x3C: screen off"); return false; }
    i2c_device_config_t dc = {.dev_addr_length = I2C_ADDR_BIT_LEN_7, .device_address = addr,
                              .scl_speed_hz = 100000};
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus, &dc, &dev));
    ESP_LOGI(TAG, "SSD1306 at 0x%02x", addr);
    static const uint8_t init[] = {0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0x8D, 0x14, 0xA0, 0xC0,
                                   0xDA, 0x12, 0x81, 0xFF, 0xD9, 0xF1, 0xDB, 0x30, 0xA4, 0xA6, 0x20, 0x00};
    fb[0] = 0x40;                             // I2C data control byte
    cmd(init, sizeof init);
    flush();                                  // clear the RAM, then switch the panel on
    cmd((const uint8_t[]){0xAF}, 1);
    return true;
}

void oled_start(void) {
    if (oled_init()) xTaskCreate(screen, "oled", 4096, NULL, 1, NULL);
}
