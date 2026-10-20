// SPI slave on VSPI (GPIO 18 SCK, 23 MOSI, 19 MISO, 5 CS).
//
// The FPGA sends a command frame, then poll frames that read the answer.  A
// transaction's DMA buffers are armed before its first clock, so a response can
// only be armed after the command frame ended: the loop always re-arms at once,
// with the response if one is ready and zeros otherwise (the FPGA retries until
// byte 0 is ACK).  Slow work (SD, encode/decode) is done by a worker task.
#include "link.h"
#include "disks.h"
#include "nibble.h"
#include <string.h>
#include "driver/spi_slave.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#define TAG "link"
#define BUF 7168      // the FPGA's track slot (trk_defs.vh); >= 3 + NIB_TRACK_LEN
#define NWBUF 4

enum { OP_POLL = 0x00, OP_HELLO = 0x01, OP_STATUS = 0x02, OP_READ_TRK = 0x10, OP_WRITE_TRK = 0x20 };
#define ACK 0xA5

typedef struct { uint8_t op, d, t; uint8_t *data; } job_t;

static uint8_t *rx, *tx_zero, *resp, *wbuf[NWBUF];
static volatile bool resp_ready;
static QueueHandle_t jobs;
static int wnext;

// Publish resp to the link task running on the other core.
static void resp_publish(void) { __sync_synchronize(); resp_ready = true; }

static void worker(void *arg) {
    job_t j;
    for (;;) {
        xQueueReceive(jobs, &j, portMAX_DELAY);
        if (j.op == OP_READ_TRK) {
            resp[0] = ACK;
            if (disk_read_track(j.d, j.t, resp + 1)) resp_publish();
            else ESP_LOGW(TAG, "READ_TRK %d/%d failed", j.d, j.t);   // the FPGA times out and retries
        } else if (j.op == OP_WRITE_TRK) {
            disk_write_track(j.d, j.t, j.data);
        }
    }
}

static void link_task(void *arg) {
    spi_slave_transaction_t t;
    for (;;) {
        memset(&t, 0, sizeof t);
        bool armed_resp = resp_ready;
        t.length = BUF * 8;
        t.tx_buffer = armed_resp ? resp : tx_zero;
        t.rx_buffer = rx;
        if (spi_slave_transmit(SPI3_HOST, &t, portMAX_DELAY) != ESP_OK) continue;
        size_t len = t.trans_len / 8;
        if (len == 0) continue;
        switch (rx[0]) {
        case OP_POLL:                   // poll: the answer was read (or was not ready)
            if (armed_resp) resp_ready = false;
            break;
        case OP_HELLO:
            resp[0] = ACK; resp[1] = 0x5A; resp_publish();
            break;
        case OP_STATUS: {
            uint8_t g0, g1, fl;
            disks_status(&g0, &g1, &fl);
            resp[0] = ACK; resp[1] = g0; resp[2] = g1; resp[3] = fl; resp_publish();
            break;
        }
        case OP_READ_TRK: {
            resp_ready = false;
            job_t j = {OP_READ_TRK, rx[1], rx[2], NULL};
            xQueueSend(jobs, &j, 0);
            break;
        }
        case OP_WRITE_TRK:
            if (len >= 3 + NIB_TRACK_LEN) {
                uint8_t *w = wbuf[wnext];
                wnext = (wnext + 1) % NWBUF;
                memcpy(w, rx + 3, NIB_TRACK_LEN);
                job_t j = {OP_WRITE_TRK, rx[1], rx[2], w};
                if (xQueueSend(jobs, &j, 0) != pdTRUE) ESP_LOGW(TAG, "write queue full, track dropped");
            }
            break;
        default:
            break;
        }
    }
}

void link_start(void) {
    rx      = heap_caps_calloc(1, BUF, MALLOC_CAP_DMA);
    tx_zero = heap_caps_calloc(1, BUF, MALLOC_CAP_DMA);
    resp    = heap_caps_calloc(1, BUF, MALLOC_CAP_DMA);
    for (int i = 0; i < NWBUF; i++) wbuf[i] = heap_caps_calloc(1, NIB_TRACK_LEN, MALLOC_CAP_8BIT);
    jobs = xQueueCreate(NWBUF - 1, sizeof(job_t));   // + the one the worker holds = NWBUF buffers

    spi_bus_config_t bus = {.mosi_io_num = 23, .miso_io_num = 19, .sclk_io_num = 18,
                            .quadwp_io_num = -1, .quadhd_io_num = -1, .max_transfer_sz = BUF};
    spi_slave_interface_config_t slv = {.mode = 0, .spics_io_num = 5, .queue_size = 1, .flags = 0};
    ESP_ERROR_CHECK(spi_slave_initialize(SPI3_HOST, &bus, &slv, SPI_DMA_CH_AUTO));
    xTaskCreatePinnedToCore(link_task, "link", 4096, NULL, 10, NULL, 1);
    xTaskCreatePinnedToCore(worker, "disk", 6144, NULL, 5, NULL, 0);
}
