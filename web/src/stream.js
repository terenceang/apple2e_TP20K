// ============================================================================
//  stream.js -- parsing what comes back from the Apple //e
//
//  There is one UART and one stream. COUT, the console echo, and the debugger
//  all share it, so this classifies as it goes rather than assuming which is
//  which. The firmware makes that tractable: COUT is only mirrored while the
//  machine is running (cout_hit is qualified with !dbg_mode) and the debugger
//  only prints while it is paused, so the mode tells you which of the two is
//  live. Anything unrecognised is console text, which is the right default --
//  it is the only thing the Apple II itself ever sends.
//
//  Line-oriented, because every frame the firmware emits is CRLF-delimited and
//  the only non-line thing is the W screen dump, which is a long run of hex.
//
//  Plain JS so `node --test` can drive it with real byte sequences.
// ============================================================================

import {
  SCR_TEXT_ROWS,
  SCR_COLS,
  SCR_TEXT_BYTES,
  SCR_GFX_BYTES,
  SCR_HGR_BYTES,
  SCR_FLAG,
  textPageIndex,
  BANNER_TEXT,
  RESUME_TEXT,
  PROMPT_LINE,
  HANDSHAKE,
} from './protocol.js'

const HELP_PREFIX = HANDSHAKE.slice(0, HANDSHAKE.indexOf(':') + 2) // 'Cmds: '

const REGS_RE =
  /^PC:\$([0-9A-F]{4}) A:\$([0-9A-F]{2}) X:\$([0-9A-F]{2}) Y:\$([0-9A-F]{2}) SP:\$([0-9A-F]{2}) P:\[([N\-V\-BDIZC]{8})\] OP:\$([0-9A-F]{2})/
// The hex field has a double space after byte 7 (the firmware's M_MEM step 8
// puts an extra one there so the halves of a 16-byte line line up), so split
// on whitespace rather than matching a fixed pattern.
const MEM_RE = /^\$([0-9A-F]{4}): (.*)\|([\x20-\x7e.]*)\|$/
// serial_debugger.v M_STATUS: VID:T PLL:1 D:<eight hex digits of DDR3 diagnostics>
export const STATUS_RE = /^VID:([TG]) PLL:([01])(?: D:[0-9A-F]{8})?$/

/**
 * $SS <flags> then the 1 KB text page; $GF then 4 rows of 40; $SEND ends it.
 *
 * The text page goes down the wire in memory order, interleaving holes
 * included, so all 1024 bytes arrive as hex.
 */
const HEX_RUN = SCR_TEXT_BYTES * 2
const GFX_RUN = SCR_GFX_BYTES * 2
const HGR_RUN = SCR_HGR_BYTES * 2

export class AppleStream {
  constructor() {
    /** @type {string} */
    this.line = ''
    /** @type {string[]} */
    this.text = []
    /** @type {Array<object>} */
    this.events = []
    this.mode = 'console' // console | debugger

    this.cr = false // saw CR, so the next LF is part of the same line ending
    this.sscNext = 0 // a 1E/1F marker was the last byte: the next is the card's
    this.afterPrompt = false // just emitted a prompt, so eat its trailing space

    // screen frame accumulation
    this.frame = null

    /** @type {{text: string[], events: object[]}} */
    this.sink = { text: [], events: [] }
  }

  /** Take bytes off the wire. Returns what to show the user this tick. */
  push(bytes) {
    this.sink = { text: [], events: [] }
    for (const b of bytes) this.char(b)
    return this.sink
  }

  emit(event) {
    this.events.push(event)
    this.sink.events.push(event)
  }

  say(s) {
    this.text.push(s)
    this.sink.text.push(s)
  }

  char(b) {
    // The Super Serial Card's line (src/serial_debugger.v): 1E <byte> is a
    // byte the Apple sent through slot 1, 1F <st> its DTR (bit 6) and baud
    // (bits 3:0).  Nothing else the board sends is 1E or 1F, and a raw sector
    // transfer does not come through here (disk.js takes the link for it).
    if (this.sscNext) {
      const k = this.sscNext
      this.sscNext = 0
      this.emit(k === 0x1e ? { t: 'ssc', b } : { t: 'sscst', dtr: Boolean(b & 0x40), baud: b & 15 })
      return
    }
    if (b === 0x1e || b === 0x1f) {
      this.sscNext = b
      return
    }
    if (b === 0x0d) {
      this.cr = true
      this.endLine()
      return
    }
    if (b === 0x0a) {
      // The firmware sends CR then LF as two separate bytes, possibly in
      // different reads, so a bare LF right after a CR is the other half of
      // the same line ending and is not a line of its own.
      this.cr = false
      return
    }
    this.cr = false
    if (b === 0x08) {
      this.line = this.line.slice(0, -1)
      return
    }
    if (b === 0x07) {
      this.emit({ t: 'bell' })
      return
    }
    if (b >= 0x20 && b <= 0x7e) {
      // The debugger prompt is "\r\n> " and nothing follows it until a
      // command comes back, so it never gets a line ending of its own. Catch
      // it as it is typed, because "the machine is idle and waiting" is the
      // signal the command queue paces itself on. The trailing space is
      // swallowed so it does not show up as console text.
      if (this.afterPrompt) {
        this.afterPrompt = false
        if (b === 0x20) return
      }
      this.line += String.fromCharCode(b)
      if (this.mode === 'debugger' && this.line === PROMPT_LINE) {
        this.line = ''
        this.afterPrompt = true
        this.emit({ t: 'prompt' })
        return
      }
      // Guard against a runaway stream with no line endings.
      if (this.line.length > 4096) this.endLine()
      return
    }
    // Anything else is not something a terminal shows.
  }

