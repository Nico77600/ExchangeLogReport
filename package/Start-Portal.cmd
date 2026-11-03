@echo off
setlocal
set POWERSHELL_TELEMETRY_OPTOUT=1
if not exist "%~dp0powershell\pwsh.exe" (
  echo The portable PowerShell runtime is missing. Extract the complete package before starting it.
  pause
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0src\Test-PackageIntegrity.ps1" -Root "%~dp0." -Distribution
if errorlevel 1 (
  echo The package could not be verified. Read the message above.
  pause
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0Invoke-ExchangeLogReport.ps1" -Mode Serve %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%