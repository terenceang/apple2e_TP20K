// ============================================================================
//  keymap.test.js -- the keymap is the era check
//
//  These assertions are the mechanical version of "this is a 1979-83 Apple
//  //e keyboard". If someone helpfully adds a tilde keycap in the wrong place,
//  a function key, or a Mac-style *: key, or breaks the BELL on G, one of
//  these fails.
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import { KEYS, boardBox, keysOutsideBoard } from '../src/keyboard/layouts.js'
import {
  resolve,
  isModifier,
  buttonFor,
  repertoire,
  keyIds,
  PADDLE_BUTTONS,
  hostKey,
  hostCodeFor,
  REPEAT_DELAY_MS,
  REPEAT_INTERVAL_MS,
} from '../src/keymap.js'

test('no keycap legend depends on an emoji font', () => {
  // The two apple keys were the 1F34F/1F34E emoji and rendered as blank boxes
  // on any machine without an emoji font -- a //e with two empty keys where
  // its apple keys should be. They are drawn as SVG now, by AppleGlyph.tsx.
  // Anything outside Latin-1 and the arrows would be a font gamble again.
  const risky = KEYS.filter((k) => /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(k.legend ?? ''))
  assert.deepEqual(
    risky.map((k) => `${k.id}:${k.legend}`),
    [],
    'these legends need an emoji font',
  )
})

test('the apple keys are identified for the SVG renderer', () => {
  const o = KEYS.find((k) => k.id === 'apple-o')
  const c = KEYS.find((k) => k.id === 'apple-c')
  assert.equal(o.legend, 'open')
  assert.equal(c.legend, 'solid')
  // and they are the two game buttons, at the sides of the space bar
  assert.equal(buttonFor('apple-o'), 0b001)
  assert.equal(buttonFor('apple-c'), 0b010)
  const space = KEYS.find((k) => k.id === 'space')
  const w = (k) => k.w ?? 1
  // flanking the space bar: adjacent, not overlapping
  assert.ok(o.x + w(o) <= space.x, 'Open-Apple is immediately left of SPACE')
  assert.ok(c.x >= space.x + w(space), 'Solid-Apple is immediately right of SPACE')
  assert.ok(c.x < (space.x + w(space) + 6), 'and not left stranded over on its own')
})

test('the board has the 63 keys of a //e', () => {
  assert.equal(KEYS.length, 63)
})

test('every key fits inside the key field', () => {
  // The Reset tier sits at y = -1, so the board has to be tall enough to hold
  // it. It used to be one row short, which put the whole bottom row -- CAPS
  // LOCK, both apple keys, SPACE and all four arrows -- outside the dark key
  // well, on the beige case. Caught by rendering the page, not by the tests.
  assert.deepEqual(keysOutsideBoard(), [], 'keys outside the board')
  const box = boardBox()
  assert.equal(box.height, 6, 'six rows: the Reset tier and five of keys')
  assert.equal(box.top, -1, 'the Reset tier is above the keys')
  assert.ok(box.width >= 15, 'wide enough for the RETURN key at the right')
})

test('the arrangement is a left-to-right, top-to-bottom grid with no gaps in the rows', () => {
  // Not a pixel-perfect check, just that no two keys share a slot, which would
  // silently hide one behind another.
  const slots = new Set()
  for (const k of KEYS) {
    for (let dx = 0; dx < (k.w ?? 1); dx++) {
      for (let dy = 0; dy < (k.h ?? 1); dy++) {
        const slot = `${Math.round((k.x + dx) * 2)}:${k.y + dy}`
        assert.ok(!slots.has(slot), `${k.id} overlaps another key at ${slot}`)
        slots.add(slot)
      }
    }
  }
})

test('no REPT key, no function keys, no numeric keypad, no Mac *: key', () => {
  const ids = keyIds()
  for (const gone of ['rept', 'f1', 'f13', 'numpad0', 'colon', 'star', 'cmd', 'opt']) {
    assert.ok(!ids.includes(gone), `${gone} should not be on a //e keyboard`)
  }
})

