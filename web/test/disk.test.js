// ============================================================================
//  disk.test.js -- Apple //e Disk II image handling & transfer protocol tests
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
  DOS_TO_PHYS,
  PHYS_TO_DOS,
  detectDiskFormat,
  validateDiskImage,
  dosToPhysical,
  physicalToDos,
  prepareUploadImage,
  prepareDownloadImage,
  uploadDisk,
  diskChecksum,
  queryDiskSums,
  downloadDisk,
  parseHdStatus,
  mountHd,
  validateHardDiskImage,
  hdRecords,
  copyToSlot,
  buildCardImage,
} from '../src/disk.js'

test('disk dimensions match standard 140K 5.25" floppy geometry', () => {
  assert.equal(TRACKS, 35)
  assert.equal(SECTORS_PER_TRACK, 16)
  assert.equal(SECTOR_BYTES, 256)
  assert.equal(TRACK_BYTES, 4096)
  assert.equal(DISK_BYTES, 143360)
  assert.equal(ACK_BYTE, 0x06)
})

test('interleave tables are bijections and mutually inverse', () => {
  assert.equal(DOS_TO_PHYS.length, 16)
  assert.equal(PHYS_TO_DOS.length, 16)

  const dosSet = new Set(DOS_TO_PHYS)
  const physSet = new Set(PHYS_TO_DOS)
  assert.equal(dosSet.size, 16)
  assert.equal(physSet.size, 16)

  for (let i = 0; i < 16; i++) {
    assert.equal(PHYS_TO_DOS[DOS_TO_PHYS[i]], i)
    assert.equal(DOS_TO_PHYS[PHYS_TO_DOS[i]], i)
  }

  // The DOS 3.3 interleave, as the boot sector spells it: its table at $084D is
  // 00 0D 0B 09 07 05 03 01 0E 0C 0A 08 06 04 02 0F, the physical sector that
  // holds logical sector 0, 1, 2 ... (boot1 asks the P6 ROM for these, in order,
  // to put logical sectors 1-9 at $3700-$3F00).
  assert.deepEqual(DOS_TO_PHYS, [0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1, 0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf])
})

test('detectDiskFormat distinguishes ProDOS and DOS orders by extension', () => {
  assert.equal(detectDiskFormat('master.dsk'), 'dos')
  assert.equal(detectDiskFormat('game.do'), 'dos')
  assert.equal(detectDiskFormat('prodos.po'), 'prodos')
  assert.equal(detectDiskFormat('PRODOS.PO'), 'prodos')
  assert.equal(detectDiskFormat('unknown.bin'), 'dos')
  assert.equal(detectDiskFormat(''), 'dos')
})

test('validateDiskImage enforces exact 143,360 byte size', () => {
  const good = new Uint8Array(DISK_BYTES)
  const res = validateDiskImage(good.buffer, 'test.po')
  assert.equal(res.data.byteLength, DISK_BYTES)
  assert.equal(res.order, 'prodos')
  assert.equal(res.filename, 'test.po')

  assert.throws(
    () => validateDiskImage(new Uint8Array(100), 'small.dsk'),
    /Invalid disk image size/,
  )
  assert.throws(
    () => validateDiskImage(new Uint8Array(143361), 'big.dsk'),
    /Invalid disk image size/,
  )
})

test('dosToPhysical and physicalToDos interleave each track correctly and round-trip', () => {
  const original = new Uint8Array(DISK_BYTES)
  // Fill each sector with a unique track & sector tag
  for (let t = 0; t < TRACKS; t++) {
    for (let s = 0; s < SECTORS_PER_TRACK; s++) {
      const off = t * TRACK_BYTES + s * SECTOR_BYTES
      original[off] = t
      original[off + 1] = s
      original[off + 2] = 0xaa
    }
  }

  const physical = dosToPhysical(original)
  assert.equal(physical.length, DISK_BYTES)

  // Track 0, logical sector 1 should have moved to physical sector 13 (offset 13 * 256)
  const physSec13Off = 13 * SECTOR_BYTES
  assert.equal(physical[physSec13Off], 0)
  assert.equal(physical[physSec13Off + 1], 1)
  assert.equal(physical[physSec13Off + 2], 0xaa)

  // Track 0, logical sector 2 should have moved to physical sector 11 (offset 11 * 256)
  const physSec11Off = 11 * SECTOR_BYTES
  assert.equal(physical[physSec11Off], 0)
  assert.equal(physical[physSec11Off + 1], 2)
  assert.equal(physical[physSec11Off + 2], 0xaa)

  // Converting back must return the exact original
  const roundTrip = physicalToDos(physical)
  assert.deepEqual(roundTrip, original)
})

