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
                  counted by reason. Schedule it every hour: -Mode Collect. The first
                  collection reads the last Collection.BackfillDays days.
      2. REPORT   SQLite database -> CSV + HTML files in a local folder, in seconds or minutes.
                  The report reads the new log lines first only when the last collection is
                  older than Report.MaxDataAgeMinutes (90 min) and does not cover the period.
                  Usage     : is each server really used, by whom, with which protocols,
                              clients, devices and operations (latency per operation).
                  Detailed  : + one row per client session with its timeline across the front-end
                              and back-end logs (Outlook MAPI, ActiveSync, OWA, EWS, IMAP, POP),
                              failed and slow requests (recovered or not), one row per message
                              with its route, SMTP sessions with their transcript.

    Everything is set in config\ExchangeLogReport.config.psd1. The tool only reads the
    Exchange logs: it never changes any Exchange setting and never sends anything.

    Edge Transport servers (detected, or Role = 'Edge' in the Servers block): only their SMTP
    protocol logs and message tracking are read, without IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4.
    Run the tool on the Edge itself (SYSTEM or a local administrator).

.PARAMETER Mode
    Report  (default) Writes the report from the database. When the last collection is older than
                      Report.MaxDataAgeMinutes (90 min) and the period ends after it, the lines written since
                      are read first. No collection yet: the report stops (run -Mode Collect first).
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
                      On an Edge Transport server: its local Exchange Management Shell (SYSTEM is
                      accepted), SMTP log folders and message tracking only.
    MailTest          Checks the Mail section of the configuration: connects to the SMTP server, shows the
                      conversation (TLS, certificate, authentication) and sends a test message. With
                      -Credential, first saves the account of the SMTP server to Mail.CredentialFile (Basic
                      authentication, or Kerberos with another account), protected by DPAPI.

.PARAMETER Range
    Period of the report (-Mode Report). Default: Report.DefaultRange.
      Last24Hours, Last7Days, Last30Days : rolling windows ending now
      PreviousMonth                      : the previous calendar month
      Month  -Month 2026-09              : a calendar month
      Day    -Date 2026-09-28            : a calendar day
      Custom -Start '2026-09-01 08:00' -End '2026-09-01 12:00'
    -Month, -Date and -Start / -End select their range on their own: -Range can be left out. They cannot be
    combined with each other (parameter sets) nor with another -Range (error). A collection, -Mode Status and
    -Mode Discover do not use a period: a period given with them is reported as ignored, with the reason.

.PARAMETER Month
    Calendar month of the report, yyyy-MM (-Range Month).

.PARAMETER Date
    Calendar day of the report, yyyy-MM-dd (-Range Day).

.PARAMETER Start
    Start of a custom period, included (-Range Custom, with -End): yyyy-MM-dd or 'yyyy-MM-dd HH:mm' in the
    time zone of the report (Report.TimeZone), or an ISO 8601 value with an offset.

.PARAMETER End
    End of a custom period, excluded (-Range Custom, with -Start). Same formats as -Start; a time later
    than now is replaced by now.

.PARAMETER ReportType
    Usage (default from the configuration) or Detailed. When every server of the report is an Edge
    Transport server, the report is an Edge report: mail flow only (messages, SMTP clients, SMTP destinations).

.PARAMETER User
    One or more users (part of domain\sam, UPN or SMTP address). Filters every view; with
    -ReportType Detailed the successful requests kept for these users are shown as well.

.PARAMETER Server
    One or more servers of the configuration. Filters the report and, with -Mode Collect, the collection.

.PARAMETER IncludeRoutingDetails
    Overrides Report.IncludeRoutingDetails: message route and SMTP transcripts in the CSV files.

.PARAMETER IncludeSessionDetails
    Overrides Report.IncludeSessionDetails: timeline of each client session in the CSV files.

.PARAMETER Collect
    Report mode: reads the new log lines first, whatever the age of the data (the first collection reads the last
    Collection.BackfillDays days).

.PARAMETER NoCollect
    Report mode: uses only the data already in the database, whatever its age.

