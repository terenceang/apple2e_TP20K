import serial, time

def set_addr_and_dump(ser, addr_str):
    # Send @ then 4 chars with a tiny pause between
    ser.write(b'@')
    time.sleep(0.02)
    for ch in addr_str:
        ser.write(ch.encode('ascii'))
        time.sleep(0.02)
    time.sleep(0.05)
    ser.reset_input_buffer()
    ser.write(b'm')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 200).decode('ascii', errors='replace')
    return res

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

print('Dumping $0800...')
print(set_addr_and_dump(ser, '0800'))

print('Dumping $3700...')
print(set_addr_and_dump(ser, '3700'))

print('Dumping $3800...')
print(set_addr_and_dump(ser, '3800'))

print('Dumping $3600...')
print(set_addr_and_dump(ser, '3600'))

ser.write(b'c')
ser.close()
