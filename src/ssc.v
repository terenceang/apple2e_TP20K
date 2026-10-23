// Apple Super Serial Card in slot 1: a 6551 ACIA, its DIP switches and its
// 2 KB firmware, with the serial line carried over the Dock's USB link to the
// web page, which plays a Hayes modem (web/src/modem.js).
//
// $C098 data (read: the received byte, clears RDRF; write: send a byte)
// $C099 status (read; clears IRQ)  / programmed reset (write)
// $C09A command    $C09B control (baud in bits 3:0)
// $C091 SW1, $C092 SW2: the DIP switches, set as AppleWin's defaults -- SSC
// (communications) mode, 9600 baud, 8 data bits, 1 stop, no parity, no
// auto line feed, CTS asserted.
//
// Firmware: the card's ROM (341-0065-A) is Apple's, supplied as roms/ssc.hex
// like the //e's own (roms/README.md); without it the build defines
// SSC_NO_ROM and the slot reads zeros, so only software that drives the 6551
// itself can use the card.  $C100-$C1FF is ROM offset $700, and $C800-$CFFF
// the whole 2 KB once the card has claimed the expansion space (slot_bus).
//
// The line: a byte the Apple sends goes to serial_debugger, which frames it
// for the page (1E <byte>); a byte from the page arrives from input_controller
// (FF 06) into a 64-byte FIFO, and moves into the receive register one
// character time apart at the programmed baud (10 bits a byte), so software
// sees the line speed it set.  The transmitter is busy for one character time
// after each write, likewise.  DTR and the baud go to the page whenever they
// change (1F <st>: bit 7 set, bit 6 DTR, bits 3:0 the baud code), and the
// page's carrier and DSR come back as the status bits (FF 07).
`include "src/hdmi/hdmi_defs.vh"   // VM_PIXEL_HZ: the clock
`default_nettype none

