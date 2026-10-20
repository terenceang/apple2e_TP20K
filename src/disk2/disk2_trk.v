// Disk II controller card, slot 6, playing nibble tracks out of SDRAM.
//
// Same card as disk2_card.v as far as the bus is concerned (the I/O strobes, the
// stepper, the $C600 ROM, the data register), but the disk byte stream is no
// longer synthesised here.  Every track is a 7040-byte nibble stream that an
// ESP32 encodes and src/spi_ctl.v loads into SDRAM (layout: trk_defs.vh); this
// card reads the byte at the play head from there and, in write mode, writes the
// byte the CPU gives it back.  No 6-and-2 logic, no sector buffer, no decode:
// the ESP32 turns a flushed track back into sectors.
//
// Timing is unchanged: one disk byte per 33 ce_1m, the stream wraps at 7040, and
// a read of the data register hands the CPU the byte under the head with bit 7
// set only while it is fresh.  An SDRAM read takes ~10 clocks against the 858 a
// byte of drive time gives, so the byte is fetched when the head arrives.  If the
// head moves before the fetch lands (a seek) the register waits for it.
//
// A drive with no image reads as a stream of $FF and reports write protected.
//
// SDRAM port: this card owns dsk_*; spi_ctl reaches it through the x_* port,
// served only while the card itself has nothing to do.

