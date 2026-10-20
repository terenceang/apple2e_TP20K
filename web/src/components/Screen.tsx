import { useEffect, useMemo, useRef, useState, useCallback } from 'react'
import { AppleStream, screenToText } from '../stream.js'
import { dotRow, HAS_GLYPHS, GLYPH_W, GLYPH_H } from '../charset.js'
import { LORES_PALETTE, SCR_COLS, SCR_TEXT_ROWS, SCR_GFX_ROWS, SCR_GFX_ROW_BYTES } from '../protocol.js'
import {
  PREF_SCREEN_PALETTE,
  PREF_SCREEN_SCANLINES,
  PREF_SCREEN_AUTOREFRESH,
  getSavedString,
  setSavedString,
  getSavedBool,
  setSavedBool,
} from '../prefs.js'
import type { Screen as ScreenFrame } from '../useApple'

const SCALE = 2 // the Apple II raster is 560x384; double it
const FLASH_MS = 620 // video_generator.v's flash_clk is about 1.6 Hz
const LORES_BLOCK_W = 14 // a lo-res block is one 14-pixel character cell wide

const rgb = (c: number[]) => `rgb(${c[0]},${c[1]},${c[2]})`
// Precompute lo-res palette RGB strings once to avoid dynamic allocations during rendering.
const LORES_PALETTE_RGB = LORES_PALETTE.map(rgb)

export type PhosphorTheme = 'green' | 'amber' | 'white'

const PALETTES: Record<PhosphorTheme, { on: number[]; off: number[]; label: string; dot: string }> = {
  // green.on/off are video_generator.v's text phosphor; the other themes are
  // this pane's own cosmetic choices.
  green: {
    on: [0x20, 0xe8, 0x20],
    off: [0x02, 0x06, 0x02],
    label: 'Green',
    dot: '#20e820',
  },
  amber: {
    on: [0xff, 0xb0, 0x00],
    off: [0x14, 0x0a, 0x00],
    label: 'Amber',
    dot: '#ffb000',
  },
  white: {
    on: [0xee, 0xee, 0xee],
    off: [0x08, 0x08, 0x08],
    label: 'B&W',
    dot: '#eeeeee',
  },
}

interface Props {
  screen: ScreenFrame | null
  onCapture: () => void
  busy: boolean
  onClose?: () => void
}

/**
 * The //e text page, redrawn in the browser from the W screen dump.
 *
 * The dump is only readable while the CPU is paused, so this is on demand:
 * Freeze & capture pauses, dumps, and lets the machine run again. The glyphs
 * come from the same 2732 ROM the FPGA reads, addressed with the same
 * expression video_generator.v uses, so this is the same picture the monitor
 * over HDMI is showing.
 */
