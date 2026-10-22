// ============================================================================
//  sd_vol.v -- the drives' images, kept as files on an ordinary FAT32 TF card
//
//  The card is what a PC formats: an MBR (or none) and one FAT32 partition.
//  The page (web/src/fat32.js) does all the file management over the raw
//  sector commands below; this module only finds files, by name, and streams
//  them.  At reset, and for one drive whenever the debugger asks (y<d>):
//
//    1. LBA 0: the MBR's first partition (or a partitionless boot sector),
//       then the FAT32 boot sector: sectors per cluster, the FATs, the root.
//    2. The root directory, for A2CONFIG.TXT (web/src/config.js has the
//       format: lines S6D1=NAME.EXT, 8.3 names, ";" starts a comment).
//    3. The root again, for the four names it gives.
//    4. Each file's FAT chain must be one run (it is streamed with a single
//       CMD18), and its size must fit the drive: 143,360 bytes and .DSK/.DO
//       (DOS order) or .PO for slot 6, a .HDV or .PO of whole 512-byte blocks
//       up to 32 MB for slot 7.  A file that is missing, fragmented or the wrong size leaves
//       its drive empty and sets its `fail` bit.
//    5. Slot 6 files stream into disk2_store's up_* port in physical sector
//       order (DOS_TO_PHYS for DOS order, the same table as web/src/disk.js).
//       Slot 7 files are not loaded: each block is read when prodos_hd asks
//       (rb_go, below).
//  Nothing is buffered (block RAM is 46/46): each sector is parsed as it goes
//  past, and the SPI clock simply waits when the far side is not ready.
//  `loading` is high for all of it, and top.v holds the CPU on it.
//
//  After that, in priority order:
//    wb_go    write a slot 7 block back (prodos_hd, after each WRITE), to the
//             file's sector `start + blk`, dropped past the file's end so a
//             write can never land in another file
//    rb_go    read slot 7 block wb_blk into its DDR3 home (aux_ram hd_*, word
//             address {drive, block, word}, low byte = even byte); rb_ok says
//             it is there.  The block last read or written is remembered
//             (`tag`) and not read again; writes go straight through, so the
//             DDR3 copy is never newer than the file.
//    x_go     write sector x_lba from bytes the debugger hands over
//             (x_byte/x_valid, x_take when used) or, with x_zero, zeros
//    r_go     read r_cnt sectors from r_lba, each byte to the debugger
//             (r_byte/r_valid, r_take); r_done, r_ok at the end
//    floppy   a track the Apple wrote (fl_wr) goes back to its file, 8 sectors
//             at start + track * 8, once the drive has been quiet ~1 s and the
//             debugger is not in session (bg_hold)
//    mnt_go   reload drive mnt_drv (0-1 slot 6, 2-3 slot 7) from the config,
//             after its floppy tracks are on the card
//  Each request is latched, so one that arrives while another runs waits;
//  a floppy track flush is one job per sector, so rb_go waits for at most
//  one sector behind it.  A card that stops answering gives up after 2^20
//  polls (~0.75 s at 13.5 MHz).
//
//  `err` latches on a card failure, `estage` = the command (0 CMD0 1 CMD8
//  2 CMD55 3 ACMD41 4 CMD17 5 CMD24 6 CMD18 7 CMD12/timeout).  A raw read
//  that fails (past the card's end) only answers r_ok = 0.
//  ponytail: SDHC/SDXC only (no CMD58 check), no CRC checking, FAT32 only,
//  root directory only.
// ============================================================================
`default_nettype none

module sd_vol #(
    parameter       PWR_BITS   = 20,   // card power-up wait, 2^N clocks
    parameter [6:0] FAST_HALF  = 7'd0, // SPI half period after init: 0 = 13.5 MHz
    parameter       QUIET_BITS = 25    // floppy write-back after 2^N quiet clocks
) (
    input  wire        clk,            // 27 MHz
    input  wire        reset,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output reg         sd_cs_n,

    input  wire        ddr_ready,
    output reg         m_go,           // slot 7: the DDR3 (aux_ram hd_*)
    output reg  [24:0] m_addr,
    output reg         m_we,
    output reg  [15:0] m_wdata,
    input  wire [15:0] m_rdata,
    input  wire        m_ack,          // shared with the card: only ours while m_busy

    output reg         f_up_go,        // slot 6: disk2_store's up_*/down_* ports
    output reg         f_up_drive,
    output reg  [17:0] f_up_addr,
    output reg  [7:0]  f_up_data,
    output reg         f_up_last,
    output reg         f_up_bad,
    input  wire        f_up_busy,
    input  wire        f_up_done,
    output reg         f_dn_go,
    output reg         f_dn_drive,
    output reg  [17:0] f_dn_addr,
    input  wire [7:0]  f_dn_data,
    input  wire        f_dn_valid,
    input  wire        fl_wr,          // a data field is being written...
    input  wire        fl_wr_drv,      // ...on this drive and track
    input  wire [5:0]  fl_wr_trk,
    input  wire [1:0]  fl_detach,      // the debugger put its own image in a drive
    input  wire        bg_hold,        // no background write-back now

    output reg  [3:0]  present,        // a drive holds its file (slot 6 1-2, slot 7 1-2)
    output reg  [3:0]  fail,           // ...or the config named one that cannot be used
    output reg         fs_ok,          // the card is FAT32
    output wire        loading,
    output wire        busy,
    output reg         err,
    output reg  [2:0]  estage,

    input  wire        wb_go,
    input  wire        wb_drv,
    input  wire [15:0] wb_blk,
    input  wire        rb_go,          // block in wb_drv/wb_blk
    output reg         rb_ok,
    input  wire        mnt_go,
    input  wire [1:0]  mnt_drv,

    input  wire        x_go,
    input  wire [31:0] x_lba,
    input  wire        x_zero,
    input  wire [7:0]  x_byte,
    input  wire        x_valid,
    output reg         x_take,

    input  wire        r_go,
    input  wire [31:0] r_lba,
    input  wire [15:0] r_cnt,
    output reg  [7:0]  r_byte,
    output reg         r_valid,
    input  wire        r_take,
    output reg         r_done,
    output reg         r_ok
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

    // DOS 3.3 logical sector -> the store's physical position (web/src/disk.js)
    function [3:0] dos2phys(input [3:0] s);
        case (s)
            4'h0: dos2phys = 4'h0; 4'h1: dos2phys = 4'hD; 4'h2: dos2phys = 4'hB; 4'h3: dos2phys = 4'h9;
            4'h4: dos2phys = 4'h7; 4'h5: dos2phys = 4'h5; 4'h6: dos2phys = 4'h3; 4'h7: dos2phys = 4'h1;
            4'h8: dos2phys = 4'hE; 4'h9: dos2phys = 4'hC; 4'hA: dos2phys = 4'hA; 4'hB: dos2phys = 4'h8;
            4'hC: dos2phys = 4'h6; 4'hD: dos2phys = 4'h4; 4'hE: dos2phys = 4'h2; default: dos2phys = 4'hF;
        endcase
    endfunction

    localparam [4:0] PWR = 0, DUM = 1, CMDS = 2, R1 = 3, EXTRA = 4, DTOK = 5, DATA = 6,
                     CRC = 7, IDLE = 8, WGAP = 9, WTOK = 10, WBYTE = 11, WCRC = 12,
                     WRESP = 13, WBSY = 14, SKIP = 15, BSY = 16;
    // what a read's bytes are for
    localparam [3:0] T_MBR = 0, T_VBR = 1, T_DIR = 2, T_FAT1 = 3, T_CFG = 4, T_FATW = 5,
                     T_HD = 6, T_FL = 7, T_RAW = 8;
    // where a write's bytes come from
    localparam [1:0] W_X = 0, W_Z = 1, W_HD = 2, W_FL = 3;
    // the job that is running, for what to do when it ends
    localparam [2:0] J_LK = 0, J_RAW = 1, J_X = 2, J_WB = 3, J_FW = 4, J_RB = 5;
    // the lookup (header steps 1-5)
    localparam [3:0] L_IDLE = 0, L_MBR = 1, L_VBR = 2, L_DIR = 3, L_DIRF = 4, L_DIRDONE = 5,
                     L_CFG = 6, L_DRV = 7, L_WALK = 8, L_DDR = 9, L_LOAD = 10, L_NEXT = 11;
    // the config parser
    localparam [2:0] P_K0 = 0, P_K1 = 1, P_K2 = 2, P_K3 = 3, P_EQ = 4, P_N0 = 5, P_N = 6, P_SKIP = 7;
    localparam [87:0] SPACES  = {11{8'h20}};
    localparam [87:0] CFGNAME = "A2CONFIGTXT";
    localparam [31:0] FLOPPY_BYTES = 32'd143360;

    reg [4:0]  st = PWR;
    reg [2:0]  ph = CMD0;
    reg        sx = 1'b0, got = 1'b0;  // a byte in flight / its answer is in rxv
    reg [7:0]  rxv = 8'hFF;
    reg [PWR_BITS-1:0] pcnt = 0;
    reg [19:0] n = 20'd0;
    reg [47:0] cmdbuf;
    reg [11:0] tries = 12'd0;
    reg [8:0]  bcnt = 9'd0;
    reg        inited = 1'b0;

    // the job
    reg [3:0]  tgt = T_MBR;
    reg [1:0]  wsrc = W_X;
    reg [2:0]  jk = J_LK;
    reg [15:0] blk = 16'd0;             // sector of the job
    reg [15:0] jlast = 16'd0;           // ...its last one (a CMD18 when not 0)
    reg        jdone = 1'b0;            // a job has ended; IDLE deals with it
    reg        jfail = 1'b0;            // ...badly
    reg        m_busy = 1'b0;
    reg [7:0]  lo = 8'h00;              // even byte, waiting for its odd one
    reg [15:0] wword = 16'h0000;        // word being sent on a write
    reg        fl_pend = 1'b0;          // a byte is out to the store

    // the file system
    reg [31:0] part = 0, fat_lba = 0, data_lba = 0, root = 0, fatsz = 0, nxt = 0;
    reg [15:0] rsvd = 0, bps = 0;
    reg [7:0]  spc = 1, nfats = 2, ptype = 0;
    reg [2:0]  spc_log = 0;
    reg        vchk = 1'b0;             // "FAT32" at 0x52 of the sector
    function [31:0] clus_lba(input [31:0] c);
        clus_lba = data_lba + ((c - 32'd2) << spc_log);
    endfunction

    // the lookup
    reg [3:0]  lk = L_MBR;
    reg        lk_wait = 1'b0;          // a lookup read is out
    reg        pass = 1'b0;             // 0: find the config, 1: find the drives' files
    reg [31:0] dclus = 0;               // directory cluster being read
    reg        dir_end = 1'b0;
    reg [3:0]  ld_mask = 4'b1111;       // drives this lookup loads
    reg [1:0]  k = 2'd0;
    reg [87:0] nm [0:3];                // 8.3 names from the config
    reg [3:0]  has = 4'd0;              // ...where it names one
    reg [4:0]  found = 5'd0;            // directory hits: drives 0-3, config 4
    reg [31:0] fclus [0:4];
    reg [31:0] fsize [0:4];
    reg [4:0]  mt = 5'd0;               // the entry being read still matches
    reg [31:0] ec = 0, es = 0;          // the entry's cluster and size so far
    reg [31:0] c0 = 0, clast = 0, ent = 0;
    reg        walk_ok = 1'b0;
    reg [31:0] fstart [0:3];
    reg [16:0] fnsec [0:3];
    reg [1:0]  fdos = 2'b00;            // slot 6 drive holds a DOS-order file
    // the config parser
    reg [2:0]  ps = P_K0;
    reg [1:0]  pkey = 2'd0;
    reg [87:0] nb = SPACES;
    reg [3:0]  np = 4'd0;
    reg        pdot = 1'b0;

    // requests waiting
    reg        wb_req = 1'b0, rb_req = 1'b0, x_req = 1'b0, r_req = 1'b0;
    // the slot 7 block of wb_go or rb_go: one latch, since prodos_hd never has
    // both out (its driver waits for busy after each)
    reg        hd_d = 1'b0;
    reg [15:0] hd_b = 16'd0;
    // ponytail: one block remembered; a 2nd tag if ProDOS ping-pongs blocks
    reg        tag_v = 1'b0;
    reg [16:0] tag = 17'd0;             // {drive, block} the DDR3 holds
    reg [3:0]  rl_req = 4'd0;           // drives to reload
    reg [1:0]  rl_d = 2'd0;             // ...the one being looked at
    reg        ej_pend = 1'b0;          // pulse f_up_bad next clock (f_up_drive is set)
    // floppy write-back
    reg [34:0] dirty0 = 0, dirty1 = 0;
    reg [QUIET_BITS-1:0] quiet = 0;
    wire       quiet_up = &quiet;
    reg        fs_drv = 1'b0;           // the scan for a dirty track
    reg [5:0]  fs_trk = 6'd0;
    reg        fw_active = 1'b0, fw_k = 1'b0;
    reg [5:0]  fw_t = 6'd0;
    reg [2:0]  fw_j = 3'd0;
    wire [34:0] dsel   = fs_drv ? dirty1 : dirty0;
    wire        fs_hit = dsel[fs_trk];
    // a reload waits for its drive's tracks; otherwise ~1 s after the last write
    wire        fs_go  = fs_hit && (rl_req[fs_drv] || (quiet_up && !bg_hold));

    // A DDR3 that never calibrates must not hold the CPU for ever: give up
    // on loading after ~2.5 s of waiting for it.
    reg [25:0] dwait = 26'd0;
    wire       gave_up = &dwait;
    always @(posedge clk)
        if (reset) dwait <= 26'd0;
        else if (!ddr_ready && !gave_up) dwait <= dwait + 1'b1;

    assign loading = lk != L_IDLE;
    assign busy    = st != IDLE || lk != L_IDLE || jdone || wb_req || rb_req || x_req || r_req ||
                     fw_active || rl_req != 4'd0;

    wire        hd_in  = present[{1'b1, hd_d}] && {1'b0, hd_b} < fnsec[{1'b1, hd_d}];
    wire [31:0] hd_lba = fstart[{1'b1, hd_d}] + {16'd0, hd_b};

    // the byte of an 8.3 name at position e (0-10), byte 0 first
    function [7:0] nbyte(input [87:0] s, input [3:0] e);
        nbyte = s[8*(10 - e) +: 8];
    endfunction
    wire [4:0] e      = bcnt[4:0];                     // offset in a directory entry
    wire [7:0] up_c   = (rxv >= "a" && rxv <= "z") ? rxv - 8'd32 : rxv;
    wire       c_end  = rxv == " " || rxv == ";" || rxv == 8'h0D || rxv == 8'h0A ||
                        rxv == 8'h09 || rxv == 8'h00;
    wire [31:0] v_ent = {4'h0, rxv[3:0], ent[31:8]};  // a FAT entry, at its 4th byte
    wire [27:0] cur_cl = {c0[27:7] + blk[15:0], bcnt[8:2]};
    wire [3:0] fl_sec = {blk[2:0], bcnt[8]};           // DOS sector within the track
    wire [3:0] fw_sec = {fw_j, bcnt[8]};

    task xfer(input [7:0] b); begin txb <= b; spi_go <= 1'b1; sx <= 1'b1; end endtask
    task go_cmd(input [2:0] p, input [31:0] l);
        begin ph <= p; cmdbuf <= cmdw(p, l); n <= 0; st <= CMDS; end
    endtask
    // a read of `cnt` sectors from `lba`, its bytes for `t`
    task rd(input [31:0] lba, input [15:0] last, input [3:0] t, input [2:0] kind);
        begin
            tgt <= t; jk <= kind; blk <= 16'd0; jlast <= last; jfail <= 1'b0;
            sd_cs_n <= 1'b0; got <= 1'b0;
            go_cmd(last == 16'd0 ? CMD17 : CMD18, lba);
        end
    endtask
    task wr(input [31:0] lba, input [1:0] src, input [2:0] kind);
        begin
            wsrc <= src; jk <= kind; jfail <= 1'b0; sd_cs_n <= 1'b0; got <= 1'b0;
            go_cmd(CMD24, lba);
        end
    endtask
    task fin; begin sd_cs_n <= 1'b1; st <= IDLE; jdone <= inited; end endtask
    task die;
        if (inited && ph == CMD18) begin
            // a run that failed part way: stop the card streaming first, or it
            // answers nothing else until it is power-cycled
            jfail <= 1'b1; go_cmd(CMD12, 32'h0);
            if (jk != J_RAW) begin err <= 1'b1; estage <= ph; end
        end else begin
            fin; jfail <= 1'b1;
            // a raw read past the card's end is an answer, not a broken card
            if (!(inited && jk == J_RAW)) begin err <= 1'b1; estage <= ph; end
            if (!inited) lk <= L_IDLE;
        end
    endtask
    task commit_name;
        begin nm[pkey] <= nb; has[pkey] <= np != 4'd0; end
    endtask

    integer i;
    always @(posedge clk) begin
        spi_go   <= 1'b0;
        m_go     <= 1'b0;
        x_take   <= 1'b0;
        r_done   <= 1'b0;
        f_up_bad <= 1'b0;
        if (ej_pend) begin ej_pend <= 1'b0; f_up_bad <= 1'b1; end
        if (m_ack && m_busy) begin
            m_busy <= 1'b0;
            wword  <= m_rdata;
        end
        if (r_take) r_valid <= 1'b0;
        if (f_up_done && fl_pend) begin fl_pend <= 1'b0; f_up_go <= 1'b0; end
        if (wb_go || rb_go) begin hd_d <= wb_drv; hd_b <= wb_blk; end
        if (wb_go) wb_req <= 1'b1;
        if (rb_go) rb_req <= 1'b1;
        if (x_go)  begin x_req <= 1'b1; tag_v <= 1'b0; end   // it may rewrite the file
        if (r_go)  r_req <= 1'b1;
        if (mnt_go) begin rl_req[mnt_drv] <= 1'b1; tag_v <= 1'b0; end
        // a written track of a drive that holds its file; quiet counts from the last
        if (fl_wr) begin
            quiet <= 0;
            if (present[fl_wr_drv] && fl_wr_trk < 6'd35) begin
                if (fl_wr_drv) dirty1[fl_wr_trk] <= 1'b1; else dirty0[fl_wr_trk] <= 1'b1;
            end
        end else if (!quiet_up) quiet <= quiet + 1'b1;
        for (i = 0; i < 2; i = i + 1)
            if (fl_detach[i]) begin
                present[i] <= 1'b0; fail[i] <= 1'b0;
                if (i == 1) dirty1 <= 0; else dirty0 <= 0;
            end

        if (reset) begin
            st <= PWR; pcnt <= 0; fast <= 1'b0; sx <= 1'b0; got <= 1'b0; tries <= 0;
            err <= 1'b0; estage <= 0; sd_cs_n <= 1'b1; n <= 0; bcnt <= 0;
            inited <= 1'b0; present <= 4'd0; fail <= 4'd0; fs_ok <= 1'b0; m_busy <= 1'b0;
            lk <= L_MBR; lk_wait <= 1'b0; ld_mask <= 4'b1111; k <= 2'd0; jdone <= 1'b0;
            wb_req <= 1'b0; x_req <= 1'b0; r_req <= 1'b0; rl_req <= 4'd0;
            rb_req <= 1'b0; rb_ok <= 1'b1; tag_v <= 1'b0;
            dirty0 <= 0; dirty1 <= 0; fw_active <= 1'b0; r_valid <= 1'b0;
            f_up_go <= 1'b0; f_dn_go <= 1'b0; fl_pend <= 1'b0;
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
                            ACMD41: if (rxv == 0) begin fast <= 1'b1; inited <= 1'b1; sd_cs_n <= 1'b1; st <= IDLE; end
                                    else if (&tries) die;
                                    else begin tries <= tries + 1'b1; go_cmd(CMD55, 32'h0); end
                            CMD24:  if (rxv == 0) st <= WGAP; else die;
                            CMD12:  st <= BSY;
                            default:if (rxv == 0) begin bcnt <= 0; st <= DTOK; end else die;  // CMD17, CMD18
                        endcase
                    end else if (n == 63) die;
                end
            EXTRA: if (!got) xfer(8'hFF);
                   else begin got <= 1'b0; n <= n + 1'b1; if (n == 3) go_cmd(CMD55, 32'h0); end

            // ---- reading: one sector (CMD17) or a run of them (CMD18) ----
            DTOK: if (!got) xfer(8'hFF);
                  else begin
                      got <= 1'b0; n <= n + 1'b1;
                      if (rxv == 8'hFE) begin bcnt <= 0; st <= DATA; end
                      else if (&n) die;
                  end
            DATA: if (!got) xfer(8'hFF);
                  else if (!((tgt == T_HD && bcnt[0] && m_busy) ||
                             (tgt == T_FL && (fl_pend || f_up_busy)) ||
                             (tgt == T_RAW && r_valid))) begin
                      got <= 1'b0; bcnt <= bcnt + 1'b1;
                      case (tgt)
                          T_MBR, T_VBR: begin
                              if (bcnt >= 9'h052 && bcnt <= 9'h056)
                                  vchk <= (bcnt == 9'h052 || vchk) &&
                                          rxv == nbyte({"FAT32", 48'h0}, bcnt - 9'h052);
                              if (bcnt == 9'h1C2) ptype <= rxv;
                              if (tgt == T_MBR && bcnt >= 9'h1C6 && bcnt <= 9'h1C9) part <= {rxv, part[31:8]};
                              if (bcnt == 9'h00B || bcnt == 9'h00C) bps <= {rxv, bps[15:8]};
                              if (bcnt == 9'h00D) spc <= rxv;
                              if (bcnt == 9'h00E || bcnt == 9'h00F) rsvd <= {rxv, rsvd[15:8]};
                              if (bcnt == 9'h010) nfats <= rxv;
                              if (bcnt >= 9'h024 && bcnt <= 9'h027) fatsz <= {rxv, fatsz[31:8]};
                              if (bcnt >= 9'h02C && bcnt <= 9'h02F) root <= {rxv, root[31:8]};
                          end
                          T_DIR: if (!dir_end) begin
                              if (e == 5'd0 && rxv == 8'h00) dir_end <= 1'b1;
                              for (i = 0; i < 5; i = i + 1) begin
                                  if (e <= 5'd10)
                                      mt[i] <= (e == 5'd0 || mt[i]) &&
                                               rxv == nbyte(i == 4 ? CFGNAME : nm[i[1:0]], e[3:0]) &&
                                               (i == 4 || has[i[1:0]]);
                                  if (e == 5'd11 && (rxv & 8'h18) != 8'h00) mt[i] <= 1'b0;  // dir, label, LFN
                                  if (e == 5'd31 && mt[i]) begin
                                      found[i] <= 1'b1;
                                      fclus[i] <= {4'h0, ec[27:0]};
                                      fsize[i] <= {rxv, es[31:8]};
                                  end
                              end
                              if (e == 5'd20 || e == 5'd21) ec[31:16] <= {rxv, ec[31:24]};
                              if (e == 5'd26 || e == 5'd27) ec[15:0]  <= {rxv, ec[15:8]};
                              if (e >= 5'd28) es <= {rxv, es[31:8]};
                          end
                          T_FAT1: if (bcnt[8:2] == dclus[6:0]) nxt <= {rxv, nxt[31:8]};
                          T_FATW: begin
                              ent <= {rxv, ent[31:8]};
                              if (bcnt[1:0] == 2'd3 && cur_cl >= c0[27:0] && cur_cl <= clast[27:0]) begin
                                  if (cur_cl == clast[27:0]) begin
                                      if (v_ent[27:0] < 28'hFFFFFF8) walk_ok <= 1'b0;
                                  end else if (v_ent[27:0] != cur_cl + 1'b1) walk_ok <= 1'b0;
                              end
                          end
                          T_CFG: if ({23'd0, bcnt} < fsize[4]) begin
                              if (rxv == 8'h0A) begin
                                  if (ps == P_N0 || ps == P_N) commit_name;
                                  ps <= P_K0;
                              end else case (ps)
                                  P_K0: if (up_c == "S") ps <= P_K1; else if (!c_end) ps <= P_SKIP;
                                  P_K1: if (rxv == "6" || rxv == "7") begin pkey[1] <= rxv[0]; ps <= P_K2; end
                                        else ps <= P_SKIP;
                                  P_K2: ps <= (up_c == "D") ? P_K3 : P_SKIP;
                                  P_K3: if (rxv == "1" || rxv == "2") begin pkey[0] <= ~rxv[0]; ps <= P_EQ; end
                                        else ps <= P_SKIP;
                                  P_EQ: if (rxv == "=") begin ps <= P_N0; nb <= SPACES; np <= 0; pdot <= 1'b0; end
                                        else if (rxv != " ") ps <= P_SKIP;
                                  P_N0, P_N:
                                      if (c_end) begin
                                          if (!(ps == P_N0 && rxv == " ")) begin commit_name; ps <= P_SKIP; end
                                      end else begin
                                          ps <= P_N;
                                          if (rxv == ".") begin
                                              if (pdot || np == 4'd0) ps <= P_SKIP;
                                              pdot <= 1'b1; np <= 4'd8;
                                          end else if (np < (pdot ? 4'd11 : 4'd8)) begin
                                              nb[8*(10 - np) +: 8] <= up_c; np <= np + 1'b1;
                                          end else ps <= P_SKIP;      // too long: not an 8.3 name
                                      end
                                  default: ;
                              endcase
                          end
                          T_HD: if (!bcnt[0]) lo <= rxv;
                                else begin
                                    m_go <= 1'b1; m_we <= 1'b1; m_busy <= 1'b1;
                                    m_addr  <= {hd_d, hd_b, bcnt[8:1]};
                                    m_wdata <= {rxv, lo};
                                end
                          T_FL: begin
                              f_up_go <= 1'b1; fl_pend <= 1'b1; f_up_drive <= k[0];
                              f_up_data <= rxv;
                              f_up_addr <= {blk[8:3], fdos[k[0]] ? dos2phys(fl_sec) : fl_sec, bcnt[7:0]};
                              f_up_last <= blk == 16'd279 && bcnt == 9'd511;
                          end
                          default: begin r_byte <= rxv; r_valid <= 1'b1; end   // T_RAW
                      endcase
                      if (bcnt == 9'd511) begin n <= 0; st <= CRC; end
                  end
            CRC: if (!got) xfer(8'hFF);
                 else begin
                     got <= 1'b0; n <= n + 1'b1;
                     if (n == 1) begin
                         n <= 0;
                         if (blk == jlast) begin
                             if (jlast == 16'd0) fin; else go_cmd(CMD12, 32'h0);
                         end else begin blk <= blk + 1'b1; st <= DTOK; end
                     end
                 end
            BSY: if (!got) xfer(8'hFF);          // after CMD12, and after a write
                 else begin
                     got <= 1'b0; n <= n + 1'b1;
                     if (rxv == 8'hFF) fin;
                     else if (&n) begin ph <= CMD12; die; end
                 end

            // ---- writing one sector ----
            WGAP: if (!got) xfer(8'hFF); else begin got <= 1'b0; st <= WTOK; end
            WTOK: if (!got) xfer(8'hFE); else begin got <= 1'b0; bcnt <= 0; n <= 0; st <= WBYTE; end
            WBYTE: if (!got) begin
                       case (wsrc)
                           W_Z: xfer(8'h00);
                           W_X: if (x_valid && !x_take) begin xfer(x_byte); x_take <= 1'b1; end
                           W_HD:
                               if (bcnt[0]) xfer(wword[15:8]);
                               else if (!m_busy && !m_go) begin
                                   // the word's low byte goes when its read has come back
                                   if (n[0]) begin n <= 0; xfer(wword[7:0]); end
                                   else begin
                                       m_go <= 1'b1; m_we <= 1'b0; m_busy <= 1'b1; n <= 1;
                                       m_addr <= {hd_d, hd_b, bcnt[8:1]};
                                   end
                               end
                           default:   // W_FL: a byte from the store
                               if (f_dn_go && f_dn_valid) begin f_dn_go <= 1'b0; xfer(f_dn_data); end
                               else if (!f_dn_go && !f_dn_valid) begin
                                   f_dn_go    <= 1'b1;
                                   f_dn_drive <= fw_k;
                                   f_dn_addr  <= {fw_t, fdos[fw_k] ? dos2phys(fw_sec) : fw_sec, bcnt[7:0]};
                               end
                       endcase
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
                if (jdone) begin
                    // ---- a job has ended ----
                    jdone <= 1'b0;
                    case (jk)
                        J_RAW: begin r_done <= 1'b1; r_ok <= !jfail; end
                        J_RB: begin rb_ok <= !jfail; tag_v <= !jfail; tag <= {hd_d, hd_b}; end
                        J_FW: if (jfail || fw_j == 3'd7) fw_active <= 1'b0; else fw_j <= fw_j + 1'b1;
                        J_LK: begin
                            lk_wait <= 1'b0;
                            if (jfail) lk <= L_IDLE;
                            else case (lk)
                                L_MBR:
                                    // a boot sector at LBA 0 (no MBR), or partition 1 of type 0B/0C
                                    if (vchk) begin part <= 0; lk <= L_VBR; end
                                    else if (ptype == 8'h0B || ptype == 8'h0C) lk <= L_VBR;
                                    else lk <= L_IDLE;
                                L_VBR:
                                    if (!vchk || bps != 16'd512 || spc == 8'd0) lk <= L_IDLE;
                                    else begin
                                        fs_ok   <= 1'b1;
                                        fat_lba <= part + rsvd;
                                        data_lba <= part + rsvd + (nfats == 8'd2 ? fatsz << 1 : fatsz);
                                        spc_log <= spc[7] ? 3'd7 : spc[6] ? 3'd6 : spc[5] ? 3'd5 :
                                                   spc[4] ? 3'd4 : spc[3] ? 3'd3 : spc[2] ? 3'd2 :
                                                   spc[1] ? 3'd1 : 3'd0;
                                        pass <= 1'b0; dclus <= root; dir_end <= 1'b0; found <= 5'd0;
                                        lk <= L_DIR;
                                    end
                                L_DIR: lk <= dir_end ? L_DIRDONE : L_DIRF;
                                L_DIRF: begin
                                    if (nxt[27:0] >= 28'd2 && nxt[27:0] < 28'hFFFFFF8) begin
                                        dclus <= {4'h0, nxt[27:0]}; lk <= L_DIR;
                                    end else lk <= L_DIRDONE;
                                end
                                L_CFG: begin
                                    if (ps == P_N0 || ps == P_N) commit_name;
                                    pass <= 1'b1; dclus <= root; dir_end <= 1'b0; found[3:0] <= 4'd0;
                                    lk <= L_DIR;
                                end
                                L_WALK:
                                    if (!walk_ok) begin fail[k] <= 1'b1; lk <= L_NEXT; end
                                    else begin
                                        fstart[k] <= clus_lba(c0);
                                        fnsec[k]  <= fsize[k][25:9];
                                        if (!k[1]) fdos[k[0]] <= nm[k][23:0] != "PO ";
                                        lk <= L_DDR;
                                    end
                                L_LOAD: begin present[k] <= 1'b1; lk <= L_NEXT; end
                                default: lk <= L_IDLE;
                            endcase
                        end
                        default: ;   // J_X, J_WB: the debugger and prodos_hd watch busy
                    endcase
                end else if (lk != L_IDLE) begin
                    // ---- the lookup's next step ----
                    if (!lk_wait) case (lk)
                        L_MBR: begin lk_wait <= 1'b1; vchk <= 1'b0; rd(32'd0, 16'd0, T_MBR, J_LK); end
                        L_VBR: begin lk_wait <= 1'b1; vchk <= 1'b0; rd(part, 16'd0, T_VBR, J_LK); end
                        L_DIR: begin lk_wait <= 1'b1; rd(clus_lba(dclus), {8'd0, spc} - 16'd1, T_DIR, J_LK); end
                        L_DIRF: begin lk_wait <= 1'b1; rd(fat_lba + {11'd0, dclus[27:7]}, 16'd0, T_FAT1, J_LK); end
                        L_DIRDONE:
                            if (!pass && found[4]) begin
                                lk <= L_CFG; lk_wait <= 1'b1;
                                ps <= P_K0; has <= 4'd0;
                                for (i = 0; i < 4; i = i + 1) nm[i] <= SPACES;
                                rd(clus_lba(fclus[4]), 16'd0, T_CFG, J_LK);
                            end else begin
                                if (!pass) has <= 4'd0;   // no config: every drive empty
                                k <= 2'd0; lk <= L_DRV;
                            end
                        L_DRV:
                            if (!ld_mask[k] || !has[k]) lk <= L_NEXT;      // not asked for, or empty
                            else if (!found[k] ||
                                     (!k[1] && !(fsize[k] == FLOPPY_BYTES &&
                                                 (nm[k][23:0] == "DSK" || nm[k][23:0] == "DO " ||
                                                  nm[k][23:0] == "PO "))) ||
                                     (k[1] && (fsize[k] == 32'd0 || fsize[k][8:0] != 9'd0 ||
                                               fsize[k] > 32'h0200_0000 ||
                                               // a .dsk/.do is DOS order: not a block device
                                               !(nm[k][23:0] == "HDV" || nm[k][23:0] == "PO ")))) begin
                                fail[k] <= 1'b1; lk <= L_NEXT;
                            end else begin
                                c0 <= fclus[k];
                                // the last cluster: first + ceil(size / cluster) - 1
                                clast <= fclus[k] - 32'd1 +
                                         ((fsize[k] + (32'd512 << spc_log) - 32'd1) >> (5'd9 + spc_log));
                                lk <= L_WALK;
                            end
                        L_WALK: begin
                            lk_wait <= 1'b1; walk_ok <= 1'b1;
                            rd(fat_lba + {11'd0, c0[27:7]}, clast[22:7] - c0[22:7], T_FATW, J_LK);
                        end
                        L_DDR: if (gave_up) lk <= L_NEXT; else if (ddr_ready) lk <= L_LOAD;
                        L_LOAD:
                            // slot 7 is read a block at a time when prodos_hd asks
                            if (k[1]) begin present[k] <= 1'b1; lk <= L_NEXT; end
                            else begin
                                lk_wait <= 1'b1;
                                rd(fstart[k], fnsec[k][15:0] - 16'd1, T_FL, J_LK);
                            end
                        L_NEXT: if (k == 2'd3) lk <= L_IDLE; else begin k <= k + 1'b1; lk <= L_DRV; end
                        default: lk <= L_IDLE;
                    endcase
                end else if (wb_req) begin
                    // ---- a slot 7 block back to its file, never past its end ----
                    wb_req <= 1'b0;
                    if (hd_in) begin
                        tag <= {hd_d, hd_b}; tag_v <= 1'b1;   // the DDR3 holds what was written
                        wr(hd_lba, W_HD, J_WB);
                    end
                end else if (rb_req) begin
                    // ---- a slot 7 block from its file into the DDR3 ----
                    rb_req <= 1'b0;
                    if (tag_v && tag == {hd_d, hd_b}) rb_ok <= 1'b1;
                    else if (!hd_in) rb_ok <= 1'b0;
                    else begin
                        tag_v <= 1'b0;
                        rd(hd_lba, 16'd0, T_HD, J_RB);
                    end
                end else if (x_req) begin
                    x_req <= 1'b0;
                    wr(x_lba, x_zero ? W_Z : W_X, J_X);
                end else if (r_req) begin
                    r_req <= 1'b0;
                    rd(r_lba, r_cnt - 16'd1, T_RAW, J_RAW);
                end else if (fw_active) begin
                    wr(fstart[{1'b0, fw_k}] + {23'd0, fw_t, fw_j}, W_FL, J_FW);
                end else if (fs_go) begin
                    // ---- a written floppy track back to its file ----
                    if (fs_drv) dirty1[fs_trk] <= 1'b0; else dirty0[fs_trk] <= 1'b0;
                    fw_active <= 1'b1; fw_k <= fs_drv; fw_t <= fs_trk; fw_j <= 3'd0;
                end else if (rl_req != 4'd0) begin
                    // ---- reload a drive, once its written tracks are on the card ----
                    rl_d <= rl_d + 1'b1;
                    if (rl_req[rl_d] && !(!rl_d[1] && (rl_d[0] ? dirty1 : dirty0) != 0)) begin
                        rl_req[rl_d] <= 1'b0;
                        present[rl_d] <= 1'b0; fail[rl_d] <= 1'b0;
                        if (!rl_d[1]) begin f_up_drive <= rl_d[0]; ej_pend <= 1'b1; end
                        ld_mask <= 4'd1 << rl_d;
                        lk <= L_MBR;
                    end
                end
                // the dirty-track scan steps on past anything it cannot flush yet
                if (!fs_go) begin
                    if (fs_trk == 6'd34) begin fs_trk <= 6'd0; fs_drv <= ~fs_drv; end
                    else fs_trk <= fs_trk + 1'b1;
                end
            end
            default: ;
        endcase
    end
endmodule

`default_nettype wire
