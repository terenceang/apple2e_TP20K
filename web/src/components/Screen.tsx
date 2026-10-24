import { useEffect, useMemo, useRef, useState, useCallback } from 'react'
import { AppleStream, screenToText } from '../stream.js'
import { dotRow, HAS_GLYPHS, GLYPH_W, GLYPH_H, hasGlyphs, parseCharRom, setUserCharRom } from '../charset.js'
import { LORES_PALETTE, SCR_COLS, SCR_TEXT_ROWS, SCR_GFX_ROWS, SCR_GFX_ROW_BYTES, hgrScanlineOffset, SCR_GFX_BYTES } from '../protocol.js'
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

export type PhosphorTheme = 'color' | 'green' | 'amber' | 'white'

const PALETTES: Record<PhosphorTheme, { on: number[]; off: number[]; label: string; dot: string }> = {
  color: {
    on: [0x20, 0xe8, 0x20],
    off: [0x00, 0x00, 0x00],
    label: 'Color (NTSC)',
    dot: 'linear-gradient(135deg, #30bd1b 25%, #d043e5 50%, #d06b1b 75%, #3095e5 100%)',
  },
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
  const [hasCustomRom, setHasCustomRom] = useState(() => hasGlyphs())
  const canDrawPixels = HAS_GLYPHS || hasCustomRom
  const [flash, setFlash] = useState(false)

  const store = typeof localStorage !== 'undefined' ? localStorage : null

  // Persistent Display Options
  const [palette, setPaletteState] = useState<PhosphorTheme>(() => {
    const saved = getSavedString(store, PREF_SCREEN_PALETTE, 'color')
    return saved === 'color' || saved === 'green' || saved === 'amber' || saved === 'white' ? saved : 'color'
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

    // 1. If in Hi-Res mode, draw the 280x192 graphics scanlines
    if (screen.hires && screen.hgr && screen.hgr.length >= 8192) {
      drawHires(ctx, screen, palette, curPal)
    }

    // 2. Draw text or lo-res rows
    const bottom = SCR_TEXT_ROWS - SCR_GFX_ROWS
    const isTextLine = (row: number) => screen.text || (screen.mixed && row >= bottom)

    for (let row = 0; row < SCR_TEXT_ROWS; row++) {
      // If this row was already rendered as Hi-Res graphics, skip it
      if (screen.hires && (!screen.mixed || row < bottom)) {
        continue
      }

      if (!isTextLine(row)) {
        drawLores(ctx, row, screen, cells)
        continue
      }

      // Draw text row (if character ROM is loaded)
      for (let col = 0; col < SCR_COLS; col++) {
        const cell = cells[row][col]
        const on = onRgb
        const off = offRgb
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
        <span className="hint">Live Framebuffer Capture</span>
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
            <span className="opt-label">Display:</span>
            {(['color', 'green', 'amber', 'white'] as PhosphorTheme[]).map((p) => (
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
        {(canDrawPixels || screen?.hires || (!screen?.text && !screen?.hires)) ? (
          <canvas ref={canvas} className="screen" />
        ) : (
          <p className="warn">
            No character ROM built in (monospaced fallback active).
            <label style={{ display: 'inline-block', marginLeft: '8px', padding: '2px 8px', background: '#222', color: '#e0e0e0', border: '1px solid #444', borderRadius: '4px', cursor: 'pointer', fontSize: '11px' }}>
              📁 Load apple2e_char.hex
              <input
                type="file"
                accept=".hex,.bin,.rom"
                style={{ display: 'none' }}
                onChange={(e) => {
                  const file = e.target.files?.[0]
                  if (!file) return
                  const reader = new FileReader()
                  reader.onload = (ev) => {
                    const raw = ev.target?.result as string
                    const bytes = parseCharRom(raw)
                    if (bytes.length >= 2048) {
                      setUserCharRom(bytes)
                      setHasCustomRom(true)
                    } else {
                      alert('Invalid character ROM. Expected at least 2048 hex bytes.')
                    }
                  }
                  reader.readAsText(file)
                }}
              />
            </label>
          </p>
        )}
      </div>

      {screen ? (
        <>
          <p className="screen-status">
            {screen.text
              ? screen.col80
                ? '80-COL TEXT'
                : 'TEXT'
              : screen.dhires
                ? 'DOUBLE HIRES'
                : screen.hires
                  ? 'HIRES'
                  : 'LORES'}
            {screen.mixed ? ' + MIXED' : ''} &middot; {screen.page2 ? 'PAGE 2' : 'PAGE 1'} &middot;{' '}
            PLL {screen.pll ? 'locked' : 'unlocked'}
          </p>
          {!canDrawPixels && (screen.text || screen.mixed) && (
            <pre className="screen-fallback">
              {text.join('\n').trim() || '(empty text screen)'}
            </pre>
          )}
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

/** Hi-Res & Double Hi-Res graphics renderer: full NTSC composite artifact color or monochrome phosphor. */
function drawHires(
  ctx: CanvasRenderingContext2D,
  screen: ScreenFrame,
  theme: PhosphorTheme,
  palette: { on: number[]; off: number[] }
) {
  if (!screen.hgr || screen.hgr.length < 8192) return
  const isDh = Boolean(screen.dhires && screen.aux && screen.aux.length >= 8192)
  const numScanlines = screen.mixed ? 160 : 192
  const targetW = SCR_COLS * GLYPH_W * SCALE // 560
  const targetH = numScanlines * SCALE        // 384 or 320
  const img = ctx.createImageData(targetW, targetH)
  const data = img.data

  if (theme === 'color') {
    // Authentic Apple II NTSC composite artifact color demodulation (matching video_generator.v)
    const samples = new Uint8Array(targetW)
    for (let y = 0; y < numScanlines; y++) {
      const offset = hgrScanlineOffset(y)

      if (isDh) {
        // Double Hi-Res (560x192): 7 dots from Aux RAM, 7 dots from Main RAM per column
        for (let col = 0; col < 40; col++) {
          const auxByte = screen.aux[offset + col] ?? 0
          const mainByte = screen.hgr[offset + col] ?? 0
          for (let dot = 0; dot < 7; dot++) {
            samples[col * 14 + dot] = (auxByte >> dot) & 1
          }
          for (let dot = 0; dot < 7; dot++) {
            samples[col * 14 + 7 + dot] = (mainByte >> dot) & 1
          }
        }
      } else {
        // Standard Hi-Res (280x192): 7 dots from Main RAM, 2 samples per dot with delay shift
        let prevLast = 0
        for (let col = 0; col < 40; col++) {
          const byte = screen.hgr[offset + col] ?? 0
          const delay = (byte >> 7) & 1
          for (let dot = 0; dot < 7; dot++) {
            const cur = (byte >> dot) & 1
            const left = dot === 0 ? prevLast : (byte >> (dot - 1)) & 1
            samples[col * 14 + dot * 2] = delay ? left : cur
            samples[col * 14 + dot * 2 + 1] = cur
          }
          prevLast = (byte >> 6) & 1
        }
      }

      for (let x = 0; x < targetW; x++) {
        const s_m2 = x >= 2 ? samples[x - 2] : 0
        const s_m1 = x >= 1 ? samples[x - 1] : 0
        const s_0 = samples[x]
        const s_p1 = x < targetW - 1 ? samples[x + 1] : 0

        const yVal = s_m2 + s_m1 + s_0 + s_p1
        const ph = x & 3

        const ci =
          chromaI(s_m2, (ph + 2) & 3) +
          chromaI(s_m1, (ph + 3) & 3) +
          chromaI(s_0, ph) +
          chromaI(s_p1, (ph + 1) & 3)
        const cq =
          chromaQ(s_m2, (ph + 2) & 3) +
          chromaQ(s_m1, (ph + 3) & 3) +
          chromaQ(s_0, ph) +
          chromaQ(s_p1, (ph + 1) & 3)

        const r = Math.max(0, Math.min(255, 64 * yVal + 80 * ci))
        const g = Math.max(0, Math.min(255, 64 * yVal - 41 * ci - 20 * cq))
        const b = Math.max(0, Math.min(255, 64 * yVal + 101 * cq))

        const idx0 = (y * 2 * targetW + x) * 4
        const idx1 = ((y * 2 + 1) * targetW + x) * 4

        data[idx0]     = r
        data[idx0 + 1] = g
        data[idx0 + 2] = b
        data[idx0 + 3] = 255

        data[idx1]     = r
        data[idx1 + 1] = g
        data[idx1 + 2] = b
        data[idx1 + 3] = 255
      }
    }
  } else {
    // Monochrome phosphor dot rendering
    const [onR, onG, onB] = palette.on
    const [offR, offG, offB] = palette.off
    for (let y = 0; y < numScanlines; y++) {
      const offset = hgrScanlineOffset(y)

      if (isDh) {
        for (let col = 0; col < 40; col++) {
          const auxByte = screen.aux[offset + col] ?? 0
          const mainByte = screen.hgr[offset + col] ?? 0
          const baseX = col * 14
          for (let dot = 0; dot < 7; dot++) {
            const lit = (auxByte >> dot) & 1
            const r = lit ? onR : offR
            const g = lit ? onG : offG
            const b = lit ? onB : offB
            const px = baseX + dot
            const idx0 = (y * 2 * targetW + px) * 4
            const idx1 = ((y * 2 + 1) * targetW + px) * 4
            data[idx0] = r; data[idx0 + 1] = g; data[idx0 + 2] = b; data[idx0 + 3] = 255
            data[idx1] = r; data[idx1 + 1] = g; data[idx1 + 2] = b; data[idx1 + 3] = 255
          }
          for (let dot = 0; dot < 7; dot++) {
            const lit = (mainByte >> dot) & 1
            const r = lit ? onR : offR
            const g = lit ? onG : offG
            const b = lit ? onB : offB
            const px = baseX + 7 + dot
            const idx0 = (y * 2 * targetW + px) * 4
            const idx1 = ((y * 2 + 1) * targetW + px) * 4
            data[idx0] = r; data[idx0 + 1] = g; data[idx0 + 2] = b; data[idx0 + 3] = 255
            data[idx1] = r; data[idx1 + 1] = g; data[idx1 + 2] = b; data[idx1 + 3] = 255
          }
        }
      } else {
        for (let col = 0; col < 40; col++) {
          const byte = screen.hgr[offset + col] ?? 0
          const baseX = col * 7 * SCALE
          for (let dot = 0; dot < 7; dot++) {
            const lit = (byte >> dot) & 1
            const r = lit ? onR : offR
            const g = lit ? onG : offG
            const b = lit ? onB : offB
            for (let dx = 0; dx < SCALE; dx++) {
              const px = baseX + dot * SCALE + dx
              const idx0 = (y * 2 * targetW + px) * 4
              const idx1 = ((y * 2 + 1) * targetW + px) * 4
              data[idx0]     = r
              data[idx0 + 1] = g
              data[idx0 + 2] = b
              data[idx0 + 3] = 255
              data[idx1]     = r
              data[idx1 + 1] = g
              data[idx1 + 2] = b
              data[idx1 + 3] = 255
            }
          }
        }
      }
    }
  }

  ctx.putImageData(img, 0, 0)
}

function chromaI(s: number, q: number): number {
  if (!s) return 0
  if (q === 0) return 1
  if (q === 2) return -1
  return 0
}

function chromaQ(s: number, q: number): number {
  if (!s) return 0
  if (q === 1) return 1
  if (q === 3) return -1
  return 0
}

/** Lo-res: 40 blocks across, four scanlines from the high nibble and four from
 *  the low one, which is what video_generator.v does with glyph_row[2]. */
function drawLores(
  ctx: CanvasRenderingContext2D,
  row: number,
  screen: ScreenFrame,
  cells: Array<Array<{ code: number }>>
) {
  for (let col = 0; col < SCR_COLS; col++) {
    let byte = 0
    if (screen.mixed && row >= (SCR_TEXT_ROWS - SCR_GFX_ROWS) && screen.gfx && screen.gfx.length >= SCR_GFX_BYTES) {
      const gfxRow = row - (SCR_TEXT_ROWS - SCR_GFX_ROWS)
      byte = screen.gfx[gfxRow * SCR_GFX_ROW_BYTES + col] ?? 0
    } else {
      byte = cells[row]?.[col]?.code ?? 0
    }
    const x = col * LORES_BLOCK_W * SCALE
    const y = row * GLYPH_H * SCALE
    ctx.fillStyle = LORES_PALETTE_RGB[(byte >> 4) & 0x0f]
    ctx.fillRect(x, y, LORES_BLOCK_W * SCALE, 4 * SCALE)
    ctx.fillStyle = LORES_PALETTE_RGB[byte & 0x0f]
    ctx.fillRect(x, y + 4 * SCALE, LORES_BLOCK_W * SCALE, 4 * SCALE)
  }
}
