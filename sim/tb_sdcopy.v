`timescale 1ns / 1ps
`default_nettype none

// tb_sdcopy -- the debugger's q copy of an image into a TF card slot, through
// src/sd_vol.v into sim/models/sdcard.v (volumes shortened to 4 blocks).
//
// The card's config puts slot 1 in drive 2.  The host copies into slot 1: a
// data block, a run of two zero blocks, a data block, then 02.  Each record
// must be acked only once it is on the card; the sectors must hold exactly
// that; the copy must end in "done"; and drive 2, which holds slot 1, must
// load it afresh, so the DDR3 copy is the new image.  Then a bad tag must end
// in "lost".  The debugger's output is read off its TX FIFO's push port.
module tb_sdcopy;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;

    reg  [7:0] rx_byte  = 8'h00;
    reg        rx_valid = 1'b0;

    wire sd_clk, sd_mosi, sd_miso, sd_cs_n;
    sdcard #(.SECTORS(8192)) card (.sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso));

    wire        m_go, m_we;
    wire [24:0] m_addr;
    wire [15:0] m_wdata, slot0, slot1;
    reg  [15:0] m_rdata = 16'h0;
    reg         m_ack = 1'b0;
    wire [1:0]  present;
    wire        loading, busy, err;
    wire [2:0]  estage;
    wire        x_go, x_zero, x_valid, x_take, x_fin, mnt_go, mnt_drv;
    wire [15:0] x_slot, x_blk, mnt_slot;
    wire [7:0]  x_byte;

    sd_vol #(.PWR_BITS(8), .LAST_BLK(16'd3)) u_sd (
        .clk(clk), .reset(reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .ddr_ready(1'b1),
        .m_go(m_go), .m_addr(m_addr), .m_we(m_we), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack),
        .slot0(slot0), .slot1(slot1), .present(present),
        .loading(loading), .busy(busy), .err(err), .estage(estage),
        .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd0),
        .mnt_go(mnt_go), .mnt_drv(mnt_drv), .mnt_slot(mnt_slot),
        .x_go(x_go), .x_slot(x_slot), .x_blk(x_blk), .x_zero(x_zero),
        .x_byte(x_byte), .x_valid(x_valid), .x_take(x_take), .x_fin(x_fin)
    );

    serial_debugger u_dbg (
        .clk(clk), .reset(reset), .ce_1m(1'b1), .uart_tx(),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .dbg_mode(), .cpu_rdy(), .cpu_reset_req(),
        .dbg_mem_addr(), .dbg_mem_din(8'h00), .dbg_mem_ready(1'b1), .dbg_aux(),
        .img_up_go(), .img_up_drive(), .img_up_addr(), .img_up_data(), .img_up_last(),
        .img_up_bad(), .img_up_busy(1'b0), .img_up_done(1'b0),
        .img_dn_go(), .img_dn_drive(), .img_dn_addr(), .img_dn_last(), .img_dn_data(8'h00),
        .img_dn_valid(1'b0), .img_dn_done(1'b0),
        .sd_mnt_go(mnt_go), .sd_mnt_drv(mnt_drv), .sd_mnt_slot(mnt_slot),
        .sd_slot0(slot0), .sd_slot1(slot1),
        .sd_stat({loading, busy, err, estage, present}),
        .sd_x_go(x_go), .sd_x_slot(x_slot), .sd_x_blk(x_blk), .sd_x_zero(x_zero),
        .sd_x_byte(x_byte), .sd_x_valid(x_valid), .sd_x_take(x_take), .sd_x_fin(x_fin),
        .cpu_pc(16'hFA62), .dsk_head(8'd0), .cpu_a(8'h00), .cpu_x(8'h00), .cpu_y(8'h00),
        .cpu_s(8'hFF), .cpu_p(8'h20), .cpu_ir(8'h00), .cpu_addr(16'h0000), .cpu_dout(8'h00),
        .cpu_we(1'b0), .cpu_sync(1'b0),
        .text_mode(1'b1), .mixed_mode(1'b0), .page2(1'b0), .hires_mode(1'b0),
        .pll_locked(1'b1), .ddr_diag(32'd0)
    );

    // DDR3: two drives x 4 blocks
    reg [15:0] ddr [0:2047];
    reg        pend = 1'b0;
    reg [4:0]  t = 0;
    reg [24:0] a_q;
    reg        we_q;
    reg [15:0] d_q;
    integer fails = 0, i, b, k, n = 0, m;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (m_go) begin
            pend <= 1'b1; t <= 0; a_q <= m_addr; we_q <= m_we; d_q <= m_wdata;
        end else if (pend) begin
            t <= t + 1'b1;
            if (t == 5'd20) begin
                pend <= 1'b0; m_ack <= 1'b1;
                if (we_q) ddr[{a_q[24], a_q[9:0]}] <= d_q; else m_rdata <= ddr[{a_q[24], a_q[9:0]}];
            end
        end
    end

    // Everything the debugger queues for the UART
    reg [7:0] out [0:65535];
    always @(posedge clk) if (u_dbg.fifo_push_en) begin out[n] = u_dbg.fifo_push_byte; n = n + 1; end

    function [7:0] pat(input integer blk, input integer k);
        pat = (blk * 53 + k * 7 + (k >> 8)) | 8'h01;
    endfunction
    function integer sec(input integer s, input integer b); sec = 2048 + b + (s ? 4096 : 0); endfunction

    task send(input [7:0] v);
        begin
            @(posedge clk); rx_byte <= v; rx_valid <= 1'b1;
            @(posedge clk); rx_valid <= 1'b0;
            repeat (400) @(posedge clk);       // a host faster than 115200, slower than the card
        end
    endtask

    task wait_idle;
        begin
            repeat (50) @(posedge clk);
            while (u_dbg.main_state != 4'd0) @(posedge clk);
            repeat (50) @(posedge clk);
        end
    endtask

    task wait_ack(input integer from);
        reg got;
        begin
            got = 1'b0;
            while (!got) begin
                for (k = from; k < n; k = k + 1) if (out[k] == 8'h06) got = 1'b1;
                if (!got) @(posedge clk);
            end
        end
    endtask

    function saw(input [8*4-1:0] word, input integer from);
        integer q;
        begin
            saw = 1'b0;
            for (q = from; q + 3 < n; q = q + 1)
                if ({out[q], out[q+1], out[q+2], out[q+3]} == word) saw = 1'b1;
        end
    endfunction

    integer acks, mark;
    initial begin
        for (i = 0; i < 2048; i = i + 1) ddr[i] = 16'hDEAD;
        for (i = 0; i < 512; i = i + 1) card.mem[i] = 8'h00;
        card.mem[0] = "A"; card.mem[1] = "2"; card.mem[2] = "H"; card.mem[3] = "D";
        card.mem[4] = 8'hFF; card.mem[5] = 8'hFF; card.mem[6] = 8'h01; card.mem[7] = 8'h00;  // drive 2: slot 1
        for (b = 0; b < 4; b = b + 1)
            for (k = 0; k < 512; k = k + 1) card.mem[sec(1, b) * 512 + k] = 8'hEE;  // old contents
        #200; @(posedge clk); reset = 1'b0;
        @(posedge clk); while (loading) @(posedge clk);
        if (present !== 2'b10 || err) begin $display("FAIL: before the copy present=%b err=%b", present, err); fails = fails + 1; end

        send(8'h02); wait_idle;                // into the debugger
        mark = n;
        send("q"); send("0"); send("0"); send("0"); send("1");
        while (u_dbg.main_state != 4'd10) @(posedge clk);

        m = n; send(8'h01); for (k = 0; k < 512; k = k + 1) send(pat(0, k)); wait_ack(m);
        m = n; send(8'h00); send(8'h00); send(8'h01); wait_ack(m);          // blocks 1-2: zeros
        m = n; send(8'h01); for (k = 0; k < 512; k = k + 1) send(pat(3, k)); wait_ack(m);
        send(8'h02);
        wait_idle;
        @(posedge clk); while (busy) @(posedge clk);                         // the reload

        acks = 0; for (k = mark; k < n; k = k + 1) if (out[k] == 8'h06) acks = acks + 1;
        if (acks != 3) begin $display("FAIL: %0d acks, want 3", acks); fails = fails + 1; end
        if (!saw("done", mark)) begin $display("FAIL: no done"); fails = fails + 1; end
        for (b = 0; b < 4; b = b + 1)
            for (k = 0; k < 512; k = k + 1)
                if (card.mem[sec(1, b) * 512 + k] !== ((b == 0 || b == 3) ? pat(b, k) : 8'h00)) begin
                    if (fails < 10) $display("FAIL: slot 1 block %0d byte %0d = %02x", b, k, card.mem[sec(1, b) * 512 + k]);
                    fails = fails + 1;
                end
        if (present !== 2'b10) begin $display("FAIL: drive 2 not reloaded (present %b)", present); fails = fails + 1; end
        for (k = 0; k < 512; k = k + 1)
            if ((k[0] ? ddr[{1'b1, 2'd3, k[8:1]}][15:8] : ddr[{1'b1, 2'd3, k[8:1]}][7:0]) !== pat(3, k)) begin
                if (fails < 10) $display("FAIL: drive 2's DDR3 block 3 byte %0d is stale", k);
                fails = fails + 1;
            end

        // a bad tag
        mark = n;
        send("q"); send("0"); send("0"); send("0"); send("1");
        while (u_dbg.main_state != 4'd10) @(posedge clk);
        send(8'h07);
        wait_idle;
        if (!saw("lost", mark)) begin $display("FAIL: a bad tag did not say lost"); fails = fails + 1; end
        if (card.errs != 0) begin $display("FAIL: %0d card protocol errors", card.errs); fails = fails + 1; end

        if (fails == 0) $display("tb_sdcopy: PASS");
        else            $display("tb_sdcopy: FAIL (%0d)", fails);
        $finish;
    end

    initial begin #2_000_000_000; $display("FAIL: timeout (ph=%0d blk=%0d st=%0d)", u_dbg.x_ph, x_blk, u_sd.st); $finish; end
endmodule
