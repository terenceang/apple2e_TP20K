import serial, time

def enter_debugger(ser):
    ser.reset_input_buffer()
    ser.write(b'\r\n')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '>' in res:
        return
    ser.write(b'\x02')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        ser.write(b'\x02')
        time.sleep(0.2)
        res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')

# Apple II text screen row memory offsets
LINE_OFFSETS = [
    0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380,
    0x028, 0x0A8, 0x128, 0x1A8, 0x228, 0x2A8, 0x328, 0x3A8,
    0x050, 0x0D0, 0x150, 0x1D0, 0x250, 0x2D0, 0x350, 0x3D0
]

ser = serial.Serial('COM47', 115200, timeout=0.5)
enter_debugger(ser)

print("\n=== APPLE //E SCREEN (All 24 Lines) ===")
for row_idx, offset in enumerate(LINE_OFFSETS):
    base_addr = 0x0400 + offset
    row_bytes = bytearray()
    for col_block in [0, 16, 32]:
        addr = base_addr + col_block
        ser.write(f'@{addr:04X}'.encode('ascii'))
        time.sleep(0.02)
        ser.write(b'm')
        time.sleep(0.04)
        resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
        # Response has format: "$0400: XX XX ... |ASCII|"
        for line in resp.splitlines():
            if ':' in line and '|' in line:
                hex_part = line.split(':')[1].split('|')[0].strip()
                tokens = hex_part.split()
                row_bytes.extend(int(t, 16) for t in tokens[:16 if col_block < 32 else 8])
                break
    line_str = ''.join(chr(b & 0x7F) if 32 <= (b & 0x7F) < 127 else ' ' for b in row_bytes[:40])
    print(f"{row_idx:02d}: |{line_str}|")

ser.write(b'c')
ser.close()
