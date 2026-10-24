# Archived: TN20K SD card support

Removed from the live design because it does not fit. The Apple build was already ~92% full
(about 19k of 20,736 LUT4, 44 of 46 BSRAM once the SD buffer is added) and the FAT32 file layer
adds ~5k LUT4, so placement fails (`113%` LUT4, "Unable to find legal placement"). Nothing here is
referenced by `fpga.yaml`, `sim/run.ps1` or any script, so it never builds. Git history has the same
code: raw loader in commit `cd09e68` (and earlier), FAT32 smoke test in `7b85727`.

## What is here and how far each piece got

| Piece | Files | State |
|---|---|---|
| SPI byte engine, command set, UART TX | `src/sd/spi_byte.v`, `src/sd/sd_defs.vh`, `src/uart_tx.v` | shared by everything below; hardware-verified |
| Block layer (SDHC, SPI mode, 512 B buffer) | `src/sd/sd_blk.v` | hardware-verified; ~160 LUT4 + 1 BSRAM |
| Raw boot loader (ProDOS HD = sectors 0-4095, Disk II drive 1 = 4096-4375 + magic 4376, HD write-back, self-test sector 4095, status line) | `src/prodos/sd_loader.v`, `sim/tb_sd_loader.v` | worked on hardware (DOS 3.3 image uploaded, saved, reloaded after reset). Hazard: it writes raw sectors, so it corrupts a FAT card whose partition starts before sector 4377, and `SELFTEST` writes sector 4095 every boot |
| FAT32 smoke test: mount, create/write/read/delete `TEST.TXT` | `src/sdtest/fat_test.v` (on `fat32`), `top_sdtest.v`, `sim/tb_fat_test.v` | PASS on hardware on a FAT32 card (the first version, commit `7b85727`, had its own FAT code and a one-off FORMAT step that made the exFAT card FAT32) |
| FAT32 file layer: mount (MBR/VBR), listing with long names, contiguous alloc, long-name + 8.3 entries (`~N` tails, checksum), remove, delete (frees the chain), rename (add + remove) | `src/sd/fat32.v`, `sim/tb_fat32.v` | passes `tb_fat32` (2.5 s); hardware-verified only through the smoke test. ~2.4k LUT4 + 1.2k ALU + 1.3k FF |
| File-manager controller: boot mount from `TN20K.CFG`, host protocol, mount onto Disk II 1/2 and HD 1/2, HD write-back into the file, DOS-order to physical remap for `.dsk` files | `src/sd/sd_files.v`, `sim/tb_sd_files.v` | passes `tb_sd_files` (23 s); never reached hardware (does not fit). ~1k LUT4 + 0.4k ALU |
| Card model for the benches | `sim/models/sdcard.v` | |

Wiring as it was: `integration/top_with_raw_sd_loader.v` (committed state) and `integration/top_with_sd_files.v`
plus `integration/serial_debugger_with_file_session.v` (the `z` command: `M_FILE` passes UART bytes through
to `sd_files`). `integration/prodos_card_with_writeback.v` / `apple2_core_with_writeback.v` hold the
`wr_req/wr_blk/wr_ack` hook the card used to ask the loader to write a block back. `integration/scripts/` has the
`build.ps1 -Top sdtest`, `prog.ps1 -Top`, `sources.ps1 -Block` and `run.ps1` entries; `fpga.yaml.with_sd` has the source
lists (including `sdtest_sources`); `integration/sd_pins.cst` the pin lines.

## Hardware
TF slot on the Tang Nano 20K, SPI mode: CLK = pin 83, CMD/MOSI = 82, DAT0/MISO = 84, DAT3/CS = 81 (LVCMOS33,
MISO pull-up). `top.v` ports were `sd_clk`, `sd_mosi`, `sd_miso`, `sd_cs_n`.

## Things learned (worth keeping)
- A card left mid-transfer (FPGA reconfigured without a card power cycle) keeps clocking out data: after CMD0 keep polling for
  the idle R1 (0x01) for ~1000 bytes instead of failing on the first non-R1 byte.
- Write busy-wait can exceed 100 ms on some cards; poll up to ~1 s.
- `yosys abc9` crashes on Windows (see `scripts/build.ps1`); use `abc -lut 4`.
- Icarus does not support `\r` in string literals (it prints `r`); use `8'h0D`. The file protocol was made LF-only.
- 88-bit short-name registers with indexed part-selects, 32-bit address arithmetic everywhere and wide muxes are what made
  `fat32` big. A register-file RAM (LUT RAM is ~64 bits per 4 LUTs) or a smaller datapath would be far cheaper.
- A Disk II file named `.dsk` is in DOS 3.3 sector order; the store holds physical order (a `.po` file already is). The loader
  remapped with the DOS_TO_PHYS table from `web/src/disk.js`.

## Recommended way to bring it back
1. FPGA: raw sector I/O only (`spi_byte` + `sd_blk` + a small loader), boot mount by *start LBA + size* kept in a reserved
   sector in the MBR gap (e.g. LBA 1), HD write-back as `hd_start + block`. No FAT in the FPGA (about the size of the old `sd_loader`).
2. Web app: FAT32 in JavaScript over raw `read sector` / `write sector` commands (list, upload, download, delete, rename, long names,
   mount = write the LBA/size record), unit-tested in node against an in-memory image. `fat32.v` and `tb_fat32.v` are a
   working reference for the on-disk details (LFN order, checksum, `~N`, 0xE5, FAT chain, FSInfo not touched).
3. Keep `fat_test` as the standalone hardware smoke test (its own bitstream, no Apple core).
4. Check the LUT budget before wiring anything into the Apple build (target under ~19.5k LUT4 total, 44/46 BSRAM already used with the card buffer).

## Host protocol of the file controller (for reference)
`z` in the debugger starts the session; the controller prints `FILES\n`. `L` list (`F<TAB>idx<TAB>size<TAB>name`), `S` mounts,
`P len name size4` put (512-byte chunks, ACK 0x06 each), `G idx2` get, `D idx2` delete, `R idx2` rename, `M slot idx2` mount, `Q` quit;
errors `ERR <hex>`. Full text is in the header of `src/sd/sd_files.v`.
