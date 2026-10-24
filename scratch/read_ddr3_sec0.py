import serial, time

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

# Break into debugger
for attempt in range(5):
    ser.write(b'\x02')
    time.sleep(0.2)
    chunk = ser.read(ser.in_waiting or 100)
    if b'>' in chunk:
        break

print('Sending e1...')
ser.write(b'e1')
time.sleep(0.2)

# Wait for DOWNLOAD banner
banner = b''
t0 = time.time()
while time.time() - t0 < 2.0:
    ch = ser.read(ser.in_waiting or 1)
    if ch:
        banner += ch
        if b'bytes\r\n' in banner:
            break

print('Banner:', repr(banner))

# Read first 256 bytes
data = b''
t0 = time.time()
while len(data) < 256 and time.time() - t0 < 3.0:
    ch = ser.read(256 - len(data))
    if ch:
        data += ch

print(f'Read {len(data)} bytes from DDR3')
print('DDR3 sector 0 (bytes 0x00 to 0x40):')
for i in range(0, 0x40, 16):
    print(f'{i:02X}: ' + ' '.join(f'{b:02X}' for b in data[i:i+16]))

print('DDR3 sector 0 (bytes 0x80 to 0xC0):')
for i in range(0x80, 0xC0, 16):
    print(f'{i:02X}: ' + ' '.join(f'{b:02X}' for b in data[i:i+16]))

ser.close()
