with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re

# Look for strings near "Appletini" or "Mockingboard in slot"
pos = data.find(b"Mockingboard in slot")
if pos != -1:
    print(data[pos-50:pos+150])

# Look for category names or help screens in Total Replay
for m in re.finditer(rb'CATEGOR|FILTER|Mockingboard|MOCKINGBOARD', data):
    print(hex(m.start()), data[m.start():m.start()+40])
