import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import dump_screen

def is_row_highlighted(raw_row):
    return any(b < 0x80 for b in raw_row[4:35])

ROW_MAP = {4: 1, 6: 2, 8: 3, 10: 4, 12: 5, 14: 6, 16: 7, 18: 8}

def get_current_menu_item(raw):
    for r, item_num in ROW_MAP.items():
        if is_row_highlighted(raw[r]):
            return item_num
    return None

def navigate_to_item(ser, target_item):
    for _ in range(10):
        ser.write(b'\x02')
        time.sleep(0.04)
        lines, raw = dump_screen(ser)
        ser.write(b'c')
        time.sleep(0.04)
        curr = get_current_menu_item(raw)
        if curr == target_item:
            return True
        if curr is None:
            time.sleep(0.2)
            continue
        if curr < target_item:
            ser.write(b'\x1b[B') # Down arrow
        else:
            ser.write(b'\x1b[A') # Up arrow
        time.sleep(0.25)
    return False

def get_clean_screen(ser):
    ser.write(b'\x02')
    time.sleep(0.04)
    lines, raw = dump_screen(ser)
    ser.write(b'c')
    time.sleep(0.04)
    return lines, raw

def print_screen_box(title, lines):
    print(f"\n{'='*15} {title} {'='*15}")
    for idx, l in enumerate(lines):
        if l.strip():
            print(f"{idx:02d}: |{l}|")
    print(f"{'='*(32 + len(title))}\n")

results = {}

ser = serial.Serial('COM47', 115200, timeout=0.5)
time.sleep(0.2)

# --- 1. Machine Identification ---
print("Running Option 1: Machine Identification...")
navigate_to_item(ser, 1)
ser.write(b'\r')
time.sleep(2.0)
lines, _ = get_clean_screen(ser)
results['1_machine_id'] = [l for l in lines if l.strip()]
print_screen_box("1. Machine Identification", lines)

# Return to Main Menu
ser.write(b'\x1b')
time.sleep(1.0)

# --- 2. Monitor Adjustment ---
print("Running Option 2: Monitor Adjustment...")
navigate_to_item(ser, 2)
ser.write(b'\r')
time.sleep(1.5)
lines, _ = get_clean_screen(ser)
results['2_monitor_adj'] = [l for l in lines if l.strip()]
print_screen_box("2. Monitor Adjustment Menu", lines)

# Return to Main Menu
ser.write(b'\x1b')
time.sleep(1.0)

# --- 3. Disk Drive Test (Write-protect test) ---
print("Running Option 4: Disk Drive Test...")
navigate_to_item(ser, 4)
ser.write(b'\r')
time.sleep(1.5)
lines, _ = get_clean_screen(ser)
results['4_disk_menu'] = [l for l in lines if l.strip()]
print_screen_box("4. Disk Drive Menu", lines)

# Move down to 3: Write-protect Switch
ser.write(b'\x1b[B\x1b[B')
time.sleep(0.3)
ser.write(b'\r')
time.sleep(1.5)
# Slot 6 Drive 1 prompt -> Return
ser.write(b'\r')
time.sleep(1.5)
lines, _ = get_clean_screen(ser)
results['4_disk_wp'] = [l for l in lines if l.strip()]
print_screen_box("4. Disk Write-Protect Test", lines)

# Return to Main Menu (ESC twice)
ser.write(b'\x1b')
time.sleep(0.5)
ser.write(b'\x1b')
time.sleep(1.0)

# --- 4. RAM Memory Test ---
print("Running Option 5: RAM Memory Test (Main + Aux 128K)...")
navigate_to_item(ser, 5)
ser.write(b'\r')
print("Waiting 12 seconds for full RAM test to complete...")
time.sleep(12.0)
lines, _ = get_clean_screen(ser)
results['5_ram_test'] = [l for l in lines if l.strip()]
print_screen_box("5. RAM Memory Test Results", lines)

# Return to Main Menu
ser.write(b'\x1b')
time.sleep(1.0)

# --- 5. Joystick/Paddle Test ---
print("Running Option 6: Joystick/Paddle Test...")
navigate_to_item(ser, 6)
ser.write(b'\r')
time.sleep(1.5)
lines, _ = get_clean_screen(ser)
results['6_joystick_test'] = [l for l in lines if l.strip()]
print_screen_box("6. Joystick/Paddle Test", lines)

# Return to Main Menu
ser.write(b'\x1b')
time.sleep(1.0)

# --- 6. Information ---
print("Running Option 7: Information...")
navigate_to_item(ser, 7)
ser.write(b'\r')
time.sleep(1.5)
lines, _ = get_clean_screen(ser)
results['7_info_page1'] = [l for l in lines if l.strip()]
print_screen_box("7. Information (Page 1)", lines)

ser.close()
print("All MECC Computer Inspector diagnostic tests finished!")
