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
Run-Tb 'tb_sound'        @('src/sound_generator.v', 'src/audio_filter.v')
Run-Tb 'tb_audio_filter' @('src/audio_filter.v')
Run-Tb 'tb_input'        @('src/input_controller.v')
Run-Tb 'tb_slots'        @('src/slot_bus.v')
Run-Tb 'tb_ay8910'       @('src/mockingboard/ay8910.v')
Run-Tb 'tb_via6522'      @('src/mockingboard/via6522.v')
Run-Tb 'tb_mockingboard' @('src/mockingboard/mockingboard_card.v', 'src/mockingboard/via6522.v', 'src/mockingboard/ay8910.v')

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
# memory, the slot-6 card, the slot-4 Mockingboard card, the slot-2 SoftCard and the slot-7 hard disk.  tb_cpu_trace and
# tb_auxsw both elaborate apple2_core, so both need the cards with it; tb_disk2
# drives the card on its own and does not want the core.
$disk2 = @('src/disk2/disk2_card.v', 'src/disk2/disk2_store.v')
$mockingboard = @('src/mockingboard/mockingboard_card.v', 'src/mockingboard/via6522.v', 'src/mockingboard/ay8910.v')
$softcard = @('src/softcard.v', 'src/z80/tv80_core.v', 'src/z80/tv80_alu.v', 'src/z80/tv80_mcode.v', 'src/z80/tv80_reg.v')
$core  = @('src/apple2_core.v', 'src/apple2_mem.v', 'src/slot_bus.v',
           'src/cpu/cpu_65c02.v', 'src/cpu/ALU.v', 'src/prodos_hd.v', 'src/thunderclock.v') + $disk2 + $mockingboard + $softcard
Run-Tb 'tb_thunderclock' @('src/thunderclock.v')
# slot 7's firmware: the included .vh must match src/prodos_hd_rom.s, and the
# firmware is run against a model of its registers (py65; the system Python,
# not the OSS CAD Suite's, which has no py65).  Judged by exit code alone.
if (-not $Target -or $Target -in @('tb_prodos_hd', 'hdrom')) {
    foreach ($py in @(@('scripts\hdrom.py', '--check'), @('scripts\hdrom_test.py'))) {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & python (Join-Path $root $py[0]) $py[1..($py.Count - 1)] 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $out | ForEach-Object { "$_" }
        if ($code -ne 0) { throw "FAILED: python $($py -join ' ')" }
    }
}
Run-Tb 'tb_disk2'        $disk2 -Gen '2012' -Defines $disk2Defines
# tb_sdvol and tb_sdcopy boot from a FAT32 card built by the page's own FAT code
if (-not $Target -or $Target -in @('tb_sdvol', 'tb_sdcopy')) {
    & node (Join-Path $root 'web\scripts\simcard.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'FAILED: web/scripts/simcard.mjs' }
}
Run-Tb 'tb_sdvol'        @('sim/models/sdcard.v', 'src/sd_vol.v', 'src/spi_byte.v') -Gen '2012'
Run-Tb 'tb_sdcopy'       @('sim/models/sdcard.v', 'src/sd_vol.v', 'src/spi_byte.v', 'src/serial_debugger.v') -Gen '2012'
Run-Tb 'tb_video_hdmi'   (@('src/video_generator.v', 'src/colorbar_gen.v') + $hdmi)
Run-Tb 'tb_cpu_trace'    $core -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_auxsw'        $core -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_prodos_hd'    $core -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_p6boot'       $core -Gen '2012' -Defines $disk2Defines

Run-Tb 'tb_aux_ram'     @('sim/models/ddr3_model.v', 'src/aux_ram.v') -Gen '2012'
Run-Tb 'tb_auxstress'   (@('sim/models/ddr3_model.v', 'src/aux_ram.v', 'src/video_generator.v') + $core) -Gen '2012' -Defines $disk2Defines
Run-Tb 'tb_softcard'    (@('sim/models/ddr3_model.v', 'src/aux_ram.v', 'src/video_generator.v') + $core) -Gen '2012' -Defines $disk2Defines

# The DDR3 IP is encrypted; sim/models/ddr3_model.v stands in for it.
$allSources = & (Join-Path $root 'scripts\sources.ps1') -Except 'src/ddr3_memory_interface/ddr3_memory_interface.v'
Run-Tb 'tb_top'          (@('sim/models/gowin_prims.v', 'sim/models/ddr3_model.v') + $allSources) -Gen '2012' -Defines $disk2Defines

Write-Host "all testbenches passed"
