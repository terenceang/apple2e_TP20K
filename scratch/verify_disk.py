import serial, time

DOS_TO_PHYS = [
    0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
    0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf
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

def main():
    disk_path = r'Disk/DOS 3.3 System Master - 680-0210-A.dsk'
    with open(disk_path, 'rb') as f:
        raw_data = f.read()

    expected = dos_to_physical(raw_data)

    ser = serial.Serial('COM47', 115200, timeout=1.0)
    time.sleep(0.1)
    ser.reset_input_buffer()

    print('Breaking into debugger...')
    for attempt in range(5):
        ser.write(b'\x02')
        time.sleep(0.2)
        chunk = ser.read(ser.in_waiting or 100)
        if b'>' in chunk:
            break

    print('Starting e1 download...')
    ser.write(b'e1')
    time.sleep(0.1)

    # Read until we see banner
    banner = b''
    t0 = time.time()
    while time.time() - t0 < 3.0:
        ch = ser.read(1)
        if ch:
            banner += ch
            if b'bytes\r\n' in banner:
                break

    print('Got banner, reading 143360 bytes...')
    downloaded = bytearray()
    t0 = time.time()
    while len(downloaded) < 143360 and time.time() - t0 < 20.0:
        chunk = ser.read(min(4096, 143360 - len(downloaded)))
        if chunk:
            downloaded.extend(chunk)

    print(f'Downloaded {len(downloaded)} bytes in {time.time() - t0:.2f}s')

    # Compare with expected
    diffs = 0
    first_diff = None
    for i in range(min(len(downloaded), len(expected))):
        if downloaded[i] != expected[i]:
            diffs += 1
            if first_diff is None:
                first_diff = i

    print(f'Total differences: {diffs}')
    if first_diff is not None:
        print(f'First difference at offset {first_diff} (0x{first_diff:04X}):')
        print(f'  Expected: {expected[first_diff]:02X}')
        print(f'  Got:      {downloaded[first_diff]:02X}')
        print('Expected surrounding:')
        start = max(0, first_diff - 8)
        print(' '.join(f'{b:02X}' for b in expected[start:start+16]))
        print('Got surrounding:')
        print(' '.join(f'{b:02X}' for b in downloaded[start:start+16]))
    else:
        print('SUCCESS! ALL 143,360 BYTES IN DDR3 MATCH EXPECTED BIT-FOR-BIT!')

    ser.close()

if __name__ == '__main__':
    main()
