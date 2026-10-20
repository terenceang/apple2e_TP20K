#include "web.h"
#include "disks.h"
#include "oled.h"
#include <stdio.h>
#include <dirent.h>
#include <string.h>
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#define TAG "web"

#include "index_html.h"   // the page: src/index.html, turned into a C array by html2h.py

static esp_err_t index_get(httpd_req_t *r) {
    return httpd_resp_send(r, index_html, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t status_get(httpd_req_t *r) {
    uint8_t g0, g1, fl;
    disks_status(&g0, &g1, &fl);
    char b[280];                       // a directory entry name can be up to 255 bytes
    httpd_resp_set_type(r, "application/json");
    httpd_resp_sendstr_chunk(r, "{\"drives\":[");
    for (int d = 0; d < 2; d++) {
        const char *n = disk_name(d);   // names are [A-Za-z0-9._-]: no JSON escaping needed
        snprintf(b, sizeof b, "%s{\"name\":%s%s%s,\"rw\":%s}", d ? "," : "", n ? "\"" : "", n ? n : "null",
                 n ? "\"" : "", (fl >> d) & 1 ? "true" : "false");
        httpd_resp_sendstr_chunk(r, b);
    }
    httpd_resp_sendstr_chunk(r, "],\"lib\":[");
    DIR *dir = opendir(DISK_DIR);
    bool first = true;
    for (struct dirent *e; dir && (e = readdir(dir));)
        if (disk_name_ok(e->d_name)) {
            snprintf(b, sizeof b, "%s\"%s\"", first ? "" : ",", e->d_name);
            httpd_resp_sendstr_chunk(r, b);
            first = false;
        }
    if (dir) closedir(dir);
    httpd_resp_sendstr_chunk(r, "]}");
    return httpd_resp_sendstr_chunk(r, NULL);
}

// ?name= of a request, checked as a library file name.
static bool query_name(httpd_req_t *r, char *name, size_t n) {
    char q[64];
    return httpd_req_get_url_query_str(r, q, sizeof q) == ESP_OK &&
           httpd_query_key_value(q, "name", name, n) == ESP_OK && disk_name_ok(name);
}

static esp_err_t qr_post(httpd_req_t *r) {
    oled_show_qr();
    return httpd_resp_sendstr(r, "QR code on the display");
}

static esp_err_t eject_post(httpd_req_t *r) {
    disk_eject((int)(intptr_t)r->user_ctx);
    return httpd_resp_sendstr(r, "ejected");
}

static esp_err_t mount_post(httpd_req_t *r) {
    char name[DISK_NAME_MAX + 1];
    if (!query_name(r, name, sizeof name)) return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "bad name");
    return httpd_resp_sendstr(r, disk_mount((int)(intptr_t)r->user_ctx, name) ? "mounted"
                                                                              : "cannot mount (bad image, or in the other drive)");
}

static esp_err_t delete_post(httpd_req_t *r) {
    char name[DISK_NAME_MAX + 1];
    if (!query_name(r, name, sizeof name)) return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "bad name");
    return httpd_resp_sendstr(r, disk_delete(name) ? "deleted" : "no such image");
}

// Add an image to the library; if it replaces one a drive holds, that drive remounts it.
static esp_err_t lib_post(httpd_req_t *r) {
    char name[DISK_NAME_MAX + 1], path[48];
    if (!query_name(r, name, sizeof name))
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "name must be letters, digits . _ - and end in .dsk, .do or .po");
    if (r->content_len != DISK_BYTES)
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "image must be 143360 bytes");

    FILE *f = fopen(DISK_DIR "/upload.tmp", "wb");
    if (!f) return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD write failed");
    static char buf[4096];                             // httpd handles one request at a time
    int left = r->content_len;
    while (left > 0) {
        int n = httpd_req_recv(r, buf, left < (int)sizeof buf ? left : (int)sizeof buf);
        if (n <= 0 || fwrite(buf, 1, n, f) != (size_t)n) {
            fclose(f); remove(DISK_DIR "/upload.tmp");
            return n <= 0 ? ESP_FAIL : httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD write failed");
        }
        left -= n;
    }
    fclose(f);
    bool held[2];
    for (int d = 0; d < 2; d++) held[d] = disk_name(d) && !strcmp(disk_name(d), name);
    disk_delete(name);                                 // ejects it everywhere; ok if it was not there
    disk_path(path, sizeof path, name);
    if (rename(DISK_DIR "/upload.tmp", path))
        return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD rename failed");
    for (int d = 0; d < 2; d++) if (held[d]) disk_mount(d, name);
    return httpd_resp_sendstr(r, "added");
}

