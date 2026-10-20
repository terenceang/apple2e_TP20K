// Apple //e Video Display Generator for Tang Nano 20K
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
    input  wire        flash_clk,    // ~1.6 Hz flashing text clock

    // Raster position of the next pixel, from hdmi_tx (see above)
    input  wire [9:0]  h_cnt,        // 0..719 active, >= 720 blanking
    input  wire [9:0]  v_cnt,        // 0..479 active, 480..524 blanking

    // Softswitches
    input  wire        text_mode,    // 1: Text, 0: Graphics
    input  wire        mixed_mode,   // 1: Bottom 4 lines are text
    input  wire        page2,        // 1: Page 2, 0: Page 1
    input  wire        hires_mode,   // 1: Hi-Res, 0: Lo-Res
    input  wire        col80,        // 1: 80-column text (aux byte first, then main)
    input  wire        dhires,       // 1: double hi-res (with col80 and HIRES): aux byte then main, 560 dots
    input  wire        altchar,      // 1: alternate character set (MouseText, no flashing)
    input  wire        store80,      // 1: 80STORE, PAGE2 no longer selects the display page

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
    // X: 80 .. 639 (560 pixels = 40 cols * 14 px)
    // Y: 48 .. 431 (384 lines = 192 lines * 2)
    localparam [9:0] A2_X0 = 10'd80, A2_X1 = 10'd640; // first h_cnt in / past the Apple area
    localparam [9:0] A2_Y0 = 10'd48, A2_Y1 = 10'd432; // first v_cnt in / past the Apple area
    localparam [9:0] A2_PRE0 = A2_X0 - 10'd14;        // the pre-roll slot before column 0

    assign vbl = (v_cnt >= A2_Y1);

    wire in_apple_x = (h_cnt >= A2_X0) && (h_cnt < A2_X1);
    wire in_apple_y = (v_cnt >= A2_Y0) && (v_cnt < A2_Y1);
    wire in_apple_screen = in_apple_x && in_apple_y;

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

    // Hi-Res dot stream. char_code_display is the byte on screen (bit 0 is the
    // leftmost dot, bit 7 the palette/delay bit); char_code already holds the
    // next byte from sub_col 12, which is all dot 6's right neighbour needs.
    // A delayed byte (bit 7) shifts its pixels right by one clock, half a dot.
    //
    // Colour is what an NTSC set makes of that 560-sample stream. One colour
    // subcarrier cycle is 4 samples, so the pixel is decoded from the window
    // s[n-2..n+1]: luma is the number of lit samples, chroma is
    //   I = s@phase0 - s@phase2,   Q = s@phase1 - s@phase3
    // with the phase of sample m = m mod 4. 1100 (even dots) is violet, 0011
    // green, and the one-sample shift of a delayed byte turns them into blue
    // and orange; 1111 is white and a 0101 dot pattern fills solid, as on a TV.
    // The channel constants (64/unit of luma, then I and Q terms) put those
    // four at D043E5 / 30BD1B / 3095E5 / D06B1B, within a few counts of the lo-res palette.
    wire       hgr_cur   = char_code_display[dot_index];
    wire       hgr_left  = (dot_index == 3'd0) ? prev_last : char_code_display[dot_index - 3'd1];
    wire       hgr_on_std = (char_code_display[7] && !sub_col[0]) ? hgr_left : hgr_cur;
    // The sample one clock ahead: the next slot's first pixel at sub_col 13.
    wire [3:0] hgr_npos  = sub_col + 4'd1;
    wire       hgr_next_std = (sub_col == 4'd13)
                         ? (col_cnt != 6'd39 && (char_code[7] ? char_code_display[6] : char_code[0]))
                         : ((char_code_display[7] && !hgr_npos[0]) ? char_code_display[hgr_npos[3:1] - 3'd1]
                                                                   : char_code_display[hgr_npos[3:1]]);
    // Double hi-res: the dot stream is the bits themselves, one sample per clock
    // (aux byte bits 0..6, then main byte bits 0..6), so the same NTSC window applies.
    wire [3:0] dh_nk     = sub_col + 4'd1;
    wire       dh_cur    = right_half ? char_code_display[dot80[2:0]] : aux_disp[dot80[2:0]];
    wire       dh_next   = (sub_col == 4'd13) ? (col_cnt != 6'd39 && aux_code[0])
                         : (dh_nk >= 4'd7) ? char_code_display[dh_nk - 4'd7] : aux_disp[dh_nk[2:0]];
    wire       hgr_on    = dh ? dh_cur  : hgr_on_std;
    wire       hgr_next  = dh ? dh_next : hgr_next_std;
    reg  [1:0] hgr_hist; // s[n-1] in bit 0, s[n-2] in bit 1; zero outside the screen
    always @(posedge clk_pixel or posedge reset) begin
        if (reset) hgr_hist <= 2'b00;
        else       hgr_hist <= in_apple_x ? {hgr_hist[0], hgr_on} : 2'b00;
    end

    // Phase of pixel n: 14 * col + sub_col mod 4.
    wire [1:0] hgr_ph = {col_cnt[0], 1'b0} + sub_col[1:0];
    function integer chroma_i(input s, input [1:0] q);
        chroma_i = !s ? 0 : (q == 2'd0) ? 1 : (q == 2'd2) ? -1 : 0;
    endfunction
    function integer chroma_q(input s, input [1:0] q);
        chroma_q = !s ? 0 : (q == 2'd1) ? 1 : (q == 2'd3) ? -1 : 0;
    endfunction
    function [7:0] clamp8(input integer v);
        clamp8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
    endfunction

    reg [7:0] hgr_r, hgr_g, hgr_b;
    integer   hgr_y, hgr_ci, hgr_cq;
    always @(*) begin
        hgr_y  = hgr_hist[1] + hgr_hist[0] + hgr_on + hgr_next;
        hgr_ci = chroma_i(hgr_hist[1], hgr_ph + 2'd2) + chroma_i(hgr_hist[0], hgr_ph + 2'd3)
               + chroma_i(hgr_on,      hgr_ph)        + chroma_i(hgr_next,    hgr_ph + 2'd1);
        hgr_cq = chroma_q(hgr_hist[1], hgr_ph + 2'd2) + chroma_q(hgr_hist[0], hgr_ph + 2'd3)
               + chroma_q(hgr_on,      hgr_ph)        + chroma_q(hgr_next,    hgr_ph + 2'd1);
        hgr_r  = clamp8(64 * hgr_y + 80 * hgr_ci);
        hgr_g  = clamp8(64 * hgr_y - 41 * hgr_ci - 20 * hgr_cq);
        hgr_b  = clamp8(64 * hgr_y + 101 * hgr_cq);
    end

    // Lo-Res graphics support:
    wire [3:0] lores_color_idx = glyph_row[2] ? char_code_display[7:4] : char_code_display[3:0];

    // Lo-Res 16-color RGB palette
    reg [7:0] lores_r, lores_g, lores_b;
    always @(*) begin
        case (lores_color_idx)
            4'h0: begin lores_r = 8'h00; lores_g = 8'h00; lores_b = 8'h00; end // Black
            4'h1: begin lores_r = 8'h90; lores_g = 8'h17; lores_b = 8'h40; end // Magenta
            4'h2: begin lores_r = 8'h40; lores_g = 8'h2C; lores_b = 8'hA5; end // Dark Blue
            4'h3: begin lores_r = 8'hD0; lores_g = 8'h43; lores_b = 8'hE5; end // Purple
            4'h4: begin lores_r = 8'h00; lores_g = 8'h69; lores_b = 8'h40; end // Dark Green
            4'h5: begin lores_r = 8'h80; lores_g = 8'h80; lores_b = 8'h80; end // Gray 1
            4'h6: begin lores_r = 8'h2F; lores_g = 8'h95; lores_b = 8'hE5; end // Medium Blue
            4'h7: begin lores_r = 8'hBF; lores_g = 8'hAB; lores_b = 8'hFF; end // Light Blue
            4'h8: begin lores_r = 8'h40; lores_g = 8'h54; lores_b = 8'h00; end // Brown
            4'h9: begin lores_r = 8'hE0; lores_g = 8'h6A; lores_b = 8'h1A; end // Orange
            4'hA: begin lores_r = 8'h80; lores_g = 8'h80; lores_b = 8'h80; end // Gray 2
            4'hB: begin lores_r = 8'hFF; lores_g = 8'h96; lores_b = 8'hBF; end // Pink
            4'hC: begin lores_r = 8'h30; lores_g = 8'hC0; lores_b = 8'h1A; end // Light Green
            4'hD: begin lores_r = 8'hBF; lores_g = 8'hD3; lores_b = 8'h5A; end // Yellow
            4'hE: begin lores_r = 8'h6F; lores_g = 8'hE8; lores_b = 8'hBF; end // Aquamarine
            4'hF: begin lores_r = 8'hFF; lores_g = 8'hFF; lores_b = 8'hFF; end // White
        endcase
    end

    // Output color assignment
    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            red   <= 8'h00;
            green <= 8'h00;
            blue  <= 8'h00;
        end else begin
            if (in_apple_screen) begin
                if (is_text_line) begin
                    // Authentic Apple II Green Phosphor (or crisp monochrome)
                    red   <= pixel_on ? 8'h20 : 8'h02;
                    green <= pixel_on ? 8'hE8 : 8'h06;
                    blue  <= pixel_on ? 8'h20 : 8'h02;
                end else if (hires_mode) begin
                    red   <= hgr_r;
                    green <= hgr_g;
                    blue  <= hgr_b;
                end else begin
                    // Lo-Res graphics color
                    red   <= lores_r;
                    green <= lores_g;
                    blue  <= lores_b;
                end
            end else begin
                // Border & blanking: black
                red   <= 8'h00;
                green <= 8'h00;
                blue  <= 8'h00;
            end
        end
    end

endmodule
