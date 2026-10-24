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
        line_str = ''.join(decode_apple2_char(b) for b in row_bytes[:40])
        lines.append(line_str)
    return lines

ser = serial.Serial('COM47', 115200, timeout=0.5)

print("1. Moving cursor to Option 1 (pressing Up Arrow 5 times)...")
for _ in range(5):
    ser.write(b'\x1b[A')
    time.sleep(0.05)

time.sleep(0.2)
print("2. Selecting Option 1: Machine Identification (Space)...")
ser.write(b' ')
time.sleep(2.0)

print("3. Capturing Machine Identification screen...")
ser.write(b'\x02')
time.sleep(0.1)
screen = dump_screen(ser)
ser.write(b'c\r\n')

print("\n================ MACHINE IDENTIFICATION ================")
for idx, l in enumerate(screen):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

# Check if there is a prompt at bottom
print("\nPressing Space / Return to return to Main Menu...")
ser.write(b' ')
time.sleep(0.5)
ser.write(b'\x1b')
time.sleep(0.5)

ser.close()
