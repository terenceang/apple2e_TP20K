import { useRef, useState } from 'react'
import type { DriveState, DiskProgress } from '../useApple'
import type { HdStatus } from '../disk.js'
import { CardPrep } from './CardPrep'

interface Props {
  drives: Record<1 | 2, DriveState>
  progress: DiskProgress | null
  error: string | null
  onUpload: (drive: 1 | 2, file: File) => Promise<void>
  onDownload: (drive: 1 | 2, format: 'dsk' | 'po') => Promise<void>
  onEject: (drive: 1 | 2) => void
  hd: HdStatus | null
  hdBusy: boolean
  onHdRefresh: () => Promise<void>
  onHdMount: (drive: 1 | 2, slot: number | null) => Promise<void>
  onHdCopy: (slot: number, file: File) => Promise<void>
  onClearError: () => void
  onClose: () => void
  disabled?: boolean
}

export function DiskPane({
  drives,
  progress,
  error,
  onUpload,
  onDownload,
  onEject,
  hd,
  hdBusy,
  onHdRefresh,
  onHdMount,
  onHdCopy,
  onClearError,
  onClose,
  disabled = false,
}: Props) {
  const [hdSlot, setHdSlot] = useState<Record<1 | 2, string>>({ 1: '', 2: '' })
  const [copySlot, setCopySlot] = useState('')
  const copyInput = useRef<HTMLInputElement>(null)
  const copyN = Number(copySlot)
  const copyValid = copySlot !== '' && Number.isInteger(copyN) && copyN >= 0 && copyN < 0xffff
  const quiet = (p: Promise<void>) => void p.catch(() => {}) // the error banner shows it

  const renderHdDrive = (drive: 1 | 2) => {
    const slot = hd?.slots[drive - 1] ?? null
    const loaded = hd?.present[drive - 1] ?? false
    const n = Number(hdSlot[drive])
    const valid = hdSlot[drive] !== '' && Number.isInteger(n) && n >= 0 && n < 0xffff
    return (
      <div className="disk-info" key={drive}>
        <span className={`disk-led ${hdBusy ? 'busy' : loaded ? 'active' : 'off'}`} />
        <div className="disk-details">
          <span className="disk-filename">Drive {drive}: {slot === null ? 'empty' : `TF slot ${slot}`}</span>
          <span className="disk-meta">
            {slot === null ? 'no volume' : loaded ? '32 MB ProDOS volume, loaded' : 'not loaded'}
          </span>
        </div>
        <input
          type="number"
          min={0}
          max={65534}
          placeholder="slot"
          value={hdSlot[drive]}
          onChange={(e) => setHdSlot((s) => ({ ...s, [drive]: e.target.value }))}
          style={{ width: '5em' }}
          disabled={disabled || hdBusy}
        />
        <button
          type="button"
          className="btn-disk-action"
          onClick={() => quiet(onHdMount(drive, n))}
          disabled={disabled || hdBusy || !valid}
          title="Load this TF card slot into the drive (a full volume takes about 30 s)"
        >
          Mount
        </button>
        <button
          type="button"
          className="btn-disk-action secondary"
          onClick={() => quiet(onHdMount(drive, null))}
          disabled={disabled || hdBusy || slot === null}
        >
          ⏏ Eject
        </button>
      </div>
    )
  }
  const fileInputFloppy1 = useRef<HTMLInputElement>(null)
  const fileInputFloppy2 = useRef<HTMLInputElement>(null)

  const [dragOver1, setDragOver1] = useState(false)
  const [dragOver2, setDragOver2] = useState(false)

  const handleFile = (drive: 1 | 2, files: FileList | null) => {
    if (!files || !files.length) return
    const file = files[0]
    void onUpload(drive, file)
  }

  const renderDriveCard = (
    drive: 1 | 2,
    fileInputRef: React.RefObject<HTMLInputElement | null>,
    dragOver: boolean,
    setDragOver: (v: boolean) => void,
  ) => {
    const d = drives[drive]
    const isBusy = d.busy || progress?.drive === drive
    const hasDisk = Boolean(d.filename)

    return (
      <div
        className={`disk-drive-card ${hasDisk ? 'has-disk' : 'empty'} ${dragOver ? 'drag-over' : ''} ${isBusy ? 'busy' : ''}`}
        onDragOver={(e) => {
          e.preventDefault()
          if (!disabled && !isBusy) setDragOver(true)
        }}
        onDragLeave={() => setDragOver(false)}
        onDrop={(e) => {
          e.preventDefault()
          setDragOver(false)
          if (!disabled && !isBusy && e.dataTransfer.files) {
            handleFile(drive, e.dataTransfer.files)
          }
        }}
      >
        <div className="disk-drive-header">
          <div className="disk-drive-title">
            <span className={`disk-led ${isBusy ? 'busy' : hasDisk ? 'active' : 'off'}`} />
            <h3>Floppy Drive {drive}</h3>
          </div>
          <span className="disk-status-tag">
            {isBusy ? 'Busy' : hasDisk ? 'Mounted' : 'Empty'}
          </span>
        </div>

        <div className="disk-drive-body">
          {hasDisk ? (
            <div className="disk-info">
              <span className="disk-icon" aria-hidden>💾</span>
              <div className="disk-details">
                <span className="disk-filename" title={d.filename ?? ''}>
                  {d.filename}
                </span>
                <span className="disk-meta">140 KB Floppy (35 Tracks)</span>
              </div>
            </div>
          ) : (
            <div
              className="disk-dropzone"
              onClick={() => !disabled && !isBusy && fileInputRef.current?.click()}
            >
              <span className="drop-icon">⇪</span>
              <span>Drop .dsk / .do / .po image here</span>
              <span className="drop-sub">or click to browse</span>
            </div>
          )}

          <input
            ref={fileInputRef}
            type="file"
            accept=".dsk,.do,.po,.bin"
            style={{ display: 'none' }}
            onChange={(e) => {
              handleFile(drive, e.target.files)
              e.target.value = ''
            }}
          />
        </div>

        <div className="disk-drive-actions">
          {hasDisk ? (
            <>
              <button
                type="button"
                className="btn-disk-action"
                onClick={() => onEject(drive)}
                disabled={disabled || isBusy}
                title="Eject this disk"
              >
                ⏏ Eject
              </button>
              <button
                type="button"
                className="btn-disk-action"
                onClick={() => void onDownload(drive, 'dsk')}
                disabled={disabled || isBusy}
                title="Download image from FPGA in DOS 3.3 (.dsk) format"
              >
                ⬇ Save .dsk
              </button>
              <button
                type="button"
                className="btn-disk-action"
                onClick={() => void onDownload(drive, 'po')}
                disabled={disabled || isBusy}
                title="Download image from FPGA in ProDOS (.po) format"
              >
                ⬇ Save .po
              </button>
              <button
                type="button"
                className="btn-disk-action secondary"
                onClick={() => fileInputRef.current?.click()}
                disabled={disabled || isBusy}
                title="Replace disk with a different file"
              >
                Change
              </button>
            </>
          ) : (
            <button
              type="button"
              className="btn-disk-insert"
              onClick={() => fileInputRef.current?.click()}
              disabled={disabled || isBusy}
            >
              Insert Floppy Image...
            </button>
          )}
        </div>
      </div>
    )
  }

  return (
    <section className="pane disk-pane" aria-label="Storage Manager">
      <header className="pane-header">
        <span className="pane-title">💾 Storage Manager</span>
        <button
          type="button"
          className="pane-close"
          onClick={onClose}
          aria-label="Close Storage Pane"
          title="Close"
        >
          ×
        </button>
      </header>

      {error && (
        <div className="disk-error-banner" role="alert">
          <span>⚠️ {error}</span>
          <button type="button" onClick={onClearError} title="Dismiss">
            ×
          </button>
        </div>
      )}

      {progress && (
        <div className="disk-progress-bar-container">
          <div className="disk-progress-labels">
            <span className="progress-phase">
              {progress.drive === 7
                ? 'Copying to TF card'
                : progress.phase === 'uploading'
                  ? 'Uploading to'
                  : 'Downloading from'}{' '}
              {progress.drive === 7 ? (progress.slot !== undefined ? `slot ${progress.slot}` : '') : `Slot 6 Drive ${progress.drive}`}
            </span>
            <span className="progress-detail">{progress.detail}</span>
          </div>
          <div className="progress-track">
            <div
              className="progress-fill"
              style={{ width: `${progress.percent}%` }}
            />
          </div>
        </div>
      )}

      <div className="disk-drives-grid">
        {renderDriveCard(1, fileInputFloppy1, dragOver1, setDragOver1)}
        {renderDriveCard(2, fileInputFloppy2, dragOver2, setDragOver2)}
        <div className={`disk-drive-card ${hd?.present.some(Boolean) ? 'has-disk' : 'empty'} ${hdBusy ? 'busy' : ''}`}>
          <div className="disk-drive-header">
            <div className="disk-drive-title">
              <span className={`disk-led ${hdBusy ? 'busy' : hd?.present.some(Boolean) ? 'active' : 'off'}`} />
              <h3>Slot 7 Hard Disk (TF card)</h3>
            </div>
            <span className="disk-status-tag">
              {hdBusy || hd?.busy
                ? 'Busy'
                : hd === null
                  ? 'Unknown'
                  : hd.error !== null
                    ? `TF error ${hd.error}`
                    : 'Ready'}
            </span>
          </div>
          <div className="disk-drive-body">
            {renderHdDrive(1)}
            {renderHdDrive(2)}
            {progress?.drive === 7 && (
              <div className="hd-copy-progress">
                <div className="hd-copy-progress-header">
                  <span className="hd-copy-tag">
                    Copying to slot {progress.slot ?? copySlot}
                  </span>
                  <span className="hd-copy-percent">{progress.percent}%</span>
                </div>
                <div className="progress-track">
                  <div
                    className="progress-fill"
                    style={{ width: `${progress.percent}%` }}
                  />
                </div>
                <div className="hd-copy-detail">{progress.detail}</div>
              </div>
            )}
          </div>
          <div className="disk-drive-actions">
            <input
              type="number"
              min={0}
              max={65534}
              placeholder="slot"
              value={copySlot}
              onChange={(e) => setCopySlot(e.target.value)}
              style={{ width: '5em' }}
              disabled={disabled || hdBusy}
            />
            <button
              type="button"
              className="btn-disk-action"
              onClick={() => copyInput.current?.click()}
              disabled={disabled || hdBusy || !copyValid}
              title="Copy a .hdv / .po / .2mg image into this TF card slot, through the board. Empty blocks are quick; at 1 Mbps a full 32 MB volume takes about 5.5 minutes."
            >
              {progress?.drive === 7
                ? `⏳ Copying ${progress.percent}%...`
                : '⇪ Copy image to slot'}
            </button>
            <input
              ref={copyInput}
              type="file"
              accept=".hdv,.po,.2mg"
              style={{ display: 'none' }}
              onChange={(e) => {
                const f = e.target.files?.[0]
                e.target.value = ''
                if (f && copyValid) quiet(onHdCopy(copyN, f))
              }}
            />
            <button
              type="button"
              className="btn-disk-action secondary"
              onClick={() => quiet(onHdRefresh())}
              disabled={disabled || hdBusy}
            >
              ↻ Refresh
            </button>
          </div>
        </div>
      </div>

      <div className="disk-drives-grid">
        <CardPrep />
      </div>

      <footer className="disk-pane-footer">
        <span className="disk-tip">
          Supported: 140 KB 5.25" floppy images (143,360 bytes). Logical sector order (.dsk, .do) is automatically translated to physical order for the FPGA. The slot 7 hard disk loads 32 MB ProDOS volumes from numbered slots on the TF card, which you write from a PC with scripts/sdvol.py; ProDOS writes go back to the card.
        </span>
      </footer>
    </section>
  )
}
