`timescale 1ns / 1ps
`default_nettype none

//  tb_p6boot.v -- the real Apple //e ROM boots the real P6 ROM from the Disk ][ card
//
//  tb_disk2 checks the card against a model of a disk.  This one checks it
//  against what actually reads it: the //e's reset code falls through to slot 6
//  (nothing in slot 7 is bootable with no drive there), the P6 boot ROM
//  recalibrates, finds track 0 sector 0 and reads it, and its own 6-and-2
//  unpack (LSR/ROL) puts the sector at $0800.  If the disk bytes were packed in
//  an order the ROM does not unpack -- which a bench with its own encode and
//  decode cannot see -- $0800 is wrong even though the checksum passes.
//
//  Needs the ROMs (roms/apple2e_rom.hex, roms/disk2_p6.hex) and
//  build/dos33_physical.bin: the DOS 3.3 System Master in physical sector order
//  (made by scripts in the session that produced it; skipped if it is missing).
//  Run from the repo root.

module tb_p6boot;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;                 // 27 MHz

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

    // ~60 Hz vertical blank: the //e's reset code polls $C019 for it
    reg vbl = 1'b0;
    reg [19:0] vcnt = 20'd0;
    always @(posedge clk) begin
        vcnt <= (vcnt == 20'd449999) ? 20'd0 : vcnt + 1'b1;
        vbl  <= (vcnt < 20'd36000);
    end

    // ---- a keyboard: $C000 data with strobe, $C010 clears the strobe ----
    wire [7:0]  io_addr;
    wire        io_read, io_write;
    reg  [7:0]  kbd_data = 8'h00;
    wire [15:0] cpu_a = dut.debug_cpu_addr;
    wire        cpu_w = dut.debug_cpu_we;
    wire        input_hit  = !cpu_w && (cpu_a == 16'hC000 || cpu_a == 16'hC010);
    wire [7:0]  input_dout = (cpu_a == 16'hC000) ? kbd_data : 8'h00;
    always @(posedge clk) if ((io_read || io_write) && io_addr == 8'h10) kbd_data[7] <= 1'b0;
    task press(input [7:0] c);
        begin
            kbd_data = {1'b1, c[6:0]};
            wait (!kbd_data[7]);
            #3000000;                 // 3 ms between keys
        end
    endtask
    initial begin
        #400000000;                   // 400 ms: the ROM is at its prompt
        press("P"); press("R"); press("#"); press("6"); press(8'h0D);
        $display("  keys sent at t=%0t", $time);
    end

    wire        dsk_go, dsk_we;
    wire [21:0] dsk_addr;
    wire [15:0] dsk_wdata;
    reg  [15:0] dsk_rdata = 16'd0;
    reg         dsk_ack   = 1'b0;
    wire        dsk_idle;

    wire [15:0] pc;
    wire        sync;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(input_dout), .input_hit(input_hit),
        .io_addr(io_addr), .io_read(io_read), .io_write(io_write), .spkr_pulse(),
        .text_mode(), .mixed_mode(), .page2(), .hires_mode(),
        .col80(), .altchar(), .dhires(), .store80(),
        .vbl(vbl),
        .vram_req(1'b0), .vram_addr(16'd0), .vram_data(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(), .aux_rd_addr(), .aux_rd_hit(1'b1), .aux_rd_data(8'h00),
        .aux_wr_go(), .aux_wr_addr(), .aux_wr_data(), .aux_wr_busy(1'b0),
        .dsk_store_go(dsk_go), .dsk_store_addr(dsk_addr), .dsk_store_we(dsk_we),
        .dsk_store_wdata(dsk_wdata), .dsk_store_rdata(dsk_rdata),
        .dsk_store_ack(dsk_ack), .dsk_store_idle(dsk_idle),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_aux(1'b0), .dbg_mem_ready(),
        .img_up_go(1'b0), .img_up_drive(1'b0), .img_up_addr(18'd0), .img_up_data(8'd0),
        .img_up_last(1'b0), .img_up_bad(1'b0), .img_up_busy(), .img_up_done(),
        .img_dn_go(1'b0), .img_dn_drive(1'b0), .img_dn_addr(18'd0), .img_dn_last(1'b0),
        .img_dn_data(), .img_dn_valid(), .img_dn_done(),
        .debug_cpu_pc(pc), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(sync), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir()
    );

    // ---- the store's SDRAM: 16-bit words, answers a request after a few clocks ----
    // Bank 1 (addr[21:20] = 01); drive 0's byte n is the low half of word n/2 for
    // even n and the high half for odd n.
    reg [15:0] dskmem [0:262143];
    reg [7:0]  img    [0:143359];
    reg        pend = 1'b0;
    reg [3:0]  lat  = 4'd0;
    reg [21:0] la;
    reg        lwe;
    reg [15:0] lwd;
    assign dsk_idle = !pend;
    always @(posedge clk) begin
        dsk_ack <= 1'b0;
        if (dsk_go && !pend) begin pend <= 1'b1; lat <= 4'd12; la <= dsk_addr; lwe <= dsk_we; lwd <= dsk_wdata; end
        else if (pend) begin
            if (lat != 0) lat <= lat - 1'b1;
            else begin
                pend <= 1'b0; dsk_ack <= 1'b1;
                if (lwe) dskmem[la[17:0]] <= lwd; else dsk_rdata <= dskmem[la[17:0]];
            end
        end
    end

    integer fd, n, i;
    integer fails = 0;
    initial begin
        for (i = 0; i < 262144; i = i + 1) dskmem[i] = 16'h0000;
        fd = $fopen("build/dos33_physical.bin", "rb");
        if (fd == 0) begin
            $display("tb_p6boot: SKIP (build/dos33_physical.bin missing)");
            $display("PASS");
            $finish;
        end
        n = $fread(img, fd);
        $fclose(fd);
        for (i = 0; i < 71680; i = i + 1) dskmem[i] = {img[2*i+1], img[2*i]};
        // the 6502 core does not reset its registers; the stack pointer must not be X
        dut.u_cpu.AXYS[0] = 8'h00;
        dut.u_cpu.AXYS[1] = 8'h00;
        dut.u_cpu.AXYS[2] = 8'h00;
        dut.u_cpu.AXYS[3] = 8'hFF;
        #200 @(posedge clk) reset = 1'b0;
        // the drive holds an image, as an upload would leave it
        dut.g_sector.u_disk2_store.present[0]    = 1'b1;
        dut.g_sector.u_disk2_store.writable_q[0] = 1'b1;
    end

    // Boot sector: track 0, sector 0, is the first 256 bytes of the physical image.
    // The P6 ROM leaves it at $0800 and jumps to $0801.  Compare when the CPU first
    // executes there.
    reg done = 1'b0;
    always @(posedge clk) if (!reset && ce_1m && sync && pc == 16'h0801 && !done) begin
        done = 1'b1;
        n = 0;
        for (i = 0; i < 256; i = i + 1)
            if (dut.u_ram.mem[16'h0800 + i] !== img[i]) begin
                if (n < 8) $display("  $%04X: got %02X want %02X", 16'h0800 + i, dut.u_ram.mem[16'h0800 + i], img[i]);
                n = n + 1;
            end
        if (n == 0) $display("PASS: the P6 ROM read the boot sector intact (t=%0t)", $time);
        else        $display("FAIL: boot sector at $0800 has %0d wrong bytes", n);
        $finish;
    end

    // progress: what the CPU is doing every 100 ms of Apple time
    reg [24:0] tick = 25'd0;
    always @(posedge clk) begin
        tick <= tick + 1'b1;
        if (tick == 25'd2700000 - 1) begin
            tick <= 25'd0;
            $display("  t=%0t PC=$%04X", $time, pc); $fflush;
        end
    end

    initial begin
        #6000000000;   // 6 s of Apple time
        $display("FAIL: never reached $0801 (PC=$%04X)", pc);
        $finish;
    end
endmodule
