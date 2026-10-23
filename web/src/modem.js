// ============================================================================
//  modem.js -- a Hayes modem on the far side of the Super Serial Card
//
//  The board's slot 1 is a Super Serial Card (src/ssc.v) whose line runs over
//  the USB link: what the Apple sends arrives here a byte at a time (the
//  stream's `ssc` events), with its DTR and baud (`sscst`), and what this
//  sends goes back as FF 06 packets (protocol.js encodeSscBytes).  So a comm
//  program on the Apple (ProTERM, Modem MGR, a BASIC terminal) talks to this
//  as it would to a Hayes modem on the card:
//
//    AT commands     E V Q H Z &F I O A D S &C &D X M L &K (case-insensitive,
//                    several to a line, A/ repeats the last line)
//    ATDT host:port  a telnet BBS, through a WebSocket gateway (a browser
//                    cannot open TCP); the gateway URL has {host} and {port}
//    ATDT ws://...   a WebSocket straight, raw bytes (wss:// too)
//    ATDT LOOP       a loopback, for testing: what is sent comes back
//    +++             a second of quiet, +++, a second of quiet: command mode
//    DTR off         hangs up (as &D2)
//
//  Results are words (V1, "CONNECT 9600" with the Apple's baud) or digits
//  (V0).  The telnet layer answers option negotiation (DO/WILL ECHO and SGA,
//  refuses the rest), drops subnegotiation, and doubles an outgoing 0xFF.
//  Bytes to the Apple are paced at its baud (bytes/s = baud / 10) so the
//  card's 64-byte FIFO never overflows.  Clock and connection are injected,
//  so node --test runs it with no browser.
// ============================================================================

export const BAUDS = [115200, 110, 110, 110, 110, 110, 300, 600, 1200, 1800, 2400, 3600, 4800, 7200, 9600, 19200]
const WORDS = { 0: 'OK', 1: 'CONNECT', 2: 'RING', 3: 'NO CARRIER', 4: 'ERROR', 6: 'NO DIALTONE', 7: 'BUSY', 8: 'NO ANSWER' }
const IAC = 255, DONT = 254, DO = 253, WONT = 252, WILL = 251, SB = 250, SE = 240
const OPT_ECHO = 1, OPT_SGA = 3

/**
 * @typedef {{ send: (bytes: Uint8Array) => void, close: () => void }} Conn
 * @typedef {{
 *   toApple: (bytes: number[]) => void,             // bytes for the card (paced here)
 *   setLines: (dcd: boolean, dsr: boolean) => void, // the card's status inputs
 *   connect: (url: string, h: { onOpen: () => void, onData: (b: Uint8Array) => void, onClose: () => void }) => Conn,
 *   now?: () => number,
 *   setTimer?: (fn: () => void, ms: number) => any,
 *   clearTimer?: (t: any) => void,
 *   log?: (s: string) => void,
 * }} ModemIO
 */
export class Modem {
  /** @param {ModemIO} io  @param {{ gateway?: string }} [opts] */
  constructor(io, opts = {}) {
    this.io = io
    this.now = io.now ?? (() => Date.now())
    this.setTimer = io.setTimer ?? ((fn, ms) => setTimeout(fn, ms))
    this.clearTimer = io.clearTimer ?? ((t) => clearTimeout(t))
    this.log = io.log ?? (() => {})
    this.gateway = opts.gateway ?? ''
    this.baud = 9600
    this.dtr = false
    this.out = []                 // bytes waiting to be paced to the Apple
    this.pacer = null
    this.reset()
    this.io.setLines(false, true)
  }

  reset() {
    this.hangup(false)
    this.echo = true
    this.verbose = true
    this.quiet = false
    this.dcdMode = 1              // &C1: carrier follows the connection
    this.dtrMode = 2              // &D2: DTR off hangs up
    this.s = new Array(32).fill(0)
    this.s[2] = 43                // '+'
    this.s[12] = 50               // guard time, 1/50 s
    this.line = ''
    this.last = ''
    this.online = false           // data mode
    this.plus = 0                 // escape: '+' seen in a row
    this.lastRx = 0               // when the Apple last sent a byte
  }

  get status() {
    return this.conn ? (this.online ? `connected to ${this.peer}` : `connected to ${this.peer} (command mode)`) : 'on hook'
  }

