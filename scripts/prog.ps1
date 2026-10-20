# ============================================================================
#  scripts/prog.ps1 -- load the bitstream into the Tang Primer 20K with the
#  Gowin programmer (over the Dock's BL702 USB-JTAG).
#
#    scripts\prog.ps1           SRAM load (fast, lost on power cycle)
#    scripts\prog.ps1 -Flash    write the external config flash (persistent)
#
#  Run 36 is "exFlash Erase,Program thru GAO-Bridge", the mode Sipeed documents
#  for this board (see .claude/skills/tp20k-program).  programmer_cli loads its
#  DLLs from its own directory and its embedded Python dies on an inherited
#  PYTHON* variable ("unknown encoding"), so it is run from there with those
#  cleared.  Keep DIP SW1 ON: it is RECONFIG_N.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Flash
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain.ps1')

$name = Get-FpgaName
$fs   = (Resolve-Path (Join-Path $root "build/bitstream/$name.fs")).Path

$pdir = 'C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin'
if (-not (Test-Path "$pdir\programmer_cli.exe")) { throw "Gowin programmer_cli.exe not found in $pdir" }

Get-ChildItem Env: | Where-Object Name -Match '^PYTHON' | ForEach-Object { Remove-Item "Env:$($_.Name)" }

$run = if ($Flash) { 36 } else { 2 }
Write-Host "programmer_cli ($(if ($Flash) { 'exFlash' } else { 'SRAM' })): $fs"
Push-Location $pdir
try {
    & .\programmer_cli.exe -d GW2A-18C --run $run --fsFile $fs 2>&1 |
        ForEach-Object { $_ -split "`r" } | Where-Object { $_ -notmatch '^\s*Programing' -and $_.Trim() }
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($code -ne 0) { throw "programmer_cli exited with code $code" }
