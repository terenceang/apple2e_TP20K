`timescale 1ns / 1ps
`default_nettype none

// tb_prodos_hd -- the slot 7 ProDOS card run by the real //e ROM and 65C02.
//
// From reset, the Autostart ROM scans slots 7 down to 1, so it should find
// the card's signature at $C700, run its boot, and land in a block 0 that
// this bench puts in the image.  That block calls the driver at $C729 (the
// $C7FF entry) the way ProDOS does: WRITE block 5 from $0800, READ it back to
// $1000 and compare, STATUS (65,535 blocks), and STATUS on drive 2 (no
// volume there, so no device).  $0300 = $AA when all of it passed, and the
// written block must also have been handed to the TF card (wb_go).
//
// The DDR3 is a behavioural port with a deliberately slow answer (LAT clocks,
// a few times what aux_ram takes) and it fails the bench if a request arrives
// while one is still out: the card has no queue, so that is the timing
// assumption the driver loops rely on.  Needs roms/apple2e_rom.hex.
module tb_prodos_hd;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

    localparam integer LAT = 60;     // ~2.2 us per request

    wire        hd_go, hd_we, wb_go, wb_drv;
    wire [1:0]  hd_be;
    wire [24:0] hd_addr;
    wire [15:0] hd_wdata, wb_blk;
    reg  [15:0] hd_rdata = 16'h0000;
    reg         hd_ack = 1'b0;
    reg         sd_busy = 1'b0;
    wire [15:0] pc;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(), .mixed_mode(), .page2(), .hires_mode(), .vbl(1'b0),
        .vram_req(1'b0), .vram_addr(16'd0), .vram_data(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(), .aux_rd_addr(), .aux_rd_hit(1'b1), .aux_rd_data(8'h00),
        .aux_wr_go(), .aux_wr_addr(), .aux_wr_data(), .aux_wr_busy(1'b0),
        .hd_present(2'b01), .hd_go(hd_go), .hd_addr(hd_addr), .hd_we(hd_we), .hd_be(hd_be),
        .hd_wdata(hd_wdata), .hd_rdata(hd_rdata), .hd_ack(hd_ack),
        .hd_wb_go(wb_go), .hd_wb_drv(wb_drv), .hd_wb_blk(wb_blk), .hd_sd_busy(sd_busy),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_aux(1'b0), .dbg_mem_ready(),
        .debug_cpu_pc(pc), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir()
    );

    // Blocks 0-15 of the volume
    reg [7:0] img [0:8191];
    integer i, fails = 0, reqs = 0;
    initial begin
        for (i = 0; i < 8192; i = i + 1) img[i] = 8'h00;
        for (i = 100; i < 512; i = i + 1) img[i] = i * 7 + 3;
        for (i = 5 * 512; i < 6 * 512; i = i + 1) img[i] = 8'h5A;
        img[0] = 8'h01;
        img[1] = 8'hA9; img[2] = 8'h02;                       //       LDA #$02
        img[3] = 8'h85; img[4] = 8'h42;                       //       STA $42
        img[5] = 8'hA9; img[6] = 8'h00;                       //       LDA #$00
        img[7] = 8'h85; img[8] = 8'h44;                       //       STA $44
        img[9] = 8'h85; img[10] = 8'h47;                      //       STA $47
        img[11] = 8'hA9; img[12] = 8'h08;                     //       LDA #$08
        img[13] = 8'h85; img[14] = 8'h45;                     //       STA $45
        img[15] = 8'hA9; img[16] = 8'h05;                     //       LDA #$05
        img[17] = 8'h85; img[18] = 8'h46;                     //       STA $46
        img[19] = 8'h20; img[20] = 8'h29; img[21] = 8'hC7;    //       JSR $C729
        img[22] = 8'hB0; img[23] = 8'h44;                     //       BCS FAIL
        img[24] = 8'hA9; img[25] = 8'h01;                     //       LDA #$01
        img[26] = 8'h85; img[27] = 8'h42;                     //       STA $42
        img[28] = 8'hA9; img[29] = 8'h10;                     //       LDA #$10
        img[30] = 8'h85; img[31] = 8'h45;                     //       STA $45
        img[32] = 8'h20; img[33] = 8'h29; img[34] = 8'hC7;    //       JSR $C729
        img[35] = 8'hB0; img[36] = 8'h37;                     //       BCS FAIL
        img[37] = 8'hA0; img[38] = 8'h00;                     //       LDY #$00
        img[39] = 8'hB9; img[40] = 8'h00; img[41] = 8'h08;    // CMP:  LDA $0800,Y
        img[42] = 8'hD9; img[43] = 8'h00; img[44] = 8'h10;    //       CMP $1000,Y
        img[45] = 8'hD0; img[46] = 8'h2D;                     //       BNE FAIL
        img[47] = 8'hB9; img[48] = 8'h00; img[49] = 8'h09;    //       LDA $0900,Y
        img[50] = 8'hD9; img[51] = 8'h00; img[52] = 8'h11;    //       CMP $1100,Y
        img[53] = 8'hD0; img[54] = 8'h25;                     //       BNE FAIL
        img[55] = 8'hC8;                                      //       INY
        img[56] = 8'hD0; img[57] = 8'hED;                     //       BNE CMP
        img[58] = 8'hA9; img[59] = 8'h00;                     //       LDA #$00
        img[60] = 8'h85; img[61] = 8'h42;                     //       STA $42
        img[62] = 8'h20; img[63] = 8'h29; img[64] = 8'hC7;    //       JSR $C729
        img[65] = 8'hB0; img[66] = 8'h19;                     //       BCS FAIL
        img[67] = 8'hE0; img[68] = 8'hFF;                     //       CPX #$FF
        img[69] = 8'hD0; img[70] = 8'h15;                     //       BNE FAIL
        img[71] = 8'hC0; img[72] = 8'hFF;                     //       CPY #$FF
        img[73] = 8'hD0; img[74] = 8'h11;                     //       BNE FAIL
        img[75] = 8'hA9; img[76] = 8'hF0;                     //       LDA #$F0
        img[77] = 8'h85; img[78] = 8'h43;                     //       STA $43
        img[79] = 8'h20; img[80] = 8'h29; img[81] = 8'hC7;    //       JSR $C729
        img[82] = 8'h90; img[83] = 8'h08;                     //       BCC FAIL
        img[84] = 8'hC9; img[85] = 8'h28;                     //       CMP #$28
        img[86] = 8'hD0; img[87] = 8'h04;                     //       BNE FAIL
        img[88] = 8'hA9; img[89] = 8'hAA;                     //       LDA #$AA
        img[90] = 8'hD0; img[91] = 8'h02;                     //       BNE DONE
        img[92] = 8'hA9; img[93] = 8'hEE;                     // FAIL: LDA #$EE
        img[94] = 8'h8D; img[95] = 8'h00; img[96] = 8'h03;    // DONE: STA $0300
        img[97] = 8'h4C; img[98] = 8'h61; img[99] = 8'h08;    // HANG: JMP HANG
    end

    reg        pend = 1'b0;
    reg [7:0]  t = 8'd0;
    reg [24:0] a_q;
    reg        we_q;
    reg [15:0] d_q;
    reg [1:0]  be_q;
    always @(posedge clk) begin
        hd_ack <= 1'b0;
        if (hd_go) begin
            reqs = reqs + 1;
            if (pend) begin $display("FAIL: request at %0t while one is out", $time); fails = fails + 1; end
            if (hd_addr[24:12] != 13'd0) begin $display("FAIL: drive %0d block %0d outside the bench's image", hd_addr[24], hd_addr[23:8]); fails = fails + 1; end
            pend <= 1'b1; t <= 8'd0; a_q <= hd_addr; we_q <= hd_we; d_q <= hd_wdata; be_q <= hd_be;
        end else if (pend) begin
            t <= t + 8'd1;
            if (t == LAT) begin
                pend <= 1'b0; hd_ack <= 1'b1;
                if (we_q) begin
                    if (be_q[0]) img[{a_q[11:0], 1'b0}] <= d_q[7:0];
                    if (be_q[1]) img[{a_q[11:0], 1'b1}] <= d_q[15:8];
                end else
                    hd_rdata <= {img[{a_q[11:0], 1'b1}], img[{a_q[11:0], 1'b0}]};
            end
        end
    end

    // The TF card: a write-back keeps it busy for a while, as a real one does
    integer wbs = 0, wb_bad = 0, bt = 0;
    always @(posedge clk) begin
        if (wb_go) begin
            wbs = wbs + 1;
            if (wb_drv !== 1'b0 || wb_blk !== 16'd5) wb_bad = wb_bad + 1;
            if (sd_busy) wb_bad = wb_bad + 1;
            sd_busy <= 1'b1; bt = 0;
        end else if (sd_busy) begin
            bt = bt + 1;
            if (bt == 3000) sd_busy <= 1'b0;
        end
    end

    reg seen_c700 = 1'b0;
    always @(posedge clk) if (pc == 16'hC701) seen_c700 <= 1'b1;   // debug_cpu_pc runs one ahead of the opcode

    initial begin
        // The ROM's reset uses the stack before it sets S (as tb_cpu_trace)
        dut.u_cpu.AXYS[0] = 8'h00; dut.u_cpu.AXYS[1] = 8'h00;
        dut.u_cpu.AXYS[2] = 8'h00; dut.u_cpu.AXYS[3] = 8'hFF;
        #200; @(posedge clk); reset = 1'b0;
        // ROM init and slot scan, then the boot and the test program
        while (dut.u_ram.mem[16'h0300] !== 8'hAA && dut.u_ram.mem[16'h0300] !== 8'hEE && $time < 400_000_000)
            #10000;
        if (!seen_c700) begin $display("FAIL: Autostart never ran $C700"); fails = fails + 1; end
        if (dut.u_ram.mem[16'h0300] !== 8'hAA) begin
            $display("FAIL: test program result $%02x (EE = a driver call failed), PC=%04x", dut.u_ram.mem[16'h0300], pc);
            fails = fails + 1;
        end
        for (i = 0; i < 512; i = i + 1)
            if (img[5 * 512 + i] !== img[i]) begin
                if (fails < 10) $display("FAIL: block 5 byte %0d = %02x, block 0 has %02x", i, img[5 * 512 + i], img[i]);
                fails = fails + 1;
            end
        if (wbs != 1 || wb_bad != 0) begin
            $display("FAIL: %0d write-backs (%0d wrong), want one of drive 1 block 5", wbs, wb_bad); fails = fails + 1;
        end
        $display("%0d DDR3 requests", reqs);
        if (fails == 0) $display("tb_prodos_hd: PASS");
        else            $display("tb_prodos_hd: FAIL (%0d)", fails);
        $finish;
    end
endmodule
