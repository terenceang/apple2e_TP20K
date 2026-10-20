import type { Conn } from '../useApple'
import { formatConnState } from '../prefs.js'

interface Props {
  conn: Conn
  canSerial: boolean
  baud: number
  showScreen: boolean
  showConsole: boolean
  showDebugger: boolean
  showPaddles: boolean
  showDisks: boolean
  onToggleScreen: () => void
  onToggleConsole: () => void
  onToggleDebugger: () => void
  onTogglePaddles: () => void
  onToggleDisks: () => void
  onSerial: () => void
  onSerialNoVerify?: () => void
  onDisconnect: () => void
  onReconnect: () => void
}

/**
 * How the app reaches the machine and controls view visibility.
 *
 * Direct USB serial via the Web Serial API: the board is plugged directly into
 * the machine running the browser and the browser opens the port itself.
 */
export function FlashBar({
  conn,
  canSerial,
  baud,
  showScreen,
  showConsole,
  showDebugger,
  showPaddles,
  showDisks,
  onToggleScreen,
  onToggleConsole,
  onToggleDebugger,
  onTogglePaddles,
  onToggleDisks,
  onSerial,
  onSerialNoVerify,
  onDisconnect,
  onReconnect,
}: Props) {
  const up = conn.state === 'open'

  return (
    <div className="flashbar">
      <span className={'dot ' + (up ? 'open' : conn.state)} aria-hidden />
      <span className="state">{formatConnState(conn, baud)}</span>
      {conn.transport && <span className="tag">USB serial</span>}

      {conn.state === 'idle' ? (
        <span className="chooser">
          <button
            type="button"
            className="btn-connect-primary"
            onClick={onSerial}
            disabled={!canSerial}
            title={
              canSerial
                ? 'Open Web Serial connection to Tang Nano 20K'
                : 'This browser has no Web Serial. That needs Chrome or Edge, on https or localhost.'
            }
          >
            ⚡ Connect USB
          </button>
        </span>
      ) : conn.state === 'wrong-port' ? (
        <span className="chooser">
          <button
            type="button"
            className="btn-connect-primary"
            onClick={onReconnect}
            title="Open device picker to select another COM port"
          >
            ⚡ Pick Another Port
          </button>
          {onSerialNoVerify && (
            <button
              type="button"
              className="btn-warn-action"
              onClick={onSerialNoVerify}
              title="Connect directly to the port without waiting for Apple //e debugger probe"
            >
              Skip Handshake
            </button>
          )}
          <button type="button" onClick={onDisconnect}>
            Dismiss
          </button>
        </span>
      ) : conn.state === 'error' ? (
        <span className="chooser">
          <button type="button" onClick={onReconnect}>Try again</button>
          <button type="button" onClick={onDisconnect}>Dismiss</button>
        </span>
      ) : (
        <button type="button" onClick={onDisconnect}>Disconnect</button>
      )}

      <span className="spacer" />

      <div className="view-toggles" role="group" aria-label="Toggle views">
        <button
          type="button"
          className={'toggle-btn' + (showScreen ? ' active' : '')}
          onClick={onToggleScreen}
          title={showScreen ? 'Hide Screen' : 'Show Screen'}
          aria-pressed={showScreen}
        >
          Screen
        </button>
        <button
          type="button"
          className={'toggle-btn' + (showConsole ? ' active' : '')}
          onClick={onToggleConsole}
          title={showConsole ? 'Hide Console' : 'Show Console'}
          aria-pressed={showConsole}
        >
          Console
        </button>
        <button
          type="button"
          className={'toggle-btn' + (showDebugger ? ' active' : '')}
          onClick={onToggleDebugger}
          title={showDebugger ? 'Hide Debugger (Ctrl+B)' : 'Show Debugger (Ctrl+B)'}
          aria-pressed={showDebugger}
        >
          Debugger
        </button>
        <button
          type="button"
          className={'toggle-btn' + (showPaddles ? ' active' : '')}
          onClick={onTogglePaddles}
          title={showPaddles ? 'Hide Paddles & Gamepad' : 'Show Paddles & Gamepad'}
          aria-pressed={showPaddles}
        >
          Paddles
        </button>
        <button
          type="button"
          className={'toggle-btn' + (showDisks ? ' active' : '')}
          onClick={onToggleDisks}
          title={showDisks ? 'Hide Disk II Manager' : 'Show Disk II Manager'}
          aria-pressed={showDisks}
        >
          Disks
        </button>
      </div>
    </div>
  )
}
