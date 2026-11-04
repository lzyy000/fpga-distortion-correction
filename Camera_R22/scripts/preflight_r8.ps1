$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'local_tool_paths.ps1')
Assert-PdsProjectPath $root
Write-Host 'R22 PC preflight; read-only tool/project checks'
foreach($name in @('pds.exe','pds_shell.exe')){Write-Host ('PASS PDS '+(Get-PdsTool $name))}
$taskLicense=Get-PdsLicense
if(!$taskLicense){throw 'PDS license is not configured (PANGO_LICENSE_FILE or local_tools.json)'}
if($taskLicense -notmatch '@' -and !(Test-Path -LiteralPath $taskLicense -PathType Leaf)){throw ('PDS license file missing: '+$taskLicense)}
Write-Host ('PASS license selection '+$taskLicense+' (license checkout is checked by PDS during a real build)')
$gccBin=Get-RiscvBin $root
Write-Host ('PASS GCC '+$gccBin)
$taskGccVersion=& (Join-Path $gccBin 'riscv-none-embed-gcc.exe') --version
if($LASTEXITCODE -ne 0){throw 'RISC-V GCC cannot run'}
$taskGccVersion | Select-Object -First 1
Write-Host ('PASS Icarus '+(Get-IverilogRoot $root))
$sdk=Join-Path (Get-PdsRoot) 'arch\vendor\pango\verilog\simulation\GTP_IOCLKDIV_E2.v'
if(!(Test-Path -LiteralPath $sdk -PathType Leaf)){throw "Missing SDK model: $sdk"}
Write-Host ('PASS SDK '+$sdk)
Write-Host ('PASS Python '+(Get-PythonExe $root))
foreach($file in @('pnr_camera_r21_modes/camera_1080p30_raw8.pds','pnr_camera_r21_modes/camera_1080p_top.fdc','rtl/camera_raw8_rgb.v','rtl/camera_capture_eis_r22.v','night/firmware/camera_r22_main.c','rtl/camera_eis_remap_r22.v')){
 if(!(Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)){throw "Missing $file"}
 Write-Host "PASS $file"
}
& (Join-Path $PSScriptRoot 'run_python.cmd') (Join-Path $root 'host/preflight.py')
if($LASTEXITCODE -ne 0){throw 'Python/serial dependency failed'}
& (Join-Path $PSScriptRoot 'run_python.cmd') -c 'import numpy,cv2,tkinter;from PIL import Image;print(numpy.__version__,cv2.__version__,tkinter.TkVersion,Image.__version__)'
if($LASTEXITCODE -ne 0){throw 'Host image/UI dependency failed'}
Write-Host 'PASS PC preflight; actual image/frame rate requires board verification'
