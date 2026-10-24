"""Run slot 7's firmware (src/prodos_hd_rom.s) on py65's NMOS 6502 against a
model of src/prodos_hd.v's registers, and check the ProDOS block entry and
every SmartPort call against the Apple IIc Technical Reference, chapter 6.

    python scripts/hdrom_test.py      prints PASS, or FAIL lines and exits 1

The model: $C0F3=1 fetches the block (busy a few reads), $C0F0 hands out the
byte fetched last and fetches the next, a write's byte 511 sends the block
(busy a few reads), $C0F4 bit 7 busy / bit 1 present / bit 0 last read
failed, $C0F6/7 the selected drive's size (0 with no volume).  The $C800 ROM
is the card's after any $C7xx access, until $CFFF.
"""
import sys
from pathlib import Path

from py65.devices.mpu6502 import MPU

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hdrom import SRC, assemble  # noqa: E402

ROM, _ = assemble(SRC.read_text())


class Card:
    def __init__(self, sizes, present):
        self.size = list(sizes)
        self.present = list(present)
        self.vol = [bytearray((i * 7 + d * 13 + (i >> 9)) & 0xFF for i in range(s * 512)) for d, s in enumerate(sizes)]
        self.blk = self.drv = self.ptr = self.data = 0
        self.busy = 0
        self.rb_ok = True
        self.fail_reads = False       # make the next block fetch fail
        self.writes = []              # blocks handed to the TF card

    def read(self, a):
        r = a & 0xF
        if r == 0:
            d = self.data
            self.ptr += 1
            if self.ptr < 512:
                self.data = self.vol[self.drv][self.blk * 512 + self.ptr]
            return d
        if r == 4:
            busy = self.busy > 0
            self.busy = max(0, self.busy - 1)
            return (0x80 if busy else 0) | (0x02 if self.present[self.drv] else 0) | (0 if self.rb_ok else 1)
        if r == 6:
            return self.size[self.drv] & 0xFF if self.present[self.drv] else 0
        if r == 7:
            return self.size[self.drv] >> 8 if self.present[self.drv] else 0
        return 0

    def write(self, a, v):
        r = a & 0xF
        if r == 0:
            self.vol[self.drv][self.blk * 512 + self.ptr] = v
            if self.ptr == 511:
                self.writes.append((self.drv, self.blk))
                self.busy = 3
            self.ptr += 1
        elif r == 1:
            self.blk = (self.blk & 0xFF00) | v
        elif r == 2:
            self.blk = (self.blk & 0xFF) | v << 8
        elif r == 3:
            self.ptr = 0
            if v == 1:
                self.rb_ok = not self.fail_reads and self.blk < self.size[self.drv]
                self.busy = 4
                self.data = self.vol[self.drv][self.blk * 512] if self.rb_ok else 0xEE
        elif r == 5:
            self.drv = v & 1


class Bus:
    """The Apple's address space, with slot 7 in it."""
    def __init__(self, card):
        self.ram = bytearray(0x10000)
        self.card = card
        self.c8_ours = False
        self.touched_cfff = False

    def _slot(self, a):
        if 0xC700 <= a <= 0xC7FF:
            self.c8_ours = True
        elif a == 0xCFFF:
            self.c8_ours = False
            self.touched_cfff = True

    def __getitem__(self, a):
        a &= 0xFFFF
        self._slot(a)
        if 0xC0F0 <= a <= 0xC0FF:
            return self.card.read(a)
        if 0xC700 <= a <= 0xC7FF:
            return ROM.get(a, 0)
        if 0xC800 <= a <= 0xCFFF:
            return ROM.get(0xC800 + (a & 0x1FF), 0) if self.c8_ours else 0xA5   # someone else's ROM
        return self.ram[a]

    def __setitem__(self, a, v):
        a &= 0xFFFF
        self._slot(a)
        if 0xC0F0 <= a <= 0xC0FF:
            self.card.write(a, v)
        elif a < 0xC000:
            self.ram[a] = v & 0xFF


fails = 0


def check(cond, what):
    global fails
    if not cond:
        fails += 1
        print('FAIL:', what)


