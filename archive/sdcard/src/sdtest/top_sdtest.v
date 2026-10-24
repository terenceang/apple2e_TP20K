// SD FAT32 raw test top: no Apple core.  S2 re-runs the test.
// LEDs (active-low): 0 heartbeat, 1 PASS, 2 FAIL.
module top_sdtest (
    input  wire       clk,        // 27 MHz
    input  wire       btn_s2,     // active high
    output wire [5:0] led,
    output wire       uart_tx,
    output wire       sd_clk,
    output wire       sd_mosi,
    input  wire       sd_miso,
    output wire       sd_cs_n
);
    reg [19:0] rst_cnt = 20'd0;
    always @(posedge clk)
        if (btn_s2) rst_cnt <= 20'd0;
        else if (rst_cnt != 20'hFFFFF) rst_cnt <= rst_cnt + 1'b1;
    wire reset = (rst_cnt != 20'hFFFFF);

    wire pass, failed;
    fat_test u_test (.clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
                     .sd_cs_n(sd_cs_n), .uart_tx(uart_tx), .pass(pass), .failed(failed));

    reg [24:0] hb = 0;
    always @(posedge clk) hb <= hb + 1'b1;
    assign led = ~{3'b000, failed, pass, hb[24]};
endmodule
