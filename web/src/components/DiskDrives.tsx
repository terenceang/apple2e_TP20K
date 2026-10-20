import { useRef } from 'react'
import type { DriveState } from '../useApple'

interface Props {
  drives: Record<1 | 2, DriveState>
  diskError: string | null
  onMount: (drive: 1 | 2, file: File) => Promise<void>
  onClearError: () => void
  disabled: boolean
}

/** Two Disk II faceplates; SELECT opens the file dialog and uploads the image. */
export function DiskDrives({ drives, diskError, onMount, onClearError, disabled }: Props) {
  const refs = { 1: useRef<HTMLInputElement>(null), 2: useRef<HTMLInputElement>(null) }

  const drive = (n: 1 | 2) => {
    const d = drives[n]
    return (
      <div className="disk-drive" key={n}>
        <div className="dd-top">
          <span className="dd-name">DISK <i>][</i></span>
          <span className="dd-num">{n}</span>
          <span className={'dd-led' + (d.busy ? ' on' : d.filename ? ' idle' : '')} title="IN USE" />
        </div>
        <div className="dd-slot">
          {d.filename && <span className="dd-label" title={d.filename}>{d.filename}</span>}
        </div>
        <button
          type="button"
          className="dd-select"
          onClick={() => refs[n].current?.click()}
          disabled={disabled || d.busy}
          title={disabled ? 'Connect USB first' : `Choose a .dsk/.do/.po image for drive ${n}`}
        >
          SELECT
        </button>
        <input
          ref={refs[n]}
          type="file"
          accept=".dsk,.do,.po"
          hidden
          onChange={(e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (f) onMount(n, f).catch(() => {}) // failure lands in diskError
          }}
        />
      </div>
    )
  }

  return (
    <div className="disk-drives">
      {drive(1)}
      {drive(2)}
      {diskError && (
        <button type="button" className="dd-error" onClick={onClearError} title="Dismiss">
          ⚠ {diskError} ×
        </button>
      )}
    </div>
  )
}
