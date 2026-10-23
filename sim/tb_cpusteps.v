`timescale 1ns / 1ps
`default_nettype none

// tb_cpusteps.v -- does the 6502 get every 1 MHz cycle?
//
// A real //e's 6502 runs one cycle per microsecond, always.  Here it steps on
// ce_1m unless something holds it (video_busy: the video's RAM fetch, the
// clocks after a step, an aux/LC RAM access waiting on the DDR3), and a held
// step is taken late (ce_1m_pending) -- but if the hold lasts to the next
// ce_1m, the two become one step and a cycle is lost.  This counts them, with
// apple2_core, aux_ram on the DDR3 model and the video generator fetching,
// running a loop from four places in turn:
//   0  main RAM, text mode        1  main RAM, hi-res
//   2  language-card RAM (DDR3)   3  aux RAM (RAMRD/RAMWRT, DDR3)
// The loop reads and writes as well as fetching:  LDA $0400,X / STA $2000,X /
// INX / JMP loop.  None is lost in any of the four, and a step is at most 3
// clocks late (the video's fetch, the clocks after a step); on the board the
// same loop timed by the Mockingboard's 6522 took its exact cycle count from
// main RAM and from LC RAM alike (2026-10-23).  The DDR3 model answers
// faster than the chip, which is why the board measurement matters.  Needs
// roms/apple2e_rom.hex (for the core's ROM file only).
module tb_cpusteps;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;
    reg mem_clk = 1'b0;
    always #2.5 mem_clk = ~mem_clk;

    reg reset = 1'b1;
    reg [7:0] ce_acc = 8'd0;          // ce_1m exactly as clk_gen makes it: 5/132
    reg ce_1m = 1'b0;
    always @(posedge clk) begin
        ce_1m  <= (ce_acc + 8'd5 >= 8'd132);
        ce_acc <= (ce_acc + 8'd5 >= 8'd132) ? ce_acc + 8'd5 - 8'd132 : ce_acc + 8'd5;
    end

    reg [9:0] px = 10'd0, py = 10'd0;
    always @(posedge clk) begin
        if (px == 10'd857) begin px <= 10'd0; py <= (py == 10'd524) ? 10'd0 : py + 1'b1; end
        else px <= px + 1'b1;
    end

    wire text_mode, mixed_mode, page2, hires_mode, dhires, store80;
    wire [15:0] vram_addr; wire vram_req; wire [7:0] vram_data;
    wire aux_fill_start; wire [15:0] aux_fill_addr; wire [5:0] aux_col; wire [7:0] aux_line_data;
    wire aux_rd_want, aux_rd_hit, aux_wr_go, aux_wr_busy, ready;
    wire [16:0] aux_rd_addr, aux_wr_addr; wire [7:0] aux_rd_data, aux_wr_data;
    wire [15:0] ddr_dq; wire [1:0] ddr_dqs, ddr_dqs_n;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .col80(), .altchar(), .dhires(dhires), .store80(store80),
        .vbl(1'b0), .clk_set(1'b0), .clk_time(52'd0),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .fl_wr(), .fl_wr_drv(), .fl_wr_blk(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(aux_rd_want), .aux_rd_addr(aux_rd_addr), .aux_rd_hit(aux_rd_hit),
        .aux_rd_data(aux_rd_data),
        .aux_wr_go(aux_wr_go), .aux_wr_addr(aux_wr_addr), .aux_wr_data(aux_wr_data),
        .aux_wr_busy(aux_wr_busy),
        .dsk_store_go(), .dsk_store_addr(), .dsk_store_we(), .dsk_store_wdata(),
        .dsk_store_rdata(16'd0), .dsk_store_ack(1'b0), .dsk_store_idle(1'b1),
        .ssc_rx_data(8'd0), .ssc_rx_valid(1'b0), .ssc_lines(2'b00),
        .ssc_tx_req(), .ssc_tx_byte(), .ssc_tx_ack(1'b0), .ssc_st_req(), .ssc_st_byte(), .ssc_st_ack(1'b0),
        .hd_present(2'b00), .hd_go(), .hd_addr(), .hd_we(), .hd_be(), .hd_wdata(),
        .hd_rdata(16'd0), .hd_ack(1'b0), .hd_wb_go(), .hd_wb_drv(), .hd_wb_blk(),
        .hd_rb_go(), .hd_rb_ok(1'b0), .hd_size0(16'd0), .hd_size1(16'd0), .hd_sd_busy(1'b0),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_mem_ready(),
        .img_up_go(1'b0), .img_up_drive(1'b0), .img_up_addr(20'd0), .img_up_data(8'd0),
        .img_up_last(1'b0), .img_up_ro(1'b0), .img_up_bad(1'b0), .img_up_busy(), .img_up_done(),
        .img_dn_go(1'b0), .img_dn_drive(1'b0), .img_dn_addr(20'd0),
        .img_dn_data(), .img_dn_valid(),
        .debug_dsk_head(), .debug_cpu_pc(), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir()
    );

    aux_ram u_aux (
        .clk(clk), .reset(reset), .ddr_clk(clk),
        .fill_start(aux_fill_start), .fill_addr(aux_fill_addr), .col(aux_col),
        .line_data(aux_line_data),
        .rd_want(aux_rd_want), .rd_addr(aux_rd_addr), .rd_data(aux_rd_data), .rd_hit(aux_rd_hit),
        .wr_go(aux_wr_go), .wr_addr(aux_wr_addr), .wr_data(aux_wr_data), .wr_busy(aux_wr_busy),
        .dsk_go(1'b0), .dsk_addr(22'd0), .dsk_we(1'b0), .dsk_wdata(16'd0),
        .dsk_rdata(), .dsk_ack(), .dsk_idle(),
        .hd_go(1'b0), .hd_addr(25'd0), .hd_we(1'b0), .hd_be(2'b11), .hd_wdata(16'd0),
        .hd_rdata(), .hd_ack(), .ready(ready), .diag(),
        .ddr_memory_clk(mem_clk), .ddr_lock(1'b1),
        .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_DQS_n(ddr_dqs_n),
        .DDR3_A(), .DDR3_BA(), .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(),
        .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(), .DDR3_CKE(), .DDR3_nRESET(),
        .DDR3_ODT(), .DDR3_DM()
    );

    video_generator u_video (
        .clk_pixel(clk), .reset(reset), .flash_clk(1'b0),
        .h_cnt(px + 10'd1), .v_cnt(py),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .col80(dut.col80), .altchar(1'b0),
        .dhires(dhires), .store80(store80), .color_tv(1'b0), .scanlines(2'd0),
        .aux_data(aux_line_data), .aux_col(aux_col),
        .aux_fill_addr(aux_fill_addr), .aux_fill_start(aux_fill_start),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .char_rom_addr(), .char_rom_data(8'h00),
        .red(), .green(), .blue(), .vbl()
    );

    task ddr_put(input [16:0] w, input [7:0] b);
        reg [127:0] q;
        begin
            q = u_aux.u_ddr3.mem[{2'b00, w[16:3]}];
            q[16 * w[2:0] +: 8] = b;
            u_aux.u_ddr3.mem[{2'b00, w[16:3]}] = q;
        end
    endtask

    // ---- counting: a ce_1m with no 6502 step before the next one is lost ----
    integer ces = 0, steps = 0, lost = 0, late_max = 0, since = 0;
    integer hist [0:63];
    integer hi;
    initial for (hi = 0; hi < 64; hi = hi + 1) hist[hi] = 0;
    reg     measuring = 1'b0, got = 1'b1;
    always @(posedge clk) if (measuring) begin
        // ce_1m first: a step on the same clock is that cycle's, on time
        if (ce_1m) begin
            ces = ces + 1;
            if (!got) lost = lost + 1;   // the previous cycle never stepped
            got = 1'b0;
            since = 0;
        end else since = since + 1;
        if (dut.c02_go) begin
            steps = steps + 1;
            if (!got) begin
                if (since > late_max) late_max = since;
                hist[since > 63 ? 63 : since] = hist[since > 63 ? 63 : since] + 1;
            end
            got = 1'b1;
        end
    end
    // The loop, at `base`:  LDA $0400,X / STA $2000,X / INX / JMP base
    task put_loop(input integer where, input [15:0] base);   // where: 0 main, 1 LC, 2 aux
        reg [7:0] code [0:9];
        integer k;
        begin
            {code[0], code[1], code[2]} = {8'hBD, 8'h00, 8'h04};
            {code[3], code[4], code[5]} = {8'h9D, 8'h00, 8'h20};
            code[6] = 8'hE8;
            {code[7], code[8], code[9]} = {8'h4C, base[7:0], base[15:8]};
            for (k = 0; k < 10; k = k + 1) begin
                if (where == 0) dut.u_ram.mem[base + k] = code[k];
                else if (where == 1) ddr_put({1'b1, base + k[15:0]}, code[k]);
                else ddr_put({1'b0, base + k[15:0]}, code[k]);
            end
        end
    endtask

    integer mode, n, bad = 0;
    reg [7:0] stub [0:31];
    task set_stub(input integer m);
        begin
            for (n = 0; n < 32; n = n + 1) stub[n] = 8'hEA;
            case (m)
                1: begin {stub[0], stub[1], stub[2]} = {8'hAD, 8'h50, 8'hC0};   // LDA $C050 graphics
                         {stub[3], stub[4], stub[5]} = {8'hAD, 8'h57, 8'hC0};   // LDA $C057 hi-res
                         {stub[6], stub[7], stub[8]} = {8'h4C, 8'h00, 8'h03}; end
                2: begin {stub[0], stub[1], stub[2]} = {8'hAD, 8'h8B, 8'hC0};   // LC RAM, read + write
                         {stub[3], stub[4], stub[5]} = {8'hAD, 8'h8B, 8'hC0};
                         {stub[6], stub[7], stub[8]} = {8'h4C, 8'h00, 8'hD0}; end
                3: begin {stub[0], stub[1], stub[2]} = {8'h8D, 8'h03, 8'hC0};   // RAMRD on
                         {stub[3], stub[4], stub[5]} = {8'h8D, 8'h05, 8'hC0};   // RAMWRT on
                         {stub[6], stub[7], stub[8]} = {8'h4C, 8'h00, 8'h03}; end
                default: {stub[0], stub[1], stub[2]} = {8'h4C, 8'h00, 8'h03};
            endcase
            dut.u_rom.mem[14'h3FFC] = 8'h00; dut.u_rom.mem[14'h3FFD] = 8'hFF;
            for (n = 0; n < 32; n = n + 1) begin
                dut.u_rom.mem[14'h3F00 + n] = stub[n];
                ddr_put({1'b1, 16'hFF00 + n[15:0]}, stub[n]);
            end
        end
    endtask

    initial begin
        #1;
        put_loop(0, 16'h0300);
        put_loop(1, 16'hD000);
        put_loop(2, 16'h0300);
        force dut.u_cpu.IRQ = 1'b0;
        while (!ready) @(posedge clk);
        for (mode = 0; mode < 4; mode = mode + 1) begin
            set_stub(mode);
            reset = 1'b1;
            repeat (10) @(posedge clk);
            dut.u_cpu.AXYS[0] = 8'h00; dut.u_cpu.AXYS[1] = 8'h00; dut.u_cpu.AXYS[2] = 8'h00; dut.u_cpu.AXYS[3] = 8'hFF;
            reset = 1'b0;
            repeat (20000) @(posedge clk);          // into the loop
            ces = 0; steps = 0; lost = 0; late_max = 0; got = 1'b1;
            for (hi = 0; hi < 64; hi = hi + 1) hist[hi] = 0;
            measuring = 1'b1;
            repeat (300000) @(posedge clk);          // ~11 ms, two thirds of a frame
            measuring = 1'b0;
            $display("mode %0d (%0s): %0d ce_1m, %0d steps, %0d lost, latest step %0d clocks after its ce_1m (PC $%04X)",
                     mode, mode == 0 ? "main RAM, text" : mode == 1 ? "main RAM, hi-res" :
                           mode == 2 ? "LC RAM" : "aux RAM", ces, steps, lost, late_max, dut.u_cpu.PC);
            // every cycle steps, and none more than a few clocks late
            if (lost != 0 || steps != ces || late_max > 8) bad = bad + 1;
        end
        if (bad == 0) $display("tb_cpusteps: PASS");
        else          $display("FAIL: tb_cpusteps: %0d of 4 modes lost or delayed cycles", bad);
        $finish;
    end
endmodule

`default_nettype wire
