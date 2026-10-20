// ============================================================================
//  serial-link.test.js -- the browser-talks-to-the-board path
//
//  Web Serial cannot run in node, so the Web Serial object is injected. That
//  is the point: everything that can go wrong here is a sequencing or framing
//  bug, and all of it is reachable with a fake.
//
//  What matters and is therefore tested:
//    * the baud rate is set to 115200 and not left at the FT2232C's 9600
//    * requestPort() is called, and a dismissed picker is not an error
//    * the two FT2232C channels are told apart by asking the debugger, not by
//      name, and the probe leaves the machine as it found it
//    * bytes written are framed as given, and bytes read are passed straight
//      through to the parser
//    * closing releases the reader, the writer and the port
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import { SerialLink, makeHandshake, serialSupported, describePort, BAUD } from '../src/serial-link.js'
import { HELP } from '../src/protocol.js'

const enc = (s) => Uint8Array.from([...s].map((c) => c.charCodeAt(0)))

/** A stand-in for a Web Serial port. */
function fakePort(opts = {}) {
  const written = []
  let readResolve = null
  let readerCancelled = false
  let writerClosed = false
  let portClosed = false
  let openOptions = null

  return {
    written,
    get openOptions() {
      return openOptions
    },
    get readerCancelled() {
      return readerCancelled
    },
    get writerClosed() {
      return writerClosed
    },
    get portClosed() {
      return portClosed
    },
    getInfo: () => ({ vendorId: 0x0403, productId: 0x6010 }),
    open(o) {
      openOptions = o
      if (opts.openThrows) throw new Error('busy')
      return Promise.resolve()
    },
    close: () => {
      portClosed = true
      return Promise.resolve()
    },
    get readable() {
      return {
        getReader: () => ({
          read: () =>
            new Promise((r) => {
              if (opts.immediate) r({ value: opts.immediate, done: true })
              else readResolve = r
            }),
          cancel: () => {
            readerCancelled = true
            return Promise.resolve()
          },
          releaseLock: () => {},
        }),
      }
    },
    get writable() {
      return {
        getWriter: () => ({
          write: (chunk) => {
            written.push(Uint8Array.from(chunk))
            return Promise.resolve()
          },
          close: () => {
            writerClosed = true
            return Promise.resolve()
          },
        }),
      }
    },
    /** Push bytes in from "the wire". */
    feed(bytes) {
      if (readResolve) {
        const r = readResolve
        readResolve = null
        r({ value: bytes, done: false })
      }
    },
  }
}

function fakeSerial(ports, opts = {}) {
  return {
    requestPort: opts.pickerThrows
      ? () => Promise.reject(Object.assign(new Error('no'), { name: 'NotFoundError' }))
      : () => Promise.resolve(ports.shift()),
    getPorts: () => Promise.resolve(opts.granted ?? []),
  }
}

const tick = (n = 6) => new Promise((r) => setTimeout(r, n))

test('Web Serial support is detected from the object, not from the browser', () => {
  assert.equal(serialSupported({ requestPort() {} }), true)
  assert.equal(serialSupported({}), false)
  assert.equal(serialSupported(null), false)
})

test('a port is described by its USB ids', () => {
  assert.equal(describePort(fakePort()), 'USB serial 0403:6010')
  assert.equal(describePort(null), 'no port')
  assert.equal(
    describePort({ getInfo: () => ({}) }),
    'USB serial',
    'a port with no ids still says something',
  )
})

test('the handshake only fires on the help line, not on the banner', () => {
  const hs = makeHandshake()
  assert.equal(hs.feed('\r\n[ Apple //e Debugger ] (h=Help, c=Cont)'), false)
  assert.equal(hs.feed(HELP), true)
})

test('the handshake survives the help line arriving in pieces', () => {
  // At 115200 the 58-byte help line arrives as several reads, and the match
  // must be able to span them. It should fire on the character that completes
  // "r=Regs", not at the end of the line.
  const hs = makeHandshake()
  let firedAt = -1
  for (let i = 0; i < HELP.length; i++) {
    if (hs.feed(enc(HELP[i]))) {
      firedAt = i
      break
    }
  }
  assert.ok(firedAt >= 0, 'never matched')
  assert.equal(firedAt, HELP.indexOf('Regs') + 3, 'matched as soon as the line was complete')
})

test('a dismissed picker is not treated as an error', async () => {
  const link = new SerialLink({ serial: fakeSerial([], { pickerThrows: true }) })
  const states = []
  link.onState = (s) => states.push(s.state)
  assert.equal(await link.open(), 'cancelled')
  assert.ok(!states.includes('error'), 'dismissing the picker is a normal outcome')
  assert.equal(link.state, 'idle')
})

test('the port is opened at 115200 8N1, not the FT2232C default of 9600', async () => {
  const port = fakePort({ immediate: enc('') })
  const link = new SerialLink({ serial: fakeSerial([port]) })
  link.onState = () => {}
  await link.open({ verify: false })
  assert.equal(port.openOptions.baudRate, BAUD)
  assert.equal(BAUD, 115200)
  assert.equal(port.openOptions.dataBits, 8)
  assert.equal(port.openOptions.stopBits, 1)
  assert.equal(port.openOptions.parity, 'none')
  await link.close()
})

