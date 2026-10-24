// ============================================================================
//  ntsc.js -- Apple //e colour, as video_generator.v makes it
//
//  An Apple II has no colour memory: the screen is one stream of dots at
//  14.318 MHz, four to a cycle of the NTSC colour subcarrier, and a set reads
//  colour from where in that cycle the lit dots fall. Each pixel is decoded
//  from the window s[x-2..x+1]: luma is the number of lit samples, chroma
//  I = s@phase0 - s@phase2, Q = s@phase1 - s@phase3. Lo-res, hi-res and
//  double hi-res all come out of this one decode, as on the machine, so the
//  page and the HDMI output agree pixel for pixel. web/test/ntsc.test.js
//  pins it to the //e's colours.
// ============================================================================

/** Double hi-res sits one dot later against the subcarrier than hi-res: a
 *  lone first dot is dark blue, not magenta (Apple's DHGR table, AppleWin). */
export const DHR_PHASE = 1

const clamp = (v) => (v < 0 ? 0 : v > 255 ? 255 : v)

/** RGB for luma y (lit samples of 4) and chroma i, q: video_generator.v's constants. */
export function ntscRgb(y, i, q) {
  return [clamp(64 * y + 80 * i), clamp(64 * y - 41 * i - 20 * q), clamp(64 * y + 101 * q)]
}

/** The 16 lo-res colours: nibble bit k goes out at subcarrier phase k. */
export const LORES_PALETTE = Array.from({ length: 16 }, (_, n) => {
  const b = (k) => (n >> k) & 1
  return ntscRgb(b(0) + b(1) + b(2) + b(3), b(0) - b(2), b(1) - b(3))
})

/** The colour a double hi-res or double lo-res aux nibble shows: it runs one
 *  dot later, so nibble v is lo-res colour ROL1(v). */
export const rol1 = (v) => ((v << 1) | (v >> 3)) & 0x0f

/** Lo-res: a byte's low nibble is the top half of its block. */
export const loresNibble = (byte, bottom) => (bottom ? byte >> 4 : byte) & 0x0f

/**
 * One line's 560-sample dot stream. Hi-res (aux null): 7 dots a byte, 2
 * samples a dot, and a byte with bit 7 set delayed one sample, its first
 * repeating the previous dot. Double hi-res: the aux byte's 7 bits then the
 * main byte's, one sample each. Bit 0 is the leftmost dot.
 * @param {Uint8Array} main @param {Uint8Array|null} aux @param {number} offset
 */
export function hiresSamples(main, aux, offset, out = new Uint8Array(560)) {
  let prev = 0
  for (let col = 0; col < 40; col++) {
    const m = main[offset + col] ?? 0
    if (aux) {
      const a = aux[offset + col] ?? 0
      for (let d = 0; d < 7; d++) {
        out[col * 14 + d] = (a >> d) & 1
        out[col * 14 + 7 + d] = (m >> d) & 1
      }
    } else {
      const delay = m & 0x80
      for (let d = 0; d < 7; d++) {
        const cur = (m >> d) & 1
        out[col * 14 + d * 2] = delay ? (d ? (m >> (d - 1)) & 1 : prev) : cur
        out[col * 14 + d * 2 + 1] = cur
      }
      prev = (m >> 6) & 1
    }
  }
  return out
}

/** Decode a line of samples to RGB (3 bytes a pixel); sample x is at phase (x + phase) & 3. */
export function decodeLine(s, phase, out = new Uint8Array(s.length * 3)) {
  const n = s.length
  for (let x = 0; x < n; x++) {
    let y = 0, i = 0, q = 0
    for (let k = x - 2; k <= x + 1; k++) {
      if (k < 0 || k >= n || !s[k]) continue
      y++
      const p = (k + phase) & 3
      if (p === 0) i++
      else if (p === 1) q++
      else if (p === 2) i--
      else q--
    }
    const c = ntscRgb(y, i, q)
    out[x * 3] = c[0]
    out[x * 3 + 1] = c[1]
    out[x * 3 + 2] = c[2]
  }
  return out
}
