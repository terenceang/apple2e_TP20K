#include "nibble.h"
#include <string.h>

static const uint8_t GCR[64] = {
    0x96, 0x97, 0x9a, 0x9b, 0x9d, 0x9e, 0x9f, 0xa6, 0xa7, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb2, 0xb3,
    0xb4, 0xb5, 0xb6, 0xb7, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xcb, 0xcd, 0xce, 0xcf, 0xd3,
    0xd6, 0xd7, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe5, 0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec,
    0xed, 0xee, 0xef, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
};

static int8_t DEC[256];
static int dec_ready;

static void dec_init(void) {
    if (dec_ready) return;
    memset(DEC, -1, sizeof DEC);
    for (int v = 0; v < 64; v++) DEC[GCR[v]] = (int8_t)v;
    dec_ready = 1;
}

static uint8_t swap2(uint8_t v) { return (uint8_t)(((v & 1) << 1) | ((v >> 1) & 1)); }
static uint8_t a44hi(uint8_t v) { return 0xaa | ((v >> 1) & 0x55); }
static uint8_t a44lo(uint8_t v) { return 0xaa | (v & 0x55); }
static uint8_t a44dec(uint8_t hi, uint8_t lo) { return (uint8_t)(((hi << 1) | 1) & lo); }

static void encode_field(const uint8_t *sec, uint8_t *out) {
    uint8_t grp[342];
    for (int k = 0; k < 86; k++) {
        uint8_t a = 172 + k < 256 ? swap2(sec[172 + k] & 3) : 0;
        uint8_t b = swap2(sec[86 + k] & 3);
        uint8_t c = swap2(sec[k] & 3);
        grp[k] = (uint8_t)((a << 4) | (b << 2) | c);
    }
    for (int k = 0; k < 256; k++) grp[86 + k] = sec[k] >> 2;
    for (int i = 0; i < 342; i++) out[i] = GCR[i == 0 ? grp[0] : grp[i] ^ grp[i - 1]];
    out[342] = GCR[grp[341]];
}

void nib_encode_track(int track, const uint8_t *sectors[16], uint8_t *out) {
    for (int s = 0; s < 16; s++) {
        uint8_t *o = out + s * NIB_SECT_LEN;
        memset(o, 0xff, NIB_SECT_LEN);
        o[48] = 0xd5; o[49] = 0xaa; o[50] = 0x96;
        const uint8_t hdr[4] = {0xfe, (uint8_t)track, (uint8_t)s, (uint8_t)(0xfe ^ track ^ s)};
        for (int i = 0; i < 4; i++) { o[51 + 2 * i] = a44hi(hdr[i]); o[52 + 2 * i] = a44lo(hdr[i]); }
        o[59] = 0xde; o[60] = 0xaa; o[61] = 0xeb;
        o[68] = 0xd5; o[69] = 0xaa; o[70] = 0xad;
        encode_field(sectors[s], o + 71);
        o[414] = 0xde; o[415] = 0xaa; o[416] = 0xeb;
    }
}

static int decode_field(const uint8_t *f, uint8_t *out) {
    uint8_t grp[342];
    uint8_t prev = 0;
    for (int i = 0; i < 342; i++) {
        int8_t v = DEC[f[i]];
        if (v < 0) return 0;
        prev = grp[i] = (uint8_t)(i == 0 ? v : v ^ prev);
    }
    if (DEC[f[342]] != grp[341]) return 0;
    for (int k = 0; k < 256; k++) {
        uint8_t pair = k < 86 ? grp[k] & 3 : k < 172 ? (grp[k - 86] >> 2) & 3 : (grp[k - 172] >> 4) & 3;
        out[k] = (uint8_t)((grp[86 + k] << 2) | swap2(pair));
    }
    return 1;
}

uint16_t nib_decode_track(const uint8_t *t, uint8_t out[16][256]) {
    dec_init();
    const int n = NIB_TRACK_LEN;
    uint16_t mask = 0;
    uint8_t field[343];
    for (int i = 0; i < n; i++) {
        if (t[i] != 0xd5 || t[(i + 1) % n] != 0xaa || t[(i + 2) % n] != 0x96) continue;
        uint8_t h[4];
        for (int j = 0; j < 4; j++) h[j] = a44dec(t[(i + 3 + 2 * j) % n], t[(i + 4 + 2 * j) % n]);
        if ((h[0] ^ h[1] ^ h[2]) != h[3] || h[2] > 15) continue;
        for (int j = i + 11; j < i + 11 + 100; j++) {
            if (t[j % n] == 0xd5 && t[(j + 1) % n] == 0xaa && t[(j + 2) % n] == 0xad) {
                for (int k = 0; k < 343; k++) field[k] = t[(j + 3 + k) % n];
                if (decode_field(field, out[h[2]])) mask |= (uint16_t)(1u << h[2]);
                break;
            }
        }
    }
    return mask;
}
