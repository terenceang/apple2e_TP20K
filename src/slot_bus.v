// Apple //e slot bus -- the motherboard half of the 6502 peripheral architecture
//
// This is scaffolding, not cards.  It owns the decode and interrupt wiring the
// //e motherboard provides, so a card is later a matter of driving the card-side
// inputs and adding a card module, instead of re-deriving the //e's address and
// interrupt rules inside apple2_core.  There are no cards yet: apple2_core ties
// every card_* input inactive, so the bus is idle and $C100-$CFFF behaves
// exactly as before (internal ROM, or $00 for an empty slot).
//
// What the real //e bus carries, and what this module does with it:
//
//   Address decode, driven by the motherboard, active low to the card:
//     /DEVSEL  $C080+0x10n   the card in slot n is selected for I/O, so slot
//                            n's 16 bytes are $C08(n+8)0-$C08(n+8)F: slot 1
//                            is $C090-$C09F, slot 6 (a Disk II) $C0E0-$C0EF,
//                            slot 7 $C0F0-$C0FF.  Only slots 1-7 exist:
//                            $C000-$C07F is the motherboard's own (keyboard,
//                            speaker, video, paddles), and $C080-$C08F is the
//                            language card, called "slot 8" for the address
//                            it occupies, so neither strobes a card.
//     /IOSEL   $Cn00-$CnFF   the card in slot n is selected for its 256-byte
//                            on-board ROM, and (if it has one) it claims the
//                            $C800 expansion space, which it then holds until
//                            the $CFFF /IOSTROBE pulse.  That claim is latched
//                            here, in c8_owner, because it is bus state, not
//                            softswitch state.
//     $C800-$CFFF            the 2 KB shared expansion space, served by the
//                            claiming card, or by the //e motherboard itself
//                            when INTC8ROM is on (set by a $C3xx access with
//                            SLOTC3ROM off, cleared by $CFFF).  Both of those
//                            rules are in apple2_core; intc8rom comes in here
//                            so this module can keep the card out of the way
//                            when the motherboard owns the space.
//
//   Interrupts.  /IRQ is a daisy chain of INT IN/INT OUT, one link per slot,
//   slots in increasing priority order with slot 1 highest: INT IN -> slot 1
//   -> ... -> slot 7 -> the CPU.  A slot passes the chain on only if it is not
//   asserting its own request, so a card does not see another card's interrupt
//   unless it has released the chain itself.  /NMI and /DMA are not chained:
//   they are shared lines, wired-OR across every card.
//
// A note on qualification: the decode runs on `bus_cycle`, which the caller
// builds as "a real bus cycle, CPU or debugger" (cpu_go, or the debugger's
// turn of the bus).  The softswitch block in apple2_core uses cpu_go directly
// because a switch must not re-fire on a stalled cycle; here a strobe to a card
// is harmless if the address is held, and gating on bus_cycle keeps one
// definition of "is this address really being accessed".