  // ---- to the Apple, paced at its baud ------------------------------------
  sendApple(bytes) {
    for (const b of bytes) this.out.push(b & 0xff)
    if (!this.pacer) this.pace()
  }
  pace() {
    this.pacer = null
    if (!this.out.length) { this.credit = 0; return }
    // baud / 10 bytes a second, in 10 ms ticks, the fraction carried over
    this.credit = (this.credit ?? 1) + (this.pacedOnce ? this.baud / 1000 : 0)
    this.pacedOnce = true
    const n = Math.floor(this.credit)
    if (n > 0) { this.io.toApple(this.out.splice(0, n)); this.credit -= n }
    if (this.out.length) this.pacer = this.setTimer(() => this.pace(), 10)
    else this.pacedOnce = false
  }
  result(code, extra = '') {
    if (this.quiet) return
    const text = this.verbose ? `\r\n${WORDS[code]}${extra}\r\n` : `${code}\r`
    this.sendApple([...text].map((c) => c.charCodeAt(0)))
  }
  setCarrier() {
    this.io.setLines(this.dcdMode === 0 ? true : !!this.conn, true)
  }

  // ---- from the Apple ------------------------------------------------------
  /** The card's DTR and baud (the stream's `sscst`). */
  fromDte(dtr, baudCode) {
    this.baud = BAUDS[baudCode & 15]
    if (this.dtr && !dtr && this.dtrMode === 2 && this.conn) {
      this.log('DTR dropped: hanging up')
      this.hangup(true)
    }
    this.dtr = dtr
  }

  /** A byte the Apple sent (the stream's `ssc`). */
  fromApple(b) {
    const t = this.now()
    const guard = this.s[12] * 20
    if (this.online) {
      // +++ escape: quiet before, three '+' quickly, then quiet after (checked by a timer)
      const isPlus = (b & 0x7f) === this.s[2]
      if (isPlus && (this.plus > 0 || t - this.lastRx >= guard)) {
        this.plus++
        if (this.plus === 3) {
          const at = t
          this.escTimer = this.setTimer(() => {
            if (this.plus === 3 && this.lastRx === at) {
              this.plus = 0
              this.online = false
              this.log('+++: command mode')
              this.result(0)
            }
          }, guard)
        }
      } else this.plus = 0
      this.lastRx = t
      this.toRemote([b])
      return
    }
    this.lastRx = t
    const c = b & 0x7f
    if (c === 0x0d) {
      if (this.echo) this.sendApple([0x0d, 0x0a])
      const line = this.line
      this.line = ''
      this.command(line)
      return
    }
    if (c === 0x08 || c === 0x7f) {
      if (this.line.length) {
        this.line = this.line.slice(0, -1)
        if (this.echo) this.sendApple([0x08, 0x20, 0x08])
      }
      return
    }
    if (c < 0x20) return
    if (this.echo) this.sendApple([c])
    this.line += String.fromCharCode(c)
    if (this.line.toUpperCase() === 'A/') {
      this.line = ''
      if (this.echo) this.sendApple([0x0d, 0x0a])
      this.command(this.last)
    }
  }

  // ---- the command line ----------------------------------------------------
  command(raw) {
    const line = raw.trim()
    if (!line) return
    if (!/^AT/i.test(line)) return
    this.last = line
    let s = line.slice(2)
    const up = () => s.toUpperCase()
    const num = () => {
      const m = /^\d+/.exec(s)
      if (!m) return 0
      s = s.slice(m[0].length)
      return +m[0]
    }
    while (s.length) {
      const c = up()[0]
      s = s.slice(1)
      if (c === ' ') continue
      if (c === '&') {
        const d = up()[0]
        s = s.slice(1)
        const n = num()
        if (d === 'F') { this.reset(); this.setCarrier() }
        else if (d === 'C') { this.dcdMode = n ? 1 : 0; this.setCarrier() }
        else if (d === 'D') this.dtrMode = n
        else if (!'KWSV'.includes(d)) return this.result(4)
        continue
      }
      switch (c) {
        case 'E': this.echo = num() !== 0; break
        case 'V': this.verbose = num() !== 0; break
        case 'Q': this.quiet = num() !== 0; break
        case 'X': case 'M': case 'L': case 'B': num(); break
        case 'Z': num(); this.reset(); this.setCarrier(); break
        case 'H': num(); this.hangup(false); break
        case 'I': {
          num()
          this.sendApple([...'\r\nApple //e TP20K WebSocket modem\r\n'].map((x) => x.charCodeAt(0)))
          break
        }
        case 'S': {
          const r = num()
          if (s[0] === '=') { s = s.slice(1); this.s[r & 31] = num() & 255 }
          else if (s[0] === '?') { s = s.slice(1); this.sendApple([...`\r\n${String(this.s[r & 31]).padStart(3, '0')}\r\n`].map((x) => x.charCodeAt(0))) }
          break
        }
        case 'O':
          num()
          if (!this.conn) return this.result(3)
          this.online = true
          return this.result(1, ` ${this.baud}`)
        case 'A':
          return this.result(3)                 // nobody calls in
        case 'D':
          return this.dial(s.replace(/^[TP]/i, '').replace(/[;,]/g, '').trim())
        default:
          return this.result(4)
      }
    }
    this.result(0)
  }

