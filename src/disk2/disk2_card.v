// Disk II controller card, for slot 6 ($C0E0-$C0EF, $C600-$C6FF).
//
// This is the card side of a Disk ][ controller, at the level the P6 boot ROM
// and DOS/ProDOS RWTS actually drive: the four I/O strobes, the data register,
// four stepper phases, a motor and a drive select.  It decodes /DEVSEL and
// /IOSEL, answers $C600-$C6FF, and claims $C0E0-$C0EF on the read bus.
//
// The disk is bits
// ----------------
// A real drive hands the card a flux transition (a 1) or none (a 0) every
// 4 us, and the card's logic state sequencer shifts them into the data
// register until its top bit is set: that is a disk byte.  Here the bits come
// from a WOZ file (src/disk2/disk2_store.v plays the track under the head), and
// this module does what the sequencer does with them, so a track is read the
// way the hardware reads it: self-sync, nibble counts, odd marks and timing
// all come out of the bits, and nothing in the FPGA knows what a sector is.
//
// A bit cell is 4 CPU cycles, as on a //e, where the sequencer runs off the
// same clock as the 6502: a track of ~50,000 bits turns in 200 ms, 300 rpm.
// The cells count `step`, the 6502's own steps (ce_1m while the Z80 has the
// bus), not ce_1m.  The CPU gets every cycle (tb_cpusteps, and timed on the
// board), but a step can come up to 3 clocks after its ce_1m when the video
// has the RAM; with the latch window counted in ce_1m, a poll on time at the
// window's start and late at its end saw only 6 of its 7 cycles, so a 7-cycle
// LDA/BPL poll could miss a byte (seen on the board: DOS 3.3 read sector 0,
// then dropped bytes and crashed).  On the CPU's own steps it cannot drift.
//
// Read (Q7 low): each bit goes through an MC3470 model -- more than three
// zero bits in a row read as random bits, as the real amplifier's noise does
// (WOZ reference, "emulating fake bits") -- and is shifted into the register;
// when bit 7 is set the byte is in the data latch for 7 CPU cycles (long
// enough for a 7-cycle LDA/BPL poll to see it, short enough that RWTS's next
// read does not see it twice), and the register starts again from zero, so the
// zero bits after a sync byte are absorbed (self-sync).  After those 7 cycles
// the latch reads the register as it fills, bit 7 clear.
//
// Write (Q7 high): the register shifts its top bit onto the disk every bit
// cell, a 1 as a flux transition, and zeros in behind it, so a byte loaded
// every 32 cycles writes 8 bits and one loaded after 40 writes 10 (an FF and
// two zeros: a sync byte).  A write to the card with Q6 and Q7 both high
// loads the register (STA $C08F,X, then STA $C08D,X for each byte).
//
// The stepper
// -----------
// Four phase magnets, half a track apart, latched by $C0E0-$C0E7.  The head
// sits where the energised magnets pull it: on one magnet, or between two
// adjacent ones -- a quarter track.  It is tracked in quarter tracks, 0-159,
// which is what the WOZ map is indexed by.

