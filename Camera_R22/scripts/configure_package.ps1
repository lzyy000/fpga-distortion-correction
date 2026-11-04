param([switch]$Quiet,[switch]$DetectComputer)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath=Join-Path $PSScriptRoot 'local_tools.json'
$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$oldRoot=[string]$config.package_root
$config.shared_tools=Join-Path $root 'tools'
$config.python_exe=Join-Path $root 'tools/python/python.exe'
$config.riscv_bin=Join-Path $root 'tools/riscv-gcc/bin'
$config.package_root=$root
# Icarus invokes its internal programs through cmd.exe without quoting its base
# directory. Use a checked junction for tools when the extraction path has spaces.
$taskIverilogRoot=Join-Path $root 'tools/iverilog'
if($taskIverilogRoot -match '[\s()]'){
 $taskAliasParent=Split-Path $root -Parent
 while($taskAliasParent -match '[\s()]'){$taskAliasParent=Split-Path $taskAliasParent -Parent}
 $taskHasher=[Security.Cryptography.SHA256]::Create()
 try {$taskAliasId=([BitConverter]::ToString($taskHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))).Replace('-','').Substring(0,10).ToLowerInvariant()} finally {$taskHasher.Dispose()}
 $taskAlias=Join-Path $taskAliasParent ('r22_tools_'+$taskAliasId)
 $taskTarget=Join-Path $root 'tools'
 if(Test-Path -LiteralPath $taskAlias){
  $taskLink=Get-Item -LiteralPath $taskAlias -Force
  if($taskLink.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath([string]@($taskLink.Target)[0]) -ine $taskTarget){throw ('Tool alias belongs to another location: '+$taskAlias)}
 }else{New-Item -ItemType Junction -Path $taskAlias -Value $taskTarget | Out-Null}
 $taskIverilogRoot=Join-Path $taskAlias 'iverilog'
}
$config | Add-Member -NotePropertyName iverilog_root -NotePropertyValue $taskIverilogRoot -Force
# Keep package-local dependencies, but resolve PDS and its license on this PC.
$pdsCandidates=@($env:FPGA_PDS_ROOT,[string]$config.pds_root,'D:\pango\PDS_2022.2-SP6.4','C:\pango\PDS_2022.2-SP6.4')
foreach($candidate in $pdsCandidates){
 if($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin/pds.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $candidate 'bin/pds_shell.exe') -PathType Leaf)){
  $config.pds_root=[IO.Path]::GetFullPath($candidate);break
 }
}
if($env:PANGO_LICENSE_FILE){$config.pds_license_file=$env:PANGO_LICENSE_FILE}
$settingsPath=Join-Path $root 'host/camera_console/settings.json'
$settings=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not [IO.Path]::IsPathRooted([string]$settings.output)){
 $settings.output=Join-Path $root ([string]$settings.output)
}elseif($oldRoot -and $oldRoot -ne $root -and ([string]$settings.output).StartsWith($oldRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
 $settings.output=Join-Path $root (([string]$settings.output).Substring($oldRoot.Length+1))
}
if($DetectComputer){
 # Enumerate only; never open a UART, send packets or change Windows networking.
 $previousPythonPath=$env:PYTHONPATH
 try {
  $env:PYTHONPATH=Join-Path $root 'tools/python_packages'
  $portsJson=& $config.python_exe -B (Join-Path $root 'host/preflight.py') --json
  if($LASTEXITCODE -ne 0){throw 'Serial enumeration failed'}
  $ports=@($portsJson | ConvertFrom-Json | ForEach-Object {$_})
  if($ports.Count -eq 1){$settings.serial_port=[string]$ports[0]}
  elseif($ports.Count -eq 0){$settings.serial_port=''}
  if(!$Quiet){Write-Host ('CP210x ports: '+($ports -join ', '));Write-Host 'No device is opened. Connect USB_UART and select its port in the console.'}
 } finally {$env:PYTHONPATH=$previousPythonPath}
}
foreach($entry in @(@($configPath,$config),@($settingsPath,$settings))){
 $text=($entry[1] | ConvertTo-Json -Depth 8)+[Environment]::NewLine
 if([IO.File]::ReadAllText($entry[0]) -ne $text){[IO.File]::WriteAllText($entry[0],$text,[Text.UTF8Encoding]::new($false))}
}
$env:PYTHONDONTWRITEBYTECODE='1'
$env:TEMP=Join-Path $root 'work/package_runtime';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
if(!$Quiet){Write-Host 'Package paths configured:' $root;Write-Host 'PDS:' $config.pds_root;Write-Host 'License:' $config.pds_license_file;Write-Host 'Bundled Python 3.12 / RISC-V / Icarus / MTF are used.'}