  dial(addr) {
    if (this.conn) return this.result(4)
    if (!addr) return this.result(4)
    let url, telnet = false, peer = addr
    if (/^LOOP$/i.test(addr)) {
      this.conn = { send: (b) => this.fromRemote(b), close: () => {} }
      this.peer = 'loopback'
      this.telnet = false
      return this.connected()
    }
    if (/^wss?:\/\//i.test(addr)) url = addr
    else {
      const m = /^([^:\s]+)(?::(\d+))?$/.exec(addr)
      if (!m) return this.result(4)
      if (!this.gateway) {
        this.log(`no WebSocket gateway set: cannot dial ${addr}`)
        return this.result(6)
      }
      url = this.gateway.replace('{host}', encodeURIComponent(m[1])).replace('{port}', m[2] ?? '23')
      telnet = true
      peer = `${m[1]}:${m[2] ?? '23'}`
    }
    this.log(`dialling ${peer} (${url})`)
    this.peer = peer
    this.telnet = telnet
    this.tn = { state: 0, cmd: 0 }
    let opened = false
    try {
      this.conn = this.io.connect(url, {
        onOpen: () => { opened = true; this.connected() },
        onData: (b) => this.fromRemote(b),
        onClose: () => {
          if (!this.conn) return
          this.log(`${peer}: closed`)
          this.conn = null
          const was = this.online
          this.online = false
          this.setCarrier()
          this.result(opened || was ? 3 : 8)
        },
      })
    } catch (e) {
      this.log(`${peer}: ${e.message}`)
      this.conn = null
      return this.result(3)
    }
  }

  connected() {
    this.online = true
    this.plus = 0
    this.setCarrier()
    this.log(`connected to ${this.peer}`)
    this.result(1, ` ${this.baud}`)
  }

  hangup(withResult) {
    if (this.escTimer) this.clearTimer(this.escTimer)
    const c = this.conn
    this.conn = null
    this.online = false
    if (c) { try { c.close() } catch { /* already gone */ } }
    this.io.setLines(this.dcdMode === 0, true)
    if (withResult) this.result(3)
  }

  // ---- the remote end, with telnet when dialled by host:port ---------------
  toRemote(bytes) {
    if (!this.conn) return
    const out = []
    for (const b of bytes) {
      out.push(b)
      if (this.telnet && b === IAC) out.push(IAC)
    }
    this.conn.send(Uint8Array.from(out))
  }

  fromRemote(data) {
    if (!this.telnet) { this.sendApple([...data]); return }
    const plain = []
    const reply = []
    const tn = this.tn
    for (const b of data) {
      switch (tn.state) {
        case 0:
          if (b === IAC) tn.state = 1
          else plain.push(b)
          break
        case 1:                                  // after IAC
          if (b === IAC) { plain.push(IAC); tn.state = 0 }
          else if (b === DO || b === DONT || b === WILL || b === WONT) { tn.cmd = b; tn.state = 2 }
          else if (b === SB) tn.state = 3
          else tn.state = 0
          break
        case 2: {                                // the option
          const ok = b === OPT_ECHO || b === OPT_SGA
          if (tn.cmd === DO) reply.push(IAC, ok && b === OPT_SGA ? WILL : WONT, b)
          else if (tn.cmd === WILL) reply.push(IAC, ok ? DO : DONT, b)
          tn.state = 0
          break
        }
        case 3:                                  // subnegotiation, up to IAC SE
          if (b === IAC) tn.state = 4
          break
        case 4:
          tn.state = b === SE ? 0 : 3
          break
      }
    }
    if (reply.length && this.conn) this.conn.send(Uint8Array.from(reply))
    if (plain.length) this.sendApple(plain)
  }
}
