import serial, time

try:
    s = serial.Serial('COM47', 1000000, timeout=1)
    print("Opened COM47 successfully")
    # Send Ctrl+B
    s.write(b'\x02')
    time.sleep(0.3)
    resp = s.read_all()
    print("After Ctrl+B:", repr(resp))
    # Send 'v'
    s.write(b'v')
    time.sleep(0.3)
    resp2 = s.read_all()
    print("After v:", repr(resp2))
    # Send Ctrl+B to resume
    s.write(b'\x02')
    time.sleep(0.1)
    s.close()
except Exception as e:
    print("Error:", e)
