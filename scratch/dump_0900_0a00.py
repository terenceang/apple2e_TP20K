import serial, time

def set_addr_and_dump(ser, addr_str):
    ser.write(b'@')
    time.sleep(0.02)
    for ch in addr_str:
        ser.write(ch.encode('ascii'))
        time.sleep(0.02)
    time.sleep(0.05)
    ser.reset_input_buffer()
    lines = []
    for _ in range(16):
        ser.write(b'm')
        time.sleep(0.03)
    res = ser.read(ser.in_waiting or 3000).decode('ascii', errors='replace')
    return res

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

for attempt in range(5):
    ser.write(b'\x02')
    time.sleep(0.2)
    chunk = ser.read(ser.in_waiting or 100)
    if b'>' in chunk:
        break

print('Dumping $0900..$09FF:')
print(set_addr_and_dump(ser, '0900'))

print('Dumping $0A00..$0AFF:')
print(set_addr_and_dump(ser, '0A00'))

ser.write(b'c')
ser.close()
