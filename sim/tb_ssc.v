`timescale 1ns / 1ps
`default_nettype none

// tb_ssc.v -- the Super Serial Card (src/ssc.v): its 6551 as the 6502 sees it
// at $C098-$C09B and the DIP switches at $C091/$C092, and its line as the
// page's modem sees it (bytes in through input_controller's FF 06, out as
// tx_req, DTR and baud as st_req).
//
//   * the DIP switches read as the defaults (SW1 $E0, SW2 $02)
//   * DTR and the baud go to the page when they change, and only then
//   * a byte written goes out once, and the transmitter is busy one
//     character time (10 bits at the baud) after it
//   * bytes from the page wait in the FIFO and land in RDR one character
//     time apart, in order; reading the data clears RDRF
//   * RX interrupt (command bit 1 clear): IRQ with RDRF, cleared by reading
//     status; none with bit 1 set
//   * the page's carrier and DSR are status bits 5 and 6 (0 = asserted)
//   * more than 64 bytes from the page sets overrun; programmed reset clears
//     it and drops DTR (the command's low five bits)
//   * a debugger read (no bus_cycle) does not take the byte

module tb_ssc;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;

    reg        bus_cycle = 1'b0, we = 1'b0, devsel_n = 1'b1;
    reg [15:0] addr = 16'h0000;
    reg [7:0]  din = 8'h00;
    wire [7:0] io_data, rom_data;
    wire       irq_n;
    reg  [7:0] rx_data = 8'h00;
    reg        rx_valid = 1'b0;
    reg  [1:0] lines = 2'b00;
    wire       tx_req, st_req;
    wire [7:0] tx_byte, st_byte;
    reg        tx_ack = 1'b0, st_ack = 1'b0;

    ssc dut (.clk(clk), .reset(reset), .bus_cycle(bus_cycle), .cpu_we(we), .addr(addr), .din(din),
             .devsel_n(devsel_n), .io_data(io_data), .rom_data(rom_data), .irq_n(irq_n),
             .rx_data(rx_data), .rx_valid(rx_valid), .lines(lines),
             .tx_req(tx_req), .tx_byte(tx_byte), .tx_ack(tx_ack),
             .st_req(st_req), .st_byte(st_byte), .st_ack(st_ack));

    integer fails = 0, checks = 0;
    task check(input [8*72-1:0] what, input ok);
        begin checks = checks + 1; if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end end
    endtask

    // the 6502: one access, devsel and bus_cycle on its clock, as slot_bus makes them
    task acc(input [3:0] r, input w, input [7:0] d, output [7:0] q);
        begin
            @(negedge clk);
            addr = 16'hC090 | r; we = w; din = d; devsel_n = 1'b0; bus_cycle = 1'b1;
            #1 q = io_data;
            @(negedge clk); devsel_n = 1'b1; bus_cycle = 1'b0; we = 1'b0;
        end
    endtask
    reg [7:0] v;
    task wr(input [3:0] r, input [7:0] d); acc(r, 1'b1, d, v); endtask

    // the page: the board takes its bytes and acknowledges what it sends
    integer tx_n = 0, st_n = 0;
    reg [7:0] tx_last, st_last;
    always @(posedge clk) begin
        tx_ack <= 1'b0; st_ack <= 1'b0;
        if (tx_req && !tx_ack) begin tx_ack <= 1'b1; tx_n = tx_n + 1; tx_last = tx_byte; end
        if (st_req && !st_ack) begin st_ack <= 1'b1; st_n = st_n + 1; st_last = st_byte; end
    end
    task send(input [7:0] b);
        begin @(negedge clk); rx_data = b; rx_valid = 1'b1; @(negedge clk); rx_valid = 1'b0; end
    endtask

    // 115200 (control $10, baud code 0): 2344 clocks a character
    localparam integer CHAR = 2344;
    integer i, t0, t1, got;
    reg [7:0] order [0:7];
    initial begin
        $display("=== tb_ssc ===");
        repeat (10) @(posedge clk); reset = 1'b0; repeat (10) @(posedge clk);

        acc(4'h1, 1'b0, 8'h00, v); check("SW1 reads $E0 (9600, SSC mode)", v == 8'hE0);
        acc(4'h2, 1'b0, 8'h00, v); check("SW2 reads $02 (8N1, no LF, CTS on)", v == 8'h02);

        // the line comes up: 115200, DTR on, RX IRQ off, TX on (RTS low, no TX IRQ)
        wr(4'hB, 8'h10);
        wr(4'hA, 8'h0B);
        repeat (20) @(posedge clk);
        check("DTR and the baud went to the page", st_n >= 1 && st_last == 8'hC0);
        i = st_n; repeat (50) @(posedge clk);
        check("and are not sent again while they stay", st_n == i);

        // transmit
        acc(4'h9, 1'b0, 8'h00, v); check("idle: TDRE set, RDRF clear, no carrier/DSR", v == 8'h70);
        wr(4'h8, 8'h41);
        acc(4'h9, 1'b0, 8'h00, v); check("TDRE clear right after a write", v[4] == 1'b0);
        repeat (20) @(posedge clk);
        check("the byte went to the page once", tx_n == 1 && tx_last == 8'h41);
        t0 = $time;
        acc(4'h9, 1'b0, 8'h00, v);
        while (!v[4]) acc(4'h9, 1'b0, 8'h00, v);
        t1 = ($time - t0) / 37;
        check("the transmitter is busy about one character time", t1 > CHAR - 100 && t1 < CHAR + 10);

        // receive, paced
        lines = 2'b11;
        repeat (3) @(posedge clk);
        acc(4'h9, 1'b0, 8'h00, v); check("carrier and DSR from the page: status bits 5 and 6 low", v[6:5] == 2'b00);
        for (i = 0; i < 5; i = i + 1) send(8'h30 + i);
        got = 0; t0 = $time;
        while (got < 5) begin
            acc(4'h9, 1'b0, 8'h00, v);
            if (v[3]) begin acc(4'h8, 1'b0, 8'h00, order[got]); got = got + 1; end
        end
        t1 = ($time - t0) / 37;
        check("five bytes in order", order[0] == 8'h30 && order[1] == 8'h31 && order[4] == 8'h34);
        check("one character time apart (~4 x 2344 clocks for the last four)", t1 > 4 * CHAR - 200 && t1 < 5 * CHAR);
        acc(4'h9, 1'b0, 8'h00, v); check("RDRF clear once the data is read", v[3] == 1'b0);

        // the debugger's read does not take a byte
        send(8'h55);
        repeat (CHAR + 10) @(posedge clk);
        @(negedge clk); addr = 16'hC098; we = 1'b0; devsel_n = 1'b0; bus_cycle = 1'b0;
        @(negedge clk); devsel_n = 1'b1;
        acc(4'h9, 1'b0, 8'h00, v); check("a debugger read leaves RDRF set", v[3] == 1'b1);
        acc(4'h8, 1'b0, 8'h00, v); check("and the CPU gets the byte", v == 8'h55);

        // RX interrupt
        wr(4'hA, 8'h09);                       // DTR, RX IRQ on (bit 1 clear)
        repeat (CHAR) @(posedge clk);
        send(8'h66);
        repeat (CHAR + 10) @(posedge clk);
        check("IRQ with the received byte", irq_n == 1'b0);
        acc(4'h9, 1'b0, 8'h00, v); check("status shows IRQ and RDRF", v[7] && v[3]);
        check("reading status clears the IRQ", irq_n == 1'b1);
        acc(4'h8, 1'b0, 8'h00, v);
        // a status read in the very clock a byte lands must not lose its IRQ
        send(8'h6A);
        @(negedge clk); while (!dut.f_take) @(negedge clk);
        addr = 16'hC099; we = 1'b0; devsel_n = 1'b0; bus_cycle = 1'b1;
        @(negedge clk); devsel_n = 1'b1; bus_cycle = 1'b0;
        check("a status read as a byte lands keeps its IRQ", irq_n == 1'b0);
        acc(4'h9, 1'b0, 8'h00, v); acc(4'h8, 1'b0, 8'h00, v);
        wr(4'hA, 8'h0B);                       // RX IRQ off
        send(8'h77);
        repeat (CHAR + 10) @(posedge clk);
        check("no IRQ with RX interrupts off", irq_n == 1'b1);
        acc(4'h8, 1'b0, 8'h00, v);

        // overrun, and programmed reset
        repeat (CHAR + 10) @(posedge clk);
        for (i = 0; i < 70; i = i + 1) send(i);
        acc(4'h9, 1'b0, 8'h00, v); check("more than the FIFO holds: overrun", v[2] == 1'b1);
        i = st_n;
        wr(4'h9, 8'h00);
        acc(4'h9, 1'b0, 8'h00, v); check("programmed reset clears overrun", v[2] == 1'b0);
        acc(4'hA, 1'b0, 8'h00, v); check("and drops DTR (command bits 4:0)", v[4:0] == 5'd0);
        repeat (20) @(posedge clk);
        check("the page hears DTR drop", st_n == i + 1 && st_last[6] == 1'b0);
        acc(4'h8, 1'b0, 8'h00, v);             // the byte that was in RDR
        send(8'h99);
        repeat (2 * CHAR) @(posedge clk);
        acc(4'h9, 1'b0, 8'h00, v); check("with DTR off nothing is received (the FIFO is dropped)", v[3] == 1'b0);

`ifndef SSC_NO_ROM
        // the firmware's addressing: $C1xx is ROM offset $700, $C800 the whole 2 KB
        @(negedge clk); addr = 16'hC1A5; @(negedge clk); @(negedge clk);
        check("$C1A5 reads ROM $7A5", rom_data === dut.rom[11'h7A5]);
        addr = 16'hC823; @(negedge clk); @(negedge clk);
        check("$C823 reads ROM $023", rom_data === dut.rom[11'h023]);
`endif

        if (fails == 0) $display("tb_ssc: PASS (%0d checks)", checks);
        else            $display("FAIL: tb_ssc failed %0d of %0d checks", fails, checks);
        $finish;
    end
endmodule

`default_nettype wire
