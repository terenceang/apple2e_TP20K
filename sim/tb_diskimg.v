// tb_diskimg -- the debugger's Disk ][ image transfer, both directions.
//
// This is the path a host actually uses to get a disk onto the board: the
// debugger's d1/d2 and e1/e2 commands, one byte at a time over the debugger's
// own port, into and out of the image store's SDRAM.  The card is not involved
// and neither is the CPU: what is checked is that the bytes the host sends
// arrive in the image in the right place, and that the bytes that come back are
// the ones that went in.
//
// It is a separate bench from tb_disk2 because it is a different system: that one
// drives the card with real bit timings and checks that sectors decode, and it
// ties the store's debugger port off.  What is shared is the SDRAM stand-in,
// which is the same 8-clocks-per-word model aux_ram.v paces the real controller
// with, so the byte map under test is the byte map the card sees.
//
// The host here is a real one: it reads the wire at 115200 8N1, it waits for the
// banner before it sends anything, and it paces the upload on the board's
// acknowledgements.  Those are not politeness.  A host that blasts the file gets
// its bytes dropped in the middle, because the board has room for exactly one
// byte in hand, and it ends up with an image the board believes in.

`timescale 1ns/1ps

module tb_diskimg;

    localparam integer IMG_BYTES = 143360;   // 35 tracks x 16 sectors x 256
    localparam integer DL_BYTES  = 4096;     // how much of a download is checked
    localparam integer SHADOWB   = 600000;   // two drives in SDRAM geometry (row 1024, col 512)

    reg clk = 1'b0;
    always #18.5 clk = ~clk;                 // 27 MHz

    reg reset = 1'b1;

    // The debugger's own inputs.  A command byte is offered on one clock edge,
    // the way input_controller does it, and a pause after it, the way a host
    // that waits for silence does: the debugger reads a command only while it is
    // idle and it prints for tens of cycles after taking one, so "d1" sent in
    // consecutive bytes loses the "1".
    reg  [7:0] rx_byte  = 8'h00;
    reg        rx_valid = 1'b0;

    wire       uart_tx;
    wire       dbg_mode, cpu_rdy, cpu_reset_req, dbg_aux, dbg_mem_ready;
    wire [7:0] dbg_mem_din;
    wire [15:0] dbg_mem_addr;
    wire       img_up_go, img_up_drive, img_up_last, img_up_busy, img_up_done;
    wire       img_up_bad;
    wire [17:0] img_up_addr;
    wire [7:0]  img_up_data;
    wire       img_dn_go, img_dn_drive, img_dn_last, img_dn_valid, img_dn_done;
    wire [17:0] img_dn_addr;
    wire [7:0]  img_dn_data;

    // The bench's own connection to the store's upload port, for the direct
    // tests.  Declared here, before the store that is wired to them, because
    // Icarus will not bind a port expression to something declared later.  The
    // debugger drives the same pins, and its outputs are all zero while it is
    // idle, so plain ORs and muxes are enough to share them.
    reg         b_up_go = 1'b0;
    reg         b_up_drive = 1'b0;
    reg  [17:0] b_up_addr = 18'd0;
    reg  [7:0]  b_up_data = 8'h00;
    reg         b_up_last = 1'b0;

    // A CPU that never runs, which is what a paused machine looks like to the
    // debugger.  The registers are only read back by the r command.
    wire [15:0] cpu_pc = 16'hFA62, cpu_addr = 16'h0000;
    wire [7:0]  cpu_a = 8'h00, cpu_x = 8'h00, cpu_y = 8'h00, cpu_s = 8'hFF;
    wire [7:0]  cpu_p = 8'h20, cpu_ir = 8'h00, cpu_dout = 8'h00;
    wire        cpu_we = 1'b0, cpu_sync = 1'b0;

    serial_debugger u_dbg (
        .clk(clk), .reset(reset), .ce_1m(1'b1), .uart_tx(uart_tx),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .dbg_mode(dbg_mode), .cpu_rdy(cpu_rdy), .cpu_reset_req(cpu_reset_req),
        .dbg_mem_addr(dbg_mem_addr), .dbg_mem_din(dbg_mem_din),
        .dbg_mem_ready(dbg_mem_ready), .dbg_aux(dbg_aux),
        .img_up_go(img_up_go), .img_up_drive(img_up_drive), .img_up_addr(img_up_addr),
        .img_up_data(img_up_data), .img_up_last(img_up_last),
        .img_up_bad(img_up_bad),
        .img_up_busy(img_up_busy), .img_up_done(img_up_done),
        .img_dn_go(img_dn_go), .img_dn_drive(img_dn_drive), .img_dn_addr(img_dn_addr),
        .img_dn_last(img_dn_last), .img_dn_data(img_dn_data),
        .img_dn_valid(img_dn_valid), .img_dn_done(img_dn_done),
        .cpu_pc(cpu_pc), .dsk_head(8'd0), .cpu_a(cpu_a), .cpu_x(cpu_x), .cpu_y(cpu_y), .cpu_s(cpu_s),
        .cpu_p(cpu_p), .cpu_ir(cpu_ir), .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
        .cpu_we(cpu_we), .cpu_sync(cpu_sync),
        .text_mode(1'b1), .mixed_mode(1'b0), .page2(1'b0), .hires_mode(1'b0),
        .pll_locked(1'b1), .ddr_diag(32'd0)
    );

    // The store, with the same SDRAM stand-in as tb_disk2: one word per 8 clocks.
    // The card's ports are tied off -- an input may be tied to a constant but an
    // output may not, so grp_ack needs a wire of its own.
    wire        dsk_go, dsk_we, dsk_ack, dsk_idle, unused_grp_ack;
    wire [21:0] dsk_addr;
    wire [15:0] dsk_wdata, dsk_rdata;
    wire [1:0]  drv_present, drv_writable;

    reg  [3:0]  dsk_t = 4'd0;
    reg         dsk_busy = 1'b0;
    reg  [21:0] dsk_a_q = 22'd0;
    reg         dsk_we_q = 1'b0;
    reg  [15:0] dsk_d_q = 16'd0;
    reg  [15:0] dsk_r_q = 16'd0;
    reg         dsk_ack_q = 1'b0;

    assign dsk_idle  = !dsk_busy;
    assign dsk_ack   = dsk_ack_q;
    assign dsk_rdata = dsk_r_q;

    // The whole image space in the controller's own byte order, so a check can
    // see where a byte landed rather than what went into it.  Big enough to
    // catch a byte written one drive too far.
    reg [7:0] shadow [0:SHADOWB-1];
    integer si;
    initial for (si = 0; si < SHADOWB; si = si + 1) shadow[si] = 8'h00;

    always @(posedge clk) begin
        dsk_ack_q <= 1'b0;
        if (dsk_go) begin
            dsk_busy <= 1'b1;
            dsk_t    <= 4'd0;
            dsk_a_q  <= dsk_addr;
            dsk_we_q <= dsk_we;
            dsk_d_q  <= dsk_wdata;
        end else if (dsk_busy) begin
            dsk_t <= dsk_t + 4'd1;
            if (dsk_t == 4'd7) begin
                dsk_busy  <= 1'b0;
                dsk_ack_q <= 1'b1;
                dsk_r_q   <= {shadow[byte_of(dsk_a_q, 1'b1)],
                              shadow[byte_of(dsk_a_q, 1'b0)]};
                if (dsk_we_q) begin
                    shadow[byte_of(dsk_a_q, 1'b0)] <= dsk_d_q[7:0];
                    shadow[byte_of(dsk_a_q, 1'b1)] <= dsk_d_q[15:8];
                end
            end
        end
    end

    // The byte address a controller word address names, in the same layout
    // tb_disk2 uses: bank 1, then row, column and the half bit.
    function integer byte_of(input [21:0] a, input half);
        begin
            byte_of = ((a[21:20] - 2'd1) * 1048576) + (a[19:9] * 1024) +
                      (a[8:1] * 2) + half;
        end
    endfunction

    function integer shadow_idx(input integer drive, input integer off);
        reg [18:0] flat;
        begin
            flat = (drive ? IMG_BYTES : 0) + off;
            shadow_idx = (flat[18:9] * 1024) + (flat[8:1] * 2) + flat[0];
        end
    endfunction

    disk2_store u_store (
        .clk(clk), .reset(reset),
        .grp_req(1'b0), .grp_off(9'd0), .pos_sec(4'd0), .pos_track(9'd0),
        .pos_drive(1'b0), .grp_val(), .grp_ack(unused_grp_ack),
        .wr_seen(1'b0), .wr_byte(8'h00), .wr_in_data(1'b0), .wr_off(9'd0),
        .drv_present(drv_present), .drv_writable(drv_writable),
        // The debugger and the bench share the upload port.  The debugger's
        // outputs are all zero while it is idle, which is whenever the bench is
        // driving, so the ORs have one driver each in practice.
        .up_go(img_up_go | b_up_go),
        .up_drive(b_up_go ? b_up_drive : img_up_drive),
        .up_addr(b_up_go ? b_up_addr : img_up_addr),
        .up_data(b_up_go ? b_up_data : img_up_data),
        .up_last(img_up_last | b_up_last),
        .up_bad(img_up_bad),
        .up_busy(img_up_busy), .up_done(img_up_done),
        .down_go(img_dn_go), .down_drive(img_dn_drive), .down_addr(img_dn_addr),
        .down_last(img_dn_last), .down_data(img_dn_data),
        .down_valid(img_dn_valid), .down_done(img_dn_done),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack), .dsk_idle(dsk_idle)
    );

    // ------------------------------------------------------------------
    // The host
    // ------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;

    // Shared by the tasks and the initial block, and declared before them because
    // Icarus will not bind a task port to something declared later.
    reg [31:0] sum_exp;
    integer i, bad, outstanding, acks, WINDOW = 16, match, slen;
    reg [7:0] gotb;
    reg [7:0] skipbuf [0:15];

    task check;
        input ok;
        input [8*64-1:0] what;
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL: %0s", what);
            end
        end
    endtask

    // The byte the host sends at offset i of an image.  It depends on the offset,
    // so a byte that lands in the wrong place is not the byte that was sent: a
    // constant image would pass with an off-by-one in the address.
    function [7:0] pat(input integer n);
        begin
            pat = ((n * 8'h1D) ^ (n[15:8] ^ n[7:0]) ^ 8'hA5) & 8'hFF;
        end
    endfunction

    // One byte, then a pause.  The pause is not the wire's 234 clocks: that makes
    // a whole image 33 million clocks of simulated time, and what is under test
    // here is the path from the debugger to the store, not the UART, which
    // tb_input already drives with real bit timings.  Twenty clocks a byte is
    // still slower than the debugger, whose intake is take-then-offer-then-wait
    // and whose store blocks for a word write every second byte, so nothing is
    // dropped -- and if the pacing were too fast the transfer would end in
    // "lost" rather than "done" and expect_str below would say so, so a wrong
    // guess fails the test instead of quietly corrupting an image.
    task send(input [7:0] b);
        begin
            @(negedge clk);
            rx_byte  = b;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
            repeat (25) @(posedge clk);
        end
    endtask

    task send_cmd(input [7:0] b);
        begin
            wait_quiet(4000);      // the board has to be idle to read it
            send(b);
        end
    endtask

    // 115200 8N1 off the pin, least significant bit first, sampled with delays
    // rather than by counting clock edges: at 2,340 clocks a byte the edge-by-edge
    // version spends all its time in the testbench.
    task rx_byte_task(output [7:0] b);
        integer k;
        reg [9:0] sh;
        begin
            while (uart_tx !== 1'b0) @(posedge clk);   // wait for the start bit
            #(37 * 117);                                // into the middle of it
            sh[0] = uart_tx;
            for (k = 1; k < 10; k = k + 1) begin
                #(37 * 234);
                sh[k] = uart_tx;
            end
            b = sh[1];
            for (k = 1; k < 8; k = k + 1) b[k] = sh[k + 1];
        end
    endtask

    // Everything the board says, in a queue, drained in the background the way a
    // host's reader does.  Reading it only when a test wants it would mean
    // counting lines, and the debugger prints its banner, two prompts and a
    // register dump before the first command does anything.
    reg [7:0] q [0:65535];
    integer q_wr = 0, q_rd = 0;
    reg [7:0] drain_b;

    initial forever begin
        rx_byte_task(drain_b);
        q[q_wr % 65536] = drain_b;
        q_wr = q_wr + 1;
`ifdef DBG_DRAIN
        if (q_wr < 60) $write("%c", drain_b);
