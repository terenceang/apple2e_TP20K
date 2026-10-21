import serial
import time
import sys

def send_key(ser, ch, hold_time=0.15):
    # Send character over UART to Apple //e keyboard
    ser.write(ch.encode('ascii'))
    time.sleep(hold_time)

def get_runner_coords(ser):
    # Enter debugger to read $00-$03
    ser.write(b'\x02')
    time.sleep(0.08)
    res = ser.read(ser.in_waiting or 1)
    if b'[Resuming...]' in res:
        ser.write(b'\x02')
        time.sleep(0.08)
        ser.read(ser.in_waiting or 1)
    
    ser.write(b'@0000\r')
    time.sleep(0.03)
    ser.write(b'm')
    time.sleep(0.03)
    resp = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    
    # Resume CPU
    ser.write(b'c')
    time.sleep(0.05)
    ser.read(ser.in_waiting or 1)
    
    coords = None
    for line in resp.splitlines():
        if '$0000:' in line:
            tokens = line.split('$0000:')[1].split('|')[0].strip().split()
            coords = tokens[:8]
            break
    return coords

def main():
    port = 'COM47'
    baud = 115200
    ser = serial.Serial(port, baud, timeout=0.5)
    time.sleep(0.1)

    print("Checking initial runner position in zero page...")
    c0 = get_runner_coords(ser)
    print("Initial coordinates ($00..$07):", c0)

    print("\n>>> Moving character RIGHT (sending 'K' 12 times)...")
    for i in range(12):
        send_key(ser, 'K', hold_time=0.12)
        print(".", end="", flush=True)
    print(" Done!")

    time.sleep(0.3)
    c1 = get_runner_coords(ser)
    print("Position after moving RIGHT ($00..$07):", c1)

    print("\nWaiting 1 second...")
    time.sleep(1.0)

    print("\n>>> Moving character LEFT (sending 'J' 12 times)...")
    for i in range(12):
        send_key(ser, 'J', hold_time=0.12)
        print(".", end="", flush=True)
    print(" Done!")

    time.sleep(0.3)
    c2 = get_runner_coords(ser)
    print("Position after moving LEFT ($00..$07):", c2)

    print("\n>>> Digging a hole to the RIGHT ('O')...")
    send_key(ser, 'O', hold_time=0.5)

    print("\n>>> Digging a hole to the LEFT ('U')...")
    send_key(ser, 'U', hold_time=0.5)

    ser.close()
    print("\nMovement commands completed successfully!")

if __name__ == '__main__':
    main()
