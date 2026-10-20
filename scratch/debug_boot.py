import serial
import time

def send_cmd(ser, cmd, delay=0.1):
    ser.write(cmd.encode('ascii'))
    time.sleep(delay)
    resp = b''
    while ser.in_waiting:
        resp += ser.read(ser.in_waiting)
        time.sleep(0.05)
    return resp.decode('ascii', errors='replace')

def main():
    ser = serial.Serial('COM47', 115200, timeout=1.0)
    time.sleep(0.1)
    ser.reset_input_buffer()

    print("Checking debugger status...")
    # Send Ctrl+B to ensure we are at prompt if halted or running
    ser.write(b'\x02')
    time.sleep(0.1)
    res = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    print("Initial prompt:", res)

    print("\nSending 'x' to reset CPU...")
    print(send_cmd(ser, 'x', 0.2))

    print("\nSending 'c' to run...")
    ser.write(b'c')
    
    # Wait for breakpoint hit banner: "BP HIT at PC=xxxx"
    t0 = time.time()
    hit_resp = b''
    while time.time() - t0 < 3.0:
        if ser.in_waiting:
            hit_resp += ser.read(ser.in_waiting)
            if b'BP HIT' in hit_resp or b'>' in hit_resp:
                break
        time.sleep(0.05)

    print("Hit response:", hit_resp.decode('ascii', errors='replace'))

    print("\nReading registers ('r'):")
    print(send_cmd(ser, 'r', 0.1))

    print("\nReading PC trace buffer ('p'):")
    print(send_cmd(ser, 'p', 0.1))

    print("\nDumping zero-page @0020 (16 bytes):")
    print(send_cmd(ser, '@0020', 0.1))
    print("\nDumping zero-page @0030 (16 bytes):")
    print(send_cmd(ser, '@0030', 0.1))
    print("\nDumping zero-page @0040 (16 bytes):")
    print(send_cmd(ser, '@0040', 0.1))

    print("\nDumping Sector 0 header / tail:")
    print("Sector 0 start @0800:")
    print(send_cmd(ser, '@0800', 0.1))
    print("Sector 0 end @08F0:")
    print(send_cmd(ser, '@08f0', 0.1))

    ser.close()

if __name__ == '__main__':
    main()
