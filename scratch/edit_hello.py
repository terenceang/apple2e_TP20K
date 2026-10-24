import struct

# Let's inspect the original HELLO
with open('scratch/oldskool.dsk', 'rb') as f:
    dsk = bytearray(f.read())

sec_offset = (18 * 16 + 14) * 256
orig_sec = dsk[sec_offset : sec_offset + 256]
orig_len = orig_sec[0] | (orig_sec[1] << 8)
orig_prog = orig_sec[2 : 2 + orig_len]

print(f"Original program length: {orig_len} bytes")

# Lines to encode
lines = [
    (10, b'\x97\x3a\xba\x00'), # HOME:PRINT
    (50, b'\xba" OLDSKOOL FORT ET VERT  by FRENCH TOUCH"\x00'),
    (51, b'\xba\x00'),
    (55, b'\xba"     8KB INTRO for APPLE IIe (6502)"\x00'),
    (60, b'\xba"           with MOCKINGBOARD"\x00'),
    (100, b'\xba\xe7(4)"CATALOG"\x00'),
    (150, b'\xba\x00'),
    (230, b'\xba\x00'),
    (240, b'\xba"TYPE BRUN OLDSKOOL TO LAUNCH"\x00'),
    (250, b'\xba\xe7(4)"BRUN OLDSKOOL"\x00'),
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
print(f"New program length: {len(new_prog)} bytes (at addr 0x{addr:04x})")

# Let's verify that the original lines 10..240 match exactly byte-for-byte!
orig_prefix_len = len(new_prog) - (len(lines[-1][1]) + 4) - 2 # excluding line 250 and 00 00
assert orig_prog[:orig_prefix_len] == new_prog[:orig_prefix_len], "Prefix mismatch!"
print("Prefix lines 10..240 match original byte-for-byte!")

# Now build the new sector
new_sec = bytearray(256)
new_len = len(new_prog)
new_sec[0] = new_len & 0xff
new_sec[1] = (new_len >> 8) & 0xff
new_sec[2 : 2 + new_len] = new_prog

print(f"New sector built, {new_len + 2} of 256 bytes used.")

# Write to modified dsk
dsk[sec_offset : sec_offset + 256] = new_sec
with open('scratch/oldskool_brun.dsk', 'wb') as f:
    f.write(dsk)

print("Saved scratch/oldskool_brun.dsk")
