import { useEffect, useRef, useState } from 'react'
import type { DriveState, DiskProgress, CardState, CardFile } from '../useApple'
import { fitsDrive } from '../card.js'

interface Props {
  drives: Record<1 | 2, DriveState>
  card: CardState | null
  cardBusy: boolean
  progress: DiskProgress | null
  error: string | null
  onUpload: (drive: 1 | 2, file: File) => Promise<void>
  onDownload: (drive: 1 | 2, format: 'dsk' | 'po') => Promise<void>
  onEject: (drive: 1 | 2) => void
  onCardRefresh: () => Promise<void>
  onCardUpload: (file: File) => Promise<CardFile | null>
  onCardDownload: (f: CardFile) => Promise<void>
  onCardDelete: (f: CardFile) => Promise<void>
  onCardMount: (d: number, f: CardFile | null) => Promise<void>
  onClearError: () => void
  onClose: () => void
  disabled?: boolean
}

/** Drives in the board's order: slot 6 drives 1-2, slot 7 drives 1-2. */
const LABEL = ['S6,D1', 'S6,D2', 'S7,D1', 'S7,D2']
const ACCEPT = '.dsk,.do,.po,.hdv,.2mg'
const kb = (n: number) => (n >= 1 << 20 ? `${(n / (1 << 20)).toFixed(1)} MB` : `${Math.round(n / 1024)} KB`)
const quiet = (p: Promise<unknown>) => void p.catch(() => {}) // the error banner shows it

type Ask =
  | { kind: 'drive'; d: number; file?: CardFile }   // pick a file for drive d, then confirm it
  | { kind: 'file'; file: CardFile }               // pick a drive for this file
  | { kind: 'delete'; file: CardFile }