def run(bus, code, decimal=False, c8_owned_elsewhere=True, limit=200000):
    """Put `code` at $0300, run it until it returns to $0300+len, return the MPU."""
    for i, b in enumerate(code):
        bus.ram[0x300 + i] = b
    bus.c8_ours = not c8_owned_elsewhere
    mpu = MPU(memory=bus, pc=0x300)
    mpu.sp = 0xF0
    mpu.p |= mpu.DECIMAL if decimal else 0
    end = 0x300 + len(code)
    low_sp = mpu.sp
    for _ in range(limit):
        if mpu.pc == end:
            break
        mpu.step()
        low_sp = min(low_sp, mpu.sp)
        if mpu.pc < 0x200 or mpu.pc == 0:
            break
    else:
        check(False, f'code at $0300 did not return (pc ${mpu.pc:04X})')
    check(mpu.pc == end, f'returned to ${mpu.pc:04X}, not ${end:04X}')
    check(mpu.sp == 0xF0, f'stack unbalanced: SP ${mpu.sp:02X}')
    check(0xF0 - low_sp <= 35, f'{0xF0 - low_sp} bytes of stack (the SmartPort may use 35)')
    return mpu


def sp_call(bus, cmd, plist, **kw):
    """JSR $C72C / .byte cmd / .word $0280, with the parameter list at $0280."""
    for i, b in enumerate(plist):
        bus.ram[0x280 + i] = b
    mpu = run(bus, [0x20, 0x2C, 0xC7, cmd, 0x80, 0x02], **kw)
    carry = bool(mpu.p & mpu.CARRY)
    return mpu.a, carry, mpu.x, mpu.y


def blk_call(bus, cmd, unit, buf, block):
    bus.ram[0x42:0x48] = bytes([cmd, unit, buf & 0xFF, buf >> 8, block & 0xFF, block >> 8])
    mpu = run(bus, [0x20, 0x29, 0xC7])
    return mpu.a, bool(mpu.p & mpu.CARRY), mpu.x, mpu.y


def err(res, code, what):
    a, c, _, _ = res
    check(c and a == code, f'{what}: A=${a:02X} C={int(c)}, want error ${code:02X}')


def ok(res, what):
    a, c, _, _ = res
    check(not c and a == 0, f'{what}: A=${a:02X} C={int(c)}, want success')


LIST = 0x0400   # status lists and buffers


