// ============================================================================
//  keymap.js -- what each //e key produces
//
//  The code in $C000 is the *final* character, not a key position. That is
//  because the real //e puts a PROM on the motherboard (341-0132-D US,
//  342-03xx-A Enhanced) which takes a matrix position plus the SHIFT, CAPS
//  LOCK and CONTROL lines and emits the character; the ROMs then take D6-D0 as
//  final. So the shift and caps-lock logic lives here, where a UI keyboard
//  belongs, and the FPGA stays a dumb latch.
//
//  The Apple II ASCII repertoire and what each key does come from TIL-01298
//  ("Apple II, II+, IIe, IIc: ASCII characters, values & keystrokes"). Two
//  details that are easy to get wrong and are not negotiable:
//
//    * SHIFT-G is the BELL, not a tilde. The G cap says BELL, and the shift
//      character is 0x07. Pressing it rings the speaker.
//    * SHIFT/CTRL do nothing to the number and punctuation keys on the //e,
//      and CONTROL only does something for the letters (0x01-0x1A) and G. The
//      whole SHIFT-M-is-a-bracket business is Apple II/II+; the //e gave those
//      keys real caps.
//
//  Plain JS with JSDoc so `node --test` can check this exact code.
// ============================================================================

import { KEYS } from './keyboard/layouts.js'

// --- the codes --------------------------------------------------------------

/** Final 7-bit code, unshifted and shifted, for every key that types. */
const CODES = {
  esc: [0x1b, null],
  '1': [0x31, 0x21],
  '2': [0x32, 0x40],
  '3': [0x33, 0x23],
  '4': [0x34, 0x24],
  '5': [0x35, 0x25],
  '6': [0x36, 0x5e],
  '7': [0x37, 0x26],
  '8': [0x38, 0x2a],
  '9': [0x39, 0x28],
  '0': [0x30, 0x29],
  minus: [0x2d, 0x5f],
  equals: [0x3d, 0x2b],
  tilde: [0x60, 0x7e],
  delete: [0x7f, null],
  tab: [0x09, null],
  return: [0x0d, null],
  semicolon: [0x3b, 0x3a],
  quote: [0x27, 0x22],
  z: [0x7a, 0x5a],
  x: [0x78, 0x58],
  c: [0x63, 0x43],
  v: [0x76, 0x56],
  b: [0x62, 0x42],
  n: [0x6e, 0x4e],
  m: [0x6d, 0x4d],
  comma: [0x2c, 0x3c],
  period: [0x2e, 0x3e],
  slash: [0x2f, 0x3f],
  lbracket: [0x5b, 0x7b],
  rbracket: [0x5d, 0x7d],
  backslash: [0x5c, 0x7c],
  space: [0x20, null],
  // The four cursor keys. On the //e these are real keys at the bottom right;
  // they set the ROM's escape mode, and these are the codes the ROM expects.
  left: [0x08, null],
  right: [0x15, null],
  down: [0x0a, null],
  up: [0x0b, null],
}

// G is special: the cap says BELL and its shift character is 0x07.
CODES.g = [0x67, 0x07]

// Letters, generated rather than written out.
for (let c = 0x41; c <= 0x5a; c++) {
  const id = String.fromCharCode(c).toLowerCase()
  CODES[id] = [c | 0x20, c]
}

/** Keys that press a game button instead of typing. Open-Apple is hand-control
 *  0 and Solid-Apple is hand-control 1, which is literally how they are wired
 *  on the //e. */
export const APPLE_BUTTON = { 'apple-o': 0b001, 'apple-c': 0b010 }

/** Keys that do nothing on their own. */
const MODIFIERS = new Set([
  'control',
  'shift-l',
  'shift-r',
  'caps',
  'apple-o',
  'apple-c',
  'reset',
])

export function isModifier(id) {
  return MODIFIERS.has(id)
}

export function isLetter(id) {
  return typeof CODES[id]?.[0] === 'number' && id.length === 1 && id >= 'a' && id <= 'z'
}

/**
 * The 7-bit code a keypress should put in $C000, or null if the key does not
 * type anything by itself.
 *
 * @param {string} id        a key id from layouts.js
 * @param {{shift?: boolean, caps?: boolean, ctrl?: boolean}} [mods]
 * @returns {number|null}
 */
export function resolve(id, mods = {}) {
  const entry = CODES[id]
  if (!entry) return null
  const [base, shifted] = entry
  const { shift = false, caps = false, ctrl = false } = mods

  // CONTROL is only meaningful on the letters, where it gives 0x01-0x1A, and
  // on G, where it is the bell. Everything else the //e ignores it.
  if (ctrl) {
    if (id === 'g') return 0x07
    if (isLetter(id)) return base & 0x1f
    return null
  }

  if (isLetter(id)) {
    // The G cap says BELL and its shift character is the bell, not a tilde.
    // This is the one letter where shift does not produce uppercase.
    if (id === 'g' && shift) return 0x07
    // CAPS LOCK shifts letters only -- "with the CAPS LOCK set, the 4 key will
    // produce a 4, not the $" -- and shift cancels it, as on a typewriter.
    const upper = shift !== caps
    return upper ? base & 0xdf : base
  }

  // The number and punctuation keys are not affected by CAPS LOCK.
  if (shift && shifted !== null) return shifted
  return base
}

