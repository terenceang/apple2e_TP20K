`timescale 1ns / 1ps
`default_nettype none

//  tb_disk2.v -- the Disk ][ card and its WOZ store, at the level RWTS drives them
//
//  The DDR3 holds a WOZ file the page's own converter made from a DOS-order
//  .dsk (web/scripts/simcard.mjs: build/sim_floppy.hex, and the .dsk as
//  build/sim_floppy_dsk.hex).  The bench is the 6502: every access is one CPU
//  cycle on the card's bus, and the read and write loops take the cycles
//  RWTS's do (LDA abs,X / BPL is 7 cycles a pass; a written byte is loaded
//  every 32 cycles, a sync byte every 40), so the bits, the sequencer's latch
//  and its self-sync are what is tested.  What is checked:
//
//    * the stepper: half and quarter tracks, the stop at 0, DOS's recalibrate
//    * a whole track read from wherever the head lands: 16 address fields
//      with volume 254, the track and sectors 0-15, and 16 data fields that
//      decode (an independent 6-and-2 decoder, below) to the .dsk's sectors
//      through DOS 3.3's interleave
//    * a quarter track next to a track reads that track; an empty one is noise
//    * write protect: the sense bit, with and without the INFO flag
//    * a sector written with RWTS's timing reads back, the rest of the track
//      is unchanged, only that track's DDR3 words changed, and fl_wr named
//      that track's blocks of the file
//    * drive 2, empty: noise, and protected
//
//  ce_1m runs every 4 clocks here: everything in the card counts ce_1m, so the
//  disk turns ~6.6 times faster than real time and the DDR3's latency is
//  still small against a 16-bit word (256 clocks).

