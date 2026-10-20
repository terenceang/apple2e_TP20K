// ============================================================================
//  prodos_card.v -- Apple //e ProDOS Hard Disk Controller Card for Slot 7
//
//  Features:
//  - Two 2 MB Hard Disk Volumes:
//      Drive 1: SDRAM Bank 2 (addr[21:20] = 2'b10, 4,096 blocks = 2,097,152 bytes)
//      Drive 2: SDRAM Bank 3 (addr[21:20] = 2'b11, 4,096 blocks = 2,097,152 bytes)
//  - 256-Byte On-Board Slot 7 ROM ($C700-$C7FF):
//      Identifies as ProDOS Block Device ($C701=$20, $C703=$00, $C705=$03, $C7FF=$10)
//      ProDOS MLI driver entry at $C742
//      Auto-bootloader at $C700: checks Drive 1 mounted; if empty, jumps to $C600 (Disk II fallback)
//  - I/O Register Interface ($C0F0-$C0FF):
//      $C0F0: Data port (read/write auto-incrementing 512-byte block buffer)
//      $C0F1: Block number low (0..255)
//      $C0F2: Block number high (0..15)
//      $C0F3: Command (0=reset buffer ptr, 1=read block from SDRAM, 2=write block to SDRAM)
//      $C0F4: Status (bit 7: busy, bit 6: error, bit 5: write protect, bit 2: drv2, bit 1: drv1)
//      $C0F5: Drive select (0=Drive 1, 1=Drive 2)
//  - Bulk UART Upload / Download Port for Serial Debugger (2 MB per drive)
// ============================================================================

