#Requires -Version 5.1
<#
.SYNOPSIS
    Exchange Log Report - reads the log settings of the Exchange organisation (internal helper).

.DESCRIPTION
    Run by Invoke-ExchangeLogReport.ps1 -Mode Discover in Windows PowerShell 5.1 (powershell.exe):
    the Exchange management cmdlets are supported in Windows PowerShell only. Not meant to be run
    directly.

    Only read-only Get-* cmdlets are used (View-Only Organization Management is enough); nothing
    is changed in Exchange.
      - On an Exchange server, without -ConnectTo: the Exchange Management Shell of the server
        (RemoteExchange.ps1 + Connect-ExchangeServer -Auto, as its Start menu shortcut).
      - On an Edge Transport server, without -ConnectTo: its local Exchange Management Shell
        (snap-in Microsoft.Exchange.Management.PowerShell.E2010, as bin\Exchange.ps1; no RBAC on an
        Edge, a local administrator or SYSTEM is enough). Only this server is returned, with
        Role = 'Edge': its SMTP protocol log folders (Edge) and message tracking.
      - Elsewhere, or with -ConnectTo: Exchange remote PowerShell (http://<server>/PowerShell/,
        Kerberos), on the first server of -ConnectTo that answers.

    The result (one entry per mailbox server, paths as Exchange returns them, and the names of the
    subscribed Edge Transport servers) is written as JSON to -OutFile. Errors are written to the
    error stream and the exit code is 1.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutFile,
    [string]$ConnectTo,       # comma-separated server names (FQDN or short names)
    [string]$CredentialFile   # Export-Clixml of a PSCredential (DPAPI: same account, same computer)
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

