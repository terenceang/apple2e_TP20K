import { useEffect, useRef, useState } from 'react'
import { KEYS, boardBox, CAPTION } from '../keyboard/layouts.js'
import {
  hostKey,
  isModifier,
  isDebuggerToggle,
  paddleButtonBits,
  REPEAT_DELAY_MS,
  REPEAT_INTERVAL_MS,
} from '../keymap.js'
import { BAUD } from '../serial-link.js'
import { AppleGlyph } from './AppleGlyph.js'
import type { Conn, Mode } from '../useApple'

interface Props {
  mode: Mode
  onPress: (
    id: string,
    mods: { shift: boolean; caps: boolean; ctrl: boolean },
    buttons: number,
  ) => void
  /** RESET key down/up, with the paddle buttons (Open/Solid-Apple) held. */
  onReset?: (down: boolean, buttons: number) => void
  /** The last character key came up: the //e's any-key-down line drops. */
  onRelease?: () => void
  /** Latching switches, so the caps can show as down. */
  held: { shift: boolean; ctrl: boolean; caps: boolean; appleO: boolean; appleC: boolean }
  conn?: Conn
  canSerial?: boolean
  onConnect?: () => void
}

type Cap = (typeof KEYS)[number]

/**
 * The Apple //e keyboard, US layout, 1983-86 beige case with the large white
 * keycap print. 63 keys, arranged in layouts.js; this draws the board and
 * provides immediate visual connection feedback (Power LED, TX activity, and
 * offline alerts).
 */