static char ip_str[16] = "no router";
static char ap_ssid[16], ap_pass[9];
const char *web_ap_ssid(void) { return ap_ssid; }
const char *web_ap_pass(void) { return ap_pass; }

// Per-board AP name from the MAC, and a random password made once and kept in NVS.
static void ap_identity(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    snprintf(ap_ssid, sizeof ap_ssid, "Apple-%02X%02X", mac[4], mac[5]);
    nvs_handle_t h;
    size_t n = sizeof ap_pass;
    if (nvs_open("web", NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_get_str(h, "ap_pass", ap_pass, &n) != ESP_OK) {
        static const char A[] = "abcdefghjkmnpqrstuvwxyz23456789";   // no look-alikes, no QR-special characters
        for (int i = 0; i < 8; i++) ap_pass[i] = A[esp_random() % (sizeof A - 1)];
        ap_pass[8] = 0;
        nvs_set_str(h, "ap_pass", ap_pass);
        nvs_commit(h);
    }
    nvs_close(h);
}
static volatile bool online, scanning;
static char sta_ssid[33], sta_pass[64];   // the router, kept in NVS ("web" namespace), set from the page

static void load_sta(void) {
    nvs_handle_t h;
    if (nvs_open("web", NVS_READONLY, &h) != ESP_OK) return;
    size_t n = sizeof sta_ssid;
    if (nvs_get_str(h, "sta_ssid", sta_ssid, &n) == ESP_OK) {
        n = sizeof sta_pass;
        nvs_get_str(h, "sta_pass", sta_pass, &n);
    }
    nvs_close(h);
}

// Remember the router (an empty ssid forgets it).
static void save_sta(const char *ssid, const char *pass) {
    nvs_handle_t h;
    if (nvs_open("web", NVS_READWRITE, &h) == ESP_OK) {
        if (ssid[0]) { nvs_set_str(h, "sta_ssid", ssid); nvs_set_str(h, "sta_pass", pass); }
        else { nvs_erase_key(h, "sta_ssid"); nvs_erase_key(h, "sta_pass"); }
        nvs_commit(h);
        nvs_close(h);
    }
    strlcpy(sta_ssid, ssid, sizeof sta_ssid);
    strlcpy(sta_pass, pass, sizeof sta_pass);
}

static void sta_config(void) {
    wifi_config_t wc = {0};
    strlcpy((char *)wc.sta.ssid, sta_ssid, sizeof wc.sta.ssid);
    strlcpy((char *)wc.sta.password, sta_pass, sizeof wc.sta.password);
    esp_wifi_set_config(WIFI_IF_STA, &wc);
}

static void sta_apply(void) {
    sta_config();
    online = false;
    snprintf(ip_str, sizeof ip_str, sta_ssid[0] ? "connecting..." : "no router");
    esp_wifi_disconnect();
    if (sta_ssid[0]) esp_wifi_connect();
}

// Body is "ssid\npassword": no URL escaping to get wrong.
static esp_err_t wifi_post(httpd_req_t *r) {
    char b[100];
    if (r->content_len == 0 || r->content_len >= sizeof b) return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "bad request");
    for (int got = 0, n; got < (int)r->content_len; got += n)
        if ((n = httpd_req_recv(r, b + got, r->content_len - got)) <= 0) return ESP_FAIL;
    b[r->content_len] = 0;
    char *pass = strchr(b, '\n');
    if (!pass || !b[0] || strlen(b) > 32 || strlen(pass + 1) > 63)
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "network name 1-32, password up to 63 characters");
    *pass++ = 0;
    save_sta(b, pass);
    sta_apply();
    return httpd_resp_sendstr(r, "saved, connecting...");
}

