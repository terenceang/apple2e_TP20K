// Convert floppy images for a TF card written with a card reader: slot 6 reads
// .woz only (WOZ 2), and the page converts on upload with the same code.
//
//   node web/scripts/towoz.mjs Game.dsk [More.po Other.nib Old.woz ...]   -> Game.woz ...
//   node web/scripts/towoz.mjs --dsk Saved.woz                            -> Saved.dsk (standard disks only)
//   node web/scripts/towoz.mjs --blank "New disk.woz"                     -> a blank floppy
import { readFileSync, writeFileSync } from 'node:fs'
import { toWoz, wozToDsk, blankWoz } from '../src/woz.js'

const args = process.argv.slice(2)
if (!args.length) {
  console.error('usage: towoz.mjs FILE... | --dsk FILE.woz... | --blank NAME.woz')
  process.exit(2)
}
let failed = 0
if (args[0] === '--blank') {
  writeFileSync(args[1] ?? 'blank.woz', blankWoz())
  console.log(`${args[1] ?? 'blank.woz'}: blank floppy`)
} else {
  const toDsk = args[0] === '--dsk'
  for (const name of toDsk ? args.slice(1) : args) {
    try {
      const data = new Uint8Array(readFileSync(name))
      const out = toDsk ? { name: name.replace(/\.woz$/i, '') + '.dsk', data: wozToDsk(data) } : toWoz(name, data)
      if (out.data === data) { console.log(`${name}: already WOZ 2`); continue }
      writeFileSync(out.name, out.data)
      console.log(`${name} -> ${out.name}`)
    } catch (e) {
      console.error(`${name}: ${e.message}`)
      failed++
    }
  }
}
process.exit(failed ? 1 : 0)
