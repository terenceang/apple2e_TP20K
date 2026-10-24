import sys
sys.path.append('.')
with open('roms/apple2e_rom.hex') as f:
    rom = [int(line.strip(), 16) for line in f if line.strip()]

from scratch.disasm_mecc_boot import disasm
idx = 0xFAA6 - 0xC000
disasm(bytes(rom[idx:idx+90]), 0xFAA6, 40)
