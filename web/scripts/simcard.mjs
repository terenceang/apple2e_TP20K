// Build the FAT32 card image sim/tb_sdvol.v and sim/tb_sdcopy.v boot from,
// with the page's own FAT code: build/sim_card.hex, sparse ($readmemh, @ byte
// addresses), for sim/models/sdcard.v's INIT.  Run by sim/run.ps1.
//
//   GAME.WOZ        pattern 1 as a DOS-order .dsk, converted   S6D1
//   FRAG.WOZ        the same, fragmented                       S6D2 -> fails
//   Prodos Vol.hdv  16 blocks, pattern 2                       S7D1 (PRODOS~1.HDV)
//   MISSING.HDV     not on the card                            S7D2 -> fails
//   PROT.WOZ        write protected (INFO byte 22)             (the bench mounts it)
//   JUNK.WOZ        4 KB that is not a WOZ file                (the bench mounts it)
//   RAW.DSK         a .dsk, which slot 6 no longer reads       (the bench mounts it)
// plus twelve long-named files first, so the root runs past one cluster.
// The bench's pat() is the same function.
//
// Also build/sim_floppy.hex (a .woz as 16-bit words, low byte = even byte, for
// sim/tb_disk2.v's DDR3) and build/sim_floppy_dsk.hex (the .dsk it came from),
// and, when build/dos33_physical.bin is there (the DOS 3.3 System Master in
// physical sector order), build/dos33_woz.hex for sim/tb_p6boot.v.
import { writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs'
import { Fat32, memoryDevice, mkfs, SECTOR } from '../src/fat32.js'
import { dskToWoz } from '../src/woz.js'

const pat = (id, o) => (o * 7 + id * 13 + (o >>> 9)) & 0xff
const fill = (id, n) => Uint8Array.from({ length: n }, (_, o) => pat(id, o))

const game = dskToWoz(fill(1, 143360))
const prot = dskToWoz(fill(5, 143360))
prot[22] = 1

const img = mkfs(4 * 1024 * 1024, 2)
const fs = await new Fat32(memoryDevice(img)).mount()
for (let i = 0; i < 12; i++) await fs.create(`Some other disk number ${i}.dsk`, fill(9, 100))
await fs.create('GAME.WOZ', game)
await fs.create('FRAG.WOZ', game)
await fs.create('Prodos Vol.hdv', fill(2, 16 * 512))
await fs.create('PROT.WOZ', prot)
await fs.create('JUNK.WOZ', fill(7, 4096))
await fs.create('RAW.DSK', fill(1, 143360))
await fs.create(
  'A2CONFIG.TXT',
  new TextEncoder().encode('S6D1=GAME.WOZ\r\ns6d2 = frag.woz\r\nS7D1=PRODOS~1.HDV ; Prodos Vol.hdv\r\nS7D2=MISSING.HDV\r\n'),
)
// FRAG.WOZ: cluster 40 of its chain jumps to a free cluster and back
const frag = await fs.find('FRAG.WOZ')
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

// tb_disk2's floppy: a DOS-order disk of pattern 6
const dsk = fill(6, 143360)
const woz = dskToWoz(dsk)
const wordsHex = (w) => {
  let out = ''
  for (let i = 0; i < w.length; i += 2) out += ((w[i + 1] << 8) | w[i]).toString(16).padStart(4, '0') + '\n'
  return out
}
writeFileSync('build/sim_floppy.hex', wordsHex(woz))
writeFileSync('build/sim_floppy_dsk.hex', Array.from(dsk, (b) => b.toString(16).padStart(2, '0')).join('\n') + '\n')
console.log(`build/sim_floppy.hex: ${woz.length} bytes of WOZ`)

if (existsSync('build/dos33_physical.bin')) {
  const phys = new Uint8Array(readFileSync('build/dos33_physical.bin'))
  const DOS2PHYS = [0, 13, 11, 9, 7, 5, 3, 1, 14, 12, 10, 8, 6, 4, 2, 15]
  const dos = new Uint8Array(143360)
  for (let t = 0; t < 35; t++)
    for (let l = 0; l < 16; l++) dos.set(phys.subarray((t * 16 + DOS2PHYS[l]) * 256, (t * 16 + DOS2PHYS[l] + 1) * 256), (t * 16 + l) * 256)
  writeFileSync('build/dos33_woz.hex', wordsHex(dskToWoz(dos)))
  console.log('build/dos33_woz.hex: the DOS 3.3 System Master')
}
