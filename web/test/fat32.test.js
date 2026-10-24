// ============================================================================
//  fat32.test.js -- the page's FAT32 layer and A2CONFIG.TXT, on an in-memory card
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import { Fat32, memoryDevice, mkfs, to83, from83, lfnChecksum } from '../src/fat32.js'
import { parseConfig, formatConfig } from '../src/config.js'

const MB = 1024 * 1024
const card = async (spc = 1) => new Fat32(memoryDevice(mkfs(64 * MB, spc))).mount()
const bytes = (n, seed = 1) => Uint8Array.from({ length: n }, (_, i) => (i * 7 + seed) & 0xff)

test('8.3 names and the LFN checksum', () => {
  assert.equal(to83('GAME.DSK'), 'GAME    DSK')
  assert.equal(to83('README'), 'README     ')
  assert.equal(to83('game.dsk'), null) // lower case needs an LFN
  assert.equal(to83('TOOLONGNAME.DSK'), null)
  assert.equal(from83('GAME    DSK'), 'GAME.DSK')
  assert.equal(from83('README     '), 'README')
  // the checksum Windows writes for "TOTALR~1HDV"
  let sum = 0
  for (const ch of 'TOTALR~1HDV') sum = (((sum & 1) << 7) + (sum >> 1) + ch.charCodeAt(0)) & 0xff
  assert.equal(lfnChecksum('TOTALR~1HDV'), sum)
})

test('create, list, read back, replace and delete', async () => {
  const fs = await card()
  const a = bytes(143360)
  await fs.create('GAME.DSK', a)
  const b = bytes(5000, 9)
  await fs.create('Total Replay v6.1.hdv', b)

  const files = await fs.list()
  assert.deepEqual(files.map((f) => f.name), ['GAME.DSK', 'Total Replay v6.1.hdv'])
  assert.equal(files[1].short, 'TOTALR~1HDV')
  assert.deepEqual(await fs.readFile(files[0]), a)
  assert.deepEqual(await fs.readFile(files[1]), b)
  assert.ok(await fs.find('totalr~1.hdv'), 'found by short name too')

  const c = bytes(1000, 3)
  await fs.create('GAME.DSK', c) // replaces
  const again = await fs.list()
  assert.equal(again.filter((f) => f.name === 'GAME.DSK').length, 1)
  assert.deepEqual(await fs.readFile(await fs.find('GAME.DSK')), c)

  await fs.remove(await fs.find('Total Replay v6.1.hdv'))
  assert.deepEqual((await fs.list()).map((f) => f.name), ['GAME.DSK'])
})

test('freed clusters are reused, and new files are always contiguous', async () => {
  const fs = await card()
  for (const n of ['A', 'B', 'C']) await fs.create(`${n}.PO`, bytes(512))
  await fs.remove(await fs.find('B.PO'))
  await fs.create('D.PO', bytes(512 * 3)) // does not fit B's one-cluster hole
  const d = await fs.find('D.PO')
  const ext = await fs.extent(d)
  assert.ok(ext, 'contiguous')
  assert.equal(ext.sectors, 3)
  // allocation carries on from FSInfo's hint (as Windows does); no two files share a cluster
  await fs.create('E.PO', bytes(512))
  const used = []
  for (const f of await fs.list()) used.push(...(await fs.chain(f.cluster)))
  assert.equal(new Set(used).size, used.length)
})

test('a fragmented file has no extent', async () => {
  const fs = await card()
  await fs.create('F.DSK', bytes(1024))
  const f = await fs.find('F.DSK')
  await fs.setFat(new Map([[f.cluster, f.cluster + 5], [f.cluster + 5, 0x0fffffff], [f.cluster + 1, 0]]))
  assert.equal(await fs.extent(f), null)
})

test('the root directory grows past one cluster', async () => {
  const fs = await card()
  const names = Array.from({ length: 20 }, (_, i) => `Disk number ${i}.dsk`) // 3 slots each
  for (const n of names) await fs.create(n, bytes(100, names.indexOf(n)))
  assert.ok((await fs.chain(fs.rootCluster)).length > 1)
  const files = await fs.list()
  assert.deepEqual(files.map((f) => f.name), names)
  assert.deepEqual(await fs.readFile(files[13]), bytes(100, 13))
})

test('larger clusters', async () => {
  const fs = await card(8)
  const data = bytes(143360)
  await fs.create('GAME.DSK', data)
  const f = await fs.find('GAME.DSK')
  assert.deepEqual(await fs.extent(f), { lba: fs.clusterLba(f.cluster), sectors: 280 })
  assert.deepEqual(await fs.readFile(f), data)
})

test('a card that is not FAT32 is refused', async () => {
  await assert.rejects(new Fat32(memoryDevice(new Uint8Array(MB))).mount(), /not FAT32/)
})

test('A2CONFIG.TXT round trip', () => {
  const cfg = { S6D1: 'LODERU~1.DSK', S6D2: null, S7D1: 'TOTALR~1.HDV', S7D2: null }
  const text = formatConfig(cfg, { S6D1: 'Lode Runner.dsk', S7D1: 'Total Replay v6.1.hdv' })
  assert.equal(text, 'S6D1=LODERU~1.DSK ; Lode Runner.dsk\r\nS6D2=\r\nS7D1=TOTALR~1.HDV ; Total Replay v6.1.hdv\r\nS7D2=\r\n')
  assert.deepEqual(parseConfig(text), cfg)
  assert.deepEqual(parseConfig('s7d2 = game.po\n'), { S6D1: null, S6D2: null, S7D1: null, S7D2: 'GAME.PO' })
  assert.throws(() => parseConfig('S8D1=X.DSK'), /not KEY=NAME/)
  assert.throws(() => parseConfig('S6D1=Lode Runner.dsk'), /not KEY=NAME/)
})
