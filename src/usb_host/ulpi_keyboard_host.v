// ============================================================================
//  ulpi_keyboard_host.v -- ULPI USB 2.0 HID Keyboard Host Controller
//
//  Directly interfaces with the Microchip USB3317 ULPI PHY on the
//  Sipeed Tang Primer 20K Dock board (connected to USB-C port J8).
//
//  Functions:
//    1. Initializes USB3317 PHY into USB Host mode with 15k pull-downs.
//    2. Auto-detects keyboard connection (Full-Speed or Low-Speed).
//    3. Resets USB bus and performs standard USB enumeration:
//       - SET_ADDRESS (Address 1)
//       - SET_CONFIGURATION (Config 1)
//       - SET_IDLE (Duration 0 - report on change only)
//    4. Periodically polls Interrupt Endpoint 1 (IN token every ~10 ms).
//    5. Receives standard 8-byte Boot Keyboard HID reports:
//       - Modifier byte -> Left Alt/GUI (Open-Apple), Right Alt (Closed-Apple)
//       - Scancode 1-6 -> Decoded into 7-bit Apple //e ASCII character
//       - Ctrl + Alt + Delete -> Triggers Apple //e Hardware Reset!
//    6. Synchronizes decoded key events to the Apple //e pixel clock (27 MHz).
// ============================================================================