module ssc (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,

    input  wire        bus_cycle,     // a real CPU cycle
    input  wire        cpu_we,
    input  wire [15:0] addr,          // the effective CPU address
    input  wire [7:0]  din,
    input  wire        devsel_n,      // slot 1's /DEVSEL from slot_bus: side effects only
    output wire [7:0]  io_data,       // $C090-$C09F read data, by address alone
    output wire [7:0]  rom_data,      // $C1xx, or $C800-$CFFF while the card holds it
    output wire        irq_n,

    // the modem, through the USB link
    input  wire [7:0]  rx_data,       // a byte from the page
    input  wire        rx_valid,
    input  wire [1:0]  lines,         // {DSR, DCD}, 1 = asserted
    output reg         tx_req = 1'b0, // a byte for the page...
    output reg  [7:0]  tx_byte = 8'd0,
    input  wire        tx_ack,        // ...taken
    output reg         st_req = 1'b0, // DTR or the baud changed...
    output wire [7:0]  st_byte,
    input  wire        st_ack         // ...sent
);

    // ------------------------------------------------------------------
    // The 6551's registers
    // ------------------------------------------------------------------
    reg [7:0] cmd = 8'h00, ctl = 8'h00, rdr = 8'h00;
    reg       rdrf = 1'b0, ovr = 1'b0, irq_flag = 1'b0;
    reg       tdre = 1'b1;                // the transmitter can take a byte
    wire      dtr  = cmd[0];
    wire      rx_irq_en = dtr && !cmd[1];
    wire      tx_irq_en = dtr && (cmd[3:2] == 2'b01);

    // one character (10 bits) at the programmed rate, in clocks, rounded
`define SSC_CHAR(baud) (((10 * `VM_PIXEL_HZ) + (baud) / 2) / (baud))
    function [21:0] char_clks(input [3:0] b);
        case (b)
            4'd0:  char_clks = `SSC_CHAR(115200);  // internal clock
            4'd6:  char_clks = `SSC_CHAR(300);
            4'd7:  char_clks = `SSC_CHAR(600);
            4'd8:  char_clks = `SSC_CHAR(1200);
            4'd9:  char_clks = `SSC_CHAR(1800);
            4'd10: char_clks = `SSC_CHAR(2400);
            4'd11: char_clks = `SSC_CHAR(3600);
            4'd12: char_clks = `SSC_CHAR(4800);
            4'd13: char_clks = `SSC_CHAR(7200);
            4'd14: char_clks = `SSC_CHAR(9600);
            4'd15: char_clks = `SSC_CHAR(19200);
            default: char_clks = `SSC_CHAR(110);   // 50-150: as 110
        endcase
    endfunction
`undef SSC_CHAR

    // address decode: reads by address (the read mux needs no strobe), side
    // effects and writes on slot 1's /DEVSEL, which is bus_cycle-qualified
    wire [3:0] ra   = addr[3:0];
    wire       acc  = !devsel_n && bus_cycle;   // not the debugger's reads (bus_cycle is cpu_go)
    wire       rd_data_acc   = acc && !cpu_we && ra == 4'h8;
    wire       rd_status_acc = acc && !cpu_we && ra == 4'h9;
    wire       wr = acc && cpu_we;

    wire [7:0] status = {irq_flag, !lines[1], !lines[0], tdre, rdrf, ovr, 2'b00};
    reg  [7:0] io_q;
    always @(*)
        case (ra)
            4'h1:    io_q = 8'hE0;    // SW1: 9600 baud, SSC mode
            4'h2:    io_q = 8'h02;    // SW2: 1 stop, 8 bits, no parity, no LF, CTS on
            4'h8:    io_q = rdr;
            4'h9:    io_q = status;
            4'hA:    io_q = cmd;
            4'hB:    io_q = ctl;
            default: io_q = 8'h00;
        endcase
    assign io_data = io_q;
    assign irq_n   = !irq_flag;

    // ------------------------------------------------------------------
    // Receive: a FIFO from the page, paced into RDR at the baud
    // ------------------------------------------------------------------
    reg [7:0] fifo [0:63];
    reg [5:0] f_wr = 6'd0, f_rd = 6'd0;
    reg [6:0] f_n  = 7'd0;
    reg [21:0] rx_t = 22'd0;          // clocks until the next byte may land
    wire      f_take = (f_n != 7'd0) && !rdrf && (rx_t == 22'd0);
    always @(posedge clk) if (rx_valid && dtr && f_n != 7'd64) fifo[f_wr] <= rx_data;

    // ------------------------------------------------------------------
    // Transmit: busy for one character after a write
    // ------------------------------------------------------------------
    reg [21:0] tx_t = 22'd0;

    // DTR and the baud, for the page
    reg  [4:0] st_sent = 5'h1F;       // {DTR, baud} last sent ('1F: none yet)
    wire [4:0] st_now  = {dtr, ctl[3:0]};
    assign st_byte = {1'b1, st_now[4], 2'b00, st_now[3:0]};

    always @(posedge clk) begin
        if (reset) begin
            cmd <= 8'h00; ctl <= 8'h00; rdrf <= 1'b0; ovr <= 1'b0; irq_flag <= 1'b0;
            f_wr <= 6'd0; f_rd <= 6'd0; f_n <= 7'd0; rx_t <= 22'd0;
            tx_t <= 22'd0; tdre <= 1'b1; tx_req <= 1'b0;
            st_req <= 1'b0; st_sent <= 5'h1F;
        end else begin
            // the CPU's reads clear first, so a flag raised in the same clock
            // wins (a status read as a byte lands must not lose its IRQ)
            if (rd_data_acc)   begin rdrf <= 1'b0; ovr <= 1'b0; end
            if (rd_status_acc) irq_flag <= 1'b0;

            // the FIFO, and RDR at the line's pace
            if (rx_t != 22'd0) rx_t <= rx_t - 22'd1;
            case ({rx_valid && dtr && f_n != 7'd64, f_take})
                2'b10: begin f_wr <= f_wr + 6'd1; f_n <= f_n + 7'd1; end
                2'b01: begin f_rd <= f_rd + 6'd1; f_n <= f_n - 7'd1; end
                2'b11: begin f_wr <= f_wr + 6'd1; f_rd <= f_rd + 6'd1; end
                default: ;
            endcase
            if (rx_valid && dtr && f_n == 7'd64) ovr <= 1'b1;     // the page outran it
            if (f_take) begin
                rdr  <= fifo[f_rd];
                rdrf <= 1'b1;
                rx_t <= char_clks(ctl[3:0]);
                if (rx_irq_en) irq_flag <= 1'b1;
            end

            // the transmitter: the byte goes to the page, and the register is
            // busy for a character time
            if (tx_t != 22'd0) tx_t <= tx_t - 22'd1;
            if (tx_req && tx_ack) tx_req <= 1'b0;
            if (!tdre && tx_t == 22'd0 && !tx_req) begin
                tdre <= 1'b1;
                if (tx_irq_en) irq_flag <= 1'b1;
            end

            // DTR or baud changed: tell the page
            if (st_req && st_ack) begin st_req <= 1'b0; st_sent <= st_now; end
            else if (!st_req && st_now != st_sent) st_req <= 1'b1;

            // the CPU's writes
            if (wr) case (ra)
                4'h8: begin
                    tx_byte <= din;
                    tdre    <= 1'b0;
                    tx_t    <= char_clks(ctl[3:0]);
                    if (dtr) tx_req <= 1'b1;            // no DTR: nothing on the line
                end
                4'h9: begin cmd <= cmd & 8'hE0; ovr <= 1'b0; end   // programmed reset
                4'hA: cmd <= din;
                4'hB: ctl <= din;
                default: ;
            endcase
            if (!dtr) begin f_wr <= 6'd0; f_rd <= 6'd0; f_n <= 7'd0; end   // DTR off: the line is down
        end
    end

    // ------------------------------------------------------------------
    // The firmware
    // ------------------------------------------------------------------
`ifdef SSC_NO_ROM
    assign rom_data = 8'h00;          // no firmware: no block RAM spent on it either
`else
    reg [7:0] rom [0:2047];
    reg [7:0] rom_q = 8'h00;
    initial $readmemh("roms/ssc.hex", rom);
    // latched every clock from the address, as the Disk II's P6 ROM is: the
    // CPU samples on the strobe's own edge
    always @(posedge clk) rom_q <= rom[addr[11] ? addr[10:0] : {3'b111, addr[7:0]}];
    assign rom_data = rom_q;
`endif

endmodule

`default_nettype wire
