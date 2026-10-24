import { useEffect, useRef, useState } from 'react'

interface Props {
  status: string
  log: string[]
  gateway: string
  onGateway: (url: string) => void
  onHangup: () => void
  onClose?: () => void
}

/**
 * The Hayes modem behind slot 1's Super Serial Card (src/modem.js).
 *
 * The Apple's comm program types AT commands at the card as it would at a
 * real modem; this pane only shows what the modem is doing and holds the one
 * setting a browser needs: a WebSocket gateway for ATDT host:port, since a
 * page cannot open a TCP connection itself.  ATDT ws://... or wss://... dials
 * a WebSocket directly, and ATDT LOOP is a loopback for testing.
 */
export function ModemPane({ status, log, gateway, onGateway, onHangup, onClose }: Props) {
  const [draft, setDraft] = useState(gateway)
  useEffect(() => setDraft(gateway), [gateway])
  const box = useRef<HTMLPreElement>(null)
  useEffect(() => {
    if (box.current) box.current.scrollTop = box.current.scrollHeight
  }, [log])

  return (
    <section className="pane console-pane modem-pane">
      <header>
        <h2>Modem</h2>
        <span className="hint">slot 1 Super Serial Card</span>
        <button type="button" onClick={onHangup} disabled={status === 'on hook'} title="Hang up (as ATH)">
          Hang up
        </button>
        {onClose && (
          <button
            type="button"
            className="pane-close-btn"
            onClick={onClose}
            aria-label="Close modem"
            title="Close modem"
          >
            &times;
          </button>
        )}
      </header>
      <div className="modem-status">{status}</div>
      <label className="modem-gateway">
        <span>Gateway for ATDT host:port</span>
        <input
          type="text"
          value={draft}
          placeholder="wss://your-gateway/?host={host}&port={port}"
          onChange={(e) => setDraft(e.target.value)}
          onBlur={() => draft !== gateway && onGateway(draft.trim())}
          onKeyDown={(e) => { if (e.key === 'Enter') onGateway(draft.trim()) }}
          spellCheck={false}
        />
      </label>
      <pre ref={box} className="console modem-log">
        {log.length ? log.join('\n') : 'ATDT LOOP for a loopback; ATDT host:port through the gateway; ATDT wss://... direct.'}
      </pre>
    </section>
  )
}
