import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to ensure we are on Main Menu
print("1. Sending ESC to return to Main Menu...")
ser.write(b'\x1b')
time.sleep(0.5)

# Move up to Option 1 first
print("2. Moving to Option 1...")
for _ in range(8):
    ser.write(b'\x1b[A')
    time.sleep(0.06)

time.sleep(0.2)

# Move down 4 times to Option 5 (RAM Memory Test)
print("3. Moving down 4 times to Option 5 (RAM Memory Test)...")
for i in range(4):
    ser.write(b'\x1b[B')
    time.sleep(0.08)

time.sleep(0.3)

# Verify selection is Option 5
ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("Main Menu Selection:")
for r in [4, 6, 8, 10, 12, 14, 16, 18]:
    inv = any(b < 0x80 for b in raw[r][4:35])
    marker = "-->" if inv else "   "
    print(f"{marker} Row {r:02d}: |{lines[r]}|")

# Now press Return to enter RAM Memory Test!
print("\n4. Pressing Return to run RAM Memory Test...")
ser.write(b'\r')
time.sleep(2.0)

# Dump initial memory test screen
ser.write(b'\x02')
time.sleep(0.1)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("\n=== RAM MEMORY TEST SCREEN ===")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
