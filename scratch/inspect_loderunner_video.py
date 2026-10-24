import serial, time

ser = serial.Serial('COM47', 115200, timeout=0.5)
ser.write(b'\x02')
time.sleep(0.1)
ser.read(ser.in_waiting or 1)

# Inspect registers
ser.write(b'r')
time.sleep(0.05)
print("Registers:", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

# Inspect zero page variables $95, $96, $A6, $A7
ser.write(b'@0090\r')
time.sleep(0.05)
ser.write(b'm')
time.sleep(0.05)
print("ZP $90-$9F:", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

ser.write(b'@00A0\r')
time.sleep(0.05)
ser.write(b'm')
time.sleep(0.05)
print("ZP $A0-$AF:", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

# Check status of video softswitches
ser.write(b't')
time.sleep(0.05)
print("Hardware Status:", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

# Sample Page 1 ($2000) non-blank bytes
p1_bytes = []
for row in [0x2000, 0x2080, 0x2100, 0x2400, 0x2800]:
    ser.write(f'@{row:04X}\r'.encode('ascii'))
    time.sleep(0.03)
    ser.write(b'm')
    time.sleep(0.03)
    p1_bytes.append(ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())
print("\nPage 1 samples:\n" + "\n".join(p1_bytes))

# Sample Page 2 ($4000) non-blank bytes
p2_bytes = []
for row in [0x4000, 0x4080, 0x4100, 0x4400, 0x4800]:
    ser.write(f'@{row:04X}\r'.encode('ascii'))
    time.sleep(0.03)
    ser.write(b'm')
    time.sleep(0.03)
    p2_bytes.append(ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())
print("\nPage 2 samples:\n" + "\n".join(p2_bytes))

ser.write(b'c')
ser.close()
