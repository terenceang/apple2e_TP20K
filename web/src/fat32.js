// ============================================================================
//  fat32.js -- the TF card's FAT32 file system, in the page rather than the FPGA
//
//  The board only reads and writes raw 512-byte sectors (the debugger's b/u
//  commands, src/sd_vol.v); everything that knows about FAT lives here, over a
//  block device { read(lba, n) -> Uint8Array, write(lba, bytes) }, which is the
//  board in the app and a Uint8Array in the tests.  Root directory only, which
//  is where the FPGA looks for A2CONFIG.TXT and the images it names.
//
//  New files are always allocated as one run of clusters: the FPGA streams a
//  mounted image with a single CMD18 from its first sector, so it can only use
//  a contiguous file, and it checks that itself at boot (sd_vol's chain walk).
//  `extent` is the same check here.
// ============================================================================

/**
 * @typedef {{
 *   name: string, short: string, size: number, cluster: number, attr: number,
 *   dir: boolean, slots: { lba: number, off: number }[],
 *   wozVersion?: number, fragmented?: boolean,
 * }} DirEntry
 * `name` is the long name when there is one, `short` the 11-byte 8.3 form
 * ("GAME    DSK"), `slots` where the entry and its LFN entries sit.
 */

export const SECTOR = 512
const EOC = 0x0fffffff
const FREE = 0
const ATTR_LFN = 0x0f
const ATTR_VOLUME = 0x08
const ATTR_DIR = 0x10
const ATTR_ARCHIVE = 0x20

const le16 = (b, o) => b[o] | (b[o + 1] << 8)
const le32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0
const put16 = (b, o, v) => { b[o] = v & 0xff; b[o + 1] = (v >> 8) & 0xff }
const put32 = (b, o, v) => { put16(b, o, v & 0xffff); put16(b, o + 2, v >>> 16) }

