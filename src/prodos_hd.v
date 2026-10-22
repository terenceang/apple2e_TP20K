// ============================================================================
//  prodos_hd.v -- slot 7 ProDOS block device: two 32 MB volumes in the DDR3
//
//  The volumes are 65,536 blocks of 512 bytes each at the top of the DDR3,
//  two bytes per 16-bit word (src/aux_ram.v, hd_*: word address {drive,
//  block, word}, low byte = even byte).  They are files on the TF card
//  (src/sd_vol.v), which reads each block into the DDR3 when READ asks for
//  it (rb_go, ~1 ms, nothing if it is the block it read or wrote last) and
//  gets each block written here back, so `present` is sd_vol's.  There is
//  no block buffer, because
//  block RAM is too scarce for one (Documents/memory_architecture.md): the data port streams straight to
//  and from the DDR3.  A read of $C0F0 hands over the byte fetched last and
//  asks for the next; a write posts the byte.  The driver's copy loops take
//  ~14 CPU cycles a byte against well under 1 us for a DDR3 request, so the
//  next byte is always there in time.
//
//  $C0F0  data: read or write the byte at the pointer, then advance it
//  $C0F1  block number, low      $C0F2  block number, high
//  $C0F3  write 1: pointer to 0, the block from the TF card, then fetch byte 0
//         (READ); anything else: pointer to 0
//  $C0F4  status: bit 7 busy (a DDR3 request, or the block coming from or
//         going back to the TF card), bit 1 the selected drive has a volume,
//         bit 0 the last READ could not get its block from the card
//  $C0F5  drive: 0 or 1
//  $C0F6/$C0F7  read: the selected drive's size in blocks, low/high (0 with no
//         volume); the block driver's STATUS and the SmartPort's report it
//  $C0F7  write: clear the profile below
//  $C0F8-$C0FF  profile, 16-bit little-endian, in 256-clock units (9.48 us,
//         saturating at 65,535 = 0.62 s): last READ, worst READ, last WRITE,
//         worst WRITE.  A READ counts from $C0F3 to its block being in the
//         DDR3 (~0 for the remembered block), a WRITE from byte 511 to the
//         card having it; both include waiting behind other card work.  The
//         debugger reads them without side effects (@c0f0 then m: the
//         last eight bytes of the line).
//
//  Writing byte 511 of a block also queues that block for the TF card, and
//  busy stays up until the card has it, which the driver's WRITE waits for.
//
//  Timing per 512-byte block (estimates from the design, not measured on
//  hardware; an SPI byte is ~19 clocks = 0.7 us at 13.5 MHz, so a CMD17 is
//  ~525 bytes = ~0.37 ms plus the card's own access time):
//    READ, block remembered (tag hit)   ~7.6 ms: the copy loop alone, 512 x 15
//                                       cycles (LDA abs, STA (zp),Y, INY, BNE)
//    READ, typical miss                 ~8-9 ms: + 0.5-1.4 ms for the CMD17
//                                       (card access 0.1-1 ms)
//    READ, slow card                    ~110 ms: SDHC's 100 ms read timeout
//    READ, behind a sector write        ~360 ms: a floppy track flush sector
//                                       already on the card (250 ms busy
//                                       limit); the rest of the track waits
//    READ, card gone                    ~0.75 s, then $27 (sd_vol's 2^20-poll
//                                       timeout)
//    WRITE                              ~7 ms copy (512 x 14 cycles), then
//                                       ~1-3 ms on the card typically, 250 ms
//                                       worst (the SD write busy limit)
//  The CPU's byte loop, not the card, sets the pace: ~60 KB/s, about what
//  the fastest real //e cards (SCSI, CFFA) manage with the same kind of loop.
//
//  ROM: $C700-$C7FF and the $C800-$CFFF expansion ROM (the card claims it
//  on any $C7xx access, as slot_bus does for card_exprom): a boot that reads
//  block 0 of drive 1, the ProDOS block driver ($C7FF = $29, so $C729) and
//  a SmartPort at $C72C.  The source is src/prodos_hd_rom.s, with the
//  signature and ID bytes and what ProDOS and the SmartPort expect of them;
//  scripts/hdrom.py assembles it into src/prodos_hd_rom.vh, included here,
//  and scripts/hdrom_test.py runs it against a model of these registers.
// ============================================================================

