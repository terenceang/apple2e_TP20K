// ============================================================================
//  disk.js -- Apple //e Disk II image handling & serial transfer protocol
//
//  Handles:
//  - Sector interleaving: DOS 3.3 logical order (.dsk/.do) <-> ProDOS physical order (.po)
//  - Validation of 140K 5.25" floppy images (143,360 bytes: 35 tracks x 16 sectors x 256 bytes)
//  - Serial transfer protocol (upload d1/d2 with 4096-byte track ACKs, download e1/e2)
//
//  Plain JS with JSDoc types so `node --test` can test it directly.
// ============================================================================

export const TRACKS = 35
export const SECTORS_PER_TRACK = 16
export const SECTOR_BYTES = 256
export const TRACK_BYTES = SECTORS_PER_TRACK * SECTOR_BYTES // 4096
export const DISK_BYTES = TRACKS * TRACK_BYTES // 143360

export const ACK_BYTE = 0x06 // ASCII ACK returned by serial_debugger.v after each chunk

/**
 * DOS 3.3 logical-to-physical sector interleave mapping.
 * Logical sector L is stored on physical sector DOS_TO_PHYS[L].
 */
export const DOS_TO_PHYS = [
  0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
  0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf,
]

/**
 * Physical-to-DOS 3.3 logical sector interleave mapping (reverse of DOS_TO_PHYS).
 * Physical sector P maps to logical sector PHYS_TO_DOS[P].
 */
export const PHYS_TO_DOS = DOS_TO_PHYS.map((_, p) => DOS_TO_PHYS.indexOf(p))

/**
 * Detect disk image format ('prodos' or 'dos') from filename.
 * .po = ProDOS physical sector order
 * .dsk / .do = DOS 3.3 logical sector order (default)
 *
 * @param {string} [filename]
 * @returns {'prodos' | 'dos'}
 */
export function detectDiskFormat(filename = '') {
  if (typeof filename === 'string' && filename.toLowerCase().endsWith('.po')) {
    return 'prodos'
  }
  return 'dos'
}

/**
 * Validates that a buffer is an exact 143,360 byte Apple II 5.25" floppy disk image.
 *
 * @param {ArrayBuffer | Uint8Array} buffer
 * @param {string} [filename]
 * @returns {{ data: Uint8Array, order: 'prodos' | 'dos', filename: string }}
 */
export function validateDiskImage(buffer, filename = '') {
  const data = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer)
  if (data.byteLength !== DISK_BYTES) {
    throw new Error(
      `Invalid disk image size: expected ${DISK_BYTES.toLocaleString()} bytes (35 tracks × 16 sectors × 256 bytes), got ${data.byteLength.toLocaleString()} bytes.`,
    )
  }
  return {
    data,
    order: detectDiskFormat(filename),
    filename,
  }
}

/** Move every sector of every track of a 143,360-byte image to the slot `map` gives it. */
function permuteSectors(src, map) {
  if (src.length !== DISK_BYTES) {
    throw new Error(`Expected ${DISK_BYTES} bytes, got ${src.length}`)
  }
  const dst = new Uint8Array(DISK_BYTES)
  for (let t = 0; t < TRACKS; t++) {
    for (let sec = 0; sec < SECTORS_PER_TRACK; sec++) {
      const from = t * TRACK_BYTES + sec * SECTOR_BYTES
      dst.set(src.subarray(from, from + SECTOR_BYTES), t * TRACK_BYTES + map[sec] * SECTOR_BYTES)
    }
  }
  return dst
}

/** Convert a disk image from DOS 3.3 logical order to ProDOS physical order. */
export const dosToPhysical = (src) => permuteSectors(src, DOS_TO_PHYS)

/** Convert a disk image from ProDOS physical order to DOS 3.3 logical order. */
export const physicalToDos = (src) => permuteSectors(src, PHYS_TO_DOS)

/**
 * Prepare raw disk file bytes for upload to the FPGA (translates to physical sector order).
 *
 * @param {Uint8Array} data
 * @param {'dos' | 'prodos' | 'dsk' | 'do' | 'po'} [format]
 * @returns {Uint8Array}
 */
export function prepareUploadImage(data, format = 'dos') {
  if (format === 'prodos' || format === 'po') {
    return new Uint8Array(data)
  }
  return dosToPhysical(data)
}

/**
 * Prepare physical disk image bytes downloaded from FPGA into the target format.
 *
 * @param {Uint8Array} physicalData
 * @param {'dos' | 'prodos' | 'dsk' | 'do' | 'po'} [format]
 * @returns {Uint8Array}
 */
export function prepareDownloadImage(physicalData, format = 'dsk') {
  if (format === 'prodos' || format === 'po') {
    return new Uint8Array(physicalData)
  }
  return physicalToDos(physicalData)
}

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

/**
 * The debugger's image protocol, uploading: `cmd` and the drive digit, wait for the
 * UPLOAD banner, send `bytes` in `unit`-sized chunks (the board ACKs each), then
 * wait for "done" or "lost".  `onChunk(n)` is called after chunk n (1-based).
 */
