param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
$env:PYTHONDONTWRITEBYTECODE='1';$env:PYTHONIOENCODING='utf-8'
$env:TEMP=Join-Path $root 'work/rotation_integration';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null
if($CheckOnly){Write-Host 'Finite rotation RTL/CPU/host checks only; no PDS or device access.';return}
Push-Location $root
try{
 foreach($script in @('sim/rotation/run_validation.py','host/camera_console/run_r22_validation.py','scripts/check_r22_hierarchy.py','scripts/verify_camera_r22.py')){
  & $python -B $script
  if($LASTEXITCODE -ne 0){throw ('Rotation check failed: '+$script)}
 }
}finally{Pop-Location}
