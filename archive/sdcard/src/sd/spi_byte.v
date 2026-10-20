// ============================================================================
//  spi_byte.v -- SPI mode 0 byte engine for the TF card (shared by sd_loader
//  and sd_blk).  Pulse `go` for one clock with `tx` valid; `done` pulses when
//  the byte has been exchanged and `rx` holds the byte received.  211 kHz for
//  card init (fast = 0), 6.75 MHz after (fast = 1), from the 27 MHz clock.
// ============================================================================
`default_nettype none

module spi_byte (
    input  wire       clk,
    input  wire       reset,
    input  wire       fast,
    input  wire       go,
    input  wire [7:0] tx,
    output wire [7:0] rx,          // valid when done pulses
    output reg        done,
    output reg        sd_clk,
    output wire       sd_mosi,
    input  wire       sd_miso
);
    reg  [7:0] sh;
    reg  [3:0] bits;
    reg  [6:0] hc;
    reg        busy, rxb;
    wire [6:0] half = fast ? 7'd1 : 7'd63;
    assign sd_mosi = sh[7];
    assign rx = sh;

    always @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            sd_clk <= 1'b0; busy <= 1'b0;
        end else if (go) begin
            sh <= tx; bits <= 4'd0; hc <= half; busy <= 1'b1;
        end else if (busy) begin
            if (hc != 0) hc <= hc - 1'b1;
            else begin
                hc <= half;
                if (!sd_clk) begin sd_clk <= 1'b1; rxb <= sd_miso; end
                else begin
                    sd_clk <= 1'b0; sh <= {sh[6:0], rxb}; bits <= bits + 1'b1;
                    if (bits == 4'd7) begin busy <= 1'b0; done <= 1'b1; end
                end
            end
        end
    end
endmodule

`default_nettype wire
