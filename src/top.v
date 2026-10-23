// Apple //e Computer on Tang Primer 20K FPGA (GW2A-LV18PG256C8/I7, Dock)
// Top-Level Module integrating CPU, Memory, Video/HDMI, I2S Audio, and UART/HID/Gamepad Inputs

`include "src/hdmi/hdmi_defs.vh"

module top (
    input  wire       clk,        // 27.0 MHz SOM oscillator (H11)
    input  wire       key_s1_n,   // Dock button S0 (T10, active low; also FPGA_RST): Apple reset
    input  wire       key_s2_n,   // Dock button S1 (T3, active low, 1.5 V bank): HDMI test pattern
    input  wire       sw_color_tv,// DIP1 (C7, 1.5 V bank): Colour TV mode (1 = ON, 0 = OFF)
    input  wire [1:0] sw_scanline,// DIP2 (E9), DIP3 (E8, 1.5 V bank): scanlines (00=off, 01=25%, 10=50%, 11=75%)

    // Dock LEDs 0-5 (C13 A13 N16 N14 L14 L16, active low)
    output wire [5:0] led,

    // UART console via the BL702 USB-C debugger
    input  wire       uart_rx,    // T13
    output wire       uart_tx,    // M11

    // TF card on the SOM (J2), SPI mode: the slot 7 hard disk's volumes (src/sd_vol.v)
    output wire       sd_clk,     // N10 SDIO_CLK
    output wire       sd_mosi,    // R14 SDIO_CMD
    input  wire       sd_miso,    // M8  SDIO_D0
    output wire       sd_cs_n,    // N11 SDIO_D3

    // HDMI TMDS output (J3); the tools place each _n leg from the pair
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,

    // PT8211 DAC -> LPA4809 amplifier -> 3.5 mm jack
    output wire       i2s_bclk,   // N15 HP_BCK
    output wire       i2s_lrck,   // P16 HP_WS
    output wire       i2s_din,    // P15 HP_DIN
    output wire       pa_en,      // R16 PA_EN

    // DDR3 on the SOM (H5TQ1G63EFR, 128 MB x16): the aux 64 KB and the Disk ][ images
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    inout  wire [1:0]  DDR3_DQS_n,
    output wire [13:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nCS,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_CK,
    output wire        DDR3_CK_n,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire        DDR3_ODT,
    output wire [1:0]  DDR3_DM
);

    // Clock Generator
    wire clk_tmds;
    wire clk_pixel;
    wire pll_locked;
    wire ce_1m;

    clk_gen u_clk_gen (
        .clk_in(clk),
        .rst_in(1'b0),
        .clk_tmds(clk_tmds),
        .clk_pixel(clk_pixel),
        .pll_locked(pll_locked),
        .ce_1m(ce_1m)
    );

    // Both keys are active low (10k pull-ups), synchronised into their
    // respective clock domains.
    reg [1:0] s1_sync = 2'b11;
    always @(posedge clk) s1_sync <= {s1_sync[0], key_s1_n};
    wire btn_reset = ~s1_sync[1];    // press: Apple reset

    reg [1:0] s2_sync = 2'b11;
    always @(posedge clk_pixel) s2_sync <= {s2_sync[0], key_s2_n};
    wire btn_test = ~s2_sync[1];     // hold: HDMI colour bars + 1 kHz tone


    // Power-on and Button Reset Generator (S1 key triggers reset while pressed)
    reg [19:0] rst_cnt = 20'd0;

    always @(posedge clk) begin
        if (btn_reset)
            rst_cnt <= 20'd0;
        else if (rst_cnt != 20'hFFFFF)
            rst_cnt <= rst_cnt + 1'b1;
    end

    wire sys_reset_raw = (rst_cnt != 20'hFFFFF);

    // Reset synchronizer for the Apple system domain (clk_pixel): asynchronous
    // assertion so reset takes effect immediately, synchronous deassertion to
    // eliminate reset removal violations across clk_pixel registers.
    reg [1:0] sys_rst_sync = 2'b11;
    always @(posedge clk_pixel or posedge sys_reset_raw) begin
        if (sys_reset_raw)
            sys_rst_sync <= 2'b11;
        else
            sys_rst_sync <= {sys_rst_sync[0], 1'b0};
    end
    wire sys_reset = sys_rst_sync[1];

    // Serial Debugger & Apple //e Console Mirror
    wire [7:0]  rx_byte;
    wire        rx_valid;
    wire        dbg_mode;
    wire        cpu_rdy;
    wire [15:0] dbg_mem_addr;
    wire [7:0]  dbg_mem_din;
    wire        dbg_mem_ready;

    // The image store's byte ports (inside the core), from sd_vol only: every
    // drive's disk is a file on the TF card, loaded and written back by it.
    wire        img_up_go, img_up_drive, img_up_last, img_up_ro, img_up_bad, img_up_busy, img_up_done;
    wire [19:0] img_up_addr;
    wire [7:0]  img_up_data;
    wire        img_dn_go, img_dn_drive, img_dn_valid;
    wire [19:0] img_dn_addr;
    wire [7:0]  img_dn_data;
    wire        fl_wr, fl_wr_drv;
    wire [10:0] fl_wr_blk;

    // The slot 7 hard disk's DDR3 port (aux_ram hd_*), shared by the card in
    // the core and the TF card loader (src/sd_vol.v).  They never ask at once:
    // sd_vol moves bytes only while the driver sits in its wait for a block
    // to come from or go back to the card, and aux_ram, which latches a request
    // on its go pulse, takes whichever pulsed.
    wire [3:0]  sd_present, sd_fail;
    wire [1:0]  hd_present = sd_present[3:2];
    wire        hd_sd_busy, hd_loading, sd_err, sd_fs_ok;
    wire [15:0] hd_rdata;
    wire        core_hd_go, core_hd_we, sd_m_go, sd_m_we;
    wire [1:0]  core_hd_be;
    wire [24:0] core_hd_addr, sd_m_addr;
    wire [15:0] core_hd_wdata, sd_m_wdata;
    wire        hd_wb_go, hd_wb_drv, sd_mnt_go, hd_rb_go, hd_rb_ok;
    wire [15:0] hd_size0, hd_size1;
    wire [1:0]  sd_mnt_drv;
    wire [15:0] hd_wb_blk;
    wire [2:0]  sd_estage;
    wire        sd_x_go, sd_x_zero, sd_x_valid, sd_x_take;
    wire [31:0] sd_x_lba, sd_r_lba;
    wire [7:0]  sd_x_byte, sd_r_byte;
    wire        sd_r_go, sd_r_valid, sd_r_take, sd_r_done, sd_r_ok;
    wire [15:0] sd_r_cnt;

    // Asserted by the debugger's "x" (CPU reset) command; consumed by the core
    wire        cpu_reset_req;

    // DDR3 PLL lock and aux_ram ready (DDR3 calibrated + self-tested); declared
    // here because the debugger reports them (this iverilog rejects use before declaration)
    wire        ddr_lock, aux_ready;
    wire [31:0] ddr_diag;

    wire [15:0] debug_cpu_pc;
    wire [7:0]  debug_dsk_head;
    wire [15:0] debug_cpu_addr;
    wire [7:0]  debug_cpu_dout;
    wire        debug_cpu_we;
    wire        debug_cpu_sync;
    wire [7:0]  debug_cpu_a;
    wire [7:0]  debug_cpu_x;
    wire [7:0]  debug_cpu_y;
    wire [7:0]  debug_cpu_s;
    wire [7:0]  debug_cpu_p;
    wire [7:0]  debug_cpu_ir;

    // Softswitch state wires
    wire        spkr_pulse;
    wire signed [15:0] mock_left;
    wire signed [15:0] mock_right;
    wire        text_mode;
    wire        mixed_mode;
    wire        page2;
    wire        hires_mode;
    wire        col80;
    wire        altchar;
    wire        dhires;
    wire        store80;
    wire        vbl;

    // The Super Serial Card's line (slot 1, src/ssc.v): the page's modem, in
    // and out over the USB link
    wire [7:0] ssc_rx_data, ssc_tx_byte, ssc_st_byte;
    wire       ssc_rx_valid, ssc_tx_req, ssc_tx_ack, ssc_st_req, ssc_st_ack;
    wire [1:0] ssc_lines;

    serial_debugger u_debugger (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .uart_tx(uart_tx),
        .rx_byte(rx_byte),
        .rx_valid(rx_valid),
        .ssc_tx_req(ssc_tx_req), .ssc_tx_byte(ssc_tx_byte), .ssc_tx_ack(ssc_tx_ack),
        .ssc_st_req(ssc_st_req), .ssc_st_byte(ssc_st_byte), .ssc_st_ack(ssc_st_ack),
        .dbg_mode(dbg_mode),
        .cpu_rdy(cpu_rdy),
        .cpu_reset_req(cpu_reset_req),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .dbg_mem_ready(dbg_mem_ready),
        .sd_mnt_go(sd_mnt_go),
        .sd_mnt_drv(sd_mnt_drv),
        .sd_stat({hd_loading, hd_sd_busy, sd_err, sd_estage, sd_fs_ok, 1'b0, sd_fail, sd_present}),
        .sd_x_go(sd_x_go), .sd_x_lba(sd_x_lba), .sd_x_zero(sd_x_zero),
        .sd_x_byte(sd_x_byte), .sd_x_valid(sd_x_valid), .sd_x_take(sd_x_take),
        .sd_r_go(sd_r_go), .sd_r_lba(sd_r_lba), .sd_r_cnt(sd_r_cnt), .sd_r_byte(sd_r_byte),
        .sd_r_valid(sd_r_valid), .sd_r_take(sd_r_take), .sd_r_done(sd_r_done), .sd_r_ok(sd_r_ok),
        .cpu_pc(debug_cpu_pc),
        .dsk_head(debug_dsk_head),
        .cpu_a(debug_cpu_a),
        .cpu_x(debug_cpu_x),
        .cpu_y(debug_cpu_y),
        .cpu_s(debug_cpu_s),
        .cpu_p(debug_cpu_p),
        .cpu_ir(debug_cpu_ir),
        .cpu_addr(debug_cpu_addr),
        .cpu_sync(debug_cpu_sync),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .pll_locked(pll_locked & ddr_lock & aux_ready),  // "PLL:1" in `t`: both PLLs and DDR3 up
        .ddr_diag(ddr_diag)
    );

    // Input Controller (UART RX, Keyboard & Gamepad)
    wire [7:0] io_addr;
    wire       io_read;
    wire       io_write;
    wire [7:0] input_dout;
    wire       input_hit;
    wire       key_strobe;
    wire       kbd_reset;
    wire        clk_set;           // slot 5 clock, set by the host (FF 05)
    wire [51:0] clk_time;

    input_controller u_input (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .uart_rx(uart_rx),
        .dbg_mode(dbg_mode),
        .rx_byte(rx_byte),
        .rx_valid(rx_valid),
        .io_addr(io_addr),
        .io_read(io_read),
        .io_write(io_write),
        .io_dout(input_dout),
        .io_hit(input_hit),
        .key_strobe(key_strobe),
        .kbd_reset(kbd_reset),
        .clk_set(clk_set),
        .clk_time(clk_time),
        .ssc_rx_data(ssc_rx_data), .ssc_rx_valid(ssc_rx_valid), .ssc_lines(ssc_lines)
    );

    // Apple //e Core (CPU, Memory, Softswitches)
    wire        vram_req;
    wire [15:0] vram_addr;
    wire [7:0]  vram_data;
    wire [11:0] char_rom_addr;
    wire [7:0]  char_rom_data;

    // DDR3 memory clock: a second rPLL, 27 MHz * 59/4 = 398.25 MHz (Sipeed's
    // Tang Primer 20K DDR3 example; the Gowin IP was generated for 400 MHz).
    // The IP divides it by 4 for its own user clock.  Unrelated in phase to
    // clk_pixel; aux_ram does the crossing.
    wire ddr_memory_clk;
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2A-18C"),
        .IDIV_SEL(3), .FBDIV_SEL(58), .ODIV_SEL(2),
        .CLKFB_SEL("internal"),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .DYN_DA_EN("false")
    ) u_ddr_pll (
        .CLKIN(clk), .CLKOUT(ddr_memory_clk), .CLKOUTP(), .CLKOUTD(),
        .CLKOUTD3(), .LOCK(ddr_lock),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    // Aux RAM (DDR3) between the core, the video line buffer and the pins,
    // and the arbiter for the Disk ][ image store, which shares the same
    // controller at the lowest priority.
    wire        aux_rd_want, aux_rd_hit, aux_wr_go, aux_wr_busy;
    wire [16:0] aux_rd_addr, aux_wr_addr;
    wire [7:0]  aux_rd_data, aux_wr_data, aux_line_data;
    wire        aux_fill_start;
    wire [15:0] aux_fill_addr;
    wire [5:0]  aux_col;

    // The Disk ][ store's SDRAM port, from the core's copy of the store.
    wire        dsk_store_go, dsk_store_we, dsk_store_ack, dsk_store_idle;
    wire [21:0] dsk_store_addr;
    wire [15:0] dsk_store_wdata, dsk_store_rdata;

    // aux_ram's hd port holds one request.  The slot 7 card and sd_vol each
    // keep at most one out and wait for its ack, but both can be out at once
    // (a floppy flush or a mount while the CPU streams a block), and then a
    // second go overwrote the first and both took the one ack.  Each client's
    // request waits here; one goes at a time and the ack goes to its owner.
    reg         hq_c = 1'b0, hq_s = 1'b0;     // a request waiting, per client
    reg  [24:0] hq_c_addr;  reg hq_c_we;  reg [1:0] hq_c_be;  reg [15:0] hq_c_wdata;
    reg  [24:0] hq_s_addr;  reg hq_s_we;  reg [15:0] hq_s_wdata;
    reg         hd_out = 1'b0, hd_own_s = 1'b0;   // one in aux_ram, and whose
    reg         hd_m_go = 1'b0, hd_m_we = 1'b0;
    reg  [24:0] hd_m_addr = 25'd0;
    reg  [1:0]  hd_m_be = 2'b11;
    reg  [15:0] hd_m_wdata = 16'd0;
    wire        hd_m_ack;
    always @(posedge clk_pixel) begin
        hd_m_go <= 1'b0;
        if (core_hd_go) begin
            hq_c <= 1'b1; hq_c_addr <= core_hd_addr; hq_c_we <= core_hd_we;
            hq_c_be <= core_hd_be; hq_c_wdata <= core_hd_wdata;
        end
        if (sd_m_go) begin
            hq_s <= 1'b1; hq_s_addr <= sd_m_addr; hq_s_we <= sd_m_we; hq_s_wdata <= sd_m_wdata;
        end
        // aux_ram drops a waiting request on reset and never acks it
        if (hd_m_ack || sys_reset) hd_out <= 1'b0;
        if (sys_reset) begin
            hq_c <= 1'b0; hq_s <= 1'b0;
        end else if (!hd_out && !hd_m_go && !hd_m_ack) begin
            if (hq_s) begin
                hq_s <= 1'b0; hd_out <= 1'b1; hd_own_s <= 1'b1; hd_m_go <= 1'b1;
                hd_m_addr <= hq_s_addr; hd_m_we <= hq_s_we; hd_m_be <= 2'b11; hd_m_wdata <= hq_s_wdata;
            end else if (hq_c) begin
                hq_c <= 1'b0; hd_out <= 1'b1; hd_own_s <= 1'b0; hd_m_go <= 1'b1;
                hd_m_addr <= hq_c_addr; hd_m_we <= hq_c_we; hd_m_be <= hq_c_be; hd_m_wdata <= hq_c_wdata;
            end
        end
    end

    aux_ram u_aux (
        .clk(clk_pixel), .reset(sys_reset),
        .ddr_clk(clk),
        .fill_start(aux_fill_start), .fill_addr(aux_fill_addr), .col(aux_col),
        .line_data(aux_line_data),
        .rd_want(aux_rd_want), .rd_addr(aux_rd_addr), .rd_data(aux_rd_data), .rd_hit(aux_rd_hit),
        .wr_go(aux_wr_go), .wr_addr(aux_wr_addr), .wr_data(aux_wr_data), .wr_busy(aux_wr_busy),
        .dsk_go(dsk_store_go), .dsk_addr(dsk_store_addr), .dsk_we(dsk_store_we),
        .dsk_wdata(dsk_store_wdata), .dsk_rdata(dsk_store_rdata),
        .dsk_ack(dsk_store_ack), .dsk_idle(dsk_store_idle),
        .hd_go(hd_m_go), .hd_addr(hd_m_addr), .hd_we(hd_m_we),
        .hd_be(hd_m_be), .hd_wdata(hd_m_wdata),
        .hd_rdata(hd_rdata), .hd_ack(hd_m_ack),
        .ready(aux_ready), .diag(ddr_diag),
        .ddr_memory_clk(ddr_memory_clk), .ddr_lock(ddr_lock),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_n(DDR3_DQS_n),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS), .DDR3_nWE(DDR3_nWE),
        .DDR3_CK(DDR3_CK), .DDR3_CK_n(DDR3_CK_n), .DDR3_CKE(DDR3_CKE), .DDR3_nRESET(DDR3_nRESET),
        .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    // The drives' images: files on the TF card (FAT32, A2CONFIG.TXT)
    sd_vol u_sd_vol (
        .clk(clk_pixel), .reset(sys_reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .ddr_ready(aux_ready),
        .m_go(sd_m_go), .m_addr(sd_m_addr), .m_we(sd_m_we), .m_wdata(sd_m_wdata),
        .m_rdata(hd_rdata), .m_ack(hd_m_ack && hd_own_s),
        .f_up_go(img_up_go), .f_up_drive(img_up_drive), .f_up_addr(img_up_addr), .f_up_data(img_up_data),
        .f_up_last(img_up_last), .f_up_ro(img_up_ro), .f_up_bad(img_up_bad), .f_up_busy(img_up_busy), .f_up_done(img_up_done),
        .f_dn_go(img_dn_go), .f_dn_drive(img_dn_drive), .f_dn_addr(img_dn_addr),
        .f_dn_data(img_dn_data), .f_dn_valid(img_dn_valid),
        .fl_wr(fl_wr), .fl_wr_drv(fl_wr_drv), .fl_wr_blk(fl_wr_blk),
        .bg_hold(dbg_mode),
        .present(sd_present), .fail(sd_fail), .fs_ok(sd_fs_ok),
        .loading(hd_loading), .busy(hd_sd_busy), .err(sd_err), .estage(sd_estage),
        .wb_go(hd_wb_go), .wb_drv(hd_wb_drv), .wb_blk(hd_wb_blk),
        .rb_go(hd_rb_go), .rb_ok(hd_rb_ok), .hd_size0(hd_size0), .hd_size1(hd_size1),
        .mnt_go(sd_mnt_go), .mnt_drv(sd_mnt_drv),
        .x_go(sd_x_go), .x_lba(sd_x_lba), .x_zero(sd_x_zero),
        .x_byte(sd_x_byte), .x_valid(sd_x_valid), .x_take(sd_x_take),
        .r_go(sd_r_go), .r_lba(sd_r_lba), .r_cnt(sd_r_cnt), .r_byte(sd_r_byte), .r_valid(sd_r_valid),
        .r_take(sd_r_take), .r_done(sd_r_done), .r_ok(sd_r_ok)
    );

    apple2_core u_core (
        .clk(clk_pixel),
        .reset(sys_reset | cpu_reset_req | kbd_reset),
        .ce_1m(ce_1m),
        .input_dout(input_dout),
        .input_hit(input_hit),
        .io_addr(io_addr),
        .io_read(io_read),
        .io_write(io_write),
        .spkr_pulse(spkr_pulse),
        .mock_audio_left(mock_left),
        .mock_audio_right(mock_right),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .col80(col80),
        .altchar(altchar),
        .dhires(dhires),
        .store80(store80),
        .vbl(vbl),
        .clk_set(clk_set), .clk_time(clk_time),
        .vram_req(vram_req),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .fl_wr(fl_wr), .fl_wr_drv(fl_wr_drv), .fl_wr_blk(fl_wr_blk),
        .char_rom_addr(char_rom_addr),
        .char_rom_data(char_rom_data),
        .aux_rd_want(aux_rd_want), .aux_rd_addr(aux_rd_addr),
        .aux_rd_hit(aux_rd_hit), .aux_rd_data(aux_rd_data),
        .aux_wr_go(aux_wr_go), .aux_wr_addr(aux_wr_addr), .aux_wr_data(aux_wr_data),
        .aux_wr_busy(aux_wr_busy),
        .dsk_store_go(dsk_store_go), .dsk_store_addr(dsk_store_addr),
        .dsk_store_we(dsk_store_we), .dsk_store_wdata(dsk_store_wdata),
        .dsk_store_rdata(dsk_store_rdata), .dsk_store_ack(dsk_store_ack),
        .dsk_store_idle(dsk_store_idle),
        .ssc_rx_data(ssc_rx_data), .ssc_rx_valid(ssc_rx_valid), .ssc_lines(ssc_lines),
        .ssc_tx_req(ssc_tx_req), .ssc_tx_byte(ssc_tx_byte), .ssc_tx_ack(ssc_tx_ack),
        .ssc_st_req(ssc_st_req), .ssc_st_byte(ssc_st_byte), .ssc_st_ack(ssc_st_ack),
        .hd_present(hd_present),
        .hd_go(core_hd_go), .hd_addr(core_hd_addr), .hd_we(core_hd_we), .hd_be(core_hd_be),
        .hd_wdata(core_hd_wdata), .hd_rdata(hd_rdata), .hd_ack(hd_m_ack && !hd_own_s),
        .hd_wb_go(hd_wb_go), .hd_wb_drv(hd_wb_drv), .hd_wb_blk(hd_wb_blk),
        .hd_rb_go(hd_rb_go), .hd_rb_ok(hd_rb_ok), .hd_size0(hd_size0), .hd_size1(hd_size1),
        .hd_sd_busy(hd_sd_busy),
        // held while the TF card's volumes load, so the boot finds them
        .cpu_rdy(cpu_rdy & !hd_loading),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .dbg_mem_ready(dbg_mem_ready),
        .img_up_go(img_up_go),
        .img_up_drive(img_up_drive),
        .img_up_addr(img_up_addr),
        .img_up_data(img_up_data),
        .img_up_last(img_up_last),
        .img_up_ro(img_up_ro),
        .img_up_bad(img_up_bad),
        .img_up_busy(img_up_busy),
        .img_up_done(img_up_done),
        .img_dn_go(img_dn_go),
        .img_dn_drive(img_dn_drive),
        .img_dn_addr(img_dn_addr),
        .img_dn_data(img_dn_data),
        .img_dn_valid(img_dn_valid),
        .debug_cpu_pc(debug_cpu_pc),
        .debug_dsk_head(debug_dsk_head),
        .debug_cpu_addr(debug_cpu_addr),
        .debug_cpu_dout(debug_cpu_dout),
        .debug_cpu_we(debug_cpu_we),
        .debug_cpu_sync(debug_cpu_sync),
        .debug_cpu_a(debug_cpu_a),
        .debug_cpu_x(debug_cpu_x),
        .debug_cpu_y(debug_cpu_y),
        .debug_cpu_s(debug_cpu_s),
        .debug_cpu_p(debug_cpu_p),
        .debug_cpu_ir(debug_cpu_ir)
    );

    // HDMI link reset: held only until the PLL has locked and the pixel clock
    // has run a while, and deliberately independent of sys_reset, so the S1
    // button resets the Apple without making the display drop and re-sync.
    reg [7:0] hdmi_rst_cnt = 8'd0;
    wire      hdmi_rst_n   = hdmi_rst_cnt[7];
    always @(posedge clk_pixel or negedge pll_locked) begin
        if (!pll_locked)       hdmi_rst_cnt <= 8'd0;
        else if (!hdmi_rst_n)  hdmi_rst_cnt <= hdmi_rst_cnt + 1'b1;
    end

    // hdmi_tx owns the 720x480p raster and asks for the colour of
    // (pixel_x, pixel_y) combinationally, on the same cycle.
    wire [9:0]  pixel_x;
    wire [9:0]  pixel_y;

    // Video Generator (Apple II Raster to 720x480 CEA-861). Its colour output
    // is registered, so it is given the next pixel's position; see the
    // header of src/video_generator.v.
    wire [7:0] vid_red;
    wire [7:0] vid_green;
    wire [7:0] vid_blue;

    // Persistent configuration via DIP switches:
    //   DIP1 (C7): Color TV mode (1 = softer hi-res decode, 0 = sharp RGB)
    //   DIP2 (E9), DIP3 (E8): Scanlines (00 = off, 01 = 25%, 10 = 50%, 11 = 75%)
    reg [1:0] color_tv_sync  = 2'b00;
    reg [1:0] scanline0_sync = 2'b00;
    reg [1:0] scanline1_sync = 2'b00;
    always @(posedge clk_pixel) begin
        color_tv_sync  <= {color_tv_sync[0],  sw_color_tv};
        scanline0_sync <= {scanline0_sync[0], sw_scanline[0]};
        scanline1_sync <= {scanline1_sync[0], sw_scanline[1]};
    end
    wire       color_tv  = color_tv_sync[1];
    wire [1:0] scanlines = {scanline1_sync[1], scanline0_sync[1]};

    // Flashing text, as the //e makes it from its video counter: the state
    // changes every 16 frames, ~1.9 Hz a full cycle (one clock of the frame,
    // pixel (0, 0), counts it).  Locked to the picture, not free-running.
    reg [3:0] flash_frames = 4'd0;
    reg       flash_clk = 1'b0;
    always @(posedge clk_pixel)
        if (pixel_x == 10'd0 && pixel_y == 10'd0) begin
            flash_frames <= flash_frames + 4'd1;
            if (flash_frames == 4'd15) flash_clk <= ~flash_clk;
        end

    video_generator u_video (
        .clk_pixel(clk_pixel),
        .reset(sys_reset),
        .flash_clk(flash_clk),
        .h_cnt(pixel_x + 10'd1),
        .v_cnt(pixel_y),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .col80(col80),
        .altchar(altchar),
        .dhires(dhires),
        .store80(store80),
        .color_tv(color_tv),
        .scanlines(scanlines),
        .aux_data(aux_line_data),
        .aux_col(aux_col),
        .aux_fill_addr(aux_fill_addr),
        .aux_fill_start(aux_fill_start),
        .vram_req(vram_req),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .char_rom_addr(char_rom_addr),
        .char_rom_data(char_rom_data),
        .red(vid_red),
        .green(vid_green),
        .blue(vid_blue),
        .vbl(vbl)
    );

    // HDMI bring-up test pattern (color bars + 1kHz tone). Hold S2
    // to force the output to this pattern instead of the Apple //e
    // framebuffer, to verify the clocking/TMDS/serializer/audio path
    // independent of the CPU, RAM and video_generator. See
    // src/colorbar_gen.v.
    wire test_pattern_enable = btn_test;

    wire [23:0] bar_rgb;

    colorbar_gen u_colorbar (
        .clk_pixel(clk_pixel),
        .reset(~hdmi_rst_n),
        .x(pixel_x),
        .y(pixel_y),
        .rgb(bar_rgb)
    );

    // Black while the TF card loads: the CPU is held, so the ROM has not
    // cleared the text page yet.
    wire [23:0] hdmi_rgb = test_pattern_enable ? bar_rgb
                         : hd_loading          ? 24'h000000
                                               : {vid_red, vid_green, vid_blue};

    // HDMI audio: sound_generator's 48 kHz samples, the same ones the DAC
    // plays (audio_filter resamples the speaker and Mockingboard to 48 kHz).
    wire        hdmi_audio_valid;
    wire [15:0] hdmi_audio_pcm_l;
    wire [15:0] hdmi_audio_pcm_r;

    // HDMI transmitter: 720x480p59.94 (VIC 2) with data islands carrying
    // 48 kHz L-PCM audio, ACR, and the AVI / Audio InfoFrames. Mode and audio
    // rate come from src/hdmi/hdmi_defs.vh. The Apple palette is full-range
    // RGB, so the AVI InfoFrame says so (a sink would otherwise assume
    // limited range for this CE mode and crush blacks / clip whites).
    wire [39:0] tmds;

    hdmi_tx #(
        .RGB_QUANT(2'b10)
    ) u_hdmi (
        .clk_pixel(clk_pixel),
        .rst_n(hdmi_rst_n),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .video_rgb(hdmi_rgb),
        .audio_valid(hdmi_audio_valid),
        .audio_l(hdmi_audio_pcm_l),
        .audio_r(hdmi_audio_pcm_r),
        .tmds(tmds[29:0])
    );

    // Lane 3 is the TMDS clock: the constant 0000011111, one pixel period.
    assign tmds[39:30] = 10'b0000011111;

    // Serializers: OSER10 shifts D0 first (TMDS bit 0 first), DDR on
    // clk_tmds (5x), 270 Mbit/s per lane.  The Dock's HDMI balls are true
    // LVDS pairs (TLVDS_OBUF + LVDS25, verified on hardware by the TP20K
    // starter's hdmi/ design).
    wire [3:0] tmds_pad_p, tmds_pad_n;
    assign {tmds_clk_p, tmds_d_p} = tmds_pad_p;
    assign {tmds_clk_n, tmds_d_n} = tmds_pad_n;

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_tmds_lane
            wire [9:0] sym = tmds[10*lane +: 10];
            wire       q;
            OSER10 #(.GSREN("false"), .LSREN("true")) u_ser (
                .D0(sym[0]), .D1(sym[1]), .D2(sym[2]), .D3(sym[3]), .D4(sym[4]),
                .D5(sym[5]), .D6(sym[6]), .D7(sym[7]), .D8(sym[8]), .D9(sym[9]),
                .PCLK(clk_pixel), .FCLK(clk_tmds), .RESET(~hdmi_rst_n), .Q(q)
            );
            TLVDS_OBUF u_obuf (.I(q), .O(tmds_pad_p[lane]), .OB(tmds_pad_n[lane]));
        end
    endgenerate

    // Sound Generator (PT8211 DAC + LPA4809 amplifier on the Dock)
    sound_generator u_sound (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .spkr_pulse(spkr_pulse),
        .test_tone_enable(test_pattern_enable),
        .mock_left(mock_left),
        .mock_right(mock_right),
        .i2s_bclk(i2s_bclk),
        .i2s_lrck(i2s_lrck),
        .i2s_din(i2s_din),
        .pa_en(pa_en),
        .spkr_out(),
        .audio_valid(hdmi_audio_valid),
        .audio_sample(),
        .audio_sample_l(hdmi_audio_pcm_l),
        .audio_sample_r(hdmi_audio_pcm_r)
    );

    // Diagnostic LEDs (active-low)
    // LED 0: Heartbeat blinker (~1.9 Hz: the text flash, below, as SSOT)
    // LED 1: PLLs locked and DDR3 calibrated (ON when all three)
    // LED 2: Reset status (ON when running)
    // LED 3: CPU Memory Write Activity
    // LED 4: Video mode (ON = Text, OFF = Graphics)
    // LED 5: Keyboard strobe active
    assign led[0] = ~flash_clk;
    assign led[1] = ~(pll_locked & ddr_lock & aux_ready);
    assign led[2] = sys_reset;
    assign led[3] = ~debug_cpu_we;
    assign led[4] = ~text_mode;
    assign led[5] = ~key_strobe;

endmodule

// A Dock key, debounced: synchronised, and it has to read the same for 2^18
// clocks (~10 ms) before a change counts, so a press is one pulse however it
// bounces.  Active low (the Dock's 10k pull-ups).
module key_press (
    input  wire clk,
    input  wire key_n,
    output reg  press = 1'b0      // one clock, as the key goes down
);
    reg  [1:0]  sync  = 2'b11;
    reg         level = 1'b0;     // debounced: 1 = held
    reg  [17:0] cnt   = 18'd0;
    always @(posedge clk) begin
        sync  <= {sync[0], key_n};
        press <= 1'b0;
        if (~sync[1] == level) cnt <= 18'd0;
        else if (&cnt) begin
            level <= ~level;
            cnt   <= 18'd0;
            press <= ~level;
        end else cnt <= cnt + 18'd1;
    end
endmodule

