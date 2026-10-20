// ============================================================================
//  protocol.test.js -- byte-level agreement with the RTL
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  encodeKey,
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

test('the firmware strings match serial_debugger.v byte for byte', () => {
  assert.equal(BANNER, '\r\n[ Apple //e Debugger ] (h=Help, c=Cont)\r\n> ')
  assert.equal(RESUME, '\r\n[Resuming...]\r\n')
  assert.equal(HELP, '\r\nCmds: r=Regs s=Step c=Cont m=Mem t=Stat w=Scr h=Help\r\n> ')
  assert.equal(PROMPT, '\r\n> ')
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
