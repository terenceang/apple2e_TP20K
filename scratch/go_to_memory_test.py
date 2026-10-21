import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

def get_title(ser):
    ser.write(b'\x02')
    time.sleep(0.05)
    lines, raw = dump_screen(ser)
    ser.write(b'c\r\n')
    time.sleep(0.05)
    return lines[0].strip(), lines, raw

def ensure_main_menu(ser):
    for attempt in range(5):
        title, lines, raw = get_title(ser)
        if "Computer Inspector" in title:
            print(f"At Main Menu (attempt {attempt}).")
            return lines, raw
        print(f"Current title: '{title}', sending ESC...")
        ser.write(b'\x1b')
        time.sleep(0.5)
    title, lines, raw = get_title(ser)
    return lines, raw

ser = serial.Serial('COM47', 115200, timeout=0.5)
lines, raw = ensure_main_menu(ser)
print("Title:", lines[0])

# Move up to Option 1
for _ in range(8):
    ser.write(b'\x1b[A')
    time.sleep(0.05)
time.sleep(0.2)

# Move down 4 times to Option 5
print("Moving to Option 5 (RAM Memory Test)...")
for _ in range(4):
    ser.write(b'\x1b[B')
    time.sleep(0.08)
time.sleep(0.3)

title, lines, raw = get_title(ser)
print("Selection on Main Menu:")
for r in [4, 6, 8, 10, 12, 14, 16, 18]:
    inv = any(b < 0x80 for b in raw[r][4:35])
    marker = "-->" if inv else "   "
    print(f"{marker} Row {r:02d}: |{lines[r]}|")

print("Pressing Return to launch RAM Memory Test...")
ser.write(b'\r')
time.sleep(2.0)

title, lines, raw = get_title(ser)
print(f"\nScreen after launching (Title: '{title}'):")
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
