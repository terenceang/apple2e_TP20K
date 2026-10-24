import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

ser = serial.Serial('COM47', 115200, timeout=0.5)

# Step down to Item 4, then Item 5
print("1. Sending Down Arrow (to Item 4)...")
ser.write(b'\x1b[B')
time.sleep(0.3)

print("2. Sending Down Arrow (to Item 5: RAM Memory Test)...")
ser.write(b'\x1b[B')
time.sleep(0.3)

# Verify Item 5
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

# Launch Item 5: RAM Memory Test
print("\n3. Launching Item 5: RAM Memory Test (pressing Return)...")
ser.write(b'\r')
time.sleep(3.0)

# Dump the Memory Test screen
ser.write(b'\x02')
time.sleep(0.05)
lines, raw = dump_screen(ser)
ser.write(b'c')

print("\n================== RAM MEMORY TEST SCREEN ==================")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

# If it prompts to press space / return to begin test
time.sleep(1.0)
print("\n4. Starting memory test execution...")
ser.write(b' ')
time.sleep(0.5)
ser.write(b'\r')

# Monitor memory test progress
for poll in range(5):
    time.sleep(3.0)
    ser.write(b'\x02')
    time.sleep(0.05)
    lines, raw = dump_screen(ser)
    ser.write(b'c')
    print(f"\n--- Poll {poll+1} (after {(poll+1)*3}s) ---")
    for idx, l in enumerate(lines):
        if l.strip():
            print(f"{idx:02d}: |{l}|")
    if any("PASSED" in l or "FAILED" in l or "Complete" in l or "Press Space" in l for l in lines):
        break

ser.close()
