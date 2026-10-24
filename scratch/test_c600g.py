import serial, time

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

# Send C600G and Enter
print('Sending C600G\\r...')
for ch in 'C600G\r':
    ser.write(ch.encode('ascii'))
    time.sleep(0.05)

print('Waiting 4 seconds for execution...')
time.sleep(4.0)

# Break into debugger to dump screen and check PC
ser.write(b'\x02')
time.sleep(0.2)
regs = ser.read(ser.in_waiting or 200).decode('ascii', errors='replace')
print('Regs after C600G:\n', regs.strip())

ser.write(b'w')
time.sleep(0.3)
scr_raw = ser.read(ser.in_waiting or 3000).decode('ascii', errors='replace')

print('================ APPLE //e SCREEN ================')
for line in scr_raw.splitlines():
    line = line.strip()
    if not line or line.startswith('$SS') or line.startswith('$GF') or line.startswith('$SEND') or line.startswith('>'):
        continue
    if len(line) >= 80:
        chars = []
        for j in range(0, 80, 2):
            val = int(line[j:j+2], 16) & 0x7F
            chars.append(chr(val) if 0x20 <= val <= 0x7E else ' ')
        print(''.join(chars))
print('==================================================')

ser.write(b'c')
ser.close()
