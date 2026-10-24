import serial, time

def enter_debugger(ser):
    ser.reset_input_buffer()
    ser.write(b'\r\n')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '>' in res:
        return
    ser.write(b'\x02')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        ser.write(b'\x02')
        time.sleep(0.2)
        res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')

ser = serial.Serial('COM47', 115200, timeout=0.5)
enter_debugger(ser)

ser.write(b'w')
time.sleep(0.3)
buf = b''
while ser.in_waiting:
    buf += ser.read(ser.in_waiting)
    time.sleep(0.05)

print("Screen dump:")
print(buf.decode('ascii', errors='replace'))

ser.close()