static esp_err_t wifi_forget_post(httpd_req_t *r) {
    save_sta("", "");
    sta_apply();
    return httpd_resp_sendstr(r, "router forgotten");
}

static esp_err_t wifi_get(httpd_req_t *r) {   // ssid, ip, 1 if online
    char b[64 + 40];
    snprintf(b, sizeof b, "%s\n%s\n%d", sta_ssid, ip_str, online);
    httpd_resp_set_type(r, "text/plain");
    return httpd_resp_sendstr(r, b);
}

static esp_err_t scan_get(httpd_req_t *r) {   // one network per line
    static wifi_ap_record_t rec[20];
    uint16_t n = 20;
    scanning = true;                          // a scan fails while the station is mid-connect
    if (!online) esp_wifi_disconnect();
    if (esp_wifi_scan_start(NULL, true) != ESP_OK || esp_wifi_scan_get_ap_records(&n, rec) != ESP_OK) n = 0;
    scanning = false;
    if (sta_ssid[0] && !online) esp_wifi_connect();
    httpd_resp_set_type(r, "text/plain");
    for (int i = 0; i < n; i++)
        if (rec[i].ssid[0]) {             // "rssi<TAB>secured<TAB>ssid"
            char pre[16];
            snprintf(pre, sizeof pre, "%d\t%d\t", rec[i].rssi, rec[i].authmode != WIFI_AUTH_OPEN);
            httpd_resp_sendstr_chunk(r, pre);
            httpd_resp_sendstr_chunk(r, (char *)rec[i].ssid);
            httpd_resp_sendstr_chunk(r, "\n");
        }
    return httpd_resp_sendstr_chunk(r, NULL);
}

// Captive portal: answer every DNS A query with the access point's address, so a phone that joins
// the AP opens the page by itself.
static void dns_task(void *arg) {
    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons(53), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (s < 0 || bind(s, (struct sockaddr *)&sa, sizeof sa) < 0) { ESP_LOGW(TAG, "no captive DNS"); vTaskDelete(NULL); }
    uint8_t q[256];
    for (;;) {
        struct sockaddr_in c;
        socklen_t cl = sizeof c;
        int n = recvfrom(s, q, sizeof q - 16, 0, (struct sockaddr *)&c, &cl);
        int i = 12;
        while (n > 12 && i < n && q[i]) i += q[i] + 1;
        i += 5;                               // the name's zero byte, then type and class
        if (n <= 12 || i > n) continue;
        int a = (q[i - 4] << 8 | q[i - 3]) == 1;      // only A records get an answer
        q[2] = 0x81; q[3] = 0x80; q[6] = 0; q[7] = a; q[8] = q[9] = q[10] = q[11] = 0;
        static const uint8_t ans[] = {0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 10, 0, 4, 192, 168, 4, 1};
        if (a) memcpy(q + i, ans, sizeof ans);
        sendto(s, q, i + (a ? sizeof ans : 0), 0, (struct sockaddr *)&c, cl);
    }
}

static esp_err_t portal_redirect(httpd_req_t *r, httpd_err_code_t e) {   // the OS's connectivity probes land here
    httpd_resp_set_status(r, "302 Found");
    httpd_resp_set_hdr(r, "Location", "http://192.168.4.1/");
    return httpd_resp_send(r, NULL, 0);
}

