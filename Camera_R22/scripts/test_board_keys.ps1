param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
$env:PYTHONDONTWRITEBYTECODE='1';$env:PYTHONIOENCODING='utf-8'
$env:TEMP=Join-Path $root 'work/board_keys_20261031';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
if($CheckOnly){Write-Host 'Finite board-key RTL, host and input checks only; no PDS build or board access.';return}
Push-Location $root
try {
 foreach($script in @('sim/board_keys/run_validation.py','host/camera_console/run_r22_validation.py','scripts/check_r22_hierarchy.py','scripts/verify_camera_r22.py')){
  & $python -B $script
  if($LASTEXITCODE -ne 0){throw ('Board key validation failed: '+$script)}
 }
} finally {Pop-Location}
