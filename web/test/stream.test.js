// ============================================================================
//  stream.test.js -- the wire parser, against the strings the firmware emits
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import { AppleStream, screenToText } from '../src/stream.js'
import {
  BANNER,
  HELP,
  RESUME,
  SCR_COLS,
  SCR_TEXT_BYTES,
  SCR_GFX_BYTES,
  SCR_GFX_ROWS,
  SCR_GFX_ROW_BYTES,
  textPageIndex,
} from '../src/protocol.js'

const b = (s) => Uint8Array.from([...s].map((c) => c.charCodeAt(0)))

/** Feed chunks through a fresh parser and collect what it produced. */
function collect(chunks) {
  const st = new AppleStream()
  const events = []
  /** @type {string[]} */
  const lines = []
  for (const c of chunks) {
    const r = st.push(typeof c === 'string' ? b(c) : c)
    events.push(...r.events)
    lines.push(...r.text)
  }
  return { st, events, lines, text: lines.join('\n') }
}

const REGS_LINE = '\r\n' + 'PC:$FA62 A:$00 X:$0A Y:$7B SP:$D6 P:[NV-BDIZC] OP:$AD'
const MEM_LINE = '\r\n' + '$0300: 01 02 03 04 05 06 07 08  09 0A 0B 0C 0D 0E 0F 10 |................|'
const STATUS_LINE = '\r\n' + 'VID:T PLL:1'
/** The prompt is its own string, "\r\n> ", so it brings its own line ending. */
const PROMPT = String.fromCharCode(13, 10, 62)

test('console output arrives one line at a time', () => {
  const { lines } = collect(['HELLO', '\r\n', 'WORLD', '\r\n'])
  assert.deepEqual(lines, ['HELLO', 'WORLD'])
})

test('a line only appears when its line ending does', () => {
  // The //e is not waiting for you; text shows up as the machine emits it.
  const st = new AppleStream()
  const a = st.push(b('HEL'))
  assert.deepEqual(a.text, [], 'partial line is not emitted yet')
  const c = st.push(b('LO\r\n'))
  assert.deepEqual(c.text, ['HELLO'])
})

test('the firmware CR-then-LF pair is one line ending, not two lines', () => {
  // COUT of Return pushes CR, then schedules LF, as two separate bytes
  const { st, lines } = collect([Uint8Array.from([0x41, 0x0d, 0x0a, 0x42, 0x0d, 0x0a])])
  assert.equal(st.line, '')
  assert.deepEqual(lines, ['A', 'B'])
})

test('backspace rewinds the current line, as COUT of left-arrow does', () => {
  const { text } = collect(['HELX', '\x08', 'LO\r\n'])
  assert.equal(text, 'HELLO')
})

test('the bell is an event, not a character', () => {
  const { events, text } = collect(['\x07', 'A\r\n'])
  assert.deepEqual(
    events.map((e) => e.t),
    ['bell'],
  )
  assert.equal(text, 'A')
})

test('entering and leaving the debugger moves the mode', () => {
  const { st, events } = collect([BANNER])
  assert.equal(st.mode, 'debugger')
  assert.ok(events.some((e) => e.t === 'banner'))
  collect([RESUME])
  const two = collect([BANNER, RESUME])
  assert.equal(two.st.mode, 'console')
  assert.ok(two.events.some((e) => e.t === 'resumed'))
})

test('the register line parses', () => {
  const { events } = collect([REGS_LINE + PROMPT])
  const regs = events.find((e) => e.t === 'regs')
  assert.deepEqual(regs, {
    t: 'regs',
    pc: 0xfa62,
    a: 0x00,
    x: 0x0a,
    y: 0x7b,
    sp: 0xd6,
    flags: 'NV-BDIZC',
    op: 0xad,
  })
})

test('a memory dump parses, including the extra space after byte 7', () => {
  const { events } = collect([MEM_LINE + PROMPT])
  const m = events.find((e) => e.t === 'mem')
  assert.equal(m.addr, 0x0300)
  assert.equal(m.bytes.length, 16)
  assert.equal(m.bytes[0], 0x01)
  assert.equal(m.bytes[8], 0x09)
  assert.equal(m.text, '................')
})

test('the status line parses', () => {
  const { events } = collect([STATUS_LINE + PROMPT])
  assert.deepEqual(events.find((e) => e.t === 'status'), {
    t: 'status',
    video: 'text',
    pll: true,
  })
})

test('the prompt is its own event, so commands can be paced', () => {
  const { events } = collect([BANNER, REGS_LINE + PROMPT])
  const kinds = events.map((e) => e.t).filter((k) => k === 'regs' || k === 'prompt')
  // Two prompts, not one. The banner string in serial_debugger.v ends with
  // "\r\n> " itself and only then does the sequencer run the register dump,
  // which ends with another. Releasing a queued command on the first prompt
  // would have it dropped, because the debugger only reads commands when its
  // main state is idle -- hence the quiet-period rule in useApple.
  assert.deepEqual(kinds, ['prompt', 'regs', 'prompt'])
})

