// ============================================================================
//  sd_blk.v -- SD card (SPI mode, SDHC) 512-byte block read/write with a
//  512-byte buffer.  Sibling of src/prodos/sd_loader.v (kept separate
//  so the boot loader keeps its streaming interface; the SPI byte engine and
//  the command set are shared: src/sd/spi_byte.v, src/sd/sd_defs.vh).
//
//  Pulse `rd` or `wr` (with `lba`) for one clock while !busy.  `busy` is high
//  from reset through init and during every operation; `err` latches on any
//  failure, `estage` = the command that failed (0 CMD0 1 CMD8 2 CMD55
//  3 ACMD41 4 CMD17 5 CMD24 6 wait).  The buffer (ba/bwe/bwd -> brd, 2-clock
//  read latency) belongs to the client only while !busy.
//
//  ponytail: SDHC/SDXC only (no CMD58 check), no CRC checking.
// ============================================================================
`default_nettype none

module sd_blk #(
    parameter PWR_BITS = 20            // card power-up wait, 2^N clocks
) (
    input  wire        clk,            // 27 MHz
    input  wire        reset,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output reg         sd_cs_n,

    input  wire        rd,
    input  wire        wr,
    input  wire [31:0] lba,
    output reg         busy,
    output reg         err,
    output reg  [2:0]  estage,
    output reg  [7:0]  lrx,            // last byte seen while polling for R1 / data token

    input  wire [8:0]  ba,
    input  wire        bwe,
    input  wire [7:0]  bwd,
    output reg  [7:0]  brd
);
    // ---- SPI byte engine (src/sd/spi_byte.v) ----
    reg        fast;
    reg  [7:0] txb;
    reg        spi_go;
    wire       spi_done;
    wire [7:0] sh;
    spi_byte u_spi (.clk(clk), .reset(reset), .fast(fast), .go(spi_go), .tx(txb), .rx(sh),
                    .done(spi_done), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso));

    // ---- sector buffer: the engine owns it while busy ----
    reg [7:0] mem [0:511];
    reg [8:0] maddr;
    reg [7:0] mwd;
    reg       mwe;
    wire [8:0] a_eff = busy ? maddr : ba;
    always @(posedge clk) begin
        if (busy ? mwe : bwe) mem[a_eff] <= busy ? mwd : bwd;
        brd <= mem[a_eff];
    end

    // ---- protocol ----
    localparam [3:0] PWR = 0, DUM = 1, CMDS = 2, R1 = 3, EXTRA = 4, DTOK = 5, DATA = 6,
                     CRC = 7, IDLE = 8, WGAP = 9, WTOK = 10, WWAIT = 11, WBYTE = 12,
                     WCRC = 13, WRESP = 14, WBSY = 15;
`include "src/sd/sd_defs.vh"

    reg [3:0]  st;
    reg [2:0]  ph;
    reg        sx, got;           // transfer in flight / its result is in rxv
    reg [7:0]  rxv;
    reg [PWR_BITS-1:0] pcnt;
    reg [19:0] n;         // 2^20 bytes of busy-wait = ~1.2 s at 6.75 MHz
    reg [47:0] cmdbuf;
    reg [11:0] tries;
    reg [8:0]  bcnt;

    task xfer(input [7:0] b); begin txb <= b; spi_go <= 1'b1; sx <= 1'b1; end endtask
    task go_cmd(input [2:0] p, input [31:0] l);
        begin ph <= p; cmdbuf <= cmdw(p, l); n <= 0; st <= CMDS; end
    endtask
    task fin; begin sd_cs_n <= 1'b1; busy <= 1'b0; st <= IDLE; end endtask
    task die; begin err <= 1'b1; estage <= ph; fin; end endtask

    always @(posedge clk) begin
        spi_go <= 1'b0; mwe <= 1'b0;
        if (reset) begin
            st <= PWR; pcnt <= 0; fast <= 1'b0; sx <= 1'b0; got <= 1'b0; tries <= 0;
            busy <= 1'b1; err <= 1'b0; estage <= 0; lrx <= 0; sd_cs_n <= 1'b1; n <= 0; bcnt <= 0;
        end else if (sx) begin
            if (spi_done) begin sx <= 1'b0; got <= 1'b1; rxv <= sh; end
        end else case (st)
            PWR: begin pcnt <= pcnt + 1'b1; if (&pcnt) begin st <= DUM; n <= 0; end end
            DUM: if (!got) xfer(8'hFF);
                 else begin
                     got <= 1'b0; n <= n + 1'b1;
                     if (n == 9) begin sd_cs_n <= 1'b0; go_cmd(CMD0, 32'h0); end
                 end
            CMDS: if (!got) xfer(n == 0 ? 8'hFF : cmdbuf[47:40]);
                  else begin
                      got <= 1'b0;
                      if (n != 0) cmdbuf <= cmdbuf << 8;
                      n <= n + 1'b1;
                      if (n == 6) begin n <= 0; st <= R1; end
                  end
            R1: if (!got) xfer(8'hFF);
                else begin
                    got <= 1'b0; n <= n + 1'b1; lrx <= rxv;
                    if (ph == CMD0 && rxv != 8'h01) begin
                        // a card left mid-transfer by a previous run still clocks out data
                        // before it answers, so keep polling for the idle R1
                        if (&n[9:0]) die;
                    end else if (!rxv[7]) begin
                        n <= 0;
                        case (ph)
                            CMD0:   if (rxv == 8'h01) go_cmd(CMD8, 32'h0); else die;
                            CMD8:   if (rxv[2]) die; else st <= EXTRA;       // illegal = SDv1
                            CMD55:  go_cmd(ACMD41, 32'h0);
                            ACMD41: if (rxv == 0) begin fast <= 1'b1; fin; end
                                    else if (&tries) die;
                                    else begin tries <= tries + 1'b1; go_cmd(CMD55, 32'h0); end
                            CMD24:  if (rxv == 0) st <= WGAP; else die;
                            default:if (rxv == 0) st <= DTOK; else die;
                        endcase
                    end else if (n == 63) die;
                end
            EXTRA: if (!got) xfer(8'hFF);
                   else begin got <= 1'b0; n <= n + 1'b1; if (n == 3) go_cmd(CMD55, 32'h0); end
            // ---- read ----
            DTOK: if (!got) xfer(8'hFF);
                  else begin
                      got <= 1'b0; n <= n + 1'b1;
                      if (rxv == 8'hFE) begin bcnt <= 0; st <= DATA; end
                      else if (&n) begin ph <= 3'd6; die; end
                  end
            DATA: if (!got) xfer(8'hFF);
                  else begin
                      got <= 1'b0; maddr <= bcnt; mwd <= rxv; mwe <= 1'b1; bcnt <= bcnt + 1'b1;
                      if (bcnt == 9'd511) begin n <= 0; st <= CRC; end
                  end
            CRC: if (!got) xfer(8'hFF);
                 else begin got <= 1'b0; n <= n + 1'b1; if (n == 1) fin; end
            // ---- write ----
            IDLE: if (rd || wr) begin
                      busy <= 1'b1; sd_cs_n <= 1'b0; got <= 1'b0;
                      go_cmd(rd ? CMD17 : CMD24, lba);
                  end
            WGAP: if (!got) xfer(8'hFF); else begin got <= 1'b0; st <= WTOK; end
            WTOK: if (!got) xfer(8'hFE); else begin got <= 1'b0; bcnt <= 0; maddr <= 0; st <= WWAIT; end
            WWAIT: st <= WBYTE;                       // buffer read latency
            WBYTE: if (!got) xfer(brd);
                   else begin
                       got <= 1'b0; bcnt <= bcnt + 1'b1; maddr <= bcnt + 1'b1;
                       if (bcnt == 9'd511) begin n <= 0; st <= WCRC; end else st <= WWAIT;
                   end
            WCRC: if (!got) xfer(8'hFF);
                  else begin got <= 1'b0; n <= n + 1'b1; if (n == 1) st <= WRESP; end
            WRESP: if (!got) xfer(8'hFF);
                   else begin
                       got <= 1'b0;
                       if (rxv[4:0] == 5'b00101) begin n <= 0; st <= WBSY; end else die;
                   end
            WBSY: if (!got) xfer(8'hFF);
                  else begin
                      got <= 1'b0; n <= n + 1'b1;
                      if (rxv == 8'hFF) fin; else if (&n) begin ph <= 3'd6; die; end
                  end
            default: ;
        endcase
    end
endmodule

`default_nettype wire
