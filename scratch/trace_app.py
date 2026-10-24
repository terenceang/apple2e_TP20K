# 6502 / 65C02 emulator to trace execution starting at $7FD4

mem = bytearray(open('scratch/unpacked.bin', 'rb').read())
# Add standard Apple //e ROM vectors / pages if needed, but let's see how far it gets

A = 0
X = 0
Y = 0
SP = 0xFF
PC = 0x7FD4
C = 0
Z = 0
N = 0
V = 0
D = 0
I = 0

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

def read_mem(addr):
    addr &= 0xFFFF
    if 0xC000 <= addr <= 0xCFFF:
        # print(f"  READ softswitch/IO: ${addr:04X} at PC=${PC:04X}")
        if addr == 0xC000:
            return 0x00 # no key pressed
        if addr == 0xC010:
            return 0x00
        if addr == 0xC030: # speaker
            return 0x00
        # Slot 4 (Mockingboard): $C400 or $C0C0
        return 0x00
    return mem[addr]

def write_mem(addr, val):
    val &= 0xFF
    addr &= 0xFFFF
    if 0xC000 <= addr <= 0xCFFF:
        print(f"  WRITE softswitch/IO: ${addr:04X} = ${val:02X} (PC=${last_pc:04X})")
        return
    mem[addr] = val

logs = 0
last_pc = PC

# Disassemble / step
import sys

