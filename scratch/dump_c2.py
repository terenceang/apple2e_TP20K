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

for addr in ['C200', 'C270', 'C280', 'C290', 'C600']:
    ser.write(f'@{addr}'.encode('ascii'))
    time.sleep(0.05)
    ser.write(b'm')
    time.sleep(0.05)
    print(f"Dump @{addr}:\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace'))

ser.close()
