import { useCallback, useEffect, useState } from 'react'
import { useApple } from './useApple'
import { isDebuggerToggle } from './keymap.js'
import { PADDLE_CENTER } from './protocol.js'
import { Keyboard } from './components/Keyboard'
import { Console } from './components/Console'
import { Screen } from './components/Screen'
import { DebuggerPane } from './components/DebuggerPane'
import { Gamepad } from './components/Gamepad'
import { FlashBar } from './components/FlashBar'
import { DiskPane } from './components/DiskPane'
import { ModemPane } from './components/ModemPane'
import versionInfo from './version.json'

import {
  PREF_CONSOLE,
  PREF_DEBUGGER,
  PREF_SCREEN,
  PREF_PADDLES,
  PREF_DISKS,
  PREF_MODEM,
  getSavedBool,
  setSavedBool,
} from './prefs.js'

export default function App() {
  const apple = useApple()
  const [held, setHeld] = useState({ shift: false, ctrl: false, caps: false, appleO: false, appleC: false })
  const [buttons, setButtons] = useState(0)
  const [paddles, setPaddles] = useState({ x: PADDLE_CENTER, y: PADDLE_CENTER })

  const store = typeof localStorage !== 'undefined' ? localStorage : null

  // View Visibility Toggles (Screen and Paddles are visible by default; Console and Debugger hidden)
  const [showScreen, setShowScreenState] = useState(() => getSavedBool(store, PREF_SCREEN, true))
  const [showConsole, setShowConsoleState] = useState(() => getSavedBool(store, PREF_CONSOLE, false))
  const [showDebugger, setShowDebuggerState] = useState(() => getSavedBool(store, PREF_DEBUGGER, false))
  const [showPaddles, setShowPaddlesState] = useState(() => getSavedBool(store, PREF_PADDLES, true))
  const [showDisks, setShowDisksState] = useState(() => getSavedBool(store, PREF_DISKS, true))
  const [showModem, setShowModemState] = useState(() => getSavedBool(store, PREF_MODEM, false))

  // One persistence wrapper; the five toggles differ only in key and setter.
  const useToggle = (
    key: string,
    setter: (value: boolean | ((prev: boolean) => boolean)) => void,
  ) =>
    useCallback(
      (show: boolean | ((prev: boolean) => boolean)) => {
        setter((prev) => {
          const next = typeof show === 'function' ? show(prev) : show
          setSavedBool(store, key, next)
          return next
        })
      },
      [store, key, setter],
    )

  const setShowScreen = useToggle(PREF_SCREEN, setShowScreenState)
  const setShowConsole = useToggle(PREF_CONSOLE, setShowConsoleState)
  const setShowDebugger = useToggle(PREF_DEBUGGER, setShowDebuggerState)
  const setShowPaddles = useToggle(PREF_PADDLES, setShowPaddlesState)
  const setShowDisks = useToggle(PREF_DISKS, setShowDisksState)
  const setShowModem = useToggle(PREF_MODEM, setShowModemState)

  // Ctrl+B is the debugger toggle. Automatically reveal the debugger pane when engaged.
  useEffect(() => {
    const h = (e: KeyboardEvent) => {
      if (isDebuggerToggle(e)) {
        e.preventDefault()
        apple.toggleDebugger()
        setShowDebugger(true)
      }
      setHeld((s) => ({
        ...s,
        shift: e.shiftKey,
        ctrl: e.ctrlKey,
        caps: s.caps,
        appleO: e.code === 'AltLeft' ? true : (s.appleO && e.altKey),
        appleC: e.code === 'AltRight' ? true : (s.appleC && e.altKey),
      }))
      if (e.code === 'CapsLock') setHeld((s) => ({ ...s, caps: !s.caps }))
    }
    const up = (e: KeyboardEvent) => {
      if (e.code === 'ShiftLeft' || e.code === 'ShiftRight') setHeld((s) => ({ ...s, shift: false }))
      if (e.code === 'ControlLeft' || e.code === 'ControlRight')
        setHeld((s) => ({ ...s, ctrl: false }))
      if (e.code === 'AltLeft') setHeld((s) => ({ ...s, appleO: false }))
      if (e.code === 'AltRight') setHeld((s) => ({ ...s, appleC: false }))
    }
    window.addEventListener('keydown', h)
    window.addEventListener('keyup', up)
    return () => {
      window.removeEventListener('keydown', h)
      window.removeEventListener('keyup', up)
    }
  }, [apple, setShowDebugger])

  const press = useCallback(
    (id: string, mods: { shift: boolean; caps: boolean; ctrl: boolean }, btns: number) => {
      // the on-screen CAPS LOCK cap toggles, as the host's Caps Lock key does
      if (id === 'caps') setHeld((s) => ({ ...s, caps: !s.caps }))
      else apple.pressKey(id, mods, btns)
    },
    [apple],
  )

  const onGamepad = useCallback(
    (b: number, x: number, y: number) => {
      setButtons(b)
      setPaddles({ x, y })
      apple.setPaddles(b, x, y)
    },
    [apple],
  )

  const onCommand = useCallback(
    (ch: string) => apple.send([ch.charCodeAt(0)]),
    [apple],
  )

  const hasLeftCol = showConsole || showScreen || showDisks

  return (
    <div className="app">
      <FlashBar
        conn={apple.conn}
        canSerial={apple.canSerial}
        baud={apple.baud}
        progress={apple.diskProgress}
        showScreen={showScreen}
        showConsole={showConsole}
        showDebugger={showDebugger}
        showPaddles={showPaddles}
        showDisks={showDisks}
        showModem={showModem}
        onToggleScreen={() => setShowScreen((s) => !s)}
        onToggleConsole={() => setShowConsole((s) => !s)}
        onToggleDebugger={() => setShowDebugger((s) => !s)}
        onTogglePaddles={() => setShowPaddles((s) => !s)}
        onToggleDisks={() => setShowDisks((s) => !s)}
        onToggleModem={() => setShowModem((s) => !s)}
        onSerial={apple.connectSerial}
        onSerialNoVerify={apple.connectWithoutVerify}
        onDisconnect={apple.disconnect}
        onReconnect={apple.reconnect}
      />

      <main className={!hasLeftCol ? 'no-left-col' : ''}>
        {hasLeftCol && (
          <div className="col-left">
            {showDisks && (
              <DiskPane
                progress={apple.diskProgress}
                error={apple.diskError}
                card={apple.card}
                cardBusy={apple.cardBusy}
                onCardRefresh={apple.refreshCard}
                onCardUpload={apple.uploadToCard}
                onCardDownload={apple.downloadFromCard}
                onCardDelete={apple.deleteFromCard}
                onCardMount={apple.mountCard}
                onClearError={apple.clearDiskError}
                onClose={() => setShowDisks(false)}
                disabled={apple.conn.state !== 'open'}
              />
            )}
            {showConsole && (
              <Console
                lines={apple.lines}
                onClear={apple.clearConsole}
                onClose={() => setShowConsole(false)}
              />
            )}
            {showScreen && (
              <Screen
                screen={apple.screen}
                onCapture={apple.captureScreen}
                busy={apple.busy}
                onClose={() => setShowScreen(false)}
              />
            )}
          </div>
        )}

        <div className="col-right">
          {showModem && (
            <ModemPane
              status={apple.modemStatus}
              log={apple.modemLog}
              gateway={apple.modemGateway}
              onGateway={apple.setModemGateway}
              onHangup={apple.modemHangup}
              onClose={() => setShowModem(false)}
            />
          )}
          {showDebugger && (
            <DebuggerPane
              mode={apple.mode}
              regs={apple.regs}
              mem={apple.mem}
              status={apple.status}
              onCommand={onCommand}
              onClearMem={apple.clearMem}
              onColdBoot={apple.coldBoot}
              onToggle={apple.toggleDebugger}
              onClose={() => setShowDebugger(false)}
            />
          )}
          {showPaddles && (
            <Gamepad
              buttons={buttons}
              x={paddles.x}
              y={paddles.y}
              onChange={onGamepad}
              onClose={() => setShowPaddles(false)}
            />
          )}
          <Keyboard
            mode={apple.mode}
            onPress={press}
            onReset={apple.resetKey}
            onRelease={apple.releaseKeys}
            held={held}
            conn={apple.conn}
            canSerial={apple.canSerial}
            onConnect={apple.connectSerial}
          />
        </div>
      </main>

      <footer className="app-footer">
        <div className="footer-item">
          <span className="footer-label">Web Companion:</span>
          <strong className="footer-val">{versionInfo.display}</strong>
        </div>
        <div className="footer-item">
          <span
            className={`footer-status-dot ${apple.conn.state === 'open' ? 'connected' : ''}`}
            title={apple.conn.state === 'open' ? 'Connected' : 'Disconnected'}
          />
          <span className="footer-label">Firmware:</span>
          <strong
            className={`footer-val ${apple.conn.state === 'open' ? 'clickable' : ''}`}
            onClick={apple.conn.state === 'open' ? () => apple.queryFirmware() : undefined}
            title={apple.conn.state === 'open' ? 'Click to re-query firmware version from board' : undefined}
          >
            {apple.conn.state === 'open'
              ? (apple.firmwareVersion ?? 'Detecting...')
              : 'Not connected'}
          </strong>
          {apple.conn.state === 'open' && (
            <button
              type="button"
              className="shelf-btn-icon"
              style={{ fontSize: '0.75rem', padding: '1px 4px', marginLeft: '4px', verticalAlign: 'middle' }}
              onClick={() => apple.queryFirmware()}
              title="Re-query firmware version from board"
              aria-label="Refresh firmware version"
            >
              ↻
            </button>
          )}
        </div>
      </footer>
    </div>
  )
}
