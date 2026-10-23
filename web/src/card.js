// ============================================================================
//  card.js -- the TF card as the page uses it: files, and which drive holds which
//
//  The board finds a drive's file by the 8.3 name A2CONFIG.TXT gives it, at
//  power-on and on the debugger's y (src/sd_vol.v); everything else here is
//  the page's own FAT32 (src/fat32.js) over raw sector reads and writes.
// ============================================================================

import { Fat32, from83 } from './fat32.js'
import { CONFIG_NAME, DRIVES, parseConfig, formatConfig } from './config.js'
import { DISK_BYTES, HD_BLOCK_BYTES, HD_MAX_BLOCKS, validateHardDiskImage, reloadDrive, cardDevice } from './disk.js'
import { toWoz, WOZ_MAX } from './woz.js'

const ext = (name) => (/\.([^.]*)$/.exec(name)?.[1] ?? '').toLowerCase()

/**
 * Whether drive `d` (0-3: S6D1 S6D2 S7D1 S7D2) can use `file`, by the same
 * rules sd_vol.v applies at boot: slot 6 takes a .woz (WOZ 2, up to 1 MB;
 * the page converts every other floppy format to it on upload, src/woz.js),
 * slot 7 a .hdv or .po of whole blocks up to 32 MB.
 *
 * @param {{ name: string, short: string, size: number }} file
 * @param {number} d
 */
export function fitsDrive(file, d) {
  const e = ext(from83(file.short))
  if (d < 2) return e === 'woz' && file.size >= 1536 && file.size <= WOZ_MAX
  return ['hdv', 'po'].includes(e) && file.size > 0 && file.size % HD_BLOCK_BYTES === 0 &&
    file.size <= HD_MAX_BLOCKS * HD_BLOCK_BYTES
}

/** A file the page lists: a disk image of some kind, not the config or a directory. */
const isImage = (f) => !f.dir && f.name.toUpperCase() !== CONFIG_NAME && (fitsDrive(f, 0) || fitsDrive(f, 2))

/**
 * What to store for an uploaded file: the bytes, and the name.  A floppy
 * (.dsk .do .nib .woz, or a 140K .po) becomes a WOZ 2 .woz; a .2mg becomes
 * .po, its header stripped, so the blocks start on a sector.
 *
 * @param {string} name
 * @param {Uint8Array} data
 */
export function prepareCardFile(name, data) {
  const e = ext(name)
  if (['dsk', 'do', 'nib', 'woz'].includes(e) || (e === 'po' && data.length === DISK_BYTES)) {
    try {
      return toWoz(name, data)
    } catch (err) {
      throw new Error(`${name}: ${err.message.replace(/^.*?: /, '')}`)
    }
  }
  if (['hdv', 'po', '2mg'].includes(e)) {
    const blocks = validateHardDiskImage(data)
    return { name: e === '2mg' ? name.replace(/\.2mg$/i, '.po') : name, data: blocks }
  }
  throw new Error(`${name}: not a disk image (.dsk .do .po .nib .woz .hdv .2mg).`)
}

/** The card, mounted: its files, A2CONFIG.TXT, and the board's link for reloads. */
export class Card {
  /** @param {import('./fat32.js').Fat32} fs */
  constructor(fs, link) {
    this.fs = fs
    this.link = link
  }

  /** @param {{ write: Function, onBytes: Function }} link */
  static async open(link, dev = cardDevice(link)) {
    return new Card(await new Fat32(dev).mount(), link)
  }

  /** Every file in the root, and the config as 8.3 names per drive key. */
  async scan() {
    const files = await this.fs.list()
    const cf = files.find((f) => f.name.toUpperCase() === CONFIG_NAME)
    let config = Object.fromEntries(DRIVES.map((k) => [k, null]))
    let configError = null
    if (cf) {
      try {
        config = parseConfig(new TextDecoder().decode(await this.fs.readFile(cf)))
      } catch (e) {
        configError = e.message
      }
    }
    // the file each drive names, if it is on the card
    const byShort = new Map(files.map((f) => [from83(f.short), f]))
    const drives = DRIVES.map((k) => (config[k] ? byShort.get(config[k]) ?? null : null))
    return { files: files.filter(isImage), config, configError, drives }
  }

  async upload(name, data, onProgress) {
    const f = prepareCardFile(name, data)
    return this.fs.create(f.name, f.data, onProgress)
  }

  async download(file, onProgress) {
    return this.fs.readFile(file, onProgress)
  }

  async remove(file) {
    await this.fs.remove(file)
  }

  /**
   * Put `file` in drive `d` (0-3), or empty it with null: rewrite A2CONFIG.TXT,
   * then have the board reload that drive.  A file in another drive is taken
   * out of it, since two drives writing one file would undo each other.
   */
  async mount(d, file, opts = {}) {
    const { config, configError, files } = await this.scan()
    if (configError) throw new Error(`${configError} -- fix or delete ${CONFIG_NAME} first.`)
    const others = []
    if (file) {
      if (!fitsDrive(file, d)) throw new Error(`${file.name} does not fit ${DRIVES[d]}.`)
      if (!(await this.fs.extent(file))) {
        throw new Error(`${file.name} is fragmented on the card, so the board cannot stream it. Copy it off, delete it and copy it back.`)
      }
      const short = from83(file.short)
      DRIVES.forEach((k, i) => {
        if (i !== d && config[k] === short) { config[k] = null; others.push(i) }
      })
    }
    config[DRIVES[d]] = file ? from83(file.short) : null
    const long = {}
    for (const k of DRIVES) {
      const f = files.find((x) => from83(x.short) === config[k])
      if (f) long[k] = f.name
    }
    await this.fs.create(CONFIG_NAME, new TextEncoder().encode(formatConfig(config, long)))
    let st = null
    for (const i of [...others, d]) st = await reloadDrive(this.link, /** @type {1|2|3|4} */ (i + 1), opts)
    return st
  }
}
