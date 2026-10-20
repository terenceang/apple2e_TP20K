import serial, time

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

# Break into debugger
for attempt in range(5):
    ser.write(b'\x02')
    time.sleep(0.2)
    chunk = ser.read(ser.in_waiting or 100)
    if b'>' in chunk:
        break

ser.write(b't')
time.sleep(0.2)
print('Diag:', ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

# Send d1
ser.write(b'd1')
time.sleep(0.2)
banner = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
print('Banner:', banner.strip())

# Send 1 byte: 0x01
print('Sending byte 0 (0x01)...')
ser.write(b'\x01')
time.sleep(0.1)
print('In waiting after byte 0:', ser.in_waiting)

# Send byte 1: 0xA5
print('Sending byte 1 (0xA5)...')
ser.write(b'\xA5')
time.sleep(0.1)
print('In waiting after byte 1:', ser.in_waiting)

# Break into debugger to see where it is
print('Breaking in...')
ser.write(b'\x02')
time.sleep(0.2)
dbg = ser.read(ser.in_waiting or 200).decode('ascii', errors='replace')
print('Debugger:\n', dbg.strip())

ser.close()
