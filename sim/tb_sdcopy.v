`timescale 1ns / 1ps
`default_nettype none

// tb_sdcopy -- the debugger's TF card commands through src/sd_vol.v into
// sim/models/sdcard.v, holding the FAT32 card web/scripts/simcard.mjs builds
// (PRODOS~1.HDV, 16 blocks, in S7D1).
//
// u: the host writes the hard-disk file's first four sectors -- a data
// sector, a run of two zero sectors, a data sector, then 02.  Each record
// must be acked only once it is on the card, the sectors must hold exactly
// that and the write must end in "done"; y3 then remounts S7D1, and block 3,
// read once before the upload, must come back new (the upload drops
// sd_vol's remembered block).  b: two sectors come back raw after "SECTORS", then
// "done"; a read past the card's end says "lost".  i reports S:02A5 (FAT32,
// S6D2 and S7D2 failed, S6D1 and S7D1 present).  A bad u tag says "lost".
// The debugger's output is read off its TX FIFO's push port.
module tb_sdcopy;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;

    reg  [7:0] rx_byte  = 8'h00;
    reg        rx_valid = 1'b0;
    reg        rb_go    = 1'b0;           // sd_vol: slot 7 block 3 into the DDR3

    wire sd_clk, sd_mosi, sd_miso, sd_cs_n;
    sdcard #(.SECTORS(8192), .INIT("build/sim_card.hex")) card (
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso));

    wire        m_go, m_we;
    wire [24:0] m_addr;
    wire [15:0] m_wdata;
    reg  [15:0] m_rdata = 16'h0;
    reg         m_ack = 1'b0;
    wire [3:0]  present, fail;
    wire        fs_ok, loading, busy, err;
    wire [2:0]  estage;
    wire        x_go, x_zero, x_valid, x_take, mnt_go;
    wire [1:0]  mnt_drv;
    wire [31:0] x_lba, r_lba;
    wire [7:0]  x_byte, r_byte;
    wire        r_go, r_valid, r_take, r_done, r_ok;
    wire [15:0] r_cnt;
    // the store's up port only has to take bytes (S6D1 loads at boot)
    wire        f_up_go;
    reg         f_up_done = 1'b0;
    always @(posedge clk) f_up_done <= f_up_go && !f_up_done;

    sd_vol #(.PWR_BITS(8)) u_sd (
        .clk(clk), .reset(reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .ddr_ready(1'b1),
        .m_go(m_go), .m_addr(m_addr), .m_we(m_we), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack),
        .f_up_go(f_up_go), .f_up_drive(), .f_up_addr(), .f_up_data(), .f_up_last(), .f_up_bad(),
        .f_up_busy(f_up_done), .f_up_done(f_up_done), .f_dn_go(), .f_dn_drive(), .f_dn_addr(),
        .f_dn_data(8'd0), .f_dn_valid(1'b0),
        .fl_wr(1'b0), .fl_wr_drv(1'b0), .fl_wr_trk(6'd0), .bg_hold(1'b1),
        .present(present), .fail(fail), .fs_ok(fs_ok),
        .loading(loading), .busy(busy), .err(err), .estage(estage),
        .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd3), .rb_go(rb_go), .rb_ok(),
        .mnt_go(mnt_go), .mnt_drv(mnt_drv),
        .x_go(x_go), .x_lba(x_lba), .x_zero(x_zero),
        .x_byte(x_byte), .x_valid(x_valid), .x_take(x_take),
        .r_go(r_go), .r_lba(r_lba), .r_cnt(r_cnt), .r_byte(r_byte), .r_valid(r_valid),
        .r_take(r_take), .r_done(r_done), .r_ok(r_ok)
    );

    serial_debugger u_dbg (
        .clk(clk), .reset(reset), .ce_1m(1'b1), .uart_tx(),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .dbg_mode(), .cpu_rdy(), .cpu_reset_req(),
        .dbg_mem_addr(), .dbg_mem_din(8'h00), .dbg_mem_ready(1'b1), .dbg_aux(),
        .sd_mnt_go(mnt_go), .sd_mnt_drv(mnt_drv),
        .sd_stat({loading, busy, err, estage, fs_ok, 1'b0, fail, present}),
        .sd_x_go(x_go), .sd_x_lba(x_lba), .sd_x_zero(x_zero),
        .sd_x_byte(x_byte), .sd_x_valid(x_valid), .sd_x_take(x_take),
        .sd_r_go(r_go), .sd_r_lba(r_lba), .sd_r_cnt(r_cnt), .sd_r_byte(r_byte),
        .sd_r_valid(r_valid), .sd_r_take(r_take), .sd_r_done(r_done), .sd_r_ok(r_ok),
        .cpu_pc(16'hFA62), .dsk_head(8'd0), .cpu_a(8'h00), .cpu_x(8'h00), .cpu_y(8'h00),
        .cpu_s(8'hFF), .cpu_p(8'h20), .cpu_ir(8'h00), .cpu_addr(16'h0000), .cpu_dout(8'h00),
        .cpu_we(1'b0), .cpu_sync(1'b0),
        .text_mode(1'b1), .mixed_mode(1'b0), .page2(1'b0), .hires_mode(1'b0),
        .pll_locked(1'b1), .ddr_diag(32'd0)
    );

    // DDR3: two drives x 16 blocks
    reg [15:0] ddr [0:8191];
    reg        pend = 1'b0;
    reg [4:0]  t = 0;
    reg [24:0] a_q;
    reg        we_q;
    reg [15:0] d_q;
    integer fails = 0, i, b, k, n = 0, m;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (m_go) begin
            pend <= 1'b1; t <= 0; a_q <= m_addr; we_q <= m_we; d_q <= m_wdata;
        end else if (pend) begin
            t <= t + 1'b1;
            if (t == 5'd20) begin
                pend <= 1'b0; m_ack <= 1'b1;
                if (we_q) ddr[{a_q[24], a_q[11:0]}] <= d_q; else m_rdata <= ddr[{a_q[24], a_q[11:0]}];
            end
        end
    end

    // Everything the debugger queues for the UART
    reg [7:0] out [0:65535];
    always @(posedge clk) if (u_dbg.fifo_push_en) begin out[n] = u_dbg.fifo_push_byte; n = n + 1; end

    function [7:0] pat(input integer blk, input integer k);
        pat = (blk * 53 + k * 7 + (k >> 8)) | 8'h01;
    endfunction
    // the card's own contents: web/scripts/simcard.mjs, file 2
    function [7:0] orig(input integer o);
        orig = o * 7 + 2 * 13 + (o >> 9);
    endfunction

    task send(input [7:0] v);
        begin
            @(posedge clk); rx_byte <= v; rx_valid <= 1'b1;
            @(posedge clk); rx_valid <= 1'b0;
            repeat (270) @(posedge clk);       // 1 Mbps host: 270 clocks/byte, slower than the card
        end
    endtask
    function [7:0] hex(input [3:0] v); hex = v < 10 ? "0" + v : "A" + v - 10; endfunction
    task send_hex(input [31:0] v, input integer digits);
        integer d;
        for (d = digits - 1; d >= 0; d = d - 1) send(hex(v[4*d +: 4]));
    endtask

    task wait_idle;
        begin
            repeat (50) @(posedge clk);
            while (u_dbg.main_state != 4'd0) @(posedge clk);
            repeat (50) @(posedge clk);
        end
    endtask

    task wait_ack(input integer from);
        reg got;
        begin
            got = 1'b0;
            while (!got) begin
                for (k = from; k < n; k = k + 1) if (out[k] == 8'h06) got = 1'b1;
                if (!got) @(posedge clk);
            end
        end
    endtask

    // the first place `word` (its last `len` characters) appears at or after `from`, or -1
    function integer find(input [8*7-1:0] word, input integer len, input integer from);
        integer q, c;
        reg     ok;
        begin
            find = -1;
            for (q = from; q + len <= n && find < 0; q = q + 1) begin
                ok = 1'b1;
                for (c = 0; c < len; c = c + 1) if (out[q + c] != word[8*(len - 1 - c) +: 8]) ok = 1'b0;
                if (ok) find = q;
            end
        end
    endfunction

    integer acks, mark, lba, at;
    task read_block3;
        begin
            @(posedge clk); rb_go <= 1'b1;
            @(posedge clk); rb_go <= 1'b0;
            @(posedge clk); while (busy) @(posedge clk);
        end
    endtask
    initial begin
        for (i = 0; i < 8192; i = i + 1) ddr[i] = 16'hDEAD;
        #200; @(posedge clk); reset = 1'b0;
        @(posedge clk); while (loading) @(posedge clk);
        if (present !== 4'b0101 || err) begin $display("FAIL: after the boot present=%b err=%b", present, err); fails = fails + 1; end
        lba = u_sd.fstart[2];
        read_block3;                           // the old contents, remembered

        send(8'h02); wait_idle;                // into the debugger

        // ---- i ----
        mark = n; send("i"); wait_idle;
        if (find("S:02A5", 6, mark) < 0) begin $display("FAIL: i did not say S:02A5"); fails = fails + 1; end

        // ---- u: four sectors of the HD file ----
        mark = n;
        send("u"); send_hex(lba, 8);
        while (u_dbg.main_state != 4'd10) @(posedge clk);
        m = n; send(8'h01); for (k = 0; k < 512; k = k + 1) send(pat(0, k)); wait_ack(m);
        m = n; send(8'h00); send(8'h00); send(8'h01); wait_ack(m);          // sectors 1-2: zeros
        m = n; send(8'h01); for (k = 0; k < 512; k = k + 1) send(pat(3, k)); wait_ack(m);
        send(8'h02);
        wait_idle;
        acks = 0; for (k = mark; k < n; k = k + 1) if (out[k] == 8'h06) acks = acks + 1;
        if (acks != 3) begin $display("FAIL: %0d acks, want 3", acks); fails = fails + 1; end
        if (find("done", 4, mark) < 0) begin $display("FAIL: no done"); fails = fails + 1; end
        for (b = 0; b < 5; b = b + 1)
            for (k = 0; k < 512; k = k + 1)
                if (card.mem[(lba + b) * 512 + k] !== ((b == 0 || b == 3) ? pat(b, k) :
                                                       b == 4 ? orig(b * 512 + k) : 8'h00)) begin
                    if (fails < 10) $display("FAIL: sector %0d byte %0d = %02x", b, k, card.mem[(lba + b) * 512 + k]);
                    fails = fails + 1;
                end

        // ---- y3: S7D1 remounted, block 3 reads the new contents ----
        send("y"); send("3"); wait_idle;
        @(posedge clk); while (busy) @(posedge clk);
        read_block3;
        if (present !== 4'b0101) begin $display("FAIL: S7D1 not reloaded (present %b)", present); fails = fails + 1; end
        for (k = 0; k < 512; k = k + 1)
            if ((k[0] ? ddr[{1'b0, 4'd3, k[8:1]}][15:8] : ddr[{1'b0, 4'd3, k[8:1]}][7:0]) !== pat(3, k)) begin
                if (fails < 10) $display("FAIL: S7D1's DDR3 block 3 byte %0d is stale", k);
                fails = fails + 1;
            end

        // ---- b: two sectors back ----
        mark = n;
        send("b"); send_hex(lba + 2, 8); send_hex(2, 4);
        wait_idle;
        at = find("SECTORS", 7, mark);
        if (at < 0) begin $display("FAIL: b did not say SECTORS"); fails = fails + 1; end
        else begin
            at = at + 9;                       // past CR LF
            for (k = 0; k < 1024; k = k + 1)
                if (out[at + k] !== card.mem[(lba + 2) * 512 + k]) begin
                    if (fails < 10) $display("FAIL: b byte %0d = %02x", k, out[at + k]);
                    fails = fails + 1;
                end
            if (find("done", 4, at + 1024) != at + 1024 + 2) begin $display("FAIL: b did not end in done"); fails = fails + 1; end
        end
        mark = n;
        send("b"); send_hex(9000, 8); send_hex(1, 4);
        wait_idle;
        if (find("lost", 4, mark) < 0) begin $display("FAIL: b past the end did not say lost"); fails = fails + 1; end
        if (err) begin $display("FAIL: b past the end set err"); fails = fails + 1; end

        // ---- a bad tag ----
        mark = n;
        send("u"); send_hex(lba, 8);
        while (u_dbg.main_state != 4'd10) @(posedge clk);
        send(8'h07);
        wait_idle;
        if (find("lost", 4, mark) < 0) begin $display("FAIL: a bad tag did not say lost"); fails = fails + 1; end
        if (card.errs != 0) begin $display("FAIL: %0d card protocol errors", card.errs); fails = fails + 1; end

        if (fails == 0) $display("tb_sdcopy: PASS");
        else            $display("tb_sdcopy: FAIL (%0d)", fails);
        $finish;
    end

    initial begin #2_000_000_000; $display("FAIL: timeout (ph=%0d st=%0d)", u_dbg.x_ph, u_sd.st); $finish; end
endmodule
