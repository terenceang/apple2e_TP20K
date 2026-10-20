// ============================================================================
//  charset.js -- the //e character set, addressed exactly as the RTL does
//
//  video_generator.v builds the character ROM address like this:
//
//      char_rom_addr = { 1'b0,
//                        char_code[7] | (char_code[6] & flash_clk),
//                        char_code[6] & char_code[7],
//                        char_code[5:0],
//                        glyph_row[2:0] }
//
//  and lights a dot where the ROM bit is clear (the 2732 is active-low):
//
//      dot_index = sub_col[3:1]          // 0..6, left to right
//      pixel_on  = ~glyph_byte[dot_index]
//
//  So the character code is NOT plain ASCII as far as the video path is
//  concerned: bits 7 and 6 pick the alternate set, and only bits 5..0 pick a
//  glyph. This module reproduces that expression rather than reinterpreting
//  the ROM, so the browser's screen and the monitor over HDMI are the same
//  picture even if that expression is ever changed on one side only.
//
//  The bytes come from the 2732 video ROM, which is Apple copyright and
//  gitignored, so it is not built in. Run `npm run charset` after supplying
//  roms/apple2e_char.hex (see roms/README.md). Without it the screen falls
//  back to ASCII in a monospace face and says so.
// ============================================================================

// The import attribute is what lets `node --test` load this module directly, so
// the tests exercise the same bytes the browser renders from.
import charset from './generated/charset.json' with { type: 'json' }

/** True when the real glyphs were built from the ROM. */
export const HAS_GLYPHS = Boolean(charset && Array.isArray(charset.bytes) && charset.bytes.length)

const ROM = HAS_GLYPHS ? Uint8Array.from(charset.bytes) : null

export const GLYPH_W = 7
export const GLYPH_H = 8

/**
 * Byte the character ROM returns for a text cell.
 *
 * @param {number} code     the cell's character code, bit 7 included
 * @param {number} row      0..7, top to bottom
 * @param {boolean} flash   the ~1.6 Hz flash clock state
 */
export function romByte(code, row, flash) {
  if (!ROM) return 0
  const selA = code & 0x80 || (code & 0x40 && flash) ? 1 : 0
  const selB = code & 0x40 && code & 0x80 ? 1 : 0
  const addr = (selA << 10) | (selB << 9) | ((code & 0x3f) << 3) | (row & 7)
  return ROM[addr & 0xfff] ?? 0
}

/**
 * The 7-bit dot mask for one scanline of a cell, leftmost dot in bit 0, a set
 * bit meaning the dot is lit. The 2732 is active-low (a 0 is a lit dot), so
 * this is the complement of the ROM byte, exactly as the RTL's `~glyph_byte`.
 * Rows run top to bottom and bit 0 is the leftmost dot.
 */
export function dotRow(code, row, flash) {
  return ~romByte(code, row, flash) & 0x7f
}
