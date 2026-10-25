// Disk ][ image store: the two drives' WOZ files in DDR3, played a bit at a time.
//
// Each drive's .woz (WOZ 2, src/sd_vol.v loads the whole file, up to 1 MB)
// sits in aux_ram's region 1 byte for byte: file byte n of drive d is half of
// word {d, n[19:1]}, the low half for an even n.  Nothing here knows what a
// sector is.  The card (src/disk2/disk2_card.v) says which drive and which
// quarter track the head is on, and once per bit cell takes the bit under the
// head and moves on, writing one in its place in write mode.  This module
// finds that quarter track's bits through the file's own tables (WOZ 2
// reference, applesaucefdc.com/woz/reference2):
//
//   TMAP  byte 88 + quarter track: the TRKS index, 0xFF = no track there
//   TRKS  bytes 256 + 8 i: starting block (u16), block count, bit count (u32)
//   bits  from that block (512 bytes each), MSB first, wrapping at the count
//
// and keeps the 16-bit word under the head in hand with the next one fetched
// behind it, so a bit is always there: a word is 16 bit cells, ~1,750 clocks,
// against a DDR3 read of a few tens.  A written word goes back when the head
// leaves it (or write mode ends), and fl_wr names its 512-byte block of the
// file, which is what sd_vol copies back to the card.  An empty quarter track,
// a track not fetched yet, or no disk gives rd_ok = 0, and the card makes the
// MC3470's noise from that.
`default_nettype none

module disk2_store (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,

    // The head, from the card
    input  wire        drive,         // 0 = drive 1
    input  wire [7:0]  qtr,           // quarter track, 0..159
    input  wire        bit_tick,      // the bit cell ends: move on one bit
    input  wire        wr_en,         // ...having written wr_bit in it
    input  wire        wr_bit,
    input  wire        wr_mode,       // Q7; a written word goes back when it drops
    output wire        rd_bit,        // the bit under the head
    output wire        rd_ok,         // ...is a real one
    output wire [1:0]  drv_present,   // a drive holds an image
    output wire [1:0]  drv_writable,  // ...and it is not write protected

    // A written word went to DDR3: the file block sd_vol must copy back
    output reg         fl_wr = 1'b0,
    output reg         fl_wr_drv = 1'b0,
    output reg  [10:0] fl_wr_blk = 11'd0,

    // The bulk port sd_vol loads a file through (up_*) and copies written
    // blocks back through (down_*), a byte at a time; addresses are byte
    // offsets in the file
    input  wire        up_go,
    input  wire        up_drive,
    input  wire [19:0] up_addr,
    input  wire [7:0]  up_data,
    input  wire        up_last,       // the file's last byte: the drive holds it now
    input  wire        up_ro,         // ...write protected (INFO byte 22)
    input  wire        up_bad,        // eject the drive
    output wire        up_busy,
    output reg         up_done,
    input  wire        down_go,
    input  wire        down_drive,
    input  wire [19:0] down_addr,
    output reg  [7:0]  down_data,
    output reg         down_valid,

    // DDR3 port to aux_ram's arbiter (src/aux_ram.v), region 1
    output reg         dsk_go,
    output reg  [21:0] dsk_addr,
    output reg         dsk_we,
    output reg  [15:0] dsk_wdata,
    input  wire [15:0] dsk_rdata,
    input  wire        dsk_ack
);

    reg [1:0] present = 2'b00, writable = 2'b00;
    reg [1:0] is_woz1 = 2'b00;
    assign drv_present  = present;
    assign drv_writable = present & writable;

    // the DDR3 word of a drive's word index
    function [21:0] waddr(input d, input [18:0] w);
        waddr = {2'b00, d, w};
    endfunction

    // ------------------------------------------------------------------
    // Where the head is: the track the lookup found
    // ------------------------------------------------------------------
    reg        lk_drv = 1'b0;          // what it was found for
    reg [7:0]  lk_q   = 8'hFF;
    reg        lk_ok  = 1'b0;          // the lookup is done (and still the head's)
    reg        tv     = 1'b0;          // ...and there is a track
    reg [18:0] t_base = 19'd0;         // its first word
    reg [19:0] t_bits = 20'd0;         // its length in bits
    reg [7:0]  t_idx  = 8'd0;          // TRKS index, during the lookup
    reg [1:0]  lk_st  = 2'd0;          // 0 TMAP, 2 bits lo, 3 bits hi, 1 start
    wire       lk_want = !lk_ok || lk_drv != drive || lk_q != qtr;

    // The bit position, and the word under the head with the next behind it
    reg [19:0] pos  = 20'd0;
    reg [15:0] buf0 = 16'd0, buf1 = 16'd0;
    reg [15:0] w0   = 16'd0, w1   = 16'd0;   // their word indices in the track
    reg        ok0  = 1'b0,  ok1  = 1'b0, dirty0 = 1'b0;
    wire [3:0] bi   = {pos[3], ~pos[2:0]};    // MSB first; the even byte is the low half
    assign rd_ok  = tv && lk_ok && !lk_want && ok0;
    assign rd_bit = buf0[bi];

    wire [19:0] pos_inc = pos + 20'd1;
    wire [19:0] pos_nx  = (pos_inc >= t_bits) ? 20'd0 : pos_inc;
    wire [15:0] w0_inc  = w0 + 16'd1;
    wire [15:0] w0_nx   = ({w0_inc, 4'd0} >= t_bits) ? 16'd0 : w0_inc;  // the word after w0
    wire        wr_now  = bit_tick && wr_en && rd_ok && writable[lk_drv];
    wire [15:0] buf0_wr = wr_now ? (buf0 & ~(16'd1 << bi)) | ({15'd0, wr_bit} << bi) : buf0;

    // A word on its way back to DDR3
    reg        wb_pend = 1'b0;
    reg [21:0] wb_addr = 22'd0;
    reg [15:0] wb_data = 16'd0;
    wire [18:0] w0_word = t_base + {3'd0, w0};

    // ------------------------------------------------------------------
    // The DDR3 engine: one word at a time
    // ------------------------------------------------------------------
    localparam [2:0] K_WB = 3'd0, K_UP = 3'd1, K_DOWN = 3'd2, K_LK = 3'd3, K_F0 = 3'd4, K_F1 = 3'd5;
    reg        busy_q = 1'b0;
    reg [2:0]  kind   = K_WB;
    reg [15:0] f_w    = 16'd0;           // the word a fetch is for
    reg [7:0]  up_hold = 8'd0;
    reg        up_have = 1'b0;
    reg [15:0] dn_word = 16'd0;           // the download's word cache
    reg [19:0] dn_at   = 20'd0;
    reg        dn_ok   = 1'b0;
    wire       dn_hit  = dn_ok && dn_at[19:1] == down_addr[19:1];
    assign     up_busy = busy_q || up_done;

    // the lookup's word: TMAP byte 88 + q is word 44 + q/2;
    // WOZ2: TRKS entry i is words 128 + 4i ..
    // WOZ1: track i is words 128 + 3328*i, bit count at word + 3324
    // Implemented via hardware DSP multiplier (3328 words = 6656 bytes per track)
    wire [18:0] woz1_track_word = 19'd128 + ({11'd0, t_idx} * 19'd3328);
    wire [18:0] lk_word = (lk_st == 2'd0) ? 19'd44 + {12'd0, qtr[7:1]} :
                          is_woz1[lk_drv] ? (woz1_track_word + 19'd3324) :
                          19'd128 + {9'd0, t_idx, 2'b00} + {17'd0, lk_st == 2'd1 ? 2'd0 : lk_st};

    always @(posedge clk) begin
        dsk_go <= 1'b0;
        fl_wr  <= 1'b0;
        if (!up_go)   up_done    <= 1'b0;
        if (!down_go) down_valid <= 1'b0;

        // ---- the head ----
        if (bit_tick && rd_ok) begin
            pos <= pos_nx;
            if (pos_nx[19:4] != pos[19:4]) begin
                // leaving the word: send it back if it was written
                if (dirty0 || wr_now) begin
                    wb_pend <= 1'b1; wb_addr <= waddr(lk_drv, w0_word); wb_data <= buf0_wr;
                    fl_wr <= 1'b1; fl_wr_drv <= lk_drv; fl_wr_blk <= w0_word[18:8];
                end
                dirty0 <= 1'b0;
                if (ok1 && w1 == pos_nx[19:4]) begin buf0 <= buf1; w0 <= w1; ok1 <= 1'b0; end
                else ok0 <= 1'b0;
            end else begin
                buf0 <= buf0_wr;
                if (wr_now) dirty0 <= 1'b1;
            end
        end else if (dirty0 && (!wr_mode || lk_want) && !wb_pend) begin
            // write mode is over (or the head is moving): the word goes back now
            wb_pend <= 1'b1; wb_addr <= waddr(lk_drv, w0_word); wb_data <= buf0;
            fl_wr <= 1'b1; fl_wr_drv <= lk_drv; fl_wr_blk <= w0_word[18:8];
            dirty0 <= 1'b0;
        end

        // a new head position (or a disk in or out) looks the track up again
        if (lk_want && lk_ok && !dirty0) begin
            lk_ok <= 1'b0; ok0 <= 1'b0; ok1 <= 1'b0; lk_st <= 2'd0;
        end

        if (up_bad) begin present[up_drive] <= 1'b0; is_woz1[up_drive] <= 1'b0; up_have <= 1'b0; lk_ok <= 1'b0; lk_st <= 2'd0; ok0 <= 1'b0; ok1 <= 1'b0; end

        if (!busy_q) begin
            if (wb_pend) begin
                busy_q <= 1'b1; kind <= K_WB; dsk_go <= 1'b1; dsk_we <= 1'b1;
                dsk_addr <= wb_addr; dsk_wdata <= wb_data;
            end else if (up_go && !up_done) begin
                // a byte of a file being loaded: two make a word
                up_done <= 1'b1;
                if (up_addr == 20'd3) is_woz1[up_drive] <= (up_data == "1");
                if (up_last) begin
                    present[up_drive] <= 1'b1; writable[up_drive] <= !up_ro;
                    if (up_drive == lk_drv) begin lk_ok <= 1'b0; lk_st <= 2'd0; ok0 <= 1'b0; ok1 <= 1'b0; end
                end
                if (up_have) begin
                    busy_q <= 1'b1; kind <= K_UP; dsk_go <= 1'b1; dsk_we <= 1'b1;
                    dsk_addr  <= waddr(up_drive, up_addr[19:1]);
                    dsk_wdata <= up_addr[0] ? {up_data, up_hold} : {up_hold, up_data};
                    up_have   <= 1'b0;
                    dn_ok     <= 1'b0;
                end else begin
                    up_hold <= up_data; up_have <= 1'b1;
                end
            end else if (down_go && !down_valid && dn_hit) begin
                down_data <= down_addr[0] ? dn_word[15:8] : dn_word[7:0]; down_valid <= 1'b1;
            end else if (down_go && !down_valid) begin
                busy_q <= 1'b1; kind <= K_DOWN; dsk_go <= 1'b1; dsk_we <= 1'b0;
                dsk_addr <= waddr(down_drive, down_addr[19:1]);
            end else if (!lk_ok && !dirty0 && present[drive]) begin
                if (lk_want && (lk_drv != drive || lk_q != qtr)) begin
                    // latch what this lookup is for; a move mid-lookup restarts it
                    lk_drv <= drive; lk_q <= qtr; lk_st <= 2'd0;
                end else begin
                    busy_q <= 1'b1; kind <= K_LK; dsk_go <= 1'b1; dsk_we <= 1'b0;
                    dsk_addr <= waddr(lk_drv, lk_word);
                end
            end else if (!lk_ok && !present[drive]) begin
                // no disk: no track
                lk_drv <= drive; lk_q <= qtr; lk_ok <= 1'b1; tv <= 1'b0;
            end else if (lk_ok && tv && !ok0) begin
                busy_q <= 1'b1; kind <= K_F0; dsk_go <= 1'b1; dsk_we <= 1'b0;
                f_w <= pos[19:4];
                dsk_addr <= waddr(lk_drv, t_base + {3'd0, pos[19:4]});
            end else if (lk_ok && tv && ok0 && !ok1) begin
                busy_q <= 1'b1; kind <= K_F1; dsk_go <= 1'b1; dsk_we <= 1'b0;
                f_w <= w0_nx;
                dsk_addr <= waddr(lk_drv, t_base + {3'd0, w0_nx});
            end
        end else if (dsk_ack) begin
            busy_q <= 1'b0;
            case (kind)
                K_WB:   wb_pend <= 1'b0;
                K_DOWN: begin
                    dn_word <= dsk_rdata; dn_at <= down_addr; dn_ok <= 1'b1;
                    down_data <= down_addr[0] ? dsk_rdata[15:8] : dsk_rdata[7:0]; down_valid <= 1'b1;
                end
                K_LK: if (lk_drv == drive && lk_q == qtr) case (lk_st)
                    2'd0: begin
                        t_idx <= qtr[0] ? dsk_rdata[15:8] : dsk_rdata[7:0];
                        if ((qtr[0] ? dsk_rdata[15:8] : dsk_rdata[7:0]) >= (is_woz1[lk_drv] ? 8'd80 : 8'd160)) begin
                            tv <= 1'b0; lk_ok <= 1'b1;            // 0xFF: no track here
                        end else lk_st <= is_woz1[lk_drv] ? 2'd1 : 2'd2;
                    end
                    2'd2: begin t_bits[15:0] <= dsk_rdata; lk_st <= 2'd3; end
                    2'd3: begin t_bits[19:16] <= dsk_rdata[3:0]; lk_st <= 2'd1;
                                if (dsk_rdata[15:4] != 12'd0) begin tv <= 1'b0; lk_ok <= 1'b1; end end
                    default: begin                                // state 1: start block (WOZ2) or bit count (WOZ1)
                        if (is_woz1[lk_drv]) begin
                            t_bits <= {4'd0, dsk_rdata};
                            t_base <= woz1_track_word;
                            tv     <= (dsk_rdata != 16'd0);
                            lk_ok  <= 1'b1;
                            if (pos >= {4'd0, dsk_rdata}) pos <= 20'd0;
                        end else begin
                            t_base <= {dsk_rdata[10:0], 8'd0};
                            tv     <= t_bits != 20'd0 && dsk_rdata[15:11] == 5'd0;
                            lk_ok  <= 1'b1;
                            if (pos >= t_bits) pos <= 20'd0;          // a shorter track
                        end
                    end
                endcase
                // a fetch the head has moved away from (lk_ok or ok0 cleared) is dropped
                K_F0: if (lk_ok && f_w == pos[19:4]) begin
                    buf0 <= dsk_rdata; w0 <= f_w; ok0 <= 1'b1; ok1 <= 1'b0;
                end
                K_F1: if (lk_ok && ok0 && f_w == w0_nx) begin
                    buf1 <= dsk_rdata; w1 <= f_w; ok1 <= 1'b1;
                end
                default: ;   // K_UP
            endcase
        end

        if (reset) begin
            busy_q <= 1'b0; wb_pend <= 1'b0; up_have <= 1'b0; dn_ok <= 1'b0;
            lk_ok <= 1'b0; ok0 <= 1'b0; ok1 <= 1'b0; dirty0 <= 1'b0; pos <= 20'd0;
            // a reset does not take the disks out: the files are in DDR3
        end
    end

endmodule

`default_nettype wire
