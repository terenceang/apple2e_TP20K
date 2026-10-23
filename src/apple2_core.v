// Apple //e Core Logic for Tang Primer 20K
// Integrates the 65C02, main RAM, the system and character ROMs, the softswitches
// and the slot cards (Z-80 SoftCard 2, Mockingboard 4, clock 5, Disk II 6,
// ProDOS hard disk 7)

module apple2_core (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        ce_1m,         // 1.023 MHz clock enable

    // Inputs from Input Controller
    input  wire [7:0]  input_dout,
    input  wire        input_hit,
    output wire [7:0]  io_addr,
    output wire        io_read,
    output wire        io_write,

    // Speaker toggle pulse to Sound Generator
    output reg         spkr_pulse,

    // Mockingboard C Stereo Sound Output
    output wire signed [15:0] mock_audio_left,
    output wire signed [15:0] mock_audio_right,

    // Softswitches to Video Generator
    output reg         text_mode,
    output reg         mixed_mode,
    output reg         page2,
    output reg         hires_mode,
    output reg         col80,
    output reg         altchar,
    output reg         dhires,        // AN3 cleared ($C05E): double hi-res
    output reg         store80,
    input  wire        vbl,
    input  wire        clk_set,       // set the slot 5 clock (input_controller FF 05)
    input  wire [51:0] clk_time,

    // Video Generator RAM and Char ROM access
    input  wire        vram_req,
    input  wire [15:0] vram_addr,
    output reg  [7:0]  vram_data,
    output wire        fl_wr,         // a Disk ][ data field is being written (sd_vol's write-back)
    output wire        fl_wr_drv,
    output wire [5:0]  fl_wr_trk,
    input  wire [11:0] char_rom_addr,
    output wire [7:0]  char_rom_data,

    // Aux RAM port (aux_ram.v): the CPU's reads and writes that the aux
    // switches send to the second 64 KB
    output wire        aux_rd_want,
    output wire [16:0] aux_rd_addr,  // {main LC, address}: see aux_ram.v
    input  wire        aux_rd_hit,
    input  wire [7:0]  aux_rd_data,
    output wire        aux_wr_go,
    output wire [16:0] aux_wr_addr,
    output wire [7:0]  aux_wr_data,
    input  wire        aux_wr_busy,

    // Disk ][ controller in slot 6, and its image store in DDR3
    // (src/disk2/disk2_card.v, src/disk2/disk2_store.v).  The store's SDRAM
    // port is wired to aux_ram's arbiter at the top level; the card sits on the
    // slot bus below.
    output wire        dsk_store_go,
    output wire [21:0] dsk_store_addr,
    output wire        dsk_store_we,
    output wire [15:0] dsk_store_wdata,
    input  wire [15:0] dsk_store_rdata,
    input  wire        dsk_store_ack,
    input  wire        dsk_store_idle,

    // ProDOS hard disk in slot 7 (src/prodos_hd.v); its DDR3 port goes to
    // aux_ram at the top level, shared there with the TF card (src/sd_vol.v),
    // which also takes the block write-backs.
    input  wire [1:0]  hd_present,
    output wire        hd_go,
    output wire [24:0] hd_addr,
    output wire        hd_we,
    output wire [1:0]  hd_be,
    output wire [15:0] hd_wdata,
    input  wire [15:0] hd_rdata,
    input  wire        hd_ack,
    output wire        hd_wb_go,
    output wire        hd_wb_drv,
    output wire [15:0] hd_wb_blk,
    output wire        hd_rb_go,
    input  wire        hd_rb_ok,
    input  wire [15:0] hd_size0,      // slot 7 volumes' sizes in blocks (sd_vol)
    input  wire [15:0] hd_size1,
    input  wire        hd_sd_busy,

    // Diagnostic status & Debugger Interface
    input  wire        cpu_rdy,
    input  wire [15:0] dbg_mem_addr,
    output wire [7:0]  dbg_mem_din,
    output wire        dbg_mem_ready,  // dbg_mem_din is valid

    // The Disk ][ image transfer, from the debugger to the image store that
    // lives here.  It crosses the same boundary as the memory bus above and for
    // the same reason: the debugger is at the top level and the store is in here,
    // and the store's SDRAM port already goes out to aux_ram's arbiter.
    input  wire        img_up_go,
    input  wire        img_up_drive,
    input  wire [17:0] img_up_addr,
    input  wire [7:0]  img_up_data,
    input  wire        img_up_last,
    input  wire        img_up_bad,
    output wire        img_up_busy,
    output wire        img_up_done,
    input  wire        img_dn_go,
    input  wire        img_dn_drive,
    input  wire [17:0] img_dn_addr,
    output wire [7:0]  img_dn_data,
    output wire        img_dn_valid,

    output wire [7:0]  debug_dsk_head,   // the Disk ][ head's track (for the debugger's i command)
    output wire [15:0] debug_cpu_pc,
    output wire [15:0] debug_cpu_addr,
    output wire [7:0]  debug_cpu_dout,
    output wire        debug_cpu_we,
    output wire        debug_cpu_sync,
    output wire [7:0]  debug_cpu_a,
    output wire [7:0]  debug_cpu_x,
    output wire [7:0]  debug_cpu_y,
    output wire [7:0]  debug_cpu_s,
    output wire [7:0]  debug_cpu_p,
    output wire [7:0]  debug_cpu_ir
);

    // CPU Signals.  cpu_addr/cpu_dout/cpu_we are the bus, driven by the 65C02
    // or, while the SoftCard has it (z80_on), by the Z80 (src/softcard.v).
    wire [15:0] c02_addr;
    wire [7:0]  c02_dout;
    wire        c02_we;
    wire        z80_on, z_cen, z_go, z_we;
    wire [15:0] z_addr;
    wire [7:0]  z_dout;
    wire [15:0] cpu_addr = z80_on ? z_addr : c02_addr;
    wire [7:0]  cpu_dout = z80_on ? z_dout : c02_dout;
    wire        cpu_we   = z80_on ? z_we   : c02_we;
    reg  [7:0]  cpu_din;
    wire        cpu_sync;

    // Video-CPU memory conflict prevention:
    // If a 1 MHz CPU cycle enable (ce_1m) coincides with a video prefetch
    // access (vram_req or its read latch cycle vram_req_d), hold the cycle
    // enable until video RAM read has finished. This completely eliminates
    // contention/corruption between video prefetch and CPU RAM reads/writes,
    // avoiding display flickering/scrolling artifacts.
    reg ce_1m_pending;
    // Dual-latch RAM arbitration between CPU and Video Generator (declared
    // here because video_busy below reads vram_req_d; this iverilog rejects
    // declaration-after-use).
    reg vram_req_d;
    always @(posedge clk or posedge reset) begin
        if (reset)
            vram_req_d <= 1'b0;
        else
            vram_req_d <= vram_req;
    end
    // aux_stall is the hold while an aux RAM access is not ready; assigned
    // where its inputs are decoded, further down.
    wire aux_stall;
    // It is used a clock late: it comes from aux_ram's 17-bit cache tag
    // compare on the CPU's own address, and feeding that into cpu_go in the
    // same clock was clk_pixel's critical path.  A clock of lag is safe as
    // long as nothing that can turn a stall *on* changed in that clock, and
    // those all happen at one of: the CPU stepping (its address, cpu_we, the
    // softswitches, and a write, which empties the cache and fills the write
    // buffer), the debugger releasing RDY, and reset.  aux_fresh holds the
    // CPU for the clock after each.  (The next ce_1m is ~26 clocks off, so
    // it never actually waits.)  What turns a stall off -- a fill landing,
    // the write buffer draining -- just costs a clock.  DDR3 coming ready
    // is not covered: until then a read returns $FF anyway.
    //
    // Main RAM needs two clocks, not one: the address goes into the BSRAM
    // one clock after the step and its byte reaches cpu_ram_dout the clock
    // after that, so a step two clocks after the last one would latch the
    // previous address's byte (cpu_go_q2).  The same goes for the video
    // having had the BSRAM two clocks back (vram_req_d2): cpu_ram_dout was
    // not reloaded then.  A step that close only happens when the last one
    // waited (ce_1m_pending) behind a long aux stall and the next ce_1m
    // follows at once -- code running from aux or language-card RAM, e.g.
    // Prince of Persia, read stale main-RAM bytes and crashed.
    reg  aux_stall_q = 1'b0, cpu_go_q = 1'b0, cpu_go_q2 = 1'b0, rdy_q = 1'b0, reset_q = 1'b1;
    reg  vram_req_d2 = 1'b0;
    wire aux_fresh = cpu_go_q || cpu_go_q2 || reset_q || (cpu_rdy != rdy_q);
    // The same hold applies while an aux RAM access is not ready (aux_stall).
    wire video_busy = vram_req || vram_req_d || vram_req_d2 || aux_stall_q || aux_fresh;
    wire cpu_ce = (ce_1m || ce_1m_pending) && !video_busy;

    always @(posedge clk or posedge reset) begin
        if (reset)
            ce_1m_pending <= 1'b0;
        else if ((ce_1m || ce_1m_pending) && video_busy)
            ce_1m_pending <= 1'b1;
        else
            ce_1m_pending <= 1'b0;
    end

    // A CPU cycle that really happens: while the debugger holds RDY low the
    // enable keeps ticking, and side effects must not replay on each tick.
    // cpu_go is a bus step by either CPU: the 65C02's (c02_go) or a Z80
    // memory cycle (z_go).  Every Z80 T-state (z_cen) counts as a step for
    // aux_fresh, since its address and write flag change on any of them.
    wire c02_go = cpu_ce && cpu_rdy && !z80_on;
    wire cpu_go = c02_go || z_go;
    always @(posedge clk) begin
        aux_stall_q <= aux_stall;
        cpu_go_q    <= c02_go || z_cen;
        cpu_go_q2   <= cpu_go_q;
        vram_req_d2 <= vram_req_d;
        rdy_q       <= cpu_rdy;
        reset_q     <= reset;
    end
    // A real access to the bus, by the CPU or by the debugger while it holds
    // it.  The slot bus decodes on this rather than on cpu_go, so its strobes
    // follow the same address the cpu_din mux uses (effective_cpu_addr).
    wire bus_cycle = cpu_go || !cpu_rdy;

    // Slot bus (src/slot_bus.v): the //e's peripheral bus decode, the $C800
    // expansion-space arbitration and the interrupt daisy chain.  The cards
    // are listed at card_present; an empty slot's card-side inputs are tied
    // inactive at the instantiation, so its $Cn00 space behaves as on a //e
    // with nothing there: the internal ROM when a softswitch selects it, $00 for an
    // empty slot.  The wires are declared here rather than next to the
    // instantiation because the CPU below takes the interrupt lines from them.
    wire        slot_irq_n;
    wire        slot_nmi_n;
    wire        slot_dma_n;
    wire        slot_int_rom;
    wire [7:0]  slot_dout;
    wire [6:0]  devsel_n;
    wire [6:0]  iosel_n;
    wire        mock_irq_n;     // slot 4's IRQ, which the CPU below also takes

    wire addr_is_c0 = (cpu_addr[15:8] == 8'hC0);
    assign io_addr  = cpu_addr[7:0];
    assign io_read  = cpu_go && !cpu_we && addr_is_c0;
    assign io_write = cpu_go &&  cpu_we && addr_is_c0;

    assign debug_cpu_addr = c02_addr;
    assign debug_cpu_dout = c02_dout;
    assign debug_cpu_we   = c02_we;
    assign debug_cpu_sync = cpu_sync;

    // 65C02 CPU Core
    cpu_65c02 u_cpu (
        .clk(clk),
        .reset(reset),
        .AB(c02_addr),
        .DI(cpu_din),
        .DO(c02_dout),
        .WE(c02_we),
        .IRQ((~slot_irq_n) | (~mock_irq_n)),   // Active-high IRQ into 65C02 (core active-high, bus active-low)
        .NMI(~slot_nmi_n),
        .RDY(c02_go),
        .SYNC(cpu_sync),
        .debug_a(debug_cpu_a),
        .debug_x(debug_cpu_x),
        .debug_y(debug_cpu_y),
        .debug_s(debug_cpu_s),
        .debug_p(debug_cpu_p),
        .debug_pc(debug_cpu_pc),
        .debug_ir(debug_cpu_ir)
    );

    // Softswitches state registers
    reg lc_bank2;       // 1: Bank 2 ($D000 4KB alt), 0: Bank 1
    reg lc_read_ram;    // 1: Read LC RAM, 0: Read System ROM
    reg lc_write_ram;   // 1: Write LC RAM enabled
    reg lc_pre_write;   // Two successive reads required to enable write
    reg intcxrom;       // 1: Internal CX ROM ($C100-$CFFF) active
    reg slotc3rom;      // 1: slot 3 ROM at $C300 (0: internal 80-col firmware)
    reg intc8rom;       // 1: internal ROM at $C800-$CFFF (set by a $C3xx access)
    reg ramrd;          // 1: reads of $0200-$BFFF come from aux RAM
    reg ramwrt;         // 1: writes to $0200-$BFFF go to aux RAM
    reg altzp;          // 1: zero page, stack and language card use aux RAM

    // Softswitches decoding on posedge clk when ce_1m is active
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            text_mode    <= 1'b1; // Default: Text mode
            mixed_mode   <= 1'b0; // Default: Full screen
            page2        <= 1'b0; // Default: Page 1
            hires_mode   <= 1'b0; // Default: Lo-Res
            dhires       <= 1'b0;
            lc_bank2     <= 1'b0;
            lc_read_ram  <= 1'b0; // Default: Read ROM ($D000-$FFFF)
            lc_write_ram <= 1'b0;
            lc_pre_write <= 1'b0;
            altchar      <= 1'b0;
            col80        <= 1'b0;
            store80      <= 1'b0;
            intcxrom     <= 1'b0; // RESET clears INTCXROM, so the slot scan boots the card, not the //e self-test at $C600
            slotc3rom    <= 1'b0;
            intc8rom     <= 1'b0;
            ramrd        <= 1'b0;
            ramwrt       <= 1'b0;
            altzp        <= 1'b0;
            spkr_pulse   <= 1'b0;
        end else if (cpu_go) begin
            spkr_pulse <= 1'b0;

            // INTC8ROM: set by any $C3xx access with SLOTC3ROM off, cleared by
            // $CFFF.  A card claiming $C800 for itself is u_slot_bus's own
            // state (c8_owner), not this switch: on a real //e the two cannot
            // both hold the space, and u_slot_bus already keeps its card out
            // of the bus whenever this bit is set.
            if (cpu_addr[15:8] == 8'hC3 && !slotc3rom)
                intc8rom <= 1'b1;
            else if (cpu_addr == 16'hCFFF)
                intc8rom <= 1'b0;

            if (addr_is_c0) begin
                // Speaker toggle at $C030
                if (cpu_addr[7:4] == 4'h3) begin
                    spkr_pulse <= 1'b1;
                end

                // Video softswitches ($C050 - $C057)
                if (cpu_addr[7:4] == 4'h5) begin
                    case (cpu_addr[3:1])
                        3'd0: text_mode  <= cpu_addr[0]; // $C050/$C051: TEXT / GRAPHICS
                        3'd1: mixed_mode <= cpu_addr[0]; // $C052/$C053: FULL / MIXED
                        3'd2: page2      <= cpu_addr[0]; // $C054/$C055: PAGE1 / PAGE2
                        3'd3: hires_mode <= cpu_addr[0]; // $C056/$C057: LORES / HIRES
                        3'd7: dhires     <= ~cpu_addr[0]; // $C05E/$C05F: DHIRES on / off (AN3)
                        default: ;
                    endcase
                end

                // Apple //e aux softswitches ($C000-$C00F writes)
                if (cpu_we && (cpu_addr[7:4] == 4'h0)) begin
                    case (cpu_addr[3:1])
                        3'd0: store80  <= cpu_addr[0]; // $C000/$C001: 80STORE
                        3'd1: ramrd    <= cpu_addr[0]; // $C002/$C003: RAMRD
                        3'd2: ramwrt   <= cpu_addr[0]; // $C004/$C005: RAMWRT
                        3'd3: intcxrom <= cpu_addr[0]; // $C006/$C007: INTCXROM
                        3'd4: altzp    <= cpu_addr[0]; // $C008/$C009: ALTZP
                        3'd5: slotc3rom <= cpu_addr[0]; // $C00A/$C00B: SLOTC3ROM
                        3'd6: col80    <= cpu_addr[0]; // $C00C/$C00D: 80COL
                        3'd7: altchar  <= cpu_addr[0]; // $C00E/$C00F: ALTCHAR
                        default: ;
                    endcase
                end

                // Language Card Bank Switching ($C080 - $C08F)
                if (cpu_addr[7:4] == 4'h8) begin
                    lc_bank2    <= ~cpu_addr[3]; // A3=0 -> Bank 2, A3=1 -> Bank 1
                    lc_read_ram <= ~(cpu_addr[1] ^ cpu_addr[0]); // A0=A1 -> RAM read, A0!=A1 -> ROM read

                    if (!cpu_we && cpu_addr[0]) begin
                        // Two successive reads with A0=1 enable write
                        if (lc_pre_write)
                            lc_write_ram <= 1'b1;
                        lc_pre_write <= 1'b1;
                    end else if (!cpu_addr[0]) begin
                        lc_write_ram <= 1'b0;
                        lc_pre_write <= 1'b0;
                    end
                end
            end
        end
    end

    // Effective address: CPU address during normal operation, dbg_mem_addr when paused
    wire [15:0] effective_cpu_addr = (!cpu_rdy) ? dbg_mem_addr : cpu_addr;

    // The slot bus.  card_present (below) lists the cards; the empty slots'
    // card-side inputs are tied to their inactive levels.
    //
    // The active-low ties are 7'h7F and not 7'd7: that is decimal seven,
    // 7'b0000111, which would leave slot 4 asserting a line it has no card to
    // answer for.  card_data is a byte per card, so 56 bits wide, not 7.
    // Index 5 of a seven-slot vector is slot 6, which is the indexing
    // slot_bus uses throughout.
    wire [7:0]  d2_rom_data;
    wire [7:0]  mock_rom_data;
    wire [7:0]  hd_rom_data;
    wire [7:0]  hd_io_data;
    wire [7:0]  tc_rom_data;
    wire [7:0]  tc_io_data;
    wire        d2_any_disk;    // a Disk ][ drive holds an image (gates the $C600 ROM)
    wire [6:0]  card_present;
    // A byte per card, so 56 bits wide, not 7:
    // Slot 4 (index 3) is Mockingboard C.
    // Slot 5 (index 4) is the clock.
    // Slot 6 (index 5) is the Disk ][.
    // Slot 7 (index 6) is the ProDOS hard disk.
    wire [55:0] card_data;
    assign card_data = ({48'd0, hd_rom_data} << (6 * 8)) |
                       // no disk in either drive: slot 6 reads as empty (the
                       // floating bus), so the Autostart scan passes it by and
                       // falls into BASIC
                       ({48'd0, d2_any_disk ? d2_rom_data : vram_data} << (5 * 8)) |
                       ({48'd0, tc_rom_data} << (4 * 8)) |
                       ({48'd0, mock_rom_data} << (3 * 8));

    // The card's registers are on the $C0Ex bus, which the read mux claims
    // after the motherboard's own $C0xx addresses and before the $00 an
    // unclaimed I/O space returns.
    wire [7:0]  d2_io_data;
    wire        d2_io_hit = (effective_cpu_addr[15:8] == 8'hC0) &&
                            (effective_cpu_addr[7:4] == 4'hE);

    // The Mockingboard (slot 4): its two VIAs at /IOSEL ($C400-$C4FF) and
    // /DEVSEL ($C0C0-$C0CF).  Its $C4xx bytes reach the CPU as slot 4's
    // card_data, so the internal ROM outranks it under INTCXROM as it does any
    // card on a //e.  The selects are decoded from the address alone, not
    // taken from slot_bus's strobes: those are gated by bus_cycle, i.e. by
    // cpu_go, and the VIA's read data feeds cpu_din, so the strobes put the
    // whole cpu_go chain in front of the read mux (clk_pixel fell 32 -> 28 MHz).
    wire        mock_iosel_n  = !(effective_cpu_addr[15:8] == 8'hC4);
    wire        mock_devsel_n = !((effective_cpu_addr[15:8] == 8'hC0) &&
                                  (effective_cpu_addr[7:4] == 4'hC));

    wire [6:0]  card_irq_n = {1'b1, 1'b1, 1'b1, mock_irq_n, 1'b1, 1'b1, 1'b1};

    slot_bus u_slot_bus (
        .clk(clk),
        .reset(reset),
        .bus_cycle(bus_cycle),
        .addr(effective_cpu_addr),
        .intcxrom(intcxrom),
        .slotc3rom(slotc3rom),
        .intc8rom(intc8rom),
        .card_present(card_present),
        .card_exprom(7'b1000000), // slot 7's SmartPort lives in $C800 (prodos_hd_rom.s)
        .card_data(card_data),
        .int_in_n(1'b1),
        .card_irq_n(card_irq_n),
        .card_nmi_n(7'h7F),
        .card_dma_n(7'h7F),
        .devsel_n(devsel_n),     // the card listens to its own /DEVSEL
        .iosel_n(iosel_n),       // ...and /IOSEL, to answer $C600-$C6FF
        .irq_out_n(),
        .iostrobe_n(),           // $CFFF releases the expansion space
        .float_data(vram_data),          // the floating bus: the video's last byte
        .int_rom_sel(slot_int_rom),
        .slot_dout(slot_dout),
        .irq_n(slot_irq_n),
        .nmi_n(slot_nmi_n),
        .dma_n(slot_dma_n)
    );

    // Address Decode logic:
    // Memory map:
    // $0000 - $BFFF: Main RAM (48KB)
    // $C000 - $C0FF: I/O Softswitches, and slots 1-7's $C0n0-$C0nF I/O
    // $C100 - $C7FF: Slot ROM ($Cn00-$CnFF), or the internal peripheral ROM
    // $C800 - $CFFF: Shared expansion space, the internal ROM when INTC8ROM
    // $D000 - $FFFF: Language Card (RAM or System ROM)
    wire is_ram_base = (effective_cpu_addr < 16'hC000);
    wire is_io       = (effective_cpu_addr[15:8] == 8'hC0);
    wire is_slot_rom = (effective_cpu_addr >= 16'hC100 && effective_cpu_addr < 16'hD000);
    wire is_lc_area  = (effective_cpu_addr >= 16'hD000);

    // Aux RAM selection, from the CPU's own address (the debugger, which runs
    // with cpu_rdy low, sees main RAM only):
    //   $0000-$01FF zero page and stack   ALTZP
    //   $0200-$BFFF                       RAMRD / RAMWRT, except that with
    //                                     80STORE the text page ($0400-$07FF)
    //                                     and, with HIRES, $2000-$3FFF follow PAGE2
    //   $D000-$FFFF language card RAM     ALTZP
    wire st_page = store80 && (cpu_addr[15:10] == 6'b000001 ||
                               (hires_mode && cpu_addr[15:13] == 3'b001));
    wire aux_sel_cpu_rd = cpu_rdy && (cpu_addr < 16'h0200 ? altzp :
                                  cpu_addr < 16'hC000 ? (st_page ? page2 : ramrd) :
                                  cpu_addr >= 16'hD000 ? (lc_read_ram && altzp) : 1'b0);
    wire aux_sel_wr = cpu_rdy && (cpu_addr < 16'h0200 ? altzp :
                                  cpu_addr < 16'hC000 ? (st_page ? page2 : ramwrt) :
                                  cpu_addr >= 16'hD000 ? (lc_write_ram && altzp) : 1'b0);
    // Main memory's language-card RAM is in the DDR3 too, behind the same
    // port as aux (aux_ram.v; on the Tang Primer 20K its 16 KB of block RAM
    // went to the DDR3 controller), so it takes the same path: bit 16 of the
    // port address says which of the two.
    wire main_lc_rd = cpu_rdy && cpu_addr >= 16'hD000 && lc_read_ram  && !altzp;
    wire main_lc_wr = cpu_rdy && cpu_addr >= 16'hD000 && lc_write_ram && !altzp;
    wire ddr_sel_rd = aux_sel_cpu_rd || main_lc_rd;
    wire ddr_sel_wr = aux_sel_wr || main_lc_wr;
    // The debugger, while it holds the CPU, sees main memory; main
    // language-card RAM is in the DDR3, so reading it waits on the port too.
    // dbg_mem_ready is a clock late: it comes off aux_ram's tag compare, and
    // the debugger waits four clocks after setting an address anyway.
    wire dbg_lc_sel = !cpu_rdy && dbg_mem_addr >= 16'hD000 && lc_read_ram;
    wire aux_sel_rd    = ddr_sel_rd || dbg_lc_sel;
    assign aux_rd_want = (ddr_sel_rd && !cpu_we) || dbg_lc_sel;
    reg dbg_ready_q = 1'b1;
    always @(posedge clk) dbg_ready_q <= !dbg_lc_sel || aux_rd_hit;
    assign dbg_mem_ready = dbg_ready_q;
    assign aux_stall   = (ddr_sel_rd && !cpu_we && !aux_rd_hit) || (ddr_sel_wr && cpu_we && aux_wr_busy);
    assign aux_wr_go   = cpu_go && cpu_we && ddr_sel_wr;
    assign aux_wr_data = cpu_dout;

    // RAM Write Enable:
    // Writes go to RAM if in $0000-$BFFF, or if in $D000-$FFFF with lc_write_ram enabled
    // (and not to the aux RAM instead)
    // (the language-card area is never block RAM any more: see main_lc_wr)
    wire ram_we_cpu = cpu_we && !aux_sel_wr && is_ram_base;
    wire ram_we     = cpu_go ? ram_we_cpu : 1'b0;

    wire is_lc_bank2_d = lc_bank2 && (effective_cpu_addr >= 16'hD000 && effective_cpu_addr < 16'hE000);
    wire [15:0] cpu_ram_addr = is_lc_bank2_d ? {4'hC, effective_cpu_addr[11:0]} : effective_cpu_addr;
    assign aux_rd_addr = {cpu_rdy ? main_lc_rd : 1'b1, cpu_ram_addr};
    assign aux_wr_addr = {main_lc_wr, cpu_ram_addr};
    wire ram_addr_is_video = vram_req;
    wire [15:0] ram_addr   = ram_addr_is_video ? vram_addr : cpu_ram_addr;
    wire [7:0]  ram_din    = cpu_dout;
    wire [7:0]  ram_dout;

    // 48 KB main RAM, $0000-$BFFF (24 blocks); the language card is in DDR3
    apple2_ram_48k u_ram (
        .clk(clk),
        .addr(ram_addr),
        .din(ram_din),
        .we(ram_we),
        .dout(ram_dout)
    );

    // Latch Video RAM output when vram_req_d is active
    always @(posedge clk or posedge reset) begin
        if (reset)
            vram_data <= 8'hA0;
        else if (vram_req_d)
            vram_data <= ram_dout;
    end

    // Latch CPU RAM output when not serving video
    reg [7:0] cpu_ram_dout;
    always @(posedge clk or posedge reset) begin
        if (reset)
            cpu_ram_dout <= 8'h00;
        else if (!vram_req_d)
            cpu_ram_dout <= ram_dout;
    end

    // System ROM: 16KB ($C000 - $FFFF)
    wire [13:0] rom_addr = effective_cpu_addr[13:0]; // 0x0000 = $C000, 0x3FFF = $FFFF
    wire [7:0]  rom_dout;

    apple2_system_rom u_rom (
        .clk(clk),
        .addr(rom_addr),
        .dout(rom_dout)
    );

    // Character ROM: 4KB/8KB
    apple2_char_rom u_char_rom (
        .clk(clk),
        .addr(char_rom_addr),
        .dout(char_rom_data)
    );

    // Softswitch Read Multiplexer for $C010-$C01F (status returned in bit 7)
    reg sw_bit;
    always @(*) begin
        case (effective_cpu_addr[3:0])
            4'h1:    sw_bit = lc_bank2;       // $C011 RDLCBNK2
            4'h2:    sw_bit = lc_read_ram;    // $C012 RDLCRAM
            4'h3:    sw_bit = ramrd;          // $C013 RDRAMRD
            4'h4:    sw_bit = ramwrt;         // $C014 RDRAMWRT
            4'h5:    sw_bit = intcxrom;       // $C015 RDCXROM
            4'h6:    sw_bit = altzp;          // $C016 RDALTZP
            4'h7:    sw_bit = slotc3rom;      // $C017 RDC3ROM
            4'h8:    sw_bit = store80;        // $C018 RD80STORE
            4'h9:    sw_bit = ~vbl;           // $C019 RDVBLBAR
            4'hA:    sw_bit = text_mode;      // $C01A RDTEXT
            4'hB:    sw_bit = mixed_mode;     // $C01B RDMIXED
            4'hC:    sw_bit = page2;          // $C01C RDPAGE2
            4'hD:    sw_bit = hires_mode;     // $C01D RDHIRES
            4'hE:    sw_bit = altchar;        // $C01E RDALTCHAR
            4'hF:    sw_bit = col80;          // $C01F RD80COL
            default: sw_bit = 1'b0;
        endcase
    end
    // Bit 7 is the switch; bits 6:0 are the last key read, as on the //e
    wire [7:0] softswitch_read_data = {sw_bit, input_dout[6:0]};

    // CPU Data In (Read Bus) Multiplexer:
    reg [7:0] cpu_din_comb;
    always @(*) begin
        if (is_ram_base) begin
            cpu_din_comb = aux_sel_rd ? aux_rd_data : cpu_ram_dout;
        end else if (is_io) begin
            if (input_hit) begin
                cpu_din_comb = input_dout;
            end else if (effective_cpu_addr[7:4] == 4'h1 && effective_cpu_addr[3:0] != 4'h0) begin
                cpu_din_comb = softswitch_read_data;
            end else if (d2_io_hit) begin
                // The Disk ][ controller's registers: the data register at Q6L
                // and Q6, and the floating bus at the rest of $C0E0-$C0EF.
                cpu_din_comb = d2_io_data;
            end else if (effective_cpu_addr[7:4] == 4'hF) begin
                cpu_din_comb = hd_io_data;      // slot 7, $C0F0-$C0FF
            end else if (effective_cpu_addr[7:4] == 4'hD) begin
                cpu_din_comb = tc_io_data;      // slot 5, $C0D0-$C0DF
            end else if (!mock_devsel_n) begin
                // Mockingboard alternate I/O registers at $C0C0-$C0CF
                cpu_din_comb = mock_rom_data;
            end else begin
                cpu_din_comb = vram_data;       // nothing answers: the floating bus
            end
        end else if (is_slot_rom) begin
            cpu_din_comb = slot_int_rom ? rom_dout : slot_dout;
        end else if (is_lc_area) begin
            if (lc_read_ram)
                cpu_din_comb = aux_rd_data; // Language Card RAM, main or aux: both in DDR3
            else
                cpu_din_comb = rom_dout; // Read from System ROM (Applesoft BASIC + Monitor)
        end else begin
            cpu_din_comb = 8'hFF;
        end
    end

    // Latch data in to CPU on 1 MHz clock enable to prevent combinational loops
    // with CPU's internal address generator (which derives AB from DI in ABS/JMP/ZP states).
    always @(posedge clk or posedge reset) begin
        if (reset)
            cpu_din <= 8'h00;
        else if (cpu_go)
            cpu_din <= cpu_din_comb;
    end

    assign dbg_mem_din = (!cpu_rdy) ? cpu_din_comb : cpu_din;

    // ------------------------------------------------------------------
    // Microsoft Z-80 SoftCard, slot 2: a second bus master, no ROM
    // ------------------------------------------------------------------
    softcard u_softcard (
        .clk(clk),
        .reset(reset),
        .cpu_rdy(cpu_rdy),
        .video_busy(video_busy),
        .intcxrom(intcxrom),
        .bus_go(cpu_go),
        .bus_we(cpu_we),
        .bus_addr(cpu_addr),
        .bus_din(cpu_din_comb),
        .z80_on(z80_on),
        .z_cen(z_cen),
        .z_go(z_go),
        .z_addr(z_addr),
        .z_we(z_we),
        .z_dout(z_dout)
    );

    // ------------------------------------------------------------------
    // Disk ][ controller card, slot 6
    // ------------------------------------------------------------------
    // One card on the slot bus, wired to the strobes slot_bus decodes for it.
    // It sees the CPU's own cycles only (cpu_go), so the debugger walking the
    // bus in `m` cannot step the head or turn the motor on, which is the same
    // qualification rule the softswitch block above follows.
    wire        d2_motor;
    wire        d2_drive;
    wire        d2_wr_mode;
    wire        d2_grp_req;
    wire [8:0]  d2_grp_off;
    wire [5:0]  d2_grp_val;
    wire        d2_grp_ack;
    wire [3:0]  d2_pos_sec;     // where the head is: the tag for both a
    wire [8:0]  d2_pos_track;   // group request and a written byte
    wire        d2_pos_drive;
    wire [1:0]  d2_drv_present;
    wire [1:0]  d2_drv_writable;
    wire        d2_wr_seen;
    wire [7:0]  d2_wr_byte;
    wire        d2_wr_in_data;
    wire [8:0]  d2_wr_off;
    assign fl_wr     = d2_wr_seen && d2_wr_in_data;
    assign fl_wr_drv = d2_pos_drive;
    assign fl_wr_trk = d2_pos_track[5:0];

    assign card_present = 7'b1111000;   // slot 7 (bit 6): ProDOS hard disk, slot 6 (bit 5): the Disk ][, slot 5 (bit 4): clock, slot 4 (bit 3): Mockingboard
    wire [6:0]  d2_dbg_track;
    wire [7:0]  d2_dbg_head;
    assign debug_dsk_head = d2_dbg_head;

    // ------------------------------------------------------------------
    // Mockingboard "C" Sound Card, slot 4
    // ------------------------------------------------------------------
    mockingboard_card u_mockingboard (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .bus_cycle(bus_cycle),
        .cpu_we(cpu_we),
        .addr(effective_cpu_addr),
        .din(cpu_dout),
        .devsel_n(mock_devsel_n),
        .iosel_n(mock_iosel_n),
        .dout(mock_rom_data),
        .irq_n(mock_irq_n),
        .audio_left(mock_audio_left),
        .audio_right(mock_audio_right)
    );

    // ------------------------------------------------------------------
    // Clock (ProDOS sees a Thunderclock), slot 5
    // ------------------------------------------------------------------
    thunderclock u_clock (
        .clk(clk),
        .bus_cycle(cpu_go),
        .cpu_we(cpu_we),
        .addr(effective_cpu_addr),
        .set(clk_set),
        .set_time(clk_time),
        .rom_data(tc_rom_data),
        .io_data(tc_io_data)
    );

    // ------------------------------------------------------------------
    // ProDOS hard disk, slot 7
    // ------------------------------------------------------------------
    prodos_hd u_prodos_hd (
        .clk(clk),
        .reset(reset),
        .bus_cycle(cpu_go),
        .cpu_we(cpu_we),
        .addr(effective_cpu_addr),
        .cpu_di(cpu_dout),
        .present(hd_present),
        .size0(hd_size0),
        .size1(hd_size1),
        .rom_data(hd_rom_data),
        .io_data(hd_io_data),
        .hd_go(hd_go),
        .hd_addr(hd_addr),
        .hd_we(hd_we),
        .hd_be(hd_be),
        .hd_wdata(hd_wdata),
        .hd_rdata(hd_rdata),
        .hd_ack(hd_ack),
        .wb_go(hd_wb_go),
        .wb_drv(hd_wb_drv),
        .wb_blk(hd_wb_blk),
        .rb_go(hd_rb_go),
        .rb_ok(hd_rb_ok),
        .sd_busy(hd_sd_busy)
    );

    disk2_card u_disk2 (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .devsel_n(devsel_n[5]),
        .iosel_n(iosel_n[5]),
        .bus_cycle(cpu_go),
        .cpu_we(cpu_we),
        .addr(effective_cpu_addr),
        .cpu_di(cpu_dout),
        .rom_data(d2_rom_data),
        .io_data(d2_io_data),
        .grp_req(d2_grp_req),
        .grp_off(d2_grp_off),
        .pos_sec(d2_pos_sec),
        .pos_track(d2_pos_track),
        .pos_drive(d2_pos_drive),
        .grp_val(d2_grp_val),
        .grp_ack(d2_grp_ack),
        .store_wr_seen(d2_wr_seen),
        .store_wr_byte(d2_wr_byte),
        .store_wr_data(d2_wr_in_data),
        .store_wr_off(d2_wr_off),
        .store_drv_present(d2_drv_present),
        .store_drv_writable(d2_drv_writable),
        .dbg_track(d2_dbg_track),
        .dbg_head(d2_dbg_head),
        .dbg_motor(d2_motor),
        .dbg_drive(d2_drive),
        .dbg_any_disk(d2_any_disk),
        .dbg_wr_mode(d2_wr_mode)
    );

    // The image store, whose SDRAM port leaves the core for aux_ram's arbiter
    // at the top level.  The debugger's bulk transfer port is left off here
    // and reaches the store through the top level too, for the same reason.
    disk2_store u_disk2_store (
        .clk(clk),
        .reset(reset),
        .grp_req(d2_grp_req),
        .grp_off(d2_grp_off),
        .pos_sec(d2_pos_sec),
        .pos_track(d2_pos_track),
        .pos_drive(d2_pos_drive),
        .grp_val(d2_grp_val),
        .grp_ack(d2_grp_ack),
        .wr_seen(d2_wr_seen),
        .wr_byte(d2_wr_byte),
        .wr_in_data(d2_wr_in_data),
        .wr_off(d2_wr_off),
        .drv_present(d2_drv_present),
        .drv_writable(d2_drv_writable),
        .up_go(img_up_go),
        .up_drive(img_up_drive),
        .up_addr(img_up_addr),
        .up_data(img_up_data),
        .up_last(img_up_last),
        .up_bad(img_up_bad),
        .up_busy(img_up_busy),
        .up_done(img_up_done),
        .down_go(img_dn_go),
        .down_drive(img_dn_drive),
        .down_addr(img_dn_addr),
        .down_data(img_dn_data),
        .down_valid(img_dn_valid),
        .dsk_go(dsk_store_go),
        .dsk_addr(dsk_store_addr),
        .dsk_we(dsk_store_we),
        .dsk_wdata(dsk_store_wdata),
        .dsk_rdata(dsk_store_rdata),
        .dsk_ack(dsk_store_ack),
        .dsk_idle(dsk_store_idle)
    );

endmodule
