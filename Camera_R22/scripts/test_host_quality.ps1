param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
$env:PYTHONDONTWRITEBYTECODE='1';$env:PYTHONIOENCODING='utf-8'
$env:TEMP=Join-Path $root 'work/host_ui_migration';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
if($CheckOnly){Write-Host 'Offline host/quality/MTF tests; no FPGA build or real device connection.';return}
Push-Location $root
try {
 foreach($script in @('host/camera_console/run_r22_validation.py','scripts/verify_camera_r22.py')){
  & $python -B $script
  if($LASTEXITCODE -ne 0){throw ('Host quality validation failed: '+$script)}
 }
} finally {Pop-Location}
