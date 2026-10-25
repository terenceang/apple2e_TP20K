with open('scratch/sec_0.bin', 'rb') as f:
    sec0 = f.read()
print('sec0[0:32]:', [hex(x) for x in sec0[:32]])
