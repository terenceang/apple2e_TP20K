`timescale 1ns / 1ps
`default_nettype none

// tb_sdvol -- src/sd_vol.v against sim/models/sdcard.v and a behavioural DDR3
// port, on volumes shortened to 4 blocks (LAST_BLK = 3).
//
// From reset: the card comes up, the config (slot 0 in drive 1, slot 1 in
// drive 2) is read and both slots stream into the DDR3 with CMD18; loading
// drops and both drives are present.  Then a block written back from the
// DDR3 lands in the right sector, an eject rewrites the config, and mounting
// slot 1 in drive 1 reloads it.  A second instance with no card must give
// up (err) and drop `loading`, so a missing card cannot hold the CPU.
module tb_sdvol;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;

    wire sd_clk, sd_mosi, sd_miso, sd_cs_n;
    sdcard #(.SECTORS(8192)) card (.sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n), .sd_miso(sd_miso));

    wire        m_go, m_we;
    wire [24:0] m_addr;
    wire [15:0] m_wdata;
    reg  [15:0] m_rdata = 16'h0;
    reg         m_ack = 1'b0;
    wire [15:0] slot0, slot1;
    wire [1:0]  present;
    wire        loading, busy, err;
    wire [2:0]  estage;
    reg         wb_go = 1'b0, wb_drv = 1'b0, mnt_go = 1'b0, mnt_drv = 1'b0;
    reg  [15:0] wb_blk = 16'd0, mnt_slot = 16'd0;

    sd_vol #(.PWR_BITS(8), .LAST_BLK(16'd3)) dut (
        .clk(clk), .reset(reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .ddr_ready(1'b1),
        .m_go(m_go), .m_addr(m_addr), .m_we(m_we), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack),
        .slot0(slot0), .slot1(slot1), .present(present),
        .loading(loading), .busy(busy), .err(err), .estage(estage),
        .wb_go(wb_go), .wb_drv(wb_drv), .wb_blk(wb_blk),
        .mnt_go(mnt_go), .mnt_drv(mnt_drv), .mnt_slot(mnt_slot)
    );

    // No card: MISO floats high through the pull-up
    wire        n_loading, n_err;
    sd_vol #(.PWR_BITS(8), .LAST_BLK(16'd3)) nocard (
        .clk(clk), .reset(reset),
        .sd_clk(), .sd_mosi(), .sd_miso(1'b1), .sd_cs_n(),
        .ddr_ready(1'b1),
        .m_go(), .m_addr(), .m_we(), .m_wdata(), .m_rdata(16'h0), .m_ack(1'b0),
        .slot0(), .slot1(), .present(), .loading(n_loading), .busy(), .err(n_err), .estage(),
        .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd0), .mnt_go(1'b0), .mnt_drv(1'b0), .mnt_slot(16'd0)
    );

    // DDR3: two drives x 4 blocks x 256 words; a slow-ish answer, random waits
    reg [15:0] ddr [0:2047];
    function [10:0] di(input [24:0] a); di = {a[24], a[9:0]}; endfunction  // drive, block[1:0], word
    reg        pend = 1'b0;
    reg [4:0]  t = 0;
    reg [24:0] a_q;
    reg        we_q;
    reg [15:0] d_q;
    integer fails = 0, i, b, k;
    always @(posedge clk) begin
        m_ack <= 1'b0;
        if (m_go) begin
            if (pend) begin $display("FAIL: request while one is out"); fails = fails + 1; end
            if (m_addr[23:10] != 14'd0) begin $display("FAIL: block %0d past the bench's 4", m_addr[23:8]); fails = fails + 1; end
            pend <= 1'b1; t <= 0; a_q <= m_addr; we_q <= m_we; d_q <= m_wdata;
        end else if (pend) begin
            t <= t + 1'b1;
            if (t == 5'd20 + ($random & 5'd7)) begin
                pend <= 1'b0; m_ack <= 1'b1;
                if (we_q) ddr[di(a_q)] <= d_q; else m_rdata <= ddr[di(a_q)];
            end
        end
    end

    function [7:0] pat(input integer slot, input integer blk, input integer k);
        pat = slot * 101 + blk * 37 + k * 3 + (k >> 8);
    endfunction
    // sector of block b of slot s, as the model folds it
    function integer sec(input integer s, input integer b); sec = 2048 + b + (s ? 4096 : 0); endfunction

    task check_drive(input integer drv, input integer slot);
        begin
            for (b = 0; b < 4; b = b + 1)
                for (k = 0; k < 512; k = k + 1)
                    if ((k[0] ? ddr[{drv[0], b[1:0], k[8:1]}][15:8] : ddr[{drv[0], b[1:0], k[8:1]}][7:0]) !== pat(slot, b, k)) begin
                        if (fails < 10) $display("FAIL: drive %0d block %0d byte %0d, want slot %0d", drv, b, k, slot);
                        fails = fails + 1;
                    end
        end
    endtask

    task wait_idle; begin @(posedge clk); while (busy) @(posedge clk); end endtask

    initial begin
        for (i = 0; i < 2048; i = i + 1) ddr[i] = 16'hDEAD;
        for (i = 0; i < 512; i = i + 1) card.mem[i] = 8'h00;
        card.mem[0] = "A"; card.mem[1] = "2"; card.mem[2] = "H"; card.mem[3] = "D";
        card.mem[4] = 8'h00; card.mem[5] = 8'h00; card.mem[6] = 8'h01; card.mem[7] = 8'h00;
        for (b = 0; b < 5; b = b + 1)
            for (k = 0; k < 512; k = k + 1) begin
                card.mem[sec(0, b) * 512 + k] = pat(0, b, k);
                card.mem[sec(1, b) * 512 + k] = pat(1, b, k);
            end
        #200; @(posedge clk); reset = 1'b0;

        // ---- power-on load ----
        @(posedge clk); while (loading) @(posedge clk);
        if (err) begin $display("FAIL: err, stage %0d", estage); fails = fails + 1; end
        if (present !== 2'b11) begin $display("FAIL: present %b after the load", present); fails = fails + 1; end
        if (slot0 !== 16'd0 || slot1 !== 16'd1) begin $display("FAIL: slots %h %h", slot0, slot1); fails = fails + 1; end
        if (card.rblks < 8) begin $display("FAIL: %0d sectors streamed, want 8 or more", card.rblks); fails = fails + 1; end
        check_drive(0, 0);
        check_drive(1, 1);
        $display("load: %0t ns for 2 x 4 blocks", $time);

        // ---- write-back: drive 2 block 2 ----
        for (k = 0; k < 256; k = k + 1) ddr[{1'b1, 2'd2, k[7:0]}] = {k[7:0] ^ 8'h5A, k[7:0]};
        @(posedge clk); wb_go <= 1'b1; wb_drv <= 1'b1; wb_blk <= 16'd2;
        @(posedge clk); wb_go <= 1'b0;
        wait_idle;
        for (k = 0; k < 512; k = k + 1)
            if (card.mem[sec(1, 2) * 512 + k] !== (k[0] ? (k[8:1] ^ 8'h5A) : k[8:1])) begin
                if (fails < 10) $display("FAIL: written-back byte %0d = %02x", k, card.mem[sec(1, 2) * 512 + k]);
                fails = fails + 1;
            end
        if (card.mem[sec(1, 1) * 512] !== pat(1, 1, 0) || card.mem[sec(1, 3) * 512] !== pat(1, 3, 0)) begin
            $display("FAIL: write-back touched a neighbouring sector"); fails = fails + 1;
        end

        // ---- eject drive 1, then mount slot 1 in it ----
        @(posedge clk); mnt_go <= 1'b1; mnt_drv <= 1'b0; mnt_slot <= 16'hFFFF;
        @(posedge clk); mnt_go <= 1'b0;
        wait_idle;
        if (present !== 2'b10) begin $display("FAIL: present %b after the eject", present); fails = fails + 1; end
        if ({card.mem[5], card.mem[4], card.mem[7], card.mem[6]} !== 32'hFFFF0001 ||
            {card.mem[0], card.mem[1], card.mem[2], card.mem[3]} !== "A2HD") begin
            $display("FAIL: config after the eject"); fails = fails + 1;
        end
        for (k = 0; k < 2048; k = k + 1) ddr[k] = 16'hDEAD;
        for (k = 0; k < 512; k = k + 1) card.mem[sec(1, 2) * 512 + k] = pat(1, 2, k);   // undo the write-back
        @(posedge clk); mnt_go <= 1'b1; mnt_drv <= 1'b0; mnt_slot <= 16'h0001;
        @(posedge clk); mnt_go <= 1'b0;
        wait_idle;
        if (present !== 2'b01) begin $display("FAIL: present %b after mounting slot 1 in drive 1", present); fails = fails + 1; end
        // slot 1 was in drive 2, so drive 2 let it go
        if (slot0 !== 16'd1 || slot1 !== 16'hFFFF) begin $display("FAIL: slots %h %h", slot0, slot1); fails = fails + 1; end
        if ({card.mem[5], card.mem[4], card.mem[7], card.mem[6]} !== 32'h0001FFFF) begin
            $display("FAIL: config %02x%02x %02x%02x", card.mem[5], card.mem[4], card.mem[7], card.mem[6]); fails = fails + 1;
        end
        check_drive(0, 1);
        if (err) begin $display("FAIL: err, stage %0d", estage); fails = fails + 1; end

        // ---- no card ----
        while (n_loading) @(posedge clk);
        if (!n_err) begin $display("FAIL: no card, but no err"); fails = fails + 1; end

        if (card.errs != 0) begin $display("FAIL: %0d card protocol errors", card.errs); fails = fails + 1; end
        if (fails == 0) $display("tb_sdvol: PASS");
        else            $display("tb_sdvol: FAIL (%0d)", fails);
        $finish;
    end

    initial begin #500_000_000; $display("FAIL: timeout (st=%0d ph=%0d blk=%0d)", dut.st, dut.ph, dut.blk); $finish; end
endmodule
