mem = open('scratch/unpacked.bin', 'rb').read()

# Let's inspect $7FD4
PC = 0x7FD4

# Quick disassembler for 6502 instructions around 7FD4
# We can use a simple disassembler loop
import subprocess

with open('scratch/code_at_7fd4.bin', 'wb') as f:
    f.write(mem[0x7FD4 : 0x7FD4 + 256])

print("Wrote 256 bytes at 7FD4")
