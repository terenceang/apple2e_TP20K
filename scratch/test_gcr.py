with open('Disk/DOS 3.3 System Master - 680-0210-A.dsk', 'rb') as f:
    dsk = f.read()

def gcr_pair_swap(v):
    return ((v & 1) << 1) | ((v >> 1) & 1)

def test_sector(sec_num):
    sec = dsk[sec_num*256 : (sec_num+1)*256]

    groups = []
    for k in range(86):
        b0 = sec[172 + k] if (172 + k) < 256 else 0
        b1 = sec[86 + k] if (86 + k) < 256 else 0
        b2 = sec[k]
        grp = (gcr_pair_swap(b0 & 3) << 4) | (gcr_pair_swap(b1 & 3) << 2) | gcr_pair_swap(b2 & 3)
        groups.append(grp)

    for k in range(256):
        groups.append(sec[k] >> 2)

    groups.append(sec[255] >> 2)

    vals = []
    prev = 0
    for i, g in enumerate(groups[:-1]):
        if i == 0:
            val = g
        else:
            val = g ^ prev
        vals.append(val)
        prev = g

    vals.append(groups[-1])

    rom_aux = bytearray(86)
    rom_data = bytearray(256)

    A = 0
    for k in range(86):
        A = A ^ vals[k]
        rom_aux[85 - k] = A

    for k in range(256):
        A = A ^ vals[86 + k]
        rom_data[k] = A

    A = A ^ vals[342]
    assert A == 0, f"Checksum error on sector {sec_num}!"

    unpacked = bytearray(256)
    x = 0x56
    for y in range(256):
        x -= 1
        if x < 0:
            x = 0x55
        b = rom_data[y]
        c = rom_aux[x] & 1
        rom_aux[x] >>= 1
        b = ((b << 1) | c) & 0xFF
        c = rom_aux[x] & 1
        rom_aux[x] >>= 1
        b = ((b << 1) | c) & 0xFF
        unpacked[y] = b

    diffs = [i for i in range(256) if unpacked[i] != sec[i]]
    if diffs:
        print(f"Sector {sec_num}: {len(diffs)} diffs! First at {diffs[0]}")
    return len(diffs) == 0

all_ok = True
for s in range(16):
    ok = test_sector(s)
    if not ok:
        all_ok = False

if all_ok:
    print("ALL 16 SECTORS ENCODE AND DECODE BIT-FOR-BIT PERFECTLY WITH P6 ROM!")
