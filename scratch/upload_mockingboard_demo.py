import sys
import time
import serial

DOS_TO_PHYS = [
    0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
    0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf
]

LINE_OFFSETS = [
    0x000, 0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380,
    0x028, 0x0A8, 0x128, 0x1A8, 0x228, 0x2A8, 0x328, 0x3A8,
    0x050, 0x0D0, 0x150, 0x1D0, 0x250, 0x2D0, 0x350, 0x3D0
]

def dos_to_physical(src):
    assert len(src) == 143360
    dst = bytearray(143360)
    for t in range(35):
        for sec in range(16):
            from_idx = t * 4096 + sec * 256
            to_idx = t * 4096 + DOS_TO_PHYS[sec] * 256
            dst[to_idx : to_idx + 256] = src[from_idx : from_idx + 256]
    return bytes(dst)

def dump_screen(ser):
    lines = []
    for row_idx, offset in enumerate(LINE_OFFSETS):
        base_addr = 0x0400 + offset
        row_bytes = bytearray()
        for col_block in [0, 16, 32]:
            addr = base_addr + col_block
            ser.write(f'@{addr:04X}'.encode('ascii'))
            time.sleep(0.015)
            ser.write(b'm')
            time.sleep(0.03)
            resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
            for line in resp.splitlines():
                if ':' in line and '|' in line:
                    hex_part = line.split(':')[1].split('|')[0].strip()
                    tokens = hex_part.split()
                    row_bytes.extend(int(t, 16) for t in tokens[:16 if col_block < 32 else 8])
                    break
        line_str = ''.join(chr(b & 0x7F) if 32 <= (b & 0x7F) < 127 else ' ' for b in row_bytes[:40])
        lines.append(line_str)
    return lines

def main():
    disk_path = r'Disk/Mockingboard_Sound_and_Speech_I_Demo_Disk_Apple_II_Plus_Sweet_Micro_Systems_1982.dsk'
    port = 'COM47'

    print(f"Reading {disk_path}...")
    with open(disk_path, 'rb') as f:
        raw_data = f.read()

    to_upload = dos_to_physical(raw_data)

    ser = serial.Serial(port, 115200, timeout=1.0)
    time.sleep(0.1)
    ser.reset_input_buffer()

    print("Breaking into debugger...")
    ser.write(b'\x02')
    time.sleep(0.2)
    resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    if '[Resuming...]' in resp:
        ser.write(b'\x02')
        time.sleep(0.2)

    print("Starting d1 upload...")
    ser.write(b'd1')
    time.sleep(0.1)

    banner = b''
    t0 = time.time()
    while time.time() - t0 < 3.0:
        ch = ser.read(1)
        if ch:
            banner += ch
            if b'bytes\r\n' in banner:
                break

    print("Uploading 143,360 bytes...")
    CHUNK_SIZE = 1024
    t0 = time.time()
    for i in range(0, len(to_upload), CHUNK_SIZE):
        ser.write(to_upload[i : i + CHUNK_SIZE])
        time.sleep(0.08)

    while time.time() - t0 < 20.0:
        chunk = ser.read(ser.in_waiting or 100)
        if b'done' in chunk or b'>' in chunk:
            break
        time.sleep(0.05)
    print(f"Upload complete in {time.time() - t0:.2f}s.")

    # Check disk status
    ser.write(b'i')
    time.sleep(0.1)
    print("Disk status:", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace').strip())

    # Resume CPU into console mode
    print("Resuming CPU...")
    ser.write(b'c')
    time.sleep(0.5)

    # Cancel any partial line with Ctrl-C
    ser.write(b'\x03\r')
    time.sleep(0.3)

    # Send PR#6
    print("Sending 'PR#6'...")
    for ch in "PR#6\r":
        ser.write(ch.encode('ascii'))
        time.sleep(0.06)

    print("Waiting 6s for boot...")
    time.sleep(6.0)

    # Inspect state
    ser.write(b'\x02')
    time.sleep(0.2)
    ser.write(b'i')
    time.sleep(0.1)
    i_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    ser.write(b'r')
    time.sleep(0.1)
    r_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    ser.write(b't')
    time.sleep(0.1)
    t_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')

    screen = dump_screen(ser)

    ser.write(b'c')
    ser.close()

    print(f"\nDisk Status: {i_resp.strip()}")
    print(f"Registers:   {r_resp.strip()}")
    print(f"Hardware:    {t_resp.strip()}")

    print("\n=== SCREEN OUTPUT ===")
    for idx, l in enumerate(screen):
        if l.strip():
            print(f"{idx:02d}: |{l}|")

if __name__ == '__main__':
    main()
