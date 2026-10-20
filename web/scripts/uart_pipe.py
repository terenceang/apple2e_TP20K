import sys
import serial
import threading
import base64

port_name = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyUSB1'
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200

try:
    ser = serial.Serial(port_name, baud, timeout=0.1)
except Exception as e:
    sys.stderr.write(f"Failed to open {port_name}: {e}\n")
    sys.stderr.flush()
    sys.exit(1)

sys.stderr.write(f"Opened {port_name} at {baud}\n")
sys.stderr.flush()

def read_serial():
    while True:
        try:
            data = ser.read(1024)
            if data:
                b64 = base64.b64encode(data).decode('ascii')
                sys.stdout.write(f"RX:{b64}\n")
                sys.stdout.flush()
        except Exception:
            break

t = threading.Thread(target=read_serial, daemon=True)
t.start()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line.startswith("TX:"):
        payload = base64.b64decode(line[3:])
        ser.write(payload)
    elif line == "QUIT":
        break

ser.close()
