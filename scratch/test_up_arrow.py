import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to return to Main Menu
print("1. Sending ESC to return to Main Menu...")
ser.write(b'\x1b')
time.sleep(0.6)

# Send Up Arrow: \x1b [ A
print("2. Sending Up Arrow (\\x1b[A)...")
ser.write(b'\x1b[A')
time.sleep(0.5)

# Dump screen to verify cursor position
ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
ser.close()

print("\nMain Menu after Up Arrow:")
for r in [4, 6, 8, 10, 12, 14, 16, 18]:
    inv = any(b < 0x80 for b in raw[r][4:35])
    marker = "-->" if inv else "   "
    print(f"{marker} Row {r:02d}: |{lines[r]}|")
