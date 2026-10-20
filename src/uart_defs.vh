// ============================================================================
//  uart_defs.vh -- the one definition of the UART timing both ends agree on.
//
//  input_controller.v (RX) and serial_debugger.v (TX) must run at the same
//  bit rate or the debugger and the keyboard talk past each other, so the
//  divisor lives here and nowhere else.
//
//  Included by repo-relative path (like src/hdmi/hdmi_defs.vh): run tools
//  from the repo root. The web side's rate is web/src/serial-link.js BAUD.
// ============================================================================

// 27 MHz / 115200 baud = 234.375, truncated to 234 (0.16% fast, fine for 8N1)
`define UART_CLKS_PER_BIT 9'd234
`define UART_CLKS_HALF_BIT 9'd117
