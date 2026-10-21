import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

def ensure_main_menu(ser):
    for _ in range(5):
        ser.write(b'\x02')
        time.sleep(0.05)
        lines, raw = dump_screen(ser)
        ser.write(b'c\r\n')
        time.sleep(0.05)
        if any("Machine Identification" in l for l in lines):
            return lines, raw
        ser.write(b'\x1b')
        time.sleep(0.5)
    return lines, raw

ser = serial.Serial('COM47', 115200, timeout=0.5)

print("1. Ensuring Main Menu...")
lines, raw = ensure_main_menu(ser)

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}
current_item = 1
for r, item_num in ROW_MAP.items():
    if is_row_highlighted(raw[r]):
        current_item = item_num
        break

print(f"2. Current selection is Item {current_item}.")

# Move to Option 5 (RAM Memory Test)
target_item = 5
diff = target_item - current_item
if diff > 0:
    for _ in range(diff):
        ser.write(b'\x1b[B')
        time.sleep(0.12)
elif diff < 0:
    for _ in range(-diff):
        ser.write(b'\x1b[A')
        time.sleep(0.12)

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

print("\n3. Pressing Return to launch Option 5: RAM Memory Test...")
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