.PARAMETER SendMail
    Report mode: sends the report by e-mail (Mail section of the configuration), or with -SendMail:$false does not,
    whatever Mail.Enabled says.

.PARAMETER ConnectTo
    Discover mode: Exchange server used for remote PowerShell (http://<server>/PowerShell/, Kerberos).
    Default: the Exchange Management Shell of this computer if it is an Exchange server, else the
    first server of the configuration that answers.

.PARAMETER Credential
    Discover mode: account for remote PowerShell, when it is not the account running the tool.
    MailTest mode: account of the SMTP server, saved to Mail.CredentialFile (DPAPI) for the reports sent later.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode Discover -ConnectTo EXCH01
    Finds the real log folders of every Exchange server (moved logs, Exchange on another drive...).

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode Collect
    Scheduled collection, every hour. The first one reads the last Collection.BackfillDays days.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range Last30Days
    Usage of every server over 30 days (which servers are really used).

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range Day -Date 2026-09-30 -ReportType Detailed -User alice@contoso.com
    Everything about one user on one day: requests, failures, messages and their route.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -ReportType Detailed -NoCollect
    An incident window (custom period, -Range Custom is implied) from the data already collected.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode MailTest
    Checks the Mail section: TLS, authentication and a test message to Mail.To.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range PreviousMonth -SendMail
    Usage report of the previous month, sent by e-mail (monthly scheduled task).

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
    Exit codes : 0 = success, 1 = failure, 2 = finished with warnings (a server, a folder or a file could not
                 be read, a source is stale, the IIS log folders changed since -Mode Discover, or the report
                 could not be sent by e-mail).
    Documentation : docs\ExchangeLogReport-UserGuide.html (user guide: prerequisites, everyday commands) and
                    docs\ExchangeLogReport-Guide.html (developer guide); sources: docs\*.md
#>
[CmdletBinding(DefaultParameterSetName = 'Range')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Report', 'Collect', 'Status', 'Discover', 'MailTest')]
    [string]$Mode = 'Report',

    # Period of the report: one parameter set per kind of period, so that a period parameter is never ignored.
    [Parameter(ParameterSetName = 'Range', Position = 1)]
    [Parameter(ParameterSetName = 'Month', Position = 1)]
    [Parameter(ParameterSetName = 'Day', Position = 1)]
    [Parameter(ParameterSetName = 'Custom', Position = 1)]
    [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth', 'Month', 'Day', 'Custom')]
    [string]$Range,
    [Parameter(ParameterSetName = 'Month', Mandatory)]
    [string]$Month,
    [Parameter(ParameterSetName = 'Day', Mandatory)]
    [string]$Date,
    [Parameter(ParameterSetName = 'Custom', Mandatory)]
    [string]$Start,
    [Parameter(ParameterSetName = 'Custom', Mandatory)]
    [string]$End,

    [ValidateSet('Usage', 'Detailed')]
    [string]$ReportType,
    [string[]]$User,
    [string[]]$Server,
    [switch]$IncludeRoutingDetails,
    [switch]$IncludeSessionDetails,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\ExchangeLogReport.config.psd1'),
    [string]$OutputPath,
    [switch]$Collect,
    [switch]$NoCollect,
    [switch]$SendMail,

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
        # -Start / -End, -Month and -Date select their range on their own; with another -Range they are an error.
        if ($Mode -eq 'Report') { $Range = Resolve-ExlRange -Range $Range -Month $Month -Date $Date -Start $Start -End $End -Default $settings.Report.DefaultRange }
        # Parameters that this mode does not use: shown after the banner with the reason, never ignored silently.
        $ignored = @(Get-ExlIgnoredParameter -Mode $Mode -Name @($PSBoundParameters.Keys))
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

        # ---- test of the e-mail settings (no database, no log file read) ------------------------------
        if ($Mode -eq 'MailTest') {
            $m = $settings.Mail
            $banner = [ordered]@{}
            $banner['Mode'] = @('Info', 'MailTest')
            $banner['Server'] = @('Mail', ("{0}:{1} {2} encryption {3} {2} authentication {4}" -f $m.SmtpServer, $m.Port, $dot, $m.Encryption, $m.Authentication))
            $banner['From'] = @('People', $m.From)
            $banner['To'] = @('People', (@($m.To) + @($m.Cc | ForEach-Object { "$_ (Cc)" }) -join ', '))
            $banner['Log'] = @('Log', $logPath)
            Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot test of the e-mail settings" -Details $banner
            foreach ($n in $ignored) { Write-ExlItem Warn $n }
            $problems = @(Test-ExlMailReady -Settings $settings)
            if ($problems.Count) { throw ('The Mail section of the configuration is not complete: ' + ($problems -join ' ')) }
            Initialize-ExlEngine -Root $PSScriptRoot
            $total = if ($Credential) { 2 } else { 1 }
            $step = 0
            if ($Credential) {
                $step++
                Write-ExlStep $step $total 'Saving the account of the SMTP server' -Icon File
                Save-ExlMailCredential -Settings $settings -Credential $Credential
                $who = if ($m.CredentialScope -eq 'Computer') { 'any account of this computer' } else { "$([Environment]::UserDomainName)\$([Environment]::UserName) on this computer only" }
                Write-ExlItem Ok ("{0} {1} {2} {1} password protected by DPAPI, readable by {3}" -f $m.CredentialFile, $dot, $Credential.UserName, $who) -Icon File
                if ($m.Authentication -eq 'Anonymous') { Write-ExlItem Warn "Mail.Authentication is 'Anonymous': the account is saved but not used." }
            }
            $step++
            Write-ExlStep $step $total "Sending a test message through $($m.SmtpServer):$($m.Port)" -Icon Mail
            $mail = Send-ExlTestMail -Settings $settings
            foreach ($l in $mail.Transcript) { Write-ExlDetail $l }
            foreach ($r in $mail.Refused) { Write-ExlItem Warn "Recipient refused: $r" }
            $values = [ordered]@{}
            $values['Server'] = @('Server', ("{0}:{1}" -f $m.SmtpServer, $m.Port))
            $values['TLS'] = @($(if ($mail.Tls) { 'Ok' } else { 'Warn' }), $(if ($mail.Tls) { $mail.Tls } else { 'none: the message travels in clear' }))
            if ($mail.Certificate) { $values['Certificate'] = @('File', $mail.Certificate) }
            if ($mail.AuthenticationUsed) { $values['Account'] = @('People', $mail.AuthenticationUsed) }
            if ($mail.Sent) {
                $values['Message'] = @('Ok', ("{0} {1} {2} bytes {1} {3}" -f $mail.MessageId, $dot, (Format-ExlNumber $mail.MessageBytes), $mail.Response))
                Write-ExlSummary -Title 'Test message sent' -Values $values -Status $(if ($mail.Refused.Count) { 'Warn' } else { 'Ok' })
                $exitCode = if ($mail.Refused.Count) { 2 } else { 0 }
            }
            else {
                $values['Error'] = @('Fail', $mail.Error)
                Write-ExlSummary -Title 'Test message not sent' -Values $values -Status Fail
                $exitCode = 1
            }
            $runStatus = 'Completed'
            break
        }

        # ---- discovery of the log paths (no database, no log file read) ------------------------------
        if ($Mode -eq 'Discover') {
            $banner = [ordered]@{}
            $banner['Mode'] = @('Info', 'Discover')
            $localExchange = [bool]$env:ExchangeInstallPath -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup')
            $banner['Exchange'] = @('Server', $(if ($ConnectTo) { "remote PowerShell on $ConnectTo" } elseif ($localExchange -and -not $Credential) { 'Exchange Management Shell of this server (Windows PowerShell 5.1)' } else { "remote PowerShell (Windows PowerShell 5.1) on the first of $($settings.Servers.Name -join ', ') that answers" }))
            $banner['Paths'] = @('File', $settings.PathsFile)
            $banner['Log'] = @('Log', $logPath)
            Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot discovery of the log folders" -Details $banner
            foreach ($n in $ignored) { Write-ExlItem Warn $n }
            $found = Invoke-ExlDiscovery -Settings $settings -ConnectTo $ConnectTo -Credential $Credential
            $values = [ordered]@{}
            $mailbox = @($found.Found | Where-Object { $_ -notin $found.Edge })
            $text = @(if ($mailbox.Count) { "{0} mailbox server(s): {1}" -f $mailbox.Count, ($mailbox -join ', ') }
                if ($found.Edge.Count) { "{0} Edge Transport server(s): {1}" -f $found.Edge.Count, ($found.Edge -join ', ') }) -join " $dot "
            $values['Servers'] = @('Server', $text)
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

        $period = if ($Mode -eq 'Report') { Resolve-ExlPeriod -Range $Range -Month $Month -Date $Date -Start $Start -End $End -Zone $zone }
        # A report reads the database; it reads the new log lines first only when the data is too old for the period
        # (Report.MaxDataAgeMinutes), or with -Collect. The hourly scheduled collection keeps the data fresh.
        $collecting = $Mode -eq 'Collect'
        $data = $null
        if ($Mode -eq 'Report') {
            $data = Resolve-ExlReportCollection -Settings $settings -Period $period -Collect:$Collect -NoCollect:$NoCollect
            $collecting = $data.Collect
            if ($collecting -and -not $Collect) {
                # Decided by the age of the data: never wait for, nor fail on, a collection that is running.
                $lock = Enter-ExlLock -Path ($settings.Storage.DatabasePath + '.lock') -NoWait
                if (-not $lock) {
                    $collecting = $false
                    $owner = try { [IO.File]::ReadAllText($settings.Storage.DatabasePath + '.lock') } catch { 'another execution' }
                    $data.Text = "$($data.Text -replace ': the new log lines are read first', '') $dot a collection is running ($owner): the report uses the data already collected"
                }
            }
        }
        # The report is sent by e-mail when Mail.Enabled is $true, or when -SendMail says so (-SendMail:$false never sends).
        $mailing = $Mode -eq 'Report' -and $(if ($PSBoundParameters.ContainsKey('SendMail')) { [bool]$SendMail } else { $settings.Mail.Enabled })
        $totalSteps = switch ($Mode) { 'Status' { 2 } 'Collect' { 4 } default { $(if ($collecting) { 5 } else { 2 }) + $(if ($mailing) { 1 } else { 0 }) } }
        $banner = [ordered]@{}
        $banner['Mode'] = @('Info', ($Mode + $(if ($period) { " $dot $ReportType $dot $Range" } else { '' })))
        if ($period) { $banner['Period'] = @('Calendar', "$(Format-ExlRange $period.StartMs $period.EndMs $zone)  ($($settings.Report.TimeZone), end excluded)") }
        $banner['Servers'] = @('Server', ($servers.Name -join ', '))
        if ($User) { $banner['Users'] = @('People', ($User -join ', ')) }
        $banner['Database'] = @('Database', $settings.Storage.DatabasePath)
        if ($data) { $banner['Data'] = @($(if ($data.NoData) { 'Warn' } elseif ($collecting) { 'Download' } else { 'Clock' }), $data.Text) }
        if ($mailing) { $banner['Mail'] = @('Mail', ("to {0} through {1}" -f (@($settings.Mail.To) -join ', '), $settings.Mail.SmtpServer)) }
        $banner['Paths'] = @('Folder', $(if ($settings.Discovery) { "found by -Mode Discover on $($settings.Discovery.When.Substring(0, [Math]::Min(16, $settings.Discovery.When.Length)).Replace('T', ' '))" } else { 'default folders (run -Mode Discover to check them)' }))
        $banner['Log'] = @('Log', $logPath)
        Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot usage and troubleshooting from the server logs" -Details $banner
        foreach ($n in $ignored) { Write-ExlItem Warn $n }
        if ($settings.Discovery -and $settings.Discovery.Collector -and $settings.Discovery.Collector -ne [Environment]::MachineName.ToUpperInvariant()) {
            Write-ExlItem Warn "The paths file was written on $($settings.Discovery.Collector): run -Mode Discover on this computer."
        }

        if ($data -and $data.NoData) {
            throw ("No collection in the database yet: run '.\Invoke-ExchangeLogReport.ps1 -Mode Collect' first (it reads the last {0} days of logs; then schedule it every hour), or add -Collect to this command." -f $settings.Collection.BackfillDays)
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
        if ($collecting -and -not $lock) { $lock = Enter-ExlLock -Path ($settings.Storage.DatabasePath + '.lock') }
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
            Write-ExlStep $step $totalSteps 'Checking access to the servers and their log folders' -Icon Server
            $here = [Environment]::MachineName.ToUpperInvariant()
            foreach ($s in $servers) {
                $local = $s.Name -eq $here
                if ((Resolve-ExlServerRole -Server $s -Local:$local) -eq 'Edge') {
                    # Edge Transport: no IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4 to check or read.
                    $how = @{ Configuration = 'set in the configuration'; Discover = 'recorded by -Mode Discover'; Detected = 'detected' }[$s.RoleOrigin]
                    Write-ExlItem Info "$($s.Name): Edge Transport server ($how): SMTP protocol logs and message tracking only." -Icon Server
                }
                else {
                    # The IIS settings are read at every collection: a log folder moved since -Mode Discover is followed.
                    $notes = @(Test-ExlIisSites -Server $s -Local:$local)
                    foreach ($n in $notes) { Write-ExlItem $n.Status "$($s.Name): $($n.Text)" }
                    if (@($notes | Where-Object { $_.Drift -or $_.Status -eq 'Warn' }).Count) { $incomplete = $true }
                }
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
        if (-not $collecting) {
            # Role of each server (an Edge report has its own layout); the collection has already resolved it.
            # Without collection the servers are not contacted: the role comes from the data already collected.
            $here = [Environment]::MachineName.ToUpperInvariant()
            foreach ($s in $servers) { [void](Resolve-ExlServerRole -Server $s -Local:($s.Name -eq $here) -Store $store) }
        }
        Write-ExlStep $step $totalSteps "Building the $($ReportType.ToLowerInvariant()) report" -Icon Report
        $report = New-ExlReport -Store $store -Settings $settings -Period $period -ReportType $ReportType -User $User -Server $Server -IncludeRoutingDetails $settings.Report.IncludeRoutingDetails -IncludeSessionDetails $settings.Report.IncludeSessionDetails
        foreach ($f in $report.Files) { Write-ExlItem Ok ("{0}  {1} rows {2} {3}" -f (Split-Path $f.Path -Leaf), (Format-ExlNumber $f.Rows), $dot, (Format-ExlBytes $f.Bytes)) -Icon File }
        if ($runId) {
            $store.EndRun($runId, $(if ($incomplete) { 'Incomplete' } else { 'Completed' }), $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
            $runId = $null
        }
        $c = $report.Counts
        $edgeReport = $c.ContainsKey('smtpdestinations')
        $periodText = Format-ExlRange $period.StartMs $period.EndMs $zone

        # ---- e-mail -------------------------------------------------------------------------------------
        $collectionWarnings = $incomplete
        $mail = $null
        if ($mailing) {
            $step++
            Write-ExlStep $step $totalSteps 'Sending the report by e-mail' -Icon Mail
            $problems = @(Test-ExlMailReady -Settings $settings)
            if ($problems.Count) { Write-ExlItem Warn ('The report is not sent: ' + ($problems -join ' ')); $incomplete = $true }
            else {
                try { $mail = Send-ExlReportMail -Settings $settings -Report $report -Period $periodText -ReportType $ReportType -Range $Range -Title $report.Title }
                catch { $mail = [pscustomobject]@{ Sent = $false; Error = $_.Exception.Message; Refused = @(); Tls = $null; AuthenticationUsed = $null } }
                if ($mail.Sent) {
                    $attached = if (@($mail.Attached).Count) { (@($mail.Attached) -join ', ') + ' attached' } elseif ($mail.OmittedBytes) { 'report not attached' } else { 'no attachment' }
                    Write-ExlItem Ok ("Sent to {0} {1} {2} {1} {3} {1} {4}" -f ((@($settings.Mail.To) + @($settings.Mail.Cc)) -join ', '), $dot, $(if ($mail.Tls) { $mail.Tls } else { 'no TLS' }), $mail.AuthenticationUsed, $attached) -Icon Mail
                    if ($mail.OmittedBytes) { Write-ExlItem Info ("The report ({0}) is larger than Mail.MaxAttachmentMB ({1} MB): not attached, the message gives its folder." -f (Format-ExlBytes $mail.OmittedBytes), $settings.Mail.MaxAttachmentMB) }
                    foreach ($r in $mail.Refused) { Write-ExlItem Warn "Recipient refused: $r"; $incomplete = $true }
                }
                else { Write-ExlItem Warn ("The report was not sent by e-mail: {0} (-Mode MailTest shows the SMTP conversation)." -f $mail.Error); $incomplete = $true }
            }
        }
        $values = [ordered]@{}
        $values['Period'] = @('Calendar', $periodText)
        $values['Servers'] = @('Server', ("{0} in the report{1}" -f (Format-ExlNumber $c['servers']), $(if ($edgeReport) { " $dot Edge Transport (mail flow only)" } else { '' })))
        if ($edgeReport) {
            $values['Clients'] = @('Mail', ("{0} SMTP client(s) {1} {2} SMTP destination(s)" -f (Format-ExlNumber $c['smtpclients']), $dot, (Format-ExlNumber $c['smtpdestinations'])))
            if ($ReportType -eq 'Detailed') { $values['Messages'] = @('Mail', ("{0} message(s) {1} {2} SMTP transaction(s)" -f (Format-ExlNumber $c['messages']), $dot, (Format-ExlNumber $c['smtp']))) }
        }
        else {
            $values['Users'] = @('People', ("{0} real user(s)" -f (Format-ExlNumber $c['users'])))
            if ($ReportType -eq 'Detailed') {
                $values['Sessions'] = @('People', ("{0} client session(s) {1} {2} with failures" -f (Format-ExlNumber $c['sessions']), $dot, (Format-ExlNumber $c['sessionsWithFailures'])))
                $values['Issues'] = @('Warn', ("{0} failed or slow request(s) kept" -f (Format-ExlNumber $c['issues'])))
                $values['Messages'] = @('Mail', ("{0} message(s) {1} {2} SMTP transaction(s) from {3} SMTP client(s)" -f (Format-ExlNumber $c['messages']), $dot, (Format-ExlNumber $c['smtp']), (Format-ExlNumber $c['smtpclients'])))
            }
        }
        $values['Folder'] = @('Folder', $report.Folder)
        if ($report.HtmlPath) { $values['Open'] = @('Report', $report.HtmlPath) }
        if ($mail) { $values['Mail'] = @($(if ($mail.Sent) { 'Mail' } else { 'Warn' }), $(if ($mail.Sent) { 'sent to ' + ((@($settings.Mail.To) + @($settings.Mail.Cc)) -join ', ') } else { 'not sent' })) }
        $values['Duration'] = @('Clock', (Format-ExlDuration $clock.Elapsed.TotalSeconds))
        $mailFailed = $mailing -and -not ($mail -and $mail.Sent -and -not @($mail.Refused).Count)
        $title = if ($collectionWarnings -and $mailFailed) { 'Report ready (collection incomplete, e-mail not sent)' } elseif ($collectionWarnings) { 'Report ready (collection incomplete)' } elseif ($mailFailed) { 'Report ready (e-mail not sent)' } else { 'Report ready' }
        Write-ExlSummary -Title $title -Values $values -Status $(if ($incomplete) { 'Warn' } else { 'Ok' })
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
