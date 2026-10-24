import serial
import time

def read_until(ser, target, timeout=3.0):
    t0 = time.time()
    buf = b''
    while time.time() - t0 < timeout:
        if ser.in_waiting:
            buf += ser.read(ser.in_waiting)
            if target.encode('ascii') in buf:
                return buf.decode('ascii', errors='replace')
        time.sleep(0.02)
    return buf.decode('ascii', errors='replace')

def enter_debugger(ser):
    ser.reset_input_buffer()
    # Check if already at prompt
    ser.write(b'\r\n')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '>' in res:
        print("Already in debugger mode.")
        return
    # Send Ctrl+B
    print("Sending Ctrl+B...")
    ser.write(b'\x02')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        # We were in debugger, so Ctrl+B resumed it! Send Ctrl+B again to enter.
        print("Was resumed, sending Ctrl+B again...")
        ser.write(b'\x02')
        time.sleep(0.2)
        res = ser.read(ser.in_waiting or 1).decode('ascii', errors='replace')
    print("Debugger banner/prompt:", res)

def main():
    ser = serial.Serial('COM47', 115200, timeout=0.5)
    time.sleep(0.1)

    enter_debugger(ser)

    print("\n--- Resetting CPU ('x') ---")
    ser.write(b'x')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    print("Reset response:\n", res)

    print("\n--- Running CPU ('c') to wait for breakpoint at $0801 / $3793 / $3795 ---")
    ser.write(b'c')
    
    t0 = time.time()
    hit_buf = b''
    # Give it up to 5 seconds for disk spin-up and Sector 0 read
    while time.time() - t0 < 5.0:
        if ser.in_waiting:
            hit_buf += ser.read(ser.in_waiting)
            if b'Debugger' in hit_buf or b'PC=' in hit_buf:
                break
        time.sleep(0.05)

    print(f"Elapsed: {time.time()-t0:.2f}s")
    print("Breakpoint hit output:\n", hit_buf.decode('ascii', errors='replace'))

    # If halted, let's dump registers and PC trace
    time.sleep(0.1)
    ser.write(b'r')
    time.sleep(0.1)
    r_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    print("Registers:\n", r_resp)

    ser.write(b'p')
    time.sleep(0.1)
    p_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    print("PC History:\n", p_resp)

    # Dump zero-page locations
    for addr in ['0020', '0030', '0040', '0800', '08F0']:
        ser.write(f'@{addr}'.encode('ascii'))
        time.sleep(0.05)
        ser.write(b'm')
        time.sleep(0.05)
        m_resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
        print(f"Dump @{addr}:\n", m_resp)

    ser.close()

if __name__ == '__main__':
    main()
