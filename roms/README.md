# ROM images

The Apple //e ROMs are Apple copyright and are not distributed with this
repository. Supply your own dumps here before building:

| File               | Size   | Contents                                          |
|--------------------|--------|---------------------------------------------------|
| `apple2e_rom.hex`  | 16 KB  | System ROM mapped at $C000–$FFFF (16384 lines)     |
| `apple2e_char.hex` | 4 KB   | Character generator ROM (4096 lines)              |
| `disk2_p6.hex`     | 256 B  | Disk II 16-sector boot PROM 341-0027 (256 lines)  |
| `ssc.hex`          | 2 KB   | Super Serial Card firmware 341-0065-A (2048 lines) |

All files are loaded with Verilog `$readmemh`: one byte per line, two hex
digits, no address markers. To convert a raw binary dump:

```sh
xxd -p -c1 apple2e_rom.bin  > apple2e_rom.hex
xxd -p -c1 apple2e_char.bin > apple2e_char.hex
xxd -p -c1 disk2_p6.bin     > disk2_p6.hex
xxd -p -c1 ssc.bin          > ssc.hex
```

`apple2e_char.hex` must be **4096 lines** — the Apple //e Enhanced character
generator is a 4 KB 2732 (`342-0265-A`), and `video_generator`'s
`char_rom_addr` is 12 bits, so a larger file's upper half is unreachable and
`apple2_char_rom`'s `mem` array is declared `[0:4095]`. Do not use the 8 KB
2764 video ROM (`342-0273-A`) for this: it is the UK-US character set, and it
costs two dead block RAMs on a device that is otherwise at 95% BSRAM use.

`disk2_p6.hex` must be **256 lines** (256 bytes) corresponding to the standard
Disk II 16-sector P6 boot PROM (Apple part number 341-0027, mapped at $C600-$C6FF).
If absent, the build defines `DSK2_NO_P6_ROM` and fills with zeros.


`ssc.hex` must be **2048 lines**: the Super Serial Card's 2 KB firmware ROM
(341-0065-A).  The card shows its last page ($700-$7FF) at $C100-$C1FF and the
whole ROM at $C800-$CFFF.  If absent, the build defines `SSC_NO_ROM`: the
slot reads zeros (no `PR#1`/`IN#1`, and comm programs that look for the
card's ID bytes will not find it), but the 6551 at $C098-$C09B still works for
software that drives it directly.  It costs one block RAM when present.
