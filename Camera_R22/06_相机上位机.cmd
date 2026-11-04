@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_camera_console.ps1" %*
set "FPGA_EXIT_CODE=%errorlevel%"
if not "%FPGA_EXIT_CODE%"=="0" echo ERROR: exit code %FPGA_EXIT_CODE%.
if not "%FPGA_EXIT_CODE%"=="0" if not defined FPGA_NO_PAUSE pause
exit /b %FPGA_EXIT_CODE%