export function Screen({ screen, onCapture, busy, onClose }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const [flash, setFlash] = useState(false)

  const store = typeof localStorage !== 'undefined' ? localStorage : null

  // Persistent Display Options
  const [palette, setPaletteState] = useState<PhosphorTheme>(() => {
    const saved = getSavedString(store, PREF_SCREEN_PALETTE, 'green')
    return saved === 'amber' || saved === 'white' ? saved : 'green'
  })
  const [scanlines, setScanlinesState] = useState(() =>
    getSavedBool(store, PREF_SCREEN_SCANLINES, false),
  )
  const [autoRefresh, setAutoRefreshState] = useState<number>(() => {
    const v = Number(getSavedString(store, PREF_SCREEN_AUTOREFRESH, '0'))
    return isNaN(v) ? 0 : v
  })
  const [showOptions, setShowOptions] = useState(false)

  const setPalette = useCallback(
    (p: PhosphorTheme) => {
      setPaletteState(p)
      setSavedString(store, PREF_SCREEN_PALETTE, p)
    },
    [store],
  )

  const setScanlines = useCallback(
    (s: boolean | ((prev: boolean) => boolean)) => {
      setScanlinesState((prev) => {
        const next = typeof s === 'function' ? s(prev) : s
        setSavedBool(store, PREF_SCREEN_SCANLINES, next)
        return next
      })
    },
    [store],
  )

  const setAutoRefresh = useCallback(
    (sec: number) => {
      setAutoRefreshState(sec)
      setSavedString(store, PREF_SCREEN_AUTOREFRESH, String(sec))
    },
    [store],
  )

  // Auto-refresh timer
  useEffect(() => {
    if (autoRefresh <= 0) return
    const interval = setInterval(() => {
      if (!busy) onCapture()
    }, autoRefresh * 1000)
    return () => clearInterval(interval)
  }, [autoRefresh, busy, onCapture])

  useEffect(() => {
    const t = setInterval(() => setFlash((f) => !f), FLASH_MS)
    return () => clearInterval(t)
  }, [])

  const cells = useMemo(
    () => (screen ? AppleStream.cells(screen.page) : null),
    [screen],
  )
  const text = useMemo(() => (screen ? screenToText(screen.page) : []), [screen])

  const curPal = PALETTES[palette] || PALETTES.green

  useEffect(() => {
    const cv = canvas.current
    const ctx = cv?.getContext('2d')
    if (!cv || !ctx || !screen || !cells) return

    const targetW = SCR_COLS * GLYPH_W * SCALE
    const targetH = SCR_TEXT_ROWS * GLYPH_H * SCALE

    // BOLT OPTIMIZATION: Avoid resetting canvas backing buffer unless dimensions change.
    // Setting cv.width / cv.height reallocates the canvas bitmap buffer.
    if (cv.width !== targetW) cv.width = targetW
    if (cv.height !== targetH) cv.height = targetH

    ctx.imageSmoothingEnabled = false
    ctx.fillStyle = 'rgb(0,0,0)'
    ctx.fillRect(0, 0, cv.width, cv.height)

    // BOLT OPTIMIZATION: Precompute RGB color strings for the active phosphor theme
    // outside the 960-cell rendering loop to eliminate ~1,920 redundant string allocations per frame.
    const onRgb = rgb(curPal.on)
    const offRgb = rgb(curPal.off)

    // The bottom four lines are lo-res graphics in mixed mode, which is where
    // the //e ROM normally leaves them. video_generator.v decides it the same
    // way: is_text_line = text_mode || (mixed_mode && text_row >= 20).
    const bottom = SCR_TEXT_ROWS - SCR_GFX_ROWS
    const isTextLine = (row: number) => screen.text || (screen.mixed && row >= bottom)

    for (let row = 0; row < SCR_TEXT_ROWS; row++) {
      if (!isTextLine(row)) {
        drawLores(ctx, row, screen)
        continue
      }
      for (let col = 0; col < SCR_COLS; col++) {
        const cell = cells[row][col]
        // Inverse video swaps the lit and unlit colours, and the //e draws
        // flashing characters by toggling that bit, so it drives both.
        const inverse = cell.inverse !== flash
        const on = inverse ? offRgb : onRgb
        const off = inverse ? onRgb : offRgb
        for (let r = 0; r < GLYPH_H; r++) {
          const bits = dotRow(cell.code, r, flash ? 1 : 0)
          const y = (row * GLYPH_H + r) * SCALE
          for (let d = 0; d < GLYPH_W; d++) {
            const lit = (bits >> d) & 1
            ctx.fillStyle = lit ? on : off
            ctx.fillRect((col * GLYPH_W + d) * SCALE, y, SCALE, SCALE)
          }
        }
      }
    }
  }, [screen, cells, flash, curPal])

  return (
    <section className="pane screen-pane">
      <header>
        <h2>Screen</h2>
        <span className="hint">40 &times; 24, the text page</span>
        <span className="spacer" />
        <button
          type="button"
          className="btn-capture"
          onClick={onCapture}
          disabled={busy}
          title="Pause Apple //e momentarily, read text framebuffer, and resume"
        >
          {busy ? 'Capturing...' : 'Freeze & capture'}
        </button>
        <button
          type="button"
          className={'btn-options-toggle' + (showOptions ? ' active' : '')}
          onClick={() => setShowOptions((o) => !o)}
          title="Toggle display options (Phosphor color, CRT scanlines, Auto-refresh)"
          aria-pressed={showOptions}
        >
          ⚙ Options
        </button>
        {onClose && (
          <button
            type="button"
            className="pane-close-btn"
            onClick={onClose}
            title="Hide screen pane"
            aria-label="Close screen"
          >
            &times;
          </button>
        )}
      </header>

      {showOptions && (
        <div className="options-strip screen-options" role="region" aria-label="Screen Options">
          <div className="option-group">
            <span className="opt-label">Phosphor:</span>
            {(['green', 'amber', 'white'] as PhosphorTheme[]).map((p) => (
              <button
                key={p}
                type="button"
                className={'opt-pill' + (palette === p ? ' selected' : '')}
                onClick={() => setPalette(p)}
              >
                <span className="color-swatch" style={{ background: PALETTES[p].dot }} />
                {PALETTES[p].label}
              </button>
            ))}
          </div>

          <div className="option-group">
            <label className="opt-checkbox-label">
              <input
                type="checkbox"
                checked={scanlines}
                onChange={(e) => setScanlines(e.target.checked)}
              />
              CRT Scanlines
            </label>
          </div>

          <div className="option-group">
            <span className="opt-label">Auto-Poll:</span>
            {[
              { sec: 0, label: 'Off' },
              { sec: 2, label: '2s' },
              { sec: 5, label: '5s' },
            ].map((opt) => (
              <button
                key={opt.sec}
                type="button"
                className={'opt-pill' + (autoRefresh === opt.sec ? ' selected' : '')}
                onClick={() => setAutoRefresh(opt.sec)}
              >
                {opt.label}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className={'screen-container' + (scanlines ? ' with-scanlines' : '')}>
        {HAS_GLYPHS ? (
          <canvas ref={canvas} className="screen" />
        ) : (
          <p className="warn">
            No character ROM, so this is showing text rather than pixels. Run{' '}
            <code>npm run charset</code> in <code>web/</code> after supplying{' '}
            <code>roms/apple2e_char.hex</code> to draw the real //e glyphs.
          </p>
        )}
      </div>

      {screen ? (
        <>
          <p className="screen-status">
            {screen.text ? 'TEXT' : 'GRAPHICS'}
            {screen.mixed ? ' + MIXED' : ''} &middot; {screen.page2 ? 'PAGE 2' : 'PAGE 1'} &middot;{' '}
            {screen.hires ? 'HIRES' : 'LORES'} &middot; PLL {screen.pll ? 'locked' : 'unlocked'}
          </p>
          {!HAS_GLYPHS && <pre className="screen-fallback">{text.join('\n')}</pre>}
        </>
      ) : (
        <p className="dim">
          Not captured yet. This reads the text page through the debugger, so it pauses the
          //e while it does: there is no way to read RAM while the CPU is running.
        </p>
      )}
    </section>
  )
}

/** Lo-res: 40 blocks across, four scanlines from the high nibble and four from
 *  the low one, which is what video_generator.v does with glyph_row[2]. One
 *  dumped byte per block, the way the $GF frame carries it. */
function drawLores(ctx: CanvasRenderingContext2D, row: number, screen: ScreenFrame) {
  const gfxRow = row - (SCR_TEXT_ROWS - SCR_GFX_ROWS)
  if (gfxRow < 0 || gfxRow >= SCR_GFX_ROWS) return
  for (let block = 0; block < SCR_GFX_ROW_BYTES; block++) {
    const byte = screen.gfx[gfxRow * SCR_GFX_ROW_BYTES + block] ?? 0
    const y = row * GLYPH_H * SCALE
    // BOLT OPTIMIZATION: Use precomputed LORES_PALETTE_RGB strings instead of calling rgb() in loop.
    ctx.fillStyle = LORES_PALETTE_RGB[(byte >> 4) & 0x0f]
    ctx.fillRect(block * LORES_BLOCK_W * SCALE, y, LORES_BLOCK_W * SCALE, 4 * SCALE)
    ctx.fillStyle = LORES_PALETTE_RGB[byte & 0x0f]
    ctx.fillRect(block * LORES_BLOCK_W * SCALE, y + 4 * SCALE, LORES_BLOCK_W * SCALE, 4 * SCALE)
  }
}
