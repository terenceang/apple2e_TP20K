`timescale 1ns / 1ps
`default_nettype none

// Aux RAM stress: apple2_core + aux_ram (on sim/models/ddr3_model.v) + the
// video generator, running generated 6502 code from language-card RAM
// ($E000-, the same copy in main and aux LC so ALTZP cannot pull it away)
// that mixes RAMRD/RAMWRT/ALTZP/80STORE/PAGE2/HIRES, LC banks and loads,
// stores and RMWs everywhere.  Every CPU cycle is checked against an
// independent model of the //e MMU (Sather, Understanding the Apple IIe, ch.5).
// Needs roms/apple2e_rom.hex.
module tb_auxstress;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;
    reg mem_clk = 1'b0;
    always #2.5 mem_clk = ~mem_clk;   // 200 MHz: a slower DDR side than the board, for sim speed

    reg reset = 1'b1;
    reg [4:0] ce_div = 5'd0;
    wire ce_1m = (ce_div == 5'd25);
    always @(posedge clk) ce_div <= (ce_div == 5'd25) ? 5'd0 : ce_div + 1'b1;

    reg [9:0] px = 10'd0, py = 10'd0;
    always @(posedge clk) begin
        if (px == 10'd857) begin px <= 10'd0; py <= (py == 10'd524) ? 10'd0 : py + 1'b1; end
        else px <= px + 1'b1;
    end

    wire text_mode, mixed_mode, page2, hires_mode, dhires, store80;
    wire [15:0] vram_addr; wire vram_req; wire [7:0] vram_data;
    wire aux_fill_start; wire [15:0] aux_fill_addr; wire [5:0] aux_col; wire [7:0] aux_line_data;
    wire aux_rd_want, aux_rd_hit, aux_wr_go, aux_wr_busy, ready;
    wire [16:0] aux_rd_addr, aux_wr_addr; wire [7:0] aux_rd_data, aux_wr_data;
    wire [15:0] ddr_dq; wire [1:0] ddr_dqs, ddr_dqs_n;

    apple2_core dut (
        .clk(clk), .reset(reset), .ce_1m(ce_1m),
        .input_dout(8'h00), .input_hit(1'b0),
        .io_addr(), .io_read(), .io_write(), .spkr_pulse(),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .col80(), .altchar(), .dhires(dhires), .store80(store80),
        .vbl(1'b0), .clk_set(1'b0), .clk_time(52'd0),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .fl_wr(), .fl_wr_drv(), .fl_wr_blk(),
        .char_rom_addr(12'd0), .char_rom_data(),
        .aux_rd_want(aux_rd_want), .aux_rd_addr(aux_rd_addr), .aux_rd_hit(aux_rd_hit),
        .aux_rd_data(aux_rd_data),
        .aux_wr_go(aux_wr_go), .aux_wr_addr(aux_wr_addr), .aux_wr_data(aux_wr_data),
        .aux_wr_busy(aux_wr_busy),
        .dsk_store_go(), .dsk_store_addr(), .dsk_store_we(), .dsk_store_wdata(),
        .dsk_store_rdata(16'd0), .dsk_store_ack(1'b0),
        .hd_present(2'b00), .hd_go(), .hd_addr(), .hd_we(), .hd_be(), .hd_wdata(),
        .hd_rdata(16'd0), .hd_ack(1'b0), .hd_wb_go(), .hd_wb_drv(), .hd_wb_blk(),
        .hd_rb_go(), .hd_rb_ok(1'b0), .hd_size0(16'd0), .hd_size1(16'd0), .hd_sd_busy(1'b0),
        .cpu_rdy(1'b1), .dbg_mem_addr(16'd0), .dbg_mem_din(), .dbg_mem_ready(),
        .img_up_go(1'b0), .img_up_drive(1'b0), .img_up_addr(18'd0), .img_up_data(8'd0),
        .img_up_last(1'b0), .img_up_bad(1'b0), .img_up_busy(), .img_up_done(),
        .img_dn_go(1'b0), .img_dn_drive(1'b0), .img_dn_addr(18'd0),
        .img_dn_data(), .img_dn_valid(),
        .debug_dsk_head(), .debug_cpu_pc(), .debug_cpu_addr(), .debug_cpu_dout(), .debug_cpu_we(),
        .debug_cpu_sync(), .debug_cpu_a(), .debug_cpu_x(), .debug_cpu_y(),
        .debug_cpu_s(), .debug_cpu_p(), .debug_cpu_ir()
    );

    aux_ram u_aux (
        .clk(clk), .reset(reset), .ddr_clk(clk),
        .fill_start(aux_fill_start), .fill_addr(aux_fill_addr), .col(aux_col),
        .line_data(aux_line_data),
        .rd_want(aux_rd_want), .rd_addr(aux_rd_addr), .rd_data(aux_rd_data), .rd_hit(aux_rd_hit),
        .wr_go(aux_wr_go), .wr_addr(aux_wr_addr), .wr_data(aux_wr_data), .wr_busy(aux_wr_busy),
        .dsk_go(1'b0), .dsk_addr(22'd0), .dsk_we(1'b0), .dsk_wdata(16'd0),
        .dsk_rdata(), .dsk_ack(), .dsk_idle(),
        .hd_go(1'b0), .hd_addr(25'd0), .hd_we(1'b0), .hd_be(2'b11), .hd_wdata(16'd0),
        .hd_rdata(), .hd_ack(), .ready(ready), .diag(),
        .ddr_memory_clk(mem_clk), .ddr_lock(1'b1),
        .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_DQS_n(ddr_dqs_n),
        .DDR3_A(), .DDR3_BA(), .DDR3_nCS(), .DDR3_nRAS(), .DDR3_nCAS(),
        .DDR3_nWE(), .DDR3_CK(), .DDR3_CK_n(), .DDR3_CKE(), .DDR3_nRESET(),
        .DDR3_ODT(), .DDR3_DM()
    );

    video_generator u_video (
        .clk_pixel(clk), .reset(reset), .flash_clk(1'b0),
        .h_cnt(px + 10'd1), .v_cnt(py),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2),
        .hires_mode(hires_mode), .col80(dut.col80), .altchar(1'b0),
        .dhires(dhires), .store80(store80), .color_tv(1'b0), .scanlines(2'd0),
        .aux_data(aux_line_data), .aux_col(aux_col),
        .aux_fill_addr(aux_fill_addr), .aux_fill_start(aux_fill_start),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .char_rom_addr(), .char_rom_data(8'h00),
        .red(), .green(), .blue(), .vbl()
    );

    // ---------------- reference model ----------------
    reg [7:0] m_main [0:49151];
    reg [7:0] m_aux  [0:49151];
    reg [7:0] m_lc   [0:2*16384-1];   // {aux, D000 bank1 | D000 bank2 | E000-FFFF}
    reg s80, srd, swr, szp, sp2, shr, lbank2, lread, lwen, lpre;

    function [15:0] lcix(input aux, input [15:0] a, input bk2);
        lcix = {1'b0, aux, (a < 16'hE000) ? {1'b0, bk2, a[11:0]} : {1'b1, a[12:0]}};
    endfunction

    // ---------------- program generator ----------------
    localparam ORG = 16'hE000, PEND = 16'hFF00;
    reg [15:0] pc;
    integer seed = 1;
    task emit(input [7:0] b);
        begin
            m_lc[lcix(1'b0, pc, 1'b0)] = b;
            m_lc[lcix(1'b1, pc, 1'b0)] = b;
            pc = pc + 1;
        end
    endtask
    function [15:0] rnd_addr(input dummy);
        integer r;
        begin
            r = $unsigned($random(seed)) % 16;
            case (r)
                0, 1:    rnd_addr = $unsigned($random(seed)) % 16'h0200;           // ZP/stack
                2, 3, 4: rnd_addr = 16'h0400 + $unsigned($random(seed)) % 16'h0400; // text page
                5, 6, 7: rnd_addr = 16'h2000 + $unsigned($random(seed)) % 16'h2000; // HGR1
                8, 9:    rnd_addr = 16'h4000 + $unsigned($random(seed)) % 16'h2000; // HGR2
                10, 11:  rnd_addr = 16'hD000 + $unsigned($random(seed)) % 16'h1000; // LC banked
                default: rnd_addr = 16'h0200 + $unsigned($random(seed)) % 16'hBD00;
            endcase
            // keep a 3-byte instruction ($D000 window) and abs,X off I/O and code
            if (rnd_addr >= 16'hBF00 && rnd_addr < 16'hD000) rnd_addr = 16'h1234;
            if (rnd_addr >= 16'hDF00 && rnd_addr < 16'hE000) rnd_addr = 16'hD800;
        end
    endfunction
    task emit_abs(input [7:0] op, input [15:0] a); begin emit(op); emit(a[7:0]); emit(a[15:8]); end endtask

    integer r, n;
    reg [15:0] a;
    initial begin
        for (n = 0; n < 49152; n = n + 1) begin m_main[n] = 0; m_aux[n] = 0; end
        for (n = 0; n < 32768; n = n + 1) m_lc[n] = 0;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        pc = ORG;
        while (pc < PEND - 16) begin
            r = $unsigned($random(seed)) % 32;
            a = rnd_addr(0);
            case (r)
                0, 1, 2, 3:   emit_abs(8'h8D, 16'hC000 + ($unsigned($random(seed)) % 10)); // 80STORE RAMRD RAMWRT INTCXROM ALTZP
                4:            emit_abs(8'h8D, 16'hC054 + ($unsigned($random(seed)) % 4));  // PAGE2, HIRES
                5:            emit_abs(8'h8D, 16'hC00C + ($unsigned($random(seed)) % 2));  // 80COL
                6:            emit_abs(8'h8D, 16'hC05E + ($unsigned($random(seed)) % 2));  // DHIRES
                7:            emit_abs(8'h8D, 16'hC050 + ($unsigned($random(seed)) % 2));  // TEXT
                8: begin      // LC: read RAM always (code is there); bank and write-enable vary
                    case ($unsigned($random(seed)) % 5)
                        0: begin emit_abs(8'hAD, 16'hC083); emit_abs(8'hAD, 16'hC083); end
                        1: begin emit_abs(8'hAD, 16'hC08B); emit_abs(8'hAD, 16'hC08B); end
                        2: emit_abs(8'hAD, 16'hC080);
                        3: emit_abs(8'hAD, 16'hC088);
                        // a write between the two reads resets PRE-WRITE: from
                        // write-protected ($C088), $C08B read/write/read stays
                        // protected, so the store below must not land
                        4: begin emit_abs(8'hAD, 16'hC088);
                                 emit_abs(8'hAD, 16'hC08B); emit_abs(8'h8D, 16'hC08B); emit_abs(8'hAD, 16'hC08B);
                                 emit(8'hA9); emit($random(seed));
                                 emit_abs(8'h8D, 16'hD123); emit_abs(8'hAD, 16'hD123); end
                    endcase
                end
                9, 10:        begin emit(8'hA9); emit($random(seed)); end            // LDA #
                11:           begin emit(8'hA2); emit($random(seed)); end            // LDX #
                12, 13, 14, 15: emit_abs(8'hAD, a);                                  // LDA abs
                16, 17, 18, 19: emit_abs(8'h8D, a);                                  // STA abs
                20, 21:       emit_abs(8'hEE, a);                                    // INC abs
                22, 23:       emit_abs(8'hBD, a);                                    // LDA abs,X
                24, 25:       emit_abs(8'h9D, a);                                    // STA abs,X
                26:           emit_abs(8'h1E, a);                                    // ASL abs,X
                27:           begin emit(8'h8D); emit(8'h00); emit(8'h20);           // STA $2000; LDA $2000
                                    emit(8'hAD); emit(8'h00); emit(8'h20); end
                28:           begin emit_abs(8'h8D, a); emit_abs(8'hAD, a); end      // store then load back
                29:           begin emit(8'h48); emit(8'h68); end                    // PHA PLA
                30:           begin emit(8'hA5); emit($random(seed)); end            // LDA zp
                31:           begin emit(8'h85); emit($random(seed)); end            // STA zp
            endcase
        end
        emit_abs(8'h4C, ORG);
        $display("program: %0d bytes", pc - ORG);
    end

    // load the program into the DDR3 model (main LC {1,addr}, aux LC {0,addr}; low byte of each word)
    task ddr_put(input [16:0] w, input [7:0] b);
        reg [127:0] q;
        begin
            q = u_aux.u_ddr3.mem[{2'b00, w[16:3]}];
            q[16 * w[2:0] +: 8] = b;
            u_aux.u_ddr3.mem[{2'b00, w[16:3]}] = q;
        end
    endtask

    // ---------------- checker ----------------
    integer fails = 0, cycles = 0, checked = 0, auxhits = 0;
    reg        chk = 1'b0;
    reg [7:0]  want;
    reg [15:0] ca;
    reg        a_aux;

    always @(posedge clk) if (!reset && dut.cpu_go) begin
        ca = dut.cpu_addr;
        cycles = cycles + 1;
        if (cycles % 2000 == 0) begin $display("progress %0d fails %0d aux %0d", cycles, fails, auxhits); $fflush; end
        chk = 1'b0;
        // which bank this access uses
        if (ca < 16'h0200) a_aux = szp;
        else if (ca < 16'hC000)
            a_aux = (s80 && ((ca >= 16'h0400 && ca < 16'h0800) || (shr && ca >= 16'h2000 && ca < 16'h4000)))
                  ? sp2 : (dut.cpu_we ? swr : srd);
        else a_aux = szp;

        if (dut.cpu_we) begin
            if (ca < 16'hC000) begin
                if (a_aux) m_aux[ca] = dut.cpu_dout; else m_main[ca] = dut.cpu_dout;
                if (a_aux) auxhits = auxhits + 1;
            end else if (ca >= 16'hD000 && lwen)
                m_lc[lcix(a_aux, ca, lbank2)] = dut.cpu_dout;
        end else begin
            if (ca < 16'hC000) begin
                want = a_aux ? m_aux[ca] : m_main[ca]; chk = 1'b1;
                if (a_aux) auxhits = auxhits + 1;
            end else if (ca >= 16'hD000 && lread) begin
                want = m_lc[lcix(a_aux, ca, lbank2)]; chk = 1'b1;
            end
        end

        // softswitches
        if (ca[15:8] == 8'hC0) begin
            if (dut.cpu_we && ca[7:4] == 4'h0)
                case (ca[3:1])
                    3'd0: s80 = ca[0];
                    3'd1: srd = ca[0];
                    3'd2: swr = ca[0];
                    3'd4: szp = ca[0];
                    default: ;
                endcase
            if (ca[7:1] == 7'h2A) sp2 = ca[0];      // $C054/5
            if (ca[7:1] == 7'h2B) shr = ca[0];      // $C056/7
            if (ca[7:4] == 4'h8) begin
                lbank2 = !ca[3];
                lread  = (ca[1] == ca[0]);
                if (!ca[0]) begin lwen = 0; lpre = 0; end
                else if (!dut.cpu_we) begin if (lpre) lwen = 1; lpre = 1; end
                else lpre = 0;
            end
        end

        #1;
        if (chk) begin
            checked = checked + 1;
            if (dut.cpu_din !== want) begin
                fails = fails + 1;
                if (fails <= 20)
                    $display("FAIL: cycle %0d read $%04x (%s, 80S=%0d RD=%0d WR=%0d ZP=%0d P2=%0d HR=%0d LC b2=%0d) got %02x want %02x  t=%0t",
                             cycles, ca, a_aux ? "aux" : "main", s80, srd, swr, szp, sp2, shr, lbank2,
                             dut.cpu_din, want, $time);
            end
        end
    end

    // ROM stub at $FF00 (ROM index $3F00)
    localparam [95:0] stub = 96'hA2_FF_9A_AD_83_C0_AD_83_C0_4C_00_E0;
    initial begin
        {s80, srd, swr, szp, sp2, shr, lbank2, lread, lwen, lpre} = 10'b0;
        #1;
        dut.u_rom.mem[14'h3FFC] = 8'h00; dut.u_rom.mem[14'h3FFD] = 8'hFF;
        // LDX #$FF, TXS, LDA $C083 x2, JMP $E000
        for (n = 0; n < 12; n = n + 1)
            dut.u_rom.mem[14'h3F00 + n] = stub[8 * (11 - n) +: 8];
        force dut.u_cpu.IRQ = 1'b0;
        // the stub's tail runs from LC RAM once $C083 has switched it in
        for (n = 0; n < 12; n = n + 1) begin
            ddr_put({1'b1, 16'hFF00 + n[15:0]}, dut.u_rom.mem[14'h3F00 + n]);
            ddr_put({1'b0, 16'hFF00 + n[15:0]}, dut.u_rom.mem[14'h3F00 + n]);
            m_lc[lcix(1'b0, 16'hFF00 + n[15:0], 1'b0)] = dut.u_rom.mem[14'h3F00 + n];
            m_lc[lcix(1'b1, 16'hFF00 + n[15:0], 1'b0)] = dut.u_rom.mem[14'h3F00 + n];
        end
        for (n = ORG; n < PEND; n = n + 1) begin
            ddr_put({1'b1, n[15:0]}, m_lc[lcix(1'b0, n[15:0], 1'b0)]);
            ddr_put({1'b0, n[15:0]}, m_lc[lcix(1'b1, n[15:0], 1'b0)]);
        end
        while (!ready) @(posedge clk);
        repeat (10) @(posedge clk);
        reset = 1'b0;
    end

    // a CPU that stops stepping is a failure too
    integer idle = 0;
    always @(posedge clk) if (!reset) begin
        idle = dut.cpu_go ? 0 : idle + 1;
        if (idle == 100000) begin
            $display("FAIL: CPU stuck at cycle %0d, addr $%04x we=%0d stall=%0d hit=%0d want=%0d wr_busy=%0d diag=%08x",
                     cycles, dut.cpu_addr, dut.cpu_we, dut.aux_stall, aux_rd_hit, aux_rd_want, aux_wr_busy, u_aux.diag);
            $finish;
        end
    end

    integer limit;
    initial begin
        if (!$value$plusargs("cycles=%d", limit)) limit = 12000;
        wait (cycles >= limit || fails > 20);
        $display("%0d cycles, %0d reads checked, %0d aux accesses, %0d failures", cycles, checked, auxhits, fails);
        if (fails == 0 && checked > limit / 4 && auxhits > 1000) $display("PASS");
        else $display("FAIL: tb_auxstress");
        $finish;
    end
endmodule
