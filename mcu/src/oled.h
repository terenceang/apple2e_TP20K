// 128x64 SSD1306 status screen on I2C (GPIO 21 SDA, 22 SCL): drives, SD card, Wi-Fi IP.
#pragma once
void oled_start(void);
void oled_show_qr(void);   // the Wi-Fi QR code for 30 s (the web page asks, or the BOOT button is pressed)   // no-op (logged) if no display answers on 0x3C/0x3D
