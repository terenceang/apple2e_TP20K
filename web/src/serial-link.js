// ============================================================================
//  serial-link.js -- straight from the browser to the board, no bridge
//
//  When the board is plugged into the machine running the browser, Web Serial
//  can open the port itself. That removes the Node daemon entirely: the app
//  becomes a static bundle that can be hosted anywhere, and there is no local
//  service on the user's machine for anything to attack.
//
//  Two things make this more than a three-line change:
//
//  * The baud rate has to be set explicitly. The FT2232C comes up at 9600 and
//    the FPGA's UART is 115200 8N1, and nothing else will tell you so.
//
//  * The FT2232C has two channels and only one of them is the FPGA's UART. The
//    other is the BL616's own console. They are indistinguishable in the
//    device picker, so the choice is confirmed the only way that works: by
//    asking the debugger who is on the other end. That is the same handshake
//    the bridge uses.
//
//  Plain JS, and the Web Serial object is injected rather than reached for
//  through `navigator`, so `node --test` can drive all of this with a fake.
// ============================================================================

import { CTRL_B, CMD, HANDSHAKE } from './protocol.js'

export const BAUD = 115200
const PROBE_TIMEOUT_MS = 2500
/** Ctrl+B then '?', which makes the debugger print its help line. */
const PROBE_BYTE = CMD.help.charCodeAt(0)
const PROBE_BYTES = Uint8Array.from([CTRL_B, PROBE_BYTE])

/** Is Web Serial usable here at all? */
export function serialSupported(serial) {
  const s = serial ?? (typeof navigator !== 'undefined' ? navigator.serial : undefined)
  return Boolean(s && typeof s.requestPort === 'function')
}

/** A short description of a port, for the UI. */
export function describePort(port) {
  if (!port) return 'no port'
  const info = typeof port.getInfo === 'function' ? port.getInfo() : {}
  const v = info.vendorId
  const p = info.productId
  const ids = v != null && p != null ? `${hex4(v)}:${hex4(p)}` : null
  // The two FT2232C channels report the same ids, so this cannot tell them
  // apart. Only the handshake can.
  return ids ? `USB serial ${ids}` : 'USB serial'
}

const hex4 = (n) => n.toString(16).toUpperCase().padStart(4, '0')

/**
 * Watch bytes for the debugger's help line.
 *
 * Returns a function that reports true once it has seen it, plus a way to
 * reset. Used both to verify a picked port and, in the bridge, to choose
 * between channels.
 */
export function makeHandshake() {
  let seen = ''
  return {
    /** Feed bytes in; true if the //e has identified itself. */
    feed(chunk) {
      seen += typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk)
      if (seen.length > 4096) seen = seen.slice(-2048) // a long line cannot match
      return seen.includes(HANDSHAKE)
    },
    get text() {
      return seen
    },
    reset() {
      seen = ''
    },
  }
}

/**
 * A Web Serial connection to the //e.
 *
 * open() must be called from a user gesture: requestPort() shows a picker, and
 * browsers refuse to call it from anything else. That is why the UI has a
 * Connect button rather than connecting on load.
 */
export class SerialLink {
  /** @param {object} [opts] */
  constructor(opts = {}) {
    this.serial = opts.serial ?? (typeof navigator !== 'undefined' ? navigator.serial : null)
    this.onBytes = () => {}
    this.onState = () => {}
    this.port = null
    this.writer = null
    this.reader = null
    this.closing = false
    this.queue = []
    this.draining = false
    this.state = 'idle'
    this.detail = null
  }

  /** @returns {'serial'} */
  get kind() {
    return 'serial'
  }

  /** What to show in the status bar. */
  describe() {
    return describePort(this.port)
  }

  emit(state, detail = null) {
    this.state = state
    this.detail = detail
    this.onState({ kind: 'serial', state, detail })
  }

