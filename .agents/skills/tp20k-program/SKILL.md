---
name: tp20k-program
description: Program/flash/download a bitstream (.fs) onto the Sipeed Tang Primer 20K (Gowin GW2A-18C) over its onboard USB-JTAG using Gowin programmer_cli — to SRAM (temporary) or to the external SPI config flash (persistent). Use when the user wants to load, upload, program, flash, or erase the Tang Primer 20K, detect/scan the board, or troubleshoot "No Gowin devices found".
---

# Program the Tang Primer 20K

Based on UG290 (Gowin Programming and Configuration Guide,
`docs/Schematics/UG290-2.3E_...pdf`) and `programmer_cli --help`.

Always use the full path (an unused 1.9.12 install is still on disk).
programmer_cli loads DLLs from its own dir, so `cd` there and pass **absolute
Windows paths** for files:

```bash
PDIR=/c/Gowin/Gowin_V1.9.12.04_x64/Programmer/bin
FS=$(cygpath -w "$PWD/impl/pnr/top.fs")
cd "$PDIR"
```

## 1. Detect the board

```bash
./programmer_cli --scan-cables     # should list a Gowin USB cable
./programmer_cli --scan            # should report GW2A(R)-18(C)
```

Verified on this board (2026-10-20): `--scan-cables` lists `USB Debugger A/0` and `/1`
(the BL702 debugger, two channels); `--scan` reports `GW2A-18C GW2AR-18C GW2ANR-18C`,
ID `0x0000081B`. The default cable setting works — no `--cable` flag needed.

`Error: No Gowin devices found!` → board not plugged in / not powered, USB
cable is charge-only, or the onboard BL616/BL702 debugger driver isn't bound.
Ask the user to check; don't loop retrying.

## 2. Program

| Goal | Command | Persists? |
|---|---|---|
| SRAM (fast test) | `./programmer_cli -d GW2A-18C --run 2 --fsFile "$FS"` | No — lost on power cycle |
| SRAM + verify | `--run 4` | No |
| External flash (boot image) | `./programmer_cli -d GW2A-18C --run 36 --fsFile "$FS"` | Yes |
| External flash + verify | `--run 37` | Yes |
| Read ID code | `--run 0` | — |
| Erase SRAM | `--run 24` | — |
| Reprogram (reload from flash) | `--run 1` | — |

Default to **SRAM** while iterating; flash only when the user wants the design
to survive power-off. Writing flash overwrites the stored image — confirm first.

Run 36/37 = "exFlash Erase,Program thru GAO-Bridge", the mode Sipeed documents
for this board. If it fails, try the JTAG-direct modes 8/9
("exFlash Erase,Program[,Verify]"), then 12/13 (bscan). Optional `--spiaddr
0x000000` sets the flash start address (default 0).

The progress bar floods the output with carriage-return updates; filter it:
`./programmer_cli ... 2>&1 | tr '\r' '\n' | grep -v '^ *Programing'`.
SRAM load of a full bitstream takes ~5 s at the default 2.5 MHz (verified, run 2).

Add `--frequency 15MHz` to speed up large bitstreams if the link is stable
(default 2.5 MHz). Success output ends with `Finished.`/`Cost x second(s)`
and no `Error`.

## How the board boots (UG290 §5.5)

- GW2A MODE[2:0] = `000` = **MSPI**: on power-up or a RECONFIG_N low pulse the
  FPGA reads the bitstream from the external SPI flash (M9/L10/R10/P10).
  GW2A-18 retries a failed MSPI load once.
- JTAG works regardless of MODE, so SRAM loads always work.
- After loading flash, power-cycle or press reset/reconfig to boot it (or `--run 1`).
- READY/DONE are LEDs on the Dock (A13/C13) when used as GPIO, so they don't
  indicate config status in that case.
- MSPI clock defaults to 2.5 MHz (~1.4 s boot for a full 18K bitstream);
  raise "Loading Rate" in bitstream options for faster boot (≤ 30 MHz without FASTRD_N).

## Other formats

- `.fs` → `.bin`: `./programmer_cli --filestransform 1 --files "$FS"`
- Generate SVF instead of programming: `--svfcreate`.

## Alternative: openFPGALoader (not installed)

`openFPGALoader -b tangprimer20k top.fs` (SRAM) / `-b tangprimer20k -f top.fs`
(flash). Suggest only if programmer_cli can't see the cable.
