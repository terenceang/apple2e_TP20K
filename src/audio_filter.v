// Audio resampler: the speaker and the Mockingboard, from the 27 MHz clock
// to 48 kHz, for both the PT8211 DAC and HDMI.
//
// What it replaces: the mix used to be point-sampled at 46.875 kHz (no
// filter, so an AY tone above 24 kHz -- periods 1 and 2, 64 and 32 kHz --
// folded back as a loud whistle), then nearest-sample resampled to 48 kHz
// for HDMI (one sample repeated in every ~43).
//
// The signal is piecewise constant: the AYs move on ce_1m, the speaker on a
// bus cycle.  So a CIC (cascaded integrator-comb) can integrate it exactly at
// the clock.  96 kHz is 281.25 clocks, so the integrators count in quarter
// clocks (each clock is four steps of the same x, closed form below), and a
// 96 kHz instant that falls inside a clock is captured with the 1-3 quarter
// steps it has taken.  Every 96 kHz instant is then exactly R = 1125 steps
// apart and the CIC is exact: a second-order CIC, gain R^2, nulls at every
// multiple of 96 kHz.  A 47-tap halfband FIR then decimates 96 -> 48 kHz:
// flat to 20 kHz, -62 dB from 28 kHz up.  It runs on one multiplier (a DSP
// block), shared by both channels, ~60 clocks per 48 kHz sample.
//
// The CIC's integrators run every clock, so they are DSP adders too (ALU54D,
// two a channel, accumulating in the block's own 54-bit register), and the
// capture and the two combs, which only run once per 96 kHz instant, are one
// more ALU54D stepped through both channels in turn (`cst`): logic for the
// filter is then mostly the high-passes and the FIR's sequencing.
//
// Two high-pass filters stand in for the coupling capacitors: the
// Mockingboard's output at ~5 Hz (an AY channel with its tone off is a DC
// level), and the speaker at ~120 Hz, which is the damped pop each $C030
// toggle has always made here (it was a decay of 1/64 per 46.875 kHz frame).
//
// tick is the 48 kHz sample instant, a clock edge or half a clock in, so
// ticks are 562 and 563 clocks apart; tick_late says this one was the half
// (the next is 563 away).  out_l/out_r change ~80 clocks after a tick and
// hold until after the next, so a tick may take them.  No reset: HDMI audio
// keeps running through an Apple reset, and the CIC needs none.
// sim/tb_audio_filter.v measures the passband, the aliasing and the rate.
`default_nettype none

module audio_filter (
    input  wire              clk,      // 27 MHz
    input  wire              ce_1m,
    input  wire              spkr,     // the $C030 flip-flop
    input  wire signed [15:0] mock_l,
    input  wire signed [15:0] mock_r,
    output wire              tick,     // 48 kHz
    output wire              tick_late,
    output reg  signed [15:0] out_l = 16'sd0,
    output reg  signed [15:0] out_r = 16'sd0
);

    // ---- 96 kHz instants, in quarter clocks ------------------------------
    // q = quarter steps from this clock's start to the next instant
    reg  [10:0] q = 11'd0;
    reg         odd = 1'b0;           // which 96 kHz sample; even ones are 48 kHz
    wire        cap = (q < 11'd4);
    wire [1:0]  m   = q[1:0];         // quarter steps into this clock
    always @(posedge clk) begin
        q <= cap ? q + 11'd1121 : q - 11'd4;     // 1125 - 4
        if (cap) odd <= !odd;
    end
    assign tick      = cap && !odd;
    assign tick_late = m[1];          // at 0 or 2 quarters: the next is 562 or 563 on

    // ---- speaker: +/-10000 through a ~120 Hz high-pass -------------------
    // lps follows the level with 12 fraction bits, by 3/4096 per ce_1m
    // (tau 1.33 ms, the old decay's 1.37).
    reg  signed [29:0] lps = 30'sd0;
    wire signed [29:0] ds  = (spkr ? 30'sd40960000 : -30'sd40960000) - lps;
    always @(posedge clk) if (ce_1m) lps <= lps + (ds >>> 11) + (ds >>> 12);
    wire signed [17:0] spk = ds >>> 12;

    wire [38:0] i1_l, i2_l, i1_r, i2_r;
    wire signed [17:0] x_l, x_r;
    wire signed [19:0] x3_l, x3_r;

    audio_cic cic_l (.clk(clk), .ce_1m(ce_1m), .in(mock_l), .add(spk),
                     .i1(i1_l), .i2(i2_l), .x(x_l), .x3(x3_l));
    audio_cic cic_r (.clk(clk), .ce_1m(ce_1m), .in(mock_r), .add(spk),
                     .i1(i1_r), .i2(i2_r), .x(x_r), .x3(x3_r));

    // ---- capture and combs, both channels on one ALU54D ----------------
    // At an instant m quarter steps into a clock, i2 has gone on to
    // i2 + m i1 + T(m) x (T = 0, 1, 3, 6); that is s.  Then d1 = s - s1 and
    // y = d1 - d1p, and u = y / 2^21.  Six steps a channel, left then right,
    // each one add in the DSP's accumulator (DOUT is the running value):
    //   0  i2          1  + 2 i1 (m[1])   2  + i1 (m[0])   3  + T x  -> s
    //   4  - s1  -> d1 (s1 = s)            5  - d1p -> y (d1p = d1)
    reg  [38:0] ci1 [0:1], ci2 [0:1];       // the integrators at the instant
    reg  [20:0] ctx [0:1];                  // T(m) x, sign-extended below
    reg  [1:0]  cm = 2'd0;
    reg  [38:0] s1 [0:1], d1p [0:1];
    reg  [3:0]  cst = 4'd15;                // 0-11 the steps, 12 the last result, 15 idle
    wire        cch = (cst >= 4'd6);
    wire [2:0]  cop = cch ? cst[2:0] - 3'd6 : cst[2:0];  // 6..11 -> 0..5
    reg  [38:0] opb;
    always @(*)
        case (cop)
            3'd0:    opb = ci2[cch];
            3'd1:    opb = cm[1] ? {ci1[cch][37:0], 1'b0} : 39'd0;
            3'd2:    opb = cm[0] ? ci1[cch] : 39'd0;
            3'd3:    opb = {{18{ctx[cch][20]}}, ctx[cch]};
            3'd4:    opb = s1[cch];
            default: opb = d1p[cch];
        endcase
    wire        csub = (cop >= 3'd4);
    wire [53:0] cdout;
    ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
             .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0), .ALU_RESET_MODE("SYNC"))
        u_comb (.A({53'd0, csub}),                          // the +1 of a subtraction
                .B({15'd0, csub ? ~opb : opb}),             // mod 2^39 is all that is kept
                .ASIGN(1'b0), .BSIGN(1'b0), .CASI(55'd0),
                .ACCLOAD(cop != 3'd0), .CE(cst <= 4'd11), .RESET(1'b0), .CLK(clk),
                .DOUT(cdout), .CASO());

    reg  signed [17:0] u_l = 18'sd0, u_r = 18'sd0;
    reg                u_ok = 1'b0;
    integer ci;
    initial for (ci = 0; ci < 2; ci = ci + 1) begin s1[ci] = 39'd0; d1p[ci] = 39'd0; end
    always @(posedge clk) begin
        u_ok <= 1'b0;
        if (cap) begin
            ci1[0] <= i1_l; ci2[0] <= i2_l; ci1[1] <= i1_r; ci2[1] <= i2_r;
            ctx[0] <= (m == 2'd0) ? 21'd0 : (m == 2'd1) ? {{3{x_l[17]}}, x_l} :
                      (m == 2'd2) ? {x3_l[19], x3_l} : {x3_l, 1'b0};
            ctx[1] <= (m == 2'd0) ? 21'd0 : (m == 2'd1) ? {{3{x_r[17]}}, x_r} :
                      (m == 2'd2) ? {x3_r[19], x3_r} : {x3_r, 1'b0};
            cm  <= m;
            cst <= 4'd0;
        end else if (cst != 4'd15) begin
            if (cop == 3'd4) s1[cch]  <= cdout[38:0];        // s, as d1 is made from it
            if (cop == 3'd5) d1p[cch] <= cdout[38:0];        // d1, as y is made from it
            if (cst == 4'd6)  u_l <= cdout[38:21];            // left's y, as right starts
            if (cst == 4'd12) begin u_r <= cdout[38:21]; u_ok <= 1'b1; end
            cst <= (cst == 4'd12) ? 4'd15 : cst + 4'd1;
        end
    end

    // ---- halfband FIR, 96 -> 48 kHz --------------------------------------
    // The last 64 samples of each channel ({ch, index}); distributed RAM.
    reg  signed [17:0] ring [0:127];
    reg  [5:0]  wp = 6'd0;            // next slot
    reg         w_r = 1'b0, w_odd = 1'b0, start = 1'b0;
    reg  signed [17:0] u_r_q = 18'sd0;
    always @(posedge clk) begin
        start <= 1'b0;
        w_r   <= 1'b0;
        if (u_ok || w_r)              // one write port: left, then right
            ring[{w_r, wp}] <= w_r ? u_r_q : u_l;
        if (u_ok) begin
            u_r_q <= u_r;
            w_r   <= 1'b1;
            w_odd <= odd;             // flipped at cap: 1 = this was an even sample
        end
        if (w_r) begin
            wp    <= wp + 6'd1;
            start <= w_odd;
        end
    end

    // h[k] scaled by 2^21 / 1125^2 * 2^17 (the CIC gain is folded in);
    // firwin(47, 0.5, kaiser 6.0).  Symmetric, and the even offsets from the
    // centre are zero, so tap j < 24 is k = 2j and tap 24 is the centre.
    function signed [17:0] coef(input [4:0] j);
        case (j > 5'd11 ? 5'd23 - j : j)
            5'd0:  coef = -18'sd45;
            5'd1:  coef =  18'sd155;
            5'd2:  coef = -18'sd361;
            5'd3:  coef =  18'sd709;
            5'd4:  coef = -18'sd1251;
            5'd5:  coef =  18'sd2060;
            5'd6:  coef = -18'sd3242;
            5'd7:  coef =  18'sd4974;
            5'd8:  coef = -18'sd7623;
            5'd9:  coef =  18'sd12132;
            5'd10: coef = -18'sd21993;
            5'd11: coef =  18'sd68779;
            default: coef = 18'sd108598;   // j = 24 (23 - 24 wraps above 11)
        endcase
    endfunction

    reg         busy = 1'b0, ch = 1'b0;
    reg  [4:0]  j = 5'd0;
    wire [5:0]  k   = (j == 5'd24) ? 6'd23 : {j, 1'b0};
    reg  signed [17:0] ur = 18'sd0, cr = 18'sd0;
    reg  signed [35:0] p  = 36'sd0;
    reg  signed [41:0] acc = 42'sd0;
    reg  [1:0]  v = 2'd0, first = 2'd0;    // tap issued / first tap, per stage
    wire signed [41:0] sum = acc >>> 17;
    wire signed [15:0] sat = (sum >  42'sd32767) ? 16'sd32767 :
                             (sum < -42'sd32768) ? -16'sd32768 : sum[15:0];

    always @(posedge clk) begin
        v     <= {v[0], busy && j < 5'd25};
        first <= {first[0], busy && j == 5'd0};
        ur    <= ring[{ch, wp - 6'd1 - k}];
        cr    <= coef(j);
        p     <= ur * cr;
        if (v[1]) acc <= first[1] ? p : acc + p;
        if (start) begin
            busy <= 1'b1;
            ch   <= 1'b0;
            j    <= 5'd0;
        end else if (busy) begin
            if (j == 5'd28) begin            // the last tap is in acc
                if (ch) out_r <= sat; else out_l <= sat;
                busy <= ch ? 1'b0 : 1'b1;
                ch   <= !ch;
                j    <= 5'd0;
            end else
                j <= j + 5'd1;
        end
    end

endmodule

// One channel's input and CIC integrators.  x is constant for a whole clock,
// so four quarter steps (i1 += x; i2 += i1) are
//     i1' = i1 + 4x,   i2' = i2 + 4 i1 + 10x,
// each an ALU54D accumulating in its own register.  They wrap (54 bits; 39
// are kept, 18 in + 21 of gain); the combs in audio_filter take the wrap back
// out.  x and 3x go out for the capture's T(m) x.
module audio_cic (
    input  wire              clk,
    input  wire              ce_1m,
    input  wire signed [15:0] in,
    input  wire signed [17:0] add,
    output wire [38:0]       i1,
    output wire [38:0]       i2,
    output reg  signed [17:0] x  = 18'sd0,
    output reg  signed [19:0] x3 = 20'sd0
);
    // ~5 Hz high-pass: lp follows in with 15 fraction bits, by 1/32768 per ce_1m
    reg  signed [31:0] lp = 32'sd0;
    wire signed [31:0] d  = {in[15], in, 15'd0} - lp;
    wire signed [17:0] xn = (d >>> 15) + add;

    reg  signed [21:0] x10 = 22'sd0;
    always @(posedge clk) if (ce_1m) begin
        lp  <= lp + (d >>> 15);
        x   <= xn;
        x3  <= xn + (xn <<< 1);
        x10 <= (xn <<< 3) + (xn <<< 1);
    end

    wire [53:0] i1w, i2w;
    ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
             .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0), .ALU_RESET_MODE("SYNC"))
        u_i1 (.A({{34{x[17]}}, x, 2'b00}), .B(54'd0), .ASIGN(1'b0), .BSIGN(1'b0), .CASI(55'd0),
              .ACCLOAD(1'b1), .CE(1'b1), .RESET(1'b0), .CLK(clk), .DOUT(i1w), .CASO());
    ALU54D #(.AREG(1'b0), .BREG(1'b0), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .ACCLOAD_REG(1'b0),
             .OUT_REG(1'b1), .B_ADD_SUB(1'b0), .C_ADD_SUB(1'b0), .ALUD_MODE(0), .ALU_RESET_MODE("SYNC"))
        u_i2 (.A({i1w[51:0], 2'b00}), .B({{32{x10[21]}}, x10}), .ASIGN(1'b0), .BSIGN(1'b0), .CASI(55'd0),
              .ACCLOAD(1'b1), .CE(1'b1), .RESET(1'b0), .CLK(clk), .DOUT(i2w), .CASO());
    assign i1 = i1w[38:0];
    assign i2 = i2w[38:0];
endmodule

`default_nettype wire
