#Requires -Version 7.4
<#
.SYNOPSIS
    Measures a collection of Exchange Log Report on logs written by New-ExlSyntheticLogs.ps1 (load test):
    same console table as -Mode Collect, then duration, rate, database size and peak memory.

.DESCRIPTION
    Writes a configuration for the simulated servers into -WorkPath (database, logs and reports there too),
    then runs the collection and the retention in this process, like -Mode Collect does after its access
    check (the access check is skipped: the simulated servers have no applicationHost.config).
    A second run on the same -WorkPath measures an incremental collection (only the new lines).

.PARAMETER LogPath
    Root folder given to New-ExlSyntheticLogs.ps1 (<LogPath>\<SERVER>\Exchange...). '{0}' is replaced by the
    server name, for logs generated on each server: '\\{0}\E$\ElrSim'.

.PARAMETER Server
    Simulated servers (default: the sub-folders of -LogPath).

.PARAMETER WorkPath
    Folder of the configuration, the database, the execution logs and the reports.

.PARAMETER Fresh
    Deletes the database of -WorkPath first (first collection: BackfillDays of logs).

.PARAMETER Report
    Also builds a report of this type afterwards (Usage or Detailed, last 7 days) and measures it.

.PARAMETER PageSize
    SQLite page size of the new database (test of the engine; the tool uses its default).

.PARAMETER Set
    Configuration values to change, as 'Section.Key=value' (PowerShell syntax): 'Collection.BackfillDays=14'.

.EXAMPLE
    .\tools\Measure-ExlCollection.ps1 -LogPath C:\ElrSim\prod -WorkPath C:\ElrSim\work -Fresh

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogPath,
    [string[]]$Server,
    [Parameter(Mandatory)][string]$WorkPath,
    [switch]$Fresh,
    [ValidateSet('Usage', 'Detailed')][string]$Report,
    [string[]]$Set,
    [ValidateSet(0, 4096, 8192, 16384, 32768, 65536)][int]$PageSize = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# "A,B" given as one value (pwsh -File): a list.
