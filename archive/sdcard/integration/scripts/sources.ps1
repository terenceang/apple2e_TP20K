# ============================================================================
#  scripts/sources.ps1 -- print the RTL source list from fpga.yaml.
#
#  Usage:
#    scripts\sources.ps1
#    scripts\sources.ps1 --except src/foo/bar.v [--except ...]
#
#  Outputs one path per line, relative to the repo root. sim\run.ps1 and
#  scripts\build.ps1 both consume this, so fpga.yaml is the only file list.
# ============================================================================
[CmdletBinding()]
param(
    [string[]]$Except = @(),
    [string]$Block = 'sources'        # or 'sdtest_sources'
)

$root = Split-Path -Parent $PSScriptRoot
$yaml = Get-Content (Join-Path $root 'fpga.yaml') -Raw

# Parse the `$Block` block: lines that start with '  - '
$inSources = $false
foreach ($line in $yaml -split "`n") {
    if ($line -match "^${Block}:") { $inSources = $true; continue }
    if ($inSources -and $line -match '^[^ ]') { $inSources = $false }
    if ($inSources -and $line -match '^\s*-\s+(\S+)') {
        $f = $Matches[1].Trim()
        if ($f -and $f -notin $Except) {
            Write-Output $f
        }
    }
}
