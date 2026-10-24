# Apple //e on Tang Primer 20K

A complete, cycle-accurate implementation of the **Apple //e Enhanced** computer in Verilog for the [Sipeed Tang Primer 20K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/primer-20k.html) (Gowin GW2A-LV18PG256C8/I7) on its Dock board.

The design runs as a self-contained system with digital video and audio over HDMI, stereo analog headphone audio, dual Disk II floppy drives, a ProDOS SmartPort hard disk, CP/M support, modem communications, and a browser-based Web Serial companion interface.

---

## Features

### System Core & Memory
* **65C02 CPU** clocked at an exact, cycle-accurate **1.0227 MHz** (5/132 of the 27 MHz master crystal).
* **128 KB Total RAM**: 48 KB Main RAM and 16 KB System ROM implemented in on-chip Block SRAM; 64 KB Auxiliary RAM (80-column / double hi-res) and Language Card banks ($D000–$FFFF) served from high-speed DDR3.
* **Apple //e MMU & Softswitches**: Complete banking and memory decoding for `80STORE`, `RAMRD`, `RAMWRT`, `ALTZP`, and Language Card read/write controls.

### Display & Video
* **HDMI 720×480p60 Output** (CEA-861 VIC 2) with the active 560×384 Apple raster centered.
* **Authentic NTSC Color Decoding**: Dot-stream composite artifact decoding reproduces natural color fills, fringe transitions, and the hi-res palette bit without artificial lookup tables.
* **All Video Modes Supported**:
  * 40-Column & 80-Column Text (with MouseText and alternate character set support)
  * Standard Lo-Res & Hi-Res Graphics
  * Double Hi-Res Graphics (560×192, 16 colors)
  * Mixed Graphics/Text and Page 1 / Page 2 flipping
* **Color TV Filter (DIP 1)**: Hardware multi-tap filter softens edge transitions and blends color fringes just like a composite CRT.
* **CRT Scanlines (DIP 2 & 3)**: Selectable line darkening (Off, 25%, 50%, 75%) applied across scanlines.
* **Full-Range RGB**: Declares full-range color (0–255) in the AVI InfoFrame so modern TVs and monitors do not crush deep blacks.

### Sound Subsystem
* **Speaker**: Standard 1-bit toggle speaker at `$C030`.
* **Mockingboard C (Slot 4)**: Dual 6522 VIAs driving two AY-3-8910 programmable sound generators (6 audio channels) for rich stereo game music and sound effects.
* **Clean 48 kHz Digital Pipeline**: Piecewise second-order CIC integrator and 47-tap halfband FIR decimator ensure crystal-clear audio with zero aliasing artifacts from high AY frequencies.
* **Simultaneous Audio Outputs**: Stereo audio streams over both **HDMI audio data islands** and the Dock's **3.5 mm jack** via the onboard PT8211 16-bit DAC.

