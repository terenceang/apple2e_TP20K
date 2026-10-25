`timescale 1ns / 1ps
`default_nettype none

module tb_floatbus;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

    wire [7:0] cpu_din;
    wire [7:0] char_rom_data;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(), .mixed_mode(), .page2(), .hires_mode(), .vbl(1'b0),
        .vram_req(1'b0), .vram_addr(16'd0), .vram_data(),
        .char_rom_addr(12'd0), .char_rom_data(char_rom_data),
        .aux_rd_want(), .aux_rd_addr(), .aux_rd_hit(1'b1), .aux_rd_data(8'h00),
        .aux_wr_go(), .aux_wr_addr(), .aux_wr_data(), .aux_wr_busy(1'b0),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_mem_ready(),
        .debug_cpu_pc(), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir()
    );

    integer fails = 0;
    integer checks = 0;
    task check(input [8*72-1:0] what, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin
                $display("FAIL: %0s", what);
                fails = fails + 1;
            end
        end
    endtask

    // Force write to main RAM
    task write_ram(input [15:0] addr, input [7:0] data);
        begin
            @(posedge clk);
            dut.u_ram.mem[addr] = data;
            @(posedge clk);
        end
    endtask

    initial begin
        @(negedge clk);
        reset = 1'b1;
        repeat (10) @(posedge clk);
        reset = 1'b0;
        @(posedge ce_1m);

        // Put text line 0: ':          FRENCH TOUCH PRESENT          :'
        // Column 10 ($040A) = 8'h06 ('F')
        // Column 39 ($0427) = 8'h3A (':')
        write_ram(16'h040A, 8'h06);
        write_ram(16'h0427, 8'h3A);
        // Line 8 text row 1 column 39 ($04A7) = 8'hA0 (space)
        write_ram(16'h04A7, 8'hA0);

        // Wait until scan_col == 10 and scan_line == 0
        while (dut.scan_line != 9'd0 || dut.scan_col != 7'd10) @(posedge ce_1m);

        // At column 10, line 0: reading $C051 must return 8'h06 ('F')
        @(posedge clk);
        force dut.cpu_addr = 16'hC051;
        force dut.cpu_we   = 1'b0;
        @(posedge clk);
        check("line 0 col 10 reads 'F' (0x06)", dut.cpu_din_comb == 8'h06);

        // Advance 29 cycles to column 39 ($27)
        repeat (29) @(posedge ce_1m);
        @(posedge clk);
        check("line 0 col 39 is cycle 39", dut.scan_col == 7'd39);
        check("line 0 col 39 reads ':' (0x3A)", dut.cpu_din_comb == 8'h3A);

        // Advance 65 cycles to line 1 column 39
        repeat (65) @(posedge ce_1m);
        @(posedge clk);
        check("line 1 col 39 is line 1", dut.scan_line == 9'd1);
        check("line 1 col 39 is cycle 39", dut.scan_col == 7'd39);
        check("line 1 col 39 reads ':' (0x3A)", dut.cpu_din_comb == 8'h3A);

        // Advance to line 8 column 39 (7 * 65 cycles)
        repeat (7 * 65) @(posedge ce_1m);
        @(posedge clk);
        check("line 8 col 39 is line 8", dut.scan_line == 9'd8);
        check("line 8 col 39 reads not ':' (0xA0)", dut.cpu_din_comb != 8'h3A);

        if (fails == 0)
            $display("tb_floatbus: PASS (%0d checks)", checks);
        else
            $display("tb_floatbus: FAILED %0d/%0d", fails, checks);

        $finish;
    end
endmodule
