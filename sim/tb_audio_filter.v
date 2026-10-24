// ============================================================================
//  sim/tb_audio_filter.v -- audio_filter: the 48 kHz resampler
//
//  Drives the left Mockingboard input with AY-style square waves (they move on
//  ce_1m, as an AY does) and measures the RMS of each 48 kHz output sample
//  stream:
//    * a ~1 kHz square (toggles every 512 ce_1m) comes through at its level:
//      its harmonics up to 20 kHz hold ~98% of the RMS;
//    * AY period 2 (32 kHz) and period 1 (64 kHz) tones are above 24 kHz and
//      must not fold back into the audio band.  Sampled with no filter (as
//      sound_generator did) they alias at full level; here they must be
//      >50 dB down;
//    * the right output stays silent (no crosstalk); the speaker reaches both;
//    * ticks are 562/563 clocks apart and average exactly 562.5 (48 kHz).
// ============================================================================
`timescale 1ns / 1ps

module tb_audio_filter;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;                // 27 MHz

    // ce_1m exactly as clk_gen makes it: 5/132 of 27 MHz
    reg [7:0] ce_acc = 8'd0;
    reg       ce_1m  = 1'b0;
    always @(posedge clk) begin
        ce_1m  <= (ce_acc + 8'd5 >= 8'd132);
        ce_acc <= (ce_acc + 8'd5 >= 8'd132) ? ce_acc + 8'd5 - 8'd132 : ce_acc + 8'd5;
    end

    reg               spkr = 1'b0;
    reg  signed [15:0] mock_l = 16'sd0;
    wire signed [15:0] out_l, out_r;
    wire              tick, tick_late;

    audio_filter dut (.clk(clk), .ce_1m(ce_1m), .spkr(spkr),
                      .mock_l(mock_l), .mock_r(16'sd0),
                      .tick(tick), .tick_late(tick_late),
                      .out_l(out_l), .out_r(out_r));

    // square wave on mock_l: toggles every half_per ce_1m (0 = off)
    integer half_per = 0, ce_n = 0;
    always @(posedge clk) if (ce_1m) begin
        if (half_per == 0) mock_l <= 16'sd0;
        else begin
            ce_n = ce_n + 1;
            if (ce_n >= half_per) begin
                ce_n = 0;
                mock_l <= (mock_l > 0) ? -16'sd8000 : 16'sd8000;
            end
        end
    end

    // RMS over the ticks while measuring; tick spacing all the time
    reg     measuring = 1'b0;
    real    ss_l = 0.0, ss_r = 0.0;
    integer n = 0, since = 0, gap_min = 99999, gap_max = 0, ticks = 0;
    integer clocks = 0;
    always @(posedge clk) begin
        clocks = clocks + 1;
        since  = since + 1;
        if (tick) begin
            if (ticks > 0) begin
                if (since < gap_min) gap_min = since;
                if (since > gap_max) gap_max = since;
            end
            ticks = ticks + 1;
            since = 0;
            if (measuring) begin
                ss_l = ss_l + $itor(out_l) * $itor(out_l);
                ss_r = ss_r + $itor(out_r) * $itor(out_r);
                n = n + 1;
            end
        end
    end

    integer errors = 0;
    real rms_l, rms_r;

    task measure(input integer hp, input integer ms);
        begin
            half_per = hp;
            repeat (27000 * 4) @(posedge clk);     // settle 4 ms
            ss_l = 0.0; ss_r = 0.0; n = 0;
            measuring = 1'b1;
            repeat (27000 * ms) @(posedge clk);
            measuring = 1'b0;
            rms_l = $sqrt(ss_l / n);
            rms_r = $sqrt(ss_r / n);
        end
    endtask

    integer t0, k0;
    initial begin
        $display("== tb_audio_filter ==");
        repeat (27000 * 12) @(posedge clk);       // speaker high-pass settles

        // the aliasing tones first: after the 1 kHz square the ~5 Hz
        // high-pass's follower is off by its ripple and takes ~100 ms to settle
        measure(16, 6);
        $display("   AY period 2 (32 kHz):  L rms %0.2f", rms_l);
        if (rms_l > 25.0) begin
            $display("FAIL: 32 kHz tone aliases at rms %0.2f (> -50 dB)", rms_l); errors = errors + 1;
        end

        measure(8, 6);
        $display("   AY period 1 (64 kHz):  L rms %0.2f", rms_l);
        if (rms_l > 25.0) begin
            $display("FAIL: 64 kHz tone aliases at rms %0.2f (> -50 dB)", rms_l); errors = errors + 1;
        end

        measure(512, 10);
        $display("   1 kHz square +/-8000:  L rms %0.1f  R rms %0.1f", rms_l, rms_r);
        if (rms_l < 7400.0 || rms_l > 8200.0) begin
            $display("FAIL: 1 kHz passband level %0.1f, expected ~7900", rms_l); errors = errors + 1;
        end
        if (rms_r > 2.0) begin
            $display("FAIL: right channel not silent (%0.1f)", rms_r); errors = errors + 1;
        end

        // speaker toggling at ~1 kHz reaches both channels equally
        half_per = 0;
        fork
            begin : spk
                repeat (20) begin
                    repeat (13500) @(posedge clk);
                    spkr = !spkr;
                end
            end
            begin
                repeat (27000 * 4) @(posedge clk);
                ss_l = 0.0; ss_r = 0.0; n = 0;
                measuring = 1'b1;
                repeat (27000 * 5) @(posedge clk);
                measuring = 1'b0;
            end
        join
        rms_l = $sqrt(ss_l / n);
        rms_r = $sqrt(ss_r / n);
        $display("   speaker at 1 kHz:      L rms %0.1f  R rms %0.1f", rms_l, rms_r);
        // (L also carries the tail of the square's last step through the
        // ~5 Hz high-pass, so it is not compared with R)
        if (rms_l < 5000.0 || rms_r < 5000.0) begin
            $display("FAIL: speaker should reach both channels"); errors = errors + 1;
        end

        // 48 kHz exactly: 96 ticks in 54000 clocks
        t0 = clocks; k0 = ticks;
        repeat (54000) @(posedge clk);
        $display("   ticks: %0d in 54000 clocks, gaps %0d..%0d", ticks - k0, gap_min, gap_max);
        if (ticks - k0 != 96 || gap_min != 562 || gap_max != 563) begin
            $display("FAIL: tick rate"); errors = errors + 1;
        end

        if (errors == 0) $display("tb_audio_filter: PASS");
        else             $display("tb_audio_filter: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