`default_nettype none

module disk2_card (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        ce_1m,         // 1.023 MHz clock enable
    input  wire        step,          // a CPU cycle: the 6502's step (ce_1m while the Z80 runs)

    // Slot bus strobes, from slot_bus (src/slot_bus.v)
    input  wire        devsel_n,      // a $C0E0-$C0EF access is on the bus
    input  wire        iosel_n,       // a $C600-$C6FF access is on the bus
    input  wire        bus_cycle,     // a real access (the core's cpu_go)
    input  wire        cpu_we,        // the 6502 is writing
    input  wire [15:0] addr,
    input  wire [7:0]  cpu_di,        // the 6502's data out
    output wire [7:0]  rom_data,      // this card's byte on the slot ROM bus
    output wire [7:0]  io_data,       // this card's byte on the $C0Ex bus

    // The track, from the store (src/disk2/disk2_store.v)
    output wire        drive,         // 0 = drive 1
    output wire [7:0]  qtr,           // the head, in quarter tracks
    output wire        bit_tick,      // the bit cell ends
    output wire        wr_en,         // ...and wr_bit goes onto the disk in it
    output wire        wr_bit,
    output wire        wr_mode,       // Q7
    input  wire        rd_bit,        // the bit under the head
    input  wire        rd_ok,         // ...is a real one (else: noise)
    input  wire [1:0]  drv_present,   // a drive holds an image
    input  wire [1:0]  drv_writable,  // ...and it is writable

    // Debugger view of the card
    output wire [7:0]  dbg_head,      // quarter tracks
    output wire        dbg_any_disk   // some drive holds an image
);

    // ------------------------------------------------------------------
    // I/O decode: the $C0Ex strobes the P6 ROM uses
    // ------------------------------------------------------------------
    // $C0E0-$C0E7 stepper phases 0-3 (off at the even address, on at the odd),
    // $C0E8/$C0E9 motor off/on, $C0EA/$C0EB drive 1/2, $C0EC Q6L, $C0ED Q6H,
    // $C0EE Q7L, $C0EF Q7H.  The strobes are level-sensitive, so a read sets a
    // switch as readily as a write.  bus_cycle is the caller's cpu_go, so the
    // debugger poking the bus cannot step the head or turn the motor on.
    wire io_sel = !devsel_n && bus_cycle;
    wire [3:0] io_a = addr[3:0];

    wire phase_hit = io_sel && !io_a[3];
    wire motor_off = io_sel && (io_a == 4'h8);
    wire motor_on  = io_sel && (io_a == 4'h9);
    wire drive1    = io_sel && (io_a == 4'hA);
    wire drive2    = io_sel && (io_a == 4'hB);

    reg        q6 = 1'b0, q7 = 1'b0;
    wire       q6_nx = (io_sel && io_a[3:1] == 3'b110) ? io_a[0] : q6;   // $C0EC/$C0ED
    wire       q7_nx = (io_sel && io_a[3:1] == 3'b111) ? io_a[0] : q7;   // $C0EE/$C0EF

    // ------------------------------------------------------------------
    // Motor, drive select, stepper
    // ------------------------------------------------------------------
    reg        motor_q = 1'b0;
    reg [19:0] motor_timer = 20'd0;    // ~1 s spin-down after $C0E8 (the 74LS123 one-shot)
    wire       motor_running = motor_q || (motor_timer != 20'd0);
    reg        drive_q = 1'b0;
    reg [3:0]  ph_mask = 4'd0;         // phases energised
    reg [7:0]  q = 8'd0;               // the head, quarter tracks 0..159

    // Where the energised magnets pull the head.  Magnet p is at quarter
    // tracks 2p mod 8; d is each one's offset from the head, -3..+3 (one 4
    // away is opposite and pulls neither way).  One magnet pulls the head onto
    // it, two adjacent ones to the quarter track between them, and anything
    // else holds it where it is.
    wire [3:0] mask_nx = io_a[0] ? (ph_mask | (4'd1 << io_a[2:1])) : (ph_mask & ~(4'd1 << io_a[2:1]));
    reg  [2:0]       pr;
    reg signed [4:0] pull_sum;
    reg [2:0]        pull_n;
    integer pi;
    always @(*) begin
        pull_sum = 5'sd0;
        pull_n   = 3'd0;
        for (pi = 0; pi < 4; pi = pi + 1) begin
            pr = {pi[1:0], 1'b0} - q[2:0];                    // mod 8
            if (mask_nx[pi] && pr != 3'd4) begin
                pull_sum = pull_sum + {{2{pr[2]}}, pr};
                pull_n   = pull_n + 3'd1;
            end
        end
    end
    wire signed [4:0] pull = (pull_n == 3'd1) ? pull_sum :
                             (pull_n == 3'd2) ? pull_sum >>> 1 : 5'sd0;
    wire signed [9:0] q_to = $signed({2'b00, q}) + pull;
    wire [7:0] q_nx = (q_to < 0) ? 8'd0 : (q_to > 10'sd159) ? 8'd159 : q_to[7:0];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            motor_q     <= 1'b0;
            motor_timer <= 20'd0;
            drive_q     <= 1'b0;
            ph_mask     <= 4'd0;
            q6          <= 1'b0;
            q7          <= 1'b0;
            // the head stays where it is: a reset does not move a real one
        end else begin
            q6 <= q6_nx;
            q7 <= q7_nx;
            if (motor_off) begin
                motor_q     <= 1'b0;
                motor_timer <= 20'd1000000;   // ~1.0 s
            end else if (motor_on) begin
                motor_q     <= 1'b1;
                motor_timer <= 20'd0;
            end else if (motor_timer != 20'd0 && ce_1m)
                motor_timer <= motor_timer - 1'b1;
            if (drive1)      drive_q <= 1'b0;
            else if (drive2) drive_q <= 1'b1;
            if (phase_hit) begin
                ph_mask <= mask_nx;
                q       <= q_nx;
            end
        end
    end

    // ------------------------------------------------------------------
    // The bit cell, and the sequencer
    // ------------------------------------------------------------------
    reg [1:0] bcell = 2'd0;             // ce_1m within the 4-cycle bit cell
    always @(posedge clk) if (step) bcell <= bcell + 2'd1;
    assign bit_tick = step && bcell == 2'd3 && motor_running;

    // The MC3470: four zero bits in a row (one bit late) read as noise, ~25% ones
    reg [3:0]  win = 4'd0;
    reg [15:0] lfsr = 16'hACE1;
    wire [3:0] win_nx = {win[2:0], rd_ok && rd_bit};
    wire       fake   = lfsr[0] & lfsr[5];
    wire       bit_in = (win_nx != 4'd0) ? win_nx[1] : fake;

    reg  [7:0] sr = 8'd0;              // the shift register
    reg  [7:0] latch = 8'd0;           // the byte last completed
    reg  [2:0] hold = 3'd0;            // CPU cycles the latch shows it for
    wire [7:0] sr_in = {sr[6:0], bit_in};

    reg  [7:0] wsr = 8'd0;             // write mode: the byte going out
    wire       w_load = io_sel && cpu_we && q6_nx && q7_nx;

    always @(posedge clk) begin
        if (step && hold != 3'd0) hold <= hold - 3'd1;
        if (bit_tick) begin
            lfsr <= {lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5], lfsr[15:1]};
            if (!q7) begin
                win <= win_nx;
                if (sr_in[7]) begin latch <= sr_in; sr <= 8'd0; hold <= 3'd7; end
                else sr <= sr_in;
            end else
                wsr <= {wsr[6:0], 1'b0};
        end
        if (w_load) wsr <= cpu_di;
    end
    assign wr_mode = q7;
    assign wr_en   = q7;
    assign wr_bit  = wsr[7];
    assign drive   = drive_q;
    assign qtr     = q;

    // The data register.  In read mode, the byte or the register filling.
    // With Q6 high and Q7 low (LDA $C08D,X then LDA $C08E,X, which is how DOS
    // and ProDOS check) a read is the write-protect sense, bit 7 set when
    // protected; a drive with no image behind it reports protected.  In write
    // mode a read gives the same.
    wire wr_protected = !drv_writable[drive_q];
    wire [7:0] data_rd = (q6 || q7) ? (wr_protected ? 8'h80 : 8'h00) :
                         (hold != 3'd0) ? latch : sr;

    // What the card drives onto $C0E0-$C0EF: the data register at the even
    // addresses (the ROM reads $C0EC and $C0EE), the floating bus elsewhere.
    assign io_data = (io_sel && (io_a == 4'hC || io_a == 4'hE)) ? data_rd : 8'h00;

    assign dbg_head     = q;
    assign dbg_any_disk = drv_present[0] || drv_present[1];

    // ------------------------------------------------------------------
    // The $C600-$C6FF boot ROM
    // ------------------------------------------------------------------
    // The P6 boot ROM is Apple copyright and is supplied in roms/, like the
    // //e's own ROMs; see roms/README.md.  With INTCXROM on (the reset
    // default) the //e's internal ROM at $C600 boots a Disk II by itself; this
    // copy answers $C600 when the card's ROM is selected instead, which is
    // what a real Disk II card carries and what the ROM's own checksum test at
    // $C608 expects to find.
    reg [7:0] p6_rom [0:255];
    reg [7:0] p6_dout = 8'h00;
    // A simulation build has no Apple ROM (roms/ is not distributed), and
    // scripts/build.ps1 defines DSK2_NO_P6_ROM when roms/disk2_p6.hex is not
    // there, because $readmemh on a missing file stops the build outright and a
    // fresh clone has to build.
`ifdef DSK2_NO_P6_ROM
    integer pi6;
    initial begin
        for (pi6 = 0; pi6 < 256; pi6 = pi6 + 1) p6_rom[pi6] = 8'h00;
    end
`else
    initial begin
        $readmemh("roms/disk2_p6.hex", p6_rom);
    end
`endif
    // Latched every clock, not only under /IOSEL: the strobe is one clock wide (cpu_go)
    // and the CPU samples on that same edge, so a read gated by it returns the last access.
    always @(posedge clk) p6_dout <= p6_rom[addr[7:0]];
    assign rom_data = !iosel_n ? p6_dout : 8'h00;

endmodule

`default_nettype wire
