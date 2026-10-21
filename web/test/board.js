// A board for the tests: the debugger's TF card commands (b, u, i, y) on an
// in-memory card, framed the way src/serial_debugger.v frames them.  y does
// the lookup src/sd_vol.v does -- A2CONFIG.TXT, the 8.3 name, one run of
// clusters, the size rule -- with the page's own FAT code.

import { ACK_BYTE } from '../src/disk.js'
import { Fat32, memoryDevice, from83 } from '../src/fat32.js'
import { CONFIG_NAME, DRIVES, parseConfig } from '../src/config.js'
import { fitsDrive } from '../src/card.js'

export function createMockLink() {
  const written = []
  let onBytes = () => {}
  return {
    written,
    get onBytes() { return onBytes },
    set onBytes(fn) { onBytes = fn },
    write(bytes) { written.push(bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes)) },
    feed(data) {
      onBytes(typeof data === 'string' ? new TextEncoder().encode(data) : Uint8Array.from(data))
    },
  }
}

/** @param {Uint8Array} img the card */
export function createCardBoard(img) {
  const link = createMockLink()
  const write = link.write.bind(link)
  const present = [false, false, false, false]
  const fail = [false, false, false, false]
  let busy = false
  let up = null // the u write in progress: { lba, rx }
  const status = () =>
    present.reduce((s, p, i) => s | (p ? 1 << i : 0), 0) |
    fail.reduce((s, p, i) => s | (p ? 1 << (i + 4) : 0), 0) | 0x200 | (busy ? 0x4000 : 0)

  async function reload(d) {
    busy = true
    present[d] = false
    fail[d] = false
    const fs = await new Fat32(memoryDevice(img)).mount()
    const files = await fs.list()
    const cf = files.find((f) => f.name.toUpperCase() === CONFIG_NAME)
    const name = cf ? parseConfig(new TextDecoder().decode(await fs.readFile(cf)))[DRIVES[d]] : null
    if (name) {
      const f = files.find((x) => from83(x.short) === name)
      if (f && fitsDrive(f, d) && (await fs.extent(f))) present[d] = true
      else fail[d] = true
    }
    busy = false
  }

  link.write = (bytes) => {
    write(bytes)
    const arr = [...bytes]
    if (up) {
      up.rx.push(...arr)
      while (up && up.rx.length) {
        const rx = up.rx
        if (rx[0] === 1 && rx.length >= 513) {
          img.set(rx.slice(1, 513), up.lba++ * 512)
          up.rx = rx.slice(513)
        } else if (rx[0] === 0 && rx.length >= 3) {
          const n = ((rx[1] << 8) | rx[2]) + 1
          img.fill(0, up.lba * 512, (up.lba + n) * 512)
          up.lba += n
          up.rx = rx.slice(3)
        } else if (rx[0] === 2) {
          up = null
          queueMicrotask(() => link.feed('\r\ndone\r\n'))
          return
        } else break
        queueMicrotask(() => link.feed([ACK_BYTE]))
      }
      return
    }
    const t = new TextDecoder().decode(Uint8Array.from(arr))
    let m
    if ((m = /^b([0-9A-F]{8})([0-9A-F]{4})$/.exec(t))) {
      const lba = parseInt(m[1], 16), n = parseInt(m[2], 16)
      queueMicrotask(() => {
        if ((lba + n) * 512 > img.length) return link.feed('\r\nSECTORS\r\n\r\nlost\r\n')
        link.feed('\r\nSECTORS\r\n')
        link.feed(img.subarray(lba * 512, (lba + n) * 512))
        link.feed('\r\ndone\r\n')
      })
    } else if ((m = /^u([0-9A-F]{8})$/.exec(t))) {
      up = { lba: parseInt(m[1], 16), rx: [] }
      queueMicrotask(() => link.feed('\r\nUPLOAD HD\r\n'))
    } else if (t === 'i') {
      queueMicrotask(() => link.feed(`\r\nI1:00000000 I2:00000000 H:00 S:${status().toString(16).toUpperCase().padStart(4, '0')}\r\n> `))
    } else if ((m = /^y([1-4])$/.exec(t))) {
      busy = true
      void reload(Number(m[1]) - 1)
      queueMicrotask(() => link.feed('\r\n> '))
    }
  }
  return { link, img, present, fail }
}
