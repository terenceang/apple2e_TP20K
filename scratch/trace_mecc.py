with open('Disk/ComputerInspector (MECC 1.0).dsk', 'rb') as f:
    d = f.read()

trk0_mem = bytearray(0x1800)
for s in range(16):
    trk0_mem[s*256 : (s+1)*256] = d[s*256 : (s+1)*256]

print("0x09F9:", trk0_mem[0x09F9:0x09F9+20].hex())
print("0x08B5:", trk0_mem[0x08B5:0x08B5+30].hex())
print("0x0912:", trk0_mem[0x0912:0x0912+30].hex())
print("0x09AE:", trk0_mem[0x09AE:0x09AE+30].hex())
print("0x09DD:", trk0_mem[0x09DD:0x09DD+40].hex())
