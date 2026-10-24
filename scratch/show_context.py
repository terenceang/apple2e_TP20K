with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

def show(offset, length=1000):
    chunk = data[offset - 500 : offset + length]
    clean = ''.join(chr(b) if 32 <= b < 127 else '\n' if b == 0x0D else '.' for b in chunk)
    for line in clean.split('\n'):
        if line.strip('.'):
            print(line)

print("=== Offset 0x0FCD08F ===")
show(0x0FCD08F, 500)

print("\n=== Offset 0x1794009 ===")
show(0x1794009, 500)
