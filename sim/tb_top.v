// ============================================================================
//  tb_top.v -- board-level check of src/top.v: clocking and serialisation
//
//  Runs top.v on sim/models/gowin_prims.v and deserialises the four TMDS
//  pairs the way a sink does: the clock lane (0000011111, D0 first) frames
//  the symbols, each data lane is shifted in LSB first and cut every 10 bits.
//  Checks:
//    * every _n leg is the complement of its _p leg,
//    * the clock lane repeats 0000011111 with the right period,
//    * each lane's recovered symbol stream equals the symbols hdmi_tx
//      produced for that lane (blue on lane 0, green 1, red 2), at one
//      constant latency shared by all three lanes, over tens of thousands of
//      symbols covering video, control and data islands.
//    * the HDMI audio strobe into hdmi_tx runs at 48 kHz and Audio Sample
//      Packets (type 0x02) go out in data islands.
//  The content of those symbols is tb_video_hdmi's job (and the reference
//  TN20K-HDMI project's tb_hdmi_tx for the packet layer); this only proves
//  the path from hdmi_tx to the pins is lossless and in order.
//
//  Needs the ROM images in roms/ (not in git, see roms/README.md), since
//  top.v instantiates the whole Apple //e.
// ============================================================================
`timescale 1ps / 1ps
`default_nettype none

