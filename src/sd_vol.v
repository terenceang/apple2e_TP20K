// ============================================================================
//  sd_vol.v -- the slot 7 hard disk's two volumes, kept on the TF card
//
//  The card is used raw (no file system):
//    sector 0                    config: "A2HD", drive 1 slot, drive 2 slot
//                                (16-bit little-endian, $FFFF = empty)
//    sector 2048 + N * 65,536    slot N: a 32 MB ProDOS volume, block b at +b
//  scripts/sdvol.py writes images into slots and sets the config from a PC.
//
//  At reset it brings the card up (SPI mode, SDHC/SDXC), reads the config,
//  and copies each drive's slot into the DDR3 (aux_ram hd_*, word address
//  {drive, block, word}, low byte = even byte) with one CMD18 multi-block
//  read, ~25 s for a whole volume.  `loading` is high until that is done, and
//  top.v holds the CPU on it.  After that:
//    wb_go    write a block back from the DDR3 (prodos_hd, after each WRITE)
//    x_go     write one sector of slot x_slot, block x_blk, from bytes the
//             debugger hands over (x_byte/x_valid, x_take when used) or, with
//             x_zero, zeros: the web page's copy of an image onto the card
//    x_fin    the copy is over: a drive holding x_slot reloads it
//    mnt_go   put a slot in a drive: rewrite the config, then load it
//             ($FFFF ejects; a slot in the other drive is ejected from it)
//  Neither is taken while `busy`.  There is no sector buffer (block RAM is
//  46/46): bytes go between the SPI engine and the DDR3 one word at a time,
//  and the SPI clock simply waits when the DDR3 has not finished the last one.
//
//  `err` latches on a failure, `estage` = the command (0 CMD0 1 CMD8 2 CMD55
//  3 ACMD41 4 CMD17 5 CMD24 6 CMD18 7 CMD12/timeout).
//  ponytail: SDHC/SDXC only (no CMD58 check), no CRC checking.
// ============================================================================
`default_nettype none

module sd_vol #(
    parameter       PWR_BITS  = 20,    // card power-up wait, 2^N clocks
    parameter [6:0] FAST_HALF = 7'd0,  // SPI half period after init: 0 = 13.5 MHz
    parameter [15:0] LAST_BLK = 16'hFFFF  // a volume's last block (a bench shortens it)
) (
    input  wire        clk,            // 27 MHz
    input  wire        reset,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output reg         sd_cs_n,

    input  wire        ddr_ready,
    output reg         m_go,
    output reg  [24:0] m_addr,
    output reg         m_we,
    output reg  [15:0] m_wdata,
    input  wire [15:0] m_rdata,
    input  wire        m_ack,          // shared with the card: only ours while m_busy

    output reg  [15:0] slot0,
    output reg  [15:0] slot1,
    output reg  [1:0]  present,
    output wire        loading,
    output wire        busy,
    output reg         err,
    output reg  [2:0]  estage,

    input  wire        wb_go,
    input  wire        wb_drv,
    input  wire [15:0] wb_blk,
    input  wire        mnt_go,
    input  wire        mnt_drv,
    input  wire [15:0] mnt_slot,

    input  wire        x_go,
    input  wire [15:0] x_slot,
    input  wire [15:0] x_blk,
    input  wire        x_zero,
    input  wire [7:0]  x_byte,
    input  wire        x_valid,
    output reg         x_take,
    input  wire        x_fin
);
    // ---- SPI byte engine (src/spi_byte.v) ----
    reg        fast;
    reg  [7:0] txb;
    reg        spi_go;
    wire       spi_done;
    wire [7:0] sh;
    spi_byte #(.FAST_HALF(FAST_HALF)) u_spi (
        .clk(clk), .reset(reset), .fast(fast), .go(spi_go), .tx(txb), .rx(sh),
        .done(spi_done), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso));

    localparam [2:0] CMD0 = 0, CMD8 = 1, CMD55 = 2, ACMD41 = 3, CMD17 = 4, CMD24 = 5,
                     CMD18 = 6, CMD12 = 7;
    function [47:0] cmdw(input [2:0] p, input [31:0] l);
        case (p)
            CMD0:   cmdw = {8'h40, 32'h0,        8'h95};
            CMD8:   cmdw = {8'h48, 32'h000001AA, 8'h87};
            CMD55:  cmdw = {8'h77, 32'h0,        8'h01};
            ACMD41: cmdw = {8'h69, 32'h40000000, 8'h01};
            CMD17:  cmdw = {8'h51, l,            8'h01};
            CMD24:  cmdw = {8'h58, l,            8'h01};
            CMD18:  cmdw = {8'h52, l,            8'h01};
            default:cmdw = {8'h4C, 32'h0,        8'h01};   // CMD12
        endcase
    endfunction

    localparam [4:0] PWR = 0, DUM = 1, CMDS = 2, R1 = 3, EXTRA = 4, DTOK = 5, DATA = 6,
                     CRC = 7, IDLE = 8, WGAP = 9, WTOK = 10, WBYTE = 11, WCRC = 12,
                     WRESP = 13, WBSY = 14, SKIP = 15, BSY = 16;

    reg [4:0]  st = PWR;
    reg [2:0]  ph = CMD0;
    reg        sx = 1'b0, got = 1'b0;  // a byte in flight / its answer is in rxv
    reg [7:0]  rxv = 8'hFF;
    reg [PWR_BITS-1:0] pcnt = 0;
    reg [19:0] n = 20'd0;
    reg [47:0] cmdbuf;
    reg [11:0] tries = 12'd0;
    reg [8:0]  bcnt = 9'd0;

    // What the current transfer is for
    reg        inited = 1'b0;           // card is up
    reg        cfg_rd = 1'b0;           // the config has been read (or the card failed)
    reg        to_cfg = 1'b0;           // data goes to / comes from the config, not the DDR3
    reg        xw = 1'b0;               // the write's data comes from the debugger...
    reg        xz = 1'b0;               // ...or is zeros
    reg        drv = 1'b0;              // drive being loaded or written back
    reg [15:0] blk = 16'd0;
    reg [1:0]  ld_pend = 2'b00;         // drives still to load
    reg        m_busy = 1'b0;
    reg [7:0]  lo = 8'h00;              // even byte, waiting for its odd one
    reg [15:0] wword = 16'h0000;        // word being sent on a write

    // A DDR3 that never calibrates must not hold the CPU for ever: give up
    // on loading after ~2.5 s of waiting for it.
    reg [25:0] dwait = 26'd0;
    wire       gave_up = &dwait;
    always @(posedge clk)
        if (reset) dwait <= 26'd0;
        else if (!ddr_ready && !gave_up) dwait <= dwait + 1'b1;

    assign loading = !gave_up && (!inited ? !err : (!cfg_rd || ld_pend != 2'b00));
    assign busy    = st != IDLE || ld_pend != 2'b00 || !cfg_rd;
    // the config sector's bytes
    reg  [7:0]  cfg_byte;
    always @* case (bcnt)
        9'd0: cfg_byte = "A";  9'd1: cfg_byte = "2";  9'd2: cfg_byte = "H";  9'd3: cfg_byte = "D";
        9'd4: cfg_byte = slot0[7:0]; 9'd5: cfg_byte = slot0[15:8];
        9'd6: cfg_byte = slot1[7:0]; 9'd7: cfg_byte = slot1[15:8];
        default: cfg_byte = 8'h00;
    endcase
    reg [31:0] magic = 32'd0;           // config bytes 0-3 as read

    task xfer(input [7:0] b); begin txb <= b; spi_go <= 1'b1; sx <= 1'b1; end endtask
    task go_cmd(input [2:0] p, input [31:0] l);
        begin ph <= p; cmdbuf <= cmdw(p, l); n <= 0; st <= CMDS; end
    endtask
    task fin; begin sd_cs_n <= 1'b1; st <= IDLE; end endtask
    task die;
        begin
            err <= 1'b1; estage <= ph; fin;
            ld_pend <= 2'b00; cfg_rd <= 1'b1;
            if (!to_cfg && !xw) present[drv] <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        spi_go <= 1'b0;
        m_go   <= 1'b0;
        x_take <= 1'b0;
        // the end of a copy: whichever drive holds that slot loads it afresh
        if (x_fin && !reset) begin
            if (slot0 == x_slot) begin ld_pend[0] <= 1'b1; present[0] <= 1'b0; end
            if (slot1 == x_slot) begin ld_pend[1] <= 1'b1; present[1] <= 1'b0; end
        end
        if (m_ack && m_busy) begin
            m_busy <= 1'b0;
            wword  <= m_rdata;
        end
        if (reset) begin
            st <= PWR; pcnt <= 0; fast <= 1'b0; sx <= 1'b0; got <= 1'b0; tries <= 0;
            err <= 1'b0; estage <= 0; sd_cs_n <= 1'b1; n <= 0; bcnt <= 0;
            inited <= 1'b0; cfg_rd <= 1'b0; ld_pend <= 2'b00; present <= 2'b00;
            slot0 <= 16'hFFFF; slot1 <= 16'hFFFF; m_busy <= 1'b0; to_cfg <= 1'b1;
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
                      if (n == 6) begin n <= 0; st <= (ph == CMD12) ? SKIP : R1; end
                  end
            SKIP: if (!got) xfer(8'hFF);         // CMD12's stuff byte
                  else begin got <= 1'b0; st <= R1; end
            R1: if (!got) xfer(8'hFF);
                else begin
                    got <= 1'b0; n <= n + 1'b1;
                    if (ph == CMD0 && rxv != 8'h01) begin
                        // a card left mid-transfer by a previous run still clocks out
                        // data before it answers, so keep polling for the idle R1
                        if (&n[9:0]) die;
                    end else if (!rxv[7]) begin
                        n <= 0;
                        case (ph)
                            CMD0:   if (rxv == 8'h01) go_cmd(CMD8, 32'h0); else die;
                            CMD8:   if (rxv[2]) die; else st <= EXTRA;       // illegal = SDv1
                            CMD55:  go_cmd(ACMD41, 32'h0);
                            ACMD41: if (rxv == 0) begin fast <= 1'b1; inited <= 1'b1; fin; end
                                    else if (&tries) die;
                                    else begin tries <= tries + 1'b1; go_cmd(CMD55, 32'h0); end
                            CMD24:  if (rxv == 0) st <= WGAP; else die;
                            CMD12:  st <= BSY;
                            default:if (rxv == 0) st <= DTOK; else die;      // CMD17, CMD18
                        endcase
                    end else if (n == 63) die;
                end
            EXTRA: if (!got) xfer(8'hFF);
                   else begin got <= 1'b0; n <= n + 1'b1; if (n == 3) go_cmd(CMD55, 32'h0); end

            // ---- reading: the config (CMD17) or a whole volume (CMD18) ----
            DTOK: if (!got) xfer(8'hFF);
                  else begin
                      got <= 1'b0; n <= n + 1'b1;
                      if (rxv == 8'hFE) begin bcnt <= 0; st <= DATA; end
                      else if (&n) die;
                  end
            DATA: if (!got) xfer(8'hFF);
                  else if (!(bcnt[0] && !to_cfg && m_busy)) begin   // wait for the DDR3
                      got <= 1'b0; bcnt <= bcnt + 1'b1;
                      if (to_cfg) begin
                          if (bcnt < 9'd4) magic <= {magic[23:0], rxv};
                          if (bcnt == 9'd4) slot0[7:0]  <= rxv;
                          if (bcnt == 9'd5) slot0[15:8] <= rxv;
                          if (bcnt == 9'd6) slot1[7:0]  <= rxv;
                          if (bcnt == 9'd7) slot1[15:8] <= rxv;
                      end else if (!bcnt[0]) lo <= rxv;
                      else begin
                          m_go <= 1'b1; m_we <= 1'b1; m_busy <= 1'b1;
                          m_addr  <= {drv, blk, bcnt[8:1]};
                          m_wdata <= {rxv, lo};
                      end
                      if (bcnt == 9'd511) begin n <= 0; st <= CRC; end
                  end
            CRC: if (!got) xfer(8'hFF);
                 else begin
                     got <= 1'b0; n <= n + 1'b1;
                     if (n == 1) begin
                         n <= 0;
                         if (to_cfg) begin
                             fin;
                             cfg_rd <= 1'b1;
                             // no magic: a card nobody has set up, so no volumes
                             if (magic == "A2HD")
                                 ld_pend <= {slot1 != 16'hFFFF, slot0 != 16'hFFFF};
                             else begin
                                 slot0 <= 16'hFFFF; slot1 <= 16'hFFFF;
                             end
                         end else if (blk == LAST_BLK) go_cmd(CMD12, 32'h0);
                         else begin blk <= blk + 1'b1; st <= DTOK; end
                     end
                 end
            BSY: if (!got) xfer(8'hFF);          // after CMD12, and after a write
                 else begin
                     got <= 1'b0; n <= n + 1'b1;
                     if (rxv == 8'hFF) begin
                         if (ph == CMD12) begin present[drv] <= 1'b1; ld_pend[drv] <= 1'b0; end
                         fin;
                     end else if (&n) begin ph <= CMD12; die; end
                 end

            // ---- writing: a block back, or the config ----
            WGAP: if (!got) xfer(8'hFF); else begin got <= 1'b0; st <= WTOK; end
            WTOK: if (!got) xfer(8'hFE); else begin got <= 1'b0; bcnt <= 0; st <= WBYTE; end
            WBYTE: if (!got) begin
                       if (xz) xfer(8'h00);
                       else if (xw) begin
                           if (x_valid && !x_take) begin xfer(x_byte); x_take <= 1'b1; end
                       end
                       else if (to_cfg) xfer(cfg_byte);
                       else if (bcnt[0]) xfer(wword[15:8]);
                       else if (!m_busy && !m_go) begin
                           // the word's low byte goes when its read has come back
                           if (n[0]) begin n <= 0; xfer(wword[7:0]); end
                           else begin
                               m_go <= 1'b1; m_we <= 1'b0; m_busy <= 1'b1; n <= 1;
                               m_addr <= {drv, blk, bcnt[8:1]};
                           end
                       end
                   end else begin
                       got <= 1'b0; bcnt <= bcnt + 1'b1;
                       if (bcnt == 9'd511) begin n <= 0; st <= WCRC; end
                   end
            WCRC: if (!got) xfer(8'hFF);
                  else begin got <= 1'b0; n <= n + 1'b1; if (n == 1) st <= WRESP; end
            WRESP: if (!got) xfer(8'hFF);
                   else begin
                       got <= 1'b0;
                       if (rxv[4:0] == 5'b00101) begin n <= 0; st <= BSY; end
                       else if (rxv != 8'hFF) die;
                   end

            // ---- what to do next ----
            IDLE: if (inited) begin
                      if (!cfg_rd) begin
                          // the config, once, after init
                          to_cfg <= 1'b1; sd_cs_n <= 1'b0; got <= 1'b0;
                          go_cmd(CMD17, 32'd0);
                      end else if (ld_pend != 2'b00) begin
                          if (gave_up) ld_pend <= 2'b00;
                          else if (ddr_ready) begin
                              drv <= !ld_pend[0]; blk <= 16'd0; to_cfg <= 1'b0;
                              sd_cs_n <= 1'b0; got <= 1'b0;
                              go_cmd(CMD18, {(ld_pend[0] ? slot0 : slot1), 16'd0} + 32'd2048);
                          end
                      end else if (x_go) begin
                          xw <= !x_zero; xz <= x_zero; to_cfg <= 1'b0;
                          sd_cs_n <= 1'b0; got <= 1'b0;
                          go_cmd(CMD24, {x_slot, x_blk} + 32'd2048);
                      end else if (wb_go) begin
                          xw <= 1'b0; xz <= 1'b0;
                          drv <= wb_drv; blk <= wb_blk; to_cfg <= 1'b0;
                          sd_cs_n <= 1'b0; got <= 1'b0;
                          go_cmd(CMD24, {(wb_drv ? slot1 : slot0), wb_blk} + 32'd2048);
                      end else if (mnt_go) begin
                          // the new slot goes into the config first; the load follows.
                          // One slot is never in both drives (two copies writing
                          // back to the same sectors), so the other drive lets go.
                          if (mnt_drv) slot1 <= mnt_slot; else slot0 <= mnt_slot;
                          present[mnt_drv] <= 1'b0;
                          if (mnt_slot != 16'hFFFF && mnt_slot == (mnt_drv ? slot0 : slot1)) begin
                              if (mnt_drv) slot0 <= 16'hFFFF; else slot1 <= 16'hFFFF;
                              present[!mnt_drv] <= 1'b0;
                          end
                          ld_pend[mnt_drv] <= (mnt_slot != 16'hFFFF);
                          xw <= 1'b0; xz <= 1'b0;
                          to_cfg <= 1'b1; sd_cs_n <= 1'b0; got <= 1'b0;
                          go_cmd(CMD24, 32'd0);
                      end
                  end
            default: ;
        endcase

    end
endmodule

`default_nettype wire
