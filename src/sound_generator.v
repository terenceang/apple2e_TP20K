// Apple //e Sound Generator for Tang Primer 20K
// Decodes $C030 speaker toggle and drives the Dock's PT8211 DAC (-> LPA4809
// amplifier -> 3.5 mm jack).
// The speaker and the Mockingboard C's two AYs (left, right) are mixed and
// filtered to 48 kHz by audio_filter, and the same samples go to the DAC and
// to HDMI (audio_valid / audio_sample_l / audio_sample_r).
//
// The PT8211 is 16-bit LSB-justified ("Japanese" format), not I2S: it latches
// the last 16 bits shifted in before WS changes.  So each 32-BCLK half-frame
// carries 15 zeros, the sample MSB first, then one more zero, which puts the
// LSB on the last BCLK before WS toggles (this generator's data trails its
// shift register by one BCLK, the I2S delay).  WS low is the left half;
// WS high is the right half.
//
// A frame is one 48 kHz sample: 562 or 563 clocks (27 MHz / 48 kHz = 562.5),
// from audio_filter's tick.  It holds 64 BCLKs, so BCLK is not a fixed
// division: an accumulator spreads the frame's 128 edges over its clocks,
// 4 or 5 clocks apart (BCLK 8 or 9 clocks, ~3.07 MHz).  The PT8211 has no
// master clock and does not mind.
`include "src/hdmi/hdmi_defs.vh"   // VM_PIXEL_HZ: the clock
`default_nettype none

module sound_generator (
    input  wire        clk,        // 27.0 MHz
    input  wire        reset,
    input  wire        ce_1m,
    input  wire        spkr_pulse, // Pulsed high whenever $C030 is accessed
    input  wire        test_tone_enable, // 1: output a 1kHz test tone instead of the speaker model

    // Mockingboard stereo audio inputs (optional, defaults to 0 if unconnected)
    input  wire signed [15:0] mock_left,
    input  wire signed [15:0] mock_right,

    // PT8211 serial interface
    output reg         i2s_bclk,   // HP_BCK
    output reg         i2s_lrck,   // HP_WS
    output reg         i2s_din,    // HP_DIN
    output wire        pa_en,      // PA_EN (active high amplifier enable)

    // Direct 1-bit speaker output
    output reg         spkr_out,

    // The 48 kHz samples the DAC is sent, for HDMI: a new pair on each
    // audio_valid.  Not reset, so HDMI audio runs through an Apple reset.
    output reg         audio_valid = 1'b0,
    output reg signed [15:0] audio_sample   = 16'sd0,
    output reg signed [15:0] audio_sample_l = 16'sd0,
    output reg signed [15:0] audio_sample_r = 16'sd0
);

    assign pa_en = 1'b1; // Keep power amplifier enabled

    // Speaker flip-flop toggle on $C030 access
    reg prev_pulse;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            spkr_out   <= 1'b0;
            prev_pulse <= 1'b0;
        end else begin
            prev_pulse <= spkr_pulse;
            if (spkr_pulse && !prev_pulse) begin
                spkr_out <= ~spkr_out;
            end
        end
    end

    wire               tick, tick_late;
    wire signed [15:0] filt_l, filt_r;

    audio_filter u_filter (
        .clk(clk), .ce_1m(ce_1m), .spkr(spkr_out),
        .mock_l(mock_left), .mock_r(mock_right),
        .tick(tick), .tick_late(tick_late),
        .out_l(filt_l), .out_r(filt_r)
    );

    // 1kHz test tone: phase accumulator advanced once per sample.
    // step = round(1000 * 2^32 / 48000)
    localparam [31:0] STEP_1KHZ = (64'd1000 << 32) / `VM_AUDIO_HZ;
    reg [31:0] tone_phase = 32'd0;
    wire signed [15:0] tone = tone_phase[31] ? 16'sd12000 : -16'sd12000;
    wire signed [15:0] next_l = test_tone_enable ? tone : filt_l;
    wire signed [15:0] next_r = test_tone_enable ? tone : filt_r;

    always @(posedge clk) begin
        audio_valid <= tick;
        if (tick) begin
            tone_phase     <= tone_phase + STEP_1KHZ;
            audio_sample   <= next_l;
            audio_sample_l <= next_l;
            audio_sample_r <= next_r;
        end
    end

    // PT8211 framing: a frame starts on tick; acc spreads the 127 BCLK edges
    // in between over the frame's flen clocks, and the 128th is the next tick.
    localparam [5:0] BCLK_LEFT_END = 6'd31; // last BCLK of the left channel

    // 27 MHz / 48 kHz = 562.5 clocks: a frame is 562, or 563 after a late tick
    localparam [9:0] FRAME = `VM_PIXEL_HZ / `VM_AUDIO_HZ;
    reg [9:0]  acc  = 10'd0;
    reg [9:0]  flen = FRAME;
    reg [5:0]  bit_cnt  = 6'd0; // 0..63
    reg [31:0] shift_reg = 32'd0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            acc        <= 10'd0;
            flen       <= FRAME;
            bit_cnt    <= 6'd0;
            i2s_bclk   <= 1'b0;
            i2s_lrck   <= 1'b0;
            i2s_din    <= 1'b0;
            shift_reg  <= 32'd0;
        end else if (tick) begin
            // the frame's last falling edge: left channel start
            acc       <= 10'd0;
            flen      <= FRAME + tick_late;
            i2s_bclk  <= 1'b0;
            i2s_lrck  <= 1'b0;
            i2s_din   <= shift_reg[31];
            shift_reg <= {15'd0, next_l, 1'b0};
            bit_cnt   <= 6'd0;
        end else if (acc + 10'd128 >= flen) begin
            acc      <= acc + 10'd128 - flen;
            i2s_bclk <= ~i2s_bclk;

            // Shift data out on falling edge of BCLK
            if (i2s_bclk) begin
                i2s_din   <= shift_reg[31];
                shift_reg <= {shift_reg[30:0], 1'b0};
                bit_cnt   <= bit_cnt + 1'b1;
                if (bit_cnt == BCLK_LEFT_END) begin
                    i2s_lrck  <= 1'b1; // Right channel start
                    shift_reg <= {15'd0, audio_sample_r, 1'b0};
                end
            end
        end else begin
            acc <= acc + 10'd128;
        end
    end

endmodule

`default_nettype wire
