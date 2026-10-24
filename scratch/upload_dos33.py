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

    to_upload = dos_to_physical(raw_data)

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

    print('Starting d1 upload...')
    ser.write(b'd1')
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

    print('Got banner, sending 143,360 bytes...')
    CHUNK_SIZE = 1024
    t0 = time.time()
    for i in range(0, len(to_upload), CHUNK_SIZE):
        ser.write(to_upload[i : i + CHUNK_SIZE])
        # Short sleep to prevent UART FIFO overflow
        time.sleep(0.08)

    print(f'Sent all bytes in {time.time() - t0:.2f}s, waiting for DONE...')
    resp = b''
    t0 = time.time()
    while time.time() - t0 < 5.0:
        chunk = ser.read(ser.in_waiting or 100)
        if chunk:
            resp += chunk
            if b'DONE' in resp or b'>' in resp:
                break
        time.sleep(0.05)

    print('Response:', resp.decode('ascii', errors='replace').strip())
    ser.close()

if __name__ == '__main__':
    main()
