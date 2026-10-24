`timescale 1ns / 1ps
`default_nettype none

module tb_oldskool;
    reg clk = 1'b0;
    always #18.519 clk = ~clk; // 27 MHz
    reg mem_clk = 1'b0;
    always #2.5 mem_clk = ~mem_clk; // 200 MHz

    reg reset = 1'b1;
    reg [7:0] ce_acc = 8'd0;
    reg ce_1m = 1'b0;
    always @(posedge clk) begin
        ce_1m  <= (ce_acc + 8'd5 >= 8'd132);
        ce_acc <= (ce_acc + 8'd5 >= 8'd132) ? ce_acc + 8'd5 - 8'd132 : ce_acc + 8'd5;
    end

    // Video counters for HDMI CEA-861 (720x480 @ 60Hz: 858 x 525)
    reg [9:0] px = 10'd0, py = 10'd0;
    always @(posedge clk) begin
        if (px == 10'd857) begin
            px <= 10'd0;
            py <= (py == 10'd524) ? 10'd0 : py + 1'b1;
        end else px <= px + 1'b1;
    end

    wire text_mode, mixed_mode, page2, hires_mode, dhires, store80;
    wire [15:0] vram_addr; wire vram_req; wire [7:0] vram_data;
    wire aux_fill_start; wire [15:0] aux_fill_addr; wire [5:0] aux_col; wire [7:0] aux_line_data;
    wire aux_rd_want, aux_rd_hit, aux_wr_go, aux_wr_busy, ready;
    wire [16:0] aux_rd_addr, aux_wr_addr; wire [7:0] aux_rd_data, aux_wr_data;
    wire [15:0] ddr_dq; wire [1:0] ddr_dqs, ddr_dqs_n;
    wire vbl;

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
        .red(), .green(), .blue(), .vbl(vbl)
    );

    wire [15:0] debug_cpu_pc, debug_cpu_addr;
    wire [7:0] debug_cpu_a, debug_cpu_x, debug_cpu_y, debug_cpu_s, debug_cpu_p, debug_cpu_ir, debug_cpu_dout;
    wire debug_cpu_we, debug_cpu_sync;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .col80(), .altchar(), .dhires(dhires), .store80(store80),
        .vbl(vbl), .clk_set(1'b0), .clk_time(52'd0),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .fl_wr(), .fl_wr_drv(), .fl_wr_blk(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(aux_rd_want), .aux_rd_addr(aux_rd_addr), .aux_rd_hit(aux_rd_hit),
        .aux_rd_data(aux_rd_data),
        .aux_wr_go(aux_wr_go), .aux_wr_addr(aux_wr_addr), .aux_wr_data(aux_wr_data),
        .aux_wr_busy(aux_wr_busy),
        .dsk_store_go(), .dsk_store_addr(), .dsk_store_we(), .dsk_store_wdata(),
        .dsk_store_rdata(16'd0), .dsk_store_ack(1'b0),
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
        .debug_dsk_head(), .debug_cpu_pc(debug_cpu_pc), .debug_cpu_addr(debug_cpu_addr),
        .debug_cpu_dout(debug_cpu_dout), .debug_cpu_we(debug_cpu_we),
        .debug_cpu_sync(debug_cpu_sync), .debug_cpu_a(debug_cpu_a), .debug_cpu_x(debug_cpu_x),
        .debug_cpu_y(debug_cpu_y), .debug_cpu_s(debug_cpu_s), .debug_cpu_p(debug_cpu_p),
        .debug_cpu_ir(debug_cpu_ir)
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

    // Load unpacked.bin into memory
    reg [7:0] unpacked [0:65535];
    integer i;

    initial begin
        $readmemh("scratch/unpacked.hex", unpacked);
        #1;
        while (!ready) @(posedge clk);

        // Copy unpacked image to main RAM
        for (i = 0; i < 49152; i = i + 1) begin
            dut.u_ram.mem[i] = unpacked[i];
        end

        // Set reset vector to $7FD4
        dut.u_rom.mem[14'h3FFC] = 8'hD4;
        dut.u_rom.mem[14'h3FFD] = 8'h7F;

        reset = 1'b1;
        repeat (10) @(posedge clk);
        dut.u_cpu.AXYS[0] = 8'h00;
        dut.u_cpu.AXYS[1] = 8'h00;
        dut.u_cpu.AXYS[2] = 8'h00;
        dut.u_cpu.AXYS[3] = 8'hFF;
        reset = 1'b0;

        $display("Started CPU from $7FD4");
        $fflush();
    end

    // INT_ROUT's computed jitter, written into its BVC offset at $8301 (0..3 is safe)
    integer nint = 0;
    always @(posedge clk) if (dut.c02_go && debug_cpu_we && debug_cpu_addr == 16'h8301) begin
        nint = nint + 1;
        if (debug_cpu_dout > 8'd3 || nint < 20)
            $display("INT %0d: BVC offset %0d%s  py=%0d px=%0d", nint, debug_cpu_dout,
                     debug_cpu_dout > 8'd3 ? "  <-- CRASH" : "", py, px);
        if (debug_cpu_dout > 8'd3) begin $display("FAIL: jitter out of range"); $finish; end
        if (nint == 40) begin $display("PASS: 40 interrupts in range"); $finish; end
    end

    // cycle-level timeline around the first interrupts, in 6502 steps
    integer cyc = 0, t_flag = 0, nlog = 0;
    always @(posedge clk) if (dut.c02_go) begin
        cyc = cyc + 1;
        if (!dut.mock_irq_n && t_flag == 0) t_flag = cyc;
        if (dut.mock_irq_n) t_flag = 0;
        if (t_flag != 0 && nlog < 0) begin
            nlog = nlog + 1;
            $display("  +%0d addr=%04X we=%b sync=%b pc=%04X t1c=%04X din=%02X", cyc - t_flag, debug_cpu_addr,
                     debug_cpu_we, debug_cpu_sync, debug_cpu_pc, dut.u_mockingboard.u_via1.t1c, dut.cpu_din);
        end
    end
    always @(posedge clk) if (dut.c02_go && debug_cpu_addr == 16'hC405 && debug_cpu_we)
        $display("STY $C405 at cyc %0d", cyc);

    // Instruction trace
    reg [15:0] last_pc = 16'hFFFF;
    integer step_count = 0;

    always @(posedge clk) begin
        if (dut.c02_go && debug_cpu_sync) begin
            step_count = step_count + 1;
            if (debug_cpu_pc != last_pc) begin
                last_pc = debug_cpu_pc;
                // Log key milestones
                if (debug_cpu_pc == 16'h817E || // Entering SYNC
                    debug_cpu_pc == 16'h8199 || // SYNC LDA $C019 check
                    debug_cpu_pc == 16'h819C || // SYNC BMI $8189
                    debug_cpu_pc == 16'h819E || // SYNC passed (first NOP)!
                    debug_cpu_pc == 16'h81B5 || // STY $C405 (Timer 1 launched)
                    debug_cpu_pc == 16'h81B8 || // CLI
                    debug_cpu_pc == 16'h82EF) begin // IRQ handler INT_ROUT reached!
                    $display("Step %0d: PC=$%04X OP=$%02X A=$%02X X=$%02X Y=$%02X SP=$%02X P=$%02X py=%0d vbl=%b mock_irq=%b",
                        step_count, debug_cpu_pc, debug_cpu_ir, debug_cpu_a, debug_cpu_x, debug_cpu_y,
                        debug_cpu_s, debug_cpu_p, py, vbl, dut.mock_irq_n);
                    $fflush();
                end
            end
            if (step_count % 10000 == 0) begin
                $display("Heartbeat: step %0d, PC=$%04X, py=%0d, vbl=%b, mock_irq=%b", step_count, debug_cpu_pc, py, vbl, dut.mock_irq_n);
                $fflush();
            end
            if (step_count > 5000000) begin
                $display("Finished successfully after %0d steps", step_count);
                $finish;
            end
        end
    end

endmodule
`default_nettype wire
