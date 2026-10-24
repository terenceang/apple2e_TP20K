// ============================================================================
//  ntsc.test.js -- the page's colour against the //e's
//
//  The page and video_generator.v decode the same dot stream the same way, so
//  testing the decode against itself proves nothing: double hi-res was a
//  phase out in both and in tb_video_hdmi's model, and all three agreed.
//  These pin it to facts from outside the formula instead: the 16 colours as
//  literals (tb_video_hdmi has the same table), HCOLOR's bytes, double
//  hi-res nibble v being lo-res colour ROL1(v) (Apple's DHGR table; the board
//  matched AppleWin on Prince of Persia only with it), and the low nibble on
//  top of a lo-res block.
// ============================================================================
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { LORES_PALETTE, DHR_PHASE, loresNibble, rol1, hiresSamples, loresSamples, decodeLine } from '../src/ntsc.js'

const PAL = [
  0x000000, 0x901840, 0x402ca4, 0xd044e4, 0x006840, 0x808080, 0x3094e4, 0xc0acff,
  0x405400, 0xd06c1c, 0x808080, 0xff98c0, 0x30bc1c, 0xc0d45c, 0x70e8c0, 0xffffff,
]
const hex = (c) => (c[0] << 16) | (c[1] << 8) | c[2]
const MID = 280 // well inside the line, away from its black ends

function pixel(main, aux, x = MID) {
  const rgb = decodeLine(hiresSamples(main, aux, 0), aux ? DHR_PHASE : 0)
  return hex(rgb.subarray(x * 3, x * 3 + 3))
}
const line = (even, odd) => Uint8Array.from({ length: 40 }, (_, c) => (c % 2 ? odd : even))

test('the lo-res palette is the //e table', () => {
  assert.deepEqual(LORES_PALETTE.map(hex), PAL)
})

test('HCOLOR bytes give the hi-res colours, lo-res 3 6 9 C', () => {
  assert.equal(pixel(line(0x55, 0x2a)), PAL[3], 'violet (HCOLOR=2)')
  assert.equal(pixel(line(0x2a, 0x55)), PAL[0xc], 'green (HCOLOR=1)')
  assert.equal(pixel(line(0xd5, 0xaa)), PAL[6], 'blue (HCOLOR=6)')
  assert.equal(pixel(line(0xaa, 0xd5)), PAL[9], 'orange (HCOLOR=5)')
  assert.equal(pixel(line(0x7f, 0x7f)), PAL[0xf], 'white')
})

test('double hi-res nibble v is lo-res colour ROL1(v)', () => {
  for (let v = 0; v < 16; v++) {
    // the 560-dot stream repeats v's bits, bit 0 leftmost; aux then main per column
    const byte = (x0) => [...Array(7)].reduce((b, _, d) => b | (((v >> ((x0 + d) % 4)) & 1) << d), 0)
    const aux = Uint8Array.from({ length: 40 }, (_, c) => byte(14 * c))
    const main = Uint8Array.from({ length: 40 }, (_, c) => byte(14 * c + 7))
    assert.equal(pixel(main, aux), PAL[rol1(v)], `nibble ${v.toString(16)}`)
  }
})

test('a lone first double hi-res dot is dark blue, not magenta', () => {
  const aux = new Uint8Array(40)
  aux[20] = 0x01
  const rgb = decodeLine(hiresSamples(new Uint8Array(40), aux, 0), DHR_PHASE)
  assert.equal(hex(rgb.subarray(280 * 3, 280 * 3 + 3)), PAL[2])
})

test('rol1 is a one-bit left rotate of a nibble (double lo-res aux colour)', () => {
  assert.deepEqual([1, 2, 4, 8, 9, 0xf].map(rol1), [2, 4, 8, 1, 3, 0xf])
})

test('a lo-res block is its low nibble on top', () => {
  assert.equal(loresNibble(0x9c, false), 0xc)
  assert.equal(loresNibble(0x9c, true), 0x9)
})

const loresAt = (main, aux, bottom, x) => hex(decodeLine(loresSamples(main, aux, bottom), 0).subarray(x * 3, x * 3 + 3))

test('a lo-res block decodes to its colour, and its edges fringe', () => {
  const main = Uint8Array.from({ length: 40 }, (_, c) => ((c % 16) << 4) | (15 - (c % 16)))
  for (let c = 0; c < 40; c++) {
    assert.equal(loresAt(main, null, false, 14 * c + 7), PAL[15 - (c % 16)], `top of block ${c}`)
    assert.equal(loresAt(main, null, true, 14 * c + 7), PAL[c % 16], `bottom of block ${c}`)
  }
  // orange next to blue: the pixel on the boundary is neither, as on a TV
  const edge = loresAt(Uint8Array.from({ length: 40 }, (_, c) => (c < 20 ? 0x09 : 0x06)), null, false, 280)
  assert.notEqual(edge, PAL[9])
  assert.notEqual(edge, PAL[6])
})

test('double lo-res: the aux half block is colour ROL1 of its nibble', () => {
  const main = new Uint8Array(40).fill(0x0c)
  for (let v = 0; v < 16; v++) {
    const aux = new Uint8Array(40).fill(v)
    assert.equal(loresAt(main, aux, false, 14 * 20 + 3), PAL[rol1(v)], `aux ${v.toString(16)}`)
    assert.equal(loresAt(main, aux, false, 14 * 20 + 10), PAL[0xc], 'main half')
  }
})
