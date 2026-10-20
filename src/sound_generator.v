// Apple //e Sound Generator for Tang Primer 20K
// Decodes $C030 speaker toggle and drives the Dock's PT8211 DAC (-> LPA4809
// amplifier -> 3.5 mm jack).
//
// The PT8211 is 16-bit LSB-justified ("Japanese" format), not I2S: it latches
// the last 16 bits shifted in before WS changes.  So each 32-BCLK half-frame
// carries 15 zeros, the sample MSB first, then one more zero, which puts the
// LSB on the last BCLK before WS toggles (this generator's data trails its
// shift register by one BCLK, the I2S delay).  WS low is the left half here;
// both halves carry the same sample, so the PT8211's channel order is moot.
//
// audio_sample updates once per I2S frame, at exactly 46875 Hz: 27 MHz is
// 576 clocks per frame (27e6 / 46875 = 576) and a frame is 64 BCLKs, so the
// BCLK period is 9 clocks.  top.v resamples that to the 48 kHz HDMI rate, so
// the two rates are not independent -- changing one means changing the other.

module sound_generator (
    input  wire        clk,        // 27.0 MHz
    input  wire        reset,
    input  wire        spkr_pulse, // Pulsed high whenever $C030 is accessed
    input  wire        test_tone_enable, // 1: output a 1kHz test tone instead of the speaker model

    // PT8211 serial interface
    output reg         i2s_bclk,   // HP_BCK
    output reg         i2s_lrck,   // HP_WS
    output reg         i2s_din,    // HP_DIN
    output wire        pa_en,      // PA_EN (active high amplifier enable)

    // Direct 1-bit speaker output
    output reg         spkr_out,

    // Current 16-bit signed PCM sample (the value sent on I2S), updated once
    // per I2S frame; top.v resamples it at 48 kHz for HDMI audio.
    output reg signed [15:0] audio_sample
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

    // Acoustic impulse model:
    // Physical Apple II speaker produces a damped acoustic pop on each toggle.
    reg prev_spkr_out;

    // BCLK generation: 27 MHz / 9 = 3.0 MHz
    // 64 BCLKs per sample frame -> 3.0 MHz / 64 = 46.875 kHz sample rate
    //
    // 27 MHz / 46.875 kHz is exactly 576 clocks per frame = 9 clocks per BCLK
    // period, and 9 is odd, so bclk_div free-runs 0..8 and toggles BCLK at
    // both 4 and 8: 4 clocks high, 5 low.  I2S tolerates the asymmetry, and
    // only the period matters.  A single toggle compare would give an even
    // period and land on 42187.5 Hz instead, which is what this used to do.
    localparam [3:0] BCLK_DIV_LAST = 4'd8; // bclk_div counts 0..8: a 9-clock period
    localparam [3:0] BCLK_DIV_MID  = 4'd4; // first toggle: 4 clocks high, 5 low
    localparam [5:0] BCLK_LAST     = 6'd63; // last BCLK of the 64-BCLK frame
    localparam [5:0] BCLK_LEFT_END = 6'd31; // last BCLK of the left channel

    reg [3:0] bclk_div = 4'd0;
    reg [5:0] bit_cnt  = 6'd0; // 0..63
    reg [31:0] shift_reg = 32'd0;

    // 1kHz test tone: phase accumulator advanced once per audio sample
    // (46.875 kHz frame rate). step = round(1000 * 2^32 / 46875)
    localparam [31:0] STEP_1KHZ = 32'd91625969;
    reg [31:0] tone_phase = 32'd0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            audio_sample  <= 16'sd0;
            prev_spkr_out <= 1'b0;
            bclk_div      <= 4'd0;
            bit_cnt       <= 6'd0;
            i2s_bclk      <= 1'b0;
            i2s_lrck      <= 1'b0;
            i2s_din       <= 1'b0;
            shift_reg     <= 32'd0;
            tone_phase    <= 32'd0;
        end else begin
            // BCLK clock division: the counter runs 0..8 and toggles BCLK at
            // both 4 and 8 (see bclk_div above), giving a 9-clock period.
            // The shift below is gated on the *old* i2s_bclk being 1, which
            // is true only on the 4->8 transition, i.e. the falling edge, so
            // data still changes on the falling edge as I2S requires.
            if (bclk_div == BCLK_DIV_MID || bclk_div == BCLK_DIV_LAST) begin
                i2s_bclk <= ~i2s_bclk;
                if (bclk_div == BCLK_DIV_LAST)
                    bclk_div <= 4'd0;
                else
                    bclk_div <= BCLK_DIV_MID + 4'd1;

                // Shift data out on falling edge of BCLK
                if (i2s_bclk) begin
                    i2s_din   <= shift_reg[31];
                    shift_reg <= {shift_reg[30:0], 1'b0};

                    if (bit_cnt == BCLK_LAST) begin
                        bit_cnt  <= 6'd0;
                        i2s_lrck <= 1'b0; // Left channel start

                        tone_phase <= tone_phase + STEP_1KHZ;

                        if (test_tone_enable) begin
                            audio_sample <= tone_phase[31] ? 16'sd12000 : -16'sd12000;
                        end else if (spkr_out != prev_spkr_out) begin
                            // Update acoustic pop with exponential decay
                            prev_spkr_out <= spkr_out;
                            audio_sample  <= spkr_out ? 16'sd16000 : -16'sd16000;
                        end else begin
                            audio_sample  <= audio_sample - (audio_sample >>> 6); // Damped decay
                        end

                        // Load the sample LSB-justified into each 32-bit half (see header)
                        shift_reg <= {15'd0, audio_sample, 1'b0};
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                        if (bit_cnt == BCLK_LEFT_END) begin
                            i2s_lrck  <= 1'b1; // Right channel start
                            shift_reg <= {15'd0, audio_sample, 1'b0};
                        end
                    end
                end
            end else begin
                bclk_div <= bclk_div + 1'b1;
            end
        end
    end

endmodule
