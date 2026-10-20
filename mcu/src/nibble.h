// Disk II nibble tracks: DSK/PO sectors <-> the 7040-byte stream the FPGA plays.
// C port of web/src/nibble.js; test/test_nibble.c checks it against the card's
// own stream (build/golden_track0.hex) and the JS decoder's cases.
#pragma once
#include <stdint.h>

#define NIB_SECT_LEN 440
#define NIB_TRACK_LEN (16 * NIB_SECT_LEN) /* 7040 */

// sectors[p] = 256 bytes at physical position p (ProDOS order).
void nib_encode_track(int track, const uint8_t *sectors[16], uint8_t *out /*7040*/);

// Decode every intact sector of a track (stream is circular). Returns a bit mask
// of physical sectors found; found sectors are written to out[p] (256 bytes).
uint16_t nib_decode_track(const uint8_t *trk /*7040*/, uint8_t out[16][256]);
