# A quick elaboration check: compile the whole design with iverilog and
# elaborate the top, without running anything.  sim/run.ps1 is the real gate
# (it runs every testbench); this is for the quick "does it still parse" loop
# while editing.
param(
    [string]$Top = 'top'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $root 'scripts\toolchain.ps1')

$all = & (Join-Path $root 'scripts\sources.ps1') -Except 'src/ddr3_memory_interface/ddr3_memory_interface.v'
$files = @('sim/models/gowin_prims.v', 'sim/models/ddr3_model.v') + $all

Invoke-Tool 'iverilog' (@('-g2012', '-o', 'build/elab.vvp', '-s', $Top) + $files)
Write-Host "elaborated $Top ok"
