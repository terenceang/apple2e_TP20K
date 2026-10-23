// ============================================================================
//  modem.test.js -- the Hayes modem behind the Super Serial Card, with a fake
//  clock, a fake WebSocket and the Apple's side as plain byte arrays
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'

import { Modem } from '../src/modem.js'

function rig(opts = {}) {
  let t = 0
  const timers = []
  const apple = []
  const lines = []
  const conns = []
  const io = {
    toApple: (b) => apple.push(...b),
    setLines: (dcd, dsr) => lines.push({ dcd, dsr }),
    connect: (url, h) => {
      const c = { url, h, sent: [], closed: false, send: (b) => c.sent.push(...b), close: () => { c.closed = true } }
      conns.push(c)
      return c
    },
    now: () => t,
    setTimer: (fn, ms) => { const x = { at: t + ms, fn }; timers.push(x); return x },
    clearTimer: (x) => { const i = timers.indexOf(x); if (i >= 0) timers.splice(i, 1) },
  }
  const m = new Modem(io, opts)
  const advance = (ms) => {
    const end = t + ms
    for (;;) {
      timers.sort((a, b) => a.at - b.at)
      if (!timers.length || timers[0].at > end) break
      const x = timers.shift()
      t = x.at
      x.fn()
    }
    t = end
  }
  const type = (s) => { for (const c of s) m.fromApple(c.charCodeAt(0)) }
  const said = () => { advance(5000); const s = String.fromCharCode(...apple); apple.length = 0; return s }
  return { m, io, apple, lines, conns, advance, type, said, time: () => t }
}

test('AT commands: OK, echo, verbose and numeric results, ERROR, A/', () => {
  const r = rig()
  r.m.fromDte(true, 14)
  r.type('AT\r')
  assert.equal(r.said(), 'AT\r\n\r\nOK\r\n')
  r.type('ATE0\r')
  assert.equal(r.said(), 'ATE0\r\n\r\nOK\r\n')
  r.type('ATV0\r')
  assert.equal(r.said(), '0\r')
  r.type('ATQ9X\r')                       // Q9 is quiet on, then X
  assert.equal(r.said(), '')
  r.type('ATQ0V1\r')
  assert.equal(r.said(), '\r\nOK\r\n')
  r.type('ATJ\r')
  assert.equal(r.said(), '\r\nERROR\r\n')
  r.type('ATS0=2S0?\r')
  assert.equal(r.said(), '\r\n002\r\n\r\nOK\r\n')
  r.type('A/')                            // echo is off: no CR LF of its own
  assert.equal(r.said(), '\r\n002\r\n\r\nOK\r\n')
  r.type('hello\r')                       // not AT: nothing
  assert.equal(r.said(), '')
})

test('the loopback: CONNECT at the Apple\'s baud, carrier, data both ways, +++ and ATH', () => {
  const r = rig()
  r.m.fromDte(true, 12)                   // 4800
  r.type('ATE0\r'); r.said()
  r.type('ATDT LOOP\r')
  assert.equal(r.said(), '\r\nCONNECT 4800\r\n')
  assert.deepEqual(r.lines.at(-1), { dcd: true, dsr: true })
  r.advance(2000)
  r.type('hi')
  assert.equal(r.said(), 'hi')
  // +++ with a second of quiet each side: command mode, still connected
  r.advance(1200)
  r.type('+++')                           // sent on as data (the loop returns it), then OK
  r.advance(1200)
  assert.equal(r.said(), '+++\r\nOK\r\n')
  r.type('ATO\r')
  assert.equal(r.said(), '\r\nCONNECT 4800\r\n')
  // a + inside data is data
  r.type('a+b')
  assert.equal(r.said(), 'a+b')
  r.advance(1200); r.type('+++'); r.advance(1200); r.said()
  r.type('ATH\r')
  assert.equal(r.said(), '\r\nOK\r\n')
  assert.deepEqual(r.lines.at(-1), { dcd: false, dsr: true })
})

