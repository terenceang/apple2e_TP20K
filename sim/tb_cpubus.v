`timescale 1ns / 1ps
`default_nettype none

// tb_cpubus.v -- the 65C02 core's bus, cycle by cycle, against the W65C02S
// datasheet's caveats (the differences from the NMOS 6502 that software and
// soft switches can see):
//   * indexed addressing across a page: the extra cycle reads the LAST
//     INSTRUCTION BYTE, not the invalid (un-carried) address
//   * read-modify-write: TWO reads of the effective address, then one write
//     (the NMOS part writes twice) -- so INC $C083 is two reads of a language
//     card switch, as on a real //e
//   * JMP (abs) takes 6 cycles and does not wrap within the pointer's page
//   * ADC/SBC in decimal mode take one cycle more
// The core is driven as apple2_core drives it: RDY every clock here, data in
// the clock after the address (synchronous RAM).
module tb_cpubus;
    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg reset = 1'b1;

    wire [15:0] ab;
    wire [7:0]  dout;
    wire        we, sync;
    reg  [7:0]  din = 8'h00;
    reg  [7:0]  mem [0:65535];

    cpu_65c02 u_cpu (.clk(clk), .reset(reset), .AB(ab), .DI(din), .DO(dout), .WE(we),
                     .IRQ(1'b0), .NMI(1'b0), .RDY(1'b1), .SYNC(sync),
                     .debug_a(), .debug_x(), .debug_y(), .debug_s(), .debug_p(), .debug_pc(), .debug_ir());

    // the trace: one entry per cycle
    reg  [15:0] t_a  [0:255];
    reg         t_w  [0:255];
    reg         t_s  [0:255];
    integer     tn = 0, tracing = 0;
    always @(posedge clk) begin
        din <= mem[ab];
        if (we) mem[ab] <= dout;
        if (tracing && tn < 256) begin t_a[tn] = ab; t_w[tn] = we; t_s[tn] = sync; tn = tn + 1; end
    end

    integer fails = 0, checks = 0;
    task check(input [8*72-1:0] what, input ok);
        begin checks = checks + 1; if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end end
    endtask

    // the cycles of the instruction whose opcode fetch is at `pc`, up to the next SYNC
    integer at, len;
    // (this core raises SYNC the cycle after its opcode fetch)
    task find(input [15:0] pc);
        begin
            at = -1;
            for (len = 0; len + 1 < tn; len = len + 1) if (at < 0 && t_s[len + 1] && t_a[len] == pc) at = len;
            len = 1;
            if (at >= 0) while (at + len + 1 < tn && !t_s[at + len + 1]) len = len + 1;
        end
    endtask
    task show(input [8*24-1:0] name);
        integer k;
        begin
            $write("   %0s (%0d cycles):", name, len);
            for (k = 0; k < len; k = k + 1) $write(" %s%04h", t_w[at + k] ? "W" : "R", t_a[at + k]);
            $write("\n");
        end
    endtask
    function cyc(input integer k, input [15:0] a, input w);
        cyc = (t_a[at + k] == a) && (t_w[at + k] == w);
    endfunction

    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h02;
        // 0200 LDX #1 / LDA $10FF,X / LDA $1000,X / STA $10FF,X / STA $1000,X
        // 020E INC $1234 / INC $12FF,X / JMP ($13FF)
        {mem[16'h200], mem[16'h201]} = {8'hA2, 8'h01};
        {mem[16'h202], mem[16'h203], mem[16'h204]} = {8'hBD, 8'hFF, 8'h10};
        {mem[16'h205], mem[16'h206], mem[16'h207]} = {8'hBD, 8'h00, 8'h10};
        {mem[16'h208], mem[16'h209], mem[16'h20A]} = {8'h9D, 8'hFF, 8'h10};
        {mem[16'h20B], mem[16'h20C], mem[16'h20D]} = {8'h9D, 8'h00, 8'h10};
        {mem[16'h20E], mem[16'h20F], mem[16'h210]} = {8'hEE, 8'h34, 8'h12};
        {mem[16'h211], mem[16'h212], mem[16'h213]} = {8'hFE, 8'hFF, 8'h12};
        {mem[16'h214], mem[16'h215], mem[16'h216]} = {8'h6C, 8'hFF, 8'h13};
        mem[16'h13FF] = 8'h00; mem[16'h1400] = 8'h03; mem[16'h1300] = 8'h05;   // NMOS would go to $0500
        // 0300 SED / ADC #1 / CLD / LDY #1 / LDA ($40),Y / JMP *   ($40 -> $10FF)
        mem[16'h300] = 8'hF8;
        {mem[16'h301], mem[16'h302]} = {8'h69, 8'h01};
        mem[16'h303] = 8'hD8;
        {mem[16'h304], mem[16'h305]} = {8'hA0, 8'h01};
        {mem[16'h306], mem[16'h307]} = {8'hB1, 8'h40};
        {mem[16'h308], mem[16'h309], mem[16'h30A]} = {8'h4C, 8'h08, 8'h03};
        {mem[16'h40], mem[16'h41]} = {8'hFF, 8'h10};
        mem[16'h0500] = 8'h00;     // BRK there: a wrapped JMP lands somewhere obvious
        repeat (4) @(posedge clk);
        @(negedge clk) reset = 1'b0;
        tracing = 1;
        repeat (120) @(posedge clk);
        tracing = 0;

        $display("=== tb_cpubus ===");
        if ($test$plusargs("dump")) begin
            for (i = 0; i < 70; i = i + 1) $write("%0d:%s%04h%s ", i, t_w[i] ? "W" : "R", t_a[i], t_s[i] ? "*" : "");
            $display("");
        end
        find(16'h0202); show("LDA $10FF,X (crosses)");
        check("LDA abs,X across a page: 5 cycles", len == 5);
        check("...its extra cycle reads the last instruction byte ($0204)", cyc(3, 16'h0204, 0));
        check("...then the carried address ($1100)", cyc(4, 16'h1100, 0));
        find(16'h0205); show("LDA $1000,X");
        check("LDA abs,X within a page: 4 cycles, no extra read", len == 4 && cyc(3, 16'h1001, 0));
        find(16'h0208); show("STA $10FF,X (crosses)");
        check("STA abs,X across a page: extra read of the last instruction byte, then write $1100",
              len == 5 && cyc(3, 16'h020A, 0) && cyc(4, 16'h1100, 1));
        find(16'h020B); show("STA $1000,X");
        check("STA abs,X within a page: 5 cycles, write $1001 last", len == 5 && cyc(4, 16'h1001, 1));
        find(16'h020E); show("INC $1234");
        check("INC abs: 6 cycles: read, read again, write ($1234)",
              len == 6 && cyc(3, 16'h1234, 0) && cyc(4, 16'h1234, 0) && cyc(5, 16'h1234, 1));
        find(16'h0211); show("INC $12FF,X (crosses)");
        check("INC abs,X across a page: 7 cycles, two reads then one write of $1300",
              len == 7 && cyc(4, 16'h1300, 0) && cyc(5, 16'h1300, 0) && cyc(6, 16'h1300, 1));
        check("...and no read of the un-carried $1200", !cyc(3, 16'h1200, 0) && !cyc(4, 16'h1200, 0));
        find(16'h0214); show("JMP ($13FF)");
        check("JMP (abs): 6 cycles", len == 6);
        check("...and the pointer does not wrap: on to $0300", t_a[at + len] == 16'h0300);
        find(16'h0301); show("ADC #1 (decimal)");
        check("ADC in decimal mode: 3 cycles (one more than binary)", len == 3);
        find(16'h0306); show("LDA ($40),Y (crosses)");
        check("LDA (zp),Y across a page: 6 cycles, extra read of the last instruction byte ($0307)",
              len == 6 && cyc(4, 16'h0307, 0) && cyc(5, 16'h1100, 0));

        if (fails == 0) $display("tb_cpubus: PASS (%0d checks)", checks);
        else            $display("FAIL: tb_cpubus: %0d of %0d checks", fails, checks);
        $finish;
    end
endmodule

`default_nettype wire
