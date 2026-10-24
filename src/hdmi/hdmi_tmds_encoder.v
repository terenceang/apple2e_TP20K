// ============================================================================
//  hdmi_tmds_encoder.v -- 10-bit TMDS symbol encoder for one HDMI channel
//  Target: Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7), Gowin Yosys flow
//  Language: Verilog-2001 (no SystemVerilog) so the same source elaborates
//            under iverilog, verilator and yosys/Gowin synthesis.
//
//  References:
//    DVI 1.0      Figure 5-7 (encode) / Figure 6-3 (decode)
//    HDMI 1.4a    Sec 5.4.2 control symbols (Table 5-23)
//                Sec 5.4.3 TERC4 symbols (Table 5-31)
//                Sec 5.2.2.1 video guard band
//                Sec 5.2.3.3 data guard band
//
//  The video-period encode is the running-disparity (DC-balance) variant of
//  HDMI 1.3 Figure 5-7 (spec page 83).  sim/tb_tmds_encoder.v verifies all 256
//  possible input bytes round-trip through an independent spec decoder from
//  each of the 15 reachable starting running-disparity states (-7..+7), not
//  just from a cold start, and the disparity accumulator never exceeds +/-8.
//
//  Pipeline depth is exactly 2 cycles for every mode.  That uniformity is
//  load-bearing: it is what keeps the packet assembler's TERC4 nibbles
//  aligned with the island body two pixels downstream.
// ============================================================================

`default_nettype none
`include "src/hdmi/hdmi_defs.vh"

