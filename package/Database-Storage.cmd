@echo off
setlocal
set POWERSHELL_TELEMETRY_OPTOUT=1
set POWERSHELL_UPDATECHECK=Off
if not exist "%~dp0powershell\pwsh.exe" (
  echo The bundled PowerShell runtime is missing. Extract the complete package.
  exit /b 1
)
rem Started with arguments (a script, a task): no prompt can be answered, a prompt of PowerShell must fail instead of waiting forever.
set "unattended="
if not "%~1"=="" set "unattended= -NonInteractive"
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile%unattended% -File "%~dp0src\Test-PackageIntegrity.ps1" -Root "%~dp0." -Distribution -SuppressTrustWarning
if not "%errorlevel%"=="0" (
  echo The package could not be verified. Read the message above.
  more < "%~dp0Database-Storage.ps1:Zone.Identifier" >nul 2>&1 && echo The files carry a download mark. Unblock them once, as administrator, before a task uses them: Get-ChildItem -LiteralPath "%~dp0." -Recurse -File -Force ^| Unblock-File
  exit /b 1
)
"%~dp0powershell\pwsh.exe" -NoLogo -NoProfile -File "%~dp0Database-Storage.ps1" %*
exit /b %errorlevel%