  endLine() {
    const raw = this.line
    this.line = ''
    this.classify(raw)
  }

  classify(line) {
    const s = line.trim()

    // --- a screen dump in progress, or starting --------------------------
    if (this.frame) {
      if (s.startsWith('$GF')) {
        this.frame.inGfx = true
        this.frame.inHgr = false
        this.frame.gfx += s.slice(3)
        this.frameGfx()
        return
      }
      if (s.startsWith('$HR')) {
        this.frame.inHgr = true
        this.frame.inAux = false
        this.frame.inGfx = false
        this.frame.hgr += s.slice(3)
        return
      }
      if (s.startsWith('$AX')) {
        this.frame.inAux = true
        this.frame.inHgr = false
        this.frame.inGfx = false
        this.frame.aux += s.slice(3)
        return
      }
      if (s === '$SEND') {
        if (this.frame.inHgr) {
          this.frameHgr()
        }
        if (this.frame.inAux) {
          this.frameAux()
        }
        this.finishFrame()
        return
      }
      if (this.frame.inAux) {
        this.frame.aux += s
        return
      }
      if (this.frame.inHgr) {
        this.frame.hgr += s
        return
      }
      if (this.frame.inGfx) {
        this.frame.gfx += s
        this.frameGfx()
        return
      }
      // text rows, or the space the firmware emits before the first one
      this.frame.text += s
      if (this.frame.text.length >= HEX_RUN) this.frameText()
      return
    }

    if (s.startsWith('$SS ')) {
      const flags = parseInt(s.slice(4, 6), 16)
      this.frame = {
        flags: Number.isFinite(flags) ? flags : 0,
        // the firmware carries on with the first 40 bytes on this same line
        text: s.slice(6).replace(/\s+/g, ''),
        gfx: '',
        hgr: '',
        aux: '',
        inGfx: false,
        inHgr: false,
        inAux: false,
        rows: 0,
      }
      if (this.frame.text.length >= HEX_RUN) this.frameText()
      return
    }

    // --- mode changes ----------------------------------------------------
    if (s.startsWith(BANNER_TEXT)) {
      this.mode = 'debugger'
      this.emit({ t: 'mode', mode: this.mode })
      this.emit({ t: 'banner' })
      return
    }
    if (s.startsWith(RESUME_TEXT)) {
      this.mode = 'console'
      this.emit({ t: 'mode', mode: this.mode })
      this.emit({ t: 'resumed' })
      return
    }

    // --- debugger frames -------------------------------------------------
    if (s.startsWith(HELP_PREFIX)) {
      this.emit({ t: 'help' })
      return
    }
    if (s === PROMPT_LINE) {
      this.emit({ t: 'prompt' })
      return
    }

    const regs = REGS_RE.exec(s)
    if (regs) {
      this.emit({
        t: 'regs',
        pc: parseInt(regs[1], 16),
        a: parseInt(regs[2], 16),
        x: parseInt(regs[3], 16),
        y: parseInt(regs[4], 16),
        sp: parseInt(regs[5], 16),
        flags: regs[6],
        op: parseInt(regs[7], 16),
      })
      return
    }

    const mem = MEM_RE.exec(s)
    if (mem) {
      const bytes = mem[2].trim().split(/\s+/).map((h) => parseInt(h, 16))
      this.emit({ t: 'mem', addr: parseInt(mem[1], 16), bytes, text: mem[3] })
      return
    }
    const status = STATUS_RE.exec(s)
    if (status) {
      this.emit({ t: 'status', video: status[1] === 'T' ? 'text' : 'graphics', pll: status[2] === '1' })
      return
    }

    // --- anything else is the Apple II talking ----------------------------
    if (s !== '' || line !== '') this.say(line)
  }

