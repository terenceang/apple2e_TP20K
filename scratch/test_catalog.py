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

# First ensure console mode
enter_debugger(ser)
exit_debugger(ser)

# Send Ctrl+C then Return to get a clean prompt
ser.write(b'\x03\r')
time.sleep(0.2)

# Type CATALOG
print("Sending CATALOG...")
for ch in "CATALOG\r":
    ser.write(ch.encode('ascii'))
    time.sleep(0.05)

# Wait 2 seconds for DOS to read disk catalog from Drive 1
time.sleep(2.0)

# Enter debugger to read screen
enter_debugger(ser)

ser.write(b'w')
time.sleep(0.3)
buf = b''
while ser.in_waiting:
    buf += ser.read(ser.in_waiting)
    time.sleep(0.05)

exit_debugger(ser)
ser.close()

raw_screen = buf.decode('ascii', errors='replace')
lines = raw_screen.split('\r\n')
print("\n=== CATALOG Screen Output ===")
for line in lines:
    line = line.strip()
    if len(line) == 80 and all(c in '0123456789ABCDEFabcdef' for c in line):
        chars = []
        for i in range(0, 80, 2):
            val = int(line[i:i+2], 16) & 0x7F
            chars.append(chr(val) if 32 <= val < 127 else ' ')
        txt = ''.join(chars).rstrip()
        if txt:
            print(txt)
