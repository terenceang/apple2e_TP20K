// Behavioural stand-in for Gowin's DDR3 Memory Interface IP (simulation only;
// the netlist is encrypted).  Same module name and native-interface ports as
// src/ddr3_memory_interface/ddr3_memory_interface.v (1:4, x16):
// clk_out = memory_clk / 4, init_calib_complete after INIT_CLKS, one BL8
// burst (8 x 16-bit words, word i in bits [16i+15:16i]) per command, cmd 0
// write / 1 read, wr_data_mask bit = 1 leaves that byte alone, read data
// RD_LAT clocks after the command.  cmd_ready and wr_data_rdy drop for a
// couple of clocks after each command, so a client that ignores them is
// caught.  Prints FAIL for a command while not ready, a write without its
// data, an unaligned burst, or an address outside the regions aux_ram uses.
`timescale 1ps / 1ps
`default_nettype none

module DDR3_Memory_Interface_Top #(
    parameter INIT_CLKS   = 200,
    parameter RD_LAT      = 14,
    parameter LOSE_WRITES = 0       // 1: writes are dropped (to see the self-test catch it)
) (
    input  wire clk, memory_clk, pll_lock, rst_n,
    input  wire [5:0] app_burst_number,   // bursts per command - 1; aux_ram always 0
    output reg  clk_out = 1'b0,
    output wire ddr_rst,
    output reg  init_calib_complete = 1'b0,
    output wire cmd_ready,
    input  wire [2:0] cmd,
    input  wire cmd_en,
    input  wire [27:0] addr,           // {rank, bank[2:0], row[13:0], col[9:0]}
    output wire wr_data_rdy,
    input  wire [127:0] wr_data,
    input  wire wr_data_en, wr_data_end,
    input  wire [15:0] wr_data_mask,
    output reg  [127:0] rd_data = 128'd0,
    output reg  rd_data_valid = 1'b0,
    output wire rd_data_end,
    input  wire sr_req, ref_req,
    output wire sr_ack, ref_ack,
    input  wire burst,
    output wire [13:0] O_ddr_addr,
    output wire [2:0]  O_ddr_ba,
    output wire O_ddr_cs_n, O_ddr_ras_n, O_ddr_cas_n, O_ddr_we_n,
    output wire O_ddr_clk, O_ddr_clk_n, O_ddr_cke, O_ddr_odt, O_ddr_reset_n,
    output wire [1:0] O_ddr_dqm,
    inout  wire [15:0] IO_ddr_dq,
    inout  wire [1:0]  IO_ddr_dqs, IO_ddr_dqs_n
);
    assign IO_ddr_dq = 16'bz; assign IO_ddr_dqs = 2'bz; assign IO_ddr_dqs_n = 2'bz;
    assign O_ddr_addr = 0; assign O_ddr_ba = 0; assign O_ddr_dqm = 0;
    assign {O_ddr_cs_n, O_ddr_ras_n, O_ddr_cas_n, O_ddr_we_n} = 4'b0111;
    assign O_ddr_clk = clk_out; assign O_ddr_clk_n = ~clk_out;
    assign O_ddr_cke = init_calib_complete; assign O_ddr_odt = 1'b0; assign O_ddr_reset_n = rst_n;
    assign ddr_rst = !rst_n; assign rd_data_end = rd_data_valid;
    assign sr_ack = 1'b0; assign ref_ack = 1'b0;

    integer div = 0;
    always @(posedge memory_clk) begin
        div = div + 1;
        if (div == 2) begin div = 0; clk_out = ~clk_out; end
    end

    // aux region 0: word {9'd0, main LC, byte}; disk region 1: {4'b0001, 3'b010, w[18:1], 1'b0};
    // self-test region 3: {4'b0011, 22'd0}; hard disk {1'b1, byte}, of which the
    // first 128 KB (blocks 0-255) are kept.  Bursts of 8 words, indexed by burst.
    reg [127:0] mem [0:65535];
    integer i, errors = 0, reads = 0, writes = 0, cnt = 0, busy = 0;
    initial for (i = 0; i < 65536; i = i + 1) mem[i] = 128'd0;
    function [15:0] bidx(input [25:0] a);
        bidx = a[25] ? {2'b01, a[16:3]} : a[23] ? 16'hFFFF : a[22] ? {1'b1, a[18:4]} : {2'b00, a[16:3]};
    endfunction
    function ok(input [25:0] a);
        ok = (a[25] && a[24:17] == 8'd0) || (a[25:17] == 9'd0) ||
             (a[25:22] == 4'b0001 && a[21:19] == 3'b010) ||
             (a[25:22] == 4'b0011 && a[21:3] == 19'd0);
    endfunction

    assign cmd_ready   = init_calib_complete && busy == 0;
    assign wr_data_rdy = cmd_ready;

    reg [127:0] pipe_d [0:63];
    reg         pipe_v [0:63];
    initial for (i = 0; i < 64; i = i + 1) pipe_v[i] = 1'b0;
    integer t = 0;
    reg [127:0] cur;

    // aux_ram's 26-bit word address back out of the IP's {rank, bank, row, col}
    wire [25:0] wa = {addr[26:24], addr[22:0]};

    always @(posedge clk_out) begin
        t = t + 1;
        rd_data_valid <= 1'b0;
        if (pipe_v[t % 64]) begin
            rd_data <= pipe_d[t % 64]; rd_data_valid <= 1'b1; pipe_v[t % 64] = 1'b0;
        end
        if (!rst_n || !pll_lock) begin
            cnt = 0; init_calib_complete <= 1'b0;
        end else if (cnt < INIT_CLKS) begin
            cnt = cnt + 1;
            if (cnt == INIT_CLKS) init_calib_complete <= 1'b1;
        end
        if (cmd_en && app_burst_number != 6'd0) begin
            $display("FAIL: ddr3 IP model: app_burst_number %0d, only single bursts are modelled", app_burst_number); errors = errors + 1;
        end
        if (cmd_en) begin
            if (!cmd_ready) begin $display("FAIL: ddr3 IP model: cmd_en while not ready at %0t", $time); errors = errors + 1; end
            if (addr[2:0] != 3'd0) begin $display("FAIL: ddr3 IP model: unaligned burst %07h", addr); errors = errors + 1; end
            if (!ok(wa) || addr[27] || addr[23]) begin $display("FAIL: ddr3 IP model: address %07h outside aux_ram's regions", addr); errors = errors + 1; end
            if (cmd == 3'd0) begin
                writes = writes + 1;
                if (!wr_data_en || !wr_data_end) begin $display("FAIL: ddr3 IP model: write command without its data"); errors = errors + 1; end
                cur = mem[bidx(wa)];
                for (i = 0; i < 16; i = i + 1)
                    if (!wr_data_mask[i]) cur[8*i +: 8] = wr_data[8*i +: 8];
                if (!LOSE_WRITES) mem[bidx(wa)] = cur;
            end else begin
                reads = reads + 1;
                pipe_d[(t + RD_LAT) % 64] = mem[bidx(wa)];
                pipe_v[(t + RD_LAT) % 64] = 1'b1;
            end
            busy = 3;
        end else if (wr_data_en) begin
            $display("FAIL: ddr3 IP model: write data without a command"); errors = errors + 1;
        end
        if (busy > 0) busy = busy - 1;
    end
endmodule
