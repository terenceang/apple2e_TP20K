// ============================================================================
//  sim/tb_sound.v -- sound_generator: I2S frame rate and bit timing
//
//  There was no testbench for sound_generator.v, which is how its BCLK
//  divider went unnoticed running at 42187.5 Hz while three comments (and
//  top.v's HDMI resampler) all assumed 46875 Hz.  This pins the rate down.
//
//  27 MHz / 46875 Hz = 576 clocks per frame, 64 BCLKs per frame, so the BCLK
//  period must be exactly 9 clocks.  The divider is asymmetric (4 high, 5
//  low) because 9 is odd; I2S only cares about the period.
//
//  The tone-frequency check is the end-to-end version of the same bug: the
//  1 kHz test tone is resampled to 48 kHz by top.v, so a wrong frame rate
//  puts 1 kHz out at 900 Hz (~-1.8 semitones).  It is checked here at the
//  source, where the expected value is exactly 1000 Hz.
//
//  The DAC is a PT8211 (Tang Primer 20K Dock), which is LSB-justified: it
//  keeps the last 16 bits clocked in on BCLK rising edges before WS changes.
//  A decoder below does exactly that and requires every word it latches
//  while the +/-12000 test tone plays to be +12000 or -12000, so a one-bit
//  slip in the framing (24000 / 6000, or garbage) fails.
// ============================================================================
`timescale 1ns / 1ps

module tb_sound;

    localparam CLK_HZ      = 27_000_000;
    localparam BCLK_CLKS   = 9;                  // clocks per BCLK period
    localparam FRAME_CLKS  = 64 * BCLK_CLKS;     // 576 clocks per I2S frame
    localparam FRAME_HZ    = CLK_HZ / FRAME_CLKS; // 46875
    localparam TONE_HZ     = 1000;               // 1 kHz test tone
    localparam TONE_FRAMES = 2000;               // window for the tone check

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg spkr_pulse = 1'b0;
    reg test_tone_enable = 1'b0;

    always #5 clk = ~clk;   // 10 ns period => 27 MHz

    wire        i2s_bclk, i2s_lrck, i2s_din, pa_en, spkr_out;
    wire signed [15:0] audio_sample;

    sound_generator u_dut (
        .clk              (clk),
        .reset            (reset),
        .spkr_pulse       (spkr_pulse),
        .test_tone_enable (test_tone_enable),
        .i2s_bclk         (i2s_bclk),
        .i2s_lrck         (i2s_lrck),
        .i2s_din          (i2s_din),
        .pa_en            (pa_en),
        .spkr_out         (spkr_out),
        .audio_sample     (audio_sample)
    );

    integer errors = 0;

    task expect_eq;
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %0d, expected %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // BCLK period, measured off the waveform so any RTL change trips this.
    // BCLK is high for 4 consecutive clocks, so edges are detected as
    // transitions rather than as "is high".
    // ---------------------------------------------------------------------
    integer bclk_last_rise = -1;
    integer bclk_periods   = 0;
    integer bclk_min       = 100000;
    integer bclk_max       = 0;
    reg     bclk_q         = 1'b0;

    // LRCK falls at the start of each stereo frame, so falling edges are
    // frame boundaries.  This is the frame rate top.v's resampler relies on.
    integer lrck_last_fall = -1;
    integer lrck_frames    = 0;
    integer frame_min      = 100000;
    integer frame_max      = 0;
    reg     lrck_q         = 1'b0;

    // Data must change on the falling edge of BCLK, never the rising edge.
    integer data_on_rising = 0;
    reg     din_q         = 1'b0;
    reg     bclk_q2        = 1'b0;

    // Tone frequency: count sample transitions over a known number of frames.
    integer tone_transitions = 0;
    integer tone_frames      = 0;
    reg     sample_q         = 1'b0;
    reg     tone_counting    = 1'b0;
    integer cyc              = 0;

    // PT8211 receiver: shift on BCLK rise, latch on the first rise after WS moves.
    reg  [15:0] pt_sr = 16'd0;
    reg         pt_ws = 1'b0;
    reg         pt_check = 1'b0;
    integer     pt_words = 0, pt_bad = 0;
    always @(posedge i2s_bclk) begin
        if (i2s_lrck !== pt_ws) begin
            if (pt_check) begin
                pt_words = pt_words + 1;
                if ($signed(pt_sr) !== 16'sd12000 && $signed(pt_sr) !== -16'sd12000) begin
                    if (pt_bad < 5) $display("FAIL: PT8211 word %0d = %0d, expected +/-12000", pt_words, $signed(pt_sr));
                    pt_bad = pt_bad + 1;
                end
            end
            pt_ws = i2s_lrck;
        end
        pt_sr = {pt_sr[14:0], i2s_din};
    end

    always @(posedge clk) begin
        cyc = cyc + 1;

        if (i2s_bclk && !bclk_q) begin
            if (bclk_last_rise >= 0) begin
                bclk_periods = bclk_periods + 1;
                if (($time / 10 - bclk_last_rise) < bclk_min)
                    bclk_min = $time / 10 - bclk_last_rise;
                if (($time / 10 - bclk_last_rise) > bclk_max)
                    bclk_max = $time / 10 - bclk_last_rise;
            end
            bclk_last_rise = $time / 10;
        end
        bclk_q <= i2s_bclk;

        if (lrck_q && !i2s_lrck) begin
            if (lrck_last_fall >= 0) begin
                lrck_frames = lrck_frames + 1;
                if (($time / 10 - lrck_last_fall) < frame_min)
                    frame_min = $time / 10 - lrck_last_fall;
                if (($time / 10 - lrck_last_fall) > frame_max)
                    frame_max = $time / 10 - lrck_last_fall;
            end
            lrck_last_fall = $time / 10;
            if (tone_counting) tone_frames = tone_frames + 1;
        end
        lrck_q <= i2s_lrck;

        if (bclk_q2 && !bclk_q && (i2s_din !== din_q))
            data_on_rising = data_on_rising + 1;
        din_q  <= i2s_din;
        bclk_q2 <= bclk_q;

        if (tone_counting && (audio_sample[15] !== sample_q))
            tone_transitions = tone_transitions + 1;
        sample_q <= audio_sample[15];
    end

    initial begin
        $display("== tb_sound: I2S frame rate and bit timing ==");
        $display("   expecting BCLK %0d clk, frame %0d clk, %0d Hz, tone %0d Hz",
                 BCLK_CLKS, FRAME_CLKS, FRAME_HZ, TONE_HZ);

        repeat (4) @(posedge clk);
        reset = 1'b0;

        // ---- part 1: divider shape and frame interval -------------------
        repeat (40) @(posedge clk);
        test_tone_enable = 1'b1;   // drive the tone so the output is not idle

        repeat (FRAME_CLKS * 5) @(posedge clk);

        if (bclk_periods == 0) begin
            $display("FAIL: no BCLK rising edges observed");
            errors = errors + 1;
        end
        expect_eq("BCLK period (clocks)", bclk_min, BCLK_CLKS);
        expect_eq("BCLK period (clocks)", bclk_max, BCLK_CLKS);

        if (lrck_frames == 0) begin
            $display("FAIL: no frame boundaries observed");
            errors = errors + 1;
        end
        expect_eq("frame interval (clocks)", frame_min, FRAME_CLKS);
        expect_eq("frame interval (clocks)", frame_max, FRAME_CLKS);

        if (pa_en !== 1'b1) begin
            $display("FAIL: pa_en = %b, expected 1", pa_en);
            errors = errors + 1;
        end
        expect_eq("data changes on BCLK rising edge", data_on_rising, 0);

        // ---- PT8211 framing, over the tone ------------------------------
        pt_check = 1'b1;
        repeat (FRAME_CLKS * 20) @(posedge clk);
        pt_check = 1'b0;
        if (pt_words < 30) begin
            $display("FAIL: only %0d PT8211 words latched", pt_words);
            errors = errors + 1;
        end
        errors = errors + pt_bad;

        // ---- part 2: 1 kHz tone really is 1 kHz ------------------------
        // A wrong frame rate here is the user-visible symptom: top.v
        // resamples this to 48 kHz, so 42187.5 Hz in => ~900 Hz out.
        tone_counting = 1'b1;
        repeat (FRAME_CLKS * TONE_FRAMES) @(posedge clk);
        tone_counting = 1'b0;

        begin : tone_check
            integer n_clocks;
            integer dur_us_x10;     // microseconds x10
            integer want_trans;
            integer got_hz_x10;
            // 64-bit scratch: the products below overflow a 32-bit integer.
            reg [63:0] wide;
            n_clocks = FRAME_CLKS * TONE_FRAMES;
            wide = n_clocks;
            wide = wide * 10000000;
            dur_us_x10 = wide / CLK_HZ;
            // one full cycle is two sample transitions
            wide = 2;
            wide = wide * TONE_HZ * dur_us_x10;
            want_trans = wide / 10000000;
            wide = tone_transitions;
            wide = wide * CLK_HZ * 10;
            got_hz_x10 = wide / (2 * n_clocks);
            $display("   tone: %0d transitions over %0d.%0d ms => %0d.%0d Hz (want %0d Hz)",
                     tone_transitions, dur_us_x10 / 10000, (dur_us_x10 / 100) % 100,
                     got_hz_x10 / 10, got_hz_x10 % 10, TONE_HZ);
            if ((tone_transitions < want_trans - 2) ||
                (tone_transitions > want_trans + 2)) begin
                $display("FAIL: tone frequency %0d.%0d Hz, expected about %0d Hz",
                         got_hz_x10 / 10, got_hz_x10 % 10, TONE_HZ);
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("PASS: BCLK period is %0d clocks (%0d MHz)", bclk_min,
                     CLK_HZ / 1000000 / BCLK_CLKS);
            $display("PASS: frame interval is %0d clocks = %0d Hz, not 42187.5 Hz",
                     frame_min, FRAME_HZ);
            $display("PASS: data changes on BCLK falling edge (I2S)");
            $display("PASS: pa_en held high");
            $display("PASS: %0d PT8211 words latched, all +/-12000", pt_words);
            $display("PASS: 1 kHz test tone measures 1 kHz");
            $display("tb_sound: PASS");
        end else begin
            $display("tb_sound: FAIL (%0d errors)", errors);
        end
        $finish;
    end

endmodule
