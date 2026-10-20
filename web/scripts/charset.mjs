// ============================================================================
//  charset.mjs -- turn roms/apple2e_char.hex into src/generated/charset.json
//
//  The 2732 video ROM is 4 KB and video_generator.v addresses 12 bits of it,
//  one byte per dot with bit 0 the leftmost dot and a 0 meaning the dot is
//  lit. This script does NOT try to interpret that -- it copies the bytes
//  through, and src/charset.js does the addressing with the same expression
//  the RTL uses, so the browser and the HDMI output cannot drift apart.
//
//  The ROM is Apple copyright and gitignored, so this is a local build step
//  and so is its output. Supply the ROMs (see roms/README.md), then:
//
//      npm run charset
// ============================================================================

import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { parseHexDump } from './lib/charrom.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const WEB = resolve(HERE, '..')
const REPO = resolve(WEB, '..')

const CANDIDATES = [
  process.env.CHAR_ROM,
  join(REPO, 'roms', 'apple2e_char.hex'),
  join(REPO, 'roms', 'Apple IIe Video - Enhanced - 342-0265-A - 2732.bin'),
].filter(Boolean)

const src = CANDIDATES.find((p) => existsSync(p))
if (!src) {
  console.error('charset: no character ROM found. Tried:')
  for (const c of CANDIDATES) console.error('  ' + c)
  console.error('')
  console.error('The 2732 video ROM is Apple copyright and is not in the repo.')
  console.error('See roms/README.md for how to supply it, then run: npm run charset')
  process.exit(1)
}

const raw = await readFile(src, 'utf8')

// $readmemh: 2 hex digits per line, // comments, anything else ignored
const bytes = parseHexDump(raw)

if (bytes.length < 2048) {
  console.error(
    `charset: ${src} has ${bytes.length} bytes; char_rom_addr is 12 bits, so at least 2048 are needed.`,
  )
  process.exit(1)
}

const dest = join(WEB, 'src', 'generated', 'charset.json')
await mkdir(dirname(dest), { recursive: true })
await writeFile(
  dest,
  JSON.stringify({ source: src.replace(REPO + '/', ''), bytes: bytes.slice(0, 4096) }),
)
console.log(`charset: wrote ${dest} (${bytes.length} bytes from ${src.replace(REPO + '/', '')})`)
