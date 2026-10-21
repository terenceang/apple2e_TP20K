#!/usr/bin/env python3
"""sdvol.py -- put ProDOS hard-disk volumes on a TF card for the slot 7 hard disk.

The card is used raw, in the layout src/sd_vol.v reads (no file system):

    sector 0                  config: "A2HD", drive 1 slot, drive 2 slot (16-bit LE, FFFF = empty)
    sector 2048 + N * 65536   slot N: one 32 MB ProDOS volume, block b at + b

Commands (DISK is \\\\.\\PhysicalDriveN on Windows, run from an admin prompt;
/dev/sdX on Linux, /dev/rdiskN on macOS):

    sdvol.py DISK init                  write an empty config (erases the partition table)
    sdvol.py DISK list                  the config, and the volume in each slot
    sdvol.py DISK write SLOT IMAGE      put an image (.hdv / .po / .2mg) in a slot
    sdvol.py DISK read SLOT OUT.hdv     copy a slot back out (the volume's own size)
    sdvol.py DISK mount DRIVE SLOT|none what drive 1 or 2 loads at power-on

`init` overwrites sector 0, so a card that had a FAT/exFAT partition stops being one;
on Windows unplug and replug it after `init` (the old partition is still mounted
until then, and Windows refuses writes inside a mounted volume).  Say no when
Windows offers to format it.  Writing a slot asks first unless --yes is given.
"""
import os
import struct
import sys

SECTOR = 512
SLOT_BASE = 2048
SLOT_SECTORS = 65536
MAGIC = b"A2HD"


def disk_size(fd, path):
    """Bytes on the device, or None if the platform will not say."""
    if os.name == "nt":
        import ctypes
        import msvcrt
        from ctypes import wintypes
        IOCTL_DISK_GET_LENGTH_INFO = 0x7405C
        size = ctypes.c_longlong(0)
        ret = wintypes.DWORD(0)
        h = msvcrt.get_osfhandle(fd)
        ok = ctypes.windll.kernel32.DeviceIoControl(
            wintypes.HANDLE(h), IOCTL_DISK_GET_LENGTH_INFO, None, 0,
            ctypes.byref(size), ctypes.sizeof(size), ctypes.byref(ret), None)
        if ok:
            return size.value
    try:                                   # a device elsewhere, or an image file

        return os.lseek(fd, 0, os.SEEK_END)
    except OSError:
        return None


