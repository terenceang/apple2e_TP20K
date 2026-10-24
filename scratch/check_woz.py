import struct

with open(r'e:\OneDrive\Desktop\oldskool.woz', 'rb') as f:
    data = f.read()

print("File size:", len(data))
print("Header:", data[:8])
print("CRC:", hex(struct.unpack('<I', data[8:12])[0]))

pos = 12
while pos < len(data):
    if pos + 8 > len(data):
        print(f"Remaining trailing bytes ({len(data) - pos}) at {pos}")
        break
    cid = data[pos:pos+4].decode('latin1', errors='replace')
    csize = struct.unpack('<I', data[pos+4:pos+8])[0]
    print(f"Chunk '{cid}' at {pos} (0x{pos:X}), size = {csize} (0x{csize:X}), data ends at {pos+8+csize}")
    if cid == 'INFO':
        info = data[pos+8:pos+8+csize]
        print(f"  INFO version: {info[0]}, disk_type: {info[1]}, write_protected: {info[2]}, synchronized: {info[3]}, cleaned: {info[4]}")
        print(f"  creator: {info[5:37].decode('latin1', errors='replace').rstrip(chr(0))}")
        if len(info) >= 60:
            print(f"  disk_sides: {info[37]}, boot_sector_format: {info[38]}, optimal_bit_timing: {info[39]}")
            compat = struct.unpack('<H', info[40:42])[0]
            ram = struct.unpack('<H', info[42:44])[0]
            max_tracks = struct.unpack('<H', info[44:46])[0]
            print(f"  compat: {compat}, ram: {ram}, max_tracks: {max_tracks}")
            if len(info) >= 48:
                flux_block = struct.unpack('<H', info[46:48])[0]
                largest_track = struct.unpack('<H', info[48:50])[0]
                print(f"  flux_block: {flux_block}, largest_track: {largest_track}")
    elif cid == 'TMAP':
        tmap = data[pos+8:pos+8+csize]
        print(f"  TMAP length: {len(tmap)}")
        tracks = list(tmap)
        non_empty = [(idx, trk) for idx, trk in enumerate(tracks) if trk != 0xFF]
        print(f"  Non-empty tracks count: {len(non_empty)}")
        print(f"  First few entries: {tracks[:20]}")
    elif cid == 'TRKS':
        print(f"  TRKS data starts at {pos+8}")
        # In WOZ2, TRKS contains 160 entries of 8 bytes
        # starting block (u16), block count (u16), bit count (u32)
        for i in range(160):
            entry_offset = pos + 8 + i * 8
            if entry_offset + 8 <= len(data):
                sblk, bcnt, nbits = struct.unpack('<HHI', data[entry_offset:entry_offset+8])
                if bcnt > 0 or nbits > 0 or sblk > 0:
                    print(f"    Track entry {i}: start_blk={sblk} (byte {sblk*512}), num_blks={bcnt}, bit_count={nbits}")
                    if i >= 5 and i < 155:
                        pass # don't spam all of them
    pos += 8 + csize