module tb_top;
    localparam integer N_CMP = 40000;       // symbols compared per lane
    localparam integer MAX_LAG = 16;

    reg clk = 1'b0;
    always #18519 clk = ~clk;               // 27 MHz

    wire       tmds_clk_p, tmds_clk_n;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire [5:0] led;
    wire       uart_tx, i2s_bclk, i2s_lrck, i2s_din, pa_en;

    // The board's DDR3 (aux RAM); sim/models/ddr3_model.v stands in for the
    // controller, so these only need somewhere to go.  Declared before the
    // instance that drives them (this iverilog rejects declaration-after-use).
    wire [15:0] ddr_dq;
    wire [1:0]  ddr_dqs, ddr_dqs_n;

    top dut (.clk(clk), .key_s1_n(1'b1), .key_s2_n(1'b1), .led(led),
             .uart_rx(1'b1), .uart_tx(uart_tx),
             .sd_clk(), .sd_mosi(), .sd_miso(1'b1), .sd_cs_n(),   // no TF card
             .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
             .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n),
             .i2s_bclk(i2s_bclk), .i2s_lrck(i2s_lrck), .i2s_din(i2s_din),
             .pa_en(pa_en),
             .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_DQS_n(ddr_dqs_n), .DDR3_A(), .DDR3_BA(),
             .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(), .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(), .DDR3_CKE(),
             .DDR3_nRESET(), .DDR3_ODT(), .DDR3_DM());

    integer errors = 0;

    // Symbols as hdmi_tx hands them to the serialisers, once reset is over.
    reg [9:0] core [0:2][0:N_CMP+MAX_LAG];
    integer   nc = 0;
    always @(posedge dut.clk_pixel) if (dut.hdmi_rst_n && nc <= N_CMP + MAX_LAG) begin
        core[0][nc] = dut.u_hdmi.tmds[9:0];
        core[1][nc] = dut.u_hdmi.tmds[19:10];
        core[2][nc] = dut.u_hdmi.tmds[29:20];
        nc = nc + 1;
    end

    // Sample each bit mid-cell: Q changes on every FCLK edge.
    realtime tbit = 0, t_edge = 0;
    always @(dut.clk_tmds) begin
        if (t_edge > 0) tbit = $realtime - t_edge;
        t_edge = $realtime;
    end

    reg [9:0] sr_c = 0, sr0 = 0, sr1 = 0, sr2 = 0;
    reg [9:0] rec [0:2][0:N_CMP];
    integer   nr = 0, bitpos = -1, nbits = 0;

    always @(dut.clk_tmds) if (dut.hdmi_rst_n && tbit > 0) begin
        #(tbit / 2);
        if (tmds_clk_n !== ~tmds_clk_p || tmds_d_n !== ~tmds_d_p) begin
            if (errors < 10) $display("FAIL: an _n leg is not the complement of _p");
            errors = errors + 1;
        end
        sr_c = {tmds_clk_p,  sr_c[9:1]};
        sr0  = {tmds_d_p[0], sr0[9:1]};
        sr1  = {tmds_d_p[1], sr1[9:1]};
        sr2  = {tmds_d_p[2], sr2[9:1]};
        nbits = nbits + 1;
        if (bitpos < 0) begin
            if (nbits > 40 && sr_c == 10'b0000011111) bitpos = 0;
        end else begin
            bitpos = (bitpos + 1) % 10;
        end
        if (bitpos == 0 && nr <= N_CMP) begin
            if (sr_c !== 10'b0000011111) begin
                if (errors < 10) $display("FAIL: clock lane symbol %b", sr_c);
                errors = errors + 1;
            end
            rec[0][nr] = sr0;  rec[1][nr] = sr1;  rec[2][nr] = sr2;
            nr = nr + 1;
        end
    end

    // HDMI audio: strobes into hdmi_tx, and Audio Sample Packets pushed.
    integer n_audio = 0, n_asp = 0, k;
    realtime t_audio0 = 0, t_audio1 = 0;
    always @(posedge dut.clk_pixel) if (dut.hdmi_rst_n) begin
        if (dut.hdmi_audio_valid) begin
            if (n_audio == 0) t_audio0 = $realtime;
            t_audio1 = $realtime;
            n_audio  = n_audio + 1;
        end
        // counted as an island starts, from the slots it is about to send
        if (dut.u_hdmi.island_start)
            for (k = 0; k < 3; k = k + 1)
                if (k < dut.u_hdmi.u_isl.pkt_count && dut.u_hdmi.u_isl.hdr[k][7:0] == 8'h02)
                    n_asp = n_asp + 1;
    end

    // Find the lag at which the pins replay the core's symbols.
    integer lag, found, i, l, bad;
    initial begin
        wait (nr > N_CMP && nc > N_CMP + MAX_LAG);
        found = -1;
        for (lag = 0; lag <= MAX_LAG && found < 0; lag = lag + 1) begin
            bad = 0;
            // The first recovered symbols may predate framing; skip a few.
            for (i = 4; i < N_CMP - MAX_LAG; i = i + 1)
                for (l = 0; l < 3; l = l + 1)
                    if (rec[l][i] !== core[l][i - 4 + lag]) bad = bad + 1;
            if (bad == 0) found = lag;
        end
        if (found < 0) begin
            $display("FAIL: pin symbols never match the core's at any latency");
            for (i = 100; i < 104; i = i + 1)
                $display("  rec %b %b %b   core %b %b %b", rec[0][i], rec[1][i], rec[2][i],
                         core[0][i], core[1][i], core[2][i]);
            errors = errors + 1;
        end else begin
            $display("%0d symbols x 3 lanes match hdmi_tx at a constant latency, bit time %0.1f ps",
                     N_CMP - MAX_LAG - 4, tbit);
        end
        if (n_audio < 10 || n_asp < 10) begin
            $display("FAIL: %0d audio strobes, %0d audio packets", n_audio, n_asp);
            errors = errors + 1;
        end else begin
            $display("%0d audio samples at %0.1f Hz in %0d Audio Sample Packets",
                     n_audio, (n_audio - 1) * 1.0e12 / (t_audio1 - t_audio0), n_asp);
            if ((n_audio - 1) * 1.0e12 / (t_audio1 - t_audio0) < 47900.0 ||
                (n_audio - 1) * 1.0e12 / (t_audio1 - t_audio0) > 48100.0) begin
                $display("FAIL: HDMI audio rate is not 48 kHz");
                errors = errors + 1;
            end
        end
        if (led[1] !== 1'b0) begin
            $display("FAIL: lock LED is not on");
            errors = errors + 1;
        end
        if (errors == 0) $display("tb_top: PASS");
        else             $display("tb_top: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
