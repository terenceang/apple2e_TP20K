import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def send_key(ser, code):
    ser.write(bytes([0xFE, code, 0x00]))
    time.sleep(0.05)
    ser.write(bytes([0xFF, 0x04]))
    time.sleep(0.05)

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Verify we are on Main Menu
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

print("Current Main Menu State:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

# Step down until Item 5 is highlighted
print("\nStepping down to Item 5 (RAM Memory Test)...")
for step in range(8):
    # Check if Item 5 is already highlighted
    ser.write(b'\x02')
    time.sleep(0.04)
    lines, raw = dump_screen(ser)
    ser.write(b'c\r\n')
    time.sleep(0.04)

    if is_row_highlighted(raw[12]):
        print("Item 5 (RAM Memory Test) is HIGHLIGHTED!")
        break

    print(f"Step {step}: sending Down Arrow (0x0A)...")
    send_key(ser, 0x0A)
    time.sleep(0.2)

# Verify Item 5
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c\r\n')
time.sleep(0.05)

print("\nFinal check before Return:")
for r, item_num in ROW_MAP.items():
    hl = is_row_highlighted(raw[r])
    marker = "-->" if hl else "   "
    print(f"{marker} Item {item_num} (Row {r:02d}): |{lines[r]}|")

print("\nPressing Return to execute RAM Memory Test...")
send_key(ser, 0x0D)
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
