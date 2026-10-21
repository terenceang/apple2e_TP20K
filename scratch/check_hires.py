import serial, time

ser = serial.Serial('COM47', 115200, timeout=0.5)
ser.write(b'\x02')
time.sleep(0.1)
ser.read(ser.in_waiting or 1)

# In Apple II Hi-Res:
# Row 0: 0x2000
# Row 8: 0x2080
# Row 16: 0x2100
# Row 64: 0x2028
# Let's count non-0x00 and non-0x80 bytes in the 8KB Hi-Res buffer ($2000-$3FFF)
non_blank = 0
unique_bytes = set()
for base in range(0x2000, 0x4000, 0x100):
    ser.write(f'@{base:04X}\r'.encode('ascii'))
    time.sleep(0.02)
    ser.write(b'm')
    time.sleep(0.03)
    resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    for line in resp.splitlines():
        if ':' in line and '|' in line:
            tokens = line.split(':')[1].split('|')[0].strip().split()
            for t in tokens:
                val = int(t, 16)
                unique_bytes.add(val)
                if val not in (0x00, 0x80):
                    non_blank += 1

print(f"Sampled Hi-Res memory non-blank count: {non_blank}, unique bytes: {len(unique_bytes)}")

# Also check Page 2 ($4000-$5FFF)
non_blank_p2 = 0
for base in range(0x4000, 0x6000, 0x100):
    ser.write(f'@{base:04X}\r'.encode('ascii'))
    time.sleep(0.02)
    ser.write(b'm')
    time.sleep(0.03)
    resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    for line in resp.splitlines():
        if ':' in line and '|' in line:
            tokens = line.split(':')[1].split('|')[0].strip().split()
            for t in tokens:
                val = int(t, 16)
                if val not in (0x00, 0x80):
                    non_blank_p2 += 1

print(f"Sampled Page 2 memory non-blank count: {non_blank_p2}")

ser.write(b'c')
ser.close()