function Get-Prop($Object, [string]$Name) {
    # Property of a (deserialized) object, $null when it does not exist.
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-PathText($Value) {
    # Exchange paths are LocalLongFullPath objects; through remote PowerShell they arrive as strings or objects with PathName.
    if ($null -eq $Value) { return $null }
    $text = if ($Value -is [string]) { $Value } elseif (Get-Prop $Value 'PathName') { [string](Get-Prop $Value 'PathName') } else { "$Value" }
    $text = $text.Trim()
    if ($text) { return $text }
    return $null
}

function Get-Leaf($Value) {
    # Last part of an AD object name (contoso.com/Configuration/Sites/Paris -> PARIS).
    if ($null -eq $Value) { return $null }
    $text = if (Get-Prop $Value 'Name') { [string](Get-Prop $Value 'Name') } else { [string]$Value }
    return $text.Split([char[]]@('/', '\'))[-1].ToUpperInvariant()
}

function Get-VersionText($Value) {
    # AdminDisplayVersion "Version 15.2 (Build 2562.17)" -> "15.2.2562.17".
    $text = "$Value".Trim()
    if ($text -match '^Version (\d+\.\d+) \(Build (\d+)\.(\d+)\)$') { return '{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3] }
    return $text
}

$session = $null
$exitCode = 0
try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'This helper must run in Windows PowerShell 5.1 (powershell.exe).' }
    $credential = $null
    if ($CredentialFile) { $credential = Import-Clixml -LiteralPath $CredentialFile }
    $candidates = @(if ($ConnectTo) { $ConnectTo.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $install = $env:ExchangeInstallPath
    $commands = 'Get-ExchangeServer', 'Get-TransportService', 'Get-FrontEndTransportService', 'Get-MailboxTransportService', 'Get-ImapSettings', 'Get-PopSettings', 'Get-ReceiveConnector', 'Get-SendConnector'
    $edge = -not $candidates.Count -and -not $credential -and (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\EdgeTransportRole')

    if ($edge) {
        # ---- Edge Transport server: local Exchange Management Shell (no remote PowerShell, no RBAC) ----
        $method = 'Exchange Management Shell (Edge Transport)'
        try { Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010 -ErrorAction Stop }
        catch { throw ("The Exchange Management Shell of the Edge Transport server {0} could not be loaded as {1} (Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010): the account must be a local administrator of the server. {2}" -f $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $_.Exception.Message.Trim()) }
        $via = $env:COMPUTERNAME
    } elseif (-not $candidates.Count -and -not $credential -and $install -and (Test-Path -LiteralPath (Join-Path $install 'bin\RemoteExchange.ps1'))) {
        # ---- Exchange Management Shell of this server ----
        $method = 'Exchange Management Shell'
        . (Join-Path $install 'bin\RemoteExchange.ps1') *> $null
        $reason = $null
        try { Connect-ExchangeServer -Auto -ClientApplication:ManagementShell *> $null } catch { $reason = $_.Exception.Message.Trim() }
        if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
            throw ("The Exchange Management Shell of {0} could not connect as {1} (Connect-ExchangeServer -Auto). The account needs View-Only Organization Management (or above).{2}" -f $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $(if ($reason) { ' ' + $reason } else { '' }))
        }
        $via = @(Get-PSSession | Where-Object { $_.ConfigurationName -eq 'Microsoft.Exchange' } | ForEach-Object ComputerName | Select-Object -First 1)
        $via = if ($via.Count) { [string]$via[0] } else { $env:COMPUTERNAME }
    } else {
        # ---- Exchange remote PowerShell (Kerberos) ----
        $method = 'Exchange remote PowerShell (Kerberos)'
        if (-not $candidates.Count) { throw 'No Exchange server to connect to: use -ConnectTo.' }
        $failures = @()
        foreach ($c in $candidates) {
            $p = @{ ConfigurationName = 'Microsoft.Exchange'; ConnectionUri = "http://$c/PowerShell/"; Authentication = 'Kerberos'; ErrorAction = 'Stop' }
            if ($credential) { $p.Credential = $credential }
            try { $session = New-PSSession @p; $via = $c; break }
            catch { $failures += ('{0}: {1}' -f $c, $_.Exception.Message.Trim()) }
        }
        if (-not $session) {
            throw ("Exchange remote PowerShell could not be opened (http://<server>/PowerShell/, Kerberos). Check the server name, HTTP (port 80) to the server, and that the account is a member of View-Only Organization Management (or above).`n" + ($failures -join "`n"))
        }
        Import-PSSession -Session $session -CommandName $commands -DisableNameChecking -AllowClobber *> $null
    }

    # ---- organisation-wide settings ----
    $all = @(Get-ExchangeServer)
    $index = {
        param($Items)
        $h = @{}
        foreach ($i in @($Items)) { $h[([string](Get-Prop $i 'Name')).ToUpperInvariant()] = $i }
        $h
    }
    $servers = @()
    $edgeServers = @()

    if ($edge) {
        # ---- this Edge Transport server only (the mailbox servers seen here are copies made by EdgeSync) ----
        $name = $env:COMPUTERNAME.ToUpperInvariant()
        $x = @($all | Where-Object { ([string](Get-Prop $_ 'Name')).ToUpperInvariant() -eq $name }) | Select-Object -First 1
        $transport = @(Get-TransportService | Where-Object { ([string](Get-Prop $_ 'Name')).ToUpperInvariant() -eq $name }) | Select-Object -First 1
        if (-not $transport) { throw "Get-TransportService returned no transport service for $name." }
        # Receive connectors of this server; every send connector of an Edge is used by it (EdgeSync copies only those of its subscription).
        $off = @()
        foreach ($c in @(Get-ReceiveConnector)) {
            if ((Get-Leaf (Get-Prop $c 'Server')) -eq $name -and "$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "receive connector '$(Get-Prop $c 'Name')'" }
        }
        foreach ($c in @(Get-SendConnector)) {
            if ("$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "send connector '$(Get-Prop $c 'Name')'" }
        }
        $servers += New-Object PSObject -Property ([ordered]@{
                Name                   = $name
                Role                   = 'Edge'
                Version                = Get-VersionText (Get-Prop $x 'AdminDisplayVersion')
                Site                   = Get-Leaf (Get-Prop $x 'Site')
                InstallPath            = $(if ($install) { $install.TrimEnd('\') } else { $null })
                EdgeReceivePath        = Get-PathText (Get-Prop $transport 'ReceiveProtocolLogPath')
                EdgeSendPath           = Get-PathText (Get-Prop $transport 'SendProtocolLogPath')
                MessageTrackingPath    = Get-PathText (Get-Prop $transport 'MessageTrackingLogPath')
                MessageTrackingEnabled = (Get-Prop $transport 'MessageTrackingLogEnabled') -ne $false
                LoggingOff             = @($off)
                Warnings               = @()
            })
    }
    else {
        $hub = & $index (Get-TransportService)
        $frontEnd = & $index (Get-FrontEndTransportService)
        $mailbox = & $index (Get-MailboxTransportService)
        $receive = @(Get-ReceiveConnector)
        $send = @(Get-SendConnector)

        # ---- one entry per mailbox server ----
        foreach ($x in $all) {
            if ((Get-Prop $x 'IsEdgeServer') -eq $true) { $edgeServers += ([string]$x.Name).ToUpperInvariant(); continue }
            if (-not ((Get-Prop $x 'IsMailboxServer') -eq $true -or "$(Get-Prop $x 'ServerRole')" -match 'Mailbox')) { continue }
            $name = ([string]$x.Name).ToUpperInvariant()
            $warnings = @()
            $imap = $null; $pop = $null
            try { $imap = @(Get-ImapSettings -Server $name)[0] } catch { $warnings += "IMAP4 settings not read ($($_.Exception.Message.Trim()))." }
            try { $pop = @(Get-PopSettings -Server $name)[0] } catch { $warnings += "POP3 settings not read ($($_.Exception.Message.Trim()))." }

            # SMTP connectors of this server whose protocol logging is off.
            $off = @()
            foreach ($c in $receive) {
                if ((Get-Leaf (Get-Prop $c 'Server')) -eq $name -and "$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "receive connector '$(Get-Prop $c 'Name')'" }
            }
            foreach ($c in $send) {
                $sources = @(Get-Prop $c 'SourceTransportServers' | ForEach-Object { Get-Leaf $_ })
                if ($sources -contains $name -and "$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "send connector '$(Get-Prop $c 'Name')'" }
            }
            foreach ($check in @(@($hub[$name], 'IntraOrgConnectorProtocolLoggingLevel', 'Hub intra-organization connector'),
                    @($frontEnd[$name], 'IntraOrgConnectorProtocolLoggingLevel', 'FrontEnd intra-organization connector'),
                    @($mailbox[$name], 'MailboxDeliveryConnectorProtocolLoggingLevel', 'Mailbox delivery connector'),
                    @($mailbox[$name], 'MailboxSubmissionConnectorProtocolLoggingLevel', 'Mailbox submission connector'))) {
                if ("$(Get-Prop $check[0] $check[1])" -eq 'None') { $off += $check[2] }
            }

            $servers += New-Object PSObject -Property ([ordered]@{
                    Name                   = $name
                    Role                   = 'Mailbox'
                    Version                = Get-VersionText (Get-Prop $x 'AdminDisplayVersion')
                    Site                   = Get-Leaf (Get-Prop $x 'Site')
                    DataPath               = Get-PathText (Get-Prop $x 'DataPath')
                    ImapLogPath            = Get-PathText (Get-Prop $imap 'LogFileLocation')
                    ImapProtocolLog        = (Get-Prop $imap 'ProtocolLogEnabled') -eq $true
                    PopLogPath             = Get-PathText (Get-Prop $pop 'LogFileLocation')
                    PopProtocolLog         = (Get-Prop $pop 'ProtocolLogEnabled') -eq $true
                    FrontEndReceivePath    = Get-PathText (Get-Prop $frontEnd[$name] 'ReceiveProtocolLogPath')
                    FrontEndSendPath       = Get-PathText (Get-Prop $frontEnd[$name] 'SendProtocolLogPath')
                    HubReceivePath         = Get-PathText (Get-Prop $hub[$name] 'ReceiveProtocolLogPath')
                    HubSendPath            = Get-PathText (Get-Prop $hub[$name] 'SendProtocolLogPath')
                    MailboxReceivePath     = Get-PathText (Get-Prop $mailbox[$name] 'ReceiveProtocolLogPath')
                    MailboxSendPath        = Get-PathText (Get-Prop $mailbox[$name] 'SendProtocolLogPath')
                    MessageTrackingPath    = Get-PathText (Get-Prop $hub[$name] 'MessageTrackingLogPath')
                    MessageTrackingEnabled = (Get-Prop $hub[$name] 'MessageTrackingLogEnabled') -ne $false
                    LoggingOff             = @($off)
                    Warnings               = @($warnings)
                })
        }
    }

    $result = New-Object PSObject -Property ([ordered]@{
            Method        = $method
            Via           = $via
            Account       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            ExchangeCount = $all.Count
            Servers       = @($servers)
            EdgeServers   = @($edgeServers)
        })
    [IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $result -Depth 6), (New-Object Text.UTF8Encoding $false))
    if ($edge) { Write-Output ('{0} on {1}: Edge Transport server {2}.' -f $method, $via, $env:COMPUTERNAME.ToUpperInvariant()) }
    else { Write-Output ('{0} on {1}: {2} Exchange server(s), {3} mailbox server(s), {4} Edge Transport server(s).' -f $method, $via, $all.Count, $servers.Count, $edgeServers.Count) }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 1
}
finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    Get-PSSession -ErrorAction SilentlyContinue | Where-Object { $_.ConfigurationName -eq 'Microsoft.Exchange' } | Remove-PSSession -ErrorAction SilentlyContinue
}
exit $exitCode
