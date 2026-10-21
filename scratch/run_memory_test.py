import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Find which row is currently highlighted
ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

current_item = 1
for r, item_num in ROW_MAP.items():
    if is_row_highlighted(raw[r]):
        current_item = item_num
        break

print(f"Current selection is Item {current_item}.")

# We want Item 5 (RAM Memory Test)
target_item = 5
diff = target_item - current_item
if diff > 0:
    for _ in range(diff):
        print("Sending Down Arrow...")
        ser.write(b'\x1b[B')
        time.sleep(0.1)
elif diff < 0:
    for _ in range(-diff):
        print("Sending Up Arrow...")
        ser.write(b'\x1b[A')
        time.sleep(0.1)

time.sleep(0.3)

# Verify we are on Item 5
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

print("\nPressing Return to launch RAM Memory Test...")
ser.write(b'\r')
time.sleep(3.0)

# Dump screen
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("\n================== RAM MEMORY TEST SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
