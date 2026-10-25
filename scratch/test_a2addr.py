def a2_text_addr(row, col, page=1):
    base = 0x0800 if page == 2 else 0x0400
    group = row // 8
    r_in_g = row % 8
    group_offset = 0 if group == 0 else (40 if group == 1 else 80)
    return base + r_in_g * 128 + group_offset + col

for r in [0, 1, 2, 8, 9, 16, 23]:
    print('Row %2d, col 0: 0x%04X' % (r, a2_text_addr(r, 0)))