test('prepareUploadImage and prepareDownloadImage respect format selection', () => {
  const sample = new Uint8Array(DISK_BYTES)
  sample[0] = 0x42
  sample[1] = 0x99

  // ProDOS order is identity
  const poUp = prepareUploadImage(sample, 'prodos')
  assert.deepEqual(poUp, sample)
  const poDn = prepareDownloadImage(sample, 'po')
  assert.deepEqual(poDn, sample)

  // DOS order applies interleave
  const dosUp = prepareUploadImage(sample, 'dos')
  const dosDn = prepareDownloadImage(dosUp, 'dsk')
  assert.deepEqual(dosDn, sample)
})

/**
 * Creates a mock serial link for testing upload and download protocols.
 */
function createMockLink() {
  const written = []
  let onBytes = (b) => {}

  const link = {
    written,
    get onBytes() {
      return onBytes
    },
    set onBytes(fn) {
      onBytes = fn
    },
    write(bytes) {
      const arr = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes)
      written.push(arr)
    },
    feed(data) {
      const bytes = typeof data === 'string'
        ? new TextEncoder().encode(data)
        : data instanceof Uint8Array ? data : Uint8Array.from(data)
      onBytes(bytes)
    },
  }
  return link
}

test('uploadDisk executes full 35-track paced handshake and verifies done', async () => {
  const link = createMockLink()
  const payload = new Uint8Array(DISK_BYTES)
  for (let i = 0; i < DISK_BYTES; i++) payload[i] = (i * 7) & 0xff

  const progressEvents = []
  const originalOnBytes = link.onBytes

  // Run upload in background while mock responder answers
  const uploadPromise = uploadDisk(link, 1, payload, {
    onProgress: (p) => progressEvents.push(p),
    timeoutMs: 1000,
  })

  // 1. Board receives 'd' and '1'
  // Wait until 'd' and '1' are written
  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x64) // 'd'
  assert.equal(link.written[1][0], 0x31) // '1'

  // Board responds with upload banner
  link.feed('\r\nUPLOAD 143360 bytes, send now\r\n')

  // 2. Feed ACK for each of the 35 tracks
  for (let t = 0; t < 35; t++) {
    // Wait for the track chunk to be written
    while (link.written.length < 3 + t) {
      await new Promise((r) => setTimeout(r, 5))
    }
    const chunk = link.written[2 + t]
    assert.equal(chunk.length, 4096)
    // Board sends ACK
    link.feed([ACK_BYTE])
  }

  // 3. Board finishes with done
  link.feed('\r\ndone\r\n> ')

  await uploadPromise

  // Verify all 35 tracks were reported
  assert.equal(progressEvents.length, 35)
  assert.equal(progressEvents[34].track, 35)
  assert.equal(progressEvents[34].bytesSent, 143360)

  // Verify link.onBytes was restored
  assert.equal(link.onBytes, originalOnBytes)
})

test('uploadDisk throws if FPGA reports lost bytes', async () => {
  const link = createMockLink()
  const payload = new Uint8Array(DISK_BYTES)

  const uploadPromise = uploadDisk(link, 2, payload, { timeoutMs: 1000 })

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x64) // 'd'
  assert.equal(link.written[1][0], 0x32) // '2' (drive 2)

  link.feed('\r\nUPLOAD 143360 bytes, send now\r\n')

  for (let t = 0; t < 35; t++) {
    while (link.written.length < 3 + t) {
      await new Promise((r) => setTimeout(r, 5))
    }
    link.feed([ACK_BYTE])
  }

  link.feed('\r\nlost\r\n> ')

  await assert.rejects(uploadPromise, /FPGA reported bytes lost/)
})

