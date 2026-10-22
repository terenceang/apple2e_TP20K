"""Assemble src/prodos_hd_rom.s into src/prodos_hd_rom.vh (slot 7's $C700 and $C800 ROMs).

    python scripts/hdrom.py            write the .vh
    python scripts/hdrom.py --check    fail if the .vh does not match the source
    python scripts/hdrom.py --list     print the listing

A two-pass label resolver over py65's assembler, NMOS 6502 opcodes only (the
card must run on an unenhanced //e).  Source: `LABEL:`, `NAME = expr`,
`.org`, `.byte`, `.word`, `.asc "TEXT"` (7-bit), `;` comments.  Expressions:
labels, $hex, decimal, `<`/`>` (low/high byte), and + or - terms.
"""
import re
import sys
from pathlib import Path

from py65.assembler import Assembler
from py65.devices.mpu6502 import MPU

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'src' / 'prodos_hd_rom.s'
OUT = ROOT / 'src' / 'prodos_hd_rom.vh'
SEGS = {'c7': (0xC700, 0x100), 'c8': (0xC800, 0x200)}   # the $C800 ROM is mirrored to $CFFF
# long branches (JEQ target = BNE *+5 / JMP target): the inverse branch's opcode
LONG = {'JEQ': 0xD0, 'JNE': 0xF0, 'JCS': 0x90, 'JCC': 0xB0, 'JMI': 0x10, 'JPL': 0x30}


def value(expr, syms, pc, strict):
    expr = expr.strip()
    lo_hi = None
    if expr[:1] in '<>':
        lo_hi, expr = expr[0], expr[1:]
    total = 0
    for sign, term in re.findall(r'([+-]?)\s*([^+-]+)', expr):
        term = term.strip()
        if term.startswith('$'):
            v = int(term[1:], 16)
        elif term.isdigit():
            v = int(term)
        elif term in syms:
            v = syms[term]
        elif strict:
            raise ValueError(f'unknown symbol {term!r}')
        else:
            v = pc                       # pass 1: a stand-in that keeps the length
        total += -v if sign == '-' else v
    if lo_hi == '<':
        return total & 0xFF
    if lo_hi == '>':
        return (total >> 8) & 0xFF
    return total


def operand_text(op, syms, pc, strict):
    """Replace the expression in an operand with $hex, keeping #, (), ,X/,Y."""
    if not op:
        return ''
    m = re.match(r'^(#?\(?)([^,()]+)(\)?(?:,[XY])?\)?(?:,[XY])?)$', op.replace(' ', ''), re.I)
    if not m:
        raise ValueError(f'cannot parse operand {op!r}')
    pre, expr, post = m.groups()
    v = value(expr, syms, pc, strict)
    # zero page whenever the value fits (labels are all $C700 up, so a
    # length never changes between the passes)
    width = 2 if (pre.startswith('#') or v < 0x100) else 4
    if pre.startswith('#'):
        v &= 0xFF
    return f'{pre}${v:0{width}X}{post}'


