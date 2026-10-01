#Requires -Version 7.4
<#
.SYNOPSIS
    Exchange Log Report - usage and troubleshooting reports from the IIS / HTTP Proxy, SMTP
    protocol and message tracking logs of Exchange Server SE (on-premises).

.DESCRIPTION
    The tool works in two stages:

      1. COLLECT  Log files of every configured server -> local SQLite database.
                  Only the new part of each file is read. System mailboxes, health probes,
                  load balancer checks and other noise are removed BEFORE storage and
                  counted by reason. Schedule it (for example every hour): -Mode Collect.
      2. REPORT   SQLite database -> CSV + HTML files in a local folder.
                  Usage     : is each server really used, by whom, with which protocols,
                              clients, devices and operations (latency per operation).
                  Detailed  : + one row per client session with its timeline across the front-end
                              and back-end logs (Outlook MAPI, ActiveSync, OWA, EWS, IMAP, POP),
                              failed and slow requests (recovered or not), one row per message
                              with its route, SMTP sessions with their transcript.

    Everything is set in config\ExchangeLogReport.config.psd1. The tool only reads the
    Exchange logs: it never changes any Exchange setting and never sends anything.

.PARAMETER Mode
    Report  (default) Collects what is new, then writes the report.
    Collect           Collects what is new (scheduled task). No report.
    Status            Shows what the database contains. Reads no log file.
    Discover          Reads the real log folders of every Exchange server (Exchange cmdlets in Windows
                      PowerShell 5.1: local Exchange Management Shell or Exchange remote PowerShell,
                      View-Only Organization Management is enough) and the IIS log folder of every
                      Exchange web site, custom OWA/ECP sites included (virtual directories read from
                      applicationHost.config). Writes config\ExchangeLogReport.paths.psd1. Run it once
                      on the collector with an administrator account (SYSTEM has no Exchange role), and
                      again after a CU or a change of the log paths.
                      Every collection checks the IIS sites again and follows a moved IIS log folder.

.PARAMETER Range
    Period of the report. Default: Report.DefaultRange.
      Last24Hours, Last7Days, Last30Days : rolling windows ending now
      PreviousMonth                      : the previous calendar month
      Month  -Month 2026-09              : a calendar month
      Day    -Date 2026-09-28            : a calendar day
      Custom -Start '2026-09-01 08:00' -End '2026-09-01 12:00'

.PARAMETER ReportType
    Usage (default from the configuration) or Detailed.

.PARAMETER User
    One or more users (part of domain\sam, UPN or SMTP address). Filters every view; with
    -ReportType Detailed the successful requests kept for these users are shown as well.

.PARAMETER Server
    One or more servers of the configuration. Filters the report and, with -Mode Collect, the collection.

.PARAMETER IncludeRoutingDetails
    Overrides Report.IncludeRoutingDetails: message route and SMTP transcripts in the CSV files.

.PARAMETER IncludeSessionDetails
    Overrides Report.IncludeSessionDetails: timeline of each client session in the CSV files.

.PARAMETER NoCollect
    Report mode: use only the data already in the database.