`default_nettype none

module disk2_trk (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,
    input  wire        ce_1m,

    input  wire        devsel_n,
    input  wire        iosel_n,
    input  wire        bus_cycle,
    input  wire        cpu_we,
    input  wire [15:0] addr,
    input  wire [7:0]  cpu_di,
    output wire [7:0]  rom_data,
    output wire [7:0]  io_data,

    // Which drives hold an image (from spi_ctl)
    input  wire [1:0]  drv_present,
    input  wire [1:0]  drv_writable,

    // Head state and write events, for spi_ctl's dirty-track flush
    output wire        head_drv,
    output wire [5:0]  head_trk,
    output wire        motor,
    output reg         wr_evt,        // one clock: a byte was queued to be written
    output reg         wr_drv,
    output reg  [5:0]  wr_trk,

    // spi_ctl's word access to the image store
    input  wire        x_req,         // held until x_ack
    input  wire        x_we,
    input  wire [18:0] x_addr,        // byte address; the word at {addr[18:1],0}
    input  wire [15:0] x_wdata,
    output reg  [15:0] x_rdata,
    output reg         x_ack,         // one clock, x_rdata valid for a read

    // SDRAM port to aux_ram's arbiter (lowest priority)
    output reg         dsk_go,
    output reg  [21:0] dsk_addr,
    output reg         dsk_we,
    output reg  [15:0] dsk_wdata,
    input  wire [15:0] dsk_rdata,
    input  wire        dsk_ack,
    input  wire        dsk_idle,

    // Debugger view
    output wire [6:0]  dbg_track,
    output wire [7:0]  dbg_head,
    output wire        dbg_motor,
    output wire        dbg_drive,
    output wire        dbg_any_disk,
    output wire        dbg_wr_mode
);

    `include "src/disk2/trk_defs.vh"

    // ------------------------------------------------------------------
    // I/O decode (identical to disk2_card.v)
    // ------------------------------------------------------------------
    wire io_sel  = !devsel_n && bus_cycle;
    wire [3:0] io_a = addr[3:0];

    wire phase_hit = io_sel && !io_a[3];
    wire motor_off = io_sel && (io_a == 4'h8);
    wire motor_on  = io_sel && (io_a == 4'h9);
    wire drive1    = io_sel && (io_a == 4'hA);
    wire drive2    = io_sel && (io_a == 4'hB);
    wire q6l_sel   = io_sel && (io_a == 4'hC);
    wire q7l_sel   = io_sel && (io_a == 4'hD);
    wire q6_sel    = io_sel && (io_a == 4'hE);
    wire q7_sel    = io_sel && (io_a == 4'hF);

    reg        motor_q   = 1'b0;
    reg        drive_q   = 1'b0;
    reg [7:0]  head_q    = 8'd0;
    reg        wr_mode_q = 1'b0;
    reg        q6_q      = 1'b0;
    reg        started   = 1'b0;
    reg        rdy_q     = 1'b0;
    reg [7:0]  wr_latch  = 8'h00;

    localparam [7:0] TRACK_MAX = 8'd34;

    wire [5:0] trk = head_q[5:0];

    assign dbg_track   = head_q[6:0];
    assign dbg_head    = head_q;
    assign dbg_motor   = motor_q;
    assign dbg_drive   = drive_q;
    assign dbg_wr_mode = wr_mode_q;
    assign head_drv    = drive_q;
    assign head_trk    = trk;
    assign motor       = motor_q;

    // The stepper: one half-track toward whichever neighbouring phase is
    // energised when a phase comes on (see disk2_card.v).
    reg [3:0]  ph_mask  = 4'd0;
    reg [1:0]  ph_cur   = 2'd0;
    reg [6:0]  half_q   = 7'd0;

    wire [1:0] ph_n      = io_a[2:1];
    wire [3:0] mask_nx   = io_a[0] ? (ph_mask | (4'd1 << ph_n)) : (ph_mask & ~(4'd1 << ph_n));
    wire       pull_up   = mask_nx[ph_cur + 2'd1];
    wire       pull_dn   = mask_nx[ph_cur - 2'd1];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            motor_q <= 1'b0;
            drive_q <= 1'b0;
            head_q  <= 8'd0;
            ph_mask <= 4'd0;
            ph_cur  <= 2'd0;
            half_q  <= 7'd0;
        end else if (bus_cycle) begin
            if (motor_off)     motor_q <= 1'b0;
            else if (motor_on) motor_q <= 1'b1;
            if (drive1)        drive_q <= 1'b0;
            else if (drive2)   drive_q <= 1'b1;
            if (phase_hit) begin
                ph_mask <= mask_nx;
                if (io_a[0] && pull_up && !pull_dn) begin
                    ph_cur <= ph_cur + 2'd1;
                    if (half_q != {TRACK_MAX[5:0], 1'b0}) begin
                        half_q <= half_q + 1'b1;
                        head_q <= {1'b0, half_q + 7'd1} >> 1;
                    end
                end else if (io_a[0] && pull_dn && !pull_up) begin
                    ph_cur <= ph_cur - 2'd1;
                    if (half_q != 7'd0) begin
                        half_q <= half_q - 1'b1;
                        head_q <= {1'b0, half_q - 7'd1} >> 1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // The play head
    // ------------------------------------------------------------------
    localparam integer SHIFT_CLKS = 33;   // 32.26 us at ce_1m
    localparam integer TRACK_LEN  = `TRK_BYTES;

    reg [12:0] track_pos = 13'd0;
    reg [5:0]  shift_cnt = 6'd0;
    wire [12:0] track_nx = (track_pos >= TRACK_LEN - 1) ? 13'd0 : track_pos + 1'b1;

    wire present_now = drv_present[drive_q];
    assign dbg_any_disk = drv_present[0] || drv_present[1];

    // The byte in hand and which position/track/drive it is for.
    reg [7:0]  cur_byte = 8'hFF;
    reg        have_ok  = 1'b0;
    reg [12:0] have_pos = 13'd0;
    reg [5:0]  have_trk = 6'd0;
    reg        have_drv = 1'b0;
    wire cur_ok = have_ok && (have_pos == track_pos) && (have_trk == trk) &&
                  (have_drv == drive_q);

    // A queued write: the byte, and where it goes.
    reg        wq_v    = 1'b0;
    reg        wq_done = 1'b0;      // the SDRAM side has written it
    reg [7:0]  wq_byte = 8'd0;
    reg [12:0] wq_pos  = 13'd0;
    reg [5:0]  wq_trk  = 6'd0;
    reg        wq_drv  = 1'b0;

    // The fetch in flight.
    reg [12:0] f_pos = 13'd0;
    reg [5:0]  f_trk = 6'd0;
    reg        f_drv = 1'b0;

    wire q6l_rd = q6l_sel && !cpu_we;
    wire q7_rd  = q7_sel  && !cpu_we;
    wire q7l_rd = q7l_sel && !cpu_we;

    wire byte_ok = rdy_q && (!present_now || cur_ok);

    wire wr_protected = !drv_writable[drive_q];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            track_pos <= 13'd0;
            started   <= 1'b0;
            shift_cnt <= 6'd0;
            wr_mode_q <= 1'b0;
            q6_q      <= 1'b0;
            wr_latch  <= 8'h00;
            rdy_q     <= 1'b0;
            wq_v      <= 1'b0;
            wr_evt    <= 1'b0;
            wr_drv    <= 1'b0;
            wr_trk    <= 6'd0;
            wq_byte   <= 8'd0; wq_pos <= 13'd0; wq_trk <= 6'd0; wq_drv <= 1'b0;
        end else begin
            wr_evt <= 1'b0;
            if (q6l_sel)          q6_q      <= 1'b0;
            if (q7l_sel)          q6_q      <= 1'b1;
            if (q7_rd)            wr_mode_q <= 1'b0;
            if (q7_sel && cpu_we) wr_mode_q <= 1'b1;
            if (q6l_sel && cpu_we) wr_latch <= cpu_di;

            if (motor_q && ce_1m) begin
                if (shift_cnt >= SHIFT_CLKS - 1) begin
                    shift_cnt <= 6'd0;
                    rdy_q     <= 1'b1;
                    started   <= 1'b1;
                    if (started) track_pos <= track_nx;
                end else begin
                    shift_cnt <= shift_cnt + 1'b1;
                end
            end

            if (!wr_mode_q && q6l_rd && byte_ok) rdy_q <= 1'b0;

            if (wr_mode_q && q7l_rd) begin
                // Write mode: Q7L shifts the latched byte into the stream.
                track_pos <= track_nx;
                if (!wr_protected && !wq_v) begin
                    wq_v    <= 1'b1;
                    wq_byte <= wr_latch;
                    wq_pos  <= track_pos;
                    wq_trk  <= trk;
                    wq_drv  <= drive_q;
                    wr_evt  <= 1'b1;
                    wr_drv  <= drive_q;
                    wr_trk  <= trk;
                end
            end
            if (wq_done) wq_v <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // SDRAM access: queued write (read-modify-write), the byte fetch, then x_*
    // ------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_FETCH = 3'd1, S_WRRD = 3'd2, S_WRWR = 3'd3, S_X = 3'd4;
    reg [2:0] st = S_IDLE;

    wire [18:0] f_base = trk_base(f_drv, f_trk);
    wire [18:0] w_base = trk_base(wq_drv, wq_trk);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            st        <= S_IDLE;
            dsk_go    <= 1'b0;
            dsk_we    <= 1'b0;
            dsk_wdata <= 16'd0;
            dsk_addr  <= 22'd0;
            cur_byte  <= 8'hFF;
            have_ok   <= 1'b0;
            have_pos  <= 13'd0; have_trk <= 6'd0; have_drv <= 1'b0;
            f_pos     <= 13'd0; f_trk <= 6'd0; f_drv <= 1'b0;
            x_rdata   <= 16'd0;
            x_ack     <= 1'b0;
            wq_done   <= 1'b0;
        end else begin
            dsk_go  <= 1'b0;
            x_ack   <= 1'b0;
            wq_done <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (wq_v && !wq_done) begin
                        dsk_we   <= 1'b0;
                        dsk_addr <= trk_word_addr(w_base + {6'd0, wq_pos[12:1], 1'b0});
                        dsk_go   <= 1'b1;
                        st       <= S_WRRD;
                    end else if (present_now && !cur_ok) begin
                        f_pos    <= track_pos;
                        f_trk    <= trk;
                        f_drv    <= drive_q;
                        dsk_we   <= 1'b0;
                        dsk_addr <= trk_word_addr(trk_base(drive_q, trk) + {6'd0, track_pos[12:1], 1'b0});
                        dsk_go   <= 1'b1;
                        st       <= S_FETCH;
                    end else if (x_req && !x_ack) begin
                        dsk_we    <= x_we;
                        dsk_wdata <= x_wdata;
                        dsk_addr  <= trk_word_addr({x_addr[18:1], 1'b0});
                        dsk_go    <= 1'b1;
                        st        <= S_X;
                    end
                end
                S_FETCH: if (dsk_ack) begin
                    cur_byte <= f_pos[0] ? dsk_rdata[15:8] : dsk_rdata[7:0];
                    have_ok  <= 1'b1;
                    have_pos <= f_pos; have_trk <= f_trk; have_drv <= f_drv;
                    st       <= S_IDLE;
                end
                S_WRRD: if (dsk_ack) begin
                    dsk_we    <= 1'b1;
                    dsk_wdata <= wq_pos[0] ? {wq_byte, dsk_rdata[7:0]}
                                           : {dsk_rdata[15:8], wq_byte};
                    dsk_go    <= 1'b1;
                    st        <= S_WRWR;
                end
                S_WRWR: if (dsk_ack) begin
                    wq_done <= 1'b1;
                    if (have_ok && have_pos == wq_pos && have_trk == wq_trk && have_drv == wq_drv)
                        cur_byte <= wq_byte;
                    st <= S_IDLE;
                end
                S_X: if (dsk_ack) begin
                    x_rdata <= dsk_rdata;
                    x_ack   <= 1'b1;
                    st      <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // The data register
    // ------------------------------------------------------------------
    wire sense_wp = wr_mode_q || q6_q;
    wire [7:0] stream_byte = present_now ? cur_byte : 8'hFF;
    wire [7:0] rd_byte = byte_ok ? stream_byte : {1'b0, stream_byte[6:0]};
    wire [7:0] data_rd = sense_wp ? (wr_protected ? 8'h80 : 8'h00) : rd_byte;

    assign io_data = (io_sel && (io_a == 4'hC || io_a == 4'hE)) ? data_rd : 8'h00;

    // ------------------------------------------------------------------
    // The $C600-$C6FF boot ROM (identical to disk2_card.v)
    // ------------------------------------------------------------------
    reg [7:0] p6_rom [0:255];
    reg [7:0] p6_dout = 8'h00;
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
    always @(posedge clk) p6_dout <= p6_rom[addr[7:0]];
    assign rom_data = !iosel_n ? p6_dout : 8'h00;

endmodule

`default_nettype wire
