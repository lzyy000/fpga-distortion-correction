$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$impl=Join-Path $root 'pnr_camera_r21_modes'
$env:TEMP=Join-Path $root 'work\r21'
$env:TMP=$env:TEMP
$env:PYTHONDONTWRITEBYTECODE='1'
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
$taskLicense=Get-PdsLicense
if($taskLicense){$env:PANGO_LICENSE_FILE=$taskLicense}
$statePath=Join-Path $root 'reports\r21_ghe_background_build.json'
$logPath=Join-Path $root 'reports\pds_r21_modes_build.log'
$errorPath=Join-Path $root 'reports\pds_r21_modes_build_stderr.log'
$started=Get-Date
$state=[ordered]@{status='starting';started=$started.ToString('o');worker_pid=$PID;project=(Join-Path $impl 'camera_1080p30_raw8.pds');log=$logPath;stderr=$errorPath;board_downloaded=$false;placement_seed_changed=$false}
function Save-State { $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8 }
try {
 New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
 Save-State
 $pds=Get-PdsTool 'pds_shell.exe'
 $taskArguments=@('-project',('"'+$state.project+'"'),'-run','gen_bit_stream','-work_dir',('"'+$impl+'"'),'-skip_actions','"report_power gen_netlist"')
 $build=Start-Process -FilePath $pds -ArgumentList $taskArguments -WorkingDirectory $impl -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $errorPath -PassThru
 $state.status='building';$state.pds_pid=$build.Id;Save-State
 $build.WaitForExit();$build.Refresh();$state.exit_code=$build.ExitCode
 $content=[IO.File]::ReadAllText($logPath)+[IO.File]::ReadAllText($errorPath)
 if($build.ExitCode -ne 0 -or $content -match '(?m)^E:|Program Error Out'){throw 'PDS build failed; inspect stdout and stderr logs'}
 if($content -notmatch 'Process "Generate Bitstream" done\.'){throw 'PDS did not report bitstream completion'}
 foreach($stage in @('compile','synthesize','device_map','place_route')){
  $item=Get-Item -LiteralPath (Join-Path $impl ($stage+'\run.log'))
  if($item.LastWriteTime -lt $started.AddSeconds(-2)){throw ('Stage was not rebuilt: '+$stage)}
 }
 $bit=Get-Item -LiteralPath (Join-Path $impl 'generate_bitstream\camera_1080p_top.sbit')
 if($bit.Length -lt 1000000 -or $bit.LastWriteTime -lt $started){throw 'Bitstream file is missing, too small, or stale'}
 $timing=Join-Path $impl 'report_timing\camera_1080p_top.rtr'
 $state.status='bitstream_generated';$state.bitstream=$bit.FullName;$state.bitstream_bytes=$bit.Length
 $state.bitstream_sha256=(Get-FileHash -LiteralPath $bit.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 $state.final_timing_pass=(Test-Path -LiteralPath $timing) -and ([IO.File]::ReadAllText($timing).Contains('Design Summary : All Constraints Met.'))
 $state.timing_report=$timing
} catch { $state.status='failed';$state.error=$_.Exception.Message }
finally { $state.completed=(Get-Date).ToString('o');Save-State }
