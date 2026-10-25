// ============================================================================
//  thunderclock.v -- slot 5 clock card that ProDOS takes for a Thunderclock
//
//  ProDOS 8 (1.x to 2.4) has a Thunderclock driver built in.  At boot it
//  looks for $Cn00=$08 $Cn02=$28 $Cn04=$58 $Cn06=$70 in each slot's ROM and,
//  on each time stamp, does LDA #$A3 / JSR $Cn0B (numeric mode) and
//  JSR $Cn08 (read), then parses the input buffer at $0200 as
//  "MO,DW,DD,HH,MI": high-bit ASCII digits, month at offset 0, day of week
//  (0 = Sunday) at 3, date at 6, hour at 9, minute at 12.  It has no year:
//  ProDOS infers it from the day of week and its own table, so the year it
//  shows depends on the ProDOS version.
//
//  The firmware here is this project's own (the Thunderclock ROM is
//  Thunderware's): $Cn0B returns, $Cn08 reads $C0D1 (latch the time, start
//  the string) and copies $C0D0 into $0200,X up to and including the CR of
//  "MO,0W,DD,HH,MI,SS\r", the Thunderclock's numeric format.
//
//   $C500 08 18 28 60       PHP CLC PLP RTS  (signature; PR#5 swallows output)
//   $C504 58 00 70 00                         (signature)
//   $C508 4C 10 C5  RDTCP:  JMP READ
//   $C50B 60        WRTCP:  RTS
//   $C510 AD D1 C0  READ:   LDA $C0D1
//   $C513 A2 00             LDX #$00
//   $C515 AD D0 C0  R1:     LDA $C0D0
//   $C518 9D 00 02          STA $0200,X
//   $C51B E8                INX
//   $C51C C9 8D             CMP #$8D
//   $C51E D0 F5             BNE R1
//   $C520 60                RTS
//
//  The time is set from the host (input_controller's FF 05 packet, from the
//  web page on connect) as BCD {YY, MO, DD, W, HH, MI, SS}, and counts in
//  whole seconds off the 27 MHz clock from then on.  It is not reset by
//  sys_reset, so S1 keeps it; power-off loses it (there is no battery).
//  Until set it starts at 2000-01-01, a Saturday, 00:00:00.
//  ponytail: leap years by year % 4, right for 2000-2099.
// ============================================================================

`include "src/hdmi/hdmi_defs.vh"   // VM_PIXEL_HZ: the clock
`default_nettype none