### Storage & Expansion Slots
* **Slot 6 — Dual Disk II Controller**:
  * Reads and writes authentic [WOZ 2](https://applesaucefdc.com/woz/reference2/) bitstream images byte-for-byte from the TF card.
  * Cycle-synced sequencer controller with an MC3470 read amplifier model handles 13-sector disks, standard 16-sector disks, quarter-tracks, and copy-protected originals.
  * Modified floppy sectors are automatically synced back to the TF card image ~1 second after drive activity ceases.
* **Slot 7 — ProDOS Block Device & SmartPort**:
  * Provides two 32 MB hard disk volumes (`.hdv` or `.po` raw block format) streaming on demand from the TF card.
  * Answers as both a ProDOS block driver and an Apple SmartPort device.
* **Slot 5 — Real-Time Clock**:
  * Thunderclock-compatible hardware clock; files saved under ProDOS receive live timestamps.
* **Slot 2 — Microsoft Z-80 SoftCard**:
  * Hardware Z80 CPU running at 2.045 MHz for running CP/M 2.2 and CP/M applications.
* **Slot 1 — Super Serial Card (SSC)**:
  * Full 6551 ACIA-compatible serial interface connected to the host USB link; supports virtual Hayes modem emulation via the web interface.

### Web Interface & Control
* **Web Serial Console**: Connect directly via Chrome or Edge at 1,000,000 baud 8N1 — no background daemons, drivers, or software installs required.
* **Virtual Keyboard & Gamepad**: Accurate Apple //e keyboard mapping, paddle button controls, and analog joystick emulation.
* **Disk Manager**: Live mounting, blank disk creation, and on-the-fly conversion of `.dsk`, `.do`, `.po`, and `.nib` images to `.woz`.
* **Hardware Debugger**: Built-in serial debugger allows freezing the CPU at any instant to inspect registers, single-step instructions, examine RAM, and dump the text display.

---

## Hardware Controls & Indicators

### Dock Switches & Buttons

| Control | Function | Description |
|---|---|---|
| **Button S0 (Key 1)** | System Reset | Resets the Apple //e and reloads card configuration. |
| **Button S1 (Key 2)** | HDMI Test Pattern | Overrides display with SMPTE color bars and 1 kHz tone (bypasses core for display diagnostics). |
| **DIP Switch 1** | Color TV Mode | **ON**: Blends composite fringes and softens edges. **OFF**: Sharp RGB pixel rendering. |
| **DIP Switch 2 & 3** | Scanline Intensity | Sets scanline darkening: `00` = Off, `01` = 25%, `10` = 50%, `11` = 75%. |

### Status LEDs

| LED | Indicator | Meaning |
|---|---|---|
| **LED 0** | Heartbeat | Toggles every 16 frames (~1.9 Hz) driven by vertical blanking. |
| **LED 1** | Hardware Ready | Illuminates solid when PLLs are locked and DDR3 is calibrated. |
| **LED 2** | Running | Active when CPU is out of reset. |
| **LED 3** | Memory Write | Pulses during CPU write cycles. |
| **LED 4** | Text Mode | Active when the display is in 40- or 80-column text mode. |
| **LED 5** | Keyboard Strobe | Illuminates when an unread keystroke is waiting in `$C000`. |

---

## Keyboard Shortcuts & Control Sequences

| Shortcut / Sequence | Target | Action |
|---|---|---|
| `Ctrl` + `Reset` | Apple //e | Standard **Warm Restart** (preserves memory / soft switches). |
| `Ctrl` + `Open-Apple` + `Reset` | Apple //e | Full **Cold Boot** (re-initializes memory and boots drives). |
| `Ctrl` + `Open-Apple` + `Closed-Apple` + `Reset` | Apple //e | Enters **ROM Diagnostic Self-Test** (see quirks below). |
| `Ctrl` + `B` | Serial Link | Toggles the **Hardware Debugger** (freezes/unfreezes CPU). |
| `Esc` then `4` | 80-Column Firmware | Switches active display to 40-column text. |
| `Esc` then `8` | 80-Column Firmware | Switches active display to 80-column text. |
| `PR#6` | Applesoft BASIC | Re-executes the Slot 6 Disk II bootloader. |
| `PR#7` | Applesoft BASIC | Re-executes the Slot 7 ProDOS hard drive bootloader. |
| `PR#1` | Applesoft BASIC | Initializes the Slot 1 Super Serial Card. |

---

## System Quirks & Operational Behaviors

1. **Hardware Reset Gating (Requires `Ctrl`)**:
   On authentic Apple //e hardware, the keyboard RESET line is electrically gated by the CONTROL key. Pressing `Reset` alone has no effect; `Ctrl` must be depressed simultaneously.
2. **Boot Order (Slot 7 over Slot 6)**:
   The Apple //e Autostart ROM scans expansion slots in descending order (Slot 7 down to 1). If a valid hard disk volume is mounted on Slot 7 Drive 1, the system will boot from the hard disk rather than the floppy drive. To boot a floppy disk in Slot 6 when a hard disk is attached, type `PR#6` at the `]` prompt. If no disks are attached, the machine drops to Applesoft BASIC.
3. **Triggering the ROM Self-Test vs. Disk Boot**:
   When entering the built-in diagnostic test (`Ctrl + Open-Apple + Closed-Apple + Reset`), the CPU samples the Apple modifier keys *immediately after reset release*. Release `Reset` first while keeping `Open-Apple` and `Closed-Apple` depressed. If both Apple keys are held, the ROM enters diagnostics; if both keys are released concurrently with Reset, the machine will boot disk volumes as normal.
4. **Automated Burn-In / Soak Test**:
   The built-in self-test includes a continuous burn-in mode. As long as both `Open-Apple` and `Closed-Apple` remain held, the diagnostic routines loop indefinitely (completing one rigorous RAM/ROM/MMU pass every ~10.5 seconds). Releasing the keys allows the final pass to conclude with `System OK`.
5. **TF Card Requirements**:
   * Must be formatted as **FAT32** (32 GB or smaller recommended).
   * Disk images must be stored contiguously in the root directory.
   * `A2CONFIG.TXT` in the card root specifies drive mappings using 8.3 filenames (e.g., `S6D1=DOS33.WOZ`, `S7D1=TOTAL.HDV`).
6. **Debugger Freeze Mode**:
   Pressing `Ctrl+B` pauses CPU clocking entirely. Video display refresh and audio clocks continue running normally, allowing inspection of video memory and registers without racing against software loops.

---

## Hardware Debugger Commands

When paused in debugger mode (`Ctrl+B` or via serial):

| Command | Action | Description |
|---|---|---|
| `r` | Registers | Dumps `PC`, `A`, `X`, `Y`, `SP`, `P` flags, and next instruction opcode. |
| `s` | Step | Single-steps the 65C02 by one instruction. |
| `c` | Continue | Resumes normal CPU execution and returns to console mode. |
| `m` | Memory Dump | Dumps 16 bytes of memory (subsequent `m` commands page forward). |
| `@hhhh` | Set Address | Sets the active memory dump pointer (e.g. `@0400` or `@c0f0`). |
| `0`, `1`, `4`, `8`, `f`, `v` | Quick Address | Jump presets for `$0000`, `$0100`, `$0400`, `$0800`, `$FA60`, and `$FFF0`. |
| `w` | Screen Dump | Captures the entire 1 KB text display page ($0400–$07FF). |
| `t` | Diagnostic Status | Displays video mode (`VID:T`/`VID:G`), PLL lock status, and DDR3 calibration. |
| `i` | Drive Info | Displays Disk II head track (`H:hh`) and TF card status word (`S:ssss`). |
| `y1`–`y4` | Reload Drive | Hot-reloads drive image 1–4 from `A2CONFIG.TXT` on the TF card. |
| `x` | CPU Reset | Triggers a hardware reset of the CPU while retaining the debugger pause. |

---

## Quick Start & Usage

### 1. Requirements
* [Sipeed Tang Primer 20K](https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/primer-20k.html) with Dock baseboard.
* MicroSD (TF) card formatted as **FAT32**.
* Gowin EDA 1.9.12.04 (for bitstream generation).
* Apple //e ROM files (see [`roms/README.md`](roms/README.md)).

### 2. Building the Bitstream
```powershell
# Synthesize, place & route, and generate bitstream:
make

# Fast load directly into SRAM (volatile):
make flash-sram

# Program into external SPI flash (persistent across power-cycles):
make flash
```

### 3. Web Companion Interface
Launch the zero-install web interface:
```bash
cd web
npm install
npm run build
python3 -m http.server -d dist 8000
```
Open Chrome or Edge to `http://localhost:8000`, click **Connect USB**, and select the Dock's serial port.

---

## Project Structure

```
src/top.v               Top-level integration, clocks, HDMI serializers, DDR3 & TF wiring
src/apple2_core.v       65C02 CPU integration, bus multiplexing, softswitches, language card
src/apple2_mem.v        BSRAM memory buffers for main 48 KB RAM and 16 KB system ROM
src/aux_ram.v           Auxiliary 64 KB RAM, language card, Disk II & hard-disk buffer in DDR3
src/video_generator.v   Apple display generator and CEA-861 720x480 raster alignment
src/hdmi/               HDMI transmitter: TMDS encoders, data islands, audio/AVI InfoFrames
src/sound_generator.v   Speaker logic and Mockingboard audio mixing to the PT8211 DAC
src/audio_filter.v      48 kHz resampler (CIC in DSP blocks, 47-tap halfband FIR filter)
src/mockingboard/       Mockingboard C implementation (dual 6522 VIAs + dual AY-3-8910 PSGs)
src/disk2/              Disk II controller, sequencer, and WOZ2 bitstream replay engine
src/prodos_hd.v         ProDOS block device and Apple SmartPort hard drive controller
src/prodos_hd_rom.s     SmartPort firmware assembly source
src/thunderclock.v      Thunderclock-compatible real-time clock card (Slot 5)
src/softcard.v          Microsoft Z-80 SoftCard implementation (Slot 2)
src/ssc.v               Super Serial Card with virtual modem pipeline (Slot 1)
src/sd_vol.v            FAT32 TF card interface, block caching, and auto write-back
src/input_controller.v  1 Mbps serial RX, keyboard latch, gamepad & paddle decoding
src/serial_debugger.v   1 Mbps serial TX, console mirror, and hardware debugger
src/cpu/                65C02 processor core
constraints/top.cst     Tang Primer 20K Dock pin assignments
web/                    Browser front-end (React, TypeScript, Web Serial)
scripts/                Build, programming, and diagnostic utility scripts
```

---

## Credits & Third-Party Components

* **6502 / 65C02 Processor Core**: Arlet Ottens ([verilog-6502](https://github.com/Arlet/verilog-6502)) with 65C02 extensions by David Banks and Ed Spittles ([hoglet67/verilog-6502](https://github.com/hoglet67/verilog-6502)).
* **Z80 Processor Core**: Guy Hutchison ([hutch31/tv80](https://github.com/hutch31/tv80)), based on Daniel Wallner's original T80.
* **DDR3 Memory Controller IP**: Gowin Semiconductor / Sipeed BSD-3-Clause TangPrimer-20K-example.
* **HDMI Transmitter Core**: Based on the TN20K-HDMI project (MIT License).
* **Apple //e System Firmware & ROMs**: © Apple Computer, Inc. (ROM files are not included in this repository; users must provide their own dumps per legal guidelines).

---

## License

[MIT](LICENSE) © 2026 Terence Ang
