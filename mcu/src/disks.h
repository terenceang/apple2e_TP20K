// Disk library on the SD card (DISK_DIR), two drives served to the FPGA as nibble tracks.
// Which image each drive holds is kept in NVS, so it survives a reset.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SD_MOUNT "/sd"
#define DISK_DIR SD_MOUNT "/disks"
#define DISK_TRACKS 35
#define DISK_BYTES (DISK_TRACKS * 16 * 256)
#define DISK_NAME_MAX 31
extern const char *const DISK_EXTS[3];       // dsk, do, po

extern bool sd_ok;                           // set by main after mounting the card
bool disk_name_ok(const char *name);         // plain file name (A-Z a-z 0-9 . _ -) with a DISK_EXTS extension
void disk_path(char *out, size_t n, const char *name);   // DISK_DIR/<name>
const char *disk_name(int d);                // mounted file name, or NULL if the drive is empty
void disks_init(void);                       // makes DISK_DIR, remounts what each drive held at the last reset
bool disk_mount(int d, const char *name);    // from the library; remembered across resets; bumps the generation
void disk_eject(int d);                      // drive reads as empty; remembered across resets
bool disk_delete(const char *name);          // remove from the library, ejecting it from any drive first
void disks_status(uint8_t *gen0, uint8_t *gen1, uint8_t *flags);
bool disk_read_track(int d, int t, uint8_t *out /*7040*/);
void disk_write_track(int d, int t, const uint8_t *in /*7040*/);
