# run the fast loader's read routine ($FC82) on py65 against a model of disk2_card
import struct, sys, random
from py65.devices.mpu65c02 import MPU
from py65.memory import ObservableMemory
w = open('scratch/fastloader.woz','rb').read()
trk = int(sys.argv[1]) if len(sys.argv) > 1 else 1
HOLD = int(sys.argv[2]) if len(sys.argv) > 2 else 7
i = w[88 + 4*trk]; sb, nb, bc = struct.unpack_from('<HHI', w, 256 + 8*i)
B = w[sb*512:]; bits = [(B[k>>3] >> (7-(k&7))) & 1 for k in range(bc)]
class Disk:
    def __init__(s, pos): s.t = 0; s.pos = pos; s.sr = 0; s.latch = 0; s.hold = 0; s.bc = 0; s.win = 0; s.rng = random.Random(1)
    def run_to(s, t):            # advance to just before step t
        while s.t < t:
            if s.hold: s.hold -= 1
            if s.bc == 3:
                b = bits[s.pos]; s.pos = (s.pos + 1) % bc
                s.win = ((s.win << 1) | b) & 15
                bi = (s.win >> 1) & 1 if s.win else (s.rng.random() < .25)
                v = ((s.sr << 1) | bi) & 0xff
                if v & 0x80: s.latch = v; s.sr = 0; s.hold = HOLD
                else: s.sr = v
            s.bc = (s.bc + 1) & 3; s.t += 1
    def read(s): return s.latch if s.hold else s.sr
mem = ObservableMemory()
mpu = MPU(memory=mem)
img = open('scratch/fl_fc00.bin','rb').read()
for k, b in enumerate(img): mem[0xFC00 + k] = b
disk = None
RDOFF = {0xAD: 3, 0xAC: 3}       # LDA/LDY abs: the read is the 4th cycle
def rd(addr):
    op = mem[mpu.pc]
    disk.run_to(mpu.processorCycles + RDOFF.get(op, 3))
    return disk.read()
mem.subscribe_to_read([0xC0EC], rd)
ok = bad = 0
for start in range(0, bc, 997):
    disk = Disk(start)
    mpu.pc = 0xFC82; mpu.sp = 0xFD; mem[0x1FE] = 0xFF; mem[0x1FF] = 0xEF  # RTS -> $F000
    mem[0xF000] = 0xDB  # STP
    mpu.processorCycles = 0
    for k in range(32): mem[0xFDCD + k] = 1
    while mpu.pc != 0xF000 and mpu.processorCycles < 400000: mpu.step()
    if mpu.pc != 0xF000 or mpu.a == 0xFF: bad += 1
    elif mpu.a != 0xFF: ok += 1
print('track', trk, 'hold', HOLD, 'sector read', ok, 'stuck/failed', bad)
