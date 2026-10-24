code = open('scratch/oldskool.dsk', 'rb').read()
ts_list = code[(2*16 + 1)*256 : (2*16 + 2)*256]
raw = bytearray()
for i in range(128):
    t, s = ts_list[12+i*2], ts_list[12+i*2+1]
    if t == 0 and s == 0: break
    raw += code[(t*16+s)*256 : (t*16+s+1)*256]
raw = raw[4:]

mem = bytearray(65536)
mem[0x1000 : 0x1000 + len(raw)] = raw

A = X = Y = C = Z = N = V = 0
SP = 0xFF
PC = 0x1000

writes = set()

def set_zn(val):
    global Z, N
    val &= 0xFF
    Z = 1 if val == 0 else 0
    N = 1 if (val & 0x80) else 0
    return val

def wr(addr, val):
    writes.add(addr)
    mem[addr] = val & 0xFF

steps = 0
while PC < 0x7FD0 and steps < 2000000:
    steps += 1
    op = mem[PC]
    PC += 1
    if op == 0xA0: Y = set_zn(mem[PC]); PC += 1
    elif op == 0x84: zp = mem[PC]; wr(zp, Y); PC += 1
    elif op == 0x85: zp = mem[PC]; wr(zp, A); PC += 1
    elif op == 0x20:
        addr = mem[PC] | (mem[PC+1]<<8); PC += 2
        mem[0x100 + SP] = ((PC-1) >> 8) & 0xFF; SP = (SP-1)&0xFF
        mem[0x100 + SP] = (PC-1) & 0xFF; SP = (SP-1)&0xFF
        PC = addr
    elif op == 0x60:
        SP = (SP+1)&0xFF; pcl = mem[0x100 + SP]
        SP = (SP+1)&0xFF; pch = mem[0x100 + SP]
        PC = ((pch << 8) | pcl) + 1
    elif op == 0x4A: C = A & 1; A = set_zn(A >> 1)
    elif op == 0xF0:
        rel = mem[PC]; PC += 1
        if rel >= 0x80: rel -= 256
        if Z == 1: PC += rel
    elif op == 0xD0:
        rel = mem[PC]; PC += 1
        if rel >= 0x80: rel -= 256
        if Z == 0: PC += rel
    elif op == 0x90:
        rel = mem[PC]; PC += 1
        if rel >= 0x80: rel -= 256
        if C == 0: PC += rel
    elif op == 0xB0:
        rel = mem[PC]; PC += 1
        if rel >= 0x80: rel -= 256
        if C == 1: PC += rel
    elif op == 0xC9:
        v = mem[PC]; PC += 1
        set_zn((A - v) & 0xFF)
        C = 1 if A >= v else 0
    elif op == 0xAA: X = set_zn(A)
    elif op == 0x8A: A = set_zn(X)
    elif op == 0x38: C = 1
    elif op == 0x18: C = 0
    elif op == 0x49: A = set_zn(A ^ mem[PC]); PC += 1
    elif op == 0x6D:
        addr = mem[PC] | (mem[PC+1]<<8); PC += 2
        res = A + mem[addr] + C
        C = 1 if res > 0xFF else 0
        A = set_zn(res & 0xFF)
    elif op == 0x08: mem[0x100 + SP] = 0x30 | (Z<<1) | C; SP = (SP-1)&0xFF
    elif op == 0x28:
        SP = (SP+1)&0xFF; p = mem[0x100 + SP]
        C = p & 1; Z = (p >> 1) & 1
    elif op == 0x4C:
        addr = mem[PC] | (mem[PC+1]<<8); PC = addr
    elif op == 0x29: A = set_zn(A & mem[PC]); PC += 1
    elif op == 0x69:
        v = mem[PC]; PC += 1
        res = A + v + C
        C = 1 if res > 0xFF else 0
        A = set_zn(res & 0xFF)
    elif op == 0xB1:
        zp = mem[PC]; PC += 1
        addr = (mem[zp] | (mem[zp+1] << 8)) + Y
        A = set_zn(mem[addr & 0xFFFF])
    elif op == 0xE6:
        zp = mem[PC]; PC += 1
        wr(zp, set_zn((mem[zp] + 1) & 0xFF))
    elif op == 0xC6:
        zp = mem[PC]; PC += 1
        wr(zp, set_zn((mem[zp] - 1) & 0xFF))
    elif op == 0xE8: X = set_zn((X + 1) & 0xFF)
    elif op == 0x8D:
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        wr(addr, A)
    elif op == 0xAD:
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        A = set_zn(mem[addr])
    elif op == 0xEE:
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        wr(addr, set_zn((mem[addr] + 1) & 0xFF))
    elif op == 0xA5: zp = mem[PC]; PC += 1; A = set_zn(mem[zp])
    elif op == 0x65:
        zp = mem[PC]; PC += 1
        res = A + mem[zp] + C
        C = 1 if res > 0xFF else 0
        A = set_zn(res & 0xFF)
    else:
        print(f"Unknown op {op:02X} at PC {PC-1:04X}")
        break

zp_writes = sorted([a for a in writes if a < 0x100])
non_zp_writes = sorted([a for a in writes if a >= 0x100])
print(f"Zero page writes: {[hex(a) for a in zp_writes]}")
print(f"Non-ZP writes range: {hex(min(non_zp_writes))} to {hex(max(non_zp_writes))}")
