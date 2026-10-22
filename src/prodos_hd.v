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
//  there is no block RAM to spare (46/46): the data port streams straight to
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
//  ROM ($C700): the ProDOS block-device signature ($C701 $20, $C703 $00,
//  $C705 $03, $C707 $3C -- non-zero, so not a SmartPort), a boot that reads
//  block 0 of drive 1 to $0800 through the driver and, with no volume, goes
//  on with the enhanced //e ROM's Autostart scan at its next slot (SLOOP,
//  $FABA; $01 still holds $C7), and the driver at $C729 ($C7FF):
//
//   $C700 A2 20             LDX #$20
//   $C702 A0 00             LDY #$00
//   $C704 A2 03             LDX #$03
//   $C706 86 3C             STX $3C
//   $C708 A9 01             LDA #$01
//   $C70A 85 42             STA $42
//   $C70C A9 70             LDA #$70
//   $C70E 85 43             STA $43
//   $C710 A9 00             LDA #$00
//   $C712 85 44             STA $44
//   $C714 85 46             STA $46
//   $C716 85 47             STA $47
//   $C718 A9 08             LDA #$08
//   $C71A 85 45             STA $45
//   $C71C 20 29 C7          JSR DRV
//   $C71F B0 05             BCS NOBOOT
//   $C721 A2 70             LDX #$70
//   $C723 4C 01 08          JMP $0801
//   $C726 4C BA FA  NOBOOT: JMP $FABA
//   $C729 A5 43     DRV:    LDA $43
//   $C72B 0A                ASL
//   $C72C A9 00             LDA #$00
//   $C72E 2A                ROL
//   $C72F 8D F5 C0          STA $C0F5
//   $C732 AD F4 C0          LDA $C0F4
//   $C735 29 02             AND #$02
//   $C737 F0 20             BEQ NODEV
//   $C739 A5 46             LDA $46
//   $C73B 8D F1 C0          STA $C0F1
//   $C73E A5 47             LDA $47
//   $C740 8D F2 C0          STA $C0F2
//   $C743 A0 00             LDY #$00
//   $C745 A5 42             LDA $42
//   $C747 F0 14             BEQ STATUS
//   $C749 C9 01             CMP #$01
//   $C74B F0 18             BEQ READ
//   $C74D C9 02             CMP #$02
//   $C74F F0 38             BEQ WRITE
//   $C751 C9 03             CMP #$03
//   $C753 F0 0C             BEQ OK
//   $C755 A9 01             LDA #$01
//   $C757 38                SEC
//   $C758 60                RTS
//   $C759 A9 28     NODEV:  LDA #$28
//   $C75B 38                SEC
//   $C75C 60                RTS
//   $C75D A2 FF     STATUS: LDX #$FF
//   $C75F A0 FF             LDY #$FF
//   $C761 A9 00     OK:     LDA #$00
//   $C763 18                CLC
//   $C764 60                RTS
//   $C765 A9 01     READ:   LDA #$01
//   $C767 8D F3 C0          STA $C0F3
//   $C76A AD F4 C0  RW:     LDA $C0F4
//   $C76D 30 FB             BMI RW
//   $C76F 4A                LSR
//   $C770 B0 38             BCS IOERR
//   $C772 AD F0 C0  R1:     LDA $C0F0
//   $C775 91 44             STA ($44),Y
//   $C777 C8                INY
//   $C778 D0 F8             BNE R1
//   $C77A E6 45             INC $45
//   $C77C AD F0 C0  R2:     LDA $C0F0
//   $C77F 91 44             STA ($44),Y
//   $C781 C8                INY
//   $C782 D0 F8             BNE R2
//   $C784 C6 45             DEC $45
//   $C786 4C 61 C7          JMP OK
//   $C789 A9 00     WRITE:  LDA #$00
//   $C78B 8D F3 C0          STA $C0F3
//   $C78E B1 44     W1:     LDA ($44),Y
//   $C790 8D F0 C0          STA $C0F0
//   $C793 C8                INY
//   $C794 D0 F8             BNE W1
//   $C796 E6 45             INC $45
//   $C798 B1 44     W2:     LDA ($44),Y
//   $C79A 8D F0 C0          STA $C0F0
//   $C79D C8                INY
//   $C79E D0 F8             BNE W2
//   $C7A0 C6 45             DEC $45
//   $C7A2 AD F4 C0  W3:     LDA $C0F4
//   $C7A5 30 FB             BMI W3
//   $C7A7 4C 61 C7          JMP OK
//   $C7AA A9 27     IOERR:  LDA #$27
//   $C7AC 38                SEC
//   $C7AD 60                RTS
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
    output wire [7:0]  rom_data,      // $C700-$C7FF, to slot_bus
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

    function [7:0] rom(input [7:0] a);
        reg [7:0] b;
        begin
            case (a)
            8'h00: b = 8'hA2; 8'h01: b = 8'h20; 8'h02: b = 8'hA0; 8'h03: b = 8'h00; 8'h04: b = 8'hA2; 8'h05: b = 8'h03; 8'h06: b = 8'h86; 8'h07: b = 8'h3C;
            8'h08: b = 8'hA9; 8'h09: b = 8'h01; 8'h0A: b = 8'h85; 8'h0B: b = 8'h42; 8'h0C: b = 8'hA9; 8'h0D: b = 8'h70; 8'h0E: b = 8'h85; 8'h0F: b = 8'h43;
            8'h10: b = 8'hA9; 8'h11: b = 8'h00; 8'h12: b = 8'h85; 8'h13: b = 8'h44; 8'h14: b = 8'h85; 8'h15: b = 8'h46; 8'h16: b = 8'h85; 8'h17: b = 8'h47;
            8'h18: b = 8'hA9; 8'h19: b = 8'h08; 8'h1A: b = 8'h85; 8'h1B: b = 8'h45; 8'h1C: b = 8'h20; 8'h1D: b = 8'h29; 8'h1E: b = 8'hC7; 8'h1F: b = 8'hB0;
            8'h20: b = 8'h05; 8'h21: b = 8'hA2; 8'h22: b = 8'h70; 8'h23: b = 8'h4C; 8'h24: b = 8'h01; 8'h25: b = 8'h08; 8'h26: b = 8'h4C; 8'h27: b = 8'hBA;
            8'h28: b = 8'hFA; 8'h29: b = 8'hA5; 8'h2A: b = 8'h43; 8'h2B: b = 8'h0A; 8'h2C: b = 8'hA9; 8'h2D: b = 8'h00; 8'h2E: b = 8'h2A; 8'h2F: b = 8'h8D;
            8'h30: b = 8'hF5; 8'h31: b = 8'hC0; 8'h32: b = 8'hAD; 8'h33: b = 8'hF4; 8'h34: b = 8'hC0; 8'h35: b = 8'h29; 8'h36: b = 8'h02; 8'h37: b = 8'hF0;
            8'h38: b = 8'h20; 8'h39: b = 8'hA5; 8'h3A: b = 8'h46; 8'h3B: b = 8'h8D; 8'h3C: b = 8'hF1; 8'h3D: b = 8'hC0; 8'h3E: b = 8'hA5; 8'h3F: b = 8'h47;
            8'h40: b = 8'h8D; 8'h41: b = 8'hF2; 8'h42: b = 8'hC0; 8'h43: b = 8'hA0; 8'h44: b = 8'h00; 8'h45: b = 8'hA5; 8'h46: b = 8'h42; 8'h47: b = 8'hF0;
            8'h48: b = 8'h14; 8'h49: b = 8'hC9; 8'h4A: b = 8'h01; 8'h4B: b = 8'hF0; 8'h4C: b = 8'h18; 8'h4D: b = 8'hC9; 8'h4E: b = 8'h02; 8'h4F: b = 8'hF0;
            8'h50: b = 8'h38; 8'h51: b = 8'hC9; 8'h52: b = 8'h03; 8'h53: b = 8'hF0; 8'h54: b = 8'h0C; 8'h55: b = 8'hA9; 8'h56: b = 8'h01; 8'h57: b = 8'h38;
            8'h58: b = 8'h60; 8'h59: b = 8'hA9; 8'h5A: b = 8'h28; 8'h5B: b = 8'h38; 8'h5C: b = 8'h60; 8'h5D: b = 8'hA2; 8'h5E: b = 8'hFF; 8'h5F: b = 8'hA0;
            8'h60: b = 8'hFF; 8'h61: b = 8'hA9; 8'h62: b = 8'h00; 8'h63: b = 8'h18; 8'h64: b = 8'h60; 8'h65: b = 8'hA9; 8'h66: b = 8'h01; 8'h67: b = 8'h8D;
            8'h68: b = 8'hF3; 8'h69: b = 8'hC0; 8'h6A: b = 8'hAD; 8'h6B: b = 8'hF4; 8'h6C: b = 8'hC0; 8'h6D: b = 8'h30; 8'h6E: b = 8'hFB; 8'h6F: b = 8'h4A;
            8'h70: b = 8'hB0; 8'h71: b = 8'h38; 8'h72: b = 8'hAD; 8'h73: b = 8'hF0; 8'h74: b = 8'hC0; 8'h75: b = 8'h91; 8'h76: b = 8'h44; 8'h77: b = 8'hC8;
            8'h78: b = 8'hD0; 8'h79: b = 8'hF8; 8'h7A: b = 8'hE6; 8'h7B: b = 8'h45; 8'h7C: b = 8'hAD; 8'h7D: b = 8'hF0; 8'h7E: b = 8'hC0; 8'h7F: b = 8'h91;
            8'h80: b = 8'h44; 8'h81: b = 8'hC8; 8'h82: b = 8'hD0; 8'h83: b = 8'hF8; 8'h84: b = 8'hC6; 8'h85: b = 8'h45; 8'h86: b = 8'h4C; 8'h87: b = 8'h61;
            8'h88: b = 8'hC7; 8'h89: b = 8'hA9; 8'h8A: b = 8'h00; 8'h8B: b = 8'h8D; 8'h8C: b = 8'hF3; 8'h8D: b = 8'hC0; 8'h8E: b = 8'hB1; 8'h8F: b = 8'h44;
            8'h90: b = 8'h8D; 8'h91: b = 8'hF0; 8'h92: b = 8'hC0; 8'h93: b = 8'hC8; 8'h94: b = 8'hD0; 8'h95: b = 8'hF8; 8'h96: b = 8'hE6; 8'h97: b = 8'h45;
            8'h98: b = 8'hB1; 8'h99: b = 8'h44; 8'h9A: b = 8'h8D; 8'h9B: b = 8'hF0; 8'h9C: b = 8'hC0; 8'h9D: b = 8'hC8; 8'h9E: b = 8'hD0; 8'h9F: b = 8'hF8;
            8'hA0: b = 8'hC6; 8'hA1: b = 8'h45; 8'hA2: b = 8'hAD; 8'hA3: b = 8'hF4; 8'hA4: b = 8'hC0; 8'hA5: b = 8'h30; 8'hA6: b = 8'hFB; 8'hA7: b = 8'h4C;
            8'hA8: b = 8'h61; 8'hA9: b = 8'hC7; 8'hAA: b = 8'hA9; 8'hAB: b = 8'h27; 8'hAC: b = 8'h38; 8'hAD: b = 8'h60;
            8'hFC: b = 8'hFF; 8'hFD: b = 8'hFF;   // 65,535 blocks
            // removable (the page can swap the volume), two volumes,
            // status/read/write.  Not $17: MECC's Computer Inspector names
            // exactly $Cn07=$3C + $CnFE=$17 a Corvus Transporter.
            8'hFE: b = 8'h97;
            8'hFF: b = 8'h29;                   // driver entry, $C729
            default: b = 8'h00;
            endcase
            rom = b;
        end
    endfunction
    assign rom_data = rom(addr[7:0]);

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
