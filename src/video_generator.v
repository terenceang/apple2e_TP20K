// Apple //e Video Display Generator for Tang Primer 20K
// Formats 560x384 Apple II raster into standard CEA-861 720x480 @ 60Hz HDMI frame
//
// Raster timing, sync and blanking belong to hdmi_tx, which asks for each
// pixel's colour combinationally on the cycle it presents (pixel_x, pixel_y).
// This generator's colour output is registered, so top.v feeds it the
// position of the *next* pixel (h_cnt = pixel_x + 1): the colour computed
// for h_cnt this cycle is on red/green/blue the next cycle, exactly when
// hdmi_tx is at that pixel. h_cnt must step by one every clock (it runs
// through the blanking region too, wrapping via 1023 -> 0), since the
// column counter and prefetch sequence below count clocks, not positions.

module video_generator (
    input  wire        clk_pixel,    // 27.0 MHz
    input  wire        reset,
    input  wire        flash_clk,    // flashing text: changes every 16 frames (top.v)

    // Raster position of the next pixel, from hdmi_tx (see above)
    input  wire [9:0]  h_cnt,        // 0..719 active, >= 720 blanking
    input  wire [9:0]  v_cnt,        // 0..479 active, 480..524 blanking

    // Softswitches
    input  wire        text_mode,    // 1: Text, 0: Graphics
    input  wire        mixed_mode,   // 1: Bottom 4 lines are text
    input  wire        page2,        // 1: Page 2, 0: Page 1
    input  wire        hires_mode,   // 1: Hi-Res, 0: Lo-Res
    input  wire        col80,        // 1: 80-column text (aux byte first, then main)
    input  wire        dhires,       // AN3 off: with col80, double hi-res (HIRES) or double lo-res
    input  wire        altchar,      // 1: alternate character set (MouseText, no flashing)
    input  wire        store80,      // 1: 80STORE, PAGE2 no longer selects the display page
    input  wire        color_tv,     // 1: hi-res as a composite colour TV shows it (softer; key S3)
    input  wire [1:0]  scanlines,    // darken each Apple line's second copy: 0 off, 1 25%, 2 50%, 3 75% (key S4)
    input  wire [1:0]  mon_mode,     // 00: Color, 01: Mono Green (P31), 10: Mono Amber (P134), 11: Mono White (P4)

    // Video RAM interface (reads from main 64KB RAM)
    output wire        vram_req,
    output wire [15:0] vram_addr,
    input  wire [7:0]  vram_data,
    // Aux RAM byte at vram_addr, valid on the same clock as vram_data
    input  wire [7:0]  aux_data,
    // Aux line buffer control (see aux_ram.v): the column being fetched, and a
    // pulse in the blanking of the previous line asking for the 40 aux bytes
    // of the text row the next line shows.
    output wire [5:0]  aux_col,
    output wire [15:0] aux_fill_addr,
    output wire        aux_fill_start,

    // Character ROM interface
    output wire [11:0] char_rom_addr,
    input  wire [7:0]  char_rom_data,

    // Pixel colour to hdmi_tx, for the pixel one clock after h_cnt/v_cnt
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue,

    // Vertical blanking status for Apple II $C019 softswitch
    output wire        vbl
);

    // VBL status for Apple II ($C019: bit 7 = 1 during vertical blanking)
    // Apple II active area: 560x384 centered in 720x480
    // X: 80 .. 639 (560 pixels = 40 cols * 14 px) fetched; the decoder shows them at 84 .. 643
    // Y: 48 .. 431 (384 lines = 192 lines * 2)
    localparam [9:0] A2_X0 = 10'd80, A2_X1 = 10'd640; // first h_cnt in / past the Apple area
    localparam [9:0] A2_Y0 = 10'd48, A2_Y1 = 10'd432; // first v_cnt in / past the Apple area
    localparam [9:0] A2_PRE0 = A2_X0 - 10'd14;        // the pre-roll slot before column 0

    assign vbl = (v_cnt < A2_Y0) || (v_cnt >= A2_Y1);

    wire in_apple_x = (h_cnt >= A2_X0) && (h_cnt < A2_X1);
    wire in_apple_y = (v_cnt >= A2_Y0) && (v_cnt < A2_Y1);

    wire [8:0] a2_y = in_apple_y ? ((v_cnt - A2_Y0) >> 1) : 9'd0; // 0..191

    // Text row (0..23) and column (0..39)
    wire [4:0] text_row = a2_y[7:3];       // a2_y / 8
    wire [2:0] glyph_row = a2_y[2:0];      // a2_y % 8
    
    // 80-column text: each 14-clock slot shows two characters, aux then main,
    // 7 one-clock dots each. Only text lines are affected; graphics keep the
    // 40-column pipeline. The wide slot fetches one clock earlier (sub_col 8
    // instead of 9) so the ROM can be looked up twice: aux at sub_col 11,
    // main at 12. eff_sub is sub_col, extended to the pre-roll slot that runs
    // h_cnt 66..79 ahead of column 0 (there sub_col is parked at 0).
    wire is_text_line = text_mode || (mixed_mode && (text_row >= 5'd20));
    wire wide         = col80 && is_text_line;
    // Double hi-res shares the wide slot: an aux byte then a main byte per 14 clocks,
    // fetched at sub_col 8 so both are latched by sub_col 10.
    wire dh           = col80 && dhires && hires_mode && !is_text_line;
    wire pre          = (h_cnt >= A2_PRE0) && (h_cnt < A2_X0);
    wire slot_act     = in_apple_x || pre;
    // Column counter (0..39)
    reg [5:0] col_cnt;
    reg [3:0] sub_col; // 0..13 (14 cycles per character)
    wire [3:0] eff_sub = in_apple_x ? sub_col : (h_cnt - A2_PRE0);
    wire [3:0] req_sub = (wide || dh) ? 4'd8 : 4'd9;

    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            col_cnt <= 6'd0;
            sub_col <= 4'd0;
        end else if (in_apple_x) begin
            if (sub_col == 4'd13) begin
                sub_col <= 4'd0;
                col_cnt <= (col_cnt == 6'd39) ? 6'd0 : col_cnt + 1'b1;
            end else begin
                sub_col <= sub_col + 1'b1;
            end
        end else begin
            col_cnt <= 6'd0;
            sub_col <= 4'd0;
        end
    end

    // Next column to prefetch from RAM
    wire [5:0] fetch_col = (sub_col >= req_sub) ? ((col_cnt == 6'd39) ? 6'd0 : col_cnt + 1'b1) : col_cnt;

    // Apple II text/lores interleaved memory base address calculation:
    // Screen is split into 3 groups of 8 rows (each 128 bytes apart), offset by 40 bytes per group.
    function [6:0] row_group_offset(input [4:0] r);
        row_group_offset = (r[4:3] == 2'd1) ? 7'd40 :
                           (r[4:3] == 2'd2) ? 7'd80 : 7'd0;
    endfunction

    wire [6:0]  rgo      = row_group_offset(text_row);
    wire [9:0]  row_offset = {text_row[2:0], 7'd0} + {3'd0, rgo};
    wire        disp_page2       = page2 && !store80;
    wire [15:0] base_page        = disp_page2 ? 16'h0800 : 16'h0400;
    wire [15:0] text_addr        = base_page + {6'd0, row_offset} + {10'd0, fetch_col};

    // Hi-Res: 8 interleaved lines 0x400 apart, then the same 128/40-byte
    // row grouping as text (a2_y[5:3] == text_row[2:0], a2_y[7:6] == text_row[4:3]).
    wire [15:0] hgr_base         = disp_page2 ? 16'h4000 : 16'h2000;
    wire [15:0] hgr_addr         = hgr_base + {3'd0, glyph_row, 10'd0} + {6'd0, row_offset} + {10'd0, fetch_col};
    assign vram_addr             = (hires_mode && !is_text_line) ? hgr_addr : text_addr;

    assign aux_col = fetch_col;
    wire [9:0]  a2_next = (v_cnt + 10'd1 - A2_Y0) >> 1;
    wire [4:0]  trow_n  = a2_next[7:3];
    wire [6:0]  rgo_n   = row_group_offset(trow_n);
    // The aux bytes of the next line: its hi-res line for double hi-res, else its text row.
    wire        text_n    = text_mode || (mixed_mode && (trow_n >= 5'd20));
    wire [9:0]  roff_n    = {trow_n[2:0], 7'd0} + {3'd0, rgo_n};
    assign aux_fill_addr  = (hires_mode && !text_n)
                          ? hgr_base + {3'd0, a2_next[2:0], 10'd0} + {6'd0, roff_n}
                          : base_page + {6'd0, roff_n};
    assign aux_fill_start = col80 && (v_cnt >= A2_Y0 - 10'd1) && (v_cnt < A2_Y1 - 10'd1) && (h_cnt == 10'd660);

    // Request RAM access during prefetch cycles only (1 cycle per character column + 1 cycle before col 0)
    assign vram_req = in_apple_y && slot_act && (eff_sub == req_sub);

    // Pipelined data latches
    reg [7:0] char_code;
    reg [7:0] char_code_display;
    reg [7:0] glyph_byte;
    reg [7:0] aux_disp;   // aux byte on screen (double hi-res)
    reg [7:0] aux_code;   // 80-column: aux character of the slot, and its glyph row
    reg [7:0] glyph_aux;
    reg       prev_last; // last dot of the previous HGR byte (0 at column 0)

    // Character ROM address lookup
    wire [7:0] rom_code = (wide && slot_act && eff_sub == 4'd11) ? aux_code : char_code;
    // $40-$7F flash between the inverse ($000) and normal ($400) blocks, or with
    // ALTCHARSET on, read the $200 block instead: MouseText for $40-$5F and
    // inverse lowercase for $60-$7F. $00-$3F and $80-$FF are the same in both sets.
    assign char_rom_addr = {
        1'b0,
        (rom_code[7] | (rom_code[6] & flash_clk & ~altchar)),
        (rom_code[6] & (rom_code[7] | altchar)),
        rom_code[5:0],
        glyph_row[2:0]
    };

    // Prefetch sequence during each 14-cycle character slot:
    // Cycle  9: vram_req asserted, vram_addr presented
    // Cycle 10: RAM serves vram_addr, core latches vram_data
    // Cycle 11: Latch vram_data into char_code
    // Cycle 12: char_rom_addr presented to Char ROM
    // Cycle 13: Latch char_rom_data into glyph_byte and char_code_display for display on next slot
    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            char_code         <= 8'hA0; // space
            char_code_display <= 8'hA0;
            glyph_byte        <= 8'h00;
            aux_code          <= 8'hA0;
            aux_disp          <= 8'h00;
            glyph_aux         <= 8'hFF;
            prev_last         <= 1'b0;
        end else begin
            if (slot_act && eff_sub == req_sub + 4'd2) begin
                char_code <= vram_data;
                aux_code  <= aux_data;
            end
            if (wide && slot_act && eff_sub == 4'd12)
                glyph_aux <= char_rom_data;
            if (sub_col == 4'd13 || h_cnt == 10'd79) begin
                glyph_byte        <= char_rom_data;
                char_code_display <= char_code;
                aux_disp          <= aux_code;
                prev_last         <= (h_cnt == 10'd79) ? 1'b0 : char_code_display[6];
            end
        end
    end

    // Pixel dot extraction:
    // Each of the 7 character dots spans 2 pixel clocks:
    // sub_col: 0..1 (dot 0), 2..3 (dot 1), ..., 12..13 (dot 6)
    wire [2:0] dot_index = sub_col[3:1]; // 0..6
    // The 2732 is active-low: a 0 is a lit dot. Normal glyphs (the 0x400 and
    // 0x600 halves, what the CPU writes as $80-$FF) are stored as e.g. 0xE3 for
    // the top row of '@'; the inverse half (0x000, codes $00-$3F) is stored the
    // other way round so the same inversion draws it dark on light.
    // dot_index 0 is the leftmost dot, bit 0 of the byte.
    // web/src/charset.js reproduces this, so the browser and HDMI agree.
    // 80-column: aux glyph for sub_col 0..6, main glyph for 7..13, one clock per dot.
    wire       right_half = (sub_col >= 4'd7);
    wire [3:0] dot80      = right_half ? sub_col - 4'd7 : sub_col;
    wire [7:0] g80        = right_half ? glyph_byte : glyph_aux;
    wire pixel_on = wide ? ~g80[dot80[2:0]] : ~glyph_byte[dot_index];

    // ------------------------------------------------------------------
    // Colour: one NTSC decode for every mode, as on the machine
    // ------------------------------------------------------------------
    // A //e has no colour memory. Every mode sends one stream of dots at
    // 14.318 MHz, four to a cycle of the colour subcarrier, and the set reads
    // colour from where in the cycle the lit dots fall. Each mode below only
    // makes that stream, one sample per pixel (s_now); a single decoder reads
    // colour out of the last eight samples. The phase of sample m (pixel
    // h_cnt = 80 + m) is m mod 4 = h_cnt[1:0].
    //
    // Hi-res: 7 dots a byte, 2 samples a dot, bit 0 leftmost. A byte with
    // bit 7 set is delayed one sample, its first repeating the previous dot
    // (the last of the byte before: prev_last, 0 at column 0). 1100 (even
    // dots) is violet, 0011 green, and the delay makes them blue and orange.
    wire       hgr_cur    = char_code_display[dot_index];
    wire       hgr_left   = (dot_index == 3'd0) ? prev_last : char_code_display[dot_index - 3'd1];
    wire       hgr_on     = (char_code_display[7] && !sub_col[0]) ? hgr_left : hgr_cur;
    // Double hi-res: the bits themselves, one sample each, the aux byte's 7
    // then the main byte's. It sits one dot later against the subcarrier
    // (phase + 1): a lone aux bit 0 is dark blue, not magenta, and nibble v
    // is lo-res colour ROL1(v), Apple's DHGR table and AppleWin (decoded at
    // the hi-res phase, Prince of Persia's sky came out green, not orange).
    wire       dh_on      = right_half ? char_code_display[dot80[2:0]] : aux_disp[dot80[2:0]];
    wire [1:0] ph         = h_cnt[1:0] + {1'b0, dh};
    // Lo-res: a block's nibble goes out at the dot clock, bit k at phase k,
    // so the sample is the block colour's bit at the pixel's phase: inside a
    // block the decoder reads that colour (lo-res orange is hi-res orange, as
    // on a //e), at an edge a mix, the fringe a set shows. The top half of a
    // block is the low nibble. Double lo-res (80COL, AN3 off): the aux block
    // fills the left 7 dots of a cell at double hi-res's timing, so its
    // nibble n shows as colour ROL1(n); main is plain lo-res.
    function [3:0] rol1(input [3:0] v);
        rol1 = {v[2:0], v[3]};
    endfunction
    wire       dl         = col80 && dhires && !hires_mode && !is_text_line;
    wire [3:0] lr_main    = glyph_row[2] ? char_code_display[7:4] : char_code_display[3:0];
    wire [3:0] lr_aux     = glyph_row[2] ? aux_disp[7:4]          : aux_disp[3:0];
    wire [3:0] lr_c       = (dl && !right_half) ? rol1(lr_aux) : lr_main;
    wire       lr_on      = lr_c[ph];
    // Text is a dot stream too: 2 samples a dot, 1 in 80 columns.
    wire       s_now      = is_text_line ? pixel_on : dh ? dh_on : hires_mode ? hgr_on : lr_on;

    // The last eight samples, s[m-1] in bit 0 .. s[m-8] in bit 7. Zeros (the
    // black border) shift in outside the picture, so its edges decode too.
    reg  [7:0] hist;
    always @(posedge clk_pixel or posedge reset) begin
        if (reset) hist <= 8'd0;
        else       hist <= {hist[6:0], in_apple_x && s_now};
    end

    // The decoder, centred on s[m-4.5]: the picture sits 4 pixels right of
    // its fetch (A2_X0 + 4 on), the same in every mode and both settings.
    // Luma is the 4-sample box s[m-6..m-3], the notch that takes the
    // subcarrier out, as in a set's luma path. Chroma, I = s@phase0 -
    // s@phase2 and Q = s@phase1 - s@phase3, is read from one term per phase
    // residue: taps k and k+4 (s[m-1-k], s[m-5-k]) share a phase, and tap k
    // is at phase ph - 1 - k.
    //   sharp (DIP 1 off): the same 4 samples, 5 each -- an ideal monitor
    //   colour TV (DIP 1 on): all 8, weighted 1 2 3 4 4 3 2 1 -- a set's
    //     ~1.3 MHz chroma filter: colour bleeds and fringes blend while the
    //     luma detail stays
    // Each residue weighs 5 in both, so a steady pattern decodes to the same
    // colour either way, and one set of constants serves both.
    // Colour killer (DIP 1 on): in TEXT mode a //e sends no colour burst, so
    // the set shows no colour and, with no chroma trap, full luma detail;
    // mixed mode keeps the burst and its text lines fringe, as on a real set.
    // With DIP 1 off text is green phosphor, as before.
    wire [2:0] c_0 = color_tv ? (hist[0] ? 3'd1 : 3'd0) + (hist[4] ? 3'd4 : 3'd0) : (hist[4] ? 3'd5 : 3'd0);
    wire [2:0] c_1 = color_tv ? (hist[1] ? 3'd2 : 3'd0) + (hist[5] ? 3'd3 : 3'd0) : (hist[5] ? 3'd5 : 3'd0);
    wire [2:0] c_2 = color_tv ? (hist[2] ? 3'd3 : 3'd0) + (hist[6] ? 3'd2 : 3'd0) : (hist[2] ? 3'd5 : 3'd0);
    wire [2:0] c_3 = color_tv ? (hist[3] ? 3'd4 : 3'd0) + (hist[7] ? 3'd1 : 3'd0) : (hist[3] ? 3'd5 : 3'd0);
    // The residue at phase p is r = ph - 1 - p. The terms go in as an
    // argument, not read from the module inside the function: a simulator
    // re-evaluates a continuous assign on its arguments only, and Icarus kept
    // the last clock's terms, which turned every colour 90 degrees.
    function [2:0] term(input [11:0] c, input [1:0] r);
        term = (r == 2'd0) ? c[2:0] : (r == 2'd1) ? c[5:3] : (r == 2'd2) ? c[8:6] : c[11:9];
    endfunction
    wire [11:0] c_all = {c_3, c_2, c_1, c_0};
    wire        kill  = color_tv && text_mode;
    wire [2:0]  luma  = kill ? {hist[3], 2'b00}  // full detail: 0, 4 (crisp 1-dot contrast)
                             : hist[2] + hist[3] + hist[4] + hist[5];    // 0..4
    wire signed [4:0] ci = kill ? 5'sd0
                         : $signed({2'b00, term(c_all, ph - 2'd1)}) - $signed({2'b00, term(c_all, ph - 2'd3)});
    wire signed [4:0] cq = kill ? 5'sd0
                         : $signed({2'b00, term(c_all, ph - 2'd2)}) - $signed({2'b00, term(c_all, ph)});

    // Hardware DSP multiplier-based color matrix calculation:
    // 64 a unit of luma, chroma per 5: violet/green/blue/orange come out as
    // lo-res colours 3, C, 6 and 9 (sim/tb_video_hdmi.v's pal() and web/src/ntsc.js hold the table)
    wire signed [7:0]  k_y    = 8'sd64;
    wire signed [7:0]  k_r_i  = 8'sd16;
    wire signed [7:0]  k_g_i  = -8'sd8;
    wire signed [7:0]  k_g_q  = -8'sd4;
    wire signed [7:0]  k_b_q  = 8'sd20;

    wire signed [5:0]  s_luma = $signed({1'b0, luma});
    wire signed [11:0] prod_yr = s_luma * k_y;
    wire signed [11:0] prod_ri = ci * k_r_i;
    wire signed [11:0] prod_yg = s_luma * k_y;
    wire signed [11:0] prod_gi = ci * k_g_i;
    wire signed [11:0] prod_gq = cq * k_g_q;
    wire signed [11:0] prod_yb = s_luma * k_y;
    wire signed [11:0] prod_bq = cq * k_b_q;

    wire signed [11:0] r_s = prod_yr + prod_ri;
    wire signed [11:0] g_s = prod_yg + prod_gi + prod_gq;
    wire signed [11:0] b_s = prod_yb + prod_bq;

    function [7:0] sat8(input signed [11:0] v);
        sat8 = v[11] ? 8'd0 : (v > 12'sd255) ? 8'd255 : v[7:0];
    endfunction

    // ------------------------------------------------------------------
    // Monitor Modes: Green (P31), Amber (P134), White (P4)
    // ------------------------------------------------------------------
    wire is_mono  = (mon_mode != 2'b00);
    wire is_lores = !hires_mode && !is_text_line;

    reg [7:0] mono_base_r, mono_base_g, mono_base_b;
    reg [7:0] mono_ped_r,  mono_ped_g,  mono_ped_b;

    always @(*) begin
        case (mon_mode)
            2'b01: begin // P31 Green Phosphor (Apple Monitor //, Monitor ///)
                mono_base_r = 8'h20; mono_base_g = 8'hE8; mono_base_b = 8'h20;
                mono_ped_r  = 8'h02; mono_ped_g  = 8'h06; mono_ped_b  = 8'h02;
            end
            2'b10: begin // P134 Amber Phosphor (Apple Monitor //c)
                mono_base_r = 8'hFF; mono_base_g = 8'hA0; mono_base_b = 8'h00;
                mono_ped_r  = 8'h08; mono_ped_g  = 8'h04; mono_ped_b  = 8'h00;
            end
            default: begin // White Phosphor (B&W / Paper White)
                mono_base_r = 8'hF0; mono_base_g = 8'hF0; mono_base_b = 8'hF0;
                mono_ped_r  = 8'h04; mono_ped_g  = 8'h04; mono_ped_b  = 8'h04;
            end
        endcase
    end

    // Lo-Res 5-level luminance scaling using hardware multipliers:
    wire [15:0] scale_r = (mono_base_r - mono_ped_r) * {5'd0, luma};
    wire [15:0] scale_g = (mono_base_g - mono_ped_g) * {5'd0, luma};
    wire [15:0] scale_b = (mono_base_b - mono_ped_b) * {5'd0, luma};

    wire [7:0] mono_lr_r = mono_ped_r + scale_r[9:2];
    wire [7:0] mono_lr_g = mono_ped_g + scale_g[9:2];
    wire [7:0] mono_lr_b = mono_ped_b + scale_b[9:2];

    wire [7:0] mono_dot_r = hist[3] ? mono_base_r : mono_ped_r;
    wire [7:0] mono_dot_g = hist[3] ? mono_base_g : mono_ped_g;
    wire [7:0] mono_dot_b = hist[3] ? mono_base_b : mono_ped_b;

    wire [7:0] mono_r = is_lores ? mono_lr_r : mono_dot_r;
    wire [7:0] mono_g = is_lores ? mono_lr_g : mono_dot_g;
    wire [7:0] mono_b = is_lores ? mono_lr_b : mono_dot_b;

    // Output: the picture is 4 pixels on from the fetch, so its window is too
    wire in_pic = (h_cnt >= A2_X0 + 10'd4) && (h_cnt < A2_X1 + 10'd4) && in_apple_y;
    reg [7:0] pix_r, pix_g, pix_b;
    always @(*) begin
        if (!in_pic) begin
            pix_r = 8'h00; pix_g = 8'h00; pix_b = 8'h00;
        end else if (is_mono) begin
            pix_r = mono_r; pix_g = mono_g; pix_b = mono_b;
        end else if (is_text_line && !color_tv) begin
            // green phosphor, the same 4 samples late as the decoder
            pix_r = hist[3] ? 8'h20 : 8'h02;
            pix_g = hist[3] ? 8'hE8 : 8'h06;
            pix_b = hist[3] ? 8'h20 : 8'h02;
        end else begin
            pix_r = sat8(r_s); pix_g = sat8(g_s); pix_b = sat8(b_s);
        end
    end

    // Scanlines: each Apple line is two output lines (from y = 48, so the
    // second is an odd v_cnt); that one is darkened by 25, 50 or 75%.
    function [7:0] dim(input [7:0] v, input [1:0] lvl);
        case (lvl)
            2'd1:    dim = (v >> 1) + (v >> 2);   // 75% bright
            2'd2:    dim = v >> 1;
            2'd3:    dim = v >> 2;
            default: dim = v;
        endcase
    endfunction
    wire [1:0] dim_lvl = v_cnt[0] ? scanlines : 2'd0;

    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            red   <= 8'h00;
            green <= 8'h00;
            blue  <= 8'h00;
        end else begin
            red   <= dim(pix_r, dim_lvl);
            green <= dim(pix_g, dim_lvl);
            blue  <= dim(pix_b, dim_lvl);
        end
    end

endmodule