`default_nettype none

module slot_bus (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        bus_cycle,     // a real bus cycle (CPU, or the debugger)
    input  wire [15:0] addr,          // effective CPU address this cycle

    // Softswitch state, owned by apple2_core
    input  wire        intcxrom,      // $C006/$C007: internal $C100-$CFFF on
    input  wire        slotc3rom,     // $C00A/$C00B: slot 3's $C300 to the card
    input  wire        intc8rom,      // a $C3xx access claimed $C800 internally

    // Card side, indexed by slot number minus one, so index 0 is slot 1 and
    // index 6 is slot 7: the same indexing the strobes use.  The *_n lines are
    // active low, as on the real bus.  Nothing drives these yet.
    input  wire [6:0]  card_present,  // a card is installed in the slot
    input  wire [6:0]  card_exprom,   // it has a 2 KB $C800 expansion ROM
    input  wire [6:0][7:0] card_data, // the byte each card puts on the bus
    input  wire        int_in_n,      // /IRQ into slot 1 (1 = nothing pending)
    input  wire [6:0]  card_irq_n,    // per-slot /IRQ request
    input  wire [6:0]  card_nmi_n,    // per-slot /NMI (shared line, wired-OR)
    input  wire [6:0]  card_dma_n,    // per-slot /DMA (shared line, wired-OR)

    // Strobes the motherboard drives, active low
    output wire [6:0]  devsel_n,      // /DEVSEL to slots 1-7
    output wire [6:0]  iosel_n,       // /IOSEL to slots 1-7
    output wire [6:0]  irq_out_n,     // /IRQ OUT of each slot (daisy chain)
    output wire        iostrobe_n,    // /IOSTROBE: a $CFFF cycle releases $C800

    // Arbitration of the $C100-$CFFF read bus, consumed by apple2_core's
    // cpu_din mux: the internal ROM when int_rom_sel, else slot_dout ($00 when
    // no card answers, which is what an empty slot's floating bus reads as).
    output wire        int_rom_sel,   // the internal ROM answers this access
    output wire [7:0]  slot_dout,

    // The lines back to the CPU.  /IRQ is what is left of the daisy chain,
    // /NMI the wired-OR of the cards (the 65C02 does its own edge detection),
    // /DMA reserved and not used by anything yet.
    output wire        irq_n,
    output wire        nmi_n,
    output wire        dma_n
);

    localparam integer NSLOT = 7;

    // ------------------------------------------------------------------
    // DEVSEL and IOSEL decode
    // ------------------------------------------------------------------
    // A slot's I/O space is $C080 + 0x10n, so the group index is the address's
    // bits [7:4] with 9 subtracted: slot 1 is group 9 ($C090-$C09F), slot 6
    // (where a Disk II lives) group E ($C0E0-$C0EF), slot 7 group F
    // ($C0F0-$C0FF).  Groups 0-7 are the motherboard's own I/O -- keyboard,
    // speaker, video switches, paddles -- and group 8 is the language card,
    // so nothing below group 9 strobes a card.
    wire [3:0] devsel_idx  = addr[7:4] - 4'h9;
    wire       devsel_real = (addr[7:4] >= 4'h9);   // groups 9-F => slots 1-7

    // A slot's on-board ROM is $Cn00-$CnFF, indexed the same way by bits [11:8].
    wire [3:0] iosel_idx = addr[11:8] - 4'h1;
    wire       iosel_real = (iosel_idx < 4'd7);

    wire devsel_hit = bus_cycle && (addr[15:8] == 8'hC0) && devsel_real;
    wire iosel_hit  = bus_cycle && (addr[15:12] == 4'hC) && iosel_real;

    // A $CFFF access is the /IOSTROBE pulse that tells the claiming card to
    // give up $C800.  It fires on a read or a write, like the real bus.
    wire iostrobe_hit = bus_cycle && (addr == 16'hCFFF);

    genvar s;
    generate
        for (s = 0; s < NSLOT; s = s + 1) begin : g_strobe
            assign devsel_n[s] = !(devsel_hit && (devsel_idx == s));
            assign iosel_n[s]  = !(iosel_hit  && (iosel_idx  == s));
        end
    endgenerate

    assign iostrobe_n = !iostrobe_hit;

    // ------------------------------------------------------------------
    // Who owns the $C800 expansion space
    // ------------------------------------------------------------------
    // A card claims the space by being selected (/IOSEL low) while it has
    // expansion ROM, and holds it until the /IOSTROBE pulse.  The claim is
    // cleared by $CFFF; a new claim overwrites an older one, as on the bus.
    // INTCXROM does not gate the claim: on a real //e the card still sees
    // /IOSEL and still latches, it just loses the bus to the internal ROM.
    wire c8_claim_hit = iosel_hit && card_present[iosel_idx] && card_exprom[iosel_idx];

    reg [2:0] c8_owner;          // 0 = nobody, 1-7 = the slot that holds it
    always @(posedge clk or posedge reset) begin
        if (reset)
            c8_owner <= 3'd0;
        else if (bus_cycle) begin
            if (iostrobe_hit)
                c8_owner <= 3'd0;
            else if (c8_claim_hit)
                c8_owner <= iosel_idx + 4'd1;
        end
    end

    // ------------------------------------------------------------------
    // Read-bus arbitration for $C100-$CFFF
    // ------------------------------------------------------------------
    wire is_c3    = (addr[15:8] == 8'hC3);
    wire is_c8    = (addr[15:12] == 4'hC) && (addr[11:8] >= 4'h8);

    // The motherboard's internal ROM answers $C100-$CFFF whenever INTCXROM is
    // on, and otherwise keeps $C3xx while SLOTC3ROM is off (the 80-column
    // firmware) and $C800-$CFFF while INTC8ROM is on.  Same rule as before this
    // module existed, expressed once here so the card path can be layered on
    // without the core having to know a card is there.
    assign int_rom_sel = intcxrom || (is_c3 && !slotc3rom) || (is_c8 && intc8rom);

    // Which card answers, as a slot number (0 = nobody, so the bus floats).
    reg [2:0] rom_owner;
    always @(*) begin
        if (intcxrom)                          rom_owner = 3'd0;
        else if (is_c8)                         rom_owner = c8_owner;
        else if (is_c3)                         rom_owner = slotc3rom ? 3'd3 : 3'd0;
        else if (iosel_real && (addr[15:12] == 4'hC)) rom_owner = iosel_idx + 4'd1;
        else                                    rom_owner = 3'd0;
    end

    // rom_owner is a slot number and the card vectors are indexed from slot 1
    // at zero, so the bus index is one less.  rom_owner 0 wraps to 7, which is
    // out of range for the card vectors: the select below takes the 0 case
    // first, so nothing is ever read from a card that is not there.
    wire [2:0] rom_idx    = rom_owner - 3'd1;
    wire       have_card  = (rom_owner != 3'd0) ? card_present[rom_idx] : 1'b0;
    assign slot_dout = have_card ? card_data[rom_idx] : 8'h00;

    // ------------------------------------------------------------------
    // Interrupts
    // ------------------------------------------------------------------
    // /IRQ daisy chain: chain[i] is INT IN of slot i+1, chain[NSLOT] is what
    // the CPU sees.  A slot without a card passes the chain on untouched; a
    // slot with one passes it on only while the card is not asserting, so the
    // card's own request reaches the CPU and the rest of the chain is blocked.
    wire [NSLOT:0] chain;
    assign chain[0] = int_in_n;
    genvar c;
    generate
        for (c = 0; c < NSLOT; c = c + 1) begin : g_irq
            wire idle   = ~card_present[c] | card_irq_n[c];
            assign chain[c + 1] = chain[c] & idle;
            assign irq_out_n[c] = chain[c + 1];
        end
    endgenerate
    assign irq_n = chain[NSLOT];

    // /NMI and /DMA are shared, not chained: any card holding the line low
    // takes it, and only a populated slot can do that.  /NMI reaches the 65C02
    // directly; it does its own edge detection.
    wire nmi_low = |((~card_nmi_n) & card_present);
    wire dma_low = |((~card_dma_n) & card_present);
    assign nmi_n = ~nmi_low;
    assign dma_n = ~dma_low;
endmodule

`default_nettype wire
