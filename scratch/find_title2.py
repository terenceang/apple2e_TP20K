with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re

# Look in 0x1790000 to 0x1795000 for strings
chunk = data[0x1790000:0x1795000]
strings = re.findall(rb'[A-Za-z0-9\.\-\_\!\?\'\,\: ]{4,}', chunk)
print("Strings near 0x1794009:")
for s in strings[:30]:
    print(" ", s.decode('ascii', errors='ignore'))
