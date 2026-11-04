& (Join-Path $PSScriptRoot 'configure_package.ps1') -Quiet
# Local paths are centralized in local_tools.json; FPGA_* variables can override them.
$script:LocalToolConfigPath=Join-Path $PSScriptRoot 'local_tools.json'
$script:LocalToolConfig=if(Test-Path -LiteralPath $script:LocalToolConfigPath){
    Get-Content -LiteralPath $script:LocalToolConfigPath -Raw | ConvertFrom-Json
}else{[pscustomobject]@{}}

function Get-LocalToolSetting {
    param([string]$EnvironmentName,[string]$SettingName)
    $value=[Environment]::GetEnvironmentVariable($EnvironmentName)
    if($value){return $value}
    $property=$script:LocalToolConfig.PSObject.Properties[$SettingName]
    if($property){return [string]$property.Value}
}

function Get-SharedTools {
    Get-LocalToolSetting 'FPGA_SHARED_TOOLS' 'shared_tools'
}

function Assert-PdsProjectPath {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $taskFullPath=[IO.Path]::GetFullPath($ProjectRoot)
    foreach($taskPart in ($taskFullPath -split '[\\/]+')){
        if(!$taskPart -or $taskPart -match '^[A-Za-z]:$'){continue}
        if($taskPart -match '[^0-9A-Za-z_\-~. @+#,=]' -or $taskPart.Trim() -cne $taskPart){
            throw ('PDS rejects this directory name: '+$taskPart+'. Use a project path without parentheses or Chinese characters, for example D:\pango\pango100Pro\Camera_R22_20261031.')
        }
    }
}

function Get-PdsRoot {
    $candidates=@((Get-LocalToolSetting 'FPGA_PDS_ROOT' 'pds_root'),
        'C:\pango\PDS_2022.2-SP6.4','D:\pango\PDS_2022.2-SP6.4')
    $command=Get-Command pds.exe -ErrorAction SilentlyContinue
    if($command){$candidates+=Split-Path (Split-Path $command.Source -Parent) -Parent}
    foreach($candidate in $candidates){
        if($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\pds.exe') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $candidate 'bin\pds_shell.exe') -PathType Leaf)){
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "PDS installation not found. Set pds_root in $script:LocalToolConfigPath or FPGA_PDS_ROOT."
}

function Get-PdsTool {
    param([Parameter(Mandatory=$true)][string]$Name)
    $path=Join-Path (Get-PdsRoot) ('bin\'+$Name)
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "PDS tool not found: $path"}
    return $path
}

function Get-PdsLicense {
    # Preserve Windows' existing license selection (including license servers).
    if($env:PANGO_LICENSE_FILE){return $env:PANGO_LICENSE_FILE}
    Get-LocalToolSetting 'FPGA_PDS_LICENSE_FILE' 'pds_license_file'
}

function Get-RiscvBin {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $shared=Get-SharedTools
    $candidates=@((Get-LocalToolSetting 'FPGA_RISCV_BIN' 'riscv_bin'),(Join-Path $ProjectRoot 'tools\riscv-gcc\bin'))
    if($shared){$candidates+=Join-Path $shared 'riscv-gcc\bin'}
    $command=Get-Command riscv-none-embed-gcc.exe -ErrorAction SilentlyContinue
    if($command){$candidates+=Split-Path $command.Source -Parent}
    foreach($bin in $candidates){
        if(!$bin){continue}
        $missing=@('gcc','objcopy','size','objdump') | Where-Object {
            !(Test-Path -LiteralPath (Join-Path $bin ('riscv-none-embed-'+$_+'.exe')) -PathType Leaf)
        }
        if(!$missing){return [IO.Path]::GetFullPath($bin)}
    }
    throw "Complete RISC-V GCC toolchain not found. Set shared_tools in $script:LocalToolConfigPath or FPGA_RISCV_BIN."
}

function Get-IverilogRoot {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $shared=Get-SharedTools
    $candidates=@((Get-LocalToolSetting 'FPGA_IVERILOG_ROOT' 'iverilog_root'),(Join-Path $ProjectRoot 'tools\iverilog'))
    if($shared){$candidates+=Join-Path $shared 'iverilog'}
    $command=Get-Command iverilog.exe -ErrorAction SilentlyContinue
    if($command){$candidates+=Split-Path (Split-Path $command.Source -Parent) -Parent}
    foreach($candidate in $candidates){
        if($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\iverilog.exe') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $candidate 'bin\vvp.exe') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $candidate 'lib\ivl') -PathType Container)){
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "Icarus Verilog not found. Set shared_tools in $script:LocalToolConfigPath or FPGA_IVERILOG_ROOT."
}

function Get-PythonExe {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $candidates=@((Get-LocalToolSetting 'FPGA_PYTHON' 'python_exe'),
        (Join-Path $ProjectRoot 'tools\python\python.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'))
    $command=Get-Command python.exe -ErrorAction SilentlyContinue
    if($command -and $command.Source -notmatch '\\WindowsApps\\'){$candidates+=$command.Source}
    foreach($candidate in ($candidates | Select-Object -Unique)){
        if(!$candidate -or !(Test-Path -LiteralPath $candidate -PathType Leaf)){continue}
        & $candidate -B -c "import sys,struct;sys.exit(0 if sys.version_info[:2]==(3,12) and struct.calcsize('P')==8 else 1)" 2>$null
        if($LASTEXITCODE -eq 0){return [IO.Path]::GetFullPath($candidate)}
    }
    throw "Python 3.12 x64 not found (required by shared NumPy packages). Set python_exe in $script:LocalToolConfigPath or FPGA_PYTHON."
}

function Initialize-PythonTools {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $packages=@(Join-Path $ProjectRoot 'tools\python_packages')
    $shared=Get-SharedTools
    if($shared){$packages+=Join-Path $shared 'python_packages'}
    $packages=@($packages | Where-Object {Test-Path -LiteralPath $_ -PathType Container})
    $env:PYTHONPATH=(@($packages)+@($env:PYTHONPATH -split ';' | Where-Object {$_}) | Select-Object -Unique) -join ';'
    # Serial measurement only needs Python packages; simulation/GCC are checked by 00/02/04.
    $env:FPGA_PDS_ROOT=Get-LocalToolSetting 'FPGA_PDS_ROOT' 'pds_root'
    $env:FPGA_SHARED_TOOLS=$shared
    $env:FPGA_IVERILOG_ROOT=Get-LocalToolSetting 'FPGA_IVERILOG_ROOT' 'iverilog_root'
    $env:PYTHONUTF8='1'
}
