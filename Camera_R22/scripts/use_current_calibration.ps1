param([switch]$NoOpen)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$taskPython=Get-PythonExe $root
$settings=Get-Content -LiteralPath (Join-Path $root 'host\camera_console\settings.json') -Raw | ConvertFrom-Json
$capture=[IO.Path]::GetFullPath([string]$settings.output)
$candidate=Join-Path $capture 'calibration_candidate.json'
if(!(Test-Path -LiteralPath $candidate -PathType Leaf)){throw "Calculate calibration parameters in the camera console first: $candidate"}
$review=Join-Path $capture 'calibration-review'
$corrected=Join-Path $capture 'undistorted'
& $taskPython (Join-Path $root 'scripts\apply_saved_calibration.py') $candidate $capture $corrected
if($LASTEXITCODE -ne 0){throw 'PC image correction failed.'}
& $taskPython (Join-Path $root 'scripts\inspect_undistortion.py') $candidate $review
if($LASTEXITCODE -ne 0){throw 'Correction comparison generation failed.'}
& $taskPython (Join-Path $root 'scripts\check_candidate_mapping.py') $candidate (Join-Path $review 'mapping_check.json')
if($LASTEXITCODE -ne 0){throw 'Mapping check failed.'}
Write-Host "Corrected full frames: $corrected"
Write-Host "Before/after comparison: $review\index.html"
Write-Host 'PC correction only; FPGA is unchanged.'
if(!$NoOpen){Invoke-Item -LiteralPath (Join-Path $review 'index.html')}
