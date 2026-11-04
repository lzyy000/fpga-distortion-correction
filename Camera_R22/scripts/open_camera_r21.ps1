param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:TEMP=Join-Path $root 'work\r21'
$env:TMP=$env:TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Assert-PdsProjectPath $root
$taskPdsTool=Get-PdsTool 'pds.exe'
$taskLicense=Get-PdsLicense
if($taskLicense){
 $env:PANGO_LICENSE_FILE=$taskLicense
}
$project=Join-Path $root 'pnr_camera_r21_modes\camera_1080p30_raw8.pds'
if(!(Test-Path -LiteralPath $project)){throw 'R22 integrated project missing'}
Write-Host 'R22 EIS: six independent host modes, calibrated WT901 axes, full-resolution EIS snapshots.'
Write-Host 'Source migration only; existing R21 bitstream/timing is stale. Rebuild before downloading.'
Write-Host 'To rebuild: right-click Generate Bitstream -> Rerun All (Compile through bitstream).'
Write-Host 'Opening this project does not start a build.'
Write-Host $project
Write-Host ('PDS: '+$taskPdsTool)
# PDS stores PID, process name and computer name in <project>.lock.
# Keep active, remote, malformed or inaccessible locks. Recover a local orphan
# only after checking all PDS processes and obtaining exclusive access to it.
$taskLockPath=$project+'.lock'
if(Test-Path -LiteralPath $taskLockPath -PathType Leaf){
 $taskPdsProcesses=@(Get-CimInstance Win32_Process -Filter "Name='pds.exe' OR Name='pds_shell.exe'" -ErrorAction Stop)
 if($taskPdsProcesses.Count -gt 0){
  Write-Host ('PDS or a PDS build is running (PID {0}). Project lock retained.' -f (($taskPdsProcesses.ProcessId | Sort-Object) -join ', '))
  Write-Host 'No second instance was started. Close the existing PDS session or wait for its build to finish.'
  return
 }
 try {$taskLockText=[IO.File]::ReadAllText($taskLockPath)} catch {
  Write-Warning ('Project lock is inaccessible or held open; retained: '+$taskLockPath)
  Write-Host 'No second instance was started.'
  return
 }
 $taskLockLines=@($taskLockText -split '\r?\n')
 $taskOwnerId=0
 $taskLocalHost=[Environment]::MachineName
 $taskValidLock=$taskLockLines.Count -ge 3 -and
  [int]::TryParse($taskLockLines[0],[ref]$taskOwnerId) -and $taskOwnerId -gt 0 -and
  $taskLockLines[1].Trim() -ieq 'pds' -and
  $taskLockLines[2].Trim() -ieq $taskLocalHost
 if(!$taskValidLock){
  Write-Warning ('Unrecognized or remote project lock retained: '+$taskLockPath)
  Write-Host 'No second instance was started. Check the lock owner before removing it.'
  return
 }
 if($CheckOnly){
  Write-Host ('Stale local project lock detected (old PID {0}); a normal launch will recover it.' -f $taskOwnerId)
 }else{
  $taskLockGuard=[IO.File]::Open($taskLockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try {
   $taskLockReader=[IO.StreamReader]::new($taskLockGuard,[Text.Encoding]::UTF8,$true,1024,$true)
   try {$taskLockedText=$taskLockReader.ReadToEnd()} finally {$taskLockReader.Dispose()}
   if($taskLockedText -cne $taskLockText){throw 'Project lock changed; launch cancelled'}
   $taskPdsProcesses=@(Get-CimInstance Win32_Process -Filter "Name='pds.exe' OR Name='pds_shell.exe'" -ErrorAction Stop)
   if($taskPdsProcesses.Count -gt 0){throw 'PDS started during lock recovery; launch cancelled'}
  } finally {$taskLockGuard.Dispose()}
  if([IO.File]::ReadAllText($taskLockPath) -cne $taskLockText){throw 'Project lock changed; launch cancelled'}
  Remove-Item -LiteralPath $taskLockPath -ErrorAction Stop
  Write-Host ('Removed stale local project lock (old PID {0}).' -f $taskOwnerId)
 }
}
# Restore the current source entry if an older open PDS window saved its cached
# project list on exit. Only edit after the lock check; never touch a live PDS.
$taskGheEntry='(_file "../rtl/camera_ghe_r21.v"'
$taskProjectText=[IO.File]::ReadAllText($project)
if(!$taskProjectText.Contains($taskGheEntry)){
 if($CheckOnly){throw 'GHE source entry missing. Close PDS and rerun this launcher without -CheckOnly to refresh it.'}
 $taskGheMarker='                (_file "../rtl/camera_night_hdmi_r21.v"'
 if(!$taskProjectText.Contains($taskGheMarker)){throw 'Cannot locate the R21 source list'}
 $taskGheTimestamp=(Get-Item -LiteralPath (Join-Path $root 'rtl\camera_ghe_r21.v')).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
 $taskGheBlock="                (_file `"../rtl/camera_ghe_r21.v`"`n                    (_format verilog)`n                    (_timespec `"$taskGheTimestamp`")`n                )`n"
 [IO.File]::WriteAllText($project,$taskProjectText.Replace($taskGheMarker,$taskGheBlock+$taskGheMarker),[Text.UTF8Encoding]::new($false))
}
# Recover R22 entries if an old PDS session saved its cached pre-migration list.
$taskProjectText=[IO.File]::ReadAllText($project)
$taskEisSources=@('camera_eis_serial_r22.v','camera_eis_jobs_r22.v','camera_eis_manager_r22.v','camera_eis_remap_r22.v','dynamic_map.v','dynamic_mul32.v','dynamic_divide.v','eis_quad_cache.v','image_cpu_r22.v','simpleuart_r22.v','uart_tx_buffered.v','camera_capture_eis_r22.v','camera_snapshot_eis_r22.v','camera_view_reader_eis_r22.v','camera_night_hdmi_eis_r22.v')
foreach($taskSource in $taskEisSources){
 $taskEntry='(_file "../rtl/'+$taskSource+'"'
 if(!$taskProjectText.Contains($taskEntry)){
  if($CheckOnly){throw ('R22 source missing; close old PDS and reopen with 27 launcher: '+$taskSource)}
  $taskMarker='                (_file "../rtl/camera_rgmii_rx_align.v"'
  if(!$taskProjectText.Contains($taskMarker)){throw 'Cannot locate source insertion marker'}
  $taskStamp=(Get-Item -LiteralPath (Join-Path $root ('rtl/'+$taskSource))).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
  $taskBlock="                (_file `"../rtl/$taskSource`"`n                    (_format verilog)`n                    (_timespec `"$taskStamp`")`n                )`n"
  $taskProjectText=$taskProjectText.Replace($taskMarker,$taskBlock+$taskMarker)
  [IO.File]::WriteAllText($project,$taskProjectText,[Text.UTF8Encoding]::new($false))
 }
}
# PDS requires _format followed by _timespec, including + "top" entries.
$taskProjectText=[IO.File]::ReadAllText($project)
$taskFileEntries=[regex]::Matches($taskProjectText,'(?s)\(_file\s+"([^"]+)"(?:\s*\+\s*"[^"]+")?\s*\(_format\s+[^)]+\)\s*([^\r\n]*)')
if($taskFileEntries.Count -ne [regex]::Matches($taskProjectText,'\(_file\s+"').Count){throw 'Invalid PDS source metadata (_format missing or malformed)'}
foreach($taskEntry in $taskFileEntries){
 if(!$taskEntry.Groups[2].Value.TrimStart().StartsWith('(_timespec ')){
  throw ('Invalid PDS source metadata (_timespec missing): '+$taskEntry.Groups[1].Value)
 }
}
if(!$CheckOnly){
 Start-Process -FilePath $taskPdsTool -ArgumentList ('"'+$project+'"') -WorkingDirectory (Split-Path $project -Parent) -WindowStyle Normal
}
