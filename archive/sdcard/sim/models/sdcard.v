// Behavioural SDHC card (SPI mode) for the testbenches: memory-backed, 512 B sectors.
// Access the contents through `mem` (hierarchically).  `wblks` counts completed sector
// writes, `last_wlba` is the last one written, `errs` counts protocol errors.
`timescale 1ns/1ps
module sdcard #(parameter SECTORS = 8192) (
    input  wire sd_clk,
    input  wire sd_mosi,
    input  wire sd_cs_n,
    output wire sd_miso
);
    reg [7:0] mem [0:SECTORS*512-1];
    integer wblks = 0, last_wlba = 0, errs = 0, wst = 0, wn = 0, wlba = 0;
    reg [7:0] q [0:2047]; integer qh = 0, qt = 0;
    reg [7:0] rxs, txs = 8'hFF, nxt; reg pend = 0; integer nb = 0, cn = 0, a41 = 0, k;
    reg [7:0] cmd [0:5];
    wire [31:0] carg = {cmd[1], cmd[2], cmd[3], cmd[4]};
    assign sd_miso = sd_cs_n ? 1'b1 : txs[7];
    task push(input [7:0] b); begin q[qt % 2048] = b; qt = qt + 1; end endtask
    always @(posedge sd_clk) begin
        rxs = {rxs[6:0], sd_mosi}; nb = nb + 1;
        if (nb == 8) begin
            nb = 0;
            if (wst != 0) begin
                if (wst == 1) begin if (rxs == 8'hFE) begin wst = 2; wn = 0; end end
                else if (wst == 2) begin
                    mem[wlba*512 + wn] = rxs; wn = wn + 1;
                    if (wn == 512) begin wst = 3; wn = 0; end
                end else begin
                    wn = wn + 1;
                    if (wn == 2) begin wst = 0; push(8'hE5); push(0); push(0); push(0); wblks = wblks + 1; last_wlba = wlba; end
                end
            end else if (cn > 0 || rxs[7:6] == 2'b01) begin
                cmd[cn] = rxs; cn = cn + 1;
                if (cn == 6) begin
                    cn = 0; push(8'hFF);
                    case (cmd[0][5:0])
                        0: push(8'h01);
                        8: begin push(8'h01); push(0); push(0); push(1); push(8'hAA); end
                        55: push(8'h01);
                        41: begin a41 = a41 + 1; push(a41 < 2 ? 8'h01 : 8'h00); end
                        17: begin
                            if (carg >= SECTORS) errs = errs + 1;
                            push(0); push(8'hFF); push(8'hFF); push(8'hFE);
                            for (k = 0; k < 512; k = k + 1) push(mem[carg*512 + k]);
                            push(0); push(0);
                        end
                        24: begin
                            if (carg >= SECTORS) errs = errs + 1;
                            push(0); wst = 1; wlba = carg;
                        end
                        default: errs = errs + 1;
                    endcase
                end
            end
            pend = 1;
            if (qh < qt) begin nxt = q[qh % 2048]; qh = qh + 1; end else nxt = 8'hFF;
        end
    end
    always @(negedge sd_clk) begin
        if (pend) begin txs = nxt; pend = 0; end else txs = {txs[6:0], 1'b1};
    end
endmodule
