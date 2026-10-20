// Apple //e on Tang Nano 20K - Clock Generator
// Generates 135 MHz TMDS clock, 27 MHz pixel clock, and 1.023 MHz CPU clock enable

module clk_gen (
    input  wire clk_in,       // 27.0 MHz onboard crystal (Pin 4)
    input  wire rst_in,       // Active-high reset
    output wire clk_tmds,     // 135.0 MHz (5x bit clock for HDMI)
    output wire clk_pixel,    // 27.0 MHz pixel clock
    output wire pll_locked,   // PLL locked indicator
    output reg  ce_1m,        // 1.023 MHz clock enable for 6502 CPU
    output reg  flash_clk     // ~1.6 Hz flashing text clock
);

    // Gowin rPLL instance: 27 MHz in -> 135 MHz out (5x TMDS serial clock)
    rPLL #(
        .FCLKIN("27.0"),
        .IDIV_SEL(0),   // PFD = 27.0 MHz
        .FBDIV_SEL(4),  // CLKOUT = 135.0 MHz
        .ODIV_SEL(4)    // VCO = 540.0 MHz
    ) pll_inst (
        .CLKIN(clk_in),
        .CLKOUT(clk_tmds),
        .LOCK(pll_locked),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(rst_in),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );

    // clk_pixel MUST be derived from clk_tmds via CLKDIV (divide-by-5), not
    // tapped directly off the crystal: OSER10 requires a fixed, drift-free
    // phase relationship between PCLK (clk_pixel) and FCLK (clk_tmds), which
    // only a shared hardware divider off the same PLL output guarantees.
    // Feeding it the raw crystal instead (two independently-routed clock
    // nets, frequency-locked but not phase-locked through one divider)
    // causes the HDMI serializers to intermittently lose PCLK/FCLK
    // alignment -- observed on hardware as the display dropping in and out
    // of sync. This is the same rPLL+CLKDIV pattern Gowin's own DVI TX
    // reference design and other open-toolchain Tang Nano 20K HDMI
    // projects (e.g. nestang) use.
    CLKDIV #(
        .DIV_MODE("5"),
        .GSREN("false")
    ) clkdiv_pixel (
        .CLKOUT(clk_pixel),
        .HCLKIN(clk_tmds),
        .RESETN(~rst_in & pll_locked),
        .CALIB(1'b0)
    );


    // 1.022727 MHz CPU clock enable accumulator:
    // step = round(1022727.27 * 2^32 / 27000000) = 162708307
    localparam [31:0] STEP_1M = 32'd162708307;
    reg [32:0] acc_1m = 33'd0;

    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            acc_1m <= 33'd0;
            ce_1m  <= 1'b0;
        end else begin
            acc_1m <= {1'b0, acc_1m[31:0]} + {1'b0, STEP_1M};
            ce_1m  <= acc_1m[32];
        end
    end

    // Flash clock: ~1.6 Hz for Apple II flashing characters
    // 27,000,000 / 2^24 = ~1.61 Hz
    reg [23:0] flash_cnt = 24'd0;
    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            flash_cnt <= 24'd0;
            flash_clk <= 1'b0;
        end else begin
            flash_cnt <= flash_cnt + 1'b1;
            flash_clk <= flash_cnt[23];
        end
    end

endmodule