`default_nettype none

module prodos_hd (
    input  wire        clk,
    input  wire        reset,
    input  wire        bus_cycle,     // cpu_go: the CPU's own cycles only
    input  wire        cpu_we,
    input  wire [15:0] addr,
    input  wire [7:0]  cpu_di,
    input  wire [1:0]  present,       // per drive (sd_vol)
    input  wire [15:0] size0,         // blocks in each drive's file (sd_vol)
    input  wire [15:0] size1,
    output wire [7:0]  rom_data,      // $C700-$C7FF and $C800-$CFFF, to slot_bus
    output wire [7:0]  io_data,       // $C0F0-$C0FF
    output reg         hd_go,
    output reg  [24:0] hd_addr,
    output reg         hd_we,
    output reg  [1:0]  hd_be,
    output reg  [15:0] hd_wdata,
    input  wire [15:0] hd_rdata,
    input  wire        hd_ack,        // shared with sd_vol: only ours while busy
    output reg         wb_go,         // to sd_vol: write this block back
    output reg         wb_drv,
    output reg  [15:0] wb_blk,        // the block, for wb_go and rb_go
    output reg         rb_go,         // to sd_vol: this block into the DDR3
    input  wire        rb_ok,
    input  wire        sd_busy
);

`include "src/prodos_hd_rom.vh"
    assign rom_data = addr[11] ? hd_rom_c8(addr[8:0]) : hd_rom_c7(addr[7:0]);

    reg [15:0] blk  = 16'd0;
    reg [8:0]  ptr  = 9'd0;
    reg        drv  = 1'b0;
    reg        busy = 1'b0;
    reg        hi   = 1'b0;            // the byte fetched is the word's high one
    reg        wb_pend = 1'b0;
    reg        fill = 1'b0;            // a READ waits for sd_vol to have its block
    reg [7:0]  data = 8'd0;

    // the profile
    reg [23:0] pt = 24'd0;             // clocks since the timed READ or WRITE began
    reg        pw = 1'b0;              // timing a WRITE
    reg [15:0] rd_last = 16'd0, rd_max = 16'd0, wr_last = 16'd0, wr_max = 16'd0;
    wire [15:0] pt_u = pt[23:8];

    wire st_busy = busy || fill || wb_pend || sd_busy;
    reg [7:0] io_r;
    always @(*)
        case (addr[3:0])
            4'h0: io_r = data;
            4'h4: io_r = {st_busy, 5'd0, present[drv], ~rb_ok};
            4'h6: io_r = present[drv] ? (drv ? size1[7:0]  : size0[7:0])  : 8'h00;
            4'h7: io_r = present[drv] ? (drv ? size1[15:8] : size0[15:8]) : 8'h00;
            4'h8: io_r = rd_last[7:0];  4'h9: io_r = rd_last[15:8];
            4'hA: io_r = rd_max[7:0];   4'hB: io_r = rd_max[15:8];
            4'hC: io_r = wr_last[7:0];  4'hD: io_r = wr_last[15:8];
            4'hE: io_r = wr_max[7:0];   4'hF: io_r = wr_max[15:8];
            default: io_r = 8'h00;
        endcase
    assign io_data = io_r;

    wire       io_hit = bus_cycle && addr[15:4] == 12'hC0F;
    wire [8:0] nptr   = ptr + 9'd1;

    always @(posedge clk) begin
        hd_go <= 1'b0;
        wb_go <= 1'b0;
        rb_go <= 1'b0;
        if (~&pt) pt <= pt + 1'b1;
        // a WRITE is done when the card has it (wb_go is up the clock before
        // sd_vol's busy is)
        if (pw && !wb_pend && !wb_go && !sd_busy) begin
            pw      <= 1'b0;
            wr_last <= pt_u;
            if (pt_u > wr_max) wr_max <= pt_u;
        end
        if (hd_ack && busy) begin
            busy <= 1'b0;
            if (!hd_we) data <= hi ? hd_rdata[15:8] : hd_rdata[7:0];
        end
        if (reset) begin
            busy    <= 1'b0;
            ptr     <= 9'd0;
            wb_pend <= 1'b0;
            fill    <= 1'b0;
        end else begin
            // the block is in the DDR3 (rb_go is still up the clock before
            // sd_vol's busy is): fetch byte 0
            if (fill && !rb_go && !sd_busy) begin
                fill <= 1'b0;
                rd_last <= pt_u;
                if (pt_u > rd_max) rd_max <= pt_u;
                if (rb_ok) begin
                    hd_go   <= 1'b1;
                    hd_we   <= 1'b0;
                    hd_addr <= {drv, blk, 8'd0};
                    hi      <= 1'b0;
                    busy    <= 1'b1;
                end
            end
            if (wb_pend && !busy && !sd_busy) begin
                wb_go   <= 1'b1;
                wb_pend <= 1'b0;
            end
            if (io_hit) begin
                // ponytail: one request at a time with no queue; the driver's
                // byte loops leave ~14 us between requests, so one is never
                // still out when the next comes.
                case (addr[3:0])
                    4'h0: begin
                        hd_go    <= 1'b1;
                        hd_we    <= cpu_we;
                        hd_be    <= ptr[0] ? 2'b10 : 2'b01;
                        hd_wdata <= {cpu_di, cpu_di};
                        hd_addr  <= {drv, blk, cpu_we ? ptr[8:1] : nptr[8:1]};
                        hi       <= nptr[0];
                        busy     <= 1'b1;
                        ptr      <= nptr;
                        if (cpu_we && ptr == 9'd511) begin
                            pt      <= 24'd0;
                            pw      <= 1'b1;
                            wb_pend <= 1'b1;
                            wb_drv  <= drv;
                            wb_blk  <= blk;
                        end
                    end
                    4'h1: if (cpu_we) blk[7:0]  <= cpu_di;
                    4'h2: if (cpu_we) blk[15:8] <= cpu_di;
                    4'h3: if (cpu_we) begin
                        ptr <= 9'd0;
                        if (cpu_di == 8'd1) begin
                            pt     <= 24'd0;
                            rb_go  <= 1'b1;
                            wb_drv <= drv;
                            wb_blk <= blk;
                            fill   <= 1'b1;
                        end
                    end
                    4'h5: if (cpu_we) drv <= cpu_di[0];
                    4'h7: if (cpu_we) begin
                        rd_last <= 16'd0; rd_max <= 16'd0; wr_last <= 16'd0; wr_max <= 16'd0;
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
