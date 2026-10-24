# Mockingboard "C" Sound Card Implementation & Verification Plan
**Target Platform:** Apple //e on Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7)  
**Slot Assignment:** Slot 4 ($C400–$C4FF, $C0C0–$C0CF, `/IRQ`)  
**Design Constraint:** **Zero BRAM (0 BSRAM blocks)**; 100% logic and flip-flop implementation.

---

## 1. Overview & Objectives

The goal is to implement a cycle-accurate, hardware-compatible **Mockingboard "C"** stereo sound card for the Tang Primer 20K Apple //e FPGA core. 

### Key Specifications
- **Dual 6522 VIAs (Versatile Interface Adapters)**:
  - Generates periodic 65C02 `/IRQ` interrupts via Timer 1 for background music sequencing.
  - Controls parallel data bus and control strobes (`BC1`, `BDIR`) to the sound generators.
- **Dual AY-3-8910 / AY-3-8913 PSGs (Programmable Sound Generators)**:
  - 6 independent audio voices (3 voices per chip: Tone A/B/C, Noise, Envelope).
  - True stereo audio: Chip 1 drives Left audio, Chip 2 drives Right audio.
  - Logarithmic non-linear volume D/A conversion curve matching original General Instrument silicon.
- **Audio Output Integration**:
  - Stereo output routed to the onboard **PT8211 16-bit DAC** (3.5 mm jack) and **HDMI TMDS digital audio packets**.
  - Hardware mixing with the native 1-bit Apple //e click speaker ($C030).
- **Resource Budget**:
  - BSRAM: **0 blocks** (The GW2A-18 is at 100% BSRAM utilization; Mockingboard requires no Block RAM).
  - Logic: Estimated **1,100 – 1,400 LUTs** (~11–14% of the ~10,250 free LUTs).
  - Registers: Estimated **400 – 500 FFs** (< 5% of free flip-flops).

---

## 2. Hardware Architecture & Slot 4 Memory Map

### 2.1 Apple //e Slot 4 Address Decoding
The Mockingboard resides in **Slot 4** and decodes accesses via `src/slot_bus.v`:

| Address Range | Size | Function / Chip |
| :--- | :---: | :--- |
| **$C400 – $C40F** | 16 B | VIA 1 Registers (controls Left PSG 1) |
| **$C480 – $C48F** | 16 B | VIA 2 Registers (controls Right PSG 2) |
| **$C0C0 – $C0C7** | 8 B | Alternate I/O mirror for VIA 1 |
| **$C0C8 – $C0CF** | 8 B | Alternate I/O mirror for VIA 2 |

### 2.2 6522 VIA Register Mapping
Each 6522 VIA implements 16 standard registers:

| Offset | Register Name | Mockingboard Hardware Function |
| :---: | :--- | :--- |
| `0x0` | **ORB / IRB** | Output/Input Register B. Bits [1:0] drive PSG `BDIR` and `BC1`; bit [2] drives PSG `/RESET`. |
| `0x1` | **ORA / IRA** | Output/Input Register A (handshake). 8-bit bidirectional data bus connected to PSG `DA[7:0]`. |
| `0x2` | **DDRB** | Data Direction Register B (configured as outputs for control lines). |
| `0x3` | **DDRA** | Data Direction Register A (bidirectional data direction for PSG data bus). |
| `0x4` | **T1C_L** | Timer 1 Counter Low (reads current count / writes latch low). |
| `0x5` | **T1C_H** | Timer 1 Counter High (writes high latch and initiates countdown / arms interrupt). |
| `0x6` | **T1L_L** | Timer 1 Latch Low. |
| `0x7` | **T1L_H** | Timer 1 Latch High. |
| `0x8` | **T2C_L** | Timer 2 Counter Low. |
| `0x9` | **T2C_H** | Timer 2 Counter High. |
| `0xA` | **SR** | Shift Register. |
| `0xB` | **ACR** | Auxiliary Control Register (Timer 1 free-running / continuous interrupt mode). |
| `0xC` | **PCR** | Peripheral Control Register (handshake pin modes). |
| `0xD` | **IFR** | Interrupt Flag Register (bit 6 = Timer 1 interrupt, bit 7 = composite IRQ status). |
| `0xE` | **IER** | Interrupt Enable Register (enables/masks Timer 1 and Timer 2 interrupts). |
| `0xF` | **ORA_NH** | Register A without handshake (frequently used by sound drivers). |

