// tb_spi_ctl -- the ESP32 link end to end: spi_ctl + disk2_trk against a
// behavioural ESP32 slave and a flat SDRAM stand-in.
//
// The slave is also the protocol spec for mcu/ (see the header of src/spi_ctl.v):
// a command frame, then poll frames that return A5 + payload once the answer is
// ready.  It serves two tracks of drive 0 (track 0 is the card's own golden
// stream, build/golden_track0.hex, from tb_disk2), and records the WRITE_TRK
// frame it is sent.
//
// Checks: PING brings the link up; the drive mounts (present) after STAT sees a
// generation; both tracks land in SDRAM byte for byte; the card plays the golden
// stream through its data register; four bytes written through the card show up
// in SDRAM and in the flushed WRITE_TRK frame (and only those four).
`timescale 1ns/1ps
module tb_spi_ctl;
    `include "src/disk2/trk_defs.vh"

    localparam integer NT = 2;

    reg clk = 0;
    always #18.519 clk = ~clk;
    reg reset = 1;
    reg [4:0] ce_div = 0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= ce_1m ? 5'd0 : ce_div + 5'd1;

    integer fails = 0;
    task check(input [8*60-1:0] what, input ok);
        if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end
    endtask

    // ---------------- DUT wiring ----------------
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;
    wire head_drv, motor, wr_evt, wr_drv, link_up;
    wire [5:0] head_trk, wr_trk;
    wire [1:0] drv_present, drv_writable;
    wire x_req, x_we, x_ack;
    wire [18:0] x_addr;
    wire [15:0] x_wdata, x_rdata;

    spi_ctl #(.NTRK(NT), .BOOT_CLKS(1000), .STAT_CLKS(3000)) u_ctl (
        .clk(clk), .reset(reset),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .head_drv(head_drv), .head_trk(head_trk), .motor(motor),
        .wr_evt(wr_evt), .wr_drv(wr_drv), .wr_trk(wr_trk),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .x_req(x_req), .x_we(x_we), .x_addr(x_addr), .x_wdata(x_wdata),
        .x_rdata(x_rdata), .x_ack(x_ack), .link_up(link_up));

    reg  [15:0] addr = 16'hC0E0;
    reg         bus_cycle = 0, cpu_we = 0;
    reg  [7:0]  cpu_di = 0;
    wire [7:0]  rom_data, io_data;
    wire devsel_n = !((addr[15:8] == 8'hC0) && (addr[7:4] == 4'hE));
    wire dsk_go, dsk_we, dsk_ack, dsk_idle;
    wire [21:0] dsk_addr;
    wire [15:0] dsk_wdata, dsk_rdata;
    wire [6:0] dbg_track; wire [7:0] dbg_head;
    wire dbg_motor, dbg_drive, dbg_any_disk, dbg_wr_mode;

    disk2_trk u_card (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .devsel_n(devsel_n), .iosel_n(1'b1), .bus_cycle(bus_cycle), .cpu_we(cpu_we),
        .addr(addr), .cpu_di(cpu_di), .rom_data(rom_data), .io_data(io_data),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .head_drv(head_drv), .head_trk(head_trk), .motor(motor),
        .wr_evt(wr_evt), .wr_drv(wr_drv), .wr_trk(wr_trk),
        .x_req(x_req), .x_we(x_we), .x_addr(x_addr), .x_wdata(x_wdata),
        .x_rdata(x_rdata), .x_ack(x_ack),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack), .dsk_idle(dsk_idle),
        .dbg_track(dbg_track), .dbg_head(dbg_head), .dbg_motor(dbg_motor),
        .dbg_drive(dbg_drive), .dbg_any_disk(dbg_any_disk), .dbg_wr_mode(dbg_wr_mode));

    // ---------------- SDRAM stand-in: 8 clocks per word ----------------
    reg [7:0] mem [0:524287];
    reg [3:0] dsk_t = 0;
    reg dsk_busy = 0, dsk_we_q = 0, dsk_ack_q = 0;
    reg [21:0] dsk_a_q = 0;
    reg [15:0] dsk_d_q = 0, dsk_r_q = 0;
    assign dsk_idle = !dsk_busy;
    assign dsk_ack = dsk_ack_q;
    assign dsk_rdata = dsk_r_q;
    integer mi;
    initial for (mi = 0; mi < 524288; mi = mi + 1) mem[mi] = 8'h00;
    always @(posedge clk) begin
        dsk_ack_q <= 0;
        if (dsk_go) begin
            dsk_busy <= 1; dsk_t <= 0; dsk_a_q <= dsk_addr; dsk_we_q <= dsk_we; dsk_d_q <= dsk_wdata;
        end else if (dsk_busy) begin
            dsk_t <= dsk_t + 1;
            if (dsk_t == 7) begin
                dsk_busy <= 0; dsk_ack_q <= 1;
                if (dsk_we_q) begin
                    mem[{dsk_a_q[18:1], 1'b0}] <= dsk_d_q[7:0];
                    mem[{dsk_a_q[18:1], 1'b1}] <= dsk_d_q[15:8];
                end else
                    dsk_r_q <= {mem[{dsk_a_q[18:1], 1'b1}], mem[{dsk_a_q[18:1], 1'b0}]};
            end
        end
    end

    // ---------------- the ESP32 slave model ----------------
    reg [7:0] golden [0:7039];
    initial $readmemh("build/golden_track0.hex", golden);
    function [7:0] trk_byte(input integer d, input integer t, input integer i);
        trk_byte = (t == 0 && d == 0) ? golden[i] : (8'(i * 3 + t * 17 + d * 5) ^ 8'h5A);
    endfunction

    reg [7:0] gen0 = 8'd1, gen1 = 8'd0, sflags = 8'd1;
    reg [7:0] frame [0:7167];
    integer   fn = 0;
    reg [7:0] resp [0:7167];
    integer   resp_n = 0;
    reg       resp_valid = 0;
    time      ready_at = 0;
    reg       use_resp = 0;
    reg [7:0] rxsh = 0, txsh = 0, txnext = 0;
    reg [2:0] bc = 0;
    reg       fin = 0;
    integer   ti = 0;

    // got WRITE_TRK
    reg [7:0] wrdata [0:7039];
    reg       wr_got = 0;
    integer   wr_d = 0, wr_t = 0, wr_len = 0;
    integer   reads_started = 0, polls_not_ready = 0;

    function [7:0] tx_at(input integer i);
        tx_at = (use_resp && i < resp_n) ? resp[i] : 8'h00;
    endfunction

    assign spi_miso = txsh[7];

    always @(negedge spi_cs_n) begin
        fn = 0; bc = 0; fin = 0; ti = 0;
        use_resp = resp_valid && ($time >= ready_at);
        if (resp_valid && !use_resp) polls_not_ready = polls_not_ready + 1;
        txsh <= tx_at(0);
    end
    always @(posedge spi_sck) if (!spi_cs_n) begin
        rxsh <= {rxsh[6:0], spi_mosi};
        if (bc == 3'd7) begin
            frame[fn] = {rxsh[6:0], spi_mosi};
            fn = fn + 1; ti = ti + 1;
            txnext <= tx_at(ti);
            fin <= 1;
        end else fin <= 0;
        bc <= bc + 3'd1;
    end
    always @(negedge spi_sck) if (!spi_cs_n) txsh <= fin ? txnext : {txsh[6:0], 1'b0};

    integer k;
    always @(posedge spi_cs_n) if (fn > 0) begin
        case (frame[0])
            8'h00: begin   // poll: consumed if it was served
                if (use_resp) resp_valid = 0;
            end
            8'h01: begin
                resp[0] = 8'hA5; resp[1] = 8'h5A; resp_n = 2; resp_valid = 1; ready_at = $time;
            end
            8'h02: begin
                resp[0] = 8'hA5; resp[1] = gen0; resp[2] = gen1; resp[3] = sflags; resp_n = 4;
                resp_valid = 1; ready_at = $time;
            end
            8'h10: begin
                resp[0] = 8'hA5;
                for (k = 0; k < 7040; k = k + 1) resp[k+1] = trk_byte(frame[1], frame[2], k);
                resp_n = 7041; resp_valid = 1; ready_at = $time + 200000;   // 200 us: forces a retry
                reads_started = reads_started + 1;
            end
            8'h20: begin
                wr_d = frame[1]; wr_t = frame[2]; wr_len = fn - 3;
                for (k = 0; k < 7040; k = k + 1) wrdata[k] = frame[k+3];
                wr_got = 1;
            end
            default: ;
        endcase
    end

    // ---------------- card bus tasks (as tb_disk2) ----------------
    task xfer(input [3:0] a, input we, input [7:0] d);
        begin
            @(posedge ce_1m);
            addr = 16'hC0E0 | {12'h000, a}; cpu_we = we; cpu_di = d; bus_cycle = 1;
            @(posedge clk); #1 bus_cycle = 0; @(negedge clk);
        end
    endtask
    task read_reg(input [3:0] a, output [7:0] d);
        begin
            @(posedge ce_1m);
            addr = 16'hC0E0 | {12'h000, a}; cpu_we = 0; bus_cycle = 1;
            #1 d = io_data;
            @(posedge clk); #1 bus_cycle = 0; @(negedge clk);
        end
    endtask
    task read_byte(output [7:0] d);
        integer g;
        begin
            g = 0; d = 0;
            while (d[7] !== 1'b1 && g < 4000) begin read_reg(4'hC, d); g = g + 1; end
        end
    endtask

    integer i, n_diff, first_diff;
    reg [7:0] rb;
    reg [7:0] wbytes [0:3];
    initial begin
        wbytes[0] = 8'hD7; wbytes[1] = 8'hD9; wbytes[2] = 8'hDA; wbytes[3] = 8'hDB;
        #200 reset = 0;

        wait (link_up); $display("link up at %0t", $time);
        check("PING brings the link up", link_up === 1'b1);
        wait (drv_present[0]); $display("drive 0 present at %0t", $time);
        check("drive 0 writable per STAT flags", drv_writable[0] === 1'b1);
        check("drive 1 stays empty", drv_present[1] === 1'b0);
        check("a not-ready poll was retried", polls_not_ready > 0 || reads_started == NT);
        check("both tracks were requested", reads_started == NT);

        // SDRAM holds both tracks byte for byte
        n_diff = 0;
        for (i = 0; i < NT * 7040; i = i + 1)
            if (mem[trk_base(0, i / 7040) + (i % 7040)] !== trk_byte(0, i / 7040, i % 7040))
                n_diff = n_diff + 1;
        check("tracks 0..1 are in SDRAM byte for byte", n_diff == 0);
        if (n_diff) $display("  %0d bytes differ", n_diff);

        // The card plays the golden stream
        xfer(4'h9, 1'b0, 8'h00);              // motor on
        n_diff = 0;
        for (i = 0; i < 700; i = i + 1) begin
            read_byte(rb);
            if (rb !== golden[i]) begin
                if (n_diff == 0) $display("  stream byte %0d: got %02x want %02x", i, rb, golden[i]);
                n_diff = n_diff + 1;
            end
        end
        check("the card's stream is the golden track", n_diff == 0);

        // Write four bytes through the card, motor stopped on a byte
        xfer(4'h8, 1'b0, 8'h00);              // motor off: hold the head
        xfer(4'hF, 1'b1, 8'h00);              // write mode
        for (i = 0; i < 4; i = i + 1) begin
            xfer(4'hC, 1'b1, wbytes[i]);      // latch
            read_reg(4'hD, rb);               // shift it into the stream
        end
        read_reg(4'hF, rb);                   // back to read mode
        repeat (2000) @(posedge clk);

        // It flushes once the motor is off
        wait (wr_got); $display("WRITE_TRK received at %0t", $time);
        check("WRITE_TRK is for drive 0 track 0", wr_d == 0 && wr_t == 0);
        check("WRITE_TRK carries the whole 7040-byte track", wr_len == 7040);
        n_diff = 0; first_diff = -1;
        for (i = 0; i < 7040; i = i + 1)
            if (wrdata[i] !== golden[i]) begin
                if (n_diff == 0) first_diff = i;
                n_diff = n_diff + 1;
            end
        check("exactly the four written bytes differ in the flushed track", n_diff == 4);
        if (first_diff >= 0) begin
            for (i = 0; i < 4; i = i + 1)
                check("the written bytes are in order and intact", wrdata[first_diff + i] === wbytes[i]);
            check("the written bytes are in SDRAM too", mem[trk_base(0, 0) + first_diff] === wbytes[0]);
        end

        if (fails == 0) $display("tb_spi_ctl: PASS");
        else            $display("tb_spi_ctl: FAIL (%0d)", fails);
        $finish;
    end
    initial begin #400000000; $display("tb_spi_ctl: FAIL (timeout)"); $finish; end
endmodule
