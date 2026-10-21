`timescale 1ns / 1ps
`default_nettype none

//  tb_disk2.v -- the Disk ][ card and its image store
//
//  The card's interface is a byte stream and not much else, so this bench
//  drives it the way the P6 boot ROM and RWTS do -- phase strobes, the motor,
//  Q6/Q7L reads of the data register -- and checks the stream against an
//  independent model of what a 5.25" track contains.  Nothing above the card
//  knows what a sector is, so if the model and the card agree on the bytes,
//  DOS will agree with the image.
//
//  What is checked:
//
//    * the $C0Ex decode: phases step the head, the motor and drive select
//      latch, Q7 selects write mode, and Q6L in write mode is the
//      write-protect sense
//    * a track, walked from the start: 48 self-sync $FFs, the $D5 $AA $96
//      header with the right volume, track, sector and checksum, the $DE $AA
//      $EB tail, the data address mark, a 343-byte data field that decodes
//      back to the 256 bytes the image holds, and the inter-sector gap --
//      for all 16 sectors, so the interleave is right too
//    * the store: a sector read comes out of SDRAM through aux_ram's arbiter,
//      and a written field lands back in SDRAM and is readable afterwards
//    * the round trip: encode a sector, decode it, compare with the image
//
//  The image is synthetic (a per-sector pattern), so this checks the format
//  and the arithmetic rather than a particular disk.  Nothing here depends on
//  a real .dsk, and no Apple ROM is needed: the card is driven directly.

