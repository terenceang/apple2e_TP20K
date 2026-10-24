# ============================================================================
#  Thin wrapper around scripts/build.ps1 and scripts/prog.ps1.
#
#  There is deliberately no build logic here.  The RTL file list lives in
#  fpga.yaml and is read by scripts/sources.ps1; scripts/build.ps1 turns it
#  into a Gowin EDA (gw_sh) run.  gw_sh has no stage switches worth having, so
#  there is one build target.  Nothing here is needed: the scripts run as they
#  are, and make is only shorthand for them.
# ============================================================================

# The recipes below are written for cmd.exe -- `if exist` and `rmdir /s /q` in
# clean are its syntax -- and GNU make silently switches to POSIX sh if an
# sh.exe is on PATH, which Git Bash or MSYS2 would add.  Pin it, so what a
# recipe means cannot change because a shell got installed.
SHELL := cmd.exe

PWSH  = C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass
BUILD = scripts/build.ps1
PROG  = scripts/prog.ps1

all: build

# Synthesis, place & route and the bitstream: build/bitstream/<name>.fs
build:
	$(PWSH) -File $(BUILD)

# Load into SRAM: fast, lost on power cycle.  This is the iteration path.
flash-sram:
	$(PWSH) -File $(PROG)

# Write the configuration flash: persistent across power cycles.
flash:
	$(PWSH) -File $(PROG) -Flash

clean:
	if exist build rmdir /s /q build

# ============================================================================
#  Web front end
#
#  `web/` is a Node project, separate from the FPGA build: `make web-build`
#  produces the static bundle the app is served from (it opens the board's
#  serial port itself over Web Serial; there is no bridge process), and
#  `make web-test` runs the JS tests. The React app, the keymap and the
#  screen renderer are in web/README.md.
# ============================================================================

web-install:
	cd web && npm install

web-build:
	cd web && npm run build

web-dev:
	cd web && npm run dev

web-test:
	cd web && npm test

web-charset:
	cd web && npm run charset

.PHONY: all build flash flash-sram clean \
        web-install web-build web-dev web-test web-charset
