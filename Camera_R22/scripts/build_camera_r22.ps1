param([switch]$CheckOnly,[switch]$SkipValidation)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Assert-PdsProjectPath $root
$impl=Join-Path $root 'pnr_camera_r21_modes'
if($CheckOnly){Write-Host "R22 source integration, same unique PDS: $impl";return}
Initialize-PythonTools $root
$python=Get-PythonExe $root
$pds=Get-PdsTool 'pds_shell.exe'
$env:PYTHONDONTWRITEBYTECODE='1';$env:TEMP=Join-Path $root 'work/r22_eis';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
$previousLicense=$env:PANGO_LICENSE_FILE
Push-Location $root
try {
 Copy-Item -LiteralPath (Join-Path $root 'rtl/night_gain.hex') -Destination (Join-Path $impl 'night_gain.hex')
 & (Join-Path $PSScriptRoot 'build_camera_r22_firmware.ps1')
 if(!$SkipValidation){& (Join-Path $PSScriptRoot 'test_camera_r22.ps1')}
 & $python -B 'scripts/verify_camera_r22.py' --prepare
 if($LASTEXITCODE -ne 0){throw 'R22 source freeze failed'}
 $taskLicense=Get-PdsLicense
 if($taskLicense){$env:PANGO_LICENSE_FILE=$taskLicense}
 & $pds -project (Join-Path $impl 'camera_1080p30_raw8.pds') -run gen_bit_stream -work_dir $impl -skip_actions 'report_power gen_netlist' *> (Join-Path $root 'reports/pds_r22_build.log')
 if($LASTEXITCODE -ne 0){throw 'R22 PDS build failed'}
 & $python -B 'scripts/verify_camera_r22.py' --check-build
 if($LASTEXITCODE -ne 0){throw 'R22 current build identity/timing check failed'}
}finally{$env:PANGO_LICENSE_FILE=$previousLicense;Pop-Location}
