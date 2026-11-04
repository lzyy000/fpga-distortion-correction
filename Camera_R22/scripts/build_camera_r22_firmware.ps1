param([string]$Implementation='pnr_camera_r21_modes')
$ErrorActionPreference='Stop'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TEMP=Join-Path $PSScriptRoot '../work/r22_eis';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
$taskPython=Get-PythonExe $root
Initialize-PythonTools $root
& $taskPython -B (Join-Path $root 'scripts/export_fisheye_profile.py')
if($LASTEXITCODE -ne 0){throw 'Fisheye profile export failed'}
$bin=Get-RiscvBin $root
$gcc=Join-Path $bin 'riscv-none-embed-gcc.exe'
$out=Join-Path $root 'firmware\camera_r22_build'
New-Item -ItemType Directory -Path $out -Force | Out-Null
Push-Location $root
try{
 & $gcc '-march=rv32imc' '-mabi=ilp32' '-Os' '-g' '-fstack-usage' '-ffreestanding' '-fno-builtin' '-msmall-data-limit=0' '-ffunction-sections' '-fdata-sections' '-Wall' '-Wextra' '-nostdlib' '-nostartfiles' '-Wl,--gc-sections' '-Wl,-Map,firmware/camera_r22_build/firmware.map' '-T' 'firmware/sections_r22.lds' 'firmware/start_r22.S' '-I' 'firmware' 'night/firmware/camera_r22_main.c' '-lgcc' '-o' 'firmware/camera_r22_build/firmware.elf'
 if($LASTEXITCODE -ne 0){throw 'Firmware compilation failed'}
 $taskStackFile=Join-Path $root 'camera_r22_main.su'
 if(Test-Path -LiteralPath $taskStackFile){Move-Item -LiteralPath $taskStackFile -Destination (Join-Path $out 'firmware.su') -Force}
 & (Join-Path $bin 'riscv-none-embed-objcopy.exe') '-O' 'binary' 'firmware/camera_r22_build/firmware.elf' 'firmware/camera_r22_build/firmware.bin'
 if($LASTEXITCODE -ne 0){throw 'objcopy failed'}
 & (Join-Path $bin 'riscv-none-embed-size.exe') 'firmware/camera_r22_build/firmware.elf'
 & (Join-Path $bin 'riscv-none-embed-objdump.exe') '-d' 'firmware/camera_r22_build/firmware.elf' | Out-File -LiteralPath (Join-Path $out 'firmware.dis') -Encoding ascii
 # Binary uses lowest load address 0x10000; data LMA follows text.
 $image=[IO.File]::ReadAllBytes((Join-Path $out 'firmware.bin'))
 if($image.Length -gt 0xe000){throw 'Firmware exceeds 56 KiB CODE area'}
 $ram=New-Object byte[] 65536
 [Array]::Copy($image,0,$ram,8192,$image.Length)
 $lines=for($i=0;$i -lt 16384;$i++){[BitConverter]::ToUInt32($ram,4*$i).ToString('x8')}
 [IO.File]::WriteAllLines((Join-Path (Join-Path $root $Implementation) 'firmware_camera.hex'),$lines,[Text.Encoding]::ASCII)
 Write-Host "Firmware image: $($image.Length) bytes; 16384-word BRAM initialization ready."
}finally{Pop-Location}
