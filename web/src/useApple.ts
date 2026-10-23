import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AppleStream } from './stream.js'
import { encodeClock, encodeGamepad, encodeKey, encodeKeysUp, encodeReset, encodeSscBytes, encodeModemLines, CTRL_B, CMD } from './protocol.js'
import { Modem } from './modem.js'
import { SerialLink, serialSupported, BAUD } from './serial-link.js'
import { isLetter, resolve } from './keymap.js'
import { PREF_AUTOCONNECT, getSavedBool, setSavedBool } from './prefs.js'
import { queryCardStatus, type CardStatus } from './disk.js'
import { wozToDsk } from './woz.js'
import { Card } from './card.js'
import type { DirEntry } from './fat32.js'

/** A file on the TF card, as src/fat32.js lists it. */
export type CardFile = DirEntry

export interface CardState {
  files: CardFile[]
  /** The file A2CONFIG.TXT puts in each drive, S6D1 S6D2 S7D1 S7D2 (null: none, or not on the card). */
  drives: (CardFile | null)[]
  configError: string | null
  status: CardStatus
}

export type ConnState =
  | 'idle'
  | 'opening'
  | 'open-unchecked'
  | 'probing'
  | 'open'
  | 'wrong-port'
  | 'error'

export type Transport = 'serial'

export interface Conn {
  state: ConnState
  /** Where we are plugged in, for the status bar. */
  detail: string | null
  transport: Transport | null
  error: string | null
}

export interface SerialState {
  kind: 'serial'
  state: ConnState
  detail: string | null
}

export interface Link {
  kind: 'serial'
  onBytes: (b: Uint8Array) => void
  onState?: (s: SerialState) => void
  write: (b: Uint8Array | number[]) => void
  describe: () => string
  open: (opts?: { verify?: boolean }) => Promise<string>
  close: (opts?: { preserveState?: boolean }) => Promise<void>
}

/** The events stream.js emits, mirroring the wire the firmware sends. */
type AppleEvent =
  | { t: 'mode'; mode: Mode }
  | { t: 'banner' }
  | { t: 'resumed' }
  | { t: 'help' }
  | { t: 'prompt' }
  | { t: 'bell' }
  | { t: 'ssc'; b: number }
  | { t: 'sscst'; dtr: boolean; baud: number }
  | ({ t: 'regs' } & Regs)
  | ({ t: 'mem' } & MemLine)
  | ({ t: 'status' } & Status)
  | {
      t: 'screen'
      text: boolean
      page2: boolean
      mixed: boolean
      hires: boolean
      pll: boolean
      page: Uint8Array
      gfx: Uint8Array
    }

export type Mode = 'console' | 'debugger'

export interface Regs {
  pc: number
  a: number
  x: number
  y: number
  sp: number
  flags: string
  op: number
}

export interface MemLine {
  addr: number
  bytes: number[]
  text: string
}

export interface Status {
  video: 'text' | 'graphics'
  pll: boolean
}

export interface Screen {
  text: boolean
  page2: boolean
  mixed: boolean
  hires: boolean
  pll: boolean
  page: Uint8Array
  gfx: Uint8Array
  at: number
}

export interface DiskProgress {
  drive: 7 // the TF card: every drive's disk is a file on it
  phase: 'uploading' | 'downloading'
  percent: number
  detail: string
}

const MAX_LINES = 4000
const MAX_MEM = 512

/**
 * How long the machine has to be quiet before a queued command goes out.
 *
 * The debugger only reads a command when its main state is idle, and drops
 * anything sent sooner without a word. The banner alone prints two prompts --
 * one at the end of the banner string, one after the register dump -- so
 * neither prompt on its own means "idle". Silence does: a register line is
 * about 45 bytes, which is 4 ms at 115200, so 200 ms of nothing is a very safe
 * "it has finished".
 */
const QUIET_MS = 200

/** How long to wait for a $SEND before giving up on a screen capture. The dump
 *  is 1 KB of hex, about 2.3 KB on the wire, so 220 ms is very nearly 0.25 s of
 *  transmission; this leaves generous headroom and still cannot hang the UI. */
const CAPTURE_TIMEOUT_MS = 4000

const IDLE: Conn = { state: 'idle', detail: null, transport: null, error: null }

