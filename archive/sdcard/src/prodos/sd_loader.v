// ============================================================================
//  sd_loader.v -- boot-time SD card (SPI mode) -> ProDOS drive 1 image loader
//
//  After power-up it initialises the TF card on the Tang Nano 20K, reads
//  BLOCKS 512-byte sectors from sector 0 (raw image, no partition table) and
//  pushes them through prodos_card's byte upload port, exactly as the UART
//  uploader does.  `loading` is high until done; `fail` latches on any error
//  (no card, SDv1/SDSC card, timeout), leaving the drive empty so the slot 7
//  ROM falls back to the Disk II.
//
//  SD layout (512-byte sectors, SDHC block addressing; blk[12] selects Disk II):
//    0..4095     ProDOS drive 1 (written back on every card write)
//    4096..4375  Disk II drive 1, physical sector order (140 KB = 280 sectors)
//    4376        magic "D2IMG": the Disk II image above is valid
//  A Disk II upload over UART (d2_save pulse on the last byte) is copied to the
//  card; at boot a valid image is copied back into the store.
//
//  ponytail: SDHC/SDXC only; Apple-side writes to the Disk II image are not
//  persisted (only uploads).  Add a dirty-track write-back if that is needed.
// ============================================================================
`default_nettype none

module sd_loader #(
    parameter [12:0] BLOCKS   = 13'd4096,   // 2 MB
    parameter        PWR_BITS = 20,         // wait 2^N clocks (SDRAM + card power-up)
    parameter        SELFTEST = 1           // after loading: write/read back sector 4095, report on rpt_tx
) (
    input  wire        clk,          // 27 MHz
    input  wire        reset,

    output reg         sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output reg         sd_cs_n,

    output wire        up_go,
    output reg  [7:0]  up_data,
    output wire [20:0] up_addr,
    output wire        up_last,
    input  wire        up_busy,
    input  wire        up_done,

    output wire        down_go,
    output wire [20:0] down_addr,
    input  wire [7:0]  down_data,
    input  wire        down_valid,

    input  wire        wr_req,       // card: block wr_blk of drive 1 was written
    input  wire [11:0] wr_blk,
    output reg         wr_ack,       // write-back done (or impossible)

    // Disk II store (src/disk2/disk2_store.v), drive 1
    output wire        d2_up_go,
    output wire [17:0] d2_up_addr,
    output wire        d2_up_last,
    input  wire        d2_up_busy,
    input  wire        d2_up_done,
    output wire        d2_dn_go,
    output wire [17:0] d2_dn_addr,
    input  wire [7:0]  d2_dn_data,
    input  wire        d2_dn_valid,
    input  wire        d2_save,       // pulse: a Disk II upload just finished
    output reg         d2_own,        // loader is using the Disk II store's ports

    output reg         loading,
    output reg         fail,
    output reg         rpt_tx = 1'b1,      // 115200 8N1 status line "SD L:x T:y"
    output wire        rpt_busy
);
    // ---- SPI byte engine (mode 0; slow 211 kHz for init, 6.75 MHz after) ----
    reg        fast = 1'b0;
    reg  [7:0] sh;
    reg  [3:0] bits;
    reg  [6:0] hc;
    reg        spi_go, spi_busy, spi_done, rxb;
    wire [7:0] tx;
    wire [6:0] half = fast ? 7'd1 : 7'd63;
    assign sd_mosi = sh[7];

    always @(posedge clk) begin
        spi_done <= 1'b0;
        if (reset) begin
            sd_clk <= 1'b0; spi_busy <= 1'b0;
        end else if (spi_go) begin
            sh <= tx; bits <= 4'd0; hc <= half; spi_busy <= 1'b1;
        end else if (spi_busy) begin
            if (hc != 0) hc <= hc - 1'b1;
            else begin
                hc <= half;
                if (!sd_clk) begin sd_clk <= 1'b1; rxb <= sd_miso; end
                else begin
                    sd_clk <= 1'b0; sh <= {sh[6:0], rxb}; bits <= bits + 1'b1;
                    if (bits == 4'd7) begin spi_busy <= 1'b0; spi_done <= 1'b1; end
                end
            end
        end
    end

    // ---- SD protocol ----
    localparam [3:0] PWR = 0, DUM = 1, CMDS = 2, R1 = 3, EXTRA = 4, DTOK = 5,
                     DATA = 6, PUSH = 7, PW1 = 8, PW2 = 9, CRC = 10, DONE = 11,
                     WTOK = 12, WFET = 13, WF1 = 14, WDAT = 15;
    // write-back continues in st2 (WCRC/WRESP/WBSY) while st == WDAT's spi bookkeeping
    localparam [1:0] W_DATA = 0, W_CRC = 1, W_RESP = 2, W_BSY = 3;
    localparam [2:0] CMD0 = 0, CMD8 = 1, CMD55 = 2, ACMD41 = 3, CMD17 = 4, CMD24 = 5;

    reg [3:0]  st = PWR;
    reg [2:0]  ph;
    reg        armed;
    reg [PWR_BITS-1:0] pcnt = 0;
    reg [15:0] n;
    reg [47:0] cmdbuf;
    reg [12:0] blk;
    reg [11:0] tries;      // ACMD41 retries (~2 s at 211 kHz)
    reg [8:0]  bcnt;
    reg        pgo, dgo;            // push / fetch request; routed by blk[12]
    reg        sv_pend, sv, mgw;    // save requested / saving / writing the magic sector
    reg [9:0]  sv_cnt;              // settle time after the upload's last byte
    reg        mchk, mbad, ld, d2done;
    reg [2:0]  dst;                 // 0 none, 1 loading, 2 loaded, 3 saving, 4 saved, 5 error

    function [47:0] cmdw(input [2:0] p, input [12:0] b);
        case (p)
            CMD0:   cmdw = {8'h40, 32'h0,          8'h95};
            CMD8:   cmdw = {8'h48, 32'h000001AA,   8'h87};
            CMD55:  cmdw = {8'h77, 32'h0,          8'h01};
            ACMD41: cmdw = {8'h69, 32'h40000000,   8'h01};
            CMD24:  cmdw = {8'h58, 19'd0, b,       8'h01};
            default:cmdw = {8'h51, 19'd0, b,       8'h01};   // SDHC: block address
        endcase
    endfunction

    reg        tst, tdone, tbad;    // self-test running / has run / mismatch seen
    reg  [7:0] lrx;                 // last byte seen while polling for R1 / data token
    reg  [2:0] fph;                 // command in progress when die was called
    reg  [1:0] tres;                // 0 not run, 1 pass, 2 command/timeout error, 3 mismatch
    reg  [7:0] wbyte;
    reg  [1:0] wph;         // which write-back tail state WDAT is serving
    function [7:0] mg(input [8:0] i);
        case (i) 0: mg = "D"; 1: mg = "2"; 2: mg = "I"; 3: mg = "M"; 4: mg = "G"; default: mg = 8'h00; endcase
    endfunction
    assign tx      = (st == CMDS && n != 0) ? cmdbuf[47:40] :   // n==0: idle byte first
                     (st == WTOK) ? 8'hFE :
                     (st == WDAT && wph == W_DATA) ? (tst ? bcnt[7:0] ^ 8'hA5 : mgw ? mg(bcnt) : wbyte) : 8'hFF;
    assign up_go      = pgo & ~blk[12];
    assign d2_up_go   = pgo &  blk[12];
    assign down_go    = dgo & ~blk[12];
    assign d2_dn_go   = dgo &  blk[12];
    assign d2_up_addr = {blk[8:0], bcnt};
    assign d2_dn_addr = {blk[8:0], bcnt};
    assign d2_up_last = (blk == 13'd4375) && (bcnt == 9'd511);
    wire       ubsy   = blk[12] ? d2_up_busy  : up_busy;
    wire       udone  = blk[12] ? d2_up_done  : up_done;
    wire       dvalid = blk[12] ? d2_dn_valid : down_valid;
    wire [7:0] ddata  = blk[12] ? d2_dn_data  : down_data;
    assign down_addr = {blk[11:0], bcnt};
    assign up_addr = {blk[11:0], bcnt};
    assign up_last = (blk == BLOCKS - 1'b1) && (bcnt == 9'd511);

    wire spi_st = (st == DUM) || (st == CMDS) || (st == R1) || (st == EXTRA) ||
                  (st == DTOK) || (st == DATA) || (st == CRC) || (st == WTOK) || (st == WDAT);

    task go_cmd(input [2:0] p);
        begin ph <= p; cmdbuf <= cmdw(p, blk); n <= 0; st <= CMDS; end
    endtask
    task die;
        begin fail <= 1'b1; fph <= ph; loading <= 1'b0; sd_cs_n <= 1'b1; st <= DONE;
              sv <= 1'b0; sv_pend <= 1'b0; mgw <= 1'b0; mchk <= 1'b0; ld <= 1'b0; d2_own <= 1'b0;
              if (d2_own) dst <= 3'd5; end
    endtask

    always @(posedge clk) begin
        spi_go <= 1'b0;
        pgo <= 1'b0;
        dgo <= 1'b0;
        if (d2_save) begin sv_pend <= 1'b1; sv_cnt <= 0; end
        else if (sv_pend && !(&sv_cnt)) sv_cnt <= sv_cnt + 1'b1;
        wr_ack <= 1'b0;
        if (reset) begin
            st <= PWR; pcnt <= 0; armed <= 1'b0; fast <= 1'b0; blk <= 0; bcnt <= 0; tries <= 0; tst <= 0; lrx <= 0; fph <= 0; tdone <= 0; tres <= 0; tbad <= 0;
            sv_pend <= 0; sv_cnt <= 0; sv <= 0; mgw <= 0; mchk <= 0; mbad <= 0; ld <= 0; d2done <= 0; dst <= 0; d2_own <= 0;
            sd_cs_n <= 1'b1; loading <= 1'b1; fail <= 1'b0;
        end else if (spi_st && !armed) begin
            spi_go <= 1'b1; armed <= 1'b1;
        end else if (spi_st && spi_done) begin
            armed <= 1'b0;
            case (st)
                DUM: begin
                    n <= n + 1'b1;
                    if (n == 9) begin sd_cs_n <= 1'b0; go_cmd(CMD0); end
                end
                CMDS: begin
                    if (n != 0) cmdbuf <= cmdbuf << 8;
                    n <= n + 1'b1;
                    if (n == 6) begin n <= 0; st <= R1; end
                end
                R1: begin
                    n <= n + 1'b1; lrx <= sh;
                    if (sh[7:6] == 2'b00) begin
                        n <= 0;
                        case (ph)
                            CMD0:   if (sh == 8'h01) go_cmd(CMD8); else die;
                            CMD8:   if (sh[2]) die; else st <= EXTRA;   // illegal cmd = SDv1
                            CMD55:  go_cmd(ACMD41);
                            ACMD41: if (sh == 0) begin fast <= 1'b1; go_cmd(CMD17); end
                                    else if (&tries) die;
                                    else begin tries <= tries + 1'b1; go_cmd(CMD55); end
                            CMD24:  if (sh == 0) st <= WTOK; else die;
                            default:if (sh == 0) st <= DTOK; else die;
                        endcase
                    end else if (n == 63) die;
                end
                EXTRA: begin n <= n + 1'b1; if (n == 3) go_cmd(CMD55); end
                DTOK: begin
                    n <= n + 1'b1; lrx <= sh;
                    if (sh == 8'hFE) begin bcnt <= 0; st <= DATA; end
                    else if (&n) die;
                end
                DATA: if (tst || mchk) begin
                          if (tst ? (sh != (bcnt[7:0] ^ 8'hA5)) : (bcnt < 5 && sh != mg(bcnt))) begin
                              if (tst) tbad <= 1'b1; else mbad <= 1'b1;
                          end
                          bcnt <= bcnt + 1'b1; n <= 0;
                          st <= (bcnt == 9'd511) ? CRC : DATA;
                      end else begin up_data <= sh; st <= PUSH; end
                WTOK: begin bcnt <= 0; wph <= W_DATA; st <= (tst || mgw) ? WDAT : WFET; end
                WDAT: begin
                    n <= n + 1'b1;
                    case (wph)
                        W_DATA: begin
                            bcnt <= bcnt + 1'b1; n <= 0;
                            if (bcnt == 9'd511) wph <= W_CRC; else if (!tst && !mgw) st <= WFET;
                        end
                        W_CRC:  if (n == 1) begin wph <= W_RESP; end
                        W_RESP: if (sh[4:0] == 5'b00101) begin wph <= W_BSY; n <= 0; end else die;
                        W_BSY:  if (sh == 8'hFF) begin
                                    if (tst) begin     // read it back
                                        cmdbuf <= cmdw(CMD17, blk); ph <= CMD17; n <= 0; st <= CMDS;
                                    end else if (sv) begin
                                        if (mgw) begin
                                            sv <= 1'b0; mgw <= 1'b0; d2_own <= 1'b0; dst <= 3'd4; sd_cs_n <= 1'b1; st <= DONE;
                                        end else if (blk == 13'd4375) begin
                                            blk <= 13'd4376; mgw <= 1'b1;
                                            cmdbuf <= cmdw(CMD24, 13'd4376); ph <= CMD24; n <= 0; st <= CMDS;
                                        end else begin
                                            blk <= blk + 1'b1;
                                            cmdbuf <= cmdw(CMD24, blk + 1'b1); ph <= CMD24; n <= 0; st <= CMDS;
                                        end
                                    end else begin sd_cs_n <= 1'b1; wr_ack <= 1'b1; st <= DONE; end
                                end
                                else if (&n) die;
                    endcase
                end
                CRC: begin
                    n <= n + 1'b1;
                    if (n == 1) begin
                        if (tst) begin
                            tst <= 1'b0; tres <= tbad ? 2'd3 : 2'd1; sd_cs_n <= 1'b1; st <= DONE;
                        end else if (mchk) begin
                            mchk <= 1'b0; d2done <= 1'b1;
                            if (mbad) begin sd_cs_n <= 1'b1; st <= DONE; end
                            else begin
                                d2_own <= 1'b1; ld <= 1'b1; dst <= 3'd1; blk <= 13'd4096;
                                cmdbuf <= cmdw(CMD17, 13'd4096); ph <= CMD17; n <= 0; st <= CMDS;
                            end
                        end else if (ld && blk == 13'd4375) begin
                            ld <= 1'b0; d2_own <= 1'b0; dst <= 3'd2; sd_cs_n <= 1'b1; st <= DONE;
                        end else if (!ld && blk == BLOCKS - 1'b1) begin
                            sd_cs_n <= 1'b1; loading <= 1'b0; st <= DONE;
                        end else begin blk <= blk + 1'b1; cmdbuf <= cmdw(CMD17, blk + 1'b1); ph <= CMD17; n <= 0; st <= CMDS; end
                    end
                end
            endcase
        end else case (st)
            PWR: begin
                pcnt <= pcnt + 1'b1;
                if (&pcnt) begin st <= DUM; n <= 0; end
            end
            // Card can drop a push (bf_state busy), so resend until up_done.
            PUSH: if (!ubsy) begin pgo <= 1'b1; st <= PW1; end
            PW1:  st <= PW2;
            PW2:  if (udone) begin
                      bcnt <= bcnt + 1'b1; n <= 0;
                      st <= (bcnt == 9'd511) ? CRC : DATA;
                  end else st <= PUSH;
            WFET: begin dgo <= 1'b1; n <= 0; st <= WF1; end
            WF1:  if (dvalid) begin wbyte <= ddata; st <= WDAT; end
                  else begin n <= n + 1'b1; if (&n[7:0]) st <= WFET; end   // card dropped it
            DONE: if (tst) begin                   // self-test died (die sets fail)
                      tst <= 1'b0; tres <= 2'd2;
                  end else if (SELFTEST && !tdone && !fail && !wr_req) begin
                      tdone <= 1'b1; tst <= 1'b1; sd_cs_n <= 1'b0; blk <= BLOCKS - 1'b1;
                      cmdbuf <= cmdw(CMD24, BLOCKS - 1'b1); ph <= CMD24; n <= 0; st <= CMDS;
                  end else if (wr_req && !wr_ack) begin
                      if (fail) wr_ack <= 1'b1;      // no card: don't hang the CPU
                      else begin sd_cs_n <= 1'b0; blk <= {1'b0, wr_blk};
                                 cmdbuf <= cmdw(CMD24, {1'b0, wr_blk}); ph <= CMD24; n <= 0; st <= CMDS; end
                  end else if (!wr_req && !fail && sv_pend && &sv_cnt && !d2_up_busy) begin
                      // a Disk II upload finished: copy the store to the card
                      sv_pend <= 1'b0; sv <= 1'b1; d2done <= 1'b1; d2_own <= 1'b1; dst <= 3'd3;
                      sd_cs_n <= 1'b0; blk <= 13'd4096;
                      cmdbuf <= cmdw(CMD24, 13'd4096); ph <= CMD24; n <= 0; st <= CMDS;
                  end else if (!wr_req && !fail && !sv_pend && !d2done && (tdone || !SELFTEST)) begin
                      // boot: is there a Disk II image on the card?
                      sd_cs_n <= 1'b0; mchk <= 1'b1; mbad <= 1'b0; blk <= 13'd4376;
                      cmdbuf <= cmdw(CMD17, 13'd4376); ph <= CMD17; n <= 0; st <= CMDS;
                  end else if (fail) sv_pend <= 1'b0;
            default: ;
        endcase
    end

    // ---- status line "SD L:x R:hh T:y D:z" + CR LF, every 2^25 clocks, 30 times ----
    // x: '.' loading, 'K' loaded, 'F' failed;  y: '0' not run, '1' pass, '2' error, '3' mismatch
    reg [24:0] rc = 0;
    reg [4:0]  rn = 0;
    reg [4:0]  ci;
    reg [9:0]  rsh = 10'h3FF;
    reg [3:0]  rbits = 0;
    reg [7:0]  rdiv = 0;
    reg        rsend = 0;
    assign rpt_busy = rsend;
    function [7:0] hexc(input [3:0] v); hexc = v < 10 ? "0" + v : "A" + v - 10; endfunction
    reg [7:0] ch;
    always @(*) case (ci)
        0: ch = "S"; 1: ch = "D"; 2: ch = " "; 3: ch = "L"; 4: ch = ":";
        5: ch = fail ? "a" + fph : loading ? "." : "K";   // a=CMD0 b=CMD8 c=CMD55 d=ACMD41 e=CMD17 f=CMD24
        6: ch = " "; 7: ch = "R"; 8: ch = ":";
        9: ch = hexc(lrx[7:4]); 10: ch = hexc(lrx[3:0]);
        11: ch = " "; 12: ch = "T"; 13: ch = ":"; 14: ch = "0" + tres;
        15: ch = " "; 16: ch = "D"; 17: ch = ":"; 18: ch = "0" + dst;   // 0 none 1 loading 2 loaded 3 saving 4 saved 5 error
        19: ch = 8'h0D; default: ch = 8'h0A;
    endcase
    always @(posedge clk) begin
        if (reset) begin rc <= 0; rn <= 0; rsend <= 0; rpt_tx <= 1'b1; ci <= 0; end
        else if (!rsend) begin
            rc <= rc + 1'b1; ci <= 0;
            if (&rc && rn != 30) begin
                rn <= rn + 1'b1; rsend <= 1'b1; rbits <= 0; rdiv <= 0;
                rsh <= {1'b1, ch, 1'b0}; ci <= 1;
            end
        end else if (rdiv != 8'd233) rdiv <= rdiv + 1'b1;   // 27 MHz / 115200
        else begin
            rdiv <= 0; rpt_tx <= rsh[0]; rsh <= {1'b1, rsh[9:1]}; rbits <= rbits + 1'b1;
            if (rbits == 4'd10) begin          // 10 frame bits + 1 idle bit sent
                rbits <= 0;
                if (ci == 21) rsend <= 1'b0;
                else begin rsh <= {1'b1, ch, 1'b0}; ci <= ci + 1'b1; end
            end
        end
    end
endmodule

`default_nettype wire
