import serial, time

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Ensure we are in console mode (not debugger mode)
ser.write(b'\r\n')
time.sleep(0.1)
res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
if '>' in res:
    # We are in debugger, exit with 'c'
    print("In debugger, resuming with 'c'...")
    ser.write(b'c')
    time.sleep(0.1)
    ser.read(ser.in_waiting or 1)

print("Sending 'PRINT 1234+5678' followed by Return...")
# Apple II expects uppercase or standard characters, with CR (\r)
for ch in "PRINT 1234+5678\r":
    ser.write(ch.encode('ascii'))
    time.sleep(0.05)

time.sleep(0.5)

# Now enter debugger to dump the screen
ser.write(b'\x02')
time.sleep(0.2)
res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
if '[Resuming...]' in res:
    ser.write(b'\x02')
    time.sleep(0.2)
    ser.read(ser.in_waiting or 1)

ser.write(b'w')
time.sleep(0.3)
buf = b''
while ser.in_waiting:
    buf += ser.read(ser.in_waiting)
    time.sleep(0.05)

raw_screen = buf.decode('ascii', errors='replace')

# Filter and print readable text lines from screen dump
lines = raw_screen.split('\r\n')
print("\n--- Apple II Screen Text ---")
for line in lines:
    line = line.strip()
    if len(line) == 80 and all(c in '0123456789ABCDEFabcdef' for c in line):
        # Convert 40 hex bytes to ASCII
        chars = []
        for i in range(0, 80, 2):
            val = int(line[i:i+2], 16) & 0x7F
            chars.append(chr(val) if 32 <= val < 127 else ' ')
        txt = ''.join(chars).rstrip()
        if txt:
            print(f"| {txt}")

# Resume execution
ser.write(b'c')
ser.close()
