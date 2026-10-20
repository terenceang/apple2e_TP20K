// Minimal QR encoder: version 3 (29x29), error correction L, byte mode, mask 0 only.
// Holds up to 53 bytes, which is what a "WIFI:T:WPA;S:...;P:...;;" payload needs.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define QR_SIZE 29

// m[y][x] = 1 for a dark module. False if text is longer than 53 bytes.
bool qr_encode(const char *text, uint8_t m[QR_SIZE][QR_SIZE]);
