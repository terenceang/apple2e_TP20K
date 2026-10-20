// Timing constraints for the Apple //e on Tang Primer 20K (Gowin EDA).
//
// Two unrelated clock trees off the 27 MHz oscillator:
//   u_clk_gen rPLL -> clk_tmds 135 MHz -> CLKDIV /5 -> clk_pixel 27 MHz (everything Apple)
//   u_ddr_pll rPLL -> ddr_memory_clk 398.25 MHz -> Gowin DDR3 IP -> its clk_out 99.56 MHz (u_aux/mclk)
// aux_ram crosses between clk_pixel and mclk with a toggle handshake whose
// data is held steady for two receiving clocks, so the groups are
// asynchronous.
create_clock -name clk -period 37.037 [get_ports {clk}]
create_generated_clock -name clk_tmds  -source [get_ports {clk}] -multiply_by 5 [get_pins {u_clk_gen/pll_inst/CLKOUT}]
create_generated_clock -name clk_pixel -source [get_pins {u_clk_gen/pll_inst/CLKOUT}] -master_clock clk_tmds -divide_by 5 [get_pins {u_clk_gen/clkdiv_pixel/CLKOUT}]
create_clock -name ddr_memory_clk -period 2.511 [get_nets {ddr_memory_clk}]
create_clock -name mclk -period 10.042 [get_nets {u_aux/mclk}]
set_clock_groups -asynchronous -group [get_clocks {clk clk_tmds clk_pixel}] -group [get_clocks {ddr_memory_clk}] -group [get_clocks {mclk}]
