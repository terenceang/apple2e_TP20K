// SPI master byte engine, mode 0 (SCK idles low, MOSI changes on the falling
// edge, MISO is sampled on the rising edge), MSB first.  Chip select is not
// here: the caller holds it across a whole frame (src/spi_ctl.v).
//
// SCK = clk / (2*HALF).  The ESP32's SPI slave is reliable to about 10 MHz on
// IO_MUX pins, so HALF = 2 (6.75 MHz from 27 MHz) is the fastest that stays in
// spec; HALF = 1 would be 13.5 MHz.

`default_nettype none

module spi_master #(
    parameter integer HALF = 2
) (
    input  wire       clk,
    input  wire       reset,     // active-high, async
    input  wire       start,     // pulse: send tx, ignored while busy
    input  wire [7:0] tx,
    output reg  [7:0] rx,        // valid when done pulses
    output reg        busy,
    output reg        done,      // one clock, byte finished
    output reg        sck,
    output reg        mosi,
    input  wire       miso
);
    reg [7:0] sh_out, sh_in;
    reg [2:0] nbit;
    reg [7:0] cnt;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rx <= 8'd0; busy <= 1'b0; done <= 1'b0; sck <= 1'b0; mosi <= 1'b0;
            sh_out <= 8'd0; sh_in <= 8'd0; nbit <= 3'd0; cnt <= 8'd0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                sck <= 1'b0;
                if (start) begin
                    busy <= 1'b1; sh_out <= tx; mosi <= tx[7]; nbit <= 3'd0; cnt <= 8'd0;
                end
            end else if (cnt == HALF - 1) begin
                cnt <= 8'd0;
                if (!sck) begin
                    sck   <= 1'b1;
                    sh_in <= {sh_in[6:0], miso};
                end else begin
                    sck <= 1'b0;
                    if (nbit == 3'd7) begin
                        busy <= 1'b0; done <= 1'b1; rx <= sh_in;
                    end else begin
                        nbit   <= nbit + 3'd1;
                        sh_out <= {sh_out[6:0], 1'b0};
                        mosi   <= sh_out[6];
                    end
                end
            end else begin
                cnt <= cnt + 8'd1;
            end
        end
    end
endmodule

`default_nettype wire
