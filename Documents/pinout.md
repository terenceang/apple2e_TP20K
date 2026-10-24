# Tang Primer 20K Dock — FPGA Pinout

FPGA: Gowin **GW2A-LV18PG256C8/I7** on the SOM (rev 3961), plugged into the Dock (rev 3713).
Source: `docs/Schematics/` — Dock root sheet (page 1) block labels `bank/IO/ball`, Dock sub-sheets
for polarity, SOM schematic for bank voltages, config and on-SOM peripherals.

`Ball` is the value for `IO_LOC` in the `.cst`. **Bank** decides the I/O voltage.

**Required build options** (verified with gw_sh 1.9.12.04 — without them place & route fails):

```tcl
set_option -use_sspi_as_gpio 1    ;# T10 (reset/key S1), C10 (DVP_PWDN), T9 (WS2812), N9 (LCD_R2), M8 (SD_D0)
set_option -use_ready_as_gpio 1   ;# A13 (LED1)
set_option -use_done_as_gpio 1    ;# C13 (LED0)
```

B10 (S4 / RECONFIG_N), R9 (LCD_CLK/FASTRD_N) and P9 (MIC_LED_CLK) build without extra options.

## Bank voltages

| Bank | VCCIO | IO_TYPE | Used for |
|---|---|---|---|
| 0, 1 | 3.3 V (R5 0R; optional F_VCCO0&1 from SODIMM) | `LVCMOS33` | HDMI, Ethernet, camera, USB PHY, audio, LEDs 2–5 |
| 2 | 3.3 V | `LVCMOS33` | UART, JTAG, SD card, USB PHY |
| 3 | 3.3 V | `LVCMOS33` | LCD, mic/PMOD, config pins, LED0/1, S0/key 1, S4/RCFG |
| 4 | **1.5 V** (DDR3) | `LVCMOS15` | DDR3, buttons S1–S3, DIP switches 1–5 |
| 5, 6 | 1.5 V (DDR3) | — | DDR3 only |
| 7 | 3.3 V (R9 0R; optional F_VCCO7) | `LVCMOS33` | LCD G/B, Ethernet, touch panel |

Net names ending `_1V5` are on bank 4. Never drive them as LVCMOS33.

## Clock & reset

| Signal | Ball | Bank | Notes |
|---|---|---|---|
| 27 MHz oscillator | **H11** | 0 | SOM U10, `GCLK`-capable |
| FPGA_RST / Key S1 | **T10** | 3 | Active low. Shared: SOM SGM803 reset supervisor (holds low at power-up) + Dock key S1. SSPI pin → `use_sspi_as_gpio` |

## LEDs (active LOW — anode to 3V3 via 510R)

| Signal | Ball | Bank | Notes |
|---|---|---|---|
| Orange_LED0 | **C13** | 3 | = DONE pin → `set_option -use_done_as_gpio 1` |
| Orange_LED1 | **A13** | 3 | = READY pin → `set_option -use_ready_as_gpio 1` |
| Orange_LED2 | **N16** | 1 | |
| Orange_LED3 | **N14** | 1 | |
| Orange_LED4 | **L14** | 1 | |
| Orange_LED5 | **L16** | 1 | |

Silkscreen reference designators are LED4–LED9 (Orange_LED0 = LED4 … Orange_LED5 = LED9).
Not FPGA-controlled: LED1/LED2 (BL702 status), LED3 (USB PHY power), LED10 (5 V power).

## Push buttons & DIP switches

This is the configuration the project is built for, as wired on its board (Dock **Rev 3713**):
button **S4 (silkscreened `RCFG`)** is on **`B10`** (`RECONFIG_N`, reloads the FPGA), and
**DIP 1** is on **`C7`**. Check your own board before relying on it (see the note at the end of
this section).

### Push buttons (active LOW — 10 k pull-up, press = GND)

| Silkscreen | Ball | Bank | Voltage | Function |
|---|---|---|---|---|
| **S0** | **T10** | 3 | 3.3 V | Apple reset (also `FPGA_RST`) |
| **S1** | **T3** | 4 | 1.5 V | HDMI colour-bar test pattern |
| **S2** | **T2** | 4 | 1.5 V | Spare user button |
| **S3** | **D7** | 4 | 1.5 V | Spare user button |
| **S4 / RCFG** | **B10** | 3 | 3.3 V | `RECONFIG_N`: reloads the FPGA (not a user input) |

