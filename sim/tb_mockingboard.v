`timescale 1ns / 1ps
`default_nettype none

// tb_mockingboard.v -- System-level unit testbench for Mockingboard C card in Slot 4
// Tests Slot 4 address decode ($C400-$C4FF and $C0C0-$C0CF), dual VIAs,
// dual PSGs, stereo audio generation, and /IRQ assertion.

module tb_mockingboard;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg ce_1m = 1'b0;
    reg bus_cycle = 1'b0;
    reg cpu_we = 1'b0;
    reg [15:0] addr = 16'd0;
    reg [7:0] din = 8'h00;
    reg devsel_n = 1'b1;
    reg iosel_n = 1'b1;

    wire [7:0] dout;
    wire irq_n;
    wire signed [15:0] audio_left;
    wire signed [15:0] audio_right;

    mockingboard_card dut (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .bus_cycle(bus_cycle),
        .cpu_we(cpu_we),
        .addr(addr),
        .din(din),
        .devsel_n(devsel_n),
        .iosel_n(iosel_n),
        .dout(dout),
        .irq_n(irq_n),
        .audio_left(audio_left),
        .audio_right(audio_right)
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

    // CPU bus write to slot 4 space
    task bus_write(input [15:0] a, input [7:0] d);
        begin
            @(posedge clk);
            addr = a;
            din = d;
            cpu_we = 1'b1;
            bus_cycle = 1'b1;
            iosel_n = !(a[15:8] == 8'hC4);
            devsel_n = !(a[15:4] == 12'hC0C);
            @(posedge clk);
            cpu_we = 1'b0;
            bus_cycle = 1'b0;
            iosel_n = 1'b1;
            devsel_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // CPU bus read from slot 4 space
    task bus_read(input [15:0] a, output [7:0] d);
        begin
            @(posedge clk);
            addr = a;
            cpu_we = 1'b0;
            bus_cycle = 1'b1;
            iosel_n = !(a[15:8] == 8'hC4);
            devsel_n = !(a[15:4] == 12'hC0C);
            #1; // combinational settle
            d = dout;
            @(posedge clk);
            bus_cycle = 1'b0;
            iosel_n = 1'b1;
            devsel_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // Write PSG register via VIA
    // via_base is 16'hC400 (Left / VIA 1) or 16'hC480 (Right / VIA 2)
    task psg_write(input [15:0] via_base, input [3:0] reg_num, input [7:0] val);
        begin
            // 1. Port A = register number
            bus_write(via_base + 16'h01, {4'h0, reg_num});
            // 2. Port B = LATCH_ADDR (0x07: RESET_N=1, BDIR=1, BC1=1)
            bus_write(via_base + 16'h00, 8'h07);
            // 3. Port B = INACTIVE (0x04: RESET_N=1, BDIR=0, BC1=0)
            bus_write(via_base + 16'h00, 8'h04);
            // 4. Port A = data value
            bus_write(via_base + 16'h01, val);
            // 5. Port B = WRITE (0x06: RESET_N=1, BDIR=1, BC1=0)
            bus_write(via_base + 16'h00, 8'h06);
            // 6. Port B = INACTIVE (0x04)
            bus_write(via_base + 16'h00, 8'h04);
        end
    endtask

    // Read PSG register via VIA
    task psg_read(input [15:0] via_base, input [3:0] reg_num, output [7:0] val);
        begin
            // 1. DDRA = all outputs
            bus_write(via_base + 16'h03, 8'hFF);
            // 2. Port A = register number
            bus_write(via_base + 16'h01, {4'h0, reg_num});
            // 3. Port B = LATCH_ADDR (0x07)
            bus_write(via_base + 16'h00, 8'h07);
            // 4. Port B = INACTIVE (0x04)
            bus_write(via_base + 16'h00, 8'h04);
            // 5. DDRA = all inputs
            bus_write(via_base + 16'h03, 8'h00);
            // 6. Port B = READ (0x05: RESET_N=1, BDIR=0, BC1=1)
            bus_write(via_base + 16'h00, 8'h05);
            // 7. Read Port A (IRA)
            bus_read(via_base + 16'h01, val);
            // 8. Port B = INACTIVE (0x04)
            bus_write(via_base + 16'h00, 8'h04);
            // 9. Restore DDRA = all outputs
            bus_write(via_base + 16'h03, 8'hFF);
        end
    endtask

    reg [7:0] rval;
    integer i, left_changes, right_changes;
    reg signed [15:0] last_l, last_r;

    initial begin
        $display("=== tb_mockingboard ===");
        #100;
        reset = 1'b0;
        #100;

        // 1. Initialize VIA 1 (Left, $C400)
        bus_write(16'hC402, 8'h07); // DDRB = bits [2:0] outputs
        bus_write(16'hC403, 8'hFF); // DDRA = all outputs
        bus_write(16'hC400, 8'h00); // Standard Apple II inactive bus (PB2=0)

        // 2. Initialize VIA 2 (Right, $C480)
        bus_write(16'hC482, 8'h07); // DDRB = bits [2:0] outputs
        bus_write(16'hC483, 8'hFF); // DDRA = all outputs
        bus_write(16'hC480, 8'h00); // Standard Apple II inactive bus (PB2=0)

        // 2b. Verify Timer 1 decrements on Slot 4 without prior timer configuration
        begin : test_timer_countdown
            reg [7:0] t1_val1, t1_val2;
            integer w;
            bus_read(16'hC404, t1_val1);
            for (w = 0; w < 100; w = w + 1) @(posedge clk);
            bus_read(16'hC404, t1_val2);
            check("Slot 4 VIA 1 Timer 1 decrements at startup (Skyfox detection)", t1_val2 < t1_val1);
        end

        // 3. Test PSG Register Readback through VIA (Detection Routine)
        psg_write(16'hC400, 4'h8, 8'h0B); // Channel A Amplitude = 11 on Left PSG
        psg_read(16'hC400, 4'h8, rval);
        check("Mockingboard PSG 1 detection readback matches 0x0B", rval == 8'h0B);

        psg_write(16'hC480, 4'h8, 8'h0D); // Channel A Amplitude = 13 on Right PSG
        psg_read(16'hC480, 4'h8, rval);
        check("Mockingboard PSG 2 detection readback matches 0x0D", rval == 8'h0D);

        // 4. Configure Distinct Audio on Left and Right (True Stereo)
        // Left PSG: Tone A with fast period 6
        psg_write(16'hC400, 4'h0, 8'h06);
        psg_write(16'hC400, 4'h1, 8'h00);
        psg_write(16'hC400, 4'h7, 8'h3E); // Enable Tone A only
        psg_write(16'hC400, 4'h8, 8'h0F); // Max volume

        // Right PSG: Tone A with slower period 12
        psg_write(16'hC480, 4'h0, 8'h0C);
        psg_write(16'hC480, 4'h1, 8'h00);
        psg_write(16'hC480, 4'h7, 8'h3E); // Enable Tone A only
        psg_write(16'hC480, 4'h8, 8'h0F); // Max volume

        // Let both run and observe waveforms
        left_changes = 0;
        right_changes = 0;
        last_l = audio_left;
        last_r = audio_right;

        for (i = 0; i < 30000; i = i + 1) begin
            @(posedge clk);
            if (audio_left != last_l) begin
                left_changes = left_changes + 1;
                last_l = audio_left;
            end
            if (audio_right != last_r) begin
                right_changes = right_changes + 1;
                last_r = audio_right;
            end
        end

        check("Left channel generates audio transitions", left_changes > 2);
        check("Right channel generates audio transitions", right_changes > 2);
        check("Left period differs from Right period (stereo separation)",
              left_changes != right_changes);

        // 5. Alternate I/O decode ($C0C0-$C0CF)
        // Read VIA 1 ORB via $C0C0
        bus_read(16'hC0C0, rval);
        check("Alternate I/O $C0C0 reads VIA 1 ORB (0x04)", rval == 8'h04);

        // Read VIA 2 ORB via $C0C8
        bus_read(16'hC0C8, rval);
        check("Alternate I/O $C0C8 reads VIA 2 ORB (0x04)", rval == 8'h04);

        // 6. Test Timer 1 Interrupt Assertion on VIA 1
        bus_write(16'hC40E, 8'hC0); // Enable Timer 1 interrupt
        bus_write(16'hC40B, 8'h40); // Continuous mode
        bus_write(16'hC404, 8'h08); // T1L_L = 8
        bus_write(16'hC405, 8'h00); // T1C_H = 0 (arms timer)

        for (i = 0; i < 1500 && irq_n == 1'b1; i = i + 1) begin
            @(posedge clk);
        end
        check("Mockingboard card asserts /IRQ low on Timer 1 expiration", irq_n == 1'b0);

        // Read T1C_L to clear
        bus_read(16'hC404, rval);
        #100;
        check("Mockingboard card clears /IRQ after reading T1C_L", irq_n == 1'b1);

        if (fails == 0)
            $display("tb_mockingboard: PASS (%0d checks)", checks);
        else
            $display("FAIL: tb_mockingboard failed with %0d errors", fails);

        $finish;
    end
endmodule

`default_nettype wire
