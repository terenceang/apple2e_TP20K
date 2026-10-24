// ============================================================================
//  softcard.v -- Microsoft Z-80 SoftCard, slot 2
//
//  The SoftCard's Z80 does not run beside the 6502: it takes the Apple's bus
//  over while the 6502 waits.  Any write to the card's $Cn00-$CnFF switches
//  masters, so the 6502's STA $C200 hands the bus to the Z80, and the Z80's
//  write to its own $E200 (the same $C200 after the scrambler below) hands it
//  back.  Each side resumes where it stopped; Apple RESET gives the bus to the
//  6502 and starts the Z80 at 0 next time.  The card has no ROM, no Z80 I/O
//  ports and no interrupts, and nor does this.  CP/M finds the slot itself.
//
//  The Z80 sees Apple memory through an address scrambler on A15-A12, so
//  that CP/M's page zero and TPA are not the 6502's zero page and stack:
//      Z80 $0000-$AFFF -> $1000-$BFFF     main RAM
//      Z80 $B000-$DFFF -> $D000-$FFFF     language card
//      Z80 $E000-$EFFF -> $C000-$CFFF     I/O and slot ROMs
//      Z80 $F000-$FFFF -> $0000-$0FFF     zero page, stack, text page
//
//  Timing.  The Z80 (tv80, src/z80/) runs off z_cen, a T-state enable at
//  2.045 MHz (two per ce_1m, the real card's 14.31818 MHz / 7), held like
//  the 6502's cpu_ce while the bus is busy (video_busy: a video fetch, a DDR3
//  cache miss or a write buffer still draining), so the aux and language-card
//  latency stretches a T-state exactly as it stretches a 6502 cycle.  A
//  memory cycle reaches the Apple bus as one z_go pulse, on the T2 enable
//  where tv80 takes its read data (and where its write data has been out
//  since T1), so a soft switch or a Disk II register sees one access per Z80
//  cycle, never one per T-state.  The address and the write flag only change
//  on a z_cen, and are registered here, so apple2_core's aux_fresh (which
//  counts z_cen as a step) covers them; nothing from the Z80 reaches the
//  aux tag compare without a register in between.
// ============================================================================

`default_nettype none

module softcard (
    input  wire        clk,
    input  wire        reset,
    input  wire        ce_1m,        // the 6502's cycle: the Z80 runs at twice it
    input  wire        cpu_rdy,      // the debugger's pause holds the Z80 too
    input  wire        video_busy,   // apple2_core's hold on a bus step
    input  wire        intcxrom,     // the internal ROM hides the card's $Cnxx
    // the bus as apple2_core sees it, whichever CPU is on it
    input  wire        bus_go,
    input  wire        bus_we,
    input  wire [15:0] bus_addr,
    input  wire [7:0]  bus_din,      // apple2_core's cpu_din_comb
    output reg         z80_on = 1'b0,
    output wire        z_cen,        // a Z80 T-state
    output wire        z_go,         // a Z80 memory cycle on the bus
    output reg  [15:0] z_addr = 16'd0,
    output reg         z_we = 1'b0,
    output wire [7:0]  z_dout
);

    localparam [3:0] SLOT = 4'd2;

    // Any write to $C200-$C2FF swaps the bus master, unless INTCXROM has the
    // internal ROM there (it does on a //e: the card's /IOSEL never fires)
    always @(posedge clk or posedge reset)
        if (reset)
            z80_on <= 1'b0;
        else if (bus_go && bus_we && bus_addr[15:8] == {4'hC, SLOT} && !intcxrom)
            z80_on <= !z80_on;

    // 2.045 MHz: two T-states for every 6502 cycle, one on ce_1m and one 13
    // clocks after it (ce_1m is 26 or 27 clocks apart), so the Z80's clock is
    // the Apple's doubled and locked to it, as the real card derives it.
    reg [3:0] half = 4'd0;            // clocks since ce_1m, to the midpoint
    reg       tick = 1'b0, pend = 1'b0;
    always @(posedge clk) begin
        tick <= ce_1m || half == 4'd12;
        half <= ce_1m ? 4'd0 : (half == 4'd15 ? half : half + 4'd1);
    end
    wire run = z80_on && cpu_rdy;
    assign z_cen = run && (tick || pend) && !video_busy;
    always @(posedge clk)
        pend <= run && (tick || pend) && video_busy;

    wire [15:0] a;
    wire [6:0]  mc, ts;
    wire        iorq, no_read, write, intcycle_n;
    reg  [7:0]  di_q = 8'hFF;

    // One bus access per memory cycle, on its T2 enable
    wire mem = mc[0] ? intcycle_n : (!iorq && (write || !no_read));
    assign z_go = z_cen && ts[2] && mem;
    // tv80 reads its data at that enable (an opcode) or later in the cycle,
    // so hold the byte: the Apple's bus may move on (a Disk II read latch).
    wire [7:0] di = (z_go && !z_we) ? bus_din : di_q;
    always @(posedge clk)
        if (z_go && !z_we) di_q <= bus_din;

    always @(posedge clk) begin
        z_addr <= {a[15:12] + (a[15:12] <= 4'hA ? 4'h1 :
                               a[15:12] <= 4'hD ? 4'h2 :
                               a[15:12] == 4'hE ? 4'hE : 4'h1), a[11:0]};
        z_we   <= !mc[0] && !iorq && write;
    end

    tv80_core #(.Mode(0), .IOWait(1)) u_z80 (
        .reset_n(!reset), .clk(clk), .cen(z_cen),
        .wait_n(1'b1), .int_n(1'b1), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(), .iorq(iorq), .no_read(no_read), .write(write),
        .rfsh_n(), .halt_n(), .busak_n(),
        .A(a), .dinst(di), .di(di), .dout(z_dout),
        .mc(mc), .ts(ts), .intcycle_n(intcycle_n), .IntE(), .stop()
    );

endmodule

`default_nettype wire