### 2.3 AY-3-8910 Bus Control Interface
The VIA communicates with the PSG using the General Instrument 2-bit bus protocol:

| `BDIR` (PB1) | `BC1` (PB0) | Bus State | Action on AY-3-8910 |
| :---: | :---: | :--- | :--- |
| **0** | **0** | `INACTIVE` | Bus floating; PSG retains current state. |
| **0** | **1** | `READ` | PSG outputs contents of selected register onto `DA[7:0]`. |
| **1** | **0** | `WRITE` | PSG stores data on `DA[7:0]` into currently selected register. |
| **1** | **1** | `LATCH_ADDR` | PSG latches value on `DA[3:0]` as the active register address (R0–R15). |

---

## 3. Subsystem Implementation Modules

```
                    +------------------------------------------------+
                    |             apple2_core / slot_bus             |
                    +------------------------------------------------+
                               |                 |          ^
                      Slot 4   |                 | Slot 4   | /IRQ
                    $C400-$C47F|       $C480-$C4FF|          |
                               v                 v          |
                    +------------+     +------------+       |
                    | 6522 VIA 1 |     | 6522 VIA 2 |-------+
                    +------------+     +------------+
                          |                  |
                    Port A|Port B      Port A|Port B
                          v                  v
                    +------------+     +------------+
                    | AY-3-8910  |     | AY-3-8910  |
                    |   PSG 1    |     |   PSG 2    |
                    +------------+     +------------+
                          |                  |
                          v 3 channels       v 3 channels
                     (Left Audio)       (Right Audio)
                          |                  |
                          +--------+---------+
                                   |
                                   v
                    +--------------------------------+
                    |     src/sound_generator.v      |
                    |  (Mix with $C030 click speaker)|
                    +--------------------------------+
                               |            |
                               v            v
                         PT8211 DAC      HDMI Audio
                        (3.5mm Jack)    (Data Island)
```

### Module 1: `src/mockingboard/ay8910.v`
- **Clock**: 1.023 MHz (`ce_1m` enable from Apple II core).
- **Tone Generators**: Three 12-bit down-counters. Counter ticks at $1.023\text{ MHz} / 16 \approx 63.9\text{ kHz}$.
- **Noise Generator**: 17-bit Linear Feedback Shift Register (LFSR) with polynomial $x^{17} + x^3 + 1$. Ticks at $1.023\text{ MHz} / 16 / (\text{Period})$.
- **Envelope Generator**: 16-bit frequency divider feeding a 16-step shape state machine supporting all 8 unique AY-3-8910 envelope shapes (Attack, Decay, Alternate, Hold, Continuous).
- **Volume D/A**: 4-bit non-linear logarithmic lookup table converting 0..15 volume codes into authentic 12-bit / 16-bit linear DAC values.

### Module 2: `src/mockingboard/via6522.v`
- **Clock**: 27 MHz system clock gated with `bus_cycle` and `ce_1m`.
- **Timer 1**:
  - 16-bit counter and 16-bit reload latch.
  - Free-running continuous mode: generates an interrupt and automatically reloads from latch when counter decrements past zero.
- **Timer 2**: 16-bit one-shot down-counter.
- **Interrupt Logic**: `IFR` and `IER` controlling open-drain active-low `/IRQ` output.
- **I/O Ports**: Port A (8-bit data), Port B (8-bit control).

### Module 3: `src/mockingboard/mockingboard_card.v`
- Connects to Apple //e slot signals: `addr[7:0]`, `data_in[7:0]`, `data_out[7:0]`, `we`, `iosel_n`, `devsel_n`.
- Instantiates `via6522_left` and `via6522_right`.
- Instantiates `ay8910_left` and `ay8910_right`.
- Sums 3 left voices into `audio_left[15:0]` and 3 right voices into `audio_right[15:0]`.

