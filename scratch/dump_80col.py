import sys
sys.path.append('.')
import serial, time
from scratch.apple2_screen import LINE_OFFSETS, decode_apple2_char

def read_page(ser):
    page = []
    for row_idx, offset in enumerate(LINE_OFFSETS):
        base_addr = 0x0400 + offset
        row_bytes = bytearray()
        for col_block in [0, 16, 32]:
            addr = base_addr + col_block
            ser.write(f'@{addr:04X}\r\nm\r\n'.encode('ascii'))
            time.sleep(0.015)
            resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
            for line in resp.splitlines():
                line = line.strip()
                if line.startswith('$') and '|' in line:
                    tokens = line.split()
                    # tokens[0] is '$0400:' or '$0400;'
                    # tokens[1..16] are hex bytes
                    hex_tokens = tokens[1:17] if col_block < 32 else tokens[1:9]
                    for t in hex_tokens:
                        try:
                            row_bytes.append(int(t, 16))
                        except ValueError:
                            pass
                    break
        page.append(row_bytes[:40])
    return page

if __name__ == '__main__':
    ser = serial.Serial('COM47', 115200, timeout=0.5)
    ser.write(b'\x02')
    time.sleep(0.05)

    main_page = read_page(ser)

    ser.write(b'a')
    time.sleep(0.02)
    aux_page = read_page(ser)

    ser.write(b'a')
    time.sleep(0.02)
    ser.write(b'c')
    ser.close()

    print('=== 40-COLUMN MAIN SCREEN ===')
    for r, row in enumerate(main_page):
        line = ''.join(decode_apple2_char(b) for b in row)
        if line.strip():
            print(f'{r:02d}: |{line}|')

    print('\n=== 40-COLUMN AUX SCREEN ===')
    for r, row in enumerate(aux_page):
        line = ''.join(decode_apple2_char(b) for b in row)
        if line.strip():
            print(f'{r:02d}: |{line}|')

    print('\n=== 80-COLUMN ASSEMBLED SCREEN ===')
    for r in range(24):
        line_80 = []
        for c in range(40):
            aux_c = aux_page[r][c] if c < len(aux_page[r]) else 0x20
            main_c = main_page[r][c] if c < len(main_page[r]) else 0x20
            line_80.append(decode_apple2_char(aux_c))
            line_80.append(decode_apple2_char(main_c))
        line_str = ''.join(line_80)
        if line_str.strip():
            print(f'{r:02d}: |{line_str}|')
