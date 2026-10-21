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

# 1. Send ESC to return to true Main Menu
print("1. Sending ESC to return to Main Menu...")
send_apple_key(ser, 0x1B)
time.sleep(0.5)

# Verify we are on Main Menu
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}
print("\nMain Menu at start:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# 2. Reset selection to Item 1 by sending Left Arrow (0x08) 8 times
print("\n2. Resetting selection to Item 1 by sending 8 Left Arrows (0x08)...")
for _ in range(8):
    send_apple_key(ser, 0x08)
    time.sleep(0.08)

time.sleep(0.2)
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("Selection after 8 Left Arrows:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# 3. Move down 4 times using Right Arrow (0x15) to reach Item 5 (RAM Memory Test)
print("\n3. Moving to Item 5 by sending 4 Right Arrows (0x15)...")
for i in range(4):
    send_apple_key(ser, 0x15)
    time.sleep(0.1)

time.sleep(0.3)
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("Selection after 4 Right Arrows:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# 4. Launch Option 5: RAM Memory Test!
print("\n4. Launching Item 5: RAM Memory Test (0x0D Return)...")
send_apple_key(ser, 0x0D)
time.sleep(3.0)

# Dump RAM Memory Test Screen
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("\n================== RAM MEMORY TEST SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
