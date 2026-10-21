import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Press ESC to exit to Main Menu
print("1. Sending ESC to return to Main Menu...")
ser.write(bytes([0xFE, 0x1B, 0x00]))
time.sleep(0.05)
ser.write(bytes([0xFF, 0x04]))
time.sleep(0.5)

# Dump screen using pure 'c' to exit debugger
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c') # PURE 'c', NO \r\n!
time.sleep(0.1)

print("\nScreen state after ESC:")
for r, item_num in ROW_MAP.items():
    if r < len(lines):
        hl = is_row_highlighted(raw[r])
        marker = "-->" if hl else "   "
        print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Wait 1 second and check again - did it stay on the Main Menu?
time.sleep(1.0)
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c') # PURE 'c'!
ser.close()

print("\nScreen state after 1 second (should NOT have auto-entered!):")
for r, item_num in ROW_MAP.items():
    if r < len(lines):
        hl = is_row_highlighted(raw[r])
        marker = "-->" if hl else "   "
        print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")
