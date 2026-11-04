@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_camera_r21_modes.ps1" %*
set "FPGA_EXIT_CODE=%errorlevel%"
if not "%FPGA_EXIT_CODE%"=="0" echo ERROR: exit code %FPGA_EXIT_CODE%.
if not defined FPGA_NO_PAUSE pause
exit /b %FPGA_EXIT_CODE%
