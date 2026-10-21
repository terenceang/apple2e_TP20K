// Build the FAT32 card image sim/tb_sdvol.v and sim/tb_sdcopy.v boot from,
// with the page's own FAT code: build/sim_card.hex, sparse ($readmemh, @ byte
// addresses), for sim/models/sdcard.v's INIT.  Run by sim/run.ps1.
//
//   GAME.DSK        143,360 bytes, pattern 1        S6D1
//   FRAG.PO         143,360 bytes, fragmented       S6D2 -> fails
//   Prodos Vol.hdv  16 blocks, pattern 2            S7D1 (PRODOS~1.HDV)
//   MISSING.HDV     not on the card                 S7D2 -> fails
// plus twelve long-named files first, so the root runs past one cluster.
// The bench's pat() is the same function.
import { writeFileSync, mkdirSync } from 'node:fs'
import { Fat32, memoryDevice, mkfs, SECTOR } from '../src/fat32.js'

const pat = (id, o) => (o * 7 + id * 13 + (o >>> 9)) & 0xff
const fill = (id, n) => Uint8Array.from({ length: n }, (_, o) => pat(id, o))

const img = mkfs(4 * 1024 * 1024, 2)
const fs = await new Fat32(memoryDevice(img)).mount()
for (let i = 0; i < 12; i++) await fs.create(`Some other disk number ${i}.dsk`, fill(9, 100))
await fs.create('GAME.DSK', fill(1, 143360))
await fs.create('FRAG.PO', fill(3, 143360))
await fs.create('Prodos Vol.hdv', fill(2, 16 * 512))
await fs.create(
  'A2CONFIG.TXT',
  new TextEncoder().encode('S6D1=GAME.DSK\r\ns6d2 = frag.po\r\nS7D1=PRODOS~1.HDV ; Prodos Vol.hdv\r\nS7D2=MISSING.HDV\r\n'),
)
// FRAG.PO: cluster 40 of its chain jumps to a free cluster and back
const frag = await fs.find('FRAG.PO')
const away = frag.cluster + 2000
await fs.setFat(new Map([[frag.cluster + 39, away], [away, frag.cluster + 40]]))

let out = ''
for (let s = 0; s < img.length / SECTOR; s++) {
  const sec = img.subarray(s * SECTOR, (s + 1) * SECTOR)
  if (!sec.some((b) => b)) continue
  out += `@${(s * SECTOR).toString(16)}\n`
  for (let i = 0; i < SECTOR; i += 32)
    out += Array.from(sec.subarray(i, i + 32), (b) => b.toString(16).padStart(2, '0')).join(' ') + '\n'
}
mkdirSync('build', { recursive: true })
writeFileSync('build/sim_card.hex', out)
console.log(`build/sim_card.hex: ${(await fs.list()).length} files`)
