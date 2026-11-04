@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
call "%~dp0scripts\run_python.cmd" "%~dp0host\measure_camera_r21.py" --seconds 60 %*
set "FPGA_EXIT_CODE=%errorlevel%"
if not "%FPGA_EXIT_CODE%"=="0" echo ERROR: exit code %FPGA_EXIT_CODE%.
if not defined FPGA_NO_PAUSE pause
exit /b %FPGA_EXIT_CODE%
