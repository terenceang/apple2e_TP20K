// Wi-Fi + a tiny HTTP page: disk library (add, mount in a drive, eject, delete).
#pragma once
#include <stdbool.h>
void web_start(void);
const char *web_ap_ssid(void);   // the board's own access point: always on, WPA2,
const char *web_ap_pass(void);   // password random per board (NVS), shown on the OLED as a QR code
bool web_online(void);           // joined a router (web_ip() is its address)
const char *web_ip(void);   // "a.b.c.d", or a short status text while there is none
