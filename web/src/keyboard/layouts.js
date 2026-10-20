// ============================================================================
//  layouts.js -- the physical Apple //e keyboard, as data
//
//  Apple //e, US layout, the 1983-86 beige case with the large white keycap
//  print (part 350-0071, the keyboard that shipped with the first //e and the
//  //e Enhanced). 63 keys. Not the 1984 dark-keycap revision, and not the 1987
//  Platinum, which has 81 keys, a numeric keypad, Reset above ESC, and
//  Command/Option where the apple keys are.
//
//  Positions are in keycap units, 1 = one keycap wide, and are only there to
//  draw the thing. What each key *does* is in keymap.js, and that is the part
//  the coverage test pins down.
//
//  Where the two machine-readable sources disagree -- a photo is what settles
//  it -- the arrangement here is a data change, not a code change. The set of
//  keys and their codes is not in doubt; see the notes at the bottom.
// ============================================================================

/**
 * @typedef {object} Key
 * @property {string} id        stable name, used as the React key
 * @property {number} x         keycap units from the left of the board
 * @property {number} y         keycap units down (0 is the number row)
 * @property {number} [w]       width in units, default 1
 * @property {number} [h]       height in units, default 1
 * @property {string} [legend]  the text on the cap
 * @property {string} [sub]     the lower legend, for the number row
 * @property {boolean} [mod]    a modifier: sends no key code of its own
 * @property {boolean} [latch]  a latching switch, not held
 */

/** @type {Key[]} */
export const KEYS = [
  // --- number row -------------------------------------------------------
  { id: 'esc', x: 0, y: 0, legend: 'ESC' },
  { id: '1', x: 1, y: 0, legend: '!', sub: '1' },
  { id: '2', x: 2, y: 0, legend: '@', sub: '2' },
  { id: '3', x: 3, y: 0, legend: '#', sub: '3' },
  { id: '4', x: 4, y: 0, legend: '$', sub: '4' },
  { id: '5', x: 5, y: 0, legend: '%', sub: '5' },
  { id: '6', x: 6, y: 0, legend: '^', sub: '6' },
  { id: '7', x: 7, y: 0, legend: '&', sub: '7' },
  { id: '8', x: 8, y: 0, legend: '*', sub: '8' },
  { id: '9', x: 9, y: 0, legend: '(', sub: '9' },
  { id: '0', x: 10, y: 0, legend: ')', sub: '0' },
  { id: 'minus', x: 11, y: 0, legend: '_', sub: '-' },
  { id: 'equals', x: 12, y: 0, legend: '+', sub: '=' },
  // ` and ~ share a cap on the US //e. On the ISO layouts this key carries |
  // and \ instead, which is the swap MAME's Apple IIe driver documents.
  { id: 'tilde', x: 13, y: 0, legend: '~', sub: '`' },
  { id: 'delete', x: 14.5, y: 0, legend: 'DELETE' },

  // --- top letter row ---------------------------------------------------
  { id: 'tab', x: 0, y: 1, w: 1.5, legend: 'TAB' },
  { id: 'q', x: 1.5, y: 1, legend: 'Q' },
  { id: 'w', x: 2.5, y: 1, legend: 'W' },
  { id: 'e', x: 3.5, y: 1, legend: 'E' },
  { id: 'r', x: 4.5, y: 1, legend: 'R' },
  { id: 't', x: 5.5, y: 1, legend: 'T' },
  { id: 'y', x: 6.5, y: 1, legend: 'Y' },
  { id: 'u', x: 7.5, y: 1, legend: 'U' },
  { id: 'i', x: 8.5, y: 1, legend: 'I' },
  { id: 'o', x: 9.5, y: 1, legend: 'O' },
  { id: 'p', x: 10.5, y: 1, legend: 'P' },
  { id: 'lbracket', x: 11.5, y: 1, legend: '{', sub: '[' },
  { id: 'rbracket', x: 12.5, y: 1, legend: '}', sub: ']' },
  { id: 'backslash', x: 13.5, y: 1, legend: '|', sub: '\\' },
  { id: 'return', x: 14.5, y: 1, w: 1.5, h: 2, legend: 'RETURN' },

  // --- home row ---------------------------------------------------------
  { id: 'control', x: 0, y: 2, w: 1.75, legend: 'CONTROL', mod: true },
  { id: 'a', x: 1.75, y: 2, legend: 'A' },
  { id: 's', x: 2.75, y: 2, legend: 'S' },
  { id: 'd', x: 3.75, y: 2, legend: 'D' },
  { id: 'f', x: 4.75, y: 2, legend: 'F' },
  { id: 'g', x: 5.75, y: 2, legend: 'G' },
  { id: 'h', x: 6.75, y: 2, legend: 'H' },
  { id: 'j', x: 7.75, y: 2, legend: 'J' },
  { id: 'k', x: 8.75, y: 2, legend: 'K' },
  { id: 'l', x: 9.75, y: 2, legend: 'L' },
  { id: 'semicolon', x: 10.75, y: 2, legend: ':', sub: ';' },
  { id: 'quote', x: 11.75, y: 2, legend: '"', sub: "'" },
  // (the 1.75u gap before RETURN is real: this row is shorter than the one
  //  above it because CONTROL is wider than TAB)

  // --- bottom letter row ------------------------------------------------
  { id: 'shift-l', x: 0, y: 3, w: 2.25, legend: 'SHIFT', mod: true },
  { id: 'z', x: 2.25, y: 3, legend: 'Z' },
  { id: 'x', x: 3.25, y: 3, legend: 'X' },
  { id: 'c', x: 4.25, y: 3, legend: 'C' },
  { id: 'v', x: 5.25, y: 3, legend: 'V' },
  { id: 'b', x: 6.25, y: 3, legend: 'B' },
  { id: 'n', x: 7.25, y: 3, legend: 'N' },
  { id: 'm', x: 8.25, y: 3, legend: 'M' },
  { id: 'comma', x: 9.25, y: 3, legend: '<', sub: ',' },
  { id: 'period', x: 10.25, y: 3, legend: '>', sub: '.' },
  { id: 'slash', x: 11.25, y: 3, legend: '?', sub: '/' },
  { id: 'shift-r', x: 12.25, y: 3, w: 2.25, legend: 'SHIFT', mod: true },

  // --- bottom row -------------------------------------------------------
  // Caps Lock is a latching switch at the bottom left, directly below the left
  // SHIFT: "the lock key below Shift", and "press the CAPS LOCK key until it
  // clicks into its down (on) position".
  { id: 'caps', x: 0, y: 4, w: 1.25, legend: '⇩', mod: true, latch: true },
  // The two apple keys are the game paddles' pushbuttons, wired that way in
  // hardware: OPEN-APPLE is hand-control 0, SOLID-APPLE is hand-control 1.
  // Their legends are drawn by components/AppleGlyph.tsx rather than put here:
  // as emoji they render as blank boxes on any machine without an emoji font,
  // and a //e with two blank keys where the apples should be is worse than a
  // drawn one. 'open' and 'solid' are what the renderer looks for.
  { id: 'apple-o', x: 1.25, y: 4, legend: 'open', mod: true },
  { id: 'space', x: 2.25, y: 4, w: 7.5, legend: '' },
  { id: 'apple-c', x: 9.75, y: 4, legend: 'solid', mod: true },
  { id: 'left', x: 10.75, y: 4, legend: '←' },
  { id: 'right', x: 11.75, y: 4, legend: '→' },
  { id: 'down', x: 12.75, y: 4, legend: '↓' },
  { id: 'up', x: 13.75, y: 4, legend: '↑' },

  // --- recessed, above and right of the key field -----------------------
  // "The RESET key is recessed and located above and to the right of the main
  // keyboard. It will not work unless it is pressed together with the
  // CONTROL key."
  { id: 'reset', x: 14.5, y: -1, w: 1.5, legend: 'RESET', mod: true },
]

