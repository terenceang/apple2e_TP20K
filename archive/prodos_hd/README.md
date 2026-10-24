# Archived: slot 7 ProDOS hard-disk card

Removed from the live design on request, while bringing up ProDOS on the Disk II. Nothing here is
referenced by `fpga.yaml`, `sim/run.ps1` or any script, so it never builds. The Autostart ROM scans slots
7 down to 1, so the card's boot ROM at `$C700` ran before the Disk II on every reset.

| Piece | Where |
|---|---|
| The card: 256-byte slot ROM (`$C700`, boot, ProDOS block-driver entry at `$C742`), `$C0F0-$C0FF` registers, 512-byte block buffer, SDRAM banks 2 and 3 as two 2 MB volumes, UART bulk upload/download | `src/prodos_card.v` |
| FPGA wiring that was taken out (apply with `patch -R -p1` from the repo root): `aux_ram.v` HD port and arbiter slot, `apple2_core.v` card instance, `$C0Fx` read mux, `card_present`, `top.v` wiring, `serial_debugger.v` `p1/p2` upload and `o1/o2` download plus their two strings, `fpga.yaml`, `sim/run.ps1`, `tb_p6boot.v` ties | `integration-fpga.patch` |
| Web side taken out: `validateHardDiskImage`, `uploadHardDisk`, `downloadHardDisk` and their tests, the Slot 7 tab in `DiskPane.tsx`, the callbacks in `useApple.ts` | `integration-web.patch` |

Host protocol it used: `p1`/`p2` upload, `o1`/`o2` download, 2,097,152 bytes in 512 chunks of 4,096, one ACK
(`06`) per chunk; the card's status bit 1 (drive 1 present) is what its boot ROM tested before jumping to
`$C600` as a fallback.

The patches are line-ending-insensitive (`--strip-trailing-cr`); the working tree is CRLF.
