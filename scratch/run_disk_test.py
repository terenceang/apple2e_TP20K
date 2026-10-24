import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to exit RAM Memory Test back to Main Menu
print("1. Sending ESC to return to Main Menu...")
ser.write(b'\x1b')
time.sleep(0.5)

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c')
time.sleep(0.05)

print("\nMain Menu selection:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Move from Item 5 to Item 4 (Up Arrow)
print("\n2. Moving Up to Item 4: Disk Drive Test (\\x1b[A)...")
ser.write(b'\x1b[A')
time.sleep(0.3)

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c')
time.sleep(0.05)

print("Main Menu selection after Up Arrow:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Launch Item 4: Disk Drive Test
print("\n3. Launching Item 4: Disk Drive Test (pressing Return)...")
ser.write(b'\r')
time.sleep(2.5)

# Dump initial disk test screen
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c')

print("\n================== DISK DRIVE TEST INITIAL SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

# If it asks for slot/drive or options, let's see
# Often it has options: Speed test, Read verification, etc.
time.sleep(1.0)
# Press Space / Return if prompted
ser.write(b'\r')
time.sleep(4.0)

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c')

print("\n================== DISK DRIVE TEST SCREEN AFTER RETURN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