test('the help line is recognised and does not become console text', () => {
  const { events, text } = collect([HELP])
  assert.ok(events.some((e) => e.t === 'help'))
  assert.equal(text, '')
})

test('a frame split across arbitrary chunk boundaries still parses', () => {
  // At 115200 the register line arrives as several reads, so nothing may
  // depend on the line landing in one push().
  const whole = REGS_LINE + PROMPT
  for (const size of [1, 3, 7, 16, 40]) {
    const chunks = [BANNER]
    for (let i = 0; i < whole.length; i += size) chunks.push(whole.slice(i, i + size))
    const { events } = collect(chunks)
    const regs = events.find((e) => e.t === 'regs')
    assert.equal(regs?.pc, 0xfa62, `chunk size ${size}`)
  }
})

/** Build the exact byte sequence the W command emits. */
function screenFrame(flags, fill) {
  // The wire carries the page in memory order, holes included; a cell sits at
  // textPageIndex(row, col), which is the interleaving video_generator reads.
  const page = new Uint8Array(SCR_TEXT_BYTES)
  const put = (r, c, v) => (page[textPageIndex(r, c)] = v)
  for (let r = 0; r < 24; r++) {
    for (let c = 0; c < SCR_COLS; c++) put(r, c, fill + ((r * 8 + c) % 8))
  }
  // Mark a hole, so the test proves holes are carried rather than skipped.
  page[40] = 0x5a
  const gfx = new Uint8Array(SCR_GFX_BYTES).fill(0x2a)
  let s = `\r\n$SS ${flags.toString(16).toUpperCase().padStart(2, '0')}\r\n `
  // The firmware breaks the hex run with CRLF every 40 bytes; the parser
  // should not care where the lines fall, so follow that cadence.
  const hexOf = (bytes, at, n) =>
    [...bytes.slice(at, at + n)].map((v) => v.toString(16).toUpperCase().padStart(2, '0')).join('')
  for (let at = 0; at < SCR_TEXT_BYTES; at += 40) s += hexOf(page, at, 40) + '\r\n'
  s += '\r\n$GF'
  for (let r = 0; r < SCR_GFX_ROWS; r++) {
    s += hexOf(gfx, r * SCR_GFX_ROW_BYTES, SCR_GFX_ROW_BYTES) + '\r\n'
  }
  s += '\r\n$SEND\r\n'
  return { s, page, gfx }
}

test('a screen dump parses, however it is chunked', () => {
  const { s, page } = screenFrame(0b10111, 0xa0)
  for (const size of [1, 17, 256, 4096]) {
    const chunks = []
    for (let i = 0; i < s.length; i += size) chunks.push(s.slice(i, i + size))
    const { events } = collect(chunks)
    const sc = events.find((e) => e.t === 'screen')
    assert.ok(sc, `no screen event at chunk size ${size}`)
    assert.equal(sc.page.length, SCR_TEXT_BYTES)
    assert.deepEqual([...sc.page], [...page], `page mismatch at chunk size ${size}`)
    assert.equal(sc.gfx.length, SCR_GFX_BYTES)
    assert.equal(sc.text, true, 'TEXT bit set')
    assert.equal(sc.mixed, true, 'MIXED bit set')
    assert.equal(sc.page2, true, 'PAGE2 bit set')
    assert.equal(sc.hires, false)
    assert.equal(sc.pll, true)
  }
})

test('the dump does not leak into the console as text', () => {
  const { s } = screenFrame(0b00111, 0xa0)
  const { text } = collect([s])
  assert.equal(text, '', 'hex rows should not be shown as console output')
})

test('cells undo the row interleaving and split off inverse video', () => {
  const page = new Uint8Array(SCR_TEXT_BYTES)
  // row 3, col 7 gets an inverse '$', at its interleaved address
  page[textPageIndex(3, 7)] = 0x80 | 0x24
  const rows = AppleStream.cells(page)
  assert.equal(rows.length, 24)
  assert.equal(rows[0].length, 40)
  assert.deepEqual(rows[3][7], { code: 0x24, inverse: true })
  assert.deepEqual(rows[0][0], { code: 0, inverse: false })
})

test('screenToText lays the cells out as lines', () => {
  const page = new Uint8Array(SCR_TEXT_BYTES)
  const put = (r, c, ch) => (page[textPageIndex(r, c)] = ch.charCodeAt(0))
  put(0, 0, 'A')
  put(0, 1, 'P')
  put(0, 2, 'P')
  put(0, 3, 'L')
  put(0, 4, 'E')
  const lines = screenToText(page)
  assert.equal(lines[0], 'APPLE')
  assert.equal(lines[1], '')
})