module thunderclock #(
    parameter [24:0] TICKS = `VM_PIXEL_HZ     // clocks per second
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        bus_cycle,      // cpu_go: the CPU's own cycles only
    input  wire        cpu_we,
    input  wire [15:0] addr,
    input  wire [7:0]  din,
    input  wire        set,            // load set_time (input_controller FF 05)
    input  wire [51:0] set_time,       // BCD {YY, MO, DD, W, HH, MI, SS}
    output wire [7:0]  rom_data,       // $C500-$C5FF, to slot_bus
    output wire [7:0]  io_data,        // $C0D0-$C0DF
    output wire        irq_n           // Active-low periodic interrupt
);

    function [7:0] rom(input [7:0] a);
        case (a)
            8'h00: rom = 8'h08; 8'h01: rom = 8'h18; 8'h02: rom = 8'h28; 8'h03: rom = 8'h60;
            8'h04: rom = 8'h58; 8'h06: rom = 8'h70;
            8'h08: rom = 8'h4C; 8'h09: rom = 8'h10; 8'h0A: rom = 8'hC5; 8'h0B: rom = 8'h60;
            8'h10: rom = 8'hAD; 8'h11: rom = 8'hD1; 8'h12: rom = 8'hC0; 8'h13: rom = 8'hA2;
            8'h14: rom = 8'h00; 8'h15: rom = 8'hAD; 8'h16: rom = 8'hD0; 8'h17: rom = 8'hC0;
            8'h18: rom = 8'h9D; 8'h19: rom = 8'h00; 8'h1A: rom = 8'h02; 8'h1B: rom = 8'hE8;
            8'h1C: rom = 8'hC9; 8'h1D: rom = 8'h8D; 8'h1E: rom = 8'hD0; 8'h1F: rom = 8'hF5;
            8'h20: rom = 8'h60;
            default: rom = 8'h00;
        endcase
    endfunction
    assign rom_data = rom(addr[7:0]);

    // ---- the time, in BCD ----
    reg [7:0] yy = 8'h00, mo = 8'h01, dd = 8'h01, hh = 8'h00, mi = 8'h00, ss = 8'h00;
    reg [3:0] dw = 4'd6;
    reg [24:0] cnt = 25'd0;

    function [7:0] inc(input [7:0] x);
        inc = (x[3:0] == 4'd9) ? {x[7:4] + 4'd1, 4'd0} : x + 8'd1;
    endfunction
    wire       leap = yy[4] ? (yy[3:0] == 4'd2 || yy[3:0] == 4'd6)
                            : (yy[3:0] == 4'd0 || yy[3:0] == 4'd4 || yy[3:0] == 4'd8);
    wire [7:0] last = mo == 8'h02 ? (leap ? 8'h29 : 8'h28)
                    : (mo == 8'h04 || mo == 8'h06 || mo == 8'h09 || mo == 8'h11) ? 8'h30 : 8'h31;

    always @(posedge clk) begin
        cnt <= (cnt == TICKS - 25'd1) ? 25'd0 : cnt + 25'd1;
        if (set) begin
            {yy, mo, dd, dw, hh, mi, ss} <= set_time;
            cnt <= 25'd0;
        end else if (cnt == TICKS - 25'd1) begin
            ss <= inc(ss);
            if (ss == 8'h59) begin
                ss <= 8'h00; mi <= inc(mi);
                if (mi == 8'h59) begin
                    mi <= 8'h00; hh <= inc(hh);
                    if (hh == 8'h23) begin
                        hh <= 8'h00;
                        dw <= (dw == 4'd6) ? 4'd0 : dw + 4'd1;
                        dd <= inc(dd);
                        if (dd == last) begin
                            dd <= 8'h01; mo <= inc(mo);
                            if (mo == 8'h12) begin
                                mo <= 8'h01;
                                yy <= (yy == 8'h99) ? 8'h00 : inc(yy);
                            end
                        end
                    end
                end
            end
        end
    end

    // ---- the string, from a copy latched at $C0D1 so it cannot tick mid-read ----
    reg [43:0] snap = 44'd0;            // {MO, DD, W, HH, MI, SS}
    reg [4:0]  idx  = 5'd0;
    wire [7:0] s_mo = snap[43:36], s_dd = snap[35:28], s_hh = snap[23:16],
               s_mi = snap[15:8],  s_ss = snap[7:0];
    wire [3:0] s_dw = snap[27:24];
    function [7:0] dig(input [3:0] n); dig = {4'hB, n}; endfunction
    reg [7:0] ch;
    always @(*)
        case (idx)
            5'd0:  ch = dig(s_mo[7:4]);  5'd1:  ch = dig(s_mo[3:0]);
            5'd3:  ch = dig(4'd0);       5'd4:  ch = dig(s_dw);
            5'd6:  ch = dig(s_dd[7:4]);  5'd7:  ch = dig(s_dd[3:0]);
            5'd9:  ch = dig(s_hh[7:4]);  5'd10: ch = dig(s_hh[3:0]);
            5'd12: ch = dig(s_mi[7:4]);  5'd13: ch = dig(s_mi[3:0]);
            5'd15: ch = dig(s_ss[7:4]);  5'd16: ch = dig(s_ss[3:0]);
            5'd17: ch = 8'h8D;                                  // CR ends it
            default: ch = 8'hAC;                                // ","
        endcase
    localparam [24:0] TICK_64HZ = (TICKS >= 25'd64) ? (TICKS / 25'd64) : 25'd1;
    reg [24:0] tick_64_cnt = 25'd0;
    reg        irq_en      = 1'b0;
    reg        irq_flag    = 1'b0;

    assign io_data = (addr[3:0] == 4'h0) ? ch :
                     (addr[3:0] == 4'h2) ? {irq_flag, 7'b0000000} :
                     (addr[3:0] == 4'h3) ? {irq_en, 7'b0000000} : 8'h00;

    assign irq_n = !(irq_en && irq_flag);

    wire io_hit = bus_cycle && addr[15:4] == 12'hC0D;
    always @(posedge clk) begin
        if (reset) begin
            tick_64_cnt <= 25'd0;
            irq_en      <= 1'b0;
            irq_flag    <= 1'b0;
        end else begin
            if (tick_64_cnt >= TICK_64HZ - 25'd1) begin
                tick_64_cnt <= 25'd0;
                if (irq_en) irq_flag <= 1'b1;
            end else begin
                tick_64_cnt <= tick_64_cnt + 25'd1;
            end

            if (io_hit) begin
                if (!cpu_we) begin
                    // Reading $C0D2 clears pending interrupt flag
                    if (addr[3:0] == 4'h2) irq_flag <= 1'b0;
                end else begin
                    // Writing $C0D2 sets/clears interrupt enable
                    if (addr[3:0] == 4'h2) begin
                        irq_en <= din[0];
                        if (!din[0]) irq_flag <= 1'b0;
                    end
                    // Writing $C0D3 clears interrupt flag
                    if (addr[3:0] == 4'h3) irq_flag <= 1'b0;
                end
            end
        end

        if (io_hit && addr[3:0] == 4'h1) begin
            snap <= {mo, dd, dw, hh, mi, ss};
            idx  <= 5'd0;
        end else if (io_hit && addr[3:0] == 4'h0 && !cpu_we && idx != 5'd17)
            idx <= idx + 5'd1;
    end

endmodule

`default_nettype wire