### DIP switch positions 1–5 (active HIGH — ON = high 1.5 V, OFF = pulled down by 13k to GND)

| Silkscreen | Ball | Bank | Voltage | Project Assignment |
|---|---|---|---|---|
| **DIP 1** | **C7** | 4 | 1.5 V | **Colour TV mode** (`sw_color_tv`, 1 = ON, 0 = OFF) |
| **DIP 2** | **E9** | 4 | 1.5 V | **Scanline mode [1]** (`sw_scanline[1]`) |
| **DIP 3** | **E8** | 4 | 1.5 V | **Scanline mode [0]** (`sw_scanline[0]`) |
| **DIP 4** | **T4** | 4 | 1.5 V | **Monitor mode [0]** (`sw_mon_mode[0]`) |
| **DIP 5** | **T5** | 4 | 1.5 V | **Monitor mode [1]** (`sw_mon_mode[1]`) |

Scanline modes on DIP 2 & 3:
- `00`: Scanlines off
- `01`: 25% scanlines
- `10`: 50% scanlines
- `11`: 75% scanlines

Monitor modes on DIP 4 & 5:
- `00`: Color (uses DIP 1: 0 = Sharp RGB, 1 = Soft Composite TV)
- `01`: Monochrome Green (P31 phosphor, e.g. Apple Monitor // / ///)
- `10`: Monochrome Amber (P134 phosphor, e.g. Apple Monitor //c)
- `11`: Monochrome White (B&W / Paper White, e.g. Apple Composite Mono)

> **Check your board's revision and wiring.** The Dock's revision number does not settle
> which of `B10` / `C7` is the `RCFG` button and which is DIP 1: an early Rev 3713 schematic
> shows DIP 1 on `B10` (`RECONFIG_N`) and a button on `C7`, while this project's Rev 3713 board
> (and Rev 3714+) has the `RCFG` button on `B10` and DIP 1 on `C7`. Before building for another
> board, confirm against its silkscreen and schematic. If DIP 1 is on `B10` there, it must stay
> **ON** at power-up (holding `RECONFIG_N` low stops the FPGA configuring), colour TV mode
> needs another ball, and `C7` is a button.

## UART (via BL702 USB-C debugger, appears as a COM port)

| Signal | Ball | Bank | Direction |
|---|---|---|---|
| FPGA_TX → PC | **M11** | 2 | FPGA output (BL702 UART1_RX) |
| FPGA_RX ← PC | **T13** | 2 | FPGA input (BL702 UART1_TX) |

## JTAG (dedicated — don't reuse)

| Signal | Ball |
|---|---|
| TCK | A7 |
| TMS | B8 |
| TDI | A6 |
| TDO | C6 |

Driven by the onboard BL702; also on SOM connector J1 (JST SH 8-pin: 5V, TMS, TDO, TCK, TDI, RX, TX, GND).
Remove Dock RN2 to use an external JTAG cable.

## HDMI (J3, type A) — TMDS out

| Signal | Ball (P / N) | Bank |
|---|---|---|
| HDMI_TX0 (D0) | **H14 / H16** | 0 |
| HDMI_TX1 (D1) | **J15 / K16** | 0 |
| HDMI_TX2 (D2) | **K14 / K15** | 1 |
| HDMI_TXC (clock) | **G16 / H15** | 0 |
| HDMI_HPD | J11 | 1 |
| HDMI_CEC | L12 | 1 |
| HDMI_SDA (DDC) | F14 | 0 |
| HDMI_SCL (DDC) | F16 | 0 |

Pairs are AC-coupled (100 nF) with 49.9R pull-ups to 3.3 V on the connector side and RCLAMP ESD.
Drive each pair with `TLVDS_OBUF` (true LVDS), `IO_TYPE=LVDS25 PULL_MODE=NONE DRIVE=3.5`, fed by
`OSER10`. In the `.cst` give both balls (`IO_LOC "tmds_clk_p" G16,H15;`). Working example, verified on hardware with picture + audio: `hdmi/`
(720x480p VIC 2 + 48 kHz audio, rPLL 135 MHz + CLKDIV /5). `ELVDS_OBUF` + `LVCMOS33D` also builds on these pins.
DDC SDA/SCL are level-shifted (2N7002) to 5 V. ⚠ F14/F16 are a **shared bus** — see Conflicts.

## Ethernet (RTL8201F 10/100 PHY, RMII, J9 RJ45)

| Signal | Ball | Bank |
|---|---|---|
| RTL_PHY_TXD0 | D16 | 0 |
| RTL_PHY_TXD1 | E14 | 0 |
| RTL_PHY_TXEN | E16 | 0 |
| RTL_PHY_RXD0 | F15 | 0 |
| RTL_PHY_RXD1 | C9 | 7 |
| RTL_PHY_CRS (CRS_DV) | M6 | 3 |
| RTL_PHY_RXER | L8 | 3 |
| RTL_PHY_TXCLK (50 MHz ref) | A9 | 7 |
| RTL_PHY_MDC | F14 | 0 |
| RTL_PHY_MDIO | F16 | 0 |
| RTL_PHY_RST (active low) | F10 | 7 |

PHY has its own 25 MHz crystal. ⚠ MDC/MDIO share F14/F16; RST shares F10 with USB_RESET.

## USB 2.0 PHY (USB3317, ULPI, USB-C J8)

| Signal | Ball | Bank |
|---|---|---|
| USB_DATA0 | G11 | 0 |
| USB_DATA1 | H12 | 0 |
| USB_DATA2 | J12 | 0 |
| USB_DATA3 | H13 | 0 |
| USB_DATA4 | T14 | 2 |
| USB_DATA5 | R13 | 2 |
| USB_DATA6 | P13 | 2 |
| USB_DATA7 | R12 | 2 |
| USB_NXT | K13 | 1 |
| USB_DIR | K12 | 1 |
| USB_STP | K11 | 1 |
| USB_CLKOUT (60 MHz in) | T15 | 2 — RPLL1_T_in (PLL clock input) |
| USB_RESET | F10 | 7 |

This is the **second** USB-C port (not the BL702 debug port). SW2 on the Dock selects host/device ID.

## 40-pin RGB LCD (J7, FPC 0.5 mm) + PMODs J5/J6

| Signal | Ball | Bank | | Signal | Ball | Bank |
|---|---|---|---|---|---|---|
| RGB_LCD_R0 | L9 | 3 | | RGB_LCD_B0 | B12 | 7 |
| RGB_LCD_R1 | N8 | 3 | | RGB_LCD_B1 | C12 | 7 |
| RGB_LCD_R2 | N9 | 3 | | RGB_LCD_B2 | B13 | 7 |
| RGB_LCD_R3 | N7 | 3 | | RGB_LCD_B3 | A14 | 7 |
| RGB_LCD_R4 | N6 | 3 | | RGB_LCD_B4 | B14 | 7 |
| RGB_LCD_G0 | D11 | 7 | | RGB_LCD_CLK | R9 | 3 |
| RGB_LCD_G1 | A11 | 7 | | RGB_LCD_HSYNC | A15 | 7 |
| RGB_LCD_G2 | B11 | 7 | | RGB_LCD_VSYNC | D14 | 1 |
| RGB_LCD_G3 | P7 | 3 | | RGB_LCD_DE | E15 | 1 |
| RGB_LCD_G4 | R7 | 3 | | RGB_LCD_BL (backlight EN) | E10 | 7 |
| RGB_LCD_G5 | D10 | 7 | | | | |

RGB565 (5-6-5). Panel LSBs are tied to GND. R9 is the FASTRD_N config pin (fine as GPIO after config).

**Touch panel (J4, 6-pin)**: TP_SDA F14, TP_SCK F16, TP_INT C11, TP_RST A12.

**PMOD J5** (2×6, pins 1/2 = 3V3, 3/4 = GND):
5 R0 (L9) · 6 R1 (N8) · 7 R2 (N9) · 8 R3 (N7) · 9 R4 (N6) · 10 G0 (D11) · 11 G1 (A11) · 12 G2 (B11)

**PMOD J6** (2×6, pins 1/2 = 3V3, 3/4 = GND):
5 B0 (B12) · 6 B1 (C12) · 7 B2 (B13) · 8 B3 (A14) · 9 B4 (B14) · 10 HSYNC (A15) · 11 VSYNC (D14) · 12 DE (E15)

## DVP camera (J11, FPC 24-pin, OV2640-style) + PMOD J12

| Signal | Ball | Bank | | Signal | Ball | Bank |
|---|---|---|---|---|---|---|
| DVP_D0 | T12 | 2 | | DVP_SCL | F14 | 0 |
| DVP_D1 | T11 | 2 | | DVP_SDA | F16 | 0 |
| DVP_D2 | P11 | 2 | | DVP_PCLK (in) | F13 | 0 |
| DVP_D3 | R11 | 2 | | DVP_XCLK (out) | G12 | 0 |
| DVP_D4 | M15 | 1 | | DVP_RST | L13 | 1 |
| DVP_D5 | M14 | 1 | | DVP_PWDN | C10 | 3 |
| DVP_D6 | J16 | 0 | | DVP_VSYNC (in) | G15 | 0 |
| DVP_D7 | J14 | 0 | | DVP_HSYNC (in) | G14 | 0 |

Camera runs at 2.8 V I/O; SCL/SDA level-shifted by MOSFETs, XCLK by a 74LVC1T45.

**PMOD J12** (2×6, pins 1/2 = 3V3, 3/4 = GND):
5 D7 (J14) · 6 D6 (J16) · 7 D5 (M14) · 8 D4 (M15) · 9 D0 (T12) · 10 D3 (R11) · 11 D1 (T11) · 12 D2 (P11)

## Audio (PT8211 I²S DAC → LPA4809 amp → 3.5 mm jack J10)

| Signal | Ball | Bank |
|---|---|---|
| HP_BCK (bit clock) | N15 | 1 |
| HP_WS (L/R select) | P16 | 1 |
| HP_DIN (data) | P15 | 1 |
| PA_EN (amp enable) | R16 | 1 |

PT8211 is 16-bit, LSB-justified ("Japanese") format, not standard I²S.

## Mic array connector (J15, FPC 10-pin) + WS2812 + PMOD J14

| Signal | Ball | Bank |
|---|---|---|
| MIC_DAT0 | P8 | 3 |
| MIC_DAT1 | T8 | 3 |
| MIC_DAT2 | R8 | 3 |
| MIC_DAT3 | T7 | 3 |
| MIC_WS | P6 | 3 |
| MIC_BCK | T6 | 3 |
| MIC_LED_CLK | P9 | 3 |
| WS2812-DAT (onboard RGB LED U17, also MIC_LED_DAT) | T9 | 3 |

**PMOD J14** (2×6, pins 1/2 = 3V3, 3/4 = GND):
5 MIC_LED_CLK (P9) · 6 MIC_LED_DAT (T9) · 7 DAT1 (T8) · 8 DAT0 (P8) · 9 DAT2 (R8) · 10 DAT3 (T7) · 11 BCK (T6) · 12 WS (P6)

## On the SOM

**microSD (J2, SDIO, 10 k pull-ups, 33R series)**

| Signal | Ball | Bank |
|---|---|---|
| SDIO_CLK | N10 | 2 |
| SDIO_CMD | R14 | 2 |
| SDIO_D0 | M8 | 3 |
| SDIO_D1 | M7 | 3 |
| SDIO_D2 | M10 | 2 |
| SDIO_D3 / CD | N11 | 2 |
| SDIO_DET (card detect) | D15 | 1 |

**SPI LCD connector (J3, FPC 8-pin)**

| Signal | Ball | Bank |
|---|---|---|
| LCD_SCL | F12 | 0 |
| LCD_SDA | L15 | 1 |
| LCD_RS (D/C) | J13 | 1 |
| LCD_CS (active low) | C16 | 1 |
| LCD_RST (active low) | G13 | 0 |
| LCD_BL (active low, P-FET) | P12 | 2 |

**Config SPI flash (U9) — MSPI boot, leave alone unless `use_mspi_as_gpio`**

| Signal | Ball |
|---|---|
| FLASH_CS | M9 |
| FLASH_CLK | L10 |
| FLASH_SI (MOSI) | R10 |
| FLASH_SO (MISO) | P10 |

**Config straps**: MODE0 M16, MODE1 B16, MODE2 C15 — all 4.7 k to GND (= 000, MSPI boot).
RECONFIG_N B10, READY A13, DONE C13 — 4.7 k pull-ups to 3V3.

**DDR3** (H5TQ1G63EFR, 128 MB ×16, banks 4/5/6 at 1.5 V): use the Gowin DDR3 Memory Interface IP;
take ball assignments from Sipeed's DDR3 example `.cst` rather than this table.

## Shared pins / conflicts

| Ball(s) | Shared by | Rule |
|---|---|---|
| F14, F16 | HDMI DDC SDA/SCL, touch SDA/SCK, Ethernet MDC/MDIO, camera SCL/SDA | One user at a time, or treat as one I²C bus (Ethernet MDIO is not I²C) |
| F10 | USB_RESET, RTL_PHY_RST | Resets both PHYs together |
| T10 | Key S1, FPGA_RST supervisor, SSPI | Low during power-up; fine as a reset input; needs `use_sspi_as_gpio` |
| C10, T9, N9, M8 | SSPI config pins | Need `use_sspi_as_gpio` |
| B10 | S4 (`RCFG`) / RECONFIG_N | Pressing it reconfigures the FPGA; check your board's wiring (see Push buttons & DIP switches) |
| A13, C13 | LED1/LED0, READY/DONE | Need `use_ready_as_gpio` / `use_done_as_gpio` |
| R9 | RGB_LCD_CLK, FASTRD_N | OK after config |
| J5/J6 | RGB LCD | PMOD or LCD, not both |
| J12 | DVP D0–D7 | PMOD or camera, not both |
| J14 | Mic array, WS2812 | PMOD or mic; T9 also drives the onboard WS2812 |

## .cst snippet (common I/O)

```
IO_LOC "clk" H11;             IO_PORT "clk" IO_TYPE=LVCMOS33;
IO_LOC "rst_n" T10;           IO_PORT "rst_n" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC "led[0]" C13;          IO_PORT "led[0]" IO_TYPE=LVCMOS33;
IO_LOC "led[1]" A13;          IO_PORT "led[1]" IO_TYPE=LVCMOS33;
IO_LOC "led[2]" N16;          IO_PORT "led[2]" IO_TYPE=LVCMOS33;
IO_LOC "led[3]" N14;          IO_PORT "led[3]" IO_TYPE=LVCMOS33;
IO_LOC "led[4]" L14;          IO_PORT "led[4]" IO_TYPE=LVCMOS33;
IO_LOC "led[5]" L16;          IO_PORT "led[5]" IO_TYPE=LVCMOS33;
IO_LOC "key[0]" T3;           IO_PORT "key[0]" IO_TYPE=LVCMOS15 PULL_MODE=UP;   // S1
IO_LOC "key[1]" T2;           IO_PORT "key[1]" IO_TYPE=LVCMOS15 PULL_MODE=UP;   // S2
IO_LOC "key[2]" D7;           IO_PORT "key[2]" IO_TYPE=LVCMOS15 PULL_MODE=UP;   // S3
IO_LOC "sw_color_tv" C7;      IO_PORT "sw_color_tv" IO_TYPE=LVCMOS15 PULL_MODE=DOWN;     // DIP1
IO_LOC "sw_scanline[0]" E8;   IO_PORT "sw_scanline[0]" IO_TYPE=LVCMOS15 PULL_MODE=DOWN;  // DIP3
IO_LOC "sw_scanline[1]" E9;   IO_PORT "sw_scanline[1]" IO_TYPE=LVCMOS15 PULL_MODE=DOWN;  // DIP2
IO_LOC "uart_tx" M11;         IO_PORT "uart_tx" IO_TYPE=LVCMOS33;
IO_LOC "uart_rx" T13;         IO_PORT "uart_rx" IO_TYPE=LVCMOS33 PULL_MODE=UP;
```