test('downloadDisk streams 143,360 bytes from FPGA and returns full image', async () => {
  const link = createMockLink()
  const expected = new Uint8Array(DISK_BYTES)
  for (let i = 0; i < DISK_BYTES; i++) expected[i] = (i ^ 0x5a) & 0xff

  const progressEvents = []
  const originalOnBytes = link.onBytes

  const downloadPromise = downloadDisk(link, 1, {
    onProgress: (p) => progressEvents.push(p),
    timeoutMs: 1000,
  })

  await new Promise((r) => setTimeout(r, 60))
  assert.equal(link.written[0][0], 0x65) // 'e'
  assert.equal(link.written[1][0], 0x31) // '1'

  // Board responds with download banner
  link.feed('\r\nDOWNLOAD 143360 bytes\r\n')

  // Feed the 143,360 bytes in multiple chunks (e.g. 512-byte slices)
  const chunkSize = 512
  for (let i = 0; i < DISK_BYTES; i += chunkSize) {
    link.feed(expected.subarray(i, Math.min(i + chunkSize, DISK_BYTES)))
  }

  // Board finishes with done
  link.feed('\r\ndone\r\n> ')

  const downloaded = await downloadPromise

  assert.equal(downloaded.length, DISK_BYTES)
  assert.deepEqual(downloaded, expected)
  assert.ok(progressEvents.length > 0)
  assert.equal(progressEvents[progressEvents.length - 1].bytesReceived, DISK_BYTES)
  assert.equal(link.onBytes, originalOnBytes)
})

test('diskChecksum is the rotate-and-add the FPGA computes', () => {
  assert.equal(diskChecksum(new Uint8Array(0)), 0)
  assert.equal(diskChecksum(Uint8Array.from([1])), 1)
  assert.equal(diskChecksum(Uint8Array.from([1, 1])), 3) // (1<<1)+1
  assert.equal(diskChecksum(Uint8Array.from([0x80, 0, 0, 0, 0])), 0x80 << 4) // rotates, no loss
  const a = new Uint8Array(DISK_BYTES).fill(7)
  const b = a.slice()
  b[100] = 8
  assert.notEqual(diskChecksum(a), diskChecksum(b))
})

test('queryDiskSums sends i and parses both checksums', async () => {
  const link = createMockLink()
  const p = queryDiskSums(link, { timeoutMs: 1000 })
  assert.deepEqual([...link.written[0]], [0x69])
  link.feed('\r\nI1:00000000 I2:DEADBEEF\r\n> ')
  assert.deepEqual(await p, [0, 0xdeadbeef])
})

test('parseHdStatus reads the slot 7 part of the i line', () => {
  // drive 1 slot 3 loaded, drive 2 empty, idle
  assert.deepEqual(parseHdStatus('I1:00000000 I2:00000000 H:00 V1:0003 V2:FFFF S:01'), {
    slots: [3, null], present: [true, false], busy: false, loading: false, error: null,
  })
  // loading, busy, err with estage 6 (CMD18)
  assert.deepEqual(parseHdStatus('V1:0000 V2:0001 S:F8'), {
    slots: [0, 1], present: [false, false], busy: true, loading: true, error: 6,
  })
  assert.equal(parseHdStatus('I1:00000000 I2:00000000 H:00'), null)
})

