// ============================================================================
//  config.js -- A2CONFIG.TXT, what each drive loads at power-on
//
//  One line per drive, `KEY=SHORTNAME`, the file's 8.3 name because that is
//  what the FPGA can match against a directory entry (src/sd_vol.v parses this
//  file at boot, so keep the format that plain).  Anything after `;` is a
//  comment; the page puts the long name there.
//
//    S6D1=LODERU~1.DSK ; Lode Runner.dsk
//    S6D2=
//    S7D1=TOTALR~1.HDV ; Total Replay v6.1.hdv
//    S7D2=
// ============================================================================

import { to83 } from './fat32.js'

export const CONFIG_NAME = 'A2CONFIG.TXT'
/** Drive keys in drive-number order: 1, 2 are slot 6; 3, 4 are slot 7 (the debugger's y<d>). */
export const DRIVES = ['S6D1', 'S6D2', 'S7D1', 'S7D2']

/** @returns {Record<string, string | null>} 8.3 name ("GAME.DSK") per drive key, null = empty */
export function parseConfig(text) {
  const cfg = Object.fromEntries(DRIVES.map((k) => [k, null]))
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.replace(/;.*/, '').trim()
    if (!line) return
    const m = /^(S[67]D[12])\s*=\s*(\S*)$/i.exec(line)
    if (!m) throw new Error(`${CONFIG_NAME} line ${i + 1} is not KEY=NAME: "${raw}"`)
    const name = m[2].toUpperCase()
    if (name && !to83(name)) throw new Error(`${CONFIG_NAME} line ${i + 1}: "${m[2]}" is not an 8.3 name`)
    cfg[m[1].toUpperCase()] = name || null
  })
  return cfg
}

/**
 * @param {Record<string, string | null>} cfg  8.3 name per drive key
 * @param {Record<string, string>} [longNames] comment per drive key
 */
export function formatConfig(cfg, longNames = {}) {
  return DRIVES.map((k) => {
    const v = cfg[k] ?? ''
    const note = v && longNames[k] && longNames[k].toUpperCase() !== v ? ` ; ${longNames[k]}` : ''
    return `${k}=${v}${note}\r\n`
  }).join('')
}
