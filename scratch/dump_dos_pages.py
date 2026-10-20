import serial, time

def set_addr_and_dump_first(ser, page):
    ser.write(b'@')
    time.sleep(0.01)
    addr_str = f'{page:02X}00'
    for ch in addr_str:
        ser.write(ch.encode('ascii'))
        time.sleep(0.01)
    time.sleep(0.02)
    ser.reset_input_buffer()
    ser.write(b'm')
    time.sleep(0.08)
    res = ser.read(ser.in_waiting or 300).decode('ascii', errors='replace')
    for line in res.splitlines():
        if f'${page:02X}00:' in line:
            return line.strip()
    return f'${page:02X}00: not found'

ser = serial.Serial('COM47', 115200, timeout=1.0)
time.sleep(0.1)
ser.reset_input_buffer()

for attempt in range(5):
    ser.write(b'\x02')
    time.sleep(0.2)
    chunk = ser.read(ser.in_waiting or 100)
    if b'>' in chunk:
        break

for p in range(0x36, 0x40):
    print(set_addr_and_dump_first(ser, p))

ser.write(b'c')
ser.close()
