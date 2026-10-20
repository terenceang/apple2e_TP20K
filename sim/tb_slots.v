`timescale 1ns / 1ps
`default_nettype none

//  tb_slots.v -- src/slot_bus.v, the //e's peripheral bus decode
//
//  There are no cards in the design, so the card side of slot_bus is only ever
//  tied inactive and nothing on real hardware exercises the decode.  This
//  testbench therefore drives slot_bus directly with fake cards, so the
//  motherboard's half of the bus is checked properly: the /DEVSEL and /IOSEL
//  strobes per slot, the $C3xx SLOTC3ROM rule, the $C800 expansion-space claim
//  and its $CFFF release, the read-bus arbitration, and the /IRQ daisy chain
//  and the shared /NMI and /DMA lines.
//
//  The no-card behaviour through apple2_core (the internal ROM when INTCXROM is
//  on, $00 in an empty slot, the C3xx/INTC8ROM/$CFFF rules) is tb_auxsw's job,
//  and it now checks that through slot_bus.

module tb_slots;
    // The clock is stepped by hand rather than free-running, so that the only
    // clock edges a test can produce are the ones it means to: bus() is a real
    // access and may change the held $C800 claim, look() only presents an
    // address and must not.
    reg clk = 1'b0;

    reg         reset = 1'b1;
    reg         bus_cycle = 1'b0;
    reg  [15:0] addr = 16'd0;
    reg         intcxrom = 1'b1;
    reg         slotc3rom = 1'b0;
    reg         intc8rom = 1'b0;

    // The inactive level of every per-slot active-low line.  Named, and
    // emphatically not 7'd7: that is decimal seven, 7'b0000111, which leaves
    // slot 4 asserting -- it reads like "all ones" and is not.
    localparam [6:0] LINE_IDLE = 7'h7F;
    // A card drives one *byte*, so card_data is a byte per slot, not a bit.
    // Flat here because a packed localparam is SystemVerilog, and this bench
    // builds as -g2005: 7 cards x 8 bits.
    localparam [55:0] NO_DATA = 56'd0;

    // Fake cards.  Index 0 is slot 1, so the vectors are indexed from the slot
    // number minus one.  Every populated slot drives a distinct byte, so a
    // check expecting one slot's byte also proves the mux did not pick a
    // neighbour: the byte for slot n is 8'h40 + (n - 1).
    reg [6:0] card_present = 7'd0;
    reg [6:0] card_exprom  = 7'd0;
    reg [6:0][7:0] card_data = NO_DATA;
    reg       int_in_n     = 1'b1;
    reg [6:0] card_irq_n   = LINE_IDLE;
    reg [6:0] card_nmi_n   = LINE_IDLE;
    reg [6:0] card_dma_n   = LINE_IDLE;

    wire [6:0] devsel_n;
    wire [6:0] iosel_n;
    wire [6:0] irq_out_n;
    wire       iostrobe_n;
    wire       int_rom_sel;
    wire [7:0] slot_dout;
    wire       irq_n;
    wire       nmi_n;
    wire       dma_n;

    slot_bus dut (
        .clk(clk), .reset(reset),
        .bus_cycle(bus_cycle), .addr(addr),
        .intcxrom(intcxrom), .slotc3rom(slotc3rom), .intc8rom(intc8rom),
        .card_present(card_present), .card_exprom(card_exprom), .card_data(card_data),
        .int_in_n(int_in_n), .card_irq_n(card_irq_n),
        .card_nmi_n(card_nmi_n), .card_dma_n(card_dma_n),
        .devsel_n(devsel_n), .iosel_n(iosel_n), .irq_out_n(irq_out_n),
        .iostrobe_n(iostrobe_n),
        .int_rom_sel(int_rom_sel), .slot_dout(slot_dout),
        .irq_n(irq_n), .nmi_n(nmi_n), .dma_n(dma_n)
    );

    integer fails = 0;
    integer checks = 0;

    task check(input [1023:0] what, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin
                $display("FAIL: %0s", what);
                fails = fails + 1;
            end
        end
    endtask

    task tick;
        begin
            clk = 1'b1; #1;
            clk = 1'b0; #1;
        end
    endtask

    // A real bus access to addr: the strobes and the claim register both see
    // it, then the bus is released so the held state can be inspected.  The
    // #1 before the edge is the address setup time: on hardware the decode is
    // settled long before the clock arrives, and in simulation raising clk in
    // the same time step as addr would let the register sample a stale decode.
    task bus(input [15:0] a);
        begin
            bus_cycle = 1'b1; addr = a;
            #1;
            tick;
            bus_cycle = 1'b0; #1;
        end
    endtask

    // Put an address on the bus with no clock edge, to look at the strobes
    // and the read mux without being able to change any held state.
    task look(input [15:0] a);
        begin
            bus_cycle = 1'b1; addr = a; #1;
        end
    endtask

    task settle; begin bus_cycle = 1'b0; #1; end endtask

    // The byte a populated slot n must return.
    function [7:0] card_byte(input integer n); card_byte = 8'h40 + (n - 1); endfunction

    // Exactly one strobe asserted, on the given slot (0 = none asserted).
    task check_one(input [6:0] strb, input integer slot, input [1023:0] what);
        integer i;
        begin
            for (i = 0; i < 7; i = i + 1) begin
                if (slot == 0) check(what, strb[i] === 1'b1);
                else if (i == slot - 1) check(what, strb[i] === 1'b0);
                else check(what, strb[i] === 1'b1);
            end
        end
    endtask

    initial begin
        #200; tick;                    // an edge under reset clears the claim
        reset = 1'b0; #1;

        // Nothing plugged in at all.  This is the same state apple2_core ties
        // the card side to, and it is checked first on purpose: with every line
        // idle the bus must be quiet and the shared lines high.  A tie that
        // reads like all-ones but is not (7'd7) asserts one slot, and the
        // symptom shows up as a dead /IRQ chain in every later check.
        check("no cards: /IRQ is high", irq_n === 1'b1);
        check("no cards: /NMI is high", nmi_n === 1'b1);
        check("no cards: /DMA is high", dma_n === 1'b1);
        check("no cards: INT OUT of every slot is high", irq_out_n === 7'h7F);
        // The card vectors must be wide enough for the mux to be meaningful:
        // one byte per slot, addressed by slot number minus one.
        card_present[4] = 1'b1;
        card_data[4]    = 8'h5A;
        intcxrom        = 1'b0;
        look(16'hC500);
        check("no cards: slot 5's byte comes back, 8 bits of it",
              slot_dout === 8'h5A);
        // A byte sitting on the data vector of a slot with no card in it must
        // not reach the bus: that is what makes the $00 float correct.
        card_present = 7'd0;
        intcxrom     = 1'b0;
        look(16'hC500);
        check("an absent slot's byte does not reach the bus", slot_dout === 8'h00);
        card_data = NO_DATA;
        intcxrom  = 1'b1;

        // ---- /DEVSEL: slot n owns $C080+0x10n ----
        // The real //e map: slot n's sixteen bytes are $C08(n+8)0-$C08(n+8)F,
        // so a Disk II in slot 6 is at $C0E0-$C0EF and a hard disk in slot 7
        // at $C0F0-$C0FF.  The whole range is checked, because the decode this
        // bench pins used to have slot n at $C0n0, which put "slot 6" on the
        // paddles and left $C0E0-$C0FF -- where the //e boot ROM reads a
        // sector from -- strobing nothing at all.
        look(16'hC090); check_one(devsel_n, 1, "DEVSEL slot 1 at $C090");
        look(16'hC09F); check_one(devsel_n, 1, "DEVSEL slot 1 at $C09F");
        look(16'hC0A8); check_one(devsel_n, 2, "DEVSEL slot 2 at $C0A8");
        look(16'hC0B0); check_one(devsel_n, 3, "DEVSEL slot 3 at $C0B0");
        look(16'hC0C7); check_one(devsel_n, 4, "DEVSEL slot 4 at $C0C7");
        look(16'hC0D0); check_one(devsel_n, 5, "DEVSEL slot 5 at $C0D0");
        look(16'hC0E0); check_one(devsel_n, 6, "DEVSEL slot 6 at $C0E0");
        look(16'hC0EC); check_one(devsel_n, 6, "DEVSEL slot 6 at the data register");
        look(16'hC0EE); check_one(devsel_n, 6, "DEVSEL slot 6 at $C0EE");
        look(16'hC0F0); check_one(devsel_n, 7, "DEVSEL slot 7 at $C0F0");
        look(16'hC0FF); check_one(devsel_n, 7, "DEVSEL slot 7 at $C0FF");
        // $C000-$C07F is the motherboard's own I/O and $C080-$C08F is the
        // language card, which occupies the address a "slot 8" would have
        // but is not a card slot: none of it strobes.
        look(16'hC000); check_one(devsel_n, 0, "DEVSEL quiet in $C000");
        look(16'hC010); check_one(devsel_n, 0, "DEVSEL quiet in $C010");
        look(16'hC030); check_one(devsel_n, 0, "DEVSEL quiet at the speaker");
        look(16'hC05A); check_one(devsel_n, 0, "DEVSEL quiet in the video switches");
        look(16'hC064); check_one(devsel_n, 0, "DEVSEL quiet at the paddles");
        look(16'hC070); check_one(devsel_n, 0, "DEVSEL quiet in $C070");
        look(16'hC080); check_one(devsel_n, 0, "DEVSEL quiet in the language card");
        look(16'hC08F); check_one(devsel_n, 0, "DEVSEL quiet at the end of the language card");
        look(16'hC100); check_one(devsel_n, 0, "DEVSEL quiet in the slot ROM");

        // ---- /IOSEL: slot n owns $Cn00-$CnFF ----
        look(16'hC100); check_one(iosel_n, 1, "IOSEL slot 1 at $C100");
        look(16'hC3FF); check_one(iosel_n, 3, "IOSEL slot 3 at $C3FF");
        look(16'hC500); check_one(iosel_n, 5, "IOSEL slot 5 at $C500");
        look(16'hC700); check_one(iosel_n, 7, "IOSEL slot 7 at $C700");
        look(16'hC800); check_one(iosel_n, 0, "IOSEL quiet in $C800");
        look(16'hC010); check_one(iosel_n, 0, "IOSEL quiet in $C0xx");
        settle;

        // ---- /IOSTROBE: a $CFFF access releases the expansion space ----
        look(16'hCFFF); check("IOSTROBE on $CFFF", iostrobe_n === 1'b0);
        look(16'hC800); check("IOSTROBE off $C800", iostrobe_n === 1'b1);
        look(16'hC100); check("IOSTROBE off $C100", iostrobe_n === 1'b1);
        settle;

        // ---- INTCXROM owns the whole of $C100-$CFFF, strobes or not ----
        intcxrom = 1'b1;
        look(16'hC100); check("INTCXROM: internal at $C100", int_rom_sel === 1'b1);
        look(16'hC300); check("INTCXROM: internal at $C300", int_rom_sel === 1'b1);
        look(16'hC500); check("INTCXROM: internal at $C500", int_rom_sel === 1'b1);
        look(16'hC800); check("INTCXROM: internal at $C800", int_rom_sel === 1'b1);
        look(16'hCFFF); check("INTCXROM: internal at $CFFF", int_rom_sel === 1'b1);
        look(16'hC0D0); check("INTCXROM still strobes DEVSEL", devsel_n[4] === 1'b0);
        look(16'hC500); check("INTCXROM still strobes IOSEL", iosel_n[4] === 1'b0);
        settle;

        // ---- Cards in slots 3, 5 and 6, INTCXROM off ----
        intcxrom    = 1'b0;
        card_data[2] = card_byte(3);
        card_data[4] = card_byte(5);
        card_data[5] = card_byte(6);
        card_present = 7'b0110100;

        // An empty slot's bus floats, and reads as $00.
        look(16'hC200); check("empty slot 2 floats", int_rom_sel === 1'b0 && slot_dout === 8'h00);
        look(16'hC400); check("empty slot 4 floats", int_rom_sel === 1'b0 && slot_dout === 8'h00);
        look(16'hC700); check("empty slot 7 floats", int_rom_sel === 1'b0 && slot_dout === 8'h00);

        // Each card answers its own $Cnxx window, not its neighbour's.
        look(16'hC500); check("slot 5 ROM", slot_dout === card_byte(5));
        look(16'hC600); check("slot 6 ROM", slot_dout === card_byte(6));

        // $C3xx is the motherboard's 80-column firmware while SLOTC3ROM is
        // off, and belongs to slot 3 when it is on.
        look(16'hC300); check("C300 internal with SLOTC3ROM off", int_rom_sel === 1'b1);
        look(16'hC301); check("C301 internal with SLOTC3ROM off", int_rom_sel === 1'b1);
        slotc3rom = 1'b1;
        look(16'hC300); check("C300 to slot 3 with SLOTC3ROM on",
                              int_rom_sel === 1'b0 && slot_dout === card_byte(3));
        look(16'hC301); check("C301 to slot 3 with SLOTC3ROM on",
                              int_rom_sel === 1'b0 && slot_dout === card_byte(3));
        slotc3rom = 1'b0;

        // $C800 is unclaimed: the floating bus, and no internal ROM either.
        look(16'hC800); check("C800 unclaimed floats",
                              int_rom_sel === 1'b0 && slot_dout === 8'h00);
        settle;

        // ---- The $C800 claim: a card with expansion ROM claims it on /IOSEL
        // and holds it until the $CFFF /IOSTROBE pulse ----
        card_exprom[4] = 1'b1;       // slot 5 has an expansion ROM
        bus(16'hC500);
        look(16'hC800); check("C800 served by the claiming card",
                              int_rom_sel === 1'b0 && slot_dout === card_byte(5));
        // Change the card's byte: the read is live off the bus, not latched.
        card_data[4] = 8'hEE;
        look(16'hC800); check("C800 read is live", slot_dout === 8'hEE);
        bus(16'hCFFF);
        look(16'hC800); check("C800 released by $CFFF", slot_dout === 8'h00);

        // A later claim replaces the earlier one, and it is that card's.
        bus(16'hC600);                // slot 6 has no expansion ROM yet
        look(16'hC800); check("C800 stays unclaimed without an expansion ROM",
                              slot_dout === 8'h00);
        card_exprom[5] = 1'b1;        // now give slot 6 one
        bus(16'hC600);
        look(16'hC800); check("C800 served by slot 6", slot_dout === card_byte(6));

        // Only bus() may move the claim.  look() holds an address on the bus
        // with no clock edge, and if it could latch, this would leave $C800
        // answering slot 6 instead of slot 5 -- which is exactly the race that
        // a clock raised in the same time step as the address used to cause.
        // Slot 5 is already claiming; slot 6 is holding the space.
        card_data[4] = card_byte(5);
        look(16'hC500);
        look(16'hC800); check("look() cannot move the $C800 claim",
                              slot_dout === card_byte(6));
        bus(16'hC500);
        look(16'hC800); check("bus() does move the $C800 claim",
                              slot_dout === card_byte(5));
        bus(16'hCFFF);

        // INTC8ROM, the motherboard claiming $C800 itself, outranks a card.
        intc8rom = 1'b1;
        look(16'hC800); check("INTC8ROM outranks the card", int_rom_sel === 1'b1);
        intc8rom = 1'b0;
        settle;

        // ---- /IRQ daisy chain: INT IN -> slot 1 -> ... -> slot 7 -> CPU ----
        check("IRQ idle", irq_n === 1'b1);
        int_in_n = 1'b0; #1;
        check("IRQ follows INT IN with no card asking", irq_n === 1'b0);
        int_in_n = 1'b1;
        card_irq_n[4] = 1'b0;         // slot 5 asks
        #1;
        check("IRQ reaches the CPU", irq_n === 1'b0);
        check("IRQ blocks the slots after it", irq_out_n[5] === 1'b0);
        check("IRQ does not block the slots before it", irq_out_n[3] === 1'b1);
        card_irq_n[4] = 1'b1;
        card_irq_n[5] = 1'b0;         // slot 6 asks instead
        #1;
        check("IRQ from slot 6", irq_n === 1'b0);
        check("the last slot blocks nothing before it", irq_out_n[4] === 1'b1);
        check("IRQ reaches the CPU from the last populated slot", irq_out_n[6] === 1'b0);
        card_irq_n[5] = 1'b1;
        // A slot with no card in it cannot hold the line low.
        card_irq_n[1] = 1'b0;         // slot 2 is empty
        #1;
        check("an empty slot does not assert IRQ", irq_n === 1'b1);
        check("an empty slot passes INT IN out", irq_out_n[1] === 1'b1);
        card_irq_n[1] = 1'b1;
        // A populated slot that is not asking passes the chain on.
        check("a populated idle slot passes INT IN out", irq_out_n[4] === 1'b1);
        check("IRQ idle again", irq_n === 1'b1);

        // ---- /NMI and /DMA are shared lines, not chained ----
        check("NMI idle", nmi_n === 1'b1);
        check("DMA idle", dma_n === 1'b1);
        card_nmi_n[5] = 1'b0;
        #1; check("NMI from slot 6 reaches the CPU", nmi_n === 1'b0);
        card_nmi_n[5] = 1'b1;
        // An empty slot cannot pull the shared line either.
        card_nmi_n[3] = 1'b0;         // slot 4 is empty
        #1; check("an empty slot does not assert NMI", nmi_n === 1'b1);
        card_nmi_n[3] = 1'b1;
        card_dma_n[0] = 1'b0;         // slot 1 is empty
        #1; check("an empty slot does not assert DMA", dma_n === 1'b1);
        card_dma_n[0] = 1'b1;
        card_dma_n[4] = 1'b0;         // slot 5 is populated
        #1; check("DMA from slot 5 reaches the line", dma_n === 1'b0);
        card_dma_n[4] = 1'b1;
        #1; check("DMA idle again", dma_n === 1'b1);

        if (fails == 0) $display("tb_slots: PASS (%0d checks)", checks);
        else             $display("tb_slots: FAIL (%0d of %0d checks failed)", fails, checks);
        $finish;
    end

    initial begin #2000000; $display("tb_slots: FAIL (timeout)"); $finish; end
endmodule
