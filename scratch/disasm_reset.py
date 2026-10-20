# Disassemble Apple //e reset from FA62
import capstone

lines = [line.strip() for line in open('roms/apple2e_rom.hex')]
rom_bytes = bytes(int(x, 16) for x in lines)

# 0x0000 = $C000 in apple2e_rom.hex (16KB total: C000 to FFFF)
# FA62 is offset 0x3A62
offset = 0x3A62
code = rom_bytes[offset : offset + 200]

# Simple 6502 disassembler or inspection
# Let's inspect instructions starting at FA62:
pc = 0xFA62
i = 0
while i < 100:
    op = code[i]
    print(f"${pc:04X}: {op:02X} ", end="")
    # print next 2 bytes if available
    b1 = code[i+1] if i+1 < len(code) else 0
    b2 = code[i+2] if i+2 < len(code) else 0
    print(f"{b1:02X} {b2:02X}")
    # advance roughly
    i += 1
    pc += 1
