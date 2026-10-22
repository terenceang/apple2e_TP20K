# src/z80/

A vendored Z80 core for the Z-80 SoftCard (`src/softcard.v`), not written for
this project.

- **TV80** by Guy Hutchison ([hutch31/tv80](https://github.com/hutch31/tv80),
  `rtl/core/`), a Verilog translation of Daniel Wallner's VHDL T80. MIT
  licence (`LICENSE`, and the header of each file); keep the headers intact.

Unmodified. `tv80s.v`, upstream's wrapper, is left out: it has no clock enable,
and `softcard.v` drives `tv80_core` directly with one (`cen`), taking the bus
cycle from its `mc`/`ts` outputs.
