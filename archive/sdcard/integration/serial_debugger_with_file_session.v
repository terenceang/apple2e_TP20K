// Apple //e Dual-Mode Serial Console & Hardware Debugger for Tang Nano 20K
// Operates over 115200 baud UART (Pin 69 TX, Pin 70 RX)
//
// Modes:
// 1. Console Mode (Default):
//    - Mirrors all Apple //e screen/Monitor text output (COUT / $FDED) to UART TX.
//    - Direct Apple II software UART output via writes to $C088 (Slot 1) or $C098 (Slot 2).
//    - Pass-through keyboard input to Apple //e.
//
// Debugger commands (Ctrl+B enters, Ctrl+B or 'c' leaves):
//   r  registers, s  step one instruction, c/g  continue, m  16 bytes of memory
//   t  video and PLL status, w  dump the visible text page and, in mixed
//      mode, the graphics page behind the bottom four lines
//   h/?  help, x  CPU reset, CR  repeat the prompt
//   a  toggle aux RAM view: m and w then read the aux 64 KB (the dump prints
//      ';' after the address, and w sets bit 7 of its flags byte)
//   d1 d2  upload a Disk ][ image: the next 143,360 bytes are written to drive
//      1 or 2, one byte at a time, with no framing and no way to interrupt
//   e1 e2  download a Disk ][ image: 143,360 bytes of drive 1 or 2 come back,
//      then a prompt
//   0 1 4 8 f v  set the memory dump address ($0000 $0100 $0400 $0800
//      $FA60 $FFF0) before m
// 2. Hardware Debugger Mode (Toggle with Ctrl+B / ASCII 0x02):
//    - Freezes 65C02 CPU execution (RDY = 0).
//    - Commands:
//        r - Display CPU registers (PC, A, X, Y, SP, Flags, Opcode)
//        s - Single-step 1 instruction
//        c - Continue / Resume Apple //e execution
//        m - Dump 16 bytes of memory (RAM/ROM) in hex & ASCII
//        t - Display hardware status (Softswitches, Video, Audio, Clocks)
//        h - Help menu