def assemble(text):
    asm = Assembler(MPU())
    syms = {}
    for strict in (False, True):
        pc, mem, listing = 0, {}, []
        for n, raw in enumerate(text.splitlines(), 1):
            line = raw.split(';', 1)[0].rstrip()
            if not line.strip():
                continue
            try:
                m = re.match(r'^\s*([A-Za-z_]\w*)\s*=\s*(.+)$', line)
                if m:
                    syms[m.group(1)] = value(m.group(2), syms, pc, True)
                    continue
                m = re.match(r'^([A-Za-z_]\w*):\s*(.*)$', line)
                if m:
                    if not strict:
                        syms[m.group(1)] = pc
                    elif syms[m.group(1)] != pc:
                        raise ValueError(f'{m.group(1)} moved between passes')
                    line = m.group(2)
                line = line.strip()
                if not line:
                    continue
                word, _, rest = line.partition(' ')
                rest = rest.strip()
                d = word.lower()
                if d == '.org':
                    pc = value(rest, syms, pc, True)
                    continue
                if d == '.byte':
                    out = [value(x, syms, pc, strict) & 0xFF for x in rest.split(',')]
                elif d == '.word':
                    out = []
                    for x in rest.split(','):
                        v = value(x, syms, pc, strict)
                        out += [v & 0xFF, (v >> 8) & 0xFF]
                elif d == '.asc':
                    out = [ord(c) & 0x7F for c in re.match(r'^"(.*)"$', rest).group(1)]
                elif word.upper() in LONG:
                    # long branch: the inverse branch over a JMP
                    t = value(rest, syms, pc, strict)
                    out = [LONG[word.upper()], 0x03, 0x4C, t & 0xFF, (t >> 8) & 0xFF]
                else:
                    out = asm.assemble(f'{word} {operand_text(rest, syms, pc, strict)}'.strip(), pc)
                    if not out:
                        raise ValueError(f'py65 cannot assemble {line!r} (a 65C02-only opcode?)')
                    # py65 wraps a branch that does not reach instead of refusing it
                    if strict and word.upper() in ('BPL', 'BMI', 'BVC', 'BVS', 'BCC', 'BCS', 'BNE', 'BEQ'):
                        off = value(rest, syms, pc, True) - (pc + 2)
                        if not -128 <= off <= 127:
                            raise ValueError(f'branch out of range ({off:+d})')
                for i, b in enumerate(out):
                    if pc + i in mem:
                        raise ValueError(f'${pc + i:04X} written twice')
                    mem[pc + i] = b
                listing.append(f'{pc:04X}  {" ".join(f"{b:02X}" for b in out):<9} {raw.rstrip()}')
                pc += len(out)
            except Exception as e:
                sys.exit(f'{SRC.name}:{n}: {e}\n    {raw.strip()}')
    return mem, listing


def segment(mem, base, size):
    for a in mem:
        if not (0xC700 <= a < 0xC700 + 0x100 or 0xC800 <= a < 0xC800 + 0x200):
            sys.exit(f'${a:04X} is outside the card ROMs ($C700-$C7FF, $C800-$C9FF)')
    return [mem.get(base + i, 0) for i in range(size)]


def verilog(mem):
    out = ['// Generated by scripts/hdrom.py from src/prodos_hd_rom.s -- do not edit.',
           '// Included inside prodos_hd: hd_rom_c7 is $C700-$C7FF, hd_rom_c8 $C800-$C9FF',
           '// (mirrored over the rest of $C800-$CFFF).', '']
    for name, (base, size) in SEGS.items():
        data = segment(mem, base, size)
        bits = 8 if size == 0x100 else 9
        out.append(f'function [7:0] hd_rom_{name}(input [{bits - 1}:0] a);')
        out.append('    case (a)')
        for i, b in enumerate(data):
            if b:
                out.append(f"        {bits}'h{i:0{(bits + 3) // 4}X}: hd_rom_{name} = 8'h{b:02X};")
        out.append(f"        default: hd_rom_{name} = 8'h00;")
        out.append('    endcase')
        out.append('endfunction')
        out.append('')
    return '\n'.join(out)


def main():
    mem, listing = assemble(SRC.read_text())
    text = verilog(mem)
    if '--list' in sys.argv:
        print('\n'.join(listing))
    if '--check' in sys.argv:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit(f'{OUT.relative_to(ROOT)} is stale: run python scripts/hdrom.py')
        print(f'{OUT.relative_to(ROOT)} matches {SRC.relative_to(ROOT)}')
        return
    if '--list' not in sys.argv:
        OUT.write_text(text, newline='\n')
        used = {k: sum(1 for a in mem if v[0] <= a < v[0] + v[1]) for k, v in SEGS.items()}
        print(f'wrote {OUT.relative_to(ROOT)}: $C700 page {used["c7"]} bytes, $C800 ROM {used["c8"]} bytes')


if __name__ == '__main__':
    main()