test('dialling a BBS through the gateway, with telnet', () => {
  const r = rig({ gateway: 'wss://gw.example/?host={host}&port={port}' })
  r.m.fromDte(true, 14)
  r.type('ATE0\r'); r.said()
  r.type('ATDT bbs.example.org:6400\r')
  assert.equal(r.conns.length, 1)
  assert.equal(r.conns[0].url, 'wss://gw.example/?host=bbs.example.org&port=6400')
  assert.equal(r.said(), '', 'nothing until the socket opens')
  r.conns[0].h.onOpen()
  assert.equal(r.said(), '\r\nCONNECT 9600\r\n')
  // IAC WILL ECHO, IAC DO NAWS (31), IAC SB ... SE, IAC IAC, text
  r.conns[0].h.onData(Uint8Array.from([255, 251, 1, 255, 253, 31, 255, 250, 24, 1, 255, 240, 0x41, 255, 255, 0x42]))
  r.advance(100)
  assert.deepEqual(r.apple.splice(0), [0x41, 0xff, 0x42])
  assert.deepEqual(r.conns[0].sent, [255, 253, 1, 255, 252, 31], 'DO ECHO, WONT NAWS')
  r.conns[0].sent.length = 0
  r.type('\xff')
  assert.deepEqual(r.conns[0].sent, [255, 255], 'an outgoing 0xFF is doubled')
  // the far end hangs up
  r.conns[0].h.onClose()
  assert.equal(r.said(), '\r\nNO CARRIER\r\n')
  assert.deepEqual(r.lines.at(-1), { dcd: false, dsr: true })
})

test('no gateway: NO DIALTONE; DTR off hangs up; a refused socket is NO ANSWER', () => {
  const r = rig()
  r.m.fromDte(true, 14)
  r.type('ATE0\r'); r.said()
  r.type('ATDT somewhere\r')
  assert.equal(r.said(), '\r\nNO DIALTONE\r\n')
  r.type('ATDT ws://raw.example/\r')
  r.conns[0].h.onOpen()
  r.said()
  r.m.fromDte(false, 14)
  assert.ok(r.conns[0].closed)
  assert.equal(r.said(), '\r\nNO CARRIER\r\n')
  r.m.fromDte(true, 14)
  r.type('ATDT ws://down.example/\r')
  r.conns[1].h.onClose()
  assert.equal(r.said(), '\r\nNO ANSWER\r\n')
})

test('bytes to the Apple are paced at its baud', () => {
  const r = rig()
  r.m.fromDte(true, 6)                    // 300 baud: 30 bytes a second
  r.type('ATE0\r'); r.said()
  r.type('ATDT LOOP\r'); r.said()
  r.m.fromRemote(new Uint8Array(30).fill(0x55))
  r.advance(500)
  assert.ok(r.apple.length >= 13 && r.apple.length <= 18, `${r.apple.length} bytes in half a second at 300 baud`)
  r.advance(1000)
  assert.equal(r.apple.length, 30)
})

test('the wire: FF 06 bytes never carry 0x02 or text, FF 07 lines, and the stream\'s 1E/1F frames', async () => {
  const { encodeSscBytes, encodeModemLines } = await import('../src/protocol.js')
  const { AppleStream } = await import('../src/stream.js')
  const all = encodeSscBytes(Array.from({ length: 256 }, (_, i) => i))
  for (let i = 0; i < 256; i++) {
    const p = all.subarray(i * 4, i * 4 + 4)
    assert.deepEqual([p[0], p[1]], [0xff, 0x06])
    assert.ok(p[2] >= 0xa0 && p[3] >= 0xb0, 'payload is never 0x02, a leader or printable')
    assert.equal(((p[2] & 15) << 4) | (p[3] & 15), i)
  }
  assert.deepEqual([...encodeModemLines(true, true)], [0xff, 0x07, 0xc3])
  assert.deepEqual([...encodeModemLines(false, true)], [0xff, 0x07, 0xc2])

  const st = new AppleStream()
  const out = st.push(Uint8Array.from([0x48, 0x1e, 0x02, 0x49, 0x1f, 0xce, 0x1e, 0x0d, 0x0d, 0x0a]))
  assert.deepEqual(out.events.filter((e) => e.t.startsWith('ssc')),
    [{ t: 'ssc', b: 0x02 }, { t: 'sscst', dtr: true, baud: 14 }, { t: 'ssc', b: 0x0d }])
  assert.deepEqual(st.text.concat(out.text).filter(Boolean).join('|').includes('HI'), true, 'console text around the frames is intact')
})
