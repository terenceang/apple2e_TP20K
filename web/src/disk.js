// ============================================================================
//  disk.js -- disk sizes and the debugger's TF card commands (b, u, y, i)
//
//  Every drive's disk is a file on the TF card; the board loads it (and puts
//  a DOS-order .dsk in physical order itself, src/sd_vol.v dos2phys), so the
//  page only ever moves card sectors.
//  Plain JS with JSDoc types so `node --test` can test it directly.
// ============================================================================

export const TRACKS = 35
export const SECTORS_PER_TRACK = 16
export const SECTOR_BYTES = 256
export const TRACK_BYTES = SECTORS_PER_TRACK * SECTOR_BYTES // 4096
export const DISK_BYTES = TRACKS * TRACK_BYTES // 143360

export const ACK_BYTE = 0x06 // ASCII ACK returned by serial_debugger.v after each chunk

/**
 * Helper to manage raw serial bytes during disk image transfers without
 * leaking binary bytes into the UI debugger stream.
 */
class LinkStreamReader {
  /**
   * @param {{ onBytes: (b: Uint8Array) => void, write: (b: Uint8Array | number[]) => void }} link
   */
  constructor(link) {
    this.link = link
    this.prevOnBytes = link.onBytes
    this.buffer = new Uint8Array(0)
    /** @type {{ check: () => boolean, resolve: () => void, reject: (e: Error) => void } | null} */
    this.waiter = null

    this.link.onBytes = (chunk) => {
      if (!chunk || !chunk.length) return
      const next = new Uint8Array(this.buffer.length + chunk.length)
      next.set(this.buffer, 0)
      next.set(chunk, this.buffer.length)
      this.buffer = next

      if (this.waiter && this.waiter.check()) {
        const w = this.waiter
        this.waiter = null
        w.resolve()
      }
    }
  }

  /**
   * Wait until checkFn() returns true, or fail if no activity arrives within inactivityTimeoutMs.
   *
   * @param {() => boolean} checkFn
   * @param {number} [inactivityTimeoutMs]
   */
  async waitFor(checkFn, inactivityTimeoutMs = 6000) {
    if (checkFn()) return

    return new Promise((resolve, reject) => {
      let timer = null
      const armTimer = () => {
        if (timer) clearTimeout(timer)
        timer = setTimeout(() => {
          this.waiter = null
          reject(new Error(`Serial link quiet timeout (${inactivityTimeoutMs}ms with no response)`))
        }, inactivityTimeoutMs)
      }

      armTimer()

      this.waiter = {
        check: () => {
          armTimer()
          return checkFn()
        },
        resolve: () => {
          if (timer) clearTimeout(timer)
          resolve()
        },
        reject: (err) => {
          if (timer) clearTimeout(timer)
          reject(err)
        },
      }
    })
  }

  /**
   * Read text until target substring is found. Consumes buffer up to the substring and newline.
   *
   * @param {string} target
   * @param {number} [timeoutMs]
   * @returns {Promise<string>}
   */
  async readUntil(target, timeoutMs = 6000) {
    const decoder = new TextDecoder()
    await this.waitFor(() => {
      const text = decoder.decode(this.buffer)
      return text.includes(target)
    }, timeoutMs)

    const text = decoder.decode(this.buffer)
    const idx = text.indexOf(target)
    const nlIdx = text.indexOf('\n', idx)
    const cutPos = nlIdx !== -1 ? nlIdx + 1 : idx + target.length
    this.buffer = this.buffer.subarray(cutPos)
    return text.slice(0, cutPos)
  }

  /**
   * Wait for ACK (0x06), discarding bytes prior to ACK.
   *
   * @param {number} [timeoutMs]
   */
  async readAck(timeoutMs = 6000) {
    await this.waitFor(() => this.buffer.includes(ACK_BYTE), timeoutMs)
    const idx = this.buffer.indexOf(ACK_BYTE)
    this.buffer = this.buffer.subarray(idx + 1)
  }

  /**
   * Read exactly `count` bytes from the stream.
   *
   * @param {number} count
   * @param {(received: number) => void} [onProgress]
   * @param {number} [timeoutMs]
   * @returns {Promise<Uint8Array>}
   */
  async readBytes(count, onProgress, timeoutMs = 6000) {
    let lastReported = 0
    await this.waitFor(() => {
      if (this.buffer.length !== lastReported) {
        lastReported = this.buffer.length
        onProgress?.(Math.min(lastReported, count))
      }
      return this.buffer.length >= count
    }, timeoutMs)

    const out = this.buffer.slice(0, count)
    this.buffer = this.buffer.subarray(count)
    return out
  }

