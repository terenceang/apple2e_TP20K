import serial, time

LINE_OFFSETS = [
    0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380,
    0x028, 0x0A8, 0x128, 0x1A8, 0x228, 0x2A8, 0x328, 0x3A8,
    0x050, 0x0D0, 0x150, 0x1D0, 0x250, 0x2D0, 0x350, 0x3D0
]

def decode_apple2_char(b):
    c = b & 0x7F
    if c < 0x20:
        return chr(c + 0x40)
    return chr(c)

def dump_screen(ser):
    lines = []
    raw_lines = []
    for row_idx, offset in enumerate(LINE_OFFSETS):
        base_addr = 0x0400 + offset
        row_bytes = bytearray()
        for col_block in [0, 16, 32]:
            addr = base_addr + col_block
            ser.write(f'@{addr:04X}\r\nm\r\n'.encode('ascii'))
            time.sleep(0.012)
            resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
            for line in resp.splitlines():
                if ':' in line and '|' in line:
                    hex_part = line.split(':')[1].split('|')[0].strip()
                    tokens = hex_part.split()
                    row_bytes.extend(int(t, 16) for t in tokens[:16 if col_block < 32 else 8])
                    break
        raw_lines.append(row_bytes[:40])
        line_str = ''.join(decode_apple2_char(b) for b in row_bytes[:40])
        lines.append(line_str)
    return lines, raw_lines

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to get to Main Menu
print("Ensuring Main Menu...")
ser.write(b'\x1b')
time.sleep(0.5)

# Move to Option 1
for _ in range(8):
    ser.write(b'\x1b[A') # Up arrow
    time.sleep(0.05)
time.sleep(0.2)

# Verify we are on Option 1
ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
print("Current selection:")
for r in [4, 6, 8, 10, 12, 14, 16, 18]:
    inv = any(b < 0x80 for b in raw[r][4:35])
    marker = "-->" if inv else "   "
    print(f"{marker} Row {r:02d}: |{lines[r]}|")

# Now press Return to enter Option 1!
print("\nPressing Return to execute Option 1: Machine Identification...")
ser.write(b'\r')
time.sleep(2.5)

# Dump the Machine Identification screen
ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
ser.close()

print("\n================== [1] MACHINE IDENTIFICATION ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")
