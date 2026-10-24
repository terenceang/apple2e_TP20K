// Apple //e Computer on Tang Nano 20K FPGA
// Top-Level Module integrating CPU, Memory, Video/HDMI, I2S Audio, and UART/HID/Gamepad Inputs

`include "src/hdmi/hdmi_defs.vh"

module top (
    input  wire       clk,        // 27.0 MHz onboard crystal (Pin 4)
    input  wire       btn_s1,     // Pushbutton S1 (Pin 88, active high: pressed = 1)
    input  wire       btn_s2,     // Pushbutton S2 (Pin 87, active high: pressed = 1)

    // Onboard LEDs (Pins 15-20, active-low on Tang Nano 20K)
    output wire [5:0] led,

    // UART Console (BL616 USB-Serial or Bluetooth-to-UART module)
    input  wire       uart_rx,    // Pin 70
    output wire       uart_tx,    // Pin 69

    // HDMI TMDS Output (Pins 33-40)
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,

    // Onboard MAX98357A I2S Class-D Audio Amplifier
    output wire       i2s_bclk,   // Pin 56
    output wire       i2s_lrck,   // Pin 55
    output wire       i2s_din,    // Pin 54
    output wire       pa_en,      // Pin 51

    // On-board 64 Mbit SDRAM (inside the GW2AR-18 package): the aux 64 KB
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,

    // TF card slot (SPI mode): ProDOS drive 1 is loaded from it at power-up
    output wire        sd_clk,
    output wire        sd_mosi,   // SD_CMD
    input  wire        sd_miso,   // SD_DAT0
    output wire        sd_cs_n    // SD_DAT3
);

    // Power-on and Button Reset Generator (S2 pushbutton triggers reset when pressed = 1)
    reg [19:0] rst_cnt = 20'd0;

    always @(posedge clk) begin
        if (btn_s2)
            rst_cnt <= 20'd0;
        else if (rst_cnt != 20'hFFFFF)
            rst_cnt <= rst_cnt + 1'b1;
    end

    wire sys_reset = (rst_cnt != 20'hFFFFF);

    // Clock Generator
    wire clk_tmds;
    wire clk_pixel;
    wire pll_locked;
    wire ce_1m;
    wire flash_clk;

    clk_gen u_clk_gen (
        .clk_in(clk),
        .rst_in(1'b0),
        .clk_tmds(clk_tmds),
        .clk_pixel(clk_pixel),
        .pll_locked(pll_locked),
        .ce_1m(ce_1m),
        .flash_clk(flash_clk)
    );

    // Serial Debugger & Apple //e Console Mirror
    wire [7:0]  rx_byte;
    wire        rx_valid;
    wire        dbg_mode;
    wire        cpu_rdy;
    wire [15:0] dbg_mem_addr;
    wire [7:0]  dbg_mem_din;
    wire        dbg_mem_ready;
    wire        dbg_aux;

    // The Disk ][ image transfer, between the debugger above and the image store
    // inside the core.
    wire        img_up_go, img_up_drive, img_up_last, img_up_bad, img_up_busy, img_up_done;
    wire [17:0] img_up_addr;
    wire [7:0]  img_up_data;
    wire        img_dn_go, img_dn_drive, img_dn_last, img_dn_valid, img_dn_done;
    wire [17:0] img_dn_addr;
    wire [7:0]  img_dn_data;
    // The debugger's own Disk II transfer outputs; the SD loader takes the ports while d2_own.
    wire        dbg_img_up_go, dbg_img_up_drive, dbg_img_up_last;
    wire [17:0] dbg_img_up_addr;
    wire [7:0]  dbg_img_up_data;
    wire        dbg_img_dn_go, dbg_img_dn_drive, dbg_img_dn_last;
    wire [17:0] dbg_img_dn_addr;
    wire [7:0]  sd_up_data;
    wire        sd_d2_own, sd_d2_up_go, sd_d2_up_last, sd_d2_dn_go;
    wire [17:0] sd_d2_up_addr, sd_d2_dn_addr;
    assign img_up_go    = sd_d2_own ? sd_d2_up_go   : dbg_img_up_go;
    assign img_up_drive = sd_d2_own ? 1'b0          : dbg_img_up_drive;
    assign img_up_addr  = sd_d2_own ? sd_d2_up_addr : dbg_img_up_addr;
    assign img_up_data  = sd_d2_own ? sd_up_data    : dbg_img_up_data;
    assign img_up_last  = sd_d2_own ? sd_d2_up_last : dbg_img_up_last;
    assign img_dn_go    = sd_d2_own ? sd_d2_dn_go   : dbg_img_dn_go;
    assign img_dn_drive = sd_d2_own ? 1'b0          : dbg_img_dn_drive;
    assign img_dn_addr  = sd_d2_own ? sd_d2_dn_addr : dbg_img_dn_addr;
    assign img_dn_last  = sd_d2_own ? 1'b0          : dbg_img_dn_last;

    // ProDOS Hard Disk image transfer (2 MB per drive)
    wire        hd_up_go, hd_up_drive, hd_up_last, hd_up_bad, hd_up_busy, hd_up_done;
    wire [20:0] hd_up_addr;
    wire [7:0]  hd_up_data;
    // The debugger's own upload outputs; the SD loader owns the port until it finishes.
    wire        dbg_up_go, dbg_up_drive, dbg_up_last;
    wire [20:0] dbg_up_addr;
    wire [7:0]  dbg_up_data;
    wire        sd_up_go, sd_up_last, sd_loading, dbg_uart_tx, sd_rpt_tx, sd_rpt_busy;
    assign uart_tx = sd_rpt_busy ? sd_rpt_tx : dbg_uart_tx;   // SD status line, first ~40 s only
    wire        hd_wr_req, hd_wr_ack, sd_dn_go;
    wire [11:0] hd_wr_blk;
    wire [20:0] sd_dn_addr;
    wire [20:0] sd_up_addr;
    assign hd_up_go    = sd_loading ? sd_up_go   : dbg_up_go;
    assign hd_up_drive = sd_loading ? 1'b0       : dbg_up_drive;
    assign hd_up_addr  = sd_loading ? sd_up_addr : dbg_up_addr;
    assign hd_up_data  = sd_loading ? sd_up_data : dbg_up_data;
    assign hd_up_last  = sd_loading ? sd_up_last : dbg_up_last;
    wire        hd_dn_go, hd_dn_drive, hd_dn_last, hd_dn_valid, hd_dn_done;
    wire [20:0] hd_dn_addr;
    wire [7:0]  hd_dn_data;
    wire        dbg_dn_go, dbg_dn_drive, dbg_dn_last;
    wire [20:0] dbg_dn_addr;
    assign hd_dn_go    = hd_wr_req ? sd_dn_go   : dbg_dn_go;
    assign hd_dn_drive = hd_wr_req ? 1'b0       : dbg_dn_drive;
    assign hd_dn_addr  = hd_wr_req ? sd_dn_addr : dbg_dn_addr;
    assign hd_dn_last  = hd_wr_req ? 1'b0       : dbg_dn_last;

    // Asserted by the debugger's "x" (CPU reset) command; consumed by the core
    wire        cpu_reset_req;

    wire [15:0] debug_cpu_pc;
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
    wire        text_mode;
    wire        mixed_mode;
    wire        page2;
    wire        hires_mode;
    wire        col80;
    wire        altchar;
    wire        dhires;
    wire        store80;
    wire        vbl;

    serial_debugger u_debugger (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .uart_tx(dbg_uart_tx),
        .rx_byte(rx_byte),
        .rx_valid(rx_valid),
        .dbg_mode(dbg_mode),
        .cpu_rdy(cpu_rdy),
        .cpu_reset_req(cpu_reset_req),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .dbg_mem_ready(dbg_mem_ready),
        .dbg_aux(dbg_aux),
        .img_up_go(dbg_img_up_go),
        .img_up_drive(dbg_img_up_drive),
        .img_up_addr(dbg_img_up_addr),
        .img_up_data(dbg_img_up_data),
        .img_up_last(dbg_img_up_last),
        .img_up_bad(img_up_bad),
        .img_up_busy(img_up_busy),
        .img_up_done(img_up_done),
        .img_dn_go(dbg_img_dn_go),
        .img_dn_drive(dbg_img_dn_drive),
        .img_dn_addr(dbg_img_dn_addr),
        .img_dn_last(dbg_img_dn_last),
        .img_dn_data(img_dn_data),
        .img_dn_valid(img_dn_valid),
        .img_dn_done(img_dn_done),
        .hd_up_go(dbg_up_go),
        .hd_up_drive(dbg_up_drive),
        .hd_up_addr(dbg_up_addr),
        .hd_up_data(dbg_up_data),
        .hd_up_last(dbg_up_last),
        .hd_up_bad(hd_up_bad),
        .hd_up_busy(hd_up_busy),
        .hd_up_done(hd_up_done),
        .hd_dn_go(dbg_dn_go),
        .hd_dn_drive(dbg_dn_drive),
        .hd_dn_addr(dbg_dn_addr),
        .hd_dn_last(dbg_dn_last),
        .hd_dn_data(hd_dn_data),
        .hd_dn_valid(hd_dn_valid),
        .hd_dn_done(hd_dn_done),
        .cpu_pc(debug_cpu_pc),
        .cpu_a(debug_cpu_a),
        .cpu_x(debug_cpu_x),
        .cpu_y(debug_cpu_y),
        .cpu_s(debug_cpu_s),
        .cpu_p(debug_cpu_p),
        .cpu_ir(debug_cpu_ir),
        .cpu_addr(debug_cpu_addr),
        .cpu_dout(debug_cpu_dout),
        .cpu_we(debug_cpu_we),
        .cpu_sync(debug_cpu_sync),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .pll_locked(pll_locked)
    );

    // Input Controller (UART RX, Keyboard & Gamepad)
    wire [7:0] io_addr;
    wire       io_read;
    wire       io_write;
    wire [7:0] input_dout;
    wire       input_hit;
    wire       key_strobe;
    wire       kbd_reset;

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
        .kbd_reset(kbd_reset)
    );

    // Apple //e Core (CPU, Memory, Softswitches)
    wire        vram_req;
    wire [15:0] vram_addr;
    wire [7:0]  vram_data;
    wire [11:0] char_rom_addr;
    wire [7:0]  char_rom_data;

    // Aux RAM (SDRAM) between the core, the video line buffer and the pins,
    // and the arbiter for the Disk ][ image store, which shares the same
    // controller at the lowest priority.
    wire        aux_rd_want, aux_rd_hit, aux_wr_go, aux_wr_busy;
    wire [15:0] aux_rd_addr, aux_wr_addr;
    wire [7:0]  aux_rd_data, aux_wr_data, aux_line_data;
    wire        aux_fill_start;
    wire [15:0] aux_fill_addr;
    wire [5:0]  aux_col;

    // The Disk ][ store's SDRAM port, from the core's copy of the store.
    wire        dsk_store_go, dsk_store_we, dsk_store_ack, dsk_store_idle;
    wire [21:0] dsk_store_addr;
    wire [15:0] dsk_store_wdata, dsk_store_rdata;

    // The ProDOS hard disk SDRAM port, from the core's copy of the card.
    wire        hd_store_go, hd_store_we, hd_store_ack, hd_store_idle;
    wire [21:0] hd_store_addr;
    wire [15:0] hd_store_wdata, hd_store_rdata;

    sd_loader u_sd_loader (
        .clk(clk_pixel), .reset(sys_reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .up_go(sd_up_go), .up_data(sd_up_data), .up_addr(sd_up_addr), .up_last(sd_up_last),
        .up_busy(hd_up_busy), .up_done(hd_up_done),
        .down_go(sd_dn_go), .down_addr(sd_dn_addr), .down_data(hd_dn_data), .down_valid(hd_dn_valid),
        .wr_req(hd_wr_req), .wr_blk(hd_wr_blk), .wr_ack(hd_wr_ack),
        .d2_up_go(sd_d2_up_go), .d2_up_addr(sd_d2_up_addr), .d2_up_last(sd_d2_up_last),
        .d2_up_busy(img_up_busy), .d2_up_done(img_up_done),
        .d2_dn_go(sd_d2_dn_go), .d2_dn_addr(sd_d2_dn_addr), .d2_dn_data(img_dn_data), .d2_dn_valid(img_dn_valid),
        .d2_save(dbg_img_up_go & dbg_img_up_last & ~dbg_img_up_drive), .d2_own(sd_d2_own),
        .loading(sd_loading), .fail(), .rpt_tx(sd_rpt_tx), .rpt_busy(sd_rpt_busy)
    );

    aux_ram u_aux (
        .clk(clk_pixel), .reset(sys_reset),
        .fill_start(aux_fill_start), .fill_addr(aux_fill_addr), .col(aux_col),
        .line_data(aux_line_data),
        .rd_want(aux_rd_want), .rd_addr(aux_rd_addr), .rd_data(aux_rd_data), .rd_hit(aux_rd_hit),
        .wr_go(aux_wr_go), .wr_addr(aux_wr_addr), .wr_data(aux_wr_data), .wr_busy(aux_wr_busy),
        .hd_go(hd_store_go), .hd_addr(hd_store_addr), .hd_we(hd_store_we),
        .hd_wdata(hd_store_wdata), .hd_rdata(hd_store_rdata),
        .hd_ack(hd_store_ack), .hd_idle(hd_store_idle),
        .dsk_go(dsk_store_go), .dsk_addr(dsk_store_addr), .dsk_we(dsk_store_we),
        .dsk_wdata(dsk_store_wdata), .dsk_rdata(dsk_store_rdata),
        .dsk_ack(dsk_store_ack), .dsk_idle(dsk_store_idle),
        .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .IO_sdram_dq(IO_sdram_dq), .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba),
        .O_sdram_dqm(O_sdram_dqm)
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
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .col80(col80),
        .altchar(altchar),
        .dhires(dhires),
        .store80(store80),
        .vbl(vbl),
        .vram_req(vram_req),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
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
        .hd_store_go(hd_store_go), .hd_store_addr(hd_store_addr),
        .hd_store_we(hd_store_we), .hd_store_wdata(hd_store_wdata),
        .hd_store_rdata(hd_store_rdata), .hd_store_ack(hd_store_ack),
        .hd_store_idle(hd_store_idle),
        .cpu_rdy(cpu_rdy),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .dbg_mem_ready(dbg_mem_ready),
        .dbg_aux(dbg_aux),
        .img_up_go(img_up_go),
        .img_up_drive(img_up_drive),
        .img_up_addr(img_up_addr),
        .img_up_data(img_up_data),
        .img_up_last(img_up_last),
        .img_up_bad(img_up_bad),
        .img_up_busy(img_up_busy),
        .img_up_done(img_up_done),
        .img_dn_go(img_dn_go),
        .img_dn_drive(img_dn_drive),
        .img_dn_addr(img_dn_addr),
        .img_dn_last(img_dn_last),
        .img_dn_data(img_dn_data),
        .img_dn_valid(img_dn_valid),
        .img_dn_done(img_dn_done),
        .hd_wr_req(hd_wr_req), .hd_wr_blk(hd_wr_blk), .hd_wr_ack(hd_wr_ack),
        .hd_up_go(hd_up_go),
        .hd_up_drive(hd_up_drive),
        .hd_up_addr(hd_up_addr),
        .hd_up_data(hd_up_data),
        .hd_up_last(hd_up_last),
        .hd_up_bad(hd_up_bad),
        .hd_up_busy(hd_up_busy),
        .hd_up_done(hd_up_done),
        .hd_dn_go(hd_dn_go),
        .hd_dn_drive(hd_dn_drive),
        .hd_dn_addr(hd_dn_addr),
        .hd_dn_last(hd_dn_last),
        .hd_dn_data(hd_dn_data),
        .hd_dn_valid(hd_dn_valid),
        .hd_dn_done(hd_dn_done),
        .debug_cpu_pc(debug_cpu_pc),
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
    // has run a while, and deliberately independent of sys_reset, so the S2
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

    // HDMI bring-up test pattern (color bars + 1kHz tone). Hold S1 (pressed = 1)
    // to force the output to this pattern instead of the Apple //e
    // framebuffer, to verify the clocking/TMDS/serializer/audio path
    // independent of the CPU, RAM and video_generator. See
    // src/colorbar_gen.v.
    wire test_pattern_enable = btn_s1;

    wire [23:0] bar_rgb;

    colorbar_gen u_colorbar (
        .clk_pixel(clk_pixel),
        .reset(~hdmi_rst_n),
        .x(pixel_x),
        .y(pixel_y),
        .rgb(bar_rgb)
    );

    wire [23:0] hdmi_rgb = test_pattern_enable ? bar_rgb
                                               : {vid_red, vid_green, vid_blue};

    // HDMI audio: the same speaker-model PCM that goes to the I2S amplifier
    // (sound_generator.audio_sample, updated at 46.875 kHz), sampled at
    // VM_AUDIO_HZ = 48 kHz. 27 MHz / 48 kHz = 562.5 clocks, so a fractional
    // accumulator alternates 562 and 563.
    //
    // The two rates are coupled: sound_generator holds audio_sample for one
    // I2S frame of exactly 576 clocks, so it must stay at 46.875 kHz or this
    // resampler plays it at the wrong speed. sim/tb_sound.v checks that.
    wire signed [15:0] spkr_sample;
    reg  [24:0]        hdmi_audio_acc   = 25'd0;
    reg                hdmi_audio_valid = 1'b0;
    reg  [15:0]        hdmi_audio_pcm   = 16'd0;

    always @(posedge clk_pixel) begin
        if (!hdmi_rst_n) begin
            hdmi_audio_acc   <= 25'd0;
            hdmi_audio_valid <= 1'b0;
        end else begin
            hdmi_audio_valid <= 1'b0;
            if (hdmi_audio_acc + `VM_AUDIO_HZ >= `VM_PIXEL_HZ) begin
                hdmi_audio_acc   <= hdmi_audio_acc + `VM_AUDIO_HZ - `VM_PIXEL_HZ;
                hdmi_audio_valid <= 1'b1;
                hdmi_audio_pcm   <= spkr_sample;
            end else begin
                hdmi_audio_acc <= hdmi_audio_acc + `VM_AUDIO_HZ;
            end
        end
    end

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
        .audio_l(hdmi_audio_pcm),
        .audio_r(hdmi_audio_pcm),
        .tmds(tmds[29:0])
    );

    // Lane 3 is the TMDS clock: the constant 0000011111, one pixel period.
    assign tmds[39:30] = 10'b0000011111;

    // Serializers: OSER10 shifts D0 first (TMDS bit 0 first), DDR on
    // clk_tmds (5x), 270 Mbit/s per lane. Pins 33-40 are true-LVDS pairs on
    // this package, so TLVDS_OBUF (apicula rejects ELVDS_OBUF there with
    // "it is a true lvds pin"; the Tang Nano 9K's GW1NR-9 is different).
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

    // Sound Generator (MAX98357A I2S Class-D Amplifier)
    sound_generator u_sound (
        .clk(clk_pixel),
        .reset(sys_reset),
        .spkr_pulse(spkr_pulse),
        .test_tone_enable(test_pattern_enable),
        .i2s_bclk(i2s_bclk),
        .i2s_lrck(i2s_lrck),
        .i2s_din(i2s_din),
        .pa_en(pa_en),
        // No on-board consumer: the 1-bit speaker toggle reaches the outside
        // world only through audio_sample (I2S + HDMI); tb_sound watches it.
        .spkr_out(),
        .audio_sample(spkr_sample)
    );

    // Diagnostic LEDs (active-low)
    // LED 0: Heartbeat blinker (~1.6 Hz, driven by clk_gen flash_clk as SSOT)
    // LED 1: PLL Locked (ON when locked)
    // LED 2: Reset status (ON when running)
    // LED 3: CPU Memory Write Activity
    // LED 4: Video mode (ON = Text, OFF = Graphics)
    // LED 5: Keyboard strobe active
    assign led[0] = ~flash_clk;
    assign led[1] = ~pll_locked;
    assign led[2] = sys_reset;
    assign led[3] = ~debug_cpu_we;
    assign led[4] = ~text_mode;
    assign led[5] = ~key_strobe;

endmodule
