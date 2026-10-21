// Disk ][ image store: where the floppy's sectors live, and the path to them.
//
// The card (src/disk2/disk2_card.v) works in disk bytes and never in sectors,
// and it cannot afford to hold a track: 7040 disk bytes would be four block
// RAMs on a device that already spends 42 of 46.  So the card asks this module
// for one sector at a time, and this module keeps the images in the board's
// SDRAM, where there are 8 MB and the aux RAM's 64 KB is all that is otherwise
// used.
//
// Where in SDRAM
// --------------
// The images live in bank 1 (the controller's addr[21:20] = 01), which the aux
// RAM never touches -- aux RAM is bank 0, rows 0..63.  Inside a bank, a byte
// address splits into a row, a column and one of the two halves of a 16-bit
// word, exactly as aux_ram.v does it, and a sector is 256 bytes = 128 words.
//
//   drive 0, byte 0      = track 0, sector 0, byte 0
//   drive 1, byte 143360 = track 0, sector 0, byte 0
//
// 35 tracks x 16 sectors x 256 bytes = 143,360 bytes per drive and 286,720 for
// both, which is 140 KB out of bank 1's 2 MB.  Two drives, one card.
//
// All four clients move whole 16-bit words, never single bytes: the SDRAM
// controller hands back a full word on a read and takes a full word on a write,
// and a sector is an even number of bytes, so pairing is free and there is one
// path through the engine instead of two.
//
// Sector interleave
// -----------------
// The card lays a track out as 16 sectors at positions 0..15, which is the
// ProDOS (.po) order: sector n at position n.  A DOS order (.do) image stores
// its sectors in the interleave DOS's own RWTS uses, so the host is asked to
// hand over images already in the order the card wants (web/src/disk.js does
// that conversion, because a browser is a far better place for an interleave
// table than this module).  What arrives here is therefore plain physical
// order and this module stays format-agnostic.
//
// The write path
// --------------
// When DOS writes, the card reports each disk byte that enters the stream along
// with where in the data field it landed.  This module decodes the field with
// the tables the card encodes with (src/disk2/gcr_defs.vh, shared, so the two
// cannot drift), and when the field ends it writes the 256 bytes back.  That is
// comfortably in time: a data field is 343 disk bytes, about 11 ms of drive
// time, and writing the 128 words is about 40 us.  The card's next fetch of
// that sector therefore already returns the new data, which is what makes
// RWTS's write-then-read-back verify pass.

