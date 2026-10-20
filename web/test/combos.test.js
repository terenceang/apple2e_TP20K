// Smoke test: the special key combos, from host key to bytes on the wire.
import test from 'node:test'
import assert from 'node:assert/strict'
import { resolve, buttonFor, hostKey, isModifier } from '../src/keymap.js'
import { encodeKey, CTRL_B } from '../src/protocol.js'

const wire = (id, mods = {}, held = []) =>
  [...encodeKey(resolve(id, mods), held.reduce((b, k) => b | buttonFor(k), 0))]

test('Open/Solid-Apple ride along as paddle buttons on any key', () => {
  assert.deepEqual(wire('a', {}, ['apple-o']), [0xfe, 0x61, 0b001])
  assert.deepEqual(wire('a', {}, ['apple-c']), [0xfe, 0x61, 0b010])
  assert.deepEqual(wire('a', {}, ['apple-o', 'apple-c']), [0xfe, 0x61, 0b011])
})

test('Ctrl combos the //e ROM cares about', () => {
  assert.deepEqual(wire('c', { ctrl: true }), [0xfe, 0x03, 0]) // Ctrl-C
  assert.deepEqual(wire('g', { ctrl: true }), [0xfe, 0x07, 0]) // bell
  assert.deepEqual(wire('x', { ctrl: true }), [0xfe, 0x18, 0]) // cancel line
  assert.deepEqual(wire('l', { ctrl: true }), [0xfe, 0x0c, 0]) // Ctrl-L
  assert.deepEqual(wire('esc', {}), [0xfe, 0x1b, 0])
})

test('Ctrl+Open-Apple (the 80-col/self-test keys) sends the ctrl code with PB0', () => {
  assert.deepEqual(wire('a', { ctrl: true }, ['apple-o']), [0xfe, 0x01, 0b001])
})

test('Ctrl+B is the debugger toggle, not a keystroke', () => {
  assert.equal(CTRL_B, 0x02)
  assert.notEqual(resolve('b', { ctrl: true }), CTRL_B === 0x02 ? null : 0) // it resolves; App/Keyboard intercept it
})

test('RESET (and Ctrl+RESET, Ctrl+Apple+RESET) put nothing on the wire', () => {
  assert.ok(isModifier('reset'))
  assert.equal(resolve('reset'), null)
  assert.equal(resolve('reset', { ctrl: true }), null)
  assert.equal(hostKey('F5'), null) // no host key is mapped to RESET
})

test('Ctrl+RESET packets: FF 03 <b>, bit 3 = held, apple buttons ride along', async () => {
  const { encodeReset } = await import('../src/protocol.js')
  assert.deepEqual([...encodeReset(true)], [0xff, 0x03, 0x08])
  assert.deepEqual([...encodeReset(true, 0b011)], [0xff, 0x03, 0x0b]) // Ctrl+Open+Solid+RESET
  assert.deepEqual([...encodeReset(false, 0b001)], [0xff, 0x03, 0x01])
  assert.equal(hostKey('End'), 'reset')
})
