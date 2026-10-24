with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re

# Look for game metadata or help files
for m in re.finditer(rb'MOCKINGBOARD|Mockingboard', data):
    print("Found at", hex(m.start()))

# Let's inspect block 0 to 100 or find directory filenames
entries = set()
for m in re.finditer(rb'[A-Z0-9\.\_]{3,15}\.SYSTEM', data):
    entries.add(m.group(0))

print("System files:", entries)
