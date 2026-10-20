// ============================================================================
//  sd_files.v -- the SD card at the file level: boot-time mount of the images named in
//  TN20K.CFG, the host's file manager (list / put / get / delete / rename / mount) and the
//  ProDOS HD write-back, all on src/sd/fat32.v.
//
//  Mounts: slot 0/1 = Disk II drive 1/2 (file must be D2_BYTES), slot 2/3 = ProDOS HD drive
//  1/2 (HD_BYTES).  The Disk II store holds a track in physical sector order: a ".PO" file
//  already is, any other floppy file (.DSK, .DO) is in DOS 3.3 order and its sectors are
//  re-ordered as they are loaded (D2_PHYS below; web/test/sdfiles.test.js checks it against
//  DOS_TO_PHYS in web/src/disk.js).  The mounted files are named in TN20K.CFG (four 11-byte short names),
//  which fat32 keeps out of listings.  Writes the //e makes to a Disk II image stay in the
//  store (not persisted); writes to ProDOS HD drive 1 go back into its file.
//
//  Host protocol (the debugger passes bytes through while `f_active`, after its `f` command;
//  strictly request / response: the host sends nothing until the reply is complete):
//    FPGA: "FILES\n" when the session starts.     Numbers are upper-case hex.
//    'L'                -> "F\t<idx 2>\t<size 8>\t<name>\n" per file, then "OK\n"
//    'S'                -> "S\t<slot 1>\t<name or ->\n" x4, then "OK\n"
//    'P' len name size4 -> "GO\n", then the file in 512-byte chunks (the last may be short),
//                          each answered by 0x06; finally "OK\n"  (the name must not exist)
//    'G' idx2           -> "GO <size 8>\n", the file bytes, "OK\n"
//    'D' idx2           -> "OK\n"            (refused while the file is mounted)
//    'R' idx2           -> "GO\n", then len name -> "OK\n"   (refused while mounted)
//    'M' slot idx2      -> "OK\n" once loaded (the file's size must match the slot)
//    'Q' or 0x02        -> "BYE\n", back to the debugger
//    any error          -> "ERR <hex>\n": fat32 codes 1-5, 8 bad size, 9 mounted, A no such file, B bad command
//
//  ponytail: see fat32.v.  A card without TN20K.CFG mounts nothing.  A failed put can leave
//  an unreferenced cluster run (chkdsk repairs it).  Names must not already exist (the host
//  deletes first): the long name is not compared, only the short name made from it.
// ============================================================================
`default_nettype none

module sd_files #(
    parameter        PWR_BITS = 20,
    parameter [31:0] D2_BYTES = 32'd143360,
    parameter [31:0] HD_BYTES = 32'd2097152,
    parameter        RPT_BITS = 25
) (
    input  wire        clk,
    input  wire        reset,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,

    // file session with the debugger
    input  wire        f_start,
    input  wire        f_rx_valid,
    input  wire [7:0]  f_rx_byte,
    output reg         f_tx_valid,
    output reg  [7:0]  f_tx_byte,
    input  wire        f_tx_ready,
    output reg         f_active,

    // image stores (their byte-wise upload ports; the top muxes them against the debugger's)
    output reg         d2_own,
    output reg         d2_up_go,
    output reg         hd_own,
    output reg         hd_up_go,
    output reg         up_drive,
    output reg  [20:0] up_addr,
    output reg  [7:0]  up_data,
    output reg         up_last,
    input  wire        d2_up_busy,
    input  wire        d2_up_done,
    input  wire        hd_up_busy,
    input  wire        hd_up_done,

    // ProDOS HD write-back
    input  wire        wr_req,
    input  wire [11:0] wr_blk,
    output reg         wr_ack,
    output reg         hd_dn_go,
    output wire [20:0] hd_dn_addr,
    input  wire [7:0]  hd_dn_data,
    input  wire        hd_dn_valid,

    // boot status line
    output wire        rpt_tx,
    output wire        rpt_busy
);
    // ---- the file layer ----
    reg         go;
    reg  [3:0]  cmd;
    reg  [31:0] arg;
    reg  [6:0]  nlr;
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
        .fat1_lba(fat1_lba), .lrx(lrx), .bstage(bstage), .berr(berr), .nlen(nlr),
        .cba(cba), .cbwe(cbwe), .cbwd(cbwd), .brd(brd), .cna(cna), .cnwe(cnwe), .cnwd(cnwd), .cnrd(cnrd));
    localparam [3:0] CMD_MOUNT = 1, CMD_IDX = 2, CMD_SFN = 3, CMD_ALLOC = 4, CMD_ADD = 5,
                     CMD_REMOVE = 6, CMD_RD = 8, CMD_WR = 9, CMD_DEL = 7;
    localparam [3:0] X_SIZE = 8, X_MOUNTED = 9, X_NOFILE = 10, X_CMD = 11;

    // ---- messages ----
    function [7:0] ch(input [8*8-1:0] s, input [3:0] i);
        ch = s[8*(7-i) +: 8];
    endfunction
    function [7:0] hexc(input [3:0] v); hexc = v < 10 ? "0" + v : "A" + v - 10; endfunction
    function [7:0] msg(input [3:0] id, input [3:0] i);
        case (id)
            0: msg = ch({"FILES\n", {2{8'h00}}}, i);
            1: msg = ch({"OK\n", {5{8'h00}}}, i);
            2: msg = ch({"GO\n", {5{8'h00}}}, i);
            3: msg = ch({"BYE\n", {4{8'h00}}}, i);
            4: msg = ch({"ERR ", {4{8'h00}}}, i);
            5: msg = ch({"\n", {7{8'h00}}}, i);
            6: msg = ch({"F\t", {6{8'h00}}}, i);
            7: msg = ch({"S\t", {6{8'h00}}}, i);
            8: msg = ch({"\t", {7{8'h00}}}, i);
            9: msg = ch({"-", {7{8'h00}}}, i);
            default: msg = ch({"GO ", {5{8'h00}}}, i);
        endcase
    endfunction

    // ---- state ----
    localparam [7:0]
        S_RST = 0,  S_BOOT = 1, S_B1 = 2,  S_B2 = 3,  S_B3 = 4,  S_CMD = 5,  S_FAIL = 6,
        S_PR = 7,   S_PN0 = 8,  S_PN1 = 9, S_TX = 10, S_ERR = 11, S_ERR1 = 12, S_ERR2 = 13,
        S_RXN = 14, S_RXNAME = 15, S_OK = 16,
        S_GS0 = 17, S_GS1 = 18, S_GS2 = 19, S_GS3 = 20, S_GS4 = 21, S_GS5 = 22, S_GS6 = 23, S_CP0 = 24, S_CP1 = 25,
        S_LD0 = 26, S_LD1 = 27, S_LD2 = 28, S_LD3 = 29, S_LD4 = 30, S_LD5 = 31, S_LD6 = 32, S_LD7 = 33,
        S_L0 = 34,  S_L1 = 35,  S_L2 = 36,  S_L3 = 37,  S_L4 = 38,  S_L5 = 39,  S_L6 = 40,  S_L7 = 41, S_L8 = 42,
        S_SL0 = 43, S_SL1 = 44, S_SL2 = 45, S_SL3 = 46, S_SL4 = 47, S_SL5 = 48, S_SL6 = 49,
        S_P0 = 50,  S_P1 = 51,  S_P2 = 52,  S_P3 = 53,  S_P4 = 54,  S_P5 = 55,  S_P6 = 56,  S_P7 = 57, S_P8 = 58, S_P9 = 59,
        S_G0 = 60,  S_G1 = 61,  S_G2 = 62,  S_G3 = 63,  S_G4 = 64,  S_G5 = 65,  S_G6 = 66,  S_G7 = 67, S_G8 = 68,
        S_D0 = 69,  S_D1 = 70,  S_D2 = 71,  S_D3 = 72,  S_D4 = 73,
        S_R0 = 74,  S_R1 = 75,  S_R2 = 76,  S_R3 = 77,  S_R4 = 78,  S_R5 = 79,  S_R6 = 80,  S_R7 = 81, S_R8 = 82, S_R9 = 83,
        S_M0 = 84,  S_M1 = 85,  S_M2 = 86,  S_M3 = 87,
        S_C0 = 88,  S_C1 = 89,  S_C2 = 90,  S_C3 = 91,  S_C4 = 92,  S_C5 = 93,  S_C6 = 94,  S_C7 = 95, S_C8 = 96,
        S_CF2 = 97, S_CF3 = 98, S_CF4 = 99, S_CF5 = 100,
        S_W0 = 101, S_W1 = 102, S_W2 = 103, S_W3 = 104;
    reg [7:0]  st;
    reg [7:0]  pret, rnext, gret, lret, cret;           // return states
    reg [1:0]  cw;                       // wait for fat32 to take a command
    // receive
    reg [31:0] rxw;
    reg [2:0]  rxn, rxi;
    reg [6:0]  nl, ri;                   // received name length / index
    reg [31:0] psize, sidx, nsec;
    reg [9:0]  bi, bcnt;                 // 10 bits: a chunk is 512 bytes, so the count reaches 512
    reg [1:0]  rw;
    reg [3:0]  k;
    // print engine
    reg        pk;
    reg [3:0]  pid, pidx;
    reg [31:0] hv;
    reg [3:0]  hn;
    reg [7:0]  pc;
    reg [6:0]  ni;
    // slots / mounts
    reg [2:0]  slot, mslot;
    reg [87:0] msfn;
    reg [15:0] idx;
    reg        gok;
    reg [7:0]  fb;                       // first byte of a copied name
    reg [31:0] hd_lba;
    reg        hd_valid;
    reg        ready, bfail;
    reg [3:0]  cur_err;
    reg        is_new;                   // TN20K.CFG is being created
    reg        dos_order;                // the floppy file being loaded is in DOS 3.3 sector order
    reg [7:0]  wb_n;
    reg [3:0]  ackcool;
    reg        fs_prev, start_pend;              // a rising edge of f_start, remembered until it is served
    wire       ubsy  = hd_own ? hd_up_busy : d2_up_busy;
    wire       udone = hd_own ? hd_up_done : d2_up_done;
    assign hd_dn_addr = {wr_blk, bi[8:0]};

    localparam [87:0] CFGN = "TN20K   CFG";
    // DOS 3.3 logical sector -> physical sector (the same table as DOS_TO_PHYS in web/src/disk.js)
    function [3:0] d2_phys(input [3:0] ls);
        case (ls)
            0: d2_phys = 4'h0; 1: d2_phys = 4'h7; 2: d2_phys = 4'hE; 3: d2_phys = 4'h6;
            4: d2_phys = 4'hD; 5: d2_phys = 4'h5; 6: d2_phys = 4'hC; 7: d2_phys = 4'h4;
            8: d2_phys = 4'hB; 9: d2_phys = 4'h3; 10: d2_phys = 4'hA; 11: d2_phys = 4'h2;
            12: d2_phys = 4'h9; 13: d2_phys = 4'h1; 14: d2_phys = 4'h8; default: d2_phys = 4'hF;
        endcase
    endfunction
    wire [20:0] boff = {sidx[11:0], bi[8:0]};                 // byte offset in the file being loaded
    localparam [71:0] CFGL = "TN20K.CFG";

    task CMD(input [3:0] c, input [31:0] a, input [7:0] nx);
        begin go <= 1'b1; cmd <= c; arg <= a; cw <= 2; st <= nx; end
    endtask
    task PSTR(input [3:0] id, input [7:0] nx);                    // print string id
        begin pk <= 0; pid <= id; pidx <= 0; pret <= nx; st <= S_PR; end
    endtask
    task PHEX(input [31:0] v, input [3:0] n, input [7:0] nx);     // print n hex digits of v
        begin pk <= 1; hv <= v; hn <= n; pret <= nx; st <= S_PR; end
    endtask
    task PNAME(input [7:0] nx);                                   // print the name RAM (r_nlen chars)
        begin ni <= 0; pret <= nx; st <= S_PN0; end
    endtask
    task TXB(input [7:0] c, input [7:0] nx);                      // send one byte
        begin pc <= c; pret <= nx; st <= S_TX; end
    endtask
    task ERR(input [3:0] c);
        begin cur_err <= c; st <= S_ERR; end
    endtask
    task NAMEW(input [5:0] i, input [7:0] d);
        begin cna <= i; cnwd <= d; cnwe <= 1'b1; end
    endtask
    task NEED(input [2:0] n, input [7:0] nx);                     // receive n little-endian bytes into rxw
        begin rxn <= n; rxi <= 0; rxw <= 0; rnext <= nx; st <= S_RXN; end
    endtask

    always @(posedge clk) begin
        go <= 1'b0; cbwe <= 1'b0; cnwe <= 1'b0; f_tx_valid <= 1'b0; d2_up_go <= 1'b0; hd_up_go <= 1'b0;
        hd_dn_go <= 1'b0; wr_ack <= 1'b0;
        if (ackcool != 0) ackcool <= ackcool - 1'b1;
        fs_prev <= f_start;
        if (f_start && !fs_prev) start_pend <= 1'b1;
        if (reset) begin
            st <= S_RST; cw <= 0; f_active <= 0; d2_own <= 0; hd_own <= 0; ready <= 0; bfail <= 0; hd_valid <= 0;
            ackcool <= 0; rw <= 0; is_new <= 0; start_pend <= 0; fs_prev <= 0; up_drive <= 0; up_last <= 0; up_addr <= 0; up_data <= 0;
        end else if (cw != 0) cw <= cw - 1'b1;
        else if (busy) ;
        else case (st)
            // ------------------------------------------------------------ boot
            S_RST:   begin if (err) begin bfail <= 1; st <= S_FAIL; end else CMD(CMD_MOUNT, 0, S_BOOT); end
            S_BOOT:  begin if (err) begin bfail <= 1; st <= S_FAIL; end else begin slot <= 0; st <= S_B1; end end
            S_B1:    begin
                         if (slot == 4) begin ready <= 1; st <= S_CMD; end
                         else begin gret <= S_B2; st <= S_GS0; end
                     end
            S_B2:    begin                                           // gok: the slot's file is in r_*
                         if (gok && r_size == (slot[1] ? HD_BYTES : D2_BYTES)) begin mslot <= slot; lret <= S_B3; st <= S_LD0; end
                         else begin slot <= slot + 1'b1; st <= S_B1; end
                     end
            S_B3:    begin slot <= slot + 1'b1; st <= S_B1; end
            S_FAIL:  begin                                           // no usable card: still answer write-back and sessions
                         if (wr_req && ackcool == 0) begin wr_ack <= 1; ackcool <= 8; end
                         if (!f_active && start_pend) begin f_active <= 1; start_pend <= 0; PSTR(0, S_FAIL); end
                         else if (f_active && f_rx_valid) ERR(ecode == 0 ? X_CMD : ecode);
                     end

            // ------------------------------------------------------------ command loop
            S_CMD:   begin
                         if (wr_req && ackcool == 0) begin bi <= 0; st <= S_W0; end
                         else if (!f_active && start_pend) begin f_active <= 1; start_pend <= 0; PSTR(0, S_CMD); end
                         else if (f_active && f_rx_valid) begin
                             case (f_rx_byte)
                                 "L": begin idx <= 0; st <= S_L0; end
                                 "S": begin slot <= 0; st <= S_SL0; end
                                 "P": NEED(1, S_P0);
                                 "G": NEED(2, S_G0);
                                 "D": NEED(2, S_D0);
                                 "R": NEED(2, S_R0);
                                 "M": NEED(3, S_M0);
                                 "Q", 8'h02: begin f_active <= 0; PSTR(3, S_CMD); end
                                 default: ERR(X_CMD);
                             endcase
                         end
                     end
            S_OK:    PSTR(1, S_CMD);
            S_ERR:   PSTR(4, S_ERR1);                                // "ERR " <hex> CRLF
            S_ERR1:  PHEX({28'b0, cur_err}, 1, S_ERR2);
            S_ERR2:  PSTR(5, bfail ? S_FAIL : S_CMD);

            // ------------------------------------------------------------ print engine
            S_PR:    if (f_tx_ready) begin
                         if (!pk) begin
                             if (msg(pid, pidx) == 0) st <= pret;
                             else begin f_tx_valid <= 1; f_tx_byte <= msg(pid, pidx); pidx <= pidx + 1'b1; end
                         end else begin
                             if (hn == 0) st <= pret;
                             else begin f_tx_valid <= 1; f_tx_byte <= hexc(hv[4*(hn-1) +: 4]); hn <= hn - 1'b1; end
                         end
                     end
            S_PN0:   begin if (ni == r_nlen) st <= pret; else begin cna <= ni[5:0]; st <= S_PN1; end end
            S_PN1:   if (f_tx_ready) begin f_tx_valid <= 1; f_tx_byte <= cnrd; ni <= ni + 1'b1; st <= S_PN0; end
            S_TX:    if (f_tx_ready) begin f_tx_valid <= 1; f_tx_byte <= pc; st <= pret; end

            // ------------------------------------------------------------ receive n bytes / a name
            S_RXN:   if (f_rx_valid) begin
                         rxw[8*rxi +: 8] <= f_rx_byte; rxi <= rxi + 1'b1;
                         if (rxi + 1'b1 == rxn) st <= rnext;
                     end
            S_RXNAME: if (f_rx_valid) begin
                         NAMEW(ri[5:0], f_rx_byte); ri <= ri + 1'b1;
                         if (ri + 1'b1 == nl) st <= rnext;
                     end

            // ------------------------------------------------------------ slot lookup (shared)
            // "TN20K   CFG" -> its sector -> the slot's 11 bytes -> short-name lookup.  gok: found, r_* valid
            S_GS0:   begin k <= 0; st <= S_GS1; end
            S_GS1:   begin NAMEW(k, CFGN[8*(10-k) +: 8]); k <= k + 1'b1; if (k == 10) st <= S_GS2; end
            S_GS2:   CMD(CMD_SFN, 0, S_GS3);
            S_GS3:   if (!found) begin gok <= 0; st <= gret; end else CMD(CMD_RD, file_lba, S_GS4);
            S_GS4:   begin k <= 0; cret <= S_GS5; st <= S_CP0; end
            S_GS5:   if (fb == 0) begin gok <= 0; st <= gret; end else CMD(CMD_SFN, 0, S_GS6);
            S_GS6:   begin gok <= found; st <= gret; end
            // buffer bytes slot*11 .. +10 -> name RAM[0..10]; fb = the first one
            S_CP0:   begin cba <= slot[1:0] * 4'd11 + {5'b0, k}; rw <= 0; st <= S_CP1; end
            S_CP1:   begin
                         if (rw != 2) rw <= rw + 1'b1;
                         else begin
                             NAMEW(k, brd); if (k == 0) fb <= brd;
                             if (k == 10) st <= cret; else begin k <= k + 1'b1; st <= S_CP0; end
                         end
                     end

            // ------------------------------------------------------------ load r_* into slot `mslot`'s store
            S_LD0:   begin
                         nsec <= r_size >> 9; sidx <= 0;
                         if (mslot == 2) begin hd_lba <= file_lba; hd_valid <= 1; end
                         hd_own <= mslot[1]; d2_own <= !mslot[1]; up_drive <= mslot[0];
                         dos_order <= !mslot[1] && (r_sfn[23:0] != "PO ");
                         st <= S_LD1;
                     end
            S_LD1:   CMD(CMD_RD, file_lba + sidx, S_LD2);
            S_LD2:   begin bi <= 0; st <= S_LD3; end
            S_LD3:   begin cba <= bi[8:0]; rw <= 0; st <= S_LD4; end
            S_LD4:   begin
                         if (rw != 2) rw <= rw + 1'b1;
                         else begin
                             up_data <= brd; up_addr <= dos_order ? {3'b0, boff[17:12], d2_phys(boff[11:8]), boff[7:0]} : boff; up_last <= (sidx + 1 == nsec) && (bi == 511);
                             st <= S_LD5;
                         end
                     end
            S_LD5:   if (!ubsy) begin if (hd_own) hd_up_go <= 1; else d2_up_go <= 1; st <= S_LD6; end   // dropped pushes are resent
            S_LD6:   st <= S_LD7;
            S_LD7:   begin
                         if (udone) begin
                             if (bi == 511) begin
                                 sidx <= sidx + 1'b1;
                                 if (sidx + 1 == nsec) begin hd_own <= 0; d2_own <= 0; st <= lret; end else st <= S_LD1;
                             end else begin bi <= bi + 1'b1; st <= S_LD3; end
                         end else st <= S_LD5;
                     end

            // ------------------------------------------------------------ 'L': list
            S_L0:    CMD(CMD_IDX, {16'b0, idx}, S_L1);
            S_L1:    if (!found) PSTR(1, S_CMD); else PSTR(6, S_L2);
            S_L2:    PHEX({16'b0, idx}, 2, S_L3);
            S_L3:    PSTR(8, S_L4);
            S_L4:    PHEX(r_size, 8, S_L5);
            S_L5:    PSTR(8, S_L6);
            S_L6:    PNAME(S_L7);
            S_L7:    PSTR(5, S_L8);
            S_L8:    begin idx <= idx + 1'b1; st <= S_L0; end

            // ------------------------------------------------------------ 'S': what is mounted
            S_SL0:   begin if (slot == 4) PSTR(1, S_CMD); else begin gret <= S_SL1; st <= S_GS0; end end
            S_SL1:   PSTR(7, S_SL2);
            S_SL2:   PHEX({29'b0, slot}, 1, S_SL3);
            S_SL3:   PSTR(8, S_SL4);
            S_SL4:   begin if (gok) PNAME(S_SL5); else PSTR(9, S_SL5); end
            S_SL5:   PSTR(5, S_SL6);
            S_SL6:   begin slot <= slot + 1'b1; st <= S_SL0; end

            // ------------------------------------------------------------ 'P': put
            S_P0:    begin
                         nl <= rxw[6:0]; ri <= 0; nlr <= rxw[6:0];
                         if (rxw[7:0] == 0 || rxw[7:0] > 63) ERR(X_CMD); else begin rnext <= S_P1; st <= S_RXNAME; end
                     end
            S_P1:    NEED(4, S_P2);
            S_P2:    begin psize <= rxw; if (rxw == 0) ERR(X_SIZE); else CMD(CMD_ALLOC, rxw, S_P3); end
            S_P3:    begin
                         if (err) ERR(ecode);
                         else begin sidx <= 0; nsec <= (psize + 32'd511) >> 9; PSTR(2, S_P4); end
                     end
            S_P4:    begin                                           // one sector: bcnt = the bytes this chunk holds
                         bcnt <= (psize - (sidx << 9) >= 512) ? 10'd512 : (psize - (sidx << 9));
                         bi <= 0; st <= S_P5;
                     end
            S_P5:    begin
                         if (bi == 512) st <= S_P6;
                         else if (bi >= bcnt) begin cba <= bi[8:0]; cbwd <= 8'h00; cbwe <= 1; bi <= bi + 1'b1; end    // zero the tail
                         else if (f_rx_valid) begin cba <= bi[8:0]; cbwd <= f_rx_byte; cbwe <= 1; bi <= bi + 1'b1; end
                     end
            S_P6:    CMD(CMD_WR, file_lba + sidx, S_P7);
            S_P7:    begin
                         if (err) ERR(ecode);
                         else begin
                             sidx <= sidx + 1'b1;
                             TXB(8'h06, (sidx + 1 == nsec) ? S_P8 : S_P4);     // ack the chunk; after the last one, the entry
                         end
                     end
            S_P8:    CMD(CMD_ADD, 0, S_P9);
            S_P9:    begin if (err) ERR(ecode); else PSTR(1, S_CMD); end

            // ------------------------------------------------------------ 'G': get
            S_G0:    begin idx <= rxw[15:0]; CMD(CMD_IDX, {16'b0, rxw[15:0]}, S_G1); end
            S_G1:    if (!found) ERR(X_NOFILE); else PSTR(10, S_G2);
            S_G2:    PHEX(r_size, 8, S_G3);
            S_G3:    PSTR(5, S_G4);
            S_G4:    begin psize <= r_size; sidx <= 0; nsec <= (r_size + 32'd511) >> 9; st <= S_G5; end
            S_G5:    begin if (sidx == nsec) PSTR(1, S_CMD); else CMD(CMD_RD, file_lba + sidx, S_G6); end
            S_G6:    begin bcnt <= (psize - (sidx << 9) >= 512) ? 10'd512 : (psize - (sidx << 9)); bi <= 0; st <= S_G7; end
            S_G7:    begin if (bi == bcnt) begin sidx <= sidx + 1'b1; st <= S_G5; end else begin cba <= bi[8:0]; rw <= 0; st <= S_G8; end end
            S_G8:    begin
                         if (rw != 2) rw <= rw + 1'b1;
                         else if (f_tx_ready) begin f_tx_valid <= 1; f_tx_byte <= brd; bi <= bi + 1'b1; st <= S_G7; end
                     end

            // ------------------------------------------------------------ 'D': delete (not while mounted)
            S_D0:    begin idx <= rxw[15:0]; CMD(CMD_IDX, {16'b0, rxw[15:0]}, S_D1); end
            S_D1:    begin if (!found) ERR(X_NOFILE); else begin msfn <= r_sfn; slot <= 0; st <= S_D2; end end
            S_D2:    begin if (slot == 4) CMD(CMD_IDX, {16'b0, idx}, S_D4); else begin gret <= S_D3; st <= S_GS0; end end
            S_D3:    begin if (gok && r_sfn == msfn) ERR(X_MOUNTED); else begin slot <= slot + 1'b1; st <= S_D2; end end
            S_D4:    CMD(CMD_DEL, 0, S_R9);                          // (S_R9: report the result)

            // ------------------------------------------------------------ 'R': rename (not while mounted)
            S_R0:    begin idx <= rxw[15:0]; CMD(CMD_IDX, {16'b0, rxw[15:0]}, S_R1); end
            S_R1:    begin if (!found) ERR(X_NOFILE); else begin msfn <= r_sfn; slot <= 0; st <= S_R2; end end
            S_R2:    begin if (slot == 4) CMD(CMD_IDX, {16'b0, idx}, S_R4); else begin gret <= S_R3; st <= S_GS0; end end
            S_R3:    begin if (gok && r_sfn == msfn) ERR(X_MOUNTED); else begin slot <= slot + 1'b1; st <= S_R2; end end
            S_R4:    PSTR(2, S_R5);                                  // the old entry is located; ready for the new name
            S_R5:    NEED(1, S_R6);
            S_R6:    begin
                         nl <= rxw[6:0]; ri <= 0; nlr <= rxw[6:0];
                         if (rxw[7:0] == 0 || rxw[7:0] > 63) ERR(X_CMD); else begin rnext <= S_R7; st <= S_RXNAME; end
                     end
            S_R7:    CMD(CMD_ADD, 0, S_R8);                          // same cluster and size, new name
            S_R8:    begin if (err) ERR(ecode); else CMD(CMD_REMOVE, 0, S_R9); end
            S_R9:    begin if (err) ERR(ecode); else PSTR(1, S_CMD); end

            // ------------------------------------------------------------ 'M': mount a listed file onto a slot
            S_M0:    begin
                         mslot <= rxw[2:0]; idx <= rxw[23:8];
                         if (rxw[7:0] > 3) ERR(X_CMD); else CMD(CMD_IDX, {16'b0, rxw[23:8]}, S_M1);
                     end
            S_M1:    begin
                         if (!found) ERR(X_NOFILE);
                         else if (r_size != (mslot[1] ? HD_BYTES : D2_BYTES)) ERR(X_SIZE);
                         else begin msfn <= r_sfn; lret <= S_M2; st <= S_LD0; end
                     end
            S_M2:    begin slot <= mslot; cret <= S_M3; st <= S_C0; end       // record it in TN20K.CFG
            S_M3:    begin if (err) ERR(ecode); else PSTR(1, S_CMD); end

            // ------------------------------------------------------------ TN20K.CFG: put msfn into `slot`
            S_C0:    begin k <= 0; st <= S_C1; end
            S_C1:    begin NAMEW(k, CFGN[8*(10-k) +: 8]); k <= k + 1'b1; if (k == 10) st <= S_C2; end
            S_C2:    CMD(CMD_SFN, 0, S_C3);
            S_C3:    begin
                         if (err) st <= cret;
                         else if (found) begin is_new <= 0; CMD(CMD_RD, file_lba, S_C5); end
                         else begin is_new <= 1; CMD(CMD_ALLOC, 512, S_C4); end
                     end
            S_C4:    begin bi <= 0; st <= S_C6; end                  // a new file: zero the buffer first
            S_C6:    begin cba <= bi[8:0]; cbwd <= 8'h00; cbwe <= 1; bi <= bi + 1'b1; if (bi == 511) st <= S_C5; end
            S_C5:    begin k <= 0; st <= S_C7; end
            S_C7:    begin                                           // patch the slot's 11 bytes
                         cba <= slot[1:0] * 4'd11 + {5'b0, k}; cbwd <= msfn[87 - 8*k -: 8]; cbwe <= 1;
                         k <= k + 1'b1; if (k == 10) st <= S_C8;
                     end
            S_C8:    CMD(CMD_WR, file_lba, S_CF2);
            S_CF2:   begin
                         if (err || !is_new) st <= cret;
                         else begin k <= 0; nlr <= 9; st <= S_CF3; end   // a new file: now its directory entry
                     end
            S_CF3:   begin NAMEW(k, CFGL[8*(8-k) +: 8]); k <= k + 1'b1; if (k == 8) st <= S_CF4; end
            S_CF4:   CMD(CMD_ADD, 0, S_CF5);
            S_CF5:   st <= cret;

            // ------------------------------------------------------------ ProDOS HD write-back
            S_W0:    begin
                         if (!hd_valid) begin wr_ack <= 1; ackcool <= 8; st <= S_CMD; end
                         else begin bi <= 0; st <= S_W1; end
                     end
            S_W1:    begin hd_dn_go <= 1; wb_n <= 0; st <= S_W2; end
            S_W2:    begin
                         if (hd_dn_valid) begin
                             cba <= bi[8:0]; cbwd <= hd_dn_data; cbwe <= 1;
                             if (bi == 511) begin CMD(CMD_WR, hd_lba + wr_blk, S_W3); end
                             else begin bi <= bi + 1'b1; st <= S_W1; end
                         end else begin wb_n <= wb_n + 1'b1; if (&wb_n) st <= S_W1; end     // the store dropped the request
                     end
            S_W3:    begin wr_ack <= 1; ackcool <= 8; st <= S_CMD; end
            default: st <= S_CMD;
        endcase
    end

    // ---- boot status line "SD S:x E:y R:zz", every 2^RPT_BITS clocks, 8 times ----
    // x: '.' mounting, 'K' ready, 'F' failed;  y: fat32 error code;  zz: last SD R1 byte
    reg [RPT_BITS-1:0] rc = 0;
    reg [3:0]  rn = 0;
    reg [4:0]  ci;
    reg        rsend = 0;
    assign rpt_busy = rsend;
    reg [7:0] rch;
    always @(*) case (ci)
        0: rch = "S"; 1: rch = "D"; 2: rch = " "; 3: rch = "S"; 4: rch = ":";
        5: rch = bfail ? "F" : ready ? "K" : ".";
        6: rch = " "; 7: rch = "E"; 8: rch = ":"; 9: rch = hexc(ecode);
        10: rch = " "; 11: rch = "R"; 12: rch = ":"; 13: rch = hexc(lrx[7:4]); 14: rch = hexc(lrx[3:0]);
        15: rch = 8'h0D; default: rch = 8'h0A;
    endcase
    wire tx_busy;
    wire tx_go = rsend && !tx_busy && ci != 5'd17;
    uart_tx u_rpt (.clk(clk), .reset(reset), .data(rch), .start(tx_go), .tx(rpt_tx), .busy(tx_busy));
    always @(posedge clk) begin
        if (reset) begin rc <= 0; rn <= 0; rsend <= 0; ci <= 0; end
        else if (!rsend) begin
            rc <= rc + 1'b1; ci <= 0;
            if (&rc && rn != 8) begin rn <= rn + 1'b1; rsend <= 1'b1; end
        end else if (tx_go) ci <= ci + 1'b1;
        else if (!tx_busy) rsend <= 1'b0;
    end
endmodule

`default_nettype wire