async function sendImage(link, cmd, drive, bytes, unit, timeoutMs, onChunk) {
  const reader = new LinkStreamReader(link)
  try {
    link.write([cmd.charCodeAt(0)])
    await sleep(40)
    link.write([Number(drive) === 2 ? 0x32 : 0x31]) // '2' or '1'
    await reader.readUntil('UPLOAD', timeoutMs)

    for (let c = 0; c * unit < bytes.length; c++) {
      link.write(bytes.subarray(c * unit, (c + 1) * unit))
      await reader.readAck(timeoutMs)
      onChunk(c + 1)
    }

    const decoder = new TextDecoder()
    await reader.waitFor(() => /done|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (decoder.decode(reader.buffer).includes('lost')) {
      throw new Error('Upload failed: FPGA reported bytes lost / dropped in transit.')
    }
  } finally {
    reader.restore()
  }
}

/** The matching download: `cmd`, drive digit, DOWNLOAD banner, `size` raw bytes, "done". */
async function receiveImage(link, cmd, drive, size, timeoutMs, onBytes) {
  const reader = new LinkStreamReader(link)
  try {
    link.write([cmd.charCodeAt(0)])
    await sleep(40)
    link.write([Number(drive) === 2 ? 0x32 : 0x31])
    await reader.readUntil('DOWNLOAD', timeoutMs)

    const bytes = await reader.readBytes(size, onBytes, timeoutMs)

    const decoder = new TextDecoder()
    await reader.waitFor(() => decoder.decode(reader.buffer).includes('done'), timeoutMs)
    return bytes
  } finally {
    reader.restore()
  }
}

/**
 * Upload a 143,360-byte physical disk image to Drive 1 or Drive 2 over Web Serial
 * (`d`, then 35 tracks of 4096 bytes, each ACKed).
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {1 | 2} drive
 * @param {Uint8Array} physicalBytes
 * @param {{
 *   onProgress?: (p: { phase: 'uploading', track: number, totalTracks: number, bytesSent: number, totalBytes: number }) => void,
 *   timeoutMs?: number
 * }} [opts]
 * @returns {Promise<void>}
 */
export async function uploadDisk(link, drive, physicalBytes, opts = {}) {
  if (!physicalBytes || physicalBytes.length !== DISK_BYTES) {
    throw new Error(`Upload payload must be exactly ${DISK_BYTES} bytes, got ${physicalBytes?.length}`)
  }
  await sendImage(link, 'd', drive, physicalBytes, TRACK_BYTES, opts.timeoutMs ?? 6000, (t) =>
    opts.onProgress?.({
      phase: 'uploading',
      track: t,
      totalTracks: TRACKS,
      bytesSent: t * TRACK_BYTES,
      totalBytes: DISK_BYTES,
    }),
  )
}

/**
 * Download a 143,360-byte physical disk image from Drive 1 or Drive 2 over Web Serial (`e`).
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {1 | 2} drive
 * @param {{
 *   onProgress?: (p: { phase: 'downloading', bytesReceived: number, totalBytes: number }) => void,
 *   timeoutMs?: number
 * }} [opts]
 * @returns {Promise<Uint8Array>} Raw 143,360 physical disk image bytes
 */
export function downloadDisk(link, drive, opts = {}) {
  return receiveImage(link, 'e', drive, DISK_BYTES, opts.timeoutMs ?? 6000, (bytesReceived) =>
    opts.onProgress?.({ phase: 'downloading', bytesReceived, totalBytes: DISK_BYTES }),
  )
}

/**
 * The fingerprint the FPGA keeps for a Disk II image: rotate left one and add each
 * byte, modulo 2^32 (serial_debugger.v dsk_sum0/1).  Hash the bytes that go over
 * the wire, i.e. after prepareUploadImage.  The board reports 0 for an empty drive.
 *
 * @param {Uint8Array} bytes
 * @returns {number}
 */
export function diskChecksum(bytes) {
  let s = 0
  for (let i = 0; i < bytes.length; i++) s = (((s << 1) | (s >>> 31)) + bytes[i]) >>> 0
  return s
}

/**
 * Ask the debugger (which must already be paused) what each Disk II holds.
 * `i` answers "I1:xxxxxxxx I2:xxxxxxxx".
 *
 * @param {{ write: (b: Uint8Array | number[]) => void, onBytes: (b: Uint8Array) => void }} link
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<[number, number]>} checksums of drive 1 and 2; 0 = empty
 */
export async function queryDiskSums(link, opts = {}) {
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  const re = /I1:([0-9A-F]{8}) I2:([0-9A-F]{8})/
  try {
    link.write([0x69]) // 'i'
    await reader.waitFor(() => re.test(decoder.decode(reader.buffer)), opts.timeoutMs ?? 3000)
    const m = re.exec(decoder.decode(reader.buffer))
    return [parseInt(m[1], 16), parseInt(m[2], 16)]
  } finally {
    reader.restore()
  }
}
