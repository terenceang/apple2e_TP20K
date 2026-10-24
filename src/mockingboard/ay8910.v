// AY-3-8910 / AY-3-8913 Programmable Sound Generator (PSG)
// Zero-BRAM implementation: 3 tone generators, 17-bit noise LFSR,
// 16-step envelope generator with all 8 unique shapes, and logarithmic DAC curve.
`default_nettype none

module ay8910 (
    input  wire        clk,        // 27.0 MHz system clock
    input  wire        reset,      // Active-high reset
    input  wire        ce_1m,      // 1.023 MHz clock enable
    input  wire        bdir,       // Bus Direction from VIA Port B bit 1
    input  wire        bc1,        // Bus Control 1 from VIA Port B bit 0
    input  wire [7:0]  da_in,      // Data from VIA Port A
    output reg  [7:0]  da_out,     // Data to VIA Port A

    output wire signed [15:0] channel_a,
    output wire signed [15:0] channel_b,
    output wire signed [15:0] channel_c,
    output wire signed [15:0] audio_mix
);

    // Register File: R0 to R15
    reg [7:0] r0;  // Tone A Period Fine
    reg [3:0] r1;  // Tone A Period Coarse
    reg [7:0] r2;  // Tone B Period Fine
    reg [3:0] r3;  // Tone B Period Coarse
    reg [7:0] r4;  // Tone C Period Fine
    reg [3:0] r5;  // Tone C Period Coarse
    reg [4:0] r6;  // Noise Period
    reg [7:0] r7;  // Mixer Control (/Tone_A..C, /Noise_A..C)
    reg [4:0] r8;  // Amplitude A (bit 4: Env, bits 3:0: Fixed)
    reg [4:0] r9;  // Amplitude B
    reg [4:0] r10; // Amplitude C
    reg [7:0] r11; // Envelope Period Fine
    reg [7:0] r12; // Envelope Period Coarse
    reg [3:0] r13; // Envelope Shape (CONT, ATT, ALT, HOLD)
    reg [7:0] r14; // I/O Port A (fallback)
    reg [7:0] r15; // I/O Port B (fallback)

    reg [3:0] addr_latch;
    reg [1:0] prev_bus_state;
    reg       env_restart;

    wire [1:0] bus_state = {bdir, bc1};

    // -------------------------------------------------------------------------
    // Bus Interface (LATCH_ADDR, WRITE, READ, INACTIVE)
    // -------------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            addr_latch     <= 4'd0;
            prev_bus_state <= 2'b00;
            env_restart    <= 1'b0;

            r0  <= 8'h00;
            r1  <= 4'h0;
            r2  <= 8'h00;
            r3  <= 4'h0;
            r4  <= 8'h00;
            r5  <= 4'h0;
            r6  <= 5'h00;
            r7  <= 8'hFF; // All tone/noise disabled on reset
            r8  <= 5'h00;
            r9  <= 5'h00;
            r10 <= 5'h00;
            r11 <= 8'h00;
            r12 <= 8'h00;
            r13 <= 4'h0;
            r14 <= 8'h00;
            r15 <= 8'h00;
        end else begin
            prev_bus_state <= bus_state;
            env_restart    <= 1'b0;

            case (bus_state)
                2'b11: begin // LATCH_ADDR
                    addr_latch <= da_in[3:0];
                end

                2'b10: begin // WRITE (strobe on transition into WRITE mode)
                    if (prev_bus_state != 2'b10) begin
                        case (addr_latch)
                            4'h0: r0  <= da_in;
                            4'h1: r1  <= da_in[3:0];
                            4'h2: r2  <= da_in;
                            4'h3: r3  <= da_in[3:0];
                            4'h4: r4  <= da_in;
                            4'h5: r5  <= da_in[3:0];
                            4'h6: r6  <= da_in[4:0];
                            4'h7: r7  <= da_in;
                            4'h8: r8  <= da_in[4:0];
                            4'h9: r9  <= da_in[4:0];
                            4'hA: r10 <= da_in[4:0];
                            4'hB: r11 <= da_in;
                            4'hC: r12 <= da_in;
                            4'hD: begin
                                r13         <= da_in[3:0];
                                env_restart <= 1'b1; // Writing R13 reloads envelope
                            end
                            4'hE: r14 <= da_in;
                            4'hF: r15 <= da_in;
                        endcase
                    end
                end

                default: ;
            endcase
        end
    end

    // Combinational register read
    always @(*) begin
        if (bus_state == 2'b01) begin // READ
            case (addr_latch)
                4'h0: da_out = r0;
                4'h1: da_out = {4'h0, r1};
                4'h2: da_out = r2;
                4'h3: da_out = {4'h0, r3};
                4'h4: da_out = r4;
                4'h5: da_out = {4'h0, r5};
                4'h6: da_out = {3'h0, r6};
                4'h7: da_out = r7;
                4'h8: da_out = {3'h0, r8};
                4'h9: da_out = {3'h0, r9};
                4'hA: da_out = {3'h0, r10};
                4'hB: da_out = r11;
                4'hC: da_out = r12;
                4'hD: da_out = {4'h0, r13};
                4'hE: da_out = r14;
                4'hF: da_out = r15;
            endcase
        end else begin
            da_out = 8'h00;
        end
    end

    // -------------------------------------------------------------------------
    // Prescaler from the input clock (ce_1m, the Apple's 1.023 MHz, which is
    // what a Mockingboard clocks its AYs with).  GI's datasheet: a tone is
    // f = fclk / (16 TP), i.e. it toggles every TP ticks of fclk / 8; noise
    // shifts every NP ticks and the envelope steps every EP ticks of fclk / 16
    // (f_E = fclk / (256 EP) over its 16 steps).  A period of 0 acts as 1.
    // -------------------------------------------------------------------------
    reg [3:0] prescaler;
    reg       tick8, tick16;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            prescaler <= 4'd0;
            tick8     <= 1'b0;
            tick16    <= 1'b0;
        end else if (ce_1m) begin
            prescaler <= prescaler + 4'd1;
            tick8     <= (prescaler[2:0] == 3'd7);
            tick16    <= (prescaler == 4'd15);
        end else begin
            tick8     <= 1'b0;
            tick16    <= 1'b0;
        end
    end

    // a period of 0 acts as 1; a counter at 1 or below has run its period
    function [15:0] eff(input [15:0] p);
        eff = (p == 16'd0) ? 16'd1 : p;
    endfunction

    // -------------------------------------------------------------------------
    // Tone Generators (Channels A, B, C)
    // -------------------------------------------------------------------------
    wire [11:0] period_a = {r1, r0};
    wire [11:0] period_b = {r3, r2};
    wire [11:0] period_c = {r5, r4};

    reg [11:0] tone_cnt_a, tone_cnt_b, tone_cnt_c;
    reg        tone_out_a, tone_out_b, tone_out_c;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tone_cnt_a <= 12'd0;
            tone_cnt_b <= 12'd0;
            tone_cnt_c <= 12'd0;
            tone_out_a <= 1'b0;
            tone_out_b <= 1'b0;
            tone_out_c <= 1'b0;
        end else if (tick8) begin
            // Channel A
            if (tone_cnt_a <= 12'd1) begin
                tone_cnt_a <= eff({4'd0, period_a});
                tone_out_a <= ~tone_out_a;
            end else begin
                tone_cnt_a <= tone_cnt_a - 12'd1;
            end

            // Channel B
            if (tone_cnt_b <= 12'd1) begin
                tone_cnt_b <= eff({4'd0, period_b});
                tone_out_b <= ~tone_out_b;
            end else begin
                tone_cnt_b <= tone_cnt_b - 12'd1;
            end

            // Channel C
            if (tone_cnt_c <= 12'd1) begin
                tone_cnt_c <= eff({4'd0, period_c});
                tone_out_c <= ~tone_out_c;
            end else begin
                tone_cnt_c <= tone_cnt_c - 12'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Noise Generator: 17-bit LFSR (x^17 + x^3 + 1)
    // -------------------------------------------------------------------------
    reg  [4:0] noise_cnt;
    reg [16:0] lfsr;
    reg        noise_out;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            noise_cnt <= 5'd0;
            lfsr      <= 17'h10000;
            noise_out <= 1'b0;
        end else if (tick16) begin
            if (noise_cnt <= 5'd1) begin
                noise_cnt <= eff({11'd0, r6});
                lfsr      <= {lfsr[0] ^ lfsr[3], lfsr[16:1]};
                noise_out <= lfsr[0];
            end else begin
                noise_cnt <= noise_cnt - 5'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Envelope Generator: 16-bit period divider feeding 16-step shape engine
    // -------------------------------------------------------------------------
    reg  [15:0] env_cnt;
    reg  [3:0]  env_step;
    reg         env_holding;
    reg         env_alt;

    wire env_cont = r13[3];
    wire env_att  = r13[2];
    wire env_alt_cfg = r13[1];
    wire env_hold = r13[0];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            env_cnt     <= 16'd0;
            env_step    <= 4'd0;
            env_holding <= 1'b0;
            env_alt     <= 1'b0;
        end else if (env_restart) begin
            env_cnt     <= 16'd0;
            env_step    <= 4'd0;
            env_holding <= 1'b0;
            env_alt     <= 1'b0;
        end else if (tick16) begin
            if (env_cnt <= 16'd1) begin
                env_cnt <= eff({r12, r11});
                if (!env_holding) begin
                    if (env_step == 4'd15) begin
                        if (!env_cont) begin
                            env_holding <= 1'b1;
                            env_step    <= 4'd0;
                        end else begin
                            if (env_hold) begin
                                env_holding <= 1'b1;
                                env_step    <= 4'd15;
                            end else begin
                                env_step <= 4'd0;
                                if (env_alt_cfg)
                                    env_alt <= ~env_alt;
                            end
                        end
                    end else begin
                        env_step <= env_step + 4'd1;
                    end
                end
            end else begin
                env_cnt <= env_cnt - 16'd1;
            end
        end
    end

    // Envelope volume resolution
    reg [3:0] env_vol;
    wire invert_ramp = env_att ^ env_alt;
    wire [3:0] raw_ramp = invert_ramp ? env_step : (4'd15 - env_step);

    always @(*) begin
        if (env_holding) begin
            if (!env_cont)
                env_vol = 4'd0;
            else if (env_hold)
                env_vol = (env_att ^ env_alt_cfg) ? 4'd15 : 4'd0;
            else
                env_vol = raw_ramp;
        end else begin
            env_vol = raw_ramp;
        end
    end

    // -------------------------------------------------------------------------
    // Channel Mixer & Volume Selection
    // -------------------------------------------------------------------------
    wire gate_a = (r7[0] | tone_out_a) & (r7[3] | noise_out);
    wire gate_b = (r7[1] | tone_out_b) & (r7[4] | noise_out);
    wire gate_c = (r7[2] | tone_out_c) & (r7[5] | noise_out);

    wire [3:0] vol_a = r8[4]  ? env_vol : r8[3:0];
    wire [3:0] vol_b = r9[4]  ? env_vol : r9[3:0];
    wire [3:0] vol_c = r10[4] ? env_vol : r10[3:0];

    // Logarithmic Volume DAC Conversion Table (normalized max ~5000 per channel)
    function signed [15:0] dac_table;
        input [3:0] v;
        begin
            case (v)
                4'd0:  dac_table = 16'sd0;
                4'd1:  dac_table = 16'sd27;
                4'd2:  dac_table = 16'sd39;
                4'd3:  dac_table = 16'sd56;
                4'd4:  dac_table = 16'sd82;
                4'd5:  dac_table = 16'sd119;
                4'd6:  dac_table = 16'sd173;
                4'd7:  dac_table = 16'sd251;
                4'd8:  dac_table = 16'sd365;
                4'd9:  dac_table = 16'sd531;
                4'd10: dac_table = 16'sd772;
                4'd11: dac_table = 16'sd1122;
                4'd12: dac_table = 16'sd1631;
                4'd13: dac_table = 16'sd2371;
                4'd14: dac_table = 16'sd3446;
                4'd15: dac_table = 16'sd5009;
            endcase
        end
    endfunction

    wire signed [15:0] mag_a = dac_table(vol_a);
    wire signed [15:0] mag_b = dac_table(vol_b);
    wire signed [15:0] mag_c = dac_table(vol_c);

    assign channel_a = (vol_a == 4'd0) ? 16'sd0 : (gate_a ? mag_a : -mag_a);
    assign channel_b = (vol_b == 4'd0) ? 16'sd0 : (gate_b ? mag_b : -mag_b);
    assign channel_c = (vol_c == 4'd0) ? 16'sd0 : (gate_c ? mag_c : -mag_c);

    assign audio_mix = channel_a + channel_b + channel_c;

endmodule

`default_nettype wire