$Server = @($Server | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Set = @($Set | Where-Object { $_ })
[void][IO.Directory]::CreateDirectory($WorkPath)
$WorkPath = (Resolve-Path -LiteralPath $WorkPath).Path
if (-not $Server) {
    if ($LogPath -match '\{0\}') { throw '-Server is required when -LogPath contains {0}.' }
    $Server = @(Get-ChildItem -LiteralPath $LogPath -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Exchange') } | ForEach-Object Name)
    if (-not $Server) { throw "No simulated server in $LogPath (expected <LogPath>\<SERVER>\Exchange)." }
}

# ---- configuration: the delivered one, with the simulated servers and the work folder -------------------------
$text = [IO.File]::ReadAllText((Join-Path $root 'config\ExchangeLogReport.config.psd1'))
$blocks = foreach ($s in $Server) {
    $base = if ($LogPath -match '\{0\}') { $LogPath -f $s } else { $LogPath }
    "        @{{ Name = '{0}'; Role = 'Mailbox'; ExchangePath = '{1}\{0}\Exchange'; IisLogPath = '{1}\{0}\inetpub\logs\LogFiles' }}" -f $s, $base.TrimEnd('\')
}
$servers = "Servers = @(`r`n" + ($blocks -join "`r`n") + "`r`n    )"
$text = [regex]::Replace($text, '(?ms)^    Servers = @\(.*?^    \)', $servers.Replace('$', '$$'))
$text = $text.Replace("'.\data\ExchangeLogReport.sqlite'", "'$WorkPath\data\ExchangeLogReport.sqlite'").Replace("Path          = '.\logs'", "Path          = '$WorkPath\logs'").Replace("OutputPath            = '.\reports'", "OutputPath            = '$WorkPath\reports'")
$text = [regex]::Replace($text, '(?m)^(\s*StaleSourceHours\s*=\s*)\d+', '${1}0')
foreach ($pair in $Set) {
    if ($pair -notmatch '^(\w+)\.(\w+)=(.+)$') { throw "-Set '$pair': expected Section.Key=value." }
    $key = $Matches[2]; $value = $Matches[3]
    $pattern = "(?m)^(\s*$([regex]::Escape($key))\s*=\s*)[^#\r\n]*?(\s*(#.*)?)$"
    if (-not [regex]::IsMatch($text, $pattern)) { throw "-Set '$pair': key $key not found in the configuration." }
    $text = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + $value + $(if ($m.Groups[3].Success) { '   ' + $m.Groups[3].Value } else { '' }) }, 'None')
}
$configPath = Join-Path $WorkPath 'loadtest.config.psd1'
[IO.File]::WriteAllText($configPath, $text, [Text.UTF8Encoding]::new($true))
$database = Join-Path $WorkPath 'data\ExchangeLogReport.sqlite'
if ($Fresh) { foreach ($suffix in '', '-wal', '-shm', '.lock') { Remove-Item -LiteralPath ($database + $suffix) -Force -ErrorAction SilentlyContinue } }

# ---- collection, as -Mode Collect does it after the access check -----------------------------------------------
Import-Module (Join-Path $root 'ExchangeLogReport.psd1') -Force
$module = Get-Module ExchangeLogReport
$result = & $module {
    param($ConfigPath, $Root, $Report, $PageSize)
    $settings = Import-ExlConfiguration -Path $ConfigPath -Root $Root
    [void](Start-ExlLog -Directory $settings.Logging.Path -RetentionDays $settings.Logging.RetentionDays)
    Initialize-ExlEngine -Root $Root
    if ($PageSize) { [ExchangeLogReport.Store]::PageSize = $PageSize }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $store = Open-ExlStore -Settings $settings
    try {
        $run = $store.StartRun('Collect', [Environment]::MachineName, 'loadtest', $script:ToolVersion)
        Write-ExlStep 3 4 'Reading the new log lines' -Icon Download
        $collection = Invoke-ExlCollection -Store $store -Settings $settings -RunId $run -Servers $settings.Servers
        $collectSeconds = $clock.Elapsed.TotalSeconds
        $purge = Invoke-ExlRetention -Store $store -Settings $settings
        $store.EndRun($run, 'Completed', $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
        $total = $clock.Elapsed.TotalSeconds
        $reportSeconds = $null; $reportFolder = $null
        if ($Report) {
            $period = Resolve-ExlPeriod -Range Last7Days -Zone $settings.Zone
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $built = New-ExlReport -Store $store -Settings $settings -Period $period -ReportType $Report -IncludeRoutingDetails $settings.Report.IncludeRoutingDetails -IncludeSessionDetails $settings.Report.IncludeSessionDetails
            $reportSeconds = $watch.Elapsed.TotalSeconds
            $reportFolder = $built.Folder
        }
        [pscustomobject]@{
            Version = $script:ToolVersion; Files = $collection.Files; Bytes = $collection.Bytes; Lines = $collection.Lines; Kept = $collection.Kept; Stored = $collection.Stored
            CollectSeconds = $collectSeconds; TotalSeconds = $total; Statistics = $collection.Statistics; DatabaseBytes = $store.FileBytes; ReportSeconds = $reportSeconds; ReportFolder = $reportFolder
        }
    }
    finally { $store.Dispose(); Stop-ExlLog }
} $configPath $root $Report $PageSize

$mb = $result.Bytes / 1MB
Write-Host ''
Write-Host ('  Version {0}: {1:N0} files, {2:N0} MB, {3:N0} lines, {4:N0} kept' -f $result.Version, $result.Files, $mb, $result.Lines, $result.Kept)
Write-Host ('  Collection {0:N1} s ({1:N1} MB/s, {2:N0} lines/s), with retention {3:N1} s, database {4:N0} MB, peak memory {5:N0} MB' -f $result.CollectSeconds, ($mb / [Math]::Max(0.001, $result.CollectSeconds)), ($result.Lines / [Math]::Max(0.001, $result.CollectSeconds)), $result.TotalSeconds, ($result.DatabaseBytes / 1MB), ([Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64 / 1MB))
if ($result.Statistics) { Write-Host ('  Threads: ' + $result.Statistics) }
if ($Report) { Write-Host ('  {0} report: {1:N1} s ({2})' -f $Report, $result.ReportSeconds, $result.ReportFolder) }
$result
