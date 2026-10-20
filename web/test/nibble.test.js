// nibble.js must reproduce the byte stream disk2_card plays, byte for byte.
// The golden file is written by sim/tb_disk2.v (run sim/run.ps1 first); the
// image is that bench's img_byte(drive 0, track 0, sector, offset).
import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { encodeTrack, TRACK_LEN } from '../src/nibble.js'

const GOLDEN = new URL('../../build/golden_track0.hex', import.meta.url)

test('encodeTrack matches the card stream for track 0', { skip: !existsSync(GOLDEN) && 'run sim/run.ps1 first' }, () => {
  const sectors = Array.from({ length: 16 }, (_, s) =>
    Uint8Array.from({ length: 256 }, (_, o) => ((o * 5 + s * 11) & 0xff) ^ 0xa5))
  const want = readFileSync(GOLDEN, 'utf8').trim().split(/\s+/).map((h) => parseInt(h, 16))
  assert.equal(want.length, TRACK_LEN)
  const got = encodeTrack(0, sectors)
  const bad = got.findIndex((b, i) => b !== want[i])
  assert.equal(bad, -1, `first mismatch at ${bad}: got ${got[bad]?.toString(16)}, card ${want[bad]?.toString(16)}`)
})

import { decodeTrack, encodeField } from '../src/nibble.js'

test('decodeTrack recovers every sector of an encoded track', () => {
  const sectors = Array.from({ length: 16 }, (_, s) =>
    Uint8Array.from({ length: 256 }, (_, o) => (o * 7 + s * 29 + (o >> 3) * 13) & 0xff))
  const found = decodeTrack(encodeTrack(9, sectors))
  assert.equal(found.size, 16)
  for (let s = 0; s < 16; s++) assert.deepEqual(found.get(s), sectors[s], `sector ${s}`)
})

test('decodeTrack keeps a rewritten data field and drops a corrupt one', () => {
  const sectors = Array.from({ length: 16 }, (_, s) => new Uint8Array(256).fill(s))
  const track = encodeTrack(3, sectors)
  const newer = Uint8Array.from({ length: 256 }, (_, o) => o ^ 0x3c)
  track.set(encodeField(newer), 5 * 440 + 71)      // RWTS rewrites sector 5's data field
  track[7 * 440 + 100] ^= 0x01                      // sector 7's field: flip a bit -> bad GCR byte or checksum
  const found = decodeTrack(track)
  assert.deepEqual(found.get(5), newer)
  assert.equal(found.has(7), false)
  assert.equal(found.size, 15)
})
