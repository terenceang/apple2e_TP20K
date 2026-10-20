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

# Send 'a' to toggle aux back to main RAM
ser.write(b'a')
time.sleep(0.1)
ser.read(ser.in_waiting or 100)

ser.write(b'@3700')
time.sleep(0.05)
ser.reset_input_buffer()
for _ in range(10):
    ser.write(b'm')
    time.sleep(0.02)

dump = ser.read(ser.in_waiting or 3000).decode('ascii', errors='replace')
print('Main RAM Page $37:\n')
for line in dump.splitlines():
    if '$37' in line:
        print(line)

ser.write(b'c')
ser.close()
