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
// Two high-pass filters stand in for the coupling capacitors: the
// Mockingboard's output at ~5 Hz (an AY channel with its tone off is a DC
// level), and the speaker at ~120 Hz, which is the damped pop each $C030
// toggle has always made here (it was a decay of 1/64 per 46.875 kHz frame).
//
// tick is the 48 kHz sample instant, a clock edge or half a clock in, so
// ticks are 562 and 563 clocks apart; tick_late says this one was the half
// (the next is 563 away).  out_l/out_r change ~70 clocks after a tick and
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

    wire signed [17:0] u_l, u_r;
    wire               u_ok;

    audio_cic cic_l (.clk(clk), .ce_1m(ce_1m), .in(mock_l), .add(spk),
                     .cap(cap), .m(m), .u(u_l), .u_ok(u_ok));
    audio_cic cic_r (.clk(clk), .ce_1m(ce_1m), .in(mock_r), .add(spk),
                     .cap(cap), .m(m), .u(u_r), .u_ok());

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

// Second-order CIC for one channel, sampled at 96 kHz.  x is constant for a
// whole clock, so four quarter steps (i1 += x; i2 += i1) are
//     i1' = i1 + 4x,   i2' = i2 + 4 i1 + 10x,
// and i2 after m of them (an instant inside the clock) is i2 + m i1 + T(m) x,
// T = 0, 1, 3, 6.  Integrators wrap (39 bits: 18 in + 21 of gain); the
// combs take the wrap back out.  u = y / 2^21, valid on u_ok, 4 clocks after cap.
module audio_cic (
    input  wire              clk,
    input  wire              ce_1m,
    input  wire signed [15:0] in,
    input  wire signed [17:0] add,
    input  wire              cap,
    input  wire [1:0]        m,
    output reg  signed [17:0] u = 18'sd0,
    output reg               u_ok = 1'b0
);
    // ~5 Hz high-pass: lp follows in with 15 fraction bits, by 1/32768 per ce_1m
    reg  signed [31:0] lp = 32'sd0;
    wire signed [31:0] d  = {in[15], in, 15'd0} - lp;
    wire signed [17:0] xn = (d >>> 15) + add;

    reg  signed [17:0] x   = 18'sd0;
    reg  signed [19:0] x3  = 20'sd0;
    reg  signed [21:0] x10 = 22'sd0;
    always @(posedge clk) if (ce_1m) begin
        lp  <= lp + (d >>> 15);
        x   <= xn;
        x3  <= xn + (xn <<< 1);
        x10 <= (xn <<< 3) + (xn <<< 1);
    end

    reg  [38:0] i1 = 39'd0, i2 = 39'd0;
    reg  [38:0] a = 39'd0, b = 39'd0, s = 39'd0, s1 = 39'd0, d1 = 39'd0, d1p = 39'd0;
    reg  [2:0]  st = 3'd0;
    wire signed [38:0] tx = (m == 2'd0) ? 39'sd0 :
                            (m == 2'd1) ? x :
                            (m == 2'd2) ? x3 : (x3 <<< 1);
    wire [38:0] y = d1 - d1p;
    always @(posedge clk) begin
        i1 <= i1 + {{19{x[17]}}, x, 2'b00};
        i2 <= i2 + {i1[36:0], 2'b00} + {{17{x10[21]}}, x10};
        st <= {st[1:0], cap};
        u_ok <= st[2];
        if (cap) begin
            a <= i2 + (m[1] ? {i1[37:0], 1'b0} : 39'd0);
            b <= (m[0] ? i1 : 39'd0) + tx;
        end
        if (st[0]) s <= a + b;
        if (st[1]) begin
            d1 <= s - s1;
            s1 <= s;
        end
        if (st[2]) begin
            d1p <= d1;
            u   <= $signed(y) >>> 21;
        end
    end
endmodule

`default_nettype wire