test('the //e has the keys a //e has', () => {
  const ids = new Set(keyIds())
  // modifiers and the latching switch
  for (const k of ['control', 'shift-l', 'shift-r', 'caps']) assert.ok(ids.has(k), k)
  // the two apple keys, which are the game paddles' buttons
  assert.ok(ids.has('apple-o'))
  assert.ok(ids.has('apple-c'))
  // four real cursor keys, bottom right
  for (const k of ['left', 'right', 'up', 'down']) assert.ok(ids.has(k), k)
  // RESET is recessed above the key field, and DELETE is upper right
  assert.ok(ids.has('reset'))
  assert.ok(ids.has('delete'))
  // ESC, TAB, RETURN, SPACE
  for (const k of ['esc', 'tab', 'return', 'space']) assert.ok(ids.has(k), k)
})

test('there is no third game button', () => {
  assert.equal(PADDLE_BUTTONS.length, 2)
  assert.equal(buttonFor('apple-o'), 0b001)
  assert.equal(buttonFor('apple-c'), 0b010)
})

test('letters: unshifted lowercase, shifted uppercase', () => {
  assert.equal(resolve('a'), 0x61)
  assert.equal(resolve('a', { shift: true }), 0x41)
  assert.equal(resolve('z', { shift: true }), 0x5a)
})

test('CAPS LOCK shifts letters only, and SHIFT cancels it', () => {
  assert.equal(resolve('a', { caps: true }), 0x41)
  assert.equal(resolve('a', { caps: true, shift: true }), 0x61)
  // "with the CAPS LOCK set, the 4 key will produce a 4, not the $"
  assert.equal(resolve('4', { caps: true }), 0x34)
  assert.equal(resolve('4', { caps: true, shift: true }), 0x24)
})

test('the number row shifts to its symbols', () => {
  assert.equal(resolve('1'), 0x31)
  assert.equal(resolve('1', { shift: true }), 0x21)
  assert.equal(resolve('6', { shift: true }), 0x5e) // ^
  assert.equal(resolve('minus', { shift: true }), 0x5f) // _
  assert.equal(resolve('equals', { shift: true }), 0x2b) // +
})

test('SHIFT-G is the BELL, not a tilde', () => {
  assert.equal(resolve('g'), 0x67)
  assert.equal(resolve('g', { shift: true }), 0x07)
  assert.equal(resolve('g', { ctrl: true }), 0x07)
})

test('the tilde is on its own cap with the backquote, not on G', () => {
  assert.equal(resolve('tilde'), 0x60)
  assert.equal(resolve('tilde', { shift: true }), 0x7e)
  assert.equal(resolve('backslash'), 0x5c)
  assert.equal(resolve('backslash', { shift: true }), 0x7c)
})

test('CONTROL gives 0x01-0x1A on the letters and does nothing else', () => {
  assert.equal(resolve('a', { ctrl: true }), 0x01)
  assert.equal(resolve('c', { ctrl: true }), 0x03)
  assert.equal(resolve('z', { ctrl: true }), 0x1a)
  // The II+/II+ era trick of CTRL-M for a bracket is not a //e key
  assert.equal(resolve('m', { ctrl: true }), 0x0d)
  // and CONTROL on a number or punctuation key produces nothing
  assert.equal(resolve('1', { ctrl: true }), null)
  assert.equal(resolve('slash', { ctrl: true }), null)
})

test('the named keys carry the codes the //e ROM expects', () => {
  assert.equal(resolve('return'), 0x0d)
  assert.equal(resolve('space'), 0x20)
  assert.equal(resolve('esc'), 0x1b)
  assert.equal(resolve('delete'), 0x7f)
  assert.equal(resolve('tab'), 0x09)
  assert.equal(resolve('left'), 0x08)
  assert.equal(resolve('down'), 0x0a)
  assert.equal(resolve('up'), 0x0b)
  assert.equal(resolve('right'), 0x15)
})

test('SHIFT does nothing to the keys that have only one character', () => {
  for (const k of ['return', 'space', 'esc', 'delete', 'tab', 'left', 'up']) {
    assert.equal(resolve(k, { shift: true }), resolve(k), k)
  }
})

test('modifiers produce no key code of their own', () => {
  for (const k of ['control', 'shift-l', 'shift-r', 'caps', 'apple-o', 'apple-c', 'reset']) {
    assert.ok(isModifier(k), k)
    assert.equal(resolve(k), null, k)
  }
})

