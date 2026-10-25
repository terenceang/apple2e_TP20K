import sys

OPCODES = {
    0x00: ('BRK', 1), 0x01: ('ORA ($%02X,X)', 2), 0x05: ('ORA $%02X', 2), 0x06: ('ASL $%02X', 2),
    0x08: ('PHP', 1), 0x09: ('ORA #$%02X', 2), 0x0A: ('ASL A', 1), 0x0D: ('ORA $%04X', 3), 0x0E: ('ASL $%04X', 3),
    0x10: ('BPL $%04X', 2), 0x18: ('CLC', 1), 0x20: ('JSR $%04X', 3), 0x24: ('BIT $%02X', 2),
    0x29: ('AND #$%02X', 2), 0x2C: ('BIT $%04X', 3), 0x30: ('BMI $%04X', 2), 0x38: ('SEC', 1),
    0x40: ('RTI', 1), 0x48: ('PHA', 1), 0x4A: ('LSR A', 1), 0x4C: ('JMP $%04X', 3),
    0x50: ('BVC $%04X', 2), 0x59: ('EOR $%04X,Y', 3), 0x60: ('RTS', 1), 0x68: ('PLA', 1), 0x69: ('ADC #$%02X', 2),
    0x6C: ('JMP ($%04X)', 3), 0x70: ('BVS $%04X', 2), 0x78: ('SEI', 1), 0x84: ('STY $%02X', 2),
    0x85: ('STA $%02X', 2), 0x86: ('STX $%02X', 2), 0x88: ('DEY', 1), 0x8A: ('TXA', 1),
    0x8C: ('STY $%04X', 3), 0x8D: ('STA $%04X', 3), 0x8E: ('STX $%04X', 3), 0x90: ('BCC $%04X', 2),
    0x91: ('STA ($%02X),Y', 2), 0x95: ('STA $%02X,X', 2), 0x98: ('TYA', 1), 0x99: ('STA $%04X,Y', 3), 0x9A: ('TXS', 1),
    0x9D: ('STA $%04X,X', 3), 0xA0: ('LDY #$%02X', 2), 0xA2: ('LDX #$%02X', 2), 0xA4: ('LDY $%02X', 2),
    0xA5: ('LDA $%02X', 2), 0xA6: ('LDX $%02X', 2), 0xA8: ('TAY', 1), 0xA9: ('LDA #$%02X', 2),
    0xAA: ('TAX', 1), 0xAC: ('LDY $%04X', 3), 0xAD: ('LDA $%04X', 3), 0xAE: ('LDX $%04X', 3),
    0xB0: ('BCS $%04X', 2), 0xB1: ('LDA ($%02X),Y', 2), 0xB5: ('LDA $%02X,X', 2), 0xB8: ('CLV', 1),
    0xB9: ('LDA $%04X,Y', 3), 0xBC: ('LDY $%04X,X', 3), 0xBD: ('LDA $%04X,X', 3), 0xC0: ('CPY #$%02X', 2), 0xC4: ('CPY $%02X', 2),
    0xC5: ('CMP $%02X', 2), 0xC6: ('DEC $%02X', 2), 0xC8: ('INY', 1), 0xC9: ('CMP #$%02X', 2),
    0xCA: ('DEX', 1), 0xCC: ('CPY $%04X', 3), 0xCD: ('CMP $%04X', 3), 0xCE: ('DEC $%04X', 3),
    0xD0: ('BNE $%04X', 2), 0xD8: ('CLD', 1), 0xE0: ('CPX #$%02X', 2), 0xE6: ('INC $%02X', 2),
    0xE8: ('INX', 1), 0xEA: ('NOP', 1), 0xEE: ('INC $%04X', 3), 0xF0: ('BEQ $%04X', 2), 0xFE: ('INC $%04X,X', 3)
}

fname = sys.argv[1] if len(sys.argv) > 1 else 'scratch/bootsec.bin'
with open(fname, 'rb') as f:
    code = f.read()

pc = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x800
idx = 0
while idx < len(code):
    op = code[idx]
    if op in OPCODES:
        name, length = OPCODES[op]
        if length == 1:
            print(f'${pc:04X}: {op:02X}        {name}')
            idx += 1
            pc += 1
        elif length == 2:
            if idx + 1 >= len(code): break
            arg = code[idx+1]
            if 'B' in name and name.startswith(('BPL','BMI','BVC','BVS','BCC','BCS','BNE','BEQ')):
                rel = arg if arg < 0x80 else arg - 0x100
                target = pc + 2 + rel
                print(f'${pc:04X}: {op:02X} {arg:02X}     {name.split()[0]} ${target:04X}')
            else:
                print(f'${pc:04X}: {op:02X} {arg:02X}     {name % arg}')
            idx += 2
            pc += 2
        elif length == 3:
            if idx + 2 >= len(code): break
            arg = code[idx+1] | (code[idx+2] << 8)
            print(f'${pc:04X}: {op:02X} {code[idx+1]:02X} {code[idx+2]:02X}  {name % arg}')
            idx += 3
            pc += 3
    else:
        print(f'${pc:04X}: {op:02X}        .byte ${op:02X}')
        idx += 1
        pc += 1
