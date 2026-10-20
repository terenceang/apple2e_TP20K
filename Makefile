# ============================================================================
#  Thin wrapper around scripts/build.ps1 and scripts/prog.ps1.
#
#  There is deliberately no build logic here.  The RTL file list lives in
#  fpga.yaml and is read by scripts/sources.ps1.  Timing target and mode
#  constants live in src/hdmi/hdmi_defs.vh.
#
#  Everything is re-run from scratch on each invocation, so the individual
#  stages are how you iterate:
#    make synth   (scripts/build.ps1 -Synth)
#    make pnr     (scripts/build.ps1 -Pnr)
#    make pack    (scripts/build.ps1 -Pack)
#
#  Scripts require a native Windows OSS CAD Suite install.  Point
#  $env:OSS_CAD_SUITE at the suite root, or let VS Code's
#  "openfpga.toolchain.path" setting be discovered automatically.
# ============================================================================

# The recipes below are written for cmd.exe -- `if exist` and `rmdir /s /q` in
# clean are its syntax -- and GNU make silently switches to POSIX sh if an
# sh.exe is on PATH, which Git Bash or MSYS2 would add.  Pin it, so what a
# recipe means cannot change because a shell got installed.
SHELL := cmd.exe

PWSH  = C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass
BUILD = scripts/build.ps1
PROG  = scripts/prog.ps1

all: pack

synth:
	$(PWSH) -File $(BUILD) -Synth

pnr:
	$(PWSH) -File $(BUILD) -Pnr

pack:
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

.PHONY: all synth pnr pack flash flash-sram clean \
        web-install web-build web-dev web-test web-charset
