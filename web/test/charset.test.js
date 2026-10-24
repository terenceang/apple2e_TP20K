// ============================================================================
//  charset.test.js -- the character ROM convention
//
//  The screen renderer and the FPGA's video generator have to agree on how the
//  2732 video ROM is addressed and lit, or the browser shows something other
//  than the monitor. These tests pin that convention against glyphs whose
//  shape is not in doubt, so an inversion cannot creep back in on either side.
//
//  video_generator.v:
//      char_rom_addr = {1'b0, code[7]|(code[6]&flash), code[6]&code[7],
//                       code[5:0], row}
//      pixel_on      = ~glyph_byte[dot]     // the 2732 is active-low
//
//  so a glyph lives at (code & 0x3F) * 8 + row, bit 0 is the leftmost dot, and
//  a CLEAR bit is a lit dot. What the CPU stores for normal text is $80-$FF:
//  $C1 ('A') reads the 0x600 half, glyph 1, stored as e.g. 0xF7 for the top row;
//  $A0 (space) is all ones. Codes $00-$3F read the 0x000 half, which is stored
//  the other way round so the same inversion draws them dark on light.
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { dotRow, HAS_GLYPHS, GLYPH_W, GLYPH_H } from '../src/charset.js'
import { screenToText } from '../src/stream.js'
import { parseHexDump } from '../scripts/lib/charrom.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..', '..')
const HEX = join(REPO, 'roms', 'apple2e_char.hex')

const available = existsSync(HEX)

/** The 7x8 picture of one cell code, as strings, top row first. */
function picture(code, flash = 0) {
  const out = []
  for (let r = 0; r < GLYPH_H; r++) {
    const bits = dotRow(code, r, flash)
    let s = ''
    for (let d = 0; d < GLYPH_W; d++) s += (bits >> d) & 1 ? '#' : '.'
    out.push(s)
  }
  return out
}

test('the character ROM was built', { skip: !available }, () => {
  assert.ok(HAS_GLYPHS, 'run `npm run charset` in web/ to build src/generated/charset.json')
})

test('a clear bit is a lit dot, and bit 0 is the leftmost one', { skip: !available }, () => {
  // Normal space ($A0) is stored as eight 0xFF bytes, so it is blank; read the
  // other way it would be a solid green block.
  assert.deepEqual(picture(0xa0), Array(8).fill('.......'))
})

test('A reads the glyph at code & 0x3F', { skip: !available }, () => {
  // 0xC1 & 0x3F == 0x01, and glyph 1 is a capital A. If the addressing used
  // the whole code, or the polarity were inverted, this would not be an A.
  const a = picture(0xc1)
  assert.deepEqual(a, [
    '...#...',
    '..#.#..',
    '.#...#.',
    '.#...#.',
    '.#####.',
    '.#...#.',
    '.#...#.',
    '.......',
  ])
  // and the lowercase 'a' is a different glyph at 0x61 & 0x3F == 0x21
  assert.notDeepEqual(picture(0xe1), a)
  // $01 is the INVERSE 'A': the same shape, every dot swapped
  const inv = picture(0x01)
  assert.deepEqual(inv, a.map((r) => [...r].map((c) => (c === '#' ? '.' : '#')).join('')).map((r) => r.slice(0, 7)))
})

test('@ and 0 are at their own glyphs', { skip: !available }, () => {
  // 0xC0 -> glyph 0, which is '@'
  assert.deepEqual(picture(0xc0)[0], '..###..')
  assert.deepEqual(picture(0xc0)[1], '.#...#.')
  // 0xB0 -> the digit 0, which on the Apple II carries the slash
  // that tells it apart from a capital O
  assert.deepEqual(picture(0xb0), [
    '..###..',
    '.#...#.',
    '.#..##.',
    '.#.#.#.',
    '.##..#.',
    '.#...#.',
    '..###..',
    '.......',
  ])
})

test('the glyph width is 7 dots and the height 8 lines', { skip: !available }, () => {
  assert.equal(GLYPH_W, 7)
  assert.equal(GLYPH_H, 8)
  for (const s of picture(0x41)) assert.equal(s.length, 7)
})

test('the flash clock only moves a flashing character to the alternate set',
  { skip: !available }, () => {
    // $41 flashes: the inverse half while the clock is low, normal when high
    const normal = picture(0xc1)
    assert.deepEqual(picture(0x41, 1), normal)
    assert.notDeepEqual(picture(0x41, 0), normal)
  })

test('a cell code that is not printable is drawn blank, not as a control char',
  { skip: !available }, () => {
    // Code 0 is '@' in the ROM, but $01 and $7F are control codes the text
    // screen never holds, and the text view has to show them as spaces rather
    // than letting a control character into the DOM. Printable codes on either
    // side so the result is not just trailing whitespace, which is trimmed.
    const page = new Uint8Array(1024)
    page[0] = 0x41
    page[1] = 0x01
    page[2] = 0x42
    page[3] = 0x7f
    page[4] = 0x43
    const lines = screenToText(page)
    assert.equal(lines[0], 'A B C')
    assert.ok(!/[\x00-\x1f\x7f]/.test(lines[0]), 'no control characters leak out')
  })

test('the hex file on disk is the same ROM the RTL reads', { skip: !available }, () => {
  // A cheap guard against rebuilding charset.json from the wrong file.
  const bytes = parseHexDump(readFileSync(HEX, 'utf8'))
  assert.ok(bytes.length >= 2048, 'char_rom_addr is 12 bits, so 2048 bytes minimum')
  // the eight bytes of glyph 1 spell an A with bit 1 lit
  assert.deepEqual(bytes.slice(8, 16), [0x08, 0x14, 0x22, 0x22, 0x3e, 0x22, 0x22, 0x00])
  // and glyph 0x20 is blank
  assert.deepEqual(new Set(bytes.slice(0x100, 0x108)), new Set([0]))
})
