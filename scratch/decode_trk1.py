import struct

w = open(r'e:\OneDrive\Desktop\fastloader.woz', 'rb').read()
at = 256 + 6656 # Track 1
track_bytes = w[at:at+6370]

nibbles = []
sr = 0
for b in track_bytes:
    for bit_i in range(7, -1, -1):
        bit = (b >> bit_i) & 1
        sr = ((sr << 1) | bit) & 0xFF
        if sr & 0x80:
            nibbles.append(sr)
            sr = 0

print(f'Track 1 total nibbles: {len(nibbles)}')

# In track 1:
# Let's see how address mark is structured.
# Earlier we found:
# nibble_offset=8: 0xd5 0xaa 0x96 followed by 0xaa 0xaa ...
# Let's inspect the bytes after 0xd5 0xaa 0x96
for i in range(len(nibbles)-10):
    if nibbles[i] == 0xd5 and nibbles[i+1] == 0xaa and nibbles[i+2] == 0x96:
        print(f'Addr mark at {i}:', [hex(x) for x in nibbles[i:i+8]])
        # Find next D5 AA AD
        for j in range(i+3, min(i+40, len(nibbles)-3)):
            if nibbles[j] == 0xd5 and nibbles[j+1] == 0xaa and nibbles[j+2] == 0xad:
                print(f'  Data mark at {j}:', [hex(x) for x in nibbles[j:j+10]])
                break
        if i > 500: break
