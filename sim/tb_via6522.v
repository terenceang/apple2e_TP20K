`timescale 1ns / 1ps
`default_nettype none

// tb_via6522.v -- Unit testbench for 6522 VIA
// Tests register access, Port A/B I/O, Timer 1 free-running countdown,
// Timer 2 one-shot, and IFR/IER /IRQ generation and clearing.

module tb_via6522;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg ce_1m = 1'b0;
    reg bus_cycle = 1'b0;
    reg cs = 1'b0;
    reg we = 1'b0;
    reg [3:0] rs = 4'd0;
    reg [7:0] din = 8'h00;
    wire [7:0] dout;
    wire irq_n;

    reg [7:0] port_a_in = 8'h00;
    wire [7:0] port_a_out;
    wire [7:0] port_a_oe;

    reg [7:0] port_b_in = 8'h00;
    wire [7:0] port_b_out;
    wire [7:0] port_b_oe;

    via6522 dut (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .bus_cycle(bus_cycle),
        .cs(cs),
        .we(we),
        .rs(rs),
        .din(din),
        .dout(dout),
        .irq_n(irq_n),
        .port_a_in(port_a_in),
        .port_a_out(port_a_out),
        .port_a_oe(port_a_oe),
        .port_b_in(port_b_in),
        .port_b_out(port_b_out),
        .port_b_oe(port_b_oe)
    );

    always #18 clk = ~clk; // 27 MHz

    reg [4:0] ce_div = 5'd0;
    always @(posedge clk) begin
        if (ce_div == 5'd25) begin
            ce_div <= 5'd0;
            ce_1m  <= 1'b1;
        end else begin
            ce_div <= ce_div + 5'd1;
            ce_1m  <= 1'b0;
        end
    end

    integer fails = 0;
    integer checks = 0;

    task check(input [1023:0] msg, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin
                $display("FAIL: %0s", msg);
                fails = fails + 1;
            end
        end
    endtask

    task write_via(input [3:0] reg_sel, input [7:0] val);
        begin
            @(posedge clk);
            cs = 1'b1;
            we = 1'b1;
            bus_cycle = 1'b1;
            rs = reg_sel;
            din = val;
            @(posedge clk);
            cs = 1'b0;
            we = 1'b0;
            bus_cycle = 1'b0;
            @(posedge clk);
        end
    endtask

    task read_via(input [3:0] reg_sel, output [7:0] val);
        begin
            @(posedge clk);
            cs = 1'b1;
            we = 1'b0;
            bus_cycle = 1'b1;
            rs = reg_sel;
            #1; // combinational settle
            val = dout;
            @(posedge clk);
            cs = 1'b0;
            bus_cycle = 1'b0;
            @(posedge clk);
        end
    endtask

    reg [7:0] rdata;
    integer cycles;

    initial begin
        $display("=== tb_via6522 ===");
        #100;
        reset = 1'b0;
        #100;

        // 1. Initial State Checks
        check("Initial IRQ is inactive (high)", irq_n == 1'b1);
        read_via(4'hD, rdata);
        check("Initial IFR is 0", rdata == 8'h00);

        // 2. Port A and B Direction and Data
        write_via(4'h3, 8'hFF); // DDRA = all outputs
        write_via(4'h1, 8'h5A); // ORA = 0x5A
        check("Port A output matches 0x5A", port_a_out == 8'h5A);
        read_via(4'h1, rdata);
        check("Read ORA matches 0x5A", rdata == 8'h5A);

        write_via(4'h3, 8'h00); // DDRA = all inputs
        port_a_in = 8'hC3;
        read_via(4'h1, rdata);
        check("Read IRA with input matches 0xC3", rdata == 8'hC3);

        write_via(4'h2, 8'h07); // DDRB = bits [2:0] outputs
        write_via(4'h0, 8'h05); // ORB = 0x05
        check("Port B output matches 0x05", port_b_out == 8'h05);

        // 3. IER Control (Enable Timer 1 interrupt: bit 6)
        write_via(4'hE, 8'hC0); // Bit 7=1 (set), bit 6=1 (T1) -> IER[6] = 1
        read_via(4'hE, rdata);
        check("IER has bit 6 enabled and bit 7 set", rdata == 8'hC0);

        // 4. Timer 1 Continuous Mode and Interrupt Assertion
        write_via(4'hB, 8'h40); // ACR bit 6 = 1 (free-running mode)
        // Program short countdown: 10 cycles
        write_via(4'h4, 8'h0A); // T1L_L = 10
        write_via(4'h5, 8'h00); // T1C_H = 0 (arms timer and starts countdown)

        check("IRQ still inactive before timer expires", irq_n == 1'b1);

        // Wait for Timer 1 countdown to expire
        cycles = 0;
        while (irq_n == 1'b1 && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        check("IRQ asserted low when Timer 1 expires", irq_n == 1'b0);

        read_via(4'hD, rdata);
        check("IFR bit 6 and bit 7 set", (rdata & 8'hC0) == 8'hC0);

        // 5. Clear Interrupt by Reading T1C_L
        read_via(4'h4, rdata);
        #100;
        check("Reading T1C_L clears IRQ", irq_n == 1'b1);
        read_via(4'hD, rdata);
        check("IFR cleared after T1C_L read", (rdata & 8'h40) == 8'h00);

        // 6. Verify Free-Running Reload (IRQ fires again automatically)
        cycles = 0;
        while (irq_n == 1'b1 && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        check("Free-running mode re-asserts IRQ automatically", irq_n == 1'b0);

        // Clear again by writing T1L_H
        write_via(4'h7, 8'h00);
        #100;
        check("Writing T1L_H clears IRQ", irq_n == 1'b1);

        // 7. Timer 2 One-Shot Test
        write_via(4'hE, 8'hA0); // Enable Timer 2 interrupt (bit 7=1, bit 5=1)
        write_via(4'h8, 8'h08); // T2 low = 8
        write_via(4'h9, 8'h00); // T2 high = 0 (arms T2)

        cycles = 0;
        while (irq_n == 1'b1 && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        check("Timer 2 asserts IRQ", irq_n == 1'b0);
        read_via(4'hD, rdata);
        check("IFR bit 5 set", (rdata & 8'h20) == 8'h20);

        // Clear by reading T2C_L
        read_via(4'h8, rdata);
        #100;
        check("Reading T2C_L clears IRQ", irq_n == 1'b1);

        // 8. CB1 Speech Auto-Acknowledge Test (Mockingboard handshake)
        write_via(4'hC, 8'hB0); // PCR: CB1 positive edge active (pcr[4]=1)
        cycles = 0;
        rdata = 8'h00;
        while ((rdata & 8'h10) == 8'h00 && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles % 100 == 0) read_via(4'hD, rdata);
        end
        read_via(4'hD, rdata);
        check("CB1 asserts IFR bit 4 after delay", (rdata & 8'h10) == 8'h10);

        // Clear CB1 by writing 1 to IFR bit 4
        write_via(4'hD, 8'h10);
        read_via(4'hD, rdata);
        check("Writing 1 to IFR bit 4 clears CB1 flag", (rdata & 8'h10) == 8'h00);

        // Verify CB1 re-asserts after delay
        cycles = 0;
        while ((rdata & 8'h10) == 8'h00 && cycles < 2000) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles % 100 == 0) read_via(4'hD, rdata);
        end
        read_via(4'hD, rdata);
        check("CB1 re-asserts IFR bit 4 after re-arm", (rdata & 8'h10) == 8'h10);

        if (fails == 0)
            $display("tb_via6522: PASS (%0d checks)", checks);
        else
            $display("FAIL: tb_via6522 failed with %0d errors", fails);

        $finish;
    end
endmodule

`default_nettype wire
