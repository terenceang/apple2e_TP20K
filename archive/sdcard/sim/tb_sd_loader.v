// tb_sd_loader: sd_loader against a behavioural SDHC card (SPI mode) and a stub
// of prodos_card's upload port that drops the first push (as the card does when
// its block FSM is busy), and a stub of disk2_store's ports.  Checks every byte/address,
// up_last, write-back, the Disk II save/reload round trip, and the no-card case.
`timescale 1ns/1ps
module tb_sd_loader;
    localparam BLOCKS = 2;
    reg clk = 0, reset = 1;
    always #18.5 clk = ~clk;

    // ---- DUT ----
    wire sd_clk, sd_mosi, sd_cs_n, up_go, up_last, loading, fail;
    wire [7:0] up_data; wire [20:0] up_addr, dn_addr;
    reg  present = 1;               // 0 = no card: MISO stays high
    wire sd_miso;
    reg  up_done = 0;
    // Disk II store stub
    reg  [7:0] d2mem [0:143359];
    wire d2_up_go, d2_up_last, d2_dn_go, d2_own; wire [17:0] d2_up_addr, d2_dn_addr;
    reg  d2_up_done = 0, d2_dn_valid = 0, d2_save = 0; reg [7:0] d2_dn_data;
    wire dn_go, wr_ack; reg wr_req = 0; reg [11:0] wr_blk = 0; reg dn_valid = 0; reg [7:0] dn_data;
    sd_loader #(.BLOCKS(BLOCKS), .PWR_BITS(8)) dut (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n), .up_go(up_go), .up_data(up_data), .up_addr(up_addr),
        .up_last(up_last), .up_busy(1'b0), .up_done(up_done),
        .down_go(dn_go), .down_addr(dn_addr), .down_data(dn_data), .down_valid(dn_valid),
        .wr_req(wr_req), .wr_blk(wr_blk), .wr_ack(wr_ack),
        .d2_up_go(d2_up_go), .d2_up_addr(d2_up_addr), .d2_up_last(d2_up_last),
        .d2_up_busy(1'b0), .d2_up_done(d2_up_done),
        .d2_dn_go(d2_dn_go), .d2_dn_addr(d2_dn_addr), .d2_dn_data(d2_dn_data), .d2_dn_valid(d2_dn_valid),
        .d2_save(d2_save), .d2_own(d2_own), .loading(loading), .fail(fail));

    integer d2_lasts = 0;
    reg [2:0] d2_pipe = 0; reg [17:0] d2_a;
    always @(posedge clk) begin
        d2_up_done <= 0; d2_dn_valid <= 0;
        if (d2_up_go) begin d2_up_done <= 1; d2mem[d2_up_addr] <= up_data; if (d2_up_last) d2_lasts <= d2_lasts + 1; end
        if (d2_dn_go) begin d2_pipe <= 3'b100; d2_a <= d2_dn_addr; end
        else if (d2_pipe) begin d2_pipe <= d2_pipe >> 1;
            if (d2_pipe == 3'b001) begin d2_dn_valid <= 1; d2_dn_data <= d2mem[d2_a]; end end
    end

    // ---- upload port stub ----
    reg [7:0] got [0:BLOCKS*512-1];
    integer count = 0, lasts = 0, errs = 0;
    reg dropped = 0;
    always @(posedge clk) begin
        up_done <= 0;
        if (up_go) begin
            if (!dropped) dropped <= 1;
            else begin
                up_done <= 1;
                got[up_addr] <= up_data; count <= count + 1;
                if (up_last) lasts <= lasts + 1;
            end
        end
    end

    // download stub: answers 3 clocks after down_go from the uploaded image
    reg [2:0] dn_pipe = 0; reg [20:0] dn_a;
    always @(posedge clk) begin
        dn_valid <= 0;
        if (dn_go) begin dn_pipe <= 3'b100; dn_a <= dn_addr; end
        else if (dn_pipe) begin dn_pipe <= dn_pipe >> 1;
            if (dn_pipe == 3'b001) begin dn_valid <= 1; dn_data <= got[dn_a]; end end
    end

    // ---- SD card model ----
    reg [7:0] d2card [0:281*512-1]; integer d2w = 0;   // card sectors 4096..4376
    reg [7:0] wmem [0:BLOCKS*512-1]; reg [BLOCKS-1:0] wvalid = 0; integer wst = 0, wn = 0, wblk = 0, wbytes = 0;
    function [7:0] pat(input [31:0] b, input [8:0] o); pat = b * 7 + o * 3 + 1; endfunction
    reg [7:0] q [0:2047]; integer qh = 0, qt = 0;
    reg [7:0] rxs, txs = 8'hFF, nxt; reg pend = 0; integer nb = 0, cn = 0, a41 = 0, i;
    reg [7:0] cmd [0:5];
    assign sd_miso = !present ? 1'b1 : sd_cs_n ? 1'b1 : txs[7];
    task push(input [7:0] b); begin q[qt % 2048] = b; qt = qt + 1; end endtask
    always @(posedge sd_clk) begin
        rxs = {rxs[6:0], sd_mosi}; nb = nb + 1;
        if (nb == 8) begin
            nb = 0;
            if (wst != 0) begin
                if (wst == 1) begin if (rxs == 8'hFE) begin wst = 2; wn = 0; end end
                else if (wst == 2) begin if (wblk >= 4096) d2card[(wblk-4096)*512 + wn] = rxs; else wmem[wblk*512 + wn] = rxs; wn = wn + 1; if (wn == 512) begin wst = 3; wn = 0; end end
                else begin wn = wn + 1; if (wn == 2) begin wst = 0; push(8'hE5); push(0); push(0); push(0); if (wblk >= 4096) d2w = d2w + 1; else begin wbytes = wbytes + 1; wvalid[wblk] = 1; end end end
            end else if (cn > 0 || rxs[7:6] == 2'b01) begin
                cmd[cn] = rxs; cn = cn + 1;
                if (cn == 6) begin
                    cn = 0; push(8'hFF);
                    case (cmd[0][5:0])
                        0: push(8'h01);
                        8: begin push(8'h01); push(0); push(0); push(1); push(8'hAA); end
                        55: push(8'h01);
                        41: begin a41 = a41 + 1; push(a41 < 2 ? 8'h01 : 8'h00); end
                        17: begin
                            if ({cmd[1],cmd[2],cmd[3],cmd[4]} >= BLOCKS && {cmd[1],cmd[2],cmd[3],cmd[4]} < 4096) errs = errs + 1;
                            push(0); push(8'hFF); push(8'hFF); push(8'hFE);
                            for (i = 0; i < 512; i = i + 1) push({cmd[1],cmd[2],cmd[3],cmd[4]} >= 4096 ? d2card[({cmd[1],cmd[2],cmd[3],cmd[4]}-4096)*512 + i] : wvalid[{cmd[1],cmd[2],cmd[3],cmd[4]}] ? wmem[{cmd[1],cmd[2],cmd[3],cmd[4]}*512 + i] : pat({cmd[1],cmd[2],cmd[3],cmd[4]}, i));
                            push(0); push(0);
                        end
                        24: begin push(0); wst = 1; wblk = {cmd[1],cmd[2],cmd[3],cmd[4]}; end
                        default: errs = errs + 1;
                    endcase
                end
            end
            pend = 1;
            if (qh < qt) begin nxt = q[qh % 2048]; qh = qh + 1; end else nxt = 8'hFF;
        end
    end
    // a real card changes MISO on the falling edge, so a new byte appears there
    always @(negedge sd_clk) begin
        if (pend) begin txs = nxt; pend = 0; end else txs = {txs[6:0], 1'b1};
    end

    integer k;
    initial begin
        for (i = 0; i < 281*512; i = i + 1) d2card[i] = 0;
        for (i = 0; i < 143360; i = i + 1) d2mem[i] = 0;
        #200 reset = 0;
        wait (!loading);
        if (fail) begin $display("FAIL: loader failed with card present ph=%0d n=%0d a41=%0d errs=%0d", dut.ph, dut.n, a41, errs); $finish; end
        if (count != BLOCKS*512) $display("FAIL: %0d bytes, want %0d", count, BLOCKS*512);
        else if (lasts != 1)     $display("FAIL: up_last seen %0d times", lasts);
        else if (errs != 0)      $display("FAIL: %0d card-side protocol errors", errs);
        else begin
            k = 0;
            for (i = 0; i < BLOCKS*512; i = i + 1)
                if (got[i] !== pat(i / 512, i % 512)) k = k + 1;
            if (k) $display("FAIL: %0d wrong bytes", k);
            else begin
                // self-test (last sector) runs by itself after the load
                wait (dut.tdone && !dut.tst);
                if (dut.tres != 1) begin $display("FAIL: selftest result %0d", dut.tres); $finish; end
                wbytes = 0;
                // write-back: change block 1 in the "SDRAM" image, request it
                for (i = 512; i < 1024; i = i + 1) got[i] = ~got[i];
                wr_blk = 1; wr_req = 1;
                begin : w
                    integer t; t = 0;
                    while (!wr_ack && t < 2000000) begin @(posedge clk); t = t + 1; end
                    @(posedge clk); wr_req = 0;
                end
                k = 0;
                for (i = 0; i < 512; i = i + 1) if (wmem[512 + i] !== got[512 + i]) k = k + 1;
                if (wbytes != 1 || k) begin $display("FAIL: write-back wrote %0d blocks, %0d wrong bytes", wbytes, k); $finish; end
                // Disk II: nothing on the card yet, so boot must leave the store alone
                wait (dut.d2done && dut.st == 11);
                if (dut.dst != 0 || d2_lasts != 0) begin $display("FAIL: d2 state %0d with no image on the card", dut.dst); $finish; end
                // an upload finished: the store's contents must be copied to the card
                for (i = 0; i < 143360; i = i + 1) d2mem[i] = i * 5 + (i >> 9);
                @(posedge clk); #1 d2_save = 1; @(posedge clk); #1 d2_save = 0;
                begin : sv
                    integer t; t = 0;
                    while (dut.dst != 4 && dut.dst != 5 && t < 30000000) begin @(posedge clk); t = t + 1; end
                end
                if (dut.dst != 4) begin $display("FAIL: d2 save ended in state %0d st=%0d sv_pend=%0d cnt=%0d d2done=%0d wr_req=%0d fail=%0d", dut.dst, dut.st, dut.sv_pend, dut.sv_cnt, dut.d2done, wr_req, fail); $finish; end
                k = 0;
                for (i = 0; i < 143360; i = i + 1) if (d2card[i] !== d2mem[i]) k = k + 1;
                if (k || d2w != 281 || d2card[280*512] !== "D" || d2card[280*512+4] !== "G") begin
                    $display("FAIL: d2 save: %0d wrong bytes, %0d sectors written", k, d2w); $finish;
                end
                // power cycle: the store is empty again, the card's image must come back
                for (i = 0; i < 143360; i = i + 1) d2mem[i] = 0;
                reset = 1; #200 reset = 0;
                begin : ldw
                    integer t; t = 0;
                    while (dut.dst != 2 && dut.dst != 5 && t < 30000000) begin @(posedge clk); t = t + 1; end
                end
                if (dut.dst != 2) begin $display("FAIL: d2 load ended in state %0d", dut.dst); $finish; end
                k = 0;
                for (i = 0; i < 143360; i = i + 1) if (d2mem[i] !== ((i * 5 + (i >> 9)) & 8'hFF)) k = k + 1;
                if (k || d2_lasts != 1) begin $display("FAIL: d2 load: %0d wrong bytes, up_last %0d times", k, d2_lasts); $finish; end
                // no card: must give up cleanly instead of hanging
                present = 0; reset = 1; #200 reset = 0;
                wait (!loading);
                if (!fail) $display("FAIL: no card but fail not set");
                else begin
                    wr_req = 1; #100000; wr_req = 0;
                    $display("PASS");
                end
            end
        end
        $finish;
    end
    initial begin #2_000_000_000; $display("FAIL: timeout"); $finish; end
endmodule
