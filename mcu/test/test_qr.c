// Host test: dumps the QR for argv[1] as 29 rows of 0/1, compared against Python's qrcode by test_qr.py.
// Build: python -m ziglang cc -o ../build/test_qr.exe test/test_qr.c src/qr.c
#include "../src/qr.h"
#include <stdio.h>
int main(int argc, char **argv) {
    static uint8_t m[QR_SIZE][QR_SIZE];
    if (argc < 2 || !qr_encode(argv[1], m)) return 1;
    for (int y = 0; y < QR_SIZE; y++) { for (int x = 0; x < QR_SIZE; x++) putchar('0' + m[y][x]); putchar('\n'); }
    return 0;
}