`include "src/uart_defs.vh"

module serial_debugger (
    input  wire        clk,            // 27.0 MHz
    input  wire        reset,          // Active-high reset
    input  wire        ce_1m,          // 1.023 MHz clock enable

    // Physical UART TX Pin (Pin 69)
    output wire        uart_tx,

    // UART RX from input_controller
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,

    // Debug Mode Status (1: Debugger active, 0: Apple //e Console active)
    output reg         dbg_mode,

    // CPU Ready / Pause Control
    output reg         cpu_rdy,
    output reg         cpu_reset_req,

    // Memory Inspection Bus
    output reg  [15:0] dbg_mem_addr,
    input  wire [7:0]  dbg_mem_din,
    input  wire        dbg_mem_ready,   // dbg_mem_din is valid (aux RAM answers slowly)
    output reg         dbg_aux,         // read aux RAM instead of main

    // 65C02 CPU Registers & Bus Snooping
    input  wire [15:0] cpu_pc,
    input  wire [7:0]  cpu_a,
    input  wire [7:0]  cpu_x,
    input  wire [7:0]  cpu_y,
    input  wire [7:0]  cpu_s,
    input  wire [7:0]  cpu_p,
    input  wire [7:0]  cpu_ir,
    input  wire [15:0] cpu_addr,
    input  wire [7:0]  cpu_dout,
    input  wire        cpu_we,
    input  wire        cpu_sync,

    // Hardware Status Inputs
    // Disk ][ image transfer, one byte at a time because that is all the UART
    // carries (src/disk2/disk2_store.v).  An address is a byte offset within the
    // drive's image and the drive select is held for a whole transfer, which is
    // what lets the store work out where a byte goes instead of counting.
    output reg         img_up_go,     // take img_up_data at img_up_addr
    output wire        img_up_drive,
    output wire [17:0] img_up_addr,
    output reg  [7:0]  img_up_data,
    output wire        img_up_last,   // ...and it is the drive's last byte
    output reg         img_up_bad,    // ...or it was a bad image, so empty it
    input  wire        img_up_busy,   // a word write is in flight
    input  wire        img_up_done,   // the store has the byte
    output reg         img_dn_go,     // serve the byte at img_dn_addr
    output wire        img_dn_drive,
    output wire [17:0] img_dn_addr,
    output wire        img_dn_last,   // ...and it is the drive's last byte
    input  wire [7:0]  img_dn_data,
    input  wire        img_dn_valid,  // img_dn_data is good
    input  wire        img_dn_done,   // img_dn_last and it has been served

    // ProDOS Hard Disk image transfer (2 MB per drive)
    output reg         hd_up_go,
    output wire        hd_up_drive,
    output wire [20:0] hd_up_addr,
    output reg  [7:0]  hd_up_data,
    output wire        hd_up_last,
    output reg         hd_up_bad,
    input  wire        hd_up_busy,
    input  wire        hd_up_done,
    output reg         hd_dn_go,
    output wire        hd_dn_drive,
    output wire [20:0] hd_dn_addr,
    output wire        hd_dn_last,
    input  wire [7:0]  hd_dn_data,
    input  wire        hd_dn_valid,
    input  wire        hd_dn_done,

    // SD file manager session (src/sd/sd_files.v): while main_state == M_FILE the host's
    // bytes go to it and its replies come back through the TX FIFO.  f_start is a level
    // (the session starts on its rising edge); the session ends when f_active falls.
    output reg         f_start,
    output wire        f_rx_valid,
    output wire [7:0]  f_rx_byte,
    output wire        f_tx_ready,
    input  wire        f_tx_valid,
    input  wire [7:0]  f_tx_byte,
    input  wire        f_active,

    // Softswitch state, for the W (screen dump) command
    input  wire        text_mode,
    input  wire        mixed_mode,
    input  wire        page2,
    input  wire        hires_mode,
    input  wire        pll_locked
);

    // =========================================================================
    // 1. UART TX Engine with 64-Byte Circular FIFO
    // =========================================================================
    localparam [8:0] CLKS_PER_BIT = `UART_CLKS_PER_BIT; // src/uart_defs.vh

    reg [7:0] tx_fifo [0:63];
    reg [5:0] tx_wr_ptr = 6'd0;
    reg [5:0] tx_rd_ptr = 6'd0;
    wire [5:0] fifo_used     = tx_wr_ptr - tx_rd_ptr;
    wire       tx_fifo_empty = (fifo_used == 6'd0);
    wire       tx_fifo_full  = (fifo_used >= 6'd60);

    reg [8:0] tx_clk_cnt = 9'd0;
    reg [3:0] tx_bit_idx = 4'd0;
    reg [9:0] tx_shift   = 10'h3FF;
    reg       tx_busy    = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx_clk_cnt <= 9'd0;
            tx_bit_idx <= 4'd0;
            tx_shift   <= 10'h3FF;
            tx_busy    <= 1'b0;
            tx_rd_ptr  <= 6'd0;
        end else begin
            if (tx_busy) begin
                if (tx_clk_cnt == CLKS_PER_BIT - 1) begin
                    tx_clk_cnt <= 9'd0;
                    tx_shift   <= {1'b1, tx_shift[9:1]};
                    if (tx_bit_idx == 4'd9) begin
                        tx_busy <= 1'b0;
                    end else begin
                        tx_bit_idx <= tx_bit_idx + 1'b1;
                    end
                end else begin
                    tx_clk_cnt <= tx_clk_cnt + 1'b1;
                end
            end else if (!tx_fifo_empty) begin
                tx_shift   <= {1'b1, tx_fifo[tx_rd_ptr], 1'b0};
                tx_rd_ptr  <= tx_rd_ptr + 1'b1;
                tx_clk_cnt <= 9'd0;
                tx_bit_idx <= 4'd0;
                tx_busy    <= 1'b1;
            end
        end
    end

    assign uart_tx = tx_shift[0];

    // Helper function: 4-bit nibble to ASCII hex character
    function [7:0] to_hex(input [3:0] n);
        to_hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n - 4'd10});
    endfunction

    // Single write port to tx_fifo to prevent multiplexer explosion
    reg [7:0] fifo_push_byte = 8'd0;
    reg       fifo_push_en   = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx_wr_ptr <= 6'd0;
        end else if (fifo_push_en) begin
            tx_fifo[tx_wr_ptr] <= fifo_push_byte;
            tx_wr_ptr <= tx_wr_ptr + 1'b1;
        end
    end

    task fifo_push(input [7:0] data);
        begin
            fifo_push_en   <= 1'b1;
            fifo_push_byte <= data;
        end
    endtask

    // =========================================================================
    // 3. Apple //e COUT ($FDED) and Slot Serial ($C088/$C098) Interceptor
    // =========================================================================
    reg cout_prev_sync = 1'b0;
    wire cout_hit = ce_1m && cpu_sync && !cout_prev_sync && (cpu_addr == 16'hFDED);

    always @(posedge clk or posedge reset) begin
        if (reset)
            cout_prev_sync <= 1'b0;
        else if (ce_1m)
            cout_prev_sync <= cpu_sync;
    end

    reg [7:0] cout_char_buf = 8'd0;
    reg       cout_pending  = 1'b0;
    reg       cout_need_lf  = 1'b0;

    // Slot 1/2 Serial data write ($C088 or $C098)
    wire slot_tx_hit = ce_1m && cpu_we && (cpu_addr == 16'hC088 || cpu_addr == 16'hC098);
    reg [7:0] slot_tx_buf  = 8'd0;
    reg       slot_tx_pend = 1'b0;

    // =========================================================================
    // 4. Static String Table ROM (178 Bytes)
    // =========================================================================
    localparam STR_BANNER_START = 8'd0;
    localparam STR_BANNER_LEN   = 8'd45;
    localparam STR_RESUME_START = 8'd45;
    localparam STR_RESUME_LEN   = 8'd17;
    localparam STR_HELP_START = 8'd62;
    localparam STR_HELP_LEN   = 8'd58;
    localparam STR_PROMPT_START = 8'd119;
    localparam STR_PROMPT_LEN   = 8'd4;
    localparam STR_PC_LBL_START = 8'd124;
    localparam STR_PC_LBL_LEN   = 8'd6;
    localparam STR_A_LBL_START  = 8'd130;
    localparam STR_A_LBL_LEN    = 8'd4;
    localparam STR_X_LBL_START  = 8'd134;
    localparam STR_X_LBL_LEN    = 8'd4;
    localparam STR_Y_LBL_START  = 8'd138;
    localparam STR_Y_LBL_LEN    = 8'd4;
    localparam STR_S_LBL_START  = 8'd142;
    localparam STR_S_LBL_LEN    = 8'd5;
    localparam STR_P_LBL_START  = 8'd147;
    localparam STR_P_LBL_LEN    = 8'd4;
    localparam STR_OP_LBL_START = 8'd151;
    localparam STR_OP_LBL_LEN   = 8'd6;
    localparam STR_BAR_SP_START = 8'd157;
    localparam STR_BAR_SP_LEN   = 8'd2;
    localparam STR_CRLF_START   = 8'd159;
    localparam STR_CRLF_LEN     = 8'd2;
    localparam STR_SCR_START    = 8'd161;
    localparam STR_SCR_LEN      = 8'd5;
    localparam STR_GFX_START    = 8'd166;
    localparam STR_GFX_LEN      = 8'd5;
    localparam STR_END_START    = 8'd171;
    localparam STR_END_LEN      = 8'd7;
    localparam STR_UP_START     = 9'd178;
    localparam STR_UP_LEN       = 8'd33;
    localparam STR_DN_START     = 9'd211;
    localparam STR_DN_LEN       = 8'd25;
    localparam STR_DONE_START   = 9'd236;
    localparam STR_DONE_LEN     = 8'd8;
    localparam STR_LOST_START   = 9'd244;
    localparam STR_LOST_LEN     = 8'd8;
    localparam STR_HD_UP_START  = 9'd252;
    localparam STR_HD_UP_LEN    = 8'd34;
    localparam STR_HD_DN_START  = 9'd286;
    localparam STR_HD_DN_LEN    = 8'd26;
    reg [7:0] str_rom [0:311];
    initial begin
        str_rom[0] = 8'h0D; str_rom[1] = 8'h0A; str_rom[2] = 8'h5B; str_rom[3] = 8'h20;
        str_rom[4] = 8'h41; str_rom[5] = 8'h70; str_rom[6] = 8'h70; str_rom[7] = 8'h6C;
        str_rom[8] = 8'h65; str_rom[9] = 8'h20; str_rom[10] = 8'h2F; str_rom[11] = 8'h2F;
        str_rom[12] = 8'h65; str_rom[13] = 8'h20; str_rom[14] = 8'h44; str_rom[15] = 8'h65;
        str_rom[16] = 8'h62; str_rom[17] = 8'h75; str_rom[18] = 8'h67; str_rom[19] = 8'h67;
        str_rom[20] = 8'h65; str_rom[21] = 8'h72; str_rom[22] = 8'h20; str_rom[23] = 8'h5D;
        str_rom[24] = 8'h20; str_rom[25] = 8'h28; str_rom[26] = 8'h68; str_rom[27] = 8'h3D;
        str_rom[28] = 8'h48; str_rom[29] = 8'h65; str_rom[30] = 8'h6C; str_rom[31] = 8'h70;
        str_rom[32] = 8'h2C; str_rom[33] = 8'h20; str_rom[34] = 8'h63; str_rom[35] = 8'h3D;
        str_rom[36] = 8'h43; str_rom[37] = 8'h6F; str_rom[38] = 8'h6E; str_rom[39] = 8'h74;
        str_rom[40] = 8'h29; str_rom[41] = 8'h0D; str_rom[42] = 8'h0A; str_rom[43] = 8'h3E;
        str_rom[44] = 8'h20; str_rom[45] = 8'h0D; str_rom[46] = 8'h0A; str_rom[47] = 8'h5B;
        str_rom[48] = 8'h52; str_rom[49] = 8'h65; str_rom[50] = 8'h73; str_rom[51] = 8'h75;
        str_rom[52] = 8'h6D; str_rom[53] = 8'h69; str_rom[54] = 8'h6E; str_rom[55] = 8'h67;
        str_rom[56] = 8'h2E; str_rom[57] = 8'h2E; str_rom[58] = 8'h2E; str_rom[59] = 8'h5D;
        str_rom[60] = 8'h0D; str_rom[61] = 8'h0A;
        // Help: "\r\nCmds: r=Regs s=Step c=Cont m=Mem t=Stat w=Scr h=Help\r\n> "
        str_rom[62] = 8'h0D; str_rom[63] = 8'h0A; str_rom[64] = 8'h43; str_rom[65] = 8'h6D;
        str_rom[66] = 8'h64; str_rom[67] = 8'h73; str_rom[68] = 8'h3A; str_rom[69] = 8'h20;
        str_rom[70] = 8'h72; str_rom[71] = 8'h3D; str_rom[72] = 8'h52; str_rom[73] = 8'h65;
        str_rom[74] = 8'h67; str_rom[75] = 8'h73; str_rom[76] = 8'h20; str_rom[77] = 8'h73;
        str_rom[78] = 8'h3D; str_rom[79] = 8'h53; str_rom[80] = 8'h74; str_rom[81] = 8'h65;
        str_rom[82] = 8'h70; str_rom[83] = 8'h20; str_rom[84] = 8'h63; str_rom[85] = 8'h3D;
        str_rom[86] = 8'h43; str_rom[87] = 8'h6F; str_rom[88] = 8'h6E; str_rom[89] = 8'h74;
        str_rom[90] = 8'h20; str_rom[91] = 8'h6D; str_rom[92] = 8'h3D; str_rom[93] = 8'h4D;
        str_rom[94] = 8'h65; str_rom[95] = 8'h6D; str_rom[96] = 8'h20; str_rom[97] = 8'h74;
        str_rom[98] = 8'h3D; str_rom[99] = 8'h53; str_rom[100] = 8'h74; str_rom[101] = 8'h61;
        str_rom[102] = 8'h74; str_rom[103] = 8'h20; str_rom[104] = 8'h77; str_rom[105] = 8'h3D;
        str_rom[106] = 8'h53; str_rom[107] = 8'h63; str_rom[108] = 8'h72; str_rom[109] = 8'h20;
        str_rom[110] = 8'h68; str_rom[111] = 8'h3D; str_rom[112] = 8'h48; str_rom[113] = 8'h65;
        str_rom[114] = 8'h6C; str_rom[115] = 8'h70; str_rom[116] = 8'h0D; str_rom[117] = 8'h0A;
        str_rom[118] = 8'h3E; str_rom[119] = 8'h20;
        // Prompt "\r\n> "
        str_rom[120] = 8'h0D; str_rom[121] = 8'h0A; str_rom[122] = 8'h3E; str_rom[123] = 8'h20;
        // Register line labels
        str_rom[124] = 8'h0D; str_rom[125] = 8'h0A; str_rom[126] = 8'h50; str_rom[127] = 8'h43;
        str_rom[128] = 8'h3A; str_rom[129] = 8'h24; str_rom[130] = 8'h20; str_rom[131] = 8'h41;
        str_rom[132] = 8'h3A; str_rom[133] = 8'h24; str_rom[134] = 8'h20; str_rom[135] = 8'h58;
        str_rom[136] = 8'h3A; str_rom[137] = 8'h24; str_rom[138] = 8'h20; str_rom[139] = 8'h59;
        str_rom[140] = 8'h3A; str_rom[141] = 8'h24; str_rom[142] = 8'h20; str_rom[143] = 8'h53;
        str_rom[144] = 8'h50; str_rom[145] = 8'h3A; str_rom[146] = 8'h24; str_rom[147] = 8'h20;
        str_rom[148] = 8'h50; str_rom[149] = 8'h3A; str_rom[150] = 8'h5B; str_rom[151] = 8'h5D;
        str_rom[152] = 8'h20; str_rom[153] = 8'h4F; str_rom[154] = 8'h50; str_rom[155] = 8'h3A;
        str_rom[156] = 8'h24; str_rom[157] = 8'h20; str_rom[158] = 8'h7C; str_rom[159] = 8'h0D;
        str_rom[160] = 8'h0A;
        // Screen dump framing: "\r\n$SS", "\r\n$GF", "\r\n$SEND"
        str_rom[161] = 8'h0D; str_rom[162] = 8'h0A; str_rom[163] = 8'h24; str_rom[164] = 8'h53;
        str_rom[165] = 8'h53; str_rom[166] = 8'h0D; str_rom[167] = 8'h0A; str_rom[168] = 8'h24;
        str_rom[169] = 8'h47; str_rom[170] = 8'h46; str_rom[171] = 8'h0D; str_rom[172] = 8'h0A;
        str_rom[173] = 8'h24; str_rom[174] = 8'h53; str_rom[175] = 8'h45; str_rom[176] = 8'h4E;
        str_rom[177] = 8'h44;
        // Disk image transfer.
        // 178: "\r\nUPLOAD 143360 bytes, send now\r\n"
        str_rom[178] = 8'h0D; str_rom[179] = 8'h0A; str_rom[180] = 8'h55; str_rom[181] = 8'h50;
        str_rom[182] = 8'h4C; str_rom[183] = 8'h4F; str_rom[184] = 8'h41; str_rom[185] = 8'h44;
        str_rom[186] = 8'h20; str_rom[187] = 8'h31; str_rom[188] = 8'h34; str_rom[189] = 8'h33;
        str_rom[190] = 8'h33; str_rom[191] = 8'h36; str_rom[192] = 8'h30; str_rom[193] = 8'h20;
        str_rom[194] = 8'h62; str_rom[195] = 8'h79; str_rom[196] = 8'h74; str_rom[197] = 8'h65;
        str_rom[198] = 8'h73; str_rom[199] = 8'h2C; str_rom[200] = 8'h20; str_rom[201] = 8'h73;
        str_rom[202] = 8'h65; str_rom[203] = 8'h6E; str_rom[204] = 8'h64; str_rom[205] = 8'h20;
        str_rom[206] = 8'h6E; str_rom[207] = 8'h6F; str_rom[208] = 8'h77; str_rom[209] = 8'h0D;
        str_rom[210] = 8'h0A;
        // 211: "\r\nDOWNLOAD 143360 bytes\r\n"
        str_rom[211] = 8'h0D; str_rom[212] = 8'h0A; str_rom[213] = 8'h44; str_rom[214] = 8'h4F;
        str_rom[215] = 8'h57; str_rom[216] = 8'h4E; str_rom[217] = 8'h4C; str_rom[218] = 8'h4F;
        str_rom[219] = 8'h41; str_rom[220] = 8'h44; str_rom[221] = 8'h20; str_rom[222] = 8'h31;
        str_rom[223] = 8'h34; str_rom[224] = 8'h33; str_rom[225] = 8'h33; str_rom[226] = 8'h36;
        str_rom[227] = 8'h30; str_rom[228] = 8'h20; str_rom[229] = 8'h62; str_rom[230] = 8'h79;
        str_rom[231] = 8'h74; str_rom[232] = 8'h65; str_rom[233] = 8'h73; str_rom[234] = 8'h0D;
        str_rom[235] = 8'h0A;
        // 236: "\r\ndone\r\n"
        str_rom[236] = 8'h0D; str_rom[237] = 8'h0A; str_rom[238] = 8'h64; str_rom[239] = 8'h6F;
        str_rom[240] = 8'h6E; str_rom[241] = 8'h65; str_rom[242] = 8'h0D; str_rom[243] = 8'h0A;
        // 244: "\r\nlost\r\n"
        str_rom[244] = 8'h0D; str_rom[245] = 8'h0A; str_rom[246] = 8'h6C; str_rom[247] = 8'h6F;
        str_rom[248] = 8'h73; str_rom[249] = 8'h74; str_rom[250] = 8'h0D; str_rom[251] = 8'h0A;
        // ProDOS Hard Disk image transfer (2 MB):
        // 252: "\r\nUPLOAD 2097152 bytes, send now\r\n"
        str_rom[252] = 8'h0D; str_rom[253] = 8'h0A; str_rom[254] = 8'h55; str_rom[255] = 8'h50;
        str_rom[256] = 8'h4C; str_rom[257] = 8'h4F; str_rom[258] = 8'h41; str_rom[259] = 8'h44;
        str_rom[260] = 8'h20; str_rom[261] = 8'h32; str_rom[262] = 8'h30; str_rom[263] = 8'h39;
        str_rom[264] = 8'h37; str_rom[265] = 8'h31; str_rom[266] = 8'h35; str_rom[267] = 8'h32;
        str_rom[268] = 8'h20; str_rom[269] = 8'h62; str_rom[270] = 8'h79; str_rom[271] = 8'h74;
        str_rom[272] = 8'h65; str_rom[273] = 8'h73; str_rom[274] = 8'h2C; str_rom[275] = 8'h20;
        str_rom[276] = 8'h73; str_rom[277] = 8'h65; str_rom[278] = 8'h6E; str_rom[279] = 8'h64;
        str_rom[280] = 8'h20; str_rom[281] = 8'h6E; str_rom[282] = 8'h6F; str_rom[283] = 8'h77;
        str_rom[284] = 8'h0D; str_rom[285] = 8'h0A;
        // 286: "\r\nDOWNLOAD 2097152 bytes\r\n"
        str_rom[286] = 8'h0D; str_rom[287] = 8'h0A; str_rom[288] = 8'h44; str_rom[289] = 8'h4F;
        str_rom[290] = 8'h57; str_rom[291] = 8'h4E; str_rom[292] = 8'h4C; str_rom[293] = 8'h4F;
        str_rom[294] = 8'h41; str_rom[295] = 8'h44; str_rom[296] = 8'h20; str_rom[297] = 8'h32;
        str_rom[298] = 8'h30; str_rom[299] = 8'h39; str_rom[300] = 8'h37; str_rom[301] = 8'h31;
        str_rom[302] = 8'h35; str_rom[303] = 8'h32; str_rom[304] = 8'h20; str_rom[305] = 8'h62;
        str_rom[306] = 8'h79; str_rom[307] = 8'h74; str_rom[308] = 8'h65; str_rom[309] = 8'h73;
        str_rom[310] = 8'h0D; str_rom[311] = 8'h0A;
    end

    // String printer sub-engine
    reg [8:0] str_pos = 9'd0;
    reg [7:0] str_cnt = 8'd0;
    wire str_busy = (str_cnt != 8'd0);

    // Hex digit printer sub-engine (prints up to 4 hex digits)
    reg [15:0] hex_val = 16'd0;
    reg [2:0]  hex_digits = 3'd0;
    wire hex_busy = (hex_digits != 3'd0);

    // Which received bytes the console echo passes through. Anything else is
    // protocol: the 0xFE key packet and the 0xFF gamepad packet must not be
    // reflected into the terminal as text.
    wire echoable = (rx_byte >= 8'h20 && rx_byte <= 8'h7E) ||
                    (rx_byte == 8'h0D) || (rx_byte == 8'h0A) ||
                    (rx_byte == 8'h08) || (rx_byte == 8'h07);

    // The six memory-dump preset keys ("0" "1" "4" "8" "f"/"F" "v"/"V")
    wire mem_preset = (rx_byte == "0") || (rx_byte == "1") || (rx_byte == "4") ||
                      (rx_byte == "8") || (rx_byte == "f") || (rx_byte == "F") ||
                      (rx_byte == "v") || (rx_byte == "V");

    // =========================================================================
    // 5. Hardware Debugger State Machine & Micro-Sequencer
    // =========================================================================
    localparam M_IDLE    = 4'd0;
    localparam M_STR     = 4'd1;
    localparam M_HEX     = 4'd2;
    localparam M_REGS    = 4'd3;
    localparam M_MEM     = 4'd4;
    localparam M_STATUS  = 4'd5;
    localparam M_SCREEN  = 4'd6;
    localparam M_IMG     = 4'd7;   // a Disk ][ or ProDOS HD image, in or out
    localparam M_FILE    = 4'd8;   // the SD file manager (src/sd/sd_files.v owns the byte stream)

    // Disk ][ image: 143,360 bytes (35 tracks x 16 sectors x 256 bytes)
    localparam [17:0] IMG_BYTES = 18'd143360;
    localparam [17:0] IMG_LAST  = IMG_BYTES - 18'd1;

    // ProDOS Hard Disk image: 2,097,152 bytes (4,096 blocks x 512 bytes)
    localparam [21:0] IMG_HD_BYTES = 22'd2097152;
    localparam [20:0] IMG_HD_LAST  = 21'd2097151;

    // Which way the bytes are going, and the position in the image.  img_dir is
    // 0 for the host writing the drive and 1 for the host reading it.
    reg        img_dir   = 1'b0;
    reg        img_drv   = 1'b0;
    reg        img_is_hd = 1'b0;
    reg [20:0] img_addr  = 21'd0;

    assign img_up_drive = img_drv;
    assign img_up_addr  = img_addr[17:0];
    assign img_up_last  = (img_addr == {3'd0, IMG_LAST});
    assign img_dn_drive = img_drv;
    assign img_dn_addr  = img_addr[17:0];
    assign img_dn_last  = (img_addr == {3'd0, IMG_LAST});

    assign hd_up_drive  = img_drv;
    assign hd_up_addr   = img_addr;
    assign hd_up_last   = (img_addr == IMG_HD_LAST);
    assign hd_dn_drive  = img_drv;
    assign hd_dn_addr   = img_addr;
    assign hd_dn_last   = (img_addr == IMG_HD_LAST);

    wire        active_up_busy  = img_is_hd ? hd_up_busy  : img_up_busy;
    wire        active_up_done  = img_is_hd ? hd_up_done  : img_up_done;
    wire        active_up_last  = img_is_hd ? hd_up_last  : img_up_last;
    wire        active_dn_valid = img_is_hd ? hd_dn_valid : img_dn_valid;
    wire        active_dn_last  = img_is_hd ? hd_dn_last  : img_dn_last;
    wire [7:0]  active_dn_data  = img_is_hd ? hd_dn_data  : img_dn_data;
    wire [21:0] img_target_bytes = img_is_hd ? {1'b0, IMG_HD_BYTES} : {4'd0, IMG_BYTES};

    // The byte that has arrived from the host and the flag that says so, and the
    // flag that says it has been handed to the store.
    reg [7:0]  img_byte = 8'h00;
    reg        img_have = 1'b0;      // a byte has arrived and is waiting
    reg        img_sent = 1'b0;      // ...and it has been handed over
    reg        img_ask  = 1'b0;      // a download request is out
    reg        img_ackq = 1'b0;      // an acknowledgement is waiting for room
    reg [21:0] img_rx   = 22'd0;     // bytes that arrived during the upload
    reg        img_cmd  = 1'b0;      // command seen; the next digit picks the drive

    // Screen dump state. The W command streams the 1 KB text page the video
    // generator is showing, in memory order ($0400/$0800 upward, interleaving
    // holes included -- the host applies the row interleave), plus lo-res rows
    // 20-23 of the same page, which is what the bottom four lines show in
    // mixed mode. Only reachable while the CPU is paused, which is what makes
    // the read race-free: nothing can rewrite $0400 while dbg_mode is set.
    // (With 80STORE + PAGE2 the displayed page is the aux one, which the
    // debugger cannot read -- it sees main RAM only -- so the dump then shows
    // the main-RAM copy.)
    reg [15:0] scr_addr  = 16'h0400;
    reg [10:0] scr_left  = 11'd0;   // bytes still to print
    reg [5:0]  scr_col   = 6'd0;    // byte within the current row, 0..39
    reg [1:0]  gfx_row   = 2'd0;    // graphics row being dumped, 0..3
    reg [2:0]  scr_wait  = 3'd0;    // settle cycles between RAM reads
    reg [7:0]  scr_flags = 8'h00;

    // The text page lo-res rows 20-23 sit at page + $250/$2D0/$350/$3D0, i.e.
    // page + $250 + 128*n (the same row interleave video_generator.v reads).
    wire [15:0] scr_page   = page2 ? 16'h0800 : 16'h0400;
    wire [15:0] scrgfx_row = scr_page + 16'h0250 + {7'd0, gfx_row, 7'd0};

    reg [3:0] main_state = M_IDLE;
    reg       f_seen = 1'b0;             // the file session has started
    assign f_rx_valid = rx_valid && (main_state == M_FILE);
    assign f_rx_byte  = rx_byte;
    assign f_tx_ready = !tx_fifo_full;
    reg [3:0] return_job = M_IDLE;
    reg [4:0] seq_step   = 5'd0;

    reg [15:0] latched_pc;
    reg [7:0]  latched_a;
    reg [7:0]  latched_x;
    reg [7:0]  latched_y;
    reg [7:0]  latched_s;
    reg [7:0]  latched_p;
    reg [7:0]  latched_ir;

    reg [15:0] dump_addr = 16'hFA60;
    reg [7:0]  mem_row [0:15];
    reg [3:0]  mem_col = 4'd0;
    reg [2:0]  mem_wait = 3'd0;
    reg [7:0]  reset_timer = 8'd0;

    // Single Step State Machine
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_WAIT0 = 2'd2;
    localparam S_WAIT1 = 2'd3;

    // Snapshot the 65C02 registers for the register dump. Three entry points
    // need exactly this: the Ctrl+B handshake, the step finish, and "r".
    // (Declared after the registers it writes; this iverilog rejects
    // declaration-after-use inside tasks too.)
    task latch_regs;
        begin
            latched_pc <= cpu_pc;
            latched_a  <= cpu_a;
            latched_x  <= cpu_x;
            latched_y  <= cpu_y;
            latched_s  <= cpu_s;
            latched_p  <= cpu_p;
            latched_ir <= cpu_ir;
        end
    endtask

    // One byte of a screen dump: present the address, wait for the RAM to
    // settle (same read-settle pattern as the memory dump: dbg_mem_din is
    // combinational off dbg_mem_addr), then hand the byte to the hex printer
    // and resume the dump at `next`.
    task scr_read_byte(input [4:0] next);
        begin
            dbg_mem_addr <= scr_addr;
            if (scr_wait < 3'd4) begin
                scr_wait <= scr_wait + 1'b1;
            end else if (dbg_mem_ready) begin
                scr_wait   <= 3'd0;
                scr_addr   <= scr_addr + 16'd1;
                scr_left   <= scr_left - 11'd1;
                scr_col    <= scr_col + 1'b1;
                hex_val    <= {dbg_mem_din, 8'h00};
                hex_digits <= 3'd2;
                return_job <= M_SCREEN;
                main_state <= M_HEX;
                seq_step   <= next;
            end
        end
    endtask

    reg [1:0] step_fsm = S_IDLE;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            step_fsm       <= S_IDLE;
            cpu_rdy        <= 1'b1;
            cpu_reset_req  <= 1'b0;
            reset_timer    <= 8'd0;
            dbg_mode       <= 1'b0;
            latched_pc     <= 16'hFA62;
            latched_a      <= 8'h00;
            latched_x      <= 8'h00;
            latched_y      <= 8'h00;
            latched_s      <= 8'hFF;
            latched_p      <= 8'h20;
            latched_ir     <= 8'h00;
            dump_addr      <= 16'hFA60;
            dbg_mem_addr   <= 16'hFA60;
            dbg_aux        <= 1'b0;
            main_state     <= M_IDLE;
            return_job     <= M_IDLE;
            seq_step       <= 5'd0;
            str_pos        <= 8'd0;
            str_cnt        <= 8'd0;
            cout_char_buf  <= 8'd0;
            cout_pending   <= 1'b0;
            cout_need_lf   <= 1'b0;
            slot_tx_buf    <= 8'd0;
            slot_tx_pend   <= 1'b0;
            mem_col        <= 4'd0;
            mem_wait       <= 3'd0;
            scr_addr       <= 16'h0400;
            scr_left       <= 11'd0;
            scr_col        <= 6'd0;
            scr_wait       <= 3'd0;
            scr_flags      <= 8'h00;
            img_dir        <= 1'b0;
            img_drv        <= 1'b0;
            img_is_hd      <= 1'b0;
            img_addr       <= 21'd0;
            img_byte       <= 8'h00;
            img_have       <= 1'b0;
            img_sent       <= 1'b0;
            img_ask        <= 1'b0;
            img_ackq       <= 1'b0;
            img_cmd        <= 1'b0;
            img_up_data    <= 8'h00;
            img_up_go      <= 1'b0;
            img_up_bad     <= 1'b0;
            img_dn_go      <= 1'b0;
            hd_up_data     <= 8'h00;
            hd_up_go       <= 1'b0;
            hd_up_bad      <= 1'b0;
            hd_dn_go       <= 1'b0;
            img_rx         <= 22'd0;
            f_start        <= 1'b0;
            f_seen         <= 1'b0;
        end else begin
            fifo_push_en <= 1'b0;
            // All requests are one-clock pulses and the stores take one
            // only while free, so they are cleared here:
            img_up_go  <= 1'b0;
            img_up_bad <= 1'b0;
            img_dn_go  <= 1'b0;
            hd_up_go   <= 1'b0;
            hd_up_bad  <= 1'b0;
            hd_dn_go   <= 1'b0;

            // Debugger CPU Reset Sequencer
            if (reset_timer != 8'd0) begin
                reset_timer   <= reset_timer - 1'b1;
                cpu_reset_req <= 1'b1;
                cpu_rdy       <= 1'b0;
                step_fsm      <= S_IDLE;
                if (reset_timer == 8'd1) begin
                    latched_pc <= 16'hFA62;
                    dump_addr  <= 16'hFA60;
                    main_state <= M_REGS;
                    seq_step   <= 5'd0;
                end
            end else begin
                cpu_reset_req <= 1'b0;
            end

            // Latch Apple II COUT and Slot TX events
            if (cout_hit && !dbg_mode) begin
                cout_char_buf <= cpu_a;
                cout_pending  <= 1'b1;
            end
            if (slot_tx_hit && !dbg_mode) begin
                slot_tx_buf  <= cpu_dout;
                slot_tx_pend <= 1'b1;
            end

            // Single Step FSM
            case (step_fsm)
                S_IDLE: begin
                    if (!dbg_mode)
                        cpu_rdy <= 1'b1;
                    else
                        cpu_rdy <= 1'b0;
                end

                S_START: begin
                    cpu_rdy <= 1'b1;
                    if (ce_1m)
                        step_fsm <= S_WAIT0;
                end

                S_WAIT0: begin
                    if (ce_1m && !cpu_sync)
                        step_fsm <= S_WAIT1;
                end

                S_WAIT1: begin
                    if (ce_1m && cpu_sync) begin
                        cpu_rdy    <= 1'b0;
                        step_fsm   <= S_IDLE;
                        latch_regs;
                        // Trigger Register print
                        main_state <= M_REGS;
                        seq_step   <= 5'd0;
                    end
                end
            endcase

            // Mode switching via Ctrl+B (ASCII 0x02)
            if (rx_valid && (rx_byte == 8'h02) && (main_state != M_IMG) && (main_state != M_FILE)) begin
                if (!dbg_mode) begin
                    dbg_mode   <= 1'b1;
                    cpu_rdy    <= 1'b0;
                    latch_regs;
                    dump_addr  <= cpu_pc;
                    // Print Banner
                    str_pos    <= STR_BANNER_START;
                    str_cnt    <= STR_BANNER_LEN;
                    return_job <= M_REGS;
                    seq_step   <= 5'd0;
                    main_state <= M_STR;
                end else begin
                    dbg_mode   <= 1'b0;
                    cpu_rdy    <= 1'b1;
                    // Print Resume
                    str_pos    <= STR_RESUME_START;
                    str_cnt    <= STR_RESUME_LEN;
                    return_job <= M_IDLE;
                    main_state <= M_STR;
                end
            end else if (!dbg_mode && (main_state == M_IDLE) && rx_valid) begin
                // Echo console keystrokes back so the host sees what it typed.
                // Only characters a terminal can show: the 0xFE key packet and
                // the 0xFF gamepad packet are protocol, not text, and used to
                // land in the console as five or three junk bytes each.
                if (!tx_fifo_full && echoable) begin
                    fifo_push(rx_byte);
                end
            end else if (dbg_mode && (main_state == M_IDLE) && rx_valid) begin
                case (rx_byte)
                    "r", "R": begin
                        latch_regs;
                        main_state <= M_REGS;
                        seq_step   <= 5'd0;
                    end

                    "s", "S": begin
                        step_fsm <= S_START;
                    end

                    "c", "C", "g", "G": begin
                        dbg_mode   <= 1'b0;
                        cpu_rdy    <= 1'b1;
                        str_pos    <= STR_RESUME_START;
                        str_cnt    <= STR_RESUME_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    "a", "A": begin
                        dbg_aux    <= ~dbg_aux;
                        str_pos    <= STR_PROMPT_START;
                        str_cnt    <= STR_PROMPT_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    // d1/d2 upload Disk ][, e1/e2 download Disk ][.
                    // p1/p2 upload ProDOS HD, o1/o2 download ProDOS HD.
                    "d", "D", "e", "E": begin
                        img_cmd   <= 1'b1;
                        img_is_hd <= 1'b0;
                        img_dir   <= (rx_byte == "e") || (rx_byte == "E");
                    end

                    "p", "P", "o", "O": begin
                        img_cmd   <= 1'b1;
                        img_is_hd <= 1'b1;
                        img_dir   <= (rx_byte == "o") || (rx_byte == "O");
                    end

                    "1", "2": begin
                        if (img_cmd) begin
                            img_cmd    <= 1'b0;
                            img_drv    <= (rx_byte == "2");
                            img_addr   <= 21'd0;
                            img_rx     <= 22'd0;
                            img_have   <= 1'b0;
                            img_sent   <= 1'b0;
                            img_ask    <= 1'b0;
                            img_ackq   <= 1'b0;
                            img_up_go  <= 1'b0;
                            img_dn_go  <= 1'b0;
                            hd_up_go   <= 1'b0;
                            hd_dn_go   <= 1'b0;
                            if (img_is_hd) begin
                                str_pos <= img_dir ? STR_HD_DN_START : STR_HD_UP_START;
                                str_cnt <= img_dir ? STR_HD_DN_LEN   : STR_HD_UP_LEN;
                            end else begin
                                str_pos <= img_dir ? STR_DN_START : STR_UP_START;
                                str_cnt <= img_dir ? STR_DN_LEN   : STR_UP_LEN;
                            end
                            return_job <= M_IMG;
                            main_state <= M_STR;
                        end else if (rx_byte == "1") begin
                            dump_addr <= 16'h0100;
                        end
                    end

                    // z: the SD file manager (host protocol in src/sd/sd_files.v)
                    "z", "Z": begin
                        f_start    <= 1'b1;
                        f_seen     <= 1'b0;
                        main_state <= M_FILE;
                    end

                    "m", "M": begin
                        main_state <= M_MEM;
                        seq_step   <= 5'd0;
                        mem_col    <= 4'd0;
                        mem_wait   <= 3'd0;
                    end

                    "x", "X": begin
                        reset_timer <= 8'd255;
                        dbg_mode    <= 1'b1;
                        cpu_rdy     <= 1'b0;
                    end

                    "0":     dump_addr <= 16'h0000;
                    // "1" is handled above, where it is a drive number when it
                    // follows d or e and the text-page preset when it does not.
                    "4":     dump_addr <= 16'h0400;
                    "8":     dump_addr <= 16'h0800;
                    "f", "F": dump_addr <= 16'hFA60;
                    "v", "V": dump_addr <= 16'hFFF0;

                    "t", "T": begin
                        main_state <= M_STATUS;
                        seq_step   <= 5'd0;
                    end

                    "w", "W": begin
                        main_state <= M_SCREEN;
                        seq_step   <= 5'd0;
                    end

                    "h", "H", "?": begin
                        str_pos    <= STR_HELP_START;
                        str_cnt    <= STR_HELP_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    8'h0D, 8'h0A: begin
                        str_pos    <= STR_PROMPT_START;
                        str_cnt    <= STR_PROMPT_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    default: ;
                endcase

                // Any of the six preset addresses above starts a dump; "m"
                // reuses the last address. Only the address differs.
                if (mem_preset && !img_cmd) begin
                    main_state <= M_MEM;
                    seq_step   <= 5'd0;
                    mem_col    <= 4'd0;
                    mem_wait   <= 3'd0;
                end
            end

            // Main State Machine
            case (main_state)
                M_IDLE: begin
                    // Idle: wait for commands or console activity
                end

                // -------------------------------------------------------------
                // String Sub-engine: Streams bytes from str_rom into FIFO
                // -------------------------------------------------------------
                M_STR: begin
                    if (!tx_fifo_full) begin
                        fifo_push(str_rom[str_pos]);
                        str_pos <= str_pos + 1'b1;
                        if (str_cnt == 8'd1) begin
                            str_cnt    <= 8'd0;
                            main_state <= return_job;
                        end else begin
                            str_cnt <= str_cnt - 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Hex Sub-engine: Streams hex digits into FIFO
                // -------------------------------------------------------------
                M_HEX: begin
                    if (!tx_fifo_full) begin
                        fifo_push(to_hex(hex_val[15:12]));
                        hex_val <= {hex_val[11:0], 4'h0};
                        if (hex_digits == 3'd1) begin
                            hex_digits <= 3'd0;
                            main_state <= return_job;
                        end else begin
                            hex_digits <= hex_digits - 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Register Display Sequencer
                // -------------------------------------------------------------
                M_REGS: begin
                    case (seq_step)
                        5'd0: begin // "PC:$"
                            str_pos    <= STR_PC_LBL_START;
                            str_cnt    <= STR_PC_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1: begin // 4-digit PC
                            hex_val    <= latched_pc;
                            hex_digits <= 3'd4;
                            return_job <= M_REGS;
                            seq_step   <= 5'd2;
                            main_state <= M_HEX;
                        end
                        5'd2: begin // " A:$"
                            str_pos    <= STR_A_LBL_START;
                            str_cnt    <= STR_A_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd3;
                            main_state <= M_STR;
                        end
                        5'd3: begin // 2-digit A
                            hex_val    <= {latched_a, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd4;
                            main_state <= M_HEX;
                        end
                        5'd4: begin // " X:$"
                            str_pos    <= STR_X_LBL_START;
                            str_cnt    <= STR_X_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd5;
                            main_state <= M_STR;
                        end
                        5'd5: begin // 2-digit X
                            hex_val    <= {latched_x, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd6;
                            main_state <= M_HEX;
                        end
                        5'd6: begin // " Y:$"
                            str_pos    <= STR_Y_LBL_START;
                            str_cnt    <= STR_Y_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd7;
                            main_state <= M_STR;
                        end
                        5'd7: begin // 2-digit Y
                            hex_val    <= {latched_y, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd8;
                            main_state <= M_HEX;
                        end
                        5'd8: begin // " SP:$"
                            str_pos    <= STR_S_LBL_START;
                            str_cnt    <= STR_S_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd9;
                            main_state <= M_STR;
                        end
                        5'd9: begin // 2-digit S
                            hex_val    <= {latched_s, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd10;
                            main_state <= M_HEX;
                        end
                        5'd10: begin // " P:["
                            str_pos    <= STR_P_LBL_START;
                            str_cnt    <= STR_P_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd11;
                            main_state <= M_STR;
                        end
                        5'd11: begin // Flags: N V - B D I Z C
                            if (!tx_fifo_full) begin
                                fifo_push(latched_p[7] ? "N" : "-");
                                seq_step <= 5'd12;
                            end
                        end
                        5'd12: if (!tx_fifo_full) begin fifo_push(latched_p[6] ? "V" : "-"); seq_step <= 5'd13; end
                        5'd13: if (!tx_fifo_full) begin fifo_push("-");                     seq_step <= 5'd14; end
                        5'd14: if (!tx_fifo_full) begin fifo_push(latched_p[4] ? "B" : "-"); seq_step <= 5'd15; end
                        5'd15: if (!tx_fifo_full) begin fifo_push(latched_p[3] ? "D" : "-"); seq_step <= 5'd16; end
                        5'd16: if (!tx_fifo_full) begin fifo_push(latched_p[2] ? "I" : "-"); seq_step <= 5'd17; end
                        5'd17: if (!tx_fifo_full) begin fifo_push(latched_p[1] ? "Z" : "-"); seq_step <= 5'd18; end
                        5'd18: if (!tx_fifo_full) begin fifo_push(latched_p[0] ? "C" : "-"); seq_step <= 5'd19; end
                        5'd19: begin // "] OP:$"
                            str_pos    <= STR_OP_LBL_START;
                            str_cnt    <= STR_OP_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd20;
                            main_state <= M_STR;
                        end
                        5'd20: begin // 2-digit Opcode
                            hex_val    <= {latched_ir, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd21;
                            main_state <= M_HEX;
                        end
                        5'd21: begin // Prompt "\r\n> "
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Memory Dump Sequencer (16 Bytes)
                // -------------------------------------------------------------
                M_MEM: begin
                    case (seq_step)
                        5'd0: begin // CRLF
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_MEM;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1: if (!tx_fifo_full) begin fifo_push("$"); seq_step <= 5'd2; end
                        5'd2: begin // Dump address (4 hex digits)
                            hex_val    <= dump_addr;
                            hex_digits <= 3'd4;
                            return_job <= M_MEM;
                            seq_step   <= 5'd3;
                            main_state <= M_HEX;
                        end
                        5'd3: if (!tx_fifo_full) begin fifo_push(dbg_aux ? ";" : ":"); seq_step <= 5'd4; end
                        5'd4: if (!tx_fifo_full) begin
                            fifo_push(" ");
                            mem_col  <= 4'd0;
                            mem_wait <= 3'd0;
                            seq_step <= 5'd5;
                        end
                        5'd5: begin // Read 16 bytes into mem_row
                            dbg_mem_addr <= dump_addr + {12'd0, mem_col};
                            if (mem_wait < 3'd4) begin
                                mem_wait <= mem_wait + 1'b1;
                            end else if (dbg_mem_ready) begin
                                mem_row[mem_col] <= dbg_mem_din;
                                mem_wait <= 3'd0;
                                if (mem_col == 4'd15) begin
                                    mem_col  <= 4'd0;
                                    seq_step <= 5'd6;
                                end else begin
                                    mem_col <= mem_col + 1'b1;
                                end
                            end
                        end
                        5'd6: begin // Print Hex Byte MSB
                            if (!tx_fifo_full) begin
                                fifo_push(to_hex(mem_row[mem_col][7:4]));
                                seq_step <= 5'd7;
                            end
                        end
                        5'd7: begin // Print Hex Byte LSB
                            if (!tx_fifo_full) begin
                                fifo_push(to_hex(mem_row[mem_col][3:0]));
                                seq_step <= 5'd8;
                            end
                        end
                        5'd8: begin // Print space (extra space between bytes 7 and 8)
                            if (!tx_fifo_full) begin
                                fifo_push(" ");
                                if (mem_col == 4'd7)
                                    seq_step <= 5'd9;
                                else if (mem_col == 4'd15) begin
                                    mem_col  <= 4'd0;
                                    seq_step <= 5'd10;
                                end else begin
                                    mem_col  <= mem_col + 1'b1;
                                    seq_step <= 5'd6;
                                end
                            end
                        end
                        5'd9: if (!tx_fifo_full) begin // Extra space
                            fifo_push(" ");
                            mem_col  <= mem_col + 1'b1;
                            seq_step <= 5'd6;
                        end
                        5'd10: begin // " |"
                            str_pos    <= STR_BAR_SP_START;
                            str_cnt    <= STR_BAR_SP_LEN;
                            return_job <= M_MEM;
                            seq_step   <= 5'd11;
                            main_state <= M_STR;
                        end
                        5'd11: begin // Print 16 ASCII characters
                            if (!tx_fifo_full) begin
                                fifo_push((mem_row[mem_col] >= 8'h20 && mem_row[mem_col] <= 8'h7E) ? mem_row[mem_col] : 8'h2E);
                                if (mem_col == 4'd15)
                                    seq_step <= 5'd12;
                                else
                                    mem_col  <= mem_col + 1'b1;
                            end
                        end
                        5'd12: if (!tx_fifo_full) begin fifo_push("|"); seq_step <= 5'd13; end
                        5'd13: begin // Prompt "\r\n> "
                            dump_addr  <= dump_addr + 16'd16;
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Status Display Sequencer
                // -------------------------------------------------------------
                M_STATUS: begin
                    case (seq_step)
                        5'd0: begin
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_STATUS;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1:  if (!tx_fifo_full) begin fifo_push("V"); seq_step <= 5'd2;  end
                        5'd2:  if (!tx_fifo_full) begin fifo_push("I"); seq_step <= 5'd3;  end
                        5'd3:  if (!tx_fifo_full) begin fifo_push("D"); seq_step <= 5'd4;  end
                        5'd4:  if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd5;  end
                        5'd5:  if (!tx_fifo_full) begin fifo_push(text_mode ? "T" : "G"); seq_step <= 5'd6; end
                        5'd6:  if (!tx_fifo_full) begin fifo_push(" "); seq_step <= 5'd7;  end
                        5'd7:  if (!tx_fifo_full) begin fifo_push("P"); seq_step <= 5'd8;  end
                        5'd8:  if (!tx_fifo_full) begin fifo_push("L"); seq_step <= 5'd9;  end
                        5'd9:  if (!tx_fifo_full) begin fifo_push("L"); seq_step <= 5'd10; end
                        5'd10: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd11; end
                        5'd11: if (!tx_fifo_full) begin fifo_push(pll_locked ? "1" : "0"); seq_step <= 5'd12; end
                        5'd12: begin
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Screen Dump Sequencer
                //
                // Wire format, all hex text so a plain terminal can read it too:
                //
                //   $SS <flags>          one flag byte, then
                //                         1024 bytes  the whole text page, in
                //                                     memory order ($0400/$0800
                //                                     upward, interleaving holes
                //                                     included)
                //   $GF <40 bytes>  x4   lo-res rows 20-23 of the same page
                //   $SEND
                //
                // The host applies the row interleave (web/src/protocol.js
                // textPageIndex). Bit 7 of each text byte is inverse video,
                // not part of the character.
                // -------------------------------------------------------------
                M_SCREEN: begin
                    case (seq_step)
                        5'd0: begin // "\r\n$SS"
                            scr_flags <= {dbg_aux, 1'b0, pll_locked, hires_mode, mixed_mode,
                                          page2, text_mode};
                            str_pos    <= STR_SCR_START;
                            str_cnt    <= STR_SCR_LEN;
                            return_job <= M_SCREEN;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1: if (!tx_fifo_full) begin // flags byte
                            fifo_push(" ");
                            hex_val    <= {scr_flags, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_SCREEN;
                            seq_step   <= 5'd2;
                            main_state <= M_HEX;
                        end
                        5'd2: if (!tx_fifo_full) begin // start of text page
                            fifo_push(" ");
                            scr_addr <= scr_page;
                            scr_left <= 11'd1024;
                            scr_col  <= 6'd0;
                            scr_wait <= 3'd0;
                            seq_step <= 5'd3;
                        end
                        5'd3: begin
                            if (scr_left == 11'd0) begin
                                seq_step <= 5'd6;
                            end else begin
                                scr_read_byte(5'd4);
                            end
                        end
                        5'd4: if (scr_col == 6'd40) begin // end of a text row
                            scr_col    <= 6'd0;
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                        end else begin
                            seq_step <= 5'd3;
                        end
                        5'd6: if (!tx_fifo_full) begin // "\r\n$GF"
                            // Lo-res rows 20-23 of the same page the text came
                            // from: in lo-res the graphics share the text page,
                            // and these are the four lines mixed mode hides. A
                            // hi-res screen ignores them.
                            str_pos    <= STR_GFX_START;
                            str_cnt    <= STR_GFX_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                            scr_addr   <= scrgfx_row;
                            scr_left   <= 11'd160; // 4 rows of 40 bytes
                            gfx_row    <= 2'd0;
                            scr_col    <= 6'd0;
                            scr_wait   <= 3'd0;
                            seq_step   <= 5'd7;
                        end
                        5'd7: begin
                            if (scr_left == 11'd0) begin
                                seq_step <= 5'd9;
                            end else begin
                                scr_read_byte(5'd8);
                            end
                        end
                        5'd8: if (scr_col == 6'd40) begin // end of a graphics row
                            scr_col <= 6'd0;
                            if (gfx_row == 2'd3) begin
                                seq_step <= 5'd9;
                            end else begin
                                gfx_row  <= gfx_row + 2'd1;
                                scr_addr <= scrgfx_row + 16'd128; // the next row's base
                                str_pos    <= STR_CRLF_START;
                                str_cnt    <= STR_CRLF_LEN;
                                return_job <= M_SCREEN;
                                main_state <= M_STR;
                            end
                        end else begin
                            seq_step <= 5'd7;
                        end
                        5'd9: if (!tx_fifo_full) begin // "\r\n$SEND" then prompt
                            str_pos    <= STR_END_START;
                            str_cnt    <= STR_END_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                            seq_step   <= 5'd10;
                        end
                        5'd10: begin
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Disk ][ image, in or out
                // -------------------------------------------------------------
                // Two directions, one engine, because both are "a byte, then the
                // next one" and the only thing that differs is whose turn it is.
                //
                // Nothing here waits on the UART.  An upload is paced by the host,
                // which is 86 us a byte against a 16-clock word write, and a
                // download is paced by the TX FIFO, which a request is only made
                // into when there is room in: a download of 143,360 bytes is 12.4
                // seconds of sending and the store is never the slow part.
                M_IMG: begin
                    if (img_dir == 1'b0) begin
                        // Host to drive.  A byte that has arrived is handed over
                        // in one go pulse, and the pulse waits for the store/card to be
                        // free: a byte offered while its word write is in flight
                        // is not taken.
                        //
                        // One byte in hand is all there is room for, so the host
                        // is paced by an acknowledgement for every track / 4096-byte chunk taken.
                        // The host sends a 4096-byte chunk, waits for its acknowledgement,
                        // and sends the next.
                        if (img_sent) begin
                            if (active_up_done) begin
                                img_sent <= 1'b0;
                                if (img_addr[11:0] == 12'hFFF) begin
                                    if (!tx_fifo_full)
                                        fifo_push(8'h06);
                                    else
                                        img_ackq <= 1'b1;
                                end
                                img_addr <= img_addr + 21'd1;
                                if (active_up_last) begin
                                    // Arrived and taken are counted separately:
                                    // a byte that arrives while the one in hand is
                                    // still in hand is dropped, and an image with
                                    // bytes missing in the middle is wrong.
                                    if (img_rx == {1'b0, img_addr} + 22'd1) begin
                                        str_pos <= STR_DONE_START;
                                    end else begin
                                        if (img_is_hd) hd_up_bad <= 1'b1;
                                        else           img_up_bad <= 1'b1;
                                        str_pos <= STR_LOST_START;
                                    end
                                    str_cnt    <= (img_rx == {1'b0, img_addr} + 22'd1)
                                                  ? STR_DONE_LEN : STR_LOST_LEN;
                                    return_job <= M_IDLE;
                                    main_state <= M_STR;
                                end
                            end
                        end else if (img_have) begin
                            if (!active_up_busy) begin
                                if (img_is_hd) begin
                                    hd_up_data <= img_byte;
                                    hd_up_go   <= 1'b1;
                                end else begin
                                    img_up_data <= img_byte;
                                    img_up_go   <= 1'b1;
                                end
                                img_have    <= 1'b0;
                                img_sent    <= 1'b1;
                            end
                        end
                        if (rx_valid) begin
                            img_rx <= img_rx + 22'd1;
                            if (!img_have && (!img_sent || active_up_done)) begin
                                img_byte <= rx_byte;
                                img_have <= 1'b1;
                            end
                        end
                        if ((img_rx >= img_target_bytes) && !img_have && !img_sent && (img_addr != img_target_bytes[20:0])) begin
                            if (img_is_hd) hd_up_bad <= 1'b1;
                            else           img_up_bad <= 1'b1;
                            str_pos    <= STR_LOST_START;
                            str_cnt    <= STR_LOST_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        // The acknowledgement, whenever there is room for it.
                        if (img_ackq && !tx_fifo_full) begin
                            img_ackq <= 1'b0;
                            fifo_push(8'h06);
                        end
                    end else begin
                        // Drive to host.  The request is made only with room in
                        // the FIFO, and nothing else pushes to the FIFO while
                        // this runs -- the console is silent while the machine is
                        // paused and the string engine has already finished -- so
                        // the byte that comes back always has somewhere to go.
                        if (img_ask) begin
                            if (active_dn_valid) begin
                                img_ask  <= 1'b0;
                                img_addr <= img_addr + 21'd1;
                                fifo_push(active_dn_data);
                                if (active_dn_last) begin
                                    str_pos    <= STR_DONE_START;
                                    str_cnt    <= STR_DONE_LEN;
                                    return_job <= M_IDLE;
                                    main_state <= M_STR;
                                end
                            end
                        end else if (!tx_fifo_full) begin
                            if (img_is_hd) hd_dn_go <= 1'b1;
                            else           img_dn_go <= 1'b1;
                            img_ask   <= 1'b1;
                        end
                    end
                end

                M_FILE: begin
                    if (f_tx_valid) fifo_push(f_tx_byte);
                    if (f_active) f_seen <= 1'b1;
                    if (f_seen && !f_active) begin
                        f_start    <= 1'b0;
                        f_seen     <= 1'b0;
                        str_pos    <= STR_PROMPT_START;
                        str_cnt    <= STR_PROMPT_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end
                end

                default: main_state <= M_IDLE;
            endcase

            // In Console Mode: stream Apple II COUT characters directly to UART TX
            if (!dbg_mode && (main_state == M_IDLE) && !tx_fifo_full && !rx_valid) begin
                if (cout_need_lf) begin
                    fifo_push(8'h0A); // '\n'
                    cout_need_lf <= 1'b0;
                end else if (cout_pending) begin
                    cout_pending <= 1'b0;
                    if (cout_char_buf[6:0] == 7'h0D) begin
                        fifo_push(8'h0D); // '\r'
                        cout_need_lf <= 1'b1;  // Schedule '\n'
                    end else if (cout_char_buf[6:0] == 7'h08) begin
                        fifo_push(8'h08); // '\b'
                    end else if (cout_char_buf[6:0] >= 7'h20 && cout_char_buf[6:0] <= 7'h7E) begin
                        fifo_push({1'b0, cout_char_buf[6:0]});
                    end else if (cout_char_buf[6:0] == 7'h07) begin
                        fifo_push(8'h07); // Bell
                    end
                end else if (slot_tx_pend) begin
                    slot_tx_pend <= 1'b0;
                    fifo_push(slot_tx_buf);
                end
            end
        end
    end

`ifdef DBG_IMG
    // One line per transition into or out of the image state, and one per
    // command byte: enough to see who left M_IMG and why.
    reg [3:0] img_prev_state = M_IDLE;
    always @(posedge clk) begin
        img_prev_state <= main_state;
        if ((main_state == M_IMG) != (img_prev_state == M_IMG))
            $display("[img] %0s M_IMG t=%0t addr=%0d st %0d->%0d rx=%02x",
                     (main_state == M_IMG) ? "enter" : "leave", $time, img_addr,
                     img_prev_state, main_state, rx_byte);
        if (dbg_mode && (main_state == M_IDLE) && rx_valid)
            $display("[cmd] t=%0t byte %02x img_cmd=%b", $time, rx_byte, img_cmd);
    end
`endif

endmodule
