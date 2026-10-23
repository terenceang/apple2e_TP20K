// ============================================================================
//  woz.test.js -- the floppy converter: every format slot 6 takes, to WOZ 2
//  and back, and the file layout the board reads at fixed offsets
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  encode62, decode62, dskToWoz, nibToWoz, blankWoz, woz1ToWoz2, wozToDsk, wozInfo, wozCrcOk,
  toWoz, trackNibbles, readTrack, standardTmap, TRACK_BLOCKS,
} from '../src/woz.js'

const disk = (seed) => Uint8Array.from({ length: 143360 }, (_, i) => (i * 7 + seed + (i >> 8) * 13) & 0xff)
const u16 = (w, o) => w[o] | (w[o + 1] << 8)
const u32 = (w, o) => (u16(w, o) | (u16(w, o + 2) << 16)) >>> 0

test('6-and-2 round trip, and a damaged field is refused', () => {
  for (const seed of [0, 1, 99]) {
    const s = Uint8Array.from({ length: 256 }, (_, i) => (i * seed + 3) & 0xff)
    const n = encode62(s)
    assert.equal(n.length, 343)
    assert.ok(n.every((b) => b & 0x80), 'every disk byte has its top bit set')
    assert.deepEqual(decode62(n), s)
    n[100] = n[100] === 0x96 ? 0x97 : 0x96
    assert.equal(decode62(n), null)
  }
})

test('the bytes the P6 ROM unpacks: aux k carries bytes k, k+86, k+172, each pair reversed', () => {
  const s = new Uint8Array(256)
  s[0] = 0b01; s[86] = 0b10; s[172] = 0b11 // reversed: 10, 01, 11
  const n = encode62(s)
  const table = [0x96, 0x97, 0x9a, 0x9b, 0x9d, 0x9e, 0x9f, 0xa6, 0xa7, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb2, 0xb3,
    0xb4, 0xb5, 0xb6, 0xb7, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xcb, 0xcd, 0xce, 0xcf, 0xd3,
    0xd6, 0xd7, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe5, 0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec,
    0xed, 0xee, 0xef, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff]
  const first = table.indexOf(n[0])
  assert.equal(first, 0b11_01_10)
})

test('a .dsk and a .po become WOZ 2 with the layout the board reads, and come back', () => {
  const dsk = disk(5)
  for (const order of ['dos', 'po']) {
    const w = dskToWoz(dsk, order)
    assert.equal(String.fromCharCode(...w.subarray(0, 4)), 'WOZ2')
    assert.deepEqual([...w.subarray(4, 8)], [0xff, 0x0a, 0x0d, 0x0a])
    assert.ok(wozCrcOk(w) && u32(w, 8) !== 0, 'CRC computed')
    assert.equal(String.fromCharCode(...w.subarray(80, 84)), 'TMAP')
    assert.equal(String.fromCharCode(...w.subarray(248, 252)), 'TRKS')
    assert.deepEqual([...w.subarray(88, 248)], standardTmap())
    assert.equal(w[21], 1); assert.equal(w[22], 0); assert.equal(w[59], 32)
    for (let t = 0; t < 35; t++) {
      assert.equal(u16(w, 256 + 8 * t), 3 + t * TRACK_BLOCKS, 'tracks in order from block 3')
      assert.equal(u16(w, 258 + 8 * t), TRACK_BLOCKS)
      const bits = u32(w, 260 + 8 * t)
      assert.ok(bits > 49000 && bits <= TRACK_BLOCKS * 4096, `track ${t}: ${bits} bits`)
    }
    assert.equal(w.length, (3 + 35 * TRACK_BLOCKS) * 512)
    assert.deepEqual(wozToDsk(w, order), dsk)
  }
  // the two orders put a sector in different physical places
  assert.notDeepEqual(dskToWoz(dsk, 'dos'), dskToWoz(dsk, 'po'))
})

test('physical sectors: DOS logical 1 is physical 13, ProDOS block 0 half 2 is physical 2', () => {
  const dsk = new Uint8Array(143360)
  dsk.fill(0x11, 1 * 256, 2 * 256) // track 0, file sector 1
  assert.equal(readTrack(dskToWoz(dsk, 'dos'), 0)[13][0], 0x11)
  assert.equal(readTrack(dskToWoz(dsk, 'po'), 0)[2][0], 0x11)
})

test('a track: 10-bit self-sync, then address fields 0-15 in order with volume 254', () => {
  const w = dskToWoz(disk(1))
  const n = trackNibbles(w, 17)
  const hdrs = []
  for (let i = 0; i < n.length / 2; i++) {
    if (n[i] === 0xd5 && n[i + 1] === 0xaa && n[i + 2] === 0x96) {
      const f = (k) => ((n[i + 3 + 2 * k] << 1) | 1) & n[i + 4 + 2 * k]
      hdrs.push([f(0), f(1), f(2)])
    }
  }
  assert.deepEqual(hdrs, Array.from({ length: 16 }, (_, s) => [254, 17, s]))
  // the sync bytes are FF plus two zero bits
  const start = 256 + 0
  const blk = u16(w, start)
  assert.deepEqual([...w.subarray(blk * 512, blk * 512 + 5)], [0xff, 0x3f, 0xcf, 0xf3, 0xfc])
})

test('.nib, WOZ 1 and a blank disk', () => {
  const nib = Uint8Array.from({ length: 35 * 6656 }, (_, i) => 0x96 + (i % 7))
  const w = nibToWoz(nib)
  assert.deepEqual(trackNibbles(w, 3).slice(0, 6656), [...nib.subarray(3 * 6656, 4 * 6656)])
  assert.equal(u32(w, 260), 6656 * 8)

  // WOZ 1: 160-byte TMAP at 88, TRKS at 256 of 6,656-byte entries, bit count at +6648
  const v1 = new Uint8Array(256 + 2 * 6656)
  v1.set([0x57, 0x4f, 0x5a, 0x31, 0xff, 0x0a, 0x0d, 0x0a])
  v1[21] = 1; v1[22] = 1
  v1.fill(0xff, 88, 248); v1[88] = 0; v1[92] = 1
  new DataView(v1.buffer).setUint32(252, 2 * 6656, true)
  v1.fill(0xd5, 256, 256 + 100)
  new DataView(v1.buffer).setUint16(256 + 6648, 800, true)
  const w2 = woz1ToWoz2(v1)
  assert.equal(wozInfo(w2).version, 2)
  assert.ok(wozInfo(w2).writeProtected)
  assert.equal(u32(w2, 260), 800)
  assert.equal(w2[88], 0); assert.equal(w2[92], 1); assert.equal(w2[90], 0xff)
  assert.equal(w2[u16(w2, 256) * 512], 0xd5)

  const b = blankWoz()
  assert.equal(wozInfo(b).tracks, 35)
  assert.throws(() => wozToDsk(b), /does not decode/)
})

test('toWoz takes every floppy format and names the result .woz', () => {
  assert.equal(toWoz('Lode Runner.dsk', disk(2)).name, 'Lode Runner.woz')
  assert.equal(toWoz('a.do', disk(2)).name, 'a.woz')
  assert.deepEqual(wozToDsk(toWoz('p.po', disk(3)).data, 'po'), disk(3))
  const w = dskToWoz(disk(4))
  assert.equal(toWoz('x.woz', w).data, w)
  assert.throws(() => toWoz('a.txt', new Uint8Array(10)), /not a floppy image/)
  assert.throws(() => toWoz('a.dsk', new Uint8Array(10)), /143,360/)
  assert.throws(() => wozInfo(new Uint8Array(512)), /not a WOZ/)
})
