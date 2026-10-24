// Mockingboard "C" Stereo Sound Card for Apple //e Slot 4
// Instantiates dual 6522 VIAs and dual AY-3-8910 PSGs.
// VIA 1 / PSG 1: Left channel (mapped to $C400-$C47F and $C0C0-$C0C7)
// VIA 2 / PSG 2: Right channel (mapped to $C480-$C4FF and $C0C8-$C0CF)
`default_nettype none

module mockingboard_card (
    input  wire        clk,         // 27.0 MHz system clock
    input  wire        reset,       // Active-high reset
    input  wire        ce_1m,       // 1.023 MHz clock enable
    input  wire        bus_cycle,   // CPU/debugger bus cycle
    input  wire        cpu_we,      // CPU write enable
    input  wire [15:0] addr,        // Effective CPU address
    input  wire [7:0]  din,         // Data from CPU bus
    input  wire        devsel_n,    // Slot 4 /DEVSEL ($C0C0-$C0CF)
    input  wire        iosel_n,     // Slot 4 /IOSEL ($C400-$C4FF)

    output wire [7:0]  dout,        // Data to CPU read bus
    output wire        irq_n,       // Active-low composite /IRQ

    output wire signed [15:0] audio_left,  // Left audio (PSG 1)
    output wire signed [15:0] audio_right  // Right audio (PSG 2)
);

    // -------------------------------------------------------------------------
    // Slot 4 Address Decode
    // -------------------------------------------------------------------------
    // $C400-$C4FF (/IOSEL low):
    //   addr[7] == 0: $C400-$C47F => VIA 1 (Left)
    //   addr[7] == 1: $C480-$C4FF => VIA 2 (Right)
    // $C0C0-$C0CF (/DEVSEL low):
    //   addr[3] == 0: $C0C0-$C0C7 => VIA 1 (Left)
    //   addr[3] == 1: $C0C8-$C0CF => VIA 2 (Right)
    wire via1_sel = (!iosel_n && !addr[7]) || (!devsel_n && !addr[3]);
    wire via2_sel = (!iosel_n &&  addr[7]) || (!devsel_n &&  addr[3]);

    wire [3:0] via1_rs = !iosel_n ? addr[3:0] : {1'b0, addr[2:0]};
    wire [3:0] via2_rs = !iosel_n ? addr[3:0] : {1'b0, addr[2:0]};

    wire [7:0] via1_dout;
    wire [7:0] via2_dout;

    assign dout = via1_sel ? via1_dout :
                  via2_sel ? via2_dout : 8'h00;

    // -------------------------------------------------------------------------
    // VIA 1 & PSG 1 (Left Channel)
    // -------------------------------------------------------------------------
    wire [7:0] via1_port_a_out;
    wire [7:0] via1_port_a_in;
    wire [7:0] via1_port_b_out;
    wire [7:0] via1_ddrb;
    wire       via1_irq_n;

    wire [7:0] psg1_da_out;

    via6522 u_via1 (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .bus_cycle(bus_cycle),
        .cs(via1_sel),
        .we(cpu_we),
        .rs(via1_rs),
        .din(din),
        .dout(via1_dout),
        .irq_n(via1_irq_n),

        .port_a_in(via1_port_a_in),
        .port_a_out(via1_port_a_out),
        .port_a_oe(),

        .port_b_in(8'h00),
        .port_b_out(via1_port_b_out),
        .port_b_oe(via1_ddrb)
    );

    assign via1_port_a_in = psg1_da_out;

    // PB2 is the AY's /RESET, as on the card (and in MAME and AppleWin):
    // software writes $04 for "inactive" and $00 to reset.  A port B pin
    // set as an input floats high, so the AY is only reset once DDRB drives
    // PB2.  Registered (below), since it is the AY's asynchronous reset.
    reg psg1_reset = 1'b1, psg2_reset = 1'b1;
    wire psg1_bdir  = via1_port_b_out[1];
    wire psg1_bc1   = via1_port_b_out[0];

    ay8910 u_psg1 (
        .clk(clk),
        .reset(psg1_reset),
        .ce_1m(ce_1m),
        .bdir(psg1_bdir),
        .bc1(psg1_bc1),
        .da_in(via1_port_a_out),
        .da_out(psg1_da_out),

        .channel_a(),
        .channel_b(),
        .channel_c(),
        .audio_mix(audio_left)
    );

    // -------------------------------------------------------------------------
    // VIA 2 & PSG 2 (Right Channel)
    // -------------------------------------------------------------------------
    wire [7:0] via2_port_a_out;
    wire [7:0] via2_port_a_in;
    wire [7:0] via2_port_b_out;
    wire [7:0] via2_ddrb;
    wire       via2_irq_n;

    wire [7:0] psg2_da_out;

    via6522 u_via2 (
        .clk(clk),
        .reset(reset),
        .ce_1m(ce_1m),
        .bus_cycle(bus_cycle),
        .cs(via2_sel),
        .we(cpu_we),
        .rs(via2_rs),
        .din(din),
        .dout(via2_dout),
        .irq_n(via2_irq_n),

        .port_a_in(via2_port_a_in),
        .port_a_out(via2_port_a_out),
        .port_a_oe(),

        .port_b_in(8'h00),
        .port_b_out(via2_port_b_out),
        .port_b_oe(via2_ddrb)
    );

    assign via2_port_a_in = psg2_da_out;

    wire psg2_bdir  = via2_port_b_out[1];
    wire psg2_bc1   = via2_port_b_out[0];

    ay8910 u_psg2 (
        .clk(clk),
        .reset(psg2_reset),
        .ce_1m(ce_1m),
        .bdir(psg2_bdir),
        .bc1(psg2_bc1),
        .da_in(via2_port_a_out),
        .da_out(psg2_da_out),

        .channel_a(),
        .channel_b(),
        .channel_c(),
        .audio_mix(audio_right)
    );

    always @(posedge clk) begin
        psg1_reset <= reset || (via1_ddrb[2] && !via1_port_b_out[2]);
        psg2_reset <= reset || (via2_ddrb[2] && !via2_port_b_out[2]);
    end

    // -------------------------------------------------------------------------
    // Composite Interrupt (wired-OR active-low /IRQ)
    // -------------------------------------------------------------------------
    assign irq_n = via1_irq_n & via2_irq_n;

endmodule

`default_nettype wire
