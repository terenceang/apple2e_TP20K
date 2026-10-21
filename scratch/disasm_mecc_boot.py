import sys

# Simple 6502 disassembler for analysis
OPCODES = {
    0x00: ("BRK", 1), 0x01: ("ORA ($%02X,X)", 2), 0x05: ("ORA $%02X", 2), 0x06: ("ASL $%02X", 2),
    0x08: ("PHP", 1), 0x09: ("ORA #$%02X", 2), 0x0A: ("ASL A", 1), 0x0D: ("ORA $%04X", 3),
    0x10: ("BPL $%04X", 2), 0x18: ("CLC", 1), 0x20: ("JSR $%04X", 3), 0x24: ("BIT $%02X", 2),
    0x28: ("PLP", 1), 0x29: ("AND #$%02X", 2), 0x2C: ("BIT $%04X", 3), 0x30: ("BMI $%04X", 2),
    0x38: ("SEC", 1), 0x48: ("PHA", 1), 0x4A: ("LSR A", 1), 0x4C: ("JMP $%04X", 3),
    0x58: ("CLI", 1), 0x60: ("RTS", 1), 0x68: ("PLA", 1), 0x69: ("ADC #$%02X", 2),
    0x6C: ("JMP ($%04X)", 3), 0x78: ("SEI", 1), 0x85: ("STA $%02X", 2), 0x86: ("STX $%02X", 2),
    0x88: ("DEY", 1), 0x8A: ("TXA", 1), 0x8D: ("STA $%04X", 3), 0x8E: ("STX $%04X", 3),
    0x90: ("BCC $%04X", 2), 0x98: ("TYA", 1), 0x99: ("STA $%04X,Y", 3), 0x9A: ("TXS", 1),
    0x9D: ("STA $%04X,X", 3), 0xA0: ("LDY #$%02X", 2), 0xA2: ("LDX #$%02X", 2), 0xA4: ("LDY $%02X", 2),
    0xA5: ("LDA $%02X", 2), 0xA6: ("LDX $%02X", 2), 0xA8: ("TAY", 1), 0xA9: ("LDA #$%02X", 2),
    0xAA: ("TAX", 1), 0xAC: ("LDY $%04X", 3), 0xAD: ("LDA $%04X", 3), 0xAE: ("LDX $%04X", 3),
    0xB0: ("BCS $%04X", 2), 0xB5: ("LDA $%02X,X", 2), 0xB8: ("CLV", 1), 0xB9: ("LDA $%04X,Y", 3),
    0xBA: ("TSX", 1), 0xBD: ("LDA $%04X,X", 3), 0xC0: ("CPY #$%02X", 2), 0xC5: ("CMP $%02X", 2),
    0xC6: ("DEC $%02X", 2), 0xC8: ("INY", 1), 0xC9: ("CMP #$%02X", 2), 0xCA: ("DEX", 1),
    0xCE: ("DEC $%04X", 3), 0xD0: ("BNE $%04X", 2), 0xD8: ("CLD", 1), 0xE0: ("CPX #$%02X", 2),
    0xE5: ("SBC $%02X", 2), 0xE6: ("INC $%02X", 2), 0xE8: ("INX", 1), 0xEA: ("NOP", 1),
    0xEE: ("INC $%04X", 3), 0xF0: ("BEQ $%04X", 2), 0xF8: ("SED", 1)
}

def disasm(data, base_addr, count=20):
    pc = 0
    lines = 0
    while pc < len(data) and lines < count:
        op = data[pc]
        addr = base_addr + pc
        if op in OPCODES:
            fmt, length = OPCODES[op]
            if pc + length > len(data):
                break
            if length == 1:
                print(f"{addr:04X}: {data[pc:pc+length].hex():<8} {fmt}")
            elif length == 2:
                arg = data[pc+1]
                if "B" in fmt and ("BNE" in fmt or "BEQ" in fmt or "BCC" in fmt or "BCS" in fmt or "BPL" in fmt or "BMI" in fmt):
                    dest = addr + 2 + (arg if arg < 128 else arg - 256)
                    print(f"{addr:04X}: {data[pc:pc+length].hex():<8} {fmt.split()[0]} ${dest:04X}")
                else:
                    print(f"{addr:04X}: {data[pc:pc+length].hex():<8} {fmt % arg}")
            elif length == 3:
                arg = data[pc+1] | (data[pc+2] << 8)
                print(f"{addr:04X}: {data[pc:pc+length].hex():<8} {fmt % arg}")
            pc += length
        else:
            print(f"{addr:04X}: {op:02X}       ???")
            pc += 1
        lines += 1

with open('Disk/ComputerInspector (MECC 1.0).dsk', 'rb') as f:
    d = f.read()

# Logical sector 1 is at 0x100 -> loads at $0900
sec1 = d[0x100:0x200]
print("--- Subroutine at $0912 ---")
disasm(sec1[0x12:], 0x0912, 15)

print("\n--- Subroutine at $09AE ---")
disasm(sec1[0xAE:], 0x09AE, 15)

print("\n--- Subroutine at $09DD ---")
disasm(sec1[0xDD:], 0x09DD, 20)
