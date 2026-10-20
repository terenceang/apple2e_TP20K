import serial, time

def set_addr_and_dump_page(ser, addr_str):
    ser.write(b'@')
    time.sleep(0.02)
    for ch in addr_str:
        ser.write(ch.encode('ascii'))
        time.sleep(0.02)
    time.sleep(0.05)
    ser.reset_input_buffer()
    for _ in range(10):
        ser.write(b'm')
        time.sleep(0.02)
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

dump = set_addr_and_dump_page(ser, '3700')
print('Memory Page $37 right now:\n')
for line in dump.splitlines():
    if '$37' in line:
        print(line)

ser.write(b'c')
ser.close()