`default_nettype none

module disk2_store (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset

    // The card's data-field port.  The card synthesises the disk stream itself
    // but it cannot hold a sector: the 6-and-2 encoding needs six reads of one,
    // and a 256-byte buffer with six read addresses is about 4,400 LUT4 on a
    // design that has 20,736 and was at 48% before the card existed.  So the card
    // asks for the six-bit *value* one field position needs and this module
    // works it out from the image, which it has to fetch from SDRAM anyway.  The
    // two halves of 6-and-2 then live on the same side of the port: this module
    // encodes what the card reads and decodes what the card writes.
    //
    // The request names the field offset 0..342; the sector it belongs to is
    // the head position below, latched with it because the play head can move on
    // while the answer is being fetched.
    input  wire        grp_req,       // the card wants grp_off's value
    input  wire [8:0]  grp_off,
    output reg  [5:0]  grp_val,       // the six-bit value
    output reg         grp_ack,       // ...and this is it

    // The card's write-capture port: a disk byte entered the stream, and where
    // in the data field it landed.  The card is the only thing that knows the
    // play position, so it reports it.
    input  wire        wr_seen,
    input  wire [7:0]  wr_byte,
    input  wire        wr_in_data,    // ...inside a data field
    input  wire [8:0]  wr_off,        // where in that field, 0..342

    // Where the head is: the sector, track and drive both ports above refer to
    input  wire [3:0]  pos_sec,
    input  wire [8:0]  pos_track,
    input  wire        pos_drive,
    output wire [1:0]  drv_present,   // a drive holds an image
    output wire [1:0]  drv_writable,  // ...and it is writable

    // The debugger's bulk transfer port (src/serial_debugger.v), one byte at a
    // time because that is all the UART carries.  Addresses are byte offsets
    // within the drive's image, 0..143359.
    input  wire        up_go,         // take up_data at up_addr
    input  wire        up_drive,
    input  wire [17:0] up_addr,
    input  wire [7:0]  up_data,
    input  wire        up_last,       // this is the drive's last byte
    input  wire        up_bad,        // ...or it was not, and the drive is not
    output wire        up_busy,       // the store is holding this byte
    output reg         up_done,       // ...and has taken it
    input  wire        down_go,       // serve the byte at down_addr
    input  wire        down_drive,
    input  wire [17:0] down_addr,     // a byte offset, 0..143359
    input  wire        down_last,     // ...and this is the last one
    output reg  [7:0]  down_data,
    output reg         down_valid,    // down_data is good
    output reg         down_done,     // down_last and it has been served

    // SDRAM port to aux_ram's arbiter (src/aux_ram.v), lowest priority
    output reg         dsk_go,        // request a slot; addr/we/wdata are set
    output reg  [21:0] dsk_addr,
    output reg         dsk_we,
    output reg  [15:0] dsk_wdata,
    input  wire [15:0] dsk_rdata,     // valid with dsk_ack on a read
    input  wire        dsk_ack,       // the slot finished
    input  wire        dsk_idle       // the arbiter is free
);

    // The GCR tables, shared with the card that encodes with them.  Functions,
    // so the header goes inside the module.
    `include "src/disk2/gcr_defs.vh"

    localparam integer SEC_BYTES  = 256;
    localparam integer NTRACKS    = 35;
    localparam integer DRIVE_BYTES = NTRACKS * 16 * SEC_BYTES;   // 143,360

    // Byte address of a drive's image within the store's bank.
    function [18:0] drv_base(input drv);
        drv_base = drv ? DRIVE_BYTES : 0;
    endfunction

    // Whether a drive holds an image.  Until one is uploaded a drive reads as
    // empty, which is what makes the card report it write protected: a format
    // goes nowhere rather than into unwritten memory.
    reg present [0:1];
    reg writable_q [0:1];
    integer di;
    initial begin
        for (di = 0; di < 2; di = di + 1) begin
            present[di]    = 1'b0;
            writable_q[di] = 1'b0;
        end
    end
    assign drv_present[0]  = present[0];
    assign drv_present[1]  = present[1];
    assign drv_writable[0] = present[0] && writable_q[0];
    assign drv_writable[1] = present[1] && writable_q[1];

    // ------------------------------------------------------------------
    // The SDRAM engine
    // ------------------------------------------------------------------
    // One word transaction at a time.  A request is picked at S_IDLE and
    // issued; the slot's completion arrives as dsk_ack, and a read then serves
    // the byte the client asked for straight out of the data that came back.
    // The card's fetch caches the word it has in hand so the second byte of a
    // pair costs nothing, but the cache is an optimisation only: losing it
    // would slow the fill, not break it.
    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_WAIT  = 3'd1;   // a slot is in flight

    localparam [2:0] K_NONE = 3'd0;
    localparam [2:0] K_FILL = 3'd1;   // the card's group fetch, reading
    localparam [2:0] K_WRT  = 3'd2;   // a written sector, writing
    localparam [2:0] K_UP   = 3'd3;   // the debugger's upload, writing
    localparam [2:0] K_DOWN = 3'd4;   // the debugger's download, reading

    reg [2:0]  state = S_IDLE;
    reg [2:0]  kind  = K_NONE;
    reg [15:0] sec_data_q  = 16'd0;    // the word in hand ...
    reg [18:0] sec_addr_q  = 19'd0;    // ... and where in a drive it came from,
    reg        sec_hit_ok  = 1'b0;     // which is the only thing a cache can
                                       // usefully remember
    reg        want_low = 1'b0;        // which half the card asked for

    // ------------------------------------------------------------------
    // The card's group fetch
    // ------------------------------------------------------------------
    // A field position's value is the XOR of two six-bit groups, and each group
    // is built from up to three sector bytes: below 86 an auxiliary byte carries
    // the low two bits of sector bytes 172+k, 86+k and k, and from 86 on it is
    // one sector byte's top six.  So the two groups of a position need at most
    // six sector bytes, and they are fetched one at a time -- a byte the word
    // cache already holds costs nothing, and the two bytes of a source are
    // adjacent, so the second is nearly always the one just fetched.
    //
    // A position's group has at most three sources, one per step (g_step 0..2);
    // the XOR with the position before uses the group kept in g_prevgrp, so the
    // previous position's sources are not fetched again.
    localparam [2:0] G_DONE     = 3'd6;   // no request in flight
    localparam [2:0] G_LAST_AUX = 3'd2;   // an auxiliary group: steps 0, 1, 2
    localparam [2:0] G_LAST_DAT = 3'd0;   // a data group: step 0 only

    reg [8:0]  g_want = 9'd0;          // the offset in flight
    reg [3:0]  g_wsec = 4'd0;          // ...and the sector it was asked about
    reg [8:0]  g_wtrk = 9'd0;
    reg        g_wdrv = 1'b0;
    reg [2:0]  g_step = G_DONE;         // which byte is next
    reg [7:0]  g_b0 = 8'd0, g_b1 = 8'd0, g_b2 = 8'd0;
    reg        g_run = 1'b0;           // a request is being served
    reg [5:0]  g_prevgrp = 6'd0;      // the group the position before was made of

    // A position is made of three pairs of low bits in the first 86 of a field,
    // of one byte's top six in the next 256, and of the last of those again for
    // the checksum.  So it takes up to three reads and never more, and the two
    // that would fall past the end of the sector are the ones 6-and-2 drops:
    // 172+85 is 257, so the first pair of the 86th group is zeros, and they come
    // out of this as zeros rather than as sector byte 0 or 1 wrapped round.
    wire       g_aux = (g_want < `GCR_AUX_N);
    wire       g_par = (g_want == `GCR_PAR_OFF);

    // A data position is one sector byte's top six, and its number in the
    // sector is its position in the field less the 86 that came before it.  The
    // checksum is the last of those again, so it is byte 255's top six.
    wire [8:0] g_addr = g_aux ? gcr_aux_src(g_step[1:0], g_want)
                      : g_par ? 9'd255 : (g_want - `GCR_DATA_OFF);
    wire [2:0] g_last = g_aux ? G_LAST_AUX : G_LAST_DAT;
    wire       g_need = (g_step <= g_last) && (g_addr < SEC_BYTES);

    // The word that byte is in, as a byte address in a drive, and which half of
    // it the byte is.
    wire [18:0] g_waddr = drv_base(g_wdrv) + {1'b0, g_wtrk[5:0], g_wsec, g_addr[7:0]};
    wire [18:0] g_even  = {g_waddr[18:1], 1'b0};
    wire        g_low   = ~g_addr[0];

    // A group: the low two bits of three sector bytes (transposed, see
    // gcr_pair_swap), or a sector byte's top six.
    wire [5:0] g_grp = g_aux ? {gcr_pair_swap(g_b0[1:0]), gcr_pair_swap(g_b1[1:0]),
                                gcr_pair_swap(g_b2[1:0])} : g_b0[7:2];

    // 6-and-2 writes each position as its own group XORed with the group
    // before it, and the first position and the checksum are their own groups
    // with nothing done to them.  What matters here is that the thing the XOR
    // chain runs through is the *group*: at the 86th position the group before
    // is an auxiliary group of three pairs, not a data byte's top six, so
    // keeping the previous group's six bits is both simpler and the only thing
    // that survives that boundary.  A real RWTS undoes this by XORing the disk
    // bytes as it reads them, which telescopes to the group at each position
    // whichever of the two chains a field was written with.
    wire [5:0] g_val = (g_want == 9'd0 || g_par) ? g_grp : (g_grp ^ g_prevgrp);

    // The SDRAM address for a byte address in a drive.  The controller splits
    // it as addr[21:20] = bank, addr[19:9] = row, addr[8:1] = column and addr[0]
    // = which 16-bit half, which is how aux_ram.v addresses it: the byte
    // address sits in bits [19:1] with bit 0 clear, so one byte address per
    // column position and both halves of a word at once.  Bank 1, which aux RAM
    // never touches, so the two drives live alone in it -- 143,360 bytes is a
    // 19-bit address and two of them fit with room to spare, and 19 bits is
    // even, so the bank's low bit is the zero that the top of this puts in
    // place of byte address bit 19.  Both halves of that are easy to get wrong
    // and wrong in ways that still look plausible: a byte address one bit too
    // low asks for the neighbouring word, and 2'b01 landing at bits [20:19]
    // instead of [21:20] asks bank 0, which is the aux RAM this store shares
    // the chip with.
    function [21:0] sd_word_addr(input [18:0] byte_even);
        begin
            sd_word_addr = {2'b01, 1'b0, byte_even[18:1], 1'b0};
        end
    endfunction

    // The written sector, in pieces.  A data field's 343 disk bytes decode to
    // 256 sector bytes; see src/disk2/gcr_defs.vh for the layout.  The order
    // that layout comes in is what makes this cheap: the low two bits of all
    // 256 bytes arrive first (in the 86 auxiliary bytes) and the top six bits
    // after (in the 256 data bytes), so the two halves of a byte are never in
    // hand at the same time until its partner byte's data byte arrives.
    //
    // So the low two bits go in wr_lo -- 256 two-bit entries, 512 flip-flops and
    // one two-bit read -- and each *word* is written back to SDRAM as soon as
    // its second byte's top six bits turn up.  A whole 256-byte buffer with two
    // read addresses, which is what holding the sector and writing it back
    // afterwards needs, costs two eight-bit 256-to-1 muxes: about 4,000 LUT4,
    // on a design that has 20,736 and was already at 48% before the card
    // existed.  343 disk bytes take 11 ms of drive time and the 128 words take
    // 40 us, so streaming them out is not a timing question at all.
    reg [1:0]  wr_lo  [0:255];
    reg [5:0]  wr_top = 6'd0;        // the top six of the odd-numbered partner
    reg [15:0] wr_wd_data = 16'd0;    // a word waiting to go to SDRAM
    reg [18:0] wr_wd_ba   = 19'd0;
    reg        wr_wq      = 1'b0;    // ...and this says there is one

    // The debugger's pairs: two bytes make a word, and the second one waits.
    reg [7:0]  up_hold  = 8'h00;
    reg        up_have  = 1'b0;

    // The upload is told which drive and which byte it is on, every byte, rather
    // than being given a start and left to count: the debugger drives both and
    // holds them for a whole transfer, and a store that counted would have to be
    // primed from somewhere and would keep counting through a second transfer
    // into the first one's place.
    wire [18:0] ba_up   = drv_base(up_drive)   + {up_addr[17:1], 1'b0};
    wire [18:0] ba_dn   = drv_base(down_drive) + {down_addr[17:1], 1'b0};
    wire        up_low  = ~up_addr[0];

    // Whether the download's word is the one in hand, so a download that walks
    // forward costs one SDRAM read per pair of bytes.  Which half the debugger
    // asked for is its byte address's low bit, the other way round from the
    // card's: byte n of the image is the low half of word n/2.
    wire        dn_low   = ~down_addr[0];
    wire        dn_hit   = sec_hit_ok && (sec_addr_q == ba_dn);

    // The engine is carrying a captured word to SDRAM: it took it (on the ack of
    // its write) and is finished with it, which is when the capture below may
    // queue the next one.  Reading the engine's state rather than having the
    // engine clear the capture's flag keeps one owner per register.
    wire        wr_taken = (state == S_WAIT) && (kind == K_WRT) && dsk_ack;
    assign      up_busy  = (state != S_IDLE) || up_done;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= S_IDLE;
            kind           <= K_NONE;
            dsk_go         <= 1'b0;
            dsk_we         <= 1'b0;
            dsk_wdata      <= 16'd0;
            dsk_addr       <= 22'd0;
            up_done        <= 1'b0;
            down_valid     <= 1'b0;
            down_done      <= 1'b0;
            up_have        <= 1'b0;
            up_hold        <= 8'd0;
            sec_data_q     <= 16'd0;
            sec_addr_q     <= 19'd0;
            sec_hit_ok     <= 1'b0;
            want_low       <= 1'b0;
            // A reset does not take the disks out: the images are in DDR3,
            // which keeps them, so a drive changes only on an upload or an
            // eject (up_bad).  present[] starts empty at configuration.
        end else begin
            if (up_bad) begin
                present[up_drive]    <= 1'b0;
                writable_q[up_drive] <= 1'b0;
                up_have              <= 1'b0;
            end
            dsk_go     <= 1'b0;
            if (!up_go)   up_done    <= 1'b0;
            if (!down_go) down_valid <= 1'b0;
            down_done  <= 1'b0;
            grp_ack    <= 1'b0;
            if (grp_ack) g_run <= 1'b0;
            // A request is taken when it is new, and "new" has to mean *newer
            // than the one being answered*: the card holds its request up until
            // the answer comes, and raises the next one in the same clock cycle
            // it drops this one, so a store that took whatever was on the
            // request line at the moment it answered would take the request it
            // had just served and answer it twice -- which is a field that is
            // one byte behind for its whole length.
            if (grp_req && !g_run && !grp_ack) begin
                // A request starts here and is answered six bytes later.  The
                // sector it names is latched with it: the play head can move
                // on while the answer is being fetched, and the answer is only
                // useful for the sector that was asked about.  The bytes are
                // cleared because the steps that want nothing are the ones whose
                // value is zero.
                g_want <= grp_off;
                g_wsec <= pos_sec;
                g_wtrk <= pos_track;
                g_wdrv <= pos_drive;
                g_step <= 3'd0;
                g_run  <= 1'b1;
                g_b0   <= 8'd0; g_b1 <= 8'd0; g_b2 <= 8'd0;
            end

            case (state)
                // ------------------------------------------------------
                S_IDLE: begin
                    if (wr_wq) begin
                        // A captured word, over the top of everything else: a
                        // word that misses its slot is a sector that is not
                        // written, while a slow upload is only a slow upload.
                        dsk_we    <= 1'b1;
                        dsk_wdata <= wr_wd_data;
                        dsk_addr  <= sd_word_addr(wr_wd_ba);
                        kind      <= K_WRT;
                        state     <= S_WAIT;
                        dsk_go    <= 1'b1;
                    end else if (up_go && !up_done) begin
                        // The debugger is handing over a byte: prioritized over
                        // background group fetches so host bytes are never starved or dropped.
                        up_done <= 1'b1;
                        if (up_last) begin
                            present[up_drive]    <= 1'b1;
                            writable_q[up_drive] <= 1'b1;
                        end
                        if (up_have) begin
                            dsk_we    <= 1'b1;
                            dsk_wdata <= up_low ? {up_hold, up_data}
                                                : {up_data, up_hold};
                            dsk_addr  <= sd_word_addr(ba_up);
                            kind      <= K_UP;
                            state     <= S_WAIT;
                            dsk_go    <= 1'b1;
                            up_have   <= 1'b0;
                        end else begin
                            up_hold <= up_data;
                            up_have <= 1'b1;
                        end
                    end else if (down_go && !down_valid && dn_hit) begin
                        down_data  <= dn_low ? sec_data_q[7:0] : sec_data_q[15:8];
                        down_valid <= 1'b1;
                        if (down_last) down_done <= 1'b1;
                    end else if (down_go && !down_valid) begin
                        dsk_we   <= 1'b0;
                        dsk_addr <= sd_word_addr(ba_dn);
                        kind     <= K_DOWN;
                        state    <= S_WAIT;
                        dsk_go   <= 1'b1;
                    end else if (g_run && g_need) begin
                        dsk_we   <= 1'b0;
                        dsk_addr <= sd_word_addr(g_even);
                        kind     <= K_FILL;
                        want_low <= g_low;
                        state    <= S_WAIT;
                        dsk_go   <= 1'b1;
                    end else if (g_run && (g_step <= g_last)) begin
                        g_step <= g_step + 3'd1;
                    end else if (g_run) begin
                        grp_val <= g_val;
                        grp_ack <= 1'b1;
                        g_prevgrp <= g_grp; // the next position XORs with this
                        g_run   <= 1'b0;
                    end
                end

                // ------------------------------------------------------
                S_WAIT: if (dsk_ack) begin
                    case (kind)
                        K_FILL: begin
                            // A group byte has landed.  The cache is kept for
                            // the download, which does walk word by word; the
                            // group's own six reads are not close enough
                            // together for it to be worth much.
                            sec_data_q     <= dsk_rdata;
                            sec_addr_q     <= g_even;
                            sec_hit_ok     <= 1'b1;
                            case (g_step)
                                3'd0:    g_b0 <= want_low ? dsk_rdata[7:0]
                                                        : dsk_rdata[15:8];
                                3'd1:    g_b1 <= want_low ? dsk_rdata[7:0]
                                                        : dsk_rdata[15:8];
                                default: g_b2 <= want_low ? dsk_rdata[7:0]
                                                        : dsk_rdata[15:8];
                            endcase
                            g_step <= g_step + 3'd1;
                            state  <= S_IDLE;
                        end
                        K_DOWN: begin
                            // The same cache, so a download that walks forward
                            // costs one SDRAM read per pair of bytes like the
                            // card's fill.  It is keyed on the download's own
                            // address: the two share a word only by accident.
                            sec_data_q     <= dsk_rdata;
                            sec_addr_q     <= ba_dn;
                            sec_hit_ok     <= 1'b1;
                            down_data      <= dn_low ? dsk_rdata[7:0]
                                                     : dsk_rdata[15:8];
                            down_valid     <= 1'b1;
                            if (down_last) down_done <= 1'b1;
                            state          <= S_IDLE;
                        end
                        K_UP: begin
                            // The word is in.  The byte itself was acknowledged
                            // when it was taken, not here: the debugger moves
                            // one byte at a time and a handshake that only came
                            // back every second byte would leave it waiting for
                            // the first one to be taken before it could offer the
                            // second.
                            state   <= S_IDLE;
                        end
                        K_WRT: begin
                            // One word per write, queued by the capture; the
                            // capture clears wr_wq when it sees this ack.
                            state <= S_IDLE;
                        end
                        default: state <= S_IDLE;
                    endcase
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // The write capture
    // ------------------------------------------------------------------
    // The card reports each disk byte of a written data field as it enters the
    // stream, and where in the field it landed.  The field is decoded here, in
    // order, exactly as the card encodes it (see the layout in gcr_defs.vh and
    // the card's six-and-two section):
    //
    //   0..85    six bits holding the low two bits of sector bytes 172+k, 86+k
    //            and k, each pair reversed, so each is put back the other way up
    //   86..341  the top six bits of sector byte k-86
    //   342      the checksum, which only says the field has ended
    //
    // Every one of the 342 six-bit values is the XOR of itself and the one
    // before it, so the decode is a running XOR with one register of state --
    // which is why the field can be decoded as it streams past instead of
    // needing all 343 bytes at once.
    //
    // The low two bits of a sector byte arrive first (the aux bytes come before
    // the data bytes) and the top six after, so the two halves of a byte are in
    // hand at different times and each is kept where it is needed: the low two
    // bits in wr_lo, and the top six of a byte in wr_top until its partner byte
    // completes the word.
    reg [5:0] wr_val;
    reg [5:0] wr_cur;
    reg [5:0] wr_prev = 6'd0;
    reg [8:0] wr_a, wr_b, wr_c;
    reg [8:0] wr_d;

    always @(*) begin
        wr_val = gcr_decode(wr_byte);
        // The XOR chain: the first byte of the field has nothing before it.
        wr_cur = (wr_off == 9'd0) ? wr_val : (wr_val ^ wr_prev);
        // Defaults for the four, so the unused ones do not infer a latch: an
        // address past the end of the sector is not a thing that happens, but a
        // latch on it is a thing yosys will build and a simulation will not
        // show.
        wr_a = 9'd0;
        wr_b = 9'd0;
        wr_c = 9'd0;
        wr_d = 9'd0;
        if (wr_off < `GCR_AUX_N) begin
            wr_a = gcr_aux_src(2'd0, wr_off);
            wr_b = gcr_aux_src(2'd1, wr_off);
            wr_c = gcr_aux_src(2'd2, wr_off);
        end else if (wr_off < `GCR_PAR_OFF) begin
            wr_d = wr_off - `GCR_DATA_OFF;
        end
    end

    // Where the word that sector bytes n-1 and n make lives, as a byte address
    // in a drive.  A sector is 16 sectors of 256 bytes and a track is 16 of
    // those, so the whole thing is shifts, and the byte index is even because a
    // word always starts on an even byte.
    wire [18:0] wr_sector = drv_base(pos_drive) + {pos_track[5:0], pos_sec, 8'd0};

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            wr_wq      <= 1'b0;
            wr_top     <= 6'd0;
            wr_prev    <= 6'd0;
        end else begin
            // The engine has carried the queued word to SDRAM, so the slot is
            // free.  (The engine does not clear this itself: a register written
            // from two always blocks is a multiple-driver net, which simulation
            // resolves to "last write wins" and synthesis to a constant.)
            if (wr_wq && wr_taken) wr_wq <= 1'b0;
            if (wr_seen && wr_in_data) begin
                wr_prev <= wr_cur;
                if (wr_off < `GCR_AUX_N) begin
                    // The two groups that would land past sector byte 255 are the
                    // two the encoding drops, and they arrive as zeros, so they
                    // are left out rather than wrapped onto byte 0.
                    if (wr_a < SEC_BYTES) wr_lo[wr_a[7:0]] <= gcr_pair_swap(wr_cur[5:4]);
                    wr_lo[wr_b[7:0]] <= gcr_pair_swap(wr_cur[3:2]);
                    wr_lo[wr_c[7:0]] <= gcr_pair_swap(wr_cur[1:0]);
                end else if (wr_off < `GCR_PAR_OFF) begin
                    if (wr_d[0] == 1'b0) begin
                        // The low half of the word: wait for its partner.
                        wr_top <= wr_cur;
                    end else begin
                        // The high half, so the word is whole: queue it.  The
                        // low two bits of both bytes came with the auxiliary
                        // bytes, long before this point.
                        wr_wd_data <= {wr_cur,       wr_lo[wr_d[7:0]],
                                       wr_top,       wr_lo[wr_d[7:0] - 8'd1]};
                        wr_wd_ba   <= wr_sector + {1'b0, wr_d} - 19'd1;
                        wr_wq      <= 1'b1;
                    end
                end
                // The checksum byte that ends the field needs nothing: the
                // sector is already in SDRAM, word by word, and RWTS does not
                // check the checksum either -- it is there for the data
                // separator.
            end
        end
    end
endmodule

`default_nettype wire
