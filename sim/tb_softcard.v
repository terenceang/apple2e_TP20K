`timescale 1ns / 1ps
`default_nettype none

// Z-80 SoftCard (src/softcard.v) in apple2_core, with aux_ram on the DDR3
// model and the video generator fetching, as tb_auxstress has them.  A 6502
// stub enables language-card RAM and writes $C200; a Z80 program at $1000
// (Z80 $0000) then writes and reads every scrambled region, does one
// read-modify-write, touches the speaker once and writes $E200 to hand back.
// The 6502 carries on after its STA, hands over again, and the Z80 has to
// resume after its own handing-back write.  Needs roms/apple2e_rom.hex.
module tb_softcard;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;
    reg mem_clk = 1'b0;
    always #2.5 mem_clk = ~mem_clk;

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

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
        .fl_wr(), .fl_wr_drv(), .fl_wr_trk(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(aux_rd_want), .aux_rd_addr(aux_rd_addr), .aux_rd_hit(aux_rd_hit),
        .aux_rd_data(aux_rd_data),
        .aux_wr_go(aux_wr_go), .aux_wr_addr(aux_wr_addr), .aux_wr_data(aux_wr_data),
        .aux_wr_busy(aux_wr_busy),
        .dsk_store_go(), .dsk_store_addr(), .dsk_store_we(), .dsk_store_wdata(),
        .dsk_store_rdata(16'd0), .dsk_store_ack(1'b0), .dsk_store_idle(1'b1),
        .hd_present(2'b00), .hd_go(), .hd_addr(), .hd_we(), .hd_be(), .hd_wdata(),
        .hd_rdata(16'd0), .hd_ack(1'b0), .hd_wb_go(), .hd_wb_drv(), .hd_wb_blk(),
        .hd_rb_go(), .hd_rb_ok(1'b0), .hd_size0(16'd0), .hd_size1(16'd0), .hd_sd_busy(1'b0),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_mem_ready(),
        .img_up_go(1'b0), .img_up_drive(1'b0), .img_up_addr(18'd0), .img_up_data(8'd0),
        .img_up_last(1'b0), .img_up_bad(1'b0), .img_up_busy(), .img_up_done(),
        .img_dn_go(1'b0), .img_dn_drive(1'b0), .img_dn_addr(18'd0),
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
        .dhires(dhires), .store80(store80),
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

    // 6502, ROM $FF00 and the same bytes in LC RAM (it runs on from there
    // once $C08B has switched it in):
    //   LDX #$FF / TXS / LDA $C08B x2      bank 1, read and write LC RAM
    //   STA $C200                          to the Z80
    //   LDA #$5A / STA $0310               back on the 6502
    //   STA $C200                          to the Z80 again
    //   LDA #$A5 / STA $0311 / JMP *
    localparam integer NS = 31;
    localparam [8*NS-1:0] stub = {
        8'hA2, 8'hFF, 8'h9A, 8'hAD, 8'h8B, 8'hC0, 8'hAD, 8'h8B, 8'hC0,
        8'h8D, 8'h00, 8'hC2,
        8'hA9, 8'h5A, 8'h8D, 8'h10, 8'h03,
        8'h8D, 8'h00, 8'hC2,
        8'hA9, 8'hA5, 8'h8D, 8'h11, 8'h03, 8'h4C, 8'h19, 8'hFF,
        8'hEA, 8'hEA, 8'hEA};
    // Z80, at Apple $1000:
    //   LD A,$11 / LD ($F300),A            -> $0300
    //   LD A,$22 / LD ($0100),A            -> $1100
    //   LD A,$33 / LD ($B000),A            -> $D000, LC RAM bank 1
    //   LD A,($B000) / LD ($F301),A        read it back -> $0301
    //   LD A,($E030)                       the speaker, once
    //   LD HL,$F380 / INC (HL)             $0380: $41 -> $42
    //   LD ($E200),A                       back to the 6502
    //   LD A,$44 / LD ($F302),A            after the second handover
    //   LD ($E200),A / JR $
    localparam integer NZ = 46;
    localparam [8*NZ-1:0] zprog = {
        8'h3E, 8'h11, 8'h32, 8'h00, 8'hF3,
        8'h3E, 8'h22, 8'h32, 8'h00, 8'h01,
        8'h3E, 8'h33, 8'h32, 8'h00, 8'hB0,
        8'h3A, 8'h00, 8'hB0, 8'h32, 8'h01, 8'hF3,
        8'h3A, 8'h30, 8'hE0,
        8'h21, 8'h80, 8'hF3, 8'h34,
        8'h32, 8'h00, 8'hE2,
        8'h3E, 8'h44, 8'h32, 8'h02, 8'hF3,
        8'h32, 8'h00, 8'hE2, 8'h18, 8'hFE,
        8'h00, 8'h00, 8'h00, 8'h00, 8'h00};

    reg spk_q = 1'b0;
    integer n, fails = 0, spk = 0, handovers = 0, zgo = 0;
    always @(posedge clk) if (!reset) begin
        if (dut.spkr_pulse && !spk_q) spk = spk + 1;   // it holds to the next bus step
        spk_q = dut.spkr_pulse;
        if (dut.z_go) zgo = zgo + 1;
    end
    reg on_q = 1'b0;
    always @(posedge clk) begin
        on_q <= dut.z80_on;
        if (dut.z80_on != on_q) handovers = handovers + 1;
    end

    task check(input [255:0] what, input ok);
        if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end
    endtask

    initial begin
        #1;
        dut.u_rom.mem[14'h3FFC] = 8'h00; dut.u_rom.mem[14'h3FFD] = 8'hFF;
        for (n = 0; n < NS; n = n + 1) begin
            dut.u_rom.mem[14'h3F00 + n] = stub[8 * (NS - 1 - n) +: 8];
            ddr_put({1'b1, 16'hFF00 + n[15:0]}, stub[8 * (NS - 1 - n) +: 8]);
        end
        for (n = 0; n < NZ; n = n + 1)
            dut.u_ram.mem[16'h1000 + n] = zprog[8 * (NZ - 1 - n) +: 8];
        dut.u_ram.mem[16'h0380] = 8'h41;
        force dut.u_cpu.IRQ = 1'b0;
        while (!ready) @(posedge clk);
        repeat (10) @(posedge clk);
        reset = 1'b0;
        // the 6502 reaches its JMP * once both rounds are done
        n = 0;
        while (dut.u_ram.mem[16'h0311] !== 8'hA5 && n < 400000) begin @(posedge clk); n = n + 1; end
        repeat (2000) @(posedge clk);
        check("6502 finished", dut.u_ram.mem[16'h0311] === 8'hA5);
        check("6502 resumed after its first STA $C200", dut.u_ram.mem[16'h0310] === 8'h5A);
        check("Z80 $F300 -> $0300", dut.u_ram.mem[16'h0300] === 8'h11);
        check("Z80 $0100 -> $1100", dut.u_ram.mem[16'h1100] === 8'h22);
        check("Z80 $B000 -> LC $D000 and back", dut.u_ram.mem[16'h0301] === 8'h33);
        check("Z80 INC (HL) at $F380", dut.u_ram.mem[16'h0380] === 8'h42);
        check("Z80 resumed after handing back", dut.u_ram.mem[16'h0302] === 8'h44);
        check("speaker touched once", spk == 1);
        check("four handovers", handovers == 4);
        check("6502 has the bus", !dut.z80_on);
        $display("%0d Z80 bus cycles, %0d speaker pulses, %0d handovers", zgo, spk, handovers);
        if (fails == 0) $display("PASS"); else $display("FAIL: tb_softcard");
        $finish;
    end
endmodule
