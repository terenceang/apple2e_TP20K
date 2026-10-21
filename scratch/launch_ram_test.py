import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def send_apple_key(ser, key_code):
    ser.write(bytes([0xFE, key_code, 0x00]))
    time.sleep(0.04)
    ser.write(bytes([0xFF, 0x04]))
    time.sleep(0.04)

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ser = serial.Serial('COM47', 115200, timeout=0.5)

# First ensure Main Menu
ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

current_item = None
for r, num in ROW_MAP.items():
    if is_row_highlighted(raw[r]):
        current_item = num
        break

print(f"Current selection is Item {current_item}.")

# Move to Item 5 (RAM Memory Test)
target_item = 5
diff = target_item - current_item
if diff > 0:
    for _ in range(diff):
        print("Moving down (0x0A)...")
        send_apple_key(ser, 0x0A)
        time.sleep(0.08)
elif diff < 0:
    for _ in range(-diff):
        print("Moving up (0x0B)...")
        send_apple_key(ser, 0x0B)
        time.sleep(0.08)

time.sleep(0.2)

# Verify Item 5 highlighted
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

for r, num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {num} (Row {r:02d}): |{lines[r]}|")

print("\nLaunching Option 5: RAM Memory Test (0x0D)...")
send_apple_key(ser, 0x0D)
time.sleep(2.0)

# Dump RAM Memory Test screen
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("\n================== RAM MEMORY TEST SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
