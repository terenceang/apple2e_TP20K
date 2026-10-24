import os, sys, time, serial
sys.path.append('.')
from scratch.apple2_screen import dump_screen

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

disk_path = r'Disk/ProDOS_2_4_2.dsk'
print(f"Reading {disk_path}...")
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

print("2. Starting d1 upload for ProDOS 2.4.2...")
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

print("3. Uploading 143,360 bytes...")
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

# Make sure debugger is exited to console mode before sending key packets
print("5. Exiting debugger to console mode...")
ser.write(b'c')
time.sleep(0.1)
ser.read(ser.in_waiting or 100)

# Trigger Cold Reset via Solid-Apple + Reset (invoking Auto Boot ROM)
print("6. Sending Solid-Apple + Reset to trigger Auto Boot ROM (0xFF 0x03 0x0A)...")
ser.write(bytes([0xFF, 0x03, 0x0A]))
time.sleep(0.2)

print("7. Releasing Reset while holding Solid-Apple (0xFF 0x03 0x02)...")
ser.write(bytes([0xFF, 0x03, 0x02]))
time.sleep(0.3)

print("8. Releasing Solid-Apple (0xFF 0x03 0x00)...")
ser.write(bytes([0xFF, 0x03, 0x00]))
time.sleep(0.1)

print("9. Waiting 6.0 seconds for Auto Boot ROM to boot ProDOS (NO PR#6 sent)...")
time.sleep(6.0)

print("10. Entering debugger to inspect state...")
enter_debugger(ser)

ser.write(b'i\r\n')
time.sleep(0.05)
i_resp2 = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')

ser.write(b'r\r\n')
time.sleep(0.05)
r_resp2 = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')

print(f"Disk Status: {i_resp2.strip()}")
print(f"Registers:   {r_resp2.strip()}")

print("\n=== APPLE //E SCREEN OUTPUT ===")
screen, _ = dump_screen(ser)

ser.write(b'c')
ser.close()

for idx, l in enumerate(screen):
    if l.strip():
        print(f"{idx:02d}: |{l}|")