/** Board width in keycap units, for scaling. */
export const BOARD_W = 16.5
/** Board height in keycap units, including the Reset tier at y = -1. */
export const BOARD_H = 6

/**
 * The key field's extent, in keycap units, derived from the keys themselves
 * rather than declared separately -- so a key placed outside the board is a
 * layout mistake this reports instead of one that only shows up as a cap
 * sitting on the beige case instead of in the dark well.
 *
 * `top` is the y of the first row, which is -1 because RESET is on its own
 * recessed tier above the keys. The renderer offsets by it, so the height here
 * counts the Reset row too.
 */
export function boardBox(keys = KEYS) {
  let right = 0
  let bottom = -Infinity
  let top = Infinity
  for (const k of keys) {
    right = Math.max(right, k.x + (k.w ?? 1))
    top = Math.min(top, k.y)
    bottom = Math.max(bottom, k.y + (k.h ?? 1))
  }
  // BOARD_W and BOARD_H are floors: the keys are the source of truth, and these
  // stop the well shrinking if a key is ever removed from an edge.
  return {
    width: Math.max(right, BOARD_W),
    height: Math.max(bottom - top, BOARD_H),
    top,
  }
}

/** Any key that would not fit inside the board, by id. */
export function keysOutsideBoard(keys = KEYS) {
  const box = boardBox(keys)
  return keys
    .filter(
      (k) =>
        k.x < 0 ||
        k.y < box.top ||
        k.y + (k.h ?? 1) > box.top + box.height + 0.01 ||
        k.x + (k.w ?? 1) > box.width + 0.01,
    )
    .map((k) => k.id)
}

/**
 * What this layout deliberately does not have, so nobody helpfully adds it:
 *
 *   REPT        the //e dropped it; every key auto-repeats instead
 *   F1..F15     no function keys
 *   a numpad    that is the 1987 Platinum, and the Apple Keyboard Numeric
 *               Keypad accessory, which is a separate device
 *   ⌘ and ⌥    those replace the apple keys on the Platinum
 *   *:          that is a Macintosh key
 *   ESC/arrows  the //e has real arrow keys, at the bottom right
 *
 * And the codes with no cap: `` ` `` and ~ share one, | and \ share another,
 * and the //e's keyboard PROM can produce all four.
 */

// ---------------------------------------------------------------------------
//  Legends that need a word rather than a glyph. The G key is captioned BELL
//  on the //e and SHIFT-G rings the speaker instead of typing anything:
//  "The G key has the word BELL on it, but pressing Shift/G does not put BELL
//  on the screen. Instead, it produces a beep."
// ---------------------------------------------------------------------------

export const CAPTION = { g: 'BELL' }