/** The paddle button bit for a key, or 0. */
export function buttonFor(id) {
  return APPLE_BUTTON[id] ?? 0
}

// ---------------------------------------------------------------------------
//  Host keyboard
//
//  Mapped by physical position (KeyboardEvent.code) rather than by
//  event.key, so a Dvorak or AZERTY user still gets the //e's QWERTY layout,
//  the way a real //e behaves.
// ---------------------------------------------------------------------------

export const HOST_MAP = {
  Escape: 'esc',
  Digit1: '1',
  Digit2: '2',
  Digit3: '3',
  Digit4: '4',
  Digit5: '5',
  Digit6: '6',
  Digit7: '7',
  Digit8: '8',
  Digit9: '9',
  Digit0: '0',
  Minus: 'minus',
  Equal: 'equals',
  Backquote: 'tilde',
  Backslash: 'backslash',
  BracketLeft: 'lbracket',
  BracketRight: 'rbracket',
  Semicolon: 'semicolon',
  Quote: 'quote',
  Comma: 'comma',
  Period: 'period',
  Slash: 'slash',
  Enter: 'return',
  Space: 'space',
  Tab: 'tab',
  Delete: 'delete',
  Backspace: 'delete',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  ArrowDown: 'down',
  ArrowUp: 'up',
  ShiftLeft: 'shift-l',
  ShiftRight: 'shift-r',
  ControlLeft: 'control',
  ControlRight: 'control',
  CapsLock: 'caps',
  // RESET is recessed above the keys on a //e; End is the nearest host key.
  End: 'reset',
  // Alt stands in for the apple keys, which are modifiers on a real //e.
  AltLeft: 'apple-o',
  AltRight: 'apple-c',
}

for (const c of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') HOST_MAP['Key' + c] = c.toLowerCase()

/** Reverse map, for highlighting the virtual caps when the host key is down. */
export const HOST_REVERSE = (() => {
  /** @type {Record<string,string[]>} */
  const m = {}
  for (const [code, id] of Object.entries(HOST_MAP)) (m[id] ??= []).push(code)
  return m
})()

/** The //e key a host KeyboardEvent.code is, or null if it is not a //e key. */
export function hostKey(code) {
  return Object.prototype.hasOwnProperty.call(HOST_MAP, code) ? HOST_MAP[code] : null
}

/** A host key code for a //e key id, for synthesising the repeat events. */
export function hostCodeFor(id) {
  const codes = HOST_REVERSE[id]
  return codes ? codes[0] : null
}

// ---------------------------------------------------------------------------
//  Repertoire, for the coverage test
// ---------------------------------------------------------------------------

/** Every code the 63-key board can produce, as a sorted list of numbers. */
export function repertoire() {
  /** @type {Set<number>} */
  const out = new Set()
  for (const k of KEYS) {
    if (k.mod) continue
    for (const shift of [false, true]) {
      for (const caps of [false, true]) {
        for (const ctrl of [false, true]) {
          const v = resolve(k.id, { shift, caps, ctrl })
          if (v !== null) out.add(v)
        }
      }
    }
  }
  return [...out].sort((a, b) => a - b)
}

/** The keys that are on the board, for tests that care about the count. */
export function keyIds() {
  return KEYS.map((k) => k.id)
}

// ---------------------------------------------------------------------------
//  Auto-repeat
//
//  The //e dropped the REPT key: "all the printing-character keys repeat
//  automatically if you hold the keys down for more than a second". So no
//  repeat delay short enough to feel instant, and a steady ~10 Hz once it
//  starts, which is the rate the real hardware repeats at.
// ---------------------------------------------------------------------------

export const REPEAT_DELAY_MS = 1000
export const REPEAT_INTERVAL_MS = 100

/** The //e's two game buttons, and only two. There is no third pushbutton on
 *  the keyboard; $C063 exists in the RTL and stays unused by this UI. */
export const PADDLE_BUTTONS = [
  // No emoji in the labels either: see components/AppleGlyph.tsx.
  { key: 'apple-o', label: 'Open-Apple', bit: APPLE_BUTTON['apple-o'], which: 'paddle 0' },
  { key: 'apple-c', label: 'Solid-Apple', bit: APPLE_BUTTON['apple-c'], which: 'paddle 1' },
]

/** The paddle-button bits of every PADDLE_BUTTONS key held down. */
export function paddleButtonBits(held) {
  return PADDLE_BUTTONS.reduce((bits, b) => (held[b.key === 'apple-o' ? 'appleO' : 'appleC'] ? bits | b.bit : bits), 0)
}

/**
 * Ctrl+B belongs to the debugger, not the //e: the firmware drops 0x02 before
 * the keyboard sees it, and App toggles the debugger pane with it. One
 * predicate, because App's listener and Keyboard's listener must agree.
 */
export function isDebuggerToggle(e) {
  return e.ctrlKey && !e.shiftKey && !e.altKey && e.code === 'KeyB'
}
