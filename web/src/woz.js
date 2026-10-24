// ============================================================================
//  woz.js -- floppy images as WOZ 2, the one format slot 6 reads
//
//  The board plays a WOZ track bit by bit (src/disk2/), so every floppy goes
//  onto the TF card as a .woz and the conversion happens here, on the PC:
//
//    .dsk/.do (DOS order) and 140K .po (ProDOS order)  -> standard 16-sector
//                                                         tracks, volume 254
//    .nib (35 x 6,656 nibbles)                          -> the nibbles as bits
//    .woz version 1                                     -> version 2 layout
//    nothing (a new disk)                               -> 35 blank tracks
//
//  and back: wozToDsk decodes standard tracks to sectors, for a .dsk to take
//  to another emulator (a protected track does not decode, and says so).
//
//  The layout is the one sd_vol.v and disk2_store.v read (WOZ 2 reference,
//  applesaucefdc.com/woz/reference2): header and CRC at 0, INFO at 12, TMAP
//  at 80 (quarter-track -> TRKS index, 0xFF empty), TRKS at 248, its 160
//  8-byte entries at 256 (start block, block count, bit count), bit data from
//  block 3, MSB first.  Every track this writes gets 13 blocks, so the board
//  can write a full track back into the space the file already has.
// ============================================================================

export const TRACKS = 35
export const TRACK_BLOCKS = 13 // 53,248 bits: a whole 6,656-nibble track
export const NIB_TRACK = 6656
export const WOZ_MAX = 1024 * 1024 // the board's limit per drive (src/sd_vol.v)
const SECTOR = 256
const DSK_BYTES = TRACKS * 16 * SECTOR
const VOLUME = 254

// ---- GCR ------------------------------------------------------------------
const GCR62 = [
  0x96, 0x97, 0x9a, 0x9b, 0x9d, 0x9e, 0x9f, 0xa6, 0xa7, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb2, 0xb3,
  0xb4, 0xb5, 0xb6, 0xb7, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xcb, 0xcd, 0xce, 0xcf, 0xd3,
  0xd6, 0xd7, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe5, 0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec,
  0xed, 0xee, 0xef, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
]
const UNGCR62 = new Map(GCR62.map((v, i) => [v, i]))
// DOS 3.3 logical sector -> physical sector; ProDOS order is 2s mod 15
const DOS2PHYS = [0, 13, 11, 9, 7, 5, 3, 1, 14, 12, 10, 8, 6, 4, 2, 15]
const PO2PHYS = Array.from({ length: 16 }, (_, s) => (s < 8 ? 2 * s : 2 * s - 15))
const rev2 = (b) => ((b & 1) << 1) | ((b >> 1) & 1)

/** 256 bytes -> the data field's 343 disk bytes (86 auxiliary, 256, checksum). */
export function encode62(data) {
  const v = new Array(342).fill(0)
  for (let i = 0; i < 256; i++) {
    const k = i % 86
    v[k] |= rev2(data[i] & 3) << (2 * Math.floor(i / 86))
    v[86 + i] = data[i] >> 2
  }
  const out = []
  let prev = 0
  for (const x of v) { out.push(GCR62[x ^ prev]); prev = x }
  out.push(GCR62[prev])
  return out
}

/** The inverse, or null when a byte is not a disk byte or the checksum fails. */
export function decode62(nibs) {
  const v = []
  let prev = 0
  for (let i = 0; i < 343; i++) {
    const x = UNGCR62.get(nibs[i])
    if (x === undefined) return null
    prev ^= x
    v.push(prev)
  }
  if (v[342] !== 0) return null // the checksum carries the last value, so the chain ends at 0
  const data = new Uint8Array(256)
  for (let i = 0; i < 256; i++) data[i] = (v[86 + i] << 2) | rev2((v[i % 86] >> (2 * Math.floor(i / 86))) & 3)
  return data
}

