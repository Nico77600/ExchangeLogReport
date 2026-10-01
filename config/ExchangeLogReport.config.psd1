#
#  Exchange Log Report - configuration file
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : 1.3.1
#
#  This file is read by Invoke-ExchangeLogReport.ps1. It is a PowerShell data
#  file: text between quotes, $true / $false, numbers, and @( ) for lists.
#  Lines starting with # are comments. Relative paths are relative to the tool folder.
#
@{
    # ---------------------------------------------------------------------
    # Exchange servers. One block per server; their data is consolidated in
    # one database and one report.
    #   Name          : server name shown in the reports
    #   ExchangePath  : Exchange installation folder as seen from the collector
    #                   (default: \\<Name>\c$\Program Files\Microsoft\Exchange Server\V15)
    #   IisLogPath    : IIS log root (default: \\<Name>\c$\inetpub\logs\LogFiles)
    # Optional overrides when the logs were moved: HttpProxyPath, LoggingPath (Exchange "Logging"
    # folder: MapiHttp, Imap4, Pop3), TransportLogPath, MessageTrackingPath (check with
    # Get-TransportService | fl *LogPath).
    # The account that runs the tool needs read access to these folders
    # (members of 'Exchange Trusted Subsystem', such as the computer account of
    # an Exchange server running the tool as SYSTEM, have it by default).
    # ---------------------------------------------------------------------
    Servers = @(
        @{ Name = 'EXCH01' }
        @{ Name = 'EXCH02' }
    )

    # ---------------------------------------------------------------------
    # Logs to read on each server.
    # ---------------------------------------------------------------------
    Sources = @{
        HttpProxy       = $true    # Logging\HttpProxy\<protocol>: main source of client access (one line per request)
        IisFrontEnd     = $true    # inetpub\logs\LogFiles\<IisSite>: IIS sub-status/Win32 status of failures, requests rejected before the proxy
        IisSite         = 'W3SVC1' # Default Web Site (front end). W3SVC2 (Exchange Back End) is server-to-server traffic
        SmtpReceive     = $true    # TransportRoles\Logs\<role>\ProtocolLog\SmtpReceive (protocol logging must be enabled on the connectors)
        SmtpSend        = $true    # TransportRoles\Logs\<role>\ProtocolLog\SmtpSend
        MessageTracking = $true    # TransportRoles\Logs\MessageTracking\MSGTRK*.log
        TransportRoles  = @('FrontEnd', 'Hub', 'Mailbox')
        MapiBackEnd     = $true    # Logging\MapiHttp\Mailbox: Outlook version and mode, MAPI status codes (an HTTP 200 can hide a MAPI failure)
        EasBackEnd      = $true    # inetpub\logs\LogFiles\<IisBackEndSite>: ActiveSync results hidden behind HTTP 200 (only ActiveSync lines are kept)
        IisBackEndSite  = 'W3SVC2' # Exchange Back End web site
        PopImap         = $false   # Logging\Imap4 and Logging\Pop3 (optional). Needs Set-ImapSettings / Set-PopSettings -ProtocolLogEnabled $true
    }

    # ---------------------------------------------------------------------
    # Noise: lines removed BEFORE anything is written to the database. Each removed
    # line is counted by reason (see -Mode Status). Patterns are regular expressions,
    # case-insensitive, tested on the account name with and without domain.
    # Defaults below were checked against the logs of an Exchange SE lab.
    # ---------------------------------------------------------------------
    Noise = @{
        # Accounts that are not people: health mailboxes, system/arbitration mailboxes, computer accounts.
        SystemUserPatterns = @(
            '^HealthMailbox', '^SystemMailbox\{', '^SM_[0-9a-f]{10,}', '^FederatedEmail\.', '^Migration\.', '^DiscoverySearchMailbox',
            '^extest_', '^MSExchApproval', '^Exchange Online-ApplicationAccount', '\$$', '^nt authority\\', '^system$', '^S-1-5-18$'
        )
        # Managed Availability probes and Exchange internal clients.
        ProbeUserAgentPatterns = @(
            'AMProbe', 'ActiveMonitoring', 'MSExchangeHM', 'HealthManager', 'MapiHttpClient', 'ExchangeInternalEwsClient', 'ExchangeWebServicesProxy',
            'RpcClientAccess\.Monitoring'
        )
        # Load balancer health checks.
        ProbeUrlPatterns = @('healthcheck\.htm', '/owa/auth/x\.gif$')
        # Probe and system messages (message tracking, SMTP).
        ProbeSenderPatterns = @('^HealthMailbox', '^MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@', '^inboundproxy@', '^SystemMailbox\{')
        # Client addresses to ignore entirely (prefix match), e.g. a monitoring server. Never put the
        # load balancer here if it hides the client addresses (SNAT): all traffic would be removed.
        ExcludedClientIps = @()
        # Shadow redundancy events (copies kept by another server until delivery): internal, not a route step.
        IgnoredTrackingEvents = @('HARECEIVE', 'HADISCARD', 'HAREDIRECT', 'HAREDIRECTFAIL')
    }

    # ---------------------------------------------------------------------
    # Collection (scheduled task, -Mode Collect). Only the new part of each file is read.
    # ---------------------------------------------------------------------
    Collection = @{
        BackfillDays           = 14     # first collection: files modified in the last N days
        RecoveryWindowMinutes  = 30     # a failure followed by a success (same user, same protocol) within N minutes is "Recovered"
        SmtpSessionIdleMinutes = 10     # an SMTP session open at the end of the current file is read again next time, unless idle this long
        FullDetailUsers        = @()    # users (domain\sam, UPN or SMTP address) whose successful requests are also kept, e.g. during an incident
        StoreAllRequests       = $false # $true keeps every real-user request (large databases: test environments only)
        # Client sessions (Detailed report): what one client did for one user on one day, until idle this long.
        SessionIdleMinutes     = 30
        SessionDetailRequests  = 40     # the first N requests of a session are always kept one by one in its timeline
        MaxSessionSteps        = 80     # timeline steps written per session and log file; the other successes are folded into batches
        # Successful requests slower than this (ms) are kept as "Slow" (0 = never). Long-polling requests are excluded:
        # pattern tested on "Protocol|Action|Url" (Outlook NotificationWait, ActiveSync Ping, RPC/HTTP channels...).
        SlowRequestMs          = 5000
        LongRunningPatterns    = @('^Mapi\|NotificationWait\|', '^Eas\|Ping\|', '^RpcHttp\|', '^Owa\|.*(notificationchannel|/ev\.owa)', '^PowerShell\|', '^Imap4\|IDLE\|')
    }

    # ---------------------------------------------------------------------
    # Local database (SQLite). Raw log lines are never stored.
    #   RetentionDays       : daily usage, operations, clients, SMTP transactions and message tracking
    #   DetailRetentionDays : request-level failures, client sessions and SMTP session transcripts
    # ---------------------------------------------------------------------
    Storage = @{
        DatabasePath        = '.\data\ExchangeLogReport.sqlite'
        RetentionDays       = 60
        DetailRetentionDays = 14
    }

    # ---------------------------------------------------------------------
    # Report files (CSV and HTML), written locally only.
    # ---------------------------------------------------------------------
    Report = @{
        DefaultRange          = 'Last7Days'      # Last24Hours | Last7Days | Last30Days | PreviousMonth
        DefaultType           = 'Usage'          # Usage (who uses which server) | Detailed (+ failures, messages, SMTP sessions)
        TimeZone              = 'Europe/Paris'
        OutputPath            = '.\reports'      # one sub-folder per execution
        FilePrefix            = 'ExchangeLogs'
        Formats               = @('Csv', 'Html')
        IncludeRoutingDetails = $true            # message route and SMTP transcripts in the CSV files (always behind a click in HTML)
        IncludeSessionDetails = $true            # timeline of each client session in the CSV files (always behind a click in HTML)
        CsvDelimiter          = ';'              # ';' opens directly in Excel with French regional settings
        MaxHtmlRows           = 200000           # per table in the HTML file; the CSV files are always complete
        Title                 = 'Exchange Server usage and troubleshooting'
    }

    # ---------------------------------------------------------------------
    # Execution log files (one per day).
    # ---------------------------------------------------------------------
    Logging = @{
        Path          = '.\logs'
        RetentionDays = 14
    }
}