const char *web_ip(void) { return ip_str; }
bool web_online(void) { return online; }

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && (id == WIFI_EVENT_STA_START || id == WIFI_EVENT_STA_DISCONNECTED) && sta_ssid[0] && !scanning) {
        online = false;
        snprintf(ip_str, sizeof ip_str, "connecting...");
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        snprintf(ip_str, sizeof ip_str, IPSTR, IP2STR(&e->ip_info.ip));
        online = true;
        ESP_LOGI(TAG, "http://%s/", ip_str);
    }
}

void web_start(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL));
    // Always an access point (join it with the QR code on the OLED; the page opens by itself, or
    // browse to 192.168.4.1) and a station too, once the page has been given a router.
    ap_identity();
    load_sta();
    wifi_config_t ap = {.ap = {.max_connection = 2, .authmode = WIFI_AUTH_WPA2_PSK}};
    strlcpy((char *)ap.ap.ssid, ap_ssid, sizeof ap.ap.ssid);
    strlcpy((char *)ap.ap.password, ap_pass, sizeof ap.ap.password);
    ap.ap.ssid_len = strlen(ap_ssid);
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    if (sta_ssid[0]) sta_config();
    ESP_LOGI(TAG, "AP %s / %s: http://192.168.4.1/", ap_ssid, ap_pass);
    ESP_ERROR_CHECK(esp_wifi_start());

    httpd_handle_t h = NULL;
    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    hc.max_uri_handlers = 16;   // 10 for the library + 4 for Wi-Fi
    hc.max_open_sockets = 5;    // leaves lwip sockets for the captive DNS
    hc.stack_size = 8192;
    ESP_ERROR_CHECK(httpd_start(&h, &hc));
    httpd_uri_t i = {.uri = "/", .method = HTTP_GET, .handler = index_get};
    httpd_uri_t st = {.uri = "/status", .method = HTTP_GET, .handler = status_get};
    httpd_uri_t lib = {.uri = "/lib", .method = HTTP_POST, .handler = lib_post};
    httpd_uri_t del = {.uri = "/delete", .method = HTTP_POST, .handler = delete_post};
    httpd_register_uri_handler(h, &i);
    httpd_register_uri_handler(h, &st);
    httpd_register_uri_handler(h, &lib);
    httpd_uri_t qr = {.uri = "/qr", .method = HTTP_POST, .handler = qr_post};
    httpd_register_uri_handler(h, &del);
    httpd_register_uri_handler(h, &qr);
    httpd_uri_t w1 = {.uri = "/wifi", .method = HTTP_GET, .handler = wifi_get};
    httpd_uri_t w2 = {.uri = "/wifi", .method = HTTP_POST, .handler = wifi_post};
    httpd_uri_t w3 = {.uri = "/wifi/scan", .method = HTTP_GET, .handler = scan_get};
    httpd_uri_t w4 = {.uri = "/wifi/forget", .method = HTTP_POST, .handler = wifi_forget_post};
    httpd_register_uri_handler(h, &w1);
    httpd_register_uri_handler(h, &w2);
    httpd_register_uri_handler(h, &w3);
    httpd_register_uri_handler(h, &w4);
    httpd_register_err_handler(h, HTTPD_404_NOT_FOUND, portal_redirect);
    xTaskCreate(dns_task, "dns", 3072, NULL, 3, NULL);
    static const char *const mt[] = {"/mount/1", "/mount/2"}, *const ej[] = {"/eject/1", "/eject/2"};
    for (int d = 0; d < 2; d++) {
        httpd_uri_t m = {.uri = mt[d], .method = HTTP_POST, .handler = mount_post, .user_ctx = (void *)(intptr_t)d};
        httpd_uri_t e = {.uri = ej[d], .method = HTTP_POST, .handler = eject_post, .user_ctx = (void *)(intptr_t)d};
        httpd_register_uri_handler(h, &m);
        httpd_register_uri_handler(h, &e);
    }
}