const a44 = (b) => [(b >> 1) | 0xaa, b | 0xaa]

// ---- bits -----------------------------------------------------------------
class Bits {
  constructor() { this.buf = new Uint8Array(TRACK_BLOCKS * 512); this.n = 0 }
  push(bit) { if (bit) this.buf[this.n >> 3] |= 0x80 >> (this.n & 7); this.n++ }
  byte(b, bits = 8) { for (let i = 7; i > 7 - bits && i >= 0; i--) this.push((b >> i) & 1); for (let i = 8; i < bits; i++) this.push(0) }
  bytes(list) { for (const b of list) this.byte(b) }
  sync(n) { for (let i = 0; i < n; i++) this.byte(0xff, 10) } // self-sync: FF and two zeros
}

/** One standard 16-sector track: ~50,000 bits, 300 rpm at 4 us a bit. */
function sectorTrack(track, sectorAt) {
  const t = new Bits()
  t.sync(64)
  for (let p = 0; p < 16; p++) {
    t.bytes([0xd5, 0xaa, 0x96, ...a44(VOLUME), ...a44(track), ...a44(p), ...a44(VOLUME ^ track ^ p), 0xde, 0xaa, 0xeb])
    t.sync(6)
    t.bytes([0xd5, 0xaa, 0xad, ...encode62(sectorAt(p)), 0xde, 0xaa, 0xeb])
    t.sync(12)
  }
  return { bits: t.buf, count: t.n }
}

// ---- the file -------------------------------------------------------------
let crcTable
function crc32(data) {
  if (!crcTable) {
    crcTable = new Uint32Array(256)
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
      crcTable[n] = c
    }
  }
  let c = 0xffffffff
  for (const b of data) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

const ascii = (out, at, s) => { for (let i = 0; i < s.length; i++) out[at + i] = s.charCodeAt(i) }

/** The quarter-track map of a standard disk: tracks t at 4t-1, 4t and 4t+1. */
export function standardTmap(tracks = TRACKS) {
  return Array.from({ length: 160 }, (_, q) => {
    const t = Math.round(q / 4)
    return q % 4 !== 2 && t < tracks ? t : 0xff
  })
}

/**
 * A WOZ 2 file from its tracks.
 * @param {{ bits: Uint8Array, count: number }[]} tracks  TRKS entries, in order
 * @param {number[]} tmap  160 quarter-track entries
 * @param {{ writeProtected?: boolean, bootFormat?: number, creator?: string, synchronized?: boolean, cleaned?: boolean }} [info]
 */
export function buildWoz(tracks, tmap, info = {}) {
  const blocks = tracks.map((t) => Math.max(TRACK_BLOCKS, Math.ceil(t.bits.length / 512)))
  const total = 3 + blocks.reduce((a, b) => a + b, 0)
  const out = new Uint8Array(total * 512)
  const v = new DataView(out.buffer)
  ascii(out, 0, 'WOZ2'); out.set([0xff, 0x0a, 0x0d, 0x0a], 4)
  ascii(out, 12, 'INFO'); v.setUint32(16, 60, true)
  out[20] = 2 // INFO version
  out[21] = 1 // 5.25"
  out[22] = info.writeProtected ? 1 : 0
  out[23] = info.synchronized ? 1 : 0
  out[24] = info.cleaned ?? 1 ? 1 : 0
  out.fill(0x20, 25, 57); ascii(out, 25, (info.creator ?? 'apple2e_TP20K').slice(0, 32))
  out[57] = 1 // sides
  out[58] = info.bootFormat ?? 0
  out[59] = 32 // 4 us bits
  v.setUint16(64, Math.max(...blocks), true) // largest track
  ascii(out, 80, 'TMAP'); v.setUint32(84, 160, true)
  out.set(tmap, 88)
  ascii(out, 248, 'TRKS'); v.setUint32(252, 1280 + (total - 3) * 512, true)
  let blk = 3
  tracks.forEach((t, i) => {
    v.setUint16(256 + 8 * i, blk, true)
    v.setUint16(258 + 8 * i, blocks[i], true)
    v.setUint32(260 + 8 * i, t.count, true)
    out.set(t.bits.subarray(0, Math.ceil(t.count / 8)), blk * 512)
    blk += blocks[i]
  })
  v.setUint32(8, crc32(out.subarray(12)), true)
  return out
}

