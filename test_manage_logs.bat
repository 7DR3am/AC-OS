@echo off
setlocal
rem Run the five automatic Windows test cases.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_manage_logs_windows.ps1"
exit /b %ERRORLEVEL%
