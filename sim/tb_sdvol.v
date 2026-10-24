`timescale 1ns / 1ps
`default_nettype none

// tb_sdvol -- src/sd_vol.v against sim/models/sdcard.v holding a FAT32 card
// built by the page's own FAT code (web/scripts/simcard.mjs, build/sim_card.hex),
// a behavioural DDR3 port and a behavioural disk2_store byte port.
//
// From reset: the card comes up, A2CONFIG.TXT is found in a root directory
// that runs past one cluster, and the four names it gives are looked up:
// GAME.WOZ (S6D1) loads into the store byte for byte but for its zeroed CRC,
// FRAG.WOZ (S6D2) is fragmented and MISSING.HDV (S7D2) is not on the card, so
// both fail, and PRODOS~1.HDV (S7D1, 16 blocks) is found but not loaded.  Then:
// a block asked for (rb_go) is read into the DDR3, asking again does not
// touch the card, one past the file's end or on an empty drive fails
// (rb_ok = 0), a block written back lands in the file's sector, one past
// the file's end is dropped, reading the block just written does not touch
// the card, the blocks of a .woz the Apple wrote (lowest to highest, then
// block 0 once, for the CRC) go back to the file once the drive is quiet, a
// second write sends only its own block, the raw read hands over a file's sectors,
// a read past the card's end only answers r_ok = 0, and a reload of S6D1
// ejects it from the store and loads it again with what was written.  In
// S6D2: a file that is not WOZ2 and a .DSK are refused, and a write-protected
// .woz says so with its last byte.  A second instance with no
// card must give up (err) and drop `loading`, so a missing card cannot hold
// the CPU.
module tb_sdvol;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;

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
    reg         wb_go = 1'b0, wb_drv = 1'b0, mnt_go = 1'b0, rb_go = 1'b0;
    wire        rb_ok;
    reg  [1:0]  mnt_drv = 2'd0;
    reg  [15:0] wb_blk = 16'd0;
    reg         fl_wr = 1'b0;
    reg  [10:0] fl_wr_blk = 11'd0;
    reg         r_go = 1'b0, r_take = 1'b0;
    reg  [31:0] r_lba = 32'd0;
    reg  [15:0] r_cnt = 16'd0;
    wire [7:0]  r_byte;
    wire        r_valid, r_done, r_ok;
    wire        f_up_go, f_up_drive, f_up_last, f_up_ro, f_up_bad, f_dn_go, f_dn_drive;
    wire [19:0] f_up_addr, f_dn_addr;
    wire [7:0]  f_up_data;
    reg         f_up_done = 1'b0, f_dn_valid = 1'b0;
    reg  [7:0]  f_dn_data = 8'h00;

    sd_vol #(.PWR_BITS(8), .QUIET_BITS(12)) dut (
        .clk(clk), .reset(reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .ddr_ready(1'b1),
        .m_go(m_go), .m_addr(m_addr), .m_we(m_we), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack),
        .f_up_go(f_up_go), .f_up_drive(f_up_drive), .f_up_addr(f_up_addr), .f_up_data(f_up_data),
        .f_up_last(f_up_last), .f_up_ro(f_up_ro), .f_up_bad(f_up_bad), .f_up_busy(f_up_done), .f_up_done(f_up_done),
        .f_dn_go(f_dn_go), .f_dn_drive(f_dn_drive), .f_dn_addr(f_dn_addr),
        .f_dn_data(f_dn_data), .f_dn_valid(f_dn_valid),
        .fl_wr(fl_wr), .fl_wr_drv(1'b0), .fl_wr_blk(fl_wr_blk), .bg_hold(1'b0),
        .present(present), .fail(fail), .fs_ok(fs_ok),
        .loading(loading), .busy(busy), .err(err), .estage(estage),
        .wb_go(wb_go), .wb_drv(wb_drv), .wb_blk(wb_blk),
        .rb_go(rb_go), .rb_ok(rb_ok),
        .mnt_go(mnt_go), .mnt_drv(mnt_drv),
        .x_go(1'b0), .x_lba(32'd0), .x_zero(1'b0), .x_byte(8'd0), .x_valid(1'b0), .x_take(),
        .r_go(r_go), .r_lba(r_lba), .r_cnt(r_cnt), .r_byte(r_byte), .r_valid(r_valid),
        .r_take(r_take), .r_done(r_done), .r_ok(r_ok)
    );

    // No card: MISO floats high through the pull-up
    wire        n_loading, n_err;
    sd_vol #(.PWR_BITS(8)) nocard (
        .clk(clk), .reset(reset),
        .sd_clk(), .sd_mosi(), .sd_miso(1'b1), .sd_cs_n(),
        .ddr_ready(1'b1),
        .m_go(), .m_addr(), .m_we(), .m_wdata(), .m_rdata(16'h0), .m_ack(1'b0),
        .f_up_go(), .f_up_drive(), .f_up_addr(), .f_up_data(), .f_up_last(), .f_up_ro(), .f_up_bad(),
        .f_up_busy(1'b0), .f_up_done(1'b0), .f_dn_go(), .f_dn_drive(), .f_dn_addr(),
        .f_dn_data(8'd0), .f_dn_valid(1'b0),
        .fl_wr(1'b0), .fl_wr_drv(1'b0), .fl_wr_blk(11'd0), .bg_hold(1'b0),
        .present(), .fail(), .fs_ok(), .loading(n_loading), .busy(),
        .err(n_err), .estage(),
        .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd0), .rb_go(1'b0), .rb_ok(),
        .mnt_go(1'b0), .mnt_drv(2'd0),
        .x_go(1'b0), .x_lba(32'd0), .x_zero(1'b0), .x_byte(8'd0), .x_valid(1'b0), .x_take(),
        .r_go(1'b0), .r_lba(32'd0), .r_cnt(16'd0), .r_byte(), .r_valid(), .r_take(1'b0),
        .r_done(), .r_ok()
    );

    // DDR3: drive x 16 blocks x 256 words; a slow-ish answer, random waits
    reg [15:0] ddr [0:8191];
    function [12:0] di(input [24:0] a); di = {a[24], a[11:0]}; endfunction  // drive, block[3:0], word
    reg        pend = 1'b0;
    reg [4:0]  t = 0;
    reg [24:0] a_q;
    reg        we_q;
    reg [15:0] d_q;
    integer fails = 0, i, b, o, s, at, ups = 0, bads = 0;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (m_go) begin
            if (pend) begin $display("FAIL: request while one is out"); fails = fails + 1; end
            if (m_addr[23:12] != 12'd0) begin $display("FAIL: block %0d past the bench's 16", m_addr[23:8]); fails = fails + 1; end
            pend <= 1'b1; t <= 0; a_q <= m_addr; we_q <= m_we; d_q <= m_wdata;
        end else if (pend) begin
            t <= t + 1'b1;
            if (t == 5'd20 + ($random & 5'd7)) begin
                pend <= 1'b0; m_ack <= 1'b1;
                if (we_q) ddr[di(a_q)] <= d_q; else m_rdata <= ddr[di(a_q)];
            end
        end
    end

    // disk2_store's byte ports: two drives' files, byte for byte (256 KB each here)
    reg [7:0] fl [0:2*262144-1];
    reg [1:0] fl_present = 2'b00, fl_ro = 2'b00;
    always @(posedge clk) begin
        if (!f_up_go) f_up_done <= 1'b0;
        else if (!f_up_done && ($random & 3) == 0) begin
            f_up_done <= 1'b1; ups = ups + 1;
            if (f_up_addr >= 20'd262144) begin $display("FAIL: store byte %0d past the bench's 256 KB", f_up_addr); fails = fails + 1; end
            fl[{f_up_drive, f_up_addr[17:0]}] <= f_up_data;
            if (f_up_last) begin fl_present[f_up_drive] <= 1'b1; fl_ro[f_up_drive] <= f_up_ro; end
        end
        if (f_up_bad) begin fl_present[f_up_drive] <= 1'b0; bads = bads + 1; end
        if (!f_dn_go) f_dn_valid <= 1'b0;
        else if (!f_dn_valid && ($random & 3) == 0) begin
            f_dn_valid <= 1'b1; f_dn_data <= fl[{f_dn_drive, f_dn_addr[17:0]}];
        end
    end

    function [7:0] pat(input integer id, input integer o);
        pat = o * 7 + id * 13 + (o >> 9);
    endfunction
    task check(input cond, input [8*64-1:0] what);
        if (!cond) begin $display("FAIL: %0s", what); fails = fails + 1; end
    endtask
    task wait_idle; begin @(posedge clk); while (busy) @(posedge clk); end endtask
    // ask for slot 7 block bk of drive dv; `want` is whether the card is read
    task rb(input dv, input [15:0] bk, input want_ok, input want_read, input [8*48-1:0] what);
        begin
            i = card.r17s;
            @(posedge clk); rb_go <= 1'b1; wb_drv <= dv; wb_blk <= bk;
            @(posedge clk); rb_go <= 1'b0;
            wait_idle;
            check(rb_ok === want_ok, what);
            check(card.r17s == i + want_read, what);
        end
    endtask
    task check_hd_block(input integer bk);
        for (o = 0; o < 512; o = o + 1)
            if ((o[0] ? ddr[{1'b0, bk[3:0], o[8:1]}][15:8] : ddr[{1'b0, bk[3:0], o[8:1]}][7:0]) !== pat(2, bk * 512 + o)) begin
                if (fails < 10) $display("FAIL: HD block %0d byte %0d", bk, o);
                fails = fails + 1;
            end
    endtask
    // the store holds drive d's file as the card has it, CRC (bytes 8-11) zeroed
    task check_floppy(input integer d);
        begin
            s = dut.fstart[d];
            for (o = 0; o < dut.fsize[d]; o = o + 1)
                if (fl[d * 262144 + o] !== ((o >= 8 && o <= 11) ? 8'h00 : card.mem[s * 512 + o])) begin
                    if (fails < 10) $display("FAIL: floppy %0d byte %0d = %02x, want %02x", d, o, fl[d * 262144 + o], card.mem[s * 512 + o]);
                    fails = fails + 1;
                end
        end
    endtask
    // the config's name for drive key "s6d2" (as simcard writes it, lower case) -> an 8-byte name
    task set_s6d2(input [8*8-1:0] nm8);
        begin
            s = dut.data_lba + ((dut.fclus[4] - 2) << dut.spc_log);   // A2CONFIG.TXT
            at = -1;
            for (o = 0; o < 500; o = o + 1)
                if (card.mem[s * 512 + o] == "s" && card.mem[s * 512 + o + 1] == "6" &&
                    card.mem[s * 512 + o + 3] == "2") at = o + 7;            // "s6d2 = "
            check(at > 0, "S6D2 not found in the config");
            for (o = 0; o < 8; o = o + 1) card.mem[s * 512 + at + o] = (nm8 >> (8 * (7 - o))) & 8'hFF;
            @(posedge clk); mnt_go <= 1'b1; mnt_drv <= 2'd1;
            @(posedge clk); mnt_go <= 1'b0;
            @(posedge clk); while (!loading) @(posedge clk);
            while (loading) @(posedge clk);
        end
    endtask

    reg [7:0] got [0:1023];
    integer   ngot;
    initial begin
        for (i = 0; i < 8192; i = i + 1) ddr[i] = 16'hDEAD;
        #200; @(posedge clk); reset = 1'b0;

        // ---- power-on lookup and load ----
        @(posedge clk); while (loading) @(posedge clk);
        check(!err, "err after the boot load");
        check(fs_ok, "FAT32 not recognised");
        check(present === 4'b0101, "present after the load (want S6D1 and S7D1)");
        check(fail === 4'b1010, "fail after the load (want FRAG.PO and MISSING.HDV)");
        check(fl_present === 2'b01 && fl_ro[0] === 1'b0, "store present, writable");
        check(dut.fstart[1] == 0, "a fragmented file got a start");
        check(card.mem[dut.fstart[0] * 512 + 8] !== 8'h00 || card.mem[dut.fstart[0] * 512 + 9] !== 8'h00,
              "the card's own file has its CRC");
        check_floppy(0);
        for (i = 0; i < 8192; i = i + 1)
            if (ddr[i] !== 16'hDEAD) begin
                if (fails < 10) $display("FAIL: DDR3 word %0d written by the boot (slot 7 is read on demand)", i);
                fails = fails + 1;
            end
        $display("load: %0t ns, floppy at LBA %0d, HD at LBA %0d", $time, dut.fstart[0], dut.fstart[2]);

        // ---- slot 7 blocks on demand ----
        rb(1'b0, 16'd3,  1'b1, 1'b1, "block 3 not read from the card");
        check_hd_block(3);
        rb(1'b0, 16'd3,  1'b1, 1'b0, "block 3 asked again went to the card");
        rb(1'b0, 16'd16, 1'b0, 1'b0, "a block past the file's end");
        rb(1'b1, 16'd0,  1'b0, 1'b0, "a block of the empty drive");
        rb(1'b0, 16'd15, 1'b1, 1'b1, "block 15 not read from the card");
        check_hd_block(15);
        rb(1'b0, 16'd3,  1'b1, 1'b1, "block 3 after 15 not read again");

        // ---- slot 7 write-back: block 2, then one past the end ----
        for (i = 0; i < 256; i = i + 1) ddr[{1'b0, 4'd2, i[7:0]}] = {i[7:0] ^ 8'h5A, i[7:0]};
        @(posedge clk); wb_go <= 1'b1; wb_drv <= 1'b0; wb_blk <= 16'd2;
        @(posedge clk); wb_go <= 1'b0;
        wait_idle;
        s = dut.fstart[2] + 2;
        for (o = 0; o < 512; o = o + 1)
            if (card.mem[s * 512 + o] !== (o[0] ? (o[8:1] ^ 8'h5A) : o[8:1])) begin
                if (fails < 10) $display("FAIL: written-back byte %0d = %02x", o, card.mem[s * 512 + o]);
                fails = fails + 1;
            end
        check(card.mem[(s - 1) * 512] === pat(2, 512) && card.mem[(s + 1) * 512] === pat(2, 3 * 512),
              "write-back touched a neighbouring sector");
        i = card.wblks;
        @(posedge clk); wb_go <= 1'b1; wb_blk <= 16'd16;
        @(posedge clk); wb_go <= 1'b0;
        wait_idle;
        check(card.wblks == i, "a block past the file's end was written");
        rb(1'b0, 16'd16, 1'b0, 1'b0, "a block past the end after its write-back");
        // the last write was block 16 (dropped); write block 2 again, then read it
        @(posedge clk); wb_go <= 1'b1; wb_blk <= 16'd2;
        @(posedge clk); wb_go <= 1'b0;
        wait_idle;
        rb(1'b0, 16'd2, 1'b1, 1'b0, "the block just written was read from the card");

        // ---- floppy write-back: the Apple wrote blocks 10 and 12 ----
        for (o = 10 * 512; o < 13 * 512; o = o + 1) fl[o] = o ^ 8'hC3;
        @(posedge clk); fl_wr <= 1'b1; fl_wr_blk <= 11'd12;
        @(posedge clk); fl_wr_blk <= 11'd10;
        @(posedge clk); fl_wr <= 1'b0;
        i = card.wblks;
        repeat (6000) @(posedge clk);   // past QUIET_BITS
        wait_idle;
        check(card.wblks == i + 4, "not blocks 10-12 and block 0 back on the card");
        s = dut.fstart[0];
        for (o = 10 * 512; o < 13 * 512; o = o + 1)
            if (card.mem[s * 512 + o] !== (o ^ 8'hC3) % 256) begin
                if (fails < 10) $display("FAIL: written byte %0d on the card = %02x", o, card.mem[s * 512 + o]);
                fails = fails + 1;
            end
        check(card.mem[s * 512 + 8] === 8'h00 && card.mem[s * 512 + 11] === 8'h00, "the file's CRC is not zeroed");
        check(card.mem[s * 512] === "W" && card.mem[s * 512 + 12] === "I", "block 0 is not the file's own");
        check(card.mem[s * 512 + 9 * 512 + 5] === fl[9 * 512 + 5] && card.mem[s * 512 + 13 * 512] === fl[13 * 512],
              "a neighbouring block changed");
        // a second write: its block alone (block 0 is done)
        fl[20 * 512 + 7] = 8'h5A;
        @(posedge clk); fl_wr <= 1'b1; fl_wr_blk <= 11'd20;
        @(posedge clk); fl_wr <= 1'b0;
        i = card.wblks;
        repeat (6000) @(posedge clk);
        wait_idle;
        check(card.wblks == i + 1 && card.mem[s * 512 + 20 * 512 + 7] === 8'h5A, "the second write-back");

        // ---- raw read: the HD file's first two sectors ----
        ngot = 0;
        fork
            begin
                @(posedge clk); r_go <= 1'b1; r_lba <= dut.fstart[2]; r_cnt <= 16'd2;
                @(posedge clk); r_go <= 1'b0;
                @(posedge clk); while (!r_done) @(posedge clk);
            end
            begin : take
                forever begin
                    @(posedge clk); r_take <= 1'b0;
                    if (r_valid && !r_take && ($random & 7) == 0) begin
                        got[ngot] = r_byte; ngot = ngot + 1; r_take <= 1'b1;
                    end
                    if (ngot == 1024) disable take;
                end
            end
        join
        check(r_ok, "raw read not ok");
        check(ngot == 1024, "raw read byte count");
        for (o = 0; o < 1024; o = o + 1)
            if (got[o] !== card.mem[dut.fstart[2] * 512 + o]) begin
                if (fails < 10) $display("FAIL: raw byte %0d", o);
                fails = fails + 1;
            end
        // past the card's end: an answer, not an error
        @(posedge clk); r_go <= 1'b1; r_lba <= 32'd9000; r_cnt <= 16'd1;
        @(posedge clk); r_go <= 1'b0;
        @(posedge clk); while (!r_done) @(posedge clk);
        check(!r_ok, "a read past the card's end said ok");
        check(!err && present === 4'b0101, "a read past the card's end broke something");
        // ...and a run (CMD18) that fails: the card must still answer after it
        @(posedge clk); r_go <= 1'b1; r_lba <= 32'd9000; r_cnt <= 16'd4;
        @(posedge clk); r_go <= 1'b0;
        @(posedge clk); while (!r_done) @(posedge clk);
        check(!r_ok, "a run past the card's end said ok");
        ngot = 0;
        fork
            begin
                @(posedge clk); r_go <= 1'b1; r_lba <= dut.fstart[2]; r_cnt <= 16'd1;
                @(posedge clk); r_go <= 1'b0;
                @(posedge clk); while (!r_done) @(posedge clk);
            end
            begin : take2
                forever begin
                    @(posedge clk); r_take <= 1'b0;
                    if (r_valid && !r_take) begin ngot = ngot + 1; r_take <= 1'b1; end
                    if (ngot == 512) disable take2;
                end
            end
        join
        check(r_ok && ngot == 512 && !err, "a read after a failed run did not work");

        // ---- reload S6D1 ----
        i = bads;
        for (o = 0; o < 143360; o = o + 1) fl[o] = 8'h00;
        @(posedge clk); mnt_go <= 1'b1; mnt_drv <= 2'd0;
        @(posedge clk); mnt_go <= 1'b0;
        @(posedge clk); while (!loading) @(posedge clk);
        while (loading) @(posedge clk);
        check(bads == i + 1, "the reload did not eject the old disk");
        check(present === 4'b0101 && fail === 4'b1010, "present/fail after the reload");
        check(fl[11 * 512 + 3] === (11 * 512 + 3 ^ 8'hC3) % 256 && fl[20 * 512 + 7] === 8'h5A,
              "the reload did not read the written-back blocks");
        check_floppy(0);

        // ---- a .WOZ named for slot 7 is refused: it is not blocks ----
        s = dut.data_lba + ((dut.fclus[4] - 2) << dut.spc_log);   // A2CONFIG.TXT
        at = -1;
        for (o = 0; o < 500; o = o + 1)
            if (card.mem[s * 512 + o] == "S" && card.mem[s * 512 + o + 1] == "7" &&
                card.mem[s * 512 + o + 3] == "2") at = o + 5;
        check(at > 0, "S7D2 not found in the config");
        for (o = 0; o < 11; o = o + 1) card.mem[s * 512 + at + o] = ("GAME.WOZ   " >> (8 * (10 - o))) & 8'hFF;
        @(posedge clk); mnt_go <= 1'b1; mnt_drv <= 2'd3;
        @(posedge clk); mnt_go <= 1'b0;
        @(posedge clk); while (!loading) @(posedge clk);
        while (loading) @(posedge clk);
        check(present[3] === 1'b0 && fail[3] === 1'b1, "a .WOZ was loaded as a slot 7 volume");

        // ---- slot 6: not WOZ2, not .WOZ, write protected ----
        set_s6d2("JUNK.WOZ");
        check(present[1] === 1'b0 && fail[1] === 1'b1 && fl_present[1] === 1'b0, "a file that is not WOZ2 was loaded");
        set_s6d2("RAW.DSK ");
        check(present[1] === 1'b0 && fail[1] === 1'b1, "a .DSK was loaded into slot 6");
        set_s6d2("PROT.WOZ");
        check(present[1] === 1'b1 && fl_present[1] === 1'b1 && fl_ro[1] === 1'b1, "PROT.WOZ: loaded, write protected");
        check_floppy(1);

        // ---- no card ----
        while (n_loading) @(posedge clk);
        check(n_err, "no card: err not set");
        check(card.errs == 0, "card model protocol errors");

        if (fails == 0) $display("PASS");
        else $display("FAIL: %0d errors", fails);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule

`default_nettype wire
