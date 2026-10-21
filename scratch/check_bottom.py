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

for addr in ['07D0', '3FC0', '3BC0', '3F50']:
    ser.write(f'@{addr}'.encode('ascii'))
    time.sleep(0.04)
    ser.write(b'm')
    time.sleep(0.04)
    print(f"Dump @{addr}:\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

ser.write(b'c')
ser.close()
