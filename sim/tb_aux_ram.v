`timescale 1ns / 1ps
`default_nettype none

// aux_ram against sim/models/ddr3_model.v (the Gowin DDR3 IP's native
// interface) on its own unrelated ~100 MHz clock: the init self-test, CPU
// byte writes/reads (neighbours in one burst included), the video line fill
// racing CPU traffic and finishing inside the horizontal blanking, and
// disk-store words, across the clock crossing.  The model prints FAIL for a
// command the IP would not take.
module tb_aux_ram;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;
    reg mem_clk = 1'b0;              // 398.25 MHz memory clock; clk_out is a quarter, not a multiple of clk
    always #1.2555 mem_clk = ~mem_clk;

    reg reset = 1'b1;
    reg fill_start = 1'b0;
    reg [15:0] fill_addr = 16'd0;
    reg [5:0] col = 6'd0;
    wire [7:0] line_data;
    reg rd_want = 1'b0;
    reg [16:0] rd_addr = 17'd0;
    wire [7:0] rd_data;
    wire rd_hit;
    reg wr_go = 1'b0;
    reg [16:0] wr_addr = 17'd0;
    reg [7:0] wr_data = 8'd0;
    wire wr_busy;

    reg dsk_go = 1'b0, dsk_we = 1'b0;
    reg [21:0] dsk_addr = 22'd0;
    reg [15:0] dsk_wdata = 16'd0;
    wire [15:0] dsk_rdata;
    wire dsk_ack, dsk_idle, ready;
    wire [15:0] ddr_dq;
    wire [1:0] ddr_dqs, ddr_dqs_n;

    aux_ram dut (
        .clk(clk), .reset(reset),
        .ddr_clk(clk),
        .fill_start(fill_start), .fill_addr(fill_addr), .col(col), .line_data(line_data),
        .rd_want(rd_want), .rd_addr(rd_addr), .rd_data(rd_data), .rd_hit(rd_hit),
        .wr_go(wr_go), .wr_addr(wr_addr), .wr_data(wr_data), .wr_busy(wr_busy),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack), .dsk_idle(dsk_idle), .ready(ready),
        .ddr_memory_clk(mem_clk), .ddr_lock(1'b1),
        .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_DQS_n(ddr_dqs_n), .DDR3_A(), .DDR3_BA(),
        .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(), .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(),
        .DDR3_CKE(), .DDR3_nRESET(), .DDR3_ODT(), .DDR3_DM()
    );
    wire [31:0] mdl_errors    = dut.u_ddr3.errors;

    // One disk-store word access, the way disk2_store makes them (bank-1 form).
    task dsk(input we, input [17:0] w, input [15:0] d, output [15:0] q);
        begin
            @(posedge clk); while (!dsk_idle) @(posedge clk);
            dsk_go <= 1'b1; dsk_we <= we; dsk_addr <= {2'b01, 1'b0, w, 1'b0}; dsk_wdata <= d;
            @(posedge clk); dsk_go <= 1'b0;
            while (!dsk_ack) @(posedge clk);
            q = dsk_rdata;
        end
    endtask
    reg [15:0] q;

    // When the line fill actually ends (the test keeps the CPU busy past it).
    time t_fill = 0;
    reg  fill_was = 1'b0;
    always @(posedge clk) begin
        if (fill_was && !dut.fill_active) t_fill = $time;
        fill_was <= dut.fill_active;
    end

    reg [7:0] shadow [0:131071];      // aux, then main language-card RAM
    integer errors = 0, i, n, stalls;
    reg [15:0] a;
    reg [7:0] d;
    time t0, t1;

    task cpu_write(input [16:0] addr, input [7:0] data);
        begin
            @(posedge clk); #1;
            while (wr_busy) begin @(posedge clk); #1; end
            wr_go <= 1'b1; wr_addr <= addr; wr_data <= data;
            @(posedge clk); #1; wr_go <= 1'b0;
            shadow[addr] = data;
        end
    endtask

    task cpu_read(input [16:0] addr, output [7:0] data);
        begin
            @(posedge clk); rd_want <= 1'b1; rd_addr <= addr;
            @(posedge clk);
            while (!rd_hit) @(posedge clk);
            data = rd_data;
            rd_want <= 1'b0;
        end
    endtask

    task check_read(input [16:0] addr);
        reg [7:0] got;
        begin
            cpu_read(addr, got);
            if (got !== shadow[addr]) begin
                if (errors < 10) $display("FAIL: ram[%05h] = %02h, expected %02h", addr, got, shadow[addr]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 131072; i = i + 1) shadow[i] = 8'h00;
        #200; @(posedge clk); reset <= 1'b0;
        wait (ready);
        if (dut.u_ddr3.writes != 2 || dut.u_ddr3.reads != 2) begin
            $display("FAIL: self-test was %0d writes %0d reads, expected 2 and 2", dut.u_ddr3.writes, dut.u_ddr3.reads); errors = errors + 1;
        end
        t0 = $time;

        // Neighbouring bytes of one word, both orders, and the ends of the map.
        cpu_write(16'h0400, 8'h11); cpu_write(16'h0401, 8'h22);
        cpu_write(16'h0403, 8'h44); cpu_write(16'h0402, 8'h33);
        cpu_write(16'h0000, 8'h5A); cpu_write(16'hFFFF, 8'hA5); cpu_write(16'hFFFE, 8'h3C);
        check_read(16'h0400); check_read(16'h0401); check_read(16'h0402); check_read(16'h0403);
        check_read(16'h0000); check_read(16'hFFFF); check_read(16'hFFFE);
        // Main language-card RAM (bit 16) and aux at the same address are
        // different bytes.
        cpu_write(17'h0D000, 8'h11); cpu_write(17'h1D000, 8'h22);
        cpu_write(17'h1FFFF, 8'h33); cpu_write(17'h1C000, 8'h44);
        check_read(17'h0D000); check_read(17'h1D000); check_read(17'h1FFFF);
        check_read(17'h1C000); check_read(17'h0FFFF);
        // overwrite one byte of a cached word: the other byte must survive
        cpu_write(16'h0400, 8'h99);
        check_read(16'h0400); check_read(16'h0401);

        // Pseudo-random scatter
        a = 16'h1234;
        for (n = 0; n < 300; n = n + 1) begin
            a = {a[14:0], a[15] ^ a[13] ^ a[12] ^ a[10]};
            cpu_write(a, a[7:0] ^ n[7:0]);
        end
        a = 16'h1234;
        for (n = 0; n < 300; n = n + 1) begin
            a = {a[14:0], a[15] ^ a[13] ^ a[12] ^ a[10]};
            check_read(a);
        end

        // Line fill: 40 bytes at an even address, read back through the
        // video port, while the CPU keeps writing and reading elsewhere.
        for (i = 0; i < 40; i = i + 1) cpu_write(16'h0450 + i, 8'hC0 + i[7:0]);
        fill_addr <= 16'h0450;
        @(posedge clk); fill_start <= 1'b1; @(posedge clk); fill_start <= 1'b0;
        t1 = $time;
        for (n = 0; n < 12; n = n + 1) begin
            cpu_write(16'h8000 + n, n[7:0]);
            check_read(16'h8000 + n);
        end
        wait (!dut.fill_active);
        // video_generator starts the fill at the end of the active line and
        // reads the buffer ~218 pixel clocks later; keep a margin for the CPU
        // access and the refresh that can sit in front of it.
        if ((t_fill - t1) > 180 * 37.037) begin
            $display("FAIL: line fill took %0d pixel clocks", (t_fill - t1) / 37.037);
            errors = errors + 1;
        end else
            $display("line fill: %0d pixel clocks with CPU traffic", (t_fill - t1) / 37.037);
        repeat (20) @(posedge clk);
        for (i = 0; i < 40; i = i + 1) begin
            col <= i; @(posedge clk); #1;
            if (line_data !== 8'hC0 + i[7:0]) begin
                if (errors < 10) $display("FAIL: line buffer col %0d = %02h, expected %02h", i, line_data, 8'hC0 + i[7:0]);
                errors = errors + 1;
            end
        end

        // Disk store words do not alias aux RAM, and read back.
        dsk(1, 18'h00000, 16'hBEEF, q); dsk(1, 18'h3FFFF, 16'h1234, q);
        dsk(0, 18'h00000, 16'h0, q);
        if (q !== 16'hBEEF) begin $display("FAIL: disk word 0 = %04h", q); errors = errors + 1; end
        dsk(0, 18'h3FFFF, 16'h0, q);
        if (q !== 16'h1234) begin $display("FAIL: disk word 3FFFF = %04h", q); errors = errors + 1; end
        check_read(16'h0000);

        errors = errors + mdl_errors;

        if (errors == 0) $display("tb_aux_ram: PASS (%0d reads, %0d writes)", dut.u_ddr3.reads, dut.u_ddr3.writes);
        else             $display("FAIL: tb_aux_ram %0d errors", errors);
        $finish;
    end

    initial begin #60000000; $display("FAIL: tb_aux_ram timeout"); $finish; end
endmodule
