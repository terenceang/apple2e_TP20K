`timescale 1ns / 1ps
`default_nettype none

module tb_aux_test;
    reg clk = 1'b0;
    always #18.519 clk = ~clk; // 27 MHz

    reg mem_clk = 1'b0;
    always #1.2555 mem_clk = ~mem_clk; // 400 MHz DDR3 clock

    reg reset = 1'b1;

    // CPU port to aux_ram
    reg         wr_go = 1'b0;
    reg  [16:0] wr_addr = 17'd0;
    reg  [7:0]  wr_data = 8'd0;
    wire        wr_busy;

    reg         rd_want = 1'b0;
    reg  [16:0] rd_addr = 17'd0;
    wire [7:0]  rd_data;
    wire        rd_hit;
    wire        ready;

    // Video fill
    reg         fill_start = 1'b0;
    reg  [15:0] fill_addr = 16'd0;
    reg  [5:0]  col = 6'd0;
    wire [7:0]  line_data;

    wire [15:0] ddr_dq;
    wire [1:0]  ddr_dqs, ddr_dqs_n;

    aux_ram u_aux (
        .clk(clk),
        .reset(reset),
        .ddr_clk(clk),
        .fill_start(fill_start),
        .fill_addr(fill_addr),
        .col(col),
        .line_data(line_data),
        .rd_want(rd_want),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .rd_hit(rd_hit),
        .wr_go(wr_go),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .wr_busy(wr_busy),
        .dsk_go(1'b0), .dsk_addr(22'd0), .dsk_we(1'b0), .dsk_wdata(16'd0),
        .dsk_rdata(), .dsk_ack(), .dsk_idle(),
        .hd_go(1'b0), .hd_addr(25'd0), .hd_we(1'b0), .hd_be(2'b11), .hd_wdata(16'd0),
        .hd_rdata(), .hd_ack(),
        .ready(ready),
        .diag(),
        .ddr_memory_clk(mem_clk),
        .ddr_lock(1'b1),
        .DDR3_DQ(ddr_dq),
        .DDR3_DQS(ddr_dqs),
        .DDR3_DQS_n(ddr_dqs_n),
        .DDR3_A(), .DDR3_BA(), .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(),
        .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(), .DDR3_CKE(), .DDR3_nRESET(),
        .DDR3_ODT(), .DDR3_DM()
    );

    integer errors = 0;

    // Simulate periodic video line fill requests like video_generator does
    reg run_fills = 1'b0;
    always begin
        @(posedge clk);
        if (run_fills && ready) begin
            fill_start <= 1'b1;
            fill_addr  <= 16'h2000;
            @(posedge clk);
            fill_start <= 1'b0;
            // Next fill in 200 clocks
            repeat (200) @(posedge clk);
        end
    end

    task do_write(input [16:0] a, input [7:0] d);
        begin
            @(posedge clk);
            while (wr_busy) @(posedge clk);
            wr_go <= 1'b1;
            wr_addr <= a;
            wr_data <= d;
            @(posedge clk);
            wr_go <= 1'b0;
            while (wr_busy) @(posedge clk);
        end
    endtask

    task do_read(input [16:0] a, output [7:0] d);
        begin
            @(posedge clk);
            rd_want <= 1'b1;
            rd_addr <= a;
            @(posedge clk);
            while (!rd_hit) @(posedge clk);
            d = rd_data;
            rd_want <= 1'b0;
        end
    endtask

    reg [7:0] read_val;

    initial begin
        $display("Starting tb_aux_test...");
        #200;
        @(posedge clk);
        reset = 1'b0;
        while (!ready) @(posedge clk);
        $display("Ready at %t", $time);
        run_fills = 1'b1;

        // First pre-populate Language Card $EA00 with $91
        $display("Pre-populating LC $EA00 with 0x91...");
        do_write(17'h1EA00, 8'h91);
        $display("Pre-populate done at %t", $time);
        repeat (10) @(posedge clk);

        // Test 1: Write Aux RAM $2000 with $A5
        $display("Test 1: Write Aux $2000 = $A5, then immediately read LC $EA00...");
        @(posedge clk);
        while (wr_busy) @(posedge clk);
        wr_go <= 1'b1;
        wr_addr <= 17'h02000;
        wr_data <= 8'hA5;
        @(posedge clk);
        wr_go <= 1'b0;
        // Immediately on next cycle, request read of $EA00
        rd_want <= 1'b1;
        rd_addr <= 17'h1EA00;
        while (!rd_hit) begin
            $display("time=%t op_busy=%b kind=%0d rd_want=%b rd_hit=%b ack_edge=%b cache_val=%b cache_data=%02x ddr_rdata=%04x rdata=%04x m_word=%04x fb=%0d open=%b e=%0d",
                     $time, u_aux.op_busy, u_aux.kind, rd_want, rd_hit, u_aux.ack_edge, u_aux.cache_valid, u_aux.cache_data, u_aux.ddr_rdata, u_aux.rdata, u_aux.m_word, u_aux.fb, u_aux.open, u_aux.e);
            @(posedge clk);
        end
        read_val = rd_data;
        $display("Landed! time=%t cache_val=%b cache_data=%02x rd_data=%02x", $time, u_aux.cache_valid, u_aux.cache_data, rd_data);
        rd_want <= 1'b0;
        $display("Read LC $EA00 = 0x%02x (expected 0x91)", read_val);
        if (read_val !== 8'h91) begin
            $display("FAIL: LC read returned wrong data!");
            errors = errors + 1;
        end

        // Wait for write buffer to be idle
        while (wr_busy) @(posedge clk);
        repeat (10) @(posedge clk);

        // Now read back Aux RAM $2000
        $display("Reading back Aux $2000...");
        do_read(17'h02000, read_val);
        $display("Read Aux $2000 = 0x%02x (expected 0xA5)", read_val);
        if (read_val !== 8'hA5) begin
            $display("FAIL: Aux $2000 returned wrong data!");
            errors = errors + 1;
        end

        // Test 2: PutScrByte loop: write 40 consecutive bytes to Aux RAM
        // with alternating LC reads between each write!
        $display("Test 2: 40 Aux writes with LC reads in between...");
        begin : test2
            integer i;
            for (i = 0; i < 40; i = i + 1) begin
                // Write Aux $2000 + i
                @(posedge clk);
                while (wr_busy) @(posedge clk);
                wr_go <= 1'b1;
                wr_addr <= 17'h02000 + i;
                wr_data <= 8'h10 + i[7:0];
                @(posedge clk);
                wr_go <= 1'b0;

                // Immediately read LC $EA00
                rd_want <= 1'b1;
                rd_addr <= 17'h1EA00;
                @(posedge clk);
                while (!rd_hit) @(posedge clk);
                rd_want <= 1'b0;
            end
        end

        while (wr_busy) @(posedge clk);
        repeat (20) @(posedge clk);

        // Verify all 40 bytes in Aux RAM
        begin : check2
            integer i;
            for (i = 0; i < 40; i = i + 1) begin
                do_read(17'h02000 + i, read_val);
                if (read_val !== (8'h10 + i[7:0])) begin
                    $display("FAIL at index %0d: got 0x%02x, expected 0x%02x", i, read_val, 8'h10 + i[7:0]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("ALL TESTS PASSED!");
        else
            $display("TESTS FAILED with %0d errors!", errors);
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
