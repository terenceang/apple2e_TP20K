import sys
sys.path.append('.')
import serial, time
from scratch.disasm_mecc_boot import disasm

ser = serial.Serial('COM47', 115200, timeout=0.5)
ser.write(b'\x02')
time.sleep(0.05)
ser.write(b'@7080\r\n')
time.sleep(0.05)
data = bytearray()
for _ in range(6):
    ser.write(b'm\r\n')
    time.sleep(0.04)
    resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    for line in resp.splitlines():
        if ':' in line and '|' in line:
            tokens = line.split(':')[1].split('|')[0].strip().split()
            data.extend(int(t, 16) for t in tokens)

ser.write(b'c\r\n')
ser.close()

disasm(bytes(data), 0x7080, 40)
