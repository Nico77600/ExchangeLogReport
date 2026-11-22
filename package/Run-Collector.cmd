@echo off
setlocal
set POWERSHELL_TELEMETRY_OPTOUT=1
set POWERSHELL_UPDATECHECK=Off
rem Server garbage collector with 4 heaps not tied to processors: fewer, shorter collections while the collector parses and writes large batches.
set DOTNET_gcServer=1
set DOTNET_GCHeapCount=4
set DOTNET_GCNoAffinitize=1
if not exist "%~dp0powershell\pwsh.exe" (
  echo The bundled PowerShell runtime is missing. Extract the complete package.
  exit /b 1
)
rem A scheduled task passes arguments: no prompt can be answered there, a prompt of PowerShell must fail instead of waiting forever.
set "unattended="
if not "%~1"=="" set "unattended= -NonInteractive"
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile%unattended% -File "%~dp0src\Test-PackageIntegrity.ps1" -Root "%~dp0." -Distribution -SuppressTrustWarning
rem A scheduled task must not wait; a double-click (no arguments) keeps the window open.
if not "%errorlevel%"=="0" (
  echo The package could not be verified. Read the message above.
  more < "%~dp0Invoke-ExchangeLogReport.ps1:Zone.Identifier" >nul 2>&1 && echo The files carry a download mark. Unblock them once, as administrator, before a task uses them: Get-ChildItem -LiteralPath "%~dp0." -Recurse -File -Force ^| Unblock-File
  if "%~1"=="" pause
  exit /b 1
)
if "%~1"=="" (
  "%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0Invoke-ExchangeLogReport.ps1" -Mode Status
) else (
  "%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0Invoke-ExchangeLogReport.ps1" %*
)
exit /b %errorlevel%