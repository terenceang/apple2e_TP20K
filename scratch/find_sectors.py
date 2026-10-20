import serial, time

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

for attempt in range(5):
    ser.write(b'\x02')
    time.sleep(0.2)
    chunk = ser.read(ser.in_waiting or 100)
    if b'>' in chunk:
        break

print('Searching memory pages for 9D 75 2A CA...')

# Check common pages: $1E00, $2000, $B600, $B700, $BA00, $9D00, $0800..$3F00
found = []
for page in [0x08, 0x09, 0x0A, 0x0B, 0x1E, 0x20, 0x26, 0x27, 0x28, 0x2A, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x9D, 0xB6, 0xB7, 0xBA]:
    ser.write(b'@')
    time.sleep(0.01)
    addr_str = f'{page:02X}00'
    for ch in addr_str:
        ser.write(ch.encode('ascii'))
        time.sleep(0.01)
    time.sleep(0.02)
    ser.reset_input_buffer()
    ser.write(b'm')
    time.sleep(0.03)
    res = ser.read(ser.in_waiting or 200).decode('ascii', errors='replace')
    for line in res.splitlines():
        if f'${page:02X}00:' in line:
            # Check if non-zero
            hex_part = line.split('|')[0]
            if not all(b == '00' for b in hex_part.split()[1:]):
                print(line.strip())

ser.write(b'c')
ser.close()
