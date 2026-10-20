MOD# Compares src/qr.c with the qrcode package (pip install qrcode): version 3, ECC L, mask 0.
# Run from mcu/ (python test/test_qr.py) after building build/test_qr.exe (see test_qr.c).
import subprocess, qrcode, qrcode.constants as C
for t in ["WIFI:T:WPA;S:Apple-A1B2;P:k7m2x9qd;;", "a", "x" * 53, "WIFI:T:WPA;S:Apple-FFFF;P:23456789;;"]:
    q = qrcode.QRCode(version=3, error_correction=C.ERROR_CORRECT_L, border=0, mask_pattern=0)
    q.add_data(t, optimize=0); q.make(fit=False)
    want = ["".join("1" if c else "0" for c in r) for r in q.get_matrix()]
    got = subprocess.run(["../build/test_qr.exe", t], capture_output=True, text=True).stdout.split()
    assert got == want, t
print("test_qr: PASS")
