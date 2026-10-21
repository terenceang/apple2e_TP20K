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

def ensure_true_main_menu(ser):
    for i in range(5):
        ser.write(b'\x02')
        time.sleep(0.05)
        lines, raw = dump_screen(ser)
        ser.write(b'c\r\n')
        time.sleep(0.05)
        if any("Machine Identification" in l for l in lines):
            print(f"Verified on true Main Menu on attempt {i}.")
            return lines, raw
        print(f"Attempt {i}: Sending ESC...")
        send_apple_key(ser, 0x1B)
        time.sleep(0.4)
    return lines, raw

ser = serial.Serial('COM47', 115200, timeout=0.5)

lines, raw = ensure_true_main_menu(ser)

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

# Move up 8 times to guarantee we are at Item 1
print("Moving to Item 1 (Up Arrow)...")
for _ in range(8):
    send_apple_key(ser, 0x0B) # Up arrow
    time.sleep(0.08)

time.sleep(0.2)

# Check current item
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

current_item = 1
for r, num in ROW_MAP.items():
    if is_row_highlighted(raw[r]):
        current_item = num
        break
print(f"Selection is now Item {current_item}.")

# Move down to Item 5
target_item = 5
diff = target_item - current_item
print(f"Moving down {diff} times to Item 5 (RAM Memory Test)...")
for i in range(diff):
    send_apple_key(ser, 0x0A) # Down arrow
    time.sleep(0.1)

time.sleep(0.3)

# Verify Item 5
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')

print("Menu status before pressing Return:")
for r, num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {num} (Row {r:02d}): |{lines[r]}|")

print("\nPressing Return (0x0D) to run RAM Memory Test...")
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
