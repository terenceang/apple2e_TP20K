with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re
chunk = data[0x1794000:0x17A0000]
strings = re.findall(rb'[A-Za-z0-9\.\-\_\!\?\'\,\: ]{4,}', chunk)
for s in strings[:40]:
    txt = s.decode('ascii', errors='ignore')
    if len(txt.strip()) > 4:
        print(" ", txt.strip())
