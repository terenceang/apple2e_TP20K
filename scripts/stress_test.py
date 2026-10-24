"""Apple //e Enhanced Built-in Diagnostic Soak / Stress Test Runner
Communicates over the Tang Primer 20K UART (1 Mbps) using the serial debugger and input controller.
"""

import argparse
import sys
import time
import serial


def decode_apple_screen_row(hex_str: str) -> str:
    """Decode a 40-byte hex string (80 hex chars) from the Apple //e screen dump."""
    chars = []
    for i in range(0, len(hex_str), 2):
        byte = int(hex_str[i : i + 2], 16)
        ascii_code = byte & 0x7F
        if 32 <= ascii_code <= 126:
            chars.append(chr(ascii_code))
        else:
            chars.append(" ")
    return "".join(chars)


def run_stress_test(port="COM47", duration_sec=60, continuous=False):
    print(f"[*] Opening {port} at 1,000,000 baud...")
    try:
        ser = serial.Serial(port, 1000000, timeout=0.5)
    except Exception as e:
        print(f"[-] Failed to open {port}: {e}")
        return False

    ser.reset_input_buffer()

    # Step 1: Ensure CPU is unpaused
    print("[*] Resuming CPU...")
    ser.write(b"c\r\n")
    time.sleep(0.1)
    ser.read_all()

    # Step 2: Trigger Apple //e Enhanced Self-Test
    # 0xFF 0x03 0x0B: Reset asserted (bit 3) with Open-Apple (bit 0) and Closed-Apple (bit 1) held
    print("[*] Asserting Reset with Open-Apple + Closed-Apple held...")
    ser.write(b"\xff\x03\x0b")
    time.sleep(0.3)

    # 0xFF 0x03 0x03: Reset released, but keep Open-Apple and Closed-Apple held
    # When both Apple keys are held, ROM jumps back to $C600 at the end of every pass (continuous loop)
    print(
        "[*] Releasing Reset while latching Open-Apple + Closed-Apple high (Continuous Loop Mode)..."
    )
    ser.write(b"\xff\x03\x03")

    print(
        f"[*] Stress test running! Soak duration: {duration_sec}s (Continuous={continuous})"
    )
    start_time = time.time()

    try:
        iteration = 0
        while True:
            elapsed = time.time() - start_time
            if not continuous and elapsed >= duration_sec:
                break

            time.sleep(5)
            iteration += 1

            # Pause briefly to check status
            ser.write(b"\x02")
            time.sleep(0.1)

            # Query hardware status
            ser.write(b"t\r\n")
            time.sleep(0.05)
            t_resp = ser.read_all().decode("ascii", errors="replace")

            # Query CPU registers
            ser.write(b"r\r\n")
            time.sleep(0.05)
            r_resp = ser.read_all().decode("ascii", errors="replace")

            # Resume
            ser.write(b"c\r\n")

            # Parse status
            vid_pll = ""
            for line in t_resp.splitlines():
                if "VID:" in line or "PLL:" in line:
                    vid_pll = line.strip()
                    break

            pc_val = ""
            for line in r_resp.splitlines():
                if "PC:" in line:
                    pc_val = line.strip()
                    break

            print(
                f"[{int(elapsed):4d}s] Iteration {iteration} | {vid_pll} | {pc_val}"
            )

    except KeyboardInterrupt:
        print("\n[*] Interrupted by user!")

    # Step 3: Stop continuous loop by releasing Apple keys (0xFF 0x03 0x00)
    print(
        "[*] Releasing Open-Apple + Closed-Apple buttons (0xFF 0x03 0x00) to allow final pass to complete..."
    )
    ser.write(b"\xff\x03\x00")

    # Wait for the current test pass to complete (approx 15-20 seconds)
    print("[*] Waiting ~20 seconds for final verification pass to complete...")
    for i in range(20, 0, -5):
        print(f"    ... {i}s remaining")
        time.sleep(5)

    # Step 4: Check screen buffer for "System OK"
    ser.write(b"\x02")
    time.sleep(0.1)
    ser.write(b"w\r\n")
    time.sleep(0.3)
    w_resp = ser.read_all().decode("ascii", errors="replace")

    # Resume CPU
    ser.write(b"c\r\n")
    ser.close()

    # Search for decoded text
    print("\n" + "=" * 50)
    print("           DIAGNOSTIC TEST RESULT")
    print("=" * 50)

    found_ok = False
    for line in w_resp.splitlines():
        line = line.strip()
        if len(line) == 80 and not line.startswith("$"):
            decoded = decode_apple_screen_row(line)
            if "System OK" in decoded or "SYSTEM OK" in decoded:
                found_ok = True
                print(f"Screen Output: [{decoded.strip()}]")

    if found_ok:
        print("\n[+] SUCCESS: Apple //e Enhanced Self-Test PASSED (System OK)!")
        print(
            "    Main RAM, Aux RAM, MMU, IOU, and ROM checksums are all fully healthy."
        )
        return True
    else:
        print("\n[?] Notice: Screen dump did not contain 'System OK'.")
        print("    Full screen output:")
        for line in w_resp.splitlines():
            if len(line) == 80 and not line.startswith("$"):
                decoded = decode_apple_screen_row(line).strip()
                if decoded:
                    print(f"    {decoded}")
        return False


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Run Apple //e Enhanced Diagnostic Stress Test"
    )
    parser.add_argument(
        "--port", default="COM47", help="Serial port (default: COM47)"
    )
    parser.add_argument(
        "--time",
        type=int,
        default=45,
        help="Soak duration in seconds (default: 45)",
    )
    parser.add_argument(
        "--continuous", action="store_true", help="Run indefinitely until Ctrl+C"
    )
    args = parser.parse_args()

    run_stress_test(
        port=args.port, duration_sec=args.time, continuous=args.continuous
    )
