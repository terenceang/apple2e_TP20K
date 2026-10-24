with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

def find_surrounding_strings(offset):
    chunk = data[max(0, offset - 4096) : min(len(data), offset + 4096)]
    import re
    # Look for filenames like GAME.SYSTEM or similar ProDOS directory entries
    return re.findall(b'/[A-Z0-9\\._\\-]+', chunk)

print("Near 0x0FCD08F:", set(find_surrounding_strings(0x0FCD08F)))
print("Near 0x1794009:", set(find_surrounding_strings(0x1794009)))