### Module 4: Audio Pipeline Update (`src/sound_generator.v`)
- Extends the existing 16-bit PT8211 serializer and HDMI audio island scheduler to accept external `mock_left[15:0]` and `mock_right[15:0]`.
- Implements saturating adder mixing Apple speaker clicks into both channels:
  $$\text{Left}_{\text{out}} = \text{SatAdd}(\text{Mockingboard}_{\text{Left}}, \text{Speaker})$$
  $$\text{Right}_{\text{out}} = \text{SatAdd}(\text{Mockingboard}_{\text{Right}}, \text{Speaker})$$

---

## 4. Verification & Testing Plan

### Phase 1: RTL Unit Simulation (Icarus Verilog + GTKWave)
1. **`sim/tb_ay8910.v`**:
   - Write register test: program Tone A frequency ($440\text{ Hz}$ A4 note), set Volume to 15, verify output square wave period.
   - Verify Noise LFSR randomness and noise frequency control.
   - Verify all envelope generator waveforms (Sawtooth, Triangle, Decaying burst).
2. **`sim/tb_via6522.v`**:
   - Program Timer 1 for a $60\text{ Hz}$ periodic tick.
   - Verify `IFR` bit 6 sets on countdown expiration and `/IRQ` asserts low.
   - Verify reading/writing `T1C_L` clears interrupt flag.
3. **`sim/tb_mockingboard.v`**:
   - Simulate 65C02 bus write sequence to play a 3-chord sequence on Left and Right channels.
   - Verify digital sample output on Left and Right channels.

### Phase 2: Synthesis & Timing Closure (Gowin IDE / gw_sh)
1. Integrate modules into `src/top.v` and `src/apple2_core.v`.
2. Run full place-and-route with Gowin PnR (`scripts/build.ps1`).
3. Verify resource report:
   - BSRAM usage remains **46/46** (0 additional blocks).
   - Logic utilization remains safely under 60% (< 12,000 LUTs).
   - Timing report: confirm no setup or hold violations on 27 MHz or 1.023 MHz domains.

### Phase 3: Hardware Diagnostics over Serial Debugger
1. Write Python test script `scratch/test_mockingboard.py`:
   - Enters serial debugger on `COM47`.
   - Directly probes Slot 4 registers: writes to VIA 1 at `$C400` / `$C401` to configure 440 Hz tone.
   - Listens to 3.5mm audio jack / HDMI audio to verify audible test tone.
   - Checks Timer 1 `/IRQ` latching into 65C02 status register.

### Phase 4: Software & Game Compatibility Testing
Load and execute standard Mockingboard test and game disk images:
1. **Mockingboard Diagnostic Disk (Sweet Micro Systems)**:
   - Automated self-test of VIAs, Timers, and sound channels.
2. **Ultima IV / Ultima V**:
   - Cold boot via Slot 6 Disk II.
   - Verify background polyphonic orchestral music playing in towns, wilderness, and combat.
3. **Music Construction Set**:
   - 6-voice polyphonic playback.
4. **Skyfox**:
   - Dynamic stereo sound effects and theme music.

---

## 5. Execution Timeline & Milestones

| Milestone | Deliverables | Verification Criteria |
| :---: | :--- | :--- |
| **M1: Sound Synthesis** | `ay8910.v` | Unit testbench produces clean $440\text{ Hz}$ tone, noise, and envelope in Icarus simulation. |
| **M2: VIA & Timer Engine** | `via6522.v` | Unit testbench validates register I/O, Timer 1 countdown, and interrupt assertion. |
| **M3: Slot 4 Integration** | `mockingboard_card.v`, `slot_bus.v` | Mockingboard mapped into Slot 4; 0 BSRAM used; timing passes clean in Gowin PnR. |
| **M4: Audio Mixer & DAC** | `sound_generator.v` update | Tone test via Python script outputs clear sound on 3.5 mm jack and HDMI. |
| **M5: Game Verification** | Game disk testing | Ultima IV/V and Mockingboard Diagnostics boot and play 6-channel stereo music. |
