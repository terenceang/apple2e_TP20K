import { useEffect, useRef, useState } from 'react'
import type { DiskProgress, CardState, CardFile } from '../useApple'
import { fitsDrive } from '../card.js'
import { blankWoz } from '../woz.js'

// Every drive's disk is a file on the TF card: LOAD picks one (or copies one
// from this computer onto the card first), EJECT empties the drive.  There is
// no other way in, so without a FAT32 card the drives are empty.
interface Props {
  card: CardState | null
  cardBusy: boolean
  progress: DiskProgress | null
  error: string | null
  onCardRefresh: () => Promise<void>
  onCardUpload: (file: File) => Promise<CardFile | null>
  onCardDownload: (f: CardFile, asDsk?: boolean) => Promise<void>
  onCardDelete: (f: CardFile) => Promise<void>
  onCardMount: (d: number, f: CardFile | null) => Promise<void>
  onClearError: () => void
  onClose: () => void
  disabled?: boolean
}

/** Drives in the board's order: slot 6 drives 1-2, slot 7 drives 1-2. */
const LABEL = ['S6,D1', 'S6,D2', 'S7,D1', 'S7,D2']
const ACCEPT = '.dsk,.do,.po,.nib,.woz,.hdv,.2mg'
const kb = (n: number) => (n >= 1 << 20 ? `${(n / (1 << 20)).toFixed(1)} MB` : `${Math.round(n / 1024)} KB`)
const quiet = (p: Promise<unknown>) => void p.catch(() => {}) // the error banner shows it

