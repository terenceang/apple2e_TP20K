// ============================================================================
//  fat_test.v -- raw FAT32 test on the TF card, no Apple core, as a client of
//  src/sd/fat32.v: mount, create TEST.TXT, write "Hello World", read it back
//  through the directory, delete it, verify it is gone and its cluster free.
//  Progress and the verdict go out on uart_tx (115200 8N1); the verdict line
//  repeats every ~1.2 s so a terminal can attach late.
//
//  Needs an SDHC card formatted FAT32 (MBR or superfloppy), root cluster 2.
//  See fat32.v for its limits.
// ============================================================================
`default_nettype none

module fat_test #(
    parameter PWR_BITS    = 20,
    parameter REPEAT_BITS = 25          // verdict repeat period, 2^N clocks
) (
    input  wire clk,
    input  wire reset,
    output wire sd_clk,
    output wire sd_mosi,
    input  wire sd_miso,
    output wire sd_cs_n,
    output wire uart_tx,
    output reg  pass = 1'b0,
    output reg  failed = 1'b0
);
    // ---- the file layer ----
    reg         go;
    reg  [3:0]  cmd;
    reg  [31:0] arg;
    reg  [6:0]  nlen;
    reg  [8:0]  cba;
    reg         cbwe;
    reg  [7:0]  cbwd;
    reg  [5:0]  cna;
    reg         cnwe;
    reg  [7:0]  cnwd;
    wire        busy, err, found, berr;
    wire [3:0]  ecode;
    wire [31:0] r_cluster, r_size, file_lba, fat1_lba;
    wire [87:0] r_sfn;
    wire [6:0]  r_nlen;
    wire [7:0]  lrx, brd, cnrd;
    wire [2:0]  bstage;
    fat32 #(.PWR_BITS(PWR_BITS)) u_fat (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .go(go), .cmd(cmd), .arg(arg), .busy(busy), .err(err), .ecode(ecode), .found(found),
        .r_cluster(r_cluster), .r_size(r_size), .r_sfn(r_sfn), .r_nlen(r_nlen), .file_lba(file_lba),
        .fat1_lba(fat1_lba), .lrx(lrx), .bstage(bstage), .berr(berr), .nlen(nlen),
        .cba(cba), .cbwe(cbwe), .cbwd(cbwd), .brd(brd), .cna(cna), .cnwe(cnwe), .cnwd(cnwd), .cnrd(cnrd));
    localparam [3:0] CMD_MOUNT = 1, CMD_SFN = 3, CMD_ALLOC = 4, CMD_ADD = 5, CMD_DEL = 7, CMD_RD = 8, CMD_WR = 9;

    // ---- constants ----
    localparam [87:0] HW = "Hello World";
    localparam [87:0] SN = "TEST    TXT";
    localparam [63:0] LN = "TEST.TXT";
    function [7:0] txt(input [8:0] i);
        txt = (i < 11) ? HW[8*(10-i) +: 8] : 8'h00;
    endfunction

    // ---- messages ----
    function [7:0] ch(input [8*24-1:0] s, input [5:0] i);
        ch = s[8*(23-i) +: 8];
    endfunction
    function [7:0] hexc(input [3:0] v); hexc = v < 10 ? "0" + v : "A" + v - 10; endfunction
    reg [7:0] step, fst;
    function [7:0] msg(input [7:0] id, input [5:0] i);
        case (id)
            0: msg = ch({"SD INIT OK\r\n",          {12{8'h00}}}, i);
            1: msg = ch({"MOUNT FAT32 OK\r\n",      {8{8'h00}}},  i);
            2: msg = ch({"CREATE test.txt OK\r\n",  {4{8'h00}}},  i);
            3: msg = ch({"READ OK: Hello World\r\n",{2{8'h00}}},  i);
            4: msg = ch({"DELETE OK\r\n",           {13{8'h00}}}, i);
            5: msg = ch({"PASS\r\n",                {18{8'h00}}}, i);
            default: case (i)              // FAIL s<step> e<fat32 error> b<sd cmd> r<last R1> @<state>
                0: msg = "F"; 1: msg = "A"; 2: msg = "I"; 3: msg = "L"; 4: msg = " ";
                5: msg = "s"; 6: msg = "0" + step; 7: msg = " "; 8: msg = "e"; 9: msg = hexc(ecode);
                10: msg = " "; 11: msg = "b"; 12: msg = "0" + {5'b0, bstage}; 13: msg = " "; 14: msg = "r";
                15: msg = hexc(lrx[7:4]); 16: msg = hexc(lrx[3:0]); 17: msg = " "; 18: msg = "@";
                19: msg = hexc(fst[7:4]); 20: msg = hexc(fst[3:0]); 21: msg = 8'h0D; 22: msg = 8'h0A;
                default: msg = 8'h00;
            endcase
        endcase
    endfunction
    localparam [7:0] MSG_FAIL = 6;

    // ---- program ----
    localparam [5:0]
        S_INIT = 0, S_SAYW = 1, S_MOUNT = 2, S_AL = 3, S_AL2 = 4, S_WT = 5, S_WT2 = 6, S_NM = 7, S_NM2 = 8, S_ADD = 9,
        S_V0 = 10, S_V1 = 11, S_V2 = 12, S_V3 = 13, S_V4 = 14, S_V5 = 15,
        S_D0 = 16, S_D1 = 17, S_D2 = 18, S_D3 = 19, S_D4 = 20, S_D5 = 21, S_D6 = 22, S_D7 = 23,
        S_PASS = 24, S_END = 25, S_P2 = 26;
    reg [5:0]  st, nst;
    reg [1:0]  cw;                       // wait for the layer to take the command
    reg [31:0] c1;
    reg [8:0]  k;
    reg [1:0]  rw;                       // buffer read latency
    // printer
    reg [7:0]  pid;
    reg [5:0]  pidx;
    reg        pbusy;
    wire       tbusy;
    reg [7:0]  fin_id;
    reg [REPEAT_BITS-1:0] rcnt;
    wire [7:0] pc = msg(pid, pidx);
    wire       pstart = pbusy && !tbusy && pc != 0;
    uart_tx u_tx (.clk(clk), .reset(reset), .data(pc), .start(pstart), .tx(uart_tx), .busy(tbusy));

    task CMD(input [3:0] c, input [31:0] a, input [5:0] nx);
        begin go <= 1'b1; cmd <= c; arg <= a; cw <= 2; st <= nx; end
    endtask
    task SAY(input [7:0] id, input [5:0] nx);
        begin pid <= id; pidx <= 0; pbusy <= 1'b1; nst <= nx; st <= S_SAYW; end
    endtask
    task FAIL;
        begin fst <= {2'b00, st}; failed <= 1'b1; fin_id <= MSG_FAIL;
              pid <= MSG_FAIL; pidx <= 0; pbusy <= 1'b1; nst <= S_END; st <= S_SAYW; end
    endtask
    task NAME(input [5:0] i, input [7:0] d);                     // write name RAM[i]
        begin cna <= i; cnwd <= d; cnwe <= 1'b1; end
    endtask

    always @(posedge clk) begin
        go <= 1'b0; cbwe <= 1'b0; cnwe <= 1'b0;
        if (pstart) pidx <= pidx + 1'b1;
        else if (pbusy && !tbusy && pc == 0) pbusy <= 1'b0;

        if (reset) begin
            st <= S_INIT; cw <= 0; pbusy <= 0; pass <= 0; failed <= 0; step <= 0; fst <= 0; rcnt <= 0; fin_id <= 5; k <= 0; rw <= 0;
            nlen <= 0;
        end else if (cw != 0) cw <= cw - 1'b1;
        else if (busy) ;
        else if (err && st != S_SAYW && st != S_END) FAIL;
        else case (st)
            S_SAYW: if (!pbusy && !tbusy) st <= nst;
            S_INIT: SAY(0, S_MOUNT);
            S_MOUNT: begin step <= 1; CMD(CMD_MOUNT, 0, S_AL); end
            S_AL:    SAY(1, S_AL2);
            // ---- create: cluster, data sector, directory entry ----
            S_AL2:   begin step <= 2; CMD(CMD_ALLOC, 11, S_WT); end
            S_WT:    begin c1 <= r_cluster; k <= 0; st <= S_WT2; end
            S_WT2:   begin                                           // "Hello World" into the buffer, zero-filled
                         cba <= k; cbwd <= txt(k); cbwe <= 1'b1; k <= k + 1'b1;
                         if (k == 511) st <= S_NM;
                     end
            S_NM:    CMD(CMD_WR, file_lba, S_NM2);
            S_NM2:   begin k <= 0; st <= S_ADD; end
            S_ADD:   begin                                           // "TEST.TXT" into name RAM
                         NAME(k[5:0], LN[8*(7-k[2:0]) +: 8]); k <= k + 1'b1;
                         if (k == 7) begin nlen <= 8; st <= S_V0; end
                     end
            S_V0:    CMD(CMD_ADD, 0, S_V1);
            S_V1:    SAY(2, S_V2);
            // ---- read back: look it up by its short name, then read its sector ----
            S_V2:    begin step <= 3; k <= 0; st <= S_V3; end
            S_V3:    begin NAME(k[5:0], SN[8*(10-k[3:0]) +: 8]); k <= k + 1'b1; if (k == 10) st <= S_V4; end
            S_V4:    CMD(CMD_SFN, 0, S_V5);
            S_V5:    if (!found || r_size != 11 || r_cluster != c1) FAIL; else CMD(CMD_RD, file_lba, S_D0);
            S_D0:    begin k <= 0; rw <= 0; cba <= 0; st <= S_D1; end
            S_D1:    begin                                           // brd is valid 2 clocks after cba
                         if (rw != 2) rw <= rw + 1'b1;
                         else begin
                             if (brd != txt(k)) FAIL;
                             else if (k == 10) SAY(3, S_D2);
                             else begin k <= k + 1'b1; cba <= k + 1'b1; rw <= 0; end
                         end
                     end
            // ---- delete: the file is gone and its cluster is free in the FAT ----
            S_D2:    begin step <= 4; CMD(CMD_DEL, 0, S_D3); end
            S_D3:    begin step <= 5; k <= 0; st <= S_D4; end
            S_D4:    begin NAME(k[5:0], SN[8*(10-k[3:0]) +: 8]); k <= k + 1'b1; if (k == 10) st <= S_D5; end
            S_D5:    CMD(CMD_SFN, 0, S_D6);
            S_D6:    if (found) FAIL; else CMD(CMD_RD, fat1_lba + (c1 >> 7), S_D7);
            S_D7:    begin rw <= 0; cba <= {c1[6:0], 2'b00}; st <= S_PASS; end
            S_PASS:  begin
                         if (rw != 2) rw <= rw + 1'b1;
                         else if (brd != 0) FAIL;
                         else begin pass <= 1'b1; fin_id <= 5; SAY(4, S_P2); end
                     end
            S_P2:    SAY(5, S_END);
            S_END:   begin rcnt <= rcnt + 1'b1; if (&rcnt) SAY(fin_id, S_END); end
            default: ;
        endcase
    end
endmodule

`default_nettype wire
