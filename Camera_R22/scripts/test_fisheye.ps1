param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
$env:PYTHONDONTWRITEBYTECODE='1';$env:TEMP=Join-Path $root 'work/fisheye_integration';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
if($CheckOnly){Write-Host 'Finite fisheye/OpenCV, 128x96 renderer, CPU/slots/snapshot and host checks. No PDS or board.';return}
Push-Location $root
try {
 foreach($script in @('sim/fisheye/run_validation.py','host/camera_console/run_r22_validation.py','scripts/check_r22_hierarchy.py','scripts/verify_camera_r22.py')){
  & $python -B $script
  if($LASTEXITCODE -ne 0){throw ('Fisheye source check failed: '+$script)}
 }
}finally{Pop-Location}
