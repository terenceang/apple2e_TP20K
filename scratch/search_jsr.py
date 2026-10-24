import re
with open('scratch/main.a') as f:
    lines = f.readlines()

for i, l in enumerate(lines):
    m = re.search(r'JSR\s+\$([C-Fc-f][0-9A-Fa-f]{3})', l)
    if m:
        print(f'{i}: {l.strip()}')
