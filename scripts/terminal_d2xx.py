#!/usr/bin/env python3
"""
Apple //e Interactive D2XX Terminal for Tang Nano 20K (Windows)
Connects directly to Channel B (UART) via ftd2xx.dll without requiring a VCP COM port.
"""

import sys
import time
import threading

try:
    import ctypes
    ftdi = ctypes.windll.LoadLibrary('ftd2xx.dll')
except Exception as e:
    print(f"Error loading ftd2xx.dll: {e}")
    sys.exit(1)

FT_OK = 0

def open_channel_b():
    num = ctypes.c_ulong()
    if ftdi.FT_CreateDeviceInfoList(ctypes.byref(num)) != FT_OK or num.value == 0:
        raise RuntimeError("No FTDI devices detected.")
    
    target_idx = None
    for i in range(num.value):
        flags = ctypes.c_ulong()
        typ = ctypes.c_ulong()
        dev_id = ctypes.c_ulong()
        loc_id = ctypes.c_ulong()
        serial = ctypes.create_string_buffer(64)
        desc = ctypes.create_string_buffer(64)
        handle = ctypes.c_void_p()
        ftdi.FT_GetDeviceInfoDetail(i, ctypes.byref(flags), ctypes.byref(typ), ctypes.byref(dev_id), ctypes.byref(loc_id), serial, desc, ctypes.byref(handle))
        d_name = desc.value.decode('utf-8', errors='ignore')
        s_name = serial.value.decode('utf-8', errors='ignore')
        if d_name.endswith(' B') or s_name.endswith('B'):
            target_idx = i
            break
            
    if target_idx is None:
        target_idx = 1 if num.value > 1 else 0

    h = ctypes.c_void_p()
    if ftdi.FT_Open(target_idx, ctypes.byref(h)) != FT_OK:
        raise RuntimeError(f"Failed to open FTDI device index {target_idx}")

    ftdi.FT_ResetDevice(h)
    ftdi.FT_SetBaudRate(h, 115200)
    ftdi.FT_SetDataCharacteristics(h, 8, 0, 0)
    ftdi.FT_SetFlowControl(h, 0, 0, 0)
    ftdi.FT_SetTimeouts(h, 100, 100)
    ftdi.FT_Purge(h, 3)
    return h

def main():
    print("Connecting to Apple //e on Tang Nano 20K via FTDI D2XX...")
    try:
        h = open_channel_b()
    except Exception as e:
        print(f"Connection failed: {e}")
        return

    print("Connected! Type commands (Ctrl+C to exit).")
    print("Tip: Press Enter or type Applesoft BASIC commands like 'NEW', '10 PRINT \"HI\"', 'RUN'\n")

    running = True

    def reader_thread():
        while running:
            rx_q = ctypes.c_ulong()
            tx_q = ctypes.c_ulong()
            evt = ctypes.c_ulong()
            ftdi.FT_GetStatus(h, ctypes.byref(rx_q), ctypes.byref(tx_q), ctypes.byref(evt))
            if rx_q.value > 0:
                buf = ctypes.create_string_buffer(rx_q.value)
                read_b = ctypes.c_ulong()
                ftdi.FT_Read(h, buf, rx_q.value, ctypes.byref(read_b))
                text = buf.raw[:read_b.value].decode('latin1', errors='replace')
                sys.stdout.write(text)
                sys.stdout.flush()
            else:
                time.sleep(0.01)

    t = threading.Thread(target=reader_thread, daemon=True)
    t.start()

    try:
        import msvcrt
        while True:
            ch = msvcrt.getch()
            if ch == b'\x03': # Ctrl+C
                break
            elif ch == b'\r':
                written = ctypes.c_ulong()
                ftdi.FT_Write(h, b'\r', 1, ctypes.byref(written))
            elif ch == b'\x08': # Backspace
                written = ctypes.c_ulong()
                ftdi.FT_Write(h, b'\x08', 1, ctypes.byref(written))
            elif ch == b'\xe0': # Special / Arrow keys
                ch2 = msvcrt.getch()
                # ANSI arrow mapping: Up=0x0B, Down=0x0A, Right=0x15, Left=0x08
                arrow_map = {b'H': b'\x1b[A', b'P': b'\x1b[B', b'M': b'\x1b[C', b'K': b'\x1b[D'}
                seq = arrow_map.get(ch2, b'')
                if seq:
                    written = ctypes.c_ulong()
                    ftdi.FT_Write(h, seq, len(seq), ctypes.byref(written))
            else:
                written = ctypes.c_ulong()
                ftdi.FT_Write(h, ch, len(ch), ctypes.byref(written))
    except KeyboardInterrupt:
        pass
    finally:
        running = False
        time.sleep(0.1)
        ftdi.FT_Close(h)
        print("\nDisconnected.")

if __name__ == '__main__':
    main()
