import struct

with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

# ProDOS 512-byte blocks
target_block1 = 0x0FCD08F // 512
target_block2 = 0x1794009 // 512

print(f"Target block 1: {target_block1} (0x{target_block1:04X})")
print(f"Target block 2: {target_block2} (0x{target_block2:04X})")

# Let's search the disk for pointers to these blocks
# In ProDOS, index blocks and directory entries reference block numbers as 16-bit little-endian
b1_bytes = struct.pack('<H', target_block1)
b2_bytes = struct.pack('<H', target_block2)

for b in range(len(data) // 512):
    block = data[b*512 : (b+1)*512]
    if b1_bytes in block:
        print(f"Block {b} contains pointer to target block 1")
    if b2_bytes in block:
        print(f"Block {b} contains pointer to target block 2")
