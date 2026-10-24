mem = open('scratch/unpacked.bin', 'rb').read()

# Disassemble $80E0 to $8200
from disasm4 import disasm # or run custom disasm
# Let's print the instructions from $80E0 to $81A0
import subprocess

with open('scratch/disasm_8100.py', 'w') as f:
    f.write('''
mem = open('scratch/unpacked.bin', 'rb').read()
from disasm4 import disasm
disasm(0x80D0, 60)
''')
