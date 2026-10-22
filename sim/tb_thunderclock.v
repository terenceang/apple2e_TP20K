`timescale 1ns / 1ps
`default_nettype none

// tb_thunderclock -- src/thunderclock.v on its own, with a 4-clock second.
//
// The $C5xx signature ProDOS looks for, the string its driver parses
// ("MO,0W,DD,HH,MI,SS" + CR in high-bit ASCII, read at $C0D0 after $C0D1),
// that the string does not move while it is read across a tick, and every
// rollover: a second, a 30-day month, February in leap and common years
// with both an even and an odd tens digit, and 1999-12-31 23:59:59 into 2000.
module tb_thunderclock;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;

    reg         bus_cycle = 1'b0, cpu_we = 1'b0, set = 1'b0;
    reg  [15:0] addr = 16'h0000;
    reg  [51:0] set_time = 52'd0;
    wire [7:0]  rom_data, io_data;

    thunderclock #(.TICKS(25'd4)) dut (
        .clk(clk), .bus_cycle(bus_cycle), .cpu_we(cpu_we), .addr(addr),
        .set(set), .set_time(set_time), .rom_data(rom_data), .io_data(io_data));

    integer fails = 0, i;
    reg [8*18-1:0] got;
    reg [7:0] b;

    // one CPU read: the byte, then the access's side effect on the edge
    task rd(input [15:0] a, output [7:0] d);
        begin
            @(negedge clk); addr = a; bus_cycle = 1'b1; #1 d = io_data;
            @(posedge clk); #1 bus_cycle = 1'b0;
        end
    endtask
    // what ProDOS's driver gets: $C0D1, then $C0D0 up to the CR
    task read_str;
        begin
            rd(16'hC0D1, b); got = 0;
            for (i = 0; i < 18; i = i + 1) begin rd(16'hC0D0, b); got = {got[8*17-1:0], b & 8'h7F}; end
        end
    endtask
    task set_to(input [51:0] t);
        begin @(negedge clk); set_time = t; set = 1'b1; @(negedge clk); set = 1'b0; end
    endtask
    task expect_str(input [8*18-1:0] want, input [8*40-1:0] what);
        begin
            read_str;
            if (got !== want) begin
                $display("FAIL: %0s: got \"%0s\", want \"%0s\"", what, got[8*18-1:8], want[8*18-1:8]);
                fails = fails + 1;
            end
        end
    endtask
    // the time after `n` seconds from t (the set lands on a tick boundary)
    task after(input [51:0] t, input integer n);
        begin set_to(t); repeat (4 * n) @(posedge clk); end
    endtask

    initial begin
        // ---- signature and entry points ----
        for (i = 0; i < 8; i = i + 2) begin
            addr = 16'hC500 + i; #1;
            if (rom_data !== (i == 0 ? 8'h08 : i == 2 ? 8'h28 : i == 4 ? 8'h58 : 8'h70)) begin
                $display("FAIL: $C5%02x = %02x", i, rom_data); fails = fails + 1;
            end
        end
        addr = 16'hC501; #1; if (rom_data === 8'h20) begin $display("FAIL: $C501 = $20 (Autostart would boot it)"); fails = fails + 1; end
        addr = 16'hC508; #1; if (rom_data !== 8'h4C) begin $display("FAIL: $C508 is not a JMP"); fails = fails + 1; end
        addr = 16'hC50B; #1; if (rom_data !== 8'h60) begin $display("FAIL: $C50B is not an RTS"); fails = fails + 1; end

        // ---- the string ----
        // 2026-10-22, Thursday (4), 13:45:07
        set_to({8'h26, 8'h10, 8'h22, 4'd4, 8'h13, 8'h45, 8'h07});
        expect_str({"10,04,22,13,45,07", 8'h0D}, "the string");
        // high bit set on every byte (ProDOS subtracts "0" = $B0)
        rd(16'hC0D1, b); rd(16'hC0D0, b);
        if (b !== 8'hB1) begin $display("FAIL: first byte %02x, want $B1", b); fails = fails + 1; end
        // it stays on the CR once it gets there
        rd(16'hC0D1, b); for (i = 0; i < 20; i = i + 1) rd(16'hC0D0, b);
        if (b !== 8'h8D) begin $display("FAIL: past the end reads %02x, want the CR", b); fails = fails + 1; end

        // ---- rollovers ----
        after({8'h26, 8'h10, 8'h22, 4'd4, 8'h13, 8'h45, 8'h07}, 1);
        expect_str({"10,04,22,13,45,08", 8'h0D}, "one second");
        after({8'h26, 8'h04, 8'h30, 4'd4, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"05,05,01,00,00,00", 8'h0D}, "30 April");
        after({8'h24, 8'h02, 8'h28, 4'd3, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"02,04,29,00,00,00", 8'h0D}, "28 Feb 2024 (leap)");
        after({8'h25, 8'h02, 8'h28, 4'd5, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"03,06,01,00,00,00", 8'h0D}, "28 Feb 2025");
        after({8'h99, 8'h12, 8'h31, 4'd6, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"01,00,01,00,00,00", 8'h0D}, "31 Dec 1999");
        if (dut.yy !== 8'h00) begin $display("FAIL: year after 99 is %02x", dut.yy); fails = fails + 1; end
        // an odd tens digit takes the other half of the year % 4 rule
        after({8'h12, 8'h02, 8'h28, 4'd2, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"02,03,29,00,00,00", 8'h0D}, "28 Feb 2012 (leap)");
        after({8'h14, 8'h02, 8'h28, 4'd5, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"03,06,01,00,00,00", 8'h0D}, "28 Feb 2014");
        after({8'h00, 8'h02, 8'h28, 4'd1, 8'h23, 8'h59, 8'h59}, 1);
        expect_str({"02,02,29,00,00,00", 8'h0D}, "28 Feb 2000 (leap)");

        // ---- a read that spans a tick sees one time ----
        set_to({8'h26, 8'h10, 8'h22, 4'd4, 8'h13, 8'h45, 8'h59});
        rd(16'hC0D1, b); got = 0;
        for (i = 0; i < 18; i = i + 1) begin
            rd(16'hC0D0, b); got = {got[8*17-1:0], b & 8'h7F};
            repeat (3) @(posedge clk);               // ~7 seconds go by
        end
        if (got !== {"10,04,22,13,45,59", 8'h0D}) begin
            $display("FAIL: torn read \"%0s\"", got[8*18-1:8]); fails = fails + 1;
        end

        if (fails == 0) $display("tb_thunderclock: PASS");
        else            $display("tb_thunderclock: FAIL (%0d)", fails);
        $finish;
    end
endmodule

`default_nettype wire
