# Apple //e on Tang Nano 20K

An Apple //e implemented in Verilog for the [Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html) (Gowin GW2AR-18). It is built entirely with the open-source Yosys / nextpnr / Apicula toolchain.

## Features

- **65C02 CPU** at 1.023 MHz (Arlet Ottens' core with 65C02 extensions)
- **64 KB RAM** in block RAM, with a **language card** for $D000–$FFFF bank switching
- **HDMI video** at 720×480p60 (CEA-861 VIC 2), with the 560×384 Apple display centered; text, lo-res and hi-res (HGR) modes, including mixed mode and page 2; hi-res colour is an NTSC-style decode of the dot stream, so solid fills, edge fringes and the blue/orange palette bit look as they do on a TV
- **Audio** from the $C030 speaker toggle, sent both over HDMI (48 kHz L-PCM in data islands) and through the onboard MAX98357A I2S amplifier
- **UART keyboard** at 115200 baud over the USB-C serial bridge (or a Bluetooth-to-UART module); ANSI arrow keys are mapped to Apple control codes, and a three-byte key packet lets the Open-Apple and Solid-Apple keys drive the game paddles. There is a [browser front end](web/README.md) — keyboard, screen and debugger — in `web/`
- **Gamepad over UART**: pushbuttons $C061–$C063 and paddles 0/1
- **Built-in hardware debugger**: press Ctrl+B to freeze the CPU and inspect registers, single-step, or dump memory
- **Diagnostic LEDs**: heartbeat, PLL lock, reset, CPU write, text mode, key strobe

Auxiliary 64 KB (in the board's on-board SDRAM, via the GPL-3 controller in `src/sdram/`) and 80-column text are implemented; double hi-res and MouseText (ALTCHARSET) are too, as is the //e's peripheral slot bus (address decode, $C800 expansion space, IRQ/NMI wiring) with no cards in it; not yet: peripheral cards themselves, disk drives, and interrupts. The browser front end shows the text screen only, not hi-res.

## Web front end

`web/` is a React app that puts the //e's keyboard, its text screen and its
hardware debugger in the browser, over the same USB serial link. With the board
plugged into the machine running the browser it needs **nothing installed**:
Web Serial opens the port, and the app is just a static bundle. Chrome or Edge,
served over https or localhost.

```sh
cd web && npm install && npm run build
python3 -m http.server -d web/dist 8000   # http://localhost:8000
```

To publish it: `cd web && npm run pages`, which builds without the Apple
character ROM, checks that it really is not in there, and copies the result to
`docs/`, which is the site's root. Commit that and set **Settings &rarr;
Pages** to serve `/docs` from `main`; the site will be at
`https://terenceang.github.io/Apple_TN20K/`.

`docs/` is entirely published, so nothing that should not be public goes there
— the board documentation lives in `Documents/`.

The app talks to the board over Web Serial directly, so it needs a
Chromium-based browser and the board plugged into the machine it runs on.

The screen is drawn from the same 2732 video ROM the FPGA reads, so it needs the
ROM supplied first — see [`web/README.md`](web/README.md).

## Requirements

- Tang Nano 20K board
- [Yosys](https://github.com/YosysHQ/yosys), [nextpnr-gowin](https://github.com/YosysHQ/nextpnr), [Apicula](https://github.com/YosysHQ/apicula) (`gowin_pack`)
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
- [GNU make](https://www.gnu.org/software/make/) and Windows PowerShell 5.1, for the commands below. `make` is only the documented entry point — the build itself does not need it, since `scripts/build.ps1` and the OpenFPGA Deck both call the toolchain directly — but it is what every command here is spelled with. On Windows, GnuWin32 Make is enough: `winget install GnuWin32.Make`.
- Apple //e ROM images. **These are not included**; see [`roms/README.md`](roms/README.md)

## Building

```sh
make            # synthesize, place & route, pack => build/bitstream/Apple_TN20K.fs
make synth      # yosys only (build/yosys/top.json)
make pnr        # place & route only (build/pnr/top.pnr.json)
make flash-sram # load into SRAM (lost on power cycle)
make flash      # write to onboard flash (persistent)
make clean
```

`make` is a thin wrapper around `scripts/build.ps1`, which is the single build implementation, so the Makefile and the **OpenFPGA Deck** extension produce the same netlist at the same paths. The RTL file list lives in `fpga.yaml`; add new source files there. `scripts/build.ps1` fails the build if the achieved Fmax falls below the 27 MHz target, and `constraints/top.sdc` is available for a stricter two-domain timing analysis.

The Makefile sets `SHELL := cmd.exe`: its recipes are cmd.exe commands, and GNU make otherwise switches to POSIX `sh` if an `sh.exe` is on `PATH` (Git Bash or MSYS2 would add one), which breaks `make clean`. Place and route is allowed to warn, so read the nextpnr report after making changes.

To keep the HDMI core honest, `scripts/hdmi_diff.ps1 -Check` verifies `src/hdmi/` still matches its recorded snapshot, and `-Upstream` reports what has changed in the TN20K-HDMI project since.

```sh
powershell -File sim\run.ps1    # run all testbenches with iverilog (~80 s; tb_top needs the ROMs)
```

If building with the **OpenFPGA Deck** extension in VS Code or `scripts/build.ps1` (which writes to `build\bitstream\Apple_TN20K.fs`), use the programming script:

```powershell
scripts\prog.ps1           # load Deck bitstream into SRAM (volatile)
scripts\prog.ps1 -Flash    # write Deck bitstream to onboard flash (persistent)
```

You can also run the stages separately with `make synth` and `make pnr`. Timing failures are allowed in place & route, so check the nextpnr report after making changes.

```sh
sim/run.ps1      # run all testbenches with iverilog (~1 min; tb_top needs the ROMs)
```

HDMI audio needs a display that accepts HDMI audio (not a DVI-only input). Hold **S1** to switch the output to color bars and a 1 kHz tone, to check the HDMI link independently of the Apple core.

## Using it

1. Connect HDMI and USB-C, then flash the bitstream.
2. Open a serial terminal on the board's UART at **115200 8N1**, for example `picocom -b 115200 /dev/ttyUSB1`.
3. Type to send keystrokes to the Apple //e. Text the machine prints through COUT is echoed back to the terminal.

### Debugger

Press **Ctrl+B** to pause the CPU and enter the debugger. Press it again to leave.

| Key | Action                                         |
|-----|------------------------------------------------|
| `r` | Show CPU registers (PC, A, X, Y, SP, P, opcode) |
| `s` | Single-step one instruction                    |
| `c` | Continue execution (also `g`)                  |
| `m` | Dump 16 bytes of memory                        |
| `4` | Point the dump at $0400 (also `0 1 8 f v`)     |
| `t` | Show hardware status (video mode, PLL lock)    |
| `w` | Dump the text page, and the graphics page in mixed mode |
| `h` | Help (also `?`)                                |
| `x` | Reset the CPU and show the registers           |

Commands are only read when the debugger is idle, so anything sent before the
previous command has finished printing is dropped. The banner prints two
prompts; neither one alone means it is ready. `web/` waits for 200 ms of
silence instead, which is why its buttons are reliable.

### Gamepad protocol

The gamepad sends a 5-byte packet on the same UART: `FF 01 <buttons> <x> <y>`. Bits 0–2 of `<buttons>` map to PB0–PB2. `<x>` and `<y>` are paddle positions from 0 to 255.

### LEDs

| LED | Meaning                  |
|-----|--------------------------|
| 0   | Heartbeat                |
| 1   | PLL locked               |
| 2   | Running (out of reset)   |
| 3   | CPU memory write         |
| 4   | Text mode                |
| 5   | Keyboard strobe pending  |

## Video Programming to HDMI AV

The Apple //e display pipeline is interfaced to the HDMI transmitter (`hdmi_tx`) in `src/hdmi/`, outputting standard CEA-861 720×480p @ 59.94 Hz (VIC 2) with embedded 48 kHz stereo audio.

### Video Architecture & Centering

The authentic Apple II display is 560×384 pixels, derived from 40 character columns (14 pixel clocks per column) and 192 Apple scanlines doubled to 384 lines. This active display is centered inside the standard 720×480 HDMI frame:

- **Horizontal**: Active visible area from $X = 80 \dots 639$ (560 pixels wide). Columns $0 \dots 79$ and $640 \dots 719$ form the left and right borders (black).
- **Vertical**: Active visible area from $Y = 48 \dots 431$ (384 lines high). Lines $0 \dots 47$ and $432 \dots 479$ form the top and bottom borders (black).
- **VBL Flag**: Line $Y \ge 432$ asserts Apple II vertical blanking status ($C019 bit 7).

### Interfacing & 1-Clock Lookahead Pipelining

`hdmi_tx` drives the master raster counters `pixel_x` ($0 \dots 719$) and `pixel_y` ($0 \dots 479$), requesting the 24-bit `{R, G, B}` pixel value combinationally on the same clock cycle.

Because [`video_generator.v`](src/video_generator.v) registers its output colors (`red`, `green`, `blue`) to achieve high Fmax, [`top.v`](src/top.v) supplies the **lookahead position** of the next pixel:
- `h_cnt = pixel_x + 10'd1`
- `v_cnt = pixel_y`

The color computed during cycle $N$ for `h_cnt` appears at the registered output on cycle $N+1$, exactly aligned with `hdmi_tx`'s raster.

```verilog
video_generator u_video (
    .clk_pixel  (clk_pixel),
    .reset      (sys_reset),
    .flash_clk  (flash_clk),
    .h_cnt      (pixel_x + 10'd1),  // 1-pixel lookahead for registered RGB
    .v_cnt      (pixel_y),
    .text_mode  (text_mode),
    .mixed_mode (mixed_mode),
    .page2      (page2),
    .hires_mode (hires_mode),
    ...
    .red        (vid_red),
    .green      (vid_green),
    .blue       (vid_blue),
    .vbl        (vbl)
);
```

### Memory & Prefetch Pipeline

Each Apple II character column occupies 14 pixel clock cycles ($27\text{ MHz} / 14 \approx 1.928\text{ MHz}$):
1. **Cycle 9**: `vram_req` asserts; `vram_addr` is presented using Apple II interleaved memory offsets ($0400–$07FF or Page 2 $0800–$0BFF).
2. **Cycle 10**: VRAM serves the address.
3. **Cycle 11**: Latch `vram_data` into `char_code`.
4. **Cycle 12**: `char_rom_addr` presented to Character ROM based on ASCII code and `glyph_row` (with flash blink support).
5. **Cycle 13**: Latch `char_rom_data` into `glyph_byte` and `char_code_display`.
6. **Cycles 0–13**: Seven dot pairs (2 pixel clocks per dot) are sequentially rendered for text, mapped to the 16-color Lo-Res palette, or, in hi-res, decoded to colour (below).

### Hi-Res (HGR)

With `hires_mode` set (and the line not one of the mixed-mode text rows), the same prefetch fetches the HGR byte instead of a character code. `vram_addr` uses the hi-res interleave: page 1 at `$2000` or page 2 at `$4000`, eight lines `$400` apart, then the same 128-byte row groups and 40-byte group offset as text. The character ROM lookup is unused for these lines.

One HGR byte is 7 dots, and each dot is 2 pixels of the 560-pixel raster, so a byte fills exactly one 14-pixel slot. Bit 7 is the palette/delay bit: a set bit shifts that byte's pixels right by one pixel, which is the half-dot delay of the real hardware.

Colour comes from decoding the 560-sample dot stream the way an NTSC set does. One colour-subcarrier cycle is 4 samples, so each pixel looks at the window `s[n-2..n+1]`: luma is the number of lit samples, and chroma is `I = s@phase0 - s@phase2`, `Q = s@phase1 - s@phase3` with the phase of sample `m` being `m mod 4`. The window's look-ahead sample is the next byte, already latched at cycle 12. The channel weights are `R = 64Y + 80I`, `G = 64Y - 41I - 20Q`, `B = 64Y + 101Q` (clamped), which give violet `D043E5`, green `30BD1B`, blue `3095E5`, orange `D06B1B` and white for `1100`, `0011`, their delayed forms and `1111`. A `0101` dot pattern therefore fills solid, and colour edges fringe, as on a TV. This costs no block RAM.

Mixed mode keeps the bottom four lines on the text page. Hi-res was checked on the board with page 1 mixed, page 1 full-screen, page 2, and lo-res and text as regressions; `sim/tb_video_hdmi.v` checks a whole page-2 mixed frame pixel by pixel against an independent model.

### Full-Range RGB Quantization

CEA-861 video modes (such as 720×480p) default to limited-range RGB ($16 \dots 235$), which would cause monitors and TVs to crush blacks and clip whites for Apple II colors. To ensure accurate color reproduction, `hdmi_tx` is instantiated with:

```verilog
hdmi_tx #(
    .RGB_QUANT(2'b10)  // Full-range RGB (0..255)
) u_hdmi ( ... );
```

This sets the Q1..Q0 flags in the AVI InfoFrame to Full Range, instructing the HDMI sink to accept $0 \dots 255$ levels without contrast compression.

### HDMI Audio Integration & Clock Regeneration

- **PCM Audio Stream**: Sound generated by the $C030 speaker toggle is captured by [`sound_generator.v`](src/sound_generator.v) as 16-bit signed PCM.
- **Sample Rate Conversion**: A fractional accumulator resamples the audio from 46.875 kHz to 48.000 kHz (`VM_AUDIO_HZ = 48000`). Since $27\text{ MHz} / 48\text{ kHz} = 562.5$ clock cycles, the accumulator alternates sample intervals between 562 and 563 clock cycles.
- **Data Islands**: `hdmi_tx` buffers the samples and transmits them as Audio Sample Packets (Layout 0, stereo) along with Audio Clock Regeneration (ACR) packets ($N = 6144, \text{CTS} = 27000$) during horizontal blanking.

### Hardware Bring-Up & Test Pattern (Button S1)

To isolate the HDMI physical link and serializer chain from the Apple core logic during testing:
- Hold button **S1** to bypass the Apple framebuffer and switch the HDMI video and audio to [`colorbar_gen.v`](src/colorbar_gen.v) (SMPTE 8-color bars with a 1px border and blinking liveness indicator) accompanied by a 1 kHz test tone.
- If the test pattern renders cleanly, the PLL, clock divider, TMDS encoders, OSER10 serializers, and TLVDS output buffers are verified.

## Project layout

```
src/top.v               top level: wires everything together, LEDs, reset
src/apple2_core.v       CPU, address decode, softswitches, language card
src/apple2_mem.v        RAM and ROM block-RAM modules
src/clk_gen.v           PLL (135 MHz TMDS) and 1 MHz / 14 MHz clock enables
src/video_generator.v   Apple II raster into the 720x480 frame
src/colorbar_gen.v      HDMI bring-up color bars (hold S1)
src/hdmi/               HDMI transmitter: timing, TMDS, data islands, audio/InfoFrame packets
sim/                    iverilog testbenches (sim/run.ps1)
src/sound_generator.v   speaker to I2S
src/input_controller.v  UART RX, keyboard, gamepad, $C0xx input registers
src/serial_debugger.v   UART TX, console mirror, hardware debugger, screen dump
src/cpu/                65C02 core
constraints/top.cst     pin assignments
roms/                   ROM images (supply your own)
scripts/                build, programming, verification and snapshot scripts
web/                    React keyboard, screen and debugger (see web/README.md)
```

## License

[MIT](LICENSE) © 2026 Terence Ang.

The HDMI transmitter in `src/hdmi/` is a local copy of the one from the TN20K-HDMI project, taken at commit `388b39e` and differing only in `hdmi_tx`'s `RGB_QUANT` parameter. `scripts/hdmi_snapshot.sha256` records the snapshot and `scripts/hdmi_diff.ps1 -Check` fails if it is edited locally without being re-baselined; `-Upstream` reports what has changed in the other project since. The 65C02 core in `src/cpu/` is by Arlet Ottens, David Banks and Ed Spittles, and stays under its original permissive terms (see the file headers). Apple //e ROMs are copyright Apple and are not part of this project.
