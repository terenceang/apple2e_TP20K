`timescale 1ns / 1ps
`default_nettype none

module tb_dhires_test;
    reg clk = 1'b0;
    always #18.519 clk = ~clk; // 27 MHz (clk_pixel)

    reg mem_clk = 1'b0;
    always #1.2555 mem_clk = ~mem_clk; // 400 MHz DDR3 clock

    reg reset = 1'b1;

    // Softswitches
    reg text_mode = 1'b0;
    reg mixed_mode = 1'b0;
    reg page2 = 1'b0;
    reg hires_mode = 1'b1;
    reg col80 = 1'b1;
    reg dhires = 1'b1;
    reg altchar = 1'b0;
    reg store80 = 1'b0;

    // Raster counters
    reg [9:0] pixel_x = 10'd0;
    reg [9:0] pixel_y = 10'd0;

    // Wires between video and aux_ram
    wire        aux_fill_start;
    wire [15:0] aux_fill_addr;
    wire [5:0]  aux_col;
    wire [7:0]  aux_line_data;

    // CPU port to aux_ram
    reg         wr_go = 1'b0;
    reg  [16:0] wr_addr = 17'd0;
    reg  [7:0]  wr_data = 8'd0;
    wire        wr_busy;

    reg         rd_want = 1'b0;
    reg  [16:0] rd_addr = 17'd0;
    wire [7:0]  rd_data;
    wire        rd_hit;
    wire        ready;

    // Main RAM model
    reg [7:0] main_ram [0:65535];
    wire        vram_req;
    wire [15:0] vram_addr;
    reg  [7:0]  vram_data = 8'd0;
    reg  [7:0]  ram_dout = 8'd0;
    reg         vram_req_d = 1'b0;

    always @(posedge clk) begin
        ram_dout   <= main_ram[vram_addr];
        vram_req_d <= vram_req;
        if (vram_req_d)
            vram_data <= ram_dout;
    end

    // Video generator
    wire [7:0] red, green, blue;
    video_generator u_video (
        .clk_pixel(clk),
        .reset(reset),
        .flash_clk(1'b0),
        .h_cnt(pixel_x + 10'd1),
        .v_cnt(pixel_y),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .col80(col80),
        .altchar(altchar),
        .dhires(dhires),
        .store80(store80),
        .aux_data(aux_line_data),
        .aux_col(aux_col),
        .aux_fill_addr(aux_fill_addr),
        .aux_fill_start(aux_fill_start),
        .vram_req(vram_req),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .char_rom_addr(),
        .char_rom_data(8'h00),
        .red(red),
        .green(green),
        .blue(blue),
        .vbl()
    );

    wire [15:0] ddr_dq;
    wire [1:0]  ddr_dqs, ddr_dqs_n;

    aux_ram u_aux (
        .clk(clk),
        .reset(reset),
        .ddr_clk(clk),
        .fill_start(aux_fill_start),
        .fill_addr(aux_fill_addr),
        .col(aux_col),
        .line_data(aux_line_data),
        .rd_want(rd_want),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .rd_hit(rd_hit),
        .wr_go(wr_go),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .wr_busy(wr_busy),
        .dsk_go(1'b0), .dsk_addr(22'd0), .dsk_we(1'b0), .dsk_wdata(16'd0),
        .dsk_rdata(), .dsk_ack(), .dsk_idle(),
        .hd_go(1'b0), .hd_addr(25'd0), .hd_we(1'b0), .hd_be(2'b11), .hd_wdata(16'd0),
        .hd_rdata(), .hd_ack(),
        .ready(ready),
        .diag(),
        .ddr_memory_clk(mem_clk),
        .ddr_lock(1'b1),
        .DDR3_DQ(ddr_dq),
        .DDR3_DQS(ddr_dqs),
        .DDR3_DQS_n(ddr_dqs_n),
        .DDR3_A(), .DDR3_BA(), .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(),
        .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(), .DDR3_CKE(), .DDR3_nRESET(),
        .DDR3_ODT(), .DDR3_DM()
    );

    task cpu_aux_write(input [15:0] addr, input [7:0] val);
        begin
            @(posedge clk);
            while (wr_busy) @(posedge clk);
            wr_go <= 1'b1;
            wr_addr <= {1'b0, addr};
            wr_data <= val;
            @(posedge clk);
            wr_go <= 1'b0;
            @(posedge clk);
        end
    endtask

    integer c, r;

    initial begin
        $display("Starting tb_dhires_test...");
        #200;
        @(posedge clk);
        reset = 1'b0;

        // Wait for DDR3 ready
        while (!ready) @(posedge clk);
        $display("DDR3 ready at %t", $time);

        // Populate line 0 of DHires Page 1:
        // In Apple II hires, line 0 is at base $2000:
        // Even columns (0, 2, 4...) are in Aux RAM at $2000 + col/2
        // Odd columns (1, 3, 5...) are in Main RAM at $2000 + col/2
        // Total 40 bytes in Aux RAM, 40 bytes in Main RAM.
        // Let's put distinct values:
        // Aux RAM gets 8'hA0 + col (e.g. $A0, $A1, $A2...)
        // Main RAM gets 8'h50 + col (e.g. $50, $51, $52...)
        for (c = 0; c < 40; c = c + 1) begin
            cpu_aux_write(16'h2000 + c, 8'hA0 + c[7:0]);
            main_ram[16'h2000 + c] = 8'h50 + c[7:0];
        end

        // Wait a few clocks for writes to settle
        repeat (50) @(posedge clk);

        $display("Memory written. Now running scanline 47 (pre-fill) and scanline 48 (line 0)...");

        // Scanlines 47 to 60:
        for (r = 47; r < 60; r = r + 1) begin
            pixel_y = r;
            for (pixel_x = 0; pixel_x < 858; pixel_x = pixel_x + 1) begin
                @(posedge clk);
            end
            $display("Scanline %0d done. aux_fill_addr=0x%04x linebuf[0]=0x%02x linebuf[1]=0x%02x",
                     r, u_video.aux_fill_addr, u_aux.linebuf[0], u_aux.linebuf[1]);
        end

        $display("Test finished.");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT in tb_dhires_test");
        $finish;
    end

endmodule
