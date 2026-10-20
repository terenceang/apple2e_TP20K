import { useRef, useState } from 'react'
import type { DriveState, DiskProgress } from '../useApple'

interface Props {
  drives: Record<1 | 2, DriveState>
  progress: DiskProgress | null
  error: string | null
  onUpload: (drive: 1 | 2, file: File) => Promise<void>
  onDownload: (drive: 1 | 2, format: 'dsk' | 'po') => Promise<void>
  onEject: (drive: 1 | 2) => void
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
  onClearError,
  onClose,
  disabled = false,
}: Props) {
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
              {progress.phase === 'uploading' ? 'Uploading to' : 'Downloading from'}{' '}
              Slot 6 Drive {progress.drive}
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
      </div>

      <footer className="disk-pane-footer">
        <span className="disk-tip">
          Supported: 140 KB 5.25" floppy images (143,360 bytes). Logical sector order (.dsk, .do) is automatically translated to physical order for the FPGA.
        </span>
      </footer>
    </section>
  )
}
