// ============================================================================
//  views.test.js -- UI view preferences and connection state text
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import {
  PREF_CONSOLE,
  PREF_DEBUGGER,
  PREF_SCREEN,
  PREF_PADDLES,
  getSavedBool,
  setSavedBool,
  getSavedString,
  setSavedString,
  formatConnState,
} from '../src/prefs.js'

function fakeStore() {
  const m = new Map()
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
  }
}

test('formatConnState produces human-readable strings for every connection state', () => {
  assert.equal(formatConnState(null), 'not connected')
  assert.equal(formatConnState({ state: 'idle' }), 'not connected')
  assert.equal(formatConnState({ state: 'opening' }), 'opening the USB port...')
  assert.equal(formatConnState({ state: 'open-unchecked' }), 'port open, checking that this is the //e...')
  assert.equal(formatConnState({ state: 'probing' }), 'asking the //e who is there...')
  assert.equal(formatConnState({ state: 'open', detail: 'FT2232C Channel B' }), 'connected to FT2232C Channel B')
  assert.equal(formatConnState({ state: 'open', detail: null }, 115200), 'connected at 115200')
  assert.equal(formatConnState({ state: 'wrong-port' }), 'that is the wrong USB channel -- pick the other one')
  assert.equal(formatConnState({ state: 'error', detail: 'Device disconnected' }), 'Device disconnected')
  assert.equal(formatConnState({ state: 'error', error: 'Port access denied' }), 'Port access denied')
})

test('view preferences default to false (hidden) when not set', () => {
  const store = fakeStore()
  assert.equal(getSavedBool(store, PREF_CONSOLE, false), false)
  assert.equal(getSavedBool(store, PREF_DEBUGGER, false), false)
  assert.equal(getSavedBool(null, PREF_CONSOLE, false), false)
})

test('view preferences persist when set', () => {
  const store = fakeStore()
  setSavedBool(store, PREF_CONSOLE, true)
  assert.equal(getSavedBool(store, PREF_CONSOLE, false), true)

  setSavedBool(store, PREF_CONSOLE, false)
  assert.equal(getSavedBool(store, PREF_CONSOLE, false), false)

  setSavedBool(store, PREF_DEBUGGER, true)
  assert.equal(getSavedBool(store, PREF_DEBUGGER, false), true)

  setSavedBool(store, PREF_SCREEN, true)
  assert.equal(getSavedBool(store, PREF_SCREEN, false), true)

  setSavedBool(store, PREF_PADDLES, false)
  assert.equal(getSavedBool(store, PREF_PADDLES, true), false)
})

test('string preferences save and retrieve correctly', () => {
  const store = fakeStore()
  assert.equal(getSavedString(store, 'test.key', 'defaultVal'), 'defaultVal')
  setSavedString(store, 'test.key', 'amber')
  assert.equal(getSavedString(store, 'test.key', 'defaultVal'), 'amber')
  assert.equal(getSavedString(null, 'test.key', 'fallback'), 'fallback')
})

test('storage exceptions do not throw and fall back to default', () => {
  const hostileStore = {
    getItem() {
      throw new Error('access denied')
    },
    setItem() {
      throw new Error('quota exceeded')
    },
  }
  assert.doesNotThrow(() => {
    assert.equal(getSavedBool(hostileStore, PREF_CONSOLE, false), false)
    assert.equal(getSavedBool(hostileStore, PREF_CONSOLE, true), true)
    setSavedBool(hostileStore, PREF_CONSOLE, true)
  })
})