  restore() {
    this.link.onBytes = this.prevOnBytes
    if (this.waiter) {
      this.waiter.reject(new Error('Operation cancelled'))
      this.waiter = null
    }
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

export const HD_BLOCK_BYTES = 512
export const HD_MAX_BLOCKS = 65536

// ============================================================================
//  The TF card: drive images as files on FAT32 (src/sd_vol.v, src/fat32.js)
// ============================================================================

/**
 * @typedef {{
 *   present: boolean[],
 *   fail: boolean[],
 *   fsOk: boolean,
 *   busy: boolean,
 *   loading: boolean,
 *   error: number | null,
 * }} CardStatus
 * Per drive (config.js DRIVES order: S6D1 S6D2 S7D1 S7D2): `present` it holds its file, `fail` the config
 * names a file that cannot be used (missing, fragmented, wrong size).  `error`
 * is the card command that failed (sd_vol.v estage) or null.
 */

/**
 * The TF card part of the debugger's `i` line, "S:ssss":
 * {loading, busy, err, estage[2:0], fs_ok, 0, fail[3:0], present[3:0]}.
 *
 * @param {string} text
 * @returns {CardStatus | null} null for firmware without it
 */
export function parseCardStatus(text) {
  const m = /S:([0-9A-F]{4})/.exec(text)
  if (!m) return null
  const s = parseInt(m[1], 16)
  const bits = (n) => [0, 1, 2, 3].map((i) => Boolean((n >> i) & 1))
  return {
    present: bits(s),
    fail: bits(s >> 4),
    fsOk: Boolean(s & 0x200),
    busy: Boolean(s & 0x4000),
    loading: Boolean(s & 0x8000),
    error: s & 0x2000 ? (s >> 10) & 7 : null,
  }
}

/**
 * Ask the (paused) debugger what the card's drives hold.
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<CardStatus>}
 */
export async function queryCardStatus(link, opts = {}) {
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  try {
    link.write([0x69]) // 'i'
    await reader.waitFor(() => parseCardStatus(decoder.decode(reader.buffer)) !== null, opts.timeoutMs ?? 3000)
    return /** @type {CardStatus} */ (parseCardStatus(decoder.decode(reader.buffer)))
  } finally {
    reader.restore()
  }
}

/**
 * Reload drive `drive` (1-4: S6D1 S6D2 S7D1 S7D2) from A2CONFIG.TXT with the
 * debugger's `y`, then wait for the load: about a second for a floppy; a
 * volume is only looked up (its blocks are read from the card on demand).
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {1 | 2 | 3 | 4} drive
 * @param {{ timeoutMs?: number, pollMs?: number, onPoll?: (s: CardStatus) => void }} [opts]
 * @returns {Promise<CardStatus>}
 */
export async function reloadDrive(link, drive, opts = {}) {
  if (![1, 2, 3, 4].includes(drive)) throw new Error(`Drive must be 1-4, got ${drive}`)
  link.write([0x79, 0x30 + drive]) // 'y', digit
  const deadline = Date.now() + (opts.timeoutMs ?? 120000)
  for (;;) {
    await sleep(opts.pollMs ?? 1000)
    const st = await queryCardStatus(link)
    opts.onPoll?.(st)
    if (!st.busy) {
      if (st.error !== null) throw new Error(`TF card error (stage ${st.error}).`)
      return st
    }
    if (Date.now() > deadline) throw new Error('TF card load did not finish.')
  }
}

const hex = (v, digits) => v.toString(16).toUpperCase().padStart(digits, '0')

/**
 * Read `count` sectors from `lba` (the debugger's `b`): "SECTORS", the raw
 * bytes, then "done" ("lost" past the card's end).
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {number} lba
 * @param {number} count 1-65535
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<Uint8Array>}
 */
export async function readSectors(link, lba, count, opts = {}) {
  if (!(count >= 1 && count <= 0xffff)) throw new Error(`Sector count must be 1-65535, got ${count}`)
  const timeoutMs = opts.timeoutMs ?? 6000
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  try {
    link.write([...new TextEncoder().encode(`b${hex(lba >>> 0, 8)}${hex(count, 4)}`)])
    await reader.waitFor(() => /SECTORS\r\n|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    const text = decoder.decode(reader.buffer)
    if (!text.includes('SECTORS')) throw new Error('The board refused the read: no TF card, or it is busy.')
    await reader.readUntil('SECTORS', timeoutMs)
    // a failed read sends "lost" where the rest of the data would be
    const want = count * HD_BLOCK_BYTES
    const lost = new TextEncoder().encode('\r\nlost\r\n')
    const endsLost = () =>
      reader.buffer.length < want + lost.length &&
      lost.every((b, i) => reader.buffer[reader.buffer.length - lost.length + i] === b)
    await reader.waitFor(() => reader.buffer.length >= want || endsLost(), timeoutMs)
    if (reader.buffer.length < want) throw new Error(`TF card read failed at sector ${lba}.`)
    const bytes = await reader.readBytes(want, undefined, timeoutMs)
    await reader.waitFor(() => /done|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (decoder.decode(reader.buffer).includes('lost')) throw new Error(`TF card read failed at sector ${lba}.`)
    return bytes
  } finally {
    reader.restore()
  }
}

/**
 * The records the debugger's u takes (serial_debugger.v): 01 + 512 bytes for a
 * sector, 00 (n-1 hi) (n-1 lo) for n zero sectors, then 02 at the end.  The
 * last sector is padded with zeros.
 *
 * @param {Uint8Array} data
 * @returns {Generator<{ bytes: Uint8Array, blocks: number }>}
 */
export function* hdRecords(data) {
  const blocks = Math.ceil(data.length / HD_BLOCK_BYTES)
  const isZero = (b) => {
    for (let i = b * HD_BLOCK_BYTES; i < Math.min(data.length, (b + 1) * HD_BLOCK_BYTES); i++) if (data[i]) return false
    return true
  }
  for (let b = 0; b < blocks; ) {
    if (!isZero(b)) {
      const bytes = new Uint8Array(1 + HD_BLOCK_BYTES)
      bytes[0] = 0x01
      bytes.set(data.subarray(b * HD_BLOCK_BYTES, (b + 1) * HD_BLOCK_BYTES), 1)
      yield { bytes, blocks: 1 }
      b++
    } else {
      let n = 1
      while (b + n < blocks && n < 65536 && isZero(b + n)) n++
      yield { bytes: Uint8Array.of(0x00, (n - 1) >> 8, (n - 1) & 0xff), blocks: n }
      b += n
    }
  }
}

/**
 * A ProDOS-order hard-disk image: raw (.hdv, .po) or 2IMG (.2mg, ProDOS order
 * only), a whole number of blocks up to 32 MB.
 *
 * @param {ArrayBuffer | Uint8Array} buffer
 * @returns {Uint8Array} the blocks
 */
export function validateHardDiskImage(buffer) {
  let data = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)
  if (data.length >= 64 && String.fromCharCode(...data.subarray(0, 4)) === '2IMG') {
    const v = new DataView(data.buffer, data.byteOffset, data.byteLength)
    if (v.getUint32(0x0c, true) !== 1) throw new Error('2IMG image is not in ProDOS order.')
    const off = v.getUint32(0x18, true)
    data = data.subarray(off, off + v.getUint32(0x1c, true))
  }
  if (data.length === 0 || data.length % HD_BLOCK_BYTES || data.length > HD_MAX_BLOCKS * HD_BLOCK_BYTES) {
    throw new Error(
      `Invalid hard-disk image: expected a whole number of 512-byte blocks up to 32 MB, got ${data.length.toLocaleString()} bytes.`,
    )
  }
  return data
}

/**
 * Write `data` to the card from sector `lba` on (the debugger's `u`): one ACK
 * per record, once it is on the card.  The serial link is the limit: about
 * 45 s per MB of non-zero sectors, so a full 32 MB volume is ~48 min.
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {number} lba
 * @param {Uint8Array} data
 * @param {{ onProgress?: (p: { blocks: number, totalBlocks: number }) => void, timeoutMs?: number }} [opts]
 */
export async function writeSectors(link, lba, data, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 6000
  const total = Math.ceil(data.length / HD_BLOCK_BYTES)
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  try {
    link.write([...new TextEncoder().encode(`u${hex(lba >>> 0, 8)}`)])
    await reader.waitFor(() => /UPLOAD HD|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (!decoder.decode(reader.buffer).includes('UPLOAD HD')) {
      throw new Error('The board refused the write: no TF card, or it is busy.')
    }
    reader.buffer = new Uint8Array(0)
    let done = 0
    for (const r of hdRecords(data)) {
      link.write(r.bytes)
      // a zero sector takes the card a few ms to write
      await reader.readAck(timeoutMs + r.blocks * 10)
      done += r.blocks
      opts.onProgress?.({ blocks: done, totalBlocks: total })
    }
    link.write([0x02])
    await reader.waitFor(() => /done|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (decoder.decode(reader.buffer).includes('lost')) throw new Error('Write failed: the board reported lost bytes.')
  } finally {
    reader.restore()
  }
}

/**
 * The card as a block device for src/fat32.js.  Reads go in runs of up to
 * 128 sectors, so a progress callback can follow a big download.
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 */
export function cardDevice(link) {
  return {
    async read(lba, n) {
      const out = new Uint8Array(n * HD_BLOCK_BYTES)
      for (let i = 0; i < n; i += 128) out.set(await readSectors(link, lba + i, Math.min(128, n - i)), i * HD_BLOCK_BYTES)
      return out
    },
    /** @param {(done: number, total: number) => void} [onProgress] in bytes */
    async write(lba, bytes, onProgress) {
      await writeSectors(link, lba, bytes, {
        onProgress: onProgress && ((p) => onProgress(Math.min(p.blocks * HD_BLOCK_BYTES, bytes.length), bytes.length)),
      })
    },
  }
}
