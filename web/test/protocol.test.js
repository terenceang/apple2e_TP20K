// ============================================================================
//  protocol.test.js -- byte-level agreement with the RTL
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  encodeKey,
  encodeClock,
  encodeGamepad,
  encodeKeysUp,
  clampPaddle,
  parseHexChunk,
  BANNER,
  RESUME,
  HELP,
  PROMPT,
  HANDSHAKE,
  SCR_TEXT_BYTES,
  SCR_GFX_BYTES,
  SCR_TEXT_ROWS,
  SCR_COLS,
  SCR_FLAG,
  textPageIndex,
} from '../src/protocol.js'
import { STATUS_RE } from '../src/stream.js'

test('a clock packet is FF 05 and YYMMDDWHHMMSS as ASCII digits, never 0x02', () => {
  // 2026-10-22 is a Thursday (4); local time, as ProDOS has no time zone
  const p = encodeClock(new Date(2026, 9, 22, 13, 45, 7))
  assert.deepEqual([...p.slice(0, 2)], [0xff, 0x05])
  assert.equal(String.fromCharCode(...p.slice(2)), '2610224134507')
  // a Sunday is 0, and early in the month every field is zero-padded
  assert.equal(String.fromCharCode(...encodeClock(new Date(2027, 0, 3, 2, 2, 2)).slice(2)), '2701030020202')
  assert.ok(!p.slice(2).includes(0x02))
})

test('a key packet is FE <code> <buttons>', () => {
  assert.deepEqual([...encodeKey(0x61, 0b001)], [0xfe, 0x61, 0b001])
  assert.deepEqual([...encodeKey(0x0d, 0)], [0xfe, 0x0d, 0x00])
})

test('the key packet masks its payload to 7 and 3 bits', () => {
  assert.deepEqual([...encodeKey(0xe1, 0xff)], [0xfe, 0x61, 0x07])
})

test('all-keys-up is FF 04', () => {
  assert.deepEqual([...encodeKeysUp()], [0xff, 0x04])
})

test('a gamepad packet is FF 01 <buttons> <x> <y>', () => {
  assert.deepEqual([...encodeGamepad(0b011, 200, 0)], [0xff, 0x01, 0b011, 200, 0])
})

test('paddles clamp to a byte', () => {
  assert.equal(clampPaddle(-5), 0)
  assert.equal(clampPaddle(300), 255)
  assert.equal(clampPaddle(128.4), 128)
  assert.equal(clampPaddle('nonsense'), 128)
})

// The debugger's strings, read out of the RTL itself: each STR_TEXT piece is a
// Verilog literal with a `// NAME` comment, CR LF written as \015\012.
function rtlStrings() {
  const here = dirname(fileURLToPath(import.meta.url))
  const v = readFileSync(join(here, '..', '..', 'src', 'serial_debugger.v'), 'utf8')
  const body = v.slice(v.indexOf('STR_TEXT = {'), v.indexOf('};', v.indexOf('STR_TEXT = {')))
  const out = {}
  for (const m of body.matchAll(/^\s*"((?:[^"\\]|\\.)*)"[,\s]*\/\/\s*(\w+)/gm)) {
    out[m[2]] = m[1].replace(/\\([0-7]{3}|.)/g, (_, e) => (e.length === 3 ? String.fromCharCode(parseInt(e, 8)) : e))
  }
  // each piece's length must be the STR_<NAME>_LEN the ROM addresses it by
  for (const [name, text] of Object.entries(out)) {
    const len = v.match(new RegExp(`STR_${name}_LEN\\s*=\\s*8'd(\\d+)`))
    assert.ok(len, `STR_${name}_LEN missing`)
    assert.equal(text.length, Number(len[1]), `STR_${name}_LEN is not the length of its text`)
  }
  return out
}

