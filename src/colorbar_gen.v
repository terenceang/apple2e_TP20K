// HDMI bring-up test pattern generator for Tang Nano 20K
//
// Generates a standard 8-bar color pattern for hdmi_tx's 720x480p60 raster,
// with no dependency on the CPU, RAM or video_generator. Used to isolate the
// HDMI TX chain (clk_gen -> hdmi_tx -> OSER10 -> TLVDS_OBUF -> cable ->
// display) from the rest of the Apple //e core when diagnosing a blank or
// broken HDMI output: if the bars display correctly, the clocking and
// serializer path are good and the fault lies upstream in the Apple II
// video pipeline; if the bars are wrong or absent, the fault is in the
// clocking/HDMI path itself.
//
// rgb is combinational in (x, y), as hdmi_tx samples it on the same cycle it
// presents the coordinates. Full-range colours: top.v declares full-range
// RGB in the AVI InfoFrame (hdmi_tx RGB_QUANT).
module colorbar_gen (
    input  wire        clk_pixel,   // 27.0 MHz pixel clock
    input  wire        reset,       // Active-high reset

    input  wire [9:0]  x,           // hdmi_tx pixel_x, 0..719 active
    input  wire [9:0]  y,           // hdmi_tx pixel_y, 0..479 active
    output reg  [23:0] rgb          // {R, G, B}
);

    localparam H_VISIBLE = 720;
    localparam V_VISIBLE = 480;

    // Frame counter, used to blink the liveness box so a frozen/garbled
    // picture can be told apart from a live one.
    reg [5:0] frame_cnt = 6'd0;
    always @(posedge clk_pixel or posedge reset) begin
        if (reset)
            frame_cnt <= 6'd0;
        else if (x == 10'd0 && y == 10'd0)
            frame_cnt <= frame_cnt + 1'b1;
    end
    wire liveness_on = frame_cnt[5]; // toggles every 32 frames (~0.5s @ 60Hz)

    // 1px white border around the active area, so the active window edges are
    // visible and any off-by-one in blanking timing is obvious.
    wire on_border = (x == 0) || (x == H_VISIBLE - 1) ||
                     (y == 0) || (y == V_VISIBLE - 1);

    // 40x40 liveness box in the top-left corner: red/black, toggling.
    wire in_liveness_box = (x < 40) && (y < 40);

    // 8 vertical bars, 90px each: White, Yellow, Cyan, Green, Magenta, Red, Blue, Black
    always @(*) begin
        if (in_liveness_box)   rgb = {liveness_on ? 8'hFF : 8'h00, 16'h0000};
        else if (on_border)    rgb = 24'hFFFFFF;
        else if (x < 90)       rgb = 24'hFFFFFF; // White
        else if (x < 180)      rgb = 24'hFFFF00; // Yellow
        else if (x < 270)      rgb = 24'h00FFFF; // Cyan
        else if (x < 360)      rgb = 24'h00FF00; // Green
        else if (x < 450)      rgb = 24'hFF00FF; // Magenta
        else if (x < 540)      rgb = 24'hFF0000; // Red
        else if (x < 630)      rgb = 24'h0000FF; // Blue
        else                   rgb = 24'h000000; // Black
    end

endmodule