  frameText() {
    if (!this.frame || this.frame.rows) return
    const hex = this.frame.text.slice(0, HEX_RUN)
    // Memory order, exactly as the firmware read it out of $0400-$07FF: the
    // 64 interleaving holes are on the wire too. Callers index the page with
    // textPageIndex.
    const page = new Uint8Array(SCR_TEXT_BYTES)
    const shown = Math.min(Math.floor(hex.length / 2), SCR_TEXT_BYTES)
    for (let i = 0; i < shown; i++) page[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
    this.frame.page = page
    this.frame.rows = 1
  }

  frameGfx() {
    if (!this.frame || !this.frame.rows) return
    const hex = this.frame.gfx.slice(0, GFX_RUN)
    const gfx = new Uint8Array(SCR_GFX_BYTES)
    for (let i = 0; i < SCR_GFX_BYTES; i++) gfx[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
    this.frame.gfxPage = gfx
  }

  frameHgr() {
    if (!this.frame) return
    const hex = (this.frame.hgr || '').replace(/[^0-9A-Fa-f]/g, '')
    const hgr = new Uint8Array(SCR_HGR_BYTES)
    const count = Math.min(Math.floor(hex.length / 2), SCR_HGR_BYTES)
    for (let i = 0; i < count; i++) {
      hgr[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
    }
    this.frame.hgrPage = hgr
  }

  frameAux() {
    if (!this.frame) return
    const hex = (this.frame.aux || '').replace(/[^0-9A-Fa-f]/g, '')
    const aux = new Uint8Array(SCR_HGR_BYTES)
    const count = Math.min(Math.floor(hex.length / 2), SCR_HGR_BYTES)
    for (let i = 0; i < count; i++) {
      aux[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
    }
    this.frame.auxPage = aux
  }

  finishFrame() {
    const f = this.frame
    this.frame = null
    if (!f) return
    if (!f.page && f.text) {
      const hex = f.text.replace(/[^0-9A-Fa-f]/g, '')
      const page = new Uint8Array(SCR_TEXT_BYTES)
      const count = Math.min(Math.floor(hex.length / 2), SCR_TEXT_BYTES)
      for (let i = 0; i < count; i++) page[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
      f.page = page
    }
    if (f.gfx && !f.gfxPage) {
      const hex = f.gfx.replace(/[^0-9A-Fa-f]/g, '')
      const gfx = new Uint8Array(SCR_GFX_BYTES)
      const count = Math.min(Math.floor(hex.length / 2), SCR_GFX_BYTES)
      for (let i = 0; i < count; i++) gfx[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
      f.gfxPage = gfx
    }
    if (f.hgr && !f.hgrPage) {
      const hex = f.hgr.replace(/[^0-9A-Fa-f]/g, '')
      const hgr = new Uint8Array(SCR_HGR_BYTES)
      const count = Math.min(Math.floor(hex.length / 2), SCR_HGR_BYTES)
      for (let i = 0; i < count; i++) hgr[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
      f.hgrPage = hgr
    }
    if (f.aux && !f.auxPage) {
      const hex = f.aux.replace(/[^0-9A-Fa-f]/g, '')
      const aux = new Uint8Array(SCR_HGR_BYTES)
      const count = Math.min(Math.floor(hex.length / 2), SCR_HGR_BYTES)
      for (let i = 0; i < count; i++) aux[i] = parseInt(hex.substr(i * 2, 2), 16) || 0
      f.auxPage = aux
    }
    const flags = f.flags
    this.emit({
      t: 'screen',
      flags,
      text: Boolean(flags & SCR_FLAG.TEXT),
      page2: Boolean(flags & SCR_FLAG.PAGE2),
      mixed: Boolean(flags & SCR_FLAG.MIXED),
      hires: Boolean(flags & SCR_FLAG.HIRES),
      dhires: Boolean(flags & SCR_FLAG.DHIRES),
      col80: Boolean(flags & SCR_FLAG.COL80),
      pll: Boolean(flags & SCR_FLAG.PLL),
      page: f.page ?? new Uint8Array(SCR_TEXT_BYTES),
      gfx: f.gfxPage ?? new Uint8Array(0),
      hgr: f.hgrPage ?? new Uint8Array(0),
      aux: f.auxPage ?? new Uint8Array(0),
    })
  }

  /**
   * Unpack a dumped page into 24 rows of 40 cells.
   *
   * The dump is in memory order ($0400 upward, interleaving holes included),
   * so each cell comes out through textPageIndex -- the same interleaving
   * video_generator.v reads the page with.
   * Each cell is { code }, the stored byte whole: bits 7 and 6 are what pick
   * normal, inverse or flashing glyphs, through the same character-ROM address
   * the RTL makes (charset.js), so they are not split off here.
   */
  static cells(page) {
    const rows = []
    for (let r = 0; r < SCR_TEXT_ROWS; r++) {
      const row = []
      for (let c = 0; c < SCR_COLS; c++) {
        const b = page[textPageIndex(r, c)]
        row.push({ code: b })
      }
      rows.push(row)
    }
    return rows
  }
}

/** Roll a decoded frame into one line per text row, for copying. */
export function screenToText(page, glyphs) {
  const out = []
  for (const row of AppleStream.cells(page)) {
    out.push(
      row
        .map((c) => glyphFor(glyphs, c.code))
        .join('')
        .replace(/[ ]+$/, ''),
    )
  }
  return out
}

/**
 * The character a cell code renders as. The //e character ROM has 256
 * glyphs, but without the generated table the best we can do is ASCII, and a
 * code outside printable ASCII is a blank on screen rather than a control
 * character.
 */
export function glyphFor(glyphs, code) {
  if (glyphs) return glyphs[code] ?? ' '
  if (code < 0x20 || code > 0x7e) return ' '
  return String.fromCharCode(code)
}