test('the firmware strings match serial_debugger.v byte for byte', () => {
  const rtl = rtlStrings()
  assert.equal(BANNER, rtl.BANNER)
  assert.equal(RESUME, rtl.RESUME)
  assert.equal(HELP, rtl.HELP)
  assert.equal(PROMPT, rtl.PROMPT)
  // the `t` line, as M_STATUS builds it, is what stream.js parses
  const line = rtl.VID + 'T' + rtl.PLL + '1' + rtl.DDR + 'D3000C35'
  assert.ok(STATUS_RE.test(line), `stream.js does not parse the debugger's status line: ${line}`)
  // what web/src/disk.js waits for after `b` and `u`
  assert.ok(rtl.SECS.includes('SECTORS'))
  assert.ok(rtl.HDUP.includes('UPLOAD HD'))
  assert.ok(rtl.LOST.includes('lost'))
  // the handshake serial-link uses to tell the FPGA's UART from the BL616's
  // own console
  assert.ok(HELP.includes(HANDSHAKE))
  assert.ok(!BANNER.includes(HANDSHAKE))
})

test('the handshake is a substring of the help line and nothing else', () => {
  // serial-link tells the FPGA's UART from the BL616's own console by sending
  // Ctrl+B, then '?', and looking for this. It must not appear in the banner
  // or the resume notice, or the probe would fire on the wrong port.
  assert.ok(HELP.includes(HANDSHAKE))
  assert.ok(!BANNER.includes(HANDSHAKE))
  assert.ok(!RESUME.includes(HANDSHAKE))
  assert.ok(!PROMPT.includes(HANDSHAKE))
})

test('hex parsing tolerates whitespace and chunk boundaries', () => {
  assert.deepEqual([...parseHexChunk('A0 B1 2C', 3)], [0xa0, 0xb1, 0x2c])
  assert.deepEqual([...parseHexChunk('A0B1', 2)], [0xa0, 0xb1])
  assert.equal(parseHexChunk('A0B1', 3), null, 'short input is not a complete row')
  assert.deepEqual([...parseHexChunk('  a0\nb1\r\n', 2)], [0xa0, 0xb1])
})

test('the screen dump sizes are what the W command emits', () => {
  assert.equal(SCR_TEXT_BYTES, 1024) // the whole page, contiguous
  assert.equal(SCR_GFX_BYTES, 160) // lo-res rows 20-23: 4 rows x 40 bytes
  assert.equal(SCR_TEXT_ROWS * SCR_COLS, 960) // but only 960 are on screen
})

test('the page index matches the interleaving video_generator.v uses', () => {
  // rows 0-7 step 128, then the next group starts 40 bytes in
  assert.equal(textPageIndex(0, 0), 0x000)
  assert.equal(textPageIndex(0, 39), 0x027)
  assert.equal(textPageIndex(1, 0), 0x080)
  assert.equal(textPageIndex(7, 0), 0x380)
  assert.equal(textPageIndex(8, 0), 0x028)
  assert.equal(textPageIndex(15, 0), 0x3a8)
  assert.equal(textPageIndex(16, 0), 0x050)
  // the last cell on screen is $07F7; $07F8-$07FF are the group's unused tail
  assert.equal(textPageIndex(23, 39), 0x3f7)
  // every cell lands on a distinct byte inside the 1 KB page
  const seen = new Set()
  for (let r = 0; r < 24; r++) for (let c = 0; c < 40; c++) seen.add(textPageIndex(r, c))
  assert.equal(seen.size, 960)
  for (const i of seen) assert.ok(i >= 0 && i < SCR_TEXT_BYTES, `index ${i} out of the page`)
  // 1024 - 960 = 64 bytes in the dump are not displayed
  assert.equal(SCR_TEXT_BYTES - seen.size, 64)
})

test('the screen flag bits are the softswitches the renderer needs', () => {
  assert.equal(SCR_FLAG.TEXT, 0x01)
  assert.equal(SCR_FLAG.PAGE2, 0x02)
  assert.equal(SCR_FLAG.MIXED, 0x04)
  assert.equal(SCR_FLAG.HIRES, 0x08)
  assert.equal(SCR_FLAG.PLL, 0x10)
})
