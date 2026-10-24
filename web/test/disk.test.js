// ============================================================================
//  disk.test.js -- disk sizes and the hard-disk image checks the card upload uses
//  (images go onto the TF card and the board loads them; src/sd_vol.v puts a
//  DOS-order floppy in physical order, which tb_sdvol checks)
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  TRACKS,
  SECTORS_PER_TRACK,
  SECTOR_BYTES,
  TRACK_BYTES,
  DISK_BYTES,
  ACK_BYTE,
  validateHardDiskImage,
  hdRecords,
} from '../src/disk.js'

test('disk dimensions match standard 140K 5.25" floppy geometry', () => {
  assert.equal(TRACKS, 35)
  assert.equal(SECTORS_PER_TRACK, 16)
  assert.equal(SECTOR_BYTES, 256)
  assert.equal(TRACK_BYTES, 4096)
  assert.equal(DISK_BYTES, 143360)
  assert.equal(ACK_BYTE, 0x06)
})

test('validateHardDiskImage takes raw and 2IMG images and rejects partial blocks', () => {
  assert.equal(validateHardDiskImage(new Uint8Array(1024)).length, 1024)
  assert.throws(() => validateHardDiskImage(new Uint8Array(1000)), /512-byte blocks/)
  assert.throws(() => validateHardDiskImage(new Uint8Array(65537 * 512)), /32 MB/)
  const img = new Uint8Array(64 + 1024)
  img.set([0x32, 0x49, 0x4d, 0x47], 0) // "2IMG"
  const v = new DataView(img.buffer)
  v.setUint32(0x0c, 1, true)
  v.setUint32(0x18, 64, true)
  v.setUint32(0x1c, 1024, true)
  img[64] = 0xab
  assert.equal(validateHardDiskImage(img)[0], 0xab)
  v.setUint32(0x0c, 0, true)
  assert.throws(() => validateHardDiskImage(img), /ProDOS order/)
})

test('hdRecords covers the image with data blocks and zero runs, and no further', () => {
  const data = new Uint8Array(6 * 512)
  data[0] = 1
  data[3 * 512 + 5] = 2
  const recs = [...hdRecords(data)]
  assert.deepEqual(recs.map((r) => [r.bytes[0], r.blocks]), [[1, 1], [0, 2], [1, 1], [0, 2]])
  assert.equal(recs[0].bytes.length, 513)
  assert.deepEqual([...recs[1].bytes], [0, 0, 1])
})