module tb_disk2;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;
    reg [1:0] cdiv = 2'd0;
    always @(posedge clk) cdiv <= cdiv + 2'd1;
    wire ce_1m = (cdiv == 2'd3);

    // ---- the card's bus ----
    reg        devsel_n = 1'b1, bus_cycle = 1'b0, we = 1'b0;
    reg [15:0] addr = 16'h0000;
    reg [7:0]  di = 8'h00;
    wire [7:0] io_data, rom_data;

    wire        drive, bit_tick, wr_en, wr_bit, wr_mode, rd_bit, rd_ok;
    wire [7:0]  qtr, dbg_head;
    wire [1:0]  drv_present, drv_writable;
    wire        dbg_any_disk, fl_wr, fl_wr_drv;
    wire [10:0] fl_wr_blk;
    wire        dsk_go, dsk_we;
    wire [21:0] dsk_addr;
    wire [15:0] dsk_wdata;
    reg  [15:0] dsk_rdata = 16'h0000;
    reg         dsk_ack = 1'b0;

    disk2_card card (
        .clk(clk), .reset(reset), .ce_1m(ce_1m), .step(bus_cycle),
        .devsel_n(devsel_n), .iosel_n(1'b1), .bus_cycle(bus_cycle), .cpu_we(we),
        .addr(addr), .cpu_di(di), .rom_data(rom_data), .io_data(io_data),
        .drive(drive), .qtr(qtr), .bit_tick(bit_tick), .wr_en(wr_en), .wr_bit(wr_bit),
        .wr_mode(wr_mode), .rd_bit(rd_bit), .rd_ok(rd_ok),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .dbg_head(dbg_head), .dbg_any_disk(dbg_any_disk));

    disk2_store store (
        .clk(clk), .reset(reset),
        .drive(drive), .qtr(qtr), .bit_tick(bit_tick), .wr_en(wr_en), .wr_bit(wr_bit),
        .wr_mode(wr_mode), .rd_bit(rd_bit), .rd_ok(rd_ok),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .fl_wr(fl_wr), .fl_wr_drv(fl_wr_drv), .fl_wr_blk(fl_wr_blk),
        .up_go(1'b0), .up_drive(1'b0), .up_addr(20'd0), .up_data(8'd0), .up_last(1'b0),
        .up_ro(1'b0), .up_bad(1'b0), .up_busy(), .up_done(),
        .down_go(1'b0), .down_drive(1'b0), .down_addr(20'd0), .down_data(), .down_valid(),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack), .dsk_idle());

    // ---- DDR3: drive 0's file as words, a request at a time, random latency ----
    localparam integer WORDS = 117248;          // 234,496 bytes
    reg [15:0] mem  [0:2*262144-1];
    reg [15:0] orig [0:WORDS-1];
    reg        pend = 1'b0;
    reg [5:0]  lat = 6'd0;
    reg [21:0] la;
    reg        lwe;
    reg [15:0] lwd;
    integer    fails = 0, checks = 0;
    always @(posedge clk) begin
        dsk_ack <= 1'b0;
        if (dsk_go) begin
            if (pend) begin $display("FAIL: a DDR3 request while one is out"); fails = fails + 1; end
            pend <= 1'b1; lat <= 6'd6 + ($random & 6'd15); la <= dsk_addr; lwe <= dsk_we; lwd <= dsk_wdata;
        end else if (pend) begin
            if (lat != 6'd0) lat <= lat - 6'd1;
            else begin
                pend <= 1'b0; dsk_ack <= 1'b1;
                if (la[21:20] != 2'b00) begin $display("FAIL: DDR3 address %h outside region 1's drives", la); fails = fails + 1; end
                if (lwe) mem[la[19:0]] <= lwd; else dsk_rdata <= mem[la[19:0]];
            end
        end
    end

    // fl_wr: the blocks the store said it wrote
    integer fl_lo = 99999, fl_hi = -1, fl_n = 0, fb;
    always @(posedge clk) if (fl_wr) begin
        fl_n = fl_n + 1;
        if (fl_wr_drv !== 1'b0) begin $display("FAIL: fl_wr for drive 2"); fails = fails + 1; end
        fb = fl_wr_blk;
        if (fb < fl_lo) fl_lo = fb;
        if (fb > fl_hi) fl_hi = fb;
    end

    task check(input [8*72-1:0] what, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end
        end
    endtask

    // ---- the 6502: one step per CPU cycle, bus_cycle (cpu_go, and the card's
    // step) on each ----
    // As on the board, a step is now and then lost to a memory stall (one in
    // 16 here): the disk has to turn on the CPU's steps, not ce_1m, for a
    // 7-cycle poll to see every byte and a written byte to go out on time.
    integer lost = 0;
    reg     stalls = 1'b1;
    task step_edge;   // the next ce_1m this CPU gets a step on
        begin
            @(negedge clk); while (!ce_1m) @(negedge clk);
            if (stalls && ($random & 15) < 1) begin
                lost = lost + 1;
                @(negedge clk); while (!ce_1m) @(negedge clk);
            end
        end
    endtask
    task tick;      // a cycle with nothing on the card's bus
        begin step_edge; bus_cycle = 1'b1; @(negedge clk); bus_cycle = 1'b0; end
    endtask
    task acc(input [3:0] a, input w, input [7:0] d, output [7:0] q);
        begin
            step_edge;
            addr = 16'hC0E0 | a; we = w; di = d; devsel_n = 1'b0; bus_cycle = 1'b1;
            #1 q = io_data;
            @(negedge clk); devsel_n = 1'b1; bus_cycle = 1'b0; we = 1'b0;
        end
    endtask
    reg [7:0] junk;
    task sw(input [3:0] a); acc(a, 1'b0, 8'h00, junk); endtask
    task idle(input integer n); repeat (n) tick; endtask

    // RD: LDA $C08C,X / BPL RD (7 cycles a pass), then BPL not taken and a
    // compare (4) before the caller's next read
    task rdnib(output [7:0] b);
        begin
            b = 8'h00;
            while (!b[7]) begin
                tick; tick; tick; acc(4'hC, 1'b0, 8'h00, b);
                if (!b[7]) begin tick; tick; end
            end
            tick; tick; tick; tick;
        end
    endtask

    // ---- the stepper, as RWTS moves it: next phase on, settle, previous off ----
    integer hb = 0;                 // where DOS believes the head is, in half tracks
    function [1:0] ph(input integer h); ph = h[1:0]; endfunction   // half track h's phase
    task halfstep(input integer dir);
        begin
            sw({1'b0, ph(hb + dir), 1'b1});
            idle(20);
            sw({1'b0, ph(hb), 1'b0});
            idle(20);
            hb = hb + dir;
        end
    endtask
    task phases_off; begin sw(4'h0); sw(4'h2); sw(4'h4); sw(4'h6); end endtask
    task seek(input integer track);
        begin
            while (hb < 2 * track) halfstep(1);
            while (hb > 2 * track) halfstep(-1);
            phases_off;
        end
    endtask
    task recal;   // DOS: believe 80 half tracks out and seek to 0, against the stop
        begin hb = 80; seek(0); end
    endtask

    // ---- 6-and-2, the bench's own: the decode table spelled out ----
    reg [7:0] g62 [0:63];
    initial begin
        {g62[0],g62[1],g62[2],g62[3],g62[4],g62[5],g62[6],g62[7]}         = {8'h96,8'h97,8'h9A,8'h9B,8'h9D,8'h9E,8'h9F,8'hA6};
        {g62[8],g62[9],g62[10],g62[11],g62[12],g62[13],g62[14],g62[15]}   = {8'hA7,8'hAB,8'hAC,8'hAD,8'hAE,8'hAF,8'hB2,8'hB3};
        {g62[16],g62[17],g62[18],g62[19],g62[20],g62[21],g62[22],g62[23]} = {8'hB4,8'hB5,8'hB6,8'hB7,8'hB9,8'hBA,8'hBB,8'hBC};
        {g62[24],g62[25],g62[26],g62[27],g62[28],g62[29],g62[30],g62[31]} = {8'hBD,8'hBE,8'hBF,8'hCB,8'hCD,8'hCE,8'hCF,8'hD3};
        {g62[32],g62[33],g62[34],g62[35],g62[36],g62[37],g62[38],g62[39]} = {8'hD6,8'hD7,8'hD9,8'hDA,8'hDB,8'hDC,8'hDD,8'hDE};
        {g62[40],g62[41],g62[42],g62[43],g62[44],g62[45],g62[46],g62[47]} = {8'hDF,8'hE5,8'hE6,8'hE7,8'hE9,8'hEA,8'hEB,8'hEC};
        {g62[48],g62[49],g62[50],g62[51],g62[52],g62[53],g62[54],g62[55]} = {8'hED,8'hEE,8'hEF,8'hF2,8'hF3,8'hF4,8'hF5,8'hF6};
        {g62[56],g62[57],g62[58],g62[59],g62[60],g62[61],g62[62],g62[63]} = {8'hF7,8'hF9,8'hFA,8'hFB,8'hFC,8'hFD,8'hFE,8'hFF};
    end
    function [6:0] un62(input [7:0] n);   // {not a disk byte, value}
        integer v;
        begin
            un62 = 7'h40;
            for (v = 0; v < 64; v = v + 1) if (g62[v] == n) un62 = v;
        end
    endfunction

    reg [7:0] nib [0:342];
    reg [7:0] sec [0:255];
    reg [5:0] val [0:342];
    // the field in nib[] -> sec[]; 0 if a byte is not a disk byte or the checksum fails
    function field_ok(input dummy);
        integer i;
        reg [6:0] u;
        reg [5:0] prev;
        begin
            field_ok = 1'b1; prev = 6'd0;
            for (i = 0; i < 343; i = i + 1) begin
                u = un62(nib[i]);
                if (u[6]) field_ok = 1'b0;
                prev = prev ^ u[5:0];
                val[i] = prev;
            end
            if (val[342] != 6'd0) field_ok = 1'b0;
            for (i = 0; i < 256; i = i + 1) begin
                u = val[i % 86] >> (2 * (i / 86));      // this byte's pair, reversed
                sec[i] = {val[86 + i], u[0], u[1]};
            end
        end
    endfunction

    // the .dsk the WOZ was made from, and DOS 3.3's interleave (physical -> logical)
    reg [7:0] dsk [0:143359];
    function integer p2d(input integer p);
        case (p)
            0: p2d = 0;  1: p2d = 7;  2: p2d = 14; 3: p2d = 6;  4: p2d = 13; 5: p2d = 5;  6: p2d = 12; 7: p2d = 4;
            8: p2d = 11; 9: p2d = 3;  10: p2d = 10; 11: p2d = 2; 12: p2d = 9; 13: p2d = 1; 14: p2d = 8; default: p2d = 15;
        endcase
    endfunction

    // ---- read a track: every address and data field in ~2 turns ----
    reg [15:0] seen;               // sectors whose data field decoded and matched
    reg [7:0]  hv, ht, hs, hc;
    integer    bad, got_trk;
    // the expected bytes of physical sector p of track t; `override` replaces one sector
    integer    ov_t = -1, ov_p = -1;
    reg [7:0]  ov [0:255];
    function [7:0] want(input integer t, input integer p, input integer i);
        want = (t == ov_t && p == ov_p) ? ov[i] : dsk[(t * 16 + p2d(p)) * 256 + i];
    endfunction
    task read_track(input integer t, input integer nibs);
        integer n, i, k;
        reg [7:0] b, b2, b3;
        begin
            seen = 16'h0000; bad = 0; got_trk = -1;
            n = 0;
            while (n < nibs && seen != 16'hFFFF) begin
                rdnib(b); n = n + 1;
                if (b == 8'hD5) begin
                    rdnib(b2); rdnib(b3); n = n + 2;
                    if (b2 == 8'hAA && b3 == 8'h96) begin
                        rdnib(b); rdnib(b2); hv = ((b << 1) | 8'h01) & b2;
                        rdnib(b); rdnib(b2); ht = ((b << 1) | 8'h01) & b2;
                        rdnib(b); rdnib(b2); hs = ((b << 1) | 8'h01) & b2;
                        rdnib(b); rdnib(b2); hc = ((b << 1) | 8'h01) & b2;
                        n = n + 8;
                        got_trk = ht;
                        if (hv != 8'd254 || (hv ^ ht ^ hs) != hc || hs > 15) bad = bad + 1;
                        // the data mark within the next ~20 bytes
                        for (k = 0; k < 20; k = k + 1) begin
                            rdnib(b); n = n + 1;
                            if (b == 8'hD5) begin
                                rdnib(b2); rdnib(b3); n = n + 2;
                                if (b2 == 8'hAA && b3 == 8'hAD) begin
                                    for (i = 0; i < 343; i = i + 1) rdnib(nib[i]);
                                    n = n + 343;
                                    if (!field_ok(1'b0)) bad = bad + 1;
                                    else begin
                                        for (i = 0; i < 256; i = i + 1)
                                            if (sec[i] !== want(t, hs, i)) begin
                                                if (bad < 4) $display("   track %0d sector %0d byte %0d = %02x, want %02x", t, hs, i, sec[i], want(t, hs, i));
                                                bad = bad + 1; i = 256;
                                            end
                                        if (ht == t) seen[hs[3:0]] = 1'b1;
                                    end
                                    k = 20;
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    // ---- write a sector the way RWTS's WRITE16 does ----
    // after the address field and its DE AA: Q6H, Q7L (the protect sense),
    // then Q7H loads FF, and each byte is loaded with Q6H and shifted with Q6L:
    // five 40-cycle sync bytes, the data mark, 343 bytes and the tail at 32
    task wbyte(input [7:0] b, input integer cycles, input first);
        begin
            acc(first ? 4'hF : 4'hD, 1'b1, b, junk);   // STA $C08F,X / STA $C08D,X (the load)
            tick; tick; tick; sw(4'hC);                  // ORA $C08C,X
            idle(cycles - 5);
        end
    endtask
    task write_sector(input integer t, input integer s, input wp);
        integer i, guard;
        reg [7:0] b, b2, b3;
        reg [5:0] v [0:341];
        reg [5:0] pv;
        reg       found;
        begin
            // the address field of sector s
            found = 1'b0; guard = 0;
            while (!found && guard < 20000) begin
                rdnib(b); guard = guard + 1;
                if (b == 8'hD5) begin
                    rdnib(b2); rdnib(b3);
                    if (b2 == 8'hAA && b3 == 8'h96) begin
                        rdnib(b); rdnib(b); rdnib(b); rdnib(b);
                        rdnib(b); rdnib(b2); hs = ((b << 1) | 8'h01) & b2;
                        rdnib(b); rdnib(b);
                        rdnib(b); rdnib(b2);                    // DE AA
                        if (hs == s) found = 1'b1;
                    end
                end
            end
            check("found the address field to write after", found);
            // the new sector, encoded here (aux k carries bytes k, k+86, k+172, pairs reversed)
            for (i = 0; i < 86; i = i + 1) v[i] = 6'd0;
            for (i = 0; i < 256; i = i + 1) begin
                v[i % 86] = v[i % 86] | ({ov[i][0], ov[i][1]} << (2 * (i / 86)));
                v[86 + i] = ov[i][7:2];
            end
            sw(4'hD); acc(4'hE, 1'b0, 8'h00, b);              // LDA $C08D,X ; LDA $C08E,X
            check("the write-protect sense before a write", b[7] === wp);
            wbyte(8'hFF, 40, 1'b1);
            for (i = 0; i < 4; i = i + 1) wbyte(8'hFF, 40, 1'b0);
            wbyte(8'hD5, 32, 1'b0); wbyte(8'hAA, 32, 1'b0); wbyte(8'hAD, 32, 1'b0);
            pv = 6'd0;
            for (i = 0; i < 342; i = i + 1) begin wbyte(g62[v[i] ^ pv], 32, 1'b0); pv = v[i]; end
            wbyte(g62[pv], 32, 1'b0);
            wbyte(8'hDE, 32, 1'b0); wbyte(8'hAA, 32, 1'b0); wbyte(8'hEB, 32, 1'b0);
            wbyte(8'hFF, 32, 1'b0);
            sw(4'hE); sw(4'hC);                                   // Q7L: read mode
        end
    endtask

    integer i, n, q0, changed, outside;
    reg [7:0] b;
    initial begin
        $display("=== tb_disk2 ===");
        $readmemh("build/sim_floppy.hex", mem, 0, WORDS - 1);
        $readmemh("build/sim_floppy_dsk.hex", dsk);
        for (i = 0; i < WORDS; i = i + 1) orig[i] = mem[i];
        #200 @(posedge clk) reset = 1'b0;
        store.present  = 2'b01;           // as sd_vol leaves it after loading drive 1
        store.writable = 2'b01;

        // ---- the stepper ----
        check("the head starts at track 0", dbg_head === 8'd0);
        seek(1);  check("one track out is quarter track 4", dbg_head === 8'd4);
        seek(3);  check("track 3 is quarter track 12", dbg_head === 8'd12);
        seek(2);  check("one track in", dbg_head === 8'd8);
        sw(4'h1); sw(4'h3);               // track 2 is phase 0's: phases 0 and 1 together
        check("two adjacent phases hold a quarter track", dbg_head === 8'd9);
        sw(4'h2);                         // phase 1 off
        check("one phase pulls it back onto its magnet", dbg_head === 8'd8);
        sw(4'h0);
        seek(30); check("track 30", dbg_head === 8'd120);
        recal;    check("DOS's recalibrate lands on track 0", dbg_head === 8'd0);
        halfstep(-1); halfstep(-1); phases_off; hb = 0;
        check("stepping in at track 0 does nothing", dbg_head === 8'd0);

        // ---- read track 0 and track 17 from wherever the head lands ----
        sw(4'h9); sw(4'hA); sw(4'hE);        // motor on, drive 1, read mode
        idle(300);
        read_track(0, 14000);
        check("track 0: all 16 sectors decode to the .dsk", seen == 16'hFFFF && bad == 0);
        seek(17);
        read_track(17, 14000);
        check("track 17: all 16 sectors decode to the .dsk", seen == 16'hFFFF && bad == 0);

        // ---- a quarter track beside track 17 reads it; one between tracks is noise ----
        sw(4'h5); sw(4'h7); idle(20);       // track 17 is phase 2's: phases 2 and 3, 17.25
        check("quarter track 69", dbg_head === 8'd69);
        read_track(17, 3000);
        check("17.25 reads track 17's fields", got_trk == 17 && bad == 0 && seen != 16'h0000);
        sw(4'h4); idle(20);                 // phase 2 off: phase 3 alone pulls to 70 (17.5: empty)
        check("quarter track 70", dbg_head === 8'd70);
        n = 0;
        for (i = 0; i < 200; i = i + 1) begin rdnib(b); if (b == 8'hD5) n = n + 1; end
        check("17.5 has no track: the reads are noise, never stuck", rd_ok == 1'b0);
        sw(4'h5); sw(4'h6); idle(20);       // phase 2 on, 3 off: back onto 17
        check("back on track 17", dbg_head === 8'd68);
        sw(4'h4);

        // ---- write protect: the sense bit ----
        sw(4'hD); acc(4'hE, 1'b0, 8'h00, b);
        check("writable: the sense bit is clear", b[7] === 1'b0);
        store.writable = 2'b00;
        sw(4'hD); acc(4'hE, 1'b0, 8'h00, b);
        check("write protected: the sense bit is set", b[7] === 1'b1);
        store.writable = 2'b01;
        sw(4'hC);

        // ---- write sector 5 of track 17 with RWTS's timing ----
        for (i = 0; i < 256; i = i + 1) ov[i] = (i * 29 + 7) ^ 8'hA5;
        ov[0] = 8'h00; ov[1] = 8'hFF; ov[255] = 8'h03;
        fl_n = 0; fl_lo = 99999; fl_hi = -1;
        write_sector(17, 5, 1'b0);
        ov_t = 17; ov_p = 5;
        idle(100);
        read_track(17, 14000);
        check("track 17 after the write: sector 5 is the new data, the rest unchanged", seen == 16'hFFFF && bad == 0);
        // the DDR3: only track 17's blocks changed, and fl_wr said which
        changed = 0; outside = 0;
        for (i = 0; i < WORDS; i = i + 1)
            if (mem[i] !== orig[i]) begin
                changed = changed + 1;
                if (i / 256 < 3 + 17 * 13 || i / 256 >= 3 + 18 * 13) outside = outside + 1;
            end
        $display("   the write changed %0d DDR3 words; fl_wr %0d times, blocks %0d..%0d", changed, fl_n, fl_lo, fl_hi);
        check("the write changed DDR3 words of track 17 only", changed > 100 && outside == 0);
        check("fl_wr named track 17's blocks", fl_n > 0 && fl_lo >= 3 + 17 * 13 && fl_hi >= fl_lo && fl_hi < 3 + 18 * 13);
        seek(16); read_track(16, 14000);
        check("track 16 is untouched", seen == 16'hFFFF && bad == 0);

        // ---- a write-protected disk takes no writes ----
        store.writable = 2'b00;
        for (i = 0; i < WORDS; i = i + 1) orig[i] = mem[i];
        write_sector(16, 2, 1'b1);
        idle(100);
        n = 0;
        for (i = 0; i < WORDS; i = i + 1) if (mem[i] !== orig[i]) n = n + 1;
        check("a protected disk's DDR3 is unchanged by a write", n == 0);
        store.writable = 2'b01;

        // ---- drive 2: no disk ----
        sw(4'hB); idle(50);
        for (i = 0; i < 100; i = i + 1) rdnib(b);
        check("drive 2 empty: noise, not stuck", rd_ok == 1'b0);
        sw(4'hD); acc(4'hE, 1'b0, 8'h00, b);
        check("drive 2 empty: write protected", b[7] === 1'b1);
        check("a disk is in some drive", dbg_any_disk === 1'b1);

        $display("   %0d CPU steps lost to stalls", lost);
        if (fails == 0) $display("tb_disk2: PASS (%0d checks)", checks);
        else            $display("FAIL: tb_disk2 failed %0d of %0d checks", fails, checks);
        $finish;
    end

    initial begin
        #4000000000;
        $display("FAIL: tb_disk2 timed out");
        $finish;
    end
endmodule

`default_nettype wire