export function Keyboard({ mode, onPress, onReset, onRelease, held, conn, canSerial = true, onConnect }: Props) {
  const [down, setDown] = useState<Set<string>>(new Set())
  // Character keys currently held, for the any-key-down release
  const charsDown = useRef(new Set<string>())
  const charUp = (id: string) => {
    if (charsDown.current.delete(id) && charsDown.current.size === 0) onRelease?.()
  }
  const delay = useRef<number | null>(null)
  const ticker = useRef<number | null>(null)
  const repeatId = useRef<string | null>(null)
  const mods = useRef({ shift: false, ctrl: false })

  const isConnected = conn?.state === 'open'
  const isConnecting = conn?.state === 'opening' || conn?.state === 'probing'
  const isWrongPort = conn?.state === 'wrong-port'

  // Dynamic responsive unit scaling to fill the keyboard case
  const bezelRef = useRef<HTMLDivElement>(null)
  const [unit, setUnit] = useState(34)

  useEffect(() => {
    const el = bezelRef.current
    if (!el) return

    const update = () => {
      const w = el.clientWidth
      if (w > 0) {
        // Total key units across: the board width plus the 0.5-unit left
        // margin every cap is drawn at. Bezel padding is 12px on each side.
        const available = w - 24
        // Calculate unit to fill available width: minimum 34px, up to 70px
        const computed = Math.min(70, Math.max(34, Math.floor(available / (boardBox().width + 0.5))))
        setUnit(computed)
      }
    }

    update()
    const ro = new ResizeObserver(update)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  // Visual feedback when typing while disconnected, and TX activity pulse when connected
  const [warnDisconnected, setWarnDisconnected] = useState(false)
  const warnTimer = useRef<number | null>(null)
  const [txPulse, setTxPulse] = useState(false)
  const txTimer = useRef<number | null>(null)

  const triggerActivity = () => {
    if (!isConnected) {
      setWarnDisconnected(true)
      if (warnTimer.current) clearTimeout(warnTimer.current)
      warnTimer.current = window.setTimeout(() => setWarnDisconnected(false), 3500)
    } else {
      setTxPulse(true)
      if (txTimer.current) clearTimeout(txTimer.current)
      txTimer.current = window.setTimeout(() => setTxPulse(false), 120)
    }
  }

  // Ref mirror so event handlers don't stale
  const heldRef = useRef(held)
  heldRef.current = held

  const isConnectedRef = useRef(isConnected)
  isConnectedRef.current = isConnected

  /** The paddle buttons held with a keypress (Open/Solid-Apple). */
  const heldButtons = () => paddleButtonBits(heldRef.current)

  useEffect(() => {
    const typingInto = (t: EventTarget | null) =>
      t instanceof HTMLElement && /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)

    const stopRepeat = () => {
      if (delay.current !== null) clearTimeout(delay.current)
      if (ticker.current !== null) clearInterval(ticker.current)
      delay.current = null
      ticker.current = null
      repeatId.current = null
    }

    const press = (id: string) => {
      triggerActivity()
      const buttons = heldButtons()
      onPress(id, { ...mods.current, caps: heldRef.current.caps }, buttons)
    }

    const startRepeat = () => {
      ticker.current = window.setInterval(() => {
        if (repeatId.current) press(repeatId.current)
      }, REPEAT_INTERVAL_MS)
    }

    const onDown = (e: KeyboardEvent) => {
      if (typingInto(e.target)) return
      const id = hostKey(e.code)
      if (!id) return
      // Ctrl+B is the debugger toggle and never reaches the //e -- the
      // firmware drops 0x02 before the keyboard sees it -- so App handles it.
      if (isDebuggerToggle(e)) return
      e.preventDefault()
      if (e.repeat) return // our own timer drives repeats, at the //e's rate
      mods.current = { shift: e.shiftKey, ctrl: e.ctrlKey }
      setDown((d) => new Set(d).add(id))
      // CONTROL-RESET: RESET does nothing on a //e unless CONTROL is down
      if (id === 'reset') {
        if (e.ctrlKey) {
          triggerActivity()
          onReset?.(true, heldButtons())
        }
        return
      }
      if (!isModifier(id) && e.code !== 'CapsLock') {
        charsDown.current.add(id)
        press(id)
      }

      // Hold-to-repeat. The //e dropped REPT, so the hardware repeats instead,
      // after about a second and then at roughly 10 Hz.
      stopRepeat()
      if (!isModifier(id) && e.code !== 'CapsLock') {
        repeatId.current = id
        delay.current = window.setTimeout(startRepeat, REPEAT_DELAY_MS)
      }
    }

    const onUp = (e: KeyboardEvent) => {
      const id = hostKey(e.code)
      if (id === 'reset') onReset?.(false, heldButtons())
      if (id) charUp(id)
      if (id) {
        setDown((d) => {
          if (!d.has(id)) return d
          const n = new Set(d)
          n.delete(id)
          return n
        })
      }
      mods.current = { shift: e.shiftKey, ctrl: e.ctrlKey }
      if (id && id === repeatId.current) stopRepeat()
      if (!e.shiftKey) mods.current.shift = false
      if (!e.ctrlKey) mods.current.ctrl = false
    }

    const onBlur = () => {
      stopRepeat()
      setDown(new Set())
      mods.current = { shift: false, ctrl: false }
      if (charsDown.current.size) {
        charsDown.current.clear()
        onRelease?.()
      }
    }

    window.addEventListener('keydown', onDown)
    window.addEventListener('keyup', onUp)
    window.addEventListener('blur', onBlur)
    return () => {
      stopRepeat()
      window.removeEventListener('keydown', onDown)
      window.removeEventListener('keyup', onUp)
      window.removeEventListener('blur', onBlur)
      if (warnTimer.current) clearTimeout(warnTimer.current)
      if (txTimer.current) clearTimeout(txTimer.current)
    }
  }, [onPress, onReset, onRelease])

  const capDown = (k: Cap, capEvent: 'down' | 'up') => {
    const buttons = heldButtons()
    if (k.id === 'reset') {
      // CONTROL-RESET, from the on-screen cap: only with CONTROL held
      if (capEvent === 'up') onReset?.(false, buttons)
      else if (heldRef.current.ctrl) onReset?.(true, buttons)
      setDown((d) => {
        const n = new Set(d)
        if (capEvent === 'down') n.add(k.id)
        else n.delete(k.id)
        return n
      })
      return
    }
    if (capEvent === 'down') {
      triggerActivity()
      setDown((d) => new Set(d).add(k.id))
      if (!isModifier(k.id)) charsDown.current.add(k.id)
      onPress(k.id, { shift: heldRef.current.shift, caps: heldRef.current.caps, ctrl: heldRef.current.ctrl }, buttons)
    } else {
      charUp(k.id)
      setDown((d) => {
        const n = new Set(d)
        n.delete(k.id)
        return n
      })
    }
  }

  const legend = (k: Cap) => k.legend ?? ''
  /** The two apple keys, whose legend names the glyph rather than being text. */
  const isApple = (k: Cap) => legend(k) === 'open' || legend(k) === 'solid'
  const caption = (k: Cap) => CAPTION[k.id as keyof typeof CAPTION]
  const board = boardBox()
  // Total key units across: the board plus the 0.5-unit left margin at line 341.
  const UNITS = board.width + 0.5

  return (
    <div className={'keyboard-case' + (!isConnected ? ' offline-case' : '')}>
      <div className="keyboard-header">
        <div className="keyboard-brand">
          <span className="apple-badge">apple //e</span>
          <div
            className={`pwr-indicator ${
              isConnected ? 'on' : isConnecting ? 'probing' : isWrongPort ? 'error' : 'off'
            }`}
            title={
              isConnected
                ? `Tang Nano 20K connected (${BAUD} 8N1)`
                : isConnecting
                ? 'Connecting to Tang Nano 20K...'
                : isWrongPort
                ? 'Selected port did not respond (likely JTAG or unprogrammed board)'
                : 'Not connected - click Connect USB to enable typing'
            }
          >
            <span className={`pwr-led ${txPulse ? 'tx-active' : ''}`} />
            <span className="pwr-text">
              {isConnected
                ? 'POWER'
                : isConnecting
                ? 'LINKING...'
                : isWrongPort
                ? 'WRONG PORT'
                : 'OFFLINE'}
            </span>
            {isConnected && (
              <span className={`tx-tag ${txPulse ? 'active' : ''}`} title="UART TX Activity">
                TX
              </span>
            )}
          </div>
        </div>

        <div className="keyboard-status-bar">
          {!isConnected && (
            <div className={`kb-notice ${warnDisconnected || isWrongPort ? 'alert' : ''}`}>
              <span className="kb-notice-msg">
                {isWrongPort
                  ? conn?.detail
                    ? `⚠️ Wrong USB Port! ${conn.detail}`
                    : '⚠️ Wrong USB Port! Selected port did not respond to Apple //e probe.'
                  : warnDisconnected
                  ? '⚠️ Not connected! Keystrokes are not reaching the board.'
                  : 'Hardware offline'}
              </span>
              {onConnect && (
                <button
                  type="button"
                  className="kb-quick-connect"
                  onClick={onConnect}
                  disabled={!canSerial}
                  title="Select Tang Nano 20K USB serial"
                >
                  ⚡ {isWrongPort ? 'Pick Port' : 'Connect USB'}
                </button>
              )}
            </div>
          )}
          {isConnected && (
            <span className="kb-connected-tag">
              <span className="online-dot" /> Online • {BAUD} 8N1
            </span>
          )}
        </div>
      </div>

      <div className="keyboard-bezel" ref={bezelRef}>
        <div
          className={'board' + (!isConnected ? ' board-offline' : '')}
          style={{
            width: UNITS * unit,
            height: board.height * unit,
            ['--unit' as string]: `${unit}px`,
          }}
          role="group"
          aria-label="Apple //e keyboard"
        >
          {KEYS.map((k) => {
            const isDown =
              down.has(k.id) ||
              (k.id.startsWith('shift') && held.shift) ||
              (k.id === 'control' && held.ctrl) ||
              (k.id === 'caps' && held.caps) ||
              (k.id === 'apple-o' && held.appleO) ||
              (k.id === 'apple-c' && held.appleC)
            return (
              <button
                key={k.id}
                type="button"
                className={
                  'cap' + (isDown ? ' down' : '') + (k.mod ? ' mod' : '') + (k.latch ? ' latch' : '')
                }
                style={{
                  left: (k.x + 0.5) * unit,
                  top: (k.y - board.top) * unit,
                  width: k.w ? k.w * unit - 3 : unit - 3,
                  height: k.h ? k.h * unit - 3 : unit - 3,
                }}
                onPointerDown={() => capDown(k, 'down')}
                onPointerUp={() => capDown(k, 'up')}
                onPointerLeave={() => capDown(k, 'up')}
                aria-label={k.id}
                aria-pressed={isDown}
              >
                {isApple(k) ? (
                  <AppleGlyph solid={legend(k) === 'solid'} />
                ) : (
                  <>
                    {k.sub && <span className="cap-top">{legend(k)}</span>}
                    {k.sub ? (
                      <span className="cap-bottom">{k.sub}</span>
                    ) : caption(k) ? (
                      <span className="cap-word">{caption(k)}</span>
                    ) : (
                      <span className={legend(k).length > 2 ? 'cap-word' : 'cap-main'}>
                        {legend(k)}
                      </span>
                    )}
                  </>
                )}
              </button>
            )
          })}
        </div>
      </div>

      <p className={'keyboard-note' + (!isConnected ? ' offline-note' : '')}>
        {!isConnected ? (
          <>
            <strong className="status-highlight offline">⚠️ OFFLINE:</strong> Not connected to the Tang Nano 20K.
            Keystrokes will not reach the Apple //e until you{' '}
            {onConnect && canSerial ? (
              <button type="button" className="link-inline-btn" onClick={onConnect}>
                connect USB
              </button>
            ) : (
              'connect USB'
            )}.
          </>
        ) : mode === 'debugger' ? (
          <>
            <strong className="status-highlight paused">⏸️ DEBUGGER:</strong> CPU is paused. Letters are commands;{' '}
            <kbd>Ctrl</kbd>+<kbd>B</kbd> or <kbd>c</kbd> resumes.
          </>
        ) : (
          <>
            <strong className="status-highlight online">🟢 READY:</strong> Connected to Apple //e. Click a cap, or just type. <kbd>Alt</kbd> is the apple key,{' '}
            <kbd>Shift</kbd> and <kbd>Ctrl</kbd> are the //e's own, and holding a key repeats.
          </>
        )}
      </p>
    </div>
  )
}
