$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'run_python.cmd') (Join-Path $PSScriptRoot 'verify_camera_r22.py') --check-inputs @args
if($LASTEXITCODE -ne 0){throw 'R22 input verification failed'}
