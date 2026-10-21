with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re

mb_files = set(re.findall(rb'[A-Z0-9\.\_]{3,15}\.MB\b', data))
print("Found .MB files in Total Replay:")
for f in sorted(mb_files):
    print(" -", f.decode('ascii'))
