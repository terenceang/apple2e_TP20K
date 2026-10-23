`timescale 1ns / 1ps
`default_nettype none

module tb_pop_unpack;
    reg clk = 1'b0;
    always #18.519 clk = ~clk; // 27 MHz

    reg mem_clk = 1'b0;
    always #1.2555 mem_clk = ~mem_clk; // 400 MHz DDR3

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

    // Video generator raster
    reg [9:0] pixel_x = 10'd0;
    reg [9:0] pixel_y = 10'd0;

    always @(posedge clk) begin
        if (reset) begin
            pixel_x <= 10'd0;
            pixel_y <= 10'd0;
        end else begin
            if (pixel_x == 10'd857) begin
                pixel_x <= 10'd0;
                pixel_y <= (pixel_y == 10'd524) ? 10'd0 : pixel_y + 1'b1;
            end else begin
                pixel_x <= pixel_x + 1'b1;
            end
        end
    end

    wire text_mode, mixed_mode, page2, hires_mode, dhires, store80;
    wire [15:0] vram_addr;
    wire        vram_req;
    wire [7:0]  vram_data;
    wire        aux_fill_start;
    wire [15:0] aux_fill_addr;
    wire [5:0]  aux_col;
    wire [7:0]  aux_line_data;

    // Aux RAM wires to core
    wire        aux_rd_want;
    wire [16:0] aux_rd_addr;
    wire [7:0]  aux_rd_data;
    wire        aux_rd_hit;
    wire        aux_wr_go;
    wire [16:0] aux_wr_addr;
    wire [7:0]  aux_wr_data;
    wire        aux_wr_busy;
    wire        ready;

    wire [15:0] ddr_dq;
    wire [1:0]  ddr_dqs, ddr_dqs_n;

    wire [15:0] debug_cpu_pc;
    wire [7:0]  debug_cpu_ir;
    wire        debug_cpu_sync;

    // Core
    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .dhires(dhires), .store80(store80), .vbl(1'b0),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .char_rom_addr(), .char_rom_data(),
        .aux_rd_want(aux_rd_want), .aux_rd_addr(aux_rd_addr), .aux_rd_hit(aux_rd_hit),
        .aux_rd_data(aux_rd_data),
        .aux_wr_go(aux_wr_go), .aux_wr_addr(aux_wr_addr), .aux_wr_data(aux_wr_data),
        .aux_wr_busy(aux_wr_busy),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_mem_ready(),
        .debug_cpu_pc(debug_cpu_pc), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(debug_cpu_sync), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir(debug_cpu_ir)
    );

    always @(posedge clk) begin
        if (!reset && dut.cpu_go && debug_cpu_sync && (debug_cpu_pc < 16'h0820 || (debug_cpu_pc >= 16'hD100 && debug_cpu_pc < 16'hD130))) begin
            $display("INST PC=%04x IR=%02x A=%02x X=%02x",
                     debug_cpu_pc, debug_cpu_ir, dut.u_cpu.debug_a, dut.u_cpu.debug_x);
            $fflush;
        end
    end

    // Aux RAM
    aux_ram u_aux (
        .clk(clk), .reset(reset), .ddr_clk(clk),
        .fill_start(aux_fill_start), .fill_addr(aux_fill_addr), .col(aux_col),
        .line_data(aux_line_data),
        .rd_want(aux_rd_want), .rd_addr(aux_rd_addr), .rd_data(aux_rd_data), .rd_hit(aux_rd_hit),
        .wr_go(aux_wr_go), .wr_addr(aux_wr_addr), .wr_data(aux_wr_data), .wr_busy(aux_wr_busy),
        .dsk_go(1'b0), .dsk_addr(22'd0), .dsk_we(1'b0), .dsk_wdata(16'd0),
        .dsk_rdata(), .dsk_ack(), .dsk_idle(),
        .hd_go(1'b0), .hd_addr(25'd0), .hd_we(1'b0), .hd_be(2'b11), .hd_wdata(16'd0),
        .hd_rdata(), .hd_ack(),
        .ready(ready),
        .diag(),
        .ddr_memory_clk(mem_clk), .ddr_lock(1'b1),
        .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_DQS_n(ddr_dqs_n),
        .DDR3_A(), .DDR3_BA(), .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(),
        .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(), .DDR3_CKE(), .DDR3_nRESET(),
        .DDR3_ODT(), .DDR3_DM()
    );

    // Video Generator
    video_generator u_video (
        .clk_pixel(clk), .reset(reset), .flash_clk(1'b0),
        .h_cnt(pixel_x + 10'd1), .v_cnt(pixel_y),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .col80(dut.col80), .altchar(dut.altchar),
        .dhires(dhires), .store80(store80),
        .aux_data(aux_line_data), .aux_col(aux_col),
        .aux_fill_addr(aux_fill_addr), .aux_fill_start(aux_fill_start),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .char_rom_addr(), .char_rom_data(),
        .red(), .green(), .blue(), .vbl()
    );

    integer i;

    reg [127:0] burst_data;
    reg [7:0] aux_val;
    reg [7:0] main_val;

    initial begin
        $display("Starting tb_pop_unpack...");
        dut.u_cpu.AXYS[0] = 8'h00;
        dut.u_cpu.AXYS[1] = 8'h00;
        dut.u_cpu.AXYS[2] = 8'h00;
        dut.u_cpu.AXYS[3] = 8'hFF;

        // Set reset vector to jump to $0800
        dut.u_rom.mem[14'h3FFC] = 8'h00;
        dut.u_rom.mem[14'h3FFD] = 8'h08;

        // Pre-load Main RAM with 6502 test code at $0800:
        // Setup LC Bank 1 R/W
        // 0800: A2 FF       LDX #$FF
        // 0802: 9A          TXS
        // 0803: AD 8B C0    LDA $C08B ; LC Bank 1 R/W
        // 0806: AD 8B C0    LDA $C08B
        //
        // Copy 48 bytes from $0900 to $D100 (in Language Card):
        // 0809: A2 00       LDX #$00
        // 080B: BD 00 09    LDA $0900,X
        // 080E: 9D 00 D1    STA $D100,X
        // 0811: E8          INX
        // 0812: E0 30       CPX #$30
        // 0814: D0 F5       BNE $080B
        // 0816: 4C 00 D1    JMP $D100
        dut.u_ram.mem[16'h0800] = 8'hA2; dut.u_ram.mem[16'h0801] = 8'hFF;
        dut.u_ram.mem[16'h0802] = 8'h9A;
        dut.u_ram.mem[16'h0803] = 8'hAD; dut.u_ram.mem[16'h0804] = 8'h8B; dut.u_ram.mem[16'h0805] = 8'hC0;
        dut.u_ram.mem[16'h0806] = 8'hAD; dut.u_ram.mem[16'h0807] = 8'h8B; dut.u_ram.mem[16'h0808] = 8'hC0;
        dut.u_ram.mem[16'h0809] = 8'hA2; dut.u_ram.mem[16'h080A] = 8'h00;
        dut.u_ram.mem[16'h080B] = 8'hBD; dut.u_ram.mem[16'h080C] = 8'h00; dut.u_ram.mem[16'h080D] = 8'h09;
        dut.u_ram.mem[16'h080E] = 8'h9D; dut.u_ram.mem[16'h080F] = 8'h00; dut.u_ram.mem[16'h0810] = 8'hD1;
        dut.u_ram.mem[16'h0811] = 8'hE8;
        dut.u_ram.mem[16'h0812] = 8'hE0; dut.u_ram.mem[16'h0813] = 8'h30;
        dut.u_ram.mem[16'h0814] = 8'hD0; dut.u_ram.mem[16'h0815] = 8'hF5;
        dut.u_ram.mem[16'h0816] = 8'h4C; dut.u_ram.mem[16'h0817] = 8'h00; dut.u_ram.mem[16'h0818] = 8'hD1;

        // Code at $0900 (will run at $D100 in Language Card):
        // D100: 8D 05 C0    STA $C005 ; RAMWRT aux
        //
        // Loop: write 10 bytes to Aux RAM at $2000..$2009 using Total Replay's exact sequence:
        // D103: A2 00       LDX #$00
        // D105: 8A          TXA
        // D106: 18          CLC
        // D107: 69 A0       ADC #$A0 (data byte = $A0 + X)
        // D109: 9D 00 20    STA $2000,X ; writes to Aux RAM!
        // D10C: 8D 04 C0    STA $C004   ; STA RAMWRTmain
        // D10F: 8D 00 04    STA $0400   ; writes to $0400
        // D112: 8D 05 C0    STA $C005   ; STA RAMWRTaux
        // D115: E8          INX
        // D116: E0 0A       CPX #$0A
        // D118: D0 EB       BNE $D105
        // D11A: 8D 04 C0    STA $C004   ; RAMWRT main
        // D11D: 4C 1D D1    JMP $D11D   ; loop forever
        dut.u_ram.mem[16'h0900] = 8'h8D; dut.u_ram.mem[16'h0901] = 8'h05; dut.u_ram.mem[16'h0902] = 8'hC0;
        dut.u_ram.mem[16'h0903] = 8'hA2; dut.u_ram.mem[16'h0904] = 8'h00;
        dut.u_ram.mem[16'h0905] = 8'h8A;
        dut.u_ram.mem[16'h0906] = 8'h18;
        dut.u_ram.mem[16'h0907] = 8'h69; dut.u_ram.mem[16'h0908] = 8'hA0;
        dut.u_ram.mem[16'h0909] = 8'h9D; dut.u_ram.mem[16'h090A] = 8'h00; dut.u_ram.mem[16'h090B] = 8'h20;
        dut.u_ram.mem[16'h090C] = 8'h8D; dut.u_ram.mem[16'h090D] = 8'h04; dut.u_ram.mem[16'h090E] = 8'hC0;
        dut.u_ram.mem[16'h090F] = 8'h8D; dut.u_ram.mem[16'h0910] = 8'h00; dut.u_ram.mem[16'h0911] = 8'h04;
        dut.u_ram.mem[16'h0912] = 8'h8D; dut.u_ram.mem[16'h0913] = 8'h05; dut.u_ram.mem[16'h0914] = 8'hC0;
        dut.u_ram.mem[16'h0915] = 8'hE8;
        dut.u_ram.mem[16'h0916] = 8'hE0; dut.u_ram.mem[16'h0917] = 8'h0A;
        dut.u_ram.mem[16'h0918] = 8'hD0; dut.u_ram.mem[16'h0919] = 8'hEB;
        dut.u_ram.mem[16'h091A] = 8'h8D; dut.u_ram.mem[16'h091B] = 8'h04; dut.u_ram.mem[16'h091C] = 8'hC0;
        dut.u_ram.mem[16'h091D] = 8'h4C; dut.u_ram.mem[16'h091E] = 8'h1D; dut.u_ram.mem[16'h091F] = 8'hD1;

        reset = 1'b1;
        while (!ready) @(posedge clk);
        $display("DDR3 ready at %t", $time);
        repeat (10) @(posedge clk);
        reset = 1'b0;
        $display("Running 6502 CPU from $0800 at %t...", $time);

        // Wait until CPU hits $D11D (the infinite loop at the end of the test)
        while (!(debug_cpu_sync && debug_cpu_pc == 16'hD11E)) @(posedge clk);

        $display("CPU reached $D11C at %t!", $time);

        // Wait a few clocks for write buffer to drain
        while (aux_wr_busy) @(posedge clk);
        repeat (50) @(posedge clk);

        $display("=== CHECKING RESULTS ===");
        for (i = 0; i < 10; i = i + 1) begin
            burst_data = u_aux.u_ddr3.mem[(16'h2000 + i) >> 3];
            aux_val = burst_data[(i & 7) * 16 +: 8];
            main_val = dut.u_ram.mem[16'h2000 + i];
            $display("Byte %0d: Main RAM=$%02x (want $00), Aux RAM (DDR3)=$%02x (want $%02x)",
                     i, main_val, aux_val, 8'hA0 + i);
        end
        $display("Main RAM $0400: $%02x (want $a9)", dut.u_ram.mem[16'h0400]);

        $finish;
    end

    initial begin
        #5000000000;
        $display("TIMEOUT in tb_pop_unpack! PC=%04x state=%0d",
                 dut.u_cpu.PC, dut.u_cpu.state);
        $finish;
    end

endmodule
