param([switch]$CheckOnly,[switch]$FullFrame)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
$env:PYTHONDONTWRITEBYTECODE='1';$env:TEMP=Join-Path $root 'work/r22_eis';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
if($CheckOnly){Write-Host 'R22 finite RTL + host + CPU + source checks. No PDS or board action.';return}
if($FullFrame){throw 'R22 full-HD concurrent renderer regression is not supplied; use finite tests then user PDS/board validation. Old R21 full-frame tests cannot certify R22.'}
Push-Location $root
try {
 foreach($script in @('sim/r21_modes/run_validation.py','sim/r22_eis/test_static_cache32.py','sim/r22_eis/run_validation.py','sim/fisheye/run_validation.py','sim/rotation/run_validation.py','host/camera_console/run_r22_validation.py','scripts/check_r22_hierarchy.py','scripts/verify_camera_r22.py')){
  & $python -B $script
  if($LASTEXITCODE -ne 0){throw ('R22 check failed: '+$script)}
 }
}finally{Pop-Location}
