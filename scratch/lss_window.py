# how many CPU cycles the real P6 sequencer (apple2js SEQUENCER_ROM_16, Sather fig 9.11) shows a finished nibble
import re
src = open(r'C:\Users\teren\AppData\Local\Temp\claude\C--Users-teren-source-repos-apple2e-TP20K\a76dfeda-2677-4ffa-94ca-68aba7ebc81b\scratchpad\a2js\disk2.ts').read()
body = src[src.index('SEQUENCER_ROM_16 = ['):]; body = body[:body.index('] as const')]
rom = [int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{2})', re.sub(r'//.*', '', body))]
assert len(rom) == 256
nibs = [0xFF, 0xD5, 0xAA, 0xAD, 0x96, 0x97, 0xFF, 0xFE, 0xEB, 0x96, 0xD5, 0xAA] * 4
bits = [(n >> (7 - k)) & 1 for n in nibs for k in range(8)]
st = 0; latch = 0; clk = 0; hist = []
for b in bits:
    for c in range(8):                  # 8 LSS clocks a bit cell, 2 per CPU cycle
        pulse = b if c == 4 else 0
        idx = (0 if pulse else 1) | (2 if latch & 0x80 else 0) | (st << 4)
        cmd = rom[idx]
        op = cmd & 15
        if op == 0: latch = 0
        elif op == 9: latch = (latch << 1) & 0xff
        elif op == 0xD: latch = ((latch << 1) | 1) & 0xff
        st = cmd >> 4
        if c & 1: hist.append(latch)    # what a CPU read sees, once per cycle
runs, cur, val = [], 0, None
for v in hist:
    if v & 0x80: cur += 1; val = v
    elif cur: runs.append((hex(val), cur)); cur = 0
print(runs[8:24])
