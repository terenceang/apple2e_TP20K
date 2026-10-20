// tb_fat32: the FAT32 file layer against sim/models/sdcard.v.  Volume: MBR at 0, FAT32 at
// LBA 100, 2 sectors/cluster, 2 FATs of 8 sectors, root cluster = sectors 148-149 (32 entries)
// holding a short-name file, a long-name file (LFN set), a deleted entry and TN20K.CFG.
// Checks mount, listing (long and short names, the hidden CFG), SFN lookup, contiguous alloc
// with its FAT chain in both FATs, directory writes (LFN order/flags/checksum/chars, ~N tails,
// exact 8.3 names without LFN, duplicates), rename-style add+remove, and delete (+ chain free).
`timescale 1ns/1ps
module tb_fat32;
    localparam PART = 100, FAT1 = 132, FAT2 = 140, DATA = 148, DIR = 148 * 512;
    reg clk = 0, reset = 1;
    always #18.5 clk = ~clk;

    wire sd_clk, sd_mosi, sd_cs_n, sd_miso;
    reg  go = 0; reg [3:0] cmd = 0; reg [31:0] arg = 0; reg [6:0] nlen = 0;
    wire busy, err, found, berr; wire [3:0] ecode; wire [31:0] r_cluster, r_size, file_lba;
    wire [87:0] r_sfn; wire [6:0] r_nlen; wire [7:0] lrx, brd, cnrd; wire [2:0] bstage;
    reg [5:0] cna = 0; reg cnwe = 0; reg [7:0] cnwd = 0;
    reg [8:0] cba = 0;
    fat32 #(.PWR_BITS(6)) dut (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .go(go), .cmd(cmd), .arg(arg), .busy(busy), .err(err), .ecode(ecode), .found(found),
        .r_cluster(r_cluster), .r_size(r_size), .r_sfn(r_sfn), .r_nlen(r_nlen), .file_lba(file_lba),
        .lrx(lrx), .bstage(bstage), .berr(berr), .nlen(nlen),
        .cba(cba), .cbwe(1'b0), .cbwd(8'd0), .brd(brd), .cna(cna), .cnwe(cnwe), .cnwd(cnwd), .cnrd(cnrd));
    sdcard #(.SECTORS(1024)) card (.sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso));

    localparam CMD_MOUNT = 1, CMD_IDX = 2, CMD_SFN = 3, CMD_ALLOC = 4, CMD_ADD = 5, CMD_REMOVE = 6, CMD_DEL = 7;
    integer errs = 0, i, j;
    task bad(input [8*48-1:0] msg); begin errs = errs + 1; $display("FAIL: %0s", msg); end endtask

    task run(input [3:0] c, input [31:0] a);
        integer t;
        begin
            @(posedge clk); #1 cmd = c; arg = a; go = 1; @(posedge clk); #1 go = 0;
            t = 0; @(posedge clk);
            while (busy && t < 5_000_000) begin @(posedge clk); t = t + 1; end
            if (busy) bad("timeout");
        end
    endtask
    task put_name(input [8*64-1:0] s, input integer len);     // s right-aligned
        integer q;
        begin
            for (q = 0; q < len; q = q + 1) begin
                @(posedge clk); #1 cna = q; cnwd = s[8*(len-1-q) +: 8]; cnwe = 1; @(posedge clk); #1 cnwe = 0;
            end
            nlen = len;
        end
    endtask
    task expect_name(input [8*64-1:0] s, input integer len);
        integer q; reg ok;
        begin
            ok = (r_nlen == len);
            for (q = 0; q < len; q = q + 1) begin cna = q; #2; if (cnrd !== s[8*(len-1-q) +: 8]) ok = 0; end
            if (!ok) begin errs = errs + 1; $display("FAIL: name mismatch (len %0d want %0d)", r_nlen, len); end
        end
    endtask

    // ---- the volume ----
    task put32(input integer a, input [31:0] v);
        begin card.mem[a] = v[7:0]; card.mem[a+1] = v[15:8]; card.mem[a+2] = v[23:16]; card.mem[a+3] = v[31:24]; end
    endtask
    function [7:0] cksum(input [87:0] sfn);
        integer q; reg [7:0] s;
        begin s = 0; for (q = 0; q < 11; q = q + 1) s = {s[0], s[7:1]} + sfn[87 - 8*q -: 8]; cksum = s; end
    endfunction
    task sfn_entry(input integer pos, input [87:0] name, input [31:0] cl, input [31:0] sz);
        integer q;
        begin
            for (q = 0; q < 11; q = q + 1) card.mem[DIR + pos*32 + q] = name[87 - 8*q -: 8];
            card.mem[DIR + pos*32 + 11] = 8'h20;
            card.mem[DIR + pos*32 + 20] = cl[23:16]; card.mem[DIR + pos*32 + 21] = cl[31:24];
            card.mem[DIR + pos*32 + 26] = cl[7:0];   card.mem[DIR + pos*32 + 27] = cl[15:8];
            put32(DIR + pos*32 + 28, sz);
        end
    endtask
    task lfn_entry(input integer pos, input [7:0] seq, input [8*13-1:0] chars, input [7:0] ck);   // chars: 13, FF = pad, 00 = NUL
        integer q; integer off;
        begin
            card.mem[DIR + pos*32] = seq; card.mem[DIR + pos*32 + 11] = 8'h0F; card.mem[DIR + pos*32 + 13] = ck;
            for (q = 0; q < 13; q = q + 1) begin
                off = (q < 5) ? 1 + 2*q : (q < 11) ? 14 + 2*(q-5) : 28 + 2*(q-11);
                card.mem[DIR + pos*32 + off] = chars[8*(12-q) +: 8];
                card.mem[DIR + pos*32 + off + 1] = (chars[8*(12-q) +: 8] == 8'hFF) ? 8'hFF : 8'h00;
            end
        end
    endtask
    localparam [87:0] SF_LONG = "LONGNA~1DSK";
    task build;
        begin
            for (i = 0; i < 1024*512; i = i + 1) card.mem[i] = 0;
            card.mem[446+4] = 8'h0C; put32(446+8, PART); card.mem[510] = 8'h55; card.mem[511] = 8'hAA;
            card.mem[PART*512+12] = 2; card.mem[PART*512+13] = 2; card.mem[PART*512+14] = 32; card.mem[PART*512+16] = 2;
            put32(PART*512+36, 8); put32(PART*512+44, 2);
            for (i = 0; i < 2; i = i + 1) begin
                put32((i ? FAT2 : FAT1)*512 + 0, 32'h0FFFFFF8); put32((i ? FAT2 : FAT1)*512 + 4, 32'h0FFFFFFF);
                for (j = 2; j <= 5; j = j + 1) put32((i ? FAT2 : FAT1)*512 + 4*j, 32'h0FFFFFFF);
            end
            sfn_entry(0, "VOLUME  DAT", 3, 500);
            lfn_entry(1, 8'h42, {"e.dsk", 8'h00, {7{8'hFF}}}, cksum(SF_LONG));
            lfn_entry(2, 8'h01, "Long Name Fil", cksum(SF_LONG));
            sfn_entry(3, SF_LONG, 4, 1000);
            card.mem[DIR + 4*32] = 8'hE5; card.mem[DIR + 4*32 + 11] = 8'h20;
            sfn_entry(5, "TN20K   CFG", 5, 33);
        end
    endtask
    function [31:0] fat(input integer which, input integer c);
        fat = {card.mem[(which ? FAT2 : FAT1)*512 + 4*c + 3], card.mem[(which ? FAT2 : FAT1)*512 + 4*c + 2],
               card.mem[(which ? FAT2 : FAT1)*512 + 4*c + 1], card.mem[(which ? FAT2 : FAT1)*512 + 4*c]};
    endfunction

    integer p, n; reg [8*64-1:0] nm;
    initial begin
        build;
        #200 reset = 0;
        wait (!busy); if (err) bad("init");

        run(CMD_MOUNT, 0);
        if (err) bad("mount");
        // ---- listing: short name, long name; the CFG is hidden; then nothing ----
        run(CMD_IDX, 0);
        if (!found || r_cluster != 3 || r_size != 500) bad("idx 0"); expect_name("VOLUME.DAT", 10);
        run(CMD_IDX, 1);
        if (!found || r_cluster != 4 || r_size != 1000 || r_sfn != SF_LONG) bad("idx 1"); expect_name("Long Name File.dsk", 18);
        run(CMD_IDX, 2);
        if (found) bad("idx 2 should not exist (CFG is hidden)");
        // ---- lookup by short name ----
        put_name("LONGNA~1DSK", 11); run(CMD_SFN, 0);
        if (!found || r_cluster != 4) bad("sfn lookup"); expect_name("Long Name File.dsk", 18);
        put_name("NOPE    XXX", 11); run(CMD_SFN, 0);
        if (found) bad("sfn lookup of a missing name");
        // ---- alloc: 5000 bytes = 5 clusters of 1 KB, first free is 6 ----
        run(CMD_ALLOC, 5000);
        if (err || r_cluster != 6 || r_size != 5000) bad("alloc");
        for (p = 0; p < 2; p = p + 1) begin
            if (fat(p, 6) != 7 || fat(p, 7) != 8 || fat(p, 8) != 9 || fat(p, 9) != 10 || fat(p, 10) != 32'h0FFFFFFF) bad("fat chain");
            if (fat(p, 11) != 0) bad("fat chain overran");
        end
        if (file_lba != DATA + 4*2) bad("file_lba");
        // ---- add a long name (3 LFN entries) ----
        put_name("DOS 3.3 System Master - 680-0210-A.dsk", 38); run(CMD_ADD, 0);
        if (err) begin bad("add long"); $display("ecode=%0d st=%0d", ecode, dut.st); end
        if (r_sfn != "DOS33S~1DSK") begin bad("short name"); $display("sfn=%s exact=%b nlfn=%0d dotp=%0d bl=%0d", r_sfn, dut.exact, dut.nlfn, dut.dotp, dut.bl); end
        // the entries: free slots were 4 (deleted), then 6.. -> needs 4 consecutive: 6,7,8,9
        if (card.mem[DIR + 6*32] != 8'h43 || card.mem[DIR + 7*32] != 8'h02 || card.mem[DIR + 8*32] != 8'h01) bad("lfn seq");
        if (card.mem[DIR + 6*32 + 13] != cksum("DOS33S~1DSK") || card.mem[DIR + 8*32 + 13] != cksum("DOS33S~1DSK")) bad("lfn checksum");
        if (card.mem[DIR + 8*32 + 1] != "D" || card.mem[DIR + 8*32 + 3] != "O" || card.mem[DIR + 8*32 + 28] != "t") bad("lfn chars");
        if (card.mem[DIR + 6*32 + 1] != "0" || card.mem[DIR + 6*32 + 22] != "d" || card.mem[DIR + 6*32 + 24] != "s" || card.mem[DIR + 6*32 + 28] != "k") bad("lfn tail chars");
        if (card.mem[DIR + 6*32 + 30] != 8'h00 || card.mem[DIR + 6*32 + 31] != 8'h00) bad("lfn terminator");
        if (card.mem[DIR + 9*32 + 11] != 8'h20 || card.mem[DIR + 9*32] != "D" || card.mem[DIR + 9*32 + 26] != 6 || card.mem[DIR + 9*32 + 28] != 8'h88 || card.mem[DIR + 9*32 + 29] != 8'h13 || card.mem[DIR + 9*32 + 30] != 0) bad("sfn entry");
        // ---- and it lists, by its long name ----
        run(CMD_IDX, 2);
        if (!found || r_cluster != 6) bad("idx long"); expect_name("DOS 3.3 System Master - 680-0210-A.dsk", 38);
        // ---- an exact 8.3 name takes no LFN and no tail; a duplicate is refused ----
        run(CMD_ALLOC, 1024);
        if (r_cluster != 11) bad("alloc 2");
        put_name("HD1.PO", 6); run(CMD_ADD, 0);
        if (err || r_sfn != "HD1     PO ") bad("add exact");
        if (card.mem[DIR + 4*32] != "H" || card.mem[DIR + 4*32 + 11] != 8'h20 || card.mem[DIR + 4*32 + 26] != 11) bad("exact entry reuses the deleted slot 4");
        put_name("HD1.PO", 6); run(CMD_ADD, 0);
        if (!err || ecode != 4) bad("duplicate must fail with E_EXISTS");
        // ---- the same long name again gets ~2 ----
        run(CMD_ALLOC, 100);
        put_name("DOS 3.3 System Master - 680-0210-A.dsk", 38); run(CMD_ADD, 0);
        if (err || r_sfn != "DOS33S~2DSK") bad("~2 tail");
        if (card.mem[DIR + 10*32] != 8'h43 || card.mem[DIR + 13*32] != "D") bad("second long name at 10..13");
        // ---- delete the original long-name file: entries 1..3 marked, chain 4 freed ----
        run(CMD_IDX, 1);
        run(CMD_DEL, 0);
        if (err) bad("del");
        if (card.mem[DIR + 1*32] != 8'hE5 || card.mem[DIR + 2*32] != 8'hE5 || card.mem[DIR + 3*32] != 8'hE5) bad("del marks");
        if (fat(0, 4) != 0 || fat(1, 4) != 0) bad("del frees chain");
        if (fat(0, 3) != 32'h0FFFFFFF) bad("del touched a neighbour");
        run(CMD_IDX, 1);
        if (!found || r_cluster != 11) bad("list after delete (HD1.PO)");
        // ---- rename = add the new name for the same cluster, remove the old entries ----
        run(CMD_IDX, 0);                                    // VOLUME.DAT (cluster 3, 500 bytes)
        put_name("renamed volume file.dat", 23); run(CMD_ADD, 0);
        if (err || r_sfn != "RENAME~1DAT") bad("rename add");
        if (card.mem[DIR + 1*32] != 8'h42 || card.mem[DIR + 2*32] != 8'h01 || card.mem[DIR + 3*32] != "R") bad("rename entries reuse 1..3");
        if (card.mem[DIR + 1*32 + 24] != 8'h00 || card.mem[DIR + 1*32 + 25] != 8'h00 || card.mem[DIR + 1*32 + 28] != 8'hFF || card.mem[DIR + 1*32 + 31] != 8'hFF) bad("lfn NUL then FF padding");
        run(CMD_REMOVE, 0);
        if (err || card.mem[DIR + 0*32] != 8'hE5) bad("rename remove");
        if (fat(0, 3) != 32'h0FFFFFFF) bad("rename must keep the chain");

        if (card.errs != 0) bad("card-side protocol errors");
        if (errs == 0) $display("PASS"); else $display("FAIL: %0d errors", errs);
        $finish;
    end
    initial begin #3_000_000_000; $display("FAIL: sim timeout"); $finish; end
endmodule
