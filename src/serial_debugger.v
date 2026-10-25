// Apple //e serial console and hardware debugger, over the Dock's 1 Mbps
// UART (src/uart_defs.vh).  The web page (web/) is its client.
//
// Console mode (the default): the Apple's COUT ($FDED) output goes up the
// UART as text, and received printable bytes are echoed back.
//
// Debugger mode (Ctrl+B, 0x02, toggles it; the CPU is held while it is on):
//   r  registers, s  step one instruction, c  continue, x  CPU reset
//   m  16 bytes of memory; 0 1 4 8 f v first set the address ($0000 $0100
//      $0400 $0800 $FA60 $FFF0) and dump, m then pages on by 16; @hhhh sets
//      any address (the README's card timing: @c0f0 then m)
//   t  video, PLL and the DDR3 diagnostic word, w  the displayed text page and
//      lo-res rows 20-23 (the mixed-mode lines), ?  help (the page's handshake)
//   i  the Disk ][ head ("H:hh") and the TF card: "S:ssss", src/sd_vol.v's
//      state ({loading, busy, err, estage[2:0], fs_ok, 0, fail[3:0],
//      present[3:0]}; drives 0-1 are slot 6, 2-3 slot 7)
//   uhhhhhhhh  write TF card sectors from LBA hhhhhhhh: "UPLOAD HD", then
//      records (01 + 512 bytes = the next sector, 00 hi lo = (hi:lo)+1 zero
//      sectors, 02 = done), one 06 back per record once it is on the card,
//      then "done" or "lost"
//   bhhhhhhhhcccc  read cccc TF card sectors from LBA hhhhhhhh: "SECTORS",
//      the raw bytes, then "done" (or "lost": past the card's end)
//   y1-y4  reload a drive (S6D1 S6D2 S7D1 S7D2) from A2CONFIG.TXT on the
//      card, after its written floppy tracks are back on it; the load runs on
//      after the prompt, so poll i until S says not busy
//   Every drive's disk is a file on the TF card; there is no other way in.

`include "src/uart_defs.vh"
`include "src/version.vh"

