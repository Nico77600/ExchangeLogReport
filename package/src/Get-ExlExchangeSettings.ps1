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
    Version : 3.0.0
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

# SIG # Begin signature block
# MIImIgYJKoZIhvcNAQcCoIImEzCCJg8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB2k09LIPAiiGWz
# U1+L4LfCZKZTTMvpouxLrlFyi2kMKqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYIYCTCCGAUCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAJqtMj0CEH
# a7BdvSNsVqBAT6RIhfMzw7pHHBR/HGdyxTANBgkqhkiG9w0BAQEFAASCAgA7NxtK
# QnDdcVQsD90Xaq9Q9i30G5In5wWjqhdmSEneUJ4M9Q9KcoMR/6z2hqzJ8WQ/EtKX
# mDOn8LFQreUsjBFuwm4I0v+yyA3GmZHK9LSrSPOMpBlO+J53d8C7A17oeOP5R78k
# MS9upRuSfFO2kc2U179Zm/X8EnVdKHn6+51ZshnT5zp6vqprceSM3Nuoj3q2GNlz
# lpCYaPanhPfpFW9YpiTnX+VhEidBXS8xaqKQWWKJ9u8pEY6jiSa0OWcpXLp7H2Vv
# urWX+lKDpVx7bmhsSFKUrdYopTG+Q6v7lsfGtaQ3cZxVYKrmJG84yHYvAA5RHfC0
# 3+0xlxwd9wRenDqYGECAYZs3Ws+S7IqyQvXpuB3PQzbRVQnXMCA5gL/Zh1eBRZAH
# WPARtckeA1HY2lH0lhGITDnjKsyjcUUIvqNVuZeodC9EW2xp/ipkfHOJ/iixRZqR
# qAUZauWFSLpzxJ2g6umQHk0TSRvpySgkwsmydPj175sxW/Z+jYDAudBbsTMbZjUT
# foMwYwimpK5Z86BDNZfKJP6+BR4rdOm83idak7kICthTIWJYqp7XXxhKzhVdDXCg
# ZzsETChvpzCGMFPj9gVpZIJcj+iXI+B1K1svPNhO9rp6X9+0Lmhb3l49ND/NSqKF
# 0fQQ+eFhM8u8j9I1EQi1MuFwmIwQSxkCRMnrMqGCFMYwghTCBgorBgEEAYI3AwMB
# MYIUsjCCFK4GCSqGSIb3DQEHAqCCFJ8wghSbAgEDMQ0wCwYJYIZIAWUDBAIBMIGB
# BgsqhkiG9w0BCRABBKByBHAwbgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIHLiapT0zH1qwGI/eq3dEftEoa2fKDw0cuMmlDNFu7/NAghdVUkxYvwD
# dRgPMjAyNjExMDMwOTM4MDNaMAMCAQECCBBPyGkUGcoEoIIRpzCCBPMwggLboAMC
# AQICEFRD+De9Wu4YAYRyuFzajuMwDQYJKoZIhvcNAQELBQAwcjELMAkGA1UEBhMC
# VVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhT
# U0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNzdWluZyBS
# U0EgQ0EgMjAeFw0yNjA2MTIxNzIyNDZaFw0zNjA2MDkxNzIyNDVaMG4xCzAJBgNV
# BAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UE
# CgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1waW5nIFVuaXQg
# MjAyNiBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOgli7hmEy5IkjjzCzbJ
# DgbYV7CIUUgOOn3jkML0i3A2jYer8VMwShMdSnRQURbOzh65x/ytFQOjGw0CBaVI
# ND2jggFSMIIBTjAfBgNVHSMEGDAWgBRwmmXBQ4Cj/OmxZIlu8TCcCSHJfDBNBggr
# BgEFBQcBAQRBMD8wPQYIKwYBBQUHMAKGMWh0dHA6Ly9jZXJ0LnNzbC5jb20vU1NM
# LmNvbS10aW1lU3RhbXBpbmctSS1SMi5jZXIwUQYDVR0gBEowSDA8BgwrBgEEAYKp
# MAEDBgEwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0
# b3J5MAgGBmeBDAEEAjAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDBCBgNVHR8EOzA5
# MDegNaAzhjFodHRwOi8vY3Jscy5zc2wuY29tL1NTTC5jb20tdGltZVN0YW1waW5n
# LUktUjIuY3JsMB0GA1UdDgQWBBQnrANWuihquhc7gz1Af3moJOzDPDAOBgNVHQ8B
# Af8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE92bs78A57CGU1wZ/oY5rgV4Mwd
# dn22MU/bmHumb4b6W2VinMg0IGnBE5D8PJOsnqp2AmMhWdOt5TDxKgIQA9pzBute
# GYez7R1vQ1qn7IIr8Wz2AXjfre1MYJGE93saW1jHTxKgbVlchzry3CrzMYCVnyYw
# DcFZMFQ35Mv4+3H9vPoopjfDynO0v7vPy3p0UZ1dltmH53EZ5M/Qn7OZ0Q82mYLo
# h666dhscIJzUEh+BgYxzpdz8y7J1WxqGSouGRI4F7qbOJhhjiu/hgdhwJUJ/jkve
# OHB6pZB9IBJbdlns6AjUaRC6YfamsbgZ40hKl1ln4BOshgcDtLsSjaqVlUx5gMK+
# krwT6H8bm1yLhJ/Yr0eAizrgMVEqyeNWQYP6qhtKCYxehpESm8au3MlkpBGWCYZi
# goNh4OX1x2oDsYsG5p+ST2db4Vgq25N7/3U8doL0yufnqwuR/f603JY1CO++sndq
# 34Y35Kb8gLG7V7OA+5658PIvcKK+fn3bUUiQVcasy5spBX7aC9FKdkPvrciglHa4
# m3XJ6weBykt7PrdwI3XGwNOgwi/Bon0IvXy9MkQUTZQOKOgT/kq++eTGgjY1EWGQ
# 7w8sSRwQU+3Ko2SMLIkfLPuvOtJ6BWwQbXYHtiMOwjwv9UN9SNu4VaJUuwdMmqN7
# /F9jLVst5rGZV03BMIIF3TCCA8WgAwIBAgIIeyyb0xaAMpkwDQYJKoZIhvcNAQEL
# BQAwfDELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3Vz
# dG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xMTAvBgNVBAMMKFNTTC5jb20g
# Um9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0EwHhcNMTYwMjEyMTczOTM5
# WhcNNDEwMjEyMTczOTM5WjB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAPkP3aMrfcvQKv7sZ4Wm5y4b
# unfh4/WvpOz6Sl2RxFdHaxh3a3by/ZPkPQ/CFp4LZsNWlJ4Xg4XOVu/yFv0AYvUi
# CVToZRdOQbngT0aXqhvIuG5iXmmxX9sqAn78bMrzQdjt0Oj8P2FI7bADFB0QDksZ
# 4LtO7IZl/zbzXmcCC52GVWH9ejjt/uIZALdvoVBidXQ8oPrIJZK0bnoix/geoeOy
# 3ZExqysdBP+lSgQ36YWkMyv94tZVNHwZpEpox7Ko07fKoZOI68GXvIz5HdkihCR0
# xwQ9aqkpk8zruFvh/l8lqjRYyMEjVJ0bmBHDOJx+PYZspQ9AhnwC9FwCTyjLrnGf
# DzrIM/4RJTXq/LrFYD3ZfBjVsqnTdXgDciLKOsMf7yzlLqn6niy2UUb9rwPW6mBo
# 6oUWNmuF6R7As93EJNyAKoFBbZQ+yODJgUEAnl6/f8UImKIYLEJAs/lvOCdLToD0
# PYFH4Ih86hzOtXVcUS4cK38acijnALXRdMbX5J+tB5O2UzU1/Dfkw/ZdFr4hc96S
# CvigY2q8lpJqPvi8ZVWb3vUNiSYE/CUapiVpy8JtynziWV+XrOvvLsi81xtZPCvM
# 8hnIk2snYxnP/Okm+Mpxm3+T/jRnhE6Z6/yzeAkzcLpmpnbtG3PrGqUNxCITIJRW
# Ck4sbE6x/c+cCbqiM+2HAgMBAAGjYzBhMB0GA1UdDgQWBBTdBAkHovV6fVJTEpKV
# 7jiAJQ2mWTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMS
# kpXuOIAlDaZZMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAIBgR
# lCn7Jp0cHh5wYfGVcpNxJK1ok1iOMq8bs3AD/CUrdIWQPXhq9LmLpZc7tRiRux6n
# +UBbkflVma8eEdBcHadm47GUBwwyOabqG7B52B2ccETjit3E+ZUfijhDPwGFpUen
# PUayvOUiaPd7nNgsPgohyC0zrL/FgZkxdMF1ccW+sfAjRfSda/wZY52jvATGGAsl
# u1OJD7OAUN5F7kR/q5R4ZJjT9ijdh9hwZXT7DrkT66cPYakylszeu+1jTBi7qUD3
# oFRuIIhxdRjqerQ0cuAjJ3dctpDqhiVAq+8zD8ufgr6iIPv2tS0a5sKFsXQP+8hl
# AqRSAUfdSSLBv9jra6x+3uxjMxW3IwiPxg+NQVrdjsW5j+VFP3jbutIbQLH+cU0/
# 4IGiul607BXgk90IH37hVZkLId6Tngr75qNJvTYw/ud3sqB1l7UtgYgXZSD32pAA
# n8lSzDLKNXz1PQ/YK9f1JmzJBjSWFupwWRoyeXkLtoh/D1JIPb9s2KJELtFOt3JY
# 04kTlf5Eq/jXixtunLwsoFvVagCvXzfh1foQC5ichucmj87w7G6KVwuA406ywKBj
# YZC6VWg3dGq2ktufoYYitmUnDuy2n0Jg5GfCtdpBC8TTi2EbvPofkSvXRAdeuims
# 2cXp71NIWuuA8ShYIc2wBlX7Jz9TkHCpBB5XJ7kwggbLMIIEs6ADAgECAhBSnbvC
# uImH9YOA4LDrogY2MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTI2MDYxMjE2NDIxNVoXDTQxMDIxMjE3MzkzOVowcjELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEuMCwGA1UEAwwlU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgMjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ8v
# q+ZzTZC8MUabNgd5WlBjVPcu71oiedNd8n9Il8+uW0HcGvW44/Jf0pHl6hxqn0od
# haGnvvNBPJgxH/d6CMI7Mtgl9nF5isarRfByRmAeH+skYShA+dMJGzsrC9NiF3/v
# xGZ2uOI334YVc+DlP5OdsUPz5yIP7hYXNlpPknPwh6gK/pWFZD8+y8uUagfX9USh
# q/SQt+1tS4FXRwudHTSHbGt0Fz4ZbWGbm0d56ROAW34tI6FFuZ+TtGssHjeOUf2F
# S8QNGBpadTh1X1Z7Kl6vG4Z8NS3OJIyelzoF5TpcP2vM3ue0723bmZd3oXsE5rzt
# AJMv56jlg0vSDz8XcXRur6awW0rh5cTQDQQGx04hYJH2Zn9HWWJU/wJ2SKBcQKtB
# yCz6JX+DoFoBE++kolkpZtl2ESF8FY6XqhtKZb18ESEAc0ohCY+0HkBZwrx8eIED
# CDbzd/shv9a8YRG2oxr3tLUz95V+Dzzh1QBNECaeGczyNWGCZIVUa4lVcVUVOBbI
# OAT8D+iPmC5h29bWeES8DhTS4f4CWA4D5QoQqMTqIBcV4MD2Waw8hEWAdGnjnsVt
# DimnDeEUbvXKhdiirvwG+QC+3mAy1RlD6xBMmGyDAKVSqqXm3NP4w0J4gvt65Grk
# QI4FXPJtYqfwkIBtQ8OGfbpVUQGPVUemWtui7E21AgMBAAGjggFRMIIBTTASBgNV
# HRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFN0ECQei9Xp9UlMSkpXuOIAlDaZZ
# ME0GCCsGAQUFBwEBBEEwPzA9BggrBgEFBQcwAoYxaHR0cDovL2NlcnQuc3NsLmNv
# bS9TU0xjb20tUm9vdENBLVJTQS00MDk2LVIxLmNlcjA/BgNVHSAEODA2MDQGBFUd
# IAAwLDAqBggrBgEFBQcCARYeaHR0cHM6Ly93d3cuc3NsLmNvbS9yZXBvc2l0b3J5
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMEIGA1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9j
# cmxzLnNzbC5jb20vU1NMY29tLVJvb3RDQS1SU0EtNDA5Ni1SMS5jcmwwHQYDVR0O
# BBYEFHCaZcFDgKP86bFkiW7xMJwJIcl8MA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG
# 9w0BAQsFAAOCAgEAZRRbzTHpgOogYgWKOeiCkI1oVrkGmCrqOKqX9CiTREQLdYM/
# h7ANki98QP1fhAPEkTzT/Ur19IrPuZg7KaWL6SsmBqmD9+mBVtJmxdRdGbV8bpgl
# FDv2VeZgTSg3+UOD2O0G9HlgHqVHNKzSa/zL5+WYl3yT8Q29sZnIPGkQ+udv56/j
# q5NlAT9BON4iXSOCxe1bNvUd0hkS2GTsTNeQyOEHm7CkZdCg5X+DpmBginO7pk8Y
# m5GbTdQtSloJ3/Y2nVPycJ8kmmBAYMev7/hVQukhjjc4mO03LyPTFfqmMR1D5Tpu
# gGkD9nUuG41l55vOpXQm1JMbTgArpkn0/e9O+yTYlWuz2dSAZHf9jxNQAvILO1Pv
# 2JNQTfV0TyIteZP7gNcRfaHnnuSho8ohipKiE+1vEJIFE+c3gopxSpHCmn2THETk
# lWKV7ZrUKhhkdoOLj2KidCtYZrOoCV6x7f9+KfDPT61fKDVntGZdRKwzLV53VIN6
# oSS+KQN2VJaO8OZTOZpfgO4o6/9xpNr+EEaA3hNkoZk13R4LaqPC/309dfZmHBE8
# nBNjWBkV7AZdzdK8w7B0a/D9066a6oUa19OIktD+3kPpQ8YEt8oRp9zs1hoQ7fRn
# 9sdantP6nYRQFTpF8czGc+FGresbAH819Pv5vBhCluTo8Px2PpC71cM0jzsxggJW
# MIICUgIBATCBhjByMQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNV
# BAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29t
# IFRpbWVzdGFtcGluZyBJc3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7j
# MAsGCWCGSAFlAwQCAaCCAWAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwG
# CSqGSIb3DQEJBTEPFw0yNjExMDMwOTM4MDNaMCgGCSqGSIb3DQEJNDEbMBkwCwYJ
# YIZIAWUDBAIBoQoGCCqGSM49BAMCMC8GCSqGSIb3DQEJBDEiBCCBopIHpHB5OgSS
# IU75AH69dOam7JxskgfzvZTe8jtsSTCByAYLKoZIhvcNAQkQAi8xgbgwgbUwgbIw
# ga8EIFdP6heq+l58aiubCMmYsXNeRQs4c8pE5qJMoJMOY/OwMIGKMHakdDByMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS4wLAYDVQQDDCVTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSAyAhBUQ/g3vVruGAGEcrhc2o7jMAoGCCqGSM49BAMCBEcw
# RQIhAJcrAN54fKnqx7HIGZTueGpAVIiqUdlh8fbPQZAfy2clAiAu3D7wOi2QlX5q
# rs6nQ90ZLaIE6buyyZls5OesRaySJw==
# SIG # End signature block
