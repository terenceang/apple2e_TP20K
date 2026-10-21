import os, sys, time, serial

DOS_TO_PHYS = [
    0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
    0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf
]

def map_sectors(raw_data):
    assert len(raw_data) == 143360
    dst = bytearray(143360)
    for t in range(35):
        for sec in range(16):
            from_idx = t * 4096 + sec * 256
            to_idx = t * 4096 + DOS_TO_PHYS[sec] * 256
            dst[to_idx : to_idx + 256] = raw_data[from_idx : from_idx + 256]
    return bytes(dst)

def enter_debugger(ser):
    ser.reset_input_buffer()
    ser.write(b'\r\n')
    time.sleep(0.05)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '>' in res:
        return
    ser.write(b'\x02')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        ser.write(b'\x02')
        time.sleep(0.1)
        ser.read(ser.in_waiting or 1)

LINE_OFFSETS = [
    0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380,
    0x028, 0x0A8, 0x128, 0x1A8, 0x228, 0x2A8, 0x328, 0x3A8,
    0x050, 0x0D0, 0x150, 0x1D0, 0x250, 0x2D0, 0x350, 0x3D0
]

def dump_screen(ser):
    lines = []
    for row_idx, offset in enumerate(LINE_OFFSETS):
        base_addr = 0x0400 + offset
        row_bytes = bytearray()
        for col_block in [0, 16, 32]:
            addr = base_addr + col_block
            ser.write(f'@{addr:04X}'.encode('ascii'))
            time.sleep(0.015)
            ser.write(b'm')
            time.sleep(0.03)
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

disk_path = r'Disk/ComputerInspector (MECC 1.0).dsk'
with open(disk_path, 'rb') as f:
    raw_data = f.read()

mapped = map_sectors(raw_data)

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.2)

print("1. Entering debugger...")
enter_debugger(ser)

ser.write(b't\r\n')
time.sleep(0.05)
t_status = ser.read(ser.in_waiting or 200).decode('ascii', errors='replace')
print("Status:\n", t_status.strip())

print("2. Starting d1 upload...")
ser.write(b'd1')
time.sleep(0.1)

banner = b''
t0 = time.time()
while time.time() - t0 < 3.0:
    ch = ser.read(1)
    if ch:
        banner += ch
        if b'bytes\r\n' in banner:
            break

print("3. Uploading 143,360 bytes of MECC...")
CHUNK_SIZE = 1024
for i in range(0, len(mapped), CHUNK_SIZE):
    ser.write(mapped[i : i + CHUNK_SIZE])
    time.sleep(0.08)

t0 = time.time()
while time.time() - t0 < 5.0:
    chunk = ser.read(ser.in_waiting or 100)
    if b'done' in chunk.lower() or b'>' in chunk:
        break
    time.sleep(0.05)

print("4. Upload completed. Checking checksum...")
ser.write(b'i\r\n')
time.sleep(0.05)
i_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("Disk checksum:", i_resp.strip())

print("5. Pulsing hardware reset ('x')...")
ser.write(b'x')
time.sleep(0.2)
ser.read(ser.in_waiting or 100)

print("6. Resuming execution to trigger cold boot from Slot 6 ('c')...")
ser.write(b'c\r\n')
time.sleep(0.05)

print("7. Waiting 5.0 seconds for MECC Computer Inspector to boot...")
time.sleep(5.0)

print("8. Checking machine state...")
enter_debugger(ser)

ser.write(b'i\r\n')
time.sleep(0.05)
i_resp2 = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')

ser.write(b'r\r\n')
time.sleep(0.05)
r_resp2 = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')

print(f"Disk Status: {i_resp2.strip()}")
print(f"Registers:   {r_resp2.strip()}")

print("\n=== SCREEN OUTPUT ===")
screen = dump_screen(ser)

ser.write(b'c\r\n')
ser.close()

for idx, l in enumerate(screen):
    if l.strip():
        print(f"{idx:02d}: |{l}|")
