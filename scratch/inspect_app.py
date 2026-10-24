with open('scratch/oldskool.dsk', 'rb') as f:
    d = f.read()

ts_list = d[(18*16 + 15)*256 : (18*16 + 16)*256]
hello_bytes = bytearray()
for i in range(128):
    t = ts_list[12 + i*2]
    s = ts_list[12 + i*2 + 1]
    if t == 0 and s == 0: break
    hello_bytes += d[(t*16 + s)*256 : (t*16 + s + 1)*256]

prog = hello_bytes[2: 2 + (hello_bytes[0] | (hello_bytes[1] << 8))]
tokens = {
    0x84: 'PRINT', 0x97: 'TEXT', 0xBA: 'REM', 0x8C: 'BRUN', 0x8F: 'BLOAD', 0xC4: 'CHR$'
}
idx = 0
while idx < len(prog) - 2:
    nxt = prog[idx] | (prog[idx+1] << 8)
    if nxt == 0: break
    lineno = prog[idx+2] | (prog[idx+3] << 8)
    line_bytes = prog[idx+4 : nxt - 0x801]
    s = ""
    for b in line_bytes:
        if b in tokens:
            s += " " + tokens[b] + " "
        elif 32 <= b <= 126:
            s += chr(b)
        else:
            s += f"[{b:02x}]"
    print(f"{lineno}: {s}")
    idx = nxt - 0x801

# Also check OLDSKOOL binary file header:
# B 33 OLDSKOOL (T/S 2/1)
ts_list2 = d[(2*16 + 1)*256 : (2*16 + 2)*256]
oldskool_bytes = bytearray()
for i in range(128):
    t = ts_list2[12 + i*2]
    s = ts_list2[12 + i*2 + 1]
    if t == 0 and s == 0: break
    oldskool_bytes += d[(t*16 + s)*256 : (t*16 + s + 1)*256]

addr = oldskool_bytes[0] | (oldskool_bytes[1] << 8)
length = oldskool_bytes[2] | (oldskool_bytes[3] << 8)
print(f"\nOLDSKOOL binary: load_addr = 0x{addr:04X}, length = 0x{length:04X} ({length} bytes)")
