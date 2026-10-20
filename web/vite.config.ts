import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))

/**
 * A published build.
 *
 * `PAGES=1 npm run build` is what `npm run pages` uses, and it changes three
 * things, all of them because the site is public and served from a subpath:
 *
 *   base './'            GitHub Pages serves /docs at /<repo>/, not at /, so
 *                        absolute asset paths would 404
 *   no sourcemaps        they are 1.2 MB of noise and name source paths
 *   no character ROM     src/charset.js imports generated/charset.json, and
 *                        Vite inlines it, so a build made after `npm run
 *                        charset` carries all 4096 bytes of Apple's 2732 in
 *                        the bundle. Alias it to a stub. The app falls back to
 *                        the text view of the screen and says so.
 */
const PAGES = Boolean(process.env.PAGES)

export default defineConfig({
  plugins: [react()],
  base: PAGES ? './' : '/',
  resolve: {
    alias: PAGES
      ? [
          {
            // The exact specifier, so the leading './' is consumed with it.
            // A regex on the tail leaves './/home/...' behind.
            find: './generated/charset.json',
            replacement: resolve(HERE, 'src/generated/no-charset.js'),
          },
        ]
      : [],
  },
  server: {
    port: 5273,
  },
  build: PAGES ? { outDir: 'dist', sourcemap: false } : { outDir: 'dist', sourcemap: true },
})
