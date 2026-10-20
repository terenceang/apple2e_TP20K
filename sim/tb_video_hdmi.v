// ============================================================================
//  tb_video_hdmi.v -- Apple video and colour bars through hdmi_tx, pixel exact
//
//  Wires video_generator and colorbar_gen to hdmi_tx exactly as src/top.v
//  does (video_generator gets pixel_x + 1 because its output is registered,
//  colorbar_gen is combinational on pixel_x), with behavioural models of the
//  RAM and character ROM that reproduce apple2_core's read timing: RAM data
//  one clock after the address, latched into vram_data on the following clock
//  when vram_req was high, character ROM data one clock after its address.
//
//  The TMDS lanes are decoded like a sink: a video data period starts after
//  the two-character video guard band, each of its 720 symbols is a pixel,
//  lines are counted from the first video period after a vsync pulse.  Every
//  decoded pixel of a whole frame is checked against an independent model
//  of what the screen should show:
//    * frame A: Apple 40x24 text page 1 filled with a known pattern, drawn
//      with a synthetic character ROM, centred at x 80..639, y 48..431, with
//      a black border,
//    * frame B: the colour bar pattern (S1 held in top.v).
//  It also checks the AVI InfoFrame declares full-range RGB, as the Apple
//  palette needs.
//  An off-by-one in the video_generator look-ahead shows up as every glyph
//  edge moving by one pixel, so this is mainly an alignment check.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_video_hdmi;
    `include "sim/include/hdmi_ref.vh"

    reg clk = 1'b0;
    always #18.519 clk = ~clk;              // 27 MHz

    reg rst_n = 1'b0;
    reg bars  = 1'b0;                       // 0: Apple video, 1: colour bars
    reg text_mode = 1'b1, mixed_mode = 1'b0, page2 = 1'b0, hires_mode = 1'b0;
    reg hgr_phase = 1'b0;                   // expect Hi-Res (page 2, mixed) instead of text
    reg col80 = 1'b0, store80 = 1'b0, dhires = 1'b0, altchar = 1'b0;
    reg dh_phase   = 1'b0;                  // expect double hi-res page 1
    reg wide_phase = 1'b0;                  // expect 80-column text (aux char first)
    reg skip      = 1'b0;                   // frame in which the mode changes: not checked
    reg [15:0] txt_base = 16'h0400;         // text page the model reads

    // -----------------------------------------------------------------------
    // DUT wiring, as in src/top.v
    // -----------------------------------------------------------------------
    wire [9:0]  pixel_x, pixel_y;
    wire [7:0]  vid_r, vid_g, vid_b;
    wire [23:0] bar_rgb;
    wire        vram_req, vbl;
    wire [15:0] vram_addr;
    reg  [7:0]  vram_data;
    reg  [7:0]  aux_data;
    wire [11:0] char_rom_addr;
    reg  [7:0]  char_rom_data;

    video_generator u_video (
        .clk_pixel(clk), .reset(!rst_n), .flash_clk(1'b0),
        .h_cnt(pixel_x + 10'd1), .v_cnt(pixel_y),
        .text_mode(text_mode), .mixed_mode(mixed_mode), .page2(page2), .hires_mode(hires_mode),
        .col80(col80), .altchar(altchar), .dhires(dhires), .store80(store80), .aux_data(aux_data),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .char_rom_addr(char_rom_addr), .char_rom_data(char_rom_data),
        .red(vid_r), .green(vid_g), .blue(vid_b), .vbl(vbl)
    );

    colorbar_gen u_bars (
        .clk_pixel(clk), .reset(!rst_n), .x(pixel_x), .y(pixel_y), .rgb(bar_rgb)
    );

    wire [29:0] tmds;
    hdmi_tx #(.RGB_QUANT(2'b10)) u_tx (
        .clk_pixel(clk), .rst_n(rst_n),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .video_rgb(bars ? bar_rgb : {vid_r, vid_g, vid_b}),
        .audio_valid(1'b0), .audio_l(16'd0), .audio_r(16'd0),
        .tmds(tmds)
    );

    // -----------------------------------------------------------------------
    // Memory models (apple2_core timing)
    // -----------------------------------------------------------------------
    reg [7:0] ram [0:65535];
    reg [7:0] crom [0:4095];
    reg [7:0] aux_ram [0:65535];
    reg [7:0] ram_dout, aux_ram_dout;
    reg       vram_req_d;

    always @(posedge clk) begin
        ram_dout      <= ram[vram_addr];
        aux_ram_dout  <= aux_ram[vram_addr];
        vram_req_d    <= vram_req;
        if (vram_req_d) begin
            vram_data <= ram_dout;
            aux_data  <= aux_ram_dout;
        end
        char_rom_data <= crom[char_rom_addr];
    end

    // Text row base offsets, from the Apple II memory map.
    function [15:0] row_base;
        input [4:0] r;
        begin
            row_base = {6'd0, r[2:0], 7'd0} + (r[4:3] * 16'd40);
        end
    endfunction

    // Expected colour of screen pixel (x, y), independent of the RTL.
    function [23:0] expect_apple;
        input integer x, y;
        integer col, dot, ay, row, gr;
        reg [7:0] c, g;
        reg [11:0] a;
        begin
            if (x < 80 || x >= 640 || y < 48 || y >= 432) begin
                expect_apple = 24'h000000;
            end else begin
                col = (x - 80) / 14;
                dot = ((x - 80) % 14) / 2;
                ay  = (y - 48) / 2;
                row = ay / 8;
                gr  = ay % 8;
                c   = ram[txt_base + row_base(row) + col];
                // Character ROM address as the //e video ROM wiring (flash off)
                a   = {1'b0, c[7], c[6] & (c[7] | altchar), c[5:0], gr[2:0]};
                g   = crom[a];
                // A CLEAR bit in the character ROM is a lit dot: the 2732 is
                // active-low. Normal glyphs are stored complemented (the 'A'
                // that $C1 reads is F7 EB DD DD C1 DD DD FF, space is all FF),
                // and the inverse half is stored the other way round.
                // web/test/charset.test.js pins the same convention against the
                // real 342-0265-A dump.
                expect_apple = ~g[dot] ? 24'h20E820 : 24'h020602;
            end
        end
    endfunction

    // 80-column text page 1: 7 one-clock dots per character, aux character
    // in the left half of each 14-pixel slot, main in the right.
    function [23:0] expect_apple80;
        input integer x, y;
        integer col, d, ay, row, gr;
        reg [7:0] c, g;
        reg [11:0] a;
        begin
            if (x < 80 || x >= 640 || y < 48 || y >= 432) begin
                expect_apple80 = 24'h000000;
            end else begin
                col = (x - 80) / 14;
                d   = (x - 80) % 14;
                ay  = (y - 48) / 2;
                row = ay / 8;
                gr  = ay % 8;
                c   = (d < 7) ? aux_ram[16'h0400 + row_base(row) + col]
                              : ram[16'h0400 + row_base(row) + col];
                a   = {1'b0, c[7], c[6] & (c[7] | altchar), c[5:0], gr[2:0]};
                g   = crom[a];
                expect_apple80 = ~g[(d < 7) ? d : d - 7] ? 24'h20E820 : 24'h020602;
            end
        end
    endfunction

    // Hi-Res page 2: the 560-sample stream of the line at byte offset lbase,
    // as the Apple's shift register emits it (7 dots per byte, 2 samples per
    // dot; a byte with bit 7 set is delayed one sample, so its first sample
    // repeats the previous dot). Zero outside 0..559.
    function hgr_sample;
        input integer lbase, n;
        integer c, k, h;
        reg     b7;
        begin
            if (n < 0 || n >= 560) hgr_sample = 1'b0;
            else begin
                c  = n / 14;
                k  = (n % 14) / 2;
                h  = n % 2;
                b7 = ram[16'h4000 + lbase + c][7];
                if (b7 && h == 0) begin
                    // previous dot: same byte, or the last dot of the byte before
                    if (k > 0)      hgr_sample = ram[16'h4000 + lbase + c][k - 1];
                    else if (c > 0) hgr_sample = ram[16'h4000 + lbase + c - 1][6];
                    else            hgr_sample = 1'b0;
                end else begin
                    hgr_sample = ram[16'h4000 + lbase + c][k];
                end
            end
        end
    endfunction

    function integer clamp255;
        input integer v;
        clamp255 = (v < 0) ? 0 : (v > 255) ? 255 : v;
    endfunction

    // Expected colour: decode samples n-2..n+1 as an NTSC set would. Luma is
    // 64 per lit sample; chroma I = s@ph0 - s@ph2, Q = s@ph1 - s@ph3 (ph =
    // sample index mod 4); channel weights per video_generator.v.
    function [23:0] expect_hgr;
        input integer x, y;
        integer ay, lbase, n, m, ph, yy, ci, cq, cr, cg, cb;
        reg s;
        begin
            ay = (y - 48) / 2;
            if (x < 80 || x >= 640 || y < 48 || y >= 432) expect_hgr = 24'h000000;
            else if (ay >= 160)                            expect_hgr = expect_apple(x, y);
            else begin
                lbase = (ay % 8) * 1024 + ((ay / 8) % 8) * 128 + (ay / 64) * 40;
                n = x - 80;
                yy = 0; ci = 0; cq = 0;
                for (m = n - 2; m <= n + 1; m = m + 1) begin
                    s  = hgr_sample(lbase, m);
                    ph = (m + 4) % 4;
                    if (s) begin
                        yy = yy + 1;
                        case (ph)
                            0: ci = ci + 1;
                            1: cq = cq + 1;
                            2: ci = ci - 1;
                            3: cq = cq - 1;
                        endcase
                    end
                end
                cr = clamp255(64 * yy + 80 * ci);
                cg = clamp255(64 * yy - 41 * ci - 20 * cq);
                cb = clamp255(64 * yy + 101 * cq);
                expect_hgr = {cr[7:0], cg[7:0], cb[7:0]};
            end
        end
    endfunction

    // Double hi-res page 1: 560 one-clock dots per line, aux byte's bits 0..6
    // then the main byte's, 14 per column; same NTSC window as expect_hgr.
    function dhgr_sample;
        input integer lbase, n;
        integer c, d;
        reg [7:0] b;
        begin
            if (n < 0 || n >= 560) dhgr_sample = 1'b0;
            else begin
                c = n / 14; d = n % 14;
                b = (d < 7) ? aux_ram[16'h2000 + lbase + c] : ram[16'h2000 + lbase + c];
                dhgr_sample = b[(d < 7) ? d : d - 7];
            end
        end
    endfunction

    function [23:0] expect_dhgr;
        input integer x, y;
        integer ay, lbase, n, m, ph, yy, ci, cq, cr, cg, cb;
        reg s;
        begin
            ay = (y - 48) / 2;
            if (x < 80 || x >= 640 || y < 48 || y >= 432) expect_dhgr = 24'h000000;
            else begin
                lbase = (ay % 8) * 1024 + ((ay / 8) % 8) * 128 + (ay / 64) * 40;
                n = x - 80;
                yy = 0; ci = 0; cq = 0;
                for (m = n - 2; m <= n + 1; m = m + 1) begin
                    s  = dhgr_sample(lbase, m);
                    ph = (m + 4) % 4;
                    if (s) begin
                        yy = yy + 1;
                        case (ph)
                            0: ci = ci + 1;
                            1: cq = cq + 1;
                            2: ci = ci - 1;
                            3: cq = cq - 1;
                        endcase
                    end
                end
                cr = clamp255(64 * yy + 80 * ci);
                cg = clamp255(64 * yy - 41 * ci - 20 * cq);
                cb = clamp255(64 * yy + 101 * cq);
                expect_dhgr = {cr[7:0], cg[7:0], cb[7:0]};
            end
        end
    endfunction

    function [23:0] expect_bars;
        input integer x, y;
        begin
            if (x < 40 && y < 40)                            expect_bars = 24'hxxxxxx;
            else if (x == 0 || x == 719 || y == 0 || y == 479) expect_bars = 24'hFFFFFF;
            else case (x / 90)
                0: expect_bars = 24'hFFFFFF;
                1: expect_bars = 24'hFFFF00;
                2: expect_bars = 24'h00FFFF;
                3: expect_bars = 24'h00FF00;
                4: expect_bars = 24'hFF00FF;
                5: expect_bars = 24'hFF0000;
                6: expect_bars = 24'h0000FF;
                default: expect_bars = 24'h000000;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Sink: decode the three lanes
    // -----------------------------------------------------------------------
    wire [9:0] s0 = tmds[9:0], s1 = tmds[19:10], s2 = tmds[29:20];
    wire [2:0] c0 = ctrl_dec(s0);
    wire       vgb = (s0 == REF_VGB_02) && (s1 == REF_GB_1) && (s2 == REF_VGB_02);

    integer x = -1, y = -1, gb_run = 0, frame = -1;
    integer errors = 0, checked = 0;
    reg     in_vs = 1'b0, saw_vs = 1'b0;
    reg [23:0] got, want;

    always @(posedge clk) if (rst_n) begin
        // vsync on the wire is negative: ch0 control D1 = 0 during the pulse.
        in_vs = c0[2] && !c0[1];
        if (in_vs) saw_vs = 1'b1;

        if (x >= 0) begin
            got  = {tmds_dec(s2), tmds_dec(s1), tmds_dec(s0)};
            want = bars ? expect_bars(x, y) : hgr_phase ? expect_hgr(x, y) :
                   dh_phase ? expect_dhgr(x, y) :
                   wide_phase ? expect_apple80(x, y) : expect_apple(x, y);
            if (frame >= 1 && !skip && want !== 24'hxxxxxx) begin
                checked = checked + 1;
                if (got !== want) begin
                    if (errors < 10)
                        $display("FAIL: %s frame %0d pixel (%0d,%0d) = %06h, expected %06h",
                                 bars ? "bars" : "apple", frame, x, y, got, want);
                    errors = errors + 1;
                end
            end
            x = (x == 719) ? -1 : x + 1;
        end

        gb_run = vgb ? gb_run + 1 : 0;
        if (gb_run == 2) begin
            if (saw_vs) begin
                y      = 0;
                frame  = frame + 1;
                saw_vs = 1'b0;
            end else if (y >= 0) begin
                y = y + 1;
            end
            if (y >= 0) x = 0;
        end
    end

    // AVI InfoFrame as pushed to the scheduler: full-range RGB (PB3 Q = 10)
    // and a checksum making header + PB0..PB13 sum to zero.
    integer n_avi = 0, k;
    reg [7:0] avi_sum;
    always @(posedge clk) if (rst_n && u_tx.src_valid && u_tx.src_ready &&
                              u_tx.src_header[7:0] == 8'h82) begin
        n_avi   = n_avi + 1;
        avi_sum = u_tx.src_header[7:0] + u_tx.src_header[15:8] + u_tx.src_header[23:16];
        for (k = 0; k <= 13; k = k + 1) avi_sum = avi_sum + u_tx.src_body[8*k +: 8];
        if (u_tx.src_body[8*3 +: 8] !== 8'h08 || avi_sum !== 8'h00) begin
            $display("FAIL: AVI PB3 = %02h (want 08), checksum residue %02h",
                     u_tx.src_body[8*3 +: 8], avi_sum);
            errors = errors + 1;
        end
    end

    // -----------------------------------------------------------------------
    // The real character ROM, when it has been supplied
    //
    // The synthetic ROM above proves the *addressing* -- a wrong row, code or
    // bank shows up as the wrong dots. It cannot prove the *polarity*, because
    // a synthetic ROM has no letters in it. So also read the real 2732 and
    // check the two things that settle how it is read: glyph $20, which is what
    // $A0 (space) resolves to, must be all ones, and glyph 1, which is what
    // $C1 ('A') resolves to because char_rom_addr carries only six bits of the
    // code, must be a capital A read with a clear bit meaning a lit dot.
    //
    // 342-0265-A, 4 KB. Run the video generator's expression by hand rather than
    // through the generator, so this stays fast and independent.
    // -----------------------------------------------------------------------
    reg [7:0] realrom [0:4095];
    reg       realrom_ok = 1'b0;
    reg [7:0] real_file [0:65535];
    integer   probe_fd;
    // Declared before any use (this iverilog rejects declaration-after-use)
    integer i, frame_a_checked, bars_checked;
    initial begin
        // $readmemh cannot report failure, so look for the file first.
        probe_fd = $fopen("roms/apple2e_char.hex", "r");
        if (probe_fd == 0) begin
            $display("tb_video_hdmi: no roms/apple2e_char.hex, skipping the real-ROM check");
        end else begin
            $fclose(probe_fd);
            $readmemh("roms/apple2e_char.hex", real_file);
            for (i = 0; i < 4096; i = i + 1) realrom[i] = real_file[i];
            realrom_ok = 1'b1;
            $display("tb_video_hdmi: read the real 2732 from roms/apple2e_char.hex");
        end
    end

    // $20 -> char_rom_addr bits [8:3] = 6'b100000 -> 0x100, so bytes 0x100..0x107
    // $41 -> bits [8:3] = 6'b000001 -> 0x008, so bytes 0x008..0x00F
    function [7:0] real_glyph_row;
        input [15:0] code;
        input [2:0]  row;
        reg [11:0] a;
        begin
            // {1'b0, code[7], code[6]&code[7], code[5:0], row}, flash off
            a = {1'b0, code[7], code[6] & code[7], code[5:0], row};
            real_glyph_row = realrom[a];
        end
    endfunction

    task check_real_rom;
        integer r;
        reg [7:0] arow [0:7];
        begin
            // space: blank
            for (r = 0; r < 8; r = r + 1) arow[r] = real_glyph_row(16'h00A0, r[2:0]);
            for (r = 0; r < 8; r = r + 1) begin
                if (arow[r] !== 8'hFF) begin
                    $display("FAIL: real ROM space row %0d is %02h, not FF", r, arow[r]);
                    errors = errors + 1;
                end
            end
            // 'A' at glyph 1, active-low
            for (r = 0; r < 8; r = r + 1) arow[r] = real_glyph_row(16'h00C1, r[2:0]);
            if (arow[0] !== 8'hF7 || arow[1] !== 8'hEB || arow[4] !== 8'hC1 ||
                arow[7] !== 8'hFF) begin
                $display("FAIL: real ROM 'A' rows are %02h %02h %02h ... %02h, expected F7 EB .. C1 .. FF",
                         arow[0], arow[1], arow[2], arow[7]);
                errors = errors + 1;
            end
            // ALTCHARSET reads the $200 block for $40-$7F (video_generator.v's
            // char_rom_addr): $41 is MouseText, $61 an inverse lowercase 'a'
            // (stored the inverse-half way round, so set bits are lit).
            for (r = 0; r < 8; r = r + 1) arow[r] = realrom[{1'b0, 1'b0, 1'b1, 6'd1, r[2:0]}];
            if (arow[0] !== 8'hEF || arow[3] !== 8'hBE || arow[7] !== 8'hC9) begin
                $display("FAIL: real ROM alt $41 rows %02h .. %02h .. %02h, expected EF .. BE .. C9",
                         arow[0], arow[3], arow[7]);
                errors = errors + 1;
            end
            for (r = 0; r < 8; r = r + 1) arow[r] = realrom[{1'b0, 1'b0, 1'b1, 6'd33, r[2:0]}];
            if (arow[2] !== 8'h1C || arow[3] !== 8'h20 || arow[4] !== 8'h3C) begin
                $display("FAIL: real ROM alt $61 rows %02h %02h %02h, expected 1C 20 3C",
                         arow[2], arow[3], arow[4]);
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        if (realrom_ok) check_real_rom();
        // Synthetic char ROM: every glyph row distinct, so a wrong address
        // (row, code or bank) shows up as a different dot pattern.
        for (i = 0; i < 4096; i = i + 1)
            crom[i] = (i * 8'd37) ^ (i >> 5) ^ 8'h5A;
        for (i = 0; i < 65536; i = i + 1) begin
            ram[i] = 8'h00;
            aux_ram[i] = 8'h00;
        end
        // Text page 1: distinct code per screen position.
        for (i = 0; i < 24 * 40; i = i + 1)
            ram[16'h0400 + row_base(i / 40) + (i % 40)] = (i * 7 + 3) & 8'hFF;

        // Text page 2 and both HGR pages, distinct from text page 1.
        for (i = 0; i < 24 * 40; i = i + 1)
            ram[16'h0800 + row_base(i / 40) + (i % 40)] = (i * 11 + 5) & 8'hFF;
        for (i = 0; i < 8192; i = i + 1) begin
            ram[16'h2000 + i] = 8'hFF;
            ram[16'h4000 + i] = (i * 37) ^ (i >> 3) ^ 8'h6D;
        end

        // Solid colour lines (page 2): 2A/55 is green, 2A/55 with bit 7 orange
        // (AA/D5), D5/AA... and 7F/7F white. They are checked below against
        // the palette, on top of the frame comparison against the model.
        for (i = 0; i < 40; i = i + 1) begin
            ram[16'h4000 + 3 * 1024 + i] = (i % 2) ? 8'h55 : 8'h2A;
            ram[16'h4000 + 4 * 1024 + i] = (i % 2) ? 8'hD5 : 8'hAA;
            ram[16'h4000 + 5 * 1024 + i] = (i % 2) ? 8'h2A : 8'h55;
            ram[16'h4000 + 6 * 1024 + i] = 8'h7F;
        end

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // Frame 0 settles the sink; frame 1 is checked as Apple video.
        wait (frame == 2);
        frame_a_checked = checked;
        bars = 1'b1;
        wait (frame == 3);
        if (frame_a_checked != 720 * 480) begin
            $display("FAIL: checked %0d Apple pixels, expected %0d", frame_a_checked, 720 * 480);
            errors = errors + 1;
        end
        // The first bars frame ran from frame 2's start; check that it
        // produced a full frame of pixels (liveness box excluded).
        if (checked - frame_a_checked != 720 * 480 - 40 * 40) begin
            $display("FAIL: checked %0d bar pixels, expected %0d",
                     checked - frame_a_checked, 720 * 480 - 40 * 40);
            errors = errors + 1;
        end
        if (n_avi < 2) begin
            $display("FAIL: %0d AVI InfoFrames sent", n_avi);
            errors = errors + 1;
        end
        $display("%0d pixels checked (%0d Apple text, %0d colour bars)",
                 checked, frame_a_checked, checked - frame_a_checked);

        // Hi-Res, page 2, mixed mode: the frame the switches change in is not
        // checked (the pipeline is mid-flight); the next one is, in full.
        // Page 1 HGR and text page 1 hold different data, so a wrong page
        // shows up as wrong pixels.
        bars_checked = checked;
        skip = 1'b1; bars = 1'b0; hgr_phase = 1'b1;
        text_mode = 1'b0; mixed_mode = 1'b1; page2 = 1'b1; hires_mode = 1'b1;
        txt_base = 16'h0800;
        wait (frame == 4);
        skip = 1'b0;
        wait (frame == 5);
        if (checked - bars_checked < 720 * 480 - 4 || checked - bars_checked > 720 * 480 + 4) begin
            $display("FAIL: checked %0d HGR pixels, expected about %0d",
                     checked - bars_checked, 720 * 480);
            errors = errors + 1;
        end
        $display("%0d Hi-Res pixels checked", checked - bars_checked);
        // Interior of each solid line, away from its ends: the palette.
        // (the model is exact per pixel; these pin its constants to real colours)
        if (expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 3) !== 24'h30BD1B ||   // green
            expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 5) !== 24'hD043E5 ||   // violet
            expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 6) !== 24'hFFFFFF) begin
            $display("FAIL: solid HGR lines are %06h %06h %06h, expected 30BD1B D043E5 FFFFFF",
                     expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 3),
                     expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 5),
                     expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 6));
            errors = errors + 1;
        end
        // bit 7 set: solid blue/orange, whichever sample phase the pixel is at
        if (expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 4) !== 24'hD06B1B &&
            expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 4) !== 24'h3095E5) begin
            $display("FAIL: bit-7 HGR line is %06h", expect_hgr(80 + 14 * 10 + 4, 48 + 2 * 4));
            errors = errors + 1;
        end
        // 80-column text, page 1: aux and main hold different characters.
        // store80 with page2 set must still show page 1.
        bars_checked = checked;
        for (i = 0; i < 24 * 40; i = i + 1)
            aux_ram[16'h0400 + row_base(i / 40) + (i % 40)] = (i * 13 + 9) & 8'hFF;
        skip = 1'b1; hgr_phase = 1'b0; wide_phase = 1'b1;
        text_mode = 1'b1; mixed_mode = 1'b0; hires_mode = 1'b0;
        page2 = 1'b1; store80 = 1'b1; col80 = 1'b1;
        wait (frame == 6);
        skip = 1'b0;
        wait (frame == 7);
        if (checked - bars_checked < 720 * 480 - 4 || checked - bars_checked > 720 * 480 + 4) begin
            $display("FAIL: checked %0d 80-col pixels, expected about %0d",
                     checked - bars_checked, 720 * 480);
            errors = errors + 1;
        end
        $display("%0d 80-column pixels checked", checked - bars_checked);
        // Double hi-res, page 1: 80COL + HIRES + AN3 cleared, graphics, no mixed.
        // Main and aux hold different data, so a swapped or missing aux byte
        // shows up as wrong dots.
        bars_checked = checked;
        for (i = 0; i < 8192; i = i + 1) begin
            ram[16'h2000 + i]     = (i * 29) ^ (i >> 2) ^ 8'h31;
            aux_ram[16'h2000 + i] = (i * 53) ^ (i >> 3) ^ 8'h4B;
        end
        skip = 1'b1; wide_phase = 1'b0; dh_phase = 1'b1;
        text_mode = 1'b0; mixed_mode = 1'b0; hires_mode = 1'b1;
        page2 = 1'b0; store80 = 1'b0; col80 = 1'b1; dhires = 1'b1;
        wait (frame == 8);
        skip = 1'b0;
        wait (frame == 9);
        if (checked - bars_checked < 720 * 480 - 4 || checked - bars_checked > 720 * 480 + 4) begin
            $display("FAIL: checked %0d double hi-res pixels, expected about %0d",
                     checked - bars_checked, 720 * 480);
            errors = errors + 1;
        end
        $display("%0d double hi-res pixels checked", checked - bars_checked);
        // ALTCHARSET on, 40 columns: $40-$7F read the $200 block instead of flashing.
        bars_checked = checked;
        skip = 1'b1; dh_phase = 1'b0; wide_phase = 1'b0;
        text_mode = 1'b1; hires_mode = 1'b0; col80 = 1'b0; dhires = 1'b0; page2 = 1'b0;
        altchar = 1'b1; txt_base = 16'h0400;
        wait (frame == 10);
        skip = 1'b0;
        wait (frame == 11);
        if (checked - bars_checked < 720 * 480 - 4 || checked - bars_checked > 720 * 480 + 4) begin
            $display("FAIL: checked %0d ALTCHARSET pixels, expected about %0d",
                     checked - bars_checked, 720 * 480);
            errors = errors + 1;
        end
        $display("%0d ALTCHARSET pixels checked", checked - bars_checked);
        if (errors == 0) $display("tb_video_hdmi: PASS");
        else             $display("tb_video_hdmi: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
