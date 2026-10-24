import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to ensure we are on Main Menu
ser.write(b'\x1b')
time.sleep(0.5)

print("Sending Left Arrow (\\x1b[D) 8 times to reach Item 1...")
for _ in range(8):
    ser.write(b'\x1b[D')
    time.sleep(0.08)

time.sleep(0.3)

ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("Menu status after Left Arrows:")
for r in [4, 6, 8, 10, 12, 14, 16, 18]:
    inv = any(b < 0x80 for b in raw[r][4:35])
    marker = "-->" if inv else "   "
    print(f"{marker} Row {r:02d}: |{lines[r]}|")

print("\nNow sending Right Arrow (\\x1b[C)...")
ser.write(b'\x1b[C')
time.sleep(0.3)

ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
ser.close()

print("Menu status after Right Arrow:")
for r in [4, 6, 8, 10, 12, 14, 16, 18]:
    inv = any(b < 0x80 for b in raw[r][4:35])
    marker = "-->" if inv else "   "
    print(f"{marker} Row {r:02d}: |{lines[r]}|")
