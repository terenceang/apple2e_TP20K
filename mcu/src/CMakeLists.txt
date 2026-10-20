idf_component_register(
    SRCS main.c link.c disks.c web.c nibble.c oled.c qr.c
    INCLUDE_DIRS .
    REQUIRES driver esp_wifi esp_netif lwip esp_event esp_http_server nvs_flash fatfs sdmmc)
