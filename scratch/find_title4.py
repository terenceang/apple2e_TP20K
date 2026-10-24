with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re
chunk = data[0x0FC8000:0x0FD2000]
strings = re.findall(rb'[A-Za-z0-9\.\-\_\!\?\'\,\: ]{4,}', chunk)
for s in strings:
    txt = s.decode('ascii', errors='ignore').strip()
    if len(txt) > 4:
        print(" ", txt)
