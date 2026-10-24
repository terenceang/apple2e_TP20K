// ============================================================================
//  uart_tx.v -- 115200 8N1 byte transmitter.  `start` with `data` valid while
//  !busy sends one byte; the bit time is the one in src/uart_defs.vh.
// ============================================================================
`include "src/uart_defs.vh"
`default_nettype none

module uart_tx (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx = 1'b1,
    output wire       busy
);
    reg [9:0] sh;
    reg [8:0] div;
    reg [3:0] bit_n;
    reg       run = 1'b0;
    assign busy = run;

    always @(posedge clk) begin
        if (reset) begin run <= 1'b0; tx <= 1'b1; end
        else if (!run) begin
            if (start) begin sh <= {1'b1, data, 1'b0}; run <= 1'b1; div <= 0; bit_n <= 0; end
        end else if (div != `UART_CLKS_PER_BIT - 1'b1) div <= div + 1'b1;
        else begin
            div <= 0;
            if (bit_n == 4'd10) run <= 1'b0;          // 10 frame bits, then the last bit's time
            else begin tx <= sh[0]; sh <= {1'b1, sh[9:1]}; bit_n <= bit_n + 1'b1; end
        end
    end
endmodule

`default_nettype wire