/** A .dsk/.do (DOS order) or 140K .po (ProDOS order) as WOZ. */
export function dskToWoz(dsk, order = 'dos') {
  if (dsk.length !== DSK_BYTES) throw new Error(`a floppy image is ${DSK_BYTES.toLocaleString()} bytes, this is ${dsk.length.toLocaleString()}`)
  const map = order === 'po' ? PO2PHYS : DOS2PHYS
  const phys2file = new Array(16)
  map.forEach((p, s) => { phys2file[p] = s })
  const tracks = Array.from({ length: TRACKS }, (_, t) =>
    sectorTrack(t, (p) => dsk.subarray((t * 16 + phys2file[p]) * SECTOR, (t * 16 + phys2file[p] + 1) * SECTOR)))
  return buildWoz(tracks, standardTmap(), { bootFormat: 1 })
}

/** A .nib: 35 tracks of 6,656 nibbles, eight bits each (it keeps no sync timing). */
export function nibToWoz(nib) {
  if (nib.length !== TRACKS * NIB_TRACK) throw new Error(`a .nib is ${(TRACKS * NIB_TRACK).toLocaleString()} bytes, this is ${nib.length.toLocaleString()}`)
  const tracks = Array.from({ length: TRACKS }, (_, t) => {
    const bits = new Uint8Array(TRACK_BLOCKS * 512)
    bits.set(nib.subarray(t * NIB_TRACK, (t + 1) * NIB_TRACK))
    return { bits, count: NIB_TRACK * 8 }
  })
  return buildWoz(tracks, standardTmap())
}

/** A new disk: 35 tracks of 50,000 zero bits, for DOS INIT or a ProDOS format. */
export function blankWoz() {
  const tracks = Array.from({ length: TRACKS }, () => ({ bits: new Uint8Array(TRACK_BLOCKS * 512), count: 50000 }))
  return buildWoz(tracks, standardTmap(), { cleaned: false })
}

/** A WOZ 1 file re-laid as WOZ 2 (same tracks, same map). */
export function woz1ToWoz2(w) {
  const v = new DataView(w.buffer, w.byteOffset, w.byteLength)
  const n = v.getUint32(252, true) / 6656
  const tracks = Array.from({ length: n }, (_, i) => {
    const at = 256 + i * 6656
    const bits = new Uint8Array(TRACK_BLOCKS * 512)
    bits.set(w.subarray(at, at + 6646))
    return { bits, count: v.getUint16(at + 6648, true) }
  })
  return buildWoz(tracks, Array.from(w.subarray(88, 248)), {
    writeProtected: w[22] === 1, synchronized: w[23] === 1, cleaned: w[24] === 1,
    creator: String.fromCharCode(...w.subarray(25, 57)).trimEnd(),
  })
}

/**
 * What the board needs of a WOZ file, or why it cannot use it.
 * @returns {{ version: number, writeProtected: boolean, tracks: number }}
 */
export function wozInfo(w) {
  const magic = String.fromCharCode(...w.subarray(0, 4))
  if (magic !== 'WOZ1' && magic !== 'WOZ2') throw new Error('not a WOZ file')
  if (w[21] !== 1) throw new Error('not a 5.25" disk')
  if (w.length > WOZ_MAX) throw new Error(`larger than ${WOZ_MAX / 1024} KB`)
  const tracks = new Set(Array.from(w.subarray(88, 248)).filter((t) => t !== 0xff)).size
  return { version: magic === 'WOZ1' ? 1 : 2, writeProtected: w[22] === 1, tracks }
}

