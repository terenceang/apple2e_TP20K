# ============================================================================
#  scripts/toolchain.ps1 -- dot-source this to configure the OSS CAD Suite
#  environment (iverilog/vvp for sim/run.ps1) and set $OssCadBin.  The FPGA
#  build itself is Gowin EDA (scripts/build.ps1) and needs none of this.
#
#  Tool discovery order:
#    1. $env:OSS_CAD_SUITE, if set
#    2. "openfpga.toolchain.path" from VS Code user settings
#    3. C:\oss-cad-suite  (the default install location)
#    4. Whatever is already on $env:PATH
#
#  After dot-sourcing, $OssCadBin is the bin\ path.  The OSS CAD Suite environment.ps1 is applied so
#  that lib\ (DLLs) is on PATH and all other required env-vars are set.
# ============================================================================

$OssCadBin = $null

# The project name (and so the bitstream name) is the SSOT in fpga.yaml.
function Get-FpgaName {
    $yaml = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'fpga.yaml') -Raw
    $name = ($yaml -split "`n" | Where-Object { $_ -match '^name:\s*(.+)' } | Select-Object -First 1) -replace '^name:\s*', ''
    return $name.Trim()
}

function _FindOssCadRoot {
    param([string]$Root)
    if ($Root -and (Test-Path (Join-Path $Root 'bin\yosys.exe'))) { return $Root }
    return $null
}

# 1. Explicit env var
$found = _FindOssCadRoot $env:OSS_CAD_SUITE

# 2. VS Code user settings
if (-not $found) {
    $vsSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (Test-Path $vsSettings) {
        try {
            $json = Get-Content $vsSettings -Raw | ConvertFrom-Json -ErrorAction Stop
            $found = _FindOssCadRoot $json.'openfpga.toolchain.path'
        } catch {}
    }
}

# 3. Default install location
if (-not $found) { $found = _FindOssCadRoot 'C:\oss-cad-suite' }

if ($found) {
    $OssCadBin = Join-Path $found 'bin'

    # Apply the suite's environment so DLLs in lib\ are loadable
    if (-not $env:YOSYSHQ_ROOT) {
        $env:YOSYSHQ_ROOT      = $found
        $env:SSL_CERT_FILE     = Join-Path $found 'etc\cacert.pem'
        $env:PYTHON_EXECUTABLE = Join-Path $found 'lib\python3.exe'
        $env:QT_PLUGIN_PATH    = Join-Path $found 'lib\qt6\plugins'
        $env:QT_LOGGING_RULES  = '*=false'
        $env:GTK_EXE_PREFIX    = $found
        $env:GTK_DATA_PREFIX   = $found
        $env:GDK_PIXBUF_MODULEDIR   = Join-Path $found 'lib\gdk-pixbuf-2.0\2.10.0\loaders'
        $env:GDK_PIXBUF_MODULE_FILE = Join-Path $found 'lib\gdk-pixbuf-2.0\2.10.0\loaders.cache'
        $env:OPENFPGALOADER_SOJ_DIR = Join-Path $found 'share\openFPGALoader'

        # Prepend bin\ and lib\ to PATH (lib\ carries the Windows DLLs)
        $env:PATH = "$OssCadBin;$(Join-Path $found 'lib');$env:PATH"

        # Run the pixbuf cache update silently (it's fast, output goes nowhere)
        $gdk = Join-Path $found 'lib\gdk-pixbuf-query-loaders.exe'
        if (Test-Path $gdk) {
            & $gdk --update-cache 2>$null | Out-Null
        }
    }
}

function Invoke-Tool {
    <#
    .SYNOPSIS
        Run a tool from the OSS CAD Suite bin dir.
        Throws on non-zero exit code.
    #>
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    if ($OssCadBin) {
        $exe = Join-Path $OssCadBin "$Name.exe"
        if (-not (Test-Path $exe)) { $exe = $Name }  # fallback for scripts
    } else {
        $exe = $Name
    }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @Arguments
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        throw "'$Name' exited with code $LASTEXITCODE"
    }
}
