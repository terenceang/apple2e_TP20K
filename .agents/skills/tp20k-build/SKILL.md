---
name: tp20k-build
description: Synthesize, place & route and generate a bitstream (.fs) for the Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7) from Verilog/VHDL using the Gowin IDE command line (gw_sh). Use when the user wants to build, compile, synthesize, or create a new FPGA project/design for the Tang Primer 20K, write a .cst constraints file, or look up a Tang Primer 20K Dock pin.
---

# Build for Tang Primer 20K

Toolchain: Gowin EDA at `C:/Gowin/Gowin_V1.9.12.04_x64`. It's on the user PATH, but call it by
full path anyway (shells opened before the PATH change, and an unused 1.9.12 install is still on disk).

```bash
GW_SH=/c/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh
```

Device: part `GW2A-LV18PG256C8/I7`, family `GW2A-18C` (programmer device name too).

## Project layout

```
<proj>/
  src/top.v      # HDL (Verilog .v / SystemVerilog .sv / VHDL .vhd)
  src/top.cst    # physical constraints (pins)
  src/top.sdc    # optional timing constraints
  sim/tb_top.v   # testbenches (tp20k-sim) — never add to build.tcl
  build.tcl
```

## build.tcl

```tcl
set_device -name GW2A-18C GW2A-LV18PG256C8/I7
add_file src/top.v
add_file src/top.cst
# add_file src/top.sdc
set_option -top_module top
set_option -output_base_name top
set_option -verilog_std sysv2017        ;# only if using SystemVerilog
set_option -use_sspi_as_gpio 1          ;# T10 reset/key, C10, T9, N9, M8 — P&R fails without it
set_option -use_ready_as_gpio 1         ;# A13 = LED1 on the Dock
set_option -use_done_as_gpio 1          ;# C13 = LED0 on the Dock
run all
```

Run from the project dir (takes ~10 s for small designs):

```bash
cd <proj> && "$GW_SH" build.tcl 2>&1 | tail -30
```

Output: `impl/pnr/top.fs` (bitstream for programming), plus `top.rpt.txt`
(utilization), `top.log`. Timing summary (Fmax, TNS) is in `top_tr_content.html`:
`sed "s/<[^>]*>/ /g" impl/pnr/top_tr_content.html | tr -s " \n" " " | grep -o -E "Max Frequency Summary.{0,250}"`. Check the log for `ERROR`;
a successful run ends with `Bitstream generation completed`.

Other useful options: `-use_mspi_as_gpio 1` (only if
you use those pins — MSPI pins are the config flash), `-bit_compress 1`,
`-gen_text_timing_rpt 1`. Add a clock constraint to silence `TA1132`:
`create_clock -name clk -period 37.037 [get_ports {clk}]` in a `.sdc`.

Flow: simulate first (`tp20k-sim`), build here, then program (`tp20k-program`).

## Pin reference

**Full pinout: `docs/pinout.md`** (every Dock/SOM peripheral, bank voltages, PMODs,
shared-pin conflicts). Read it before writing a `.cst`. Most-used:

| Signal | Ball | Notes |
|---|---|---|
| 27 MHz clock | H11 | |
| LED0..LED5 | C13, A13, N16, N14, L14, L16 | active **low**; C13/A13 need `use_done_as_gpio`/`use_ready_as_gpio` |
| Key S1 / reset | T10 | active low, 3.3 V, needs `use_sspi_as_gpio` |
| Keys S2..S5 | T3, T2, D7, C7 | active low, **1.5 V bank → LVCMOS15** |
| UART TX / RX | M11 / T13 | via BL702 USB-C COM port |

If a signal isn't in `docs/pinout.md`, read the ball from the schematic net name
(`<ball>_<io>_<function>`) — never guess.

## .cst syntax

```
IO_LOC  "clk" H11;
IO_PORT "clk" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "led[0]" L16;
IO_PORT "led[0]" IO_TYPE=LVCMOS33 DRIVE=8;
```

Bus bits are constrained one per line. Banks with 1V5 in the net name
(e.g. `T2_IOB48B_1V5`) are 1.5 V banks — use `LVCMOS15`/`SSTL15` there.

## Gotchas

- `run all` reuses the project in `impl/`; delete `impl/` if results look stale.
- IP (PLL `rPLL`, DDR3, etc.) is generated in the Gowin IDE GUI; add the
  generated `.v` with `add_file`. The GW2A-18C PLL primitive is `rPLL`.
- Default bitstream has the security bit set (no readback) — that's normal.
