#!/usr/bin/env python3
"""Fetch Tom Harte's SingleStepTests for the Synertek 65C02 (the 65SC02 kind of
chip an enhanced //e has: no Rockwell bit instructions) and flatten them for
sim/tb_cpusst.v.  Each case is a real chip's state before and after one
instruction plus the address, data and direction of every bus cycle.

    python sim/sst65c02.py [cases-per-opcode]   -> build/sst65c02.txt

Only the first ~90 KB of each opcode's file is fetched (a Range request), so
the whole set is ~23 MB of download, cached in build/sst/.
"""
import json, os, sys, urllib.request

N = int(sys.argv[1]) if len(sys.argv) > 1 else 40
URL = 'https://raw.githubusercontent.com/SingleStepTests/65x02/main/synertek65c02/v1/%02x.json'
CACHE = os.path.join('build', 'sst')
os.makedirs(CACHE, exist_ok=True)


def cases(op):
    path = os.path.join(CACHE, '%02x.part' % op)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        req = urllib.request.Request(URL % op, headers={'Range': 'bytes=0-90000'})
        with urllib.request.urlopen(req) as r, open(path, 'wb') as f:
            f.write(r.read())
    text = open(path, encoding='utf-8').read()
    dec, i, out = json.JSONDecoder(), text.index('[') + 1, []
    while len(out) < N:                         # the file is cut mid-case: stop at the last whole one
        while i < len(text) and text[i] in ' \r\n\t,':
            i += 1
        try:
            obj, i = dec.raw_decode(text, i)
        except json.JSONDecodeError:
            break
        out.append(obj)
    return out


lines = []
for op in range(256):
    for t in cases(op):
        a, b, cyc = t['initial'], t['final'], t['cycles']
        lines.append('%x %x %x %x %x %x %x %x %x %x' % (op, a['pc'], a['s'], a['a'], a['x'], a['y'], a['p'],
                                                       len(a['ram']), len(cyc), len(b['ram'])))
        lines += ['%x %x' % (m, v) for m, v in a['ram']]
        lines += ['%x %x %x' % (m, v if v is not None else 0, c == 'write') for m, v, c in cyc]
        lines.append('%x %x %x %x %x %x' % (b['pc'], b['s'], b['a'], b['x'], b['y'], b['p']))
        lines += ['%x %x' % (m, v) for m, v in b['ram']]
os.makedirs('build', exist_ok=True)
with open(os.path.join('build', 'sst65c02.txt'), 'w') as f:
    f.write('\n'.join(lines) + '\nffff\n')
print('build/sst65c02.txt: %d opcodes x %d cases' % (256, N))
