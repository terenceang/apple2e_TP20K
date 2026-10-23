// 6522 VIA (Versatile Interface Adapter) for Mockingboard C
// Implements 16 standard registers with Timer 1, Timer 2, Port A/B, and IRQ generation.
`default_nettype none

module via6522 (
    input  wire        clk,          // 27.0 MHz system clock
    input  wire        reset,        // Active-high reset
    input  wire        ce_1m,        // 1.023 MHz clock enable
    input  wire        bus_cycle,    // Valid CPU/debugger bus cycle
    input  wire        cs,           // Chip select (active high)
    input  wire        we,           // Write enable (active high)
    input  wire [3:0]  rs,           // Register select RS3..RS0
    input  wire [7:0]  din,          // Data from CPU bus
    output reg  [7:0]  dout,         // Data to CPU bus
    output wire        irq_n,        // Active-low /IRQ output

    // Port A (connects to PSG DA[7:0])
    input  wire [7:0]  port_a_in,
    output wire [7:0]  port_a_out,
    output wire [7:0]  port_a_oe,

    // Port B (connects to PSG control: BC1, BDIR, RESET)
    input  wire [7:0]  port_b_in,
    output wire [7:0]  port_b_out,
    output wire [7:0]  port_b_oe
);

    // Register file
    reg [7:0]  orb;       // 0x0: Output Register B
    reg [7:0]  ora;       // 0x1: Output Register A (with handshake)
    reg [7:0]  ddrb;      // 0x2: Data Direction Register B
    reg [7:0]  ddra;      // 0x3: Data Direction Register A
    reg [15:0] t1c;       // 0x4/0x5: Timer 1 Counter
    reg [15:0] t1l;       // 0x6/0x7: Timer 1 Latch
    reg [15:0] t2c;       // 0x8/0x9: Timer 2 Counter
    reg [7:0]  t2l_l;     // Timer 2 Latch Low
    reg [7:0]  sr;        // 0xA: Shift Register
    reg [7:0]  acr;       // 0xB: Auxiliary Control Register
    reg [7:0]  pcr;       // 0xC: Peripheral Control Register
    reg [6:0]  ifr;       // 0xD: Interrupt Flag Register (bits 6:0)
    reg [6:0]  ier;       // 0xE: Interrupt Enable Register (bits 6:0)

    reg        t1_loaded;
    reg        t1_int_arm;
    reg        t1_reload;     // free-running: $FFFF this cycle, the latch the next
    reg        t2_loaded;
    reg        t2_int_arm;
    reg [11:0] cb1_delay;
    reg [6:0]  nifr;      // next IFR: clears, then sets, so a flag raised in
                          // the clock it is cleared or written is not lost

    // Pin drivers
    assign port_a_out = ora;
    assign port_a_oe  = ddra;
    assign port_b_out = orb;
    assign port_b_oe  = ddrb;

    // Input data with direction mask
    wire [7:0] ira = (ora & ddra) | (port_a_in & ~ddra);
    wire [7:0] irb = (orb & ddrb) | (port_b_in & ~ddrb);

    // Interrupt composite bit (IFR bit 7)
    wire ifr_composite = |(ifr & ier);
    assign irq_n = ~ifr_composite;

    // Combinational register read
    always @(*) begin
        case (rs)
            4'h0: dout = irb;
            4'h1: dout = ira;
            4'h2: dout = ddrb;
            4'h3: dout = ddra;
            4'h4: dout = t1c[7:0];
            4'h5: dout = t1c[15:8];
            4'h6: dout = t1l[7:0];
            4'h7: dout = t1l[15:8];
            4'h8: dout = t2c[7:0];
            4'h9: dout = t2c[15:8];
            4'hA: dout = sr;
            4'hB: dout = acr;
            4'hC: dout = pcr;
            4'hD: dout = {ifr_composite, ifr};
            4'hE: dout = {1'b1, ier};
            4'hF: dout = ira; // ORA without handshake
        endcase
    end

    // Bus access flags
    wire write_strobe = cs && we && bus_cycle;
    wire read_strobe  = cs && !we && bus_cycle;

    // Synchronous state and timer update
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            orb       <= 8'h00;
            ora       <= 8'h00;
            ddrb      <= 8'h00;
            ddra      <= 8'h00;
            t1c       <= 16'hFFFF;
            t1l       <= 16'h0000;
            t2c       <= 16'hFFFF;
            t2l_l     <= 8'h00;
            sr        <= 8'h00;
            acr       <= 8'h00;
            pcr       <= 8'h00;
            ifr        <= 7'h00;
            ier        <= 7'h00;
            t1_loaded  <= 1'b0;
            t1_int_arm <= 1'b0;
            t1_reload  <= 1'b0;
            t2_loaded  <= 1'b0;
            t2_int_arm <= 1'b0;
            cb1_delay  <= 12'd0;
        end else begin
            nifr = ifr;

            // -----------------------------------------------------------------
            // Interrupt Flag Clearing on Register Read, and on IFR / ORB writes
            // -----------------------------------------------------------------
            if (read_strobe) begin
                if (rs == 4'h4)      nifr[6] = 1'b0;  // T1C_L clears Timer 1
                else if (rs == 4'h8) nifr[5] = 1'b0;  // T2C_L clears Timer 2
                else if (rs == 4'h0) nifr[4] = 1'b0;  // ORB/IRB clears CB1
            end
            if (write_strobe && rs == 4'hD) nifr = nifr & ~din[6:0];
            if (write_strobe && rs == 4'h0) nifr[4] = 1'b0;

            // -----------------------------------------------------------------
            // CB1 Speech Acknowledge (Mockingboard Sound/Speech Handshake)
            // -----------------------------------------------------------------
            // When PCR configures CB1 (e.g. pcr[4] = 1 for positive edge A/R),
            // auto-acknowledge phoneme writes by asserting ifr[4] after ~1000 cycles (~37 us).
            // This prevents software expecting the SC-01 speech synthesizer from hanging.
            if (pcr[4]) begin
                if (!ifr[4]) begin
                    if (cb1_delay < 12'd1000) begin
                        cb1_delay <= cb1_delay + 1'b1;
                    end else begin
                        nifr[4] = 1'b1;
                    end
                end else begin
                    cb1_delay <= 12'd0;
                end
            end else begin
                cb1_delay <= 12'd0;
            end

            // -----------------------------------------------------------------
            // Timer 1 and Timer 2 Countdown on ce_1m (1.023 MHz)
            // -----------------------------------------------------------------
            // Both timers decrement continuously on ce_1m at all times, including
            // immediately after reset before any configuration writes occur.
            // This enables Apple II Mockingboard detection routines (e.g. Skyfox)
            // to measure timer decrements across successive reads of T1C_L ($C404).
            if (ce_1m) begin
                if (t1_loaded && acr[6]) begin
                    // Free-running: 0, then $FFFF (the flag rises here), then
                    // the latch: a period of N + 2 cycles, as on a 6522
                    if (t1_reload) begin
                        t1c       <= t1l;
                        t1_reload <= 1'b0;
                    end else if (t1c == 16'd0) begin
                        nifr[6]    = 1'b1;
                        t1c       <= 16'hFFFF;
                        t1_reload <= 1'b1;
                    end else begin
                        t1c <= t1c - 16'd1;
                    end
                end else begin
                    // One-shot mode or unconfigured: continuous countdown
                    if (t1c == 16'd0) begin
                        if (t1_loaded && t1_int_arm) begin
                            nifr[6]     = 1'b1;
                            t1_int_arm <= 1'b0;
                        end
                        t1c <= 16'hFFFF;
                    end else begin
                        t1c <= t1c - 16'd1;
                    end
                end

                if (t2c == 16'd0) begin
                    if (t2_loaded && t2_int_arm) begin
                        nifr[5]     = 1'b1;
                        t2_int_arm <= 1'b0;
                    end
                    t2c <= 16'hFFFF;
                end else begin
                    t2c <= t2c - 16'd1;
                end
            end

            // -----------------------------------------------------------------
            // Register Writes
            // -----------------------------------------------------------------
            if (write_strobe) begin
                case (rs)
                    4'h0: orb  <= din;
                    4'h1: ora  <= din;
                    4'h2: ddrb <= din;
                    4'h3: ddra <= din;
                    4'h4: begin
                        // Write T1 Low Latch
                        t1l[7:0] <= din;
                    end
                    4'h5: begin
                        // Write T1 High Latch, load counter, clear interrupt, arm
                        t1l[15:8]  <= din;
                        t1c        <= {din, t1l[7:0]};
                        t1_reload  <= 1'b0;
                        nifr[6]     = 1'b0;
                        t1_loaded  <= 1'b1;
                        t1_int_arm <= 1'b1;
                    end
                    4'h6: begin
                        // Write T1 Low Latch
                        t1l[7:0] <= din;
                    end
                    4'h7: begin
                        // Write T1 High Latch, clear interrupt, arm
                        t1l[15:8]  <= din;
                        nifr[6]     = 1'b0;
                        t1_loaded  <= 1'b1;
                        t1_int_arm <= 1'b1;
                    end
                    4'h8: begin
                        // Write T2 Low Latch
                        t2l_l <= din;
                    end
                    4'h9: begin
                        // Write T2 High Counter, load low counter from latch, clear interrupt, arm
                        t2c        <= {din, t2l_l};
                        nifr[5]     = 1'b0;
                        t2_loaded  <= 1'b1;
                        t2_int_arm <= 1'b1;
                    end
                    4'hA: sr  <= din;
                    4'hB: acr <= din;
                    4'hC: pcr <= din;
                    4'hE: begin
                        // IER write: bit 7 = 1 enables bits, bit 7 = 0 disables bits
                        if (din[7])
                            ier <= ier | din[6:0];
                        else
                            ier <= ier & ~din[6:0];
                    end
                    4'hF: ora <= din;
                endcase
            end
            // a timer load clears its flag after the sets above: the load
            // restarts the count, so an expiry in the same clock is stale
            ifr <= nifr;
        end
    end

endmodule

`default_nettype wire
