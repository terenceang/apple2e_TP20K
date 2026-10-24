import os, sys, time, subprocess, serial

DOS_TO_PHYS = [
    0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
    0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf
]

def map_sectors(raw_data):
    assert len(raw_data) == 143360
    dst = bytearray(143360)
    for t in range(35):
        for sec in range(16):
            from_idx = t * 4096 + sec * 256
            to_idx = t * 4096 + DOS_TO_PHYS[sec] * 256
            dst[to_idx : to_idx + 256] = raw_data[from_idx : from_idx + 256]
    return bytes(dst)

LINE_OFFSETS = [
    0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380,
    0x028, 0x0A8, 0x128, 0x1A8, 0x228, 0x2A8, 0x328, 0x3A8,
    0x050, 0x0D0, 0x150, 0x1D0, 0x250, 0x2D0, 0x350, 0x3D0
]

def decode_apple2_char(b):
    c = b & 0x7F
    if c < 0x20:
        return chr(c + 0x40)
    return chr(c)

def dump_screen(ser):
    lines = []
    raw_lines = []
    for row_idx, offset in enumerate(LINE_OFFSETS):
        base_addr = 0x0400 + offset
        row_bytes = bytearray()
        for col_block in [0, 16, 32]:
            addr = base_addr + col_block
            ser.write(f'@{addr:04X}\r\nm\r\n'.encode('ascii'))
            time.sleep(0.012)
            resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
            for line in resp.splitlines():
                if ':' in line and '|' in line:
                    hex_part = line.split(':')[1].split('|')[0].strip()
                    tokens = hex_part.split()
                    row_bytes.extend(int(t, 16) for t in tokens[:16 if col_block < 32 else 8])
                    break
        raw_lines.append(row_bytes[:40])
        line_str = ''.join(decode_apple2_char(b) for b in row_bytes[:40])
        lines.append(line_str)
    return lines, raw_lines

def send_apple_key(ser, key_code):
    ser.write(bytes([0xFE, key_code, 0x00]))
    time.sleep(0.04)
    ser.write(bytes([0xFF, 0x04]))
    time.sleep(0.04)

def enter_debugger(ser):
    ser.reset_input_buffer()
    ser.write(b'\r\n')
    time.sleep(0.05)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '>' in res:
        return
    ser.write(b'\x02')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        ser.write(b'\x02')
        time.sleep(0.1)
        ser.read(ser.in_waiting or 1)

def exit_debugger(ser):
    ser.write(b'c\r\n')
    time.sleep(0.05)
    ser.read(ser.in_waiting or 100)

def flash_fpga():
    print("Reloading FPGA SRAM with top.fs...")
    cmd = [
        r"C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe",
        "-d", "GW2A-18C",
        "--run", "2",
        "--fsFile", r"C:\Users\teren\source\repos\apple2e_TP20K\impl\pnr\top.fs"
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if "Finished" not in res.stdout:
        print("Programming error:", res.stdout, res.stderr)
        raise RuntimeError("Failed to program FPGA")
    print("FPGA reconfigured successfully.")

def upload_and_boot():
    with open(r'Disk/ComputerInspector (MECC 1.0).dsk', 'rb') as f:
        raw_data = f.read()
    mapped = map_sectors(raw_data)

    ser = serial.Serial('COM47', 115200, timeout=1.0)
    time.sleep(0.2)
    enter_debugger(ser)

    print("Uploading MECC image...")
    ser.write(b'd1')
    time.sleep(0.1)

    # banner
    t0 = time.time()
    while time.time() - t0 < 3.0:
        if b'bytes\r\n' in ser.read(ser.in_waiting or 1):
            break

    CHUNK = 1024
    for i in range(0, len(mapped), CHUNK):
        ser.write(mapped[i : i + CHUNK])
        time.sleep(0.08)

    t0 = time.time()
    while time.time() - t0 < 5.0:
        chunk = ser.read(ser.in_waiting or 100)
        if b'done' in chunk.lower() or b'>' in chunk:
            break
        time.sleep(0.05)

    print("Pulsing hardware reset ('x')...")
    ser.write(b'x')
    time.sleep(0.2)
    ser.read(ser.in_waiting or 100)

    print("Booting MECC from Slot 6 ('c')...")
    exit_debugger(ser)

    print("Waiting 5.0 seconds for MECC to load main menu...")
    time.sleep(5.0)

    return ser

def main():
    flash_fpga()
    ser = upload_and_boot()

    # Verify Main Menu
    enter_debugger(ser)
    lines, raw = dump_screen(ser)
    exit_debugger(ser)

    print("\n================ MAIN MENU ================")
    for idx, l in enumerate(lines):
        if l.strip():
            print(f"{idx:02d}: |{l}|")

    # TEST 5: RAM MEMORY TEST
    print("\n>>> Moving to Test 5: RAM Memory Test (4 Down Arrows)...")
    for _ in range(4):
        send_apple_key(ser, 0x0A)
        time.sleep(0.1)
    time.sleep(0.3)

    print("Launching Test 5: RAM Memory Test (Return)...")
    send_apple_key(ser, 0x0D)
    time.sleep(3.0)

    enter_debugger(ser)
    lines, raw = dump_screen(ser)
    exit_debugger(ser)

    print("\n================ [TEST 5] RAM MEMORY TEST INITIAL SCREEN ================")
    for idx, l in enumerate(lines):
        if l.strip():
            print(f"{idx:02d}: |{l}|")

    # If it asks to start test or press space, let's see what is on screen
    # Often it says "Press Space Bar to begin test" or similar
    time.sleep(1.0)
    print("\nSending Space / Return to run the memory test patterns...")
    send_apple_key(ser, 0x20) # Space
    time.sleep(0.5)
    send_apple_key(ser, 0x0D) # Return
    time.sleep(5.0) # Wait for memory test to execute passes

    enter_debugger(ser)
    lines, raw = dump_screen(ser)
    exit_debugger(ser)

    print("\n================ [TEST 5] RAM MEMORY TEST RESULTS ================")
    for idx, l in enumerate(lines):
        if l.strip():
            print(f"{idx:02d}: |{l}|")

    # Wait another 5 seconds in case it runs multiple passes
    time.sleep(5.0)
    enter_debugger(ser)
    lines, raw = dump_screen(ser)
    exit_debugger(ser)

    print("\n================ [TEST 5] RAM MEMORY TEST RESULTS (After 10s) ================")
    for idx, l in enumerate(lines):
        if l.strip():
            print(f"{idx:02d}: |{l}|")

    ser.close()

if __name__ == "__main__":
    main()
