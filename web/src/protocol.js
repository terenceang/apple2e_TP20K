// ============================================================================
//  protocol.js -- the host side of the Apple_TN20K UART protocol
//
//  Plain JS with JSDoc types rather than TS, so `node --test` can import the
//  exact same code the browser bundles. Anything in here that both the bridge
//  and the app need to agree on byte for byte lives in this file.
//
//  See src/input_controller.v and src/serial_debugger.v for the other end.
// ============================================================================

/** Ctrl+B: toggles the hardware debugger. Never reaches the keyboard. */
export const CTRL_B = 0x02

/** Leader for FF 01 <buttons> <x> <y>. */
export const GAMEPAD_HDR = 0xff

/** Leader for FE <code> <buttons>. */
export const KEY_HDR = 0xfe

/**
 * A key packet: the final 7-bit Apple II key code plus the paddle button bits
 * that were down with it, so 🍏 and 🍎 press the game buttons the way they do
 * on real hardware.
 *
 * The code is already shifted. On a real //e the keyboard PROM (341-0132-D)
 * turns a key position plus the shift and caps-lock lines into the character
 * in $C000, and the ROMs take D6-D0 as final, so the sender owns that job.
 */
export function encodeKey(code, buttons = 0) {
  return Uint8Array.from([KEY_HDR, code & 0x7f, buttons & 0x07])
}

/**
 * All keys up: FF 04. Drops any-key-down ($C010 bit 7), which a key packet
 * holds until this arrives (a plain ASCII key has no release, so it times out).
 */
export function encodeKeysUp() {
  return Uint8Array.from([GAMEPAD_HDR, 0x04])
}

/**
 * The RESET key: FF 03 <b>, bit 3 = RESET held, bits 0-2 = the paddle buttons
 * (the ROM reads Open/Solid-Apple just after RESET is released). A real //e's
 * RESET only acts with CONTROL down; the caller enforces that.
 */
export function encodeReset(down, buttons = 0) {
  return Uint8Array.from([GAMEPAD_HDR, 0x03, (down ? 0x08 : 0) | (buttons & 0x07)])
}

/** A gamepad packet: PB0/PB1/PB2 in the low three bits, then two paddles. */
export function encodeGamepad(buttons, x, y) {
  return Uint8Array.from([
    GAMEPAD_HDR,
    0x01,
    buttons & 0x07,
    clampPaddle(x),
    clampPaddle(y),
  ])
}

export function clampPaddle(v) {
  const n = Math.round(Number(v))
  if (!Number.isFinite(n)) return PADDLE_CENTER
  return n < 0 ? 0 : n > 255 ? 255 : n
}

/** The centre the paddles rest at (also the RTL's reset value, $80). */
export const PADDLE_CENTER = 128

// ---------------------------------------------------------------------------
//  What the firmware says back
//
//  These are literal, taken from the str_rom table in serial_debugger.v. The
//  app uses them to stay in step with the machine rather than guessing: a
//  command is only accepted when the debugger is back at M_IDLE, so anything
//  sent too early is silently dropped.
// ---------------------------------------------------------------------------

// The debugger's literal strings, byte for byte what serial_debugger.v sends.
// stream.js parses against the plain texts; the wire forms keep the CRLFs and
// trailing prompt so tests can replay exact firmware output.

/** The line after Ctrl+B, without its CRLFs. */
export const BANNER_TEXT = '[ Apple //e Debugger ] (h=Help, c=Cont)'
/** The line when the machine is let go, without its CRLFs. */
export const RESUME_TEXT = '[Resuming...]'
/** The idle prompt the debugger types, without its CRLFs (and trailing space). */
export const PROMPT_LINE = '>'

export const BANNER = `\r\n${BANNER_TEXT}\r\n${PROMPT_LINE} `
export const RESUME = `\r\n${RESUME_TEXT}\r\n`
export const HELP = '\r\nCmds: r=Regs s=Step c=Cont m=Mem t=Stat w=Scr h=Help\r\n> '
export const PROMPT = `\r\n${PROMPT_LINE} `

/** Substring that proves we are talking to the FPGA's UART, not the BL616's
 *  own console. Used by the bridge to pick the right FT2232C channel. */
export const HANDSHAKE = 'Cmds: r=Regs'

// ---------------------------------------------------------------------------
//  Debugger commands
// ---------------------------------------------------------------------------

