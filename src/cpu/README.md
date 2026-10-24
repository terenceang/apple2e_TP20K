# src/cpu/

A vendored 65C02 core, not written for this project.

- **The 6502 core** is Arlet Ottens' Verilog 6502
  ([Arlet/verilog-6502](https://github.com/Arlet/verilog-6502)),
  (C) Arlet Ottens.
- **The 65C02 instructions and addressing modes** are by David Banks and
  Ed Spittles, (C) 2016, maintained in David Banks' fork
  ([hoglet67/verilog-6502](https://github.com/hoglet67/verilog-6502)).

Both carry the same terms, kept in the headers of `cpu_65c02.v` and `ALU.v`:
any use, commercial or not, as long as the message and the copyright notice
are kept. Keep those headers intact.

**Local change:** `cpu_65c02.v` exposes the `debug_*` register ports (PC, A,
X, Y, S, P, IR) that `serial_debugger.v` prints. Which upstream commit it was
taken from was not recorded, so diff against the fork before assuming
anything else matches it.
