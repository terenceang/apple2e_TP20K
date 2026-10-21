#!/usr/bin/env python3
"""
scripts/upload_disk.py - Upload a Disk II image (.dsk or .po) to Tang Primer 20K DDR3.

Handles DOS 3.3 logical-to-physical sector interleaving and uploads over the 1Mbps UART
via the hardware debugger 'd1' or 'd2' command.

Usage:
    python scripts/upload_disk.py <image.dsk> [--drive 1|2] [--port COM47] [--baud 1000000]
"""

import sys
import os
import argparse
import time
import serial

# DOS 3.3 logical to physical sector interleaving
DOS_TO_PHYS = [
    0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
    0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf
]

# ProDOS / 2img block to physical sector interleaving
PRODOS_TO_PHYS = [
    0x0, 0x8, 0x1, 0x9, 0x2, 0xa, 0x3, 0xb,
    0x4, 0xc, 0x5, 0xd, 0x6, 0xe, 0x7, 0xf
]

def map_sectors(raw_data, order='dos'):
    if len(raw_data) != 143360:
        raise ValueError(f"Disk image size must be exactly 143,360 bytes (got {len(raw_data)}).")
    
    if order == 'raw':
        return raw_data

    mapping = PRODOS_TO_PHYS if order == 'prodos' else DOS_TO_PHYS
    dst = bytearray(143360)
    for t in range(35):
        for sec in range(16):
            from_idx = t * 4096 + sec * 256
            to_idx = t * 4096 + mapping[sec] * 256
            dst[to_idx : to_idx + 256] = raw_data[from_idx : from_idx + 256]
    return bytes(dst)

def enter_debugger(ser):
    ser.reset_input_buffer()
    ser.write(b'\r\n')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '>' in res:
        return
    ser.write(b'\x02')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        ser.write(b'\x02')
        time.sleep(0.2)
        ser.read(ser.in_waiting or 1)

def main():
    parser = argparse.ArgumentParser(description="Upload disk image to Apple //e on Tang Primer 20K.")
    parser.add_argument("disk", help="Path to .dsk or .po image")
    parser.add_argument("--drive", type=int, choices=[1, 2], default=1, help="Drive number (1 or 2)")
    parser.add_argument("--port", default="COM47", help="Serial COM port")
    parser.add_argument("--baud", type=int, default=1000000, help="Baud rate (default: 1000000)")
    parser.add_argument("--order", choices=["auto", "dos", "prodos", "raw"], default="auto",
                        help="Sector interleaving order (default: auto based on extension)")
    args = parser.parse_args()

    if not os.path.exists(args.disk):
        print(f"Error: file not found: {args.disk}", file=sys.stderr)
        sys.exit(1)

    order = args.order
    if order == "auto":
        order = "prodos" if args.disk.lower().endswith(".po") else "dos"

    with open(args.disk, "rb") as f:
        raw_data = f.read()

    to_upload = map_sectors(raw_data, order)
    print(f"Prepared 143,360 bytes using '{order}' sector interleaving for Drive {args.drive}.")

    ser = serial.Serial(args.port, args.baud, timeout=1.0)
    time.sleep(0.1)

    print(f"Connecting to debugger on {args.port}...")
    enter_debugger(ser)

    cmd = f"d{args.drive}".encode("ascii")
    print(f"Sending '{cmd.decode()}' upload command...")
    ser.write(cmd)
    time.sleep(0.1)

    # Consume upload banner
    banner = b''
    t0 = time.time()
    while time.time() - t0 < 3.0:
        ch = ser.read(1)
        if ch:
            banner += ch
            if b'bytes\r\n' in banner:
                break

    print("Uploading disk image chunks...")
    CHUNK_SIZE = 1024
    t0 = time.time()
    for i in range(0, len(to_upload), CHUNK_SIZE):
        ser.write(to_upload[i : i + CHUNK_SIZE])
        time.sleep(0.08)

    # Wait for completion
    resp = b''
    t0 = time.time()
    while time.time() - t0 < 5.0:
        chunk = ser.read(ser.in_waiting or 100)
        if chunk:
            resp += chunk
            if b'done' in resp.lower() or b'>' in resp:
                break
        time.sleep(0.05)

    print(f"Upload complete in {time.time() - t0:.2f}s.")
    print("Resuming execution...")
    ser.write(b'c')
    time.sleep(0.1)
    ser.close()
    print("Done! If in Applesoft BASIC, type 'PR#6' or enter Monitor ('CALL -151') and type 'C600G' to boot.")

if __name__ == "__main__":
    main()
