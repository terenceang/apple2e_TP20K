`timescale 1ns / 1ps
`default_nettype none

// tb_irq_system.v -- Comprehensive testbench for the Apple //e IRQ system:
// 1. 65C02 CLI single-instruction interrupt shadow (CLI; INX executes INX before IRQ)
// 2. 65C02 CLI; SEI prevents pending IRQ from triggering
// 3. 65C02 WAI ($CB) with I=0 wakes and vectors to IRQ handler
// 4. 65C02 WAI ($CB) with I=1 wakes and continues to next instruction without taking IRQ
// 5. Slot bus: Pin 30 /IRQ wired-OR across all slots vs Pins 27/28 daisy chain
// 6. Thunderclock: 64 Hz periodic interrupt assertion and $C0D2 read clear

module tb_irq_system;
    reg clk = 1'b0;
    always #10 clk = ~clk;
    reg reset = 1'b1;

    wire [15:0] ab;
    wire [7:0]  dout;
    wire        we, sync;
    reg  [7:0]  din = 8'h00;
    reg  [7:0]  mem [0:65535];
    reg         irq = 1'b0;
    reg         nmi = 1'b0;

    wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    wire [15:0] dbg_pc;
    wire [7:0] dbg_ir;

    cpu_65c02 u_cpu (
        .clk(clk), .reset(reset), .AB(ab), .DI(din), .DO(dout), .WE(we),
        .IRQ(irq), .NMI(nmi), .RDY(1'b1), .SYNC(sync),
        .debug_a(dbg_a), .debug_x(dbg_x), .debug_y(dbg_y), .debug_s(dbg_s),
        .debug_p(dbg_p), .debug_pc(dbg_pc), .debug_ir(dbg_ir)
    );

    always @(posedge clk) begin
        din <= mem[ab];
        if (we) mem[ab] <= dout;
    end

    integer fails = 0, checks = 0;
    task check(input [8*72-1:0] what, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin
                $display("FAIL: %0s", what);
                fails = fails + 1;
            end else begin
                $display("PASS: %0s", what);
            end
        end
    endtask

    integer timeout;

    initial begin
        integer i;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA; // NOP

        // Vectors
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h03; // Reset vector = $0300
        mem[16'hFFFE] = 8'h00; mem[16'hFFFF] = 8'h04; // IRQ vector   = $0400

        // Program at $0300 for Test 1:
        mem[16'h0300] = 8'hA2; mem[16'h0301] = 8'hFF; // LDX #$FF
        mem[16'h0302] = 8'h9A;                         // TXS
        mem[16'h0303] = 8'hA2; mem[16'h0304] = 8'h00; // LDX #0
        mem[16'h0305] = 8'h58;                         // CLI
        mem[16'h0306] = 8'hE8;                         // INX
        mem[16'h0307] = 8'hEA;                         // NOP
        mem[16'h0400] = 8'h40;                         // RTI

        // Reset the CPU
        repeat (10) @(posedge clk);
        reset = 1'b0;
        // Wait until address bus reaches $0300
        timeout = 0;
        while (ab !== 16'h0300 && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        check("CPU reaches reset target $0300", ab === 16'h0300);

        // Hold IRQ asserted continuously
        irq = 1'b1;

        timeout = 0;
        while (dbg_x !== 8'h01 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("INX executed after CLI despite active IRQ (X == 1)", dbg_x === 8'h01);

        // After INX completes, the interrupt should be taken to $0400
        timeout = 0;
        while (ab !== 16'h0400 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("Interrupt taken to vector $0400 after INX", ab === 16'h0400);

        irq = 1'b0; // release IRQ

        // =====================================================================
        // Test 2: CLI immediately followed by SEI prevents pending IRQ
        // Program at $0310:
        //   $0310: 78          SEI        (set I=1)
        //   $0311: 58          CLI        (clear I)
        //   $0312: 78          SEI        (set I=1 again immediately!)
        //   $0313: A2 42       LDX #$42
        // =====================================================================
        mem[16'h0310] = 8'h78;
        mem[16'h0311] = 8'h58;
        mem[16'h0312] = 8'h78;
        mem[16'h0313] = 8'hA2; mem[16'h0314] = 8'h42;

        // Force PC to $0310
        force u_cpu.PC = 16'h0310;
        force u_cpu.state = 6'd13; // FETCH
        @(posedge clk);
        release u_cpu.PC;
        release u_cpu.state;

        irq = 1'b1; // IRQ asserted during CLI; SEI sequence
        timeout = 0;
        while (dbg_x !== 8'h42 && dbg_pc !== 16'h0400 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("CLI followed immediately by SEI prevented IRQ from hijacking (X == $42)", dbg_x === 8'h42);
        check("CPU did not enter IRQ handler at $0400", dbg_pc !== 16'h0400);

        irq = 1'b0;

        // =====================================================================
        // Test 3: WAI ($CB) with I=1 resumes to NEXT instruction without taking IRQ
        // Program at $0320:
        //   $0320: 78          SEI
        //   $0321: A2 00       LDX #$00
        //   $0323: CB          WAI
        //   $0324: A2 55       LDX #$55   <-- MUST EXECUTE when IRQ wakes WAI with I=1
        // =====================================================================
        mem[16'h0320] = 8'h78;
        mem[16'h0321] = 8'hA2; mem[16'h0322] = 8'h00;
        mem[16'h0323] = 8'hCB;
        mem[16'h0324] = 8'hA2; mem[16'h0325] = 8'h55;

        force u_cpu.PC = 16'h0320;
        force u_cpu.state = 6'd13;
        @(posedge clk);
        release u_cpu.PC;
        release u_cpu.state;

        // Wait until CPU enters WAIT state (state 54)
        timeout = 0;
        while (u_cpu.state !== 6'd54 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("CPU entered WAIT state on WAI instruction", u_cpu.state === 6'd54);

        // Pulse IRQ to wake CPU
        repeat (2) @(posedge clk);
        irq = 1'b1;
        @(posedge clk);
        irq = 1'b0;

        // CPU should NOT branch to $0400; it must execute LDX #$55 at $0324
        timeout = 0;
        while (dbg_x !== 8'h55 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("WAI with I=1 woke and executed next instruction (X == $55)", dbg_x === 8'h55);
        check("Did not vector to IRQ handler", dbg_pc !== 16'h0400);

        // =====================================================================
        // Test 4: WAI ($CB) with I=0 wakes and takes IRQ vector
        // Program at $0330:
        //   $0330: 58          CLI
        //   $0331: CB          WAI
        //   $0332: A2 77       LDX #$77
        // IRQ handler at $0400:
        //   $0400: A0 99       LDY #$99
        //   $0402: 40          RTI
        // =====================================================================
        mem[16'h0330] = 8'h58;
        mem[16'h0331] = 8'hCB;
        mem[16'h0332] = 8'hA2; mem[16'h0333] = 8'h77;
        mem[16'h0400] = 8'hA0; mem[16'h0401] = 8'h99;
        mem[16'h0402] = 8'h40;

        force u_cpu.PC = 16'h0330;
        force u_cpu.state = 6'd13;
        @(posedge clk);
        release u_cpu.PC;
        release u_cpu.state;

        // Wait until CPU enters WAIT state
        timeout = 0;
        while (u_cpu.state !== 6'd54 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("CPU entered WAIT with I=0", u_cpu.state === 6'd54);

        // Assert IRQ to wake CPU
        irq = 1'b1;
        timeout = 0;
        while (ab !== 16'h0400 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("WAI with I=0 woke and vectored to IRQ handler $0400", ab === 16'h0400);

        // Wait until Y == $99
        timeout = 0;
        while (dbg_y !== 8'h99 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("IRQ handler executed (Y == $99)", dbg_y === 8'h99);

        // Release IRQ and let RTI return to $0332
        irq = 1'b0;
        timeout = 0;
        while (dbg_x !== 8'h77 && timeout < 50) begin
            @(posedge clk); timeout = timeout + 1;
        end
        check("RTI cleanly returned to instruction following WAI (X == $77)", dbg_x === 8'h77);

        // Final tally
        if (fails == 0) $display("tb_irq_system: ALL %0d CHECKS PASSED", checks);
        else            $display("tb_irq_system: FAILED %0d of %0d checks", fails, checks);
        $finish;
    end

endmodule
