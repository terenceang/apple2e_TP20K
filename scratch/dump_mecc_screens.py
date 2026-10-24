import serial, time

LINE_OFFSETS = [
    0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380,
    0x028, 0x0A8, 0x128, 0x1A8, 0x228, 0x2A8, 0x328, 0x3A8,
    0x050, 0x0D0, 0x150, 0x1D0, 0x250, 0x2D0, 0x350, 0x3D0
]

def dump_page(ser, base_page=0x0400):
    lines = []
    for row_idx, offset in enumerate(LINE_OFFSETS):
        base_addr = base_page + offset
        row_bytes = bytearray()
        for col_block in [0, 16, 32]:
            addr = base_addr + col_block
            ser.write(f'@{addr:04X}\r\nm\r\n'.encode('ascii'))
            time.sleep(0.02)
            resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
            for line in resp.splitlines():
                if ':' in line and '|' in line:
                    hex_part = line.split(':')[1].split('|')[0].strip()
                    tokens = hex_part.split()
                    row_bytes.extend(int(t, 16) for t in tokens[:16 if col_block < 32 else 8])
                    break
        line_str = ''.join(chr(b & 0x7F) if 32 <= (b & 0x7F) < 127 else ' ' for b in row_bytes[:40])
        lines.append(line_str)
    return lines

ser = serial.Serial('COM47', 115200, timeout=0.5)
ser.write(b'\x02')
time.sleep(0.05)

print("=== TEXT PAGE 1 ($0400) ===")
p1 = dump_page(ser, 0x0400)
for idx, l in enumerate(p1):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

print("\n=== TEXT PAGE 2 ($0800) ===")
p2 = dump_page(ser, 0x0800)
for idx, l in enumerate(p2):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

# Check aux text page 1
ser.write(b'a\r\n')
time.sleep(0.05)
print("\n=== AUX TEXT PAGE 1 ($0400) ===")
p1_aux = dump_page(ser, 0x0400)
for idx, l in enumerate(p1_aux):
    if l.strip():
        print(f"{idx:02d}: |{l}|")
ser.write(b'a\r\n')
time.sleep(0.05)

ser.write(b'c\r\n')
ser.close()
