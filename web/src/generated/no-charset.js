// ============================================================================
//  no-charset.js -- the stand-in for the character ROM, for a public build
//
//  src/charset.js imports src/generated/charset.json, which Vite inlines, so
//  building after `npm run charset` bakes all 4096 bytes of the 2732 into the
//  bundle. That ROM is Apple copyright, and a GitHub Pages site is public the
//  moment it is published, so it must not go in one -- which is the same
//  reason roms/*.hex is gitignored.
//
//  `npm run pages` aliases that import to this file, so a published bundle has
//  no ROM in it. The app degrades to the text view of the screen and says so;
//  everything else is identical, and a local build still gets the real glyphs.
//
//  scripts/pages.mjs checks the result and fails the deploy if the ROM is in
//  there anyway, because this is exactly the kind of mistake that is invisible
//  until it is published.
// ============================================================================

export default { source: 'excluded from a published build', bytes: null }
