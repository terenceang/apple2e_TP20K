`timescale 1ns / 1ps
`default_nettype none

// Aux/slot-ROM softswitches in apple2_core: the CPU bus is forced so each
// access is a single 1 MHz cycle, then the latched switch and the read data
// are checked.  Needs roms/apple2e_rom.hex (see roms/README.md).
module tb_auxsw;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(), .mixed_mode(), .page2(), .hires_mode(), .vbl(1'b0),
        .vram_req(1'b0), .vram_addr(16'd0), .vram_data(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(), .aux_rd_addr(), .aux_rd_hit(1'b1), .aux_rd_data(8'h00),
        .aux_wr_go(), .aux_wr_addr(), .aux_wr_data(), .aux_wr_busy(1'b0),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_aux(1'b0), .dbg_mem_ready(),
        .debug_cpu_pc(), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir()
    );

    integer fails = 0;

    // One CPU cycle at addr; the read data lands in dut.cpu_din.
    task cyc(input [15:0] addr, input w);
        begin
            force dut.cpu_addr = addr;
            force dut.cpu_we   = w;
            @(posedge ce_1m); @(posedge clk); @(posedge clk);
        end
    endtask

    task rd(input [15:0] addr); cyc(addr, 1'b0); endtask
    task wr(input [15:0] addr); cyc(addr, 1'b1); endtask

    task check(input [255:0] what, input ok);
        if (!ok) begin
            $display("FAIL: %0s", what);
            fails = fails + 1;
        end
    endtask

    task status(input [15:0] addr, input [255:0] what, input exp);
        begin rd(addr); check(what, dut.cpu_din[7] === exp); end
    endtask

    initial begin
        force dut.cpu_addr = 16'h0000;
        force dut.cpu_we   = 1'b0;
        #200; @(posedge clk); reset = 1'b0;
        @(posedge ce_1m);

        wr(16'hC003); status(16'hC013, "RAMRD on", 1);
        wr(16'hC002); status(16'hC013, "RAMRD off", 0);
        wr(16'hC005); status(16'hC014, "RAMWRT on", 1);
        wr(16'hC004); status(16'hC014, "RAMWRT off", 0);
        wr(16'hC009); status(16'hC016, "ALTZP on", 1);
        wr(16'hC008); status(16'hC016, "ALTZP off", 0);
        wr(16'hC00B); status(16'hC017, "SLOTC3ROM on", 1);
        wr(16'hC00A); status(16'hC017, "SLOTC3ROM off", 0);

        // Internal ROM gating.  Reset state: INTCXROM off, as on a //e, so the
        // slot scan boots the card and not the self-test at $C600.
        status(16'hC015, "INTCXROM reset", 0);
        rd(16'hC100); check("C100 floats at reset", dut.cpu_din === 8'h00);
        wr(16'hC007);
        rd(16'hC100); check("C100 ROM when INTCXROM", dut.cpu_din === dut.u_rom.mem[16'h0100]);
        wr(16'hC006);
        rd(16'hC100); check("C100 floats when INTCXROM off", dut.cpu_din === 8'h00);
        // $C3xx is internal with SLOTC3ROM off, and turns on INTC8ROM
        rd(16'hC800); check("C800 floats before C3xx", dut.cpu_din === 8'h00);
        rd(16'hC300); check("C300 ROM with SLOTC3ROM off", dut.cpu_din === dut.u_rom.mem[16'h0300]);
        rd(16'hC800); check("C800 ROM after C3xx", dut.cpu_din === dut.u_rom.mem[16'h0800]);
        rd(16'hCFFF);
        rd(16'hC800); check("C800 floats after CFFF", dut.cpu_din === 8'h00);
        // SLOTC3ROM on: $C3xx belongs to the (empty) slot
        wr(16'hC00B);
        rd(16'hC300); check("C300 floats with SLOTC3ROM on", dut.cpu_din === 8'h00);
        rd(16'hC800); check("C800 stays off", dut.cpu_din === 8'h00);

        if (fails == 0) $display("tb_auxsw: PASS");
        else            $display("FAIL: tb_auxsw %0d checks", fails);
        $finish;
    end

    initial begin #20000000; $display("FAIL: tb_auxsw timeout"); $finish; end
endmodule