test('every key on the board can type something', () => {
  for (const k of KEYS) {
    if (k.mod) continue
    let produced = false
    for (const shift of [false, true]) {
      for (const caps of [false, true]) {
        for (const ctrl of [false, true]) {
          if (resolve(k.id, { shift, caps, ctrl }) !== null) produced = true
        }
      }
    }
    assert.ok(produced, `${k.id} cannot produce any code`)
  }
})

test('the repertoire is the //e 40-column set, and no more', () => {
  const r = repertoire()
  const printable = r.filter((c) => c >= 0x20 && c <= 0x7e)

  // every printable ASCII character the //e's caps can reach
  for (const ch of ' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~') {
    assert.ok(printable.includes(ch.charCodeAt(0)), `${ch} is not reachable`)
  }

  // plus the control characters the keys and CONTROL produce
  for (const c of [0x01, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0d, 0x15, 0x1b, 0x7f]) {
    assert.ok(r.includes(c), `control $${c.toString(16).padStart(2, '0')} is not reachable`)
  }

  // and nothing that no //e key can make. The control block runs $01-$1B --
  // CONTROL on the letters gives $01-$1A, ESC is $1B -- and DEL is $7F. NUL,
  // and $1C-$1F (FS, GS, RS, US) are not on the board.
  const allowed = new Set([0x7f])
  for (let c = 0x01; c <= 0x1b; c++) allowed.add(c)
  for (const c of r) {
    if (c >= 0x20 && c <= 0x7e) continue
    assert.ok(allowed.has(c), `$${c.toString(16)} should not be reachable`)
  }
  for (const c of [0x00, 0x1c, 0x1d, 0x1e, 0x1f]) {
    assert.ok(!r.includes(c), `$${c.toString(16)} should not be reachable`)
  }
})

test('the repertoire is 95 printable + $01-$1B + DEL', () => {
  const r = repertoire()
  assert.equal(new Set(r).size, r.length, 'no duplicates')
  assert.equal(r.length, 95 + 27 + 1)
})

test('hostKey maps physical host KeyboardEvent.code positions to Apple //e keys', () => {
  // Letters
  assert.equal(hostKey('KeyA'), 'a')
  assert.equal(hostKey('KeyQ'), 'q')
  assert.equal(hostKey('KeyZ'), 'z')
  // Numbers & Symbols
  assert.equal(hostKey('Digit1'), '1')
  assert.equal(hostKey('Digit0'), '0')
  assert.equal(hostKey('Minus'), 'minus')
  assert.equal(hostKey('Equal'), 'equals')
  assert.equal(hostKey('Backquote'), 'tilde')
  // Control & Nav
  assert.equal(hostKey('Escape'), 'esc')
  assert.equal(hostKey('Enter'), 'return')
  assert.equal(hostKey('Backspace'), 'delete')
  assert.equal(hostKey('Delete'), 'delete')
  assert.equal(hostKey('ArrowLeft'), 'left')
  assert.equal(hostKey('ArrowRight'), 'right')
  assert.equal(hostKey('ArrowUp'), 'up')
  assert.equal(hostKey('ArrowDown'), 'down')
  // Modifiers: Alt maps to the two apple keys
  assert.equal(hostKey('AltLeft'), 'apple-o')
  assert.equal(hostKey('AltRight'), 'apple-c')
  assert.equal(hostKey('ShiftLeft'), 'shift-l')
  assert.equal(hostKey('ShiftRight'), 'shift-r')
  assert.equal(hostKey('ControlLeft'), 'control')
  assert.equal(hostKey('ControlRight'), 'control')
  assert.equal(hostKey('CapsLock'), 'caps')
  // Unmapped keys return null
  assert.equal(hostKey('F1'), null)
  assert.equal(hostKey('F12'), null)
  assert.equal(hostKey('Insert'), null)
  assert.equal(hostKey('UnknownKey'), null)
})

test('hostCodeFor provides reverse lookup from Apple //e key to host code', () => {
  assert.equal(hostCodeFor('a'), 'KeyA')
  assert.equal(hostCodeFor('esc'), 'Escape')
  assert.equal(hostCodeFor('apple-o'), 'AltLeft')
  assert.equal(hostCodeFor('apple-c'), 'AltRight')
  assert.equal(hostCodeFor('not-a-key'), null)
})

test('auto-repeat runs at ~10 Hz with an initial delay of ~1 second', () => {
  assert.equal(REPEAT_DELAY_MS, 1000)
  assert.equal(REPEAT_INTERVAL_MS, 100)
})