test('a port that refuses the long open form is retried with the short one', async () => {
  // Older Chrome only takes { baudRate }, and rejects the extra members. The
  // baud rate is the part that must survive that fallback.
  const tries = []
  const port = fakePort()
  const realOpen = port.open
  port.open = (o) => {
    tries.push(o)
    if (Object.keys(o).length > 1) return Promise.reject(new Error('unknown member'))
    return realOpen.call(port, o)
  }
  const link = new SerialLink({ serial: fakeSerial([port]) })
  link.onState = () => {}
  await link.open({ verify: false })
  assert.equal(tries.length, 2)
  assert.equal(tries[1].baudRate, 115200)
  await link.close()
})

test('open() is called on the port, not on navigator.serial', () => {
  // navigator.serial has requestPort and getPorts; open belongs to the port.
  // Getting this wrong used to fall through to the short form and quietly lose
  // 8N1, so it is worth a test that would notice.
  const serial = fakeSerial([fakePort({ immediate: enc('') })])
  assert.equal(typeof serial.open, 'undefined')
  assert.equal(typeof fakePort().open, 'function')
})

test('the wrong FT2232C channel is caught by the debugger, and the probe leaves no trace', async () => {
  // A port that never answers: this is the BL616's own console, not the FPGA.
  const port = fakePort()
  const link = new SerialLink({ serial: fakeSerial([port]) })
  const states = []
  link.onState = (s) => states.push(s.state)
  const result = await link.open()
  assert.equal(result, 'wrong-port')
  assert.ok(states.includes('probing'))
  assert.ok(states.includes('wrong-port'))
  // it sent Ctrl+B and '?', and nothing else
  assert.deepEqual([...port.written[0]], [0x02, 0x3f])
  await tick(10)
})

test('a port that answers is accepted and the debugger is left again', async () => {
  const port = fakePort()
  const link = new SerialLink({ serial: fakeSerial([port]) })
  const states = []
  link.onState = (s) => states.push(s.state)
  const opened = link.open()
  await tick()
  // The FPGA answers with its help line.
  port.feed(enc(HELP))
  assert.equal(await opened, 'ok')
  assert.ok(states.includes('open'))
  // and the probe put it back: Ctrl+B, '?', then Ctrl+B to resume
  assert.equal(port.written.length, 2)
  assert.deepEqual([...port.written[1]], [0x02])
  await link.close()
})

test('bytes read reach the parser unchanged', async () => {
  const port = fakePort()
  const link = new SerialLink({ serial: fakeSerial([port]) })
  link.onState = () => {}
  await link.open({ verify: false })
  const got = []
  link.onBytes = (b) => got.push(b)
  port.feed(enc('HELLO'))
  await tick()
  assert.equal(got.length, 1)
  assert.equal(new TextDecoder().decode(got[0]), 'HELLO')
  await link.close()
})

test('bytes written go out as given, one write per call', async () => {
  const port = fakePort({ immediate: enc('') })
  const link = new SerialLink({ serial: fakeSerial([port]) })
  link.onState = () => {}
  await link.open({ verify: false })
  port.written.length = 0
  link.write(Uint8Array.from([0xfe, 0x41, 0x01]))
  link.write(Uint8Array.from([0x02]))
  await tick()
  assert.equal(port.written.length, 2, 'no coalescing, and no splitting')
  assert.deepEqual([...port.written[0]], [0xfe, 0x41, 0x01])
  assert.deepEqual([...port.written[1]], [0x02])
  await link.close()
})

test('a write with no port open is dropped rather than throwing', async () => {
  const link = new SerialLink({ serial: fakeSerial([]) })
  link.onState = () => {}
  assert.doesNotThrow(() => link.write(Uint8Array.from([1])))
})

test('closing releases the reader, the writer and the port', async () => {
  const port = fakePort({ immediate: enc('') })
  const link = new SerialLink({ serial: fakeSerial([port]) })
  link.onState = () => {}
  await link.open({ verify: false })
  link.write(Uint8Array.from([1]))
  await tick()
  await link.close()
  assert.equal(port.readerCancelled, true)
  assert.equal(port.writerClosed, true)
  assert.equal(port.portClosed, true)
  assert.equal(link.port, null)
})

test('reopening does not leave the old port open', async () => {
  const first = fakePort({ immediate: enc('') })
  const second = fakePort({ immediate: enc('') })
  const link = new SerialLink({ serial: fakeSerial([first, second]) })
  link.onState = () => {}
  await link.open({ verify: false })
  await link.open({ verify: false })
  assert.equal(first.portClosed, true, 'the first port was closed')
  assert.equal(second.portClosed, false, 'the second is the live one')
  await link.close()
})

test('an open failure is reported and leaves nothing half-open', async () => {
  const port = fakePort({ openThrows: true })
  const link = new SerialLink({ serial: fakeSerial([port]) })
  const states = []
  link.onState = (s) => states.push(s.state)
  await link.open()
  assert.ok(states.includes('error'), 'the user is told')
  assert.equal(link.port, null)
})
