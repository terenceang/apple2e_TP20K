"""Self-check for sdvol.py on a card image file: python scripts/test_sdvol.py"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SLOT = 65536 * 512


def run(*args):
    return subprocess.run([sys.executable, os.path.join(HERE, "sdvol.py"), *args, "--yes"],
                          capture_output=True, text=True, check=True).stdout


def volume(name, blocks, fill):
    img = bytearray(bytes([fill]) * blocks * 512)
    hdr = 2 * 512
    img[hdr + 4] = 0xF0 | len(name)
    img[hdr + 5:hdr + 5 + len(name)] = name.encode()
    struct.pack_into("<H", img, hdr + 0x29, blocks)
    return bytes(img)


with tempfile.TemporaryDirectory() as d:
    card = os.path.join(d, "card.img")
    with open(card, "wb") as f:
        f.truncate(2048 * 512 + 2 * SLOT)          # two slots
    a, b = os.path.join(d, "a.hdv"), os.path.join(d, "b.2mg")
    open(a, "wb").write(volume("ALPHA", 1600, 0x11))
    vb = volume("BETA", 280, 0x22)
    open(b, "wb").write(b"2IMG" + bytes(8) + struct.pack("<I", 1) + bytes(8)
                        + struct.pack("<II", 64, len(vb)) + bytes(32) + vb)

    run(card, "init")
    run(card, "write", "0", a)
    run(card, "write", "1", b)
    run(card, "mount", "1", "0")
    run(card, "mount", "2", "1")
    out = run(card, "list")
    assert "drive 1: slot 0" in out and "drive 2: slot 1" in out, out
    assert "/ALPHA  1600 blocks" in out and "/BETA  280 blocks" in out, out
    raw = open(card, "rb").read()
    assert raw[:8] == b"A2HD" + struct.pack("<HH", 0, 1)
    assert raw[2048 * 512 + SLOT:2048 * 512 + SLOT + len(vb)] == vb      # slot 1, 2IMG header gone

    run(card, "mount", "1", "1")                    # slot 1 leaves drive 2
    assert open(card, "rb").read(8) == b"A2HD" + struct.pack("<HH", 1, 0xFFFF)

    back = os.path.join(d, "back.hdv")
    run(card, "read", "0", back)
    assert open(back, "rb").read() == open(a, "rb").read()
print("test_sdvol: PASS")
