with open('scratch/oldskool.dsk', 'rb') as f:
    d = f.read()

ts_list2 = d[(2*16 + 1)*256 : (2*16 + 2)*256]
oldskool_bytes = bytearray()
for i in range(128):
    t = ts_list2[12 + i*2]
    s = ts_list2[12 + i*2 + 1]
    if t == 0 and s == 0: break
    oldskool_bytes += d[(t*16 + s)*256 : (t*16 + s + 1)*256]

# Address is 0x1000, length is bytes 2-3
raw_code = oldskool_bytes[4:]

# Let's inspect the first 256 bytes hex
for i in range(0, min(256, len(raw_code)), 16):
    line = raw_code[i:i+16]
    hex_str = " ".join(f"{b:02x}" for b in line)
    asc_str = "".join(chr(b) if 32 <= b <= 126 else "." for b in line)
    print(f"{0x1000 + i:04x}:  {hex_str:<48}  {asc_str}")
