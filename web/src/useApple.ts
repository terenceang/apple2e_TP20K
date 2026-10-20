import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AppleStream } from './stream.js'
import { encodeGamepad, encodeKey, encodeKeysUp, encodeReset, CTRL_B, CMD } from './protocol.js'
import { SerialLink, serialSupported, BAUD } from './serial-link.js'
import { isLetter, resolve } from './keymap.js'
import { PREF_AUTOCONNECT, getSavedBool, setSavedBool, loadDisk, saveDisk } from './prefs.js'
import {
  validateDiskImage,
  prepareUploadImage,
  prepareDownloadImage,
  uploadDisk,
  downloadDisk,
  diskChecksum,
  queryDiskSums,
} from './disk.js'

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

export interface DriveState {
  filename: string | null
  busy: boolean
}

export interface DiskProgress {
  drive: 1 | 2
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
          default:
            break
        }
      }
    },
    [release, flushQuiet],
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
      l.onState = (s: SerialState) =>
        setConn({
          state: s.state,
          detail: s.detail,
          transport: 'serial',
          error: s.state === 'error' ? s.detail : null,
        })
    },
    [onBytes],
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

  const [drives, setDrives] = useState<Record<1 | 2, DriveState>>({
    1: { filename: null, busy: false },
    2: { filename: null, busy: false },
  })
  const [diskProgress, setDiskProgress] = useState<DiskProgress | null>(null)
  const [diskError, setDiskError] = useState<string | null>(null)

  const uploadDiskFile = useCallback(
    async (drive: 1 | 2, file: File) => {
      if (!link.current || conn.state !== 'open') {
        throw new Error('Connect USB serial before uploading a disk image.')
      }
      setDiskError(null)
      setDrives((d) => ({ ...d, [drive]: { ...d[drive], busy: true } }))
      const wasConsole = stream.current.mode === 'console'

      try {
        const buffer = await file.arrayBuffer()
        const { data, order } = validateDiskImage(buffer, file.name)
        const physical = prepareUploadImage(data, order)

        if (wasConsole) {
          send([CTRL_B])
          await new Promise((r) => setTimeout(r, QUIET_MS))
        }

        // Ask the board first: the image survives in its SDRAM, so an identical
        // one needs no 12 s transfer.
        const sum = diskChecksum(physical)
        const onBoard = (await queryDiskSums(link.current).catch(() => [-1, -1]))[drive - 1] // old firmware: no `i`, just upload

        if (onBoard !== sum) {
          setDiskProgress({
            drive,
              phase: 'uploading',
            percent: 0,
            detail: `Starting upload of ${file.name}...`,
          })
        }

        if (onBoard !== sum) await uploadDisk(link.current, drive, physical, {
          onProgress: (p) => {
            const percent = Math.round((p.track / p.totalTracks) * 100)
            setDiskProgress({
              drive,
                  phase: 'uploading',
              percent,
              detail: `Track ${p.track}/${p.totalTracks} (${percent}%)`,
            })
          },
        })

        saveDisk(store, drive, { filename: file.name, sum })
        setDrives((d) => ({ ...d, [drive]: { filename: file.name, busy: false } }))
        setDiskProgress(null)

        if (wasConsole) {
          release(CMD.cont.charCodeAt(0))
        }
      } catch (err: any) {
        setDrives((d) => ({ ...d, [drive]: { ...d[drive], busy: false } }))
        setDiskProgress(null)
        const msg = err?.message ?? String(err)
        setDiskError(msg)
        if (wasConsole) {
          release(CMD.cont.charCodeAt(0))
        }
        throw err
      }
    },
    [conn.state, mode, send, release, store],
  )

  /**
   * Ask the board what its drives hold and show that, not what this page last
   * did: a power cycle empties them, and another browser may have loaded them.
   * A drive whose checksum matches what we saved gets its filename back.
   */
  const syncDrives = useCallback(async () => {
    if (!link.current || conn.state !== 'open') return
    const wasConsole = stream.current.mode === 'console'
    try {
      if (wasConsole) {
        send([CTRL_B])
        await new Promise((r) => setTimeout(r, QUIET_MS))
      }
      const sums = await queryDiskSums(link.current)
      setDrives((d) => {
        const next = { ...d }
        for (const n of [1, 2] as const) {
          const saved = loadDisk(store, n)
          next[n] = {
            ...d[n],
            filename: sums[n - 1] === 0 ? null : saved && saved.sum === sums[n - 1] ? saved.filename : 'Unknown image',
          }
        }
        return next
      })
    } catch {
      // Firmware without the `i` command: leave the display as it is.
    } finally {
      if (wasConsole) release(CMD.cont.charCodeAt(0))
    }
  }, [conn.state, mode, send, release, store])

  const syncRef = useRef(syncDrives)
  syncRef.current = syncDrives
  useEffect(() => {
    if (conn.state !== 'open') return
    // The probe left the debugger again, so the machine is running; the parser
    // may still think the probe's banner is the last word, and a transfer that
    // trusts that never pauses the machine and talks to the keyboard instead.
    stream.current.mode = 'console'
    setMode('console')
    void syncRef.current()
  }, [conn.state])

  const downloadDiskFile = useCallback(
    async (drive: 1 | 2, format: 'dsk' | 'po' = 'dsk') => {
      if (!link.current || conn.state !== 'open') {
        throw new Error('Connect USB serial before downloading a disk image.')
      }
      setDiskError(null)
      setDrives((d) => ({ ...d, [drive]: { ...d[drive], busy: true } }))
      const wasConsole = stream.current.mode === 'console'

      try {
        if (wasConsole) {
          send([CTRL_B])
          await new Promise((r) => setTimeout(r, QUIET_MS))
        }

        setDiskProgress({
          drive,
          phase: 'downloading',
          percent: 0,
          detail: `Starting download from Drive ${drive}...`,
        })

        const physical = await downloadDisk(link.current, drive, {
          onProgress: (p) => {
            const percent = Math.round((p.bytesReceived / p.totalBytes) * 100)
            setDiskProgress({
              drive,
                  phase: 'downloading',
              percent,
              detail: `${Math.round(p.bytesReceived / 1024)} KB / ${Math.round(p.totalBytes / 1024)} KB (${percent}%)`,
            })
          },
        })

        const fileData = prepareDownloadImage(physical, format)
        setDrives((d) => ({ ...d, [drive]: { ...d[drive], busy: false } }))
        setDiskProgress(null)

        const ext = format === 'po' ? '.po' : '.dsk'
        const baseName = drives[drive].filename
          ? drives[drive].filename!.replace(/\.[^.]+$/, '')
          : `disk${drive}`
        const filename = `${baseName}${ext}`

        if (typeof document !== 'undefined') {
          const blob = new Blob([fileData as unknown as BlobPart], { type: 'application/octet-stream' })
          const url = URL.createObjectURL(blob)
          const a = document.createElement('a')
          a.href = url
          a.download = filename
          document.body.appendChild(a)
          a.click()
          document.body.removeChild(a)
          URL.revokeObjectURL(url)
        }

        if (wasConsole) {
          release(CMD.cont.charCodeAt(0))
        }
      } catch (err: any) {
        setDrives((d) => ({ ...d, [drive]: { ...d[drive], busy: false } }))
        setDiskProgress(null)
        const msg = err?.message ?? String(err)
        setDiskError(msg)
        if (wasConsole) {
          release(CMD.cont.charCodeAt(0))
        }
        throw err
      }
    },
    [conn.state, mode, send, release, drives],
  )

  const ejectDisk = useCallback((drive: 1 | 2) => {
    setDrives((d) => ({ ...d, [drive]: { filename: null, busy: false } }))
  }, [])

  const clearDiskError = useCallback(() => setDiskError(null), [])

  const clearConsole = useCallback(() => setLines([]), [])
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
      drives,
      diskProgress,
      diskError,
      uploadDiskFile,
      downloadDiskFile,
      ejectDisk,
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
      drives,
      diskProgress,
      diskError,
      uploadDiskFile,
      downloadDiskFile,
      ejectDisk,
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
    ],
  )
}
