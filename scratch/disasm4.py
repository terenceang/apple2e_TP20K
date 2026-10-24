mem = open('scratch/unpacked.bin', 'rb').read()

# Let's inspect instructions at $7FD4
# We can decode opcodes
def disasm(pc, count=50):
    for _ in range(count):
        op = mem[pc]
        # Common opcodes
        s = f"{pc:04X}: {op:02X} "
        if op == 0x78:
            print(s + "      SEI"); pc += 1
        elif op == 0xD8:
            print(s + "      CLD"); pc += 1
        elif op == 0xA9:
            print(s + f"{mem[pc+1]:02X}   LDA #{mem[pc+1]:02X}"); pc += 2
        elif op == 0xA2:
            print(s + f"{mem[pc+1]:02X}   LDX #{mem[pc+1]:02X}"); pc += 2
        elif op == 0xA0:
            print(s + f"{mem[pc+1]:02X}   LDY #{mem[pc+1]:02X}"); pc += 2
        elif op == 0x8D:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} STA ${addr:04X}"); pc += 3
        elif op == 0xAD:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} LDA ${addr:04X}"); pc += 3
        elif op == 0x8E:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} STX ${addr:04X}"); pc += 3
        elif op == 0x8C:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} STY ${addr:04X}"); pc += 3
        elif op == 0x20:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} JSR ${addr:04X}"); pc += 3
        elif op == 0x4C:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} JMP ${addr:04X}"); pc += 3
        elif op == 0x6C:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} JMP (${addr:04X})"); pc += 3
        elif op == 0x60:
            print(s + "      RTS"); pc += 1
        elif op == 0x9A:
            print(s + "      TXS"); pc += 1
        elif op == 0xBA:
            print(s + "      TSX"); pc += 1
        elif op == 0x48:
            print(s + "      PHA"); pc += 1
        elif op == 0x68:
            print(s + "      PLA"); pc += 1
        elif op == 0x85:
            print(s + f"{mem[pc+1]:02X}   STA ${mem[pc+1]:02X}"); pc += 2
        elif op == 0xA5:
            print(s + f"{mem[pc+1]:02X}   LDA ${mem[pc+1]:02X}"); pc += 2
        elif op == 0x86:
            print(s + f"{mem[pc+1]:02X}   STX ${mem[pc+1]:02X}"); pc += 2
        elif op == 0xA6:
            print(s + f"{mem[pc+1]:02X}   LDX ${mem[pc+1]:02X}"); pc += 2
        elif op == 0x84:
            print(s + f"{mem[pc+1]:02X}   STY ${mem[pc+1]:02X}"); pc += 2
        elif op == 0xA4:
            print(s + f"{mem[pc+1]:02X}   LDY ${mem[pc+1]:02X}"); pc += 2
        elif op == 0xBD:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} LDA ${addr:04X},X"); pc += 3
        elif op == 0xB9:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} LDA ${addr:04X},Y"); pc += 3
        elif op == 0x9D:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} STA ${addr:04X},X"); pc += 3
        elif op == 0x99:
            addr = mem[pc+1] | (mem[pc+2]<<8)
            print(s + f"{mem[pc+1]:02X} {mem[pc+2]:02X} STA ${addr:04X},Y"); pc += 3
        elif op == 0xD0:
            rel = mem[pc+1]
            if rel >= 128: rel -= 256
            print(s + f"{mem[pc+1]:02X}   BNE ${pc+2+rel:04X}"); pc += 2
        elif op == 0xF0:
            rel = mem[pc+1]
            if rel >= 128: rel -= 256
            print(s + f"{mem[pc+1]:02X}   BEQ ${pc+2+rel:04X}"); pc += 2
        elif op == 0x10:
            rel = mem[pc+1]
            if rel >= 128: rel -= 256
            print(s + f"{mem[pc+1]:02X}   BPL ${pc+2+rel:04X}"); pc += 2
        elif op == 0x30:
            rel = mem[pc+1]
            if rel >= 128: rel -= 256
            print(s + f"{mem[pc+1]:02X}   BMI ${pc+2+rel:04X}"); pc += 2
        elif op == 0x90:
            rel = mem[pc+1]
            if rel >= 128: rel -= 256
            print(s + f"{mem[pc+1]:02X}   BCC ${pc+2+rel:04X}"); pc += 2
        elif op == 0xB0:
            rel = mem[pc+1]
            if rel >= 128: rel -= 256
            print(s + f"{mem[pc+1]:02X}   BCS ${pc+2+rel:04X}"); pc += 2
        elif op == 0xC9:
            print(s + f"{mem[pc+1]:02X}   CMP #{mem[pc+1]:02X}"); pc += 2
        elif op == 0xE0:
            print(s + f"{mem[pc+1]:02X}   CPX #{mem[pc+1]:02X}"); pc += 2
        elif op == 0xC0:
            print(s + f"{mem[pc+1]:02X}   CPY #{mem[pc+1]:02X}"); pc += 2
        elif op == 0xAA:
            print(s + "      TAX"); pc += 1
        elif op == 0x8A:
            print(s + "      TXA"); pc += 1
        elif op == 0xA8:
            print(s + "      TAY"); pc += 1
        elif op == 0x98:
            print(s + "      TYA"); pc += 1
        elif op == 0xCA:
            print(s + "      DEX"); pc += 1
        elif op == 0xE8:
            print(s + "      INX"); pc += 1
        elif op == 0x88:
            print(s + "      DEY"); pc += 1
        elif op == 0xC8:
            print(s + "      INY"); pc += 1
        elif op == 0xEA:
            print(s + "      NOP"); pc += 1
        else:
            print(s + f"      ??? ({op:02X})"); pc += 1

disasm(0x832F, 30)