export const CMD = {
  regs: 'r',
  step: 's',
  cont: 'c',
  mem: 'm',
  status: 't',
  screen: 'w',
  help: '?',
  reset: 'x',
}

/** Memory-dump presets. The firmware only accepts these, so there is no way to
 *  ask for an arbitrary address; `m` then pages forward by 16. */
export const MEM_JUMPS = [
  { key: '0', label: '$0000', addr: 0x0000 },
  { key: '1', label: '$0100', addr: 0x0100 },
  { key: '4', label: '$0400 text', addr: 0x0400 },
  { key: '8', label: '$0800', addr: 0x0800 },
  { key: 'f', label: '$FA60 input', addr: 0xfa60 },
  { key: 'v', label: '$FFF0 ROM', addr: 0xfff0 },
]

// ---------------------------------------------------------------------------
//  W (screen dump) framing
//
//    $SS <flags>   one flag byte, then the whole 1 KB text page as hex
//    $GF           four rows of 40 bytes as hex: lo-res rows 20-23
//    $SEND         end of the dump
//
//  All hex text so `picocom` shows something readable too.
// ---------------------------------------------------------------------------

export const SCR_TEXT_ROWS = 24
export const SCR_COLS = 40
export const SCR_GFX_ROWS = 4
export const SCR_GFX_ROW_BYTES = 40
/**
 * The W command streams the text page *contiguously* -- all 1024 bytes of
 * $0400-$07FF in memory order, the 64 interleaving holes included -- even
 * though only 24x40 = 960 of them are on screen: the Apple II interleaves the
 * page into three groups of eight rows 128 bytes apart. Use textPageIndex()
 * to go from a row and column to a byte in that stream.
 */
export const SCR_TEXT_BYTES = 1024
export const SCR_GFX_BYTES = SCR_GFX_ROWS * SCR_GFX_ROW_BYTES

/**
 * Byte offset of a text cell within the contiguous page dump.
 *
 * The same interleaving video_generator.v does:
 *   vram_addr = base_page + (row & 7) * 128 + (row >= 8 ? 40 : row >= 16 ? 80 : 0) + col
 */
export function textPageIndex(row, col) {
  const group = row >= 16 ? 0x50 : row >= 8 ? 0x28 : 0x00
  return ((row & 7) << 7) + group + col
}

/** Bit layout of the $SS flags byte. */
export const SCR_FLAG = {
  TEXT: 1 << 0,
  PAGE2: 1 << 1,
  MIXED: 1 << 2,
  HIRES: 1 << 3,
  PLL: 1 << 4,
}

/**
 * Parse a hex run of `count` bytes. Tolerant of whitespace and of the frame
 * arriving in several chunks, because at 115200 a 1 KB dump arrives as ~150
 * separate serial reads. stream.js keeps its own accumulated version (it pads
 * a partially filled page rather than rejecting it), so this is only a helper
 * for tools and tests.
 */
export function parseHexChunk(s, count) {
  const out = new Uint8Array(count)
  let n = 0
  const clean = s.replace(/[^0-9A-Fa-f]/g, '')
  for (let i = 0; i + 1 < clean.length && n < count; i += 2) {
    out[n++] = parseInt(clean.slice(i, i + 2), 16)
  }
  return n === count ? out : null
}

/** The 16-colour lo-res palette, copied from video_generator.v so the browser
 *  and the HDMI output agree pixel for pixel. */
export const LORES_PALETTE = [
  [0x00, 0x00, 0x00], // black
  [0x90, 0x17, 0x40], // magenta
  [0x40, 0x2c, 0xa5], // dark blue
  [0xd0, 0x43, 0xe5], // purple
  [0x00, 0x69, 0x40], // dark green
  [0x80, 0x80, 0x80], // grey 1
  [0x2f, 0x95, 0xe5], // medium blue
  [0xbf, 0xab, 0xff], // light blue
  [0x40, 0x54, 0x00], // brown
  [0xe0, 0x6a, 0x1a], // orange
  [0x80, 0x80, 0x80], // grey 2
  [0xff, 0x96, 0xbf], // pink
  [0x30, 0xc0, 0x1a], // light green
  [0xbf, 0xd3, 0x5a], // yellow
  [0x6f, 0xe8, 0xbf], // aquamarine
  [0xff, 0xff, 0xff], // white
]
