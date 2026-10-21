import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser = serial.Serial('COM47', 115200, timeout=0.5)

print("Sending Down Arrow (\\x1b[B)...")
ser.write(b'\x1b[B')
time.sleep(0.3)

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c') # PURE 'c'
ser.close()

print("\nScreen state after Down Arrow:")
for r, item_num in ROW_MAP.items():
    if r < len(lines):
        hl = is_row_highlighted(raw[r])
        marker = "-->" if hl else "   "
        print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")
