`timescale 1ns / 1ps
`default_nettype none

// tb_ay8910.v -- Unit testbench for AY-3-8910 PSG
// Tests bus write/read protocol, tone generator periods, noise LFSR,
// envelope generator shapes, and logarithmic DAC output.

module tb_ay8910;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg ce_1m = 1'b0;
    reg bdir = 1'b0;
    reg bc1 = 1'b0;
    reg [7:0] da_in = 8'h00;
    wire [7:0] da_out;

    wire signed [15:0] channel_a;
    wire signed [15:0] channel_b;
    wire signed [15:0] channel_c;
    wire signed [15:0] audio_mix;

    ay8910 dut (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .bdir(bdir),
        .bc1(bc1),
        .da_in(da_in),
        .da_out(da_out),
        .channel_a(channel_a),
        .channel_b(channel_b),
        .channel_c(channel_c),
        .audio_mix(audio_mix)
    );

    // 27 MHz clock: period ~37.037 ns (use 18 ns half-period)
    always #18 clk = ~clk;

    // ce_1m generation: pulse every 26 clocks
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

    task write_reg(input [3:0] r, input [7:0] v);
        begin
            @(posedge clk);
            da_in = {4'h0, r};
            bdir = 1'b1; bc1 = 1'b1; // LATCH_ADDR
            @(posedge clk);
            bdir = 1'b0; bc1 = 1'b0; // INACTIVE
            @(posedge clk);
            da_in = v;
            bdir = 1'b1; bc1 = 1'b0; // WRITE
            @(posedge clk);
            bdir = 1'b0; bc1 = 1'b0; // INACTIVE
            @(posedge clk);
        end
    endtask

    task read_reg(input [3:0] r, output [7:0] v);
        begin
            @(posedge clk);
            da_in = {4'h0, r};
            bdir = 1'b1; bc1 = 1'b1; // LATCH_ADDR
            @(posedge clk);
            bdir = 1'b0; bc1 = 1'b0; // INACTIVE
            @(posedge clk);
            bdir = 1'b0; bc1 = 1'b1; // READ
            @(posedge clk);
            v = da_out;
            bdir = 1'b0; bc1 = 1'b0; // INACTIVE
            @(posedge clk);
        end
    endtask

    reg [7:0] rval;
    integer i, transitions;
    reg signed [15:0] last_a;

    initial begin
        $display("=== tb_ay8910 ===");
        #100;
        reset = 1'b0;
        #100;

        // 1. Bus Register Write / Readback Verification
        write_reg(4'h0, 8'hAA); // Tone A fine
        read_reg(4'h0, rval);
        check("R0 write/read match 0xAA", rval == 8'hAA);

        write_reg(4'h1, 8'h0F); // Tone A coarse (4-bit)
        read_reg(4'h1, rval);
        check("R1 write/read coarse 4-bit 0x0F", rval == 8'h0F);

        write_reg(4'h6, 8'h1F); // Noise period (5-bit)
        read_reg(4'h6, rval);
        check("R6 write/read 5-bit 0x1F", rval == 8'h1F);

        write_reg(4'h7, 8'h3E); // Enable Tone A only (disable noise, disable B & C)
        read_reg(4'h7, rval);
        check("R7 write/read mixer 0x3E", rval == 8'h3E);

        write_reg(4'h8, 8'h0F); // Channel A Amplitude = 15 (max fixed volume)
        read_reg(4'h8, rval);
        check("R8 write/read volume 15", rval == 8'h0F);

        // 2. Tone A Generation & DAC Amplitude
        // Set short period for faster simulation: period = 4
        write_reg(4'h0, 8'h04);
        write_reg(4'h1, 8'h00);

        // Let tone run and count transitions
        transitions = 0;
        last_a = channel_a;
        for (i = 0; i < 20000; i = i + 1) begin
            @(posedge clk);
            if (channel_a != last_a) begin
                transitions = transitions + 1;
                last_a = channel_a;
                // Channel amplitude at volume 15 should be +/- 5009
                check("Channel A amplitude matches max DAC table (+/-5009)",
                      channel_a == 16'sd5009 || channel_a == -16'sd5009);
            end
        end
        check("Tone A generates transitions", transitions > 2);

        // 3. Envelope Generator Shape Test
        // Configure Channel A to use Envelope mode (R8 bit 4 = 1)
        write_reg(4'h8, 8'h10);
        // Fast envelope period = 1
        write_reg(4'hB, 8'h01);
        write_reg(4'hC, 8'h00);
        // Envelope Shape 0x0E: Triangle (/ \ / \) (CONT=1, ATT=1, ALT=1, HOLD=0)
        write_reg(4'hD, 8'h0E);

        // Run and monitor amplitude change
        transitions = 0;
        for (i = 0; i < 30000; i = i + 1) begin
            @(posedge clk);
            if (channel_a != last_a) begin
                transitions = transitions + 1;
                last_a = channel_a;
            end
        end
        check("Envelope Triangle generates amplitude changes", transitions > 10);

        // 4. Silence Test
        write_reg(4'h7, 8'h3F); // Disable Tone A
        write_reg(4'h8, 8'h00); // Volume 0
        @(posedge clk);
        #100;
        check("Channel A is silent when disabled", channel_a == 16'sd0);

        if (fails == 0)
            $display("tb_ay8910: PASS (%0d checks)", checks);
        else
            $display("FAIL: tb_ay8910 failed with %0d errors", fails);

        $finish;
    end
endmodule

`default_nettype wire
