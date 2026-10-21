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

def exit_debugger(ser):
    ser.write(b'c')
    time.sleep(0.1)
    ser.read(ser.in_waiting or 100)

ser = serial.Serial('COM47', 115200, timeout=0.5)
enter_debugger(ser)

print("=== HARDWARE SMOKE TEST ===")

# Query status 't'
ser.write(b't')
time.sleep(0.1)
t_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("Status ('t'):\n", t_resp)

# Query registers 'r'
ser.write(b'r')
time.sleep(0.1)
r_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("Registers ('r'):\n", r_resp)

# Query disk 'i'
ser.write(b'i')
time.sleep(0.1)
i_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("Disk Info ('i'):\n", i_resp)

exit_debugger(ser)
ser.close()
