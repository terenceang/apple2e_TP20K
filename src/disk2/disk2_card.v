// Disk II controller card, for slot 6 ($C0E0-$C0EF, $C600-$C6FF).
//
// This is the card side of a Disk ][ controller, at the level the P6 boot ROM
// and DOS/ProDOS RWTS actually drive: the four I/O strobes, a shift register
// the data register reads from and writes to, four stepper phases, a motor and
// a drive select.  It is a slot card in every sense the bus cares about -- it
// decodes /DEVSEL and /IOSEL, answers $C600-$C6FF, and claims $C0E0-$C0EF on
// the read bus -- so a card module like this is what the slot_bus scaffolding
// in src/slot_bus.v was written for.
//
// The drive as a byte stream
// --------------------------
// A real drive produces GCR-encoded bytes (nibbles) at 250 kbit/s, one every
// 32 us: self-sync $FF fields, a $D5 $AA $96 header, then a $D5 $AA $AD data
// field of 343 six-and-two encoded bytes, and so on around the track.  The
// 6502 reads them one at a time from the data register at $C0EE.  That byte
// stream *is* the disk interface: nothing above this card knows what a sector
// is, and copy protection works precisely because software times and samples
// individual bytes and bits.  So the track here is a byte stream that advances
// one byte per 32 us and wraps at the end of the track, and the byte at a
// position is a pure function of that position.
//
// The sector payloads live in SDRAM (src/disk2/disk2_store.v).  This module
// holds the sector under the play head in a 256-byte buffer and six-and-two
// encodes from it on the fly, one encoded byte at a time, so a track never has
// to be resident and the device spends no block RAM on it.
//
// Timing
// ------
// 32 us at ce_1m (1.023 MHz) is 32.7 enables, so the stream advances on every
// 33rd enable (32.26 us) to stay at the real drive's rate.  A sector then
// takes the same number of CPU cycles it would on a //e with a real drive,
// which is what keeps timing-sensitive reads behaving.
//
// The stepper
// ----------
// Four phase lines, each latched by an access to $C0E0-$C0E7, and a head that
// moves one half-track toward whichever neighbouring phase is energised when a
// phase comes on.  DOS moves a track with two such steps and recalibrates with
// 80 steps inward against the stop, so a seek to track N is 2N half-tracks.  The
// head's position is reported in whole tracks, which is all DOS, ProDOS and
// every other filesystem use.  The details are at the stepper below.
//
// Writes
// ------
// With Q7 in write mode a byte written to the data register goes into the
// stream at the current position, and the stream advances exactly as on a
// read.  That is what RWTS needs: it writes a field and reads it back, and
// because the write went into the same stream the read sees, a write is
// immediately readable, exactly as on hardware.  disk2_store.v watches the
// stream and decodes a written data field back into its SDRAM sector, so the
// change survives the write and the next pass over the track returns it.

