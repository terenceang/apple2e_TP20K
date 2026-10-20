// ============================================================================
//  prefs.js -- persistent UI view preferences & status formatting
//
//  Plain JS with JSDoc so `node --test` can test this directly without browser.
// ============================================================================

import { BAUD } from './serial-link.js'

export const PREF_CONSOLE = 'a2e.showConsole'
export const PREF_DEBUGGER = 'a2e.showDebugger'
export const PREF_SCREEN = 'a2e.showScreen'
export const PREF_PADDLES = 'a2e.showPaddles'
export const PREF_DISKS = 'a2e.showDisks'
export const PREF_AUTOCONNECT = 'a2e.autoConnect'
export const PREF_SCREEN_PALETTE = 'a2e.screenPalette'
export const PREF_SCREEN_SCANLINES = 'a2e.screenScanlines'
export const PREF_SCREEN_AUTOREFRESH = 'a2e.screenAutoRefresh'

/**
 * Read a boolean setting from localStorage with a fallback default.
 * Safe against storage access errors (e.g. private browsing mode).
 *
 * @param {Storage|null} [store]
 * @param {string} key
 * @param {boolean} [defaultValue]
 * @returns {boolean}
 */
export function getSavedBool(store, key, defaultValue = false) {
  if (!store) return defaultValue
  try {
    const v = store.getItem(key)
    return v !== null ? v === 'true' : defaultValue
  } catch {
    return defaultValue
  }
}

/**
 * Save a boolean setting to localStorage.
 * Safe against storage write errors.
 *
 * @param {Storage|null} [store]
 * @param {string} key
 * @param {boolean} value
 */
export function setSavedBool(store, key, value) {
  if (!store) return
  try {
    store.setItem(key, String(value))
  } catch {
    /* ignore write failures */
  }
}

/**
 * Read a string setting from localStorage with a fallback default.
 *
 * @param {Storage|null} [store]
 * @param {string} key
 * @param {string} [defaultValue]
 * @returns {string}
 */
export function getSavedString(store, key, defaultValue = '') {
  if (!store) return defaultValue
  try {
    const v = store.getItem(key)
    return v !== null ? v : defaultValue
  } catch {
    return defaultValue
  }
}

/**
 * Save a string setting to localStorage.
 *
 * @param {Storage|null} [store]
 * @param {string} key
 * @param {string} value
 */
export function setSavedString(store, key, value) {
  if (!store) return
  try {
    store.setItem(key, String(value))
  } catch {
    /* ignore write failures */
  }
}

/**
 * Format connection state into human-readable text for the UI.
 *
 * @param {{ state?: string, detail?: string|null, error?: string|null }|null} [conn]
 * @param {number} [baud]
 * @returns {string}
 */
export function formatConnState(conn, baud = BAUD) {
  if (!conn) return 'not connected'
  switch (conn.state) {
    case 'idle':
      return 'not connected'
    case 'opening':
      return 'opening the USB port...'
    case 'open-unchecked':
      return 'port open, checking that this is the //e...'
    case 'probing':
      return 'asking the //e who is there...'
    case 'open':
      return conn.detail ? `connected to ${conn.detail}` : `connected at ${baud}`
    case 'wrong-port':
      return conn.detail || 'that is the wrong USB channel -- pick the other one'
    case 'error':
      return conn.error ?? conn.detail ?? 'error'
    default:
      return ''
  }
}

const diskKey = (n) => `a2e.disk${n}`

/** What this page last loaded into Disk II drive n: { filename, sum } or null. */
export function loadDisk(store, n) {
  try {
    const v = JSON.parse(store?.getItem(diskKey(n)) ?? 'null')
    return v && typeof v.filename === 'string' && Number.isInteger(v.sum) ? v : null
  } catch {
    return null
  }
}

export function saveDisk(store, n, value) {
  try {
    store?.setItem(diskKey(n), JSON.stringify(value))
  } catch {
    /* storage is a convenience, never a requirement */
  }
}