module serial_debugger (
    input  wire        clk,            // 27.0 MHz
    input  wire        reset,          // Active-high reset
    input  wire        ce_1m,          // 1.023 MHz clock enable

    // Physical UART TX Pin (Pin 69)
    output wire        uart_tx,

    // UART RX from input_controller
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,

    // The Super Serial Card's line, framed into the console stream for the
    // page's modem: 1E <byte> for a byte the Apple sent, 1F <st> for its DTR
    // and baud.  Neither 1E nor 1F is anything else the console sends.
    input  wire        ssc_tx_req,
    input  wire [7:0]  ssc_tx_byte,
    output reg         ssc_tx_ack = 1'b0,
    input  wire        ssc_st_req,
    input  wire [7:0]  ssc_st_byte,
    output reg         ssc_st_ack = 1'b0,

    // Debug Mode Status (1: Debugger active, 0: Apple //e Console active)
    output reg         dbg_mode,

    // CPU Ready / Pause Control
    output reg         cpu_rdy,
    output reg         cpu_reset_req,

    // Memory Inspection Bus
    output reg  [15:0] dbg_mem_addr,
    output reg         dbg_aux_read = 1'b0,
    input  wire [7:0]  dbg_mem_din,
    input  wire        dbg_mem_ready,   // dbg_mem_din is valid (LC RAM is in DDR3 and answers slowly)

    // 65C02 CPU Registers & Bus Snooping
    input  wire [15:0] cpu_pc,
    input  wire [7:0]  dsk_head,     // the Disk ][ head's track, shown by i
    input  wire [7:0]  cpu_a,
    input  wire [7:0]  cpu_x,
    input  wire [7:0]  cpu_y,
    input  wire [7:0]  cpu_s,
    input  wire [7:0]  cpu_p,
    input  wire [7:0]  cpu_ir,
    input  wire [15:0] cpu_addr,
    input  wire        cpu_sync,
    input  wire        z80_on,       // the SoftCard's Z80 has the bus: s cannot step the 6502
    input  wire        wp_hit,       // the k watchpoint's write (apple2_core debug_wp_hit)
    input  wire        slot_irq_n,
    input  wire [6:0]  card_irq_n,

    // The TF card (src/sd_vol.v)
    output reg         sd_mnt_go,
    output reg  [1:0]  sd_mnt_drv,
    input  wire [15:0] sd_stat,
    // ...the u write, straight onto the card (sd_vol x_*)
    output reg         sd_x_go,
    output reg  [31:0] sd_x_lba,
    output reg         sd_x_zero,
    output reg  [7:0]  sd_x_byte,
    output reg         sd_x_valid,
    input  wire        sd_x_take,
    // ...and the b read (sd_vol r_*)
    output reg         sd_r_go,
    output reg  [31:0] sd_r_lba,
    output reg  [15:0] sd_r_cnt,
    input  wire [7:0]  sd_r_byte,
    input  wire        sd_r_valid,
    output reg         sd_r_take,
    input  wire        sd_r_done,
    input  wire        sd_r_ok,

    // Softswitch state, for the W (screen dump) command
    input  wire        text_mode,
    input  wire        mixed_mode,
    input  wire        page2,
    input  wire        hires_mode,
    input  wire        dhires,
    input  wire        col80,
    input  wire        pll_locked,
    input  wire [31:0] ddr_diag      // printed after PLL: by `t` (src/aux_ram.v diag)
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
    // 3. Apple //e COUT ($FDED) Interceptor
    // =========================================================================
    reg cout_prev_sync = 1'b0;
    wire cout_hit = ce_1m && cpu_sync && !cout_prev_sync && (cpu_addr == 16'hFDED);

    always @(posedge clk or posedge reset) begin
        if (reset)
            cout_prev_sync <= 1'b0;
        else if (ce_1m)
            cout_prev_sync <= cpu_sync;
    end

    reg [7:0] ssc_second = 8'd0;       // the byte after a 1E/1F marker
    reg       ssc_second_pend = 1'b0;
    reg [7:0] cout_char_buf = 8'd0;
    reg       cout_pending  = 1'b0;
    reg       cout_need_lf  = 1'b0;

    // =========================================================================
    // 4. Static String Table ROM (218 Bytes)
    // =========================================================================
    // Each string's start is the one before's start plus its length, so the
    // lengths are the only numbers to keep right, and the text is STR_TEXT in
    // the same order.  web/test/protocol.test.js reads this file and checks
    // the strings the page depends on against web/src/protocol.js.
    localparam [8:0] STR_BANNER_START = 9'd0;
    localparam [7:0] STR_BANNER_LEN   = 8'd45;
    localparam [8:0] STR_RESUME_START = STR_BANNER_START + STR_BANNER_LEN;
    localparam [7:0] STR_RESUME_LEN   = 8'd17;
    localparam [8:0] STR_HELP_START = STR_RESUME_START + STR_RESUME_LEN;
    localparam [7:0] STR_HELP_LEN   = 8'd58;
    localparam [8:0] STR_PROMPT_START = STR_HELP_START + STR_HELP_LEN;
    localparam [7:0] STR_PROMPT_LEN   = 8'd4;
    localparam [8:0] STR_PC_LBL_START = STR_PROMPT_START + STR_PROMPT_LEN;
    localparam [7:0] STR_PC_LBL_LEN   = 8'd6;
    localparam [8:0] STR_A_LBL_START = STR_PC_LBL_START + STR_PC_LBL_LEN;
    localparam [7:0] STR_A_LBL_LEN   = 8'd4;
    localparam [8:0] STR_X_LBL_START = STR_A_LBL_START + STR_A_LBL_LEN;
    localparam [7:0] STR_X_LBL_LEN   = 8'd4;
    localparam [8:0] STR_Y_LBL_START = STR_X_LBL_START + STR_X_LBL_LEN;
    localparam [7:0] STR_Y_LBL_LEN   = 8'd4;
    localparam [8:0] STR_S_LBL_START = STR_Y_LBL_START + STR_Y_LBL_LEN;
    localparam [7:0] STR_S_LBL_LEN   = 8'd5;
    localparam [8:0] STR_P_LBL_START = STR_S_LBL_START + STR_S_LBL_LEN;
    localparam [7:0] STR_P_LBL_LEN   = 8'd4;
    localparam [8:0] STR_OP_LBL_START = STR_P_LBL_START + STR_P_LBL_LEN;
    localparam [7:0] STR_OP_LBL_LEN   = 8'd6;
    localparam [8:0] STR_BAR_SP_START = STR_OP_LBL_START + STR_OP_LBL_LEN;
    localparam [7:0] STR_BAR_SP_LEN   = 8'd2;
    localparam [8:0] STR_CRLF_START = STR_BAR_SP_START + STR_BAR_SP_LEN;
    localparam [7:0] STR_CRLF_LEN   = 8'd2;
    localparam [8:0] STR_SCR_START = STR_CRLF_START + STR_CRLF_LEN;
    localparam [7:0] STR_SCR_LEN   = 8'd5;
    localparam [8:0] STR_GFX_START = STR_SCR_START + STR_SCR_LEN;
    localparam [7:0] STR_GFX_LEN   = 8'd5;
    localparam [8:0] STR_HR_START  = STR_GFX_START + STR_GFX_LEN;
    localparam [7:0] STR_HR_LEN    = 8'd5;
    localparam [8:0] STR_AX_START  = STR_HR_START + STR_HR_LEN;
    localparam [7:0] STR_AX_LEN    = 8'd5;
    localparam [8:0] STR_END_START = STR_AX_START + STR_AX_LEN;
    localparam [7:0] STR_END_LEN   = 8'd7;
    localparam [8:0] STR_DONE_START = STR_END_START + STR_END_LEN;
    localparam [7:0] STR_DONE_LEN   = 8'd8;
    localparam [8:0] STR_LOST_START = STR_DONE_START + STR_DONE_LEN;
    localparam [7:0] STR_LOST_LEN   = 8'd8;
    localparam [8:0] STR_HDUP_START = STR_LOST_START + STR_LOST_LEN;
    localparam [7:0] STR_HDUP_LEN   = 8'd13;
    localparam [8:0] STR_SECS_START = STR_HDUP_START + STR_HDUP_LEN;
    localparam [7:0] STR_SECS_LEN   = 8'd11;
    localparam [8:0] STR_VID_START = STR_SECS_START + STR_SECS_LEN;
    localparam [7:0] STR_VID_LEN   = 8'd4;
    localparam [8:0] STR_PLL_START = STR_VID_START + STR_VID_LEN;
    localparam [7:0] STR_PLL_LEN   = 8'd5;
    localparam [8:0] STR_DDR_START = STR_PLL_START + STR_PLL_LEN;
    localparam [7:0] STR_DDR_LEN   = 8'd3;
    localparam [8:0] STR_VER_START = STR_DDR_START + STR_DDR_LEN;
    localparam [7:0] STR_VER_LEN   = `FW_VER_LEN;
    localparam integer STR_BYTES = 240 + `FW_VER_LEN;
    // \015\012 is CR LF: Verilog-2001 has no \r escape.
    localparam [8*STR_BYTES-1:0] STR_TEXT = {
        "\015\012[ Apple //e Debugger ] (h=Help, c=Cont)\015\012> ",  // BANNER
        "\015\012[Resuming...]\015\012",  // RESUME
        "\015\012Cmds: r=Regs s=Step c=Cont m=Mem t=Stat w=Scr h=Help\015\012> ",  // HELP
        "\015\012> ",  // PROMPT
        "\015\012PC:$",  // PC_LBL
        " A:$",  // A_LBL
        " X:$",  // X_LBL
        " Y:$",  // Y_LBL
        " SP:$",  // S_LBL
        " P:[",  // P_LBL
        "] OP:$",  // OP_LBL
        " |",  // BAR_SP
        "\015\012",  // CRLF
        "\015\012$SS",  // SCR
        "\015\012$GF",  // GFX
        "\015\012$HR",  // HR
        "\015\012$AX",  // AX (Auxiliary RAM dump)
        "\015\012$SEND",  // END
        "\015\012done\015\012",  // DONE
        "\015\012lost\015\012",  // LOST
        "\015\012UPLOAD HD\015\012",  // HDUP
        "\015\012SECTORS\015\012",  // SECS
        "VID:",  // VID
        " PLL:",  // PLL
        " D:",   // DDR
        `FW_VER_TEXT  // VER
    };
    reg [7:0] str_rom [0:STR_BYTES-1];
    integer si;
    initial begin
        for (si = 0; si < STR_BYTES; si = si + 1)
            str_rom[si] = STR_TEXT[8 * (STR_BYTES - 1 - si) +: 8];
        // synthesis translate_off
        // a length that does not match its text leaves a NUL or cuts one off
        if (STR_VER_START + STR_VER_LEN != STR_BYTES || str_rom[0] == 8'h00)
            $display("FAIL: serial_debugger string table lengths do not add up");
        // synthesis translate_on
    end

    // String printer sub-engine
    reg [8:0] str_pos = 9'd0;
    reg [7:0] str_cnt = 8'd0;

    // Hex digit printer sub-engine (prints up to 4 hex digits)
    reg [15:0] hex_val = 16'd0;
    reg [2:0]  hex_digits = 3'd0;

    // Which received bytes the console echo passes through. Anything else is
    // protocol: the 0xFE key packet and the 0xFF gamepad packet must not be
    // reflected into the terminal as text.
    wire echoable = (rx_byte >= 8'h20 && rx_byte <= 8'h7E) ||
                    (rx_byte == 8'h0D) || (rx_byte == 8'h0A) ||
                    (rx_byte == 8'h08) || (rx_byte == 8'h07);

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
    localparam M_INFO    = 4'd8;   // the Disk ][ head and the TF card (the i command)
    localparam M_SDW     = 4'd10;  // u: records onto TF card sectors
    localparam M_SDR     = 4'd11;  // b: TF card sectors back

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
    reg [13:0] scr_left  = 14'd0;   // bytes still to print
    reg [5:0]  scr_col   = 6'd0;    // byte within the current row, 0..39
    reg [1:0]  gfx_row   = 2'd0;    // graphics row being dumped, 0..3
    reg [2:0]  scr_wait  = 3'd0;    // settle cycles between RAM reads
    reg [7:0]  scr_flags = 8'h00;

    // The text page lo-res rows 20-23 sit at page + $250/$2D0/$350/$3D0, i.e.
    // page + $250 + 128*n (the same row interleave video_generator.v reads).
    wire [15:0] scr_page   = page2 ? 16'h0800 : 16'h0400;
    wire [15:0] scrgfx_row = scr_page + 16'h0250 + {7'd0, gfx_row, 7'd0};

    reg [3:0] main_state = M_IDLE;
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
    reg [2:0]  adr_n     = 3'd0;         // hex digits still owed after '@'
    reg        mnt_n     = 1'b0;         // the drive digit is owed after 'y'
    reg        wp_arm    = 1'b0;         // k: stop on the next wp_hit, once
    reg [3:0]  q_n       = 4'd0;         // hex digits still owed after 'u'
    reg [3:0]  rd_n      = 4'd0;         // ...and after 'b' (8 of LBA, 4 of count)
    reg        r_fin     = 1'b0;         // the b read has ended (its last byte may still be out)

    // The u write.  The card writes far faster than 1Mbps brings bytes, so a
    // byte goes to sd_vol as soon as it arrives and nothing is buffered.
    localparam [2:0] X_TAG = 3'd0, X_CHI = 3'd1, X_CLO = 3'd2, X_DATA = 3'd3,
                     X_ZGO = 3'd4, X_WAIT = 3'd5;
    reg [2:0]  x_ph   = X_TAG;
    reg [9:0]  x_cnt  = 10'd0;           // bytes of the block handed over
    reg [15:0] x_zn   = 16'd0;           // zero blocks still owed after this one
    reg [1:0]  x_hold = 2'd0;            // clocks before sd_vol's busy means anything
    reg        x_zrun = 1'b0;            // the block in flight is part of a zero run
    wire       sd_busy_s = sd_stat[14];
    wire       sd_err_s  = sd_stat[13];
    wire       sd_no     = sd_err_s || sd_busy_s;   // no card, or still loading: refuse u and b
    wire       rx_hex    = (rx_byte >= "0" && rx_byte <= "9") ||
                           (rx_byte >= "a" && rx_byte <= "f") ||
                           (rx_byte >= "A" && rx_byte <= "F");
    wire [3:0] rx_nib    = rx_byte[6] ? rx_byte[3:0] + 4'd9 : rx_byte[3:0];
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

    // Print str_rom[pos +: cnt], then carry on in `job`
    task say(input [8:0] pos, input [7:0] cnt, input [3:0] job);
        begin
            str_pos    <= pos;
            str_cnt    <= cnt;
            return_job <= job;
            main_state <= M_STR;
        end
    endtask

    // ...the prompt, then idle
    task prompt;
        say(STR_PROMPT_START, STR_PROMPT_LEN, M_IDLE);
    endtask

    // From inside a sequencer: a string, or the top n hex digits of v, and
    // then back to this sequencer at step `next`
    task sub_say(input [8:0] pos, input [7:0] cnt, input [4:0] next);
        begin
            say(pos, cnt, main_state);
            seq_step <= next;
        end
    endtask
    task sub_hex(input [15:0] v, input [2:0] n, input [4:0] next);
        begin
            hex_val    <= v;
            hex_digits <= n;
            return_job <= main_state;
            main_state <= M_HEX;
            seq_step   <= next;
        end
    endtask

    // Back to the Apple
    task resume;
        begin
            dbg_mode <= 1'b0;
            cpu_rdy  <= 1'b1;
            say(STR_RESUME_START, STR_RESUME_LEN, M_IDLE);
        end
    endtask

    // 16 bytes of memory from a
    task mem_dump(input [15:0] a);
        begin
            dump_addr  <= a;
            main_state <= M_MEM;
            seq_step   <= 5'd0;
            mem_col    <= 4'd0;
            mem_wait   <= 3'd0;
        end
    endtask

    // The register dump's flags: steps 11-18 print P's bits 7-0
    localparam [63:0] P_FLAGS = "NV-BDIZC";   // byte b (from the right) is bit b's letter
    wire [2:0] p_bit = 5'd18 - seq_step;

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
                scr_left   <= scr_left - 14'd1;
                scr_col    <= scr_col + 1'b1;
                sub_hex({dbg_mem_din, 8'h00}, 3'd2, next);
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
            wp_arm         <= 1'b0;
            latched_pc     <= 16'hFA62;
            latched_a      <= 8'h00;
            latched_x      <= 8'h00;
            latched_y      <= 8'h00;
            latched_s      <= 8'hFF;
            latched_p      <= 8'h20;
            latched_ir     <= 8'h00;
            dump_addr      <= 16'hFA60;
            dbg_mem_addr   <= 16'hFA60;
            main_state     <= M_IDLE;
            return_job     <= M_IDLE;
            seq_step       <= 5'd0;
            str_pos        <= 8'd0;
            str_cnt        <= 8'd0;
            cout_char_buf  <= 8'd0;
            cout_pending   <= 1'b0;
            cout_need_lf   <= 1'b0;
            mem_col        <= 4'd0;
            mem_wait       <= 3'd0;
            scr_addr       <= 16'h0400;
            scr_left       <= 14'd0;
            scr_col        <= 6'd0;
            scr_wait       <= 3'd0;
            scr_flags      <= 8'h00;
            dbg_aux_read   <= 1'b0;
        end else begin
            fifo_push_en <= 1'b0;
            sd_mnt_go    <= 1'b0;
            sd_x_go      <= 1'b0;
            sd_r_go      <= 1'b0;
            sd_r_take    <= 1'b0;

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

            // Latch Apple II COUT
            if (cout_hit && !dbg_mode) begin
                cout_char_buf <= cpu_a;
                cout_pending  <= 1'b1;
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

            // Mode switching via Ctrl+B (ASCII 0x02), or by the armed k
            // watchpoint, which enters exactly as Ctrl+B does (a byte arriving
            // in that one clock is dropped)
            if (wp_arm && wp_hit && !dbg_mode) begin
                wp_arm     <= 1'b0;
                dbg_mode   <= 1'b1;
                cpu_rdy    <= 1'b0;
                latch_regs;
                dump_addr  <= cpu_pc;
                say(STR_BANNER_START, STR_BANNER_LEN, M_REGS);
                seq_step   <= 5'd0;
            end else if (rx_valid && (rx_byte == 8'h02) && (main_state != M_SDW)) begin
                if (!dbg_mode) begin
                    dbg_mode   <= 1'b1;
                    cpu_rdy    <= 1'b0;
                    latch_regs;
                    dump_addr  <= cpu_pc;
                    say(STR_BANNER_START, STR_BANNER_LEN, M_REGS);
                    seq_step   <= 5'd0;
                end else
                    resume;
            end else if (!dbg_mode && (main_state == M_IDLE) && rx_valid) begin
                // Echo console keystrokes back so the host sees what it typed.
                // Only characters a terminal can show: the 0xFE key packet and
                // the 0xFF gamepad packet are protocol, not text, and used to
                // land in the console as five or three junk bytes each.
                if (!tx_fifo_full && echoable) begin
                    fifo_push(rx_byte);
                end
            end else if (dbg_mode && (main_state == M_IDLE) && rx_valid) begin
                if (adr_n != 3'd0) begin
                    // "@" and four hex digits set the dump address
                    if (rx_hex) begin
                        dump_addr <= {dump_addr[11:0], rx_nib};
                        adr_n     <= adr_n - 1'b1;
                    end else
                        adr_n <= 3'd0;
                end else if (q_n != 4'd0) begin
                    // "u" and eight hex digits: write records from that LBA on
                    if (rx_hex) begin
                        sd_x_lba <= {sd_x_lba[27:0], rx_nib};
                        q_n      <= q_n - 1'b1;
                        if (q_n == 4'd1) begin
                            sd_x_valid <= 1'b0;
                            x_ph       <= X_TAG;
                            if (sd_no) say(STR_LOST_START, STR_LOST_LEN, M_IDLE);
                            else       say(STR_HDUP_START, STR_HDUP_LEN, M_SDW);
                        end
                    end else
                        q_n <= 4'd0;
                end else if (rd_n != 4'd0) begin
                    // "b", eight hex digits of LBA and four of count: read sectors
                    if (rx_hex) begin
                        rd_n <= rd_n - 1'b1;
                        if (rd_n > 4'd4) sd_r_lba <= {sd_r_lba[27:0], rx_nib};
                        else             sd_r_cnt <= {sd_r_cnt[11:0], rx_nib};
                        if (rd_n == 4'd1) begin
                            r_fin      <= 1'b0;
                            sd_r_go    <= !sd_no;
                            if (sd_no) say(STR_LOST_START, STR_LOST_LEN, M_IDLE);
                            else       say(STR_SECS_START, STR_SECS_LEN, M_SDR);
                        end
                    end else
                        rd_n <= 4'd0;
                end else if (mnt_n) begin
                    // "y" and the drive digit, 1-4: reload that drive from the card
                    mnt_n <= 1'b0;
                    if (rx_byte >= "1" && rx_byte <= "4") begin
                        sd_mnt_drv <= rx_byte[1:0] - 2'd1;
                        sd_mnt_go  <= 1'b1;
                        prompt;
                    end
                end else case (rx_byte)
                    "@": adr_n <= 3'd4;
                    "y": mnt_n <= 1'b1;
                    "k", "K": begin   // arm the $0100-$0105 write watchpoint
                        wp_arm <= 1'b1;
                        prompt;
                    end
                    "u": q_n   <= 4'd8;
                    "b": rd_n  <= 4'd12;
                    "r", "R": begin
                        latch_regs;
                        main_state <= M_REGS;
                        seq_step   <= 5'd0;
                    end

                    // The step waits on the 6502's SYNC, which never moves
                    // while the Z80 has the bus: it would hang with the CPU
                    // let go.  ponytail: refused; step the Z80 by m1_n if needed.
                    "s", "S":
                        if (z80_on) prompt;
                        else        step_fsm <= S_START;

                    "c", "C": resume;

                    // m pages on; the presets set the address first
                    "m", "M":  mem_dump(dump_addr);
                    "0":       mem_dump(16'h0000);
                    "1":       mem_dump(16'h0100);
                    "4":       mem_dump(16'h0400);
                    "8":       mem_dump(16'h0800);
                    "f", "F":  mem_dump(16'hFA60);
                    "v", "V":  say(STR_VER_START, STR_VER_LEN, M_IDLE);

                    "x", "X": begin
                        reset_timer <= 8'd255;
                        dbg_mode    <= 1'b1;
                        cpu_rdy     <= 1'b0;
                    end

                    "i", "I", "q", "Q": begin
                        main_state <= M_INFO;
                        seq_step   <= 5'd0;
                    end

                    "t", "T": begin
                        main_state <= M_STATUS;
                        seq_step   <= 5'd0;
                    end

                    "w", "W": begin
                        main_state <= M_SCREEN;
                        seq_step   <= 5'd0;
                    end

                    "h", "H", "?": say(STR_HELP_START, STR_HELP_LEN, M_IDLE);

                    8'h0D, 8'h0A: prompt;

                    default: ;
                endcase
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
                        5'd0:  sub_say(STR_PC_LBL_START, STR_PC_LBL_LEN, 5'd1);   // "PC:$"
                        5'd1:  sub_hex(latched_pc, 3'd4, 5'd2);
                        5'd2:  sub_say(STR_A_LBL_START, STR_A_LBL_LEN, 5'd3);     // " A:$"
                        5'd3:  sub_hex({latched_a, 8'h00}, 3'd2, 5'd4);
                        5'd4:  sub_say(STR_X_LBL_START, STR_X_LBL_LEN, 5'd5);     // " X:$"
                        5'd5:  sub_hex({latched_x, 8'h00}, 3'd2, 5'd6);
                        5'd6:  sub_say(STR_Y_LBL_START, STR_Y_LBL_LEN, 5'd7);     // " Y:$"
                        5'd7:  sub_hex({latched_y, 8'h00}, 3'd2, 5'd8);
                        5'd8:  sub_say(STR_S_LBL_START, STR_S_LBL_LEN, 5'd9);     // " SP:$"
                        5'd9:  sub_hex({latched_s, 8'h00}, 3'd2, 5'd10);
                        5'd10: sub_say(STR_P_LBL_START, STR_P_LBL_LEN, 5'd11);    // " P:["
                        // Flags N V - B D I Z C: steps 11-18 print bits 7-0
                        5'd11, 5'd12, 5'd13, 5'd14, 5'd15, 5'd16, 5'd17, 5'd18:
                            if (!tx_fifo_full) begin
                                fifo_push(latched_p[p_bit] ? P_FLAGS[8*p_bit +: 8] : "-");
                                seq_step <= seq_step + 5'd1;
                            end
                        5'd19: sub_say(STR_OP_LBL_START, STR_OP_LBL_LEN, 5'd20);  // "] OP:$"
                        5'd20: sub_hex({latched_ir, 8'h00}, 3'd2, 5'd21);
                        5'd21: prompt;
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Memory Dump Sequencer (16 Bytes)
                // -------------------------------------------------------------
                M_MEM: begin
                    case (seq_step)
                        5'd0: sub_say(STR_CRLF_START, STR_CRLF_LEN, 5'd1);
                        5'd1: if (!tx_fifo_full) begin fifo_push("$"); seq_step <= 5'd2; end
                        5'd2: sub_hex(dump_addr, 3'd4, 5'd3);
                        5'd3: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd4; end
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
                        5'd10: sub_say(STR_BAR_SP_START, STR_BAR_SP_LEN, 5'd11);   // " |"
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
                        5'd13: begin
                            dump_addr <= dump_addr + 16'd16;
                            prompt;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Status Display Sequencer: VID:T PLL:1 D:<ddr_diag>, which
                // web/src/stream.js parses
                // -------------------------------------------------------------
                M_STATUS: begin
                    case (seq_step)
                        5'd0: sub_say(STR_CRLF_START, STR_CRLF_LEN, 5'd1);
                        5'd1: sub_say(STR_VID_START, STR_VID_LEN, 5'd2);
                        5'd2: if (!tx_fifo_full) begin fifo_push(text_mode ? "T" : "G"); seq_step <= 5'd3; end
                        5'd3: sub_say(STR_PLL_START, STR_PLL_LEN, 5'd4);
                        5'd4: if (!tx_fifo_full) begin fifo_push(pll_locked ? "1" : "0"); seq_step <= 5'd5; end
                        5'd5: sub_say(STR_DDR_START, STR_DDR_LEN, 5'd6);
                        5'd6: sub_hex(ddr_diag[31:16], 3'd4, 5'd7);
                        5'd7: sub_hex(ddr_diag[15:0], 3'd4, 5'd8);
                        5'd8: prompt;
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // i: CRLF, H:hh (the Disk ][ head), S:ssss (the TF card), a prompt
                // -------------------------------------------------------------
                M_INFO: begin
                    case (seq_step)
                        5'd0: sub_say(STR_CRLF_START, STR_CRLF_LEN, 5'd1);
                        5'd1: if (!tx_fifo_full) begin fifo_push("H"); seq_step <= 5'd2; end
                        5'd2: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd3; end
                        5'd3: sub_hex({dsk_head, 8'h00}, 3'd2, 5'd4);
                        5'd4: if (!tx_fifo_full) begin fifo_push(" "); seq_step <= 5'd5; end
                        5'd5: if (!tx_fifo_full) begin fifo_push("S"); seq_step <= 5'd6; end
                        5'd6: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd7; end
                        5'd7: sub_hex(sd_stat, 3'd4, 5'd8);
                        5'd8: if (!tx_fifo_full) begin fifo_push(" "); seq_step <= 5'd9; end
                        5'd9: if (!tx_fifo_full) begin fifo_push("Q"); seq_step <= 5'd10; end
                        5'd10: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd11; end
                        5'd11: sub_hex({~slot_irq_n, ~card_irq_n, 8'h00}, 3'd2, 5'd12);
                        5'd12: prompt;
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
                            // DHIRES: AN3 off with 80COL in graphics, i.e. double
                            // hi-res, or double lo-res when HIRES is off
                            scr_flags <= {1'b0, (dhires && col80 && !text_mode),
                                          pll_locked, hires_mode, mixed_mode,
                                          page2, text_mode};
                            dbg_aux_read <= 1'b0;
                            sub_say(STR_SCR_START, STR_SCR_LEN, 5'd1);
                        end
                        5'd1: if (!tx_fifo_full) begin // flags byte
                            fifo_push(" ");
                            sub_hex({scr_flags, 8'h00}, 3'd2, 5'd2);
                        end
                        5'd2: if (!tx_fifo_full) begin // start of text page
                            fifo_push(" ");
                            scr_addr <= scr_page;
                            scr_left <= 14'd1024;
                            scr_col  <= 6'd0;
                            scr_wait <= 3'd0;
                            seq_step <= 5'd3;
                        end
                        5'd3: begin
                            if (scr_left == 14'd0) begin
                                if (hires_mode) seq_step <= 5'd11;
                                else if (dhires && col80 && !text_mode) seq_step <= 5'd14;
                                else if (mixed_mode) seq_step <= 5'd6;
                                else seq_step <= 5'd9;
                            end else begin
                                scr_read_byte(5'd4);
                            end
                        end
                        5'd4: if (scr_col == 6'd40) begin // end of a text row
                            scr_col <= 6'd0;
                            say(STR_CRLF_START, STR_CRLF_LEN, M_SCREEN);
                        end else begin
                            seq_step <= 5'd3;
                        end
                        5'd6: if (!tx_fifo_full) begin // "\r\n$GF"
                            // Lo-res rows 20-23 of the same page the text came
                            // from: in lo-res the graphics share the text page,
                            // and these are the four lines mixed mode hides. A
                            // hi-res screen ignores them.
                            sub_say(STR_GFX_START, STR_GFX_LEN, 5'd7);
                            scr_addr   <= scrgfx_row;
                            scr_left   <= 14'd160; // 4 rows of 40 bytes
                            gfx_row    <= 2'd0;
                            scr_col    <= 6'd0;
                            scr_wait   <= 3'd0;
                        end
                        5'd7: begin
                            if (scr_left == 14'd0) begin
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
                                say(STR_CRLF_START, STR_CRLF_LEN, M_SCREEN);
                            end
                        end else begin
                            seq_step <= 5'd7;
                        end
                        5'd11: if (!tx_fifo_full) begin // "\r\n$HR"
                            sub_say(STR_HR_START, STR_HR_LEN, 5'd12);
                            scr_addr     <= page2 ? 16'h4000 : 16'h2000;
                            scr_left     <= 14'd8192;
                            scr_col      <= 6'd0;
                            scr_wait     <= 3'd0;
                            dbg_aux_read <= 1'b0;
                        end
                        5'd12: begin
                            if (scr_left == 14'd0) begin
                                if (dhires && col80 && !text_mode) seq_step <= 5'd14;
                                else seq_step <= 5'd9;
                            end else begin
                                scr_read_byte(5'd13);
                            end
                        end
                        5'd13: if (scr_col == 6'd40) begin // end of a 40-byte line
                            scr_col <= 6'd0;
                            say(STR_CRLF_START, STR_CRLF_LEN, M_SCREEN);
                        end else begin
                            seq_step <= 5'd12;
                        end
                        5'd14: if (!tx_fifo_full) begin // "\r\n$AX"
                            sub_say(STR_AX_START, STR_AX_LEN, 5'd15);
                            // the aux half: the hi-res page, or for double
                            // lo-res the 1 KB text page
                            scr_addr     <= !hires_mode ? scr_page : page2 ? 16'h4000 : 16'h2000;
                            scr_left     <= hires_mode ? 14'd8192 : 14'd1024;
                            scr_col      <= 6'd0;
                            scr_wait     <= 3'd0;
                            dbg_aux_read <= 1'b1;
                        end
                        5'd15: begin
                            if (scr_left == 14'd0) begin
                                dbg_aux_read <= 1'b0;
                                seq_step     <= (!hires_mode && mixed_mode) ? 5'd6 : 5'd9;
                            end else begin
                                scr_read_byte(5'd16);
                            end
                        end
                        5'd16: if (scr_col == 6'd40) begin // end of a 40-byte line
                            scr_col <= 6'd0;
                            say(STR_CRLF_START, STR_CRLF_LEN, M_SCREEN);
                        end else begin
                            seq_step <= 5'd15;
                        end
                        5'd9: if (!tx_fifo_full) begin // "\r\n$SEND" then prompt
                            dbg_aux_read <= 1'b0;
                            sub_say(STR_END_START, STR_END_LEN, 5'd10);
                        end
                        5'd10: begin
                            dbg_aux_read <= 1'b0;
                            prompt;
                        end
                        default: begin
                            dbg_aux_read <= 1'b0;
                            main_state <= M_IDLE;
                        end
                    endcase
                end

                // -------------------------------------------------------------
                // u: records onto TF card sectors (record format at u above)
                // -------------------------------------------------------------
                M_SDW: begin
                    if (x_hold != 2'd0) x_hold <= x_hold - 1'b1;
                    if (sd_x_take) sd_x_valid <= 1'b0;
                    case (x_ph)
                        X_TAG, X_CHI, X_CLO:
                            if (rx_valid) case (x_ph)
                                X_TAG:
                                    if (rx_byte == 8'h01) begin
                                        // sd_vol is idle: the last record was acked
                                        // only once its write had finished
                                        sd_x_go <= 1'b1; sd_x_zero <= 1'b0; x_zrun <= 1'b0;
                                        x_cnt <= 10'd0; x_hold <= 2'd3; x_ph <= X_DATA;
                                    end else if (rx_byte == 8'h00) x_ph <= X_CHI;
                                    else begin
                                        // 02 ends the copy; anything else is lost
                                        if (rx_byte == 8'h02) say(STR_DONE_START, STR_DONE_LEN, M_IDLE);
                                        else                  say(STR_LOST_START, STR_LOST_LEN, M_IDLE);
                                    end
                                X_CHI: begin x_zn[15:8] <= rx_byte; x_ph <= X_CLO; end
                                default: begin x_zn[7:0] <= rx_byte; x_ph <= X_ZGO; end
                            endcase
                        X_DATA: begin
                            if (rx_valid) begin
                                sd_x_byte  <= rx_byte;
                                sd_x_valid <= 1'b1;
                                if (sd_x_valid && !sd_x_take)   // the last one is still waiting
                                    say(STR_LOST_START, STR_LOST_LEN, M_IDLE);
                            end
                            if (sd_x_take) begin
                                x_cnt <= x_cnt + 1'b1;
                                if (x_cnt == 10'd511) x_ph <= X_WAIT;
                            end
                        end
                        X_ZGO:
                            if (!sd_busy_s && x_hold == 2'd0) begin
                                sd_x_go <= 1'b1; sd_x_zero <= 1'b1; x_zrun <= 1'b1;
                                x_hold <= 2'd3; x_ph <= X_WAIT;
                            end
                        default:   // X_WAIT: the block is on the card
                            if (x_hold == 2'd0 && !sd_busy_s) begin
                                sd_x_lba <= sd_x_lba + 1'b1;
                                if (sd_err_s)
                                    say(STR_LOST_START, STR_LOST_LEN, M_IDLE);
                                else if (x_zrun && x_zn != 16'd0) begin
                                    x_zn <= x_zn - 1'b1;
                                    x_ph <= X_ZGO;
                                end else begin
                                    fifo_push(8'h06);
                                    x_ph <= X_TAG;
                                end
                            end
                    endcase
                end

                // -------------------------------------------------------------
                // b: TF card sectors, raw, as sd_vol reads them
                // -------------------------------------------------------------
                M_SDR: begin
                    if (sd_r_done) r_fin <= 1'b1;
                    if (sd_r_valid && !sd_r_take && !tx_fifo_full) begin
                        fifo_push(sd_r_byte);
                        sd_r_take <= 1'b1;
                    end else if (r_fin && !sd_r_valid) begin
                        if (sd_r_ok) say(STR_DONE_START, STR_DONE_LEN, M_IDLE);
                        else         say(STR_LOST_START, STR_LOST_LEN, M_IDLE);
                    end
                end

                default: main_state <= M_IDLE;
            endcase

            // In Console Mode: stream Apple II COUT characters directly to UART TX,
            // and the serial card's line between them
            ssc_tx_ack <= 1'b0;
            ssc_st_ack <= 1'b0;
            if (!dbg_mode && (main_state == M_IDLE) && !tx_fifo_full && !rx_valid) begin
                if (ssc_second_pend) begin
                    fifo_push(ssc_second);
                    ssc_second_pend <= 1'b0;
                end else if (cout_need_lf) begin
                    fifo_push(8'h0A); // '\n'
                    cout_need_lf <= 1'b0;
                end else if (ssc_st_req && !ssc_st_ack) begin
                    fifo_push(8'h1F);
                    ssc_second <= ssc_st_byte; ssc_second_pend <= 1'b1; ssc_st_ack <= 1'b1;
                end else if (ssc_tx_req && !ssc_tx_ack) begin
                    fifo_push(8'h1E);
                    ssc_second <= ssc_tx_byte; ssc_second_pend <= 1'b1; ssc_tx_ack <= 1'b1;
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
                end
            end
        end
    end

endmodule
