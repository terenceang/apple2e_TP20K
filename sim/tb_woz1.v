`timescale 1ns / 1ps
`default_nettype none

// tb_woz1.v -- verify WOZ1 file loading, track lookup, and bit playback in disk2_store
module tb_woz1;
    reg clk = 1'b0;
    always #18.5 clk = ~clk;
    reg reset = 1'b1;

    reg        drive = 1'b0;
    reg [7:0]  qtr = 8'd0;
    reg        bit_tick = 1'b0;
    wire       rd_bit, rd_ok;
    wire [1:0] drv_present, drv_writable;

    reg         up_go = 1'b0;
    reg         up_drive = 1'b0;
    reg [19:0]  up_addr = 20'd0;
    reg [7:0]   up_data = 8'd0;
    reg         up_last = 1'b0;
    reg         up_ro = 1'b0;
    wire        up_busy, up_done;

    wire        dsk_go, dsk_we;
    wire [21:0] dsk_addr;
    wire [15:0] dsk_wdata;
    reg  [15:0] dsk_rdata = 16'h0000;
    reg         dsk_ack = 1'b0;

    disk2_store store (
        .clk(clk), .reset(reset),
        .drive(drive), .qtr(qtr), .bit_tick(bit_tick), .wr_en(1'b0), .wr_bit(1'b0),
        .wr_mode(1'b0), .rd_bit(rd_bit), .rd_ok(rd_ok),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .fl_wr(), .fl_wr_drv(), .fl_wr_blk(),
        .up_go(up_go), .up_drive(up_drive), .up_addr(up_addr), .up_data(up_data), .up_last(up_last),
        .up_ro(up_ro), .up_bad(1'b0), .up_busy(up_busy), .up_done(up_done),
        .down_go(1'b0), .down_drive(1'b0), .down_addr(20'd0), .down_data(), .down_valid(),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack)
    );

    // Simulated DDR3 memory (256K words = 512KB)
    reg [15:0] mem [0:262143];
    reg        pend = 1'b0;
    reg [3:0]  lat = 4'd0;
    reg [21:0] la;
    reg        lwe;
    reg [15:0] lwd;

    always @(posedge clk) begin
        dsk_ack <= 1'b0;
        if (dsk_go) begin
            pend <= 1'b1; lat <= 4'd4; la <= dsk_addr; lwe <= dsk_we; lwd <= dsk_wdata;
        end else if (pend) begin
            if (lat != 4'd0) lat <= lat - 4'd1;
            else begin
                pend <= 1'b0; dsk_ack <= 1'b1;
                if (lwe) mem[la[18:0]] <= lwd;
                else dsk_rdata <= mem[la[18:0]];
            end
        end
    end

    integer fails = 0, checks = 0;
    task check(input [8*72-1:0] what, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin $display("FAIL: %0s", what); fails = fails + 1; end
        end
    endtask

    // Upload a byte into store
    task send_byte(input [19:0] a, input [7:0] d, input last);
        begin
            @(posedge clk);
            up_go <= 1'b1; up_drive <= 1'b0; up_addr <= a; up_data <= d; up_last <= last;
            @(posedge clk);
            while (!up_done) @(posedge clk);
            up_go <= 1'b0; up_last <= 1'b0;
            @(posedge clk);
            while (up_busy) @(posedge clk);
        end
    endtask

    integer i;
    reg [15:0] bit_buf;
    initial begin
        $display("=== tb_woz1 ===");
        for (i = 0; i < 262144; i = i + 1) mem[i] = 16'h0000;
        #200 @(posedge clk); reset = 1'b0;
        @(posedge clk);

        // Upload header: "WOZ1", INFO, TMAP, and Track 0
        // Header
        send_byte(20'd0, "W", 0);
        send_byte(20'd1, "O", 0);
        send_byte(20'd2, "Z", 0);
        send_byte(20'd3, "1", 0); // triggers is_woz1[0] <= 1
        for (i = 4; i < 88; i = i + 1) send_byte(i, 8'h00, 0);

        // TMAP: quarter track 0 -> track index 0, quarter track 4 -> track index 1
        send_byte(20'd88, 8'd0, 0);   // qtr 0 -> trk 0
        send_byte(20'd89, 8'd0, 0);   // qtr 1 -> trk 0
        send_byte(20'd90, 8'd0, 0);   // qtr 2 -> trk 0
        send_byte(20'd91, 8'd0, 0);   // qtr 3 -> trk 0
        send_byte(20'd92, 8'd1, 0);   // qtr 4 -> trk 1
        for (i = 93; i < 248; i = i + 1) send_byte(i, 8'hFF, 0); // others unmapped

        // Byte 248..255: TRKS header
        send_byte(20'd248, "T", 0);
        send_byte(20'd249, "R", 0);
        send_byte(20'd250, "K", 0);
        send_byte(20'd251, "S", 0);
        for (i = 252; i < 256; i = i + 1) send_byte(i, 8'h00, 0);

        // Track 0 data: starts at byte 256.
        // Let's write distinct pattern at track 0: bytes 0xAA, 0x55, 0xD5, 0xAA ...
        send_byte(20'd256, 8'hA5, 0);
        send_byte(20'd257, 8'h5A, 0);
        send_byte(20'd258, 8'hF0, 0);
        send_byte(20'd259, 8'h0F, 0);

        // Write bit_cnt for Track 0 at relative byte 6648 (abs byte 256 + 6648 = 6904)
        // bit_cnt = 50000 (0xC350) -> low byte 0x50, high byte 0xC3
        send_byte(20'd6904, 8'h50, 0);
        send_byte(20'd6905, 8'hC3, 0);

        // Track 1 data: starts at byte 256 + 6656 = 6912.
        // Word 0 (bytes 6912, 6913): bits 0..15
        send_byte(20'd6912, 8'h11, 0);
        send_byte(20'd6913, 8'h22, 0);
        // Word 1 (bytes 6914, 6915): bits 16..31
        send_byte(20'd6914, 8'h33, 0);
        send_byte(20'd6915, 8'hCC, 0);
        // Write bit_cnt for Track 1 at relative byte 6648 (abs byte 6912 + 6648 = 13560)
        // bit_cnt = 32 -> low byte 0x20, high byte 0x00 (test wrapping after 32 bits!)
        send_byte(20'd13560, 8'h20, 0);
        send_byte(20'd13561, 8'h00, 1); // last byte

        check("drive present", drv_present[0] === 1'b1);
        check("is_woz1 detected", store.is_woz1[0] === 1'b1);

        // Head is at qtr 0: wait for track lookup
        qtr <= 8'd0;
        repeat (100) @(posedge clk);
        check("track 0 lookup ok", store.lk_ok === 1'b1);
        check("track 0 tv valid", store.tv === 1'b1);
        check("track 0 t_base is word 128", store.t_base === 19'd128);
        check("track 0 t_bits is 50000", store.t_bits === 20'd50000);
        check("track 0 rd_ok", rd_ok === 1'b1);

        // Read 16 bits from track 0: even byte is low half (0xA5), odd is high (0x5A)
        // MSB first: 0xA5 = 10100101, then 0x5A = 01011010
        for (i = 15; i >= 0; i = i - 1) begin
            bit_buf[i] = rd_bit;
            @(posedge clk); bit_tick <= 1'b1;
            @(posedge clk); bit_tick <= 1'b0;
            repeat (2) @(posedge clk);
        end
        check("track 0 first 8 bits match 8'hA5", bit_buf[15:8] === 8'hA5);
        check("track 0 next 8 bits match 8'h5A", bit_buf[7:0] === 8'h5A);

        // Now move head to qtr 4 (track 1)
        qtr <= 8'd4;
        repeat (100) @(posedge clk);
        check("track 1 lookup ok", store.lk_ok === 1'b1);
        check("track 1 tv valid", store.tv === 1'b1);
        check("track 1 t_base is word 3456", store.t_base === 19'd3456); // 128 + 3328 = 3456
        check("track 1 t_bits is 32", store.t_bits === 20'd32);
        check("track 1 rd_ok", rd_ok === 1'b1);

        // Read 16 bits from track 1 at pos 16 (Word 1): byte 0x33, then 0xCC
        for (i = 15; i >= 0; i = i - 1) begin
            bit_buf[i] = rd_bit;
            @(posedge clk); bit_tick <= 1'b1;
            @(posedge clk); bit_tick <= 1'b0;
            repeat (2) @(posedge clk);
        end
        check("track 1 Word 1 first 8 bits match 8'h33", bit_buf[15:8] === 8'h33);
        check("track 1 Word 1 next 8 bits match 8'hCC", bit_buf[7:0] === 8'hCC);

        // Now pos has reached 32, which wraps to 0 (Word 0: 0x11, 0x22)
        repeat (10) @(posedge clk);
        for (i = 15; i >= 0; i = i - 1) begin
            bit_buf[i] = rd_bit;
            @(posedge clk); bit_tick <= 1'b1;
            @(posedge clk); bit_tick <= 1'b0;
            repeat (2) @(posedge clk);
        end
        check("track 1 Word 0 (wrapped) first 8 bits match 8'h11", bit_buf[15:8] === 8'h11);
        check("track 1 Word 0 (wrapped) next 8 bits match 8'h22", bit_buf[7:0] === 8'h22);

        // Move head to unmapped qtr (qtr 8)
        qtr <= 8'd8;
        repeat (50) @(posedge clk);
        check("unmapped track lookup ok", store.lk_ok === 1'b1);
        check("unmapped track tv is false", store.tv === 1'b0);
        check("unmapped track rd_ok is false", rd_ok === 1'b0);

        if (fails == 0) $display("tb_woz1: PASS (%0d checks)", checks);
        else $display("tb_woz1: FAIL (%0d errors of %0d checks)", fails, checks);
        $finish;
    end
endmodule
`default_nettype wire
