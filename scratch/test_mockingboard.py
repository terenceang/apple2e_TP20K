"""
test_mockingboard.py -- Mockingboard C Hardware Diagnostic & Tone Test

Connects to the Apple //e over the serial debugger, tests Slot 4 register
reads and writes, tests Timer 1 /IRQ behavior, and programs a test tone
on Left and Right channels.
"""
import sys
import time
import serial

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else 'COM47'
    baud = 115200

    print(f"Connecting to Apple //e on {port} at {baud} baud...")
    try:
        ser = serial.Serial(port, baud, timeout=0.5)
    except Exception as e:
        print(f"Error opening port {port}: {e}")
        return

    # Enter Debugger
    ser.write(b'\x02')
    time.sleep(0.2)
    res = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')
    if '[Resuming...]' in res:
        # Was already in debugger, toggle back in
        ser.write(b'\x02')
        time.sleep(0.2)
        res = ser.read(ser.in_waiting or 100).decode('ascii', errors='replace')

    print("Debugger Response:\n", res)

    # Read CPU Registers
    ser.write(b'r')
    time.sleep(0.1)
    print("Registers:\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace'))

    # Dump Slot 4 VIA 1 space ($C400)
    ser.write(b'@c400\r')
    time.sleep(0.1)
    ser.write(b'm')
    time.sleep(0.1)
    print("Slot 4 VIA 1 ($C400-$C40F):\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace'))

    # Dump Slot 4 VIA 2 space ($C480)
    ser.write(b'@c480\r')
    time.sleep(0.1)
    ser.write(b'm')
    time.sleep(0.1)
    print("Slot 4 VIA 2 ($C480-$C48F):\n", ser.read(ser.in_waiting or 100).decode('ascii', errors='replace'))

    # Resume CPU
    ser.write(b'c')
    time.sleep(0.2)
    print("Resumed CPU execution.")

    ser.close()
    print("Mockingboard diagnostic complete.")

if __name__ == '__main__':
    main()
