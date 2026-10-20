# ============================================================================
#  scripts/hdmi_diff.ps1 -- keep src/hdmi/ honest.
#
#    -Check     (default) verify src/hdmi/ against the recorded sha256 snapshot.
#               Exits non-zero if any file was edited locally.
#    -Upstream  diff src/hdmi/ against another checkout of TN20K-HDMI.
#               Informational; always exits 0.
#
#  Usage:
#    scripts\hdmi_diff.ps1
#    scripts\hdmi_diff.ps1 -Check
#    scripts\hdmi_diff.ps1 -Upstream
#    scripts\hdmi_diff.ps1 -Upstream C:\path\to\TN20K-HDMI
# ============================================================================
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Check')]   [switch]$Check,
    [Parameter(ParameterSetName = 'Upstream')][switch]$Upstream,
    [Parameter(ParameterSetName = 'Upstream')][string]$UpstreamPath = ''
)
$ErrorActionPreference = 'Stop'

$root           = Split-Path -Parent $PSScriptRoot
$SNAPSHOT       = Join-Path $root 'scripts\hdmi_snapshot.sha256'
$UPSTREAM_COMMIT = '388b39e'
$DEFAULT_UPSTREAM = Join-Path $HOME 'TN20K-HDMI'

if (-not $UpstreamPath) { $UpstreamPath = $DEFAULT_UPSTREAM }

# ── --Check (default) ────────────────────────────────────────────────────────
if (-not $Upstream) {
    Write-Host "== src/hdmi/ vs the recorded snapshot (TN20K-HDMI @$UPSTREAM_COMMIT)"

    $lines = Get-Content $SNAPSHOT
    $allOk = $true
    foreach ($line in $lines) {
        # Format: <hash>  <path>
        if ($line -match '^([0-9a-f]{64})\s+(.+)$') {
            $expectedHash = $Matches[1]
            $filePath     = $Matches[2].Trim()
            $fullPath     = Join-Path $root $filePath
            if (-not (Test-Path $fullPath)) {
                Write-Host "MISSING: $filePath"
                $allOk = $false
                continue
            }
            $actualHash = (Get-FileHash $fullPath -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedHash) {
                Write-Host "CHANGED: $filePath"
                $allOk = $false
            } else {
                Write-Host "OK:      $filePath"
            }
        }
    }

    if ($allOk) {
        Write-Host "OK: src/hdmi/ is unmodified since the snapshot was taken."
        Write-Host "    only hdmi_tx.v was ever meant to differ upstream (RGB_QUANT)."
    } else {
        Write-Error @'

FAILED: src/hdmi/ has local edits not reflected in scripts/hdmi_snapshot.sha256.
  If they are intended, re-baseline with:
    Get-ChildItem src\hdmi -Include *.v,*.vh -Recurse | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() + '  src/hdmi/' + $_.Name } | Set-Content scripts\hdmi_snapshot.sha256 -Encoding ascii
'@
        exit 1
    }
}

# ── --Upstream ───────────────────────────────────────────────────────────────
else {
    $upstreamHdmi = Join-Path $UpstreamPath 'src\hdmi'
    if (-not (Test-Path $upstreamHdmi)) {
        Write-Error "no TN20K-HDMI checkout at $UpstreamPath`nusage: scripts\hdmi_diff.ps1 -Upstream [-UpstreamPath <path>]"
        exit 2
    }

    Write-Host "== src/hdmi/ vs $upstreamHdmi"
    Write-Host "   snapshot was taken at TN20K-HDMI $UPSTREAM_COMMIT"
    Write-Host ""

    $drift = $false
    # -Include needs -Recurse (or a wildcard path) to see anything at all;
    # without it this loop ran over zero files and always reported "no drift".
    $localFiles = Get-ChildItem (Join-Path $root 'src\hdmi') -Include '*.v','*.vh' -Recurse
    foreach ($f in $localFiles) {
        $base = $f.Name
        $other = Join-Path $upstreamHdmi $base
        if (-not (Test-Path $other)) {
            Write-Host ("  {0,-28} only here" -f $base)
            $drift = $true
        } else {
            $h1 = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
            $h2 = (Get-FileHash $other      -Algorithm SHA256).Hash
            if ($h1 -eq $h2) {
                Write-Host ("  {0,-28} same" -f $base)
            } else {
                # Count differing lines (basic line diff)
                $local  = Get-Content $f.FullName
                $remote = Get-Content $other
                $maxLen = [Math]::Max($local.Count, $remote.Count)
                $diffCount = 0
                for ($i = 0; $i -lt $maxLen; $i++) {
                    if ($local[$i] -ne $remote[$i]) { $diffCount++ }
                }
                Write-Host ("  {0,-28} differs ({1} changed lines)" -f $base, $diffCount)
                $drift = $true
            }
        }
    }

    Write-Host ""
    if (-not $drift) {
        Write-Host "No drift: the upstream project has not changed src/hdmi/ since the snapshot."
    } else {
        Write-Host "Drift found. Expected: hdmi_tx.v only (RGB_QUANT)."
        Write-Host "Anything else means TN20K-HDMI has moved on; review each file with:"
        Write-Host "  Compare-Object (Get-Content src\hdmi\<file>) (Get-Content $UpstreamPath\src\hdmi\<file>)"
        Write-Host "then either port the change and re-baseline the snapshot, or record"
        Write-Host "why it does not apply here."
    }
}