/** The file's own CRC checks out, or it is 0 (not computed, which the board writes). */
export function wozCrcOk(w) {
  const crc = new DataView(w.buffer, w.byteOffset, w.byteLength).getUint32(8, true)
  return crc === 0 || crc === crc32(w.subarray(12))
}

/**
 * Anything slot 6 can take, as the WOZ 2 bytes and its name on the card.
 * @param {string} name
 * @param {Uint8Array} data
 */
export function toWoz(name, data) {
  const e = (/\.([^.]*)$/.exec(name)?.[1] ?? '').toLowerCase()
  const base = name.replace(/\.[^.]*$/, '')
  let woz
  if (e === 'woz') {
    woz = wozInfo(data).version === 1 ? woz1ToWoz2(data) : data
  } else if (e === 'dsk' || e === 'do') woz = dskToWoz(data, 'dos')
  else if (e === 'po') woz = dskToWoz(data, 'po')
  else if (e === 'nib') woz = nibToWoz(data)
  else throw new Error(`${name}: not a floppy image (.dsk .do .po .nib .woz)`)
  return { name: `${base}.woz`, data: woz }
}

// ---- reading it back -----------------------------------------------------
/** The bits of TRKS entry `i`. */
function trackBits(w, i) {
  const v = new DataView(w.buffer, w.byteOffset, w.byteLength)
  const start = v.getUint16(256 + 8 * i, true)
  return { bits: w.subarray(start * 512), count: v.getUint32(260 + 8 * i, true) }
}

/** The disk bytes a Disk II reads from a track, two turns' worth. */
export function trackNibbles(w, track) {
  const i = w[88 + 4 * track]
  if (i === 0xff) return []
  const { bits, count } = trackBits(w, i)
  const out = []
  let sr = 0
  for (let n = 0; n < 2 * count; n++) {
    const p = n % count
    sr = ((sr << 1) | ((bits[p >> 3] >> (7 - (p & 7))) & 1)) & 0xff
    if (sr & 0x80) { out.push(sr); sr = 0 }
  }
  return out
}

/** The 16 sectors of a standard track by physical number, or the missing ones. */
export function readTrack(w, track) {
  const nib = trackNibbles(w, track)
  const sec = new Array(16).fill(null)
  for (let i = 0; i + 14 < nib.length; i++) {
    if (nib[i] !== 0xd5 || nib[i + 1] !== 0xaa || nib[i + 2] !== 0x96) continue
    const f = (k) => ((nib[i + 3 + 2 * k] << 1) | 1) & nib[i + 4 + 2 * k]
    const [vol, trk, s, ck] = [f(0), f(1), f(2), f(3)]
    if ((vol ^ trk ^ s) !== ck || trk !== track || s > 15 || sec[s]) continue
    for (let j = i + 11; j < i + 60 && j + 346 < nib.length; j++) {
      if (nib[j] === 0xd5 && nib[j + 1] === 0xaa && nib[j + 2] === 0xad) {
        sec[s] = decode62(nib.slice(j + 3, j + 346))
        break
      }
    }
  }
  return sec
}

/** A standard disk's sectors as a .dsk (DOS order) or .po. */
export function wozToDsk(w, order = 'dos') {
  if (String.fromCharCode(...w.subarray(0, 4)) !== 'WOZ2') w = woz1ToWoz2(w)
  const map = order === 'po' ? PO2PHYS : DOS2PHYS
  const out = new Uint8Array(DSK_BYTES)
  for (let t = 0; t < TRACKS; t++) {
    const sec = readTrack(w, t)
    map.forEach((p, s) => {
      if (!sec[p]) throw new Error(`track ${t} sector ${p} does not decode: not a standard 16-sector disk`)
      out.set(sec[p], (t * 16 + s) * SECTOR)
    })
  }
  return out
}