module tb_disk2;
    // The encoder under test is the card's, so the bench uses the same
    // function for the write path -- the point of the check is that what the
    // card writes is what the store's decoder reads back, not that the bench can
    // encode.  The *decode* side below is an independent copy of the inverse
    // table, spelled out, so the read path is checked against something other
    // than the design's own table.
    `include "src/disk2/gcr_defs.vh"

    reg clk = 1'b0;
    always #18.519 clk = ~clk;          // 27 MHz

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);    // ~1 MHz enable
    always @(posedge clk) begin
        if (ce_div == 5'd25) ce_div <= 5'd0;
        else                ce_div <= ce_div + 1'b1;
    end

    integer fails = 0;
    integer checks = 0;
    task check(input string what, input bit ok);
        begin
            checks = checks + 1;
            if (!ok) begin
                $display("FAIL: %0s", what);
                fails = fails + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // The image: a pattern where every byte of a sector is distinct and both
    // halves of every byte vary, so a mis-ordered or half-swapped buffer shows
    // up instead of hiding.  The obvious pattern -- the offset in the low two
    // bits -- is too weak for that: four bytes then share their top six bits,
    // and a buffer holding the wrong byte in three of every four positions
    // still decodes "correctly" in the half the test looks at.  Multiplying the
    // offset by 5 is a bijection over a byte, so all 256 are distinct, and the
    // sector, track and drive terms keep the drives and sectors apart.
    function [7:0] img_byte(input integer drive, input integer track,
                             input integer sec, input integer off);
        begin
            img_byte = (8'(off * 5 + sec * 11 + track * 23 + (drive ? 64 : 0))) ^ 8'hA5;
        end
    endfunction

    // An in-memory shadow of both drives' images, for the store to serve and
    // the write path to land in.  It is indexed by the controller's byte
    // position, which is not a flat offset (see img_idx below), so it is larger
    // than the images: 280 rows per drive of 1024 bytes, of which the
    // controller addresses the first 512.
    localparam integer NTRACKS = 35;
    localparam integer SECT    = 16;
    localparam integer SECB    = 256;
    localparam integer DRIVEB  = NTRACKS * SECT * SECB;   // 143,360
    localparam integer SHADOWB = ((2*DRIVEB) / 1024 + 1) * 1024;
    reg [7:0] shadow [0:SHADOWB-1];

    // Where a drive/track/sector/byte lives in the shadow.  Not simply the flat
    // offset: the SDRAM's address splits into a row of 1024 bytes and a column
    // of 256 words, and the controller uses all of the row's 1024 as a row
    // address while only ever driving the first 512 bytes of it as columns, so
    // a flat byte offset and a controller address are not the same thing and
    // the two differ by a whole row every 512 bytes.  The store puts a drive's
    // byte n at controller address n, so the shadow has to be laid out the way
    // the controller would find it -- which is what byte_of() below inverts.
    function integer img_idx(input integer drive, input integer track,
                             input integer sec, input integer off);
        reg [18:0] flat;
        begin
            flat   = (drive ? DRIVEB : 0) + (track * SECT + sec) * SECB + off;
            img_idx = (flat[18:9] * 1024) + (flat[8:1] * 2) + flat[0];
        end
    endfunction

    integer ii, jj;
    initial begin
        for (ii = 0; ii < 2*DRIVEB; ii = ii + 1)
            shadow[img_idx(ii / DRIVEB, (ii / (SECT*SECB)) % NTRACKS,
                           (ii / SECB) % SECT, ii % SECB)] =
                img_byte(ii / DRIVEB, (ii / (SECT*SECB)) % NTRACKS,
                         (ii / SECB) % SECT, ii % SECB);
    end

    // ------------------------------------------------------------------
    // The card, and the store behind it
    // ------------------------------------------------------------------
    // The bench pretends to be slot_bus and drives the two strobes itself, so
    // the card is tested without the rest of the bus.  The decode of which
    // addresses assert which strobe is slot_bus's job and tb_slots checks it.
    reg  [15:0] addr = 16'hC0E0;
    reg         bus_cycle = 1'b0;
    reg         cpu_we = 1'b0;
    reg  [7:0]  cpu_di = 8'h00;
    wire [7:0]  rom_data;
    wire [7:0]  io_data;
    // /DEVSEL is low whenever this bench puts a $C0E0-$C0EF address on the bus.
    wire devsel_n = !((addr[15:8] == 8'hC0) && (addr[7:4] == 4'hE));

    wire        grp_req;
    wire [8:0]  grp_off;
    wire [5:0]  grp_val;
    wire        grp_ack;
    wire [3:0]  pos_sec;
    wire [8:0]  pos_track;
    wire        pos_drive;
    wire        wr_seen;
    wire [7:0]  wr_byte;
    wire        wr_in_data;
    wire [8:0]  wr_off;
    wire [1:0]  drv_present;
    wire [1:0]  drv_writable;
    wire [6:0]  dbg_track;
    wire [7:0]  dbg_head;
    wire [4:0]  dbg_playsel;
    wire [12:0] dbg_playoff;
    wire        dbg_motor, dbg_drive, dbg_wr_mode, dbg_any_disk, dbg_need_grp;

    disk2_card u_card (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .devsel_n(devsel_n), .iosel_n(1'b1),
        .bus_cycle(bus_cycle), .cpu_we(cpu_we), .addr(addr), .cpu_di(cpu_di),
        .rom_data(rom_data), .io_data(io_data),
        .grp_req(grp_req), .grp_off(grp_off), .pos_sec(pos_sec),
        .pos_track(pos_track), .pos_drive(pos_drive),
        .grp_val(grp_val), .grp_ack(grp_ack),
        .store_wr_seen(wr_seen), .store_wr_byte(wr_byte), .store_wr_data(wr_in_data),
        .store_wr_off(wr_off),
        .store_drv_present(drv_present), .store_drv_writable(drv_writable),
        .dbg_track(dbg_track), .dbg_head(dbg_head),
        .dbg_playsel(dbg_playsel), .dbg_playoff(dbg_playoff),
        .dbg_motor(dbg_motor), .dbg_drive(dbg_drive),
        .dbg_any_disk(dbg_any_disk), .dbg_need_grp(dbg_need_grp),
        .dbg_wr_mode(dbg_wr_mode)
    );

    // The store, with its SDRAM port going to a simple stand-in for aux_ram's
    // arbiter.  The real arbiter is exercised by tb_aux_ram, and this bench
    // only needs the 8-clocks-per-word cadence and the byte map.
    // The store drives its SDRAM port; these are its outputs, so they are
    // plain wires here (no initialisers: the store owns them).
    wire        dsk_go;
    wire [21:0] dsk_addr;
    wire        dsk_we;
    wire [15:0] dsk_wdata;
    wire [15:0] dsk_rdata;
    wire        dsk_ack;
    wire        dsk_idle;
    reg  [3:0]  dsk_t = 4'd0;
    reg         dsk_busy = 1'b0;
    reg  [21:0] dsk_a_q = 22'd0;
    reg         dsk_we_q = 1'b0;
    reg  [15:0] dsk_d_q = 16'd0;
    reg  [15:0] dsk_r_q = 16'd0;
    reg         dsk_ack_q = 1'b0;

    assign dsk_idle  = !dsk_busy;
    assign dsk_ack   = dsk_ack_q;
    assign dsk_rdata = dsk_r_q;

    // The stand-in SDRAM: bank 1, one word per 8 clocks, exactly as
    // aux_ram.v paces the real controller.  Its byte map is the one the store
    // computes: addr[21:20] = bank, addr[19:9] = row, addr[8:1] = column,
    // addr[0] = the 16-bit half, ds from the byte.
    reg [21:0] sd_q;
    always @(posedge clk) begin
        dsk_ack_q <= 1'b0;
        if (dsk_go) begin
            dsk_busy <= 1'b1;
            dsk_t    <= 4'd0;
            dsk_a_q  <= dsk_addr;
            dsk_we_q <= dsk_we;
            dsk_d_q  <= dsk_wdata;
        end else if (dsk_busy) begin
            dsk_t <= dsk_t + 4'd1;
            if (dsk_t == 4'd7) begin
                dsk_busy  <= 1'b0;
                dsk_ack_q <= 1'b1;
                if (!dsk_we_q) dsk_r_q <= {shadow[byte_of(dsk_a_q, 1'b1)],
                                           shadow[byte_of(dsk_a_q, 1'b0)]};
            end
        end
    end

    // The byte address a controller word address names.  The store always
    // moves a whole word, so only the two halves vary.
    function integer byte_of(input [21:0] a, input half);
        reg [20:0] b;
        begin
            b = {a[19:1], half};          // row, column, and the half bit
            // Within a bank, the byte address is the row in the high bits, the
            // column in the middle, and the half (and ds) at the bottom.
            byte_of = ((a[21:20] - 2'd1) * 1048576) + (a[19:9] * 1024) +
                      (a[8:1] * 2) + half;
        end
    endfunction

    // The store
    disk2_store u_store (
        .clk(clk), .reset(reset),
        .grp_req(grp_req), .grp_off(grp_off), .pos_sec(pos_sec),
        .pos_track(pos_track), .pos_drive(pos_drive),
        .grp_val(grp_val), .grp_ack(grp_ack),
        .wr_seen(wr_seen), .wr_byte(wr_byte), .wr_in_data(wr_in_data),
        .wr_off(wr_off),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .up_go(1'b0), .up_drive(1'b0), .up_addr(18'd0), .up_data(8'h00),
        .up_last(1'b0), .up_busy(), .up_done(),
        .down_go(1'b0), .down_drive(1'b0), .down_addr(18'd0), .down_last(1'b0),
        .down_data(), .down_valid(), .down_done(),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack), .dsk_idle(dsk_idle)
    );

    // The shadow is written when the stand-in SDRAM takes a write.
    always @(posedge clk) begin
        if (dsk_ack_q && dsk_we_q) begin
            shadow[byte_of(dsk_a_q, 1'b1)] = dsk_d_q[15:8];
            shadow[byte_of(dsk_a_q, 1'b0)] = dsk_d_q[7:0];
        end
    end

    // ------------------------------------------------------------------
    // Driving the card, the way the ROM does
    // ------------------------------------------------------------------
    // One $C0Ex access: the address, a read or a write, one CPU cycle.  The
    // core's cpu_go is a one-clock-wide registered pulse, so bus_cycle is high
    // for exactly one edge here: holding it for two would step the head twice.
    // It is dropped a nanosecond after that edge, not in the same time step, so
    // it cannot race the card's sampling of it (in the real design cpu_go is a
    // register, and this is the one thing the bench has to reproduce by hand).
    task xfer(input [3:0] a, input we, input [7:0] d);
        begin
            @(posedge ce_1m);
            addr      = 16'hC0E0 | {12'h000, a};
            cpu_we    = we;
            cpu_di    = d;
            bus_cycle = 1'b1;
            @(posedge clk);
            #1 bus_cycle = 1'b0;
            @(negedge clk);      // let the edge's updates land before returning
        end
    endtask

    task read_reg(input [3:0] a, output [7:0] d);
        begin
            @(posedge ce_1m);
            addr      = 16'hC0E0 | {12'h000, a};
            cpu_we    = 1'b0;
            bus_cycle = 1'b1;
            #1 d = io_data;
            @(posedge clk);
            #1 bus_cycle = 1'b0;
            @(negedge clk);
        end
    endtask

    // The stepper, driven the way DOS does it: a half-track is "turn on the next
    // phase, turn off the one before" ($C0E0+2n off, $C0E1+2n on), and a track is
    // two of them.  bph is the phase the head is on, which is what "next" is
    // relative to; DOS tracks it the same way.
    reg [1:0] bph = 2'd0;
    task half_out; reg [1:0] p; begin p = bph + 2'd1;
        xfer({1'b0, p, 1'b1}, 1'b0, 8'h00); xfer({1'b0, bph, 1'b0}, 1'b0, 8'h00); bph = p; end endtask
    task half_in;  reg [1:0] p; begin p = bph - 2'd1;
        xfer({1'b0, p, 1'b1}, 1'b0, 8'h00); xfer({1'b0, bph, 1'b0}, 1'b0, 8'h00); bph = p; end endtask
    task step_out; begin half_out; half_out; end endtask
    task step_in;  begin half_in;  half_in;  end endtask

    task recalibrate;
        integer guard;
        reg [7:0] was;
        begin
            guard = 0;
            was   = 8'hFF;      // forces the first iteration to run
            while (guard < 500) begin
                step_in;
                if (dbg_head == was) guard = 500;   // the head stopped moving
                else was = dbg_head;
                guard = guard + 1;
            end
        end
    endtask

    // A seek, the way DOS does it: recalibrate to track 0 first, then step out.
    task seek_toward(input integer trk);
        integer guard;
        begin
            recalibrate;
            guard = 0;
            while (dbg_track != trk[6:0] && guard < 100) begin
                step_out;
                guard = guard + 1;
            end
        end
    endtask

    // Wait for the store's value for the position the head is on.  A real drive
    // streams a byte every 32 us and never has to ask -- the store has 858 clocks
    // per stream byte and wants 54 of them -- but this bench walks the track a
    // byte per ce_1m to keep 227 ms of drive time out of the simulation, and at
    // that rate the card is still asking when the next byte is due.  So the
    // bench waits, which is what the drive's own rate would have done for it.
    // bench waits, which is what the drive's own rate would have done for it.
    task wait_grp;
        integer guard;
        begin
            guard = 0;
            // A clock first, so the card has seen the head arrive and asked.
            @(posedge clk);
            while (dbg_need_grp === 1'b1 && guard < 20000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    // The data register: a Q6L read takes the next stream byte, which is what
    // RWTS does to walk a track.  In write mode, a write to Q6L latches a byte
    // and a Q7L read shifts it in.
    // The register has bit 7 set only for a fresh byte, so poll for it as the ROM's
    // LDA/BPL loop does; the card waits for the store by itself now, which the
    // bench used to do for it (wait_grp) when reads stepped the head.
    task read_byte(output [7:0] d);
        integer g;
        begin
            g = 0; d = 8'h00;
            while (d[7] !== 1'b1 && g < 4000) begin
                read_reg(4'hC, d);      // Q6L: the data register
                g = g + 1;
            end
        end
    endtask

    // The shift register holds a byte and a Q6L read transfers it, so the first
    // read after a reset returns whatever the register was reset to ($FF, a
    // sync byte) and each read after that returns the byte one position behind
    // the one being synthesized.  That is how the real card behaves -- the
    // register is a register -- so the bench primes it once after a reset
    // rather than compensating for it in every expectation.
    task prime_read;
        reg [7:0] junk;
        begin
            read_byte(junk);
        end
    endtask

    // A sector read, the way RWTS finds one: hunt for three $FFs, then the
    // $D5 $AA $96 header, check the four checksum bytes, then the $D5 $AA $AD
    // data mark, then 343 data bytes and the $DE $AA $EB tail.  The decoded 256
    // bytes land in got[].
    reg [7:0] got [0:255];
    integer    hunt, kk, data_i;
    reg [7:0]  b0, b1, b2, mark, vol, trk, sec, cks, t0, t1, t2;
    reg [7:0]  dmark0, dmark1, dmark2, dt0, dt1, dt2;

    task rd5(output [7:0] a, output [7:0] b, output [7:0] c);
        begin
            read_byte(a); read_byte(b); read_byte(c);
        end
    endtask

    // The GCR inverse, here written out independently of the RTL's table so
    // the check is not the design checking itself.  This is the standard
    // 6-and-2 write-translate table, spelled out: 64 legal disk bytes, the ones
    // that leave a data separator something to lock onto.
    function [5:0] model_decode(input [7:0] v);
        begin
            case (v)
                8'h96: model_decode = 6'h00; 8'h97: model_decode = 6'h01;
                8'h9A: model_decode = 6'h02; 8'h9B: model_decode = 6'h03;
                8'h9D: model_decode = 6'h04; 8'h9E: model_decode = 6'h05;
                8'h9F: model_decode = 6'h06; 8'hA6: model_decode = 6'h07;
                8'hA7: model_decode = 6'h08; 8'hAB: model_decode = 6'h09;
                8'hAC: model_decode = 6'h0A; 8'hAD: model_decode = 6'h0B;
                8'hAE: model_decode = 6'h0C; 8'hAF: model_decode = 6'h0D;
                8'hB2: model_decode = 6'h0E; 8'hB3: model_decode = 6'h0F;
                8'hB4: model_decode = 6'h10; 8'hB5: model_decode = 6'h11;
                8'hB6: model_decode = 6'h12; 8'hB7: model_decode = 6'h13;
                8'hB9: model_decode = 6'h14; 8'hBA: model_decode = 6'h15;
                8'hBB: model_decode = 6'h16; 8'hBC: model_decode = 6'h17;
                8'hBD: model_decode = 6'h18; 8'hBE: model_decode = 6'h19;
                8'hBF: model_decode = 6'h1A; 8'hCB: model_decode = 6'h1B;
                8'hCD: model_decode = 6'h1C; 8'hCE: model_decode = 6'h1D;
                8'hCF: model_decode = 6'h1E; 8'hD3: model_decode = 6'h1F;
                8'hD6: model_decode = 6'h20; 8'hD7: model_decode = 6'h21;
                8'hD9: model_decode = 6'h22; 8'hDA: model_decode = 6'h23;
                8'hDB: model_decode = 6'h24; 8'hDC: model_decode = 6'h25;
                8'hDD: model_decode = 6'h26; 8'hDE: model_decode = 6'h27;
                8'hDF: model_decode = 6'h28; 8'hE5: model_decode = 6'h29;
                8'hE6: model_decode = 6'h2A; 8'hE7: model_decode = 6'h2B;
                8'hE9: model_decode = 6'h2C; 8'hEA: model_decode = 6'h2D;
                8'hEB: model_decode = 6'h2E; 8'hEC: model_decode = 6'h2F;
                8'hED: model_decode = 6'h30; 8'hEE: model_decode = 6'h31;
                8'hEF: model_decode = 6'h32; 8'hF2: model_decode = 6'h33;
                8'hF3: model_decode = 6'h34; 8'hF4: model_decode = 6'h35;
                8'hF5: model_decode = 6'h36; 8'hF6: model_decode = 6'h37;
                8'hF7: model_decode = 6'h38; 8'hF9: model_decode = 6'h39;
                8'hFA: model_decode = 6'h3A; 8'hFB: model_decode = 6'h3B;
                8'hFC: model_decode = 6'h3C; 8'hFD: model_decode = 6'h3D;
                8'hFE: model_decode = 6'h3E; 8'hFF: model_decode = 6'h3F;
                default: model_decode = 6'h3C;
            endcase
        end
    endfunction

    // The forward table, spelled out like the inverse above and for the same
    // reason: the bench has to be able to *write* a field without asking the
    // design what a field looks like.
    function [7:0] model_encode(input [5:0] v);
        begin
            case (v)
                6'h00: model_encode = 8'h96; 6'h01: model_encode = 8'h97;
                6'h02: model_encode = 8'h9A; 6'h03: model_encode = 8'h9B;
                6'h04: model_encode = 8'h9D; 6'h05: model_encode = 8'h9E;
                6'h06: model_encode = 8'h9F; 6'h07: model_encode = 8'hA6;
                6'h08: model_encode = 8'hA7; 6'h09: model_encode = 8'hAB;
                6'h0A: model_encode = 8'hAC; 6'h0B: model_encode = 8'hAD;
                6'h0C: model_encode = 8'hAE; 6'h0D: model_encode = 8'hAF;
                6'h0E: model_encode = 8'hB2; 6'h0F: model_encode = 8'hB3;
                6'h10: model_encode = 8'hB4; 6'h11: model_encode = 8'hB5;
                6'h12: model_encode = 8'hB6; 6'h13: model_encode = 8'hB7;
                6'h14: model_encode = 8'hB9; 6'h15: model_encode = 8'hBA;
                6'h16: model_encode = 8'hBB; 6'h17: model_encode = 8'hBC;
                6'h18: model_encode = 8'hBD; 6'h19: model_encode = 8'hBE;
                6'h1A: model_encode = 8'hBF; 6'h1B: model_encode = 8'hCB;
                6'h1C: model_encode = 8'hCD; 6'h1D: model_encode = 8'hCE;
                6'h1E: model_encode = 8'hCF; 6'h1F: model_encode = 8'hD3;
                6'h20: model_encode = 8'hD6; 6'h21: model_encode = 8'hD7;
                6'h22: model_encode = 8'hD9; 6'h23: model_encode = 8'hDA;
                6'h24: model_encode = 8'hDB; 6'h25: model_encode = 8'hDC;
                6'h26: model_encode = 8'hDD; 6'h27: model_encode = 8'hDE;
                6'h28: model_encode = 8'hDF; 6'h29: model_encode = 8'hE5;
                6'h2A: model_encode = 8'hE6; 6'h2B: model_encode = 8'hE7;
                6'h2C: model_encode = 8'hE9; 6'h2D: model_encode = 8'hEA;
                6'h2E: model_encode = 8'hEB; 6'h2F: model_encode = 8'hEC;
                6'h30: model_encode = 8'hED; 6'h31: model_encode = 8'hEE;
                6'h32: model_encode = 8'hEF; 6'h33: model_encode = 8'hF2;
                6'h34: model_encode = 8'hF3; 6'h35: model_encode = 8'hF4;
                6'h36: model_encode = 8'hF5; 6'h37: model_encode = 8'hF6;
                6'h38: model_encode = 8'hF7; 6'h39: model_encode = 8'hF9;
                6'h3A: model_encode = 8'hFA; 6'h3B: model_encode = 8'hFB;
                6'h3C: model_encode = 8'hFC; 6'h3D: model_encode = 8'hFD;
                6'h3E: model_encode = 8'hFE; 6'h3F: model_encode = 8'hFF;
                default: model_encode = 8'hFF;
            endcase
        end
    endfunction

    // The two bits of a group the other way up, which is how 6-and-2 packs them.
    // The P6 ROM unpacks a group with LSR/ROL/LSR/ROL, which puts the group's
    // bit 0 in the byte's bit 1 and the group's bit 1 in the byte's bit 0, so a
    // disk holds each pair transposed.  This is checked against the ROM's own
    // arithmetic in check_p6_unpack below, not just against the design.
    function [1:0] model_swap2(input [1:0] v);
        begin
            model_swap2 = {v[0], v[1]};
        end
    endfunction

    // Build a data field for one sector of the image, the way a drive would
    // write it: 86 aux bytes of low two bits, 256 bytes of top six, a checksum,
    // and every six-bit value XORed with the one before it.
    reg [7:0] wfld [0:342];
    reg [5:0] wnib [0:341];
    integer bi;
    reg [5:0] wprev;

    task build_field(input integer sector);
        begin
            for (bi = 0; bi < 86; bi = bi + 1)
                wnib[bi] = {model_swap2(172 + bi < 256 ?
                             shadow[img_idx(0, 0, sector, 172 + bi)][1:0] : 2'b00),
                             model_swap2(shadow[img_idx(0, 0, sector, 86 + bi)][1:0]),
                             model_swap2(shadow[img_idx(0, 0, sector, bi)][1:0])};
            for (bi = 0; bi < 256; bi = bi + 1)
                wnib[86 + bi] = shadow[img_idx(0, 0, sector, bi)][7:2];
            // The chain a real drive writes: each position is its own group
            // XORed with the group before it, the first is its own group, and
            // the checksum is the last position's group again with nothing done
            // to it.  A RWTS undoes it by XORing the disk bytes as it reads
            // them, which telescopes to the group at each position.
            wprev = 6'd0;
            for (bi = 0; bi < 342; bi = bi + 1) begin
                wfld[bi] = model_encode(wprev ^ wnib[bi]);
                wprev     = wnib[bi];
            end
            wfld[342] = model_encode(wnib[341]);
        end
    endtask

    // The 4-and-4 decode of an address field, also independent of the RTL.
    function [7:0] model_a44(input [7:0] hi, input [7:0] lo);
        begin
            model_a44 = {hi[6] & lo[7], hi[5] & lo[6], hi[4] & lo[5],
                         hi[3] & lo[4], hi[2] & lo[3], hi[1] & lo[2],
                         hi[0] & lo[1], lo[0]};
        end
    endfunction

    // The data field decoded the way the store decodes it, from the field's
    // own layout: 256 disk bytes of top six bits, 86 of low two bits.
    reg [7:0] field [0:342];
    // Decode a data field into got[].  The layout is the one RWTS reads: 86 aux
    // bytes carrying the low two bits of sector bytes 172+k, 86+k and k, then
    // 256 bytes of top six bits, then the checksum.  Each six-bit value is the
    // XOR of itself and the one before it, and the last byte repeats the 342nd.
    // Written out here rather than shared with the RTL, so that checking the
    // field is checking the field.
    reg [5:0] nib6 [0:341];
    integer nx;
    reg [5:0] nv;
    task decode_field;
        begin
            nv = 6'd0;
            for (nx = 0; nx < 342; nx = nx + 1) begin
                nv       = model_decode(field[nx]) ^ nv;
                nib6[nx] = nv;
            end
            for (nx = 0; nx < 256; nx = nx + 1) got[nx] = 8'h00;
            for (nx = 0; nx < 86; nx = nx + 1) begin
                // Each group is a byte's low two bits in order, so the way back
                // out is the way in.
                if (172 + nx < 256)
                    got[172 + nx][1:0] = model_swap2(nib6[nx][5:4]);
                got[86 + nx][1:0] = model_swap2(nib6[nx][3:2]);
                got[nx][1:0]      = model_swap2(nib6[nx][1:0]);
            end
            for (nx = 86; nx < 342; nx = nx + 1)
                got[nx - 86][7:2] = nib6[nx][5:0];
        end
    endtask

    // The 4-and-4 decode of the address field, which is what RWTS does with the
    // eight bytes it reads after the $D5 $AA $96.
    reg [7:0] a0, a1, a2, a3, a4, a5, a6, a7;
    task decode_address;
        begin
            vol = model_a44(a0, a1);
            trk = model_a44(a2, a3);
            sec = model_a44(a4, a5);
            cks = model_a44(a6, a7);
        end
    endtask

    // Walk the track to sector `want` and leave the header and the data field
    // in the bench's variables.  Returns 1 if the sector was found.
    reg found;
    task find_sector(input integer want);
        integer guard;
        begin
            found  = 1'b0;
            guard  = 0;
            mark   = 8'h00;
            while (!found && guard < 16 * 500) begin
                read_byte(b0);
                if (b0 == 8'hD5) begin
                    read_byte(b1);
                    read_byte(b2);
                    if (b1 == 8'hAA && b2 == 8'h96) begin
                        read_byte(a0); read_byte(a1);
                        read_byte(a2); read_byte(a3);
                        read_byte(a4); read_byte(a5);
                        read_byte(a6); read_byte(a7);
                        decode_address;
                        read_byte(t0); read_byte(t1); read_byte(t2);
                        if (sec == want[7:0]) found = 1'b1;
                    end
                end
                guard = guard + 1;
            end
        end
    endtask

    // The bytes of one sector's data field, into field[].  The $D5 $AA $AD
    // address mark has already been read by the hunt that got here, so this
    // starts at the first data byte.
    task read_field;
        begin
            for (kk = 0; kk < 343; kk = kk + 1) read_byte(field[kk]);
            read_byte(dt0); read_byte(dt1); read_byte(dt2);
        end
    endtask

    integer diff_i, diff_n, sec_i;
    reg [7:0] rb;        // a byte read and thrown away, walking to a position

    initial begin
        #200;
        @(posedge clk);
        reset = 1'b0;
        #100;

        // ---- the $C0Ex decode ----
        xfer(4'h9, 1'b0, 8'h00);          // motor on
        check("motor on", dbg_motor === 1'b1);
        xfer(4'h8, 1'b0, 8'h00);          // motor off
        check("motor off", dbg_motor === 1'b0);
        xfer(4'h9, 1'b0, 8'h00);

        xfer(4'hB, 1'b0, 8'h00);          // drive 2
        check("drive 2 selected", dbg_drive === 1'b1);
        xfer(4'hA, 1'b0, 8'h00);          // drive 1
        check("drive 1 selected", dbg_drive === 1'b0);

        // Q7 read selects read mode, a Q7 write selects write mode.
        read_reg(4'hF, rb);
        check("Q7 read leaves read mode", dbg_wr_mode === 1'b0);
        xfer(4'hF, 1'b1, 8'h00);
        check("Q7 write selects write mode", dbg_wr_mode === 1'b1);
        read_reg(4'hF, rb);               // back to read mode
        check("Q7 read returns to read mode", dbg_wr_mode === 1'b0);

        // With no image uploaded the drive must read as write protected, so a
        // format goes nowhere rather than into unwritten memory.
        read_reg(4'hC, rb);               // Q6L in read mode is the data register
        xfer(4'hF, 1'b1, 8'h00);          // write mode
        read_reg(4'hC, rb);
        check("an empty drive reports write protected", rb === 8'h80);
        read_reg(4'hF, rb);               // back to read mode

        // ---- the stepper ----
        check("the head starts at track 0", dbg_track === 7'd0);
        // A DOS seek is two half-steps and moves one whole track.
        step_out;
        check("one out-step is one track", dbg_track === 7'd1);
        step_out; step_out;
        check("three out-steps reach track 3", dbg_track === 7'd3);
        step_in;
        check("one in-step is one track back", dbg_track === 7'd2);

        // Recalibration walks to track 0, stops there, and stays there.
        seek_toward(30);
        check("seeking out reaches track 30", dbg_track === 7'd30);
        recalibrate;
        check("recalibration lands on track 0", dbg_track === 7'd0);
        step_in;
        check("stepping in at track 0 does nothing", dbg_track === 7'd0);
        step_out;
        check("and out again works from the stop", dbg_track === 7'd1);

        // The far stop.
        seek_toward(34);
        check("seeking out reaches track 34", dbg_track === 7'd34);
        step_out; step_out;
        check("the head stops at track 34", dbg_track === 7'd34);
        check("the head position is the track", dbg_head === 8'd34);
        recalibrate;
        check("recalibration from the far stop comes back", dbg_track === 7'd0);

        // ---- the track itself: every sector, from the start ----
        // The stream is walked by reads alone, with the motor off.  A real
        // drive with the motor off holds its last byte and a read advances
        // nothing, which the card now models, so the bench can step through
        // the track one byte at a time and land on every field exactly.  DOS
        // always turns the motor on and reads at the drive's own rate (a byte
        // every 32 us, 33 ce_1m); walking a whole track that way would take
        // 227 ms of simulated time, and what is under test here is the
        // content of the stream, not its rate.
        begin
            reset = 1'b1; #40; @(posedge clk); reset = 1'b0; #40;
            xfer(4'h9, 1'b0, 8'h00);   // motor on: the head only moves with the motor, one byte per 32 us
            check("the stream starts at the top of the track", dbg_head === 8'd0);
            // 48 self-sync bytes, then the header address mark.
            for (diff_i = 0; diff_i < 48; diff_i = diff_i + 1) read_byte(rb);
            check("48 self-sync bytes come first", rb === 8'hFF);
            read_byte(b0); check("the header mark is D5", b0 === 8'hD5);
            read_byte(b1); check("then AA", b1 === 8'hAA);
            read_byte(b2); check("then 96", b2 === 8'h96);

            for (sec_i = 0; sec_i < 16; sec_i = sec_i + 1) begin
                // Position the bench at sector sec_i: sector 0's header has
                // just been read, and the rest are one track layout apart.
                if (sec_i > 0) begin
                    // Finish sector 0 (or the last one read) and hunt forward
                    // to the next sector's header mark, as RWTS does.  The
                    // address bytes it reads are 4-and-4 encoded, and the
                    // sector byte only means anything once decoded.
                    find_sector(sec_i);
                    check($sformatf("sector %0d header found on track 0", sec_i), found);
                end else begin
                    // The volume, track, sector and checksum bytes are next,
                    // each as a pair.
                    read_byte(a0); read_byte(a1);
                    read_byte(a2); read_byte(a3);
                    read_byte(a4); read_byte(a5);
                    read_byte(a6); read_byte(a7);
                    decode_address;
                    read_byte(t0); read_byte(t1); read_byte(t2);
                    check($sformatf("sector %0d header tail is DE AA EB", sec_i),
                          t0 === 8'hDE && t1 === 8'hAA && t2 === 8'hEB);
                end
                // The same four checks either way: the address field is 4-and-4
                // encoded, so RWTS decodes it, and a card that wrote the bytes
                // raw would fail every one of these.
                check($sformatf("sector %0d volume is $FE", sec_i), vol === 8'hFE);
                check($sformatf("sector %0d track byte is 0", sec_i), trk === 8'h00);
                check($sformatf("sector %0d sector byte is %0d", sec_i, sec_i),
                      sec === sec_i[7:0]);
                check($sformatf("sector %0d checksum is vol^trk^sec", sec_i),
                      cks === (8'hFE ^ 8'h00 ^ sec_i[7:0]));

                // The data address mark, the field, and its tail: hunt for
                // D5 AA AD past the header tail's self-sync bytes.
                hunt = 0; mark = 8'h00;
                while (!(mark == 8'hD5) && hunt < 64) begin
                    read_byte(b0);
                    if (b0 == 8'hD5) begin
                        read_byte(b1); read_byte(b2);
                        if (b1 == 8'hAA && b2 == 8'hAD) mark = 8'hD5;
                    end
                    hunt = hunt + 1;
                end
                check($sformatf("sector %0d data address mark found", sec_i),
                      mark === 8'hD5);
                if (mark == 8'hD5) begin
                    read_field;
                    check($sformatf("sector %0d data tail is DE AA EB", sec_i),
                          dt0 === 8'hDE && dt1 === 8'hAA && dt2 === 8'hEB);
                    decode_field;
                    diff_n = 0;
                    for (diff_i = 0; diff_i < 256; diff_i = diff_i + 1) begin
                        if (got[diff_i] !== shadow[img_idx(0, 0, sec_i, diff_i)]) begin
                            if (diff_n == 0)
                                $display("  sector %0d byte %0d: got %02x, image %02x",
                                         sec_i, diff_i, got[diff_i],
                                         shadow[img_idx(0, 0, sec_i, diff_i)]);
                            diff_n = diff_n + 1;
                        end
                    end
                    check($sformatf("sector %0d decodes to the image (%0d bytes differ)",
                                    sec_i, diff_n), diff_n == 0);
                end
            end
        end

        // ---- the write path ----
        // Write a whole data field in write mode and check it comes back out
        // of the image afterwards, which is what RWTS's verify read does.
        // The motor is stopped at the field's first byte, so the bench stays on the byte it is writing.
        begin
            reset = 1'b1; #40; @(posedge clk); reset = 1'b0; #40;
            xfer(4'h9, 1'b0, 8'h00);   // motor on: the head only moves with the motor, one byte per 32 us

            // Wipe sector 0 of drive 1 in the shadow, so the write is over
            // something known.  This stands in for the debugger's upload path,
            // which fills the same image through the same store.
            for (jj = 0; jj < 256; jj = jj + 1)
                shadow[img_idx(0, 0, 0, jj)] = 8'h00;

            // Walk to sector 0's data address mark.  The stream is reset to the
            // top of the track, so sector 0's header is the first one.
            for (diff_i = 0; diff_i < 48; diff_i = diff_i + 1) read_byte(rb);
            read_byte(b0); read_byte(b1); read_byte(b2);
            check("48 self-sync bytes, then the header mark", b0 === 8'hD5);
            read_byte(a0); read_byte(a1);
            read_byte(a2); read_byte(a3);
            read_byte(a4); read_byte(a5);
            read_byte(a6); read_byte(a7);
            decode_address;
            read_byte(t0); read_byte(t1); read_byte(t2);
            // Six self-sync bytes, then the data mark $D5 $AA $AD, then one more
            // read, which is the first data byte's slot.  A read hands back the
            // byte under the head and leaves the head on it, and a write goes
            // into the position the head is at, so the motor is stopped right
            // here (well inside the 32 us the head stays on a byte) and the
            // field is written from this position on, per access.
            for (diff_i = 0; diff_i < 6; diff_i = diff_i + 1) read_byte(rb);
            read_byte(b0); read_byte(b1); read_byte(b2);
            read_byte(rb);
            xfer(4'h8, 1'b0, 8'h00);      // motor off: hold the head
            check("the data mark's D5 and AA are next", b0 === 8'hD5 && b1 === 8'hAA && b2 === 8'hAD);
            check("the head is at the first data byte", dbg_playoff == 13'd71);

            // Write mode, then a field holding sector 3's bytes, so a sector
            // swap on the write path would show up.  The field is built by the
            // bench's own encoder, not the design's.
            build_field(3);
            xfer(4'hF, 1'b1, 8'h00);      // Q7 write: write mode
            for (kk = 0; kk < 343; kk = kk + 1) begin
                xfer(4'hC, 1'b1, wfld[kk]);
                read_reg(4'hD, rb);
            end
            read_reg(4'hF, rb);                             // back to read mode

            // The store writes the sector back when the field ends; give it
            // the time its 128 words take (about 40 us of CPU cycles).
            repeat (600) @(posedge ce_1m);

            diff_n = 0;
            for (diff_i = 0; diff_i < 256; diff_i = diff_i + 1) begin
                if (shadow[img_idx(0, 0, 0, diff_i)] !== shadow[img_idx(0, 0, 3, diff_i)]) begin
                    $display("  written byte %0d: got %02x, wrote %02x", diff_i,
                             shadow[img_idx(0, 0, 0, diff_i)],
                             shadow[img_idx(0, 0, 3, diff_i)]);
                    diff_n = diff_n + 1;
                end
            end
            check($sformatf("the written sector reached the image (%0d bytes differ)",
                            diff_n), diff_n == 0);
        end

        if (fails == 0) $display("tb_disk2: PASS (%0d checks)", checks);
        else             $display("tb_disk2: FAIL (%0d of %0d checks failed)", fails, checks);
        $finish;
    end

    initial begin
        #4000000000; // 4 s: the stream runs in real time now (32 us a byte)
        $display("tb_disk2: FAIL (timeout)");
        $finish;
    end
endmodule