test('mountHd sends y, drive and slot, then polls i until not busy', async () => {
  const link = createMockLink()
  let polls = 0
  const write = link.write.bind(link)
  link.write = (b) => {
    write(b)
    if (b[0] === 0x69) {
      polls++
      queueMicrotask(() => link.feed(`\r\nI1:0 V1:${polls < 3 ? 'FFFF' : '002A'} V2:FFFF S:${polls < 3 ? 'C0' : '01'}\r\n> `))
    }
  }
  const st = await mountHd(link, 1, 42, { pollMs: 1 })
  assert.equal(new TextDecoder().decode(link.written[0]), 'y1002A')
  assert.equal(polls, 3)
  assert.deepEqual(st.slots, [42, null])
  await assert.rejects(mountHd(link, 2, 0x10000), /Slot must be/)
  link.write = (b) => {
    write(b)
    if (b[0] === 0x69) queueMicrotask(() => link.feed('V1:0001 V2:FFFF S:3C\r\n'))   // err, stage 7
  }
  await assert.rejects(mountHd(link, 1, 1, { pollMs: 1 }), /stage 7/)
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

/** A board that takes q the way serial_debugger.v does, into a card of slots. */
function createSlotBoard() {
  const link = createMockLink()
  const write = link.write.bind(link)
  const slots = new Map()
  let rx = []
  let slot = null
  let blk = 0
  link.write = (bytes) => {
    write(bytes)
    const arr = [...bytes]
    if (slot === null) {
      const t = new TextDecoder().decode(Uint8Array.from(arr))
      if (/^q[0-9A-F]{4}$/.test(t)) {
        slot = parseInt(t.slice(1), 16)
        blk = 0
        if (!slots.has(slot)) slots.set(slot, new Uint8Array(70 * 512).fill(0xee))
        queueMicrotask(() => link.feed('\r\nUPLOAD HD\r\n'))
      }
      return
    }
    rx.push(...arr)
    const vol = slots.get(slot)
    while (rx.length) {
      if (rx[0] === 1 && rx.length >= 513) {
        vol.set(rx.slice(1, 513), blk++ * 512)
        rx = rx.slice(513)
      } else if (rx[0] === 0 && rx.length >= 3) {
        const n = ((rx[1] << 8) | rx[2]) + 1
        for (let i = 0; i < n; i++, blk++) vol.fill(0, blk * 512, (blk + 1) * 512)
        rx = rx.slice(3)
      } else if (rx[0] === 2) {
        rx = rx.slice(1)
        slot = null
        queueMicrotask(() => link.feed('\r\ndone\r\n'))
        return
      } else break
      queueMicrotask(() => link.feed([ACK_BYTE]))
    }
  }
  return { link, slots }
}

test('copyToSlot sends q, the records and 02, and the slot ends up holding the image', async () => {
  const { link, slots } = createSlotBoard()
  const data = new Uint8Array(40 * 512)
  for (let i = 0; i < data.length; i++) data[i] = ((i * 13) & 0xff) | 1
  data.fill(0, 10 * 512, 25 * 512) // a hole, which goes as a zero run
  const progress = []
  await copyToSlot(link, 0x2a, data, { onProgress: (p) => progress.push(p.blocks), timeoutMs: 1000 })
  assert.equal(new TextDecoder().decode(link.written[0]), 'q002A')
  assert.deepEqual(slots.get(0x2a).subarray(0, data.length), data)
  assert.equal(slots.get(0x2a)[data.length], 0xee, 'nothing written past the image')
  assert.equal(progress.at(-1), 40)
  await assert.rejects(copyToSlot(link, 0xffff, data), /Slot must be/)
})

test('copyToSlot says so when the board refuses (no TF card)', async () => {
  const link = createMockLink()
  const write = link.write.bind(link)
  link.write = (b) => {
    write(b)
    queueMicrotask(() => link.feed('\r\nlost\r\n'))
  }
  await assert.rejects(copyToSlot(link, 1, new Uint8Array(512), { timeoutMs: 1000 }), /refused/)
})

test('buildCardImage lays out the config and the slots as sd_vol.v reads them', () => {
  const a = new Uint8Array(1600 * 512).fill(0x11)
  const c = new Uint8Array(280 * 512).fill(0x33)
  const { parts, size } = buildCardImage([a, null, c], [0, 2])
  const img = new Uint8Array(size)
  let at = 0
  for (const p of parts) {
    img.set(p, at)
    at += p.length
  }
  assert.equal(at, size)
  assert.equal(size, (2048 + 2 * 65536) * 512 + c.length, 'ends with the last slot')
  assert.deepEqual([...img.subarray(0, 8)], [0x41, 0x32, 0x48, 0x44, 0, 0, 2, 0])
  assert.ok(img.subarray(8, 2048 * 512).every((x) => x === 0))
  assert.deepEqual(img.subarray(2048 * 512, 2048 * 512 + a.length), a)
  assert.ok(img.subarray((2048 + 65536) * 512, (2048 + 2 * 65536) * 512).every((x) => x === 0), 'slot 1 empty')
  assert.deepEqual(img.subarray((2048 + 2 * 65536) * 512), c)
  assert.deepEqual([...buildCardImage([a], [null, null]).parts[0].subarray(4, 8)], [0xff, 0xff, 0xff, 0xff])
  assert.throws(() => buildCardImage([], [null, null]), /at least one/)
  assert.throws(() => buildCardImage([a], [1, null]), /no image/)
  assert.throws(() => buildCardImage([a], [0, 0]), /both drives/)
})
