// ============================================================================
//  fat32.v -- FAT32 file layer for the TF card, on sd_blk (one 512 B buffer).
//
//  Pulse `go` with `cmd` (and `arg`) while !busy; wait for !busy; `err`/`ecode`
//  report a failure.  The sector buffer (cba/cbwe/cbwd -> brd, 2 clock read
//  latency) and the name RAM (cna/cnwe/cnwd -> cnrd, asynchronous read) belong
//  to the client only while !busy.
//
//   CMD_MOUNT   read MBR/VBR, parse the BPB (root cluster must be 2)
//   CMD_IDX     arg = n: the n-th file of the root directory -> name RAM
//               (long name if there is one), r_nlen, r_sfn, r_cluster, r_size,
//               `found`.  Directories, volume labels and TN20K.CFG are skipped.
//   CMD_SFN     like CMD_IDX but matches the 11-byte short name in name RAM[0..10]
//   CMD_ALLOC   arg = file size in bytes: reserve a contiguous cluster run and
//               chain it in both FATs -> r_cluster, r_size (not in the directory yet)
//   CMD_ADD     add a directory entry for name RAM[0..nlen-1] with r_cluster/r_size
//               (long-name entries + a ~N short name, or only a short name when
//               the name already is a valid upper-case 8.3 one) -> r_sfn
//   CMD_REMOVE  mark the directory entries of the last CMD_IDX/CMD_SFN match deleted
//   CMD_DEL     CMD_REMOVE, then free that file's cluster chain
//   CMD_RD/WR   raw sector arg (lba) <-> buffer
//   file_lba    LBA of the first data sector of r_cluster
//
//  ponytail: root directory only (its first cluster), files are contiguous
//  (CMD_ALLOC makes them so; a fragmented file is read as if it were not),
//  ASCII names up to 64 chars, SDHC only, FSInfo is not updated.
// ============================================================================
`default_nettype none

module fat32 #(
    parameter PWR_BITS = 20
) (
    input  wire        clk,
    input  wire        reset,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,

    input  wire        go,
    input  wire [3:0]  cmd,
    input  wire [31:0] arg,
    output reg         busy,
    output reg         err,
    output reg  [3:0]  ecode,
    output reg         found,
    output reg  [31:0] r_cluster,
    output reg  [31:0] r_size,
    output reg  [87:0] r_sfn,
    output reg  [6:0]  r_nlen,
    output wire [31:0] file_lba,
    output wire [31:0] fat1_lba,        // first sector of FAT 1
    output wire [7:0]  lrx,
    output wire [2:0]  bstage,
    output wire        berr,

    input  wire [6:0]  nlen,           // name length for CMD_ADD
    input  wire [8:0]  cba,
    input  wire        cbwe,
    input  wire [7:0]  cbwd,
    output wire [7:0]  brd,
    input  wire [5:0]  cna,
    input  wire        cnwe,
    input  wire [7:0]  cnwd,
    output wire [7:0]  cnrd
);
    localparam [3:0] CMD_MOUNT = 1, CMD_IDX = 2, CMD_SFN = 3, CMD_ALLOC = 4, CMD_ADD = 5,
                     CMD_REMOVE = 6, CMD_DEL = 7, CMD_RD = 8, CMD_WR = 9;
    localparam [3:0] E_SD = 1, E_FMT = 2, E_FULL = 3, E_EXISTS = 4, E_DIR = 5;

    // ---- block layer ----
    reg         rd, wr;
    reg  [31:0] lba;
    wire        bbusy;
    reg  [8:0]  fba;
    reg         fbwe;
    reg  [7:0]  fbwd;
    sd_blk #(.PWR_BITS(PWR_BITS)) u_blk (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n), .rd(rd), .wr(wr), .lba(lba), .busy(bbusy), .err(berr),
        .estage(bstage), .lrx(lrx),
        .ba(busy ? fba : cba), .bwe(busy ? fbwe : cbwe), .bwd(busy ? fbwd : cbwd), .brd(brd));

    // ---- name RAM: the client's port, the core's write port, and async read ports ----
    reg [7:0] nm [0:63];
    reg [5:0] nia;
    reg       niwe;
    reg [7:0] niwd;
    reg [6:0] ci;                      // name / scan index (read port 1)
    reg [6:0] widx;                    // entry-writer index (read port 2), set from registers below
    wire [7:0] nch = nm[ci[5:0]];
    wire [7:0] wch = nm[widx[5:0]];
    assign cnrd = nm[cna];
    always @(posedge clk) if (busy ? niwe : cnwe) nm[busy ? nia : cna] <= busy ? niwd : cnwd;

    // ---- geometry ----
    reg [31:0] part, fat1, fat2, fatsz, data_lba;
    reg [15:0] rsv;
    reg [7:0]  spc, nfat;
    reg [2:0]  spcl;                   // log2(spc)
    reg [11:0] dtotal;                 // entries in the root cluster
    assign fat1_lba = fat1;
    assign file_lba = data_lba + ((r_cluster - 32'd2) << spcl);

    // ---- state ----
    reg [6:0]  st;
    reg [6:0]  rets, fret;             // return states of the scan / FAT flush "subroutines"
    reg        opw, opdly;
    reg        gbusy;
    reg [8:0]  goff;
    reg [2:0]  gn, gi;
    reg [1:0]  gph;
    reg [31:0] acc;
    reg [3:0]  cur;
    reg [3:0]  k;
    reg        dirty;
    // directory scan
    reg [11:0] dpos;                   // entry index in the root cluster
    reg        ldv;                    // buffer holds root-directory sector ldsec
    reg [7:0]  ldsec;
    reg [31:0] want, seen;
    reg [87:0] swant, sfn, nsfn;
    reg [11:0] set_pos, sfn_pos, m_set, m_sfn;
    reg [6:0]  lfn_len;
    reg [5:0]  lseq;
    reg        have_lfn, nul_seen, isdir, hit;
    reg [7:0]  b0, attr;
    reg [2:0]  purp;
    localparam [2:0] P_IDX = 0, P_SFN = 1, P_UNIQ = 2, P_RUN = 3;
    reg [2:0]  ek;
    localparam [2:0] K_END = 0, K_FREE = 1, K_USED = 2, K_FILE = 3, K_SKIP = 4;
    reg [15:0] chi;
    reg [31:0] t_cluster, t_size;
    reg [11:0] run_pos, run_len, need;
    // ADD
    reg [6:0]  nlfn;
    reg        exact, bad;
    reg [3:0]  tail, bl, el, ndots;
    reg [6:0]  dotp;
    reg [7:0]  csum;
    reg [11:0] wpos;
    reg [5:0]  wj;
    reg [4:0]  wi;
    reg [6:0]  bn;
    // FAT work
    reg [31:0] nclus, c_cur, c_run, c_start, fs, fnext;
    reg [6:0]  ei;
    reg        fsv;

    function [2:0] log2(input [7:0] v);
        case (v) 1: log2 = 0; 2: log2 = 1; 4: log2 = 2; 8: log2 = 3; 16: log2 = 4; 32: log2 = 5; 64: log2 = 6; default: log2 = 7; endcase
    endfunction
    function is_up(input [7:0] c);          // legal in a short name, upper case
        is_up = (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-" || c == "$" || c == "~" ||
                c == "!" || c == "#" || c == "%" || c == "&" || c == "'" || c == "(" || c == ")" || c == "@" || c == "^";
    endfunction
    function [7:0] upc(input [7:0] c);      // upper-case; anything illegal becomes '_'
        upc = (c >= "a" && c <= "z") ? c - 8'd32 : is_up(c) ? c : "_";
    endfunction
    // the offset in an LFN entry of its n-th character (low byte; the high byte follows)
    function [4:0] lfn_off(input [3:0] n);
        case (n) 0: lfn_off = 1; 1: lfn_off = 3; 2: lfn_off = 5; 3: lfn_off = 7; 4: lfn_off = 9;
                 5: lfn_off = 14; 6: lfn_off = 16; 7: lfn_off = 18; 8: lfn_off = 20; 9: lfn_off = 22; 10: lfn_off = 24;
                 11: lfn_off = 28; default: lfn_off = 30; endcase
    endfunction
    // which of the 13 characters byte i of an LFN entry belongs to (0..12), and 13 = not a character byte
    function [3:0] lfn_k(input [4:0] i);
        case (i)
            1,2: lfn_k = 0; 3,4: lfn_k = 1; 5,6: lfn_k = 2; 7,8: lfn_k = 3; 9,10: lfn_k = 4;
            14,15: lfn_k = 5; 16,17: lfn_k = 6; 18,19: lfn_k = 7; 20,21: lfn_k = 8; 22,23: lfn_k = 9; 24,25: lfn_k = 10;
            28,29: lfn_k = 11; 30,31: lfn_k = 12;
            default: lfn_k = 13;
        endcase
    endfunction
    wire [7:0] lseqm1 = {2'b0, lseq} - 8'd1;
    wire [7:0] lp     = (lseqm1 << 3) + (lseqm1 << 2) + lseqm1 + {4'b0, k};     // name index of LFN char k of this entry
    wire [6:0] wseq   = nlfn - wj;                     // LFN sequence number of entry wj (nlfn..1)
    wire [6:0] wseqm1 = wseq - 7'd1;
    wire [6:0] wcidx  = (wseqm1 << 3) + (wseqm1 << 2) + wseqm1 + {3'b0, lfn_k(wi)};   // character index
    wire [7:0] wchar  = (wcidx < nlen) ? wch : (wcidx == nlen) ? 8'h00 : 8'hFF;
    always @(*) widx = wcidx;

    localparam [6:0]
        S_INIT = 0,  S_IDLE = 1,  S_DN = 2,
        S_M1 = 3,  S_M2 = 4,  S_M3 = 5,  S_M4 = 6,  S_M5 = 7,  S_M6 = 8,  S_M7 = 9,  S_M8 = 10, S_M9 = 11, S_M10 = 12, S_M11 = 13,
        S_E0 = 14, S_E1 = 15, S_E2 = 16, S_E3 = 17, S_E4 = 18, S_E5 = 19, S_E6 = 20, S_E7 = 21, S_E8 = 22, S_E9 = 23, S_E10 = 24,
        S_E11 = 25, S_E12 = 26, S_EN = 27, S_EH = 28,
        S_N0 = 29, S_N1 = 30,
        S_U0 = 31, S_U1 = 32,
        S_A0 = 33, S_A1 = 34, S_A2 = 35, S_A3 = 36, S_A4 = 37, S_A5 = 38, S_A6 = 39, S_A7 = 40,
        S_FL0 = 41, S_FL1 = 42, S_FL2 = 43,
        S_D0 = 44, S_D1 = 45, S_D2 = 46, S_D3 = 47, S_D4 = 48, S_D5 = 49, S_D6 = 50, S_D7 = 51, S_D8 = 52, S_D9 = 53,
        S_D10 = 54, S_D11 = 55, S_D12 = 56, S_D13 = 57, S_D14 = 58, S_D15 = 59, S_D16 = 60, S_D17 = 61,
        S_R0 = 62, S_R1 = 63, S_R2 = 64, S_R3 = 65,
        S_F0 = 66, S_F1 = 67, S_F2 = 68, S_F3 = 69, S_F4 = 70, S_F5 = 71;

    // ---- micro-ops ----
    task RDS(input [31:0] l, input [6:0] nx);
        begin rd <= 1'b1; lba <= l; opw <= 1'b1; opdly <= 1'b1; ldv <= 1'b0; dirty <= 1'b0; st <= nx; end
    endtask
    task WRS(input [31:0] l, input [6:0] nx);
        begin wr <= 1'b1; lba <= l; opw <= 1'b1; opdly <= 1'b1; st <= nx; end
    endtask
    task GET(input [8:0] off, input [2:0] nb, input [6:0] nx);
        begin goff <= off; gn <= nb; gi <= 0; gph <= 0; acc <= 0; gbusy <= 1'b1; st <= nx; end
    endtask
    task BW(input [8:0] a, input [7:0] d);
        begin fba <= a; fbwd <= d; fbwe <= 1'b1; dirty <= 1'b1; end
    endtask
    task NW(input [5:0] a, input [7:0] d);
        begin nia <= a; niwd <= d; niwe <= 1'b1; end
    endtask
    task FAIL(input [3:0] c);
        begin err <= 1'b1; ecode <= c; busy <= 1'b0; st <= S_IDLE; opw <= 1'b0; gbusy <= 1'b0; end
    endtask
    task DONE; begin busy <= 1'b0; st <= S_IDLE; end endtask
    // read root-directory sector s into the buffer (skipped when it is already there)
    task RDD(input [7:0] s, input [6:0] nx);
        begin
            if (ldv && ldsec == s) st <= nx;
            else begin rd <= 1'b1; lba <= data_lba + s; opw <= 1'b1; opdly <= 1'b1; ldv <= 1'b1; ldsec <= s; dirty <= 1'b0; st <= nx; end
        end
    endtask
    task WRD(input [7:0] s, input [6:0] nx);
        begin wr <= 1'b1; lba <= data_lba + s; opw <= 1'b1; opdly <= 1'b1; dirty <= 1'b0; st <= nx; end
    endtask

    wire [31:0] fsec_c = c_cur >> 7;

    always @(posedge clk) begin
        rd <= 1'b0; wr <= 1'b0; fbwe <= 1'b0; niwe <= 1'b0;
        if (reset) begin
            st <= S_INIT; busy <= 1'b1; err <= 1'b0; ecode <= 0; opw <= 0; opdly <= 0; gbusy <= 0;
            ldv <= 0; found <= 0; fsv <= 0; dirty <= 0; cur <= 0;
        end else if (gbusy) begin
            case (gph)
                0: begin fba <= goff + gi; gph <= 2'd1; end
                1: gph <= 2'd2;
                default: begin
                    acc <= acc | ({24'd0, brd} << {gi[1:0], 3'b000});
                    gi <= gi + 1'b1;
                    if (gi + 1'b1 == gn) gbusy <= 1'b0; else gph <= 2'd0;
                end
            endcase
        end else if (opw) begin
            if (opdly) opdly <= 1'b0;
            else if (!bbusy) begin opw <= 1'b0; if (berr) FAIL(E_SD); end
        end else case (st)
            S_INIT: if (!bbusy) begin if (berr) FAIL(E_SD); else DONE; end
            S_IDLE: if (go) begin
                busy <= 1'b1; err <= 1'b0; ecode <= 0; found <= 0; cur <= cmd; hit <= 0; ldv <= 0;
                case (cmd)
                    CMD_MOUNT: RDS(0, S_M1);
                    CMD_IDX:   begin want <= arg; seen <= 0; purp <= P_IDX; dpos <= 0; have_lfn <= 0; st <= S_E0; end
                    CMD_SFN:   begin purp <= P_SFN; dpos <= 0; have_lfn <= 0; ci <= 0; st <= S_U0; end
                    CMD_ALLOC: begin
                        r_size <= arg;
                        nclus <= (arg == 0) ? 32'd1 : ((arg + ({24'd0, spc} << 9) - 32'd1) >> (spcl + 4'd9));
                        c_cur <= 3; c_run <= 0; fs <= 0; ei <= 3; fsv <= 0;
                        RDS(fat1, S_A0);
                    end
                    CMD_ADD:   begin ci <= 0; dotp <= 7'h7F; bad <= 0; ndots <= 0; st <= S_D0; end
                    CMD_REMOVE, CMD_DEL: begin wpos <= m_set; st <= S_R0; end
                    CMD_RD:    RDS(arg, S_DN);
                    CMD_WR:    WRS(arg, S_DN);
                    default:   DONE;
                endcase
            end
            S_DN: DONE;

            // ------------------------------------------------------------ mount
            S_M1: GET(9'h052, 1, S_M2);                              // "FAT32   " => this is the VBR
            S_M2: if (acc[7:0] == "F") begin part <= 0; st <= S_M4; end
                  else GET(9'h1C6, 4, S_M3);                         // MBR: first partition's start LBA
            S_M3: begin part <= acc; RDS(acc, S_M4); end
            S_M4: GET(9'h00B, 2, S_M5);
            S_M5: if (acc != 512) FAIL(E_FMT); else GET(9'h00D, 1, S_M6);
            S_M6: begin spc <= acc[7:0]; spcl <= log2(acc[7:0]); dtotal <= {acc[7:0], 4'b0}; GET(9'h00E, 2, S_M7); end
            S_M7: begin rsv <= acc[15:0]; GET(9'h010, 1, S_M8); end
            S_M8: begin nfat <= acc[7:0]; GET(9'h024, 4, S_M9); end
            S_M9: begin fatsz <= acc; GET(9'h02C, 4, S_M10); end
            S_M10: if (acc != 2 || (nfat != 1 && nfat != 2)) FAIL(E_FMT);
                   else begin fat1 <= part + rsv; fat2 <= part + rsv + fatsz; st <= S_M11; end
            S_M11: begin data_lba <= (nfat == 1) ? fat2 : fat2 + fatsz; DONE; end

            // ------------------------------------------------------------ directory entry engine
            // entry dpos of the root cluster -> ek (kind) + sfn/t_cluster/t_size, then S_EH
            S_E0: if (dpos == dtotal) begin ek <= K_END; st <= S_EH; end
                  else RDD(dpos[11:4], S_E1);
            S_E1: GET({dpos[3:0], 5'b0}, 1, S_E2);
            S_E2: begin
                b0 <= acc[7:0];
                if (acc[7:0] == 8'h00)      begin ek <= K_END;  st <= S_EH; end
                else if (acc[7:0] == 8'hE5) begin ek <= K_FREE; st <= S_EH; end
                else if (purp == P_RUN)     begin ek <= K_USED; st <= S_EH; end
                else GET({dpos[3:0], 5'b0} + 9'd11, 1, S_E3);
            end
            S_E3: begin
                attr <= acc[7:0];
                if (acc[7:0] == 8'h0F) begin                              // long-name entry
                    if (b0[6]) begin
                        have_lfn <= 1; set_pos <= dpos; nul_seen <= 0;
                        lfn_len <= (b0[4:0] >= 5) ? 7'd64 : ({2'b0, b0[4:0]} << 3) + ({2'b0, b0[4:0]} << 2) + {2'b0, b0[4:0]};
                    end
                    lseq <= b0[5:0] & 6'h1F; k <= 0;
                    if (purp <= P_SFN) st <= S_E4; else st <= S_EN;
                end else if (acc[3]) begin ek <= K_SKIP; st <= S_EH; end   // volume label
                else begin isdir <= acc[4]; GET({dpos[3:0], 5'b0}, 4, S_E6); end
            end
            // one LFN character per pass: S_E4 reads it, S_E5 stores it
            S_E4: GET({4'b0, lfn_off(k)}  + {dpos[3:0], 5'b0}, 2, S_E5);
            S_E5: begin
                if (acc[15:0] == 16'h0000) begin
                    if (!nul_seen) begin nul_seen <= 1; lfn_len <= (lp < 64) ? lp[6:0] : 7'd64; end
                end else if (acc[15:0] != 16'hFFFF) begin
                    if (lp < 64) NW(lp[5:0], (acc[15:8] != 0) ? 8'h3F : acc[7:0]);
                end
                if (k == 12) st <= S_EN; else begin k <= k + 1'b1; st <= S_E4; end
            end
            // short-name entry: 11 name bytes, cluster, size
            S_E6: begin sfn[87:56] <= {acc[7:0], acc[15:8], acc[23:16], acc[31:24]}; GET({dpos[3:0], 5'b0} + 9'd4, 4, S_E7); end
            S_E7: begin sfn[55:24] <= {acc[7:0], acc[15:8], acc[23:16], acc[31:24]}; GET({dpos[3:0], 5'b0} + 9'd8, 3, S_E8); end
            S_E8: begin sfn[23:0] <= {acc[7:0], acc[15:8], acc[23:16]}; GET({dpos[3:0], 5'b0} + 9'd20, 2, S_E9); end
            S_E9: begin chi <= acc[15:0]; GET({dpos[3:0], 5'b0} + 9'd26, 2, S_E10); end
            S_E10: begin t_cluster <= {chi, acc[15:0]}; GET({dpos[3:0], 5'b0} + 9'd28, 4, S_E11); end
            S_E11: begin t_size <= acc; sfn_pos <= dpos; if (!have_lfn) set_pos <= dpos; ek <= K_FILE; st <= S_EH; end
            S_EN: begin dpos <= dpos + 1'b1; st <= S_E0; end

            // what to do with the entry
            S_EH: begin
                if (ek == K_FILE) begin
                    case (purp)
                        P_IDX, P_SFN: begin
                            if ((purp == P_IDX) ? (!isdir && sfn != "TN20K   CFG" && seen == want) : (sfn == swant)) begin
                                r_cluster <= t_cluster; r_size <= t_size; r_sfn <= sfn; m_set <= set_pos; m_sfn <= dpos;
                                found <= 1;
                                if (have_lfn) begin r_nlen <= lfn_len; DONE; end
                                else begin ci <= 0; bn <= 0; st <= S_N0; end      // name RAM from the short name
                            end else begin
                                if (!isdir && sfn != "TN20K   CFG") seen <= seen + 1'b1;
                                have_lfn <= 0; st <= S_EN;
                            end
                        end
                        P_UNIQ: begin
                            if (sfn == swant) begin hit <= 1; st <= rets; end
                            else begin have_lfn <= 0; st <= S_EN; end
                        end
                        default: begin have_lfn <= 0; run_len <= 0; st <= S_EN; end
                    endcase
                end else begin
                    case (ek)
                        K_END: begin
                            if (purp == P_RUN) begin
                                // everything from here to the end of the cluster is free
                                if (run_len == 0) run_pos <= dpos;
                                if ((run_len + (dtotal - dpos)) >= need) hit <= 1;
                                st <= rets;
                            end else if (purp == P_UNIQ) st <= rets;
                            else DONE;                                  // CMD_IDX / CMD_SFN: no such file (found = 0)
                        end
                        K_FREE: begin
                            have_lfn <= 0;
                            if (purp == P_RUN) begin
                                if (run_len == 0) run_pos <= dpos;
                                run_len <= run_len + 1'b1;
                                if (run_len + 1'b1 == need) begin hit <= 1; st <= rets; end else st <= S_EN;
                            end else st <= S_EN;
                        end
                        default: begin have_lfn <= 0; run_len <= 0; st <= S_EN; end
                    endcase
                end
            end
            // (the scan's callers continue at `rets`; CMD_IDX/SFN finish here)
            S_N0: begin                                       // short name -> name RAM
                if (ci == 12) begin r_nlen <= bn; DONE; end
                else if (ci == 8) begin
                    if (sfn[23:16] != " ") begin NW(bn[5:0], "."); bn <= bn + 1'b1; end
                    ci <= ci + 1'b1;
                end else begin
                    if (sfn[87 - 8*((ci > 8) ? ci - 7'd1 : ci) -: 8] != " ") begin
                        NW(bn[5:0], sfn[87 - 8*((ci > 8) ? ci - 7'd1 : ci) -: 8]); bn <= bn + 1'b1;
                    end
                    ci <= ci + 1'b1;
                end
            end
            // CMD_SFN: copy the short name from name RAM[0..10] into swant, then scan
            S_U0: begin swant[87 - 8*ci[3:0] -: 8] <= nch; ci <= ci + 1'b1; if (ci == 10) st <= S_E0; end

            // ------------------------------------------------------------ FAT sector flush (subroutine)
            S_FL0: WRS(fat1 + fs, S_FL1);
            S_FL1: if (nfat == 2) WRS(fat2 + fs, S_FL2); else st <= S_FL2;
            S_FL2: begin dirty <= 0; st <= fret; end

            // ------------------------------------------------------------ alloc: find a contiguous free run
            // S_A0 / S_A1 scan the FAT: entry ei of sector fs is cluster c_cur
            S_A0: GET({ei, 2'b00}, 4, S_A1);
            S_A1: begin
                if (acc[27:0] == 0) begin
                    if (c_run == 0) c_start <= c_cur;
                    c_run <= c_run + 1'b1;
                    if (c_run + 1'b1 == nclus) begin c_cur <= c_cur - c_run; st <= S_A3; end   // c_cur = first cluster of the run
                    else st <= S_A2;
                end else begin c_run <= 0; st <= S_A2; end
            end
            S_A2: begin                                         // next entry / next FAT sector
                c_cur <= c_cur + 1'b1;
                if (ei == 7'd127) begin
                    fs <= fs + 1'b1; ei <= 0;
                    if (fs + 1'b1 == fatsz) FAIL(E_FULL);
                    else RDS(fat1 + fs + 1'b1, S_A0);
                end else begin ei <= ei + 1'b1; st <= S_A0; end
            end
            // the run is found: chain it.  c_start = first cluster, c_cur = c_start (set above), nclus long
            S_A3: begin c_cur <= c_start; fsv <= 0; c_run <= 0; st <= S_A4; end
            S_A4: begin                                         // c_run = clusters done
                if (c_run == nclus) begin
                    if (dirty) begin fret <= S_A7; st <= S_FL0; end else st <= S_A7;
                end else if (!fsv || fs != fsec_c) begin
                    if (fsv && dirty) begin fret <= S_A5; st <= S_FL0; end else st <= S_A5;
                end else begin k <= 0; st <= S_A6; end
            end
            S_A5: begin fs <= fsec_c; fsv <= 1; RDS(fat1 + fsec_c, S_A6); k <= 0; end
            S_A6: begin
                // little-endian value: EOC for the last cluster of the run, else cluster+1
                BW({c_cur[6:0], 2'b00} + {7'b0, k[1:0]},
                   (c_run + 1'b1 == nclus) ? ((k[1:0] == 3) ? 8'h0F : 8'hFF) : ((c_cur + 1'b1) >> {k[1:0], 3'b000}));
                k <= k + 1'b1;
                if (k == 3) begin c_cur <= c_cur + 1'b1; c_run <= c_run + 1'b1; st <= S_A4; end
            end
            S_A7: begin r_cluster <= c_start; DONE; end

            // ------------------------------------------------------------ add a directory entry
            // D0/D1: look at every name character: last '.', illegal characters
            S_D0: begin
                if (ci == nlen) st <= S_D2;
                else begin
                    if (nch == ".") begin dotp <= ci; ndots <= ndots + 1'b1; end
                    else if (!is_up(nch)) bad <= 1;
                    ci <= ci + 1'b1;
                end
            end
            // exact 8.3? 1..8 base chars, at most one dot, up to 3 extension chars
            S_D2: begin
                exact <= !bad && ndots <= 1 && nlen != 0 && ((dotp == 7'h7F) ? (nlen <= 8) : (dotp >= 1 && dotp <= 8 && (nlen - dotp - 7'd1) >= 1 && (nlen - dotp - 7'd1) <= 3));
                nlfn <= (nlen <= 13) ? 7'd1 : (nlen <= 26) ? 7'd2 : (nlen <= 39) ? 7'd3 : (nlen <= 52) ? 7'd4 : 7'd5;
                nsfn <= {11{8'h20}}; ci <= 0; bl <= 0; el <= 0; tail <= 1; st <= S_D3;
            end
            // build the short name from the characters
            S_D3: begin
                if (ci == nlen) st <= S_D4;
                else begin
                    if (ci < ((dotp == 7'h7F) ? nlen : dotp)) begin
                        if (nch != " " && nch != "." && bl < (exact ? 4'd8 : 4'd6)) begin
                            nsfn[87 - 8*bl -: 8] <= upc(nch); bl <= bl + 1'b1;
                        end
                    end else if (ci > dotp && el < 3) begin
                        if (nch != " ") begin nsfn[23 - 8*el[1:0] -: 8] <= upc(nch); el <= el + 1'b1; end
                    end
                    ci <= ci + 1'b1;
                end
            end
            S_D4: begin
                if (!exact) begin nsfn[87 - 8*bl -: 8] <= "~"; nsfn[79 - 8*bl -: 8] <= "0" + {4'b0, tail}; end
                if (exact) nlfn <= 0;
                st <= S_D8;
            end
            // is the short name taken?  (a hit stops the scan; the end of the directory returns here too)
            S_D5: begin
                if (hit) begin
                    if (exact || tail == 9) FAIL(E_EXISTS);
                    else begin tail <= tail + 1'b1; st <= S_D6; end
                end else begin
                    need <= {5'b0, nlfn} + 12'd1; run_len <= 0; purp <= P_RUN; dpos <= 0; hit <= 0; have_lfn <= 0; rets <= S_D7; st <= S_E0;
                end
            end
            S_D6: begin                                            // rewrite the ~N digit and retry
                nsfn[79 - 8*bl -: 8] <= "0" + {4'b0, tail}; st <= S_D8;
            end
            S_D8: begin swant <= nsfn; purp <= P_UNIQ; dpos <= 0; have_lfn <= 0; hit <= 0; rets <= S_D5; st <= S_E0; end
            S_D7: begin
                // directory cluster scanned: run_pos / hit say whether `need` free entries were found
                if (!hit) FAIL(E_DIR);
                else begin
                    csum <= 0; ci <= 0; st <= S_D9;
                end
            end
            S_D9: begin                                            // checksum of the short name
                csum <= {csum[0], csum[7:1]} + nsfn[87 - 8*ci[3:0] -: 8];
                ci <= ci + 1'b1;
                if (ci == 10) begin wj <= 0; wpos <= run_pos; st <= S_D10; end
            end
            // write entry wj (nlfn long-name entries, then the short-name entry), sector by sector
            S_D10: begin
                if ({4'b0, wj} > {5'b0, nlfn}) begin                // all written: flush
                    if (dirty) begin WRD(ldsec, S_D17); end else st <= S_D17;
                end else if (ldv && ldsec == wpos[11:4]) begin wi <= 0; st <= S_D12; end
                else if (dirty) begin WRD(ldsec, S_D11); end
                else st <= S_D11;
            end
            S_D11: RDD(wpos[11:4], S_D16);
            S_D16: begin wi <= 0; st <= S_D12; end
            S_D12: begin
                if (wj < nlfn) begin
                    case (wi)
                        0: BW({wpos[3:0], 5'b0}, {1'b0, (wj == 0), 1'b0, 5'b0} | {3'b0, wseq[4:0]});
                        11: BW({wpos[3:0], 5'b0} + 9'd11, 8'h0F);
                        13: BW({wpos[3:0], 5'b0} + 9'd13, csum);
                        default: begin
                            if (lfn_k(wi) != 13) BW({wpos[3:0], 5'b0} + {4'b0, wi}, ((wi <= 10) ? !wi[0] : wi[0]) ? ((wchar == 8'hFF) ? 8'hFF : 8'h00) : wchar);
                            else BW({wpos[3:0], 5'b0} + {4'b0, wi}, 8'h00);
                        end
                    endcase
                end else begin
                    if (wi < 11)          BW({wpos[3:0], 5'b0} + {4'b0, wi}, nsfn[87 - 8*wi[3:0] -: 8]);
                    else if (wi == 11)    BW({wpos[3:0], 5'b0} + 9'd11, 8'h20);
                    else if (wi == 20)    BW({wpos[3:0], 5'b0} + 9'd20, r_cluster[23:16]);
                    else if (wi == 21)    BW({wpos[3:0], 5'b0} + 9'd21, r_cluster[31:24]);
                    else if (wi == 26)    BW({wpos[3:0], 5'b0} + 9'd26, r_cluster[7:0]);
                    else if (wi == 27)    BW({wpos[3:0], 5'b0} + 9'd27, r_cluster[15:8]);
                    else if (wi >= 28)    BW({wpos[3:0], 5'b0} + {4'b0, wi}, r_size >> {wi[1:0], 3'b000});
                    else                  BW({wpos[3:0], 5'b0} + {4'b0, wi}, 8'h00);
                end
                wi <= wi + 1'b1;
                if (wi == 31) begin wj <= wj + 1'b1; wpos <= wpos + 1'b1; st <= S_D10; end
            end
            S_D17: begin r_sfn <= nsfn; DONE; end

            // ------------------------------------------------------------ remove the entries of the last match
            S_R0: RDD(wpos[11:4], S_R1);
            S_R1: begin BW({wpos[3:0], 5'b0}, 8'hE5); st <= S_R2; end
            S_R2: WRD(wpos[11:4], S_R3);
            S_R3: begin
                if (wpos == m_sfn) begin
                    if (cur == CMD_DEL) begin c_cur <= r_cluster; fsv <= 0; st <= S_F0; end else DONE;
                end else begin wpos <= wpos + 1'b1; st <= S_R0; end
            end

            // ------------------------------------------------------------ free a cluster chain
            S_F0: st <= S_F1;
            S_F1: begin
                if (!fsv || fs != fsec_c) begin
                    if (fsv && dirty) begin fret <= S_F2; st <= S_FL0; end else st <= S_F2;
                end else st <= S_F3;
            end
            S_F2: begin fs <= fsec_c; fsv <= 1; RDS(fat1 + fsec_c, S_F3); end
            S_F3: GET({c_cur[6:0], 2'b00}, 4, S_F4);
            S_F4: begin fnext <= acc & 32'h0FFFFFFF; k <= 0; st <= S_F5; end
            S_F5: begin
                BW({c_cur[6:0], 2'b00} + {7'b0, k[1:0]}, 8'h00);
                k <= k + 1'b1;
                if (k == 3) begin
                    c_cur <= fnext;
                    if (fnext < 2 || fnext >= 32'h0FFFFFF8) begin fret <= S_DN; st <= S_FL0; end
                    else st <= S_F1;
                end
            end
            default: DONE;
        endcase
    end
endmodule

`default_nettype wire
