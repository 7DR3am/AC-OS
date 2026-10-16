@echo off
setlocal
rem Windows entry point. File operations are implemented in the adjacent PowerShell helper.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage_logs_windows.ps1" %*
exit /b %ERRORLEVEL%