module ulpi_keyboard_host #(
    parameter CLK_HZ = 60_000_000
) (
    input  wire        clk_60m,       // ULPI 60 MHz clock from USB3317 (T15)
    input  wire        reset,         // System reset
    input  wire        clk_pixel,     // Apple //e pixel clock (27 MHz)

    // ULPI Physical Interface (USB3317 on Dock J8)
    input  wire        ulpi_dir,      // PHY drives bus (1 = RX / status, 0 = TX)
    input  wire        ulpi_nxt,      // PHY accepts byte (TX) or byte valid (RX)
    output reg         ulpi_stp = 1'b0, // Link asserts to terminate packet/register write
    output reg         ulpi_reset_n = 1'b0, // Active-low PHY hardware reset (F10)
    input  wire [7:0]  ulpi_data_i,   // Data in from PHY
    output reg  [7:0]  ulpi_data_o = 8'h00, // Data out to PHY
    output reg         ulpi_data_oe = 1'b0, // Output enable for bidirectional data bus

    // Apple //e Keyboard Interface (Synchronous to clk_pixel)
    output reg         key_valid = 1'b0,  // Strobe for new keypress
    output reg  [6:0]  key_code  = 7'h00, // Apple 7-bit character code
    output reg         key_akd   = 1'b0,  // Any-key-down status ($C010 bit 7)
    output reg         btn_oa    = 1'b0,  // Open-Apple ($C061 PB0) from L-Alt / GUI
    output reg         btn_ca    = 1'b0,  // Closed-Apple ($C062 PB1) from R-Alt
    output reg         btn_reset = 1'b0   // Reset key (e.g. Ctrl-Alt-Del)
);

    // =========================================================================
    // 1. ULPI Register Addresses & USB Constants
    // =========================================================================
    localparam REG_FUNC_CTRL = 6'h04;
    localparam REG_OTG_CTRL  = 6'h0A;

    // USB PIDs
    localparam PID_SETUP = 4'hD;
    localparam PID_DATA0 = 4'h3;
    localparam PID_DATA1 = 4'hB;
    localparam PID_IN    = 4'h9;
    localparam PID_ACK   = 4'h2;
    localparam PID_NAK   = 4'hA;

    // ULPI TX Commands
    localparam [7:0] TXCMD_REG_WR = 8'h80; // 10_xxxxxx (Write to register)
    localparam [7:0] TXCMD_XMIT   = 8'h40; // 01_00_xxxx (Transmit USB PID)

    // =========================================================================
    // 2. State Machine (Running on 60 MHz clk_60m)
    // =========================================================================
    localparam S_HW_RESET       = 5'd0;
    localparam S_PHY_WAIT_IDLE  = 5'd1;
    localparam S_WR_FUNC_CTRL   = 5'd2;
    localparam S_WR_FUNC_DATA   = 5'd3;
    localparam S_WR_OTG_CTRL    = 5'd4;
    localparam S_WR_OTG_DATA    = 5'd5;
    localparam S_WAIT_DEVICE    = 5'd6;
    localparam S_BUS_RESET_START= 5'd7;
    localparam S_BUS_RESET_WAIT = 5'd8;
    localparam S_BUS_RESET_END  = 5'd9;
    localparam S_ENUM_DELAY     = 5'd10;
    localparam S_TX_SETUP_TOKEN = 5'd11;
    localparam S_TX_SETUP_DATA  = 5'd12;
    localparam S_WAIT_SETUP_ACK = 5'd13;
    localparam S_TX_STATUS_IN   = 5'd14;
    localparam S_WAIT_STATUS_DATA = 5'd15;
    localparam S_TX_STATUS_ACK  = 5'd16;
    localparam S_POLL_DELAY     = 5'd17;
    localparam S_TX_POLL_IN     = 5'd18;
    localparam S_WAIT_POLL_DATA = 5'd19;
    localparam S_TX_POLL_ACK    = 5'd20;

    reg [4:0]  state = S_HW_RESET;
    reg [23:0] timer = 24'd0;
    reg [1:0]  enum_step = 2'd0; // 0=SET_ADDRESS, 1=SET_CONFIG, 2=SET_IDLE
    reg [3:0]  tx_byte_idx = 4'd0;
    reg [1:0]  line_state = 2'b00;
    reg [1:0]  dev_speed  = 2'b00; // 2'b01 = Full-Speed, 2'b10 = Low-Speed
    reg        dev_connected = 1'b0;

    // Report buffer (8 bytes of standard USB HID boot keyboard report)
    reg [7:0]  rx_report [0:7];
    reg [3:0]  rx_byte_cnt = 4'd0;
    reg [3:0]  rx_pid = 4'd0;
    reg        report_valid = 1'b0;

    // Constant packet payloads for enumeration
    // SET_ADDRESS (addr 1): SETUP token (addr 0, ep 0, CRC5=0x02)
    // DATA0: 00 05 01 00 00 00 00 00 [CRC16: EB 25]
    // SET_CONFIG (config 1): SETUP token (addr 1, ep 0, CRC5=0x1D)
    // DATA0: 00 09 01 00 00 00 00 00 [CRC16: 27 25]
    // SET_IDLE (idle 0): SETUP token (addr 1, ep 0, CRC5=0x1D)
    // DATA0: 21 0A 00 00 00 00 00 00 [CRC16: D6 20]
    // POLL KEYBOARD: IN token (addr 1, ep 1, CRC5=0x0B)
    function [7:0] get_setup_byte(input [1:0] step, input [3:0] idx);
        case (step)
            2'd0: case (idx) // SET_ADDRESS 1
                4'd0: get_setup_byte = 8'h00;
                4'd1: get_setup_byte = 8'h05;
                4'd2: get_setup_byte = 8'h01;
                4'd3: get_setup_byte = 8'h00;
                4'd4: get_setup_byte = 8'h00;
                4'd5: get_setup_byte = 8'h00;
                4'd6: get_setup_byte = 8'h00;
                4'd7: get_setup_byte = 8'h00;
                4'd8: get_setup_byte = 8'hEB;
                4'd9: get_setup_byte = 8'h25;
                default: get_setup_byte = 8'h00;
            endcase
            2'd1: case (idx) // SET_CONFIG 1
                4'd0: get_setup_byte = 8'h00;
                4'd1: get_setup_byte = 8'h09;
                4'd2: get_setup_byte = 8'h01;
                4'd3: get_setup_byte = 8'h00;
                4'd4: get_setup_byte = 8'h00;
                4'd5: get_setup_byte = 8'h00;
                4'd6: get_setup_byte = 8'h00;
                4'd7: get_setup_byte = 8'h00;
                4'd8: get_setup_byte = 8'h27;
                4'd9: get_setup_byte = 8'h25;
                default: get_setup_byte = 8'h00;
            endcase
            default: case (idx) // SET_IDLE 0
                4'd0: get_setup_byte = 8'h21;
                4'd1: get_setup_byte = 8'h0A;
                4'd2: get_setup_byte = 8'h00;
                4'd3: get_setup_byte = 8'h00;
                4'd4: get_setup_byte = 8'h00;
                4'd5: get_setup_byte = 8'h00;
                4'd6: get_setup_byte = 8'h00;
                4'd7: get_setup_byte = 8'h00;
                4'd8: get_setup_byte = 8'hD6;
                4'd9: get_setup_byte = 8'h20;
                default: get_setup_byte = 8'h00;
            endcase
        endcase
    endfunction

    // =========================================================================
    // 3. ULPI Bus Control & Protocol State Machine
    // =========================================================================
    always @(posedge clk_60m or posedge reset) begin
        if (reset) begin
            state         <= S_HW_RESET;
            timer         <= 24'd0;
            ulpi_reset_n  <= 1'b0;
            ulpi_stp      <= 1'b0;
            ulpi_data_oe  <= 1'b0;
            ulpi_data_o   <= 8'h00;
            enum_step     <= 2'd0;
            dev_connected <= 1'b0;
            report_valid  <= 1'b0;
        end else begin
            ulpi_stp     <= 1'b0;
            report_valid <= 1'b0;

            // Monitor LineState from ULPI RX CMD (when DIR=1, NXT=0)
            if (ulpi_dir && !ulpi_nxt) begin
                line_state <= ulpi_data_i[7:6];
            end

            case (state)
                // 1. Hardware Reset: hold RESETB low for ~2 ms (120,000 clocks)
                S_HW_RESET: begin
                    ulpi_reset_n <= 1'b0;
                    ulpi_data_oe <= 1'b0;
                    if (timer < 24'd120_000)
                        timer <= timer + 1'b1;
                    else begin
                        ulpi_reset_n <= 1'b1; // Release PHY reset
                        timer        <= 24'd0;
                        state        <= S_PHY_WAIT_IDLE;
                    end
                end

                // 2. Wait for PHY to complete internal calibration and drop DIR
                S_PHY_WAIT_IDLE: begin
                    ulpi_data_oe <= 1'b0;
                    if (!ulpi_dir) begin
                        if (timer < 24'd100)
                            timer <= timer + 1'b1;
                        else begin
                            timer <= 24'd0;
                            state <= S_WR_FUNC_CTRL;
                        end
                    end else
                        timer <= 24'd0;
                end

                // 3. Write Function Control (0x04): Enable Full-Speed / Active
                S_WR_FUNC_CTRL: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        ulpi_data_o  <= TXCMD_REG_WR | REG_FUNC_CTRL;
                        if (ulpi_nxt) begin
                            state <= S_WR_FUNC_DATA;
                        end
                    end
                end

                S_WR_FUNC_DATA: begin
                    if (!ulpi_dir) begin
                        ulpi_data_o  <= 8'h45; // SuspendM=1, TermSelect=1, XcvrSelect=01 (FS)
                        ulpi_stp     <= 1'b1;  // Stop bit commits register write
                        state        <= S_WR_OTG_CTRL;
                    end
                end

                // 4. Write OTG Control (0x0A): Enable 15k pull-downs (Host mode)
                S_WR_OTG_CTRL: begin
                    ulpi_stp <= 1'b0;
                    if (!ulpi_dir) begin
                        ulpi_data_o <= TXCMD_REG_WR | REG_OTG_CTRL;
                        if (ulpi_nxt) begin
                            state <= S_WR_OTG_DATA;
                        end
                    end
                end

                S_WR_OTG_DATA: begin
                    if (!ulpi_dir) begin
                        ulpi_data_o  <= 8'h06; // DpPulldown=1, DmPulldown=1
                        ulpi_stp     <= 1'b1;
                        ulpi_data_oe <= 1'b0;
                        timer        <= 24'd0;
                        state        <= S_WAIT_DEVICE;
                    end
                end

                // 5. Wait for device connection (J or K state on LineState)
                S_WAIT_DEVICE: begin
                    ulpi_data_oe <= 1'b0;
                    if (line_state == 2'b01 || line_state == 2'b10) begin
                        // Debounce device connection for ~100 ms (6,000,000 clocks)
                        if (timer < 24'd6_000_000)
                            timer <= timer + 1'b1;
                        else begin
                            dev_speed     <= line_state; // 01=FS, 10=LS
                            dev_connected <= 1'b1;
                            timer         <= 24'd0;
                            state         <= S_BUS_RESET_START;
                        end
                    end else begin
                        timer         <= 24'd0;
                        dev_connected <= 1'b0;
                    end
                end

                // 6. Bus Reset: Write Function Control with OpMode=10 (forces SE0)
                S_BUS_RESET_START: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        ulpi_data_o  <= TXCMD_REG_WR | REG_FUNC_CTRL;
                        if (ulpi_nxt) begin
                            state <= S_BUS_RESET_WAIT;
                        end
                    end
                end

                S_BUS_RESET_WAIT: begin
                    if (!ulpi_dir) begin
                        // OpMode=10 (Disable bit stuff / drive SE0), SuspendM=1
                        ulpi_data_o  <= 8'h55;
                        ulpi_stp     <= 1'b1;
                        timer        <= 24'd0;
                        state        <= S_BUS_RESET_END;
                    end
                end

                // Hold SE0 for ~20 ms (1,200,000 clocks)
                S_BUS_RESET_END: begin
                    ulpi_stp     <= 1'b0;
                    ulpi_data_oe <= 1'b0;
                    if (timer < 24'd1_200_000)
                        timer <= timer + 1'b1;
                    else begin
                        // Return OpMode to normal (00)
                        if (!ulpi_dir) begin
                            ulpi_data_oe <= 1'b1;
                            ulpi_data_o  <= TXCMD_REG_WR | REG_FUNC_CTRL;
                            if (ulpi_nxt) begin
                                ulpi_data_o  <= 8'h45; // OpMode=00
                                ulpi_stp     <= 1'b1;
                                timer        <= 24'd0;
                                enum_step    <= 2'd0;
                                state        <= S_ENUM_DELAY;
                            end
                        end
                    end
                end

                // Delay between enumeration steps (~10 ms = 600,000 clocks)
                S_ENUM_DELAY: begin
                    ulpi_stp     <= 1'b0;
                    ulpi_data_oe <= 1'b0;
                    if (timer < 24'd600_000)
                        timer <= timer + 1'b1;
                    else begin
                        timer       <= 24'd0;
                        tx_byte_idx <= 4'd0;
                        state       <= S_TX_SETUP_TOKEN;
                    end
                end

                // 7. Transmit SETUP Token (3 bytes: PID, Byte1, Byte2)
                S_TX_SETUP_TOKEN: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        if (tx_byte_idx == 4'd0) begin
                            ulpi_data_o <= TXCMD_XMIT | PID_SETUP;
                            if (ulpi_nxt) tx_byte_idx <= 4'd1;
                        end else if (tx_byte_idx == 4'd1) begin
                            // Byte 1: {EP[0]=0, ADDR[6:0]}
                            ulpi_data_o <= (enum_step == 2'd0) ? 8'h00 : 8'h01;
                            if (ulpi_nxt) tx_byte_idx <= 4'd2;
                        end else if (tx_byte_idx == 4'd2) begin
                            // Byte 2: {CRC5, EP[3:1]}
                            ulpi_data_o <= (enum_step == 2'd0) ? 8'h10 : 8'hE8;
                            ulpi_stp    <= 1'b1;
                            tx_byte_idx <= 4'd0;
                            state       <= S_TX_SETUP_DATA;
                        end
                    end
                end

                // Transmit DATA0 Setup Payload (10 bytes: 8 bytes setup + 2 bytes CRC16)
                S_TX_SETUP_DATA: begin
                    ulpi_stp <= 1'b0;
                    if (!ulpi_dir) begin
                        if (tx_byte_idx == 4'd0) begin
                            ulpi_data_o <= TXCMD_XMIT | PID_DATA0;
                            if (ulpi_nxt) tx_byte_idx <= 4'd1;
                        end else if (tx_byte_idx <= 4'd10) begin
                            ulpi_data_o <= get_setup_byte(enum_step, tx_byte_idx - 1'b1);
                            if (tx_byte_idx == 4'd10) ulpi_stp <= 1'b1;
                            if (ulpi_nxt) begin
                                if (tx_byte_idx == 4'd10) begin
                                    ulpi_data_oe <= 1'b0;
                                    timer        <= 24'd0;
                                    state        <= S_WAIT_SETUP_ACK;
                                end else
                                    tx_byte_idx <= tx_byte_idx + 1'b1;
                            end
                        end
                    end
                end

                // Wait for ACK from device
                S_WAIT_SETUP_ACK: begin
                    ulpi_data_oe <= 1'b0;
                    if (ulpi_dir && ulpi_nxt && (ulpi_data_i[3:0] == PID_ACK)) begin
                        timer       <= 24'd0;
                        tx_byte_idx <= 4'd0;
                        state       <= S_TX_STATUS_IN;
                    end else if (timer < 24'd600_000)
                        timer <= timer + 1'b1;
                    else begin
                        // Timeout: retry or advance
                        timer <= 24'd0;
                        state <= S_TX_STATUS_IN;
                    end
                end

                // Transmit IN token for Status Stage
                S_TX_STATUS_IN: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        if (tx_byte_idx == 4'd0) begin
                            ulpi_data_o <= TXCMD_XMIT | PID_IN;
                            if (ulpi_nxt) tx_byte_idx <= 4'd1;
                        end else if (tx_byte_idx == 4'd1) begin
                            ulpi_data_o <= (enum_step == 2'd0) ? 8'h00 : 8'h01;
                            if (ulpi_nxt) tx_byte_idx <= 4'd2;
                        end else if (tx_byte_idx == 4'd2) begin
                            ulpi_data_o <= (enum_step == 2'd0) ? 8'h10 : 8'hE8;
                            ulpi_stp    <= 1'b1;
                            tx_byte_idx <= 4'd0;
                            state       <= S_WAIT_STATUS_DATA;
                        end
                    end
                end

                // Wait for DATA1 ZLP in Status Stage
                S_WAIT_STATUS_DATA: begin
                    ulpi_stp     <= 1'b0;
                    ulpi_data_oe <= 1'b0;
                    if (ulpi_dir && ulpi_nxt && (ulpi_data_i[3:0] == PID_DATA1)) begin
                        state <= S_TX_STATUS_ACK;
                    end else if (timer < 24'd600_000)
                        timer <= timer + 1'b1;
                    else begin
                        timer <= 24'd0;
                        state <= S_TX_STATUS_ACK;
                    end
                end

                // Transmit ACK handshake
                S_TX_STATUS_ACK: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        ulpi_data_o  <= TXCMD_XMIT | PID_ACK;
                        ulpi_stp     <= 1'b1;
                        timer        <= 24'd0;
                        if (enum_step < 2'd2) begin
                            enum_step <= enum_step + 1'b1;
                            state     <= S_ENUM_DELAY;
                        end else begin
                            state     <= S_POLL_DELAY; // Enumeration complete!
                        end
                    end
                end

                // 8. Polling Loop: wait ~10 ms (600,000 clocks) between IN queries
                S_POLL_DELAY: begin
                    ulpi_stp     <= 1'b0;
                    ulpi_data_oe <= 1'b0;
                    if (timer < 24'd600_000)
                        timer <= timer + 1'b1;
                    else begin
                        timer       <= 24'd0;
                        tx_byte_idx <= 4'd0;
                        state       <= S_TX_POLL_IN;
                    end
                end

                // Send IN token to Address 1, Endpoint 1
                S_TX_POLL_IN: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        if (tx_byte_idx == 4'd0) begin
                            ulpi_data_o <= TXCMD_XMIT | PID_IN;
                            if (ulpi_nxt) tx_byte_idx <= 4'd1;
                        end else if (tx_byte_idx == 4'd1) begin
                            ulpi_data_o <= 8'h81; // Addr 1, EP 1
                            if (ulpi_nxt) tx_byte_idx <= 4'd2;
                        end else if (tx_byte_idx == 4'd2) begin
                            ulpi_data_o <= 8'h58; // CRC5=0x0B, EP=000
                            ulpi_stp    <= 1'b1;
                            tx_byte_idx <= 4'd0;
                            rx_byte_cnt <= 4'd0;
                            state       <= S_WAIT_POLL_DATA;
                        end
                    end
                end

                // Wait for response: NAK (no keys) or DATA0/DATA1 (8-byte report)
                S_WAIT_POLL_DATA: begin
                    ulpi_stp     <= 1'b0;
                    ulpi_data_oe <= 1'b0;
                    if (ulpi_dir && ulpi_nxt) begin
                        if (rx_byte_cnt == 4'd0) begin
                            rx_pid <= ulpi_data_i[3:0];
                            if (ulpi_data_i[3:0] == PID_NAK) begin
                                // No keys changed
                                timer <= 24'd0;
                                state <= S_POLL_DELAY;
                            end else if (ulpi_data_i[3:0] == PID_DATA0 || ulpi_data_i[3:0] == PID_DATA1) begin
                                rx_byte_cnt <= 4'd1;
                            end
                        end else if (rx_byte_cnt >= 4'd1 && rx_byte_cnt <= 4'd8) begin
                            rx_report[rx_byte_cnt - 1'b1] <= ulpi_data_i;
                            rx_byte_cnt <= rx_byte_cnt + 1'b1;
                        end
                    end else if (!ulpi_dir && rx_byte_cnt >= 4'd8) begin
                        // Packet finished: commit report and send ACK
                        report_valid <= 1'b1;
                        state        <= S_TX_POLL_ACK;
                    end else if (timer < 24'd600_000) begin
                        timer <= timer + 1'b1;
                    end else begin
                        timer <= 24'd0;
                        state <= S_POLL_DELAY;
                    end
                end

                // Send ACK handshake back to keyboard
                S_TX_POLL_ACK: begin
                    if (!ulpi_dir) begin
                        ulpi_data_oe <= 1'b1;
                        ulpi_data_o  <= TXCMD_XMIT | PID_ACK;
                        ulpi_stp     <= 1'b1;
                        timer        <= 24'd0;
                        state        <= S_POLL_DELAY;
                    end
                end

                default: state <= S_HW_RESET;
            endcase
        end
    end

    // =========================================================================
    // 4. HID Scancode to Apple //e ASCII Decoder
    // =========================================================================
    reg [7:0] prev_keycode = 8'h00;
    reg [7:0] last_mod     = 8'h00;
    reg       key_strobe_60m = 1'b0;
    reg [6:0] key_ascii_60m  = 7'h00;
    reg       mod_oa_60m     = 1'b0;
    reg       mod_ca_60m     = 1'b0;
    reg       mod_rst_60m    = 1'b0;
    reg       akd_60m        = 1'b0;

    always @(posedge clk_60m or posedge reset) begin
        if (reset) begin
            prev_keycode   <= 8'h00;
            last_mod       <= 8'h00;
            key_strobe_60m <= 1'b0;
            key_ascii_60m  <= 7'h00;
            mod_oa_60m     <= 1'b0;
            mod_ca_60m     <= 1'b0;
            mod_rst_60m    <= 1'b0;
            akd_60m        <= 1'b0;
        end else begin
            key_strobe_60m <= 1'b0;
            if (report_valid) begin
                last_mod   <= rx_report[0];
                mod_oa_60m <= rx_report[0][2] | rx_report[0][3]; // L-Alt or L-GUI
                mod_ca_60m <= rx_report[0][6] | rx_report[0][7]; // R-Alt or R-GUI

                // Check for Ctrl + Alt + Delete -> Cold Reset
                if ((rx_report[0][0] | rx_report[0][4]) && // Ctrl
                    (rx_report[0][2] | rx_report[0][6]) && // Alt
                    (rx_report[2] == 8'h4C)) begin         // Delete key
                    mod_rst_60m <= 1'b1;
                end else begin
                    mod_rst_60m <= 1'b0;
                end

                // Keypress processing on Byte 2 (first active scancode)
                if (rx_report[2] != 8'h00) begin
                    akd_60m <= 1'b1;
                    if (rx_report[2] != prev_keycode) begin
                        prev_keycode   <= rx_report[2];
                        key_strobe_60m <= 1'b1;
                        key_ascii_60m  <= hid_to_ascii(rx_report[2], rx_report[0][1] | rx_report[0][5], rx_report[0][0] | rx_report[0][4]);
                    end
                end else begin
                    prev_keycode <= 8'h00;
                    akd_60m      <= 1'b0;
                end
            end
        end
    end

    // HID Scancode to Apple ASCII converter
    function [6:0] hid_to_ascii(input [7:0] sc, input shift, input ctrl);
        begin
            if (sc >= 8'h04 && sc <= 8'h1D) begin
                // 'A' - 'Z'
                if (ctrl)
                    hid_to_ascii = sc - 8'h04 + 7'h01; // Ctrl-A (0x01) .. Ctrl-Z (0x1A)
                else if (shift)
                    hid_to_ascii = sc - 8'h04 + 7'h41; // 'A' .. 'Z'
                else
                    hid_to_ascii = sc - 8'h04 + 7'h61; // 'a' .. 'z'
            end else case (sc)
                8'h1E: hid_to_ascii = shift ? 7'h21 : 7'h31; // 1 / !
                8'h1F: hid_to_ascii = shift ? 7'h40 : 7'h32; // 2 / @
                8'h20: hid_to_ascii = shift ? 7'h23 : 7'h33; // 3 / #
                8'h21: hid_to_ascii = shift ? 7'h24 : 7'h34; // 4 / $
                8'h22: hid_to_ascii = shift ? 7'h25 : 7'h35; // 5 / %
                8'h23: hid_to_ascii = shift ? 7'h5E : 7'h36; // 6 / ^
                8'h24: hid_to_ascii = shift ? 7'h26 : 7'h37; // 7 / &
                8'h25: hid_to_ascii = shift ? 7'h2A : 7'h38; // 8 / *
                8'h26: hid_to_ascii = shift ? 7'h28 : 7'h39; // 9 / (
                8'h27: hid_to_ascii = shift ? 7'h29 : 7'h30; // 0 / )
                8'h28: hid_to_ascii = 7'h0D; // Return
                8'h29: hid_to_ascii = 7'h1B; // Escape
                8'h2A: hid_to_ascii = 7'h08; // Backspace (Left Arrow / Delete)
                8'h2B: hid_to_ascii = 7'h09; // Tab
                8'h2C: hid_to_ascii = 7'h20; // Space
                8'h2D: hid_to_ascii = shift ? 7'h5F : 7'h2D; // - / _
                8'h2E: hid_to_ascii = shift ? 7'h2B : 7'h3D; // = / +
                8'h2F: hid_to_ascii = shift ? 7'h7B : 7'h5B; // [ / {
                8'h30: hid_to_ascii = shift ? 7'h7D : 7'h5D; // ] / }
                8'h31: hid_to_ascii = shift ? 7'h7C : 7'h5C; // \ / |
                8'h33: hid_to_ascii = shift ? 7'h3A : 7'h3B; // ; / :
                8'h34: hid_to_ascii = shift ? 7'h22 : 7'h27; // ' / "
                8'h35: hid_to_ascii = shift ? 7'h7E : 7'h60; // ` / ~
                8'h36: hid_to_ascii = shift ? 7'h3C : 7'h2C; // , / <
                8'h37: hid_to_ascii = shift ? 7'h3E : 7'h2E; // . / >
                8'h38: hid_to_ascii = shift ? 7'h3F : 7'h2F; // / / ?
                8'h4F: hid_to_ascii = 7'h15; // Right Arrow (Ctrl-U / 0x15)
                8'h50: hid_to_ascii = 7'h08; // Left Arrow (Ctrl-H / 0x08)
                8'h51: hid_to_ascii = 7'h0A; // Down Arrow (Ctrl-J / 0x0A)
                8'h52: hid_to_ascii = 7'h0B; // Up Arrow (Ctrl-K / 0x0B)
                default: hid_to_ascii = 7'h00;
            endcase
        end
    endfunction

    // =========================================================================
    // 5. Clock Domain Crossing to clk_pixel (27 MHz)
    // =========================================================================
    reg [2:0] strobe_sync = 3'd0;
    reg [6:0] code_sync   = 7'd0;
    reg [1:0] oa_sync     = 2'd0;
    reg [1:0] ca_sync     = 2'd0;
    reg [1:0] rst_sync    = 2'd0;
    reg [1:0] akd_sync    = 2'd0;

    // Toggle for pulse extension
    reg toggle_60m = 1'b0;
    always @(posedge clk_60m) begin
        if (key_strobe_60m) begin
            toggle_60m <= ~toggle_60m;
            code_sync  <= key_ascii_60m;
        end
    end

    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            strobe_sync <= 3'd0;
            key_valid   <= 1'b0;
            key_code    <= 7'h00;
            key_akd     <= 1'b0;
            btn_oa      <= 1'b0;
            btn_ca      <= 1'b0;
            btn_reset   <= 1'b0;
            oa_sync     <= 2'd0;
            ca_sync     <= 2'd0;
            rst_sync    <= 2'd0;
            akd_sync    <= 2'd0;
        end else begin
            strobe_sync <= {strobe_sync[1:0], toggle_60m};
            oa_sync     <= {oa_sync[0], mod_oa_60m};
            ca_sync     <= {ca_sync[0], mod_ca_60m};
            rst_sync    <= {rst_sync[0], mod_rst_60m};
            akd_sync    <= {akd_sync[0], akd_60m};

            btn_oa    <= oa_sync[1];
            btn_ca    <= ca_sync[1];
            btn_reset <= rst_sync[1];
            key_akd   <= akd_sync[1];

            // Detect edge of toggle
            if (strobe_sync[2] ^ strobe_sync[1]) begin
                key_valid <= 1'b1;
                key_code  <= code_sync;
            end else begin
                key_valid <= 1'b0;
            end
        end
    end

endmodule
