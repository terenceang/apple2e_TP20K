// Apple //e Input Controller for Tang Nano 20K
// Handles UART RX (115200 baud) for Bluetooth-to-UART / USB-C keyboard & gamepad
//
// Host-to-Apple protocol, all at 115200 8N1:
//
//   0x02                     toggle the hardware debugger in serial_debugger
//   0xFE <code> <buttons>    one keypress: <code> is the final 7-bit Apple II
//                            key code, <buttons> bit0/1/2 = PB0/PB1/PB2
//   0xFF 0x01 <b> <x> <y>    gamepad: buttons, paddle 0, paddle 1
//   0xFF 0x04                all keys up: clears any-key-down (AKD, $C010 bit 7).
//                            A plain ASCII key has no release event, so its AKD
//                            drops on its own after ~100 ms
//   0xFF 0x03 <b>            RESET key: b bit3 = RESET held, bits 0-2 = PB0-2
//                            (sent only with CONTROL down: the //e's RESET line
//                            is CONTROL-gated, and the host owns modifiers)
//   0x1B '[' A|B|C|D         cursor keys, mapped to 0x0B/0x0A/0x15/0x08
//   anything else            a single ASCII keystroke
//
// 0xFE is a packet leader, so a dumb terminal that sends a raw 0xFE for '~'
// now starts a key packet instead of typing '~'; send "FE 7E 00" for that
// character. The key packet is why shift and caps lock are resolved by the
// sender: on real hardware the Apple IIe keyboard PROM (341-0132-D) turns a
// key position plus the shift/caps lines into the character in $C000, and the
// Apple II ROMs take D6-D0 as the final character, so nothing downstream needs
// to know a modifier was held.

