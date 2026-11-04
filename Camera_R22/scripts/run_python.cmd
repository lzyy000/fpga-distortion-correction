@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_python.ps1" %*
exit /b %errorlevel%