.PARAMETER ConnectTo
    Discover mode: Exchange server used for remote PowerShell (http://<server>/PowerShell/, Kerberos).
    Default: the Exchange Management Shell of this computer if it is an Exchange server, else the
    first server of the configuration that answers.

.PARAMETER Credential
    Discover mode: account for remote PowerShell, when it is not the account running the tool.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode Discover -ConnectTo EXCH01
    Finds the real log folders of every Exchange server (moved logs, Exchange on another drive...).

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode Collect
    Scheduled collection.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range Last30Days
    Usage of every server over 30 days (which servers are really used).

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range Day -Date 2026-09-30 -ReportType Detailed -User alice@contoso.com
    Everything about one user on one day: requests, failures, messages and their route.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.4.0
    Exit codes : 0 = success, 1 = failure, 2 = finished with warnings (a server, a folder or a file could not
                 be read, a source is stale, or the IIS log folders changed since -Mode Discover).
    Documentation : docs\ExchangeLogReport-Guide.html (source: docs\ExchangeLogReport-Guide.md)
#>
[CmdletBinding()]
param(
    [ValidateSet('Report', 'Collect', 'Status', 'Discover')]
    [string]$Mode = 'Report',

    [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth', 'Month', 'Day', 'Custom')]
    [string]$Range,
    [string]$Month,
    [string]$Date,
    [string]$Start,
    [string]$End,

    [ValidateSet('Usage', 'Detailed')]
    [string]$ReportType,
    [string[]]$User,
    [string[]]$Server,
    [switch]$IncludeRoutingDetails,
    [switch]$IncludeSessionDetails,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\ExchangeLogReport.config.psd1'),
    [string]$OutputPath,
    [switch]$NoCollect,

    [string]$ConnectTo,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$clock = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
$runStatus = 'Failed'
$store = $null; $lock = $null; $runId = $null; $collection = $null

try {
    do {
        Import-Module (Join-Path $PSScriptRoot 'ExchangeLogReport.psd1') -Force

        # ---- configuration, then command-line overrides -------------------------------------------
        $settings = Import-ExlConfiguration -Path $ConfigPath -Root $PSScriptRoot
        if (-not $Range) { $Range = $settings.Report.DefaultRange }
        if (-not $ReportType) { $ReportType = $settings.Report.DefaultType }
        if ($PSBoundParameters.ContainsKey('IncludeRoutingDetails')) { $settings.Report.IncludeRoutingDetails = [bool]$IncludeRoutingDetails }
        if ($PSBoundParameters.ContainsKey('IncludeSessionDetails')) { $settings.Report.IncludeSessionDetails = [bool]$IncludeSessionDetails }
        if ($OutputPath) { $settings.Report.OutputPath = [IO.Path]::GetFullPath($OutputPath, (Get-Location).Path) }
        $servers = @($settings.Servers)
        if ($Server) {
            $unknown = @($Server | Where-Object { $_ -notin $servers.Name })
            if ($unknown.Count) { throw ("Unknown server(s): {0}. Servers of the configuration: {1}." -f ($unknown -join ', '), ($servers.Name -join ', ')) }
            $servers = @($servers | Where-Object { $_.Name -in $Server })
        }
        $zone = $settings.Zone

        $logPath = Start-ExlLog -Directory $settings.Logging.Path -RetentionDays $settings.Logging.RetentionDays
        $dot = [char]0x00B7

        # ---- discovery of the log paths (no database, no log file read) ------------------------------
        if ($Mode -eq 'Discover') {
            $banner = [ordered]@{}
            $banner['Mode'] = @('Info', 'Discover')
            $localExchange = [bool]$env:ExchangeInstallPath -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup')
            $banner['Exchange'] = @('Server', $(if ($ConnectTo) { "remote PowerShell on $ConnectTo" } elseif ($localExchange -and -not $Credential) { 'Exchange Management Shell of this server (Windows PowerShell 5.1)' } else { "remote PowerShell (Windows PowerShell 5.1) on the first of $($settings.Servers.Name -join ', ') that answers" }))
            $banner['Paths'] = @('File', $settings.PathsFile)
            $banner['Log'] = @('Log', $logPath)
            Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot discovery of the log folders" -Details $banner
            $found = Invoke-ExlDiscovery -Settings $settings -ConnectTo $ConnectTo -Credential $Credential
            $values = [ordered]@{}
            $values['Servers'] = @('Server', ("{0} mailbox server(s): {1}" -f $found.Found.Count, ($found.Found -join ', ')))
            if ($found.NotInConfig.Count) { $values['Add'] = @('Info', ("not in the configuration: " + (($found.NotInConfig | ForEach-Object { "@{ Name = '$_' }" }) -join ' '))) }
            if ($found.NotFound.Count) { $values['Unknown'] = @('Warn', ("in the configuration but not found in Exchange: " + ($found.NotFound -join ', '))) }
            $values['Warnings'] = @($(if ($found.Warnings.Count) { 'Warn' } else { 'Ok' }), $(if ($found.Warnings.Count) { "$($found.Warnings.Count) (see above and the log file)" } else { 'none' }))
            $values['File'] = @('File', $found.File)
            $values['Next'] = @('Info', '.\Invoke-ExchangeLogReport.ps1 -Mode Collect')
            Write-ExlSummary -Title 'Log paths discovered' -Values $values -Status $(if ($found.Warnings.Count -or $found.NotFound.Count) { 'Warn' } else { 'Ok' })
            $exitCode = 0; $runStatus = 'Completed'
            break
        }
        Initialize-ExlEngine -Root $PSScriptRoot

        $collecting = $Mode -eq 'Collect' -or ($Mode -eq 'Report' -and -not $NoCollect)
        $totalSteps = switch ($Mode) { 'Status' { 2 } 'Collect' { 4 } default { if ($collecting) { 5 } else { 2 } } }
        $period = if ($Mode -eq 'Report') { Resolve-ExlPeriod -Range $Range -Month $Month -Date $Date -Start $Start -End $End -Zone $zone }
        $banner = [ordered]@{}
        $banner['Mode'] = @('Info', $Mode + $(if ($period) { " $dot $ReportType $dot $Range" } else { '' }))
        if ($period) { $banner['Period'] = @('Calendar', "$(Format-ExlRange $period.StartMs $period.EndMs $zone)  ($($settings.Report.TimeZone), end excluded)") }
        $banner['Servers'] = @('Server', ($servers.Name -join ', '))
        if ($User) { $banner['Users'] = @('People', ($User -join ', ')) }
        $banner['Database'] = @('Database', $settings.Storage.DatabasePath)
        $banner['Paths'] = @('Folder', $(if ($settings.Discovery) { "found by -Mode Discover on $($settings.Discovery.When.Substring(0, [Math]::Min(16, $settings.Discovery.When.Length)).Replace('T', ' '))" } else { 'default folders (run -Mode Discover to check them)' }))
        $banner['Log'] = @('Log', $logPath)
        Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot usage and troubleshooting from the server logs" -Details $banner
        if ($settings.Discovery -and $settings.Discovery.Collector -and $settings.Discovery.Collector -ne [Environment]::MachineName.ToUpperInvariant()) {
            Write-ExlItem Warn "The paths file was written on $($settings.Discovery.Collector): run -Mode Discover on this computer."
        }

        # ---- step 1: database ------------------------------------------------------------------------
        $step = 1
        Write-ExlStep $step $totalSteps 'Opening the database' -Icon Database
        if (-not $collecting -and -not (Test-Path -LiteralPath $settings.Storage.DatabasePath)) {
            Write-ExlItem Info 'No database yet: the first collection (-Mode Collect) creates it.'
            Write-ExlSummary -Title 'Ready for the first collection' -Values ([ordered]@{
                    Config  = @('Ok', "valid $dot $($settings.Servers.Count) server(s)")
                    Engine  = @('Ok', 'ready')
                    Next    = @('Info', '.\Invoke-ExchangeLogReport.ps1 -Mode Collect')
                }) -Status Ok
            $exitCode = 0; $runStatus = 'Completed'
            break
        }
        if ($collecting) { $lock = Enter-ExlLock -Path ($settings.Storage.DatabasePath + '.lock') }
        $store = Open-ExlStore -Settings $settings -ReadOnly:(-not $collecting)
        if ($collecting) {
            $closed = $store.CloseAbandonedRuns()
            if ($closed) { Write-ExlItem Warn "$closed earlier execution(s) had been interrupted; their files resume where they stopped." }
            $runId = $store.StartRun($Mode, [Environment]::MachineName, [Environment]::UserDomainName + '\' + [Environment]::UserName, (Get-Module ExchangeLogReport).Version.ToString(3))
        }
        Write-ExlItem Ok ("{0} {1} {2}" -f $settings.Storage.DatabasePath, $dot, (Format-ExlBytes $store.FileBytes))

        if ($Mode -eq 'Status') {
            Write-ExlStep 2 $totalSteps 'Collected data' -Icon Chart
            Show-ExlStatus -Store $store -Settings $settings
            $exitCode = 0; $runStatus = 'Completed'
            break
        }

        # ---- steps 2-3: access check and collection ---------------------------------------------------------
        $incomplete = $false
        if ($collecting) {
            $step++
            Write-ExlStep $step $totalSteps 'Checking access to the servers and their IIS log folders' -Icon Server
            $here = [Environment]::MachineName.ToUpperInvariant()
            foreach ($s in $servers) {
                # The IIS settings are read at every collection: a log folder moved since -Mode Discover is followed.
                $notes = @(Test-ExlIisSites -Server $s -Local:($s.Name -eq $here))
                foreach ($n in $notes) { Write-ExlItem $n.Status "$($s.Name): $($n.Text)" }
                if (@($notes | Where-Object { $_.Drift -or $_.Status -eq 'Warn' }).Count) { $incomplete = $true }
                $problems = @(Test-ExlServerAccess -Server $s -Settings $settings)
                if ($problems.Count) { foreach ($p in $problems) { Write-ExlItem Warn "$($s.Name): $p" }; $incomplete = $true }
                else { Write-ExlItem Ok "$($s.Name): log folders readable ($(Get-ExlPathOrigin $s))" }
            }
            $step++
            Write-ExlStep $step $totalSteps 'Reading the new log lines' -Icon Download
            $collection = Invoke-ExlCollection -Store $store -Settings $settings -RunId $runId -Servers $servers
            if ($collection.Errors -or $collection.Unreachable.Count -or $collection.Stale.Count) { $incomplete = $true }
            foreach ($s in $collection.Stale) { Write-ExlItem Warn "$s. Logging stopped, or the logs were moved: run -Mode Discover." }
            $noisePercent = if ($collection.Lines) { 100.0 * $collection.Noise / $collection.Lines } else { 0 }
            Write-ExlItem Ok ("{0} files {5} {1} read {5} {2} lines {5} {3} kept {5} noise removed {4:0.0}%" -f (Format-ExlNumber $collection.Files), (Format-ExlBytes $collection.Bytes),
                (Format-ExlNumber $collection.Lines), (Format-ExlNumber $collection.Kept), $noisePercent, $dot)
            if ($collection.Recovered) { Write-ExlItem Info ("{0} failed request(s) followed by a success of the same user: marked as recovered." -f (Format-ExlNumber $collection.Recovered)) }
            $top = @($collection.NoiseReasons.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
            if ($top.Count) { Write-ExlItem Info ('Main noise: ' + (($top | ForEach-Object { '{0} ({1})' -f $_.Key, (Format-ExlNumber $_.Value) }) -join ', ')) -Icon Filter }
            $step++
            Write-ExlStep $step $totalSteps 'Retention and maintenance' -Icon Broom
            $purge = Invoke-ExlRetention -Store $store -Settings $settings
            Write-ExlItem Ok ("Retention {0} days (details {1} days): {2} row(s) deleted {4} database {3}" -f $settings.Storage.RetentionDays, $settings.Storage.DetailRetentionDays, (Format-ExlNumber ($purge.Total)), (Format-ExlBytes $store.FileBytes), $dot)
        }

        if ($Mode -eq 'Collect') {
            $store.EndRun($runId, $(if ($incomplete) { 'Incomplete' } else { 'Completed' }), $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
            $runId = $null
            Write-ExlSummary -Title $(if ($incomplete) { 'Collection finished with warnings' } else { 'Collection complete' }) -Values ([ordered]@{
                    Servers  = @('Server', ($servers.Name -join ', '))
                    Read     = @('Download', ("{0} in {1} files" -f (Format-ExlBytes $collection.Bytes), (Format-ExlNumber $collection.Files)))
                    Kept     = @('Ok', ("{0} lines of real activity {1} {2} noise lines removed" -f (Format-ExlNumber $collection.Kept), $dot, (Format-ExlNumber $collection.Noise)))
                    Database = @('Database', (Format-ExlBytes $store.FileBytes))
                    Duration = @('Clock', (Format-ExlDuration $clock.Elapsed.TotalSeconds))
                }) -Status $(if ($incomplete) { 'Warn' } else { 'Ok' })
            $exitCode = if ($incomplete) { 2 } else { 0 }
            $runStatus = 'Completed'
            break
        }

        # ---- last step: report ------------------------------------------------------------------------
        $step++
        Write-ExlStep $step $totalSteps "Building the $($ReportType.ToLowerInvariant()) report" -Icon Report
        $report = New-ExlReport -Store $store -Settings $settings -Period $period -ReportType $ReportType -User $User -Server $Server -IncludeRoutingDetails $settings.Report.IncludeRoutingDetails -IncludeSessionDetails $settings.Report.IncludeSessionDetails
        foreach ($f in $report.Files) { Write-ExlItem Ok ("{0}  {1} rows {2} {3}" -f (Split-Path $f.Path -Leaf), (Format-ExlNumber $f.Rows), $dot, (Format-ExlBytes $f.Bytes)) -Icon File }
        if ($runId) {
            $store.EndRun($runId, $(if ($incomplete) { 'Incomplete' } else { 'Completed' }), $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
            $runId = $null
        }
        $c = $report.Counts
        $values = [ordered]@{}
        $values['Period'] = @('Calendar', (Format-ExlRange $period.StartMs $period.EndMs $zone))
        $values['Servers'] = @('Server', ("{0} in the report" -f (Format-ExlNumber $c['servers'])))
        $values['Users'] = @('People', ("{0} real user(s)" -f (Format-ExlNumber $c['users'])))
        if ($ReportType -eq 'Detailed') {
            $values['Sessions'] = @('People', ("{0} client session(s) {1} {2} with failures" -f (Format-ExlNumber $c['sessions']), $dot, (Format-ExlNumber $c['sessionsWithFailures'])))
            $values['Issues'] = @('Warn', ("{0} failed or slow request(s) kept" -f (Format-ExlNumber $c['issues'])))
            $values['Messages'] = @('Mail', ("{0} message(s) {1} {2} SMTP transaction(s) from {3} SMTP client(s)" -f (Format-ExlNumber $c['messages']), $dot, (Format-ExlNumber $c['smtp']), (Format-ExlNumber $c['smtpclients'])))
        }
        $values['Folder'] = @('Folder', $report.Folder)
        if ($report.HtmlPath) { $values['Open'] = @('Report', $report.HtmlPath) }
        $values['Duration'] = @('Clock', (Format-ExlDuration $clock.Elapsed.TotalSeconds))
        Write-ExlSummary -Title $(if ($incomplete) { 'Report ready (collection incomplete)' } else { 'Report ready' }) -Values $values -Status $(if ($incomplete) { 'Warn' } else { 'Ok' })
        $exitCode = if ($incomplete) { 2 } else { 0 }
        $runStatus = 'Completed'
    } while ($false)
}
catch {
    $message = $_.Exception.Message
    Write-Host ''
    Write-Host ("  ERROR: {0}" -f $message) -ForegroundColor Red
    try { Write-ExlLog 'ERROR' ($message + [Environment]::NewLine + $_.ScriptStackTrace) } catch { }
    if ($runId -and $store) { try { $store.EndRun($runId, 'Failed', 0, 0, 0, 0, 0, $message) } catch { } }
    $exitCode = 1
}
finally {
    if ($store) { $store.Dispose() }
    if ($lock) { Exit-ExlLock $lock }
    try { Write-ExlLog 'INFO' ("End: {0}, exit code {1}, {2:0.0} s" -f $runStatus, $exitCode, $clock.Elapsed.TotalSeconds); Stop-ExlLog } catch { }
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
}
exit $exitCode
