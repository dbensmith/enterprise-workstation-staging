@echo off
setlocal
rem A parent PowerShell 7 session leaks its module paths; Windows PowerShell 5.1 rebuilds the default when this is empty.
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" %*
exit /b %ERRORLEVEL%
