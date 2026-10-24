// tb_sd_files: the file-level SD controller (sd_files on fat32) driven the way the debugger does,
// against sim/models/sdcard.v holding an empty FAT32 volume.  Small images (D2_BYTES / HD_BYTES
// parameters) keep it quick.  Checks: put (long names), list, mount onto Disk II drive 1 and
// ProDOS HD drive 1 (store contents), the slot report, get (round trip), delete / rename refused
// while mounted, rename and delete of an unmounted file, HD write-back into the file, and that a
// reset re-mounts both images from TN20K.CFG.
`timescale 1ns/1ps
module tb_sd_files;
    localparam D2 = 4096, HD = 4096;
    localparam PART = 100, FAT1 = 132, FAT2 = 140, DATA = 148;
    reg clk = 0, reset = 1;
    always #18.5 clk = ~clk;

    wire sd_clk, sd_mosi, sd_cs_n, sd_miso;
    reg  f_start = 0, f_rx_valid = 0; reg [7:0] f_rx_byte = 0;
    wire f_tx_valid, f_active; wire [7:0] f_tx_byte;
    wire d2_own, d2_up_go, hd_own, hd_up_go, up_drive, up_last, hd_dn_go, wr_ack, rpt_tx, rpt_busy;
    wire [20:0] up_addr, hd_dn_addr; wire [7:0] up_data;
    reg  d2_up_done = 0, hd_up_done = 0, wr_req = 0, hd_dn_valid = 0;
    reg  [11:0] wr_blk = 0; reg [7:0] hd_dn_data = 0;
    sd_files #(.PWR_BITS(6), .D2_BYTES(D2), .HD_BYTES(HD), .RPT_BITS(14)) dut (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .f_start(f_start), .f_rx_valid(f_rx_valid), .f_rx_byte(f_rx_byte),
        .f_tx_valid(f_tx_valid), .f_tx_byte(f_tx_byte), .f_tx_ready(1'b1), .f_active(f_active),
        .d2_own(d2_own), .d2_up_go(d2_up_go), .hd_own(hd_own), .hd_up_go(hd_up_go), .up_drive(up_drive),
        .up_addr(up_addr), .up_data(up_data), .up_last(up_last),
        .d2_up_busy(1'b0), .d2_up_done(d2_up_done), .hd_up_busy(1'b0), .hd_up_done(hd_up_done),
        .wr_req(wr_req), .wr_blk(wr_blk), .wr_ack(wr_ack), .hd_dn_go(hd_dn_go), .hd_dn_addr(hd_dn_addr),
        .hd_dn_data(hd_dn_data), .hd_dn_valid(hd_dn_valid), .rpt_tx(rpt_tx), .rpt_busy(rpt_busy));
    sdcard #(.SECTORS(1024)) card (.sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso));

    integer errs = 0, i, j;
    task bad(input [8*48-1:0] msg); begin errs = errs + 1; $display("FAIL: %0s", msg); end endtask

    // ---- the volume: empty root ----
    task put32(input integer a, input [31:0] v);
        begin card.mem[a] = v[7:0]; card.mem[a+1] = v[15:8]; card.mem[a+2] = v[23:16]; card.mem[a+3] = v[31:24]; end
    endtask
    task build;
        begin
            for (i = 0; i < 1024*512; i = i + 1) card.mem[i] = 0;
            card.mem[446+4] = 8'h0C; put32(446+8, PART); card.mem[510] = 8'h55; card.mem[511] = 8'hAA;
            card.mem[PART*512+12] = 2; card.mem[PART*512+13] = 2; card.mem[PART*512+14] = 32; card.mem[PART*512+16] = 2;
            put32(PART*512+36, 8); put32(PART*512+44, 2);
            for (i = 0; i < 2; i = i + 1) begin
                put32((i ? FAT2 : FAT1)*512 + 0, 32'h0FFFFFF8); put32((i ? FAT2 : FAT1)*512 + 4, 32'h0FFFFFFF);
                put32((i ? FAT2 : FAT1)*512 + 8, 32'h0FFFFFFF);
            end
        end
    endtask

    // ---- the stores: Disk II drives 1/2 and ProDOS HD drives 1/2 ----
    reg [7:0] d2mem [0:2*D2-1];
    reg [7:0] hdmem [0:2*HD-1];
    reg [7:0] hdwb  [0:HD-1];                 // what the //e "wrote" for the write-back test
    integer d2lasts = 0, hdlasts = 0, dropped = 0;
    always @(posedge clk) begin
        d2_up_done <= 0; hd_up_done <= 0;
        if (d2_up_go) begin
            if (dropped == 0) dropped = 1;                       // the first push is dropped: it must be resent
            else begin d2_up_done <= 1; d2mem[up_drive*D2 + up_addr] <= up_data; if (up_last) d2lasts = d2lasts + 1; end
        end
        if (hd_up_go) begin hd_up_done <= 1; hdmem[up_drive*HD + up_addr] <= up_data; if (up_last) hdlasts = hdlasts + 1; end
    end
    reg [20:0] dna; reg [2:0] dnp = 0;
    always @(posedge clk) begin
        hd_dn_valid <= 0;
        if (hd_dn_go) begin dnp <= 3'b100; dna <= hd_dn_addr; end
        else if (dnp) begin dnp <= dnp >> 1; if (dnp == 3'b001) begin hd_dn_valid <= 1; hd_dn_data <= hdwb[dna]; end end
    end

    // ---- the host side ----
    reg [7:0] tlog [0:65535]; integer tn = 0;
    always @(posedge clk) if (f_tx_valid) begin tlog[tn] = f_tx_byte; tn = tn + 1; end
    task hb(input [7:0] b);
        begin @(posedge clk); #1 f_rx_byte = b; f_rx_valid = 1; @(posedge clk); #1 f_rx_valid = 0; repeat (8) @(posedge clk); end
    endtask
    function [7:0] pat(input integer n, input integer w); pat = n * 7 + w * 13 + (n >> 8); endfunction
    // where file byte i of a DOS-order floppy file lands in the (physical-order) store
    function integer d2idx(input integer i);
        integer ls; reg [63:0] tbl;
        begin
            tbl = 64'h0_7_E_6_D_5_C_4_B_3_A_2_9_1_8_F;
            ls = (i % 4096) / 256;
            d2idx = (i / 4096) * 4096 + tbl[4*(15-ls) +: 4] * 256 + i % 256;
        end
    endfunction
    function tail_is(input [8*8-1:0] s, input integer len);
        integer q; reg ok;
        begin ok = (tn >= len); for (q = 0; q < len && ok; q = q + 1) if (tlog[tn - len + q] !== s[8*(len-1-q) +: 8]) ok = 0; tail_is = ok; end
    endfunction
    function find_after(input integer mark, input [8*40-1:0] s, input integer len);    // s occurs after tlog[mark]
        integer p, q; reg ok;
        begin
            find_after = 0;
            for (p = mark; p + len <= tn; p = p + 1) begin
                ok = 1; for (q = 0; q < len; q = q + 1) if (tlog[p + q] !== s[8*(len-1-q) +: 8]) ok = 0;
                if (ok) find_after = 1;
            end
        end
    endfunction
    integer mark, t, lastn;
    // the waits look at the log only when it has grown (scanning it every clock made the bench crawl)
    task wait_done(input integer m);                           // until "OK" or an ERR line after m
        reg dn;
        begin
            dn = 0; lastn = -1; t = 0;
            while (!dn && t < 3_000_000) begin
                @(posedge clk); t = t + 1;
                if (tn != lastn) begin lastn = tn; dn = (tn > m) && (tail_is("OK\n", 3) || (tail_is("\n", 1) && find_after(m, "ERR ", 4))); end
            end
            if (!dn) bad("timeout waiting for a reply");
        end
    endtask
    task wait_text(input integer m, input [8*16-1:0] s, input integer len);     // until s (or an error) appears after m
        reg dn;
        begin
            dn = 0; lastn = -1; t = 0;
            while (!dn && t < 3_000_000) begin
                @(posedge clk); t = t + 1;
                if (tn != lastn) begin lastn = tn; dn = find_after(m, s, len) || find_after(m, "ERR ", 4); end
            end
            if (!dn) bad("timeout waiting for text");
        end
    endtask
    task wait_ack;
        reg dn;
        begin
            dn = 0; lastn = -1; t = 0;
            while (!dn && t < 3_000_000) begin
                @(posedge clk); t = t + 1;
                if (tn != lastn) begin lastn = tn; dn = (tn > mark && tlog[tn-1] == 8'h06); end
            end
            if (!dn) bad("no ack");
        end
    endtask
    task put_file(input [8*40-1:0] name, input integer nlen, input integer size, input integer w);
        integer c, n, rem;
        begin
            mark = tn; hb("P"); hb(nlen);
            for (c = 0; c < nlen; c = c + 1) hb(name[8*(nlen-1-c) +: 8]);
            hb(size[7:0]); hb(size[15:8]); hb(size[23:16]); hb(size[31:24]);
            wait_text(mark, "GO\n", 3);
            if (find_after(mark, "ERR ", 4)) bad("put refused");
            else begin
                n = 0;
                while (n < size) begin
                    mark = tn;
                    rem = size - n; if (rem > 512) rem = 512;
                    for (c = 0; c < rem; c = c + 1) hb(pat(n + c, w));
                    n = n + rem;
                    wait_ack;
                end
                wait_done(mark);
                if (!tail_is("OK\n", 3)) bad("put did not end OK");
            end
        end
    endtask
    task cmd1(input [7:0] c);
        begin mark = tn; hb(c); wait_done(mark); end
    endtask
    task start_session;
        begin
            mark = tn; f_start = 1; @(posedge clk); #1 f_start = 0;
            wait_text(mark, "FILES\n", 6);
        end
    endtask

    integer k0, lm;
    reg [8*21-1:0] rn = "renamed note file.txt";
    initial begin
        build;
        #200 reset = 0;
        // ---- boot: no CFG, nothing to mount ----
        start_session;
        // ---- put two images and a small file, with long names ----
        put_file("disk one.dsk", 12, D2, 1);
        put_file("Another Long Name.po", 20, HD, 2);
        put_file("note.txt", 8, 700, 3);
        put_file("phys order.po", 13, D2, 4);
        lm = tn; cmd1("L");
        if (!find_after(lm, "F\t00\t00001000\tdisk one.dsk\n", 27)) bad("list entry 0");
        if (!find_after(lm, "F\t01\t00001000\tAnother Long Name.po\n", 35)) bad("list entry 1");
        if (!find_after(lm, "F\t02\t000002BC\tnote.txt\n", 23)) bad("list entry 2");
        if (!find_after(lm, "F\t03\t00001000\tphys order.po\n", 28)) bad("list entry 3");
        // ---- mount: Disk II drive 1 <- idx 0, ProDOS HD drive 1 <- idx 1; a wrong size is refused ----
        mark = tn; hb("M"); hb(0); hb(2); hb(0); wait_done(mark);
        if (!find_after(mark, "ERR 8", 5)) bad("mount of a wrong-size file must give ERR 8");
        mark = tn; hb("M"); hb(0); hb(0); hb(0); wait_done(mark);
        mark = tn; hb("M"); hb(2); hb(1); hb(0); wait_done(mark);
        k0 = 0; for (i = 0; i < D2; i = i + 1) if (d2mem[d2idx(i)] !== pat(i, 1)) k0 = k0 + 1;
        if (k0 || d2lasts != 1) bad("Disk II drive 1 contents (DOS order -> physical)");
        mark = tn; hb("M"); hb(1); hb(3); hb(0); wait_done(mark);
        k0 = 0; for (i = 0; i < D2; i = i + 1) if (d2mem[D2 + i] !== pat(i, 4)) k0 = k0 + 1;
        if (k0 || d2lasts != 2) bad("Disk II drive 2 contents (.po is already physical)");
        k0 = 0; for (i = 0; i < HD; i = i + 1) if (hdmem[i] !== pat(i, 2)) k0 = k0 + 1;
        if (k0 || hdlasts != 1) bad("ProDOS HD drive 1 contents");
        lm = tn; cmd1("S");
        if (!find_after(lm, "S\t0\tdisk one.dsk\n", 17)) bad("slot 0 report");
        if (!find_after(lm, "S\t1\tphys order.po\n", 18)) bad("slot 1 report");
        if (!find_after(lm, "S\t2\tAnother Long Name.po\n", 25)) bad("slot 2 report");
        // ---- get: round trip ----
        mark = tn; hb("G"); hb(0); hb(0); wait_done(mark);
        if (!find_after(mark, "GO 00001000\n", 12)) bad("get header");
        for (j = mark; tlog[j] !== 8'h0A; j = j + 1) ;
        k0 = 0; for (i = 0; i < D2; i = i + 1) if (tlog[j + 1 + i] !== pat(i, 1)) k0 = k0 + 1;       // the file as uploaded, not re-ordered
        if (k0) bad("get data");
        // ---- delete / rename are refused while mounted ----
        mark = tn; hb("D"); hb(0); hb(0); wait_done(mark);
        if (!find_after(mark, "ERR 9", 5)) bad("delete of a mounted file must give ERR 9");
        mark = tn; hb("R"); hb(1); hb(0); wait_done(mark);
        if (!find_after(mark, "ERR 9", 5)) bad("rename of a mounted file must give ERR 9");
        // ---- rename and delete an unmounted file ----
        mark = tn; hb("R"); hb(2); hb(0);
        wait_text(mark, "GO\n", 3);
        hb(21); for (i = 0; i < 21; i = i + 1) hb(rn[8*(20-i) +: 8]);
        wait_done(mark);
        lm = tn; cmd1("L");
        if (!find_after(lm, "\trenamed note file.txt\n", 23)) bad("renamed entry listed");
        mark = tn; hb("D"); hb(3); hb(0); wait_done(mark);        // the renamed entry was added last, so it lists last
        if (!tail_is("OK\n", 3)) bad("delete");
        lm = tn; cmd1("L");
        if (find_after(lm, "renamed", 7)) bad("deleted file still listed");
        // ---- HD write-back: the //e rewrites block 1 ----
        for (i = 0; i < HD; i = i + 1) hdwb[i] = ~pat(i, 2);
        @(posedge clk); #1 wr_blk = 1; wr_req = 1;
        t = 0; while (!wr_ack && t < 1_500_000) begin @(posedge clk); t = t + 1; end
        if (t >= 1_500_000) bad("no write-back ack");
        @(posedge clk); #1 wr_req = 0; repeat (20) @(posedge clk);
        mark = tn; hb("G"); hb(1); hb(0); wait_done(mark);
        for (j = mark; tlog[j] !== 8'h0A; j = j + 1) ;
        k0 = 0; for (i = 0; i < HD; i = i + 1) if (tlog[j + 1 + i] !== ((i >= 512 && i < 1024) ? ~pat(i, 2) : pat(i, 2))) k0 = k0 + 1;
        if (k0) bad("HD write-back data");
        // ---- power cycle: both images come back from TN20K.CFG ----
        for (i = 0; i < 2*D2; i = i + 1) d2mem[i] = 0;
        for (i = 0; i < 2*HD; i = i + 1) hdmem[i] = 0;
        d2lasts = 0; hdlasts = 0;
        reset = 1; #200 reset = 0;
        t = 0; while (!(d2lasts == 2 && hdlasts == 1) && t < 6_000_000) begin @(posedge clk); t = t + 1; end
        if (t >= 6_000_000) bad("boot did not remount from the CFG");
        k0 = 0; for (i = 0; i < D2; i = i + 1) begin if (d2mem[d2idx(i)] !== pat(i, 1)) k0 = k0 + 1; if (d2mem[D2 + i] !== pat(i, 4)) k0 = k0 + 1; end
        for (i = 0; i < HD; i = i + 1) if (hdmem[i] !== ((i >= 512 && i < 1024) ? ~pat(i, 2) : pat(i, 2))) k0 = k0 + 1;
        if (k0) bad("boot-time mount contents");
        if (card.errs != 0) bad("card-side protocol errors");
        if (errs == 0) $display("PASS"); else $display("FAIL: %0d errors", errs);
        $finish;
    end
    initial begin #20_000_000_000; $display("FAIL: sim timeout"); $finish; end
endmodule
