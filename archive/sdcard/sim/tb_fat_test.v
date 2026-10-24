// tb_fat_test: the raw FAT32 smoke test (fat_test on fat32) against sim/models/sdcard.v holding
// an MBR + FAT32 volume with an existing file.  Decodes the UART and checks the card afterwards:
// the neighbours are intact and TEST.TXT and its cluster are gone again.  The details of the
// file layer are in tb_fat32.
`timescale 1ns/1ps
module tb_fat_test;
    localparam PART = 100, FAT1 = 132, FAT2 = 140, DATA = 148;
    reg clk = 0, reset = 1;
    always #18.5 clk = ~clk;

    wire sd_clk, sd_mosi, sd_cs_n, sd_miso, uart_tx, pass, failed;
    fat_test #(.PWR_BITS(8), .REPEAT_BITS(18)) dut (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n), .uart_tx(uart_tx), .pass(pass), .failed(failed));
    sdcard #(.SECTORS(1024)) card (.sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso));

    integer i, errs = 0;
    task put32(input integer a, input [31:0] v);
        begin card.mem[a] = v[7:0]; card.mem[a+1] = v[15:8]; card.mem[a+2] = v[23:16]; card.mem[a+3] = v[31:24]; end
    endtask
    initial begin
        for (i = 0; i < 1024*512; i = i + 1) card.mem[i] = 0;
        card.mem[446+4] = 8'h0C; put32(446+8, PART); card.mem[510] = 8'h55; card.mem[511] = 8'hAA;
        card.mem[PART*512+12] = 2; card.mem[PART*512+13] = 2; card.mem[PART*512+14] = 32; card.mem[PART*512+16] = 2;
        put32(PART*512+36, 8); put32(PART*512+44, 2);
        card.mem[PART*512+82]="F"; card.mem[PART*512+83]="A"; card.mem[PART*512+84]="T"; card.mem[PART*512+85]="3"; card.mem[PART*512+86]="2";
        for (i = 0; i < 2; i = i + 1) begin
            put32((i ? FAT2 : FAT1)*512 + 0, 32'h0FFFFFF8); put32((i ? FAT2 : FAT1)*512 + 4, 32'h0FFFFFFF);
            put32((i ? FAT2 : FAT1)*512 + 8, 32'h0FFFFFFF); put32((i ? FAT2 : FAT1)*512 + 12, 32'h0FFFFFFF);   // root, VOLUME.DAT
        end
        card.mem[DATA*512+0]="V"; card.mem[DATA*512+1]="O"; card.mem[DATA*512+8]="D";
        card.mem[DATA*512+11] = 8'h20; card.mem[DATA*512+26] = 3;
    end

    // ---- UART decoder (115200 8N1 = 234 clocks/bit) ----
    reg [7:0] log [0:1023]; integer ln = 0; reg rxbusy = 0; reg [7:0] rb; integer bi;
    always @(negedge uart_tx) if (!rxbusy) begin
        rxbusy = 1; repeat (117) @(posedge clk);
        for (bi = 0; bi < 8; bi = bi + 1) begin repeat (234) @(posedge clk); rb[bi] = uart_tx; end
        repeat (234) @(posedge clk);
        log[ln] = rb; ln = ln + 1; rxbusy = 0;
    end
    function has(input [8*24-1:0] s, input integer len);      // s right-aligned, len chars
        integer p, q2, ok;
        begin
            has = 0;
            for (p = 0; p + len <= ln; p = p + 1) begin
                ok = 1;
                for (q2 = 0; q2 < len; q2 = q2 + 1) if (log[p + q2] !== s[8*(len-1-q2) +: 8]) ok = 0;
                if (ok) has = 1;
            end
        end
    endfunction

    integer t;
    initial begin
        #200 reset = 0;
        t = 0;
        while (!pass && !failed && t < 4000000) begin @(posedge clk); t = t + 1; end
        if (failed) begin $display("FAIL: fat_test failed: step %0d st=%0d ecode=%0d", dut.step, dut.st, dut.ecode); $finish; end
        if (!pass) begin $display("FAIL: timeout st=%0d step=%0d", dut.st, dut.step); $finish; end
        repeat (400000) @(posedge clk);
        // TEST.TXT is gone (its entry deleted) and cluster 4 is free again in both FATs
        if (card.mem[DATA*512 + 32] !== 8'hE5) begin $display("FAIL: entry not deleted"); errs = errs + 1; end
        if ({card.mem[FAT1*512+19], card.mem[FAT1*512+18], card.mem[FAT1*512+17], card.mem[FAT1*512+16]} !== 0 ||
            {card.mem[FAT2*512+19], card.mem[FAT2*512+18], card.mem[FAT2*512+17], card.mem[FAT2*512+16]} !== 0)
            begin $display("FAIL: FAT entry 4 not freed"); errs = errs + 1; end
        if (card.mem[DATA*512] !== "V" || card.mem[FAT1*512+12] !== 8'hFF || card.mem[FAT2*512+12] !== 8'hFF)
            begin $display("FAIL: neighbours damaged"); errs = errs + 1; end
        if (!has("PASS", 4) || !has("CREATE test.txt OK", 18) || !has("READ OK: Hello World", 20))
            begin $display("FAIL: uart log incomplete (%0d chars)", ln); errs = errs + 1; end
        if (card.errs != 0) begin $display("FAIL: card protocol errors"); errs = errs + 1; end
        if (errs == 0) $display("PASS"); else $display("FAIL: %0d errors", errs);
        $finish;
    end
    initial begin #2_000_000_000; $display("FAIL: sim timeout"); $finish; end
endmodule
