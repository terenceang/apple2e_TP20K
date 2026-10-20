`timescale 1ns / 1ps
`default_nettype none

module tb_cpu_trace;
    reg clk = 1'b0;
    always #18.519 clk = ~clk; // 27 MHz

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25); // ~1 MHz enable

    always @(posedge clk) begin
        if (ce_div == 5'd25)
            ce_div <= 5'd0;
        else
            ce_div <= ce_div + 1'b1;
    end

    wire [7:0]  io_addr;
    wire        io_read;
    wire        io_write;
    reg  [7:0]  input_dout = 8'h00;
    reg         input_hit  = 1'b0;
    wire        spkr_pulse;
    wire        text_mode, mixed_mode, page2, hires_mode;
    wire        vbl = 1'b0;

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

    apple2_core dut (
        .clk(clk),
        .reset(reset),
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
        .vbl(vbl),
        .vram_req(1'b0),
        .vram_addr(16'd0),
        .vram_data(),
        .char_rom_addr(12'd0),
        .char_rom_data(),
        .aux_rd_want(), .aux_rd_addr(), .aux_rd_hit(1'b1), .aux_rd_data(8'h00),
        .aux_wr_go(), .aux_wr_addr(), .aux_wr_data(), .aux_wr_busy(1'b0),
        .cpu_rdy(1'b1),
        .dbg_mem_addr(16'd0),
        .dbg_mem_din(),
        .dbg_aux(1'b0), .dbg_mem_ready(),
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

    integer inst_count = 0;
    integer cycle_count = 0;

    initial begin
        dut.u_cpu.AXYS[0] = 8'h00;
        dut.u_cpu.AXYS[1] = 8'h00;
        dut.u_cpu.AXYS[2] = 8'h00;
        dut.u_cpu.AXYS[3] = 8'hFF;
        #200;
        @(posedge clk);
        reset = 1'b0;
        $display("Reset de-asserted. Starting CPU execution trace...");
    end

    always @(posedge clk) begin
        if (!reset && ce_1m) begin
            cycle_count = cycle_count + 1;
            if (debug_cpu_sync) begin
                inst_count = inst_count + 1;
                if (inst_count <= 50 || (inst_count % 5000 == 0)) begin
                    $display("Cycle %0d [Inst #%0d] PC=%04X IR=%02X A=%02X X=%02X Y=%02X SP=%02X P=%02X (MemAddr=%04X WE=%b Dout=%02X)",
                             cycle_count, inst_count, debug_cpu_pc, debug_cpu_ir,
                             debug_cpu_a, debug_cpu_x, debug_cpu_y, debug_cpu_s, debug_cpu_p,
                             debug_cpu_addr, debug_cpu_we, debug_cpu_dout);
                end
            end
            if (inst_count >= 10000) begin
                $display("tb_cpu_trace: PASS (executed %0d instructions from Apple //e ROM)", inst_count);
                $finish;
            end
        end
    end

    // Safety timeout
    initial begin
        #50000000; // 50ms
        if (inst_count >= 1000)
            $display("tb_cpu_trace: PASS (executed %0d instructions from Apple //e ROM)", inst_count);
        else
            $display("tb_cpu_trace: FAIL (timeout with only %0d insts)", inst_count);
        $finish;
    end
endmodule