`default_nettype none

module prodos_card (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        ce_1m,         // 1.023 MHz clock enable

    // Motherboard bus interface (Slot 7)
    input  wire        devsel_n,      // $C0F0-$C0FF I/O select
    input  wire        iosel_n,       // $C700-$C7FF ROM select
    input  wire        bus_cycle,     // cpu_go
    input  wire        cpu_we,
    input  wire [15:0] addr,          // CPU effective address
    input  wire [7:0]  cpu_di,        // Data from CPU
    output reg  [7:0]  rom_data,      // Byte to slot_bus for $C7xx ROM
    output reg  [7:0]  io_data,       // Byte to CPU read mux for $C0Fx

    // SDRAM port to aux_ram arbiter
    output reg         hd_go,
    output reg  [21:0] hd_addr,
    output reg         hd_we,
    output reg  [15:0] hd_wdata,
    input  wire [15:0] hd_rdata,
    input  wire        hd_ack,
    input  wire        hd_idle,

    // UART bulk transfer port (from serial_debugger.v)
    input  wire        up_go,
    input  wire        up_drive,      // 0 = Drive 1, 1 = Drive 2
    input  wire [20:0] up_addr,       // 0..2097151 (2 MB)
    input  wire [7:0]  up_data,
    input  wire        up_last,
    input  wire        up_bad,
    output reg         up_busy,
    output reg         up_done,
    input  wire        down_go,
    input  wire        down_drive,
    input  wire [20:0] down_addr,     // 0..2097151 (2 MB)
    input  wire        down_last,
    output reg  [7:0]  down_data,
    output reg         down_valid,
    output reg         down_done,
    // Write-back request to the SD loader: level until wr_ack; busy stays set meanwhile
    output reg         wr_req,
    output reg  [11:0] wr_blk,
    input  wire        wr_ack,
    output wire [1:0]  drv_present,
    output wire [1:0]  drv_writable
);

    // -------------------------------------------------------------------------
    // 1. Drive State
    // -------------------------------------------------------------------------
    reg present [0:1];
    reg writable_q [0:1];
    integer di;
    initial begin
        for (di = 0; di < 2; di = di + 1) begin
            present[di]    = 1'b0;
            writable_q[di] = 1'b0;
        end
    end

    assign drv_present[0]  = present[0];
    assign drv_present[1]  = present[1];
    assign drv_writable[0] = present[0] && writable_q[0];
    assign drv_writable[1] = present[1] && writable_q[1];

    // -------------------------------------------------------------------------
    // 2. 256-Byte On-Board ROM ($C700-$C7FF)
    // -------------------------------------------------------------------------
    reg [7:0] rom [0:255];
    initial begin
        // $C700: Boot entry & ProDOS identification signatures
        rom[8'h00] = 8'hA2; rom[8'h01] = 8'h20; // LDX #$20 ($C701 = $20)
        rom[8'h02] = 8'hA0; rom[8'h03] = 8'h00; // LDY #$00 ($C703 = $00)
        rom[8'h04] = 8'hA9; rom[8'h05] = 8'h03; // LDA #$03 ($C705 = $03)

        // Select Drive 1: LDA #$00; STA $C0F5
        rom[8'h06] = 8'hA9; rom[8'h07] = 8'h00;
        rom[8'h08] = 8'h8D; rom[8'h09] = 8'hF5; rom[8'h0A] = 8'hC0;

        // Check Drive 1 present: LDA $C0F4; AND #$02; BNE +3; JMP $C600
        rom[8'h0B] = 8'hAD; rom[8'h0C] = 8'hF4; rom[8'h0D] = 8'hC0;
        rom[8'h0E] = 8'h29; rom[8'h0F] = 8'h02;
        rom[8'h10] = 8'hD0; rom[8'h11] = 8'h03; // BNE .has_disk ($C715)
        rom[8'h12] = 8'h4C; rom[8'h13] = 8'h00; rom[8'h14] = 8'hC6; // JMP $C600 (Disk II fallback)

        // .has_disk ($C715): Block low=0, high=0, Read Command=1
        rom[8'h15] = 8'hA9; rom[8'h16] = 8'h00;
        rom[8'h17] = 8'h8D; rom[8'h18] = 8'hF1; rom[8'h19] = 8'hC0; // STA $C0F1
        rom[8'h1A] = 8'h8D; rom[8'h1B] = 8'hF2; rom[8'h1C] = 8'hC0; // STA $C0F2
        rom[8'h1D] = 8'hA9; rom[8'h1E] = 8'h01;
        rom[8'h1F] = 8'h8D; rom[8'h20] = 8'hF3; rom[8'h21] = 8'hC0; // STA $C0F3 (Read)

        // .boot_wait ($C722): LDA $C0F4; BMI .boot_wait
        rom[8'h22] = 8'hAD; rom[8'h23] = 8'hF4; rom[8'h24] = 8'hC0;
        rom[8'h25] = 8'h30; rom[8'h26] = 8'hFB;

        // Read 512 bytes into $0800..$09FF
        rom[8'h27] = 8'hA2; rom[8'h28] = 8'h00; // LDX #$00
        // .bloop ($C729):
        rom[8'h29] = 8'hAD; rom[8'h2A] = 8'hF0; rom[8'h2B] = 8'hC0; // LDA $C0F0
        rom[8'h2C] = 8'h9D; rom[8'h2D] = 8'h00; rom[8'h2E] = 8'h08; // STA $0800,X
        rom[8'h2F] = 8'hAD; rom[8'h30] = 8'hF0; rom[8'h31] = 8'hC0; // LDA $C0F0
        rom[8'h32] = 8'h9D; rom[8'h33] = 8'h00; rom[8'h34] = 8'h09; // STA $0900,X
        rom[8'h35] = 8'hE8;                                           // INX
        rom[8'h36] = 8'hD0; rom[8'h37] = 8'hF1;                         // BNE .bloop

        // Pass control to boot sector: A=0, X=$70 (Slot 7), Y=0, JMP $0801
        rom[8'h38] = 8'hA9; rom[8'h39] = 8'h00; // LDA #$00
        rom[8'h3A] = 8'hA2; rom[8'h3B] = 8'h70; // LDX #$70
        rom[8'h3C] = 8'hA0; rom[8'h3D] = 8'h00; // LDY #$00
        rom[8'h3E] = 8'h4C; rom[8'h3F] = 8'h01; rom[8'h40] = 8'h08; // JMP $0801
        rom[8'h41] = 8'hEA;                      // NOP padding to $C742

        // $C742: MLI Driver Entry Point
        rom[8'h42] = 8'h08;                      // PHP
        rom[8'h43] = 8'h78;                      // SEI
        rom[8'h44] = 8'hA5; rom[8'h45] = 8'h43; // LDA $43 (Unit number)
        rom[8'h46] = 8'h0A;                      // ASL (Drive bit into C)
        rom[8'h47] = 8'hA9; rom[8'h48] = 8'h00; // LDA #$00
        rom[8'h49] = 8'h2A;                      // ROL
        rom[8'h4A] = 8'h8D; rom[8'h4B] = 8'hF5; rom[8'h4C] = 8'hC0; // STA $C0F5 (Drive select)

        // Check if drive mounted: LDA $C0F4; AND #$02; BEQ .err_nodev ($C77E)
        rom[8'h4D] = 8'hAD; rom[8'h4E] = 8'hF4; rom[8'h4F] = 8'hC0;
        rom[8'h50] = 8'h29; rom[8'h51] = 8'h02;
        rom[8'h52] = 8'hF0; rom[8'h53] = 8'h28; // BEQ .err_nodev

        // Range check block number: LDA $47; CMP #$10; BCS .err_io ($C776)
        rom[8'h54] = 8'hA5; rom[8'h55] = 8'h47;
        rom[8'h56] = 8'hC9; rom[8'h57] = 8'h10;
        rom[8'h58] = 8'hB0; rom[8'h59] = 8'h1A; // BCS .err_io

        // Setup block registers: STA $C0F1, STA $C0F2
        rom[8'h5A] = 8'hA5; rom[8'h5B] = 8'h46;
        rom[8'h5C] = 8'h8D; rom[8'h5D] = 8'hF1; rom[8'h5E] = 8'hC0;
        rom[8'h5F] = 8'hA5; rom[8'h60] = 8'h47;
        rom[8'h61] = 8'h8D; rom[8'h62] = 8'hF2; rom[8'h63] = 8'hC0;

        // Command dispatch: LDA $42
        rom[8'h64] = 8'hA5; rom[8'h65] = 8'h42;
        rom[8'h66] = 8'hF0; rom[8'h67] = 8'h19; // BEQ .status ($C781)
        rom[8'h68] = 8'hC9; rom[8'h69] = 8'h01;
        rom[8'h6A] = 8'hF0; rom[8'h6B] = 8'h1E; // BEQ .read ($C78A)
        rom[8'h6C] = 8'hC9; rom[8'h6D] = 8'h02;
        rom[8'h6E] = 8'hF0; rom[8'h6F] = 8'h3C; // BEQ .write ($C7AC)
        rom[8'h70] = 8'hC9; rom[8'h71] = 8'h03;
        rom[8'h72] = 8'hF0; rom[8'h73] = 8'h13; // BEQ .format ($C787)

        // .err_io ($C776): LDA #$27; BNE .exit_err
        rom[8'h74] = 8'hA9; rom[8'h75] = 8'h27;
        rom[8'h76] = 8'hD0; rom[8'h77] = 8'h06;
        // .err_prot ($C778): LDA #$2B; BNE .exit_err
        rom[8'h78] = 8'hA9; rom[8'h79] = 8'h2B;
        rom[8'h7A] = 8'hD0; rom[8'h7B] = 8'h02;
        // .err_nodev ($C77C): LDA #$28
        rom[8'h7C] = 8'hA9; rom[8'h7D] = 8'h28;
        // .exit_err ($C77E): PLP; SEC; RTS
        rom[8'h7E] = 8'h28; rom[8'h7F] = 8'h38; rom[8'h80] = 8'h60;

        // .status ($C781): LDX #$00; LDY #$10 (4,096 blocks = 2MB); BNE .exit_ok
        rom[8'h81] = 8'hA2; rom[8'h82] = 8'h00;
        rom[8'h83] = 8'hA0; rom[8'h84] = 8'h10;
        rom[8'h85] = 8'hD0; rom[8'h86] = 8'h51; // BNE .exit_ok ($C7D8)

        // .format ($C787): CLC; BCC .exit_ok
        rom[8'h87] = 8'h18; rom[8'h88] = 8'h90; rom[8'h89] = 8'h4E;

        // .read ($C78A): Trigger SDRAM block read
        rom[8'h8A] = 8'hA9; rom[8'h8B] = 8'h01;
        rom[8'h8C] = 8'h8D; rom[8'h8D] = 8'hF3; rom[8'h8E] = 8'hC0; // STA $C0F3 (Read)
        // .wait_rd ($C78F): LDA $C0F4; BMI .wait_rd
        rom[8'h8F] = 8'hAD; rom[8'h90] = 8'hF4; rom[8'h91] = 8'hC0;
        rom[8'h92] = 8'h30; rom[8'h93] = 8'hFC;
        // Copy 512 bytes from $C0F0 into ($44),Y
        rom[8'h94] = 8'hA0; rom[8'h95] = 8'h00; // LDY #$00
        // .rloop1 ($C796):
        rom[8'h96] = 8'hAD; rom[8'h97] = 8'hF0; rom[8'h98] = 8'hC0; // LDA $C0F0
        rom[8'h99] = 8'h91; rom[8'h9A] = 8'h44;                      // STA ($44),Y
        rom[8'h9B] = 8'hC8;                                           // INY
        rom[8'h9C] = 8'hD0; rom[8'h9D] = 8'hF7;                         // BNE .rloop1
        rom[8'h9E] = 8'hE6; rom[8'h9F] = 8'h45;                      // INC $45 (page 2)
        // .rloop2 ($C7A0):
        rom[8'hA0] = 8'hAD; rom[8'hA1] = 8'hF0; rom[8'hA2] = 8'hC0; // LDA $C0F0
        rom[8'hA3] = 8'h91; rom[8'hA4] = 8'h44;                      // STA ($44),Y
        rom[8'hA5] = 8'hC8;                                           // INY
        rom[8'hA6] = 8'hD0; rom[8'hA7] = 8'hF7;                         // BNE .rloop2
        rom[8'hA8] = 8'hC6; rom[8'hA9] = 8'h45;                      // DEC $45 (restore)
        rom[8'hAA] = 8'hD0; rom[8'hAB] = 8'h2C;                      // BNE .exit_ok ($C7D8)

        // .write ($C7AC): Check write protection
        rom[8'hAC] = 8'hAD; rom[8'hAD] = 8'hF4; rom[8'hAE] = 8'hC0; // LDA $C0F4
        rom[8'hAF] = 8'h29; rom[8'hB0] = 8'h20;                      // AND #$20
        rom[8'hB1] = 8'hD0; rom[8'hB2] = 8'hC5;                      // BNE .err_prot ($C778)
        // Reset buffer ptr: STA $C0F3
        rom[8'hB3] = 8'hA9; rom[8'hB4] = 8'h00;
        rom[8'hB5] = 8'h8D; rom[8'hB6] = 8'hF3; rom[8'hB7] = 8'hC0;
        // Copy 512 bytes from ($44),Y into $C0F0
        rom[8'hB8] = 8'hA0; rom[8'hB9] = 8'h00;                      // LDY #$00
        // .wloop1 ($C7BA):
        rom[8'hBA] = 8'hB1; rom[8'hBB] = 8'h44;                      // LDA ($44),Y
        rom[8'hBC] = 8'h8D; rom[8'hBD] = 8'hF0; rom[8'hBE] = 8'hC0; // STA $C0F0
        rom[8'hBF] = 8'hC8;                                           // INY
        rom[8'hC0] = 8'hD0; rom[8'hC1] = 8'hF7;                         // BNE .wloop1
        rom[8'hC2] = 8'hE6; rom[8'hC3] = 8'h45;                      // INC $45
        // .wloop2 ($C7C4):
        rom[8'hC4] = 8'hB1; rom[8'hC5] = 8'h44;                      // LDA ($44),Y
        rom[8'hC6] = 8'h8D; rom[8'hC7] = 8'hF0; rom[8'hC8] = 8'hC0; // STA $C0F0
        rom[8'hC9] = 8'hC8;                                           // INY
        rom[8'hCA] = 8'hD0; rom[8'hCB] = 8'hF7;                         // BNE .wloop2
        rom[8'hCC] = 8'hC6; rom[8'hCD] = 8'h45;                      // DEC $45 (restore)
        // Trigger SDRAM block write: STA $C0F3 (Write = 2)
        rom[8'hCE] = 8'hA9; rom[8'hCF] = 8'h02;
        rom[8'hD0] = 8'h8D; rom[8'hD1] = 8'hF3; rom[8'hD2] = 8'hC0;
        // .wait_wr ($C7D3): LDA $C0F4; BMI .wait_wr
        rom[8'hD3] = 8'hAD; rom[8'hD4] = 8'hF4; rom[8'hD5] = 8'hC0;
        rom[8'hD6] = 8'h30; rom[8'hD7] = 8'hFC;

        // .exit_ok ($C7D8): PLP; LDA #$00; CLC; RTS
        rom[8'hD8] = 8'h28;
        rom[8'hD9] = 8'hA9; rom[8'hDA] = 8'h00;
        rom[8'hDB] = 8'h18;
        rom[8'hDC] = 8'h60;

        // Unused padding bytes ($C7DD..$C7FE)
        for (di = 8'hDD; di < 8'hFF; di = di + 1) begin
            rom[di] = 8'h00;
        end

        // $C7FF: ProDOS Device Status Byte
        // Bit 7: 0 = non-removable (fixed hard disk)
        // Bits 6..4: 001 = 2 logical volumes
        // Bits 3..0: 0000
        rom[8'hFF] = 8'h10;
    end

    // ROM Read output for $C700-$C7FF (clocked, matching disk2_card)
    reg [7:0] rom_dout = 8'h00;
    always @(posedge clk) begin
        if (!iosel_n)
            rom_dout <= rom[addr[7:0]];
    end
    assign rom_data = !iosel_n ? rom_dout : 8'h00;

    // -------------------------------------------------------------------------
    // 3. I/O Registers ($C0F0-$C0FF)
    // -------------------------------------------------------------------------
    reg [8:0]  buf_ptr = 9'd0;
    reg [11:0] blk_num = 12'd0;
    reg        drv_sel = 1'b0;      // 0 = Drive 1, 1 = Drive 2
    reg        blk_busy = 1'b0;

    // Block FSM signals
    reg        blk_fsm_start_rd = 1'b0;
    reg        blk_fsm_start_wr = 1'b0;

    wire io_hit = bus_cycle && !devsel_n && (addr[15:8] == 8'hC0) && (addr[7:4] == 4'hF);

    // -------------------------------------------------------------------------
    // 4. 512-Byte Block Buffer (Synthesizes to single Gowin BSRAM block)
    // -------------------------------------------------------------------------
    reg [8:0]  fsm_buf_addr = 9'd0;
    reg [7:0]  fsm_buf_din  = 8'd0;
    reg        fsm_buf_we   = 1'b0;
    reg [7:0]  fsm_data_hold = 8'd0;

    wire [8:0] buf_ram_addr = blk_busy ? fsm_buf_addr : buf_ptr;
    wire [7:0] buf_ram_din  = blk_busy ? fsm_buf_din  : cpu_di;
    wire       buf_ram_we   = blk_busy ? fsm_buf_we   : (io_hit && cpu_we && (addr[3:0] == 4'h0));
    wire [7:0] buf_ram_dout;

    prodos_blk_buf u_blk_buf (
        .clk(clk),
        .addr(buf_ram_addr),
        .din(buf_ram_din),
        .we(buf_ram_we),
        .dout(buf_ram_dout)
    );

    // Read Multiplexer for $C0Fx
    always @(*) begin
        case (addr[3:0])
            4'h0: io_data = buf_ram_dout;
            4'h1: io_data = blk_num[7:0];
            4'h2: io_data = {4'd0, blk_num[11:8]};
            4'h3: io_data = 8'h00;
            4'h4: io_data = {blk_busy, 1'b0, ~drv_writable[drv_sel], 2'b00,
                             drv_present[1], drv_present[0], 1'b0};
            4'h5: io_data = {7'd0, drv_sel};
            default: io_data = 8'h00;
        endcase
    end

    // -------------------------------------------------------------------------
    // 5. Block SDRAM Transfer FSM (256 Words = 512 Bytes)
    // -------------------------------------------------------------------------
    localparam BF_IDLE  = 3'd0;
    localparam BF_RD_HI = 3'd1;
    localparam BF_RD_LO = 3'd2;
    localparam BF_REQ   = 3'd3;
    localparam BF_WAIT  = 3'd4;
    localparam BF_WR_LO = 3'd5;

    reg [2:0]  bf_state = BF_IDLE;
    reg        bf_is_wr = 1'b0;
    reg [7:0]  bf_widx  = 8'd0;

    // -------------------------------------------------------------------------
    // 6. Bulk UART Upload / Download State (serial_debugger)
    // -------------------------------------------------------------------------
    reg [7:0]  up_hold = 8'h00;
    reg        up_have = 1'b0;

    reg [15:0] dn_cache = 16'd0;
    reg [20:0] dn_cache_addr = 21'd0;
    reg        dn_cache_valid = 1'b0;

    localparam BK_IDLE = 2'd0;
    localparam BK_UP   = 2'd1;
    localparam BK_DN   = 2'd2;
    reg [1:0]  bk_state = BK_IDLE;

    // -------------------------------------------------------------------------
    // 7. Main Sequential Engine
    // -------------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            buf_ptr          <= 9'd0;
            blk_num          <= 12'd0;
            drv_sel          <= 1'b0;
            blk_busy         <= 1'b0;
            blk_fsm_start_rd <= 1'b0;
            blk_fsm_start_wr <= 1'b0;
            wr_req           <= 1'b0;
            wr_blk           <= 12'd0;
            bf_state         <= BF_IDLE;
            bf_is_wr         <= 1'b0;
            bf_widx          <= 8'd0;
            fsm_buf_addr     <= 9'd0;
            fsm_buf_din      <= 8'd0;
            fsm_buf_we       <= 1'b0;
            fsm_data_hold    <= 8'd0;
            hd_go            <= 1'b0;
            hd_addr          <= 22'd0;
            hd_we            <= 1'b0;
            hd_wdata         <= 16'd0;
            up_busy          <= 1'b0;
            up_done          <= 1'b0;
            up_have          <= 1'b0;
            up_hold          <= 8'd0;
            down_valid       <= 1'b0;
            down_done        <= 1'b0;
            dn_cache_valid   <= 1'b0;
            bk_state         <= BK_IDLE;
            present[0]       <= 1'b0;
            present[1]       <= 1'b0;
            writable_q[0]    <= 1'b0;
            writable_q[1]    <= 1'b0;
        end else begin
            // Pulses default low
            if (wr_ack) begin wr_req <= 1'b0; blk_busy <= 1'b0; end
            hd_go            <= 1'b0;
            up_done          <= 1'b0;
            down_valid       <= 1'b0;
            down_done        <= 1'b0;
            blk_fsm_start_rd <= 1'b0;
            blk_fsm_start_wr <= 1'b0;
            fsm_buf_we       <= 1'b0;

            // -----------------------------------------------------------------
            // Host bulk upload/download status tracking
            // -----------------------------------------------------------------
            if (up_bad) begin
                present[up_drive]    <= 1'b0;
                writable_q[up_drive] <= 1'b0;
                up_have              <= 1'b0;
            end

            // -----------------------------------------------------------------
            // CPU I/O Register Access ($C0F0-$C0FF)
            // -----------------------------------------------------------------
            if (io_hit) begin
                if (!cpu_we) begin
                    // Read access
                    if (addr[3:0] == 4'h0) begin
                        buf_ptr <= buf_ptr + 1'b1;
                    end
                end else begin
                    // Write access
                    case (addr[3:0])
                        4'h0: begin
                            buf_ptr <= buf_ptr + 1'b1;
                        end
                        4'h1: blk_num[7:0]  <= cpu_di;
                        4'h2: blk_num[11:8] <= cpu_di[3:0];
                        4'h3: begin
                            buf_ptr <= 9'd0;
                            if (cpu_di == 8'd1) begin
                                blk_busy         <= 1'b1;
                                blk_fsm_start_rd <= 1'b1;
                            end else if (cpu_di == 8'd2) begin
                                blk_busy         <= 1'b1;
                                blk_fsm_start_wr <= 1'b1;
                            end
                        end
                        4'h5: drv_sel <= cpu_di[0];
                        default: ;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Block SDRAM Transfer FSM (Serving ProDOS MLI driver)
            // -----------------------------------------------------------------
            case (bf_state)
                BF_IDLE: begin
                    if (blk_fsm_start_rd) begin
                        bf_state <= BF_REQ;
                        bf_is_wr <= 1'b0;
                        bf_widx  <= 8'd0;
                    end else if (blk_fsm_start_wr) begin
                        bf_state     <= BF_RD_HI;
                        bf_is_wr     <= 1'b1;
                        bf_widx      <= 8'd0;
                        fsm_buf_addr <= {8'd0, 1'b0};
                    end
                end

                BF_RD_HI: begin
                    hd_wdata[15:8] <= buf_ram_dout;
                    fsm_buf_addr   <= {bf_widx, 1'b1};
                    bf_state       <= BF_RD_LO;
                end

                BF_RD_LO: begin
                    hd_wdata[7:0] <= buf_ram_dout;
                    hd_go         <= 1'b1;
                    hd_we         <= 1'b1;
                    hd_addr       <= {drv_sel ? 2'b11 : 2'b10, blk_num[11:0], bf_widx};
                    bf_state      <= BF_WAIT;
                end

                BF_REQ: begin
                    hd_go    <= 1'b1;
                    hd_we    <= 1'b0;
                    hd_addr  <= {drv_sel ? 2'b11 : 2'b10, blk_num[11:0], bf_widx};
                    bf_state <= BF_WAIT;
                end

                BF_WAIT: begin
                    if (hd_ack) begin
                        if (!bf_is_wr) begin
                            fsm_buf_we    <= 1'b1;
                            fsm_buf_addr  <= {bf_widx, 1'b0};
                            fsm_buf_din   <= hd_rdata[15:8];
                            fsm_data_hold <= hd_rdata[7:0];
                            bf_state      <= BF_WR_LO;
                        end else begin
                            if (bf_widx == 8'd255) begin
                                bf_state <= BF_IDLE;
                                if (!drv_sel) begin   // drive 1 is backed by the SD card
                                    wr_req <= 1'b1;
                                    wr_blk <= blk_num;
                                end else blk_busy <= 1'b0;
                            end else begin
                                bf_widx      <= bf_widx + 1'b1;
                                fsm_buf_addr <= {bf_widx + 1'b1, 1'b0};
                                bf_state     <= BF_RD_HI;
                            end
                        end
                    end
                end

                BF_WR_LO: begin
                    fsm_buf_we   <= 1'b1;
                    fsm_buf_addr <= {bf_widx, 1'b1};
                    fsm_buf_din  <= fsm_data_hold;
                    if (bf_widx == 8'd255) begin
                        blk_busy <= 1'b0;
                        bf_state <= BF_IDLE;
                    end else begin
                        bf_widx  <= bf_widx + 1'b1;
                        bf_state <= BF_REQ;
                    end
                end
            endcase

            // -----------------------------------------------------------------
            // Bulk UART Image Transfers (Serving Serial Debugger when CPU paused)
            // -----------------------------------------------------------------
            case (bk_state)
                BK_IDLE: begin
                    if (up_go && !up_busy && (bf_state == BF_IDLE)) begin
                        up_done <= 1'b1;
                        if (up_last) begin
                            present[up_drive]    <= 1'b1;
                            writable_q[up_drive] <= 1'b1;
                        end
                        if (up_have) begin
                            // Second byte arrived: write word to SDRAM
                            hd_we    <= 1'b1;
                            hd_wdata <= {up_hold, up_data};
                            hd_addr  <= {up_drive ? 2'b11 : 2'b10, up_addr[20:1]};
                            hd_go    <= 1'b1;
                            up_busy  <= 1'b1;
                            up_have  <= 1'b0;
                            bk_state <= BK_UP;
                        end else begin
                            // First byte: hold it
                            up_hold <= up_data;
                            up_have <= 1'b1;
                        end
                    end else if (down_go && (bf_state == BF_IDLE)) begin
                        // Check if the requested word is in our 1-word download cache
                        if (dn_cache_valid && (dn_cache_addr == {down_drive, down_addr[20:1]})) begin
                            down_data  <= down_addr[0] ? dn_cache[7:0] : dn_cache[15:8];
                            down_valid <= 1'b1;
                            if (down_last) down_done <= 1'b1;
                        end else begin
                            // Cache miss: issue SDRAM read
                            hd_we    <= 1'b0;
                            hd_addr  <= {down_drive ? 2'b11 : 2'b10, down_addr[20:1]};
                            hd_go    <= 1'b1;
                            bk_state <= BK_DN;
                        end
                    end
                end

                BK_UP: begin
                    if (hd_ack) begin
                        up_busy  <= 1'b0;
                        bk_state <= BK_IDLE;
                    end
                end

                BK_DN: begin
                    if (hd_ack) begin
                        dn_cache       <= hd_rdata;
                        dn_cache_addr  <= {down_drive, down_addr[20:1]};
                        dn_cache_valid <= 1'b1;
                        down_data      <= down_addr[0] ? hd_rdata[7:0] : hd_rdata[15:8];
                        down_valid     <= 1'b1;
                        if (down_last) down_done <= 1'b1;
                        bk_state       <= BK_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

module prodos_blk_buf (
    input  wire        clk,
    input  wire [8:0]  addr,
    input  wire [7:0]  din,
    input  wire        we,
    output reg  [7:0]  dout
);
    reg [7:0] mem [0:511];

    always @(posedge clk) begin
        if (we)
            mem[addr] <= din;
        dout <= mem[addr];
    end
endmodule

`default_nettype wire
