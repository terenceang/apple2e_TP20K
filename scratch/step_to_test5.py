import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to exit to Main Menu
print("1. Sending ESC to return to Main Menu...")
ser.write(b'\x1b')
time.sleep(0.5)

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}
print("Main Menu at start:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Move up to Item 1 first
print("\nMoving up to Item 1 (\\x1b[A)...")
for _ in range(8):
    ser.write(b'\x1b[A')
    time.sleep(0.1)

time.sleep(0.3)
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("After Up Arrows:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Now step down to Item 5 (4 times)
print("\nStepping down 4 times (\\x1b[B)...")
for step in range(4):
    ser.write(b'\x1b[B')
    time.sleep(0.2)

time.sleep(0.3)
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("Selection before pressing Return:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Launch Item 5: RAM Memory Test!
print("\nPressing Return to execute RAM Memory Test...")
ser.write(b'\r')
time.sleep(3.0)

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("\n================== RAM MEMORY TEST SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
