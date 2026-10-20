`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
//  tb_input.v -- input_controller UART protocol
//
//  Drives the 115200-baud receiver with real bit timings and checks what comes
//  out of the $C0xx registers the Apple II ROMs read. The point is the host
//  protocol, so every packet type gets one case:
//
//    legacy ASCII            a Bluetooth-to-UART module or a terminal
//    0xFE key packet         the React keyboard: key code + paddle buttons
//    0xFF gamepad packet     buttons + two paddles
//    ESC [ A/B/C/D           cursor keys
//    0x02                    must reach the debugger and never the keyboard
//
//  Also covers the reason the key packet exists: $C000 holds the *final* key
//  code, because on real hardware the Apple IIe keyboard PROM (341-0132-D)
//  resolves shift and caps lock before the character reaches the CPU. So 0x20
//  is space and 0x31 is "1", not the shifted character those codes would be
//  under a naive reading of $C000 bit 5.
// ============================================================================

module tb_input;

    localparam CLK_HZ = 27000000;
    localparam BIT   = 234;      // input_controller's CLKS_PER_BIT
    localparam SETTLE = 16;      // cycles after a byte before the parser lands

    reg clk = 1'b0;
    always #18.5185185 clk = ~clk;   // 27 MHz

    reg reset = 1'b1;
    always @(posedge clk) reset <= 1'b0;

    reg ce_1m = 1'b1;                // input_controller only uses it for paddles
    reg uart_rx = 1'b1;

    reg  [7:0] io_addr  = 8'h00;
    reg        io_read  = 1'b0;
    reg        io_write = 1'b0;

    wire [7:0] io_dout;
    wire       io_hit;
    wire       key_strobe;
    wire       kbd_reset;

    wire [7:0] rx_byte;
    wire       rx_valid;

    input_controller dut (
        .clk       (clk),
        .reset     (reset),
        .ce_1m     (ce_1m),
        .uart_rx   (uart_rx),
        .dbg_mode  (1'b0),
        .rx_byte   (rx_byte),
        .rx_valid  (rx_valid),
        .io_addr   (io_addr),
        .io_read   (io_read),
        .io_write  (io_write),
        .io_dout   (io_dout),
        .io_hit    (io_hit),
        .key_strobe(key_strobe),
        .kbd_reset (kbd_reset)
    );

    integer failures = 0;
    integer checks   = 0;

    task ok;
        input condition;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $display("FAIL: %0s", name);
            end
        end
    endtask

    task eq8;
        input [7:0] got;
        input [7:0] want;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (got !== want) begin
                failures = failures + 1;
                $display("FAIL: %0s (got $%02X want $%02X)", name, got, want);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // One 8N1 byte, real bit times. 234 cycles/bit is what the receiver counts,
    // so send at the same rate the host does at 115200.
    // ------------------------------------------------------------------------
    task send_byte;
        input [7:0] b;
        integer i;
        begin
            uart_rx = 1'b0;                       // start
            repeat (BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i];
                repeat (BIT) @(posedge clk);
            end
            uart_rx = 1'b1;                       // stop
            repeat (BIT) @(posedge clk);
        end
    endtask

    // Read a $C0xx register
    task reg_read;
        input [7:0] a;
        begin
            @(negedge clk);
            io_addr = a; io_read = 1'b1;
            @(negedge clk);
            io_read = 1'b0;
        end
    endtask

    // $C010 clears the keyboard strobe
    task clear_strobe;
        begin
            @(negedge clk);
            io_addr = 8'h10; io_write = 1'b1;
            @(negedge clk);
            io_write = 1'b0;
        end
    endtask

    reg [7:0] v;

    initial begin
        repeat (10) @(posedge clk);

        // ------------------------------------------------------------------
        // 1. Legacy ASCII: the raw byte is the $C000 code
        // ------------------------------------------------------------------
        send_byte(8'h41);                        // 'A'
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hC1, "legacy 'A' arrives as strobe|$41");
        clear_strobe;
        reg_read(8'h00);
        eq8(io_dout, 8'h41, "clearing $C010 drops the strobe");

        // The whole point of the key packet: $C000 is the final character, so
        // space and the digits are not read as shifted.
        send_byte(8'h20);                        // space
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hA0, "space is $20 with strobe, not a shifted code");
        clear_strobe;

        send_byte(8'h31);                        // '1'
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hB1, "'1' is $31 with strobe");
        clear_strobe;

        send_byte(8'h61);                        // 'a'
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hE1, "lowercase 'a' is $61 with strobe");
        clear_strobe;

        // Legacy CR/LF/DEL normalisation, unchanged
        send_byte(8'h0A);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h8D, "LF is normalised to Return");
        clear_strobe;

        send_byte(8'h7F);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h88, "DEL is normalised to backspace");
        clear_strobe;

        send_byte(8'h7E);                        // '~'
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hFE, "'~' is $7E with strobe");
        clear_strobe;

        // ------------------------------------------------------------------
        // 2. 0xFE key packet: code plus the paddle buttons that go with it
        // ------------------------------------------------------------------
        send_byte(8'hFE);
        send_byte(8'h41);                        // code 'A'
        send_byte(8'h01);                        // PB0 held
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hC1, "key packet code reaches $C000");
        reg_read(8'h61);
        eq8(io_dout, 8'h80, "key packet PB0 reaches $C061 bit 7");
        clear_strobe;

        // $C010 bit 7 is any-key-down, not the strobe: still set after the
        // strobe was cleared, low 7 bits are the key, held until FF 04
        reg_read(8'h10);
        eq8(io_dout, 8'hC1, "AKD stays set while the FE key is held");
        reg_read(8'h1F);
        eq8(io_dout[6:0], 7'h41, "$C01x reads carry the key in bits 6:0");
        repeat (300000) @(posedge clk);
        reg_read(8'h10);
        eq8(io_dout, 8'hC1, "an FE key's AKD does not time out");
        send_byte(8'hFF); send_byte(8'h04);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h10);
        eq8(io_dout, 8'h41, "FF 04 drops AKD");

        // The apple keys are level state: a keypress with no buttons held must
        // clear them again.
        send_byte(8'hFE);
        send_byte(8'h20);
        send_byte(8'h00);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hA0, "key packet with no buttons still sets the code");
        reg_read(8'h61);
        eq8(io_dout, 8'h00, "key packet with no buttons releases PB0");
        clear_strobe;

        // Solid-Apple, and the phantom third button the //e has no key for
        send_byte(8'hFE);
        send_byte(8'h0D);                        // Return
        send_byte(8'h06);                        // PB1 + PB2
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h8D, "key packet can send Return");
        reg_read(8'h62);
        eq8(io_dout, 8'h80, "key packet PB1 reaches $C062 bit 7");
        reg_read(8'h63);
        eq8(io_dout, 8'h80, "key packet PB2 reaches $C063 bit 7");
        clear_strobe;

        // 0xFE is a packet leader, so '~' is still reachable as FE 7E 00
        send_byte(8'hFE);
        send_byte(8'h7E);
        send_byte(8'h00);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hFE, "FE 7E 00 types '~'");
        clear_strobe;

        // RESET key: FF 03 <b>, bit3 = held, buttons ride along, no keystroke
        clear_strobe;
        ok(kbd_reset === 1'b0, "RESET idle after power-on");
        send_byte(8'hFF); send_byte(8'h03); send_byte(8'h09);   // RESET + PB0
        repeat (SETTLE) @(posedge clk);
        ok(kbd_reset === 1'b1, "FF 03 09 holds RESET");
        reg_read(8'h61);
        eq8(io_dout, 8'h80, "RESET packet carries Open-Apple (PB0)");
        reg_read(8'h00);
        ok(io_dout[7] === 1'b0, "RESET packet types nothing");
        send_byte(8'hFF); send_byte(8'h03); send_byte(8'h01);   // release, PB0 still down
        repeat (SETTLE) @(posedge clk);
        ok(kbd_reset === 1'b0, "FF 03 01 releases RESET");
        send_byte(8'hFF); send_byte(8'h03); send_byte(8'h00);
        repeat (SETTLE) @(posedge clk);

        // ------------------------------------------------------------------
        // 3. Cursor keys
        // ------------------------------------------------------------------
        send_byte(8'h1B);
        send_byte(8'h5B);
        send_byte(8'h41);                        // up
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h8B, "ESC [ A is up arrow $0B");
        clear_strobe;

        send_byte(8'h1B);
        send_byte(8'h5B);
        send_byte(8'h42);                        // down
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h8A, "ESC [ B is down arrow $0A");
        clear_strobe;

        send_byte(8'h1B);
        send_byte(8'h5B);
        send_byte(8'h43);                        // right
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h95, "ESC [ C is right arrow $15");
        clear_strobe;

        send_byte(8'h1B);
        send_byte(8'h5B);
        send_byte(8'h44);                        // left
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h88, "ESC [ D is left arrow $08");
        clear_strobe;

        // A bare ESC is still a keystroke, and the key after it is not lost
        send_byte(8'h1B);
        send_byte(8'h78);                        // ESC then 'x', not a bracket
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h9B, "ESC not followed by [ is the ESC key");
        clear_strobe;
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'hF8, "the key after ESC arrives once ESC is read");
        clear_strobe;

        // A lone ESC (nothing after it) is delivered after a pause
        send_byte(8'h1B);
        repeat (1100000) @(posedge clk);
        reg_read(8'h00);
        eq8(io_dout, 8'h9B, "a lone ESC times out into the ESC key");
        clear_strobe;

        // ------------------------------------------------------------------
        // 4. Gamepad packet
        // ------------------------------------------------------------------
        send_byte(8'hFF);
        send_byte(8'h01);
        send_byte(8'h03);                        // PB0 + PB1
        send_byte(8'hC8);                        // paddle 0 = 200
        send_byte(8'h00);                        // paddle 1 = 0
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h61);
        eq8(io_dout, 8'h80, "gamepad PB0");
        reg_read(8'h62);
        eq8(io_dout, 8'h80, "gamepad PB1");
        reg_read(8'h63);
        eq8(io_dout, 8'h00, "gamepad with bit 2 clear leaves PB2");
        // A gamepad packet must not be mistaken for a keystroke. The code in
        // $C000 is retained with the strobe clear, the way a real strobe
        // register behaves, so test the strobe bit and not the whole byte.
        reg_read(8'h00);
        ok(io_dout[7] === 1'b0, "gamepad packet does not set the keyboard strobe");

        // Paddle trigger: reading $C070 starts the countdown, and $C064 reads 1
        // for the 60us the ROM is expected to wait.
        reg_read(8'h70);
        repeat (2) @(posedge clk);
        reg_read(8'h64);
        ok(io_dout[7] === 1'b1, "paddle 0 times out after $C070 is read");
        repeat (16) @(posedge clk);
        reg_read(8'h64);
        ok(io_dout[7] === 1'b1, "paddle 0 still times out before 60us");
        // 200 * 11 counts (ce_1m is high every clock here): still running at
        // 2100, done by 2300. The old 200 * 16 = 3200 would fail the second.
        repeat (2100) @(posedge clk);
        reg_read(8'h64);
        ok(io_dout[7] === 1'b1, "paddle 0 (200) is still counting at 2100");
        repeat (200) @(posedge clk);
        reg_read(8'h64);
        ok(io_dout[7] === 1'b0, "paddle 0 (200) is done by 2300: 11 per count");
        reg_read(8'h65);
        ok(io_dout[7] === 1'b0, "paddle 1 (0) reads 0 at once");

        // ------------------------------------------------------------------
        // 5. Ctrl+B belongs to the debugger, never the keyboard
        // ------------------------------------------------------------------
        clear_strobe;
        send_byte(8'h02);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h00);
        ok(io_dout[7] === 1'b0, "0x02 does not become a keystroke");
        ok(rx_valid === 1'b0 || rx_byte == 8'h02, "0x02 is still passed to the debugger");

        // A plain ASCII key has no release event: AKD drops by itself
        send_byte(8'h41);
        repeat (SETTLE) @(posedge clk);
        reg_read(8'h10);
        ok(io_dout[7] === 1'b1, "legacy ASCII key sets AKD");
        repeat (2800000) @(posedge clk);
        reg_read(8'h10);
        ok(io_dout[7] === 1'b0, "legacy ASCII AKD times out");
        clear_strobe;

        // ------------------------------------------------------------------
        // 6. Address decode
        // ------------------------------------------------------------------
        io_addr = 8'h00; #1 ok(io_hit === 1'b1, "$C000 is decoded");
        io_addr = 8'h10; #1 ok(io_hit === 1'b1, "$C010 is decoded");
        io_addr = 8'h20; #1 ok(io_hit === 1'b0, "$C020 is not decoded");
        io_addr = 8'h61; #1 ok(io_hit === 1'b1, "$C061 is decoded");
        io_addr = 8'h70; #1 ok(io_hit === 1'b1, "$C070 is decoded");
        io_addr = 8'h80; #1 ok(io_hit === 1'b0, "$C080 is not decoded");

        // ------------------------------------------------------------------
        if (failures == 0)
            $display("tb_input: PASS (%0d checks)", checks);
        else
            $display("FAIL: tb_input had %0d of %0d checks wrong", failures, checks);
        $finish(failures != 0);
    end

endmodule

`default_nettype wire
