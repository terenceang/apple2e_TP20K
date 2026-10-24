code = open('scratch/oldskool.dsk', 'rb').read()
# extract oldskool binary
ts_list = code[(2*16 + 1)*256 : (2*16 + 2)*256]
raw = bytearray()
for i in range(128):
    t, s = ts_list[12+i*2], ts_list[12+i*2+1]
    if t == 0 and s == 0: break
    raw += code[(t*16+s)*256 : (t*16+s+1)*256]

# Address $1000
raw = raw[4:]

# Let's inspect $1050-$1090
# 1058: 8D 00 40 -> STA $4000 (modified by self modifying code?)
# 105B: ee 5b 10 -> INC $105B
# 105E: d0 03    -> BNE
# 1060: ee 5c 10 -> INC $105C
# 1063: c6 fc    -> DEC $FC
# 1065: d0 02    -> BNE
# 1067: c6 fd    -> DEC $FD
# 1069: 60       -> RTS
# It unpacks to $4000! $4000 upwards!
# And $1082:
# 1082: AD 8E 10 -> LDA $108E
# 1085: EE 83 10 -> INC $1083
# 1088: D0 03    -> BNE
# 108A: EE 84 10 -> INC $1084
# 108D: 60       -> RTS
# It reads packed bytes from $108E!
print("Unpacker found. Unpacks to $4000+ then jumps to $7FD4!")
