/**
 * Disk II nibble track encoder: the byte stream disk2_card plays today, built
 * on the host so the FPGA only has to play bytes back (ESP32 companion plan).
 *
 * Layout per sector (440 bytes, 16 per track = 7040), see src/disk2/disk2_card.v:
 *   48 x FF, D5 AA 96, vol/trk/sec/cksum 4-and-4 (8 bytes), DE AA EB,
 *   6 x FF, D5 AA AD, 343 six-and-two bytes, DE AA EB, 23 x FF.
 * Tables and field order are src/disk2/gcr_defs.vh. The golden file
 * build/golden_track0.hex is the card's own stream (sim/tb_disk2.v).
 */

export const SECT_LEN = 440
export const TRACK_LEN = 16 * SECT_LEN
const VOLUME = 0xfe

const GCR = [
  0x96, 0x97, 0x9a, 0x9b, 0x9d, 0x9e, 0x9f, 0xa6, 0xa7, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb2, 0xb3,
  0xb4, 0xb5, 0xb6, 0xb7, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xcb, 0xcd, 0xce, 0xcf, 0xd3,
  0xd6, 0xd7, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe5, 0xe6, 0xe7, 0xe9, 0xea, 0xeb, 0xec,
  0xed, 0xee, 0xef, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
]

const swap2 = (v) => ((v & 1) << 1) | ((v >> 1) & 1)
const a44hi = (v) => 0xaa | ((v >> 1) & 0x55)
const a44lo = (v) => 0xaa | (v & 0x55)

/** 343 data-field bytes for one 256-byte sector. */
export function encodeField(sec) {
  const grp = new Array(342)
  for (let k = 0; k < 86; k++) {
    const at = (i) => (i < 256 ? swap2(sec[i] & 3) : 0)
    grp[k] = (at(172 + k) << 4) | (at(86 + k) << 2) | at(k)
  }
  for (let k = 0; k < 256; k++) grp[86 + k] = sec[k] >> 2
  const out = new Uint8Array(343)
  for (let i = 0; i < 342; i++) out[i] = GCR[i === 0 ? grp[0] : grp[i] ^ grp[i - 1]]
  out[342] = GCR[grp[341]]
  return out
}

/** One 7040-byte track; sectors[n] is the 256 bytes at physical position n. */
export function encodeTrack(track, sectors) {
  const out = new Uint8Array(TRACK_LEN)
  for (let s = 0; s < 16; s++) {
    const o = s * SECT_LEN
    out.fill(0xff, o, o + SECT_LEN)
    out.set([0xd5, 0xaa, 0x96], o + 48)
    const hdr = [VOLUME, track, s, VOLUME ^ track ^ s]
    hdr.forEach((v, i) => { out[o + 51 + 2 * i] = a44hi(v); out[o + 52 + 2 * i] = a44lo(v) })
    out.set([0xde, 0xaa, 0xeb], o + 59)
    out.set([0xd5, 0xaa, 0xad], o + 68)
    out.set(encodeField(sectors[s]), o + 71)
    out.set([0xde, 0xaa, 0xeb], o + 414)
  }
  return out
}

const DEC = new Int16Array(256).fill(-1)
GCR.forEach((b, v) => { DEC[b] = v })
const a44dec = (hi, lo) => ((hi << 1) | 1) & lo

/** One data field (343 bytes) back to 256 bytes, or null if a byte or the checksum is bad. */
export function decodeField(f) {
  const grp = new Array(342)
  let prev = 0
  for (let i = 0; i < 342; i++) {
    const v = DEC[f[i]]
    if (v < 0) return null
    prev = grp[i] = i === 0 ? v : v ^ prev
  }
  if (DEC[f[342]] !== grp[341]) return null
  const out = new Uint8Array(256)
  for (let k = 0; k < 256; k++) {
    const pair = k < 86 ? grp[k] & 3 : k < 172 ? (grp[k - 86] >> 2) & 3 : (grp[k - 172] >> 4) & 3
    out[k] = (grp[86 + k] << 2) | swap2(pair)
  }
  return out
}

/**
 * Recover the sectors in a 7040-byte track: Map of physical sector -> 256 bytes
 * for every sector whose address field (volume/track/sector/checksum) and data
 * field (343 bytes + checksum) are intact. The stream is circular.
 */
export function decodeTrack(trackBytes) {
  const n = trackBytes.length
  const at = (i) => trackBytes[i % n]
  const found = new Map()
  for (let i = 0; i < n; i++) {
    if (at(i) !== 0xd5 || at(i + 1) !== 0xaa || at(i + 2) !== 0x96) continue
    const h = [0, 1, 2, 3].map((j) => a44dec(at(i + 3 + 2 * j), at(i + 4 + 2 * j)))
    if ((h[0] ^ h[1] ^ h[2]) !== h[3] || h[2] > 15) continue
    for (let j = i + 11; j < i + 11 + 100; j++) {
      if (at(j) === 0xd5 && at(j + 1) === 0xaa && at(j + 2) === 0xad) {
        const f = decodeField(Uint8Array.from({ length: 343 }, (_, k) => at(j + 3 + k)))
        if (f) found.set(h[2], f)
        break
      }
    }
  }
  return found
}
