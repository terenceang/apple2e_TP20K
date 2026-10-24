`timescale 1ns / 1ps
`default_nettype none

// tb_cpusst.v -- the 65C02 core against a real chip, cycle by cycle.
//
// build/sst65c02.txt (sim/sst65c02.py: Tom Harte's SingleStepTests for the
// Synertek 65C02, the 65SC02 kind of part an enhanced //e has) holds, per
// case, the chip's registers and RAM before one instruction, every bus cycle
// it made (address, data, read or write), and its state after.  Each case
// is booted into the core (reset, the vector fetch answered with the case's
// PC, the registers set as the opcode is fetched), then the core's bus is
// compared cycle for cycle, and its registers and RAM afterwards.
//
// +all prints every failing case; otherwise one line per failing opcode.
module tb_cpusst;
    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg reset = 1'b1;

    wire [15:0] ab;
    wire [7:0]  dout;
    wire        we, sync;
    reg  [7:0]  din = 8'h00;
    reg  [7:0]  mem [0:65535];
    reg         boot = 1'b1, frozen = 1'b0;
    reg  [15:0] vec = 16'h0000;

    cpu_65c02 u_cpu (.clk(clk), .reset(reset), .AB(ab), .DI(din), .DO(dout), .WE(we),
                     .IRQ(1'b0), .NMI(1'b0), .RDY(1'b1), .SYNC(sync),
                     .debug_a(), .debug_x(), .debug_y(), .debug_s(), .debug_p(), .debug_pc(), .debug_ir());

    always @(posedge clk) begin
        din <= !boot ? mem[ab] : ab[15:1] == 15'h7FFE ? (ab[0] ? vec[15:8] : vec[7:0]) : 8'hEA;
        if (we && !boot && !frozen) mem[ab] <= dout;
    end

    integer fd, r, op, pc, s, a, x, y, p, ni, nc, nf, i, k, ma, mv, mw;
    integer fpc, fs, fa, fx, fy, fp;
    reg [15:0] c_a [0:15];
    reg [7:0]  c_v [0:15];
    reg        c_w [0:15];
    reg [15:0] f_a [0:255];
    reg [7:0]  f_v [0:255];
    reg [15:0] t_a [0:19];
    reg [7:0]  t_v [0:19];
    reg        t_w [0:19];
    reg        t_s [0:19];
    integer    n, bad, why;
    integer    total = 0, failed = 0, op_cases [0:255], op_fail [0:255], op_why [0:255];
    reg [8*200-1:0] op_eg [0:255];
    reg [8*200-1:0] eg;
    reg        all;

    initial begin
        all = $test$plusargs("all");
        for (i = 0; i < 256; i = i + 1) begin op_cases[i] = 0; op_fail[i] = 0; op_why[i] = 0; end
        fd = $fopen("build/sst65c02.txt", "r");
        if (fd == 0) begin $display("FAIL: tb_cpusst: no build/sst65c02.txt (run python sim/sst65c02.py)"); $finish; end
        forever begin
            r = $fscanf(fd, "%h", op);
            if (r != 1 || op == 16'hffff) begin
                $display("=== tb_cpusst: %0d cases, %0d failed ===", total, failed);
                for (i = 0; i < 256; i = i + 1)
                    if (op_fail[i] != 0)
                        $display("  %02h: %0d/%0d fail (%0s)  e.g. %0s", i[7:0], op_fail[i], op_cases[i],
                                 op_why[i] == 1 ? "cycles" : op_why[i] == 2 ? "bus" : op_why[i] == 3 ? "registers" : "memory",
                                 op_eg[i]);
                if (failed == 0) $display("tb_cpusst: PASS (%0d cases)", total);
                else             $display("FAIL: tb_cpusst: %0d of %0d cases", failed, total);
                $finish;
            end
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h", pc, s, a, x, y, p, ni, nc, nf);
            for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
            for (i = 0; i < ni; i = i + 1) begin r = $fscanf(fd, "%h %h", ma, mv); mem[ma] = mv; end
            for (i = 0; i < nc; i = i + 1) begin r = $fscanf(fd, "%h %h %h", ma, mv, mw); c_a[i] = ma; c_v[i] = mv; c_w[i] = mw; end
            r = $fscanf(fd, "%h %h %h %h %h %h", fpc, fs, fa, fx, fy, fp);
            for (i = 0; i < nf; i = i + 1) begin r = $fscanf(fd, "%h %h", ma, mv); f_a[i] = ma; f_v[i] = mv; end

            // boot: reset into a NOP just before the case's PC (every boot read
            // but the vector is $EA, writes are ignored), so the core's one-cycle-
            // late register write-back has nothing left over when the case starts
            vec = pc - 1; boot = 1'b1; frozen = 1'b0;
            @(negedge clk) reset = 1'b1;
            repeat (3) @(negedge clk);
            reset = 1'b0;
            k = 0;
            while (u_cpu.state != u_cpu.REG && k < 20) begin @(negedge clk); k = k + 1; end
            // the NOP's last cycle is the opcode fetch at the case's PC: the registers go in now
            u_cpu.AXYS[0] = a; u_cpu.AXYS[1] = s; u_cpu.AXYS[2] = x; u_cpu.AXYS[3] = y;
            u_cpu.C = p[0]; u_cpu.Z = p[1]; u_cpu.I = p[2]; u_cpu.D = p[3]; u_cpu.V = p[6]; u_cpu.N = p[7];
            boot = 1'b0;
            // the trace, from the opcode fetch to the next instruction's fetch
            n = 0;
            for (k = 0; k < 20; k = k + 1) begin
                t_a[k] = ab; t_w[k] = we; t_v[k] = we ? dout : 8'h00; t_s[k] = sync;
                if (n == 0 && k >= 2 && sync) begin n = k - 1; frozen = 1'b1; end
                @(negedge clk);
                if (n != 0 && k == n + 1) k = 20;     // the registers settle in the next DECODE
            end

            bad = 0; why = 0; eg = "";
            if (n != nc) begin
                bad = 1; why = 1;
                $sformat(eg, "%0d cycles, chip %0d:", n, nc);
            end else
                for (i = 0; i < nc; i = i + 1)
                    if (!bad && (t_a[i] != c_a[i] || t_w[i] != c_w[i] || (c_w[i] && t_v[i] != c_v[i]))) begin
                        bad = 1; why = 2;
                        $sformat(eg, "cycle %0d: %s%04h=%02h, chip %s%04h=%02h:", i + 1, t_w[i] ? "W" : "R", t_a[i], t_v[i],
                                 c_w[i] ? "W" : "R", c_a[i], c_v[i]);
                    end
            if (!bad && (t_a[n] != fpc || u_cpu.AXYS[1] != fs || u_cpu.AXYS[0] != fa || u_cpu.AXYS[2] != fx ||
                         u_cpu.AXYS[3] != fy || (u_cpu.P & 8'hCF) != (fp & 8'hCF))) begin
                bad = 1; why = 3;
                $sformat(eg, "PC %04h S %02h A %02h X %02h Y %02h P %02h, chip %04h %02h %02h %02h %02h %02h", t_a[n],
                         u_cpu.AXYS[1], u_cpu.AXYS[0], u_cpu.AXYS[2], u_cpu.AXYS[3], u_cpu.P,
                         fpc[15:0], fs[7:0], fa[7:0], fx[7:0], fy[7:0], fp[7:0]);
            end
            for (i = 0; i < nf; i = i + 1)
                if (!bad && mem[f_a[i]] != f_v[i]) begin
                    bad = 1; why = 4;
                    $sformat(eg, "$%04h = %02h, chip %02h", f_a[i], mem[f_a[i]], f_v[i]);
                end
            if (why == 1 || why == 2) begin                  // show the two traces
                for (i = 0; i < n && i < 9; i = i + 1) $sformat(eg, "%0s %s%04h", eg, t_w[i] ? "W" : "R", t_a[i]);
                $sformat(eg, "%0s | chip", eg);
                for (i = 0; i < nc && i < 9; i = i + 1) $sformat(eg, "%0s %s%04h", eg, c_w[i] ? "W" : "R", c_a[i]);
            end
            total = total + 1; op_cases[op] = op_cases[op] + 1;
            if (bad) begin
                failed = failed + 1;
                if (op_fail[op] == 0) begin op_why[op] = why; op_eg[op] = eg; end
                op_fail[op] = op_fail[op] + 1;
                if (all) $display("  %02h @%04h: %0s", op[7:0], pc[15:0], eg);
            end
        end
    end
endmodule

`default_nettype wire
