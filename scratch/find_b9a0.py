with open('Disk/ComputerInspector (MECC 1.0).dsk', 'rb') as f:
    d = f.read()

# We know sector 0 relocates sectors of track 0 to $B7A4..$BFFF
# Earlier we saw $0912 did:
# $0F00..$1759 -> $B7A4
# Let's verify what page in track 0 corresponds to $B9A0:
# $B9A0 - $B7A4 = 0x1FC
# 0x0F00 + 0x1FC = 0x10FC
# And where is 0x10FC in the dsk image?
# Sector 0 loaded pages:
# page $09 <- physical sector 0x0D (logical sec 1)
# page $0A <- physical sector 0x0B (logical sec 2)
# page $0B <- physical sector 0x09 (logical sec 3)
# page $0C <- physical sector 0x07 (logical sec 4)
# page $0D <- physical sector 0x05 (logical sec 5)
# page $0E <- physical sector 0x03 (logical sec 6)
# page $0F <- physical sector 0x01 (logical sec 7)
# page $10 <- physical sector 0x0E (logical sec 8)
# page $11 <- physical sector 0x0C (logical sec 9)
# page $12 <- physical sector 0x0A (logical sec 10)
# page $13 <- physical sector 0x08 (logical sec 11)
# page $14 <- physical sector 0x06 (logical sec 12)
# page $15 <- physical sector 0x04 (logical sec 13)
# page $16 <- physical sector 0x02 (logical sec 14)
# page $17 <- physical sector 0x0F (logical sec 15)

# Page $10 is at logical sector 8 (offset 8 * 256 = 0x800 in dsk)
# offset 0xFC in page $10 is 0x800 + 0xFC = 0x8FC!
print("Bytes at 0x8FC (around $B9A0):", d[0x8F0:0x8F0+32].hex())
