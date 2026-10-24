import serial, time

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

# Break into debugger
ser.write(b'\x02')
time.sleep(0.2)
ser.read(ser.in_waiting or 100)

ser.write(b'@3700')
time.sleep(0.1)
for i in range(4):
    ser.write(b'm')
    time.sleep(0.1)

mem = ser.read(ser.in_waiting or 1000).decode('ascii', errors='replace')
print('Mem at $3700:\n', mem.strip())

ser.write(b'c')
ser.close()
