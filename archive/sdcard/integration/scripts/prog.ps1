# ============================================================================
#  scripts/prog.ps1 -- load the bitstream into the Tang Nano 20K with the
#  Gowin programmer.
#
#    scripts\prog.ps1           SRAM load (fast, lost on power cycle)
#    scripts\prog.ps1 -Flash    write configuration flash (persistent)
#
#  openFPGALoader is not used: it needs WinUSB on the FT2232's interface A and
#  fails with `usb_open() failed` on this machine.  programmer_cli's embedded
#  Python dies on an inherited PYTHON* variable ("unknown encoding"), so those
#  are cleared for the call.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$Flash,
    [ValidateSet('top', 'sdtest')][string]$Top = 'top'   # sdtest: the raw SD FAT32 test bitstream
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $PSScriptRoot 'toolchain.ps1')

$name = Get-FpgaName
if ($Top -eq 'sdtest') { $name = 'sdtest' }
$fs   = (Resolve-Path "build/bitstream/$name.fs").Path

$gowinProg = 'C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe'
if (-not (Test-Path $gowinProg)) {
    $gowinProg = 'C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe'
}
if (-not (Test-Path $gowinProg)) { throw 'Gowin programmer_cli.exe not found' }

Get-ChildItem Env: | Where-Object Name -Match '^PYTHON' | ForEach-Object { Remove-Item "Env:$($_.Name)" }

$run = if ($Flash) { 8 } else { 2 }
Write-Host "Using Gowin programmer_cli ($(if ($Flash) { 'exFlash' } else { 'SRAM' })): $fs"
& $gowinProg --device GW2AR-18C --run $run --fsFile $fs
Write-Host "programmer_cli exit code: $LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { throw "programmer_cli exited with code $LASTEXITCODE" }
