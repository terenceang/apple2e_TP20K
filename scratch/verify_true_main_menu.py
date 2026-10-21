import sys
sys.path.append('.')
import serial, time
from scratch.test_down_arrow import dump_screen

def is_main_menu(lines):
    for l in lines:
        if "Machine Identification" in l:
            return True
    return False

ser = serial.Serial('COM47', 115200, timeout=0.5)

for attempt in range(6):
    ser.write(b'\x02')
    time.sleep(0.05)
    lines, raw = dump_screen(ser)
    ser.write(b'c\r\n')
    time.sleep(0.05)
    
    if is_main_menu(lines):
        print("Confirmed on true Main Menu!")
        break
    print(f"Attempt {attempt}: not yet main menu (title: {lines[0]}). Sending ESC...")
    ser.write(b'\x1b')
    time.sleep(0.6)

# Print current main menu screen
for idx, l in enumerate(lines):
    if l.strip():
        print(f"{idx:02d}: |{l}|")

ser.close()