module hdmi_tmds_encoder #(
    // TMDS channel number.  Selects the per-channel guard band symbols.
    // 0 = Blue (also carries the control/sync bits), 1 = Green, 2 = Red.
    parameter integer CN = 0
) (
    input  wire         clk_pixel,
    input  wire         rst_n,

    // Symbol period selector, `TMDS_* in hdmi_defs.vh:
    //   CTRL  control period     (control_data = C0..C3)
    //   VIDEO video data period  (video_data)
    //   VGB   video guard band   (fixed symbol)
    //   TERC4 data island body   (data_island_data)
    //   DGB   data guard band    (fixed symbol, control_data selects ch0's)
    input  wire [2:0]   mode,

    // Video payload (TMDS_VIDEO).  Ch0: blue, Ch1: green, Ch2: red.
    input  wire [7:0]   video_data,

    // TERC4 payload (TMDS_TERC4), 4 bits per channel.
    input  wire [3:0]   data_island_data,

    // Control bits {D1, D0} (TMDS_CTRL, TMDS_DGB).  Ch0: {vsync, hsync};
    // ch1: {CTL1, CTL0}; ch2: {CTL3, CTL2}, non-zero only in a Preamble.
    input  wire [1:0]   control_data,

    output reg  [9:0]   tmds
);

    // -----------------------------------------------------------------------
    // Symbol lookup tables
    // -----------------------------------------------------------------------

    // HDMI 1.4a Sec 5.4.2 -- control symbols C0..C3.
    function [9:0] ctrl_code;
        input [1:0] c;
        begin
            case (c)
                2'b00:   ctrl_code = 10'b1101010100;
                2'b01:   ctrl_code = 10'b0010101011;
                2'b10:   ctrl_code = 10'b0101010100;
                default: ctrl_code = 10'b1010101011;
            endcase
        end
    endfunction

    // HDMI 1.4a Sec 5.4.3 / Table 5-31 -- TERC4.
    function [9:0] terc4_code;
        input [3:0] d;
        begin
            case (d)
                4'h0: terc4_code = 10'b1010011100;
                4'h1: terc4_code = 10'b1001100011;
                4'h2: terc4_code = 10'b1011100100;
                4'h3: terc4_code = 10'b1011100010;
                4'h4: terc4_code = 10'b0101110001;
                4'h5: terc4_code = 10'b0100011110;
                4'h6: terc4_code = 10'b0110001110;
                4'h7: terc4_code = 10'b0100111100;
                4'h8: terc4_code = 10'b1011001100;
                4'h9: terc4_code = 10'b0100111001;
                4'ha: terc4_code = 10'b0110011100;
                4'hb: terc4_code = 10'b1011000110;
                4'hc: terc4_code = 10'b1010001110;
                4'hd: terc4_code = 10'b1001110001;
                4'he: terc4_code = 10'b0101100011;
                default: terc4_code = 10'b1011000011;
            endcase
        end
    endfunction

    // HDMI 1.4a Sec 5.2.3.3 -- data guard band.  Channels 1 and 2 both send
    // 0100110011.  Channel 0 sends the TERC4 code of {2'b11, vsync, hsync},
    // which is how the sink knows a data island -- not video -- follows.
    function [9:0] data_guard_code;
        input [1:0] c;
        begin
            if (CN == 1 || CN == 2) begin
                data_guard_code = 10'b0100110011;
            end else begin
                case (c)
                    2'b00:   data_guard_code = 10'b1010001110;
                    2'b01:   data_guard_code = 10'b1001110001;
                    2'b10:   data_guard_code = 10'b0101100011;
                    default: data_guard_code = 10'b1011000011;
                endcase
            end
        end
    endfunction

    // HDMI 1.4a Sec 5.2.2.1 -- video guard band.  Channels 0 and 2 send
    // 1011001100; channel 1 sends its complement 0100110011.
    wire [9:0] video_guard_const = (CN == 1) ? 10'b0100110011 : 10'b1011001100;

    // -----------------------------------------------------------------------
    // 1. Video period: transition minimisation
    //
    //    DVI Figure 5-7.  n1d is the population count of the input byte.  When
    //    the byte is ones-heavy the chain is XNORed and bit 8 is cleared to
    //    flag that polarity; when it is zeros-heavy the chain is XORed and bit
    //    8 is set.
    // -----------------------------------------------------------------------
    // Population count of an 8-bit word.
    function [3:0] popcount8;
        input [7:0] v;
        integer i;
        begin
            popcount8 = 4'd0;
            for (i = 0; i < 8; i = i + 1) popcount8 = popcount8 + v[i];
        end
    endfunction

    wire [3:0] n1d = popcount8(video_data);

    // DVI Fig 5-7 step 2: invert when ones-heavy, or when the population
    // count ties and the LSB is 0.
    wire use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && video_data[0] == 1'b0);

    // q_m[i] = q_m[i-1] XOR (or XNOR) d[i]; XNOR is XOR then invert.
    reg [8:0] qm_comb;
    integer   qi;
    always @(*) begin
        qm_comb[0] = video_data[0];
        for (qi = 1; qi < 8; qi = qi + 1)
            qm_comb[qi] = qm_comb[qi-1] ^ video_data[qi] ^ use_xnor;
        qm_comb[8] = ~use_xnor;            // 1 = XOR chain, 0 = XNOR chain
    end

    // Population count of the transition-minimised word.
    wire [3:0] n1q_comb = popcount8(qm_comb[7:0]);
    wire [3:0] n0q_comb = 4'd8 - n1q_comb;
    wire signed [4:0] disp_qm = $signed({1'b0, n1q_comb}) - $signed({1'b0, n0q_comb});

    // -----------------------------------------------------------------------
    // 2. Video period: DC balance with running disparity
    //
    //    HDMI 1.3 Figure 5-7 (spec page 83).  The 9-bit transition-minimised
    //    word q_m[8:0] becomes a 10-bit symbol as
    //
    //        q_out[9] = inv8
    //        q_out[8] = q_m[8]
    //        q_out[7:0] = inv8 ? ~q_m[7:0] : q_m[7:0]
    //
    //    so bit 9 is the inversion flag and bit 8 stays the chain polarity.
    //    inv8 is chosen per Figure 5-7:
    //
    //        cnt == 0 or N1{q_m} == N0{q_m}  ->  inv8 = ~q_m[8]
    //        bias and symbol lean the same way -> inv8 = 1
    //        otherwise                            inv8 = 0
    //
    //    and the disparity update is
    //
    //        inv8 == 0 :  cnt += 2*q_m[8] - 2 + (N1 - N0)
    //        inv8 == 1 :  cnt += 2*q_m[8]     - (N1 - N0)
    //
    //    Both expressions are the ones printed in Figure 5-7, and both were
    //    re-derived from the ones/zeros count of the emitted symbol.
    //
    //    Note the balanced branch collapses to "E1 if q_m[8] else E2" but the
    //    two off-balanced branches do NOT.  Forcing the {~q_m[8], q_m[8]}
    //    prefix everywhere, which an earlier revision of this file did, keeps
    //    bit 9 tied to the chain polarity and destroys the inversion flag --
    //    the symbol then decodes as the complement of the intended byte for
    //    every off-balanced step.  sim/tb_tmds_encoder.v covers all 15
    //    reachable starting disparities to keep that from regressing.
    //
    //    q_out[9:8] is {1,0} for a balanced symbol with q_m[8]==0 and for an
    //    inverted symbol with q_m[8]==0, i.e. the same shape as the control
    //    symbols.  That is inherent to the algorithm; sinks separate them by
    //    the 7-transition property of the four control symbols.
    // -----------------------------------------------------------------------
    reg signed [4:0] disparity;

    wire [9:0] vidsym_d;
    reg signed [4:0] disparity_d;

    wire qm_balanced = (disparity == 5'sd0) || (n1q_comb == n0q_comb);
    wire qm_agree    = ((disparity > 5'sd0) && (n1q_comb > n0q_comb)) ||
                       ((disparity < 5'sd0) && (n1q_comb < n0q_comb));

    wire inv8 = qm_balanced ? ~qm_comb[8]
                            : (qm_agree ? 1'b1 : 1'b0);

    assign vidsym_d = {inv8, qm_comb[8], inv8 ? ~qm_comb[7:0] : qm_comb[7:0]};

    // Figure 5-7 disparity accumulation, widened so the 6-bit intermediate
    // cannot wrap before it is folded back into the 5-bit running register.
    wire signed [5:0] s        = $signed({{1'b0}, disp_qm});
    wire signed [5:0] two_qm8  = qm_comb[8] ? 6'sd2 : 6'sd0;
    wire signed [5:0] contrib   = inv8 ? (two_qm8 - s)
                                       : (two_qm8 - 6'sd2 + s);
    always @(*) disparity_d = $signed(disparity) + contrib;

    // -----------------------------------------------------------------------
    // 3. Two-stage register / output
    // -----------------------------------------------------------------------
    // Stage A holds the period as one-hot flags rather than the 3-bit code.
    // Same logic, but the code form makes the abc9 flow in recent yosys
    // nightlies (the OSS CAD Suite OpenFPGA Deck uses) leave a stray $buf
    // cell that nextpnr cannot place.
    reg [3:0] sel_a;    // {DGB, TERC4, VGB, CTRL}; all clear = VIDEO
    reg [3:0] terc4_a;
    reg [1:0] ctrl_a;
    reg [9:0] vidsym_a;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            sel_a     <= 4'b0001;
            ctrl_a    <= 2'b00;
            terc4_a   <= 4'd0;
            vidsym_a  <= 10'b0000011111;   // clock-channel idle pattern
            disparity <= 5'sd0;
            tmds      <= 10'b0000011111;  // clock-channel idle pattern
        end else begin
            // Stage A -- delay the mode/control inputs one cycle, and compute
            // this pixel's video symbol against the live disparity.
            sel_a   <= {mode == `TMDS_DGB, mode == `TMDS_TERC4,
                        mode == `TMDS_VGB, mode == `TMDS_CTRL};
            ctrl_a  <= control_data;
            terc4_a <= data_island_data;

            if (mode == `TMDS_VIDEO) begin
                vidsym_a  <= vidsym_d;
                disparity <= disparity_d;
            end else begin
                // The accumulator is meaningless outside the video period; a
                // sink re-acquires it from the first video symbol after each
                // preamble, so clearing it here is both safe and stops
                // control/guard symbols from biasing it.
                disparity <= 5'sd0;
            end

            // Stage B -- output.  Every arm is one register, so every mode
            // leaves the module on the same cycle.
            if      (sel_a[0]) tmds <= ctrl_code(ctrl_a);
            else if (sel_a[1]) tmds <= video_guard_const;
            else if (sel_a[2]) tmds <= terc4_code(terc4_a);
            else if (sel_a[3]) tmds <= data_guard_code(ctrl_a);
            else               tmds <= vidsym_a;
        end
    end

endmodule

`default_nettype wire
