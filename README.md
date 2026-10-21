# Apple //e on Tang Primer 20K

An Apple //e implemented in Verilog for the [Sipeed Tang Primer 20K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/primer-20k.html) (Gowin GW2A-LV18PG256C8/I7) on its Dock board, built with Gowin EDA.

This project's code was written with AI assistance.

## Features

- **65C02 CPU** at 1.023 MHz (Arlet Ottens' core with 65C02 extensions)
- **128 KB**: 48 KB main RAM and the 16 KB ROM in block RAM; the aux 64 KB and the language card in the SOM's DDR3
- **HDMI video** at 720×480p60 (CEA-861 VIC 2), with the 560×384 Apple display centered: text (40 and 80 column, MouseText), lo-res, hi-res and double hi-res, mixed mode and page 2; colour is an NTSC-style decode of the dot stream, so fills, fringes and the palette bit look as they do on a TV
- **Audio** from the $C030 speaker and a **Mockingboard C** in slot 4, over HDMI (48 kHz L-PCM) and through the Dock's PT8211 DAC and amplifier to the 3.5 mm jack
- **Disk II** in slot 6 (two drives) and a **ProDOS hard disk** in slot 7 (two 32 MB volumes), all kept as **image files on an ordinary FAT32 TF card**; what each drive holds survives power-off, and floppy and hard-disk writes go back into the files
- **Keyboard, gamepad and debugger over USB serial** at 1 Mbps; the [browser front end](web/README.md) in `web/` has the keyboard, the text screen, the debugger and the disk drives
- **Built-in hardware debugger**: Ctrl+B freezes the CPU to inspect registers, single-step and dump memory
- **Loading screen** while the TF card's images load at power-on, so a 32 MB volume (~30 s) does not look like a hang

## Requirements

- Tang Primer 20K with the Dock board, and a TF card (FAT32, so 32 GB or smaller, or a bigger one reformatted FAT32)
- Gowin EDA 1.9.12.04 (`gw_sh` and `programmer_cli`, at the paths in `scripts/build.ps1` and `scripts/prog.ps1`)
- [Icarus Verilog](https://github.com/steveicarus/iverilog) for the testbenches (the OSS CAD Suite's, found by `scripts/toolchain.ps1`)
- Windows PowerShell 5.1; [GNU make](https://www.gnu.org/software/make/) is optional, as a shorthand (`winget install GnuWin32.Make`)
- Node 20.19+ for the web front end
- Apple //e ROM images. **These are not included**; see [`roms/README.md`](roms/README.md)

## Building

```sh
make            # synthesis, place & route, bitstream => build/bitstream/apple2e_TP20K.fs
make flash-sram # load into SRAM (lost on power cycle)
make flash      # write to the configuration flash (persistent)
make clean
```

`make` only wraps `scripts/build.ps1` and `scripts/prog.ps1`, which can be run directly. The build generates its Gowin Tcl from `fpga.yaml` (add new source files there), also writes `apple2e_TP20K.gprj` so the Gowin IDE opens the same project, and fails if the timing report shows negative setup slack. Programming uses the Dock's USB-JTAG; keep DIP switch 1 on.

```sh
powershell -File sim\run.ps1            # every testbench (tb_top needs the ROMs)
powershell -File sim\run.ps1 -Target tb_sdvol
```

`scripts/hdmi_diff.ps1 -Check` verifies that `src/hdmi/` still matches its recorded snapshot, and `-Upstream` reports what has changed in the TN20K-HDMI project since.

## Using it

1. Copy disk images onto a FAT32 TF card on a PC (`.dsk`/`.do`/`.po` floppies, `.hdv`/`.po` hard-disk volumes) and put it in the SOM's slot.
2. Connect HDMI and the Dock's USB-C, and flash the bitstream.
3. Open the [web front end](web/README.md) in Chrome or Edge and press Connect. The Disks pane lists the card's images; click one and pick a drive. The board remembers the choice in `A2CONFIG.TXT` on the card and loads it at every power-on.

A plain serial terminal at **1000000 8N1** works too: what you type goes to the Apple, and what it prints through COUT comes back.

**Keys on the Dock:** S1 resets the Apple (the TF card's images reload); hold S2 for HDMI colour bars and a 1 kHz tone, which checks the HDMI link independently of the Apple core. HDMI audio needs a display that accepts it (not a DVI-only input).

### Debugger

Press **Ctrl+B** to pause the CPU and enter the debugger; press it again (or `c`) to leave.

| Key | Action |
|-----|--------|
| `r` | CPU registers (PC, A, X, Y, SP, P, opcode) |
| `s` | Single-step one instruction |
| `c` | Continue (also `g`) |
| `m` | Dump 16 bytes of memory; `@hhhh` or `0 1 4 8 f v k j` set the address |
| `t` | Hardware status (video mode, PLL and DDR3) |
| `w` | Dump the text page, and the graphics page in mixed mode |
| `i` | What the drives hold, and the TF card's state |
| `x` | Reset the CPU |
| `h` | Help (also `?`) |

The disk commands the web page uses (`d e n` for floppy images over the link, `b u y` for the TF card) are described in [`web/README.md`](web/README.md). Commands are only read when the debugger is idle, so anything sent while it is still printing is dropped; the web page waits for 200 ms of silence.

### The TF card

An ordinary FAT32 card, readable on any PC. Images go in the root directory; `A2CONFIG.TXT` there names each drive's file by its 8.3 name (`S6D1=LODERU~1.DSK`), and the web page writes it for you. The FPGA has no file system of its own: at power-on it finds the config and the four files by name, checks each is in one piece on the card and of the right size, and streams it in. A file that is missing, fragmented or the wrong kind leaves its drive empty, and the page says why. Slot 6 takes 143,360-byte `.dsk`/`.do`/`.po` images; slot 7 takes `.hdv`/`.po` volumes up to 32 MB (a `.dsk` is in DOS sector order, so it cannot be a ProDOS block device).

Copying through the board runs at the serial link's speed, about 13 s for a floppy and up to ~48 minutes for a full 32 MB volume, so big volumes are best copied with a card reader.

### LEDs

| LED | Meaning |
|-----|---------|
| 0 | Heartbeat |
| 1 | PLLs locked and DDR3 calibrated |
| 2 | Running (out of reset) |
| 3 | CPU memory write |
| 4 | Text mode |
| 5 | Keyboard strobe pending |

## Web front end

`web/` is a React app that puts the //e's keyboard, its text screen, the debugger and the disk drives in the browser, over the same USB serial link. It needs nothing installed: Web Serial opens the port, and the app is a static bundle (Chrome or Edge, over https or localhost).

```sh
cd web && npm install && npm run build
python3 -m http.server -d web/dist 8000   # http://localhost:8000
```

`cd web && npm run pages` builds it without the Apple character ROM, checks that it really is not in there, and copies it to `docs/`, the GitHub Pages root. Everything in `docs/` is published; the board documentation lives in `Documents/`. The screen is drawn from the same 2732 video ROM the FPGA reads, so a local build needs the ROM supplied first — see [`web/README.md`](web/README.md).

## Video and HDMI

The 560×384 Apple raster (40 columns × 14 pixel clocks, 192 lines doubled) is centered in the 720×480 frame at x = 80..639, y = 48..431; lines from 432 on are vertical blanking ($C019). `hdmi_tx` owns the raster and asks for each pixel combinationally, and `video_generator.v` registers its colour output, so `top.v` feeds it the next pixel (`h_cnt = pixel_x + 1`). Hi-res colour comes from decoding the 560-sample dot stream the way an NTSC set does: each pixel looks at a 4-sample window, luma is the lit count and chroma comes from the sample phases, so a `0101` pattern fills solid and colour edges fringe. The AVI InfoFrame declares full-range RGB (`RGB_QUANT = 2'b10`) so a TV does not crush the Apple's blacks. Audio is resampled from the DAC's 46.875 kHz to 48 kHz and sent in HDMI data islands (ACR N = 6144, CTS = 27000).

## Project layout

```
src/top.v               top level: clocks, HDMI serializers, DDR3, TF card, LEDs, reset, loading screen colours
src/apple2_core.v       CPU, address decode, softswitches, language card, slots, loading screen text
src/apple2_mem.v        block-RAM RAM and ROMs
src/aux_ram.v           aux RAM, language card, Disk II and hard-disk storage in DDR3
src/video_generator.v   Apple raster into the 720x480 frame
src/hdmi/               HDMI transmitter: timing, TMDS, data islands, audio/InfoFrame packets
src/sound_generator.v   speaker and Mockingboard to the PT8211 DAC
src/mockingboard/       Mockingboard C (two 6522 VIAs, two AY-3-8910s), slot 4
src/disk2/              Disk II card and image store, slot 6
src/prodos_hd.v         ProDOS block device, slot 7
src/sd_vol.v            the TF card: finds the drives' files on FAT32, loads them, writes them back
src/input_controller.v  UART RX, keyboard, gamepad, $C0xx input registers
src/serial_debugger.v   UART TX, console mirror, hardware debugger
src/cpu/                65C02 core
constraints/top.cst     pin assignments
sim/                    iverilog testbenches (sim/run.ps1)
roms/                   ROM images (supply your own)
scripts/                build, programming and snapshot scripts
web/                    the browser front end (see web/README.md)
Documents/              board documentation, memory architecture, design notes
```

## License

The version is in [`VERSION`](VERSION).

[MIT](LICENSE) © 2026 Terence Ang / motionfxdesign.

The HDMI transmitter in `src/hdmi/` is a local copy of the one from the TN20K-HDMI project, taken at commit `388b39e` and differing only in `hdmi_tx`'s `RGB_QUANT` parameter. The 65C02 core in `src/cpu/` is by Arlet Ottens, David Banks and Ed Spittles, and stays under its original permissive terms (see the file headers). The DDR3 controller in `src/ddr3_memory_interface/` is Gowin's generated IP netlist, taken from Sipeed's BSD-3-Clause TangPrimer-20K-example (see its README). Apple //e ROMs are copyright Apple and are not part of this project.
