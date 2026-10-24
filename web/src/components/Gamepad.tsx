import { useEffect, useRef, useState, useCallback } from 'react'
import { PADDLE_BUTTONS } from '../keymap.js'
import { PADDLE_CENTER } from '../protocol.js'
import { AppleGlyph } from './AppleGlyph.js'

/** Only PB0/PB1 belong to the gamepad; any other bits pass through untouched. */
const PB_MASK = PADDLE_BUTTONS.reduce((m, b) => m | b.bit, 0)

interface Props {
  buttons: number
  x: number
  y: number
  onChange: (buttons: number, x: number, y: number) => void
  onClose?: () => void
}

/**
 * The two game buttons and the two paddles.
 *
 * There are two, not three: the //e's keyboard has an Open-Apple and a
 * Solid-Apple key and they are wired to hand-control buttons 0 and 1, which is
 * the whole of the game input on the machine. The RTL does decode a third
 * pushbutton at $C063, but no //e key can close it, so there is nothing to put
 * here.
 *
 * Positions are only sent when something moves, because the firmware latches
 * them rather than counting.
 */
export function Gamepad({ buttons, x, y, onChange, onClose }: Props) {
  const set = (b: number, px = x, py = y) => onChange(b, px, py)

  const [controlMode, setControlMode] = useState<'both' | 'sliders' | 'stick'>('both')
  const [springCenter, setSpringCenter] = useState(true)
  const [detectedGamepad, setDetectedGamepad] = useState<string | null>(null)

  const stickRef = useRef<HTMLDivElement>(null)
  const isDragging = useRef(false)

  // Reset paddles to center
  const onCenter = useCallback(() => {
    onChange(buttons, PADDLE_CENTER, PADDLE_CENTER)
  }, [buttons, onChange])

  // 2D Joystick Touch / Mouse interaction
  const handleStickPointer = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      const el = stickRef.current
      if (!el) return
      const rect = el.getBoundingClientRect()
      const clientX = Math.max(rect.left, Math.min(rect.right, e.clientX))
      const clientY = Math.max(rect.top, Math.min(rect.bottom, e.clientY))
      const normX = (clientX - rect.left) / rect.width
      const normY = (clientY - rect.top) / rect.height
      const newX = Math.round(normX * 255)
      const newY = Math.round(normY * 255)
      onChange(buttons, newX, newY)
    },
    [buttons, onChange],
  )

  const onStickPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    isDragging.current = true
    e.currentTarget.setPointerCapture(e.pointerId)
    handleStickPointer(e)
  }

  const onStickPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (isDragging.current) {
      handleStickPointer(e)
    }
  }

  const onStickPointerUp = () => {
    if (isDragging.current) {
      isDragging.current = false
      if (springCenter) {
        onChange(buttons, PADDLE_CENTER, PADDLE_CENTER)
      }
    }
  }

  // HTML5 Gamepad API loop
  useEffect(() => {
    let animId: number
    const deadzone = (v: number) => (Math.abs(v) < 0.08 ? 0 : v)

    const pollGamepads = () => {
      if (typeof navigator !== 'undefined' && typeof navigator.getGamepads === 'function') {
        const gamepads = navigator.getGamepads()
        let activeGp: globalThis.Gamepad | null = null
        for (const gp of gamepads) {
          if (gp && gp.connected) {
            activeGp = gp
            break
          }
        }

        if (activeGp) {
          if (!detectedGamepad) {
            setDetectedGamepad(activeGp.id.replace(/\s*\(.*\)/, ''))
          }
          // Read axes 0 and 1
          const rawAxis0 = deadzone(activeGp.axes[0] ?? 0)
          const rawAxis1 = deadzone(activeGp.axes[1] ?? 0)
          const gpX = Math.round(((rawAxis0 + 1) / 2) * 255)
          const gpY = Math.round(((rawAxis1 + 1) / 2) * 255)

          // Read buttons 0 and 1
          const b0 = activeGp.buttons[0]?.pressed ? 1 : 0
          const b1 = activeGp.buttons[1]?.pressed ? 2 : 0
          const gpButtons = b0 | b1

          if (gpX !== x || gpY !== y || gpButtons !== (buttons & PB_MASK)) {
            onChange((buttons & ~PB_MASK) | gpButtons, gpX, gpY)
          }
        } else if (detectedGamepad) {
          setDetectedGamepad(null)
        }
      }
      animId = requestAnimationFrame(pollGamepads)
    }

    animId = requestAnimationFrame(pollGamepads)
    return () => cancelAnimationFrame(animId)
  }, [buttons, x, y, onChange, detectedGamepad])

  return (
    <section className="pane gamepad-pane">
      <header>
        <h2>Paddles</h2>
        <span className="hint">$C061, $C062, $C064, $C065</span>
        <span className="spacer" />
        <button
          type="button"
          className="opt-pill"
          onClick={onCenter}
          title={`Reset both paddles to center (${PADDLE_CENTER}, ${PADDLE_CENTER})`}
        >
          ⌖ Center
        </button>
        {onClose && (
          <button
            type="button"
            className="pane-close-btn"
            onClick={onClose}
            title="Hide paddles pane"
            aria-label="Close paddles"
          >
            &times;
          </button>
        )}
      </header>

      {/* Options Strip */}
      <div className="options-strip gamepad-options">
        <div className="option-group">
          <span className="opt-label">View:</span>
          {(['both', 'sliders', 'stick'] as const).map((m) => (
            <button
              key={m}
              type="button"
              className={'opt-pill' + (controlMode === m ? ' selected' : '')}
              onClick={() => setControlMode(m)}
            >
              {m === 'both' ? 'Both' : m === 'sliders' ? 'Sliders' : '2D Stick'}
            </button>
          ))}
        </div>

        {controlMode !== 'sliders' && (
          <div className="option-group">
            <label className="opt-checkbox-label">
              <input
                type="checkbox"
                checked={springCenter}
                onChange={(e) => setSpringCenter(e.target.checked)}
              />
              Spring Return
            </label>
          </div>
        )}

        {detectedGamepad && (
          <div className="option-group">
            <span className="gamepad-badge" title="Physical controller mapped to Apple //e paddles">
              🎮 {detectedGamepad}
            </span>
          </div>
        )}
      </div>

      {/* Hand-Control Pushbuttons */}
      <div className="gamepad-buttons">
        {PADDLE_BUTTONS.map((b) => (
          <button
            key={b.key}
            className={'paddle-btn' + (buttons & b.bit ? ' on' : '')}
            onPointerDown={() => set(buttons | b.bit)}
            onPointerUp={() => set(buttons & ~b.bit)}
            onPointerLeave={() => set(buttons & ~b.bit)}
            title={`Hand-control button ${b.which}`}
          >
            <AppleGlyph solid={b.key === 'apple-c'} /> {b.label}
          </button>
        ))}
      </div>

      {/* Interactive 2D Virtual Joystick */}
      {(controlMode === 'stick' || controlMode === 'both') && (
        <div className="joystick-wrapper">
          <div
            ref={stickRef}
            className="joystick-pad"
            onPointerDown={onStickPointerDown}
            onPointerMove={onStickPointerMove}
            onPointerUp={onStickPointerUp}
            onPointerCancel={onStickPointerUp}
            title="Drag to steer both Paddle 0 (X) and Paddle 1 (Y) at once"
          >
            <div className="joystick-crosshair-h" />
            <div className="joystick-crosshair-v" />
            <div
              className="joystick-thumb"
              style={{
                left: `${(x / 255) * 100}%`,
                top: `${(y / 255) * 100}%`,
              }}
            />
          </div>
          <div className="joystick-readout">
            <span>Pdl 0 (X): <strong>{x}</strong></span>
            <span>Pdl 1 (Y): <strong>{y}</strong></span>
          </div>
        </div>
      )}

      {/* Individual Sliders */}
      {(controlMode === 'sliders' || controlMode === 'both') && (
        <div className="paddles-sliders">
          <label className="paddle">
            <span>Paddle 0 (X)</span>
            <input
              type="range"
              min={0}
              max={255}
              value={x}
              onChange={(e) => set(buttons, Number(e.target.value), y)}
            />
            <output>{x}</output>
          </label>
          <label className="paddle">
            <span>Paddle 1 (Y)</span>
            <input
              type="range"
              min={0}
              max={255}
              value={y}
              onChange={(e) => set(buttons, x, Number(e.target.value))}
            />
            <output>{y}</output>
          </label>
        </div>
      )}

      <p className="dim small">
        The firmware starts a 60&#8239;&micro;s countdown when the ROM reads $C070, and $C064 or
        $C065 reads back 1 until it runs out. Centre is 128, as the hardware sits.
      </p>
    </section>
  )
}