/** The 11-byte directory form of an 8.3 name ("GAME.DSK" -> "GAME    DSK"), or null. */
export function to83(name) {
  const m = /^([A-Z0-9!#$%&'()\-@^_`{}~]{1,8})(?:\.([A-Z0-9!#$%&'()\-@^_`{}~]{1,3}))?$/.exec(name)
  return m ? m[1].padEnd(8) + (m[2] ?? '').padEnd(3) : null
}

/** "GAME    DSK" -> "GAME.DSK" */
export const from83 = (s) => s.slice(0, 8).trimEnd() + (s.slice(8).trim() ? '.' + s.slice(8).trim() : '')

/** The LFN checksum of an 11-byte short name. */
export function lfnChecksum(short11) {
  let sum = 0
  for (let i = 0; i < 11; i++) sum = (((sum & 1) << 7) + (sum >> 1) + short11.charCodeAt(i)) & 0xff
  return sum
}

/** The short-name basis Windows would use: upper case, illegal characters to "_", 8 + 3. */
function shortBasis(long) {
  const clean = (s) => s.toUpperCase().replace(/[ .]/g, '').replace(/[^A-Z0-9!#$%&'()\-@^_`{}~]/g, '_')
  const dot = long.lastIndexOf('.')
  const base = clean(dot > 0 ? long.slice(0, dot) : long)
  const ext = clean(dot > 0 ? long.slice(dot + 1) : '').slice(0, 3)
  return { base: base || '_', ext }
}

export class Fat32 {
  /** @param {{ read: (lba: number, n: number) => Promise<Uint8Array>, write: (lba: number, bytes: Uint8Array) => Promise<void> }} dev */
  constructor(dev) {
    this.dev = dev
    /** @type {Map<number, Uint8Array>} FAT sectors read so far (FAT 1's lba) */
    this.fatCache = new Map()
  }

  /** Read the MBR (or a partitionless "superfloppy") and the FAT32 boot sector. */
  async mount() {
    const s0 = await this.dev.read(0, 1)
    if (s0[510] !== 0x55 || s0[511] !== 0xaa) throw new Error('The card has no boot sector (not FAT32-formatted).')
    let part = 0
    const isVbr = (b) => String.fromCharCode(...b.subarray(0x52, 0x57)) === 'FAT32'
    if (!isVbr(s0)) {
      const type = s0[0x1c2]
      if (type !== 0x0b && type !== 0x0c) throw new Error(`The card's first partition is not FAT32 (type ${type.toString(16)}).`)
      part = le32(s0, 0x1c6)
    }
    const v = part ? await this.dev.read(part, 1) : s0
    if (!isVbr(v) || le16(v, 0x0b) !== SECTOR) throw new Error('The card is not FAT32 with 512-byte sectors.')
    this.part = part
    this.spc = v[0x0d]
    this.fatStart = part + le16(v, 0x0e)
    this.nFats = v[0x10]
    this.fatSize = le32(v, 0x24)
    this.rootCluster = le32(v, 0x2c)
    this.fsInfo = part + le16(v, 0x30)
    this.dataStart = this.fatStart + this.nFats * this.fatSize
    this.clusters = Math.floor((le32(v, 0x20) - (this.dataStart - part)) / this.spc) + 2 // highest + 1
    this.clusterBytes = this.spc * SECTOR
    return this
  }

  clusterLba(c) {
    return this.dataStart + (c - 2) * this.spc
  }

  async fatSector(c) {
    const lba = this.fatStart + Math.floor(c / 128)
    let s = this.fatCache.get(lba)
    if (!s) {
      s = await this.dev.read(lba, 1)
      this.fatCache.set(lba, s)
    }
    return { lba, s, o: (c % 128) * 4 }
  }

  async next(c) {
    const { s, o } = await this.fatSector(c)
    return le32(s, o) & 0x0fffffff
  }

  /** Set FAT entries (a Map cluster -> value) in every FAT copy, one write per sector. */
  async setFat(entries) {
    const dirty = new Set()
    for (const [c, val] of entries) {
      const { lba, s, o } = await this.fatSector(c)
      put32(s, o, (le32(s, o) & 0xf0000000) | (val & 0x0fffffff))
      dirty.add(lba)
    }
    for (const lba of [...dirty].sort((a, b) => a - b))
      for (let f = 0; f < this.nFats; f++) await this.dev.write(lba + f * this.fatSize, this.fatCache.get(lba))
  }

  async chain(first) {
    const out = []
    for (let c = first; c >= 2 && c < 0x0ffffff8; c = await this.next(c)) {
      if (out.length > this.clusters) throw new Error('FAT chain loops.')
      out.push(c)
    }
    return out
  }

  /** The root directory, as { name, short, size, cluster, attr, slots: [{lba, off}] } (slots: LFN entries then the short one). */
  async list() {
    const files = []
    const dirClusters = await this.chain(this.rootCluster)
    let lfn = [], lfnSlots = []
    for (const c of dirClusters) {
      const lba0 = this.clusterLba(c)
      const data = await this.dev.read(lba0, this.spc)
      for (let off = 0; off < data.length; off += 32) {
        const e = data.subarray(off, off + 32)
        const slot = { lba: lba0 + Math.floor(off / SECTOR), off: off % SECTOR }
        if (e[0] === 0x00) return files
        if (e[0] === 0xe5) { lfn = []; lfnSlots = []; continue }
        if (e[11] === ATTR_LFN) {
          let part = ''
          for (const o of [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]) {
            const ch = le16(e, o)
            if (ch === 0 || ch === 0xffff) break
            part += String.fromCharCode(ch)
          }
          lfn[(e[0] & 0x1f) - 1] = part
          lfnSlots.push(slot)
          continue
        }
        const short = String.fromCharCode(...e.subarray(0, 11))
        const name = lfn.length && lfn.every((p) => p !== undefined) ? lfn.join('') : from83(short)
        if (!(e[11] & ATTR_VOLUME))
          files.push({
            name, short, size: le32(e, 28), attr: e[11],
            cluster: (le16(e, 20) << 16) | le16(e, 26),
            dir: Boolean(e[11] & ATTR_DIR),
            slots: [...lfnSlots, slot],
          })
        lfn = []; lfnSlots = []
      }
    }
    return files
  }

  async find(name) {
    const lower = name.toLowerCase()
    return (await this.list()).find((f) => f.name.toLowerCase() === lower || from83(f.short).toLowerCase() === lower) ?? null
  }

  /** { lba, sectors } when the file is one run of clusters, else null (what the FPGA can mount). */
  async extent(f) {
    if (!f || f.cluster < 2 || f.size === 0) return null
    const ch = await this.chain(f.cluster)
    if (ch.length * this.clusterBytes < f.size) return null
    for (let i = 1; i < ch.length; i++) if (ch[i] !== ch[i - 1] + 1) return null
    return { lba: this.clusterLba(f.cluster), sectors: Math.ceil(f.size / SECTOR) }
  }

  async readFile(f, onProgress) {
    const out = new Uint8Array(f.size)
    const ch = await this.chain(f.cluster)
    let got = 0
    for (let i = 0; i < ch.length && got < f.size; ) {
      let n = 1 // read each contiguous run at once
      while (i + n < ch.length && ch[i + n] === ch[i] + n) n++
      const want = Math.min(n * this.spc, Math.ceil((f.size - got) / SECTOR))
      const data = await this.dev.read(this.clusterLba(ch[i]), want)
      out.set(data.subarray(0, Math.min(data.length, f.size - got)), got)
      got += want * SECTOR
      onProgress?.(Math.min(got, f.size), f.size)
      i += n
    }
    return out
  }

  /** The first run of `n` free clusters, from FSInfo's hint and then from the start. */
  async freeRun(n) {
    const info = await this.dev.read(this.fsInfo, 1)
    let hint = le32(info, 0x1ec)
    if (hint < 2 || hint >= this.clusters) hint = 2
    for (const [from, to] of [[hint, this.clusters], [2, hint]]) {
      let start = from, len = 0
      for (let c = from; c < to; c++) {
        if ((await this.next(c)) === FREE) {
          if (len++ === 0) start = c
          if (len === n) return start
        } else len = 0
      }
    }
    throw new Error(`No room on the card for ${n} contiguous clusters.`)
  }

  async updateFsInfo(nextFree) {
    const info = await this.dev.read(this.fsInfo, 1)
    put32(info, 0x1e8, 0xffffffff) // free count unknown: Windows recounts
    put32(info, 0x1ec, nextFree)
    await this.dev.write(this.fsInfo, info)
  }

  /** A short name not already in the root: the 8.3 form when `long` is one, else BASE~N.EXT. */
  shortFor(long, files) {
    const taken = new Set(files.map((f) => f.short))
    const exact = to83(long)
    if (exact && !taken.has(exact)) return { short: exact, needLfn: false }
    const { base, ext } = shortBasis(long)
    for (let n = 1; n < 1000000; n++) {
      const tail = `~${n}`
      const s = (base.slice(0, 8 - tail.length) + tail).padEnd(8) + ext.padEnd(3)
      if (!taken.has(s)) return { short: s, needLfn: true }
    }
    throw new Error('No short name left.')
  }

  /** `count` consecutive free directory slots, growing the root by a cluster if it has none. */
  async dirSlots(count) {
    const dirClusters = await this.chain(this.rootCluster)
    let run = []
    for (const c of dirClusters) {
      const lba0 = this.clusterLba(c)
      const data = await this.dev.read(lba0, this.spc)
      for (let off = 0; off < data.length; off += 32) {
        if (data[off] === 0x00 || data[off] === 0xe5) {
          run.push({ lba: lba0 + Math.floor(off / SECTOR), off: off % SECTOR })
          if (run.length === count) return run
        } else run = []
      }
    }
    const c = await this.freeRun(1)
    const last = dirClusters[dirClusters.length - 1]
    await this.dev.write(this.clusterLba(c), new Uint8Array(this.clusterBytes))
    await this.setFat(new Map([[c, EOC], [last, c]]))
    for (let off = 0; run.length < count; off += 32) // the old tail run carries on into it
      run.push({ lba: this.clusterLba(c) + Math.floor(off / SECTOR), off: off % SECTOR })
    return run
  }

  /** Write `entries` (32-byte arrays) into `slots`, one read-modify-write per sector. */
  async writeSlots(slots, entries) {
    const bySector = new Map()
    for (let i = 0; i < slots.length; i++) {
      const { lba, off } = slots[i]
      if (!bySector.has(lba)) bySector.set(lba, await this.dev.read(lba, 1))
      bySector.get(lba).set(entries[i], off)
    }
    for (const [lba, s] of bySector) await this.dev.write(lba, s)
  }

  /**
   * Create `name` holding `data` as one contiguous run.  An existing file of the
   * same name is replaced.  Data first, then the FAT chain, then the directory
   * entry, so an interrupted copy leaves at worst lost clusters, never a file
   * pointing at garbage.
   */
  async create(name, data, onProgress) {
    const old = await this.find(name)
    if (old) await this.remove(old)
    const files = await this.list()
    const { short, needLfn } = this.shortFor(name, files)
    const n = Math.max(1, Math.ceil(data.length / this.clusterBytes))
    const first = await this.freeRun(n)

    if (data.length) await this.dev.write(this.clusterLba(first), data, onProgress)
    const chain = new Map()
    for (let i = 0; i < n; i++) chain.set(first + i, i === n - 1 ? EOC : first + i + 1)
    await this.setFat(chain)
    await this.updateFsInfo(first + n)

    const entries = []
    if (needLfn) {
      const sum = lfnChecksum(short)
      const units = [...name].map((ch) => ch.charCodeAt(0))
      const parts = Math.ceil(units.length / 13)
      for (let p = parts; p >= 1; p--) {
        const e = new Uint8Array(32)
        e[0] = p | (p === parts ? 0x40 : 0)
        e[11] = ATTR_LFN
        e[13] = sum
        const offs = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for (let k = 0; k < 13; k++) {
          const i = (p - 1) * 13 + k
          put16(e, offs[k], i < units.length ? units[i] : i === units.length ? 0 : 0xffff)
        }
        entries.push(e)
      }
    }
    const e = new Uint8Array(32)
    for (let i = 0; i < 11; i++) e[i] = short.charCodeAt(i)
    e[11] = ATTR_ARCHIVE
    const d = new Date()
    const time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)
    const date = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()
    for (const o of [14, 22]) put16(e, o, time)
    for (const o of [16, 18, 24]) put16(e, o, date)
    put16(e, 20, first >>> 16)
    put16(e, 26, first & 0xffff)
    put32(e, 28, data.length)
    entries.push(e)

    await this.writeSlots(await this.dirSlots(entries.length), entries)
    return { name, short, size: data.length, cluster: first }
  }

  /** Delete a file: free its chain and mark its entries (LFN ones too) deleted. */
  async remove(f) {
    const ch = f.cluster >= 2 ? await this.chain(f.cluster) : []
    await this.setFat(new Map(ch.map((c) => [c, FREE])))
    // only byte 0 changes, as on Windows
    const bySector = new Map()
    for (const { lba, off } of f.slots) {
      if (!bySector.has(lba)) bySector.set(lba, await this.dev.read(lba, 1))
      bySector.get(lba)[off] = 0xe5
    }
    for (const [lba, s] of bySector) await this.dev.write(lba, s)
  }
}

/** A block device over a Uint8Array, for tests and for building card images. */
export function memoryDevice(img) {
  return {
    img,
    async read(lba, n) { return img.slice(lba * SECTOR, (lba + n) * SECTOR) },
    async write(lba, bytes) {
      const pad = bytes.length % SECTOR ? new Uint8Array(Math.ceil(bytes.length / SECTOR) * SECTOR) : null
      if (pad) pad.set(bytes)
      img.set(pad ?? bytes, lba * SECTOR)
    },
  }
}

/**
 * Format `bytes` of card as FAT32 behind an MBR (partition at LBA 2048), the
 * layout Windows and SD Formatter produce.  For tests and sim images; a real
 * card is formatted on a PC.
 */
export function mkfs(bytes, spc = 1) {
  const img = new Uint8Array(bytes)
  const total = bytes / SECTOR
  const part = 2048
  const psize = total - part
  const rsvd = 32
  const fatSize = Math.ceil(((psize - rsvd) / spc + 2) * 4 / SECTOR)
  img[0x1be + 4] = 0x0c
  put32(img, 0x1c6, part)
  put32(img, 0x1ca, psize)
  img[510] = 0x55; img[511] = 0xaa
  const v = img.subarray(part * SECTOR, (part + 1) * SECTOR)
  v.set([0xeb, 0x58, 0x90], 0)
  v.set([...'MSWIN4.1'].map((c) => c.charCodeAt(0)), 3)
  put16(v, 0x0b, SECTOR); v[0x0d] = spc; put16(v, 0x0e, rsvd); v[0x10] = 2
  v[0x15] = 0xf8; put32(v, 0x1c, part); put32(v, 0x20, psize)
  put32(v, 0x24, fatSize); put32(v, 0x2c, 2); put16(v, 0x30, 1); put16(v, 0x32, 6)
  v[0x42] = 0x29
  v.set([...'NO NAME    FAT32   '].map((c) => c.charCodeAt(0)), 0x47)
  v[510] = 0x55; v[511] = 0xaa
  const fi = img.subarray((part + 1) * SECTOR, (part + 2) * SECTOR)
  put32(fi, 0, 0x41615252); put32(fi, 0x1e4, 0x61417272)
  put32(fi, 0x1e8, 0xffffffff); put32(fi, 0x1ec, 3); put32(fi, 0x1fc, 0xaa550000)
  for (let f = 0; f < 2; f++) {
    const fat = (part + rsvd + f * fatSize) * SECTOR
    put32(img, fat, 0x0ffffff8); put32(img, fat + 4, 0x0fffffff); put32(img, fat + 8, EOC) // root = cluster 2
  }
  return img
}
