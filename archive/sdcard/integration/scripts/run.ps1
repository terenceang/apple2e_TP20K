# ============================================================================
#  sim/run.ps1 -- build and run every testbench with iverilog.
#
#  Run from anywhere; tools run from the repo root so `include and $readmemh
#  paths resolve.  tb_top and tb_cpu_trace need the ROM images in roms/
#  (see roms/README.md).
#
#  The RTL file list is fpga.yaml, read through scripts/sources.ps1.
# ============================================================================
param(
    [string]$Target = ''
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $root 'scripts\toolchain.ps1')

New-Item -ItemType Directory -Force -Path (Join-Path $root 'build') | Out-Null

function Run-Tb {
    param(
        [string]$Name,
        [string[]]$Files,
        [string]$Gen = '2005',
        [string[]]$Defines = @()
    )
    if ($Target -and $Name -ne $Target) { return }
    Write-Host "=== $Name ==="
    # On Windows iverilog -o writes a vvp script whatever the extension is, so
    # name the output .vvp and run it through vvp explicitly.
    $outVvp = Join-Path $root "build\$Name.vvp"
    $tbFile = Join-Path $root "sim\$Name.v"

    # The array brackets matter: "-g$Gen" + @() would join the two into one
    # string, and iverilog would read "-g2005-o" as the generation.
    $iverilogArgs = @("-g$Gen") + @($Defines) + @('-o', $outVvp, $tbFile) + $Files
    Invoke-Tool 'iverilog' $iverilogArgs

    $logFile = Join-Path $root "build\$Name.log"
    $vvp = if ($OssCadBin) { Join-Path $OssCadBin 'vvp.exe' } else { 'vvp' }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $vvp $outVvp > $logFile 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    Get-Content $logFile | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "FAILED: $Name exited with code $LASTEXITCODE"
    }

    $logContent = Get-Content $logFile -Raw
    if ($logContent -match '(?m)^FAIL' -or $logContent -notmatch 'PASS') {
        throw "FAILED: $Name did not report PASS"
    }
    Write-Host ""
}

$hdmi = @('src/hdmi/hdmi_tx.v', 'src/hdmi/hdmi_island_scheduler.v', 'src/hdmi/hdmi_data_island.v',
          'src/hdmi/hdmi_packet_ecc.v', 'src/hdmi/hdmi_packets.v', 'src/hdmi/hdmi_tmds_encoder.v')
$island = @('src/hdmi/hdmi_data_island.v', 'src/hdmi/hdmi_packet_ecc.v', 'src/hdmi/hdmi_tmds_encoder.v')

# Guard against the hdmi list drifting from fpga.yaml (tb_top below reads the
# yaml through sources.ps1; the unit testbenches above use this hand-made copy).
$fpgaHdmi = @(& (Join-Path $root 'scripts\sources.ps1') | Where-Object { $_ -like 'src/hdmi/*' })
if ((Compare-Object $hdmi $fpgaHdmi).Count -ne 0) {
    throw "the `$hdmi list no longer matches fpga.yaml: $($hdmi -join ', ') vs $($fpgaHdmi -join ', ')"
}

Run-Tb 'tb_tmds_encoder' @('src/hdmi/hdmi_tmds_encoder.v')
Run-Tb 'tb_packet_ecc'   @('src/hdmi/hdmi_packet_ecc.v')
Run-Tb 'tb_packets'      @('src/hdmi/hdmi_packets.v')
Run-Tb 'tb_data_island'  $island
Run-Tb 'tb_sound'        @('src/sound_generator.v')
Run-Tb 'tb_input'        @('src/input_controller.v')
Run-Tb 'tb_slots'        @('src/slot_bus.v')
Run-Tb 'tb_sd_files'     @('sim/models/sdcard.v', 'src/sd/sd_files.v', 'src/sd/fat32.v', 'src/sd/sd_blk.v', 'src/sd/spi_byte.v', 'src/uart_tx.v') -Gen '2012'
# sd_loader and the SD test share the byte engine, the UART and the command set
$sdtest = @(& (Join-Path $root 'scripts\sources.ps1') -Block sdtest_sources | Where-Object { $_ -ne 'src/sdtest/top_sdtest.v' })
$fat32 = @('sim/models/sdcard.v', 'src/sd/fat32.v', 'src/sd/sd_blk.v', 'src/sd/spi_byte.v')
Run-Tb 'tb_fat32'        $fat32 -Gen '2012'
Run-Tb 'tb_fat_test'     (@('sim/models/sdcard.v') + $sdtest) -Gen '2012'

# The card's $C600 boot ROM is Apple copyright and is not in the repo (see
# roms/README.md), so it is loaded only if the user has put it there, the same
# condition scripts/build.ps1 uses for synthesis.  $readmemh on a missing file
# is an error in Icarus too, and a fresh clone has to be able to run the suite;
# with INTCXROM on, which is the reset default, the //e's own ROM at $C600 boots
# a Disk II without it.
$disk2Defines = @()
if (-not (Test-Path -LiteralPath (Join-Path $root 'roms\disk2_p6.hex'))) {
    $disk2Defines = @('-DDSK2_NO_P6_ROM')
    Write-Host "== no roms\disk2_p6.hex: the card's `$C600 stays zero (INTCXROM boots DOS anyway)"
}

# What apple2_core instantiates, hand-made: the core, the CPU, the slot bus, the
# memory and the slot-6 card.  tb_cpu_trace and tb_auxsw both elaborate
# apple2_core, so both need the card with it; tb_disk2 drives the card on its
# own and does not want the core.
$disk2 = @('src/disk2/disk2_card.v', 'src/disk2/disk2_store.v')
$core  = @('src/apple2_core.v', 'src/apple2_mem.v', 'src/slot_bus.v', 'src/prodos/prodos_card.v',
           'src/cpu/cpu_65c02.v', 'src/cpu/ALU.v') + $disk2
Run-Tb 'tb_disk2'        $disk2 -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_diskimg'      @('src/serial_debugger.v', 'src/disk2/disk2_store.v') -Gen '2012'
Run-Tb 'tb_video_hdmi'   (@('src/video_generator.v', 'src/colorbar_gen.v') + $hdmi)
Run-Tb 'tb_cpu_trace'    $core -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_auxsw'        $core -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_p6boot'       $core -Gen '2012' -Defines $disk2Defines

Run-Tb 'tb_aux_ram'      @('sim/models/sdram_model.v', 'src/aux_ram.v', 'src/sdram/sdram.v') -Gen '2012'

$allSources = & (Join-Path $root 'scripts\sources.ps1')
Run-Tb 'tb_top'          (@('sim/models/gowin_prims.v', 'sim/models/sdram_model.v') + $allSources) -Gen '2012' -Defines $disk2Defines

Write-Host "all testbenches passed"
