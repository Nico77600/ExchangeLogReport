@echo off
setlocal
set POWERSHELL_TELEMETRY_OPTOUT=1
if not exist "%~dp0powershell\pwsh.exe" (
  echo The bundled PowerShell runtime is missing. Extract the complete package.
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0src\Test-PackageIntegrity.ps1" -Root "%~dp0." -Distribution
if errorlevel 1 (
  echo The package could not be verified. Read the message above.
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0Database-Storage.ps1" %*
exit /b %errorlevel%