def main():
    card = Card(sizes=[300, 1600], present=[True, False])
    bus = Bus(card)

    # ---- the signature and the ID bytes ----
    sig = {0xC701: 0x20, 0xC703: 0x00, 0xC705: 0x03, 0xC707: 0x00, 0xC7FB: 0x00,
           0xC7FC: 0x00, 0xC7FD: 0x00, 0xC7FE: 0x9F, 0xC7FF: 0x29}
    for a, v in sig.items():
        check(ROM.get(a, 0) == v, f'${a:04X} = ${ROM.get(a, 0):02X}, want ${v:02X}')

    # ---- STATUS unit 0: the SmartPort ----
    r = sp_call(bus, 0x00, [3, 0, LIST & 0xFF, LIST >> 8, 0])
    ok(r, 'STATUS unit 0')
    check(r[2:] == (8, 0), f'STATUS unit 0 returned {r[2]}+{r[3]}*256 bytes, want 8')
    check(bytes(bus.ram[LIST:LIST + 8]) == bytes([2, 0x40, 0, 0, 0, 0, 0, 0]), 'STATUS unit 0 list')
    err(sp_call(bus, 0x00, [3, 0, LIST & 0xFF, LIST >> 8, 3]), 0x21, 'STATUS unit 0 code 3')

    # ---- STATUS code 0 of each drive ----
    r = sp_call(bus, 0x00, [3, 1, LIST & 0xFF, LIST >> 8, 0])
    ok(r, 'STATUS unit 1')
    check(r[2:] == (4, 0), 'STATUS unit 1 byte count')
    check(bytes(bus.ram[LIST:LIST + 4]) == bytes([0xF8, 300 & 0xFF, 300 >> 8, 0]), f'STATUS unit 1 list {bytes(bus.ram[LIST:LIST + 4]).hex()}')
    r = sp_call(bus, 0x00, [3, 2, LIST & 0xFF, LIST >> 8, 0])
    ok(r, 'STATUS unit 2 (no volume)')
    check(bytes(bus.ram[LIST:LIST + 4]) == bytes([0xE8, 0, 0, 0]), 'STATUS unit 2: not on line, no blocks')

    # ---- the DIB ----
    for unit in (1, 2):
        bus.ram[LIST:LIST + 32] = bytes(32)
        r = sp_call(bus, 0x00, [3, unit, LIST & 0xFF, LIST >> 8, 3])
        ok(r, f'DIB unit {unit}')
        check(r[2:] == (0x19, 0), f'DIB unit {unit}: {r[2]} bytes, want 25')
        dib = bytes(bus.ram[LIST:LIST + 25])
        check(dib[4] == 12 and dib[5:21] == f'TF CARD S7D{unit}    '.encode(), f'DIB unit {unit} name {dib[4:21]!r}')
        check(dib[21:25] == bytes([0x02, 0x00, 0x00, 0x01]), f'DIB unit {unit} type/subtype/version {dib[21:25].hex()}')
        check(all(b < 0x80 for b in dib[5:21]), 'DIB name is 7-bit')
    check(bytes(bus.ram[LIST:LIST + 4]) == bytes([0xE8, 0, 0, 0]), 'DIB unit 2 head')
    for code in (1, 2, 5, 0xFF):
        err(sp_call(bus, 0x00, [3, 1, LIST & 0xFF, LIST >> 8, code]), 0x21, f'STATUS code ${code:02X}')

    # ---- READ BLOCK / WRITE BLOCK ----
    r = sp_call(bus, 0x01, [3, 1, 0x00, 0x40, 5, 0, 0])
    ok(r, 'READ BLOCK 5')
    check(bytes(bus.ram[0x4000:0x4200]) == bytes(card.vol[0][5 * 512:6 * 512]), 'READ BLOCK 5 data')
    bus.ram[0x5000:0x5200] = bytes((i * 3 + 1) & 0xFF for i in range(512))
    r = sp_call(bus, 0x02, [3, 1, 0x00, 0x50, 0x2B, 0x01, 0])    # block 299, the last
    ok(r, 'WRITE BLOCK 299')
    check(bytes(card.vol[0][299 * 512:300 * 512]) == bytes(bus.ram[0x5000:0x5200]), 'WRITE BLOCK 299 data')
    check(card.writes[-1:] == [(0, 299)], f'WRITE BLOCK handed {card.writes[-1:]} to the card')
    err(sp_call(bus, 0x01, [3, 1, 0x00, 0x40, 0x2C, 0x01, 0]), 0x2D, 'READ past the end (block 300)')
    err(sp_call(bus, 0x01, [3, 1, 0x00, 0x40, 0, 0, 1]), 0x2D, 'READ with a block high byte')
    err(sp_call(bus, 0x01, [3, 1, 0x00, 0x40, 0x00, 0x02, 0]), 0x2D, 'READ block 512 (high byte above size)')
    err(sp_call(bus, 0x01, [3, 2, 0x00, 0x40, 0, 0, 0]), 0x2F, 'READ with no volume')
    err(sp_call(bus, 0x02, [3, 2, 0x00, 0x40, 0, 0, 0]), 0x2F, 'WRITE with no volume')
    err(sp_call(bus, 0x01, [3, 0, 0x00, 0x40, 0, 0, 0]), 0x11, 'READ unit 0')
    err(sp_call(bus, 0x01, [3, 3, 0x00, 0x40, 0, 0, 0]), 0x28, 'READ unit 3')
    err(sp_call(bus, 0x00, [3, 0x7E, LIST & 0xFF, LIST >> 8, 0]), 0x28, 'STATUS unit $7E')
    card.fail_reads = True
    err(sp_call(bus, 0x01, [3, 1, 0x00, 0x40, 0, 0, 0]), 0x27, 'READ that the card cannot fetch')
    card.fail_reads = False

    # ---- FORMAT, CONTROL, INIT, character calls, parameter counts ----
    ok(sp_call(bus, 0x03, [1, 1]), 'FORMAT unit 1')
    err(sp_call(bus, 0x03, [1, 2]), 0x2F, 'FORMAT with no volume')
    err(sp_call(bus, 0x03, [1, 0]), 0x11, 'FORMAT unit 0')
    ok(sp_call(bus, 0x04, [3, 0, 0x00, 0x06, 0]), 'CONTROL unit 0 code 0')
    ok(sp_call(bus, 0x04, [3, 0, 0x00, 0x06, 1]), 'CONTROL unit 0 code 1')
    err(sp_call(bus, 0x04, [3, 0, 0x00, 0x06, 2]), 0x21, 'CONTROL unit 0 code 2')
    ok(sp_call(bus, 0x04, [3, 1, 0x00, 0x06, 0]), 'CONTROL unit 1 reset')
    err(sp_call(bus, 0x04, [3, 1, 0x00, 0x06, 4]), 0x21, 'CONTROL unit 1 eject')
    ok(sp_call(bus, 0x05, [1, 0]), 'INIT')
    for cmd in (6, 7, 8, 9, 0x0A, 0x40, 0xFF):
        err(sp_call(bus, cmd, [1, 1]), 0x01, f'command ${cmd:02X}')
    err(sp_call(bus, 0x00, [2, 1, LIST & 0xFF, LIST >> 8, 0]), 0x04, 'STATUS with 2 parameters')
    err(sp_call(bus, 0x01, [1, 1, 0, 0x40, 0, 0, 0]), 0x04, 'READ with 1 parameter')
    err(sp_call(bus, 0x03, [3, 1]), 0x04, 'FORMAT with 3 parameters')

    # ---- the calling convention ----
    r = sp_call(bus, 0x01, [3, 1, 0x00, 0x40, 6, 0, 0], decimal=True)
    ok(r, 'READ BLOCK called in decimal mode')
    check(bytes(bus.ram[0x4000:0x4200]) == bytes(card.vol[0][6 * 512:7 * 512]), 'decimal-mode READ data')
    bus.touched_cfff = False
    sp_call(bus, 0x00, [3, 0, LIST & 0xFF, LIST >> 8, 0], c8_owned_elsewhere=True)
    check(bus.touched_cfff, 'the SmartPort entry did not release $C800 ($CFFF)')

    # ---- the ProDOS block entry ----
    r = blk_call(bus, 0, 0x70, 0, 0)
    ok(r, 'ProDOS STATUS drive 1')
    check(r[2] | r[3] << 8 == 300, f'ProDOS STATUS size {r[2] | r[3] << 8}, want 300')
    err(blk_call(bus, 0, 0xF0, 0, 0), 0x28, 'ProDOS STATUS drive 2 (no volume)')
    ok(blk_call(bus, 1, 0x70, 0x6000, 9), 'ProDOS READ')
    check(bytes(bus.ram[0x6000:0x6200]) == bytes(card.vol[0][9 * 512:10 * 512]), 'ProDOS READ data')
    ok(blk_call(bus, 3, 0x70, 0, 0), 'ProDOS FORMAT')
    card.present[1] = True
    ok(blk_call(bus, 1, 0xF0, 0x6000, 1500), 'ProDOS READ drive 2')
    check(bytes(bus.ram[0x6000:0x6200]) == bytes(card.vol[1][1500 * 512:1501 * 512]), 'ProDOS READ drive 2 data')
    r = sp_call(bus, 0x01, [3, 2, 0x00, 0x40, 0xDC, 0x05, 0])   # 1500 through the SmartPort
    ok(r, 'READ BLOCK unit 2')
    check(bytes(bus.ram[0x4000:0x4200]) == bytes(card.vol[1][1500 * 512:1501 * 512]), 'READ BLOCK unit 2 data')
    card.fail_reads = True
    err(blk_call(bus, 1, 0x70, 0x6000, 0), 0x27, 'ProDOS READ that the card cannot fetch')

    if fails:
        print(f'hdrom_test: FAIL ({fails})')
        sys.exit(1)
    print('hdrom_test: PASS')


if __name__ == '__main__':
    main()