`include "src/uart_defs.vh"

module input_controller (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,
    input  wire        ce_1m,         // 1.023 MHz clock enable
    input  wire        uart_rx,       // Serial RX (Pin 70)

    // Debugger Interface
    input  wire        dbg_mode,      // 1: Ignore Apple II keys when in debugger
    output wire [7:0]  rx_byte,       // Received byte
    output wire        rx_valid,      // Received byte strobe

    // CPU Bus Interface
    input  wire [7:0]  io_addr,       // $C0xx offset (A[7:0])
    input  wire        io_read,       // Read strobe
    input  wire        io_write,      // Write strobe
    output reg  [7:0]  io_dout,
    output wire        io_hit,        // Address recognized

    // Diagnostic indicator
    output wire        key_strobe,
    output wire        kbd_reset      // RESET key held
);

    // 115200 baud receiver at 27 MHz; the divisor is src/uart_defs.vh
    localparam [8:0] CLKS_PER_BIT = `UART_CLKS_PER_BIT;
    localparam [8:0] HALF_BIT     = `UART_CLKS_HALF_BIT;

    // UART RX synchronizer
    reg [2:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[1:0], uart_rx};
    wire rx_bit = rx_sync[2];

    // UART Receiver State Machine
    localparam URX_IDLE  = 3'd0;
    localparam URX_START = 3'd1;
    localparam URX_DATA  = 3'd2;
    localparam URX_STOP  = 3'd3;

    reg [2:0] urx_state = URX_IDLE;
    reg [8:0] urx_cnt   = 9'd0;
    reg [2:0] urx_idx   = 3'd0;
    reg [7:0] urx_byte  = 8'd0;
    reg       urx_valid = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            urx_state <= URX_IDLE;
            urx_cnt   <= 9'd0;
            urx_idx   <= 3'd0;
            urx_byte  <= 8'd0;
            urx_valid <= 1'b0;
        end else begin
            urx_valid <= 1'b0;
            case (urx_state)
                URX_IDLE: begin
                    if (!rx_bit) begin // Start bit detected
                        urx_cnt   <= 9'd0;
                        urx_state <= URX_START;
                    end
                end

                URX_START: begin
                    if (urx_cnt == HALF_BIT) begin
                        if (!rx_bit) begin // Confirm start bit
                            urx_cnt   <= 9'd0;
                            urx_idx   <= 3'd0;
                            urx_state <= URX_DATA;
                        end else begin
                            urx_state <= URX_IDLE;
                        end
                    end else begin
                        urx_cnt <= urx_cnt + 1'b1;
                    end
                end

                URX_DATA: begin
                    if (urx_cnt == CLKS_PER_BIT - 1) begin
                        urx_cnt <= 9'd0;
                        urx_byte[urx_idx] <= rx_bit;
                        if (urx_idx == 3'd7) begin
                            urx_state <= URX_STOP;
                        end else begin
                            urx_idx <= urx_idx + 1'b1;
                        end
                    end else begin
                        urx_cnt <= urx_cnt + 1'b1;
                    end
                end

                URX_STOP: begin
                    if (urx_cnt == CLKS_PER_BIT - 1) begin
                        urx_valid <= 1'b1;
                        urx_state <= URX_IDLE;
                    end else begin
                        urx_cnt <= urx_cnt + 1'b1;
                    end
                end
                default: urx_state <= URX_IDLE;
            endcase
        end
    end

    // Keyboard & Gamepad Registers
    reg [7:0] kbd_data = 8'h00; // Bit 7: strobe, Bits 6:0: final key code
    reg       pb0 = 1'b0;       // Pushbutton 0 ($C061 - Open Apple)
    reg       pb1 = 1'b0;       // Pushbutton 1 ($C062 - Solid Apple)
    reg       pb2 = 1'b0;       // Pushbutton 2 ($C063)
    reg       key_reset = 1'b0; // RESET key held
    reg [7:0] joy_pdl0 = 8'd128; // Analog paddle 0 (default center)
    reg [7:0] joy_pdl1 = 8'd128; // Analog paddle 1 (default center)

    // Paddle countdown timers (triggered on $C070 read)
    reg [11:0] pdl0_cnt = 12'd0;
    reg [11:0] pdl1_cnt = 12'd0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pdl0_cnt <= 12'd0;
            pdl1_cnt <= 12'd0;
        end else begin
            // Trigger countdown on $C070-$C07F read
            if (io_read && (io_addr[7:4] == 4'h7)) begin
                // ~11 us (11 CPU cycles, one PREAD loop) per count, 0..2805
                pdl0_cnt <= {4'b0, joy_pdl0} * 12'd11;
                pdl1_cnt <= {4'b0, joy_pdl1} * 12'd11;
            end else if (ce_1m) begin
                if (pdl0_cnt > 12'd0) pdl0_cnt <= pdl0_cnt - 1'b1;
                if (pdl1_cnt > 12'd0) pdl1_cnt <= pdl1_cnt - 1'b1;
            end
        end
    end

    // Protocol parser for Keyboard and Gamepad packets:
    // Packet types:
    // 1. Standard ASCII: 0x01..0x7E, 0x0D (Return), 0x08/0x7F (Backspace)
    // 2. ANSI Escape Sequences: ESC [ A/B/C/D (Up/Down/Right/Left)
    // 3. Gamepad Packet: 0xFF 0x01 <buttons> <joy_x> <joy_y>
    // 4. Key Packet: 0xFE <code> <buttons>  (see below)
    localparam PKT_NORMAL = 4'd0;
    localparam PKT_ESC    = 4'd1;
    localparam PKT_BRACKET= 4'd2;
    localparam PKT_GP_HDR = 4'd3;
    localparam PKT_GP_BTN = 4'd4;
    localparam PKT_GP_X   = 4'd5;
    localparam PKT_GP_Y   = 4'd6;
    localparam PKT_KEY_CODE= 4'd8;
    localparam PKT_KEY_BTN= 4'd9;
    localparam PKT_RST_BTN= 4'd10;

    reg [3:0] pkt_state = PKT_NORMAL;

    // The key that follows a lone ESC, held until the CPU has read the ESC
    reg       pend_valid = 1'b0;
    reg [6:0] pend_key   = 7'd0;
    // A lone ESC (no '[' after it) is delivered after ~39 ms of silence
    reg [19:0] esc_cnt   = 20'd0;

    // Any-key-down for $C010 bit 7. FE packets hold it until FF 04 (all keys
    // up); a plain ASCII sender has no release event, so it drops after ~100 ms.
    reg        akd        = 1'b0;
    reg        akd_legacy = 1'b0;
    reg [21:0] akd_cnt    = 22'd0;
    localparam [21:0] AKD_LEGACY_CLKS = 22'd2700000;

    // CR/LF are Return, DEL is backspace
    wire [6:0] norm_key = (urx_byte == 8'h0A || urx_byte == 8'h0D) ? 7'h0D :
                          (urx_byte == 8'h7F || urx_byte == 8'h08) ? 7'h08 :
                          urx_byte[6:0];

    // Deliver a legacy (plain ASCII style) key: strobe it into $C000 and hold
    // AKD for ~100 ms, since a plain sender has no release event. The FE key
    // packet path below keeps AKD until FF 04 instead, so it does not use this.
    task deliver_key(input [6:0] k);
        begin
            kbd_data   <= {1'b1, k};
            akd        <= 1'b1;
            akd_legacy <= 1'b1;
            akd_cnt    <= AKD_LEGACY_CLKS;
        end
    endtask

    // The paddle-button bits of a FE/FF packet (PB0/PB1/PB2)
    task latch_buttons(input [7:0] b);
        begin
            pb0 <= b[0];
            pb1 <= b[1];
            pb2 <= b[2];
        end
    endtask

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            kbd_data  <= 8'h00;
            pkt_state <= PKT_NORMAL;
            pend_valid <= 1'b0;
            esc_cnt    <= 20'd0;
            akd        <= 1'b0;
            akd_legacy <= 1'b0;
            akd_cnt    <= 22'd0;
            pb0       <= 1'b0;
            pb1       <= 1'b0;
            pb2       <= 1'b0;
            key_reset <= 1'b0;
            joy_pdl0  <= 8'd128;
            joy_pdl1  <= 8'd128;
        end else begin
            // Clear keyboard strobe on $C010 access
            if ((io_read || io_write) && (io_addr == 8'h10)) begin
                kbd_data[7] <= 1'b0;
            end

            // Deliver the key that followed a lone ESC once the ESC is read
            if (pend_valid && !kbd_data[7]) begin
                kbd_data   <= {1'b1, pend_key};
                pend_valid <= 1'b0;
            end

            // Lone ESC: nothing followed it, so it is the ESC key
            if (pkt_state == PKT_ESC && !urx_valid) begin
                esc_cnt <= esc_cnt + 1'b1;
                if (&esc_cnt) begin
                    deliver_key(7'h1B);
                    pkt_state <= PKT_NORMAL;
                end
            end else begin
                esc_cnt <= 20'd0;
            end

            if (akd && akd_legacy) begin
                if (akd_cnt == 22'd0) akd <= 1'b0;
                else                  akd_cnt <= akd_cnt - 1'b1;
            end

            if (urx_valid && !dbg_mode && (urx_byte != 8'h02)) begin
                case (pkt_state)
                    PKT_NORMAL: begin
                        if (urx_byte == 8'hFF) begin
                            pkt_state <= PKT_GP_HDR;
                        end else if (urx_byte == 8'hFE) begin
                            // 0xFE is only a leader; the code is the next byte
                            pkt_state <= PKT_KEY_CODE;
                        end else if (urx_byte == 8'h1B) begin // ESC
                            pkt_state <= PKT_ESC;
                        end else begin
                            // Standard keystroke, with strobe
                            deliver_key(norm_key);
                        end
                    end

                    PKT_ESC: begin
                        if (urx_byte == 8'h5B) // '['
                            pkt_state <= PKT_BRACKET;
                        else begin
                            deliver_key(7'h1B); // Raw ESC key
                            // ...and the byte that followed it is not lost
                            if (urx_byte == 8'hFF)      pkt_state <= PKT_GP_HDR;
                            else if (urx_byte == 8'hFE) pkt_state <= PKT_KEY_CODE;
                            else if (urx_byte == 8'h1B) pkt_state <= PKT_ESC;
                            else begin
                                pend_valid <= 1'b1;
                                pend_key   <= norm_key;
                                pkt_state  <= PKT_NORMAL;
                            end
                        end
                    end

                    PKT_BRACKET: begin
                        case (urx_byte)
                            8'h41: deliver_key(7'h0B); // Up Arrow (Ctrl-K / 0x0B)
                            8'h42: deliver_key(7'h0A); // Down Arrow (Ctrl-J / 0x0A)
                            8'h43: deliver_key(7'h15); // Right Arrow (Ctrl-U / 0x15)
                            8'h44: deliver_key(7'h08); // Left Arrow (Ctrl-H / 0x08)
                            default: ;
                        endcase
                        pkt_state <= PKT_NORMAL;
                    end

                    PKT_GP_HDR: begin
                        if (urx_byte == 8'h01)
                            pkt_state <= PKT_GP_BTN;
                        else if (urx_byte == 8'h03)
                            pkt_state <= PKT_RST_BTN;
                        else begin
                            if (urx_byte == 8'h04) akd <= 1'b0; // all keys up
                            pkt_state <= PKT_NORMAL;
                        end
                    end

                    PKT_GP_BTN: begin
                        latch_buttons(urx_byte);
                        pkt_state <= PKT_GP_X;
                    end

                    PKT_GP_X: begin
                        joy_pdl0  <= urx_byte;
                        pkt_state <= PKT_GP_Y;
                    end

                    PKT_GP_Y: begin
                        joy_pdl1  <= urx_byte;
                        pkt_state <= PKT_NORMAL;
                    end

                    // 0xFE <code> <buttons>: one keypress with the paddle
                    // button state that goes with it. <code> is the final
                    // 7-bit Apple II key code (shift and caps lock already
                    // resolved by the sender, which is the job the Apple IIe
                    // keyboard PROM does on real hardware). <buttons> bits
                    // 0/1/2 are PB0/PB1/PB2, so the Open-Apple and Solid-Apple
                    // keys drive the game paddles the way they do in hardware.
                    PKT_KEY_CODE: begin
                        kbd_data   <= {1'b1, urx_byte[6:0]};
                        akd        <= 1'b1;
                        akd_legacy <= 1'b0; // held until FF 04
                        pkt_state  <= PKT_KEY_BTN;
                    end

                    PKT_KEY_BTN: begin
                        latch_buttons(urx_byte);
                        pkt_state <= PKT_NORMAL;
                    end

                    PKT_RST_BTN: begin
                        latch_buttons(urx_byte);
                        key_reset <= urx_byte[3];
                        pkt_state <= PKT_NORMAL;
                    end

                    default: pkt_state <= PKT_NORMAL;
                endcase
            end
        end
    end

    assign key_strobe = kbd_data[7];
    assign kbd_reset  = key_reset;
    assign rx_byte    = urx_byte;
    assign rx_valid   = urx_valid;

    // Address Decoding for Input registers ($C000-$C07F):
    // $C000: Keyboard data (bit 7: strobe, bits 6:0: ASCII)
    // $C010: Clear strobe, returns AKD (any-key-down) or strobe in bit 7
    // $C061: PB0 (Open-Apple / Game Pushbutton 0), bit 7
    // $C062: PB1 (Solid-Apple / Game Pushbutton 1), bit 7
    // $C063: PB2 (Game Pushbutton 2), bit 7
    // $C064: PDL0 analog countdown, bit 7
    // $C065: PDL1 analog countdown, bit 7
    assign io_hit = (io_addr[7:4] == 4'h0) || (io_addr == 8'h10) ||
                    (io_addr[7:4] == 4'h6) || (io_addr[7:4] == 4'h7);

    reg in_bit;
    always @(*) begin
        case (io_addr[3:0])
            4'h1:    in_bit = pb0;                         // $C061 PB0
            4'h2:    in_bit = pb1;                         // $C062 PB1
            4'h3:    in_bit = pb2;                         // $C063 PB2
            4'h4:    in_bit = (pdl0_cnt != 12'd0);          // $C064 PDL0
            4'h5:    in_bit = (pdl1_cnt != 12'd0);          // $C065 PDL1
            default: in_bit = 1'b0;
        endcase
    end

    always @(*) begin
        case (io_addr[7:4])
            4'h0:       io_dout = kbd_data;                 // $C000-$C00F
            // Only $C010 is ours in this nibble (io_hit above); $C011-$C01F
            // are status reads the core answers with softswitch_read_data.
            4'h1:       io_dout = {akd, kbd_data[6:0]};     // $C010: AKD + key
            4'h6:       io_dout = {in_bit, 7'h00};          // $C060-$C06F
            default:    io_dout = 8'h00;                    // $C070-$C07F & others
        endcase
    end

endmodule
