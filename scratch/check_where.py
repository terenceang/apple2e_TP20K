import serial, time

ser = serial.Serial('COM47', 115200, timeout=0.5)
ser.write(b'\x02')
time.sleep(0.2)
res = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
if '[Resuming...]' in res:
    # toggled out, toggle back in
    ser.write(b'\x02')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("Status after Ctrl+B:\n", res)

ser.write(b'r')
time.sleep(0.1)
print("Registers:\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace'))

ser.write(b'p')
time.sleep(0.1)
print("PC History:\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace'))

ser.close()