  /**
   * Ask for a port and confirm it is the FPGA's UART.
   *
   * @param {{verify?: boolean, port?: object}} [opts] port: an already-granted port (skips the picker)
   * @returns {Promise<'ok'|'wrong-port'|'cancelled'>}
   */
  async open(opts = {}) {
    if (!serialSupported(this.serial)) {
      this.emit('error', 'this browser has no Web Serial')
      return 'cancelled'
    }
    await this.close()
    this.closing = false
    this.emit('opening')
    try {
      this.port = opts.port ?? (await this.serial.requestPort())
    } catch (e) {
      // A dismissed picker throws; that is not an error worth shouting about.
      this.port = null
      this.emit(e?.name === 'NotFoundError' ? 'idle' : 'error', null)
      return 'cancelled'
    }

    this.emit('open-unchecked')
    try {
      // open() is on the port, not on navigator.serial. Being explicit about
      // 8N1 matters: the FT2232C comes up at 9600 and the FPGA's UART is 115200
      // 8N1, and if the extra fields are refused the short form still sets the
      // baud rate, which is the part that cannot be wrong.
      await this.port.open({
        baudRate: BAUD,
        dataBits: 8,
        stopBits: 1,
        parity: 'none',
        bufferSize: 4096,
      })
    } catch {
      try {
        await this.port.open({ baudRate: BAUD })
      } catch (e) {
        this.emit('error', `could not open the port: ${e?.message ?? e}`)
        await this.close()
        return 'cancelled'
      }
    }

    this.startReading()

    if (opts.verify === false) {
      this.emit('open')
      return 'ok'
    }
    return this.verify()
  }
  /**
   * Confirm the FPGA is on the other end by making the debugger answer, then
   * put the machine back exactly as it was found.
   *
   * @returns {Promise<'ok'|'wrong-port'>}
   */
  verify() {
    if (this._verify) return this._verify
    this._verify = new Promise((resolve) => {
      const hs = makeHandshake()
      const previous = this.onBytes
      let settled = false
      this.emit('probing')

      let timer = null
      let probe2Timer = null
      let tries = 0
      const cleanup = () => {
        clearTimeout(timer)
        if (probe2Timer) clearTimeout(probe2Timer)
      }
      // Ctrl+B toggles. A machine left in the debugger by an earlier page is
      // resumed by the probe's Ctrl+B, so the '?' goes unanswered; the second try
      // finds it running and enters the debugger.
      const probe = () => {
        tries++
        timer = setTimeout(() => (tries < 2 ? probe() : finish('wrong-port')), PROBE_TIMEOUT_MS)
        // On real hardware the FPGA drops '?' while printing the initial banner,
        // so re-send '?' after 250ms once banner finishes.
        this.write(PROBE_BYTES)
        probe2Timer = setTimeout(() => {
          if (!settled) this.write(Uint8Array.from([PROBE_BYTE]))
        }, 250)
      }

      const finish = (result) => {
        if (settled) return
        settled = true
        cleanup()
        this.onBytes = previous
        this._verify = null
        if (result === 'ok') {
          // Leave the debugger again, so the probe leaves no trace.
          this.write(Uint8Array.from([CTRL_B]))
          this.emit('open')
        } else {
          this.emit(
            'wrong-port',
            'Port did not respond to Apple //e probe. On Tang Nano 20K, Channel A is JTAG (COM38) and Channel B is UART. Enable "Load VCP" for Converter B in Device Manager.',
          )
          void this.close({ preserveState: true })
        }
        resolve(result)
      }

      this.onBytes = (bytes) => {
        previous(bytes)
        if (hs.feed(bytes)) finish('ok')
      }

      probe()
    })
    return this._verify
  }

  startReading() {
    const readable = this.port?.readable
    if (!readable) return
    this.reader = readable.getReader()
    const pump = async () => {
      try {
        while (this.reader && !this.closing) {
          const { value, done } = await this.reader.read()
          if (done) break
          if (value && value.length) this.onBytes(new Uint8Array(value))
        }
      } catch {
        if (!this.closing) this.emit('error', 'the port closed')
      }
    }
    void pump()
  }

  /** Queue bytes; the writer is held open for the life of the connection. */
  write(bytes) {
    if (!this.port?.writable) return
    // Web Serial rejects plain arrays (disk.js sends [0x64]); a copy also keeps queued subarrays stable.
    this.queue.push(Uint8Array.from(bytes))
    void this.drain()
  }

  async drain() {
    if (this.draining) return
    this.draining = true
    try {
      if (!this.writer) this.writer = this.port.writable.getWriter()
      while (this.queue.length) {
        const chunk = this.queue.shift()
        await this.writer.write(chunk)
      }
    } catch (e) {
      if (!this.closing) this.emit('error', `write failed: ${e?.message ?? e}`)
    } finally {
      this.draining = false
    }
  }

  async close(opts = {}) {
    const preserveState = Boolean(opts?.preserveState)
    this.closing = true
    this.queue = []
    if (this.reader) {
      try {
        await this.reader.cancel()
      } catch {
        /* already gone */
      }
      try {
        this.reader.releaseLock()
      } catch {
        /* ignore */
      }
      this.reader = null
    }
    if (this.writer) {
      try {
        await this.writer.close()
      } catch {
        /* ignore */
      }
      this.writer = null
    }
    if (this.port) {
      try {
        await this.port.close()
      } catch {
        /* ignore */
      }
    }
    this.port = null
    this.closing = false
    if (!preserveState && this.state !== 'error' && this.state !== 'wrong-port') {
      this.emit('idle')
    }
  }
}
