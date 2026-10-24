// ============================================================================
//  uart_defs.vh -- the one definition of the UART timing both ends agree on.
//
//  input_controller.v (RX) and serial_debugger.v (TX) must run at the same
//  bit rate or the debugger and the keyboard talk past each other, so the
//  divisor lives here and nowhere else.  The clock is VM_PIXEL_HZ, the one
//  clock everything Apple-side runs on.
//
//  Included by repo-relative path (like src/hdmi/hdmi_defs.vh): run tools
//  from the repo root. The web side's rate is web/src/serial-link.js BAUD.
// ============================================================================
`ifndef UART_DEFS_VH
`define UART_DEFS_VH
`include "src/hdmi/hdmi_defs.vh"

// 27 MHz / 1000000 baud = 27 (exact, 0% error for 8N1)
`define UART_BAUD          1000000
`define UART_CLKS_PER_BIT  (`VM_PIXEL_HZ / `UART_BAUD)
`define UART_CLKS_HALF_BIT (`UART_CLKS_PER_BIT / 2)

`endif
