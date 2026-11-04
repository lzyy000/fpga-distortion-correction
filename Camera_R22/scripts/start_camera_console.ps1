param([switch]$SmokeTest,[switch]$UiPreview,[string]$Geometry)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:TEMP=Join-Path $root 'work\console_tmp'
$env:TMP=$env:TEMP
$env:PYTHONDONTWRITEBYTECODE='1'
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Initialize-PythonTools $root
$python=Get-PythonExe $root
$entry=Join-Path $root 'host\camera_console\console.py'
$taskArguments=@($entry,'--project',$root)
if($UiPreview){$taskArguments+='--ui-preview'}
if($Geometry){$taskArguments+=@('--geometry',$Geometry)}
if($SmokeTest){
 $taskArguments+='--smoke-test'
 & $python -B @taskArguments
 if($LASTEXITCODE -ne 0){throw 'Camera console startup check failed'}
 return
}
$pythonw=Join-Path (Split-Path $python -Parent) 'pythonw.exe'
if(Test-Path -LiteralPath $pythonw -PathType Leaf){$python=$pythonw}
$taskCommandLine=($taskArguments | ForEach-Object {'"'+$_+'"'}) -join ' '
Start-Process -FilePath $python -ArgumentList $taskCommandLine -WorkingDirectory $root -WindowStyle Hidden
