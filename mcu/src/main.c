// ESP32 companion for the Apple //e FPGA (Tang Nano 20K).
// SD card on SPI2 (GPIO 25 SCK, 26 MOSI, 27 MISO, 32 CS: clear of the strapping
// pins), FPGA link on SPI3/VSPI (see link.c), disk library in DISK_DIR.
#include "disks.h"
#include "link.h"
#include "oled.h"
#include "web.h"
#include "driver/sdspi_host.h"
#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "nvs_flash.h"
#include "sdmmc_cmd.h"

#define TAG "main"

void app_main(void) {
    ESP_ERROR_CHECK(nvs_flash_init());

    sdmmc_host_t host = SDSPI_HOST_DEFAULT();
    host.slot = SPI2_HOST;
    spi_bus_config_t bus = {.mosi_io_num = 26, .miso_io_num = 27, .sclk_io_num = 25,
                            .quadwp_io_num = -1, .quadhd_io_num = -1, .max_transfer_sz = 4096};
    ESP_ERROR_CHECK(spi_bus_initialize(host.slot, &bus, SDSPI_DEFAULT_DMA));
    sdspi_device_config_t slot = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot.gpio_cs = 32;
    slot.host_id = host.slot;
    esp_vfs_fat_sdmmc_mount_config_t mc = {.format_if_mount_failed = false, .max_files = 4,
                                           .allocation_unit_size = 16 * 1024};
    sdmmc_card_t *card;
    sd_ok = esp_vfs_fat_sdspi_mount(SD_MOUNT, &host, &slot, &mc, &card) == ESP_OK;
    if (!sd_ok)
        ESP_LOGE(TAG, "no SD card: both drives stay empty");
    disks_init();   // lock, library dir, and the images each drive held at the last reset
    link_start();
    web_start();
    oled_start();
}
