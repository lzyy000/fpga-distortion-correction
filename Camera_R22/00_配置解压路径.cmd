@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\configure_package.ps1" -DetectComputer %*
set "FPGA_EXIT_CODE=%errorlevel%"
if not "%FPGA_EXIT_CODE%"=="0" echo ERROR: exit code %FPGA_EXIT_CODE%.
if not defined FPGA_NO_PAUSE pause
exit /b %FPGA_EXIT_CODE%
