#include "qr.h"
#include <string.h>

#define N QR_SIZE
#define DATA_CW 55
#define EC_CW 15

static uint8_t mod_[N][N], fn_[N][N];   // module colour, and "is a function pattern"

static void setf(int x, int y, int dark) {
    if (x < 0 || y < 0 || x >= N || y >= N) return;
    mod_[y][x] = (uint8_t)dark;
    fn_[y][x] = 1;
}

static int cheb(int dx, int dy) {
    dx = dx < 0 ? -dx : dx; dy = dy < 0 ? -dy : dy;
    return dx > dy ? dx : dy;
}

static uint8_t gmul(uint8_t a, uint8_t b) {   // GF(256), x^8 + x^4 + x^3 + x^2 + 1
    uint8_t r = 0;
    for (; b; b >>= 1) { if (b & 1) r ^= a; a = (uint8_t)((a << 1) ^ ((a >> 7) * 0x11d)); }
    return r;
}

static void rs_ec(const uint8_t *data, uint8_t *ec) {
    uint8_t div[EC_CW] = {0}, root = 1;
    div[EC_CW - 1] = 1;
    for (int i = 0; i < EC_CW; i++) {
        for (int j = 0; j < EC_CW; j++) {
            div[j] = gmul(div[j], root);
            if (j + 1 < EC_CW) div[j] ^= div[j + 1];
        }
        root = gmul(root, 2);
    }
    memset(ec, 0, EC_CW);
    for (int i = 0; i < DATA_CW; i++) {
        uint8_t f = data[i] ^ ec[0];
        memmove(ec, ec + 1, EC_CW - 1);
        ec[EC_CW - 1] = 0;
        for (int j = 0; j < EC_CW; j++) ec[j] ^= gmul(div[j], f);
    }
}

bool qr_encode(const char *text, uint8_t out[N][N]) {
    size_t len = strlen(text);
    if (len > 53) return false;

    // data bits: mode 0100, 8-bit count, bytes, terminator, pad to the 55 codewords
    uint8_t cw[DATA_CW + EC_CW] = {0};
    int nb = 0;
#define PUT(v, n) do { for (int b_ = (n) - 1; b_ >= 0; b_--, nb++) cw[nb >> 3] |= (uint8_t)((((v) >> b_) & 1) << (7 - (nb & 7))); } while (0)
    PUT(4, 4);
    PUT(len, 8);
    for (size_t i = 0; i < len; i++) PUT((uint8_t)text[i], 8);
    nb += DATA_CW * 8 - nb < 4 ? DATA_CW * 8 - nb : 4;      // terminator (zeros)
    nb = (nb + 7) & ~7;
    for (uint8_t pad = 0xec; nb < DATA_CW * 8; nb += 8, pad ^= 0xec ^ 0x11) cw[nb >> 3] = pad;
    rs_ec(cw, cw + DATA_CW);

    memset(mod_, 0, sizeof mod_);
    memset(fn_, 0, sizeof fn_);
    for (int i = 0; i < N; i++) { setf(6, i, i % 2 == 0); setf(i, 6, i % 2 == 0); }
    static const int fc[3][2] = {{3, 3}, {N - 4, 3}, {3, N - 4}};
    for (int f = 0; f < 3; f++)
        for (int dy = -4; dy <= 4; dy++)
            for (int dx = -4; dx <= 4; dx++) {
                int d = cheb(dx, dy);
                setf(fc[f][0] + dx, fc[f][1] + dy, d != 2 && d != 4);
            }
    for (int dy = -2; dy <= 2; dy++)                         // the one alignment pattern, at (22,22)
        for (int dx = -2; dx <= 2; dx++) setf(22 + dx, 22 + dy, cheb(dx, dy) != 1);

    // format bits: ECC L (01), mask 0, BCH(15,5)
    unsigned data = 1u << 3, rem = data;
    for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    unsigned bits = ((data << 10) | rem) ^ 0x5412;
#define BIT(i) (((bits) >> (i)) & 1)
    for (int i = 0; i <= 5; i++) setf(8, i, BIT(i));
    setf(8, 7, BIT(6)); setf(8, 8, BIT(7)); setf(7, 8, BIT(8));
    for (int i = 9; i < 15; i++) setf(14 - i, 8, BIT(i));
    for (int i = 0; i < 8; i++) setf(N - 1 - i, 8, BIT(i));
    for (int i = 8; i < 15; i++) setf(8, N - 15 + i, BIT(i));
    setf(8, N - 8, 1);                                       // the always-dark module

    // zig-zag the codewords in, then mask 0 over the data modules
    int bit = 0;
    for (int right = N - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;
        for (int v = 0; v < N; v++)
            for (int j = 0; j < 2; j++) {
                int x = right - j, y = ((right + 1) & 2) == 0 ? N - 1 - v : v;
                if (!fn_[y][x] && bit < (DATA_CW + EC_CW) * 8) {
                    mod_[y][x] = (cw[bit >> 3] >> (7 - (bit & 7))) & 1;
                    bit++;
                }
            }
    }
    for (int y = 0; y < N; y++)
        for (int x = 0; x < N; x++) {
            if (!fn_[y][x] && (x + y) % 2 == 0) mod_[y][x] ^= 1;
            out[y][x] = mod_[y][x];
        }
    return true;
}
