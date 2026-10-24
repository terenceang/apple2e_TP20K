import { CMD, MEM_JUMPS } from '../protocol.js'
import type { MemLine, Mode, Regs, Status } from '../useApple'

interface Props {
  mode: Mode
  regs: Regs | null
  mem: MemLine[]
  status: Status | null
  onCommand: (ch: string) => void
  onClearMem: () => void
  onColdBoot: () => void
  onToggle: () => void
  onClose?: () => void
}

const hex = (n: number, w = 2) => '$' + n.toString(16).toUpperCase().padStart(w, '0')

/** The P register's bits, high to low; the legend under the flags cell. */
const FLAG_NAMES = ['N', 'V', '-', 'B', 'D', 'I', 'Z', 'C']

export function DebuggerPane({
  mode,
  regs,
  mem,
  status,
  onCommand,
  onClearMem,
  onColdBoot,
  onToggle,
  onClose,
}: Props) {
  return (
    <section className="pane debug-pane">
      <header>
        <h2>Debugger</h2>
        <span className="hint">Ctrl+B</span>
        <button type="button" onClick={onToggle}>
          {mode === 'debugger' ? 'Resume' : 'Enter'}
        </button>
        {onClose && (
          <button type="button" onClick={onClose} title="Hide Debugger">
            Hide
          </button>
        )}
      </header>

      <div className="debug-grid">
        <div className="debug-block">
          <h3>Registers</h3>
          {regs ? (
            <table className="regs">
              <tbody>
                <tr>
                  <th>PC</th>
                  <td>{hex(regs.pc, 4)}</td>
                  <th>A</th>
                  <td>{hex(regs.a)}</td>
                </tr>
                <tr>
                  <th>X</th>
                  <td>{hex(regs.x)}</td>
                  <th>Y</th>
                  <td>{hex(regs.y)}</td>
                </tr>
                <tr>
                  <th>SP</th>
                  <td>{hex(regs.sp)}</td>
                  <th>OP</th>
                  <td>{hex(regs.op)}</td>
                </tr>
                <tr>
                  <th>P</th>
                  <td colSpan={3} className="flags">
                    {regs.flags.split('').map((f, i) => (
                    <span key={i} className={f === '-' ? 'off' : 'on'}>
                      {f}
                    </span>
                    ))}
                    <span className="legend"> {FLAG_NAMES.join(' ')}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          ) : (
            <p className="dim">Press Enter to freeze the CPU and read the registers.</p>
          )}
        </div>

        <div className="debug-block">
          <h3>Commands</h3>
          <div className="cmd-row">
            <button onClick={() => onCommand(CMD.regs)} disabled={mode !== 'debugger'}>
              Regs <kbd>r</kbd>
            </button>
            <button onClick={() => onCommand(CMD.step)} disabled={mode !== 'debugger'}>
              Step <kbd>s</kbd>
            </button>
            <button onClick={() => onCommand(CMD.cont)} disabled={mode !== 'debugger'}>
              Continue <kbd>c</kbd>
            </button>
            <button onClick={() => onCommand(CMD.status)} disabled={mode !== 'debugger'}>
              Status <kbd>t</kbd>
            </button>
            <button onClick={() => onCommand(CMD.screen)} disabled={mode !== 'debugger'}>
              Screen <kbd>w</kbd>
            </button>
            <button onClick={() => onCommand(CMD.reset)} disabled={mode !== 'debugger'}>
              CPU reset <kbd>x</kbd>
            </button>
            <button onClick={onColdBoot} title="Ctrl+Open-Apple+RESET: reboot from slot 6">
              Cold boot
            </button>
            <button onClick={() => onCommand(CMD.help)} disabled={mode !== 'debugger'}>
              Help <kbd>?</kbd>
            </button>
          </div>
          <p className="dim small">
            The firmware's own <kbd>?</kbd> lists only r s c m t h; <kbd>x</kbd>,{' '}
            <kbd>g</kbd> and <kbd>w</kbd> work but are not in its help text.
          </p>
        </div>

        <div className="debug-block">
          <h3>Status</h3>
          {status ? (
            <p>
              Video {status.video === 'text' ? 'text' : 'lo-res graphics'}, PLL{' '}
              {status.pll ? 'locked' : 'not locked'}
            </p>
          ) : (
            <p className="dim">Press <kbd>t</kbd> to read the softswitches.</p>
          )}
        </div>
      </div>

      <div className="debug-block mem-block">
        <h3>
          Memory
          <button className="tiny" onClick={onClearMem}>
            clear
          </button>
        </h3>
        <div className="mem-jumps">
          {MEM_JUMPS.map((j) => (
            <button
              key={j.key}
              onClick={() => onCommand(j.key)}
              disabled={mode !== 'debugger'}
              title={`Set the dump address to ${j.label} and dump 16 bytes`}
            >
              {j.label}
            </button>
          ))}
          <button
            onClick={() => onCommand(CMD.mem)}
            disabled={mode !== 'debugger'}
            title="Dump 16 more bytes; the firmware advances the address by 16 each time"
          >
            +16 &nbsp;<kbd>m</kbd>
          </button>
        </div>
        {mem.length === 0 ? (
          <p className="dim">
            Pick an address above, then <kbd>m</kbd> to page forward. The firmware only accepts
            the six preset addresses, and <kbd>m</kbd> adds 16 to the address each time.
          </p>
        ) : (
          <pre className="mem">
            {mem.map((m, i) => (
              <div key={i}>
                <span className="addr">{hex(m.addr, 4)}</span>{' '}
                {m.bytes.map((b, j) => (
                  <span key={j} className={j === 8 ? 'gap' : undefined}>
                    {b.toString(16).toUpperCase().padStart(2, '0')}{' '}
                  </span>
                ))}
                <span className="ascii">|{m.text}|</span>
              </div>
            ))}
          </pre>
        )}
      </div>
    </section>
  )
}
