import { useState } from 'react'
import { validateHardDiskImage, buildCardImage } from '../disk.js'

/**
 * Prepare a TF card on this PC: pick images into slots, choose what each drive
 * loads, and download one card image to write with an imaging tool.  A browser
 * cannot write a disk itself, so this is the fast path for big volumes (the
 * copy through the board runs at the serial link's ~11 KB/s).
 */
export function CardPrep() {
  const [slots, setSlots] = useState<{ name: string; data: Uint8Array }[]>([])
  const [drives, setDrives] = useState<[number | null, number | null]>([0, null])
  const [error, setError] = useState<string | null>(null)

  const add = async (files: FileList | null) => {
    setError(null)
    for (const f of Array.from(files ?? [])) {
      try {
        const data = validateHardDiskImage(await f.arrayBuffer())
        setSlots((s) => [...s, { name: f.name, data }])
      } catch (e: any) {
        setError(`${f.name}: ${e?.message ?? e}`)
      }
    }
  }

  const build = () => {
    try {
      setError(null)
      const { parts } = buildCardImage(
        slots.map((s) => s.data),
        drives,
      )
      const url = URL.createObjectURL(new Blob(parts as unknown as BlobPart[], { type: 'application/octet-stream' }))
      const a = document.createElement('a')
      a.href = url
      a.download = 'apple2e-tfcard.img'
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      setTimeout(() => URL.revokeObjectURL(url), 60000)
    } catch (e: any) {
      setError(e?.message ?? String(e))
    }
  }

  const pick = (d: 0 | 1) => (
    <select
      value={drives[d] ?? ''}
      onChange={(e) => {
        const v = e.target.value === '' ? null : Number(e.target.value)
        setDrives((ds) => (d === 0 ? [v, ds[1] === v ? null : ds[1]] : [ds[0] === v ? null : ds[0], v]))
      }}
    >
      <option value="">empty</option>
      {slots.map((s, i) => (
        <option key={i} value={i}>
          slot {i}: {s.name}
        </option>
      ))}
    </select>
  )

  return (
    <div className="disk-drive-card">
      <div className="disk-drive-header">
        <div className="disk-drive-title">
          <h3>Prepare a TF card on this PC</h3>
        </div>
      </div>
      <div className="disk-drive-body">
        {slots.length === 0 && <span className="disk-meta">No images yet. Each one goes in the next slot.</span>}
        {slots.map((s, i) => (
          <div className="disk-info" key={i}>
            <span className="disk-filename">
              slot {i}: {s.name} ({Math.round(s.data.length / 1024)} KB)
            </span>
          </div>
        ))}
        <label className="btn-disk-action secondary">
          + Add .hdv / .po / .2mg
          <input
            type="file"
            accept=".hdv,.po,.2mg"
            multiple
            style={{ display: 'none' }}
            onChange={(e) => {
              void add(e.target.files)
              e.target.value = ''
            }}
          />
        </label>
        <div className="disk-meta">
          Drive 1 {pick(0)} &nbsp; Drive 2 {pick(1)}
        </div>
        {error && <span className="disk-meta" role="alert">⚠️ {error}</span>}
      </div>
      <div className="disk-drive-actions">
        <button type="button" className="btn-disk-action" onClick={build} disabled={slots.length === 0}>
          ⬇ Download card image
        </button>
        <button type="button" className="btn-disk-action secondary" onClick={() => setSlots([])} disabled={slots.length === 0}>
          Clear
        </button>
      </div>
      <span className="disk-tip">
        Write <code>apple2e-tfcard.img</code> to the card with Raspberry Pi Imager (Use custom), balenaEtcher or
        Win32DiskImager. It replaces everything on the card; say no when Windows then offers to format it.
      </span>
    </div>
  )
}
