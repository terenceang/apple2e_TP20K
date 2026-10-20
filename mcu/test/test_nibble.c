// Host test: zig cc -o build/test_nibble mcu/test/test_nibble.c mcu/src/nibble.c && build/test_nibble
// Run from the repo root (reads build/golden_track0.hex from sim/tb_disk2.v).
#include "../src/nibble.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

int main(void) {
    static uint8_t img[16][256], trk[NIB_TRACK_LEN], dec[16][256], want[NIB_TRACK_LEN];
    const uint8_t *sp[16];
    for (int s = 0; s < 16; s++) {
        for (int o = 0; o < 256; o++) img[s][o] = (uint8_t)(((o * 5 + s * 11) & 0xff) ^ 0xa5);
        sp[s] = img[s];
    }
    nib_encode_track(0, sp, trk);

    FILE *f = fopen("build/golden_track0.hex", "r");
    if (!f) { printf("SKIP golden (run sim first)\n"); }
    else {
        unsigned v; int n = 0;
        while (n < NIB_TRACK_LEN && fscanf(f, "%x", &v) == 1) want[n++] = (uint8_t)v;
        fclose(f);
        CHECK(n == NIB_TRACK_LEN, "golden has 7040 bytes");
        CHECK(memcmp(trk, want, NIB_TRACK_LEN) == 0, "encode matches the card's stream");
    }

    CHECK(nib_decode_track(trk, dec) == 0xffff, "all 16 sectors decode");
    for (int s = 0; s < 16; s++) CHECK(memcmp(dec[s], img[s], 256) == 0, "sector round trip");

    trk[7 * 440 + 100] ^= 1;   // corrupt sector 7's data field
    CHECK(nib_decode_track(trk, dec) == (uint16_t)~(1u << 7), "a corrupt sector is dropped");

    printf(fails ? "test_nibble: FAIL (%d)\n" : "test_nibble: PASS\n", fails);
    return fails != 0;
}
