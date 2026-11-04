param([Parameter(ValueFromRemainingArguments=$true)][string[]]$PythonArguments)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TEMP=Join-Path $root 'work\r21'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
& $python -B @PythonArguments
exit $LASTEXITCODE
