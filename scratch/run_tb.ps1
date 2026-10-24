$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $root 'scripts\toolchain.ps1')

$disk2 = @('src/disk2/disk2_card.v', 'src/disk2/disk2_store.v')
$mockingboard = @('src/mockingboard/mockingboard_card.v', 'src/mockingboard/via6522.v', 'src/mockingboard/ay8910.v')
$softcard = @('src/softcard.v', 'src/z80/tv80_core.v', 'src/z80/tv80_alu.v', 'src/z80/tv80_mcode.v', 'src/z80/tv80_reg.v')
$core = @('src/apple2_core.v', 'src/apple2_mem.v', 'src/slot_bus.v', 'src/cpu/cpu_65c02.v', 'src/cpu/ALU.v', 'src/prodos_hd.v', 'src/thunderclock.v', 'src/ssc.v') + $disk2 + $mockingboard + $softcard
$files = @('sim/models/ddr3_model.v', 'src/aux_ram.v', 'src/video_generator.v') + $core
$iverilogArgs = @('-g2012', '-DDSK2_NO_P6_ROM', '-DSSC_NO_ROM', '-o', 'build/tb_oldskool.vvp', 'sim/tb_oldskool.v') + $files

Invoke-Tool 'iverilog' $iverilogArgs
$vvp = if ($OssCadBin) { Join-Path $OssCadBin 'vvp.exe' } else { 'vvp' }
& $vvp 'build/tb_oldskool.vvp'
