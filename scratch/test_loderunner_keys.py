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

# Check runner position in zero page
# In Lode Runner, runner coordinates are at $00, $01 (or $02, $03)
ser.write(b'@0000\r')
time.sleep(0.04)
ser.write(b'm')
time.sleep(0.04)
zp_before = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("Zero page before move:\n", zp_before.strip())

# Resume CPU
ser.write(b'c')
time.sleep(0.1)

# Send 'K' (Move Right) multiple times
print("Sending movement keys (K = Right)...")
for _ in range(5):
    ser.write(b'K')
    time.sleep(0.1)

time.sleep(0.5)

enter_debugger(ser)
ser.write(b'@0000\r')
time.sleep(0.04)
ser.write(b'm')
time.sleep(0.04)
zp_after = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print("\nZero page after move:\n", zp_after.strip())

ser.write(b'c')
ser.close()