export function DiskPane(p: Props) {
  const { card, cardBusy, disabled = false } = p
  const busy = disabled || cardBusy
  const onCard = Boolean(card?.status.fsOk)
  const [ask, setAsk] = useState<Ask | null>(null)
  const dlg = useRef<HTMLDialogElement>(null)
  const pickFile = useRef<HTMLInputElement>(null)
  const pickFor = useRef<number | null>(null) // drive the next picked file goes into (null: the shelf)

  useEffect(() => {
    const el = dlg.current
    if (!el) return
    if (ask && !el.open) el.showModal()
    if (!ask && el.open) el.close()
  }, [ask])

  /** What a drive holds: its card file, a file the config names but cannot use, or this page's upload. */
  const inDrive = (d: number) => {
    const f = card?.drives[d] ?? null
    if (card?.status.present[d] && f) return { name: f.name, card: true, failed: false }
    if (card?.status.fail[d]) return { name: f ? `${f.name}: cannot load` : 'file not on the card', card: true, failed: true }
    if (d < 2 && p.drives[(d + 1) as 1 | 2].filename) return { name: p.drives[(d + 1) as 1 | 2].filename!, card: false, failed: false }
    return null
  }
  const mountedOn = (f: CardFile) =>
    [0, 1, 2, 3].filter((d) => card?.status.present[d] && card?.drives[d]?.short === f.short)

  const load = (d: number) => {
    if (onCard) setAsk({ kind: 'drive', d })
    else if (d < 2) {
      pickFor.current = d
      pickFile.current?.click()
    }
  }
  const eject = (d: number) => {
    const h = inDrive(d)
    if (h?.card) quiet(p.onCardMount(d, null))
    else if (d < 2) p.onEject((d + 1) as 1 | 2)
  }
  const fromComputer = (d: number | null) => {
    setAsk(null)
    pickFor.current = d
    pickFile.current?.click()
  }
  const picked = async (file: File) => {
    const d = pickFor.current
    if (!onCard) {
      if (d !== null && d < 2) await p.onUpload((d + 1) as 1 | 2, file)
      return
    }
    const f = await p.onCardUpload(file)
    if (f && d !== null) await p.onCardMount(d, f)
  }

  const led = (d: number) => {
    const h = inDrive(d)
    const working = cardBusy || (d < 2 && p.drives[(d + 1) as 1 | 2].busy) || card?.status.loading
    return 'dd-led' + (working && (h || cardBusy) ? ' on' : h && !h.failed ? ' idle' : '')
  }

  const floppy = (d: number) => {
    const h = inDrive(d)
    return (
      <div className="disk-drive" key={d}>
        <div className="dd-top">
          <span className="dd-name">DISK <i>][</i></span>
          <span className="dd-num">{d + 1}</span>
          <span className={led(d)} title="IN USE" />
        </div>
        <div className="dd-slot">
          {h && <span className={'dd-label' + (h.failed ? ' failed' : '')} title={h.name}>{h.name}</span>}
        </div>
        <div className="dd-buttons">
          <button type="button" className="dd-select" onClick={() => load(d)} disabled={busy}>LOAD</button>
          <button type="button" className="dd-select" onClick={() => eject(d)} disabled={busy || !h}>EJECT</button>
          {h && !h.failed && (
            <details className="dd-more">
              <summary title="More">⋯</summary>
              <div className="dd-menu">
                <button type="button" onClick={() => quiet(p.onDownload((d + 1) as 1 | 2, 'dsk'))} disabled={busy}>Save as .dsk</button>
                <button type="button" onClick={() => quiet(p.onDownload((d + 1) as 1 | 2, 'po'))} disabled={busy}>Save as .po</button>
              </div>
            </details>
          )}
        </div>
      </div>
    )
  }

  const hardDisk = (d: number) => {
    const h = inDrive(d)
    return (
      <div className="hd-unit" key={d}>
        <div className="hd-face">
          <span className={led(d)} title="IN USE" />
          <span className="hd-name">PRODOS {LABEL[d]}</span>
        </div>
        <div className={'hd-volume' + (h?.failed ? ' failed' : '')} title={h?.name}>{h ? h.name : 'empty'}</div>
        <div className="dd-buttons">
          <button type="button" className="dd-select" onClick={() => load(d)} disabled={busy || !onCard}>LOAD</button>
          <button type="button" className="dd-select" onClick={() => eject(d)} disabled={busy || !h}>EJECT</button>
        </div>
      </div>
    )
  }

  const dialog = () => {
    if (!ask) return null
    const cancel = <button type="button" className="btn-disk-action secondary" onClick={() => setAsk(null)}>Cancel</button>
    if (ask.kind === 'delete') {
      return (
        <>
          <h3>Delete {ask.file.name}?</h3>
          <p className="disk-meta">It is removed from the TF card. This cannot be undone.</p>
          <div className="dlg-actions">
            <button type="button" className="btn-disk-action danger"
              onClick={() => { setAsk(null); quiet(p.onCardDelete(ask.file)) }}>Delete</button>
            {cancel}
          </div>
        </>
      )
    }
    if (ask.kind === 'file') {
      const fit = [0, 1, 2, 3].filter((d) => fitsDrive(ask.file, d))
      return (
        <>
          <h3>Load {ask.file.name} into…</h3>
          <p className="disk-meta">{kb(ask.file.size)}. A drive that holds another disk swaps it out.</p>
          <div className="dlg-actions">
            {fit.map((d) => (
              <button key={d} type="button" className="btn-disk-action"
                onClick={() => { setAsk(null); quiet(p.onCardMount(d, ask.file)) }}>
                {LABEL[d]}{inDrive(d) ? ` (now ${inDrive(d)!.name})` : ''}
              </button>
            ))}
            {cancel}
          </div>
        </>
      )
    }
    // a drive: choose its file, then confirm
    if (ask.file) {
      return (
        <>
          <h3>Load {ask.file.name} into {LABEL[ask.d]}?</h3>
          {inDrive(ask.d) && <p className="disk-meta">{inDrive(ask.d)!.name} comes out.</p>}
          <div className="dlg-actions">
            <button type="button" className="btn-disk-action"
              onClick={() => { setAsk(null); quiet(p.onCardMount(ask.d, ask.file!)) }}>Load</button>
            {cancel}
          </div>
        </>
      )
    }
    const fit = card?.files.filter((f) => fitsDrive(f, ask.d)) ?? []
    return (
      <>
        <h3>Load into {LABEL[ask.d]}</h3>
        <div className="dlg-list">
          {fit.length === 0 && <span className="disk-meta">No image on the card fits this drive.</span>}
          {fit.map((f) => (
            <button key={f.short} type="button" className="dlg-file" onClick={() => setAsk({ ...ask, file: f })}>
              <span>{f.name}</span><span className="disk-meta">{kb(f.size)}</span>
            </button>
          ))}
        </div>
        <div className="dlg-actions">
          <button type="button" className="btn-disk-action secondary" onClick={() => fromComputer(ask.d)}>From this computer…</button>
          {cancel}
        </div>
      </>
    )
  }

  const status = card?.status
  return (
    <section className="pane disk-pane" aria-label="Disks">
      <header className="pane-header">
        <span className="pane-title">💾 Disks</span>
        <button type="button" className="pane-close" onClick={p.onClose} aria-label="Close disks" title="Close">×</button>
      </header>

      {p.error && (
        <div className="disk-error-banner" role="alert">
          <span>⚠️ {p.error}</span>
          <button type="button" onClick={p.onClearError} title="Dismiss">×</button>
        </div>
      )}
      {card?.configError && <div className="disk-error-banner" role="alert"><span>⚠️ {card.configError}</span></div>}
      {p.progress && (
        <div className="disk-progress-bar-container">
          <div className="disk-progress-labels"><span className="progress-detail">{p.progress.detail}</span></div>
          <div className="progress-track"><div className="progress-fill" style={{ width: `${p.progress.percent}%` }} /></div>
        </div>
      )}

      <div className="card-row">
        <div className="io-card">
          <div className="io-card-title">SLOT 6 · DISK II</div>
          <div className="disk-drives">{floppy(0)}{floppy(1)}</div>
        </div>
        <div className="io-card">
          <div className="io-card-title">SLOT 7 · PRODOS HARD DISK</div>
          <div className="disk-drives">{hardDisk(2)}{hardDisk(3)}</div>
        </div>
      </div>

      <div className="shelf">
        <div className="shelf-head">
          <span className="io-card-title">TF CARD</span>
          <span className="disk-meta">
            {!status ? 'not read yet' : status.fsOk ? `${card!.files.length} image${card!.files.length === 1 ? '' : 's'}`
              : 'no FAT32 card'}
          </span>
          <button type="button" className="btn-disk-action secondary" onClick={() => quiet(p.onCardRefresh())} disabled={busy}>↻</button>
        </div>
        <div className="shelf-tiles">
          {card?.files.map((f) => {
            const on = mountedOn(f)
            return (
              <div key={f.short} className={'tile' + (on.length ? ' mounted' : '')}>
                <button type="button" className="tile-main" onClick={() => setAsk({ kind: 'file', file: f })} disabled={busy}
                  title={`Load ${f.name}`}>
                  <span className="tile-icon" aria-hidden>{fitsDrive(f, 0) ? '💾' : '🗄️'}</span>
                  <span className="tile-name">{f.name}</span>
                  <span className="disk-meta">{kb(f.size)}{on.length ? ` · in ${on.map((d) => LABEL[d]).join(', ')}` : ''}</span>
                </button>
                <details className="dd-more tile-more">
                  <summary title="More">⋯</summary>
                  <div className="dd-menu">
                    <button type="button" onClick={() => quiet(p.onCardDownload(f))} disabled={busy}>Download</button>
                    <button type="button" onClick={() => setAsk({ kind: 'delete', file: f })} disabled={busy || on.length > 0}
                      title={on.length ? 'Eject it first' : undefined}>Delete</button>
                  </div>
                </details>
              </div>
            )
          })}
          <button type="button" className="tile tile-add" onClick={() => fromComputer(null)} disabled={busy || !onCard}
            title="Copy a disk image onto the card (about 13 s for a floppy; a full 32 MB volume is much faster with a card reader)">
            <span className="tile-icon">＋</span>
            <span className="tile-name">Add disk</span>
          </button>
        </div>
      </div>

      <input ref={pickFile} type="file" accept={ACCEPT} hidden
        onChange={(e) => {
          const f = e.target.files?.[0]
          e.target.value = ''
          if (f) quiet(picked(f))
        }} />

      <dialog ref={dlg} className="disk-dialog" onClose={() => setAsk(null)}>{dialog()}</dialog>
    </section>
  )
}
