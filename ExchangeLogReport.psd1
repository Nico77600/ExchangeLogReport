#
#  Exchange Log Report - module manifest
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : see ModuleVersion
#
#  Loaded by Invoke-ExchangeLogReport.ps1 (Import-Module by path).
#
@{
    RootModule        = 'ExchangeLogReport.psm1'
    ModuleVersion     = '1.3.1'
    GUID              = '7b1cdb50-cb32-4c85-8c8d-9d7a7c8eec14'
    Author            = 'Nicolas Fabert'
    Description       = 'Exchange Log Report: collects the IIS / HTTP Proxy, SMTP protocol and message tracking logs of Exchange Server SE (on-premises) into a local SQLite database, without the noise of system mailboxes and probes, and produces usage and troubleshooting reports (CSV and HTML).'
    PowerShellVersion = '7.4'

    # Functions called by Invoke-ExchangeLogReport.ps1 and by the tests. The other functions stay internal.
    FunctionsToExport = @(
        'Import-ExlConfiguration', 'Initialize-ExlEngine', 'Open-ExlStore', 'Enter-ExlLock', 'Exit-ExlLock'
        'Start-ExlLog', 'Stop-ExlLog', 'Write-ExlLog'
        'Write-ExlBanner', 'Write-ExlStep', 'Write-ExlItem', 'Write-ExlSummary'
        'Format-ExlNumber', 'Format-ExlDuration', 'Format-ExlBytes', 'Format-ExlRange', 'Format-ExlLocalTime'
        'Get-ExlTimeZone', 'Resolve-ExlPeriod', 'Get-ExlSources', 'Test-ExlServerAccess'
        'Invoke-ExlCollection', 'New-ExlReport', 'Show-ExlStatus', 'Invoke-ExlRetention'
    )
}