for step in range(5000000):
    last_pc = PC
    op = read_mem(PC)
    PC = (PC + 1) & 0xFFFF
    
    # 6502 instructions
    if op == 0x00: # BRK
        print(f"BRK encountered at PC={last_pc:04X}")
        break
    elif op == 0x78: # SEI
        I = 1
    elif op == 0x58: # CLI
        I = 0
    elif op == 0xD8: # CLD
        D = 0
    elif op == 0xF8: # SED
        D = 1
    elif op == 0x18: # CLC
        C = 0
    elif op == 0x38: # SEC
        C = 1
    elif op == 0xB8: # CLV
        V = 0
    elif op == 0xEA: # NOP
        pass
    # LDA
    elif op == 0xA9: # LDA #imm
        A = set_zn(read_mem(PC)); PC = (PC + 1) & 0xFFFF
    elif op == 0xA5: # LDA zp
        A = set_zn(read_mem(read_mem(PC))); PC = (PC + 1) & 0xFFFF
    elif op == 0xB5: # LDA zp,X
        A = set_zn(read_mem((read_mem(PC) + X) & 0xFF)); PC = (PC + 1) & 0xFFFF
    elif op == 0xAD: # LDA abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        A = set_zn(read_mem(addr))
    elif op == 0xBD: # LDA abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        A = set_zn(read_mem(addr))
    elif op == 0xB9: # LDA abs,Y
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + Y; PC = (PC + 2) & 0xFFFF
        A = set_zn(read_mem(addr))
    elif op == 0xA1: # LDA (zp,X)
        zp = (read_mem(PC) + X) & 0xFF; PC = (PC + 1) & 0xFFFF
        addr = read_mem(zp) | (read_mem((zp+1)&0xFF) << 8)
        A = set_zn(read_mem(addr))
    elif op == 0xB1: # LDA (zp),Y
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        addr = (read_mem(zp) | (read_mem((zp+1)&0xFF) << 8)) + Y
        A = set_zn(read_mem(addr))
    elif op == 0xB2: # 65C02 LDA (zp)
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        addr = read_mem(zp) | (read_mem((zp+1)&0xFF) << 8)
        A = set_zn(read_mem(addr))
    # LDX
    elif op == 0xA2: # LDX #imm
        X = set_zn(read_mem(PC)); PC = (PC + 1) & 0xFFFF
    elif op == 0xA6: # LDX zp
        X = set_zn(read_mem(read_mem(PC))); PC = (PC + 1) & 0xFFFF
    elif op == 0xB6: # LDX zp,Y
        X = set_zn(read_mem((read_mem(PC) + Y) & 0xFF)); PC = (PC + 1) & 0xFFFF
    elif op == 0xAE: # LDX abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        X = set_zn(read_mem(addr))
    elif op == 0xBE: # LDX abs,Y
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + Y; PC = (PC + 2) & 0xFFFF
        X = set_zn(read_mem(addr))
    # LDY
    elif op == 0xA0: # LDY #imm
        Y = set_zn(read_mem(PC)); PC = (PC + 1) & 0xFFFF
    elif op == 0xA4: # LDY zp
        Y = set_zn(read_mem(read_mem(PC))); PC = (PC + 1) & 0xFFFF
    elif op == 0xB4: # LDY zp,X
        Y = set_zn(read_mem((read_mem(PC) + X) & 0xFF)); PC = (PC + 1) & 0xFFFF
    elif op == 0xAC: # LDY abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        Y = set_zn(read_mem(addr))
    elif op == 0xBC: # LDY abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        Y = set_zn(read_mem(addr))
    # STA
    elif op == 0x85: # STA zp
        write_mem(read_mem(PC), A); PC = (PC + 1) & 0xFFFF
    elif op == 0x95: # STA zp,X
        write_mem((read_mem(PC) + X) & 0xFF, A); PC = (PC + 1) & 0xFFFF
    elif op == 0x8D: # STA abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        write_mem(addr, A)
    elif op == 0x9D: # STA abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        write_mem(addr, A)
    elif op == 0x99: # STA abs,Y
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + Y; PC = (PC + 2) & 0xFFFF
        write_mem(addr, A)
    elif op == 0x81: # STA (zp,X)
        zp = (read_mem(PC) + X) & 0xFF; PC = (PC + 1) & 0xFFFF
        addr = read_mem(zp) | (read_mem((zp+1)&0xFF) << 8)
        write_mem(addr, A)
    elif op == 0x91: # STA (zp),Y
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        addr = (read_mem(zp) | (read_mem((zp+1)&0xFF) << 8)) + Y
        write_mem(addr, A)
    elif op == 0x92: # 65C02 STA (zp)
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        addr = read_mem(zp) | (read_mem((zp+1)&0xFF) << 8)
        write_mem(addr, A)
    # STX
    elif op == 0x86: # STX zp
        write_mem(read_mem(PC), X); PC = (PC + 1) & 0xFFFF
    elif op == 0x96: # STX zp,Y
        write_mem((read_mem(PC) + Y) & 0xFF, X); PC = (PC + 1) & 0xFFFF
    elif op == 0x8E: # STX abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        write_mem(addr, X)
    # STY
    elif op == 0x84: # STY zp
        write_mem(read_mem(PC), Y); PC = (PC + 1) & 0xFFFF
    elif op == 0x94: # STY zp,X
        write_mem((read_mem(PC) + X) & 0xFF, Y); PC = (PC + 1) & 0xFFFF
    elif op == 0x8C: # STY abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        write_mem(addr, Y)
    # STZ (65C02)
    elif op == 0x64: # STZ zp
        write_mem(read_mem(PC), 0); PC = (PC + 1) & 0xFFFF
    elif op == 0x74: # STZ zp,X
        write_mem((read_mem(PC) + X) & 0xFF, 0); PC = (PC + 1) & 0xFFFF
    elif op == 0x9C: # STZ abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        write_mem(addr, 0)
    elif op == 0x9E: # STZ abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        write_mem(addr, 0)
    # Transfers
    elif op == 0xAA: X = set_zn(A)
    elif op == 0x8A: A = set_zn(X)
    elif op == 0xA8: Y = set_zn(A)
    elif op == 0x98: A = set_zn(Y)
    elif op == 0xBA: X = set_zn(SP)
    elif op == 0x9A: SP = X
    # Stack
    elif op == 0x48: push(A)
    elif op == 0x68: A = set_zn(pop())
    elif op == 0x08: # PHP
        p = (N<<7)|(V<<6)|0x20|0x10|(D<<3)|(I<<2)|(Z<<1)|C
        push(p)
    elif op == 0x28: # PLP
        p = pop()
        C = p & 1; Z = 1 if (p & 2) else 0; I = 1 if (p & 4) else 0
        D = 1 if (p & 8) else 0; V = 1 if (p & 0x40) else 0; N = 1 if (p & 0x80) else 0
    elif op == 0xDA: # 65C02 PHX
        push(X)
    elif op == 0x5A: # 65C02 PHY
        push(Y)
    elif op == 0xFA: # 65C02 PLX
        X = set_zn(pop())
    elif op == 0x7A: # 65C02 PLY
        Y = set_zn(pop())
    # Jumps & Branches
    elif op == 0x4C: # JMP abs
        PC = read_mem(PC) | (read_mem(PC+1) << 8)
    elif op == 0x6C: # JMP (abs)
        addr = read_mem(PC) | (read_mem(PC+1) << 8)
        PC = read_mem(addr) | (read_mem(addr+1) << 8)
    elif op == 0x7C: # 65C02 JMP (abs,X)
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X
        PC = read_mem(addr) | (read_mem(addr+1) << 8)
    elif op == 0x20: # JSR
        dest = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        push((PC - 1) >> 8); push((PC - 1) & 0xFF)
        PC = dest
    elif op == 0x60: # RTS
        lo = pop(); hi = pop()
        PC = ((lo | (hi << 8)) + 1) & 0xFFFF
    elif op == 0x40: # RTI
        p = pop()
        C = p & 1; Z = 1 if (p & 2) else 0; I = 1 if (p & 4) else 0
        D = 1 if (p & 8) else 0; V = 1 if (p & 0x40) else 0; N = 1 if (p & 0x80) else 0
        lo = pop(); hi = pop()
        PC = (lo | (hi << 8)) & 0xFFFF
    # Branches
    elif op == 0x10: # BPL
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if not N: PC = (PC + rel) & 0xFFFF
    elif op == 0x30: # BMI
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if N: PC = (PC + rel) & 0xFFFF
    elif op == 0x50: # BVC
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if not V: PC = (PC + rel) & 0xFFFF
    elif op == 0x70: # BVS
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if V: PC = (PC + rel) & 0xFFFF
    elif op == 0x90: # BCC
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if not C: PC = (PC + rel) & 0xFFFF
    elif op == 0xB0: # BCS
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if C: PC = (PC + rel) & 0xFFFF
    elif op == 0xD0: # BNE
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if not Z: PC = (PC + rel) & 0xFFFF
    elif op == 0xF0: # BEQ
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        if Z: PC = (PC + rel) & 0xFFFF
    elif op == 0x80: # 65C02 BRA
        rel = read_mem(PC); PC = (PC + 1) & 0xFFFF
        if rel >= 128: rel -= 256
        PC = (PC + rel) & 0xFFFF
    # Incs / Decs
    elif op == 0xE8: X = set_zn(X + 1)
    elif op == 0xCA: X = set_zn(X - 1)
    elif op == 0xC8: Y = set_zn(Y + 1)
    elif op == 0x88: Y = set_zn(Y - 1)
    elif op == 0xE6: # INC zp
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        write_mem(zp, set_zn(read_mem(zp) + 1))
    elif op == 0xF6: # INC zp,X
        zp = (read_mem(PC) + X) & 0xFF; PC = (PC + 1) & 0xFFFF
        write_mem(zp, set_zn(read_mem(zp) + 1))
    elif op == 0xEE: # INC abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        write_mem(addr, set_zn(read_mem(addr) + 1))
    elif op == 0xFE: # INC abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        write_mem(addr, set_zn(read_mem(addr) + 1))
    elif op == 0x1A: # 65C02 INC A
        A = set_zn(A + 1)
    elif op == 0xC6: # DEC zp
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        write_mem(zp, set_zn(read_mem(zp) - 1))
    elif op == 0xD6: # DEC zp,X
        zp = (read_mem(PC) + X) & 0xFF; PC = (PC + 1) & 0xFFFF
        write_mem(zp, set_zn(read_mem(zp) - 1))
    elif op == 0xCE: # DEC abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        write_mem(addr, set_zn(read_mem(addr) - 1))
    elif op == 0xDE: # DEC abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        write_mem(addr, set_zn(read_mem(addr) - 1))
    elif op == 0x3A: # 65C02 DEC A
        A = set_zn(A - 1)
    # Comparisons
    elif op == 0xC9: # CMP #imm
        diff = A - read_mem(PC); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xC5: # CMP zp
        diff = A - read_mem(read_mem(PC)); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xD5: # CMP zp,X
        diff = A - read_mem((read_mem(PC) + X) & 0xFF); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xCD: # CMP abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        diff = A - read_mem(addr); C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xDD: # CMP abs,X
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + X; PC = (PC + 2) & 0xFFFF
        diff = A - read_mem(addr); C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xD9: # CMP abs,Y
        addr = (read_mem(PC) | (read_mem(PC+1) << 8)) + Y; PC = (PC + 2) & 0xFFFF
        diff = A - read_mem(addr); C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xE0: # CPX #imm
        diff = X - read_mem(PC); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xE4: # CPX zp
        diff = X - read_mem(read_mem(PC)); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xEC: # CPX abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        diff = X - read_mem(addr); C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xC0: # CPY #imm
        diff = Y - read_mem(PC); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xC4: # CPY zp
        diff = Y - read_mem(read_mem(PC)); PC = (PC + 1) & 0xFFFF
        C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    elif op == 0xCC: # CPY abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        diff = Y - read_mem(addr); C = 1 if diff >= 0 else 0; set_zn(diff & 0xFF)
    # Logical / Arithmetic
    elif op == 0x29: # AND #imm
        A = set_zn(A & read_mem(PC)); PC = (PC + 1) & 0xFFFF
    elif op == 0x25: # AND zp
        A = set_zn(A & read_mem(read_mem(PC))); PC = (PC + 1) & 0xFFFF
    elif op == 0x2D: # AND abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        A = set_zn(A & read_mem(addr))
    elif op == 0x09: # ORA #imm
        A = set_zn(A | read_mem(PC)); PC = (PC + 1) & 0xFFFF
    elif op == 0x05: # ORA zp
        A = set_zn(A | read_mem(read_mem(PC))); PC = (PC + 1) & 0xFFFF
    elif op == 0x0D: # ORA abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        A = set_zn(A | read_mem(addr))
    elif op == 0x49: # EOR #imm
        A = set_zn(A ^ read_mem(PC)); PC = (PC + 1) & 0xFFFF
    elif op == 0x45: # EOR zp
        A = set_zn(A ^ read_mem(read_mem(PC))); PC = (PC + 1) & 0xFFFF
    elif op == 0x4D: # EOR abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        A = set_zn(A ^ read_mem(addr))
    elif op == 0x69: # ADC #imm
        v = read_mem(PC); PC = (PC + 1) & 0xFFFF
        res = A + v + C; C = 1 if res > 0xFF else 0; V = 1 if (~(A ^ v) & (A ^ res) & 0x80) else 0; A = set_zn(res & 0xFF)
    elif op == 0x65: # ADC zp
        v = read_mem(read_mem(PC)); PC = (PC + 1) & 0xFFFF
        res = A + v + C; C = 1 if res > 0xFF else 0; V = 1 if (~(A ^ v) & (A ^ res) & 0x80) else 0; A = set_zn(res & 0xFF)
    elif op == 0x6D: # ADC abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr); res = A + v + C; C = 1 if res > 0xFF else 0; V = 1 if (~(A ^ v) & (A ^ res) & 0x80) else 0; A = set_zn(res & 0xFF)
    elif op == 0xE9: # SBC #imm
        v = read_mem(PC); PC = (PC + 1) & 0xFFFF
        diff = A - v - (1 - C); C = 1 if diff >= 0 else 0; V = 1 if ((A ^ v) & (A ^ diff) & 0x80) else 0; A = set_zn(diff & 0xFF)
    elif op == 0xE5: # SBC zp
        v = read_mem(read_mem(PC)); PC = (PC + 1) & 0xFFFF
        diff = A - v - (1 - C); C = 1 if diff >= 0 else 0; V = 1 if ((A ^ v) & (A ^ diff) & 0x80) else 0; A = set_zn(diff & 0xFF)
    elif op == 0xED: # SBC abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr); diff = A - v - (1 - C); C = 1 if diff >= 0 else 0; V = 1 if ((A ^ v) & (A ^ diff) & 0x80) else 0; A = set_zn(diff & 0xFF)
    # Shifts
    elif op == 0x0A: # ASL A
        C = (A >> 7) & 1; A = set_zn((A << 1) & 0xFF)
    elif op == 0x06: # ASL zp
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        v = read_mem(zp); C = (v >> 7) & 1; write_mem(zp, set_zn((v << 1) & 0xFF))
    elif op == 0x0E: # ASL abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr); C = (v >> 7) & 1; write_mem(addr, set_zn((v << 1) & 0xFF))
    elif op == 0x4A: # LSR A
        C = A & 1; A = set_zn(A >> 1)
    elif op == 0x46: # LSR zp
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        v = read_mem(zp); C = v & 1; write_mem(zp, set_zn(v >> 1))
    elif op == 0x4E: # LSR abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr); C = v & 1; write_mem(addr, set_zn(v >> 1))
    elif op == 0x2A: # ROL A
        old_c = C; C = (A >> 7) & 1; A = set_zn(((A << 1) | old_c) & 0xFF)
    elif op == 0x26: # ROL zp
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        v = read_mem(zp); old_c = C; C = (v >> 7) & 1; write_mem(zp, set_zn(((v << 1) | old_c) & 0xFF))
    elif op == 0x2E: # ROL abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr); old_c = C; C = (v >> 7) & 1; write_mem(addr, set_zn(((v << 1) | old_c) & 0xFF))
    elif op == 0x6A: # ROR A
        old_c = C; C = A & 1; A = set_zn((A >> 1) | (old_c << 7))
    elif op == 0x66: # ROR zp
        zp = read_mem(PC); PC = (PC + 1) & 0xFFFF
        v = read_mem(zp); old_c = C; C = v & 1; write_mem(zp, set_zn((v >> 1) | (old_c << 7)))
    elif op == 0x6E: # ROR abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr); old_c = C; C = v & 1; write_mem(addr, set_zn((v >> 1) | (old_c << 7)))
    # BIT
    elif op == 0x24: # BIT zp
        v = read_mem(read_mem(PC)); PC = (PC + 1) & 0xFFFF
        Z = 1 if ((A & v) == 0) else 0; N = 1 if (v & 0x80) else 0; V = 1 if (v & 0x40) else 0
    elif op == 0x2C: # BIT abs
        addr = read_mem(PC) | (read_mem(PC+1) << 8); PC = (PC + 2) & 0xFFFF
        v = read_mem(addr)
        Z = 1 if ((A & v) == 0) else 0; N = 1 if (v & 0x80) else 0; V = 1 if (v & 0x40) else 0
    elif op == 0x89: # 65C02 BIT #imm
        v = read_mem(PC); PC = (PC + 1) & 0xFFFF
        Z = 1 if ((A & v) == 0) else 0
    else:
        print(f"Unknown opcode ${op:02X} at PC=${last_pc:04X}")
        break

print(f"Halted at PC=${PC:04X} after {step} steps")
