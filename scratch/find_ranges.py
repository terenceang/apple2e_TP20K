# Disassemble and find all $C0xx softswitch accesses in the unpacked binary

mem = open('scratch/unpacked.bin', 'rb').read()

# Let's inspect where non-zero data exists
ranges = []
in_range = False
start = 0
for i in range(len(mem)):
    if mem[i] != 0:
        if not in_range:
            in_range = True
            start = i
    else:
        if in_range:
            in_range = False
            ranges.append((start, i - 1))
if in_range:
    ranges.append((start, len(mem) - 1))

print("Non-zero memory ranges:")
for s, e in ranges:
    print(f"  ${s:04X} - ${e:04X} ({e - s + 1} bytes)")
