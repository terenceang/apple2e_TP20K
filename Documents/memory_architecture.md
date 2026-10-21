# Memory Subsystem Architecture: BRAM vs. DDR3

This document details the memory architecture of the Apple //e core ported to the Sipeed Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7), analyzing the design trade-offs between on-chip Block RAM (BSRAM) and external DDR3 SDRAM.

---

## 1. Executive Summary & Hardware Context

The Apple //e is fundamentally a low-speed machine compared to modern FPGA clock rates:
* **CPU Clock Rate:** 1.023 MHz (~977.5 ns per clock cycle).
* **Target FPGA:** Gowin GW2A-18C (20,736 LUTs, 46 BSRAM blocks).
* **Onboard External RAM:** 128 MB (1 Gbit) DDR3 SDRAM (SK Hynix `H5TQ1G63EFR`).

Despite the 65C02's relaxed 1 MHz cycle time, implementing a full 128 KB Apple //e system with floppy disk emulation on this FPGA presents a resource conflict: **the total memory required exceeds the on-chip BRAM capacity, while the DDR3 memory controller itself consumes significant on-chip BRAM and logic.**

To solve this, the design uses a **hybrid memory partitioning scheme**:
* **Time-critical base system** (48 KB main RAM + 16 KB ROM + 4 KB Font + Disk boot ROM) is placed in **on-chip BSRAM**.
* **Expansion memory and bulk storage** (64 KB Aux RAM + 16 KB Language Card + 4 MB Disk II floppy images) is mapped to **external DDR3 SDRAM**.

---

## 2. Trade-Off Comparison: BRAM vs. DDR3

| Attribute | On-Chip BSRAM (Block RAM) | External DDR3 SDRAM |
| :--- | :--- | :--- |
| **Physical Capacity** | **92 KB (46 blocks × 2 KB)** | **128 MB (64M × 16-bit words)** |
| **Access Latency** | **Instant (1 clock cycle)**, 0 wait states | **Variable (10–30 `mclk` cycles)**, CAS + RAS + refresh |
| **Bus Width / Granularity** | Native **8-bit byte** access | **128-bit burst (BL8)** (8 words × 16 bits = 16 bytes) |
| **FPGA Logic Overhead** | **0 logic overhead** (dedicated silicon) | **Heavy**: Eats **8 BSRAMs, ~1,300 LUTs, ~1,300 FFs, 1 rPLL** |
| **Clock Domain** | Synchronous to system domain (27 MHz) | Asynchronous domain crossing (27 MHz ↔ 100 MHz `mclk` ↔ 400 MHz PHY) |
| **Timing Slack with 65C02** | N/A (cycle-accurate synchronous) | **Huge (~97 clocks of slack)**; 6502 cycle is 977 ns vs DDR3's 10 ns clock |
| **Power Consumption** | Negligible dynamic power | Substantial dynamic I/O switching power (~400 MHz SSTL) |
| **Reset Persistence** | Lost on FPGA reconfiguration | Data preserved across warm FPGA resets (if uninitialized) |

---

## 3. Deep-Dive: Pros and Cons

### On-Chip BSRAM

#### Pros:
1. **Cycle-Accurate Determinism:**
   The 65C02 CPU and Apple II video beam generator can read/write memory simultaneously on strict cycle boundaries. There is no bus arbitration jitter or wait-state stalling.
2. **Simple, Transparent RTL:**
   Directly inferred in Verilog (`reg [7:0] mem [0:N-1]`) and easily initialized at synthesis using `$readmemh`.
3. **No External Pin Dependencies:**
   Does not consume high-speed I/O pins, DQS delay lines, or impedance calibration hardware.

#### Cons:
1. **Hard Capacity Ceiling (92 KB Max):**
   A standard Apple //e requires 64 KB Main RAM, 16 KB System ROM, 4 KB Character Font ROM, and 64 KB Auxiliary RAM for 128 KB software compatibility (e.g., AppleWorks, GEOS, 80-column desktop). That total (148 KB) **exceeds the 92 KB limit by 60%**, even before allocating memory for disk drive images.

---

### External DDR3 SDRAM

#### Pros:
1. **CPU Speed Mismatch Works to Our Advantage:**
   Because the 65C02 runs at ~1 MHz, its cycle duration is **977.5 ns**. The DDR3 user interface (`mclk`) runs at **99.58 MHz** (10.04 ns per cycle). This provides roughly **97 clock cycles of slack per CPU cycle**. A typical DDR3 read/write completes in 12–25 controller cycles, so DDR3 easily delivers data before the 6502 samples its data bus.
2. **Massive Storage Capacity (128 MB):**
   * Eliminates the need for real-time SD card SPI reading during floppy access.
   * Both Drive 1 and Drive 2 floppy disks (140 KB each) reside completely in DDR3 RAM.
   * Leaves >120 MB free for future expansion (e.g., ProDOS 32 MB hard drive partitions, RamWorks multi-megabyte cards).
3. **Warm Reset Preservation:**
   Because DDR3 retains data as long as power is applied and the memory controller periodically refreshes it, loaded disk images survive CPU resets (`x` command) and soft reboots.

