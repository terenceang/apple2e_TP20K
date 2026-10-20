// Auxiliary 64 KB RAM, and the Disk ][ image store, in the Tang Primer 20K's
// DDR3 (H5TQ1G63EFR, 128 MB x16).
//
// Wraps Gowin's DDR3 Memory Interface IP (src/ddr3_memory_interface/, the
// netlist from Sipeed's Tang Primer 20K DDR3 example: 400 MHz DDR3-800, 1:4,
// native interface, one BL8 burst = 8 x 16-bit words = 128 bits per command;
// see its README for why that one) with four clients, so
// nothing else in the design needs to know DDR3 timing:
//
//  * Video: a 40-byte line buffer. fill_start (once per scanline, in the
//    blanking before the next one) loads the 40 bytes at fill_addr; the
//    video reads them combinationally through col/line_data, so the DDR3 is
//    never on the video path.  Five burst reads, which must finish inside
//    the ~218 pixel clocks between the end of one active line and the next
//    line's pre-roll.
//  * CPU reads: a one-byte cache.  The CPU port's addresses are 17 bits: bit
//    16 = 1 is main memory's language-card RAM ($D000-$FFFF and the second
//    $D000 bank, as $C000-$FFFF), which lives here too so that its 16 KB of
//    block RAM is free for the DDR3 IP's buffers; 0 is aux RAM. While rd_want is up and the byte is not
//    cached, a read is issued; rd_hit says rd_data is valid. The CPU's
//    address is stable ~25 clocks before its cycle, so a stall is rare.
//  * CPU writes: a one-entry buffer. wr_go latches it at the CPU cycle;
//    wr_busy is high until the DDR3 has taken it and blocks a second one.
//  * The Disk ][ image store (src/disk2/disk2_store.v), lowest priority: it
//    moves whole sectors, and a floppy sector has milliseconds of slack.
//
// Two clock domains. The arbiter and every client port run on clk (27 MHz);
// the IP's user side runs on its own clk_out (memory clock / 4, ~100 MHz),
// not phase-related to clk. One operation at a time crosses between them by a
// toggle handshake: the 27 MHz side holds op/addr/data steady, flips req_t,
// and waits for ack_t to flip back, which the DDR side does only after rdata
// is final. That makes every multi-bit value that crosses stable for at least
// two clocks of the receiving domain before it is looked at. The line buffer
// is written on the DDR side and read combinationally on the video side,
// which is safe for the same reason it was with SDRAM: the video only reads
// it after the fill has finished. top.sdc declares the domains asynchronous.
//
// Each aux byte has a 16-bit word of its own, in the low byte (the disk store
// moves real 16-bit words), so a CPU byte store is one burst write with every
// other word masked off, and a line fill is five bursts of eight bytes.  Fill
// addresses are multiples of 8 (every Apple text / hi-res row base is), which
// is what makes a 40-byte row exactly five aligned bursts.
//
// Word address map (26 bits = bank[2:0], row[12:0], col[9:0]; the IP has 14
// row bits, and row bit 13 is always 0 since the 1 Gb part has 8K rows):
//   aux byte b          {10'd0, b}                  region 0
//   main LC byte b      {9'd0, 1'b1, b}             region 0, the next 64K words
//   disk store word w   {4'b0001, w[21:0]}          region 1, w as disk2_store makes it
//   init self-test      {4'b0011, 22'd0}            region 3, one burst
//
// The IP refreshes by itself.  It is not re-initialised on warm resets, so
// aux RAM and the disk images survive them.

