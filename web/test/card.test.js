// ============================================================================
//  card.test.js -- the TF card end to end: the page's FAT32 over the board's
//  b/u commands, A2CONFIG.TXT, and y reloading a drive
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import { mkfs, memoryDevice, Fat32 } from '../src/fat32.js'
import { Card, fitsDrive, prepareCardFile } from '../src/card.js'
import { parseCardStatus, readSectors, writeSectors, reloadDrive } from '../src/disk.js'
import { createCardBoard } from './board.js'
import { dskToWoz, wozToDsk } from '../src/woz.js'

const MB = 1024 * 1024
const bytes = (n, seed = 1) => Uint8Array.from({ length: n }, (_, i) => (i * 7 + seed + (i >> 9)) & 0xff)
const fast = { pollMs: 1 }

test('parseCardStatus reads S:ssss', () => {
  // S6D1 and S7D1 present, S6D2 and S7D2 failed, FAT32
  assert.deepEqual(parseCardStatus('H:00 S:02A5'), {
    present: [true, false, true, false], fail: [false, true, false, true],
    fsOk: true, busy: false, loading: false, error: null,
  })
  // loading, busy, err at estage 6 (CMD18)
  assert.deepEqual(parseCardStatus('S:F800'), {
    present: [false, false, false, false], fail: [false, false, false, false],
    fsOk: false, busy: true, loading: true, error: 6,
  })
  assert.equal(parseCardStatus('H:00'), null)
})

test('readSectors and writeSectors frame b and u, zero runs included', async () => {
  const { link, img } = createCardBoard(new Uint8Array(MB))
  const data = bytes(40 * 512)
  data.fill(0, 10 * 512, 25 * 512) // a hole, which goes as a zero run
  img.fill(0xee, 100 * 512, 150 * 512)
  const progress = []
  await writeSectors(link, 100, data, { onProgress: (p) => progress.push(p.blocks) })
  assert.equal(new TextDecoder().decode(link.written[0]), 'u00000064')
  assert.deepEqual(img.subarray(100 * 512, 140 * 512), data)
  assert.equal(img[140 * 512], 0xee, 'nothing written past the data')
  assert.equal(progress.at(-1), 40)
  assert.deepEqual(await readSectors(link, 100, 40), data)
  await assert.rejects(readSectors(link, 5000, 1), /read failed/)
})

test('upload, list, mount, move between drives, eject and download', async () => {
  const board = createCardBoard(mkfs(64 * MB, 8))
  const card = await Card.open(board.link)
  const game = bytes(143360, 3)
  const vol = bytes(800 * 512, 5)
  await card.upload('Lode Runner.dsk', game)
  await card.upload('Total Replay.hdv', vol)

  let s = await card.scan()
  assert.deepEqual(s.files.map((f) => f.name), ['Lode Runner.woz', 'Total Replay.hdv'], 'a floppy goes on as .woz')
  const [lode, tr] = s.files
  assert.ok(fitsDrive(lode, 0) && !fitsDrive(lode, 2), 'a .woz is slot 6 only')
  assert.ok(!fitsDrive(tr, 0) && fitsDrive(tr, 2))
  const po = { name: 'ProDOS.po', short: 'PRODOS  PO ', size: 143360 }
  assert.ok(!fitsDrive(po, 0) && fitsDrive(po, 2), 'a .po on the card is a slot 7 volume')
  const dsk = { name: 'GAME.DSK', short: 'GAME    DSK', size: 143360 }
  assert.ok(!fitsDrive(dsk, 0), 'slot 6 reads .woz only')

  await card.mount(0, lode, fast)
  await card.mount(2, tr, fast)
  assert.deepEqual(board.present, [true, false, true, false])
  s = await card.scan()
  assert.deepEqual(s.config, { S6D1: 'LODERU~1.WOZ', S6D2: null, S7D1: 'TOTALR~1.HDV', S7D2: null })
  assert.equal(s.drives[0].name, 'Lode Runner.woz')

  // the floppy into S6D2: it leaves S6D1, which reloads empty
  await card.mount(1, lode, fast)
  assert.deepEqual(board.present, [false, true, true, false])
  await assert.rejects(card.mount(0, tr, fast), /does not fit/)
  await assert.rejects(card.mount(3, lode, fast), /does not fit/)

  await card.mount(2, null, fast)
  assert.deepEqual((await card.scan()).config.S7D1, null)
  assert.deepEqual(board.present, [false, true, false, false])

  assert.deepEqual(wozToDsk(await card.download(lode)), game, 'the .woz decodes back to the .dsk')
  await card.remove(tr)
  assert.deepEqual((await card.scan()).files.map((f) => f.name), ['Lode Runner.woz'])

  // what the board sees is a FAT32 card a PC could read: check with a fresh mount
  const fs = await new Fat32(memoryDevice(board.img)).mount()
  assert.deepEqual(wozToDsk(await fs.readFile(await fs.find('Lode Runner.woz'))), game)
})

test('a fragmented file is refused before the board is asked', async () => {
  const board = createCardBoard(mkfs(64 * MB, 1))
  const card = await Card.open(board.link)
  const f = await card.upload('GAME.DSK', bytes(143360))
  await card.fs.setFat(new Map([[f.cluster + 9, f.cluster + 500], [f.cluster + 500, f.cluster + 10]]))
  const [file] = (await card.scan()).files
  await assert.rejects(card.mount(0, file, fast), /fragmented/)
  assert.deepEqual(board.present, [false, false, false, false])
})

test('a hand-edited config the page cannot read is left alone', async () => {
  const board = createCardBoard(mkfs(64 * MB, 1))
  const card = await Card.open(board.link)
  await card.fs.create('A2CONFIG.TXT', new TextEncoder().encode('S6D1=Lode Runner.dsk\r\n'))
  const f = await card.upload('GAME.DSK', bytes(143360))
  assert.match((await card.scan()).configError, /not KEY=NAME/)
  await assert.rejects(card.mount(0, { ...f, short: 'GAME    DSK' }, fast), /fix or delete/)
})

test('prepareCardFile: floppy sizes, .2mg becomes .po, other files are refused', () => {
  assert.equal(prepareCardFile('a.dsk', new Uint8Array(143360)).name, 'a.woz')
  assert.deepEqual(prepareCardFile('b.po', bytes(143360)).data, dskToWoz(bytes(143360), 'po'), 'a 140K .po is a floppy')
  assert.equal(prepareCardFile('c.nib', new Uint8Array(35 * 6656)).name, 'c.woz')
  assert.throws(() => prepareCardFile('a.dsk', new Uint8Array(1000)), /a\.dsk: a floppy image is 143,360 bytes/)
  const two = new Uint8Array(64 + 1024)
  two.set([0x32, 0x49, 0x4d, 0x47]) // "2IMG"
  const v = new DataView(two.buffer)
  v.setUint32(0x0c, 1, true); v.setUint32(0x18, 64, true); v.setUint32(0x1c, 1024, true)
  const p = prepareCardFile('Vol.2mg', two)
  assert.equal(p.name, 'Vol.po')
  assert.equal(p.data.length, 1024)
  assert.throws(() => prepareCardFile('notes.txt', new Uint8Array(512)), /not a disk image/)
})

test('reloadDrive sends y and the drive, then polls i until not busy', async () => {
  const board = createCardBoard(mkfs(64 * MB, 1))
  const st = await reloadDrive(board.link, 3, fast)
  assert.equal(new TextDecoder().decode(board.link.written[0]), 'y3')
  assert.equal(st.busy, false)
  await assert.rejects(reloadDrive(board.link, 5), /Drive must be/)
})
