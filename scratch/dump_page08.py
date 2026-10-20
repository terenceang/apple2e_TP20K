import serial, time

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

# Break into debugger
ser.write(b'\x02')
time.sleep(0.2)
ser.read(ser.in_waiting or 100)

ser.write(b'8')
time.sleep(0.1)
for i in range(16):
    ser.write(b'm')
    time.sleep(0.05)

mem = ser.read(ser.in_waiting or 3000).decode('ascii', errors='replace')
print('Page $08:\n')
for line in mem.splitlines():
    if '$08' in line:
        print(line)

ser.write(b'c')
ser.close()