module aux_ram (
    input  wire        clk,          // 27 MHz (Apple //e domain)
    input  wire        reset,
    input  wire        ddr_clk,      // 27 MHz onboard crystal (DDR3 IP ref clock)

    // Video line buffer
    input  wire        fill_start,
    input  wire [15:0] fill_addr,    // byte address of column 0, a multiple of 8
    input  wire [5:0]  col,          // 0..39
    output wire [7:0]  line_data,

    // CPU port
    input  wire        rd_want,
    input  wire [16:0] rd_addr,      // {main LC, address}
    output wire [7:0]  rd_data,
    output wire        rd_hit,
    input  wire        wr_go,
    input  wire [16:0] wr_addr,
    input  wire [7:0]  wr_data,
    output wire        wr_busy,

    // Disk ][ image store. A request is latched when dsk_go is pulsed, so a
    // client that asks while the arbiter is busy does not lose it, and dsk_ack
    // pulses when it has finished (with dsk_rdata valid, on a read).
    input  wire        dsk_go,
    input  wire [21:0] dsk_addr,
    input  wire        dsk_we,
    input  wire [15:0] dsk_wdata,
    output wire [15:0] dsk_rdata,
    output wire        dsk_ack,
    output wire        dsk_idle,

    // 1 once the DDR3 has calibrated and passed its self-test (clk domain)
    output wire        ready,
    // Bring-up diagnostics (quasi-static, read asynchronously; the debugger's
    // `t` prints it): {8'hD3, 4'd0, calib, ready, self-test step, low}.  low
    // is the first wrong self-test word until the DDR3 is up (step says
    // which read: 1 = after the burst write, 3 = after the masked one), then
    // live state: {e, open, op, cmd_ready, wr_data_rdy, 1, op_busy, kind,
    // dsk_pend, fill_pend, wr_pend, read miss}.
    output wire [31:0] diag,

    // DDR3 memory clock (400 MHz) from top.v's rPLL, and its lock
    input  wire        ddr_memory_clk,
    input  wire        ddr_lock,

    // DDR3 pins
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    inout  wire [1:0]  DDR3_DQS_n,
    output wire [13:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nCS,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_CK,
    output wire        DDR3_CK_n,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire        DDR3_ODT,
    output wire [1:0]  DDR3_DM
);

    localparam LINE_BYTES = 40;     // one Apple text row; video_generator fills 40 columns
    localparam [1:0] OP_RD = 2'd0, OP_WR = 2'd1, OP_FILL = 2'd2;

    // =====================================================================
    // 27 MHz side: arbiter and clients
    // =====================================================================

    reg         req_t = 1'b0;          // flips once per operation
    reg  [1:0]  req_op = OP_RD;
    reg  [25:0] req_addr = 26'd0;
    reg  [15:0] req_wdata = 16'd0;
    wire        ack_t_m;                // ack_t from the DDR side, synchronised below
    reg  [2:0]  ack_s = 3'd0;
    reg  [1:0]  rdy_s = 2'd0;
    wire        ddr_ready;
    wire [15:0] ddr_rdata;

    always @(posedge clk) begin
        ack_s <= {ack_s[1:0], ack_t_m};
        rdy_s <= {rdy_s[0], ddr_ready};
    end
    assign ready = rdy_s[1];
    wire   ack_edge = ack_s[2] ^ ack_s[1];

    localparam [2:0] K_FILL = 3'd1, K_WR = 3'd2, K_RD = 3'd3, K_DSK = 3'd5;

    reg        op_busy = 1'b0;
    reg [2:0]  kind = K_RD;
    reg [16:0] rd_addr_q = 17'd0;

    // Line fill: wanted, and where
    reg        fill_pend = 1'b0;
    reg [15:0] fill_base = 16'd0;

    // CPU write buffer
    reg        wr_pend = 1'b0;
    reg [16:0] wr_a = 17'd0;
    reg [7:0]  wr_d = 8'd0;
    assign wr_busy = wr_pend;

    // CPU read cache
    reg        cache_valid = 1'b0;
    reg [16:0] cache_addr = 17'd0;
    reg [7:0]  cache_data = 8'd0;
    reg        rd_stale = 1'b0;      // a write landed while a read was in flight
    assign rd_hit  = !ready || (cache_valid && (cache_addr == rd_addr));
    assign rd_data = ready ? cache_data : 8'hFF;

    // Disk store port
    reg        dsk_pend = 1'b0;
    reg [21:0] dsk_a_q  = 22'd0;
    reg        dsk_we_q = 1'b0;
    reg [15:0] dsk_d_q  = 16'd0;
    reg [15:0] dsk_r_q  = 16'd0;
    reg        dsk_ack_q= 1'b0;
    assign dsk_idle = !dsk_pend;
    assign dsk_ack  = dsk_ack_q;
    assign dsk_rdata= dsk_r_q;

    // Being a fill means the line buffer is mid-write; fill_active is for
    // testbenches that want to wait for it.
    wire fill_active = fill_pend || (op_busy && kind == K_FILL);

    always @(posedge clk) begin
        dsk_ack_q <= 1'b0;

        // An operation in flight is never abandoned (the DDR side would still
        // answer it); reset only drops what is waiting.
        if (reset) begin
            cache_valid <= 1'b0;
            fill_pend   <= 1'b0;
            wr_pend     <= 1'b0;
            dsk_pend    <= 1'b0;
        end

        if (dsk_go) begin
            if (ready) begin
                dsk_pend <= 1'b1;
                dsk_a_q  <= dsk_addr;
                dsk_we_q <= dsk_we;
                dsk_d_q  <= dsk_wdata;
            end else begin
                dsk_ack_q <= 1'b1;
                dsk_r_q   <= 16'hFFFF;
            end
        end

        if (fill_start && ready) begin
            fill_pend <= 1'b1;
            fill_base <= fill_addr;
        end

        if (wr_go && ready) begin
            wr_pend     <= 1'b1;
            wr_a        <= wr_addr;
            wr_d        <= wr_data;
            cache_valid <= 1'b0;
            if (op_busy && kind == K_RD) rd_stale <= 1'b1;
        end

        if (op_busy) begin
            if (ack_edge) begin
                op_busy <= 1'b0;
                case (kind)
                    K_WR: wr_pend <= 1'b0;
                    K_RD: begin
                        cache_data  <= ddr_rdata[7:0];
                        cache_addr  <= rd_addr_q;
                        cache_valid <= !rd_stale && !wr_pend && !wr_go;
                    end
                    K_DSK: begin
                        dsk_r_q   <= ddr_rdata;
                        dsk_pend  <= 1'b0;
                        dsk_ack_q <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end else if (ready) begin
            if (fill_pend && !fill_start) begin   // a new fill_start waits a clock
                kind <= K_FILL; req_op <= OP_FILL;
                req_addr  <= {10'd0, fill_base};
                fill_pend <= 1'b0;
                op_busy <= 1'b1; req_t <= ~req_t;
            end else if (wr_pend) begin
                kind <= K_WR; req_op <= OP_WR;
                req_addr  <= {9'd0, wr_a};
                req_wdata <= {8'd0, wr_d};
                op_busy <= 1'b1; req_t <= ~req_t;
            end else if (rd_want && !rd_hit) begin
                kind <= K_RD; req_op <= OP_RD;
                req_addr  <= {9'd0, rd_addr};
                rd_addr_q <= rd_addr;
                rd_stale  <= 1'b0;
                op_busy <= 1'b1; req_t <= ~req_t;
            end else if (dsk_pend) begin
                kind <= K_DSK; req_op <= dsk_we_q ? OP_WR : OP_RD;
                req_addr  <= {4'b0001, dsk_a_q};
                req_wdata <= dsk_d_q;
                op_busy <= 1'b1; req_t <= ~req_t;
            end
        end
    end

    // =====================================================================
    // DDR side (mclk, the IP's clk_out): one operation per request
    // =====================================================================

    wire        mclk;
    reg  [1:0]  req_s = 2'd0;
    reg         req_seen = 1'b0;     // req_t as of the last request taken
    reg         ack_t = 1'b0;
    reg  [15:0] rdata = 16'd0;
    assign ack_t_m   = ack_t;
    assign ddr_rdata = rdata;

    wire         m_calib, m_cmd_ready, m_wr_rdy, m_rd_valid;
    wire [127:0] m_rd_data;
    reg          m_wr = 1'b0;         // the command is a write (else a read)
    reg  [25:0]  m_addr = 26'd0;      // word address; the burst is m_addr[25:3]
    reg  [15:0]  m_wd = 16'd0;        // write data, in every word of the burst
    reg  [15:0]  m_mask = 16'h0000;   // 1 = byte not written

    // E_IDLE: wait for a request.  E_CMD: a command is ready and presented
    // until the IP takes it (cmd_en is combinational on its ready signals).
    // E_RD: a read has gone; wait for its burst.
    localparam [1:0] E_IDLE = 2'd0, E_CMD = 2'd1, E_RD = 2'd2;
    reg  [1:0]  e = E_IDLE;
    reg  [1:0]  op = OP_RD;
    reg         open = 1'b0;         // a request has been taken and not yet acked
    reg  [2:0]  fb = 3'd0;           // line fill burst 0..4

    wire         m_cmd_en = (e == E_CMD) && m_cmd_ready && (!m_wr || m_wr_rdy);
    wire [15:0]  m_word   = m_rd_data[{m_addr[2:0], 4'd0} +: 16];

    reg  [7:0]  linebuf [0:LINE_BYTES-1];
    assign line_data = linebuf[col];

    // Init: after calibration, write one burst of eight distinct words, read
    // it back, overwrite word 3 alone with a byte mask, and read it back
    // again.  That pins the beat order, the mask polarity and that writes land
    // at all (the open controller this replaced calibrated with every write a
    // CK off).  A failure leaves the DDR3 not ready and diag says where.
    reg         init_done = 1'b0;
    reg  [1:0]  tst = 2'd0;          // 0 burst write, 1 read, 2 masked write, 3 read
    reg         tbad = 1'b0;
    reg  [15:0] tval = 16'd0;
    function [15:0] pat(input [2:0] i);
        pat = 16'h5AA5 ^ ({13'd0, i} * 16'h1111);
    endfunction
    reg  [127:0] t_want;             // what the self-test expects back, and writes
    integer k;
    always @* for (k = 0; k < 8; k = k + 1)
        t_want[16*k +: 16] = (tst[1] && k == 3) ? 16'hC33C : pat(k[2:0]);
    reg  [15:0]  t_bad_word;         // the first word that differs, or 0 = none
    reg          t_ok;
    always @* begin
        t_ok = 1'b1; t_bad_word = 16'd0;
        for (k = 7; k >= 0; k = k - 1)
            if (m_rd_data[16*k +: 16] != t_want[16*k +: 16]) begin
                t_ok = 1'b0; t_bad_word = m_rd_data[16*k +: 16];
            end
    end
    wire testing = !init_done;

    always @(posedge mclk) begin
        req_s <= {req_s[0], req_t};

        case (e)
            E_IDLE:
                if (testing) begin
                    if (m_calib && !tbad) begin
                        m_addr <= {4'b0011, 22'd0};
                        m_wr   <= !tst[0];                          // steps 0, 2 write
                        m_mask <= (tst == 2'd2) ? 16'hFF3F : 16'h0000; // step 2: word 3 only
                        e <= E_CMD;
                    end
                end else if (req_s[1] != req_seen) begin
                    // req_t flipped at least two clocks ago; the request
                    // fields were already steady when it did.
                    req_seen <= req_s[1];
                    op     <= req_op;
                    m_addr <= req_addr;
                    m_wd   <= req_wdata;
                    m_wr   <= (req_op == OP_WR);
                    m_mask <= ~(16'h0003 << {req_addr[2:0], 1'b0});
                    fb     <= 3'd0;
                    open   <= 1'b1;
                    e <= E_CMD;
                end
            E_CMD:
                if (m_cmd_en) begin
                    if (!m_wr) e <= E_RD;
                    else begin
                        e <= E_IDLE;
                        if (testing) tst <= tst + 1'b1;
                        else begin open <= 1'b0; ack_t <= ~ack_t; end
                    end
                end
            E_RD:
                if (m_rd_valid) begin
                    e <= E_IDLE;
                    if (testing) begin
                        tst <= tst + 1'b1;
                        if (!t_ok) begin tbad <= 1'b1; tval <= t_bad_word; end
                        else if (tst == 2'd3) init_done <= 1'b1;
                    end else if (op == OP_FILL) begin
                        for (k = 0; k < 8; k = k + 1)
                            linebuf[{fb, 3'd0} + k] <= m_rd_data[16*k +: 8];
                        if (fb == 3'd4) begin
                            open <= 1'b0; ack_t <= ~ack_t;
                        end else begin
                            fb <= fb + 1'b1;
                            m_addr <= m_addr + 26'd8;
                            e <= E_CMD;
                        end
                    end else begin
                        rdata <= m_word;
                        open <= 1'b0; ack_t <= ~ack_t;
                    end
                end
            default: e <= E_IDLE;
        endcase
    end
    assign ddr_ready = init_done;

    // Write data: the self-test's burst, or the request's word in all eight
    // slots with the mask picking the one that lands.
    wire [127:0] m_wr_data = testing ? t_want : {8{m_wd}};

    // The IP's reset: held low while PLL is locking, then held low for
    // 128 cycles of ddr_clk after pll_lock is high, before releasing.
    reg [7:0] ip_rst_cnt = 8'd0;
    wire      ip_rst_n   = ip_rst_cnt[7];
    always @(posedge ddr_clk or negedge ddr_lock) begin
        if (!ddr_lock)
            ip_rst_cnt <= 8'd0;
        else if (!ip_rst_n)
            ip_rst_cnt <= ip_rst_cnt + 1'b1;
    end

    DDR3_Memory_Interface_Top u_ddr3 (
        .clk(ddr_clk), .memory_clk(ddr_memory_clk), .pll_lock(ddr_lock), .rst_n(ip_rst_n),
        .app_burst_number(6'd0),             // one burst per command
        .clk_out(mclk), .ddr_rst(), .init_calib_complete(m_calib),
        .cmd_ready(m_cmd_ready), .cmd(m_wr ? 3'd0 : 3'd1), .cmd_en(m_cmd_en),
        .addr({1'b0, m_addr[25:23], 1'b0, m_addr[22:3], 3'b000}),   // {rank, bank, row[13:0], col}
        .wr_data_rdy(m_wr_rdy), .wr_data(m_wr_data), .wr_data_en(m_cmd_en && m_wr),
        .wr_data_end(m_cmd_en && m_wr), .wr_data_mask(m_mask),
        .rd_data(m_rd_data), .rd_data_valid(m_rd_valid), .rd_data_end(),
        .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b1),
        .O_ddr_addr(DDR3_A), .O_ddr_ba(DDR3_BA), .O_ddr_cs_n(DDR3_nCS),
        .O_ddr_ras_n(DDR3_nRAS), .O_ddr_cas_n(DDR3_nCAS), .O_ddr_we_n(DDR3_nWE),
        .O_ddr_clk(DDR3_CK), .O_ddr_clk_n(DDR3_CK_n), .O_ddr_cke(DDR3_CKE),
        .O_ddr_odt(DDR3_ODT), .O_ddr_reset_n(DDR3_nRESET), .O_ddr_dqm(DDR3_DM),
        .IO_ddr_dq(DDR3_DQ), .IO_ddr_dqs(DDR3_DQS), .IO_ddr_dqs_n(DDR3_DQS_n)
    );

    assign diag = {8'hD3, 4'd0, m_calib, init_done, tst,
                   init_done ? {e, open, op, m_cmd_ready, m_wr_rdy, 1'b1,
                                op_busy, kind, dsk_pend, fill_pend, wr_pend, rd_want && !rd_hit}
                             : tval};
endmodule
