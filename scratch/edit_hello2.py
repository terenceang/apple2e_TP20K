import struct

with open('scratch/oldskool.dsk', 'rb') as f:
    dsk = bytearray(f.read())

# Tokens in Applesoft BASIC:
# D$ = CHR$(4):
# 'D' '$' '='(0xD0) 'CHR$'(0xE7) '(' '4' ')'
# HOME(0x97) ':'(0x3A) PRINT(0xBA)
# PRINT(0xBA)
# D$;"BRUN OLDSKOOL":
# PRINT(0xBA) 'D' '$' ';'(0x3B) '"' 'B' 'R' 'U' 'N' ' ' 'O' 'L' 'D' 'S' 'K' 'O' 'O' 'L' '"'

lines = [
    (10, b'D$\xd0\xe7(4)\x00'), # D$=CHR$(4)
    (20, b'\x97:\xba\x00'),     # HOME:PRINT
    (50, b'\xba" OLDSKOOL FORT ET VERT  by FRENCH TOUCH"\x00'),
    (51, b'\xba\x00'),
    (55, b'\xba"     8KB INTRO for APPLE IIe (6502)"\x00'),
    (60, b'\xba"           with MOCKINGBOARD"\x00'),
    (70, b'\xba\x00'),
    (80, b'\xba"LAUNCHING OLDSKOOL..."\x00'),
    (90, b'\xbaD$;"BRUN OLDSKOOL"\x00'),
]

addr = 0x0801
new_prog = bytearray()
for lineno, body in lines:
    next_addr = addr + 2 + 2 + len(body)
    new_prog += bytearray([next_addr & 0xff, (next_addr >> 8) & 0xff])
    new_prog += bytearray([lineno & 0xff, (lineno >> 8) & 0xff])
    new_prog += body
    print(f"Line {lineno:3d}: addr 0x{addr:04x}, next 0x{next_addr:04x}, len {len(body)+4}")
    addr = next_addr

# End of program: 0x00 0x00
new_prog += bytearray([0x00, 0x00])
print(f"New program length: {len(new_prog)} bytes")

new_sec = bytearray(256)
new_len = len(new_prog)
new_sec[0] = new_len & 0xff
new_sec[1] = (new_len >> 8) & 0xff
new_sec[2 : 2 + new_len] = new_prog

sec_offset = (18 * 16 + 14) * 256
dsk[sec_offset : sec_offset + 256] = new_sec

with open('scratch/oldskool_brun.dsk', 'wb') as f:
    f.write(dsk)

print("Saved scratch/oldskool_brun.dsk successfully")