`endif
    end

    task getbyte(output [7:0] b);
        begin
            while (q_rd == q_wr) @(posedge clk);
            b = q[q_rd % 65536];
            q_rd = q_rd + 1;
        end
    endtask

    // In Verilog, string literals are right-aligned (stored in the lowest bytes).
    function integer strlen(input [8*16-1:0] s);
        integer k;
        begin
            strlen = 0;
            for (k = 15; k >= 0; k = k - 1)
                if (strlen == 0 && s[8*k +: 8] !== 8'h00)
                    strlen = k + 1;
        end
    endfunction

    // Character n from the beginning of string s (0 is first character).
    function [7:0] chr(input [8*16-1:0] s, input integer n);
        integer len;
        begin
            len = strlen(s);
            if (n < len)
                chr = s[8*(len - 1 - n) +: 8];
            else
                chr = 8'h00;
        end
    endfunction

    // Throw bytes away until this string has been seen.  Matching the text is
    // what makes this independent of however much the debugger said beforehand.
    task skip_until(input [8*16-1:0] s);
        integer k;
        begin
            slen = strlen(s);
            for (k = 0; k < 16; k = k + 1) skipbuf[k] = 8'h00;
            forever begin
                getbyte(gotb);
                for (k = slen - 1; k > 0; k = k - 1) skipbuf[k] = skipbuf[k - 1];
                skipbuf[0] = gotb;
                match = 1;
                for (k = 0; k < slen; k = k + 1)
                    if (skipbuf[k] !== chr(s, slen - 1 - k)) match = 0;
                if (match) disable skip_until;
            end
        end
    endtask

    // Take this string out of the queue, and check it against what came out.
    task expect_str(input [8*16-1:0] s);
        integer n;
        begin
            slen = strlen(s);
            for (n = 0; n < slen; n = n + 1) begin
                getbyte(gotb);
                if (gotb !== chr(s, n)) begin
                    fails = fails + 1;
                    $display("FAIL: expected %02x ('%c'), got %02x ('%c'), at %0d of the string",
                             chr(s, n), chr(s, n), gotb, gotb, n);
                end
                checks = checks + 1;
            end
        end
    endtask

    task skip_to_eol;
        begin
            forever begin
                getbyte(gotb);
                if (gotb === 8'h0A) disable skip_to_eol;
            end
        end
    endtask

    // Wait until the board has said nothing for a while.  This is what the web
    // app's 200 ms of silence is for, and it is not optional: the debugger reads
    // a command only while it is idle, and after Ctrl+B it prints a banner, two
    // prompts and a register line, which at 115200 is four milliseconds of
    // talking.  A command sent into the middle of that is dropped without a word.
    task wait_quiet(input integer usec);
        integer seen;
        begin
            forever begin
                seen = q_wr;
                #(usec * 1000);
                if (q_wr == seen) disable wait_quiet;
            end
        end
    endtask

    // An upload, the way a host has to do it: one track in, one acknowledgement
    // out, 35 times.
    //
    // The track pacing is only safe because the host is also slower than the
    // store.  A host that is not gets its bytes dropped in the middle, which the
    // board notices by counting what arrived against what it took and answers
    // with "lost" rather than "done": the image is wrong, not absent, and a
    // drive with an image is one DOS will boot.  That case is checked later with
    // a host that offers bytes as fast as it can.
    task upload(input integer drive, input integer count, input [7:0] xor_mask);
        begin
            // The letter and the digit are two command bytes, each read on its
            // own visit to idle, so each waits for the board to go quiet.
            send_cmd("d");
            send_cmd(drive == 0 ? "1" : "2");
            skip_until("UPLOAD");
            skip_to_eol;
            for (i = 0; i < count; i = i + 1) begin
                send(pat(i) ^ xor_mask);
                if (i[11:0] == 12'hFFE)
                    $display("  sent %0d, acks %0d, board has %0d, st=%0d have=%b sent=%b busy=%b | store st=%0d have=%b busy=%b q=%0d",
                             i + 1, acks, u_dbg.img_addr, u_dbg.main_state,
                             u_dbg.img_have, u_dbg.img_sent, img_up_busy,
                             u_store.state, u_store.up_have, u_store.up_busy,
                             q_wr - q_rd);
                // A track's last byte, and so the byte the board acknowledges.
                if (i[11:0] == 12'hFFF) begin : wait_ack
                    forever begin
                        getbyte(gotb);
                        if (gotb === 8'h06) begin
                            acks = acks + 1;
                            disable wait_ack;
                        end
                    end
                end
            end
            expect_str({8'h0D, 8'h0A, "done", 8'h0D, 8'h0A});
        end
    endtask

    // ------------------------------------------------------------------
    // The tests
    // ------------------------------------------------------------------
    //
    // A whole image over the wire at 115200 is 335 million clocks of simulated
    // time, which is minutes of wall clock, so the wire tests are kept short and
    // full-image coverage is got a different way: the store's upload port is
    // driven directly, one byte every three clocks, which is the same port the
    // debugger drives and the same SDRAM under it, and it is what checks the
    // addressing across the whole 143,360 bytes.  What the wire is kept for is
    // the protocol: the banner, the track acknowledgements, the done and lost
    // answers, and the order a download comes back in.

    // One byte straight into the store, at whatever pace the bench likes.  The
    // handshake is the store's: up_go while it is not busy, up_done to say the
    // byte was taken.
    task store_put(input drive, input integer n);
        integer w;
        begin
            b_up_drive = drive;
            b_up_addr  = n[17:0];
            b_up_data  = pat2(n);
            b_up_last  = (n == IMG_BYTES - 1);
            while (img_up_busy) @(posedge clk);
            @(negedge clk);
            b_up_go = 1'b1;
            @(negedge clk);
            b_up_go = 1'b0;
            w = 0;
            while (!img_up_done && w < 16) begin
                @(posedge clk);
                w = w + 1;
            end
        end
    endtask

    // The second pattern, so a check can tell the direct upload's image from the
    // debugger upload's one in the same SDRAM.
    function [7:0] pat2(input integer n);
        begin
            pat2 = ((n * 8'h2B) ^ (n[13:8] + n[7:0]) ^ 8'h5C) & 8'hFF;
        end
    endfunction

    initial begin
        reset = 1'b1;
        rx_byte = 8'h00;
        rx_valid = 1'b0;
        repeat (8) @(posedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);

        // ==============================================================
        // 1. Enter the debugger and look at the drives
        // ==============================================================
        send_cmd(8'h02);
        check(dbg_mode === 1'b1, "Ctrl+B entered the debugger");
        skip_until("Debugger");
        $display("phase 1: in the debugger, drives empty");

        // Before anything is uploaded, neither drive holds an image, so both read
        // as write protected: this is what stops a format going nowhere.
        check(drv_present === 2'b00, "no drive holds an image before an upload");
        check(drv_writable === 2'b00, "an empty drive is write protected");

        // ==============================================================
        // 2. A whole image into drive 2 over the wire
        // ==============================================================
        acks = 0;
        upload(1, IMG_BYTES, 8'h00);
        $display("phase 2: full image uploaded over the wire");

        check(acks == IMG_BYTES / 4096, "one acknowledgement for every track sent");
        check(drv_present[1] === 1'b1, "drive 2 holds an image after a full upload");
        check(drv_present[0] === 1'b0, "an upload to drive 2 does not fill drive 1");
        check(drv_writable[1] === 1'b1, "a drive with an image is writable");

        // The fingerprint the host compares (web/src/disk.js diskChecksum): the
        // rotate-and-add of every byte sent, and 0 for the drive with no image.
        sum_exp = 32'd0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            sum_exp = {sum_exp[30:0], sum_exp[31]} + {24'd0, pat(i)};
        check(u_dbg.dsk_sum1 === sum_exp, "drive 2's checksum is the sum of what was sent");
        check(u_dbg.dsk_sum0 === 32'd0, "drive 1's checksum stays 0 while it is empty");

        // ...and the i command prints it: CRLF, I1:00000000 I2:, then 8 hex digits.
        send_cmd("i");
        expect_str({8'h0D, 8'h0A, "I1:00000000"});
        expect_str(" I2:");
        for (i = 7; i >= 0; i = i - 1) begin
            getbyte(gotb);
            check(gotb === ((sum_exp[4*i +: 4] < 10) ? 8'h30 + sum_exp[4*i +: 4]
                                                    : 8'h37 + sum_exp[4*i +: 4]),
                  "the i command prints drive 2's checksum digit by digit");
        end
        skip_until(">");

        // The image itself, read out of the SDRAM model rather than back down the
        // wire: the upload's own check is the acknowledgements above, and this one
        // says where the bytes landed.
        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            if (shadow[shadow_idx(1, i)] !== pat(i)) bad = bad + 1;
        check(bad == 0, "drive 2's image is byte for byte what was sent");

        // Nothing may have landed outside the drive.  The first IMG_BYTES bytes
        // are drive 1's image, which nothing was sent for.
        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            if (shadow[shadow_idx(0, i)] !== 8'h00) bad = bad + 1;
        check(bad == 0, "an upload to drive 2 does not spill into drive 1");

        // ==============================================================
        // 3. The first bytes of a download, in order
        // ==============================================================
        // What the wire is here for is the *order*: the store's word cache, and
        // which half of a word it takes the byte from, only show up on the way
        // out.  512 bytes is 256 words, which is plenty of both and 1.2 million
        // clocks rather than the 335 million a whole image costs.
        send_cmd("e");
        send_cmd("2");
        skip_until("DOWNLOAD");
        skip_to_eol;
        $display("phase 3: download started");
        bad = 0;
        for (i = 0; i < 512; i = i + 1) begin
            getbyte(gotb);
            if (gotb !== pat(i)) bad = bad + 1;
        end
        check(bad == 0, "the download gives back the image in order");

        // The transfer is still running, and there is no way to stop it: reset,
        // which is also what a host that has given up leaves the board needing.
        reset = 1'b1;
        repeat (8) @(posedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);
        send_cmd(8'h02);
        skip_until("Debugger");

        // ==============================================================
        // 4. A host that sends faster than the board can take
        // ==============================================================
        // The board has room for one byte in hand, so a host that offers bytes
        // faster than the store takes them loses some in the middle.  It must say
        // so and leave the drive empty: the alternative is an image with holes in
        // it that the board calls good, which DOS boots and then crashes on.
        send_cmd("d");
        send_cmd("1");
        skip_until("UPLOAD");
        skip_to_eol;
        $display("phase 4: fast host upload started");
        for (i = 0; i < IMG_BYTES; i = i + 1) begin
            @(negedge clk);
            rx_byte  = pat(i) ^ 8'h3C;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
        end
        skip_until("lost");
        skip_to_eol;
        $display("phase 4: fast host answered");
        repeat (200) @(posedge clk);
        check(drv_present[0] === 1'b0, "an upload that lost bytes leaves the drive empty");
        check(drv_writable[0] === 1'b0, "an upload that lost bytes leaves it protected");
        check(drv_present[1] === 1'b1, "the reset left drive 2's disk in (the image is still in DDR3)");
        check(u_dbg.dsk_sum0 === 32'd0, "an upload that lost bytes leaves no checksum");

        // n2 ejects drive 2: empty, and no checksum
        check(u_dbg.dsk_sum1 !== 32'd0, "drive 2 still has its checksum before the eject");
        send_cmd("n");
        send_cmd("2");
        repeat (200) @(posedge clk);
        check(drv_present[1] === 1'b0, "n2 empties drive 2");
        check(u_dbg.dsk_sum1 === 32'd0, "n2 clears drive 2's checksum");

        // ==============================================================
        // 5. Every address in the image, driven straight into the store
        // ==============================================================
        // The wire tests above prove the protocol; this proves the addressing
        // across the whole 143,360 bytes, which a short transfer cannot: the
        // store's row, column and half-bit arithmetic only shows up in the high
        // addresses, and a byte that lands one word out still reads back as
        // plausible data.  The debugger is idle here, so its outputs are zero and
        // the bench's OR onto the same pins is the only driver.
        for (i = 0; i < IMG_BYTES; i = i + 1) store_put(1'b0, i);
        while (img_up_busy) @(posedge clk);
        repeat (20) @(posedge clk);
        $display("phase 5: direct upload done");

        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            if (shadow[shadow_idx(0, i)] !== pat2(i)) bad = bad + 1;
        check(bad == 0, "the direct upload fills drive 1 byte for byte");
        check(drv_present[0] === 1'b1, "a direct upload also fills the drive");
        check(drv_writable[0] === 1'b1, "and it is writable");

        // Drive 2 still holds what the wire put in it, so the two images have not
        // overlapped.
        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            if (shadow[shadow_idx(1, i)] !== pat(i)) bad = bad + 1;
        check(bad == 0, "drive 2's image is untouched by the direct upload");

        if (fails == 0)
            $display("tb_diskimg: PASS (%0d checks)", checks);
        else
            $display("tb_diskimg: FAIL (%0d of %0d checks failed)", fails, checks);
        $finish;
    end

    // A watchdog, so a handshake that never completes says so instead of running
    // until the heat death of the universe.  The test is a few million clocks,
    // which at 37 ns each is a couple of hundred milliseconds of simulated time,
    // so half a second is generous and still bounded.
    initial begin
        #600000000;
        $display("tb_diskimg: FAIL (watchdog)");
        $display("  dbg_mode=%b main_state=%0d return_job=%0d str_pos=%0d str_cnt=%0d img_addr=%0d",
                 dbg_mode, u_dbg.main_state, u_dbg.return_job, u_dbg.str_pos,
                 u_dbg.str_cnt, u_dbg.img_addr);
        // What the board said last, which is usually the whole answer.
        while (q_rd + 60 < q_wr) q_rd = q_rd + 1;
        while (q_rd < q_wr) begin
            gotb = q[q_rd % 65536];
            $write("%c", (gotb >= 8'h20 && gotb < 8'h7F) ? gotb : 8'h2E);
            q_rd = q_rd + 1;
        end
        $write("\n");
        $finish;
    end

endmodule
