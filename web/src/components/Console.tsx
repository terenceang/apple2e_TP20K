import { useEffect, useRef } from 'react'

interface Props {
  lines: string[]
  onClear: () => void
  onClose?: () => void
}

/**
 * The COUT stream.
 *
 * This is a character stream, not a screen, and the difference matters. The
 * firmware only intercepts $FDED (COUT) and the two slot-serial ports, so what
 * arrives is whatever the Apple II chose to send with COUT: PRINT output,
 * messages, and whatever the machine echoes as you type. Anything that puts
 * characters on the screen by writing the text page and moving the cursor with
 * $C05x softswitches is *not* intercepted, so a full-screen program shows up
 * here mangled. That is a property of the hardware path, not of this pane --
 * the Screen pane is the way to see the real text page.
 */
export function Console({ lines, onClear, onClose }: Props) {
  const box = useRef<HTMLPreElement>(null)
  const stick = useRef(true)

  // Follow the tail, unless the reader has scrolled up to look at something.
  useEffect(() => {
    const el = box.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [lines])

  return (
    <section className="pane console-pane">
      <header>
        <h2>Console</h2>
        <span className="hint">COUT, $FDED</span>
        <button
          type="button"
          onClick={onClear}
          onMouseEnter={() => (stick.current = false)}
          onMouseLeave={() => (stick.current = true)}
        >
          Clear
        </button>
        {onClose && (
          <button type="button" onClick={onClose} title="Hide Console">
            Hide
          </button>
        )}
      </header>
      <pre
        ref={box}
        onScroll={(e) => {
          const el = e.currentTarget
          stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24
        }}
      >
        {lines.length === 0 ? (
          <span className="dim">
            Nothing yet. The //e is not printing anything over COUT. Type a RUN, or press
            Freeze &amp; capture for the real screen.
          </span>
        ) : (
          lines.join('\n')
        )}
      </pre>
    </section>
  )
}
