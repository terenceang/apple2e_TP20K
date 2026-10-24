// ============================================================================
//  gowin_prims.v -- behavioural stand-ins for the Gowin primitives in top.v
//  (and ALU54D, the DSP adder src/audio_filter.v accumulates in)
//
//  Yosys' gowin/cells_sim.v declares rPLL, CLKDIV and OSER10 as empty port
//  shells, so top.v cannot be simulated with it.  These models implement
//  only what top.v uses, per Gowin UG286 (clocking) and UG289 (OSER10:
//  D0 is shifted out first, two bits per FCLK cycle, the parallel word is
//  loaded on PCLK).  Simulation only.
// ============================================================================
`timescale 1ps / 1ps
`default_nettype none

// CLKOUT = CLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1), CLKOUTD = CLKOUT / DYN_SDIV_SEL, measured from the input
// period after two edges; LOCK rises a few input cycles later.
module rPLL #(
    parameter FCLKIN = "100.0", parameter DEVICE = "GW2A-18",
    parameter integer IDIV_SEL = 0, parameter integer FBDIV_SEL = 0,
    parameter integer ODIV_SEL = 8, parameter integer DYN_SDIV_SEL = 2,
    // accepted and ignored: phase (CLKOUTP is CLKOUT here), duty, sources
    parameter PSDA_SEL = "0000", parameter DUTYDA_SEL = "1000",
    parameter CLKOUTD_SRC = "CLKOUT", parameter CLKFB_SEL = "internal",
    parameter DYN_IDIV_SEL = "false", parameter DYN_FBDIV_SEL = "false",
    parameter DYN_ODIV_SEL = "false", parameter DYN_DA_EN = "false"
) (
    input  wire CLKIN, CLKFB, RESET, RESET_P,
    input  wire [5:0] FBDSEL, IDSEL, ODSEL,
    input  wire [3:0] PSDA, DUTYDA, FDLY,
    output reg  CLKOUT = 1'b0,
    output wire CLKOUTP, CLKOUTD, CLKOUTD3,
    output reg  LOCK = 1'b0
);
    realtime t_last = 0, t_in = 0;
    integer  edges = 0;
    always @(posedge CLKIN) begin
        if (t_last > 0) t_in = $realtime - t_last;
        t_last = $realtime;
        edges  = edges + 1;
        if (edges == 8) LOCK <= 1'b1;
    end
    // Start the output in phase with an input edge once the period is known.
    initial begin
        wait (t_in > 0);
        @(posedge CLKIN);
        forever #(t_in * (IDIV_SEL + 1) / (FBDIV_SEL + 1) / 2.0) CLKOUT = ~CLKOUT;
    end
    assign CLKOUTP = CLKOUT;
    // CLKOUTD = CLKOUT / DYN_SDIV_SEL (even divisors only, all this design uses)
    reg     clkoutd_r = 1'b0;
    integer sdiv = 0;
    always @(posedge CLKOUT) begin
        sdiv = sdiv + 1;
        if (sdiv == DYN_SDIV_SEL / 2) begin sdiv = 0; clkoutd_r = ~clkoutd_r; end
    end
    assign CLKOUTD = clkoutd_r;
    assign CLKOUTD3 = 1'b0;
endmodule

module CLKDIV #(parameter DIV_MODE = "2", parameter GSREN = "false") (
    input  wire HCLKIN, RESETN, CALIB,
    output reg  CLKOUT = 1'b0
);
    localparam integer N = (DIV_MODE == "5") ? 5 : (DIV_MODE == "4") ? 4 :
                           (DIV_MODE == "3.5") ? 0 : 2;
    // Divide by N, 50 % duty to the nearest half cycle: toggle on both edges.
    integer ph = 0;
    always @(HCLKIN) begin
        if (!RESETN) begin
            ph = 0; CLKOUT = 1'b0;
        end else begin
            ph = ph + 1;
            if (ph == N) begin ph = 0; CLKOUT = ~CLKOUT; end
        end
    end
endmodule

module OSER10 #(parameter GSREN = "false", parameter LSREN = "true") (
    input  wire D0, D1, D2, D3, D4, D5, D6, D7, D8, D9,
    input  wire FCLK, PCLK, RESET,
    output wire Q
);
    reg [9:0] word = 10'd0, shift = 10'd0;
    reg [3:0] n = 4'd0;
    reg       load = 1'b0;
    always @(posedge PCLK) begin
        word <= {D9, D8, D7, D6, D5, D4, D3, D2, D1, D0};
        load <= 1'b1;
    end
    // Shift on both FCLK edges; reload after every tenth bit.
    always @(FCLK) begin
        if (RESET) begin
            shift = 10'd0; n = 4'd0;
        end else if (n == 4'd0 && load) begin
            shift = word; n = 4'd9;
        end else begin
            shift = shift >> 1;
            if (n != 0) n = n - 4'd1;
        end
    end
    assign Q = shift[0];
endmodule

module TLVDS_OBUF (input wire I, output wire O, output wire OB);
    assign O  = I;
    assign OB = ~I;
endmodule

// ALU54D, the DSP block's 54-bit adder, in the shape src/audio_filter.v uses
// it (Gowin's simlib/gw2a/prim_sim.v has the whole thing): ALUD_MODE 0, the
// output registered, inputs not:  DOUT <= (ACCLOAD ? DOUT : 0) +/- B +/- A,
// A and B sign-extended by ASIGN/BSIGN.  RESET synchronous.
module ALU54D #(parameter AREG = 1'b0, BREG = 1'b0, ASIGN_REG = 1'b0, BSIGN_REG = 1'b0,
                parameter ACCLOAD_REG = 1'b0, OUT_REG = 1'b1, B_ADD_SUB = 1'b0, C_ADD_SUB = 1'b0,
                parameter ALUD_MODE = 0, ALU_RESET_MODE = "SYNC") (
    output wire [53:0] DOUT, output wire [54:0] CASO,
    input  wire [53:0] A, B, input wire [54:0] CASI,
    input  wire ACCLOAD, ASIGN, BSIGN, CLK, CE, RESET
);
    reg  [54:0] q = 55'd0;
    wire [54:0] ae = {ASIGN & A[53], A}, be = {BSIGN & B[53], B};
    always @(posedge CLK)
        if (RESET) q <= 55'd0;
        else if (CE) q <= (ACCLOAD ? q : 55'd0) + (B_ADD_SUB ? -be : be) + (C_ADD_SUB ? -ae : ae);
    assign DOUT = q[53:0];
    assign CASO = q;
endmodule

`default_nettype wire