class Card:
    def __init__(self, path, write):
        if os.name == "nt" and path.lower().rstrip("\\").endswith("physicaldrive0"):
            sys.exit("refusing PhysicalDrive0: that is almost certainly the system disk")
        flags = (os.O_RDWR if write else os.O_RDONLY) | getattr(os, "O_BINARY", 0)
        self.fd = os.open(path, flags)
        self.size = disk_size(self.fd, path)
        self.slots = None if self.size is None else (self.size // SECTOR - SLOT_BASE) // SLOT_SECTORS

    def read(self, sector, count):
        os.lseek(self.fd, sector * SECTOR, os.SEEK_SET)
        out = bytearray()
        while len(out) < count * SECTOR:
            chunk = os.read(self.fd, min(count * SECTOR - len(out), 1 << 20))
            if not chunk:
                raise IOError(f"short read at sector {sector}")
            out += chunk
        return bytes(out)

    def write(self, sector, data):
        assert len(data) % SECTOR == 0
        os.lseek(self.fd, sector * SECTOR, os.SEEK_SET)
        for i in range(0, len(data), 1 << 20):
            os.write(self.fd, data[i:i + (1 << 20)])

    def config(self):
        c = self.read(0, 1)
        if c[:4] != MAGIC:
            return None
        return list(struct.unpack_from("<HH", c, 4))

    def set_config(self, slots):
        self.write(0, (MAGIC + struct.pack("<HH", *slots)).ljust(SECTOR, b"\0"))

    def check_slot(self, n):
        if not 0 <= n < 0xFFFF or (self.slots is not None and n >= self.slots):
            sys.exit(f"slot {n} is not on this card (it has {self.slots})")


def image_blocks(path):
    data = open(path, "rb").read()
    if data[:4] == b"2IMG":
        fmt, off, length = struct.unpack_from("<I", data, 0x0C)[0], *struct.unpack_from("<II", data, 0x18)
        if fmt != 1:
            sys.exit("2IMG image is not in ProDOS order")
        data = data[off:off + length]
    if not data or len(data) % SECTOR or len(data) > SLOT_SECTORS * SECTOR:
        sys.exit(f"{path}: not a whole number of 512-byte blocks up to 32 MB ({len(data)} bytes)")
    return data


def volume_info(block2):
    """(name, total blocks) from a ProDOS volume directory header, or None."""
    if block2[4] >> 4 != 0xF:
        return None
    n = block2[4] & 0x0F
    return block2[5:5 + n].decode("ascii", "replace"), struct.unpack_from("<H", block2, 0x29)[0]


def confirm(what, yes):
    if yes:
        return
    if input(f"{what} -- type yes to go on: ").strip().lower() != "yes":
        sys.exit("nothing written")


def main(argv):
    yes = "--yes" in argv
    argv = [a for a in argv if a != "--yes"]
    if len(argv) < 3:
        sys.exit(__doc__)
    path, cmd, args = argv[1], argv[2], argv[3:]
    card = Card(path, write=cmd in ("init", "write", "mount"))
    size = "unknown size" if card.size is None else f"{card.size / 1e9:.1f} GB, {card.slots} slots"
    print(f"{path}: {size}")

    if cmd == "init":
        confirm(f"erase the partition table on {path}", yes)
        card.set_config([0xFFFF, 0xFFFF])
        print("done; unplug and replug the card before writing slots")
    elif cmd == "list":
        cfg = card.config()
        if cfg is None:
            print("no config: run init first")
            return
        for d, s in enumerate(cfg):
            print(f"drive {d + 1}: " + ("empty" if s == 0xFFFF else f"slot {s}"))
        for n in range(card.slots or 0):
            info = volume_info(card.read(SLOT_BASE + n * SLOT_SECTORS + 2, 1))
            if info:
                print(f"slot {n:4d}: /{info[0]}  {info[1]} blocks")
    elif cmd == "write" and len(args) == 2:
        n = int(args[0], 0)
        card.check_slot(n)
        if card.config() is None:
            sys.exit("no config on this card: run init first")
        data = image_blocks(args[1])
        info = volume_info(data[1024:1536]) if len(data) >= 1536 else None
        confirm(f"write {args[1]} ({len(data) // SECTOR} blocks{', /' + info[0] if info else ''}) to slot {n}", yes)
        card.write(SLOT_BASE + n * SLOT_SECTORS, data)
        print("done")
    elif cmd == "read" and len(args) == 2:
        n = int(args[0], 0)
        card.check_slot(n)
        base = SLOT_BASE + n * SLOT_SECTORS
        info = volume_info(card.read(base + 2, 1))
        blocks = info[1] if info and info[1] else SLOT_SECTORS
        open(args[1], "wb").write(card.read(base, blocks))
        print(f"{blocks} blocks to {args[1]}")
    elif cmd == "mount" and len(args) == 2:
        d = int(args[0])
        if d not in (1, 2):
            sys.exit("drive is 1 or 2")
        cfg = card.config()
        if cfg is None:
            sys.exit("no config on this card: run init first")
        s = 0xFFFF if args[1] == "none" else int(args[1], 0)
        if s != 0xFFFF:
            card.check_slot(s)
            if cfg[2 - d] == s:
                cfg[2 - d] = 0xFFFF       # one slot is never in both drives (as sd_vol.v)
        cfg[d - 1] = s
        card.set_config(cfg)
        print(f"drive 1: {cfg[0]:#06x}  drive 2: {cfg[1]:#06x}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
