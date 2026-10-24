code = open('scratch/oldskool.dsk', 'rb').read()
ts_list = code[(2*16 + 1)*256 : (2*16 + 2)*256]
raw = bytearray()
for i in range(128):
    t, s = ts_list[12+i*2], ts_list[12+i*2+1]
    if t == 0 and s == 0: break
    raw += code[(t*16+s)*256 : (t*16+s+1)*256]
raw = raw[4:]

# 64KB RAM
mem = bytearray(65536)
mem[0x1000 : 0x1000 + len(raw)] = raw

A = 0
X = 0
Y = 0
SP = 0xFF
PC = 0x1000
C = 0
Z = 0
N = 0
V = 0

def set_zn(val):
    global Z, N
    val &= 0xFF
    Z = 1 if val == 0 else 0
    N = 1 if (val & 0x80) else 0
    return val

def push(b):
    global SP
    mem[0x100 + SP] = b & 0xFF
    SP = (SP - 1) & 0xFF

def pop():
    global SP
    SP = (SP + 1) & 0xFF
    return mem[0x100 + SP]

steps = 0
while PC < 0x7FD0 and steps < 2000000:
    steps += 1
    op = mem[PC]
    PC += 1
    if op == 0xA0: # LDY #imm
        Y = set_zn(mem[PC]); PC += 1
    elif op == 0x84: # STY zp
        zp = mem[PC]; mem[zp] = Y; PC += 1
    elif op == 0x85: # STA zp
        zp = mem[PC]; mem[zp] = A; PC += 1
    elif op == 0x20: # JSR abs
        dest = mem[PC] | (mem[PC+1] << 8); PC += 2
        push((PC - 1) >> 8)
        push((PC - 1) & 0xFF)
        PC = dest
    elif op == 0x60: # RTS
        lo = pop(); hi = pop()
        PC = ((lo | (hi << 8)) + 1) & 0xFFFF
    elif op == 0x4A: # LSR A
        C = A & 1
        A = set_zn(A >> 1)
    elif op == 0xF0: # BEQ rel
        rel = mem[PC]; PC += 1
        if rel >= 128: rel -= 256
        if Z: PC += rel
    elif op == 0xD0: # BNE rel
        rel = mem[PC]; PC += 1
        if rel >= 128: rel -= 256
        if not Z: PC += rel
    elif op == 0x90: # BCC rel
        rel = mem[PC]; PC += 1
        if rel >= 128: rel -= 256
        if not C: PC += rel
    elif op == 0xB0: # BCS rel
        rel = mem[PC]; PC += 1
        if rel >= 128: rel -= 256
        if C: PC += rel
    elif op == 0xC9: # CMP #imm
        imm = mem[PC]; PC += 1
        diff = A - imm
        C = 1 if diff >= 0 else 0
        set_zn(diff & 0xFF)
    elif op == 0xAA: # TAX
        X = set_zn(A)
    elif op == 0x8A: # TXA
        A = set_zn(X)
    elif op == 0x38: # SEC
        C = 1
    elif op == 0x18: # CLC
        C = 0
    elif op == 0x49: # EOR #imm
        A = set_zn(A ^ mem[PC]); PC += 1
    elif op == 0x29: # AND #imm
        A = set_zn(A & mem[PC]); PC += 1
    elif op == 0x6D: # ADC abs
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        val = mem[addr]
        res = A + val + C
        C = 1 if res > 0xFF else 0
        A = set_zn(res & 0xFF)
    elif op == 0x69: # ADC #imm
        val = mem[PC]; PC += 1
        res = A + val + C
        C = 1 if res > 0xFF else 0
        A = set_zn(res & 0xFF)
    elif op == 0x08: # PHP
        p = (N<<7)|(V<<6)|0x20|0x10|(Z<<1)|C
        push(p)
    elif op == 0x28: # PLP
        p = pop()
        C = p & 1
        Z = 1 if (p & 2) else 0
        N = 1 if (p & 0x80) else 0
        V = 1 if (p & 0x40) else 0
    elif op == 0x4C: # JMP abs
        PC = mem[PC] | (mem[PC+1] << 8)
    elif op == 0xB1: # LDA (zp),Y
        zp = mem[PC]; PC += 1
        addr = (mem[zp] | (mem[zp+1] << 8)) + Y
        A = set_zn(mem[addr & 0xFFFF])
    elif op == 0xE6: # INC zp
        zp = mem[PC]; PC += 1
        mem[zp] = set_zn((mem[zp] + 1) & 0xFF)
    elif op == 0xC6: # DEC zp
        zp = mem[PC]; PC += 1
        mem[zp] = set_zn((mem[zp] - 1) & 0xFF)
    elif op == 0xE8: # INX
        X = set_zn((X + 1) & 0xFF)
    elif op == 0x8D: # STA abs
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        mem[addr] = A
    elif op == 0xAD: # LDA abs
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        A = set_zn(mem[addr])
    elif op == 0xEE: # INC abs
        addr = mem[PC] | (mem[PC+1] << 8); PC += 2
        mem[addr] = set_zn((mem[addr] + 1) & 0xFF)
    elif op == 0xA5: # LDA zp
        zp = mem[PC]; PC += 1
        A = set_zn(mem[zp])
    elif op == 0x65: # ADC zp
        zp = mem[PC]; PC += 1
        res = A + mem[zp] + C
        C = 1 if res > 0xFF else 0
        A = set_zn(res & 0xFF)
    else:
        print(f"Unknown op {op:02X} at PC {PC-1:04X}")
        break

print(f"Finished after {steps} steps. PC = {PC:04X}")
with open('scratch/unpacked.bin', 'wb') as f:
    f.write(mem)
