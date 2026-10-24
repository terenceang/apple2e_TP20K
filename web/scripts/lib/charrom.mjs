// ============================================================================
//  lib/charrom.mjs -- the one parser for the $readmemh character ROM dump
//
//  roms/apple2e_char.hex is a $readmemh file: one or two hex digits per line,
//  // comments allowed, anything else ignored. charset.mjs (build charset.json),
//  pages.mjs (probe the built bundle for a leaked ROM) and test/charset.test.js
//  (check the file on disk) all have to read it identically, so the parser
//  lives here.
// ============================================================================

/**
 * Parse a $readmemh hex dump into a byte array.
 * @param {string} raw
 * @returns {number[]}
 */
export function parseHexDump(raw) {
  const bytes = []
  for (const line of raw.split(/\r?\n/)) {
    const tok = line.replace(/\/\/.*$/, '').trim().split(/\s+/)[0]
    if (!tok) continue
    if (!/^[0-9a-fA-F]{1,2}$/.test(tok)) continue
    bytes.push(parseInt(tok, 16))
  }
  return bytes
}