`default_nettype none

module disk2_card (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        ce_1m,         // 1.023 MHz clock enable

    // Slot bus strobes, from slot_bus (src/slot_bus.v)
    input  wire        devsel_n,      // a $C0E0-$C0EF access is on the bus
    input  wire        iosel_n,       // a $C600-$C6FF access is on the bus
    input  wire        bus_cycle,     // a real access (the core's cpu_go)
    input  wire        cpu_we,        // the 6502 is writing
    input  wire [15:0] addr,
    input  wire [7:0]  cpu_di,        // the 6502's data out
    output wire [7:0]  rom_data,      // this card's byte on the slot ROM bus
    output wire [7:0]  io_data,       // this card's byte on the $C0Ex bus

    // Sector image store (src/disk2/disk2_store.v).  The card synthesises the
    // disk stream itself but holds no part of the image: 6-and-2 needs six
    // reads of a 256-byte sector buffer, which is about 4,400 LUT4 on a design
    // that has 20,736 and was at 48% before the card existed, and a drive's
    // sector is 7,040 bytes around a track that a //e's block RAM cannot hold
    // either.  So the card asks the store for the six-bit value one field
    // position needs and the store works it out from the image, which it has to
    // fetch from SDRAM anyway.  The two halves of 6-and-2 then live on the same
    // side of the port: the store encodes what the card reads and decodes what
    // the card writes.
    //
    // A value is wanted only inside a data field, and it is wanted a whole drive
    // revolution ahead of time: the store takes six SDRAM reads to answer, about
    // 54 clocks, against the 858 a byte of drive time takes.  So the card asks
    // as soon as the play head is anywhere near a field, and holds the answer
    // until the head reaches it.  If the head moves before an answer has
    // arrived -- which is what a seek does -- the byte goes out as $FF, the
    // self-sync byte, and RWTS resyncs on the next field.
    output wire        grp_req,       // the card wants grp_off's value
    output wire [8:0]  grp_off,
    output wire [3:0]  pos_sec,       // where the head is, for the store: the sector 0..15,
    output wire [8:0]  pos_track,     //   the track 0..34 under the head,
    output wire        pos_drive,     //   and the drive (0 = drive 1)
    input  wire [5:0]  grp_val,       // the six-bit value
    input  wire        grp_ack,       // ...and this is it
    output wire        store_wr_seen, // a disk byte entered the stream
    output wire [7:0]  store_wr_byte, // ...and this is it
    output wire        store_wr_data, // ...inside a data field
    output wire [8:0]  store_wr_off,  // where in that field, 0..342
    input  wire [1:0]  store_drv_present, // a drive holds an image
    input  wire [1:0]  store_drv_writable,// ...and it is writable

    // Debugger view of the card
    output wire [6:0]  dbg_track,
    output wire [7:0]  dbg_head,     // quarter-tracks, 0..138
    output wire [4:0]  dbg_playsel,  // the sector the play head is on
    output wire [12:0] dbg_playoff,  // where in it, 0..439
    output wire        dbg_motor,
    output wire        dbg_drive,
    output wire        dbg_any_disk,  // some drive holds an image
    output wire        dbg_need_grp,  // the head is in a field with no value yet
    output wire        dbg_wr_mode    // Q7: 1 = write mode
);

    // The 6-and-2 GCR tables, shared with the store that decodes a written
    // field.  They are functions, so the header goes inside the module.
    `include "src/disk2/gcr_defs.vh"

    // ------------------------------------------------------------------
    // I/O decode: the $C0Ex strobes the P6 ROM uses
    // ------------------------------------------------------------------
    // $C0E0-$C0E7 stepper phases 0-3 (off at the even address, on at the odd), $C0E8/$C0E9 motor off/on,
    // $C0EA/$C0EB drive 1/2 select, $C0EC Q6L, $C0ED Q7L, $C0EE Q6, $C0EF Q7.
    // The strobes are level-sensitive, so a phase is set by a read as readily
    // as by a write.  bus_cycle is the caller's cpu_go, so the debugger poking
    // the bus cannot step the head or turn the motor on.
    // A plain negation, not the case-equality operator: `===` is not
    // synthesizable, and yosys folds a port it thinks it has resolved to a
    // constant and then refuses to elaborate the design around it.  The select
    // lines are driven by the core and by the bench, so an X on one of them
    // would be a bug somewhere else and is worth seeing.
    wire io_sel  = !devsel_n && bus_cycle;
    wire [3:0] io_a = addr[3:0];

    wire phase_hit = io_sel && !io_a[3];   // $C0E0-$C0E7: phase n off at 2n, on at 2n+1
    wire motor_off = io_sel && (io_a == 4'h8);
    wire motor_on  = io_sel && (io_a == 4'h9);
    wire drive1    = io_sel && (io_a == 4'hA);
    wire drive2    = io_sel && (io_a == 4'hB);
    wire q6l_sel   = io_sel && (io_a == 4'hC);   // data register
    wire q7l_sel   = io_sel && (io_a == 4'hD);   // write-mode data register
    wire q6_sel    = io_sel && (io_a == 4'hE);   // read: shift; write: sense
    wire q7_sel    = io_sel && (io_a == 4'hF);   // read/write mode select

    // ------------------------------------------------------------------
    // Drive state: which drive, is the motor on, where is the head
    // ------------------------------------------------------------------
    reg        motor_q = 1'b0;
    reg        drive_q = 1'b0;      // 0 = drive 1
    reg [7:0]  head_q  = 8'd0;     // the track under the head, 0..34
    reg        wr_mode_q = 1'b0;   // Q7: the read/write mode select
    reg        q6_q      = 1'b0;   // Q6: set by $C0ED, cleared by $C0EC
    reg        started    = 1'b0;  // the first tick after reset presents byte 0 without moving on
    reg        rdy_q      = 1'b0;  // a byte has arrived under the head and has not been read
    reg [7:0]  wr_latch   = 8'h00; // the write-mode data register

    localparam [7:0] TRACK_MAX = 8'd34;
    localparam [7:0] VOLUME    = 8'hFE;   // DOS 3.3 volumes are $FE

    // The head position the store and the address field work from.
    wire [5:0] trk = head_q[5:0];

    assign dbg_track  = head_q[6:0];
    assign dbg_head   = head_q;
    assign dbg_motor  = motor_q;
    assign dbg_drive  = drive_q;
    assign dbg_wr_mode= wr_mode_q;

    // The stepper (see the header).
    // Each phase has an off address and
    // an on address, and the head moves one half-track toward the neighbouring
    // phase that is energised when a phase comes on.  DOS moves a track with two
    // such steps (on the next phase, off the previous one, twice), so a seek to
    // track N is 2N half-tracks, and recalibrating is 80 steps inward against
    // the stop.  ph_cur is the phase the head last settled on, which is what
    // makes "next" and "previous" mean anything.
    reg [3:0]  ph_mask  = 4'd0;      // phases currently energised
    reg [1:0]  ph_cur   = 2'd0;
    reg [6:0]  half_q   = 7'd0;      // half-tracks, 0..2*TRACK_MAX

    wire [1:0] ph_n      = io_a[2:1];
    wire [3:0] mask_nx   = io_a[0] ? (ph_mask | (4'd1 << ph_n)) : (ph_mask & ~(4'd1 << ph_n));
    wire       pull_up   = mask_nx[ph_cur + 2'd1];
    wire       pull_dn   = mask_nx[ph_cur - 2'd1];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            motor_q   <= 1'b0;
            drive_q   <= 1'b0;
            head_q    <= 8'd0;
            ph_mask   <= 4'd0;
            ph_cur    <= 2'd0;
            half_q    <= 7'd0;
        end else if (bus_cycle) begin
            if (motor_off)     motor_q <= 1'b0;
            else if (motor_on) motor_q <= 1'b1;
            if (drive1)        drive_q <= 1'b0;
            else if (drive2)   drive_q <= 1'b1;
            if (phase_hit) begin
                ph_mask <= mask_nx;
                if (io_a[0] && pull_up && !pull_dn) begin
                    ph_cur <= ph_cur + 2'd1;
                    if (half_q != {TRACK_MAX[5:0], 1'b0}) begin
                        half_q <= half_q + 1'b1;
                        head_q <= {1'b0, half_q + 7'd1} >> 1;
                    end
                end else if (io_a[0] && pull_dn && !pull_up) begin
                    ph_cur <= ph_cur - 2'd1;
                    if (half_q != 7'd0) begin
                        half_q <= half_q - 1'b1;
                        head_q <= {1'b0, half_q - 7'd1} >> 1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // The track layout
    // ------------------------------------------------------------------
    // The layout, repeated 16 times around the track.  This is the standard
    // DOS 3.3 16-sector interleave: sector number n is at physical position n
    // of the track, which is what a .po (ProDOS order) image stores directly
    // and what disk2_store's interleave map converts a .do (DOS order) image
    // into, so the layout is the same for both.
    //
    //   48 x $FF      self-sync, long enough for RWTS's three-byte sync hunt
    //   D5 AA 96      address mark: header
    //   vol, trk, sec, checksum
    //   DE AA EB      header tail
    //   6 x $FF       self-sync
    //   D5 AA AD      address mark: data
    //   343 bytes     the 256 data bytes, six-and-two encoded
    //   DE AA EB      data tail
    //   23 x $FF      inter-sector gap
    //
    // 48+3+8+3+6+3+343+3+23 = 440 bytes per sector, 7040 per track.
    localparam integer SHIFT_CLKS = 33;   // 32.26 us at ce_1m
    localparam integer OFF_HDR   = 48;
    localparam integer OFF_HCRC  = 51;      // volume, track, sector, checksum,
    localparam integer OFF_HDRT  = 59;      //   4-and-4 encoded: 8 bytes
    localparam integer OFF_GAP2  = 62;
    localparam integer OFF_DMRK  = 68;      // D5 AA AD
    localparam integer OFF_DATA  = 71;
    localparam integer OFF_DTAIL = 71 + `GCR_FIELD_LEN;   // 414
    localparam integer SECT_LEN  = 440;
    localparam integer TRACK_LEN = 16 * SECT_LEN;   // 7040

    reg [12:0] track_pos = 13'd0;          // byte position around the track
    reg [5:0]  shift_cnt = 6'd0;
    wire [12:0] track_nx = (track_pos >= TRACK_LEN - 1) ? 13'd0 : track_pos + 1'b1;

    // Which sector the stream is playing, and where in it: track_pos / 440,
    // as a chain of comparisons (440 is not a power of two, and a real divider
    // would cost a lot of logic for no gain).  These are continuous
    // assignments rather than an always @(*) block: a block only assigns when
    // it is triggered, and a block whose sensitivity is one wide signal read
    // through sixteen comparisons is exactly the shape iverilog sometimes
    // leaves at its initial X.
    wire [4:0] play_sec =
          (track_pos >= 15*SECT_LEN) ? 5'd15 :
          (track_pos >= 14*SECT_LEN) ? 5'd14 :
          (track_pos >= 13*SECT_LEN) ? 5'd13 :
          (track_pos >= 12*SECT_LEN) ? 5'd12 :
          (track_pos >= 11*SECT_LEN) ? 5'd11 :
          (track_pos >= 10*SECT_LEN) ? 5'd10 :
          (track_pos >= 9*SECT_LEN) ? 5'd9 :
          (track_pos >= 8*SECT_LEN) ? 5'd8 :
          (track_pos >= 7*SECT_LEN) ? 5'd7 :
          (track_pos >= 6*SECT_LEN) ? 5'd6 :
          (track_pos >= 5*SECT_LEN) ? 5'd5 :
          (track_pos >= 4*SECT_LEN) ? 5'd4 :
          (track_pos >= 3*SECT_LEN) ? 5'd3 :
          (track_pos >= 2*SECT_LEN) ? 5'd2 :
          (track_pos >= 1*SECT_LEN) ? 5'd1 :
          5'd0;

    wire [12:0] play_off =
          (track_pos >= 15*SECT_LEN) ? track_pos - 15*SECT_LEN :
          (track_pos >= 14*SECT_LEN) ? track_pos - 14*SECT_LEN :
          (track_pos >= 13*SECT_LEN) ? track_pos - 13*SECT_LEN :
          (track_pos >= 12*SECT_LEN) ? track_pos - 12*SECT_LEN :
          (track_pos >= 11*SECT_LEN) ? track_pos - 11*SECT_LEN :
          (track_pos >= 10*SECT_LEN) ? track_pos - 10*SECT_LEN :
          (track_pos >= 9*SECT_LEN) ? track_pos - 9*SECT_LEN :
          (track_pos >= 8*SECT_LEN) ? track_pos - 8*SECT_LEN :
          (track_pos >= 7*SECT_LEN) ? track_pos - 7*SECT_LEN :
          (track_pos >= 6*SECT_LEN) ? track_pos - 6*SECT_LEN :
          (track_pos >= 5*SECT_LEN) ? track_pos - 5*SECT_LEN :
          (track_pos >= 4*SECT_LEN) ? track_pos - 4*SECT_LEN :
          (track_pos >= 3*SECT_LEN) ? track_pos - 3*SECT_LEN :
          (track_pos >= 2*SECT_LEN) ? track_pos - 2*SECT_LEN :
          (track_pos >= 1*SECT_LEN) ? track_pos - 1*SECT_LEN :
          track_pos;

    assign dbg_playsel = play_sec;
    assign dbg_playoff = play_off;

    // Which field of the sector the play head is in.  The offsets are integer
    // parameters, compared against a 13-bit offset; Verilog-2001 has no sized
    // literal with a parameter in it, and the zero-extension is what we want.
    wire in_gap1  = (play_off <  OFF_HDR);
    wire in_hdr   = (play_off >= OFF_HDR)  && (play_off <  OFF_HCRC);
    wire in_hcrc  = (play_off >= OFF_HCRC)  && (play_off <  OFF_HDRT);
    wire in_hdrt  = (play_off >= OFF_HDRT)  && (play_off <  OFF_GAP2);
    wire in_gap2  = (play_off >= OFF_GAP2)  && (play_off <  OFF_DMRK);
    wire in_dmrk  = (play_off >= OFF_DMRK)  && (play_off <  OFF_DATA);
    wire in_data  = (play_off >= OFF_DATA)  && (play_off <  OFF_DTAIL);
    wire in_dtail = (play_off >= OFF_DTAIL) && (play_off <  OFF_DTAIL + 3);

    // The header checksum: volume XOR track XOR sector, the four bytes RWTS
    // compares.
    wire [7:0] hdr_cksum = VOLUME ^ {2'b00, trk} ^ {4'b0000, play_sec};

    // ------------------------------------------------------------------
    // Six-and-two encoding
    // ------------------------------------------------------------------
    // The GCR tables live in src/disk2/gcr_defs.vh, shared with the store that
    // decodes a written field: the two have to agree byte for byte, so there is
    // one copy of each table.  That header documents the field layout.
    //
    // A data field is 343 disk bytes in this order, which is the order RWTS
    // reads them in and not a free choice:
    //
    //   0..85    86 "auxiliary" bytes, six bits each, carrying the low two bits
    //            of three sector bytes apiece -- 258 slots for 256 bytes, and
    //            the two that fall past the end of the sector are the ones
    //            dropped
    //   86..341  256 bytes, the top six bits of the sector bytes in order
    //   342      the checksum
    //
    // Each of those 342 six-bit values goes out as the XOR of itself and the one
    // before it, which is what gives a data field no two bytes alike in a row
    // for the data separator to lock onto, and the last byte carries the 342nd
    // value on its own.  All of that arithmetic is in the store now, which
    // answers a request for one position's value; what is left here is the
    // GCR table and the request.
    //
    // Which byte of the 343-byte data field the play head is on.
    wire [8:0] data_off = play_off - OFF_DATA;

    // Asking the store for the value, and holding it until the head arrives.
    // Six SDRAM reads stand between the request and the answer, so the answer
    // is always for a position the head has left by the time it turns up; it is
    // kept until the head reaches the position it is for.  A head that jumps
    // (a seek) leaves the card with an answer for somewhere else, and until the
    // new one turns up the byte goes out as $FF.
    reg        grp_busy = 1'b0;      // a request is out
    reg [8:0]  grp_want = 9'd0;       // ...for this position
    reg [8:0]  grp_have = 9'h1FF;     // what grp_q is; $1FF is not a position
    reg [5:0]  grp_q    = 6'd0;
    reg [3:0]  grp_hsec = 4'd0;       // ...and where it was fetched from
    reg [5:0]  grp_htrk = 6'd0;
    reg        grp_hdrv = 1'b0;

    // The value in hand is the one for where the head is, in the sector the head
    // is in.  Both halves matter: the same offset of a different sector is a
    // different value, and after a seek back the head arrives at an offset it
    // had a value for two tracks ago.
    wire grp_ok = (grp_have == data_off) && (grp_hsec == play_sec[3:0]) &&
                  (grp_htrk == trk)          && (grp_hdrv == drive_q);

    // What the card wants is what the head is on, and nothing else.  Fetching the
    // position after that as well, so a request is in hand all the way through a
    // field, is what a real drive's phasing does and it is not free here: the
    // answer for the next position turns up long before the head reaches it, and
    // a card holding one value would have thrown away the one the head was still
    // on.  A byte of drive time is 858 clocks and a position is 27, so asking
    // when the head arrives costs nothing and cannot race.
    wire [8:0] grp_ask = (data_off > `GCR_PAR_OFF) ? `GCR_PAR_OFF : data_off;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            grp_busy <= 1'b0;
            grp_want <= 9'd0;
            grp_have <= 9'h1FF;
            grp_q    <= 6'd0;
            grp_hsec <= 4'd0;
            grp_htrk <= 6'd0;
            grp_hdrv <= 1'b0;
        end else if (grp_ack) begin
            grp_busy <= 1'b0;
            grp_have <= grp_want;     // the answer is grp_val, for grp_want
            grp_q    <= grp_val;
            grp_hsec <= play_sec[3:0];
            grp_htrk <= trk;
            grp_hdrv <= drive_q;
        end else if (!grp_busy && in_data && !grp_ok) begin
            grp_busy <= 1'b1;
            grp_want <= grp_ask;
        end
    end

    // The disk byte.  $FF is the self-sync byte, and it is also what the field
    // holds wherever the store has not answered yet: a reader that finds one
    // where it expected data resyncs on the next mark, which is what it is for.
    wire [7:0] v_data = grp_ok ? gcr_encode(grp_q) : 8'hFF;

    // The four address bytes, 4-and-4 encoded: eight disk bytes, in the order
    // RWTS reads them, so the first pair is the volume, the second the track,
    // the third the sector and the fourth the checksum.
    wire [12:0] hcrc_i   = play_off - OFF_HCRC;
    wire [1:0]  hdr_pair = hcrc_i[2:1];
    wire [7:0]  hdr_byte = (hdr_pair == 2'd0) ? VOLUME :
                           (hdr_pair == 2'd1) ? {2'b00, trk} :
                           (hdr_pair == 2'd2) ? {4'b0000, play_sec} :
                                                hdr_cksum;
    wire [7:0]  v_hdr    = hcrc_i[0] ? a44_lo(hdr_byte) : a44_hi(hdr_byte);

    // ------------------------------------------------------------------
    // The synthesized byte at the current position
    // ------------------------------------------------------------------
    reg [7:0] synth_byte;
    always @(*) begin
        if (in_gap1)
            synth_byte = 8'hFF;
        else if (in_hdr)
            synth_byte = (play_off == OFF_HDR)     ? 8'hD5 :
                         (play_off == OFF_HDR + 1) ? 8'hAA : 8'h96;
        else if (in_hcrc)
            synth_byte = v_hdr;
        else if (in_hdrt)
            synth_byte = (play_off == OFF_HDRT)     ? 8'hDE :
                         (play_off == OFF_HDRT + 1) ? 8'hAA : 8'hEB;
        else if (in_gap2)
            synth_byte = 8'hFF;
        else if (in_dmrk)
            synth_byte = (play_off == OFF_DMRK)     ? 8'hD5 :
                         (play_off == OFF_DMRK + 1) ? 8'hAA : 8'hAD;
        else if (in_data)
            synth_byte = v_data;
        else if (in_dtail)
            synth_byte = (play_off == OFF_DTAIL)     ? 8'hDE :
                         (play_off == OFF_DTAIL + 1) ? 8'hAA : 8'hEB;
        else
            synth_byte = 8'hFF;   // inter-sector gap
    end

    // ------------------------------------------------------------------
    // The data register, the shift register, and the write path
    // ------------------------------------------------------------------
    wire q6l_rd = q6l_sel && !cpu_we;
    wire q7_rd  = q7_sel  && !cpu_we;
    wire q7l_rd = q7l_sel && !cpu_we;
    // In read mode the register holds the byte under the head with bit 7 set only
    // while it is fresh, which is what the ROM's LDA/BPL loop polls for.  The
    // byte counts as arrived once the store has answered for it (its field
    // values come out of SDRAM), so a fast poller waits for the data instead of
    // reading $FF where the field should be.
    wire       byte_ok = rdy_q && (!in_data || grp_ok);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            track_pos <= 13'd0;
            started   <= 1'b0;
            shift_cnt <= 6'd0;
            wr_mode_q <= 1'b0;
            q6_q      <= 1'b0;
            wr_latch  <= 8'h00;
            rdy_q     <= 1'b0;
        end else begin
            if (q6l_sel)          q6_q      <= 1'b0;   // $C0EC: Q6 low
            if (q7l_sel)          q6_q      <= 1'b1;   // $C0ED: Q6 high
            if (q7_rd)            wr_mode_q <= 1'b0;   // $C0EF read: read mode
            if (q7_sel && cpu_we) wr_mode_q <= 1'b1;   // $C0EF write: write mode
            if (q6l_sel && cpu_we) wr_latch <= cpu_di;  // preload a write byte

            // The stream advances on the shift tick while the motor is on...
            if (motor_q && ce_1m) begin
                if (shift_cnt >= SHIFT_CLKS - 1) begin
                    shift_cnt <= 6'd0;
                    rdy_q     <= 1'b1;          // a new byte is under the head
                    started   <= 1'b1;
                    if (started) track_pos <= track_nx;
                end else begin
                    shift_cnt <= shift_cnt + 1'b1;
                end
            end

            // A read of the data register takes the byte; the next one is not there
            // until the head reaches it.  Reads never move the head: a real drive
            // hands the CPU one byte per 32 us however fast it polls, and a card
            // that stepped on every read would run the stream several times too
            // fast for the store to keep up (the store answers a position in ~54
            // clocks of the 858 the head spends on it).
            if (!wr_mode_q && q6l_rd && byte_ok) rdy_q <= 1'b0;

            if (wr_mode_q) begin
                // Write mode: Q7L shifts the latched byte into the stream.
                if (q7l_rd) track_pos <= track_nx;
            end
        end
    end

    // A byte entered the stream in write mode, for the store to decode.  The
    // store uses this to catch a written data field as it passes, and needs to
    // know where in the field the byte landed, because a data field is
    // six-and-two encoded and a sector is only assembled once all 256 values
    // have been seen.
    assign store_wr_seen  = wr_mode_q && q7l_rd;
    assign store_wr_byte  = wr_latch;
    assign store_wr_data  = in_data;
    assign store_wr_off   = data_off;

    // The data register.  In read mode it is the shift register.  With Q6 high
    // and Q7 low (LDA $C08D,X then LDA $C08E,X, which is how DOS and ProDOS
    // check) a read of it is the write-protect sense, bit 7 set when protected;
    // a drive with no image behind it (or a read-only one) reports protected.
    // In write mode a read gives the same.
    wire wr_protected = !store_drv_writable[drive_q];
    wire sense_wp     = wr_mode_q || q6_q;
    wire [7:0] rd_byte = byte_ok ? synth_byte : {1'b0, synth_byte[6:0]};
    wire [7:0] data_rd = sense_wp ? (wr_protected ? 8'h80 : 8'h00) : rd_byte;

    // What the card drives onto $C0E0-$C0EF: the data register at Q6L and Q6,
    // and the floating bus at the rest of the window.
    assign io_data = (io_sel && (io_a == 4'hC || io_a == 4'hE)) ? data_rd : 8'h00;

    // ------------------------------------------------------------------
    // The group request, and the rest of the card's wiring
    // ------------------------------------------------------------------
    assign grp_req   = grp_busy;
    assign grp_off   = grp_want;
    assign pos_sec   = play_sec[3:0];
    assign pos_track = {3'd0, trk};
    assign pos_drive = drive_q;
    assign dbg_any_disk  = store_drv_present[0] || store_drv_present[1];
    // "The card does not have the value for where the head is".  A real drive
    // streams a byte every 32 us and is never caught out, but the bench walks
    // the track a byte at a time to keep 227 ms of drive time out of the
    // simulation, and at that rate it has to wait for the store the way the
    // drive's own rate would have made it wait.
    assign dbg_need_grp = in_data && (grp_have != data_off);

    // ------------------------------------------------------------------
    // The $C600-$C6FF boot ROM
    // ------------------------------------------------------------------
    // The P6 boot ROM is Apple copyright and is supplied in roms/, like the
    // //e's own ROMs; see roms/README.md.  With INTCXROM on (the reset
    // default) the //e's internal ROM at $C600 boots a Disk II by itself; this
    // copy answers $C600 when the card's ROM is selected instead, which is
    // what a real Disk II card carries and what the ROM's own checksum test at
    // $C608 expects to find.
    reg [7:0] p6_rom [0:255];
    reg [7:0] p6_dout = 8'h00;
    // A simulation build has no Apple ROM (roms/ is not distributed, see
    // roms/README.md), and nothing needs one here: the //e's internal ROM at
    // $C600 is what boots a Disk ][ by default, with INTCXROM on, and the
    // card's own $C600-$C6FF answer is only what a build with INTCXROM off
    // sees.  The card's ROM path is the slot bus's to check, not this card's,
    // so the bench leaves it zeroed -- the same arrangement tb_video_hdmi uses
    // for the character ROM, so nothing in simulation depends on a real disk
    // boot ROM being present.
    //
    // A synthesis build reads the real thing, and scripts/build.ps1 defines
    // DSK2_NO_P6_ROM when roms/disk2_p6.hex is not there, because $readmemh on a
    // missing file stops the build outright and a fresh clone has to build.
`ifdef DSK2_NO_P6_ROM
    integer pi6;
    initial begin
        for (pi6 = 0; pi6 < 256; pi6 = pi6 + 1) p6_rom[pi6] = 8'h00;
    end
`else
    initial begin
        $readmemh("roms/disk2_p6.hex", p6_rom);
    end
`endif
    // Latched every clock, not only under /IOSEL: the strobe is one clock wide (cpu_go)
    // and the CPU samples on that same edge, so a read gated by it returns the last access.
    always @(posedge clk) p6_dout <= p6_rom[addr[7:0]];
    assign rom_data = !iosel_n ? p6_dout : 8'h00;

endmodule

`default_nettype wire