#### Cons:
1. **High FPGA Resource Cost (The "Tax" of DDR3):**
   The Gowin DDR3 Memory Interface IP is complex. It requires **8 BSRAM blocks** purely for its internal command FIFOs, read/write elastic buffers, and DQS resynchronization logic. This consumes 17.4% of the FPGA's entire BSRAM pool.
2. **Burst Width vs. Byte Granularity:**
   The 6502 reads and writes 1 byte at a time. DDR3 naturally bursts 128 bits (16 bytes) per command (Burst Length 8). Writes require byte data masking (`DM` lines) to avoid overwriting adjacent memory bytes.
3. **Video Beam Contention:**
   The video generation subsystem cannot tolerate latency spikes (row activations or refresh cycles) while outputting active scanlines. To prevent visual snow or tearing, DDR3 cannot be read directly during active pixel drawing.

---

## 4. Current Resource Allocation Breakdown

### BSRAM Allocation (46 / 46 Blocks Used — 100%)

| Module Instance | Source File | Blocks | Memory Size | Purpose |
| :--- | :--- | :---: | :---: | :--- |
| `u_core.u_ram` | `src/apple2_mem.v` | **24** | 48 KB | Apple //e Main Base RAM (`$0000`–`$BFFF`) |
| `u_core.u_rom` | `src/apple2_mem.v` | **8** | 16 KB | Apple //e Enhanced System ROM (`$C000`–`$FFFF`) |
| `u_aux.u_ddr3` | `src/ddr3_memory_interface/` | **8** | 16 KB | Gowin DDR3 Controller IP FIFOs & buffers |
| `u_hdmi.u_sched` | `src/hdmi/hdmi_island_scheduler.v` | **3** | 6 KB | HDMI Audio & InfoFrame packet queuing |
| `u_core.u_char_rom` | `src/apple2_mem.v` | **1** | 2 KB | Enhanced Character Generator ROM (2732 font) |
| `u_core.u_disk2` | `src/disk2/disk2_card.v` | **1** | 256 B | Disk II P6 Controller Boot ROM (`$C600`–`$C6FF`) |
| `u_debugger` | `src/serial_debugger.v` | **1** | 2 KB | Hardware Debugger UART TX FIFO |
| **Total BSRAM** | | **46 / 46** | **92 KB** | **100.0% utilization** |

### DDR3 Memory Mapping (128 MB Total)

Implemented in [`src/aux_ram.v`](file:///C:/Users/teren/source/repos/apple2e_TP20K/src/aux_ram.v):

| Region | Address Range | Allocated | Active Usage | Description |
| :--- | :--- | :---: | :---: | :--- |
| **Region 0 (Lower)** | `0x000000`–`0x00FFFF` | 64 KB | 64 KB | **Auxiliary RAM:** 80-column text, Double Hi-Res, aux zero page |
| **Region 0 (Upper)** | `0x010000`–`0x01FFFF` | 64 KB | 16 KB | **Main Language Card:** RAM `$D000`–`$FFFF` + Bank 2 `$D000`–`$DFFF` |
| **Region 1** | `0x1000000`–`0x13FFFFF` | 4 MB | 280 KB | **Disk II Storage:** Backing store for Drive 1 & 2 floppy images |
| **Region 3** | `0x3000000`+ | 128 B | 128 B | **Power-On Self-Test (POST):** Memory calibration pattern |
| **Free / Unused** | Remaining space | **~123.8 MB** | — | Unallocated DDR3 space |

---

## 5. Architectural Solutions Implemented

### 1. Moving the Language Card to DDR3
The standard Apple //e Language Card ($D000–$FFFF, 16 KB) originally required 8 BSRAM blocks. By relocating the Language Card into DDR3 Region 0, exactly **8 BSRAM blocks were liberated**, which directly met the requirement for the Gowin DDR3 Memory Interface IP.

### 2. Video Scanline Pre-Fetching
To prevent video glitches caused by DDR3 refresh or CPU arbitration, `src/aux_ram.v` implements a **40-byte on-chip line buffer**. 
During horizontal blanking (the ~218 pixel clocks before active video), the arbiter issues 5 consecutive BL8 burst reads to load the next 40 display bytes into the line buffer. During active display time, the video generator reads purely from the local buffer with zero DDR3 bus contention.

### 3. CPU Speculative Read Caching
The 65C02's address bus stabilizes ~25 cycles before the CPU read cycle strobe. `aux_ram.v` maintains a 1-byte read cache: while `rd_want` is asserted, a burst read is speculatively dispatched to DDR3. In practice, the data arrives well before the CPU latch point, resulting in near-zero wait state overhead.

### 4. Asynchronous Clock Domain Handshake
The Apple //e core operates on the **27.0 MHz** pixel/system clock, while the DDR3 controller operates on **99.58 MHz** (`mclk`). To prevent metastability, requests cross the domain boundary using a toggle-handshake (`req_t` / `ack_t`). Data is guaranteed stable for at least 2 full cycles before being sampled by the receiving domain.