export function useApple() {
  const link = useRef<Link | null>(null)

  // The Hayes modem behind slot 1's Super Serial Card (modem.js): the card's
  // line is the USB link, so the modem lives here and dials out by WebSocket.
  const GATEWAY_KEY = 'a2e.modemGateway'
  const loadGateway = () => {
    try { return (typeof localStorage !== 'undefined' && localStorage.getItem(GATEWAY_KEY)) || '' } catch { return '' }
  }
  const [modemGateway, setModemGatewayState] = useState(loadGateway)
  const [modemStatus, setModemStatus] = useState('on hook')
  const [modemLog, setModemLog] = useState<string[]>([])
  const modem = useRef<Modem | null>(null)
  const getModem = useCallback(() => {
    if (!modem.current) {
      modem.current = new Modem(
        {
          toApple: (b: number[]) => link.current?.write(encodeSscBytes(b)),
          setLines: (dcd: boolean, dsr: boolean) => link.current?.write(encodeModemLines(dcd, dsr)),
          connect: (url: string, h: { onOpen: () => void; onData: (b: Uint8Array) => void; onClose: () => void }) => {
            const ws = new WebSocket(url)
            ws.binaryType = 'arraybuffer'
            ws.onopen = () => h.onOpen()
            ws.onmessage = (ev) =>
              h.onData(typeof ev.data === 'string' ? new TextEncoder().encode(ev.data) : new Uint8Array(ev.data as ArrayBuffer))
            ws.onclose = () => h.onClose()
            return {
              send: (b: Uint8Array) => { if (ws.readyState === WebSocket.OPEN) ws.send(b) },
              close: () => ws.close(),
            }
          },
          log: (line: string) => {
            setModemLog((l) => [...l, line].slice(-50))
            setModemStatus(modem.current?.status ?? 'on hook')
          },
        },
        { gateway: loadGateway() },
      )
    }
    return modem.current
  }, [])
  const stream = useRef(new AppleStream())
  const quiet = useRef<ReturnType<typeof setTimeout> | null>(null)
  const queue = useRef<number[]>([])
  const wantResumeAfterScreen = useRef(false)
  const captureTimeout = useRef<ReturnType<typeof setTimeout> | null>(null)

  const [conn, setConn] = useState<Conn>(IDLE)
  const [mode, setMode] = useState<Mode>('console')
  const [lines, setLines] = useState<string[]>([])
  const [regs, setRegs] = useState<Regs | null>(null)
  const [mem, setMem] = useState<MemLine[]>([])
  const [status, setStatus] = useState<Status | null>(null)
  const [screen, setScreen] = useState<Screen | null>(null)
  const [busy, setBusy] = useState(false)
  const [canSerial, setCanSerial] = useState(false)

  useEffect(() => setCanSerial(serialSupported()), [])

  /**
   * Hand a command to the debugger and let the quiet timer release it, so it
   * cannot be dropped by arriving while the machine is still busy.
   */
  const flushQuiet = useCallback(() => {
    if (quiet.current) clearTimeout(quiet.current)
    quiet.current = setTimeout(() => {
      quiet.current = null
      if (queue.current.length) {
        link.current?.write(queue.current)
        queue.current = []
      }
    }, QUIET_MS)
  }, [])

  const release = useCallback(
    (...bytes: number[]) => {
      queue.current.push(...bytes)
      flushQuiet()
    },
    [flushQuiet],
  )

  // --- one place that turns bytes into everything the UI shows -----------
  const onBytes = useCallback(
    (bytes: Uint8Array) => {
      // Any byte at all means the machine is busy, so restart the quiet timer.
      flushQuiet()

      // stream.js is plain JS so node --test can drive it; the event shapes are
      // a discriminated union on `t`, cast once here rather than throughout.
      const { text, events } = stream.current.push(bytes) as {
        text: string[]
        events: AppleEvent[]
      }
      if (text.length) setLines((l) => [...l, ...text].slice(-MAX_LINES))
      for (const e of events) {
        switch (e.t) {
          case 'mode':
            setMode(e.mode)
            break
          case 'regs':
            setRegs(e)
            break
          case 'mem':
            setMem((m2) => [...m2, e].slice(-MAX_MEM))
            break
          case 'status':
            setStatus({ video: e.video, pll: e.pll })
            break
          case 'screen':
            setScreen({
              text: e.text,
              page2: e.page2,
              mixed: e.mixed,
              hires: e.hires,
              pll: e.pll,
              page: e.page,
              gfx: e.gfx,
              at: Date.now(),
            })
            setBusy(false)
            if (captureTimeout.current) {
              clearTimeout(captureTimeout.current)
              captureTimeout.current = null
            }
            if (wantResumeAfterScreen.current) {
              wantResumeAfterScreen.current = false
              release(CMD.cont.charCodeAt(0)) // resume once the dump is home
            }
            break
          case 'bell':
            // Counted only for the tests; the UI does not surface it.
            break
          case 'ssc': {
            const m = getModem()
            m.fromApple(e.b)
            setModemStatus(m.status)
            break
          }
          case 'sscst': {
            const m = getModem()
            m.fromDte(e.dtr, e.baud)
            setModemStatus(m.status)
            break
          }
          default:
            break
        }
      }
    },
    [release, flushQuiet, getModem],
  )

  useEffect(() => {
    return () => {
      if (quiet.current) clearTimeout(quiet.current)
      if (captureTimeout.current) clearTimeout(captureTimeout.current)
      void link.current?.close()
      link.current = null
    }
  }, [])

  const store = typeof localStorage !== 'undefined' ? localStorage : null

  const attach = useCallback(
    (l: Link) => {
      void link.current?.close()
      link.current = l
      l.onBytes = onBytes
      getModem().setCarrier()   // the modem is "on": DSR to the card
      l.onState = (s: SerialState) =>
        setConn({
          state: s.state,
          detail: s.detail,
          transport: 'serial',
          error: s.state === 'error' ? s.detail : null,
        })
    },
    [onBytes, getModem],
  )

  /**
   * Plug the board straight into this browser. Must come from a click, because
   * Web Serial's device picker only opens from a user gesture.
   */
  const connectSerial = useCallback(
    async (opts?: { verify?: boolean; port?: unknown }) => {
      const l = new SerialLink() as unknown as Link
      attach(l)
      setConn({ state: 'opening', detail: null, transport: 'serial', error: null })
      const result = await (l as any).open(opts)
      if (result === 'ok') setSavedBool(store, PREF_AUTOCONNECT, true)
      return result
    },
    [attach, store],
  )

  /**
   * Reconnect without a click: Chrome remembers ports the user has granted
   * (across refresh and restart) and getPorts() returns them with no gesture.
   * The debugger handshake still picks the FT2232's UART channel out of them.
   * Runs on load and whenever a granted board is plugged in or powered up.
   */
  const autoBusy = useRef(false)
  const autoConnect = useCallback(async () => {
    const serial = typeof navigator !== 'undefined' ? (navigator as any).serial : null
    if (!serialSupported(serial) || !getSavedBool(store, PREF_AUTOCONNECT, true)) return
    const st = () => (link.current as any)?.state
    // One run at a time: StrictMode mounts twice and the connect event can fire
    // mid-probe, and two opens of the same port make the second one fail.
    if (autoBusy.current) return
    if (link.current && !['idle', 'error', 'wrong-port'].includes(st())) return
    autoBusy.current = true
    try {
      // A refresh races the old page's hold on the port, which Chrome releases a
      // moment after the document goes: a failed open is retried before it is believed.
      for (let attempt = 0; attempt < 4; attempt++) {
        for (const port of await serial.getPorts()) {
          if ((await connectSerial({ port })) === 'ok') return
        }
        if (st() !== 'error') break
        await new Promise((r) => setTimeout(r, 1000))
      }
      // Leave a failure on screen (a port another tab holds says so); only no ports at all is quiet.
      if (st() !== 'open' && st() !== 'error' && st() !== 'wrong-port') setConn(IDLE)
    } finally {
      autoBusy.current = false
    }
  }, [connectSerial, store])

  useEffect(() => {
    const serial = typeof navigator !== 'undefined' ? (navigator as any).serial : null
    if (!serialSupported(serial)) return
    void autoConnect()
    serial.addEventListener('connect', autoConnect)
    return () => serial.removeEventListener('connect', autoConnect)
  }, [autoConnect])

  const connectWithoutVerify = useCallback(async () => {
    await connectSerial({ verify: false })
  }, [connectSerial])

  const disconnect = useCallback(async () => {
    setSavedBool(store, PREF_AUTOCONNECT, false) // an explicit Disconnect sticks across refresh
    await link.current?.close()
    link.current = null
    setConn(IDLE)
  }, [store])

  const send = useCallback((bytes: number[] | Uint8Array) => link.current?.write(bytes), [])

  /** A keypress. In console mode it goes straight out; in debugger mode the
   *  machine is paused and drops ordinary keystrokes, so letters are commands. */
  const pressKey = useCallback(
    (id: string, mods: { shift?: boolean; caps?: boolean; ctrl?: boolean }, buttons: number) => {
      if (mode === 'debugger') {
        if (isLetter(id)) release(id.toLowerCase().charCodeAt(0))
        return
      }
      const code = resolve(id, mods)
      if (code === null) return
      send(encodeKey(code, buttons))
    },
    [mode, send, release],
  )

  /** The RESET key. The //e's RESET line is CONTROL-gated, so only a press made
   *  with CONTROL down asserts it; a release is always sent. */
  const resetKey = useCallback(
    (down: boolean, buttons: number) => {
      if (mode === 'debugger') return
      send(encodeReset(down, buttons))
    },
    [mode, send],
  )

  /** Ctrl+Open-Apple+RESET: the //e's cold start. The firmware drops keys while
   *  the debugger has the CPU, so leave it first (the toggle needs ~1 s to settle). */
  const coldBoot = useCallback(() => {
    const OPEN_APPLE = 1
    let t = 0
    if (mode === 'debugger') {
      send([CTRL_B])
      t = 1000
    }
    setTimeout(() => send(encodeReset(true, OPEN_APPLE)), t)
    setTimeout(() => send(encodeReset(false, OPEN_APPLE)), t + 300)
  }, [mode, send])

  /** All character keys are up: drops the //e's any-key-down line ($C010 bit 7). */
  const releaseKeys = useCallback(() => {
    if (mode === 'debugger') return
    send(encodeKeysUp())
  }, [mode, send])

  const toggleDebugger = useCallback(() => send([CTRL_B]), [send])

  /** Freeze, dump the screen, and let it run again. */
  const captureScreen = useCallback(() => {
    setBusy(true)
    wantResumeAfterScreen.current = true
    if (mode !== 'debugger') send([CTRL_B])
    // 'w' once the banner and register dump have gone by
    release(CMD.screen.charCodeAt(0))
    // If no frame comes back -- the machine was not in a state to answer, or the
    // port went away -- do not leave the button stuck on "Capturing...".
    if (captureTimeout.current) clearTimeout(captureTimeout.current)
    captureTimeout.current = setTimeout(() => {
      captureTimeout.current = null
      wantResumeAfterScreen.current = false
      setBusy(false)
    }, CAPTURE_TIMEOUT_MS)
  }, [mode, send, release])

  const setPaddles = useCallback(
    (buttons: number, x: number, y: number) => send(encodeGamepad(buttons, x, y)),
    [send],
  )

  const reconnect = useCallback(() => {
    void connectSerial()
  }, [connectSerial])

  const [diskProgress, setDiskProgress] = useState<DiskProgress | null>(null)
  const [diskError, setDiskError] = useState<string | null>(null)

  const cardRef = useRef<() => Promise<void>>(async () => {})
  useEffect(() => {
    if (conn.state !== 'open') return
    // The probe left the debugger again, so the machine is running; the parser
    // may still think the probe's banner is the last word, and a transfer that
    // trusts that never pauses the machine and talks to the keyboard instead.
    stream.current.mode = 'console'
    setMode('console')
    // The slot 5 clock has no battery: give it the time while the parser takes
    // packets (it drops them in the debugger, which reading the card enters).
    link.current?.write(encodeClock(new Date()))
    void cardRef.current().catch(() => {})
  }, [conn.state])

  const [card, setCard] = useState<CardState | null>(null)
  const [cardBusy, setCardBusy] = useState(false)

  /** Talk to the TF card with the machine paused: mount it, run, rescan. */
  const cardSession = useCallback(
    async <T,>(run: (c: Card, l: Link) => Promise<T>): Promise<T> => {
      if (!link.current || conn.state !== 'open') {
        throw new Error('Connect USB serial before using the TF card.')
      }
      setDiskError(null)
      setCardBusy(true)
      const wasConsole = stream.current.mode === 'console'
      try {
        if (wasConsole) {
          send([CTRL_B])
          await new Promise((r) => setTimeout(r, QUIET_MS))
        }
        const l = link.current
        const status = await queryCardStatus(l)
        if (!status.fsOk) {
          setCard({ files: [], drives: [null, null, null, null], configError: null, status })
          throw new Error(status.error !== null
            ? `TF card error (stage ${status.error}): no card, or it did not answer.`
            : 'The TF card is not FAT32. Format it FAT32 on a PC (32 GB or smaller).')
        }
        const c = await Card.open(l)
        const out = await run(c, l)
        const s = await c.scan()
        setCard({ files: s.files, drives: s.drives, configError: s.configError, status: await queryCardStatus(l) })
        return out
      } catch (err: any) {
        setDiskError(err?.message ?? String(err))
        throw err
      } finally {
        setCardBusy(false)
        setDiskProgress(null)
        if (wasConsole) release(CMD.cont.charCodeAt(0))
      }
    },
    [conn.state, send, release],
  )

  const refreshCard = useCallback(() => cardSession(async () => {}), [cardSession])
  cardRef.current = refreshCard

  const progress = (verb: string, name: string) => {
    const t0 = Date.now()
    return (done: number, total: number) => {
      const percent = total ? Math.round((done / total) * 100) : 0
      const elapsed = (Date.now() - t0) / 1000
      const left = done && elapsed > 0 ? (total - done) / (done / elapsed) : 0
      const eta = left >= 60 ? `~${Math.floor(left / 60)}m ${Math.round(left % 60)}s left` : `~${Math.round(left)}s left`
      setDiskProgress({
        drive: 7,
        phase: verb === 'Copying' ? 'uploading' : 'downloading',
        percent,
        detail: `${verb} ${name}: ${Math.round(done / 1024)} / ${Math.round(total / 1024)} KB (${eta})`,
      })
    }
  }

  /** Copy a file from this computer onto the card; returns it as the card lists it. */
  const uploadToCard = useCallback(
    (file: File) =>
      cardSession(async (c) => {
        const data = new Uint8Array(await file.arrayBuffer())
        const made = await c.upload(file.name, data, progress('Copying', file.name))
        const s = await c.scan()
        return s.files.find((f) => f.short === made.short) ?? null
      }),
    [cardSession],
  )

  const downloadFromCard = useCallback(
    (f: CardFile, asDsk = false) =>
      cardSession(async (c) => {
        let data = await c.download(f, progress('Reading', f.name))
        // a .woz of a standard disk, decoded back to DOS-order sectors for other emulators
        if (asDsk) data = wozToDsk(data)
        if (typeof document !== 'undefined') {
          const url = URL.createObjectURL(new Blob([data as unknown as BlobPart], { type: 'application/octet-stream' }))
          const a = document.createElement('a')
          a.href = url
          a.download = asDsk ? f.name.replace(/\.woz$/i, '.dsk') : f.name
          document.body.appendChild(a)
          a.click()
          document.body.removeChild(a)
          setTimeout(() => URL.revokeObjectURL(url), 60000)
        }
      }),
    [cardSession],
  )

  const deleteFromCard = useCallback((f: CardFile) => cardSession((c) => c.remove(f)), [cardSession])

  /** Put a card file in drive d (0-3: S6D1 S6D2 S7D1 S7D2), or empty it; about a second (volumes are read on demand). */
  const mountCard = useCallback(
    (d: number, f: CardFile | null) =>
      cardSession(async (c) => {
        await c.mount(d, f, { onPoll: (status: CardStatus) => setCard((cs) => (cs ? { ...cs, status } : cs)) })
      }),
    [cardSession],
  )

  const clearDiskError = useCallback(() => setDiskError(null), [])

  const clearConsole = useCallback(() => setLines([]), [])

  /** The WebSocket gateway ATDT host:port dials through; {host} and {port} are filled in. */
  const setModemGateway = useCallback((url: string) => {
    setModemGatewayState(url)
    try { localStorage.setItem(GATEWAY_KEY, url) } catch { /* private mode */ }
    getModem().gateway = url
  }, [getModem])
  const modemHangup = useCallback(() => {
    const m = getModem()
    m.hangup(true)
    setModemStatus(m.status)
  }, [getModem])
  const clearMem = useCallback(() => setMem([]), [])

  return useMemo(
    () => ({
      conn,
      canSerial,
      baud: BAUD,
      connectSerial,
      connectWithoutVerify,
      disconnect,
      mode,
      lines,
      regs,
      mem,
      status,
      screen,
      busy,
      diskProgress,
      diskError,
      card,
      cardBusy,
      refreshCard,
      uploadToCard,
      downloadFromCard,
      deleteFromCard,
      mountCard,
      clearDiskError,
      pressKey,
      resetKey,
      coldBoot,
      releaseKeys,
      toggleDebugger,
      captureScreen,
      setPaddles,
      send,
      reconnect,
      clearConsole,
      clearMem,
      modemGateway,
      modemStatus,
      modemLog,
      setModemGateway,
      modemHangup,
    }),
    [
      conn,
      canSerial,
      connectSerial,
      connectWithoutVerify,
      disconnect,
      mode,
      lines,
      regs,
      mem,
      status,
      screen,
      busy,
      diskProgress,
      diskError,
      card,
      cardBusy,
      refreshCard,
      uploadToCard,
      downloadFromCard,
      deleteFromCard,
      mountCard,
      clearDiskError,
      pressKey,
      resetKey,
      coldBoot,
      releaseKeys,
      toggleDebugger,
      captureScreen,
      setPaddles,
      send,
      reconnect,
      clearConsole,
      clearMem,
      modemGateway,
      modemStatus,
      modemLog,
      setModemGateway,
      modemHangup,
    ],
  )
}
