import { useEffect, useMemo, useRef, useState } from 'react'
import type { DiskProgress, CardState, CardFile } from '../useApple'
import { fitsDrive } from '../card.js'
import { from83 } from '../fat32.js'
import { blankWoz } from '../woz.js'
import { PREF_DISK_SORT, getSavedString, setSavedString } from '../prefs.js'

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
  | { kind: 'post_upload_mount'; file: CardFile; targetDrive?: number | null }

export type DiskSortMode = 'name-asc' | 'name-desc' | 'size-asc' | 'size-desc' | 'type' | 'mounted' | 'card'

export function DiskPane(p: Props) {
  const { card, cardBusy, disabled = false } = p
  const busy = disabled || cardBusy
  const onCard = Boolean(card?.status.fsOk)
  const [ask, setAsk] = useState<Ask | null>(null)
  const dlg = useRef<HTMLDialogElement>(null)
  const pickFile = useRef<HTMLInputElement>(null)
  const pickFor = useRef<number | null>(null) // drive the next picked file goes into (null: the shelf)

  const store = typeof localStorage !== 'undefined' ? localStorage : null
  const [sortMode, setSortMode] = useState<DiskSortMode>(() =>
    (getSavedString(store, PREF_DISK_SORT, 'name-asc') as DiskSortMode)
  )
  const [filterQuery, setFilterQuery] = useState('')

  const changeSortMode = (m: DiskSortMode) => {
    setSortMode(m)
    setSavedString(store, PREF_DISK_SORT, m)
  }

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

  const diskTooltip = (f: CardFile) => {
    const isFloppy = fitsDrive(f, 0)
    const isHd = fitsDrive(f, 2)
    const typeLabel = isFloppy
      ? '5.25" Floppy Disk II (Slot 6)'
      : isHd
      ? 'SmartPort ProDOS Hard Disk (Slot 7)'
      : 'Disk Image'
    const on = mountedOn(f)
    const mountStatus = on.length > 0
      ? `Mounted in: ${on.map((d) => LABEL[d]).join(', ')}`
      : 'Not mounted (click to load into a drive)'
    const shortName = from83(f.short)

    return [
      `Disk: ${f.name}`,
      `FAT 8.3: ${shortName}`,
      `Size: ${kb(f.size)} (${f.size.toLocaleString()} bytes)`,
      `Type: ${typeLabel}`,
      `Status: ${mountStatus}`,
    ].join('\n')
  }

  const sortedFiles = useMemo(() => {
    if (!card?.files) return []
    let list = [...card.files]
    if (filterQuery.trim()) {
      const q = filterQuery.trim().toLowerCase()
      list = list.filter((f) => f.name.toLowerCase().includes(q) || from83(f.short).toLowerCase().includes(q))
    }
    switch (sortMode) {
      case 'name-asc':
        return list.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }))
      case 'name-desc':
        return list.sort((a, b) => b.name.localeCompare(a.name, undefined, { numeric: true, sensitivity: 'base' }))
      case 'size-asc':
        return list.sort((a, b) => a.size - b.size || a.name.localeCompare(b.name))
      case 'size-desc':
        return list.sort((a, b) => b.size - a.size || a.name.localeCompare(b.name))
      case 'type':
        return list.sort((a, b) => {
          const aFloppy = fitsDrive(a, 0) ? 0 : 1
          const bFloppy = fitsDrive(b, 0) ? 0 : 1
          if (aFloppy !== bFloppy) return aFloppy - bFloppy
          return a.name.localeCompare(b.name)
        })
      case 'mounted':
        return list.sort((a, b) => {
          const aMounted = mountedOn(a).length > 0 ? 0 : 1
          const bMounted = mountedOn(b).length > 0 ? 0 : 1
          if (aMounted !== bMounted) return aMounted - bMounted
          return a.name.localeCompare(b.name)
        })
      case 'card':
      default:
        return list
    }
  }, [card?.files, sortMode, filterQuery, card?.status.present, card?.drives])

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
    if (f) {
      setAsk({ kind: 'post_upload_mount', file: f, targetDrive: d })
    }
  }
  const createBlank = async () => {
    const file = new File([blankWoz() as unknown as BlobPart], `New disk ${Date.now() % 10000}.woz`)
    const f = await p.onCardUpload(file)
    if (f) {
      setAsk({ kind: 'post_upload_mount', file: f, targetDrive: null })
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
            <span className={'dd-label' + (h.failed ? ' failed' : '')} title={h.file ? diskTooltip(h.file) : h.name}>
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
        <div className={'hd-volume' + (h?.failed ? ' failed' : '')} title={h?.file ? diskTooltip(h.file) : h?.name}>
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
    if (ask.kind === 'post_upload_mount') {
      const { file, targetDrive } = ask
      if (targetDrive !== null && targetDrive !== undefined) {
        const cur = inDrive(targetDrive)
        return (
          <>
            <h3>Mount uploaded disk?</h3>
            <p className="disk-meta">
              <strong>{file.name}</strong> ({kb(file.size)}) was uploaded to the TF card.
            </p>
            <p className="disk-meta">
              Mount it into <strong>{LABEL[targetDrive]}</strong>
              {cur ? ` (replacing ${cur.name})` : ''}?
            </p>
            {cur && (
              <p className="disk-meta" style={{ color: '#d08c2a', marginTop: '6px' }}>
                The current disk will be unmounted and replaced.
              </p>
            )}
            <div className="dlg-actions">
              <button
                type="button"
                className="btn-disk-action"
                onClick={() => {
                  setAsk(null)
                  quiet(p.onCardMount(targetDrive, file))
                }}
              >
                {cur ? 'Replace and mount' : `Mount into ${LABEL[targetDrive]}`}
              </button>
              <button
                type="button"
                className="btn-disk-action secondary"
                onClick={() => setAsk(null)}
              >
                Don't mount (keep in library)
              </button>
            </div>
          </>
        )
      }

      const fit = [0, 1, 2, 3].filter((d) => fitsDrive(file, d))
      return (
        <>
          <h3>Mount uploaded disk?</h3>
          <p className="disk-meta">
            <strong>{file.name}</strong> ({kb(file.size)}) was uploaded to the TF card library.
          </p>
          <p className="disk-meta">
            {fit.length > 0 ? 'Would you like to mount it into a drive now?' : 'No compatible drive fits this disk image.'}
          </p>
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
                      setAsk({ kind: 'confirm_replace', d, file, currentName: cur.name })
                    } else {
                      setAsk(null)
                      quiet(p.onCardMount(d, file))
                    }
                  }}
                >
                  Mount into {LABEL[d]}{cur ? ` (replace ${cur.name})` : ''}
                </button>
              )
            })}
            <button
              type="button"
              className="btn-disk-action secondary"
              onClick={() => setAsk(null)}
            >
              Don't mount
            </button>
          </div>
        </>
      )
    }
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
    const sortedFit = [...fit].sort((a, b) => {
      if (sortMode === 'name-desc') return b.name.localeCompare(a.name, undefined, { numeric: true, sensitivity: 'base' })
      if (sortMode === 'size-asc') return a.size - b.size || a.name.localeCompare(b.name)
      if (sortMode === 'size-desc') return b.size - a.size || a.name.localeCompare(b.name)
      return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })
    })
    return (
      <>
        <h3>{cur ? `Replace disk in ${LABEL[ask.d]}` : `Load into ${LABEL[ask.d]}`}</h3>
        {cur && <p className="disk-meta">Current disk: <strong>{cur.name}</strong></p>}
        <div className="dlg-list">
          {sortedFit.length === 0 && <span className="disk-meta">No image on the card fits this drive.</span>}
          {sortedFit.map((f) => (
            <button key={f.short} type="button" className="dlg-file" onClick={() => setAsk({ ...ask, file: f })} title={diskTooltip(f)}>
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
        <div className="pane-title-group">
          <h2>Disks</h2>
          <span className="hint" title="Manage 5.25&quot; floppy disks (Slot 6) and ProDOS hard disks (Slot 7)">
            Slot 6 Floppy &amp; Slot 7 SmartPort
          </span>
        </div>
        <div className="pane-header-actions">
          <button
            type="button"
            className="pane-close-btn"
            onClick={p.onClose}
            aria-label="Close disks"
            title="Close disks"
          >
            &times;
          </button>
        </div>
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
          <div className="shelf-title-wrap">
            <span className="io-card-title" title="Disk Library: Stored disk images on the TF card">
              DISK LIBRARY · TF CARD
            </span>
            <span
              className="shelf-info-icon"
              tabIndex={0}
              role="note"
              aria-label="Disk library information"
              title={
                'Disk Library (FAT32 TF Card)\n\n' +
                'Supported Formats:\n' +
                '• Slot 6 (Disk II 5.25" Floppy):\n' +
                '   .woz, .dsk, .do, .po, .nib (converted to WOZ)\n' +
                '• Slot 7 (SmartPort Hard Disk):\n' +
                '   .hdv, .po, .2mg (up to 32 MB)\n\n' +
                'Requirements:\n' +
                '• FAT32 formatted TF/microSD card (32 GB or smaller)\n' +
                '• Images must be contiguous (unfragmented) on card\n\n' +
                'Usage:\n' +
                '• Click any disk tile to mount into a drive\n' +
                '• "＋ Add disk" to upload from computer\n' +
                '• "＋ New blank" to create a fresh floppy'
              }
            >
              ⓘ
            </span>
            <span className="disk-meta">
              {!status ? 'not read yet' : status.fsOk ? `${card!.files.length} image${card!.files.length === 1 ? '' : 's'}${filterQuery ? ` (${sortedFiles.length} shown)` : ''}`
                : 'no FAT32 card'}
            </span>
          </div>
          <div className="shelf-actions">
            {card?.files && card.files.length > 1 && (
              <label className="shelf-sort-label" title="Sort disk library">
                <span className="sort-icon" aria-hidden>↕</span>
                <select
                  className="shelf-sort-select"
                  value={sortMode}
                  onChange={(e) => changeSortMode(e.target.value as DiskSortMode)}
                  aria-label="Sort disks by"
                >
                  <option value="name-asc">Name (A–Z)</option>
                  <option value="name-desc">Name (Z–A)</option>
                  <option value="size-asc">Size (Smallest)</option>
                  <option value="size-desc">Size (Largest)</option>
                  <option value="type">Type (Floppy first)</option>
                  <option value="mounted">Mounted first</option>
                  <option value="card">Card order</option>
                </select>
              </label>
            )}
            {card?.files && card.files.length > 4 && (
              <div className="shelf-search-wrap">
                <input
                  type="search"
                  className="shelf-search-input"
                  placeholder="Filter..."
                  value={filterQuery}
                  onChange={(e) => setFilterQuery(e.target.value)}
                  aria-label="Filter disk images"
                />
                {filterQuery && (
                  <button
                    type="button"
                    className="shelf-search-clear"
                    onClick={() => setFilterQuery('')}
                    title="Clear filter"
                    aria-label="Clear filter"
                  >
                    ×
                  </button>
                )}
              </div>
            )}
            <button
              type="button"
              className="shelf-btn-icon"
              onClick={() => fromComputer(null)}
              disabled={busy || !onCard}
              title="Add disk image from computer (.dsk, .do, .po, .nib, .woz, .hdv, .2mg) to TF card library"
              aria-label="Add disk"
            >
              <span className="icon">＋</span> Add disk
            </button>
            <button
              type="button"
              className="shelf-btn-icon"
              disabled={busy || !onCard}
              onClick={() => quiet(createBlank())}
              title="Create new blank 140K floppy (.woz) in TF card library"
              aria-label="New blank floppy"
            >
              <span className="icon">＋</span> New blank
            </button>
            <button
              type="button"
              className="shelf-btn-icon refresh"
              onClick={() => quiet(p.onCardRefresh())}
              disabled={busy}
              title="Refresh TF card disk library"
              aria-label="Refresh files"
            >
              ↻
            </button>
          </div>
        </div>
        <div className="shelf-tiles">
          {sortedFiles.length > 0 ? (
            sortedFiles.map((f) => {
              const on = mountedOn(f)
              return (
                <div key={f.short} className={'tile' + (on.length ? ' mounted' : '')} title={diskTooltip(f)}>
                  <button type="button" className="tile-main" onClick={() => setAsk({ kind: 'file', file: f })} disabled={busy}
                    title={diskTooltip(f)}>
                    <span className="tile-icon" aria-hidden>{fitsDrive(f, 0) ? '💾' : '🗄️'}</span>
                    <span className="tile-name">{f.name}</span>
                    <span className="disk-meta">{kb(f.size)}{on.length ? ` · in ${on.map((d) => LABEL[d]).join(', ')}` : ''}</span>
                  </button>
                  <details className="dd-more tile-more">
                    <summary title="More options">⋯</summary>
                    <div className="dd-menu">
                      <button type="button" onClick={() => quiet(p.onCardDownload(f))} disabled={busy}
                        title={`Download copy of ${f.name}`}>
                        Download
                      </button>
                      {/\.woz$/i.test(f.name) && (
                        <button type="button" onClick={() => quiet(p.onCardDownload(f, true))} disabled={busy}
                          title="Decoded to DOS-order sectors; only a standard (unprotected) disk decodes">
                          Download as .dsk
                        </button>
                      )}
                      <button type="button" onClick={() => setAsk({ kind: 'delete', file: f })} disabled={busy || on.length > 0}
                        title={on.length ? `Mounted in ${on.map((d) => LABEL[d]).join(', ')}. Eject it first before deleting.` : `Delete ${f.name} from TF card`}>
                        Delete
                      </button>
                    </div>
                  </details>
                </div>
              )
            })
          ) : filterQuery ? (
            <div className="shelf-empty">
              <span>No disk images match &ldquo;{filterQuery}&rdquo;.</span>
              <button
                type="button"
                className="btn-disk-action secondary"
                onClick={() => setFilterQuery('')}
                style={{ marginTop: '8px' }}
              >
                Clear filter
              </button>
            </div>
          ) : (
            <div className="shelf-empty" title="Insert a FAT32 card or upload images to populate the disk library">
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