type Ask =
  | { kind: 'drive'; d: number; file?: CardFile }   // pick a file for drive d, then confirm it
  | { kind: 'confirm_replace'; d: number; file: CardFile; currentName: string }
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

  /** What a drive holds: its card file, or a file the config names but cannot use. */
  const inDrive = (d: number) => {
    const f = card?.drives[d] ?? null
    if (card?.status.present[d] && f) return { name: f.name, file: f, failed: false }
    if (card?.status.fail[d]) return { name: f ? `${f.name}: cannot load` : 'file not on the card', file: null, failed: true }
    return null
  }
  const mountedOn = (f: CardFile) =>
    [0, 1, 2, 3].filter((d) => card?.status.present[d] && card?.drives[d]?.short === f.short)

  const load = (d: number) => setAsk({ kind: 'drive', d })
  const replace = (d: number) => setAsk({ kind: 'drive', d })
  const eject = (d: number) => quiet(p.onCardMount(d, null))
  const fromComputer = (d: number | null) => {
    setAsk(null)
    pickFor.current = d
    pickFile.current?.click()
  }
  const picked = async (file: File) => {
    const d = pickFor.current
    const f = await p.onCardUpload(file)
    if (f && d !== null) {
      const cur = inDrive(d)
      if (cur) {
        setAsk({ kind: 'confirm_replace', d, file: f, currentName: cur.name })
      } else {
        await p.onCardMount(d, f)
      }
    }
  }

  const led = (d: number) => {
    const h = inDrive(d)
    const working = cardBusy || card?.status.loading
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
          {h && (
            <span className={'dd-label' + (h.failed ? ' failed' : '')} title={h.name}>
              <span className="dd-label-text">{h.name}</span>
              <button
                type="button"
                className="dd-eject-btn"
                onClick={(e) => { e.stopPropagation(); eject(d) }}
                title={`Eject ${h.name}`}
                aria-label={`Eject ${h.name}`}
              >
                &times;
              </button>
            </span>
          )}
        </div>
        <div className="dd-buttons">
          {h ? (
            <button
              type="button"
              className="dd-select dd-replace"
              onClick={() => replace(d)}
              disabled={busy || !onCard}
              title={`Replace ${h.name} with another disk image`}
            >
              REPLACE
            </button>
          ) : (
            <button
              type="button"
              className="dd-select"
              onClick={() => load(d)}
              disabled={busy || !onCard}
              title="Load disk image into drive"
            >
              LOAD
            </button>
          )}
          <button
            type="button"
            className="dd-select"
            onClick={() => eject(d)}
            disabled={busy || !h}
            title={h ? `Eject ${h.name}` : undefined}
          >
            EJECT
          </button>
          {h?.file && (
            <details className="dd-more">
              <summary title="More">⋯</summary>
              <div className="dd-menu">
                <button
                  type="button"
                  onClick={() => replace(d)}
                  disabled={busy || !onCard}
                >
                  Replace disk…
                </button>
                <button
                  type="button"
                  onClick={() => quiet(p.onCardDownload(h.file!))}
                  disabled={busy}
                  title="The card's copy: the board writes a track back about a second after the drive goes quiet"
                >
                  Download
                </button>
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
        <div className={'hd-volume' + (h?.failed ? ' failed' : '')} title={h?.name}>
          <span className="hd-volume-text">{h ? h.name : 'empty'}</span>
          {h && (
            <button
              type="button"
              className="dd-eject-btn"
              onClick={(e) => { e.stopPropagation(); eject(d) }}
              title={`Eject ${h.name}`}
              aria-label={`Eject ${h.name}`}
            >
              &times;
            </button>
          )}
        </div>
        <div className="dd-buttons">
          {h ? (
            <button
              type="button"
              className="dd-select dd-replace"
              onClick={() => replace(d)}
              disabled={busy || !onCard}
              title={`Replace ${h.name} with another disk image`}
            >
              REPLACE
            </button>
          ) : (
            <button
              type="button"
              className="dd-select"
              onClick={() => load(d)}
              disabled={busy || !onCard}
              title="Load disk image into drive"
            >
              LOAD
            </button>
          )}
          <button
            type="button"
            className="dd-select"
            onClick={() => eject(d)}
            disabled={busy || !h}
            title={h ? `Eject ${h.name}` : undefined}
          >
            EJECT
          </button>
          {h?.file && (
            <details className="dd-more">
              <summary title="More">⋯</summary>
              <div className="dd-menu">
                <button
                  type="button"
                  onClick={() => replace(d)}
                  disabled={busy || !onCard}
                >
                  Replace disk…
                </button>
                <button
                  type="button"
                  onClick={() => quiet(p.onCardDownload(h.file!))}
                  disabled={busy}
                >
                  Download
                </button>
              </div>
            </details>
          )}
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
    if (ask.kind === 'confirm_replace') {
      return (
        <>
          <h3>Replace disk in {LABEL[ask.d]}?</h3>
          <p className="disk-meta">
            Replace <strong>{ask.currentName}</strong> with <strong>{ask.file.name}</strong> ({kb(ask.file.size)}) in {LABEL[ask.d]}?
          </p>
          <p className="disk-meta" style={{ color: '#d08c2a', marginTop: '6px' }}>
            The current disk will be unmounted and replaced.
          </p>
          <div className="dlg-actions">
            <button
              type="button"
              className="btn-disk-action"
              onClick={() => {
                setAsk(null)
                quiet(p.onCardMount(ask.d, ask.file))
              }}
            >
              Replace
            </button>
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
            {fit.map((d) => {
              const cur = inDrive(d)
              return (
                <button
                  key={d}
                  type="button"
                  className="btn-disk-action"
                  onClick={() => {
                    if (cur) {
                      setAsk({ kind: 'confirm_replace', d, file: ask.file, currentName: cur.name })
                    } else {
                      setAsk(null)
                      quiet(p.onCardMount(d, ask.file))
                    }
                  }}
                >
                  {LABEL[d]}{cur ? ` (replace ${cur.name})` : ''}
                </button>
              )
            })}
            {cancel}
          </div>
        </>
      )
    }
    // a drive: choose its file, then confirm
    if (ask.file) {
      const cur = inDrive(ask.d)
      if (cur) {
        return (
          <>
            <h3>Replace disk in {LABEL[ask.d]}?</h3>
            <p className="disk-meta">
              Replace <strong>{cur.name}</strong> with <strong>{ask.file.name}</strong> ({kb(ask.file.size)}) in {LABEL[ask.d]}?
            </p>
            <p className="disk-meta" style={{ color: '#d08c2a', marginTop: '6px' }}>
              The current disk will be unmounted and replaced.
            </p>
            <div className="dlg-actions">
              <button
                type="button"
                className="btn-disk-action"
                onClick={() => {
                  setAsk(null)
                  quiet(p.onCardMount(ask.d, ask.file!))
                }}
              >
                Replace
              </button>
              {cancel}
            </div>
          </>
        )
      }
      return (
        <>
          <h3>Load {ask.file.name} into {LABEL[ask.d]}?</h3>
          <div className="dlg-actions">
            <button
              type="button"
              className="btn-disk-action"
              onClick={() => {
                setAsk(null)
                quiet(p.onCardMount(ask.d, ask.file!))
              }}
            >
              Load
            </button>
            {cancel}
          </div>
        </>
      )
    }
    const cur = inDrive(ask.d)
    const fit = card?.files.filter((f) => fitsDrive(f, ask.d)) ?? []
    return (
      <>
        <h3>{cur ? `Replace disk in ${LABEL[ask.d]}` : `Load into ${LABEL[ask.d]}`}</h3>
        {cur && <p className="disk-meta">Current disk: <strong>{cur.name}</strong></p>}
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
      <header>
        <h2>Disks</h2>
        <span className="hint">Slot 6 Floppy &amp; Slot 7 SmartPort</span>
        <button
          type="button"
          className="pane-close-btn"
          onClick={p.onClose}
          aria-label="Close disks"
          title="Close disks"
        >
          &times;
        </button>
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

      {status && !status.fsOk && (
        <div className="disk-error-banner" role="status">
          <span>Every drive loads from a FAT32 TF card, and there is none in the board. Insert one (formatted FAT32
            on a PC, 32 GB or smaller) and press ↻.</span>
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
          <div className="shelf-actions">
            <button
              type="button"
              className="shelf-btn-icon"
              onClick={() => fromComputer(null)}
              disabled={busy || !onCard}
              title="Add disk image from computer (.dsk, .po, .nib, .woz, .hdv, .2mg)"
              aria-label="Add disk"
            >
              <span className="icon">＋</span> Add disk
            </button>
            <button
              type="button"
              className="shelf-btn-icon"
              disabled={busy || !onCard}
              onClick={() => quiet(p.onCardUpload(new File([blankWoz() as unknown as BlobPart], `New disk ${Date.now() % 10000}.woz`)))}
              title="Create new blank floppy (.woz) on TF card"
              aria-label="New blank floppy"
            >
              <span className="icon">＋</span> New blank
            </button>
            <button
              type="button"
              className="shelf-btn-icon refresh"
              onClick={() => quiet(p.onCardRefresh())}
              disabled={busy}
              title="Refresh card file list"
              aria-label="Refresh files"
            >
              ↻
            </button>
          </div>
        </div>
        <div className="shelf-tiles">
          {card?.files && card.files.length > 0 ? (
            card.files.map((f) => {
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
                      {/\.woz$/i.test(f.name) && (
                        <button type="button" onClick={() => quiet(p.onCardDownload(f, true))} disabled={busy}
                          title="Decoded to DOS-order sectors; only a standard (unprotected) disk decodes">Download as .dsk</button>
                      )}
                      <button type="button" onClick={() => setAsk({ kind: 'delete', file: f })} disabled={busy || on.length > 0}
                        title={on.length ? 'Eject it first' : undefined}>Delete</button>
                    </div>
                  </details>
                </div>
              )
            })
          ) : (
            <div className="shelf-empty">
              <span>{onCard ? 'No disk images found on card. Click "＋ Add disk" above to upload.' : 'Insert FAT32 card to view images.'}</span>
            </div>
          )}
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
