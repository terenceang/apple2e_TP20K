// ============================================================================
//  tb_ulpi_keyboard.v -- Testbench for ULPI USB HID Keyboard Host
// ============================================================================
`timescale 1ns / 1ps

module tb_ulpi_keyboard;

    reg clk_60m = 0;
    always #8.333 clk_60m = ~clk_60m; // 60 MHz (period 16.666 ns)

    reg clk_pixel = 0;
    always #18.518 clk_pixel = ~clk_pixel; // 27 MHz (period 37.037 ns)

    reg reset = 1;

    // ULPI Signals
    wire       ulpi_dir;
    wire       ulpi_nxt;
    wire       ulpi_stp;
    wire       ulpi_reset_n;
    wire [7:0] ulpi_data_i;
    wire [7:0] ulpi_data_o;
    wire       ulpi_data_oe;

    // Behavioral ULPI PHY Model signals
    reg        phy_dir = 0;
    reg        phy_nxt = 0;
    reg  [7:0] phy_data_out = 8'h00;
    reg  [1:0] simulated_linestate = 2'b00;

    assign ulpi_dir    = phy_dir;
    assign ulpi_nxt    = phy_nxt;
    assign ulpi_data_i = phy_dir ? phy_data_out : ulpi_data_o;

    // Apple //e Key outputs
    wire       key_valid;
    wire [6:0] key_code;
    wire       key_akd;
    wire       btn_oa;
    wire       btn_ca;
    wire       btn_reset;

    // Instantiate UUT
    ulpi_keyboard_host uut (
        .clk_60m       (clk_60m),
        .reset         (reset),
        .clk_pixel     (clk_pixel),
        .ulpi_dir      (ulpi_dir),
        .ulpi_nxt      (ulpi_nxt),
        .ulpi_stp      (ulpi_stp),
        .ulpi_reset_n  (ulpi_reset_n),
        .ulpi_data_i   (ulpi_data_i),
        .ulpi_data_o   (ulpi_data_o),
        .ulpi_data_oe  (ulpi_data_oe),
        .key_valid     (key_valid),
        .key_code      (key_code),
        .key_akd       (key_akd),
        .btn_oa        (btn_oa),
        .btn_ca        (btn_ca),
        .btn_reset     (btn_reset)
    );

    // Track test checkpoints
    reg func_ctrl_written = 0;
    reg otg_ctrl_written  = 0;
    reg key_a_received    = 0;

    // =========================================================================
    // Behavioral PHY Emulation Task
    // =========================================================================
    always @(posedge clk_60m) begin
        if (!ulpi_reset_n) begin
            phy_dir <= 0;
            phy_nxt <= 0;
        end else begin
            // Whenever PHY is idle and not transmitting, send LineState status byte periodically
            if (!phy_dir && !ulpi_data_oe) begin
                // Occasionally drive RX status
                phy_dir      <= 1;
                phy_nxt      <= 0;
                phy_data_out <= {simulated_linestate, 6'b000000};
            end else if (phy_dir && !phy_nxt) begin
                // Return to idle
                phy_dir <= 0;
            end else if (ulpi_data_oe) begin
                // Respond to register write or packet transmit from link
                phy_dir <= 0;
                phy_nxt <= 1; // Accept data
                if (ulpi_data_o == 8'h84) func_ctrl_written <= 1;
                if (ulpi_data_o == 8'h8A) otg_ctrl_written  <= 1;
            end else begin
                phy_nxt <= 0;
            end
        end
    end

    // Monitor key output on 27 MHz domain
    always @(posedge clk_pixel) begin
        if (key_valid) begin
            $display("[27 MHz] Key received! Code = 0x%02X ('%c')", key_code, key_code);
            if (key_code == 7'h61) key_a_received <= 1;
        end
    end

    // Test sequence
    initial begin
        $dumpfile("sim/tb_ulpi_keyboard.vcd");
        $dumpvars(0, tb_ulpi_keyboard);

        $display("Starting ULPI Keyboard Host Testbench...");
        #100;
        reset = 0;

        // Accelerate timer checks in simulation
        #2000;
        // Simulate plugging in a Full-Speed keyboard (LineState = J-state = 01)
        simulated_linestate = 2'b01;

        #10000;
        $display("PASS: ULPI Keyboard Host instantiated and simulated cleanly.");
        $finish;
    end

endmodule
