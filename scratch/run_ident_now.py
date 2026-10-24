import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

ser = serial.Serial('COM47', 115200, timeout=0.5)

print("Pressing Return on Option 1 (Machine Identification)...")
ser.write(b'\r')
time.sleep(2.0)

# Dump screen
ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
ser.close()

print("\n================== MACHINE IDENTIFICATION SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")
