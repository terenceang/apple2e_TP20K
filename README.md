# Apple //e on Tang Primer 20K

An Apple //e implemented in Verilog for the [Sipeed Tang Primer 20K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/primer-20k.html) (Gowin GW2A-LV18PG256C8/I7) on its Dock board, built with Gowin EDA.

This project's code was written with AI assistance.

## Features

- **65C02 CPU** at 1.023 MHz (Arlet Ottens' core with 65C02 extensions)
- **128 KB**: 48 KB main RAM and the 16 KB ROM in block RAM; the aux 64 KB and the language card in the SOM's DDR3
- **HDMI video** at 720×480p60 (CEA-861 VIC 2), with the 560×384 Apple display centered: text (40 and 80 column, MouseText), lo-res, hi-res and double hi-res, mixed mode and page 2; colour is an NTSC-style decode of the dot stream, so fills, fringes and the palette bit look as they do on a TV
- **Colour TV mode and scanlines** on the Dock's keys: S3 softens hi-res and double hi-res the way a composite set blends fringes and bleeds colour at edges, and S4 steps scanlines off, 25%, 50% and 75%
- **Audio** from the $C030 speaker and a **Mockingboard C** in slot 4 (two 6522s, two AY-3-8910s), filtered once to 48 kHz (no aliasing from high AY tones) and sent over HDMI (L-PCM) and through the Dock's PT8211 DAC and amplifier to the 3.5 mm jack
- **Disk II** in slot 6 (two drives) and a **ProDOS hard disk** in slot 7 (two 32 MB volumes, also answering as a SmartPort), all kept as **image files on an ordinary FAT32 TF card**; what each drive holds survives power-off, and floppy and hard-disk writes go back into the files. Floppies are **WOZ** files played bit by bit through a model of the controller's sequencer, so copy-protected originals, 13-sector disks and bit copiers work, and every write is kept exactly
- **Clock** in slot 5 that ProDOS uses as a Thunderclock, so files get dated; the web page sets the time when it connects (there is no battery, so it is lost at power-off)
- **Z-80 SoftCard** in slot 2 (Microsoft's, at its 2.045 MHz), for Apple CP/M; the Z80 takes the bus over from the 6502 as on the real card
- **Super Serial Card** in slot 1 whose line is the USB link: the web page plays a **Hayes modem** on it (AT commands, `ATDT host:port` to a telnet BBS through a WebSocket gateway, `ATDT wss://...` direct, `ATDT LOOP` for a loopback), so ProTERM and other comm programs dial out from the Apple
- **Keyboard, gamepad and debugger over USB serial** at 1 Mbps; the [browser front end](web/README.md) in `web/` has the keyboard, the text screen, the debugger, the disk drives (with format conversion and new blank floppies) and the modem
- **Built-in hardware debugger**: Ctrl+B freezes the CPU to inspect registers, single-step and dump memory

## Requirements

- Tang Primer 20K with the Dock board, and a TF card (FAT32, so 32 GB or smaller, or a bigger one reformatted FAT32)
- Gowin EDA 1.9.12.04 (`gw_sh` and `programmer_cli`, at the paths in `scripts/build.ps1` and `scripts/prog.ps1`)
- [Icarus Verilog](https://github.com/steveicarus/iverilog) for the testbenches (the OSS CAD Suite's, found by `scripts/toolchain.ps1`)
- Python 3 with [py65](https://github.com/mnaberez/py65) (`pip install py65`), to assemble and test slot 7's firmware (`scripts/hdrom.py`, `scripts/hdrom_test.py`)
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

1. **A FAT32 TF card is required**: every drive loads from an image file on it, and there is no other way in. Put floppies on it as `.woz` (the web page converts `.dsk`/`.do`/`.po`/`.nib` on upload; with a card reader, convert them with `node web/scripts/towoz.mjs`) and hard-disk volumes as `.hdv`/`.po`, and put it in the SOM's slot; images can also be copied onto it later from the web page.
2. Connect HDMI and the Dock's USB-C, and flash the bitstream.
3. Open the [web front end](web/README.md) in Chrome or Edge and press Connect. The Disks pane lists the card's images; click one and pick a drive, or use LOAD → *From this computer…* to copy an image onto the card and load it in one go. The board remembers the choice in `A2CONFIG.TXT` on the card and loads it at every power-on.

A plain serial terminal at **1000000 8N1** works too: what you type goes to the Apple, and what it prints through COUT comes back.

**Keys on the Dock:** S1 resets the Apple (the TF card's images reload); hold S2 for HDMI colour bars and a 1 kHz tone, which checks the HDMI link independently of the Apple core. S3 switches hi-res and double hi-res to a **colour TV** look (the same NTSC decode over two colour cycles, so fringes blend and colours bleed at edges like a composite set); S4 steps **scanlines** off, 25%, 50%, 75% (the second line of each doubled Apple line darkened). Both start off at power-up. HDMI audio needs a display that accepts it (not a DVI-only input).

### Debugger

Press **Ctrl+B** to pause the CPU and enter the debugger; press it again (or `c`) to leave.

| Key | Action |
|-----|--------|
| `r` | CPU registers (PC, A, X, Y, SP, P, opcode) |
| `s` | Single-step one instruction |
| `c` | Continue |
| `m` | Dump 16 bytes of memory; `@hhhh` or `0 1 4 8 f v` set the address |
| `t` | Hardware status (video mode, PLL and DDR3) |
| `w` | Dump the text page, and the graphics page in mixed mode |
| `i` | What the drives hold, and the TF card's state |
| `x` | Reset the CPU |
| `h` | Help (also `?`) |

The TF card commands the web page uses (`b u y`) are described in [`web/README.md`](web/README.md). Commands are only read when the debugger is idle, so anything sent while it is still printing is dropped; the web page waits for 200 ms of silence.

### The TF card

An ordinary FAT32 card, readable on any PC. Images go in the root directory; `A2CONFIG.TXT` there names each drive's file by its 8.3 name (`S6D1=LODERU~1.WOZ`), and the web page writes it for you. The FPGA has no file system of its own: at power-on it finds the config and the four files by name, checks each is in one piece on the card and of the right size, and streams the floppies in. Hard-disk volumes stay on the card: each block is read when ProDOS asks for it, and the last one read or written is remembered. A file that is missing, fragmented or the wrong kind leaves its drive empty, and the page says why. Slot 6 takes `.woz` files (WOZ 2, up to 1 MB); slot 7 takes `.hdv`/`.po` volumes up to 32 MB.

### Floppies: WOZ, bit by bit

Slot 6 reads one format, [WOZ 2](https://applesaucefdc.com/woz/reference2/), the preservation format for Apple II disks: each track is the stream of bits the drive head sees. The whole file sits in DDR3; the card plays the track under the head one bit per 4 CPU cycles (300 rpm), on the 6502's own clock as the real controller is, so the CPU being held up for a moment can never make it miss a byte, through a model of the MC3470 read amplifier (long runs of zeros read as noise) into the controller's shift register and data latch, so self-sync, nibble counts, odd address marks and half/quarter tracks behave as on the hardware. Writes go into the same bits, one per 4 cycles, so a format or a bit copier writes exactly what it wrote on a real drive; the written blocks of the file are copied back to the card about a second after the drive goes quiet (the file's CRC is set to 0, which WOZ readers take as "not computed").

The conversion is done on the PC, by the page or `web/scripts/towoz.mjs`: `.dsk`/`.do` (DOS order) and 140K `.po` (ProDOS order) become standard 16-sector tracks, `.nib` keeps its nibbles, and WOZ 1 is re-laid as WOZ 2. **New blank floppy** on the page makes an unformatted disk for DOS `INIT` or a ProDOS format, and a `.woz` of a standard disk can be downloaded back as a `.dsk`. The drive's 74LS123 motor spin-down (~1 s) is modelled too, so DOS does not wait for spin-up between sectors. Tried on the board: the DOS 3.3 System Master boots from a converted `.woz` (power-on, Ctrl-OpenApple-Reset and `PR#6`), a `SAVE`d file survives the drive being reloaded from the card and the FPGA being reloaded, and a new blank floppy takes `INIT`.

Estimated hard-disk timing per 512-byte block (from the design, not yet measured on hardware):

| Case | Time | Why |
|------|------|-----|
| Best: the block just read or written | ~7.6 ms | the 6502's copy loop alone (512 × 15 cycles at 1.02 MHz) |
| Typical: any other block | ~8–9 ms | + one card read, ~0.4 ms of transfer plus 0.1–1 ms of card access |
| Slow card | ~110 ms | the SD card's 100 ms read limit |
| Worst: behind a floppy write-back | ~360 ms | waits for the one sector already being written (250 ms write limit) |
| Card removed | ~0.75 s, then I/O error | the board gives up and ProDOS gets error $27 |
| Write | ~7 ms + 1–3 ms (worst 250 ms) | the copy loop, then the card writing the block |

That is roughly 60 KB/s, set by the 1 MHz CPU rather than the card: about 5–10× a Disk II and about the same as the fastest real //e hard-disk cards.

To measure your own card: use the hard disk for a while, press Ctrl+B, then `@c0f0` and `m`. The last eight bytes of that line are four 16-bit little-endian times in units of 9.48 µs: the last read, the worst read, the last write and the worst write (the card's part only; a remembered block reads as 0). `POKE 49399,0` (`$C0F7`) clears them.

Copying through the board runs at the serial link's speed, about 20 s for a floppy and up to ~48 minutes for a full 32 MB volume, so big volumes are best copied with a card reader.

### LEDs

| LED | Meaning |
|-----|---------|
| 0 | Heartbeat |
| 1 | PLLs locked and DDR3 calibrated |
| 2 | Running (out of reset) |
| 3 | CPU memory write |
| 4 | Text mode |
| 5 | Keyboard strobe pending |

### Modem (Super Serial Card)

Slot 1 holds a Super Serial Card whose serial line is the USB link, and the web page is the modem on the other end (the **Modem** pane). A comm program on the Apple talks to it as to a Hayes modem: `ATI`, `ATZ`, `ATDT bbs.example.org:23` and so on, `+++` to get back to command mode, `ATH` or dropping DTR to hang up. A browser cannot open a TCP connection, so `ATDT host:port` goes through a **WebSocket gateway** whose address you enter in the pane (for example a [websockify](https://github.com/novnc/websockify) you run yourself), with `{host}` and `{port}` in it; `ATDT wss://...` dials a BBS that offers WebSockets directly, and `ATDT LOOP` is a loopback for trying it out. The page speaks telnet to the BBS and paces bytes to the Apple at the baud it set. The card's firmware ROM (341-0065-A) is Apple's: put it in `roms/ssc.hex` and rebuild for `PR#1`/`IN#1` and for programs such as ProTERM that look for the card; without it the card's 6551 still works for software that drives it directly. Tried on the board: a 6502 program sent `ATI` through the 6551 and read the modem's answer back.

### CP/M (Z-80 SoftCard)

Slot 2 holds a Microsoft Z-80 SoftCard. Put a SoftCard CP/M disk image (2.20 or 2.23) on the TF card as `S6D1` and boot it with `PR#6` (with a hard-disk volume in slot 7, the Autostart ROM boots that first). CP/M finds the card itself. The Z80 runs at the real card's 2.045 MHz and shares the Apple's memory and I/O, so the 6502 waits while it runs, as on the real card. Not yet tried on hardware.

## Web front end

`web/` is a React app that puts the //e's keyboard, its text screen, the debugger and the disk drives in the browser, over the same USB serial link. It needs nothing installed: Web Serial opens the port, and the app is a static bundle (Chrome or Edge, over https or localhost).

```sh
cd web && npm install && npm run build
python3 -m http.server -d web/dist 8000   # http://localhost:8000
```

`cd web && npm run pages` builds it without the Apple character ROM, checks that it really is not in there, and copies it to `docs/`, the GitHub Pages root. Everything in `docs/` is published; the board documentation lives in `Documents/`. The screen is drawn from the same 2732 video ROM the FPGA reads, so a local build needs the ROM supplied first — see [`web/README.md`](web/README.md).

## Video and HDMI

The 560×384 Apple raster (40 columns × 14 pixel clocks, 192 lines doubled) is centered in the 720×480 frame at x = 80..639, y = 48..431; lines from 432 on are vertical blanking ($C019). `hdmi_tx` owns the raster and asks for each pixel combinationally, and `video_generator.v` registers its colour output, so `top.v` feeds it the next pixel (`h_cnt = pixel_x + 1`). Hi-res colour comes from decoding the 560-sample dot stream the way an NTSC set does: each pixel looks at a 4-sample window, luma is the lit count and chroma comes from the sample phases, so a `0101` pattern fills solid and colour edges fringe. Colour TV mode (key S3) widens that to two colour cycles weighted 1 2 3 4 4 3 2 1, so edges blend while solid colours stay the same (the picture sits ~4 pixels right in that mode); scanlines (key S4) darken the second copy of each doubled Apple line. The AVI InfoFrame declares full-range RGB (`RGB_QUANT = 2'b10`) so a TV does not crush the Apple's blacks. Audio is filtered to 48 kHz once (`audio_filter.v`: an exact CIC to 96 kHz, then a 47-tap halfband FIR on one DSP multiplier, so AY tones above 24 kHz do not alias), and the same samples go to the DAC and into HDMI data islands (ACR N = 6144, CTS = 27000).

## Project layout

```
src/top.v               top level: clocks, HDMI serializers, DDR3, TF card, LEDs, reset
src/apple2_core.v       CPU, address decode, softswitches, language card, slots
src/apple2_mem.v        block-RAM RAM and ROMs
src/aux_ram.v           aux RAM, language card, Disk II and hard-disk storage in DDR3
src/video_generator.v   Apple raster into the 720x480 frame
src/hdmi/               HDMI transmitter: timing, TMDS, data islands, audio/InfoFrame packets
src/sound_generator.v   speaker and Mockingboard to the PT8211 DAC
src/audio_filter.v      the 48 kHz resampler (CIC in DSP blocks, halfband FIR)
src/mockingboard/       Mockingboard C (two 6522 VIAs, two AY-3-8910s), slot 4
src/disk2/              Disk II card and image store, slot 6
src/prodos_hd.v         ProDOS block device and SmartPort, slot 7
src/prodos_hd_rom.s     its firmware, 6502 source (scripts/hdrom.py assembles it)
src/thunderclock.v      clock card ProDOS takes for a Thunderclock, slot 5
src/softcard.v          Microsoft Z-80 SoftCard, slot 2 (Z80 core in src/z80/)
src/ssc.v               Super Serial Card, slot 1 (its line is the USB link)
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

## Credits

This project uses work by others, with thanks:

| What | Where | By | Terms |
|------|-------|----|-------|
| 6502 CPU core | `src/cpu/` | Arlet Ottens ([verilog-6502](https://github.com/Arlet/verilog-6502)) | keep the copyright notice (in the file headers) |
| 65C02 extensions to it | `src/cpu/` | David Banks and Ed Spittles ([hoglet67/verilog-6502](https://github.com/hoglet67/verilog-6502)) | as above |
| Z80 CPU core (TV80) | `src/z80/` | Guy Hutchison ([hutch31/tv80](https://github.com/hutch31/tv80)), after Daniel Wallner's T80 | MIT, [`LICENSE`](src/z80/LICENSE) there |
| DDR3 Memory Interface IP (encrypted netlist) | `src/ddr3_memory_interface/` | Gowin Semiconductor, via Sipeed's [TangPrimer-20K-example](https://github.com/sipeed/TangPrimer-20K-example) (© 2022 LAKKA) | BSD-3-Clause, [`LICENSE`](src/ddr3_memory_interface/LICENSE) there |
| HDMI transmitter | `src/hdmi/` | the author's own TN20K-HDMI project, snapshot at `388b39e` | MIT |
| React | bundled in the web page | Meta Platforms, Inc. | MIT; the published page carries `LICENSES.md` |
| Apple //e ROMs (system, character, Disk II boot, Super Serial Card) | `roms/`, not distributed | Apple Computer, Inc. | copyright; supply your own (see [`roms/README.md`](roms/README.md)) |

Built with Gowin EDA, simulated with Icarus Verilog, and the web page with Vite and TypeScript; none of them is part of this repository.

## License

The version is in [`VERSION`](VERSION).

[MIT](LICENSE) © 2026 Terence Ang / motionfxdesign.

The HDMI transmitter in `src/hdmi/` is a local copy of the one from the TN20K-HDMI project, taken at commit `388b39e`; it differs in `hdmi_tx`'s `RGB_QUANT` parameter and in having no packet FIFO (`scripts/hdmi_diff.ps1` lists both). The 65C02 core in `src/cpu/` is by Arlet Ottens, David Banks and Ed Spittles, and stays under its original permissive terms (see the file headers). The DDR3 controller in `src/ddr3_memory_interface/` is Gowin's generated IP netlist, taken from Sipeed's BSD-3-Clause TangPrimer-20K-example (see its README). Apple //e ROMs are copyright Apple and are not part of this project.
