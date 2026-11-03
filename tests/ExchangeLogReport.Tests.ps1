#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Exchange Log Report - automated tests (Pester 5 or later).
    Author  : Nicolas Fabert
    Version : 3.0.0

    Run:  Invoke-Pester -Path .\tests\ExchangeLogReport.Tests.ps1 -Output Detailed

    No Exchange server is needed: the tests write log files with the exact headers and
    line shapes of Exchange Server SE (HttpProxy, IIS front end and back end, MAPI over HTTP
    back end, IMAP4 front end and back end, SMTP receive/send protocol logs, message
    tracking), including the noise seen in a real lab: health mailboxes, Managed Availability
    probes, anonymous 401 challenges, Azure load balancer SMTP and IMAP probes and shadow
    redundancy events.
#>

BeforeAll {
    $script:Root = Join-Path (Split-Path $PSScriptRoot -Parent) 'package'
    Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Root
    # The fixtures run from an hour before Base to three hours after it, and the client sessions are cut at local midnight: Base is
    # three hours before now, or, in the first hours of a local day, three hours before that day starts, so that every fixture falls
    # in one local day and in the past. EXL_TEST_NOW (an ISO instant, not later than now) runs the fixtures as at another hour.
    function Get-TestBase([DateTimeOffset]$Now, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
        $start = [DateTime]::SpecifyKind([TimeZoneInfo]::ConvertTime($Now, $Zone).Date, [DateTimeKind]::Unspecified)
        while ($Zone.IsInvalidTime($start)) { $start = $start.AddMinutes(15) }
        $dayStart = [DateTimeOffset]::new([TimeZoneInfo]::ConvertTimeToUtc($start, $Zone), [TimeSpan]::Zero)
        if ($Now - $dayStart -ge [TimeSpan]::FromHours(4.5)) { return $Now.AddHours(-3) }
        return $dayStart.AddHours(-3).AddMinutes(-5)
    }
    $script:Now = if ($env:EXL_TEST_NOW) { [DateTimeOffset]::Parse($env:EXL_TEST_NOW, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() } else { [DateTimeOffset]::UtcNow }
    if ($script:Now -gt [DateTimeOffset]::UtcNow) { throw 'EXL_TEST_NOW must not be later than now.' }
    $script:Base = Get-TestBase $script:Now
    function Remove-TestServeSchema($Store) {
        foreach ($table in 'message_event', 'smtp_transaction') {
            foreach ($operation in 'insert', 'update', 'delete') {
                $Store.Exec("DROP TRIGGER IF EXISTS tr_${table}_rollup_${operation};")
            }
        }
        $Store.Exec("DROP TABLE IF EXISTS message_rollup_dirty; DROP TABLE IF EXISTS message_rollup;
DROP INDEX IF EXISTS ix_msg_identity_time; DROP INDEX IF EXISTS ix_smtp_identity_time;
DROP INDEX IF EXISTS ix_smtp_latest; DROP INDEX IF EXISTS ix_session_latest;
DROP TABLE IF EXISTS message_rollup_value;
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_insert; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_update; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_delete;
DROP INDEX IF EXISTS ix_smtp_client; DROP INDEX IF EXISTS ix_smtp_unknown_peer;
DROP TABLE IF EXISTS smtp_client_hour; DROP TABLE IF EXISTS smtp_client; DROP TABLE IF EXISTS smtp_client_value; DROP TABLE IF EXISTS smtp_client_pending; DROP TABLE IF EXISTS smtp_client_dirty;")
$Store.Exec("ALTER TABLE smtp_transaction DROP COLUMN client_id;")
    }

    function T([double]$Minutes, [switch]$W3C) {
        $t = $script:Base.AddMinutes($Minutes).UtcDateTime
        if ($W3C) { return $t.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
        return $t.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }

    # Reads the HTML report the way the page does: the data files (scripts of the page, or the files of the data folder in
    # manifest order), summary chunks first, then the detail blocks put back into their rows.
    # Returns the rows per dataset (Sets), the report description (Meta), the dataset of each chunk in file order
    # (Order), the detail blocks as written (Blocks) and the text of each data file (Files).
    # -Summary leaves the detail columns as stored in the chunks.
    function Read-TestHtml([string]$Path, [switch]$Summary) {
        function Unpack([string]$Text) {
            $ms = [IO.MemoryStream]::new([Convert]::FromBase64String($Text), $false)
            $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Decompress)
            $reader = [IO.StreamReader]::new($gz)
            try { return ($reader.ReadToEnd() | ConvertFrom-Json -Depth 50) }
            finally { $reader.Dispose(); $gz.Dispose(); $ms.Dispose() }
        }
        $html = [IO.File]::ReadAllText($Path)
        $meta = [regex]::Match($html, '<script id="report-meta" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json -Depth 50
        $sets = @{}; $order = [Collections.Generic.List[string]]::new(); $blocks = [Collections.Generic.List[object]]::new()
        $files = [Collections.Generic.List[string]]::new()
        if ($meta.data.folder) {
            foreach ($f in @($meta.data.files)) { $files.Add([IO.File]::ReadAllText((Join-Path (Join-Path (Split-Path $Path -Parent) $meta.data.folder) $f.name))) }
        } else {
            foreach ($match in [regex]::Matches($html, '<script>(__exl\.file\("[^"]+","[^"]+"\);\n[^<]*)</script>')) { $files.Add($match.Groups[1].Value) }
        }
        $pushes = foreach ($text in $files) { [regex]::Matches($text, '__exl\.push\("([cd])","([^"]+)",(\d+),(\d+),"([^"]+)"\);') }
        foreach ($match in @($pushes | Where-Object { $_.Groups[1].Value -eq 'c' })) {
            $chunk = Unpack $match.Groups[5].Value
            $order.Add($chunk.set)
            if (-not $sets.ContainsKey($chunk.set)) { $sets[$chunk.set] = [Collections.Generic.List[object]]::new() }
            foreach ($row in $chunk.rows) { $sets[$chunk.set].Add($row) }
        }
        foreach ($match in @($pushes | Where-Object { $_.Groups[1].Value -eq 'd' })) {
            $block = Unpack $match.Groups[5].Value
            $blocks.Add([pscustomobject]@{ Set = $match.Groups[2].Value; First = [int]$match.Groups[3].Value; Count = [int]$match.Groups[4].Value; Rows = @($block.rows); Named = $block.set })
        }
        if (-not $Summary) {
            foreach ($block in $blocks) {
                $columns = @($meta.datasets.($block.Set).detailColumns)
                for ($j = 0; $j -lt $block.Rows.Count; $j++) {
                    $row = $sets[$block.Set][$block.First + $j]
                    for ($x = 0; $x -lt $columns.Count; $x++) { $row[$columns[$x]] = $block.Rows[$j][$x] }
                }
            }
        }
        return [pscustomobject]@{ Sets = $sets; Meta = $meta; Order = $order; Blocks = $blocks; Files = $files }
    }

    $script:ProxyFields = 'DateTime,RequestId,MajorVersion,MinorVersion,BuildVersion,RevisionVersion,ClientRequestId,Protocol,UrlHost,UrlStem,ProtocolAction,AuthenticationType,IsAuthenticated,AuthenticatedUser,Organization,AnchorMailbox,UserAgent,ClientIpAddress,ServerHostName,HttpStatus,BackEndStatus,ErrorCode,Method,ProxyAction,TargetServer,TargetServerVersion,RoutingType,RoutingHint,BackEndCookie,ServerLocatorHost,ServerLocatorLatency,RequestBytes,ResponseBytes,TargetOutstandingRequests,AuthModulePerfContext,HttpPipelineLatency,CalculateTargetBackEndLatency,GlsLatencyBreakup,TotalGlsLatency,AccountForestLatencyBreakup,TotalAccountForestLatency,ResourceForestLatencyBreakup,TotalResourceForestLatency,ADLatency,SharedCacheLatencyBreakup,TotalSharedCacheLatency,ActivityContextLifeTime,ModuleToHandlerSwitchingLatency,ClientReqStreamLatency,BackendReqInitLatency,BackendReqStreamLatency,BackendProcessingLatency,BackendRespInitLatency,BackendRespStreamLatency,ClientRespStreamLatency,KerberosAuthHeaderLatency,HandlerCompletionLatency,RequestHandlerLatency,HandlerToModuleSwitchingLatency,ProxyTime,CoreLatency,RoutingLatency,HttpProxyOverhead,TotalRequestTime,RouteRefresherLatency,UrlQuery,BackEndGenericInfo,GenericInfo,GenericErrors,EdgeTraceId,DatabaseGuid,UserADObjectGuid,PartitionEndpointLookupLatency,RoutingStatus'
    $script:ProxyNames = $script:ProxyFields.Split(',')
    function ProxyLine([hashtable]$v) {
        $cells = foreach ($n in $script:ProxyNames) { $x = [string]$v[$n]; if ($x -match '[,"]') { '"' + $x.Replace('"', '""') + '"' } else { $x } }
        return $cells -join ','
    }
    function Write-Log([string]$Path, [string[]]$Lines) {
        [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
        [IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($true))
    }

    $script:FailedRequest = [guid]::NewGuid().ToString()
    function New-TestLogs([string]$Root) {
        $ex = Join-Path $Root 'EXCH01\Exchange'
        $iis = Join-Path $Root 'EXCH01\inetpub'
        # ---- HttpProxy ------------------------------------------------------------------------------------
        $p = { param($min, $proto, $user, $status, $agent, $ip = '10.1.1.10', $anchor = '', $stem = '/mapi/emsmdb/', $id = [guid]::NewGuid().ToString(), $err = '', $auth = 'Negotiate')
            ProxyLine @{ DateTime = (T $min); RequestId = $id; MajorVersion = 15; MinorVersion = 2; Protocol = $proto; UrlHost = 'mail.contoso.test'; UrlStem = $stem
                AuthenticationType = $auth; IsAuthenticated = [bool]$user; AuthenticatedUser = $user; AnchorMailbox = $anchor; UserAgent = $agent; ClientIpAddress = $ip
                ServerHostName = 'EXCH01'; HttpStatus = $status; BackEndStatus = $status; Method = 'POST'; ProxyAction = 'Proxy'; TargetServer = 'exch02.contoso.test'
                RoutingType = 'IntraForest'; RequestBytes = 1200; ResponseBytes = 5400; TotalRequestTime = 42; GenericErrors = $err } }
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Mapi\HttpProxy_2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Version: 15.02.2562.045', '#Log-type: HttpProxy Logs', "#Date: $(T 0)", "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $p 1 'Mapi' '' 401 'MapiHttpClient' 'fe80::90a2:c143:3f63:5f44%9')                                   # internal probe
            (& $p 2 'Mapi' 'CONTOSO\HealthMailboxb4dbf9b' 200 'Microsoft Office/16.0' '::1')                       # health mailbox
            (& $p 3 'Mapi' '' 401 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' '10.1.1.10' 'SMTP:alice@contoso.test') # challenge
            (& $p 4 'Mapi' 'CONTOSO\alice' 500 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' '10.1.1.10' 'SMTP:alice@contoso.test' '/mapi/emsmdb/' ([guid]::NewGuid().ToString()) 'BackEndError')
            (& $p 4.5 'Mapi' 'CONTOSO\alice' 200 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' '10.1.1.10' 'SMTP:alice@contoso.test')
            (& $p 5 'Mapi' 'CONTOSO\alice' 200 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' '10.1.1.10' 'SMTP:alice@contoso.test')
        )
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Ews\HttpProxy_2026100108-1.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $p 6 'Ews' '' 401 'AMProbe/Local/ClientAccess' '127.0.0.1' '' '/ews/exchange.asmx')
            (& $p 7 'Ews' 'bob@contoso.test' 503 'ExchangeServicesClient/15.0' '10.1.1.20' 'SMTP:bob@contoso.test' '/ews/exchange.asmx' $script:FailedRequest)
            ''
        )
        # The offline address book of alice's Outlook, downloaded with NTLM.
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Oab\HttpProxy_2026100108-1.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $p 5.5 'Oab' 'CONTOSO\alice' 200 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' '10.1.1.10' 'SMTP:alice@contoso.test' '/OAB/7a1c/oab.xml' -auth 'NTLM')
        )
        Write-Log (Join-Path $ex 'Logging\HttpProxy\PowerShell\HttpProxy_2026100108-1.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $p 8 'PowerShell' 'CONTOSO\labadmin' 200 'Microsoft WinRM Client' 'fe80::90a2:c143:3f63:5f44%45' '' '/powershell')
        )
        # ---- MAPI over HTTP of Outlook (dave): front end, then the back-end log of the same requests -------------
        $mbx = '6f1c2a3b-1111-4222-8333-944455566677'; $ci = '{A1B2C3D4-0000-4000-8000-0000000000AA}'
        $outlook = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928; Pro)'
        $script:MapiIds = @{}
        $mapi = { param($min, $rt, $n, $total = 35, $auth = 'Negotiate')
            $id = [guid]::NewGuid().ToString(); $script:MapiIds["$rt$n"] = $id
            ProxyLine @{ DateTime = (T $min); RequestId = $id; ClientRequestId = "R:{9F00AA11-2222-4333-8444-555566667777}:$n;RT:$rt;CI:$($ci):1;CID:<null>"; Protocol = 'Mapi'
                UrlStem = '/mapi/emsmdb/'; AuthenticationType = $auth; IsAuthenticated = $true; AuthenticatedUser = 'CONTOSO\dave'; AnchorMailbox = "MailboxGuid~$mbx"
                UserAgent = $outlook; ClientIpAddress = '10.1.1.40'; ServerHostName = 'EXCH01'; HttpStatus = 200; BackEndStatus = 200; Method = 'POST'
                TargetServer = 'exch01.contoso.test'; RequestBytes = 300; ResponseBytes = 900; TotalRequestTime = $total; UrlQuery = "?MailboxId=$mbx@contoso.test" } }
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Mapi\HttpProxy_2026100108-2.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            # The same Outlook session moves to OAuth (hybrid modern authentication) after its third request.
            (& $mapi 10 'Connect' 1), (& $mapi 10.1 'Execute' 2), (& $mapi 10.2 'Execute' 3), (& $mapi 11 'NotificationWait' 4 60000 'OAuth'), (& $mapi 12 'Execute' 5 35 'OAuth'), (& $mapi 13 'Disconnect' 6 35 'OAuth')
        )
        $beFields = 'DateTime,RequestId,MapiRequestId,ClientRequestId,RequestType,HttpStatusCode,ResponseCode,StatusCode,ReturnCode,TotalRequestLatency,DeploymentRing,MajorVersion,MinorVersion,BuildVersion,RevisionVersion,AuthenticatedUserEmail,UPN,Puid,TenantGuid,MailboxId,MDBGuid,ActAsUserEmail,ClientIP,SourceCafeServer,EdgeInfo,NetworkDeviceInfo,SessionCookie,SequenceCookie,MapiClientInfo,ClientSoftware,ClientSoftwareVersion,ClientMode,AuthenticationType,AuthModuleLatency,LiveIdBasicLog,LiveIdBasicError,LiveIdNegotiateError,OAuthLatency,OAuthError,OAuthErrorCategory,OAuthExtraInfo,AuthenticatedUser,RopIds,OperationSpecific,GenericInfo,GenericErrors'
        $be = { param($min, $rt, $n, $status = 0, $user = 'CONTOSO\dave', $software = 'OUTLOOK.EXE', $ops = '', $err = '')
            $v = @{ DateTime = (T $min); RequestId = $script:MapiIds["$rt$n"]; RequestType = $rt; HttpStatusCode = 200; ResponseCode = 0; StatusCode = $status; ReturnCode = 0
                TotalRequestLatency = 20; AuthenticatedUserEmail = $user; MailboxId = "$mbx@contoso.test"; ClientIP = '10.1.1.40'; SourceCafeServer = 'EXCH01.CONTOSO.TEST'
                SessionCookie = 'MAPIAAAAAOC49bfv3v3P'; MapiClientInfo = "$($ci):1"; ClientSoftware = $software; ClientSoftwareVersion = '16.0.17928.20114'; ClientMode = 'Cached'
                AuthenticatedUser = 'Anonymous'; OperationSpecific = $ops; GenericErrors = $err }
            ($beFields.Split(',') | ForEach-Object { [string]$v[$_] }) -join ',' }
        Write-Log (Join-Path $ex 'Logging\MapiHttp\Mailbox\MapiHttp_2026100108-1.LOG') @(
            "#Fields: $beFields", $beFields
            (& $be 10 'Connect' 1 -ops 'Flags=None;'), (& $be 10.2 'Execute' 3 -status 2147746063 -err 'MapiExceptionNotFound'), (& $be 13 'Disconnect' 6)
            (& $be 14 'Execute' 9 -user 'CONTOSO\HealthMailboxb4dbf9b' -software 'Microsoft.Exchange.RpcClientAccess.Monitoring.dll')
        )
        # ---- ActiveSync of an iPhone (erin): wrong password first (only IIS knows the account), then a sync ---------
        $iphone = 'Apple-iPhone15C2/2107.102'
        $eas = { param($min, $cmd, $method = 'POST')
            ProxyLine @{ DateTime = (T $min); RequestId = [guid]::NewGuid().ToString(); Protocol = 'Eas'; UrlStem = '/Microsoft-Server-ActiveSync/default.eas'; AuthenticationType = 'Basic'
                IsAuthenticated = $true; AuthenticatedUser = 'CONTOSO\erin'; AnchorMailbox = 'Sid~S-1-5-21-1-2-3-1105'; UserAgent = $iphone; ClientIpAddress = '10.1.1.60'
                ServerHostName = 'EXCH01'; HttpStatus = 200; BackEndStatus = 200; Method = $method; TargetServer = 'exch01.contoso.test'; TotalRequestTime = 70
                UrlQuery = $(if ($cmd) { "?Cmd=$cmd&User=erin&DeviceId=ERINPHONE1&DeviceType=iPhone" } else { '' }) } }
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Eas\HttpProxy_2026100108-1.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $eas 15 $null 'OPTIONS'), (& $eas 15.1 'FolderSync'), (& $eas 15.2 'Provision'), (& $eas 15.3 'FolderSync'), (& $eas 16 'Sync')
        )
        # ---- EWS: slow success (grace) and frank, known as CONTOSO\frank before his IMAP logon ---------------------------
        $ews = { param($min, $user, $total, $auth = 'Negotiate')
            ProxyLine @{ DateTime = (T $min); RequestId = [guid]::NewGuid().ToString(); Protocol = 'Ews'; UrlStem = '/EWS/Exchange.asmx'; AuthenticationType = $auth
                IsAuthenticated = $true; AuthenticatedUser = $user; UserAgent = 'MacOutlook/16.89.24091630'; ClientIpAddress = '10.1.1.80'; ServerHostName = 'EXCH01'
                HttpStatus = 200; BackEndStatus = 200; Method = 'POST'; TargetServer = 'exch01.contoso.test'; TotalRequestTime = $total } }
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Ews\HttpProxy_2026100108-2.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $ews 17 'CONTOSO\grace' 8000 'OAuth'), (& $ews 18 'CONTOSO\frank' 50)
        )
        # ---- IMAP4: front end (client address, logon) and back end (each command) -----------------------------------------
        $imapFields = '#Fields: dateTime,sessionId,seqNumber,sIp,cIp,user,duration,rqsize,rpsize,command,parameters,context,puid'
        Write-Log (Join-Path $ex 'Logging\Imap4\IMAP42026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Log-type: IMAP4 Protocol Log', $imapFields
            "$(T 20),0000000000000001,0,10.0.0.1:993,10.1.1.70:50001,,3,0,53,OpenSession,,,"
            "$(T 20),0000000000000001,1,10.0.0.1:993,10.1.1.70:50001,,1,13,158,capability,,R=OK,"
            "$(T 20),0000000000000001,2,10.0.0.1:993,10.1.1.70:50001,,1,17,21,login, *****,""R=""""a2 NO LOGIN failed."""""","
            "$(T 20),0000000000000001,3,10.0.0.1:993,10.1.1.70:50001,,2,9,84,logout,,R=OK,"
            "$(T 21),0000000000000002,0,10.0.0.1:993,10.1.1.70:50002,,4,0,53,OpenSession,,,"
            "$(T 21),0000000000000002,1,10.0.0.1:993,10.1.1.70:50002,,1,13,158,capability,,R=OK,"
            "$(T 21),0000000000000002,2,10.0.0.1:993,10.1.1.70:50002,frank,205,48,24,login,frank@contoso.test *****,""R=OK;Msg=""""Proxy:EXCH01.contoso.test:1993:SSL;ProxySuccess"""""","
            "$(T 22),0000000000000002,3,10.0.0.1:993,10.1.1.70:50002,frank,0,61,458,CloseSession,,,"
            "$(T 23),0000000000000003,0,10.0.0.1:993,168.63.129.16:50003,,1,0,53,OpenSession,,,"
            "$(T 23),0000000000000003,1,10.0.0.1:993,168.63.129.16:50003,,0,0,0,CloseSession,,,"
        )
        Write-Log (Join-Path $ex 'Logging\Imap4\IMAP4BE2026100108-1.LOG') @(
            $imapFields
            "$(T 21),0000000000000001,0,10.0.0.1:1993,10.0.0.1:26747,,91,0,53,OpenSession,,,"
            "$(T 21),0000000000000001,1,10.0.0.1:1993,10.0.0.1:26747,,36,12,195,capability,,R=OK,"
            "$(T 21),0000000000000001,2,10.0.0.1:1993,10.0.0.1:26747,frank,560,31,33,authenticate,PLAIN,R=OK,"
            "$(T 21.1),0000000000000001,3,10.0.0.1:1993,10.0.0.1:26747,frank,148,15,306,select,INBOX,R=OK;Rows=0,"
            "$(T 21.2),0000000000000001,4,10.0.0.1:1993,10.0.0.1:26747,frank,42,30,45,fetch,1:10 (FLAGS ENVELOPE),""R=""""a4 NO The specified message set is invalid."""";Rows=0"","
            "$(T 21.3),0000000000000001,5,10.0.0.1:1993,10.0.0.1:26747,frank,8,9,84,logout,,R=OK,"
            "$(T 21.3),0000000000000001,6,10.0.0.1:1993,10.0.0.1:26747,frank,0,61,458,CloseSession,,,"
        )
        # ---- IIS front end -----------------------------------------------------------------------------------
        $iisFields = '#Fields: date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip cs(User-Agent) cs(Referer) sc-status sc-substatus sc-win32-status sc-bytes cs-bytes time-taken'
        Write-Log (Join-Path $iis 'W3SVC1\u_ex261001.log') @(
            '#Software: Microsoft Internet Information Services 10.0', '#Version: 1.0', "#Date: $(T 0 -W3C)", $iisFields
            "$(T 1 -W3C) ::1 GET /Microsoft-Server-ActiveSync/default.eas &CorrelationID=<empty>;&cafeReqId=$([guid]::NewGuid()); 443 - ::1 AMProbe/Local/ClientAccess - 401 2 5 372 187 11830"
            "$(T 2 -W3C) ::1 GET /Microsoft-Server-ActiveSync/default.eas &CorrelationID=<empty>;&cafeReqId=$([guid]::NewGuid()); 443 HealthMailboxb4dbf9b720d24d5486d5ae616abe6874@contoso.test ::1 AMProbe/Local/ClientAccess - 200 0 0 330 458 766"
            "$(T 7 -W3C) 10.0.0.1 POST /ews/exchange.asmx &CorrelationID=<empty>;&cafeReqId=$($script:FailedRequest); 443 bob@contoso.test 10.1.1.20 ExchangeServicesClient/15.0 - 503 0 1236 400 900 30000"
            "$(T 5 -W3C) 10.0.0.1 POST /mapi/emsmdb/ &CorrelationID=<empty>;&cafeReqId=$([guid]::NewGuid()); 443 CONTOSO\alice 10.1.1.10 Microsoft+Office/16.0 - 200 0 0 400 900 40"
            "$(T 9 -W3C) 10.0.0.1 GET /owa/ - 443 CONTOSO\carol 10.1.1.30 Mozilla/5.0+(Windows+NT+10.0) - 403 4 5 300 200 2"
            "$(T 14 -W3C) 10.0.0.1 POST /Microsoft-Server-ActiveSync/default.eas Cmd=FolderSync&User=erin&DeviceId=ERINPHONE1&DeviceType=iPhone&CorrelationID=<empty>;&cafeReqId=$([guid]::NewGuid()); 443 CONTOSO\erin 10.1.1.60 Apple-iPhone15C2/2107.102 - 401 1 1326 304 354 37"
        )
        # ---- IIS back end (Exchange Back End): ActiveSync result behind the HTTP 200 -------------------------------
        Write-Log (Join-Path $iis 'W3SVC2\u_ex261001.log') @(
            '#Software: Microsoft Internet Information Services 10.0', '#Version: 1.0', "#Date: $(T 0 -W3C)", $iisFields
            "$(T 15 -W3C) 10.0.0.1 POST /Microsoft-Server-ActiveSync/Proxy/default.eas Cmd=FolderSync&User=erin&DeviceId=ERINPHONE1&DeviceType=iPhone&Log=Error:DeviceNotProvisioned_SC1:142_PrxFrom:10.0.0.1_Ver1:140_As:BlockedP_Mbx:EXCH01.contoso.test 444 CONTOSO\erin 10.0.0.1 Apple-iPhone15C2/2107.102 - 200 0 0 300 400 60"
            "$(T 16 -W3C) 10.0.0.1 POST /Microsoft-Server-ActiveSync/Proxy/default.eas Cmd=Sync&User=erin&DeviceId=ERINPHONE1&DeviceType=iPhone&Log=SC1:1_PrxFrom:10.0.0.1_Ver1:140_As:AllowedG 444 CONTOSO\erin 10.0.0.1 Apple-iPhone15C2/2107.102 - 200 0 0 300 400 60"
            "$(T 16 -W3C) 10.0.0.1 POST /ews/exchange.asmx - 444 CONTOSO\erin 10.0.0.1 MacOutlook - 200 0 0 300 400 60"
            "$(T 17 -W3C) 10.0.0.1 GET /Microsoft-Server-ActiveSync/Proxy/default.eas &Log=Ver1:140 444 HealthMailboxb4dbf9b@contoso.test 10.0.0.1 AMProbe/Local/ClientAccess - 200 0 0 300 400 60"
        )
        # ---- SMTP receive (front end) ------------------------------------------------------------------------
        $smtpFields = '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
        $c = 'EXCH01\Default Frontend EXCH01'
        Write-Log (Join-Path $ex 'TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive\RECV2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Version: 15.0.0.0', '#Log-type: SMTP Receive Protocol Log', "#Date: $(T 0)", $smtpFields
            "$(T 1),$c,08DF000000000001,0,10.0.0.1:25,168.63.129.16:64416,+,,"
            "$(T 1),$c,08DF000000000001,1,10.0.0.1:25,168.63.129.16:64416,>,""220 EXCH01.contoso.test Microsoft ESMTP MAIL Service ready"","
            "$(T 1),$c,08DF000000000001,2,10.0.0.1:25,168.63.129.16:64416,-,,Remote(SocketError)"
            "$(T 2),$c,08DF000000000002,0,10.0.0.1:25,10.1.1.50:50001,+,,"
            "$(T 2),$c,08DF000000000002,1,10.0.0.1:25,10.1.1.50:50001,<,EHLO app01.contoso.test,"
            "$(T 2),$c,08DF000000000002,2,10.0.0.1:25,10.1.1.50:50001,<,STARTTLS,"
            "$(T 2),$c,08DF000000000002,3,10.0.0.1:25,10.1.1.50:50001,*,,""TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded using bulk encryption algorithm CALG_AES_256"""
            "$(T 2),$c,08DF000000000002,4,10.0.0.1:25,10.1.1.50:50001,<,MAIL FROM:<alice@contoso.test> SIZE=2048,"
            "$(T 2),$c,08DF000000000002,5,10.0.0.1:25,10.1.1.50:50001,<,RCPT TO:<bob@contoso.test>,"
            "$(T 2),$c,08DF000000000002,6,10.0.0.1:25,10.1.1.50:50001,<,RCPT TO:<carol@contoso.test>,"
            "$(T 2),$c,08DF000000000002,7,10.0.0.1:25,10.1.1.50:50001,<,BDAT 2048 LAST,"
            "$(T 2),$c,08DF000000000002,8,10.0.0.1:25,10.1.1.50:50001,>,""250 2.6.0 <msg-001@contoso.test> [InternalId=1001, Hostname=EXCH01.contoso.test] Queued mail for delivery"","
            "$(T 2),$c,08DF000000000002,9,10.0.0.1:25,10.1.1.50:50001,<,QUIT,"
            "$(T 2),$c,08DF000000000002,10,10.0.0.1:25,10.1.1.50:50001,-,,Local"
            "$(T 3),$c,08DF000000000003,0,10.0.0.1:25,10.1.1.51:50002,+,,"
            "$(T 3),$c,08DF000000000003,1,10.0.0.1:25,10.1.1.51:50002,<,MAIL FROM:<HealthMailboxb4dbf9b@contoso.test>,"
            "$(T 3),$c,08DF000000000003,2,10.0.0.1:25,10.1.1.51:50002,<,RCPT TO:<HealthMailboxff42d4a@contoso.test>,"
            "$(T 3),$c,08DF000000000003,3,10.0.0.1:25,10.1.1.51:50002,-,,Local"
            "$(T 4),$c,08DF000000000004,0,10.0.0.1:25,203.0.113.9:40000,+,,"
            "$(T 4),$c,08DF000000000004,1,10.0.0.1:25,203.0.113.9:40000,<,MAIL FROM:<spam@example.net>,"
            "$(T 4),$c,08DF000000000004,2,10.0.0.1:25,203.0.113.9:40000,<,RCPT TO:<nobody@contoso.test>,"
            "$(T 4),$c,08DF000000000004,3,10.0.0.1:25,203.0.113.9:40000,>,550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipient not found,"
            "$(T 4),$c,08DF000000000004,4,10.0.0.1:25,203.0.113.9:40000,-,,Local"
            # Authenticated submission (587): the front end hands the session over to a mailbox server after AUTH.
            "$(T 5),EXCH01\Client Frontend EXCH01,08DF000000000005,0,10.0.0.1:587,10.1.1.70:50100,+,,"
            "$(T 5),EXCH01\Client Frontend EXCH01,08DF000000000005,1,10.0.0.1:587,10.1.1.70:50100,<,EHLO thunderbird.contoso.test,"
            "$(T 5),EXCH01\Client Frontend EXCH01,08DF000000000005,2,10.0.0.1:587,10.1.1.70:50100,<,AUTH LOGIN,"
            "$(T 5),EXCH01\Client Frontend EXCH01,08DF000000000005,3,10.0.0.1:587,10.1.1.70:50100,*,,Proxy session was successfully set up. Session forfrank@contoso.test will now be proxied"
            "$(T 5),EXCH01\Client Frontend EXCH01,08DF000000000005,4,10.0.0.1:587,10.1.1.70:50100,>,235 2.7.0 Authentication successful,"
            "$(T 5),EXCH01\Client Frontend EXCH01,08DF000000000005,5,10.0.0.1:587,10.1.1.70:50100,-,,Local"
        )
        # ---- SMTP receive (hub, client proxy): the proxied submission, with XPROXY ---------------------------------
        $cp = 'EXCH01\Client Proxy EXCH01'
        Write-Log (Join-Path $ex 'TransportRoles\Logs\Hub\ProtocolLog\SmtpReceive\RECV2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Log-type: SMTP Receive Protocol Log', $smtpFields
            "$(T 5),$cp,08DF000000000200,0,10.0.0.1:465,10.0.0.1:41500,+,,"
            "$(T 5),$cp,08DF000000000200,1,10.0.0.1:465,10.0.0.1:41500,<,EHLO EXCH01.contoso.test,"
            "$(T 5),$cp,08DF000000000200,2,10.0.0.1:465,10.0.0.1:41500,<,X-EXPS EXCHANGEAUTH,"
            "$(T 5),$cp,08DF000000000200,3,10.0.0.1:465,10.0.0.1:41500,<,XPROXY SID=08DF000000000005 IP=10.1.1.70 PORT=50100 DOMAIN=thunderbird.contoso.test CAPABILITIES=0,"
            "$(T 5),$cp,08DF000000000200,4,10.0.0.1:465,10.0.0.1:41500,<,MAIL FROM:<frank@contoso.test>,"
            "$(T 5),$cp,08DF000000000200,5,10.0.0.1:465,10.0.0.1:41500,<,RCPT TO:<bob@contoso.test>,"
            "$(T 5),$cp,08DF000000000200,6,10.0.0.1:465,10.0.0.1:41500,<,DATA,"
            "$(T 5),$cp,08DF000000000200,7,10.0.0.1:465,10.0.0.1:41500,>,""250 2.6.0 <msg-003@contoso.test> [InternalId=3003, Hostname=EXCH01.contoso.test] Queued mail for delivery"","
            "$(T 5),$cp,08DF000000000200,8,10.0.0.1:465,10.0.0.1:41500,-,,Local"
        )
        # ---- SMTP send (hub) ------------------------------------------------------------------------------------
        $h = 'Intra-Organization SMTP Send Connector'
        Write-Log (Join-Path $ex 'TransportRoles\Logs\Hub\ProtocolLog\SmtpSend\SEND2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Log-type: SMTP Send Protocol Log', $smtpFields
            "$(T 2.1),$h,08DF000000000100,0,10.0.0.1:41000,10.0.0.2:2525,+,,"
            "$(T 2.1),$h,08DF000000000100,1,10.0.0.1:41000,10.0.0.2:2525,>,EHLO EXCH01.contoso.test,"
            "$(T 2.1),$h,08DF000000000100,2,10.0.0.1:41000,10.0.0.2:2525,*,,sending message with RecordId 12345 and InternetMessageId <msg-001@contoso.test>"
            "$(T 2.1),$h,08DF000000000100,3,10.0.0.1:41000,10.0.0.2:2525,>,MAIL FROM:<alice@contoso.test> SIZE=2048,"
            "$(T 2.1),$h,08DF000000000100,4,10.0.0.1:41000,10.0.0.2:2525,>,RCPT TO:<bob@contoso.test>,"
            "$(T 2.1),$h,08DF000000000100,5,10.0.0.1:41000,10.0.0.2:2525,>,BDAT 2048 LAST,"
            "$(T 2.1),$h,08DF000000000100,6,10.0.0.1:41000,10.0.0.2:2525,<,""250 2.6.0 <msg-001@contoso.test> [InternalId=2002, Hostname=EXCH02.contoso.test] Queued mail for delivery"","
            "$(T 2.1),$h,08DF000000000100,7,10.0.0.1:41000,10.0.0.2:2525,-,,Local"
            # Delivery to the mailbox server (port 475): the Message-ID is only in the "250 2.0.0 OK <id>" response.
            "$(T 2.2),Mailbox Delivery,08DF000000000101,0,10.0.0.1:41001,10.0.0.2:475,+,,"
            "$(T 2.2),Mailbox Delivery,08DF000000000101,1,10.0.0.1:41001,10.0.0.2:475,>,EHLO EXCH01.contoso.test,"
            "$(T 2.2),Mailbox Delivery,08DF000000000101,2,10.0.0.1:41001,10.0.0.2:475,>,MAIL FROM:<alice@contoso.test>,"
            "$(T 2.2),Mailbox Delivery,08DF000000000101,3,10.0.0.1:41001,10.0.0.2:475,>,RCPT TO:<bob@contoso.test>,"
            "$(T 2.2),Mailbox Delivery,08DF000000000101,4,10.0.0.1:41001,10.0.0.2:475,>,BDAT 2048 LAST,"
            "$(T 2.2),Mailbox Delivery,08DF000000000101,5,10.0.0.1:41001,10.0.0.2:475,<,250 2.0.0 OK <msg-001@contoso.test> [Hostname=EXCH02.contoso.test],"
            "$(T 2.2),Mailbox Delivery,08DF000000000101,6,10.0.0.1:41001,10.0.0.2:475,-,,Local"
        )
        # ---- Message tracking -------------------------------------------------------------------------------------
        $trkFields = '#Fields: date-time,client-ip,client-hostname,server-ip,server-hostname,source-context,connector-id,source,event-id,internal-message-id,message-id,network-message-id,recipient-address,recipient-status,total-bytes,recipient-count,related-recipient-address,reference,message-subject,sender-address,return-path,message-info,directionality,tenant-id,original-client-ip,original-server-ip,custom-data,transport-traffic-type,log-id,schema-version'
        $m = { param($min, $evt, $src, $rcpt, $status, $id = '<msg-001@contoso.test>', $sender = 'alice@contoso.test', $subject = 'Quarterly figures', $client = 'app01.contoso.test', $server = '', $connector = '')
            "$(T $min),10.1.1.50,$client,10.0.0.2,$server,08DF000000000002;$(T $min);0,$connector,$src,$evt,1001,$id,net-0001,$rcpt,$status,2048,2,,,$subject,$sender,$sender,,Originating,,,,,Email,$([guid]::NewGuid()),15.02.2562.045" }
        Write-Log (Join-Path $ex 'TransportRoles\Logs\MessageTracking\MSGTRK2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Version: 15.02.2562.045', '#Log-type: Message Tracking Log', "#Date: $(T 0)", $trkFields
            (& $m 2 'RECEIVE' 'SMTP' 'bob@contoso.test;carol@contoso.test' '' -connector 'EXCH01\Default EXCH01')
            (& $m 2.05 'HARECEIVE' 'SMTP' 'bob@contoso.test;carol@contoso.test' '')
            (& $m 2.1 'SEND' 'SMTP' 'bob@contoso.test' '250 2.6.0 Queued' -server 'EXCH02.contoso.test' -connector 'Intra-Organization SMTP Send Connector')
            (& $m 2.2 'FAIL' 'ROUTING' 'carol@contoso.test' '550 5.1.1 RESOLVER.ADR.ExRecipNotFound; not found')
            (& $m 3 'RECEIVE' 'SMTP' 'healthmailboxff42d4a@contoso.test' '' '<probe-1@contoso.test>' 'healthmailboxb4dbf9b@contoso.test' 'Probe')
            (& $m 4 'RECEIVE' 'STOREDRIVER' 'dave@contoso.test' '' '<msg-002@contoso.test>' 'bob@contoso.test' 'Lunch')
            (& $m 4.1 'DELIVER' 'STOREDRIVER' 'dave@contoso.test' '' '<msg-002@contoso.test>' 'bob@contoso.test' 'Lunch')
        )
        Write-Log (Join-Path $ex 'TransportRoles\Logs\MessageTracking\MSGTRKMD2026100108-1.LOG') @(
            $trkFields
            (& $m 2.3 'DELIVER' 'STOREDRIVER' 'bob@contoso.test' '250 2.0.0 Delivered' -server 'EXCH02')
        )
        return [pscustomobject]@{ Exchange = $ex; Iis = $iis }
    }

    function New-TestConfig([string]$Directory, [hashtable]$Replace = @{}) {
        $logs = New-TestLogs (Join-Path $Directory 'logs-src')
        $text = [IO.File]::ReadAllText((Join-Path $script:Root 'config\ExchangeLogReport.config.psd1'))
        $servers = "Servers = @(`r`n        @{ Name = 'EXCH01'; ExchangePath = '$($logs.Exchange)'; IisLogPath = '$($logs.Iis)' }`r`n        @{ Name = 'EXCH02'; ExchangePath = '$Directory\missing\EXCH02'; IisLogPath = '$Directory\missing\EXCH02\iis' }`r`n    )"
        $text = [regex]::Replace($text, "(?ms)^    Servers = @\(.*?^    \)", $servers.Replace('$', '$$'))
        $text = $text.Replace("'.\data\ExchangeLogReport.sqlite'", "'$Directory\data\test.sqlite'").Replace("Path          = '.\logs'", "Path          = '$Directory\toollogs'").Replace("OutputPath            = '.\reports'", "OutputPath            = '$Directory\reports'").Replace('StaleSourceHours       = 24', 'StaleSourceHours       = 0')
        foreach ($k in $Replace.Keys) { $text = $text.Replace($k, $Replace[$k]) }
        $path = Join-Path $Directory 'test.config.psd1'
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
        return $path
    }

    function Invoke-TestCollection($Settings) {
        $store = Open-ExlStore -Settings $Settings
        try {
            $run = $store.StartRun('Collect', 'test', 'test', '1.0.0')
            $result = & (Get-Module ExchangeLogReport) { param($s, $st, $r) Invoke-ExlCollection -Store $st -Settings $s -RunId $r -Servers @($s.Servers[0]) 6>$null } $Settings $store $run
            $store.EndRun($run, 'Completed', $result.Files, $result.Bytes, $result.Lines, $result.Kept, $result.Noise, $null)
            return $result
        } finally { $store.Dispose() }
    }

    function Query($Settings, [string]$Sql) {
        $store = Open-ExlStore -Settings $Settings -ReadOnly
        try { return , $store.Query($Sql, $null).Rows } finally { $store.Dispose() }
    }

    $script:Dir = Join-Path $TestDrive 'main'
    [void][IO.Directory]::CreateDirectory($script:Dir)
    $script:ConfigPath = New-TestConfig $script:Dir @{ 'FullDetailUsers        = @()' = "FullDetailUsers        = @('alice@contoso.test')"; 'PopImap         = $false' = 'PopImap         = $true' }
    $script:Settings = Import-ExlConfiguration -Path $script:ConfigPath -Root $script:Root
    $script:First = Invoke-TestCollection $script:Settings
}

Describe 'SMTP memory instrumentation' {
    BeforeAll {
        if (-not ('SmtpProcessMemory' -as [type])) {
            Add-Type -LiteralPath (Join-Path $PSScriptRoot 'SmtpProcessMemory.cs')
        }
    }

    It 'reads private commit without allocating managed garbage in the sampling loop' {
        [SmtpProcessMemory]::ReadAllocations(1000) | Should -Be 0
    }

    It 'measures the same private-commit quantity as the existing process counter' {
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $process.Refresh()
            $reference = $process.PrivateMemorySize64
            $actual = [SmtpProcessMemory]::PrivateBytes()
            $actual | Should -BeGreaterThan 0
            [Math]::Abs($actual - $reference) | Should -BeLessThan 4MB
        } finally { $process.Dispose() }
    }
}

Describe 'Configuration' {
    It 'loads the delivered configuration with the default retention (60 days, details and logs 14 days)' {
        $s = Import-ExlConfiguration -Path (Join-Path $script:Root 'config\ExchangeLogReport.config.psd1') -Root $script:Root
        $s.Storage.RetentionDays | Should -Be 60
        $s.Storage.DetailRetentionDays | Should -Be 14
        $s.Logging.RetentionDays | Should -Be 14
        $s.Report.MemoryBudgetMB | Should -Be 512
        $s.Report.Parallelism | Should -Be 0
        $s.Servers[0].HttpProxyPath | Should -Be '\\EXCH01\c$\Program Files\Microsoft\Exchange Server\V15\Logging\HttpProxy'
    }
    It 'reports every invalid value at once' {
        $path = Join-Path $TestDrive 'bad.psd1'
        (Get-Content $script:ConfigPath -Raw).Replace('DetailRetentionDays = 14', 'DetailRetentionDays = 90').Replace("DefaultType           = 'Usage'", "DefaultType           = 'Full'") | Set-Content -LiteralPath $path
        { Import-ExlConfiguration -Path $path -Root $script:Root } | Should -Throw -ExpectedMessage '*DetailRetentionDays*DefaultType*'
    }
    It 'validates report memory and workers independently of collection settings' {
        $path = Join-Path $TestDrive 'bad-report-budget.psd1'
        (Get-Content $script:ConfigPath -Raw).Replace('MemoryBudgetMB        = 512', 'MemoryBudgetMB        = 32').
            Replace('Parallelism           = 0', 'Parallelism           = 17') | Set-Content -LiteralPath $path
        { Import-ExlConfiguration -Path $path -Root $script:Root } | Should -Throw '*Report.MemoryBudgetMB*Report.Parallelism*'
    }
    It 'keeps old configurations compatible when report budget settings are absent' {
        $path = Join-Path $TestDrive 'old-report-budget.psd1'
        $text = Get-Content $script:ConfigPath -Raw
        $text = [regex]::Replace($text, '(?m)^\s*MemoryBudgetMB\s*=.*\r?\n', '')
        $text = [regex]::Replace($text, '(?m)^\s*Parallelism           =.*\r?\n', '')
        [IO.File]::WriteAllText($path, $text)
        $s = Import-ExlConfiguration -Path $path -Root $script:Root
        $s.Report.MemoryBudgetMB | Should -Be 512
        $s.Report.Parallelism | Should -Be 0
    }
    It 'defaults to Auto layout, a 200 MB single-file limit, every row and the work file in the report folder, and validates the new Report keys' {
        $s = Import-ExlConfiguration -Path $script:ConfigPath -Root $script:Root
        $s.Report.HtmlLayout | Should -Be 'Auto'
        $s.Report.SingleFileMaxMB | Should -Be 200
        $s.Report.MaxHtmlRows | Should -Be 0
        $s.Report.ScratchFolder | Should -BeNullOrEmpty
        # An old configuration without the keys gets the same values.
        $old = Join-Path $TestDrive 'old-layout.psd1'
        $text = [regex]::Replace((Get-Content $script:ConfigPath -Raw), '(?m)^\s*(HtmlLayout|SingleFileMaxMB|MaxHtmlRows|ScratchFolder)\s*=.*\r?\n', '')
        [IO.File]::WriteAllText($old, $text)
        $o = Import-ExlConfiguration -Path $old -Root $script:Root
        @($o.Report.HtmlLayout, $o.Report.SingleFileMaxMB, $o.Report.MaxHtmlRows) | Should -Be @('Auto', 200, 0)
        # Case is normalised; every wrong value is reported.
        $good = Join-Path $TestDrive 'layout-case.psd1'
        [IO.File]::WriteAllText($good, (Get-Content $script:ConfigPath -Raw).Replace("HtmlLayout            = 'Auto'", "HtmlLayout            = 'folder'"))
        (Import-ExlConfiguration -Path $good -Root $script:Root).Report.HtmlLayout | Should -Be 'Folder'
        $bad = Join-Path $TestDrive 'layout-bad.psd1'
        $text = (Get-Content $script:ConfigPath -Raw).Replace("HtmlLayout            = 'Auto'", "HtmlLayout            = 'Both'").Replace('SingleFileMaxMB       = 200', 'SingleFileMaxMB       = 0').Replace('MaxHtmlRows           = 0 ', 'MaxHtmlRows           = 500 ')
        [IO.File]::WriteAllText($bad, $text)
        $err = $null; try { Import-ExlConfiguration -Path $bad -Root $script:Root } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Report.HtmlLayout must be one of: Auto, SingleFile, Folder'
        $err | Should -Match 'Report.SingleFileMaxMB must be a whole number between 1 and 4096'
        $err | Should -Match 'Report.MaxHtmlRows must be 0 \(every row\) or between 1000 and 2000000'
    }
}

Describe 'Time zone compatibility' {
    It 'delivers and defaults to the native Windows Paris zone' {
        $s = Import-ExlConfiguration -Path (Join-Path $script:Root 'config\ExchangeLogReport.config.psd1') -Root $script:Root
        $s.Report.TimeZone | Should -Be 'Romance Standard Time'
        $path = Join-Path $TestDrive 'missing-timezone.psd1'
        $text = Get-Content -LiteralPath $script:ConfigPath -Raw
        $text = [regex]::Replace($text, '(?m)^\s*TimeZone\s*=.*\r?\n', '')
        [IO.File]::WriteAllText($path, $text)
        $s = Import-ExlConfiguration -Path $path -Root $script:Root
        $s.Report.TimeZone | Should -Be 'Romance Standard Time'
        $s.Zone.GetUtcOffset([DateTimeOffset]'2026-01-15T12:00:00Z').TotalHours | Should -Be 1
        $s.Zone.GetUtcOffset([DateTimeOffset]'2026-07-15T12:00:00Z').TotalHours | Should -Be 2
    }
    It 'preserves an explicitly configured IANA Paris zone' {
        $path = Join-Path $TestDrive 'explicit-iana-timezone.psd1'
        $text = (Get-Content -LiteralPath $script:ConfigPath -Raw).Replace(
            "TimeZone              = 'Romance Standard Time'", "TimeZone              = 'Europe/Paris'")
        [IO.File]::WriteAllText($path, $text)
        $s = Import-ExlConfiguration -Path $path -Root $script:Root
        $s.Report.TimeZone | Should -Be 'Europe/Paris'
        $s.Zone.GetUtcOffset([DateTimeOffset]'2026-01-15T12:00:00Z').TotalHours | Should -Be 1
        $s.Zone.GetUtcOffset([DateTimeOffset]'2026-07-15T12:00:00Z').TotalHours | Should -Be 2
    }
    It 'preserves the Paris winter/summer offsets and refuses an unknown zone' {
        $zone = Get-ExlTimeZone 'Europe/Paris'
        $zone.GetUtcOffset([DateTimeOffset]'2026-01-15T12:00:00Z').TotalHours | Should -Be 1
        $zone.GetUtcOffset([DateTimeOffset]'2026-07-15T12:00:00Z').TotalHours | Should -Be 2
        (Get-ExlTimeZone 'Romance Standard Time').GetUtcOffset([DateTimeOffset]'2026-07-15T12:00:00Z').TotalHours | Should -Be 2
        { Get-ExlTimeZone 'Unknown/NotAZone' } | Should -Throw "*Unknown time zone 'Unknown/NotAZone'*"
    }
    It 'resolves the delivered default with Windows NLS and no IANA conversion' -Skip:(-not $IsWindows) {
        $saved = $env:DOTNET_SYSTEM_GLOBALIZATION_USENLS
        try {
            $env:DOTNET_SYSTEM_GLOBALIZATION_USENLS = '1'
            $module = Join-Path $script:Root 'ExchangeLogReport.psd1'
            $config = Join-Path $script:Root 'config\ExchangeLogReport.config.psd1'
            $code = @"
`$ErrorActionPreference='Stop'
try { [void][TimeZoneInfo]::FindSystemTimeZoneById('Europe/Paris'); throw 'NLS reproduction did not disable IANA lookup.' }
catch [TimeZoneNotFoundException] { }
Import-Module '$module'
`$s=Import-ExlConfiguration -Path '$config' -Root '$script:Root'
if (`$s.Report.TimeZone -ne 'Romance Standard Time') { throw 'The delivered timezone is not the native Windows default.' }
if (`$s.Zone.Id -ne 'Romance Standard Time') { throw 'Native Paris timezone was not resolved.' }
if (`$s.Zone.GetUtcOffset([DateTimeOffset]'2026-01-15T12:00:00Z').TotalHours -ne 1) { throw 'Wrong winter offset.' }
if (`$s.Zone.GetUtcOffset([DateTimeOffset]'2026-07-15T12:00:00Z').TotalHours -ne 2) { throw 'Wrong summer offset.' }
'NLS default configuration accepted'
"@
            $output = & pwsh -NoProfile -Command $code 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
            $output | Should -Match 'NLS default configuration accepted'
        } finally { $env:DOTNET_SYSTEM_GLOBALIZATION_USENLS = $saved }
    }
}

Describe 'Log paths' {
    BeforeAll {
        $script:PathsDir = Join-Path $TestDrive 'paths'
        [void][IO.Directory]::CreateDirectory($script:PathsDir)
        $text = [IO.File]::ReadAllText((Join-Path $script:Root 'config\ExchangeLogReport.config.psd1'))
        $servers = "Servers = @(`r`n        @{ Name = 'exch01'; MessageTrackingPath = 'E:\Forced\Tracking' }`r`n        @{ Name = 'EXCH02'; ExchangePath = 'D:\Exchange' }`r`n        @{ Name = 'EXCH03' }`r`n    )"
        $text = [regex]::Replace($text, "(?ms)^    Servers = @\(.*?^    \)", $servers.Replace('$', '$$'))
        $script:PathsConfig = Join-Path $script:PathsDir 'ExchangeLogReport.config.psd1'
        [IO.File]::WriteAllText($script:PathsConfig, $text, [Text.UTF8Encoding]::new($true))
        $paths = @"
@{
    Discovered = '2026-10-01T21:30:00+02:00'
    By         = 'CONTOSO\admin'
    Via        = 'EXCH01'
    Collector  = 'COLLECTOR'
    Servers    = @{
        'EXCH01' = @{
            ExchangePath        = '\\EXCH01\D$\Exchange'
            HttpProxyPath       = '\\EXCH01\D$\Exchange\Logging\HttpProxy'
            HubReceivePath      = '\\EXCH01\L$\Logs\Hub\Receive'
            MessageTrackingPath = '\\EXCH01\L$\Logs\Tracking'
            IisFrontEndPath     = '\\EXCH01\L$\IIS\W3SVC1'
            ImapProtocolLog     = `$false
            PopProtocolLog      = `$true
        }
        'EXCH02' = @{
            HubSendPath         = '\\EXCH02\L$\Logs\Hub\Send'
        }
    }
}
"@
        [IO.File]::WriteAllText((Join-Path $script:PathsDir 'ExchangeLogReport.paths.psd1'), $paths, [Text.UTF8Encoding]::new($true))
        $script:Paths = Import-ExlConfiguration -Path $script:PathsConfig -Root $script:Root
    }
    It 'takes a folder of the Servers block first, then the paths found by -Mode Discover, then the default folder' {
        $s = $script:Paths.Servers[0]
        $s.Name | Should -Be 'EXCH01'
        $s.MessageTrackingPath | Should -Be 'E:\Forced\Tracking'
        $s.Origin.MessageTrackingPath | Should -Be 'Configuration'
        $s.HubReceivePath | Should -Be '\\EXCH01\L$\Logs\Hub\Receive'
        $s.Origin.HubReceivePath | Should -Be 'Discover'
        $s.IisFrontEndPath | Should -Be '\\EXCH01\L$\IIS\W3SVC1'
        $s.MapiHttpPath | Should -Be '\\EXCH01\D$\Exchange\Logging\MapiHttp\Mailbox'
        $s.HubSendPath | Should -Be '\\EXCH01\D$\Exchange\TransportRoles\Logs\Hub\ProtocolLog\SmtpSend'
        $s.Origin.HubSendPath | Should -Be 'Default'
        $s.IisBackEndPath | Should -Be '\\EXCH01\c$\inetpub\logs\LogFiles\W3SVC2'
        $s.ImapProtocolLog | Should -BeFalse
        $s.PopProtocolLog | Should -BeTrue
        $script:Paths.Discovery.Collector | Should -Be 'COLLECTOR'
    }
    It 'derives the other folders from a root set in the Servers block, or from the default installation' {
        $two = $script:Paths.Servers[1]
        $two.HubSendPath | Should -Be '\\EXCH02\L$\Logs\Hub\Send'
        $two.HttpProxyPath | Should -Be 'D:\Exchange\Logging\HttpProxy'
        $two.FrontEndReceivePath | Should -Be 'D:\Exchange\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive'
        $three = $script:Paths.Servers[2]
        $three.Discovered | Should -BeFalse
        $three.MessageTrackingPath | Should -Be '\\EXCH03\c$\Program Files\Microsoft\Exchange Server\V15\TransportRoles\Logs\MessageTracking'
        $three.ImapProtocolLog | Should -BeNullOrEmpty
        (Get-ExlPathOrigin $three) | Should -BeLike 'default paths*'
        (Get-ExlPathOrigin $script:Paths.Servers[0]) | Should -Be 'paths from -Mode Discover and the configuration'
    }
    It 'reads every source from its own folder' {
        $sources = Get-ExlSources $script:Paths.Servers[0] $script:Paths
        ($sources | Where-Object { $_.Kind -eq 'SmtpReceive' -and $_.Role -eq 'Hub' }).Folder | Should -Be '\\EXCH01\L$\Logs\Hub\Receive'
        ($sources | Where-Object Kind -eq 'Tracking').Folder | Should -Be 'E:\Forced\Tracking'
        ($sources | Where-Object Kind -eq 'Iis').Folder | Should -Be '\\EXCH01\L$\IIS\W3SVC1'
    }
    It 'rejects an unknown setting in a Servers block' {
        $path = Join-Path $script:PathsDir 'unknown.config.psd1'
        (Get-Content $script:PathsConfig -Raw).Replace("@{ Name = 'EXCH03' }", "@{ Name = 'EXCH03'; TrackingPath = 'X:\' }") | Set-Content -LiteralPath $path
        { Import-ExlConfiguration -Path $path -Root $script:Root } | Should -Throw -ExpectedMessage '*TrackingPath is not a known setting*'
    }
    It 'turns a folder of another server into its administrative share, and keeps local and UNC paths' {
        & (Get-Module ExchangeLogReport) {
            ConvertTo-ExlRemotePath -Server 'EXCH02' -Path 'D:\Logs\Hub\' | Should -Be '\\EXCH02\D$\Logs\Hub'
            ConvertTo-ExlRemotePath -Server 'EXCH02' -Path 'D:\Logs\Hub' -Local | Should -Be 'D:\Logs\Hub'
            ConvertTo-ExlRemotePath -Server 'EXCH02' -Path '\\NAS\Logs' | Should -Be '\\NAS\Logs'
        }
    }
    It 'reads the Exchange settings with Windows PowerShell 5.1 (the Exchange cmdlets do not run in PowerShell 7)' {
        $helper = Join-Path $script:Root 'src\Get-ExlExchangeSettings.ps1'
        $tokens = $null; $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $text = Get-Content -LiteralPath $helper -Raw
        $text | Should -Match '#Requires -Version 5\.1'
        $text | Should -Not -Match '\?\?|\?\.|\s\?\s.+\s:\s'
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = Join-Path $TestDrive 'never.json'
        $result = & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -OutFile $out -ConnectTo 'exch-does-not-exist.invalid' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $result | Should -Match 'Exchange remote PowerShell could not be opened'
        Test-Path -LiteralPath $out | Should -BeFalse
        # Its helper functions, run in Windows PowerShell 5.1 (.NET Framework overloads differ from PowerShell 7).
        $ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$null, [ref]$null)
        $functions = ($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
        $probe = $functions + "`n" + @'
Get-Leaf 'contoso.com/Configuration/Sites/Paris'
Get-Leaf ([pscustomobject]@{ Name = 'EXCH01' })
Get-PathText ([pscustomobject]@{ PathName = 'E:\Logs\Tracking' })
Get-PathText '  D:\Logs\Hub  '
Get-VersionText 'Version 15.2 (Build 2562.17)'
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $lines = @(& $windowsPowerShell -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" })
        $lines | Should -Be @('PARIS', 'EXCH01', 'E:\Logs\Tracking', 'D:\Logs\Hub', '15.2.2562.17')
    }
    It 'reads the log folder of each IIS site from applicationHost.config' {
        $file = Join-Path $script:PathsDir 'applicationHost.config'
        @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.applicationHost>
    <log centralLogFileMode="Site" />
    <sites>
      <site name="Default Web Site" id="1"><logFile directory="L:\IISLogs" /></site>
      <site name="Exchange Back End" id="2"></site>
      <siteDefaults><logFile logFormat="W3C" directory="%SystemDrive%\inetpub\logs\LogFiles" /></siteDefaults>
    </sites>
  </system.applicationHost>
</configuration>
'@ | Set-Content -LiteralPath $file
        $iis = & (Get-Module ExchangeLogReport) { param($f) Get-ExlIisLogFolders -Server 'EXCH02' -File $f } $file
        $iis.Central | Should -Be 'Site'
        ($iis.Sites | Where-Object Name -eq 'Default Web Site').Folder | Should -Be 'L:\IISLogs\W3SVC1'
        ($iis.Sites | Where-Object Name -eq 'Exchange Back End').Folder | Should -Be 'C:\inetpub\logs\LogFiles\W3SVC2'
        ($iis.Sites | Where-Object Name -eq 'Exchange Back End').Format | Should -Be 'W3C'
    }
    Context 'Exchange IIS sites' {
        BeforeAll {
            Mock -ModuleName ExchangeLogReport Get-ExlApplicationLogMap { [pscustomobject]@{ Entries = @(); Failed = @(); Problems = @() } }
            # Virtual directories as created by Exchange setup, plus a custom OWA/ECP site and a site that is not Exchange.
            $fe = 'C:\Program Files\Microsoft\Exchange Server\V15\FrontEnd\HttpProxy'
            $be = 'C:\Program Files\Microsoft\Exchange Server\V15\ClientAccess'
            $script:AppHost = Join-Path $script:PathsDir 'applicationHost.exchange.config'
            $script:WriteAppHost = {
                param([string]$CustomDirectory = 'E:\IISLogs', [switch]$NoCustom, [string]$DefaultDirectory = 'E:\IISLogs')
                $custom = if ($NoCustom) { '' } else { @"
      <site name="OWA External" id="3">
        <application path="/" applicationPool="DefaultAppPool"><virtualDirectory path="/" physicalPath="C:\inetpub\owaext" /></application>
        <application path="/owa" applicationPool="MSExchangeOWAAppPool"><virtualDirectory path="/" physicalPath="$fe\owa" /></application>
        <application path="/ecp" applicationPool="MSExchangeECPAppPool"><virtualDirectory path="/" physicalPath="$fe\ecp" /></application>
        <logFile directory="$CustomDirectory" />
      </site>
"@ }
                @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.applicationHost>
    <log><centralW3CLogFile enabled="true" directory="%SystemDrive%\inetpub\logs\LogFiles" /></log>
    <sites>
      <site name="Default Web Site" id="1">
        <application path="/" applicationPool="MSExchangeOWAAppPool"><virtualDirectory path="/" physicalPath="%SystemDrive%\inetpub\wwwroot" /></application>
        <application path="/owa" applicationPool="MSExchangeOWAAppPool"><virtualDirectory path="/" physicalPath="$fe\owa" /></application>
        <application path="/owa/Calendar" applicationPool="MSExchangeOWACalendarAppPool"><virtualDirectory path="/" physicalPath="$fe\owa" /></application>
        <application path="/EWS" applicationPool="MSExchangeServicesAppPool"><virtualDirectory path="/" physicalPath="$fe\EWS" /></application>
        <application path="/Microsoft-Server-ActiveSync" applicationPool="MSExchangeSyncAppPool"><virtualDirectory path="/" physicalPath="$fe\sync" /></application>
        <application path="/mapi" applicationPool="MSExchangeMapiFrontEndAppPool"><virtualDirectory path="/" physicalPath="$fe\mapi" /></application>
        <logFile directory="$DefaultDirectory" />
      </site>
      <site name="Exchange Back End" id="2">
        <application path="/"><virtualDirectory path="/" physicalPath="$be" /></application>
        <application path="/mapi/emsmdb" applicationPool="MSExchangeMapiMailboxAppPool"><virtualDirectory path="/" physicalPath="$be\mapi\emsmdb" /></application>
        <application path="/Microsoft-Server-ActiveSync" applicationPool="MSExchangeSyncAppPool"><virtualDirectory path="/" physicalPath="$be\sync" /></application>
        <application path="/Rpc" applicationPool="MSExchangeRpcProxyAppPool"><virtualDirectory path="/" physicalPath="%windir%\System32\RpcProxy" /></application>
      </site>
$custom      <site name="Intranet" id="4">
        <application path="/" applicationPool="DefaultAppPool"><virtualDirectory path="/" physicalPath="C:\inetpub\intranet" /></application>
        <logFile logFormat="IIS" />
      </site>
      <siteDefaults><logFile logFormat="W3C" directory="%SystemDrive%\inetpub\logs\LogFiles" /></siteDefaults>
    </sites>
  </system.applicationHost>
</configuration>
"@ | Set-Content -LiteralPath $script:AppHost
            }
        }
        It 'finds the Exchange sites from their virtual directories, custom OWA/ECP sites included' {
            & $script:WriteAppHost
            $map = & (Get-Module ExchangeLogReport) { param($f) Get-ExlIisSiteMap -Server 'EXCH01' -File $f } $script:AppHost
            $map.IisFrontEndPath | Should -Be '\\EXCH01\E$\IISLogs\W3SVC1'
            $map.IisBackEndPath | Should -Be '\\EXCH01\C$\inetpub\logs\LogFiles\W3SVC2'
            @($map.Custom).Count | Should -Be 1
            $map.Custom[0].Name | Should -Be 'OWA External'
            $map.Custom[0].Role | Should -Be 'FrontEnd'
            $map.Custom[0].Vdirs | Should -Be 'owa, ecp'
            $map.Custom[0].Folder | Should -Be '\\EXCH01\E$\IISLogs\W3SVC3'
            $map.Problems | Should -BeNullOrEmpty
            $iis = & (Get-Module ExchangeLogReport) { param($f) Get-ExlIisLogFolders -Server 'EXCH01' -File $f } $script:AppHost
            ($iis.Sites | Where-Object Name -eq 'Exchange Back End').Vdirs | Should -Be 'mapi, Microsoft-Server-ActiveSync, Rpc'
            ($iis.Sites | Where-Object Name -eq 'Intranet').Role | Should -BeNullOrEmpty
        }
        It 'reads a custom front-end site with the IIS front end, and writes it to the paths file' {
            $iis = & (Get-Module ExchangeLogReport) {
                param($settings)
                $server = Resolve-ExlServerPaths -Name 'EXCH01' -Discovered @{ IisFrontEndPath = '\\EXCH01\E$\IISLogs\W3SVC1'; IisCustomSites = @(@{ Name = 'OWA External'; Id = '3'; Role = 'FrontEnd'; Vdirs = 'owa, ecp'; Folder = '\\EXCH01\E$\IISLogs\W3SVC3' }) } -Sources $settings.Sources
                @(Get-ExlSources $server $settings | Where-Object Kind -eq 'Iis')
            } $script:Paths
            $iis.Folder | Should -Be @('\\EXCH01\E$\IISLogs\W3SVC1', '\\EXCH01\E$\IISLogs\W3SVC3')
            $iis[1].Label | Should -Be 'IIS OWA External'
            $iis[1].Optional | Should -BeTrue
        }
        It 'follows an IIS log folder moved since -Mode Discover and reports the change' {
            & $script:WriteAppHost -DefaultDirectory 'F:\NewIIS' -CustomDirectory 'F:\NewIIS'
            $r = & (Get-Module ExchangeLogReport) {
                param($f, $sources)
                $server = Resolve-ExlServerPaths -Name 'EXCH01' -Discovered @{ IisFrontEndPath = '\\EXCH01\E$\IISLogs\W3SVC1'; IisCustomSites = @(@{ Name = 'OWA External'; Id = '3'; Role = 'FrontEnd'; Vdirs = 'owa, ecp'; Folder = '\\EXCH01\E$\IISLogs\W3SVC3' }, @{ Name = 'Old'; Id = '9'; Role = 'FrontEnd'; Vdirs = 'owa'; Folder = '\\EXCH01\E$\IISLogs\W3SVC9' }) } -Sources $sources
                [pscustomobject]@{ Notes = @(Test-ExlIisSites -Server $server -File $f); Server = $server }
            } $script:AppHost $script:Paths.Sources
            $r.Server.IisFrontEndPath | Should -Be '\\EXCH01\F$\NewIIS\W3SVC1'
            $r.Server.Origin.IisFrontEndPath | Should -Be 'IIS'
            $r.Server.IisCustomSites[0].Folder | Should -Be '\\EXCH01\F$\NewIIS\W3SVC3'
            @($r.Notes | Where-Object Drift).Count | Should -Be 3
            ($r.Notes.Text -join "`n") | Should -Match '''Default Web Site'' moved to \\\\EXCH01\\F\$\\NewIIS\\W3SVC1'
            ($r.Notes.Text -join "`n") | Should -Match '''Old'' no longer hosts'
        }
        It 'keeps a folder set in the configuration and finds custom sites without -Mode Discover' {
            & $script:WriteAppHost
            $r = & (Get-Module ExchangeLogReport) {
                param($f, $sources)
                $server = Resolve-ExlServerPaths -Name 'EXCH01' -Configured @{ IisLogPath = 'D:\Copies' } -Sources $sources
                [pscustomobject]@{ Origin = $server.Origin.IisFrontEndPath; Notes = @(Test-ExlIisSites -Server $server -File $f); Server = $server }
            } $script:AppHost $script:Paths.Sources
            $r.Origin | Should -Be 'ConfigurationRoot'
            $r.Server.IisFrontEndPath | Should -Be 'D:\Copies\W3SVC1'
            @($r.Notes | Where-Object { $_.Drift -or $_.Status -eq 'Warn' }).Count | Should -Be 0
            $r.Server.IisCustomSites.Name | Should -Be 'OWA External'
        }
        It 'warns about an Exchange site whose logging leaves no W3C file' {
            & $script:WriteAppHost -NoCustom
            (Get-Content -LiteralPath $script:AppHost -Raw).Replace('<logFile directory="E:\IISLogs" />', '<logFile directory="E:\IISLogs" logTargetW3C="ETW" />') | Set-Content -LiteralPath $script:AppHost
            $map = & (Get-Module ExchangeLogReport) { param($f) Get-ExlIisSiteMap -Server 'EXCH01' -File $f } $script:AppHost
            $map.Problems | Should -HaveCount 1
            $map.Problems[0] | Should -Match "'Default Web Site' logs to ETW only"
        }
    }
    It 'writes the paths file from the Exchange and IIS settings (-Mode Discover), servers with and without custom sites' {
        $dir = Join-Path $TestDrive 'discover'
        [void][IO.Directory]::CreateDirectory($dir)
        $config = Join-Path $dir 'ExchangeLogReport.config.psd1'
        $servers = "Servers = @(`r`n        @{ Name = 'EXCH01'; MessageTrackingPath = 'E:\Forced' }`r`n        @{ Name = 'EXCH03' }`r`n    )"
        [IO.File]::WriteAllText($config, [regex]::Replace([IO.File]::ReadAllText((Join-Path $script:Root 'config\ExchangeLogReport.config.psd1')), "(?ms)^    Servers = @\(.*?^    \)", $servers.Replace('$', '$$')), [Text.UTF8Encoding]::new($true))
        $before = Import-ExlConfiguration -Path $config -Root $script:Root
        $before.Servers.Name | Should -Be @('EXCH01', 'EXCH03')
        Mock -ModuleName ExchangeLogReport Get-ExlExchangeSettings {
            $default = 'C:\Program Files\Microsoft\Exchange Server\V15'
            $entry = {
                param($Name, $Install, $HubReceive, $Tracking, $Off)
                [pscustomobject]@{ Name = $Name; Version = 'Version 15.2 (Build 2562.17)'; Site = 'PARIS'; DataPath = "$Install\Mailbox"
                    ImapLogPath = "$Install\Logging\Imap4"; ImapProtocolLog = $false; PopLogPath = "$Install\Logging\Pop3"; PopProtocolLog = $false
                    FrontEndReceivePath = "$Install\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive"; FrontEndSendPath = "$Install\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpSend"
                    HubReceivePath = $HubReceive; HubSendPath = "$Install\TransportRoles\Logs\Hub\ProtocolLog\SmtpSend"
                    MailboxReceivePath = "$Install\TransportRoles\Logs\Mailbox\ProtocolLog\SmtpReceive"; MailboxSendPath = "$Install\TransportRoles\Logs\Mailbox\ProtocolLog\SmtpSend"
                    MessageTrackingPath = $Tracking; MessageTrackingEnabled = $true; LoggingOff = @($Off); Warnings = @() }
            }
            [pscustomobject]@{ Method = 'Exchange remote PowerShell (Kerberos)'; Via = 'EXCH01'; Account = 'CONTOSO\svc-elr'; ExchangeCount = 3
                Servers = @((& $entry 'EXCH01' 'D:\Exchange' 'L:\Logs\Hub\Receive' 'L:\Logs\Tracking' $null),
                    (& $entry 'EXCH02' $default "$default\TransportRoles\Logs\Hub\ProtocolLog\SmtpReceive" "$default\TransportRoles\Logs\MessageTracking" "receive connector 'Internet'")) }
        }
        Mock -ModuleName ExchangeLogReport Get-ExlIisSiteMap {
            $custom = [Collections.Generic.List[object]]::new()
            if ($Server -eq 'EXCH01') { $custom.Add([pscustomobject]@{ Name = 'OWA External'; Id = '3'; Role = 'FrontEnd'; Vdirs = 'owa, ecp'; Folder = "\\$Server\E`$\IISLogs\W3SVC3" }) }
            [pscustomobject]@{ Central = 'Site'; IisFrontEndPath = "\\$Server\E`$\IISLogs\W3SVC1"; IisBackEndPath = "\\$Server\C`$\inetpub\logs\LogFiles\W3SVC2"; Custom = $custom; Problems = [Collections.Generic.List[string]]::new() }
        }
        Mock -ModuleName ExchangeLogReport Test-Path { if ($LiteralPath -like '\\EXCH0*') { $false } else { Microsoft.PowerShell.Management\Test-Path @PesterBoundParameters } }
        $r = Invoke-ExlDiscovery -Settings $before 6>$null
        $r.Found | Should -Be @('EXCH01', 'EXCH02')
        $r.NotInConfig | Should -Be @('EXCH02')
        $r.NotFound | Should -Be @('EXCH03')
        ($r.Warnings -join "`n") | Should -Match "EXCH02: SMTP protocol logging is off on receive connector 'Internet'"
        $after = Import-ExlConfiguration -Path $config -Root $script:Root
        $after.Discovery.By | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $one = $after.Servers[0]
        $one.ExchangePath | Should -Be '\\EXCH01\D$\Exchange'
        $one.HttpProxyPath | Should -Be '\\EXCH01\D$\Exchange\Logging\HttpProxy'
        $one.HubReceivePath | Should -Be '\\EXCH01\L$\Logs\Hub\Receive'
        $one.Origin.HubReceivePath | Should -Be 'Discover'
        $one.MessageTrackingPath | Should -Be 'E:\Forced'
        $one.IisFrontEndPath | Should -Be '\\EXCH01\E$\IISLogs\W3SVC1'
        $one.IisCustomSites.Name | Should -Be 'OWA External'
        $one.ImapProtocolLog | Should -BeFalse
        (Import-PowerShellDataFile -LiteralPath $after.PathsFile).Servers['EXCH02'].Keys | Should -Not -Contain 'IisCustomSites'
    }
    It 'flags a source that Exchange writes all the time when its newest file is too old' {
        & (Get-Module ExchangeLogReport) {
            param($settings)
            $proxy = [pscustomobject]@{ Kind = 'HttpProxy' }
            $tracking = [pscustomobject]@{ Kind = 'Tracking' }
            $smtp = [pscustomobject]@{ Kind = 'SmtpSend' }
            $old = [pscustomobject]@{ Total = 3; Newest = [DateTime]::UtcNow.AddDays(-3) }
            $recent = [pscustomobject]@{ Total = 3; Newest = [DateTime]::UtcNow.AddMinutes(-20) }
            Test-ExlStaleSource -Source $proxy -Plan $old -Settings $settings | Should -BeLike 'newest file 3 d * old'
            Test-ExlStaleSource -Source $proxy -Plan $recent -Settings $settings | Should -BeNullOrEmpty
            Test-ExlStaleSource -Source $proxy -Plan ([pscustomobject]@{ Total = 0; Newest = [DateTime]::MinValue }) -Settings $settings | Should -Be 'no log file'
            # A server without mail flow writes no SMTP or tracking log for months: not a stale source.
            Test-ExlStaleSource -Source $tracking -Plan $old -Settings $settings | Should -BeNullOrEmpty
            Test-ExlStaleSource -Source $smtp -Plan $old -Settings $settings | Should -BeNullOrEmpty
        } $script:Paths
    }
}

Describe 'Application log paths' {
    BeforeAll {
        $script:AppDir = Join-Path $TestDrive 'application-logs'
        $script:AppExchange = Join-Path $script:AppDir 'Exchange'
        $script:AppSiteRoot = Join-Path $script:AppDir 'wwwroot'
        $script:AppEws = Join-Path $script:AppExchange 'FrontEnd\HttpProxy\Ews'
        $script:AppMapi = Join-Path $script:AppExchange 'ClientAccess\mapi\emsmdb'
        $script:AppNspi = Join-Path $script:AppExchange 'ClientAccess\mapi\nspi'
        $script:AppMoved = Join-Path $script:AppDir 'moved-mapi'
        $script:AppNspiMoved = Join-Path $script:AppDir 'moved-nspi'
        $script:AppProxyMoved = Join-Path $script:AppDir 'moved-proxy'
        $script:AppXml = Join-Path $script:AppDir 'applicationHost.config'
        foreach ($folder in $script:AppSiteRoot, $script:AppEws, $script:AppMapi, $script:AppNspi) { [void][IO.Directory]::CreateDirectory($folder) }
        $script:NewAppServer = {
            param([hashtable]$Configured = @{}, [hashtable]$Extra = @{})
            $found = @{ ExchangePath = $script:AppExchange }
            foreach ($key in $Extra.Keys) { $found[$key] = $Extra[$key] }
            & (Get-Module ExchangeLogReport) { param($s, $c, $d) Resolve-ExlServerPaths -Name 'APPTEST' -Configured $c -Discovered $d -Sources $s.Sources } $script:Settings $Configured $found
        }
        $script:ReadAppMap = {
            param($Server, [switch]$Remote)
            & (Get-Module ExchangeLogReport) {
                param($s, $f, $local)
                $iis = Get-ExlIisSiteMap -Server $s.Name -File $f -Local:$local
                Get-ExlApplicationLogMap -Server $s -IisMap $iis -Local:$local
            } $Server $script:AppXml (-not $Remote)
        }
        $script:WriteAppConfig = {
            param([string]$Folder, [string]$Settings = '')
            [IO.File]::WriteAllText((Join-Path $Folder 'web.config'), "<configuration><appSettings>$Settings</appSettings></configuration>")
        }
    }
    BeforeEach {
        & $script:WriteAppConfig $script:AppSiteRoot
        & $script:WriteAppConfig (Join-Path $script:AppExchange 'ClientAccess')
        & $script:WriteAppConfig $script:AppEws
        & $script:WriteAppConfig $script:AppMapi
        & $script:WriteAppConfig $script:AppNspi
        $parent = Join-Path $script:AppExchange 'ClientAccess\mapi\web.config'
        if (Test-Path -LiteralPath $parent) { Remove-Item -LiteralPath $parent }
        [IO.File]::WriteAllText($script:AppXml, @"
<configuration><system.applicationHost><sites>
  <site name="Default Web Site" id="1">
    <application path="/"><virtualDirectory path="/" physicalPath="$script:AppSiteRoot" /></application>
    <application path="/EWS"><virtualDirectory path="/" physicalPath="$script:AppEws" /></application>
  </site>
  <site name="Exchange Back End" id="2">
    <application path="/"><virtualDirectory path="/" physicalPath="$script:AppExchange\ClientAccess" /></application>
    <application path="/mapi/emsmdb"><virtualDirectory path="/" physicalPath="$script:AppMapi" /></application>
    <application path="/mapi/nspi"><virtualDirectory path="/" physicalPath="$script:AppNspi" /></application>
  </site>
</sites></system.applicationHost></configuration>
"@)
    }
    It 'uses the normal folders when no protocol-specific override is present and ignores other log formats' {
        & $script:WriteAppConfig $script:AppMapi '<add key="LogPath" value="D:\OtherMAPI" /><add key="RequestDetailsLogger.EWSProtocolLogFolder" value="D:\Ews" />'
        & $script:WriteAppConfig $script:AppNspi '<add key="LogFilePath" value="D:\AddressBook" />'
        $map = & $script:ReadAppMap (& $script:NewAppServer)
        $map.Problems | Should -BeNullOrEmpty
        $map.Entries | Should -HaveCount 3
        @($map.Entries | Where-Object Customized).Count | Should -Be 0
        ($map.Entries | Where-Object Kind -eq 'MapiBackEnd').Folder | Should -Be @("$script:AppExchange\Logging\MapiHttp\Mailbox", "$script:AppExchange\Logging\MapiHttp\Mailbox")
    }
    It 'follows distinct MAPI mailbox and address-book HTTP folders and a customized HttpProxy folder' {
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        & $script:WriteAppConfig $script:AppNspi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppNspiMoved`" />"
        & $script:WriteAppConfig $script:AppEws "<add key=`"RequestDetailsLogger.HttpProxyProtocolLogFolder`" value=`"$script:AppProxyMoved`" />"
        $server = & $script:NewAppServer
        $map = & $script:ReadAppMap $server
        $notes = & (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server $map
        $server.MapiHttpPath | Should -Be $script:AppMoved
        @($notes | Where-Object Drift).Count | Should -Be 3
        $sources = @(Get-ExlSources $server $script:Settings)
        @($sources | Where-Object Kind -eq 'MapiBackEnd').Folder | Should -Be @($script:AppMoved, $script:AppNspiMoved)
        @($sources | Where-Object Kind -eq 'HttpProxy').Folder | Should -Contain $script:AppProxyMoved
    }
    It 'reads inherited settings, clear and remove, and external configSource and file settings' {
        & $script:WriteAppConfig (Join-Path $script:AppExchange 'ClientAccess') "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        & $script:WriteAppConfig $script:AppNspi '<remove key="RequestDetailsLogger.MapiHttpMailboxLogFolder" />'
        $map = & $script:ReadAppMap (& $script:NewAppServer)
        ($map.Entries | Where-Object Application -eq '/mapi/emsmdb').Folder | Should -Be $script:AppMoved
        ($map.Entries | Where-Object Application -eq '/mapi/nspi').Customized | Should -BeFalse
        [IO.File]::WriteAllText((Join-Path $script:AppMapi 'settings.config'), "<appSettings><clear /><add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppNspiMoved`" /></appSettings>")
        [IO.File]::WriteAllText((Join-Path $script:AppMapi 'web.config'), '<configuration><appSettings configSource="settings.config" /></configuration>')
        [IO.File]::WriteAllText((Join-Path $script:AppEws 'settings.config'), "<appSettings><add key=`"RequestDetailsLogger.HttpProxyProtocolLogFolder`" value=`"$script:AppProxyMoved`" /></appSettings>")
        [IO.File]::WriteAllText((Join-Path $script:AppEws 'web.config'), '<configuration><appSettings file="settings.config" /></configuration>')
        $map = & $script:ReadAppMap (& $script:NewAppServer)
        ($map.Entries | Where-Object Application -eq '/mapi/emsmdb').Folder | Should -Be $script:AppNspiMoved
        ($map.Entries | Where-Object Application -eq '/EWS').Folder | Should -Be $script:AppProxyMoved
        $map.Problems | Should -BeNullOrEmpty
    }
    It 'deduplicates shared folders and overlapping HttpProxy folders without ignoring a customized MAPI source' {
        $server = & $script:NewAppServer
        $shared = "$script:AppExchange\Logging\MapiHttp\Mailbox"
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$shared`" />"
        & $script:WriteAppConfig $script:AppNspi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$shared`" />"
        & $script:WriteAppConfig $script:AppEws "<add key=`"RequestDetailsLogger.HttpProxyProtocolLogFolder`" value=`"$script:AppExchange\Logging\HttpProxy\Ews`" />"
        [void]@(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server (& $script:ReadAppMap $server))
        $sources = @(Get-ExlSources $server $script:Settings)
        @($sources | Where-Object Kind -eq 'MapiBackEnd').Count | Should -Be 1
        @($sources | Where-Object Kind -eq 'MapiBackEnd')[0].Optional | Should -BeFalse
        @($sources | Where-Object Kind -eq 'HttpProxy').Count | Should -Be 1
        $server.ApplicationLogSources += [pscustomobject]@{ Kind = 'HttpProxy'; Protocol = 'Owa'; Folder = "$script:AppExchange\Logging"; Customized = $true }
        $sources = @(Get-ExlSources $server $script:Settings)
        @($sources | Where-Object Kind -eq 'HttpProxy').Count | Should -Be 1
        @($sources | Where-Object Kind -eq 'HttpProxy')[0].Folder | Should -Be "$script:AppExchange\Logging"
    }
    It 'preserves forced paths and logging roots over web.config settings' {
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        & $script:WriteAppConfig $script:AppEws "<add key=`"RequestDetailsLogger.HttpProxyProtocolLogFolder`" value=`"$script:AppProxyMoved`" />"
        foreach ($configured in @(@{ MapiHttpPath = 'D:\ForcedMAPI'; HttpProxyPath = 'D:\ForcedProxy' }, @{ LoggingPath = 'D:\ForcedLogs' })) {
            $server = & $script:NewAppServer $configured
            $oldMapi = $server.MapiHttpPath
            $oldProxy = $server.HttpProxyPath
            $notes = @(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server (& $script:ReadAppMap $server))
            $server.MapiHttpPath | Should -Be $oldMapi
            @($notes | Where-Object Drift).Count | Should -Be 0
            $sources = @(Get-ExlSources $server $script:Settings)
            @($sources | Where-Object Kind -eq 'MapiBackEnd').Folder | Should -Be @($oldMapi)
            @($sources | Where-Object Kind -eq 'HttpProxy').Folder | Should -Be @($oldProxy)
        }
    }
    It 'reports unreadable, invalid and unresolved settings and keeps previously discovered application paths' {
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        $server = & $script:NewAppServer
        [void]@(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server (& $script:ReadAppMap $server))
        [IO.File]::WriteAllText((Join-Path $script:AppMapi 'web.config'), '<configuration><appSettings>')
        & $script:WriteAppConfig $script:AppEws '<add key="RequestDetailsLogger.HttpProxyProtocolLogFolder" value="%UnknownRemoteVariable%\Logs" />'
        $map = & $script:ReadAppMap $server
        $map.Failed | Should -HaveCount 2
        ($map.Problems -join ' ') | Should -Match 'could not be read'
        $notes = @(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server $map)
        @($notes | Where-Object Status -eq 'Warn').Count | Should -BeGreaterOrEqual 2
        $server.MapiHttpPath | Should -Be $script:AppMoved
        $server.ApplicationLogSources | Where-Object Application -eq '/mapi/emsmdb' | Should -HaveCount 1
    }
    It 'returns to the default folder when a customization is removed and checks it during collection' {
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        $server = & $script:NewAppServer
        $notes = @(Test-ExlIisSites -Server $server -Local -File $script:AppXml)
        $server.MapiHttpPath | Should -Be $script:AppMoved
        & $script:WriteAppConfig $script:AppMapi
        $notes = @(Test-ExlIisSites -Server $server -Local -File $script:AppXml)
        $server.MapiHttpPath | Should -Be "$script:AppExchange\Logging\MapiHttp\Mailbox"
        ($notes | Where-Object { $_.Drift -and $_.Text -match 'Application logs' }).Text | Should -Match 'read from the new folder'
    }
    It 'warns about missing external settings and rejects DTDs without resolving external entities' {
        [IO.File]::WriteAllText((Join-Path $script:AppMapi 'web.config'), '<configuration><appSettings configSource="absent.config" /></configuration>')
        [IO.File]::WriteAllText((Join-Path $script:AppNspi 'web.config'), '<!DOCTYPE configuration [<!ENTITY x SYSTEM "file:///no-such-file">]><configuration><appSettings /></configuration>')
        $map = & $script:ReadAppMap (& $script:NewAppServer)
        $map.Failed | Should -HaveCount 2
        $map.Problems | Should -HaveCount 2
    }
    It 'reports encrypted and unsupported external settings as application warnings instead of aborting collection' {
        [IO.File]::WriteAllText((Join-Path $script:AppMapi 'not-appsettings.config'), '<other />')
        foreach ($body in @(
                '<appSettings configProtectionProvider="DataProtectionConfigurationProvider"><EncryptedData /></appSettings>',
                '<appSettings configSource="D:\absolute.config" />',
                '<appSettings file="D:\absolute.config" />',
                '<appSettings configSource="not-appsettings.config" />',
                '<appSettings file="not-appsettings.config" />')) {
            [IO.File]::WriteAllText((Join-Path $script:AppMapi 'web.config'), "<configuration>$body</configuration>")
            $map = & $script:ReadAppMap (& $script:NewAppServer)
            $map.Failed | Should -HaveCount 1
            $map.Entries | Should -HaveCount 2
            $map.Problems | Should -HaveCount 1
        }
    }
    It 'retains a legacy discovered MAPI folder when its web.config cannot be read' {
        $server = & $script:NewAppServer @{} @{ MapiHttpPath = $script:AppMoved }
        [IO.File]::WriteAllText((Join-Path $script:AppMapi 'web.config'), '<configuration>')
        $map = & $script:ReadAppMap $server
        [void]@(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server $map)
        $server.MapiHttpPath | Should -Be $script:AppMoved
        @($server.ApplicationLogSources | Where-Object Application -eq '/mapi/emsmdb').Folder | Should -Be @($script:AppMoved)
    }
    It 'reports removed applications and drops their old custom folders' {
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        & $script:WriteAppConfig $script:AppNspi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppNspiMoved`" />"
        $server = & $script:NewAppServer
        [void]@(Test-ExlIisSites -Server $server -Local -File $script:AppXml)
        $xml = [xml]::new()
        $xml.Load($script:AppXml)
        foreach ($app in @($xml.SelectNodes('//application[starts-with(@path, "/mapi/")]'))) { [void]$app.ParentNode.RemoveChild($app) }
        $xml.Save($script:AppXml)
        $notes = @(Test-ExlIisSites -Server $server -Local -File $script:AppXml)
        @($notes | Where-Object { $_.Drift -and $_.Text -match 'no longer supplies' }).Count | Should -Be 2
        @($server.ApplicationLogSources | Where-Object Kind -eq 'MapiBackEnd').Count | Should -Be 0
        $server.MapiHttpPath | Should -Be "$script:AppExchange\Logging\MapiHttp\Mailbox"
    }
    It 'converges the proxy installation root even when one application configuration is unreadable' {
        $other = Join-Path $script:AppExchange 'FrontEnd\HttpProxy\Autodiscover'
        [void][IO.Directory]::CreateDirectory($other)
        & $script:WriteAppConfig $other
        [IO.File]::WriteAllText((Join-Path $script:AppEws 'web.config'), '<configuration>')
        $xml = [xml]::new()
        $xml.Load($script:AppXml)
        $app = $xml.CreateElement('application')
        $app.SetAttribute('path', '/Autodiscover')
        $vdir = $xml.CreateElement('virtualDirectory')
        $vdir.SetAttribute('path', '/')
        $vdir.SetAttribute('physicalPath', $other)
        [void]$app.AppendChild($vdir)
        [void]$xml.SelectSingleNode('//site[@name="Default Web Site"]').AppendChild($app)
        $xml.Save($script:AppXml)
        $server = & $script:NewAppServer @{} @{ HttpProxyPath = 'D:\OldInstallation\Logging\HttpProxy' }
        $map = & $script:ReadAppMap $server
        [void]@(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server $map)
        $server.HttpProxyPath | Should -Be "$script:AppExchange\Logging\HttpProxy"
        $map.Failed | Should -HaveCount 1
    }
    It 'reads scoped parent web.config locations without applying them to unrelated applications' {
        [IO.File]::WriteAllText((Join-Path $script:AppExchange 'ClientAccess\web.config'), @"
<configuration><location path="mapi/emsmdb"><appSettings>
<add key="RequestDetailsLogger.MapiHttpMailboxLogFolder" value="$script:AppMoved" />
</appSettings></location></configuration>
"@)
        $map = & $script:ReadAppMap (& $script:NewAppServer)
        ($map.Entries | Where-Object Application -eq '/mapi/emsmdb').Folder | Should -Be $script:AppMoved
        ($map.Entries | Where-Object Application -eq '/mapi/nspi').Customized | Should -BeFalse
    }
    It 'expands the Exchange installation path and follows applications relocated outside the installation folder' {
        & $script:WriteAppConfig $script:AppMapi '<add key="RequestDetailsLogger.MapiHttpMailboxLogFolder" value="%ExchangeInstallPath%\Logging\MovedMapi" />'
        $other = Join-Path $script:AppDir 'relocated-application'
        [void][IO.Directory]::CreateDirectory($other)
        & $script:WriteAppConfig $other "<add key=`"RequestDetailsLogger.HttpProxyProtocolLogFolder`" value=`"$script:AppProxyMoved`" />"
        [IO.File]::WriteAllText($script:AppXml, [IO.File]::ReadAllText($script:AppXml).Replace(
                "<application path=`"/EWS`"><virtualDirectory path=`"/`" physicalPath=`"$script:AppEws`" />",
                "<application path=`"/EWS`" applicationPool=`"MSExchangeServicesAppPool`"><virtualDirectory path=`"/`" physicalPath=`"$other`" />"))
        $server = & $script:NewAppServer @{ ExchangePath = $script:AppExchange }
        $map = & $script:ReadAppMap $server
        $map.Problems | Should -BeNullOrEmpty
        ($map.Entries | Where-Object Application -eq '/mapi/emsmdb').Folder | Should -Be "$script:AppExchange\Logging\MovedMapi"
        ($map.Entries | Where-Object Application -eq '/EWS').Folder | Should -Be $script:AppProxyMoved
        [void]@(& (Get-Module ExchangeLogReport) { param($s, $m) Update-ExlApplicationLogPaths -Server $s -Map $m } $server $map)
        $server.MapiHttpPath | Should -Be "$script:AppExchange\Logging\MovedMapi"
    }
    It 'does not open web.config for disabled application log sources' {
        Mock -ModuleName ExchangeLogReport Read-ExlConfigurationXml { throw 'A disabled source must not read its configuration.' }
        $server = & $script:NewAppServer
        $map = & (Get-Module ExchangeLogReport) {
            param($s, $f)
            Get-ExlApplicationLogMap -Server $s -IisMap (Get-ExlIisSiteMap -Server $s.Name -File $f -Local) -Local -Sources @{ HttpProxy = $false; MapiBackEnd = $false }
        } $server $script:AppXml
        $map.Entries | Should -BeNullOrEmpty
        $map.Problems | Should -BeNullOrEmpty
    }
    It 'persists application source paths in Discover and reloads them for an offline report' {
        & $script:WriteAppConfig $script:AppMapi "<add key=`"RequestDetailsLogger.MapiHttpMailboxLogFolder`" value=`"$script:AppMoved`" />"
        $config = New-TestConfig (Join-Path $script:AppDir 'discovery-runtime')
        $settings = Import-ExlConfiguration -Path $config -Root $script:Root
        $settings.Servers = @(& $script:NewAppServer)
        $script:DiscoveryAppMap = & (Get-Module ExchangeLogReport) {
            param($f) Get-ExlIisSiteMap -Server 'APPTEST' -File $f -Local
        } $script:AppXml
        Mock -ModuleName ExchangeLogReport Get-ExlExchangeSettings {
            [pscustomobject]@{ Method = 'test'; Via = 'APPTEST'; Account = 'test'; ExchangeCount = 1
                Servers = @([pscustomobject]@{ Name = 'APPTEST'; Version = '15.2'; Site = 'LAB'; DataPath = "$script:AppExchange\Mailbox"
                        ImapLogPath = $null; PopLogPath = $null; FrontEndReceivePath = $null; FrontEndSendPath = $null
                        HubReceivePath = $null; HubSendPath = $null; MailboxReceivePath = $null; MailboxSendPath = $null
                        MessageTrackingPath = $null; MessageTrackingEnabled = $true; ImapProtocolLog = $false; PopProtocolLog = $false; LoggingOff = @(); Warnings = @() }) }
        }
        Mock -ModuleName ExchangeLogReport Get-ExlIisSiteMap { $script:DiscoveryAppMap }
        Mock -ModuleName ExchangeLogReport ConvertTo-ExlRemotePath { return $Path }
        $result = Invoke-ExlDiscovery -Settings $settings 6>$null
        @($result.Warnings | Where-Object { $_ -match 'log settings could not be read|IIS settings not readable' }) | Should -BeNullOrEmpty
        $raw = Import-PowerShellDataFile -LiteralPath $result.File
        $raw.Servers['APPTEST'].MapiHttpPath | Should -Be $script:AppMoved
        $raw.Servers['APPTEST'].ApplicationLogSources | Should -HaveCount 3
        Mock -ModuleName ExchangeLogReport Read-ExlConfigurationXml { throw 'An offline import must not open web.config.' }
        $loaded = & (Get-Module ExchangeLogReport) {
            param($src, $found) Resolve-ExlServerPaths -Name 'APPTEST' -Discovered $found -Sources $src
        } $settings.Sources $raw.Servers['APPTEST']
        $loaded.MapiHttpPath | Should -Be $script:AppMoved
        $loaded.ApplicationLogSources | Should -HaveCount 3
    }
    It 'collects a moved MAPI file once, correlates the back-end detail and resumes incrementally' {
        $config = New-TestConfig (Join-Path $script:AppDir 'collection-runtime')
        $settings = Import-ExlConfiguration -Path $config -Root $script:Root
        $old = $settings.Servers[0]
        $server = & (Get-Module ExchangeLogReport) {
            param($s, $old)
            Resolve-ExlServerPaths -Name 'EXCH01' -Discovered @{
                ExchangePath = $old.ExchangePath; IisFrontEndPath = $old.IisFrontEndPath; IisBackEndPath = $old.IisBackEndPath
            } -Sources $s.Sources
        } $settings $old
        $settings.Servers = @($server)
        $moved = Join-Path $script:AppDir 'collected-mapi'
        [void][IO.Directory]::CreateDirectory($moved)
        Get-ChildItem -LiteralPath $old.MapiHttpPath -File | Move-Item -Destination $moved
        $entries = @(
            [pscustomobject]@{ Kind = 'MapiBackEnd'; Protocol = 'Mapi'; Site = 'Exchange Back End'; Application = '/mapi/emsmdb'
                Folder = $moved; DefaultFolder = $old.MapiHttpPath; ConfigFile = 'test'; Setting = 'RequestDetailsLogger.MapiHttpMailboxLogFolder'; Customized = $true }
            [pscustomobject]@{ Kind = 'MapiBackEnd'; Protocol = 'Mapi'; Site = 'Exchange Back End'; Application = '/mapi/nspi'
                Folder = $moved; DefaultFolder = $old.MapiHttpPath; ConfigFile = 'test'; Setting = 'RequestDetailsLogger.MapiHttpMailboxLogFolder'; Customized = $true }
        )
        [void]@(& (Get-Module ExchangeLogReport) {
            param($s, $e) Update-ExlApplicationLogPaths -Server $s -Map ([pscustomobject]@{ Entries = $e; Failed = @(); Problems = @() })
        } $server $entries)
        $first = Invoke-TestCollection $settings
        $first.Errors | Should -Be 0
        @(Query $settings "SELECT path FROM source_file WHERE kind='MapiBackEnd';").Count | Should -Be 1
        [long](Query $settings "SELECT SUM(kept) FROM source_file WHERE kind='MapiBackEnd';")[0][0] | Should -BeGreaterThan 0
        (Query $settings "SELECT software FROM client_session WHERE user='contoso\dave';")[0][0] | Should -Be 'OUTLOOK.EXE 16.0.17928.20114'
        $again = Invoke-TestCollection $settings
        $again.Files | Should -Be 0
    }
}

Describe 'Edge Transport servers' {
    BeforeAll {
        # Folder tree of an Edge Transport server: no IIS, HttpProxy, MAPI, ActiveSync, POP or IMAP; SMTP logs of the
        # Edge transport service, message tracking, and the AD LDS instance of the Edge role (TransportRoles\data\Adam).
        $script:EdgeDir = Join-Path $TestDrive 'edge'
        $script:EdgeExchange = Join-Path $script:EdgeDir 'EDGE01\Exchange'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:EdgeExchange 'TransportRoles\data\Adam'))
        $fields = '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
        $c = 'EDGE01\Default internal receive connector EDGE01'
        Write-Log (Join-Path $script:EdgeExchange 'TransportRoles\Logs\Edge\ProtocolLog\SmtpReceive\RECV2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Version: 15.0.0.0', '#Log-type: SMTP Receive Protocol Log', "#Date: $(T 0)", $fields
            "$(T 1),$c,08DE000000000001,0,192.0.2.10:25,198.51.100.7:51000,+,,"
            "$(T 1),$c,08DE000000000001,1,192.0.2.10:25,198.51.100.7:51000,<,EHLO mail.fabrikam.example,"
            "$(T 1),$c,08DE000000000001,2,192.0.2.10:25,198.51.100.7:51000,<,STARTTLS,"
            "$(T 1),$c,08DE000000000001,3,192.0.2.10:25,198.51.100.7:51000,*,,""TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded using bulk encryption algorithm CALG_AES_256"""
            "$(T 1),$c,08DE000000000001,4,192.0.2.10:25,198.51.100.7:51000,<,MAIL FROM:<partner@fabrikam.example> SIZE=4096,"
            "$(T 1),$c,08DE000000000001,5,192.0.2.10:25,198.51.100.7:51000,<,RCPT TO:<alice@contoso.test>,"
            "$(T 1),$c,08DE000000000001,6,192.0.2.10:25,198.51.100.7:51000,<,BDAT 4096 LAST,"
            "$(T 1),$c,08DE000000000001,7,192.0.2.10:25,198.51.100.7:51000,>,""250 2.6.0 <edge-001@fabrikam.example> [InternalId=5001, Hostname=EDGE01.perimeter.test] Queued mail for delivery"","
            "$(T 1),$c,08DE000000000001,8,192.0.2.10:25,198.51.100.7:51000,-,,Local"
        )
        $trk = '#Fields: date-time,client-ip,client-hostname,server-ip,server-hostname,source-context,connector-id,source,event-id,internal-message-id,message-id,network-message-id,recipient-address,recipient-status,total-bytes,recipient-count,related-recipient-address,reference,message-subject,sender-address,return-path,message-info,directionality,tenant-id,original-client-ip,original-server-ip,custom-data,transport-traffic-type,log-id,schema-version'
        # Outbound: one message handed over to Exchange Online, one deferred by a partner MX.
        $o = 'Internet via EXO'
        Write-Log (Join-Path $script:EdgeExchange 'TransportRoles\Logs\Edge\ProtocolLog\SmtpSend\SEND2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Version: 15.0.0.0', '#Log-type: SMTP Send Protocol Log', "#Date: $(T 0)", $fields
            "$(T 2),$o,08DE000000000101,0,192.0.2.10:50001,52.101.1.1:25,+,,"
            "$(T 2),$o,08DE000000000101,1,192.0.2.10:50001,52.101.1.1:25,<,220 AM0PR02CA0001.outlook.office365.com Microsoft ESMTP MAIL Service ready,"
            "$(T 2),$o,08DE000000000101,2,192.0.2.10:50001,52.101.1.1:25,>,EHLO hybrid.contoso.test,"
            "$(T 2),$o,08DE000000000101,3,192.0.2.10:50001,52.101.1.1:25,>,STARTTLS,"
            "$(T 2),$o,08DE000000000101,4,192.0.2.10:50001,52.101.1.1:25,*,,""TLS protocol SP_PROT_TLS1_2_CLIENT negotiation succeeded using bulk encryption algorithm CALG_AES_256"""
            "$(T 2),$o,08DE000000000101,5,192.0.2.10:50001,52.101.1.1:25,>,MAIL FROM:<alice@contoso.test> SIZE=2048,"
            "$(T 2),$o,08DE000000000101,6,192.0.2.10:50001,52.101.1.1:25,>,RCPT TO:<partner@fabrikam.example>,"
            "$(T 2),$o,08DE000000000101,7,192.0.2.10:50001,52.101.1.1:25,>,BDAT 2048 LAST,"
            "$(T 2),$o,08DE000000000101,8,192.0.2.10:50001,52.101.1.1:25,<,""250 2.6.0 <edge-002@contoso.test> [InternalId=1, Hostname=AM0PR02MB0001.eurprd02.prod.outlook.com] Queued mail for delivery"","
            "$(T 2),$o,08DE000000000101,9,192.0.2.10:50001,52.101.1.1:25,-,,Local"
            "$(T 3),Partner MX,08DE000000000102,0,192.0.2.10:50002,203.0.113.25:25,+,,"
            "$(T 3),Partner MX,08DE000000000102,1,192.0.2.10:50002,203.0.113.25:25,<,220 mx.northwind.example ESMTP,"
            "$(T 3),Partner MX,08DE000000000102,2,192.0.2.10:50002,203.0.113.25:25,>,EHLO hybrid.contoso.test,"
            "$(T 3),Partner MX,08DE000000000102,3,192.0.2.10:50002,203.0.113.25:25,>,MAIL FROM:<bob@contoso.test>,"
            "$(T 3),Partner MX,08DE000000000102,4,192.0.2.10:50002,203.0.113.25:25,>,RCPT TO:<support@northwind.example>,"
            "$(T 3),Partner MX,08DE000000000102,5,192.0.2.10:50002,203.0.113.25:25,<,451 4.7.1 Greylisted: try again later,"
            "$(T 3),Partner MX,08DE000000000102,6,192.0.2.10:50002,203.0.113.25:25,-,,Local"
        )
        Write-Log (Join-Path $script:EdgeExchange 'TransportRoles\Logs\MessageTracking\MSGTRK2026100108-1.LOG') @(
            '#Software: Microsoft Exchange Server', '#Version: 15.02.2562.045', '#Log-type: Message Tracking Log', "#Date: $(T 0)", $trk
            "$(T 1),198.51.100.7,mail.fabrikam.example,192.0.2.10,EDGE01,08DE000000000001;$(T 1);0,$c,SMTP,RECEIVE,5001,<edge-001@fabrikam.example>,net-e001,alice@contoso.test,,4096,1,,,Order,partner@fabrikam.example,partner@fabrikam.example,,Incoming,,,,,Email,$([guid]::NewGuid()),15.02.2562.045"
            "$(T 1.1),192.0.2.11,EDGE01,10.0.0.1,EXCH01.contoso.test,,EdgeSync - Inbound to Default-First-Site-Name,SMTP,SENDEXTERNAL,5001,<edge-001@fabrikam.example>,net-e001,alice@contoso.test,250 2.6.0 Queued,4096,1,,,Order,partner@fabrikam.example,partner@fabrikam.example,,Incoming,,,,,Email,$([guid]::NewGuid()),15.02.2562.045"
            # Outbound: received from the organization, handed to the internet.
            "$(T 4),10.0.0.1,EXCH01.contoso.test,192.0.2.10,EDGE01,08DE000000000003;$(T 4);0,EDGE01\Default internal receive connector EDGE01,SMTP,RECEIVE,5003,<edge-003@contoso.test>,net-e003,partner@fabrikam.example,,2048,1,,,Quote,alice@contoso.test,alice@contoso.test,,Originating,,,,,Email,$([guid]::NewGuid()),15.02.2562.045"
            "$(T 4.1),192.0.2.10,EDGE01,203.0.113.30,mx.fabrikam.example,,EdgeSync - Default-First-Site-Name to Internet,SMTP,SENDEXTERNAL,5003,<edge-003@contoso.test>,net-e003,partner@fabrikam.example,250 2.1.5 Recipient OK,2048,1,,,Quote,alice@contoso.test,alice@contoso.test,,Originating,,,,,Email,$([guid]::NewGuid()),15.02.2562.045"
        )
        $script:NewEdgeConfig = {
            param([string]$Name, [string]$ServerBlock)
            $dir = Join-Path $script:EdgeDir $Name
            [void][IO.Directory]::CreateDirectory($dir)
            $text = [IO.File]::ReadAllText((Join-Path $script:Root 'config\ExchangeLogReport.config.psd1'))
            $text = [regex]::Replace($text, "(?ms)^    Servers = @\(.*?^    \)", ("Servers = @(`r`n        $ServerBlock`r`n    )").Replace('$', '$$'))
            $text = $text.Replace("'.\data\ExchangeLogReport.sqlite'", "'$dir\data\test.sqlite'").Replace("Path          = '.\logs'", "Path          = '$dir\toollogs'").Replace("OutputPath            = '.\reports'", "OutputPath            = '$dir\reports'")
            $path = Join-Path $dir 'test.config.psd1'
            [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
            return $path
        }
    }
    It 'reads only the SMTP protocol logs and the message tracking of an Edge Transport server' {
        $s = Import-ExlConfiguration -Path (& $script:NewEdgeConfig 'sources' "@{ Name = 'EDGE01'; Role = 'edge'; TransportLogPath = 'L:\Logs' }") -Root $script:Root
        $edge = $s.Servers[0]
        $edge.Role | Should -Be 'Edge'
        $edge.RoleOrigin | Should -Be 'Configuration'
        $sources = @(Get-ExlSources $edge $s)
        ($sources | ForEach-Object { '{0}|{1}' -f $_.Kind, $_.Role }) | Should -Be @('SmtpReceive|Edge', 'SmtpSend|Edge', 'Tracking|')
        ($sources | Where-Object Kind -eq 'SmtpReceive').Folder | Should -Be 'L:\Logs\Edge\ProtocolLog\SmtpReceive'
        ($sources | Where-Object Kind -eq 'SmtpSend').Label | Should -Be 'SMTP out (Edge)'
        # A mailbox server keeps every source.
        $mailbox = & (Get-Module ExchangeLogReport) { param($src) Resolve-ExlServerPaths -Name 'EXCH01' -Sources $src } $s.Sources
        $mailbox.Role | Should -Be 'Mailbox'
        @(Get-ExlSources $mailbox $s | Where-Object Kind -in 'HttpProxy', 'Iis', 'EasBackEnd').Count | Should -Be 3
    }
    It 'rejects an unknown server role' {
        { Import-ExlConfiguration -Path (& $script:NewEdgeConfig 'badrole' "@{ Name = 'EDGE01'; Role = 'Hub' }") -Root $script:Root } | Should -Throw -ExpectedMessage '*Servers`[1`].Role must be Mailbox or Edge*'
    }
    It 'detects an Edge Transport server: registry key on this computer, Edge folders on another server' {
        $s = Import-ExlConfiguration -Path (& $script:NewEdgeConfig 'detect' "@{ Name = 'EDGE01'; ExchangePath = '$script:EdgeExchange' }") -Root $script:Root
        $edge = $s.Servers[0]
        $edge.Role | Should -Be 'Mailbox'
        Resolve-ExlServerRole -Server $edge | Should -Be 'Edge'
        $edge.RoleOrigin | Should -Be 'Detected'
        # Client access folder present: a mailbox server, whatever the other folders.
        $mailboxDir = Join-Path $TestDrive 'edge\mailbox-like'
        foreach ($f in 'TransportRoles\data\Adam', 'FrontEnd\HttpProxy') { [void][IO.Directory]::CreateDirectory((Join-Path $mailboxDir $f)) }
        $mailbox = & (Get-Module ExchangeLogReport) { param($src, $dir) Resolve-ExlServerPaths -Name 'EXCH09' -Configured @{ ExchangePath = $dir } -Sources $src } $s.Sources $mailboxDir
        Resolve-ExlServerRole -Server $mailbox | Should -Be 'Mailbox'
        # This computer: the EdgeTransportRole registry key.
        Mock -ModuleName ExchangeLogReport Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\EdgeTransportRole' }
        $local = & (Get-Module ExchangeLogReport) { param($src) Resolve-ExlServerPaths -Name 'EDGE02' -Sources $src } $s.Sources
        Resolve-ExlServerRole -Server $local -Local | Should -Be 'Edge'
        # A role set in the configuration is kept.
        $forced = & (Get-Module ExchangeLogReport) { param($src) Resolve-ExlServerPaths -Name 'EDGE03' -Configured @{ Role = 'Mailbox' } -Sources $src } $s.Sources
        Resolve-ExlServerRole -Server $forced -Local | Should -Be 'Mailbox'
    }
    It 'collects an Edge Transport server without looking for client access logs' {
        $s = Import-ExlConfiguration -Path (& $script:NewEdgeConfig 'collect' "@{ Name = 'EDGE01'; ExchangePath = '$script:EdgeExchange' }") -Root $script:Root
        [void](Resolve-ExlServerRole -Server $s.Servers[0])
        @(Test-ExlServerAccess -Server $s.Servers[0] -Settings $s) | Should -BeNullOrEmpty
        $r = Invoke-TestCollection $s
        $r.Unreachable.Count | Should -Be 0
        $r.Stale.Count | Should -Be 0
        $r.Errors | Should -Be 0
        $rows = Query $s "SELECT direction, role, connector, helo, mail_from, message_id, status, tls FROM smtp_transaction WHERE direction = 'Receive'"
        $rows.Count | Should -Be 1
        @($rows[0]) | Should -Be @('Receive', 'Edge', 'EDGE01\Default internal receive connector EDGE01', 'mail.fabrikam.example', 'partner@fabrikam.example', '<edge-001@fabrikam.example>', 'Accepted', 'TLS 1.2')
        (Query $s "SELECT COUNT(*) FROM message_event WHERE server='EDGE01' AND message_id='<edge-001@fabrikam.example>'")[0][0] | Should -Be 2
        @((Query $s 'SELECT DISTINCT kind FROM source_file ORDER BY kind') | ForEach-Object { $_[0] }) | Should -Be @('SmtpReceive', 'SmtpSend', 'Tracking')
        $script:EdgeSettings = $s
    }
    It 'builds an Edge report: mail flow only, with the SMTP destinations of the Edge' {
        $period = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $store = Open-ExlStore -Settings $script:EdgeSettings -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:EdgeSettings -Period $period -ReportType Detailed } finally { $store.Dispose() }
        Split-Path $r.Folder -Leaf | Should -BeLike 'ExchangeLogs_EdgeDetailed_*'
        @($r.Counts.Keys | Sort-Object) | Should -Be @('daily', 'messages', 'servers', 'smtp', 'smtpclients', 'smtpdestinations')
        @($r.Files | ForEach-Object { Split-Path $_.Path -Leaf } | Where-Object { $_ -like '*ClientAccess*' -or $_ -like '*Users*' -or $_ -like '*Sessions.csv' -and $_ -notlike '*SmtpSessions*' }) | Should -BeNullOrEmpty
        $dest = @(Import-Csv (Join-Path $r.Folder 'ExchangeLogs-SmtpDestinations.csv') -Delimiter ';')
        $dest.Count | Should -Be 2
        $exo = $dest | Where-Object Connector -eq 'Internet via EXO'
        @($exo.'Remote IP', $exo.'Remote host', $exo.Sent, $exo.TLS) | Should -Be @('52.101.1.1', 'AM0PR02CA0001.outlook.office365.com', '1', 'TLS 1.2')
        $partner = $dest | Where-Object Connector -eq 'Partner MX'
        @($partner.'Remote host', $partner.Deferred, $partner.'Last error') | Should -Be @('mx.northwind.example', '1', '451 4.7.1 Greylisted: try again later')
        (Get-Content (Join-Path $r.Folder 'ExchangeLogs-Servers.csv') -TotalCount 1) | Should -Not -Match 'Real users|Requests'
        # Handed over to the organization (SENDEXTERNAL on an Edge): handed off outside the collected logs.
        (Import-Csv (Join-Path $r.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' | Where-Object 'Message ID' -eq '<edge-001@fabrikam.example>').Status | Should -Be 'Handed off outside collection'
        # Handed to the internet (the accepted domain contoso.test is learnt from the inbound mail): sent to external.
        $out = Import-Csv (Join-Path $r.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' | Where-Object 'Message ID' -eq '<edge-003@contoso.test>'
        $out.Status | Should -Be 'Sent to external'
        $out.Recipients | Should -Be 'partner@fabrikam.example (Sent to external)'
        (Query $script:EdgeSettings "SELECT value FROM metadata WHERE key='mailflow_accepted_domains'")[0][0] | Should -Be 'contoso.test'
        (Query $script:EdgeSettings "SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0 AND r.identity='<edge-003@contoso.test>'")[0][0] | Should -Be 'Sent to external'
        $route = (Import-Csv (Join-Path $r.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' | Where-Object 'Message ID' -eq '<edge-001@fabrikam.example>').Route
        @($route -split "`n" | ForEach-Object { ($_ -split ' \| ')[-1] } | Select-Object -Unique) | Should -Be @('submission 1')
        $html = Get-Content -Raw $r.HtmlPath
        $html | Should -Match '"edge":true'
        $html | Should -Match '"title":"Edge Transport mail flow"'
        $html | Should -Match '"smtpdestinations":\{'
        $html | Should -Not -Match '"users":\{'
        # A mailbox server in the report: the usual report, without SMTP destinations.
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { $m = New-ExlReport -Store $store -Settings $script:Settings -Period $period -ReportType Detailed } finally { $store.Dispose() }
        $m.Counts.ContainsKey('smtpdestinations') | Should -BeFalse
        $m.Counts.ContainsKey('sessions') | Should -BeTrue
    }
    It 'resolves the role for a report without collection from the database, and never fails on a folder that cannot be read' {
        # Every server folder answers "access denied" (account that is not administrator of the servers).
        Mock -ModuleName ExchangeLogReport Test-Path { if ($LiteralPath -like '\\*') { if ($PesterBoundParameters['ErrorAction'] -notin 'SilentlyContinue', 'Ignore') { throw "Access to the path '$LiteralPath' is denied." }; $false } else { Microsoft.PowerShell.Management\Test-Path @PesterBoundParameters } }
        $new = { param($Name) & (Get-Module ExchangeLogReport) { param($n, $src) Resolve-ExlServerPaths -Name $n -Sources $src } $Name $script:EdgeSettings.Sources }
        # Report without collection: the Edge SMTP data already collected, the servers are not contacted.
        $store = Open-ExlStore -Settings $script:EdgeSettings -ReadOnly
        try {
            $edge = & $new 'EDGE01'
            Resolve-ExlServerRole -Server $edge -Store $store | Should -Be 'Edge'
            $edge.RoleOrigin | Should -Be 'Detected'
            Resolve-ExlServerRole -Server (& $new 'EXCH42') -Store $store | Should -Be 'Mailbox'
        } finally { $store.Dispose() }
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { Resolve-ExlServerRole -Server (& $new $script:Settings.Servers[0].Name) -Store $store | Should -Be 'Mailbox' } finally { $store.Dispose() }
        Should -Invoke -ModuleName ExchangeLogReport Test-Path -Times 0 -Exactly -ParameterFilter { $LiteralPath -like '\\*' }
        # Collection with folders that cannot be read: Mailbox, and every folder reported as not readable (no error).
        $denied = & $new 'EDGE01'
        Resolve-ExlServerRole -Server $denied | Should -Be 'Mailbox'
        $problems = @(Test-ExlServerAccess -Server $denied -Settings $script:EdgeSettings)
        $problems.Count | Should -BeGreaterThan 0
        $problems | ForEach-Object { $_ | Should -Match 'folder not found or not readable' }
    }
    It 'reads the settings of an Edge Transport server with -Mode Discover, and records a subscribed Edge seen from the organisation' {
        $config = & $script:NewEdgeConfig 'discover' "@{ Name = 'EDGE01' }"
        $before = Import-ExlConfiguration -Path $config -Root $script:Root
        Mock -ModuleName ExchangeLogReport Get-ExlExchangeSettings {
            [pscustomobject]@{ Method = 'Exchange Management Shell (Edge Transport)'; Via = 'EDGE01'; Account = 'EDGE01\admin'; ExchangeCount = 3; EdgeServers = @()
                Servers = @([pscustomobject]@{ Name = 'EDGE01'; Role = 'Edge'; Version = '15.2.2562.17'; Site = $null; InstallPath = 'D:\Exchange\'
                        EdgeReceivePath = 'L:\Edge\Receive'; EdgeSendPath = 'D:\Exchange\TransportRoles\Logs\Edge\ProtocolLog\SmtpSend'
                        MessageTrackingPath = 'L:\Tracking'; MessageTrackingEnabled = $true; LoggingOff = @("receive connector 'Default internal receive connector EDGE01'"); Warnings = @() }) }
        }
        Mock -ModuleName ExchangeLogReport Get-ExlIisSiteMap { throw 'An Edge Transport server has no IIS.' }
        Mock -ModuleName ExchangeLogReport Test-Path { if ($LiteralPath -like '\\EDGE0*') { $false } else { Microsoft.PowerShell.Management\Test-Path @PesterBoundParameters } }
        $r = Invoke-ExlDiscovery -Settings $before 6>$null
        $r.Found | Should -Be @('EDGE01')
        $r.Edge | Should -Be @('EDGE01')
        $r.NotFound | Should -BeNullOrEmpty
        ($r.Warnings -join "`n") | Should -Match "EDGE01: SMTP protocol logging is off on receive connector 'Default internal receive connector EDGE01'"
        ($r.Warnings -join "`n") | Should -Match 'EDGE01: not found or not readable by .*: Tracking \(\\\\EDGE01\\L\$\\Tracking\)'
        Should -Invoke -ModuleName ExchangeLogReport Get-ExlIisSiteMap -Times 0 -Exactly
        $file = (Import-PowerShellDataFile -LiteralPath $r.File).Servers['EDGE01']
        $file.Role | Should -Be 'Edge'
        $file.Keys | Should -Not -Contain 'IisFrontEndPath'
        $file.Keys | Should -Not -Contain 'ImapProtocolLog'
        $after = Import-ExlConfiguration -Path $config -Root $script:Root
        $edge = $after.Servers[0]
        @($edge.Role, $edge.RoleOrigin) | Should -Be @('Edge', 'Discover')
        $edge.ExchangePath | Should -Be '\\EDGE01\D$\Exchange'
        $edge.EdgeReceivePath | Should -Be '\\EDGE01\L$\Edge\Receive'
        $edge.MessageTrackingPath | Should -Be '\\EDGE01\L$\Tracking'
        # From a mailbox server: the subscribed Edge of the configuration is recorded with its role only.
        $config = & $script:NewEdgeConfig 'discover-org' "@{ Name = 'EXCH01' }`r`n        @{ Name = 'EDGE01' }"
        $before = Import-ExlConfiguration -Path $config -Root $script:Root
        Mock -ModuleName ExchangeLogReport Get-ExlExchangeSettings {
            [pscustomobject]@{ Method = 'Exchange Management Shell'; Via = 'EXCH01'; Account = 'CONTOSO\admin'; ExchangeCount = 2; EdgeServers = @('EDGE01', 'EDGE99')
                Servers = @([pscustomobject]@{ Name = 'EXCH01'; Role = 'Mailbox'; Version = '15.2.2562.17'; Site = 'PARIS'; DataPath = 'C:\Program Files\Microsoft\Exchange Server\V15\Mailbox'
                        ImapLogPath = $null; ImapProtocolLog = $false; PopLogPath = $null; PopProtocolLog = $false; FrontEndReceivePath = $null; FrontEndSendPath = $null
                        HubReceivePath = $null; HubSendPath = $null; MailboxReceivePath = $null; MailboxSendPath = $null; MessageTrackingPath = $null
                        MessageTrackingEnabled = $true; LoggingOff = @(); Warnings = @() }) }
        }
        Mock -ModuleName ExchangeLogReport Get-ExlIisSiteMap { $null }
        Mock -ModuleName ExchangeLogReport Test-Path { if ($LiteralPath -like '\\E*0*') { $false } else { Microsoft.PowerShell.Management\Test-Path @PesterBoundParameters } }
        $r = Invoke-ExlDiscovery -Settings $before 6>$null
        $r.Found | Should -Be @('EXCH01', 'EDGE01')
        $r.Edge | Should -Be @('EDGE01')
        $r.NotFound | Should -BeNullOrEmpty
        $after = Import-ExlConfiguration -Path $config -Root $script:Root
        @($after.Servers[0].Role, $after.Servers[1].Role, $after.Servers[1].RoleOrigin) | Should -Be @('Mailbox', 'Edge', 'Discover')
        $after.Servers[1].EdgeReceivePath | Should -Be '\\EDGE01\c$\Program Files\Microsoft\Exchange Server\V15\TransportRoles\Logs\Edge\ProtocolLog\SmtpReceive'
    }
}

Describe 'Mail sent to external' {
    BeforeAll {
        $script:ExtDir = Join-Path $TestDrive 'external'
        $config = New-TestConfig $script:ExtDir @{ 'InternalDomains        = @()' = "InternalDomains        = @('internal.test')" }
        $script:ExtSettings = Import-ExlConfiguration -Path $config -Root $script:Root
        $script:ExtFields = '#Fields: date-time,client-ip,client-hostname,server-ip,server-hostname,source-context,connector-id,source,event-id,internal-message-id,message-id,network-message-id,recipient-address,recipient-status,total-bytes,recipient-count,related-recipient-address,reference,message-subject,sender-address,return-path,message-info,directionality,tenant-id,original-client-ip,original-server-ip,custom-data,transport-traffic-type,log-id,schema-version'
        # One tracking line: minutes after Base, event, Message-ID, recipient, recipient status, connector, next host (server-ip, and server-hostname
        # unless PeerHost is given), directionality, sender, source.
        $script:ExtLine = { param($min, $evt, $id, $rcpt, $status, $connector, $peer, $direction, $sender = 'alice@contoso.test', $source = 'SMTP', $peerHost = $null)
            $hostName = if ($null -ne $peerHost) { $peerHost } else { $peer }
            "$(T $min),10.0.0.1,EXCH01.contoso.test,$peer,$hostName,,$connector,$source,$evt,9001,$id,net-x,$rcpt,$status,2048,1,,,External,$sender,$sender,,$direction,,,,,Email,$([guid]::NewGuid()),15.02.2562.045" }
        $script:ExtLog = Join-Path $script:ExtDir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\MessageTracking'
        $postfix = 'To Internet via Postfix'
        Write-Log (Join-Path $script:ExtLog 'MSGTRK2026100108-2.LOG') @(
            $script:ExtFields
            # Mail from outside addressed to a domain of ours (learnt from the recipients of an Incoming RECEIVE).
            (& $script:ExtLine 30 'RECEIVE' '<inbound@fabrikam-hosted.test>' 'user@fabrikam-hosted.test' '' 'Default EXCH01' '' 'Incoming' 'someone@gmail.example')
            (& $script:ExtLine 31 'SENDEXTERNAL' '<x-out@contoso.test>' 'partner@fabrikam.example' '250 2.1.5 Ok' $postfix '203.0.113.5' 'Originating')
            # A sub-domain of a configured internal domain, a learnt domain and a sub-domain of a learnt domain: handed off.
            (& $script:ExtLine 32 'SENDEXTERNAL' '<x-sub@contoso.test>' 'someone@sub.internal.test' '250 2.1.5 Ok' $postfix '203.0.113.5' 'Originating')
            (& $script:ExtLine 33 'SENDEXTERNAL' '<x-hosted@contoso.test>' 'user@fabrikam-hosted.test' '250 2.1.5 Ok' $postfix '203.0.113.5' 'Originating')
            (& $script:ExtLine 34 'SENDEXTERNAL' '<x-hosted-sub@contoso.test>' 'desk@tickets.fabrikam-hosted.test' '250 2.1.5 Ok' $postfix '203.0.113.5' 'Originating')
            # EXCH02 (a collected server) named with its address by a hop of the organization, then reached by that address only: handed off.
            (& $script:ExtLine 35 'SEND' '<x-hop@contoso.test>' 'bob@contoso.test' '250 2.1.5 Recipient OK' 'Intra-Organization SMTP Send Connector' '10.0.0.2' 'Originating' 'alice@contoso.test' 'SMTP' 'EXCH02.contoso.test')
            (& $script:ExtLine 36 'SENDEXTERNAL' '<x-by-address@contoso.test>' 'partner@fabrikam.example' '250 2.1.5 Ok' $postfix '10.0.0.2' 'Originating' 'alice@contoso.test' 'SMTP' '')
        )
        [void](Invoke-TestCollection $script:ExtSettings)
        function ExtStatus([string]$Id, $Settings = $script:ExtSettings) { (Query $Settings "SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0 AND r.identity='$Id'")[0][0] }
        function ExtMeta([string]$Key, $Settings = $script:ExtSettings) { $rows = Query $Settings "SELECT value FROM metadata WHERE key='$Key'"; if ($rows.Count) { $rows[0][0] } else { $null } }
        function ExtVerified($Settings) {
            $store = Open-ExlStore -Settings $Settings -ReadOnly
            try { return $store.VerifyServeRollups().Verified } finally { $store.Dispose() }
        }
        # Every column of every message rollup, the coded ones as their text (the ids depend on the order of the writes).
        $script:RollupDump = { param($Settings)
            $rows = Query $Settings @'
SELECT r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,
 r.subject,r.size_kb,d.text,sv.text,e.text,r.events_count,r.smtp_count
FROM message_rollup r JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction
 LEFT JOIN message_rollup_value sv ON sv.id=r.servers LEFT JOIN message_rollup_value e ON e.id=r.events ORDER BY r.kind,r.identity
'@
            , @(foreach ($r in $rows) { $r -join '|' }) }
    }
    It 'learns the accepted domains and the addresses of the collected servers from the logs and keeps them with the rules of the collection' {
        ExtMeta 'mailflow_accepted_domains' | Should -BeExactly 'contoso.test;fabrikam-hosted.test'
        $rules = ExtMeta 'mailflow_rules' | ConvertFrom-Json
        $rules.version | Should -Be 1
        @($rules.internalDomains) | Should -Be @('internal.test')
        @($rules.internalConnectors).Count | Should -Be 0
        @($rules.defaultConnectors) | Should -Be @('^Intra-Organization SMTP Send Connector$', '^EdgeSync - Inbound to ', '^Inbound Proxy ', '^Outbound to Office 365')
        @($rules.servers) | Should -Be @('10.0.0.2', 'exch01', 'exch02')
        $rules.saturated | Should -BeFalse
        ExtMeta 'mailflow_pending' | Should -BeNullOrEmpty
    }
    It 'names only the mail accepted outside for a foreign domain sent to external, in the rollups and in the report' {
        ExtStatus '<x-out@contoso.test>' | Should -Be 'Sent to external'
        ExtStatus '<x-sub@contoso.test>' | Should -Be 'Handed off outside collection'
        ExtStatus '<x-hosted@contoso.test>' | Should -Be 'Handed off outside collection'
        ExtStatus '<x-hosted-sub@contoso.test>' | Should -Be 'Handed off outside collection'
        ExtStatus '<x-by-address@contoso.test>' | Should -Be 'Handed off outside collection'
        $period = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $store = Open-ExlStore -Settings $script:ExtSettings -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:ExtSettings -Period $period -ReportType Detailed } finally { $store.Dispose() }
        $rows = @{}; foreach ($m in Import-Csv (Join-Path $r.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';') { $rows[$m.'Message ID'] = $m }
        $rows['<x-out@contoso.test>'].Status | Should -Be 'Sent to external'
        $rows['<x-out@contoso.test>'].Recipients | Should -Be 'partner@fabrikam.example (Sent to external)'
        $rows['<x-sub@contoso.test>'].Status | Should -Be 'Handed off outside collection'
        $rows['<x-hosted-sub@contoso.test>'].Recipients | Should -Be 'desk@tickets.fabrikam-hosted.test (Handed off)'
        $rows['<x-by-address@contoso.test>'].Status | Should -Be 'Handed off outside collection'
        ExtVerified $script:ExtSettings | Should -BeTrue
    }
    It 'shows the rules and the learnt domains in -Mode Status' {
        $text = & (Get-Module ExchangeLogReport) { param($se) $store = Open-ExlStore -Settings $se -ReadOnly; try { Show-ExlStatus -Store $store -Settings $se } finally { $store.Dispose() } } $script:ExtSettings 6>&1 | Out-String
        $text | Should -Match 'Sent to external: on\. 2 domain\(s\) of yours learnt from the logs, 1 in Collection\.InternalDomains \(internal\.test\)'
        $text | Should -Match 'contoso\.test, fabrikam-hosted\.test'
    }
    It 'reconciles the external mail again when a later collection learns a domain or the configuration changes' {
        Write-Log (Join-Path $script:ExtLog 'MSGTRK2026100108-3.LOG') @(
            $script:ExtFields
            # fabrikam.example becomes a domain of ours: a mailbox here receives its mail.
            (& $script:ExtLine 40 'DELIVER' '<x-in@contoso.test>' 'partner@fabrikam.example' '' '' '' 'Originating' 'alice@contoso.test' 'STOREDRIVER')
            (& $script:ExtLine 41 'SENDEXTERNAL' '<x-out2@contoso.test>' 'buyer@northwind.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating')
        )
        [void](Invoke-TestCollection $script:ExtSettings)
        ExtMeta 'mailflow_accepted_domains' | Should -BeExactly 'contoso.test;fabrikam-hosted.test;fabrikam.example'
        ExtMeta 'mailflow_pending' | Should -BeNullOrEmpty
        ExtStatus '<x-out@contoso.test>' | Should -Be 'Handed off outside collection'
        ExtStatus '<x-out2@contoso.test>' | Should -Be 'Sent to external'
        # A connector of the company configured as internal: no new line, the rows it changes are reconciled at the end of the collection.
        $script:ExtSettings.Collection.InternalConnectors = [string[]]@('^To Internet via ')
        [void](Invoke-TestCollection $script:ExtSettings)
        @((ExtMeta 'mailflow_rules' | ConvertFrom-Json).internalConnectors) | Should -Be @('^To Internet via ')
        ExtStatus '<x-out2@contoso.test>' | Should -Be 'Handed off outside collection'
        (Query $script:ExtSettings 'SELECT COUNT(*) FROM message_rollup_dirty')[0][0] | Should -Be 0
        ExtVerified $script:ExtSettings | Should -BeTrue
    }
    It 'bounds the accepted domains and learns them only from the three kinds of events' {
        $rules = [ExchangeLogReport.MailFlowRules]::new()
        $rules.LearnFrom('SENDEXTERNAL', 'SMTP', 'x@outside.example', 'y@gmail.example', 'Incoming') | Should -Be 0
        $rules.LearnFrom('RECEIVE', 'SMTP', 'x@outside.example', 'me@ours.example', 'Incoming') | Should -Be 1
        $rules.LearnFrom('SUBMIT', 'STOREDRIVER', 'me@sent.example', 'y@gmail.example', '') | Should -Be 1
        $rules.LearnFrom('SEND', 'SMTP', 'me@originating.example', 'y@gmail.example', 'Originating') | Should -Be 1
        $rules.LearnFrom('DELIVER', 'STOREDRIVER', '', 'a@[192.0.2.1];postmaster;b@Deliver.Example', 'Incoming') | Should -Be 1
        $rules.DomainsText() | Should -BeExactly 'deliver.example;originating.example;ours.example;sent.example'
        # Without any known domain, every recipient looks foreign: none is sent to external.
        [ExchangeLogReport.MailFlowRules]::new().HasDomains | Should -BeFalse
        [ExchangeLogReport.MailFlowRules]::new().Active | Should -BeFalse
        $rules.WithConfiguration([string[]]@('Contoso.com'), [string[]]@(), [string[]]@()).IsAcceptedDomain('mail.contoso.com') | Should -BeTrue
        $rules.IsAcceptedDomain('sub.ours.example') | Should -BeTrue
        $rules.IsAcceptedDomain('ours.example.net') | Should -BeFalse
        $rules.IsAcceptedDomain('notours.example') | Should -BeFalse
        # A missing connector is never taken for a connector that leaves the organization.
        $rules.IsInternalConnector('') | Should -BeTrue
        $rules.IsInternalConnector('Outbound to Office 365 - 6f1c8b4e-1d2a-4b5c-9e3f-0a1b2c3d4e5f') | Should -BeTrue
        $rules.IsInternalConnector('To Internet via Postfix') | Should -BeFalse
    }
    It 'gives the stronger sources priority and turns the external status off when the set of domains is full' {
        $max = [ExchangeLogReport.MailFlowRules]::MaxLearnedDomains; $weak = [ExchangeLogReport.MailFlowRules]::MaxOriginatingDomains
        $max | Should -BeGreaterThan $weak
        $rules = [ExchangeLogReport.MailFlowRules]::new()
        # The senders of Originating events (an application relay is Originating too) fill the set up to their own bound only.
        foreach ($i in 1..($weak + 10)) { [void]$rules.LearnFrom('SEND', 'SMTP', "app@relay$i.example", 'y@gmail.example', 'Originating') }
        $rules.LearnedCount | Should -Be $weak
        foreach ($i in 1..($max - $weak)) { [void]$rules.LearnFrom('DELIVER', 'STOREDRIVER', '', "u@d$i.example", 'Incoming') }
        $rules.LearnedCount | Should -Be $max
        $rules.Saturated | Should -BeFalse
        $rules.Active | Should -BeTrue
        $rules.LearnFrom('SEND', 'SMTP', 'app@late-relay.example', 'y@gmail.example', 'Originating') | Should -Be 0
        $rules.Saturated | Should -BeFalse
        # A domain proved by a delivery that does not fit: the set may miss a domain of ours, so nothing is sent to external.
        $rules.LearnFrom('DELIVER', 'STOREDRIVER', '', 'u@late-brand.example', 'Incoming') | Should -Be 1
        $rules.Saturated | Should -BeTrue
        $rules.Active | Should -BeFalse
        $rules.LearnedCount | Should -Be $max
        ($rules.RulesText() | ConvertFrom-Json).saturated | Should -BeTrue
        $back = [ExchangeLogReport.MailFlowRules]::Parse($rules.RulesText(), $rules.DomainsText())
        $back.Saturated | Should -BeTrue
        $back.LearnedCount | Should -Be $max
    }
    It 'keeps the learnt domains when the stored rules are of another rule version' {
        $dir = Join-Path $TestDrive 'external-version'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        $log = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\MessageTracking'
        Write-Log (Join-Path $log 'MSGTRK2026100108-2.LOG') @($script:ExtFields
            (& $script:ExtLine 30 'DELIVER' '<v-in@contoso.test>' 'user@kept.example' '' '' '' 'Originating' 'alice@contoso.test' 'STOREDRIVER'))
        [void](Invoke-TestCollection $s)
        ExtMeta 'mailflow_accepted_domains' $s | Should -BeExactly 'contoso.test;kept.example'
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("UPDATE metadata SET value=replace(value,'""version"":1','""version"":99') WHERE key='mailflow_rules';") } finally { $store.Dispose() }
        $store = Open-ExlStore -Settings $s -ReadOnly
        try { $old = $store.ReadMailFlowRules() } finally { $store.Dispose() }
        $old.External | Should -BeFalse
        @($old.LearnedDomains) | Should -Be @('contoso.test', 'kept.example')
        Write-Log (Join-Path $log 'MSGTRK2026100108-3.LOG') @($script:ExtFields
            (& $script:ExtLine 40 'SENDEXTERNAL' '<v-out@contoso.test>' 'buyer@kept.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating'))
        [void](Invoke-TestCollection $s)
        (ExtMeta 'mailflow_rules' $s | ConvertFrom-Json).version | Should -Be 1
        ExtMeta 'mailflow_accepted_domains' $s | Should -BeExactly 'contoso.test;kept.example'
        ExtStatus '<v-out@contoso.test>' $s | Should -Be 'Handed off outside collection'
        ExtVerified $s | Should -BeTrue
    }
    It 'turns the external status off in the collection and in -Mode Status when a domain arrives with the set of domains full' {
        $dir = Join-Path $TestDrive 'external-full'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        $log = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\MessageTracking'
        Write-Log (Join-Path $log 'MSGTRK2026100108-2.LOG') @($script:ExtFields
            (& $script:ExtLine 31 'SENDEXTERNAL' '<f-out@contoso.test>' 'partner@fabrikam.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating'))
        [void](Invoke-TestCollection $s)
        ExtStatus '<f-out@contoso.test>' $s | Should -Be 'Sent to external'
        # The set holds as many domains as it can (none of them fabrikam.example).
        $count = [int](Query $s "SELECT length(value)-length(replace(value,';',''))+1 FROM metadata WHERE key='mailflow_accepted_domains'")[0][0]
        $fill = @(1..([ExchangeLogReport.MailFlowRules]::MaxLearnedDomains - $count) | ForEach-Object { 'fill{0:d5}.example' -f $_ })
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("UPDATE metadata SET value=value||';$($fill -join ';')' WHERE key='mailflow_accepted_domains';") } finally { $store.Dispose() }
        Write-Log (Join-Path $log 'MSGTRK2026100108-3.LOG') @($script:ExtFields
            (& $script:ExtLine 40 'DELIVER' '<f-in@contoso.test>' 'user@late-brand.example' '' '' '' 'Originating' 'alice@contoso.test' 'STOREDRIVER'))
        [void](Invoke-TestCollection $s)
        (ExtMeta 'mailflow_rules' $s | ConvertFrom-Json).saturated | Should -BeTrue
        ExtStatus '<f-out@contoso.test>' $s | Should -Be 'Handed off outside collection'
        (Query $s 'SELECT COUNT(*) FROM message_rollup_dirty')[0][0] | Should -Be 0
        ExtVerified $s | Should -BeTrue
        $text = & (Get-Module ExchangeLogReport) { param($se) $store = Open-ExlStore -Settings $se -ReadOnly; try { Show-ExlStatus -Store $store -Settings $se } finally { $store.Dispose() } } $s 6>&1 | Out-String
        $text | Should -Match 'Sent to external: off\. The list of your domains learnt from the logs is full \(4,096 domains\)'
    }
    It 'gives the same stored rows whatever the order in which the same logs are collected' {
        $teach = @($script:ExtFields
            (& $script:ExtLine 50 'DELIVER' '<o-in@contoso.test>' 'user@neworg.example' '' '' '' 'Originating' 'alice@contoso.test' 'STOREDRIVER'))
        $send = @($script:ExtFields
            (& $script:ExtLine 20 'SENDEXTERNAL' '<o-out@contoso.test>' 'buyer@neworg.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating')
            (& $script:ExtLine 21 'SENDEXTERNAL' '<o-sub@contoso.test>' 'desk@eu.neworg.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating')
            (& $script:ExtLine 22 'SENDEXTERNAL' '<o-far@contoso.test>' 'buyer@far.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating'))
        $dumps = foreach ($order in @(@('teach', 'send'), @('send', 'teach'))) {
            $dir = Join-Path $TestDrive "external-order-$($order -join '-')"
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $log = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\MessageTracking'
            $k = 2
            foreach ($name in $order) {
                Write-Log (Join-Path $log "MSGTRK2026100108-$k.LOG") $(if ($name -eq 'teach') { $teach } else { $send })
                [void](Invoke-TestCollection $s)
                $k++
            }
            ExtStatus '<o-out@contoso.test>' $s | Should -Be 'Handed off outside collection' -Because ($order -join ' then ')
            ExtStatus '<o-sub@contoso.test>' $s | Should -Be 'Handed off outside collection' -Because ($order -join ' then ')
            ExtStatus '<o-far@contoso.test>' $s | Should -Be 'Sent to external' -Because ($order -join ' then ')
            ExtVerified $s | Should -BeTrue
            , (& $script:RollupDump $s)
        }
        $dumps[0].Count | Should -BeGreaterThan 3
        $dumps[1] | Should -Be $dumps[0]
    }
    It 'keeps a domain learnt by a commit that failed, and applies it with the next collection' {
        $dir = Join-Path $TestDrive 'external-rollback'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        $log = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\MessageTracking'
        Write-Log (Join-Path $log 'MSGTRK2026100108-2.LOG') @($script:ExtFields
            (& $script:ExtLine 31 'SENDEXTERNAL' '<r-out@contoso.test>' 'buyer@brand.example' '250 2.1.5 Ok' 'To Internet via Postfix' '203.0.113.5' 'Originating'))
        [void](Invoke-TestCollection $s)
        ExtStatus '<r-out@contoso.test>' $s | Should -Be 'Sent to external'
        $path = Join-Path $log 'MSGTRK2026100108-3.LOG'
        Write-Log $path @($script:ExtFields
            (& $script:ExtLine 40 'DELIVER' '<r-in@contoso.test>' 'user@brand.example' '' '' '' 'Originating' 'alice@contoso.test' 'STOREDRIVER'))
        $store = Open-ExlStore -Settings $s
        try {
            $o = [ExchangeLogReport.CollectorOptions]::new()
            $o.RunId = $store.StartRun('Collect', 'rollback', 'synthetic', '1.0.0')
            $o.ConfiguredServers = [string[]]@('EXCH01', 'EXCH02'); $o.Parallelism = 1
            $o.DisableTriggersDuringApply = $false   # the failure below is injected by an SQL trigger, which only runs on a connection that has triggers on
            $job = [ExchangeLogReport.SourceJob]::new()
            $job.Server = 'EXCH01'; $job.Kind = 'Tracking'; $job.Folder = $log; $job.Filter = 'MSGTRK2026100108-3.LOG'
            # The commit of the batch that learnt brand.example fails.
            $store.Exec("CREATE TRIGGER test_block_pending BEFORE INSERT ON metadata WHEN NEW.key='mailflow_pending' BEGIN SELECT RAISE(ABORT,'blocked by the test'); END;")
            $collector = [ExchangeLogReport.Collector]::new($store, $o)
            $collector.Plan(@($job), [DateTime]::MinValue)
            $job.Files.Count | Should -Be 1
            $run = $collector.Start(@($job))
            while (-not $run.Wait(1000)) { }
            $run.Error | Should -Not -BeNullOrEmpty
            $store.Query("SELECT COUNT(*) FROM message_event WHERE message_id='<r-in@contoso.test>'", $null).Rows[0][0] | Should -Be 0
            $store.Query("SELECT value FROM metadata WHERE key='mailflow_accepted_domains'", $null).Rows[0][0] | Should -Not -Match 'brand\.example'
            $store.Exec('DROP TRIGGER test_block_pending;')
            # The end of the collection fails: the batch and its pending domain are stored, the rules are not.
            $store.Exec("CREATE TRIGGER test_block_rules BEFORE UPDATE ON metadata WHEN NEW.key='mailflow_accepted_domains' BEGIN SELECT RAISE(ABORT,'blocked by the test'); END;")
            $job.FilesApplied = 0
            $retry = [ExchangeLogReport.Collector]::new($store, $o)
            $run = $retry.Start(@($job))
            while (-not $run.Wait(1000)) { }
            $run.Error | Should -Not -BeNullOrEmpty
            $store.Query("SELECT COUNT(*) FROM message_event WHERE message_id='<r-in@contoso.test>'", $null).Rows[0][0] | Should -Be 1
            $store.Query("SELECT value FROM metadata WHERE key='mailflow_pending'", $null).Rows[0][0] | Should -Match 'brand\.example'
            $store.Exec('DROP TRIGGER test_block_rules;')
        } finally { $store.Dispose() }
        $text = & (Get-Module ExchangeLogReport) { param($se) $store = Open-ExlStore -Settings $se -ReadOnly; try { Show-ExlStatus -Store $store -Settings $se } finally { $store.Dispose() } } $s 6>&1 | Out-String
        $text | Should -Match 'Learnt by a collection and not applied yet: 1 domain\(s\)'
        # The next collection has no new line: it applies the pending domain.
        [void](Invoke-TestCollection $s)
        ExtMeta 'mailflow_accepted_domains' $s | Should -BeExactly 'brand.example;contoso.test'
        ExtMeta 'mailflow_pending' $s | Should -BeNullOrEmpty
        ExtStatus '<r-out@contoso.test>' $s | Should -Be 'Handed off outside collection'
        (Query $s 'SELECT COUNT(*) FROM message_rollup_dirty')[0][0] | Should -Be 0
        ExtVerified $s | Should -BeTrue
    }
    It 'upgrades an older database for a report or -Mode Status only under the collector lock' {
        $dir = Join-Path $TestDrive 'external-upgrade-lock'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        [void](Invoke-TestCollection $s)
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("UPDATE metadata SET value='12' WHERE key='schema_version';") } finally { $store.Dispose() }
        [ExchangeLogReport.Store]::RequiresUpgrade($s.Storage.DatabasePath) | Should -BeTrue
        $module = Get-Module ExchangeLogReport
        $wait = & $module { $script:UpgradeLockWaitSeconds }
        $lock = & $module { param($p) Enter-ExlLock -Path $p } ($s.Storage.DatabasePath + '.lock')
        try {
            & $module { $script:UpgradeLockWaitSeconds = 1 }
            { & $module { param($se) (Open-ExlStore -Settings $se -ReadOnly).Dispose() } $s } |
                Should -Throw -ExpectedMessage '*must be upgraded once for this version before it can be read, and a collection is running*Run this command again when the collection has finished.'
        } finally { & $module { param($w) $script:UpgradeLockWaitSeconds = $w } $wait; & $module { param($l) Exit-ExlLock $l } $lock }
        [ExchangeLogReport.Store]::RequiresUpgrade($s.Storage.DatabasePath) | Should -BeTrue
        $store = & $module { param($se) Open-ExlStore -Settings $se -ReadOnly } $s
        try { $store.Query("SELECT value FROM metadata WHERE key='schema_version'", $null).Rows[0][0] | Should -Be '13' } finally { $store.Dispose() }
        [ExchangeLogReport.Store]::RequiresUpgrade($s.Storage.DatabasePath) | Should -BeFalse
    }
    It 'refuses a configured internal domain that is not a domain name' {
        $bad = New-TestConfig (Join-Path $TestDrive 'external-bad') @{ 'InternalDomains        = @()' = "InternalDomains        = @('not a domain')"; 'InternalConnectors     = @()' = "InternalConnectors     = @('[')" }
        { Import-ExlConfiguration -Path $bad -Root $script:Root } | Should -Throw -ExpectedMessage '*Collection.InternalDomains must list domain names*'
        { Import-ExlConfiguration -Path $bad -Root $script:Root } | Should -Throw -ExpectedMessage '*Collection.InternalConnectors contains an invalid regular expression*'
    }
}

Describe 'Collection and noise removal' {
    It 'keeps only real users and real messages' {
        $users = @((Query $script:Settings 'SELECT DISTINCT user FROM access_usage ORDER BY user') | ForEach-Object { $_[0] })
        $users | Should -Be @('bob@contoso.test', 'contoso\alice', 'contoso\carol', 'contoso\dave', 'contoso\erin', 'contoso\frank', 'contoso\grace', 'contoso\labadmin')
        (Query $script:Settings "SELECT COUNT(*) FROM access_usage WHERE user LIKE '%health%'")[0][0] | Should -Be 0
    }
    It 'counts every removed line by reason' {
        $r = $script:First.NoiseReasons
        $r['Monitoring probe (user agent)'] | Should -BeGreaterOrEqual 3
        $r['System or health mailbox'] | Should -BeGreaterOrEqual 1
        $r['Authentication challenge (anonymous 401)'] | Should -Be 1
        $r['Connection without message (168.63.129.16)'] | Should -Be 3
        $r['Shadow redundancy event (HARECEIVE)'] | Should -Be 1
        $r['System or probe message'] | Should -Be 1
        $script:First.Lines | Should -Be ($script:First.Kept + $script:First.Noise)
    }
    It 'does not count the anonymous 401 challenge as a failure' {
        $row = (Query $script:Settings "SELECT requests, successes, client_errors, server_errors FROM access_usage WHERE user='contoso\alice' AND protocol='Mapi'")[0]
        @($row) | Should -Be @(3, 2, 0, 1)
    }
    It 'marks a failure followed by a success of the same user as recovered' {
        $rec = (Query $script:Settings "SELECT recovered_ms - time_ms FROM access_event WHERE user='contoso\alice' AND status=500")[0][0]
        $rec | Should -Be 30000
        (Query $script:Settings "SELECT recovered_ms FROM access_event WHERE user='bob@contoso.test'")[0][0] | Should -BeNullOrEmpty
    }
    It 'keeps the IIS Win32 status of a proxied failure and the requests rejected before the proxy' {
        (Query $script:Settings "SELECT win32, time_taken FROM iis_status WHERE status = 503")[0] | Should -Be @(1236, 30000)
        (Query $script:Settings "SELECT source, status, sub_status FROM access_event WHERE user='contoso\carol'")[0] | Should -Be @('IIS', 403, 4)
    }
    It 'stores SMTP transactions, not connections, with the message ID of the queued response' {
        $rows = Query $script:Settings 'SELECT direction, mail_from, rcpt_count, message_id, internal_id, status, tls FROM smtp_transaction ORDER BY time_ms, direction'
        $rows.Count | Should -Be 5
        @($rows[0]) | Should -Be @('Receive', 'alice@contoso.test', 2, '<msg-001@contoso.test>', '1001', 'Accepted', 'TLS 1.2')
        @($rows[1]) | Should -Be @('Send', 'alice@contoso.test', 1, '<msg-001@contoso.test>', '2002', 'Sent', $null)
        @($rows[2])[3] | Should -Be '<msg-001@contoso.test>'
        $rows[3][5] | Should -Be 'Rejected'
        (Query $script:Settings "SELECT transcript FROM smtp_transaction WHERE direction='Receive' AND status='Accepted' AND message_id='<msg-001@contoso.test>'")[0][0] | Should -Match 'BDAT 2048 LAST'
    }
    It 'reads only the new lines at the next collection' {
        $again = Invoke-TestCollection $script:Settings
        $again.Lines | Should -Be 0
        $file = Get-ChildItem (Join-Path $script:Dir 'logs-src') -Recurse -Filter 'HttpProxy_*.LOG' | Where-Object { $_.Directory.Name -eq 'PowerShell' }
        $line = ProxyLine @{ DateTime = (T 30); RequestId = [guid]::NewGuid(); Protocol = 'PowerShell'; UrlStem = '/powershell'; AuthenticatedUser = 'CONTOSO\labadmin'; UserAgent = 'Microsoft WinRM Client'; ClientIpAddress = '10.1.1.5'; HttpStatus = 200 }
        [IO.File]::AppendAllText($file.FullName, $line + "`r`n")
        $next = Invoke-TestCollection $script:Settings
        $next.Lines | Should -Be 1
        $next.Kept | Should -Be 1
        (Query $script:Settings "SELECT SUM(requests) FROM access_usage WHERE user='contoso\labadmin'")[0][0] | Should -Be 2
    }
    It 'holds back an SMTP session still open at the end of the current file' {
        $dir = Join-Path $TestDrive 'open'
        $cfg = New-TestConfig $dir
        $s = Import-ExlConfiguration -Path $cfg -Root $script:Root
        $file = Get-ChildItem $dir -Recurse -Filter 'RECV*.LOG' | Select-Object -First 1
        $c = 'EXCH01\Default Frontend EXCH01'
        $now = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        [IO.File]::AppendAllText($file.FullName, "$now,$c,08DF0000000000FF,0,10.0.0.1:25,10.1.1.60:5000,+,,`r`n$now,$c,08DF0000000000FF,1,10.0.0.1:25,10.1.1.60:5000,<,MAIL FROM:<eve@contoso.test>,`r`n")
        [void](Invoke-TestCollection $s)
        (Query $s "SELECT COUNT(*) FROM smtp_transaction WHERE mail_from='eve@contoso.test'")[0][0] | Should -Be 0
        $state = (Query $s "SELECT offset, size FROM source_file WHERE kind='SmtpReceive' AND path LIKE '%\FrontEnd\%'")[0]
        $state[0] | Should -BeLessThan $state[1]
        [IO.File]::AppendAllText($file.FullName, "$now,$c,08DF0000000000FF,2,10.0.0.1:25,10.1.1.60:5000,<,RCPT TO:<bob@contoso.test>,`r`n$now,$c,08DF0000000000FF,3,10.0.0.1:25,10.1.1.60:5000,<,DATA,`r`n$now,$c,08DF0000000000FF,4,10.0.0.1:25,10.1.1.60:5000,>,""250 2.6.0 <msg-009@contoso.test> [InternalId=9, Hostname=EXCH01] Queued mail for delivery"",`r`n$now,$c,08DF0000000000FF,5,10.0.0.1:25,10.1.1.60:5000,-,,Local`r`n")
        [void](Invoke-TestCollection $s)
        (Query $s "SELECT status, message_id FROM smtp_transaction WHERE mail_from='eve@contoso.test'")[0] | Should -Be @('Accepted', '<msg-009@contoso.test>')
    }
    It 'identifies a log file whatever the path used to reach it' {
        [ExchangeLogReport.Store]::FileKey('EXCH01', '\\EXCH01\D$\Logs\Hub\RECV1.LOG') | Should -BeExactly 'D:\LOGS\HUB\RECV1.LOG'
        [ExchangeLogReport.Store]::FileKey('EXCH01', '\\exch01.contoso.test\d$\Logs\Hub\recv1.log') | Should -BeExactly 'D:\LOGS\HUB\RECV1.LOG'
        [ExchangeLogReport.Store]::FileKey('EXCH01', 'd:\Logs\Hub\Recv1.log') | Should -BeExactly 'D:\LOGS\HUB\RECV1.LOG'
        # Another server's share or a NAS stays a UNC path.
        [ExchangeLogReport.Store]::FileKey('EXCH01', '\\EXCH02\D$\Logs\Hub\RECV1.LOG') | Should -BeExactly '\\EXCH02\D$\LOGS\HUB\RECV1.LOG'
        [ExchangeLogReport.Store]::FileKey('EXCH01', '\\NAS\Logs\RECV1.LOG') | Should -BeExactly '\\NAS\LOGS\RECV1.LOG'
    }
    It 'does not read a file again when it is reached through another path of the same server' {
        $dir = Join-Path $TestDrive 'rekey'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        $first = Invoke-TestCollection $s
        $first.Lines | Should -BeGreaterThan 0
        # Same folders in another case (as Exchange may return them to -Mode Discover): nothing to read.
        $upper = Import-ExlConfiguration -Path (New-TestConfig (Join-Path $TestDrive 'rekey-upper')) -Root $script:Root
        $upper.Storage.DatabasePath = $s.Storage.DatabasePath
        $upper.Servers[0] = & (Get-Module ExchangeLogReport) { param($src, $x, $i) Resolve-ExlServerPaths -Name 'EXCH01' -Configured @{ ExchangePath = $x.ToUpperInvariant(); IisLogPath = $i.ToUpperInvariant() } -Sources $src } $s.Sources $s.Servers[0].ExchangePath $s.Servers[0].IisLogPath
        (Invoke-TestCollection $upper).Lines | Should -Be 0
        # A 1.5.0 database: the files were read through the administrative share, then once again through the
        # local path after -Mode Discover. Upgraded, the copy read last keeps the identity of the file.
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("DROP INDEX ux_source_file_key; ALTER TABLE source_file DROP COLUMN file_key;")
            $store.Exec("UPDATE source_file SET path = '\\EXCH01\' || substr(path, 1, 1) || '`$' || substr(path, 3), updated_ms = 2000000000000;")
            $store.Exec("INSERT INTO source_file(server, kind, path, offset, size, updated_ms) SELECT server, kind, substr(path, 10, 1) || ':' || substr(path, 12), offset, size, 1 FROM source_file WHERE kind = 'Tracking';")
            Remove-TestServeSchema $store
            $store.Exec("UPDATE metadata SET value = '2' WHERE key = 'schema_version';")
        } finally { $store.Dispose() }
        $again = Invoke-TestCollection $s
        $again.Lines | Should -Be 0
        (Query $s "SELECT COUNT(*) FROM source_file WHERE file_key IS NULL")[0][0] | Should -Be 2
        (Query $s "SELECT COUNT(*) FROM source_file WHERE file_key IS NOT NULL AND path LIKE '\\EXCH01\%'")[0][0] | Should -Be (Query $s "SELECT COUNT(*) FROM source_file WHERE file_key IS NOT NULL")[0][0]
        (Query $s "SELECT value FROM metadata WHERE key = 'schema_version'")[0][0] | Should -Be ([ExchangeLogReport.Store]::SchemaVersion)
    }
}

Describe 'Client sessions and back-end correlation' {
    It 'builds one Outlook MAPI session from the front-end and back-end logs' {
        $row = (Query $script:Settings "SELECT requests, failures, software, client_mode, front_ends, back_ends, backend, actions FROM client_session WHERE user='contoso\dave' AND protocol='Mapi'")
        $row.Count | Should -Be 1
        $row[0][0] | Should -Be 6
        $row[0][1] | Should -Be 0
        $row[0][2] | Should -Be 'OUTLOOK.EXE 16.0.17928.20114'
        $row[0][3] | Should -Be 'Cached'
        $row[0][4] | Should -Be 'EXCH01'
        $row[0][6] | Should -Match '^1\|'
        $row[0][7] | Should -Match 'Execute=3'
        (Query $script:Settings "SELECT COUNT(*) FROM client_session WHERE user LIKE '%health%'")[0][0] | Should -Be 0
    }
    It 'does not count long-polling requests as slow, but keeps slow successes' {
        (Query $script:Settings "SELECT COUNT(*) FROM access_event WHERE user='contoso\dave'")[0][0] | Should -Be 0
        (Query $script:Settings "SELECT outcome, duration_ms FROM access_event WHERE user='contoso\grace'")[0] | Should -Be @('Slow', 8000)
        (Query $script:Settings "SELECT slow FROM access_usage WHERE user='contoso\grace'")[0][0] | Should -Be 1
    }
    It 'attributes a rejected Basic logon to the account (IIS 401.1, Win32 1326)' {
        $e = (Query $script:Settings "SELECT source, status, sub_status, action, error_code FROM access_event WHERE user='contoso\erin' AND status=401")[0]
        @($e[0], $e[1], $e[2], $e[3]) | Should -Be @('IIS', 401, 1, 'FolderSync')
        $e[4] | Should -Match '1326'
    }
    It 'reads the ActiveSync command and device, and the result hidden behind HTTP 200' {
        $s = (Query $script:Settings "SELECT requests, failures, device_id, device_type, software, client_mode, backend, last_error, actions FROM client_session WHERE user='contoso\erin'")
        $s.Count | Should -Be 1
        @($s[0][0], $s[0][1], $s[0][2], $s[0][3]) | Should -Be @(6, 1, 'ERINPHONE1', 'iPhone')
        $s[0][4] | Should -Be 'ActiveSync 14.0'
        $s[0][6] | Should -Match '^1\|'
        $s[0][8] | Should -Match 'FolderSync=3'
        $script:First.NoiseReasons['Back-end traffic other than ActiveSync'] | Should -Be 1
    }
    It 'joins the IMAP back-end commands to the session of the client (front end)' {
        $s = (Query $script:Settings "SELECT requests, failures, connections, client_ip, back_ends, last_error FROM client_session WHERE user='contoso\frank' AND protocol='Imap4'")
        $s.Count | Should -Be 1
        @($s[0][0], $s[0][1], $s[0][2], $s[0][3], $s[0][4]) | Should -Be @(5, 1, 1, '10.1.1.70', 'EXCH01')
        $s[0][5] | Should -Match 'message set is invalid'
        $script:First.NoiseReasons['Imap4 logon failed (the account is not logged)'] | Should -Be 4
        $script:First.NoiseReasons['Imap4 connection without logon'] | Should -Be 2
        (Query $script:Settings "SELECT client_ip FROM access_usage WHERE user='contoso\frank' AND protocol='Imap4'")[0][0] | Should -Be '10.1.1.70'
    }
    It 'stores the authentication type of the clients' {
        $rows = Query $script:Settings "SELECT user, protocol, auth_type, SUM(requests) FROM access_client WHERE user IN ('contoso\dave','contoso\erin','contoso\grace','contoso\frank','contoso\alice','contoso\carol') GROUP BY user, protocol, auth_type ORDER BY user, protocol, auth_type"
        $text = @($rows | ForEach-Object { "$($_[0])|$($_[1])|$($_[2])|$($_[3])" })
        # dave's MAPI session: two client rows, one per type, whose sum is the single row of the previous shape.
        $text | Should -Contain 'contoso\dave|Mapi|Negotiate|3'
        $text | Should -Contain 'contoso\dave|Mapi|OAuth|3'
        (Query $script:Settings "SELECT SUM(requests) FROM access_usage WHERE user='contoso\dave' AND protocol='Mapi'")[0][0] | Should -Be 6
        $text | Should -Contain 'contoso\erin|Eas|Basic|5'
        $text | Should -Contain 'contoso\alice|Oab|NTLM|1'
        @($text | Where-Object { $_ -like 'contoso\grace|Ews|*' }) | Should -Be @('contoso\grace|Ews|OAuth|1')
        # IMAP4 and the logons rejected by IIS have no authentication type.
        $imap = @($text | Where-Object { $_ -like 'contoso\frank|Imap4|*' })
        $imap.Count | Should -Be 1
        $imap[0] | Should -BeLike 'contoso\frank|Imap4||*'
        @($text | Where-Object { $_ -like 'contoso\carol|*' }) | ForEach-Object { $_.Split('|')[2] | Should -BeExactly '' }
        # The raw text of the retained requests is unchanged.
        (Query $script:Settings "SELECT auth_type FROM access_event WHERE user='bob@contoso.test' AND status=503")[0][0] | Should -BeExactly 'Negotiate'
    }
    It 'keeps the authentication types of a session' {
        (Query $script:Settings "SELECT auth_modes FROM client_session WHERE user='contoso\dave' AND protocol='Mapi'")[0][0] | Should -BeExactly 'Negotiate=3;OAuth=3'
        (Query $script:Settings "SELECT auth_modes FROM client_session WHERE user='contoso\erin'")[0][0] | Should -BeExactly 'Basic=5'
        (Query $script:Settings "SELECT auth_modes FROM client_session WHERE user='contoso\frank' AND protocol='Imap4'")[0][0] | Should -BeNullOrEmpty
        (Query $script:Settings "SELECT typeof(auth_modes) FROM client_session WHERE user='contoso\frank' AND protocol='Imap4'")[0][0] | Should -BeExactly 'null'
    }
    It 'adds the authentication types of new requests to a session read back from the database' {
        $dir = Join-Path $TestDrive 'auth-reload'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        [void](Invoke-TestCollection $s)
        (Query $s "SELECT auth_modes FROM client_session WHERE user='contoso\dave' AND protocol='Mapi'")[0][0] | Should -BeExactly 'Negotiate=3;OAuth=3'
        $file = Get-ChildItem $dir -Recurse -Filter 'HttpProxy_2026100108-2.LOG' | Where-Object { $_.Directory.Name -eq 'Mapi' }
        $mbx = '6f1c2a3b-1111-4222-8333-944455566677'; $ci = '{A1B2C3D4-0000-4000-8000-0000000000AA}'
        $lines = foreach ($n in 7, 8) {
            ProxyLine @{ DateTime = (T (13 + $n / 10)); RequestId = [guid]::NewGuid().ToString(); ClientRequestId = "R:{9F00AA11-2222-4333-8444-555566667777}:$n;RT:Execute;CI:$($ci):1;CID:<null>"; Protocol = 'Mapi'
                UrlStem = '/mapi/emsmdb/'; AuthenticationType = 'OAuth'; IsAuthenticated = $true; AuthenticatedUser = 'CONTOSO\dave'; AnchorMailbox = "MailboxGuid~$mbx"
                UserAgent = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928; Pro)'; ClientIpAddress = '10.1.1.40'; ServerHostName = 'EXCH01'; HttpStatus = 200; BackEndStatus = 200; Method = 'POST'
                TargetServer = 'exch01.contoso.test'; RequestBytes = 300; ResponseBytes = 900; TotalRequestTime = 35; UrlQuery = "?MailboxId=$mbx@contoso.test" }
        }
        [IO.File]::AppendAllText($file.FullName, ($lines -join "`r`n") + "`r`n")
        # Sessions already written are read back from the database by the next collection (and evicted from memory between batches).
        [ExchangeLogReport.Collector]::EvictAboveKeys = 1
        try { $next = Invoke-TestCollection $s } finally { [ExchangeLogReport.Collector]::EvictAboveKeys = 20000 }
        $next.Lines | Should -Be 2
        $session = Query $s "SELECT requests, auth_modes FROM client_session WHERE user='contoso\dave' AND protocol='Mapi'"
        @($session).Count | Should -Be 1
        @($session[0][0], $session[0][1]) | Should -Be @(8, 'OAuth=5;Negotiate=3')
        (Query $s "SELECT requests FROM access_client WHERE user='contoso\dave' AND protocol='Mapi' AND auth_type='OAuth'")[0][0] | Should -Be 5
    }
    It 'keeps operations and clients for the usage views' {
        (Query $script:Settings "SELECT SUM(requests) FROM access_action WHERE protocol='Eas' AND action='FolderSync'")[0][0] | Should -Be 3
        # The commands of the device on Basic; the logon IIS rejected before the proxy has no authentication type.
        (Query $script:Settings "SELECT device_type, requests FROM access_client WHERE user='contoso\erin' AND device_id='ERINPHONE1' AND auth_type='Basic'")[0] | Should -Be @('iPhone', 4)
        (Query $script:Settings "SELECT SUM(requests) FROM access_client WHERE user='contoso\erin' AND device_id='ERINPHONE1'")[0][0] | Should -Be 5
    }
    It 'merges two sessions when a request fills the gap between them' {
        $file = Get-ChildItem (Join-Path $script:Dir 'logs-src') -Recurse -Filter 'HttpProxy_2026100108-2.LOG' | Where-Object { $_.Directory.Name -eq 'Ews' }
        $line = { param($min) ProxyLine @{ DateTime = (T $min); RequestId = [guid]::NewGuid().ToString(); Protocol = 'Ews'; UrlStem = '/EWS/Exchange.asmx'; AuthenticationType = 'OAuth'
            IsAuthenticated = $true; AuthenticatedUser = 'CONTOSO\grace'; UserAgent = 'MacOutlook/16.89.24091630'; ClientIpAddress = '10.1.1.80'; ServerHostName = 'EXCH01'
            HttpStatus = 200; BackEndStatus = 200; Method = 'POST'; TargetServer = 'exch01.contoso.test'; TotalRequestTime = 40 } }
        [IO.File]::AppendAllText($file.FullName, (& $line 62) + "`r`n")
        [void](Invoke-TestCollection $script:Settings)
        (Query $script:Settings "SELECT COUNT(*) FROM client_session WHERE user='contoso\grace'")[0][0] | Should -Be 2
        [IO.File]::AppendAllText($file.FullName, (& $line 40) + "`r`n")
        [void](Invoke-TestCollection $script:Settings)
        $s = Query $script:Settings "SELECT id, requests, slow FROM client_session WHERE user='contoso\grace'"
        $s.Count | Should -Be 1
        @($s[0][1], $s[0][2]) | Should -Be @(3, 1)
        (Query $script:Settings "SELECT COUNT(*) FROM session_step WHERE session_id NOT IN (SELECT id FROM client_session)")[0][0] | Should -Be 0
    }
    It 'reads an IMAP connection still open again later, without counting the others twice' {
        $dir = Join-Path $TestDrive 'imap-open'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir @{ 'PopImap         = $false' = 'PopImap         = $true' }) -Root $script:Root
        $file = Get-ChildItem $dir -Recurse -Filter 'IMAP42026100108-1.LOG' | Select-Object -First 1
        $now = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        $ok = '"R=OK;Msg=""Proxy:EXCH01.contoso.test:1993:SSL;ProxySuccess"""'
        [IO.File]::AppendAllText($file.FullName, (@(
            "$now,00000000000000A1,0,10.0.0.1:993,10.1.1.90:51001,,1,0,53,OpenSession,,,"
            "$now,00000000000000A1,1,10.0.0.1:993,10.1.1.90:51001,gina,20,40,24,login,gina@contoso.test *****,$ok,"
            "$now,00000000000000A2,0,10.0.0.1:993,10.1.1.91:51002,,1,0,53,OpenSession,,,"
            "$now,00000000000000A2,1,10.0.0.1:993,10.1.1.91:51002,hank,20,40,24,login,hank@contoso.test *****,$ok,"
            "$now,00000000000000A2,2,10.0.0.1:993,10.1.1.91:51002,hank,0,61,458,CloseSession,,,") -join "`r`n") + "`r`n")
        [void](Invoke-TestCollection $s)
        (Query $s "SELECT COUNT(*) FROM access_usage WHERE user IN ('gina','hank')")[0][0] | Should -Be 0
        [IO.File]::AppendAllText($file.FullName, "$now,00000000000000A1,2,10.0.0.1:993,10.1.1.90:51001,gina,0,61,458,CloseSession,,,`r`n")
        [void](Invoke-TestCollection $s)
        [void](Invoke-TestCollection $s)
        (Query $s "SELECT user, SUM(requests) FROM access_usage WHERE user IN ('gina','hank') GROUP BY user ORDER BY user") | ForEach-Object { "$($_[0])=$($_[1])" } | Should -Be @('gina=1', 'hank=1')
        (Query $s "SELECT SUM(connections) FROM client_session WHERE user IN ('gina','hank')")[0][0] | Should -Be 2
    }
    It 'opens a database of the previous version for a report without collection' {
        $dir = Join-Path $TestDrive 'upgrade'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        [void](Invoke-TestCollection $s)
        $store = Open-ExlStore -Settings $s
        try {
            Remove-TestServeSchema $store
            $store.Exec("DROP TABLE access_client; DROP TABLE client_session; DROP TABLE session_step; DROP TABLE access_action; UPDATE metadata SET value='1' WHERE key='schema_version';")
        } finally { $store.Dispose() }
        $store = Open-ExlStore -Settings $s -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $s -Period ([pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }) -ReportType Detailed } finally { $store.Dispose() }
        $r.Counts['servers'] | Should -Be 2
        (Query $s "SELECT value FROM metadata WHERE key='schema_version'")[0][0] | Should -Be ([ExchangeLogReport.Store]::SchemaVersion)
    }
    It 'extends the same session at the next collection instead of creating a new one' {
        $file = Get-ChildItem (Join-Path $script:Dir 'logs-src') -Recurse -Filter 'HttpProxy_*.LOG' | Where-Object { $_.Directory.Name -eq 'Eas' }
        $line = ProxyLine @{ DateTime = (T 25); RequestId = [guid]::NewGuid(); Protocol = 'Eas'; UrlStem = '/Microsoft-Server-ActiveSync/default.eas'; AuthenticatedUser = 'CONTOSO\erin'
            UserAgent = 'Apple-iPhone15C2/2107.102'; ClientIpAddress = '10.1.1.61'; HttpStatus = 200; Method = 'POST'; TotalRequestTime = 50; UrlQuery = '?Cmd=Ping&User=erin&DeviceId=ERINPHONE1&DeviceType=iPhone' }
        [IO.File]::AppendAllText($file.FullName, $line + "`r`n")
        [void](Invoke-TestCollection $script:Settings)
        $s = Query $script:Settings "SELECT requests, client_ip FROM client_session WHERE user='contoso\erin'"
        $s.Count | Should -Be 1
        $s[0][0] | Should -Be 7
        $s[0][1] | Should -Be '10.1.1.60,10.1.1.61'
        (Query $script:Settings "SELECT COUNT(*) FROM session_step WHERE session_id IN (SELECT id FROM client_session WHERE user='contoso\erin')")[0][0] | Should -BeGreaterThan 1
    }
    It 'treats an account without name ("DOMAIN\") as anonymous and reads URL parameters' {
        [ExchangeLogReport.Identity]::User('CONTOSO\') | Should -BeNullOrEmpty
        [ExchangeLogReport.Identity]::User('CONTOSO\Alice.Smith') | Should -Be 'contoso\alice.smith'
        [ExchangeLogReport.Identity]::QueryValue('?Cmd=Sync&User=erin&DeviceId=A%2DB&Log=x', 'DeviceId') | Should -Be 'A-B'
        [ExchangeLogReport.Identity]::Token('R:{1}:2;RT:Execute;CI:{2}:1;CID:<null>', 'RT') | Should -Be 'Execute'
    }
}

Describe 'Security identifiers of token requests' {
    # Exchange logs the user of a token (OAuth) request as the SID of the account. hank signs in with Basic on ActiveSync (his own mailbox is the
    # anchor Sid~...-1110), then uses a token on ActiveSync and on EWS against a shared mailbox; ghost (9999) only ever uses a token; ivan's Outlook
    # uses a token on MAPI, and the MAPI back end names him on two days. Every case runs from log files: no directory is queried.
    BeforeAll {
        $script:SidHank = 'S-1-5-21-1-2-3-1110'; $script:SidGhost = 'S-1-5-21-1-2-3-9999'; $script:SidIvan = 'S-1-5-21-1-2-3-1140'
        $script:SidMbx = '7a2b3c4d-1111-4222-8333-944455566688'; $script:SidCi = '{B1B2C3D4-0000-4000-8000-0000000000BB}'
        $script:SidMbx2 = '7a2b3c4d-1111-4222-8333-944455566699'; $script:SidCi2 = '{B1B2C3D4-0000-4000-8000-0000000000CC}'
        $script:SidBeFields = 'DateTime,RequestId,MapiRequestId,ClientRequestId,RequestType,HttpStatusCode,ResponseCode,StatusCode,ReturnCode,TotalRequestLatency,DeploymentRing,MajorVersion,MinorVersion,BuildVersion,RevisionVersion,AuthenticatedUserEmail,UPN,Puid,TenantGuid,MailboxId,MDBGuid,ActAsUserEmail,ClientIP,SourceCafeServer,EdgeInfo,NetworkDeviceInfo,SessionCookie,SequenceCookie,MapiClientInfo,ClientSoftware,ClientSoftwareVersion,ClientMode,AuthenticationType,AuthModuleLatency,LiveIdBasicLog,LiveIdBasicError,LiveIdNegotiateError,OAuthLatency,OAuthError,OAuthErrorCategory,OAuthExtraInfo,AuthenticatedUser,RopIds,OperationSpecific,GenericInfo,GenericErrors'
        function SidLine([double]$Min, [string]$Proto, [string]$User, [string]$Auth, [string]$Anchor, [string]$Stem, [string]$Query = '', [string]$Agent = 'Android-SAMSUNG-SM-S911B/101.10000',
            [string]$Ip = '10.1.2.10', [string]$ClientReq = '') {
            ProxyLine @{ DateTime = (T $Min); RequestId = [guid]::NewGuid().ToString(); MajorVersion = 15; MinorVersion = 2; Protocol = $Proto; UrlHost = 'mail.contoso.test'; UrlStem = $Stem
                AuthenticationType = $Auth; IsAuthenticated = $true; AuthenticatedUser = $User; AnchorMailbox = $Anchor; UserAgent = $Agent; ClientIpAddress = $Ip
                ServerHostName = 'EXCH01'; HttpStatus = 200; BackEndStatus = 200; Method = 'POST'; TargetServer = 'exch01.contoso.test'; RoutingType = 'IntraForest'
                RequestBytes = 300; ResponseBytes = 900; TotalRequestTime = 30; UrlQuery = $Query; ClientRequestId = $ClientReq }
        }
        $script:HankQuery = '?Cmd=Sync&User=hank@contoso.test&DeviceId=HANKPHONE1&DeviceType=Android'
        $script:EasStem = '/Microsoft-Server-ActiveSync/default.eas'
        # One Outlook (client instance $Ci, mailbox $Mbx): a Negotiate line under $Name, then token lines under $Sid, at the minutes $Minutes; the MAPI
        # back end logs the same requests with the UPN $Upn. Returns the HttpProxy lines; writes the back-end file $BackEnd.
        function Write-SidMapi([string]$Exchange, [string]$BackEnd, [string]$Name, [string]$Sid, [string]$Upn, [string]$Mbx, [string]$Ci, [string]$Ip, [double[]]$Minutes) {
            $outlook = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928; Pro)'
            $req = { param($n, $rt) "R:{9F00AA11-2222-4333-8444-555566667788}:$n;RT:$rt;CI:$($Ci):1;CID:<null>" }
            $front = [Collections.Generic.List[string]]::new(); $back = [Collections.Generic.List[string]]::new()
            $n = 0
            foreach ($m in $Minutes) {
                $n++
                $front.Add((SidLine ($m - 1) 'Mapi' $Name 'Negotiate' "MailboxGuid~$Mbx" '/mapi/emsmdb/' "?MailboxId=$Mbx@contoso.test" $outlook $Ip (& $req ($n * 10) 'Connect')))
                $front.Add((SidLine $m 'Mapi' $Sid 'Bearer' "MailboxGuid~$Mbx" '/mapi/emsmdb/' "?MailboxId=$Mbx@contoso.test" $outlook $Ip (& $req ($n * 10 + 1) 'Execute')))
                $front.Add((SidLine ($m + 0.5) 'Mapi' $Sid 'Bearer' "MailboxGuid~$Mbx" '/mapi/emsmdb/' "?MailboxId=$Mbx@contoso.test" $outlook $Ip (& $req ($n * 10 + 2) 'Execute')))
                foreach ($t in $m, ($m + 0.5)) {
                    $v = @{ DateTime = (T $t); RequestId = [guid]::NewGuid().ToString(); RequestType = 'Execute'; HttpStatusCode = 200; ResponseCode = 0; StatusCode = 0; ReturnCode = 0; TotalRequestLatency = 20
                        AuthenticatedUserEmail = $Upn; UPN = $Upn; MailboxId = "$Mbx@contoso.test"; ClientIP = $Ip; SourceCafeServer = 'EXCH01.CONTOSO.TEST'
                        MapiClientInfo = "$($Ci):1"; ClientSoftware = 'OUTLOOK.EXE'; ClientSoftwareVersion = '16.0.17928.20114'; ClientMode = 'Cached'; AuthenticatedUser = 'Anonymous' }
                    $back.Add((($script:SidBeFields.Split(',') | ForEach-Object { [string]$v[$_] }) -join ','))
                }
            }
            Write-Log (Join-Path $Exchange "Logging\MapiHttp\Mailbox\$BackEnd") (@("#Fields: $($script:SidBeFields)") + $back)
            return $front.ToArray()
        }
        # Parts: EwsBearer (oldest file, applied first), EasBearer, EasBasic (the evidence), Ghost, Ivan (MAPI back end on two days), IvanOneDay,
        # JaneFile (a second account with hank's anchor, in a file of its own), EasBearer2 and EasBearer3 (later token requests of hank), OwaUpn (hank's
        # OWA line under his UPN), HankMapiJane (hank's SID on MAPI, the back end naming jane), EasDevice (the ActiveSync back end logs nina with
        # Basic on hank's device). $Age: minutes x 10 before now of the last write of a file (the order in which they are read).
        function Write-SidLogs([string]$Exchange, [string[]]$Parts, [hashtable]$Age = @{}) {
            $proxy = Join-Path $Exchange 'Logging\HttpProxy'
            $files = [ordered]@{}
            if ('EwsBearer' -in $Parts) {
                $files['Ews\HttpProxy_2026100109-1.LOG'] = @(
                    (SidLine 34 'Ews' $script:SidHank 'Bearer' 'SMTP:shared@contoso.test' '/EWS/Exchange.asmx' -Agent 'CapybaMail/1.0' -Ip '10.1.2.11')
                    (SidLine 35 'Ews' $script:SidHank 'Bearer' 'SMTP:shared@contoso.test' '/EWS/Exchange.asmx' -Agent 'CapybaMail/1.0' -Ip '10.1.2.11')
                    # The UPN form of hank, logged before any line names CONTOSO\hank.
                    (SidLine 36 'Ews' 'hank@contoso.test' 'Negotiate' 'SMTP:hank@contoso.test' '/EWS/Exchange.asmx' -Agent 'MacOutlook/16.89' -Ip '10.1.2.12'))
            }
            if ('EasBearer' -in $Parts) {
                $files['Eas\HttpProxy_2026100109-1.LOG'] = @(
                    (SidLine 32 'Eas' $script:SidHank 'Bearer' "OAuthActAsUser:$($script:SidHank)" $script:EasStem $script:HankQuery)
                    (SidLine 33 'Eas' $script:SidHank 'Bearer' "OAuthActAsUser:$($script:SidHank)" $script:EasStem $script:HankQuery))
            }
            if ('EasBasic' -in $Parts) {
                $files['Eas\HttpProxy_2026100109-2.LOG'] = @(
                    (SidLine 30 'Eas' 'CONTOSO\hank' 'Basic' "Sid~$($script:SidHank)" $script:EasStem $script:HankQuery)
                    (SidLine 30.5 'Eas' 'CONTOSO\hank' 'Basic' "Sid~$($script:SidHank)" $script:EasStem $script:HankQuery)
                    (SidLine 31 'Eas' 'CONTOSO\hank' 'Basic' "Sid~$($script:SidHank)" $script:EasStem $script:HankQuery))
            }
            if ('Ghost' -in $Parts) {
                $q = '?Cmd=Sync&User=ghost@contoso.test&DeviceId=GHOST1&DeviceType=iPhone'
                $files['Eas\HttpProxy_2026100109-3.LOG'] = @(
                    (SidLine 40 'Eas' $script:SidGhost 'Bearer' "OAuthActAsUser:$($script:SidGhost)" $script:EasStem $q -Agent 'Apple-iPhone16C1/2201.1' -Ip '10.1.2.20')
                    (SidLine 41 'Eas' $script:SidGhost 'Bearer' "OAuthActAsUser:$($script:SidGhost)" $script:EasStem $q -Agent 'Apple-iPhone16C1/2201.1' -Ip '10.1.2.20'))
            }
            if ('JaneFile' -in $Parts) {
                $files['Eas\HttpProxy_2026100109-4.LOG'] = @(
                    (SidLine 37 'Eas' 'CONTOSO\jane' 'Basic' "Sid~$($script:SidHank)" $script:EasStem '?Cmd=Sync&User=jane&DeviceId=JANE1&DeviceType=iPhone' -Agent 'Apple-iPhone15C2/2107.102' -Ip '10.1.2.30'))
            }
            if ('EasBearer2' -in $Parts) {
                $files['Eas\HttpProxy_2026100109-5.LOG'] = @(
                    (SidLine 50 'Eas' $script:SidHank 'Bearer' "OAuthActAsUser:$($script:SidHank)" $script:EasStem $script:HankQuery)
                    (SidLine 51 'Eas' $script:SidHank 'Bearer' "OAuthActAsUser:$($script:SidHank)" $script:EasStem $script:HankQuery))
            }
            if ('EasBearer3' -in $Parts) {
                $files['Eas\HttpProxy_2026100109-6.LOG'] = @(
                    (SidLine 55 'Eas' $script:SidHank 'Bearer' "OAuthActAsUser:$($script:SidHank)" $script:EasStem $script:HankQuery)
                    (SidLine 56 'Eas' $script:SidHank 'Bearer' "OAuthActAsUser:$($script:SidHank)" $script:EasStem $script:HankQuery))
            }
            if ('OwaUpn' -in $Parts) {
                $files['Owa\HttpProxy_2026100109-1.LOG'] = @(
                    (SidLine 29 'Owa' 'hank@contoso.test' 'Fba' "Sid~$($script:SidHank)" '/owa/service.svc' '?action=GetFolder' -Agent 'Mozilla/5.0 (Windows NT 10.0)' -Ip '10.1.2.13'))
            }
            if ('Ivan' -in $Parts) {
                # The day before and today: the back end names ivan on two days.
                $files['Mapi\HttpProxy_2026100109-1.LOG'] = Write-SidMapi $Exchange 'MapiHttp_2026100109-1.LOG' 'CONTOSO\ivan' $script:SidIvan 'ivan@contoso.test' $script:SidMbx $script:SidCi '10.1.2.40' @(-1395, 45)
            }
            if ('IvanOneDay' -in $Parts) {
                $files['Mapi\HttpProxy_2026100109-1.LOG'] = Write-SidMapi $Exchange 'MapiHttp_2026100109-1.LOG' 'CONTOSO\ivan' $script:SidIvan 'ivan@contoso.test' $script:SidMbx $script:SidCi '10.1.2.40' @(45)
            }
            if ('HankMapiJane' -in $Parts) {
                $files['Mapi\HttpProxy_2026100109-2.LOG'] = Write-SidMapi $Exchange 'MapiHttp_2026100109-2.LOG' 'CONTOSO\hank' $script:SidHank 'jane@contoso.test' $script:SidMbx2 $script:SidCi2 '10.1.2.41' @(-1390, 47)
            }
            if ('EasDevice' -in $Parts) {
                $iis = Join-Path (Split-Path $Exchange -Parent) 'inetpub'
                $fields = '#Fields: date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip cs(User-Agent) cs(Referer) sc-status sc-substatus sc-win32-status sc-bytes cs-bytes time-taken'
                $nina = 'Cmd=Sync&User=nina&DeviceId=HANKPHONE1&DeviceType=Android&Log=SC1:1_PrxFrom:10.0.0.1_Ver1:161_As:AllowedG'
                Write-Log (Join-Path $iis 'W3SVC2\u_ex261002.log') @('#Software: Microsoft Internet Information Services 10.0', '#Version: 1.0', "#Date: $(T 0 -W3C)", $fields
                    "$(T -1380 -W3C) 10.0.0.1 POST /Microsoft-Server-ActiveSync/Proxy/default.eas $nina 444 CONTOSO\nina 10.0.0.1 Android-SAMSUNG-SM-S911B/101.10000 - 200 0 0 300 400 60"
                    "$(T 38 -W3C) 10.0.0.1 POST /Microsoft-Server-ActiveSync/Proxy/default.eas $nina 444 CONTOSO\nina 10.0.0.1 Android-SAMSUNG-SM-S911B/101.10000 - 200 0 0 300 400 60")
            }
            # The files are read in the order of their last write: the EWS token file first, the evidence last.
            $ages = @{ 'Ews\HttpProxy_2026100109-1.LOG' = 4; 'Eas\HttpProxy_2026100109-1.LOG' = 3; 'Mapi\HttpProxy_2026100109-1.LOG' = 3; 'Mapi\HttpProxy_2026100109-2.LOG' = 3
                'Eas\HttpProxy_2026100109-3.LOG' = 3; 'Owa\HttpProxy_2026100109-1.LOG' = 3; 'Eas\HttpProxy_2026100109-4.LOG' = 2; 'Eas\HttpProxy_2026100109-2.LOG' = 1
                'Eas\HttpProxy_2026100109-5.LOG' = 1; 'Eas\HttpProxy_2026100109-6.LOG' = 1 }
            foreach ($k in $Age.Keys) { $ages[$k] = $Age[$k] }
            foreach ($k in $files.Keys) {
                $path = Join-Path $proxy $k
                Write-Log $path (@("#Fields: $script:ProxyFields") + $files[$k])
                [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddMinutes(-10 * $ages[$k]))
            }
        }
        function New-SidSettings([string]$Name, [string[]]$Parts, [hashtable]$Replace = @{}, [hashtable]$Age = @{}) {
            $dir = Join-Path $TestDrive "sid-$Name"
            [void][IO.Directory]::CreateDirectory($dir)
            $path = New-TestConfig $dir $Replace
            Write-SidLogs (Join-Path $dir 'logs-src\EXCH01\Exchange') $Parts $Age
            return Import-ExlConfiguration -Path $path -Root $script:Root
        }
        function Add-SidLogs([string]$Name, [string[]]$Parts) { Write-SidLogs (Join-Path $TestDrive "sid-$Name\logs-src\EXCH01\Exchange") $Parts }
        # The collection log of the module (Write-ExlLog) into a string, for one collection.
        function Invoke-SidCollection($Settings) {
            $log = [IO.StringWriter]::new()
            $saved = & (Get-Module ExchangeLogReport) { $s = $script:LogWriter; $script:LogWriter = $args[0]; $s } $log
            try { [void](Invoke-TestCollection $Settings) } finally { & (Get-Module ExchangeLogReport) { $script:LogWriter = $args[0] } $saved }
            return $log.ToString()
        }
        function Get-SidStatus($Settings) {
            & (Get-Module ExchangeLogReport) { param($se) $store = Open-ExlStore -Settings $se -ReadOnly; try { Show-ExlStatus -Store $store -Settings $se } finally { $store.Dispose() } } $Settings 6>&1 | Out-String
        }
        # Every row of a query as one array each.
        function SidRows($Settings, [string]$Sql) { foreach ($r in (Query $Settings $Sql)) { , $r } }
        function Ids($Settings) { SidRows $Settings "SELECT sid, user, status, names, hints, lines, applied_ms FROM identity_map ORDER BY sid" }
        function Id($Settings, [string]$Sid) { Ids $Settings | Where-Object { $_[0] -eq $Sid.ToLowerInvariant() } }
        function Count1($Settings, [string]$Sql) { [long](Query $Settings $Sql)[0][0] }
        function Meta($Settings, [string]$Key) { (Query $Settings "SELECT COUNT(*) FROM metadata WHERE key='$Key'")[0][0] }
        $script:SidAll = New-SidSettings 'all' 'EwsBearer', 'EasBearer', 'EasBasic', 'Ghost', 'Ivan'
        $script:SidAllLog = Invoke-SidCollection $script:SidAll
    }

    It 'resolves a SID from the anchor of the account''s own lines, also for the rows written before the evidence' {
        $sid = $script:SidHank.ToLowerInvariant()
        foreach ($table in 'access_usage', 'access_client', 'client_session', 'access_event') { Count1 $script:SidAll "SELECT COUNT(*) FROM $table WHERE user='$sid'" | Should -Be 0 -Because $table }
        $row = Id $script:SidAll $sid
        $row[1] | Should -Be 'contoso\hank'
        $row[2] | Should -Be 'resolved'
        $row[3] | Should -Match '^anchor:contoso\\hank=3(;|$)'
        $row[4] | Should -Be 'hank@contoso.test=2'
        $row[5] | Should -Be 4
        $row[6] | Should -Not -BeNullOrEmpty
        # Every line of hank, whatever the form it was logged in: 3 Basic, 2 ActiveSync and 2 EWS token requests, 1 EWS request under the UPN.
        Count1 $script:SidAll "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 8
        Count1 $script:SidAll "SELECT COUNT(*) FROM access_usage WHERE user='hank@contoso.test'" | Should -Be 0
        $modes = (Query $script:SidAll "SELECT group_concat(DISTINCT auth_type) FROM access_client WHERE user='contoso\hank' AND protocol='Eas'")[0][0]
        @($modes.Split(',') | Sort-Object) -join ',' | Should -Be 'Basic,Bearer'
        $ews = @(SidRows $script:SidAll "SELECT mailbox, auth_modes FROM client_session WHERE user='contoso\hank' AND protocol='Ews' AND mailbox='shared@contoso.test'")
        $ews.Count | Should -Be 1
        [ExchangeLogReport.Packed]::Text($ews[0][1]) | Should -Be 'Bearer=2'
        # The Basic and token requests of the device are one ActiveSync session.
        Count1 $script:SidAll "SELECT COUNT(*) FROM client_session WHERE user='contoso\hank' AND protocol='Eas'" | Should -Be 1
        Count1 $script:SidAll "SELECT requests FROM client_session WHERE user='contoso\hank' AND protocol='Eas'" | Should -Be 5
        $script:SidAllLog | Should -Match 'Identities: \d+ SID\(s\) resolved \([^)]*s-1-5-21-1-2-3-1110 -> contoso\\hank, anchor'
        # A database collected with evidence from its first collection has nothing to read again.
        Meta $script:SidAll 'identity_evidence_scan' | Should -Be 1
        $script:SidAllLog | Should -Not -Match 'evidence read again'
    }

    It 'pairs a SID named before any token request without renaming anything, and writes its later requests under the account' {
        # erin's ActiveSync lines (the common fixture) and hank's carry their own SID as anchor; no token request yet.
        $s = New-SidSettings 'paired' 'EasBasic'
        $log = Invoke-SidCollection $s
        $row = Id $s $script:SidHank
        $row[2] | Should -Be 'resolved'
        $row[5] | Should -Be 0
        $row[6] | Should -Not -BeNullOrEmpty
        $log | Should -Not -Match 'Identities: \d+ SID\(s\) resolved'
        Get-SidStatus $s | Should -Match 'Security identifiers .*: 0 resolved, 2 paired in advance, 0 unresolved, 0 ambiguous'
        # The Identifiers row of the user says so, as -Mode Status does.
        $identifiers = [Collections.Generic.Dictionary[string, Collections.Generic.List[object[]]]]::new()
        $stored = @(SidRows $s "SELECT sid,user,status,names,hints,lines,first_ms,last_ms FROM identity_map WHERE sid='$($script:SidHank.ToLowerInvariant())'")[0]
        [ExchangeLogReport.ReportBuilder].GetMethod('AddIdentity', [Reflection.BindingFlags]'Static,NonPublic').Invoke($null, @($identifiers, [object[]]$stored, [Func[long, object]] { param($x) $x }))
        $identifiers['contoso\hank'][0][1] | Should -Be 'resolved (paired in advance)'
        Add-SidLogs 'paired' 'EasBearer'
        $log = Invoke-SidCollection $s
        Count1 $s "SELECT COUNT(*) FROM access_usage WHERE user='$($script:SidHank.ToLowerInvariant())'" | Should -Be 0
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 5
        $log | Should -Not -Match 'rows renamed'
        (Id $s $script:SidHank)[5] | Should -Be 2
        Get-SidStatus $s | Should -Match 'Security identifiers .*: 1 resolved \(anchor 1\), 1 paired in advance, 0 unresolved, 0 ambiguous'
    }

    It 'resolves a SID from the MAPI back end of the same Outlook instance once the back end names it on two days' {
        $row = Id $script:SidAll $script:SidIvan
        $row[1] | Should -Be 'contoso\ivan'
        $row[2] | Should -Be 'resolved'
        $row[3] | Should -Match '^mapi-backend:ivan@contoso\.test=4;days:mapi-backend=\d+-\d+$'
        $mapi = @(SidRows $script:SidAll "SELECT requests, auth_modes FROM client_session WHERE user='contoso\ivan' AND protocol='Mapi' ORDER BY start_ms")
        $mapi.Count | Should -Be 2
        foreach ($m in $mapi) {
            $m[0] | Should -Be 3
            [ExchangeLogReport.Packed]::Text($m[1]) | Should -Match '(^|;)Negotiate=1(;|$)'
            [ExchangeLogReport.Packed]::Text($m[1]) | Should -Match '(^|;)Bearer=2(;|$)'
        }
        Count1 $script:SidAll "SELECT SUM(requests) FROM access_usage WHERE user='contoso\ivan'" | Should -Be 6
        Count1 $script:SidAll "SELECT COUNT(*) FROM access_usage WHERE user='$($script:SidIvan.ToLowerInvariant())'" | Should -Be 0
    }

    It 'waits for a second day before merging a SID the MAPI back end alone names' {
        $s = New-SidSettings 'mapi-one-day' 'IvanOneDay'
        [void](Invoke-SidCollection $s)
        $sid = $script:SidIvan.ToLowerInvariant()
        $row = Id $s $sid
        $row[2] | Should -Be 'unresolved'
        [string]$row[1] | Should -BeNullOrEmpty
        $row[3] | Should -Match '^mapi-backend:ivan@contoso\.test=2;days:mapi-backend='
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2
        Get-SidStatus $s | Should -Match ([regex]::Escape("${sid}: unresolved, the MAPI back end names ivan@contoso.test on one day only (two days are needed), 2 requests"))
    }

    It 'keeps the account the ActiveSync back end logs for a device as a hint, never as evidence' {
        # hank's phone under his SID (token) and nina's Basic requests on the same device id: the back end names nina, not the SID's owner.
        $s = New-SidSettings 'eas-device' 'EasBearer', 'EasDevice'
        [void](Invoke-SidCollection $s)
        $sid = $script:SidHank.ToLowerInvariant()
        $row = Id $s $sid
        $row[2] | Should -Be 'unresolved'
        [string]$row[3] | Should -BeNullOrEmpty
        $row[4] | Should -Match '(^|;)eas-backend:contoso\\nina=2(;|$)'
        $row[4] | Should -Match '(^|;)hank@contoso\.test=2(;|$)'
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2
        Count1 $s "SELECT COUNT(*) FROM access_usage WHERE user='contoso\nina'" | Should -Be 0
        Get-SidStatus $s | Should -Match ([regex]::Escape("${sid}: unresolved, 2 requests, hints "))
    }

    It 'keeps a SID without evidence as it is, with the account its device reported' {
        $sid = $script:SidGhost.ToLowerInvariant()
        Count1 $script:SidAll "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2
        $row = Id $script:SidAll $sid
        $row[2] | Should -Be 'unresolved'
        [string]$row[1] | Should -BeNullOrEmpty
        $row[4] | Should -Be 'ghost@contoso.test=2'
        $period = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $store = Open-ExlStore -Settings $script:SidAll -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:SidAll -Period $period -ReportType Usage } finally { $store.Dispose() }
        $html = Read-TestHtml $r.HtmlPath
        $columns = @($html.Meta.datasets.users.columns)
        $at = [array]::IndexOf(@($columns.name), 'Identifiers')
        $at | Should -Be 16
        $columns[$at].grid | Should -BeFalse
        @($html.Meta.datasets.users.detailColumns) -join ',' | Should -Be '13,14,16'
        $ghost = $html.Sets.users | Where-Object { $_[0] -eq $sid }
        @($ghost[16]).Count | Should -Be 1
        $ghost[16][0][0] | Should -Be $sid
        $ghost[16][0][1] | Should -Be 'unresolved'
        $ghost[16][0][3] | Should -Be 'ghost@contoso.test=2'
        $hank = $html.Sets.users | Where-Object { $_[0] -eq 'contoso\hank' }
        $hank[16][0][0] | Should -Be $script:SidHank.ToLowerInvariant()
        $hank[15] | Should -Be 'OAuth, Negotiate, Basic'
        $ivan = $html.Sets.users | Where-Object { $_[0] -eq 'contoso\ivan' }
        $ivan[16][0][2] | Should -Be 'mapi-backend:ivan@contoso.test=4'
        $csv = Get-Content -LiteralPath (Join-Path $r.Folder 'ExchangeLogs-Users.csv') -TotalCount 1
        $csv.Split(';').Count | Should -Be 14
        $csv | Should -Not -Match 'Identifiers'
    }

    It 'names a SID from the mapping file, and ignores an entry the logs contradict' {
        $dir = Join-Path $TestDrive 'sid-map-file'
        [void][IO.Directory]::CreateDirectory($dir)
        $map = Join-Path $dir 'identities.psd1'
        Set-Content -LiteralPath $map -Value "@{ '$($script:SidGhost)' = 'CONTOSO\ghost'; '$($script:SidHank)' = 'CONTOSO\other' }"
        $s = New-SidSettings 'map' 'EwsBearer', 'EasBearer', 'EasBasic', 'Ghost' @{ "IdentityMapFile        = ''" = "IdentityMapFile        = '$map'" }
        $log = Invoke-SidCollection $s
        Count1 $s "SELECT COUNT(*) FROM access_usage WHERE user='$($script:SidGhost.ToLowerInvariant())'" | Should -Be 0
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\ghost'" | Should -Be 2
        (Id $s $script:SidGhost)[3] | Should -Be 'file:contoso\ghost=1'
        $hank = Id $s $script:SidHank
        $hank[1] | Should -Be 'contoso\hank'
        $hank[3] | Should -Match ';file:contoso\\other=1$'
        $log | Should -Match ([regex]::Escape("Mapping file entry for $($script:SidHank.ToLowerInvariant()) ignored: the logs name contoso\hank."))
        $status = Get-SidStatus $s
        $status | Should -Match 'Security identifiers .*: 2 resolved \(anchor 1, file 1\), 1 paired in advance, 0 unresolved, 0 ambiguous'
        $status | Should -Match ([regex]::Escape("Mapping file entry for $($script:SidHank.ToLowerInvariant()) ignored: the logs name contoso\hank."))
        Set-Content -LiteralPath $map -Value "@{ 'not-a-sid' = 'CONTOSO\x' }"
        { Import-ExlConfiguration -Path $s.ConfigPath -Root $script:Root } | Should -Throw "*IdentityMapFile*'not-a-sid' is not a security identifier*"
        Set-Content -LiteralPath $map -Value "@{ '$($script:SidGhost)' = 'CONTOSO|x' }"
        { Import-ExlConfiguration -Path $s.ConfigPath -Root $script:Root } | Should -Throw "*IdentityMapFile*'$($script:SidGhost)'*account name*"
    }

    It 'leaves a SID unresolved when a later file names a second account for its anchor, whatever the order and the number of threads' {
        # The order that would merge on the first evidence: hank's anchor file first, then the token requests, jane's line last.
        $age = @{ 'Eas\HttpProxy_2026100109-2.LOG' = 5 }
        $sid = $script:SidHank.ToLowerInvariant()
        $results = foreach ($threads in '1', '0') {
            $s = New-SidSettings "ambiguous-$threads" 'EasBearer', 'EasBasic', 'JaneFile' @{ 'Parallelism            = 0' = "Parallelism            = $threads" } $age
            [void](Invoke-SidCollection $s)
            $row = Id $s $sid
            $row[2] | Should -Be 'ambiguous' -Because "Parallelism $threads"
            $row[3] | Should -Match 'anchor:contoso\\hank=3'
            $row[3] | Should -Match 'anchor:contoso\\jane=1'
            [string]$row[1] | Should -BeNullOrEmpty
            Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2 -Because "Parallelism $threads"
            Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 3 -Because "Parallelism $threads"
            (@(SidRows $s "SELECT user||'|'||protocol||'|'||SUM(requests) FROM access_usage GROUP BY user, protocol ORDER BY 1" | ForEach-Object { $_[0] }) -join "`n")
        }
        $results[0] | Should -BeExactly $results[1]
        $status = Get-SidStatus $s
        $status | Should -Match ([regex]::Escape("${sid}: ambiguous, the logs name contoso\hank, contoso\jane, 2 requests"))
    }

    It 'leaves a SID unresolved when two kinds of evidence name two accounts' {
        $s = New-SidSettings 'cross-kind' 'EasBasic', 'HankMapiJane'
        [void](Invoke-SidCollection $s)
        $sid = $script:SidHank.ToLowerInvariant()
        $row = Id $s $sid
        $row[2] | Should -Be 'ambiguous'
        $row[3] | Should -Match '(^|;)anchor:contoso\\hank=3(;|$)'
        $row[3] | Should -Match '(^|;)mapi-backend:jane@contoso\.test=4(;|$)'
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 4
    }

    It 'keeps the rows merged when a later collection makes the SID ambiguous, and says with which account' {
        $s = New-SidSettings 'unmerged' 'EasBearer', 'EasBasic'
        [void](Invoke-SidCollection $s)
        $sid = $script:SidHank.ToLowerInvariant()
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 5
        # Jane's line arrives with hank's next token requests: the requests of that collection are written under the account resolved when it started.
        Add-SidLogs 'unmerged' 'JaneFile', 'EasBearer2'
        $log = Invoke-SidCollection $s
        $row = Id $s $sid
        $row[2] | Should -Be 'ambiguous'
        $row[1] | Should -Be 'contoso\hank'
        $row[6] | Should -Not -BeNullOrEmpty
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 7
        $log | Should -Match ([regex]::Escape("Identities: $sid is ambiguous (the logs name contoso\hank, contoso\jane); its rows of earlier collections stay merged with contoso\hank"))
        Get-SidStatus $s | Should -Match ([regex]::Escape("${sid}: ambiguous, the logs name contoso\hank, contoso\jane, rows of earlier collections merged with contoso\hank, ") + '.*check the requests of contoso\\hank')
        # The next collection writes the new token requests under the SID.
        Add-SidLogs 'unmerged' 'EasBearer3'
        $log = Invoke-SidCollection $s
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 7
        $log | Should -Not -Match 'is ambiguous \(the logs name'
        $period = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $store = Open-ExlStore -Settings $s -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $s -Period $period -ReportType Usage } finally { $store.Dispose() }
        $hank = (Read-TestHtml $r.HtmlPath).Sets.users | Where-Object { $_[0] -eq 'contoso\hank' }
        $hank[16][0][1] | Should -Be 'ambiguous, merged with contoso\hank'
    }

    It 'moves the rows to the "domain\sam" form when a SID resolved to a UPN is later named by that form' {
        $s = New-SidSettings 'upn' 'OwaUpn', 'EasBearer'
        [void](Invoke-SidCollection $s)
        $sid = $script:SidHank.ToLowerInvariant()
        (Id $s $sid)[1] | Should -Be 'hank@contoso.test'
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='hank@contoso.test'" | Should -Be 3
        Add-SidLogs 'upn' 'EasBasic'
        $log = Invoke-SidCollection $s
        $row = Id $s $sid
        $row[1] | Should -Be 'contoso\hank'
        $row[2] | Should -Be 'resolved'
        foreach ($table in 'access_usage', 'access_client', 'client_session') { Count1 $s "SELECT COUNT(*) FROM $table WHERE user='hank@contoso.test' OR user='$sid'" | Should -Be 0 -Because $table }
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 6
        $log | Should -Match ([regex]::Escape("$sid -> contoso\hank, anchor"))
    }

    It 'leaves a SID whose rows cannot be renamed for the next collection, and still writes the other identities' {
        $dir = Join-Path $TestDrive 'sid-map-rollback'
        [void][IO.Directory]::CreateDirectory($dir)
        $map = Join-Path $dir 'identities.psd1'
        Set-Content -LiteralPath $map -Value "@{ '$($script:SidGhost)' = 'CONTOSO\ghost' }"
        $s = New-SidSettings 'rollback' 'EasBearer', 'EasBasic', 'Ghost' @{ "IdentityMapFile        = ''" = "IdentityMapFile        = '$map'" }
        $sid = $script:SidHank.ToLowerInvariant()
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("CREATE TRIGGER test_block_rename BEFORE DELETE ON access_usage WHEN old.user='$sid' BEGIN SELECT RAISE(ABORT, 'blocked by the test'); END;") } finally { $store.Dispose() }
        $log = Invoke-SidCollection $s
        $log | Should -Match ([regex]::Escape("Identities: the rows of $sid could not be renamed to contoso\hank (") + '.*blocked by the test')
        $row = Id $s $sid
        $row[2] | Should -Be 'resolved'
        $row[3] | Should -Match '^anchor:contoso\\hank=3'
        [string]$row[6] | Should -BeNullOrEmpty
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2
        (Id $s $script:SidGhost)[5] | Should -Be 2
        $store = Open-ExlStore -Settings $s
        try { $store.Exec('DROP TRIGGER test_block_rename;') } finally { $store.Dispose() }
        [void](Invoke-SidCollection $s)
        Count1 $s "SELECT COUNT(*) FROM access_usage WHERE user='$sid'" | Should -Be 0
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 5
        (Id $s $sid)[6] | Should -Not -BeNullOrEmpty
    }

    It 'removes the requests of a SID resolved to a system account, as noise' {
        $dir = Join-Path $TestDrive 'sid-map-system'
        [void][IO.Directory]::CreateDirectory($dir)
        $map = Join-Path $dir 'identities.psd1'
        Set-Content -LiteralPath $map -Value "@{ '$($script:SidGhost)' = 'CONTOSO\HealthMailbox9999' }"
        $s = New-SidSettings 'system' 'Ghost' @{ "IdentityMapFile        = ''" = "IdentityMapFile        = '$map'" }
        $log = Invoke-SidCollection $s
        $sid = $script:SidGhost.ToLowerInvariant()
        foreach ($table in 'access_usage', 'access_client', 'client_session') { Count1 $s "SELECT COUNT(*) FROM $table WHERE user='$sid' OR user LIKE '%healthmailbox9999%'" | Should -Be 0 -Because $table }
        Count1 $s "SELECT SUM(lines) FROM noise WHERE reason='System or health mailbox (resolved from a SID)'" | Should -Be 2
        $log | Should -Match '1 SID\(s\) resolved to a system account, 2 request\(s\) removed as noise'
    }

    It 'merges the rows stored under a SID when its evidence arrives with a later collection' {
        $s = New-SidSettings 'late' 'EwsBearer', 'EasBearer', 'Ghost', 'Ivan'
        [void](Invoke-SidCollection $s)
        $sid = $script:SidHank.ToLowerInvariant()
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 4
        Count1 $s "SELECT COUNT(*) FROM access_usage WHERE user='hank@contoso.test'" | Should -Be 1
        Add-SidLogs 'late' 'EasBasic'
        [void](Invoke-SidCollection $s)
        foreach ($table in 'access_usage', 'access_client', 'client_session') { Count1 $s "SELECT COUNT(*) FROM $table WHERE user='$sid' OR user='hank@contoso.test'" | Should -Be 0 -Because $table }
        # The same figures and sessions as one collection of every file.
        $sums = "SELECT user||'|'||protocol||'|'||SUM(requests)||'|'||SUM(successes)||'|'||SUM(bytes_in) FROM access_usage GROUP BY user, protocol ORDER BY 1"
        (@(SidRows $s $sums | ForEach-Object { $_[0] }) -join "`n") | Should -BeExactly (@(SidRows $script:SidAll $sums | ForEach-Object { $_[0] }) -join "`n")
        $sessions = "SELECT user||'|'||protocol||'|'||requests||'|'||start_ms||'|'||end_ms FROM client_session ORDER BY 1"
        (@(SidRows $s $sessions | ForEach-Object { $_[0] }) -join "`n") | Should -BeExactly (@(SidRows $script:SidAll $sessions | ForEach-Object { $_[0] }) -join "`n")
        $clients = "SELECT user||'|'||protocol||'|'||auth_type||'|'||requests||'|'||servers FROM access_client ORDER BY 1"
        (@(SidRows $s $clients | ForEach-Object { $_[0] }) -join "`n") | Should -BeExactly (@(SidRows $script:SidAll $clients | ForEach-Object { $_[0] }) -join "`n")
        Count1 $s "SELECT COUNT(*) FROM session_step WHERE session_id NOT IN (SELECT id FROM client_session)" | Should -Be 0
    }

    It 'reads the lines collected while no evidence was gathered again for their evidence, for the SIDs already stored, then never again' {
        $s = New-SidSettings 'rescan' 'EasBearer', 'EasBasic' @{ 'ResolveSids            = $true' = 'ResolveSids            = $false' }
        [void](Invoke-SidCollection $s)
        $sid = $script:SidHank.ToLowerInvariant()
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$sid'" | Should -Be 2
        Count1 $s 'SELECT COUNT(*) FROM identity_map' | Should -Be 0
        Meta $s 'identity_evidence_scan' | Should -Be 0
        $on = Import-ExlConfiguration -Path ($s.ConfigPath) -Root $script:Root
        $on.Collection.ResolveSids = $true
        $log = Invoke-SidCollection $on
        $log | Should -Match 'Identities: evidence read again from \d+ ActiveSync, OWA and ECP HttpProxy file\(s\) already collected .*the evidence scan is complete'
        Count1 $on "SELECT COUNT(*) FROM access_usage WHERE user='$sid'" | Should -Be 0
        Count1 $on "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 5
        (Id $on $sid)[3] | Should -Match '^anchor:contoso\\hank=3(;|$)'
        Meta $on 'identity_evidence_scan' | Should -Be 1
        Meta $on 'identity_evidence_scan_cursor' | Should -Be 0
        $log = Invoke-SidCollection $on
        $log | Should -Not -Match 'evidence read again'
        (Id $on $sid)[3] | Should -Match '^anchor:contoso\\hank=3(;|$)'
    }

    It 'spreads the evidence scan over several collections within its budget, and reads every file once' {
        $s = New-SidSettings 'rescan-budget' 'EasBearer', 'EasBasic' @{ 'ResolveSids            = $true' = 'ResolveSids            = $false'; 'Parallelism            = 0' = 'Parallelism            = 1' }
        [void](Invoke-SidCollection $s)
        $on = Import-ExlConfiguration -Path ($s.ConfigPath) -Root $script:Root
        $on.Collection.ResolveSids = $true
        # A budget of 0 MB: one file per collection.
        $on.Collection.EvidenceRescanMBPerRun = 0
        $sid = $script:SidHank.ToLowerInvariant()
        $log = Invoke-SidCollection $on
        $log | Should -Match 'Identities: evidence read again from 1 ActiveSync, OWA and ECP HttpProxy file\(s\) already collected .*; [1-9]\d* file\(s\) left for the next collections'
        Meta $on 'identity_evidence_scan_cursor' | Should -Be 1
        Meta $on 'identity_evidence_scan' | Should -Be 0
        $runs = 1
        while ((Meta $on 'identity_evidence_scan') -eq 0 -and $runs -lt 20) { $log = Invoke-SidCollection $on; $runs++ }
        Meta $on 'identity_evidence_scan' | Should -Be 1
        $runs | Should -BeGreaterThan 1
        $log | Should -Match 'the evidence scan is complete'
        Count1 $on "SELECT COUNT(*) FROM access_usage WHERE user='$sid'" | Should -Be 0
        Count1 $on "SELECT SUM(requests) FROM access_usage WHERE user='contoso\hank'" | Should -Be 5
        (Id $on $sid)[3] | Should -Match '^anchor:contoso\\hank=3(;|$)'
    }

    It 'leaves everything as logged when ResolveSids is $false' {
        $s = New-SidSettings 'off' 'EwsBearer', 'EasBearer', 'EasBasic' @{ 'ResolveSids            = $true' = 'ResolveSids            = $false' }
        [void](Invoke-SidCollection $s)
        Count1 $s "SELECT SUM(requests) FROM access_usage WHERE user='$($script:SidHank.ToLowerInvariant())'" | Should -Be 4
        Count1 $s 'SELECT COUNT(*) FROM identity_map' | Should -Be 0
    }
}

Describe 'Reports' {
    BeforeAll {
        $script:Period = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try {
            $script:Detailed = New-ExlReport -Store $store -Settings $script:Settings -Period $script:Period -ReportType Detailed
            $script:Usage = New-ExlReport -Store $store -Settings $script:Settings -Period $script:Period -ReportType Usage -IncludeRoutingDetails $false
        } finally { $store.Dispose() }
        function Csv($Report, [string]$Name) { Import-Csv -LiteralPath (Join-Path $Report.Folder "ExchangeLogs-$Name.csv") -Delimiter ';' }
    }
    It 'lists every configured server, including the one without real usage' {
        $rows = Csv $script:Usage 'Servers'
        ($rows | Where-Object Server -eq 'EXCH01').Verdict | Should -Be 'In use'
        ($rows | Where-Object Server -eq 'EXCH02').Verdict | Should -Be 'No real usage'
    }
    It 'gives the resolution of each failure' {
        $rows = Csv $script:Detailed 'ClientAccess-Requests'
        ($rows | Where-Object Status -eq 500).Resolution | Should -Be 'Recovered'
        ($rows | Where-Object Status -eq 500).'Recovered after' | Should -Be '30 s'
        ($rows | Where-Object Status -eq 503).Resolution | Should -Be 'Unresolved'
        ($rows | Where-Object Status -eq 503).'Win32 status' | Should -Be '1236'
        ($rows | Where-Object Outcome -eq 'Slow').Resolution | Should -Be 'Slow success'
    }
    It 'writes one row per client session with its outcome and timeline' {
        $rows = @(Csv $script:Detailed 'ClientSessions')
        $erin = $rows | Where-Object User -eq 'contoso\erin'
        $erin.Outcome | Should -Be 'Recovered'
        $erin.Client | Should -Be 'iPhone (ActiveSync)'
        $erin.Timeline | Should -Match 'DeviceNotProvisioned'
        $erin.Timeline | Should -Match '1326'
        $dave = $rows | Where-Object { $_.User -eq 'contoso\dave' }
        $dave.Software | Should -Be 'OUTLOOK.EXE 16.0.17928.20114'
        $dave.Timeline | Should -Match 'Back end: MAPI OK'
        $dave.Timeline | Should -Match 'MapiExceptionNotFound'
        $dave.Timeline | Should -Match 'Front end EXCH01 HttpProxy .*HttpProxy_2026100108-2\.LOG'
        $dave.Timeline | Should -Match 'Back end EXCH01 MapiBackEnd .*MapiHttp_2026100108-1\.LOG'
        ($rows | Where-Object { $_.User -eq 'contoso\frank' -and $_.Protocol -eq 'Imap4' }).Client | Should -Be 'IMAP4 client'
    }
    It 'lists clients, devices and operations with their latency' {
        $c = @(Csv $script:Usage 'Clients') | Where-Object { $_.User -eq 'contoso\erin' -and $_.'Device ID' -eq 'ERINPHONE1' }
        $c.'Device type' | Should -Be 'iPhone'
        $c.Client | Should -Be 'iPhone (ActiveSync)'
        $o = @(Csv $script:Usage 'Operations') | Where-Object { $_.Protocol -eq 'Mapi' -and $_.Operation -eq 'NotificationWait' }
        $o.'Average (ms)' | Should -Be '60000'
        $o.Slow | Should -Be '0'
    }
    It 'leaves the session timeline out of the CSV when IncludeSessionDetails is off' {
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:Settings -Period $script:Period -ReportType Detailed -IncludeSessionDetails $false } finally { $store.Dispose() }
        (Csv $r 'ClientSessions')[0].PSObject.Properties.Name | Should -Not -Contain 'Timeline'
    }
    It 'writes one row per message with its status and route' {
        $rows = @(Csv $script:Detailed 'Messages')
        $rows.Count | Should -Be 3
        $m = $rows | Where-Object 'Message ID' -eq '<msg-001@contoso.test>'
        $m.Status | Should -Be 'Partially failed'
        $m.Delivered | Should -Be '1'
        $m.Failed | Should -Be '1'
        $m.'SMTP sessions' | Should -Be '3'
        $m.Route | Should -Match 'SMTP Receive \(FrontEnd\)'
        $m.Route | Should -Match 'DELIVER'
        $m.Route | Should -Not -Match 'HARECEIVE'
        ($rows | Where-Object 'Message ID' -eq '<msg-002@contoso.test>').Status | Should -Be 'Delivered'
        $refused = $rows | Where-Object Status -eq 'Rejected (SMTP)'
        $refused.Sender | Should -Be 'spam@example.net'
        $refused.Recipients | Should -Be 'nobody@contoso.test (Rejected)'
        $refused.Route | Should -Match 'RecipientNotFound'
    }
    It 'lists the SMTP clients without the hops between Exchange servers' {
        $rows = @(Csv $script:Usage 'SmtpClients')
        @($rows.'Remote IP' | Sort-Object) | Should -Be @('10.1.1.50', '10.1.1.70', '203.0.113.9')
        $tb = $rows | Where-Object 'Remote IP' -eq '10.1.1.70'
        @($tb.HELO, $tb.Accepted, $tb.Authentication) | Should -Be @('thunderbird.contoso.test', '1', 'Authenticated client (proxied by EXCH01)')
        $script:First.NoiseReasons['Client submission proxied to a mailbox server (recorded there)'] | Should -Be 6
        $app = $rows | Where-Object 'Remote IP' -eq '10.1.1.50'
        @($app.HELO, $app.Accepted, $app.Recipients, $app.TLS, $app.Authentication) | Should -Be @('app01.contoso.test', '1', '2', 'TLS 1.2', 'Anonymous')
        ($rows | Where-Object 'Remote IP' -eq '203.0.113.9').'Last error' | Should -Match '^550'
        $html = Get-Content -LiteralPath $script:Detailed.HtmlPath -Raw
        $html | Should -Match '"smtpclients":\{"rows":3'
        $html | Should -Not -Match '"smtp":\{"rows"'
        $html | Should -Not -Match '"clients":\{"rows"'
    }
    It 'gives each user its clients and devices' {
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:Settings -Period $script:Period -ReportType Usage -User 'erin' } finally { $store.Dispose() }
        @(Csv $r 'Clients').'Device ID' | Should -Contain 'ERINPHONE1'
        $html = Get-Content -LiteralPath $r.HtmlPath -Raw
        $html | Should -Match '"name":"Clients and devices","kind":"steps"'
    }
    It 'leaves the route out of the CSV when IncludeRoutingDetails is off' {
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:Settings -Period $script:Period -ReportType Detailed -IncludeRoutingDetails $false } finally { $store.Dispose() }
        (Csv $r 'Messages')[0].PSObject.Properties.Name | Should -Not -Contain 'Route'
    }
    It 'filters every view on a user' {
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { $r = New-ExlReport -Store $store -Settings $script:Settings -Period $script:Period -ReportType Detailed -User 'alice' } finally { $store.Dispose() }
        @(Csv $r 'Users').User | Should -Be @('contoso\alice')
        @(Csv $r 'Messages').'Message ID' | Should -Be @('<msg-001@contoso.test>')
        @(Csv $r 'ClientAccess-Requests' | Where-Object Outcome -eq 'Success').Count | Should -BeGreaterThan 0
        @(Csv $r 'ClientSessions').User | Select-Object -Unique | Should -Be @('contoso\alice')
    }
    It 'builds a self-contained HTML file' {
        $html = Get-Content -LiteralPath $script:Detailed.HtmlPath -Raw
        $html | Should -Not -Match '%%(META|CHUNKS)%%'
        ([regex]::Matches($html, '__exl\.push\("c"')).Count | Should -BeGreaterThan 3
        $html | Should -Match '"messages":\{"rows":3'
    }
    It 'lists the authentication types per protocol, with the users and devices behind each row' {
        $rows = @(Csv $script:Usage 'Authentication')
        $row = { param($protocol, $mode) @($rows | Where-Object { $_.Protocol -eq $protocol -and $_.Authentication -eq $mode }) }
        $eas = & $row 'Eas' 'Basic'
        $eas.Count | Should -Be 1
        # The iPhone with its device ID and its OPTIONS request without one: two clients, one device.
        @($eas[0].'OAuth possible', $eas[0].Users, $eas[0].Clients, $eas[0].Devices, $eas[0].Requests) | Should -Be @('Yes', '1', '2', '1', '5')
        (& $row 'Mapi' 'Negotiate')[0].Users | Should -Be '2'
        (& $row 'Mapi' 'OAuth')[0].Users | Should -Be '1'
        (& $row 'Mapi' 'OAuth')[0].Requests | Should -Be '3'
        (& $row 'Ews' 'OAuth')[0].Users | Should -Be '1'
        (& $row 'Ews' 'Negotiate')[0].Users | Should -Be '2'
        (& $row 'Oab' 'NTLM')[0].Users | Should -Be '1'
        $imap = & $row 'Imap4' 'Unknown'
        @($imap[0].'OAuth possible', $imap[0].Users) | Should -Be @('No', '1')
        # One row per protocol and type, by protocol then most users first; no CSV column for the clients detail.
        @($rows | ForEach-Object { "$($_.Protocol)|$($_.Authentication)" } | Select-Object -Unique).Count | Should -Be $rows.Count
        (Get-Content -LiteralPath (Join-Path $script:Usage.Folder 'ExchangeLogs-Authentication.csv') -TotalCount 1) | Should -BeExactly ("$([char]0xFEFF)Protocol;Authentication;OAuth possible;Users;Clients;Devices;Requests;Failed requests;Active days;First seen;Last seen;Servers")
        $users = @(Csv $script:Usage 'Users')
        @($users[0].PSObject.Properties.Name)[13] | Should -BeExactly 'Authentication'
        @($users[0].PSObject.Properties.Name).Count | Should -Be 14
        # A user lists its types in a fixed order (OAuth first, Unknown last); a session lists them most requests first (below).
        ($users | Where-Object User -eq 'contoso\erin').Authentication | Should -Match '^(Basic|Basic, Unknown)$'
        $clients = @(Csv $script:Usage 'Clients')
        @($clients[0].PSObject.Properties.Name)[13] | Should -BeExactly 'Authentication'
        ($clients | Where-Object { $_.User -eq 'contoso\grace' -and $_.Protocol -eq 'Ews' }).Authentication | Should -BeExactly 'OAuth'
        # The description has the dataset and its clients detail; the overview has the tile.
        $html = Get-Content -LiteralPath $script:Usage.HtmlPath -Raw
        $meta = [regex]::Match($html, '<script id="report-meta" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json -Depth 50
        @($meta.datasets.authentication.detailColumns) -join ',' | Should -Be '12'
        $meta.datasets.authentication.columns[12].name | Should -BeExactly 'Clients detail'
        $html | Should -Match 'id="metric-auth"'
        $html | Should -Match 'id="metric-auth-note"'
        $script:Usage.Counts['usersOnOAuth'] | Should -Be 2
        $script:Usage.Counts['usersOnBasic'] | Should -Be 1
    }
    It 'shows the authentication types of the client sessions and the users on Basic in a Detailed report' {
        $names = @((Csv $script:Detailed 'ClientSessions')[0].PSObject.Properties.Name)
        $names[25] | Should -BeExactly 'Authentication'
        $names[26] | Should -BeExactly 'Timeline'
        $names.Count | Should -Be 27
        $rows = @(Csv $script:Detailed 'ClientSessions')
        ($rows | Where-Object { $_.User -eq 'contoso\dave' -and $_.Protocol -eq 'Mapi' }).Authentication | Should -BeExactly 'Negotiate, OAuth'
        ($rows | Where-Object { $_.User -eq 'contoso\frank' -and $_.Protocol -eq 'Imap4' }).Authentication | Should -BeExactly ''
        $basic = @($script:Detailed.Highlights | Where-Object Title -eq 'Users on Basic authentication')
        $basic.Count | Should -Be 1
        $basic[0].Total | Should -Be 1
        @($basic[0].Rows[0][0], $basic[0].Rows[0][1]) | Should -Be @('Eas', '1')
        # The failed and slow requests keep the type as logged.
        ((Csv $script:Detailed 'ClientAccess-Requests') | Where-Object Status -eq 503).Authentication | Should -BeExactly 'Negotiate'
        $html = Get-Content -LiteralPath $script:Detailed.HtmlPath -Raw
        $html | Should -Match '"authentication":\{'
        $html | Should -Match 'id="metric-auth"'
    }
    It 'gives the share of the users on OAuth in the e-mail' {
        $mail = [ExchangeLogReport.ReportMail]::Build($script:Usage, 's', 'Exchange Log Report', 'p', 'Usage', 'PC1', 'None', 1MB)
        $mail.Text | Should -Match 'Authentication: \d+ % of users on OAuth, 1 on Basic, \d+ on Negotiate/NTLM/Kerberos'
        $none = [ExchangeLogReport.ReportMail]::Build([ExchangeLogReport.ReportResult]@{ Folder = $TestDrive; Title = 't' }, 's', 't', 'p', 'Usage', 'PC1', 'None', 1MB)
        $none.Text | Should -Not -Match 'Authentication:'
    }
}

Describe 'Bounded-memory reports' {
    BeforeAll {
        $script:MemoryConfig = New-TestConfig (Join-Path $TestDrive 'memory-report')
        $script:MemorySettings = Import-ExlConfiguration -Path $script:MemoryConfig -Root $script:Root
        [void](Invoke-TestCollection $script:MemorySettings)
        $script:MemorySettings.Report.MaxHtmlRows = 2
        $script:MemoryPeriod = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $t = $script:Base.ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $script:MemorySettings
        try {
            $store.Exec(@"
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<260)
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,
 requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,
 total_ms,max_ms,bytes_in,bytes_out,last_error)
SELECT 'bounded-'||x,'$(T 0 -W3C)', $t+x*1000,$t+x*1000,'contoso\bounded-'||x,'Mapi','EXCH01','EXCH01',
 1,0,1,0,0,0,$t+x*1000,$t+x*1000,1,1,0,0,'Failure '||x FROM n;
INSERT INTO session_step(session_id,time_ms,data)
SELECT id,start_ms,json_array(json_array(start_ms,0,'EXCH01','EXCH01','Execute',500,1,1,1,1,
 'Timeline '||skey,NULL,'FE',json('false'),0,NULL,NULL)) FROM client_session WHERE skey LIKE 'bounded-%';
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<300)
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,remote_ep,helo,
 mail_from,rcpt_count,rcpts,message_id,status,response,transcript)
SELECT $t+x*1000,$t+x*1000,'EXCH01','Receive','FrontEnd','bounded-client','bounded-client-'||x,
 '203.0.113.33:12345','bounded-client','sender@example.test',1,'recipient@example.test','<bounded-'||x||'>',
 CASE WHEN x<=210 THEN 'Rejected' ELSE 'Accepted' END,'Response '||x,'Transcript '||x FROM n;
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<300)
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,remote_ep,
 mail_from,rcpt_count,rcpts,status,response,transcript)
SELECT $t+x*1000,$t+x*1000,'EXCH01','Send','Hub','bounded-target','bounded-target-'||x,
 '203.0.113.44:25','sender@example.test',1,'recipient@example.test',
 CASE WHEN x<=210 THEN 'Deferred' ELSE 'Sent' END,'Response '||x,'t S: 220 bounded.example.test' FROM n;
"@)
        } finally { $store.Dispose() }
        function MemoryReport($Settings = $script:MemorySettings) {
            $store = Open-ExlStore -Settings $Settings -ReadOnly
            try { New-ExlReport -Store $store -Settings $Settings -Period $script:MemoryPeriod -ReportType Detailed }
            finally { $store.Dispose() }
        }
        function HtmlRows([string]$Path) { (Read-TestHtml $Path).Sets }
        $script:MemoryReport = MemoryReport
    }
    It 'keeps all CSV rows and timelines across session batches while limiting only HTML' {
        $sessions = @(Import-Csv (Join-Path $script:MemoryReport.Folder 'ExchangeLogs-ClientSessions.csv') -Delimiter ';')
        $bounded = @($sessions | Where-Object User -Like 'contoso\bounded-*')
        $bounded.Count | Should -Be 260
        foreach ($row in $bounded) { $row.Timeline | Should -Match ([regex]::Escape("Timeline $($row.User.Split('\')[-1])")) }
        $html = HtmlRows $script:MemoryReport.HtmlPath
        $html.sessions.Count | Should -Be 2
        $html.messages.Count | Should -Be 2
        $highlight = $script:MemoryReport.Highlights | Where-Object Title -EQ 'Client sessions that failed'
        $highlight.Total | Should -BeGreaterOrEqual 260
        $highlight.Rows.Count | Should -Be 10
        @(Get-ChildItem $script:MemoryReport.Folder -Filter '.report-*.tmp*' -Force).Count | Should -Be 0
    }
    It 'samples SMTP details before loading transcripts without truncating SMTP CSV' {
        $html = HtmlRows $script:MemoryReport.HtmlPath
        $client = $html.smtpclients | Where-Object { $_[1] -eq 'bounded-client' }
        $detail = $client[16]
        $detail.Count | Should -Be 200
        @($detail | Where-Object { $_[3] -eq 'Rejected' }).Count | Should -Be 150
        @($detail | Where-Object { $_[3] -eq 'Accepted' }).Count | Should -Be 50
        $detail[0][8] | Should -Be 'Transcript 61'
        $detail[-1][8] | Should -Be 'Transcript 300'
        $csv = @(Import-Csv (Join-Path $script:MemoryReport.Folder 'ExchangeLogs-SmtpSessions.csv') -Delimiter ';')
        @($csv | Where-Object Connector -EQ 'bounded-client').Count | Should -Be 300
        @($csv | Where-Object Connector -EQ 'bounded-target').Count | Should -Be 300
    }
    It 'preserves Edge destination sampling and banner enrichment' {
        $s = Import-ExlConfiguration -Path $script:MemoryConfig -Root $script:Root
        foreach ($server in $s.Servers) { $server.Role = 'Edge' }
        $report = MemoryReport $s
        $html = HtmlRows $report.HtmlPath
        $target = $html.smtpdestinations | Where-Object { $_[2] -eq 'bounded-target' }
        $target[1] | Should -Be 'bounded.example.test'
        $detail = $target[15]
        $detail.Count | Should -Be 200
        @($detail | Where-Object { $_[3] -eq 'Deferred' }).Count | Should -Be 150
        @($detail | Where-Object { $_[3] -eq 'Sent' }).Count | Should -Be 50
        $detail[0][6] | Should -Be 'Response 61'
        $detail[-1][6] | Should -Be 'Response 300'
    }
    It 'keeps the HTML tables within MaxHtmlRows in the summary chunks, the detail blocks and the description' {
        $html = Read-TestHtml $script:MemoryReport.HtmlPath -Summary
        foreach ($property in $html.Meta.datasets.PSObject.Properties) {
            $name = $property.Name; $def = $property.Value
            $html.Sets[$name].Count | Should -Be $def.rows -Because $name
            $def.rows | Should -BeLessOrEqual 2
            $def.total | Should -BeGreaterOrEqual $def.rows
            $blocks = @($html.Blocks | Where-Object Set -EQ $name)
            $covered = if ($blocks.Count) { ($blocks | Measure-Object -Property Count -Sum).Sum } else { $null }
            if ($def.PSObject.Properties['detailColumns']) { $covered | Should -Be $def.rows -Because $name } else { $covered | Should -BeNullOrEmpty -Because $name }
        }
        $html.Meta.datasets.sessions.total | Should -BeGreaterThan 2
    }
    It 'lists the detail columns in the description and leaves servers and daily whole' {
        $html = Read-TestHtml $script:MemoryReport.HtmlPath -Summary
        foreach ($property in $html.Meta.datasets.PSObject.Properties) {
            $name = $property.Name; $columns = @($property.Value.columns)
            $steps = @(0..($columns.Count - 1) | Where-Object { $columns[$_].kind -eq 'steps' })
            if ($name -in 'servers', 'daily') { $property.Value.PSObject.Properties['detailColumns'] | Should -BeNullOrEmpty -Because $name }
            elseif ($steps.Count) { @($property.Value.detailColumns) | Should -Be $steps -Because $name }
            else { $property.Value.PSObject.Properties['detailColumns'] | Should -BeNullOrEmpty -Because $name }
        }
        $html.Meta.datasets.sessions.detailColumns.Count | Should -BeGreaterThan 0
        @($html.Blocks | Where-Object Set -In 'servers', 'daily').Count | Should -Be 0
        $serverSteps = @(0..($html.Meta.datasets.servers.columns.Count - 1) | Where-Object { $html.Meta.datasets.servers.columns[$_].kind -eq 'steps' })
        @($html.Sets.servers | Where-Object { $row = $_; @($serverSteps | Where-Object { $null -ne $row[$_] }).Count }).Count | Should -BeGreaterThan 0
        foreach ($row in $html.Sets.sessions) { foreach ($k in $html.Meta.datasets.sessions.detailColumns) { $row[$k] | Should -BeNullOrEmpty } }
    }
    It 'writes the chunks of each dataset together, in the order the page opens the tables' {
        $order = @((Read-TestHtml $script:MemoryReport.HtmlPath -Summary).Order)
        $sets = @(); foreach ($name in $order) { if (-not $sets -or $sets[-1] -ne $name) { $sets += $name } }
        $sets.Count | Should -Be @($sets | Select-Object -Unique).Count
        $ranked = 'servers', 'daily', 'users', 'operations', 'authentication', 'smtpclients', 'smtpdestinations', 'sessions', 'issues', 'messages'
        $positions = @($sets | ForEach-Object { $ranked.IndexOf($_) })
        $positions | Should -Not -Contain -1
        $positions | Should -Be @($positions | Sort-Object)
        $sets[0] | Should -Be 'servers'; $sets[1] | Should -Be 'daily'
    }
    It 'uses disk-backed temporary sorts for a read-only report' {
        $store = Open-ExlStore -Settings $script:MemorySettings -ReadOnly
        try { $store.Query('PRAGMA temp_store;', $null).Rows[0][0] | Should -Be 1 }
        finally { $store.Dispose() }
    }
    It 'supports CSV-only and HTML-only exports without losing dataset counts' {
        $formats = $script:MemorySettings.Report.Formats
        $output = $script:MemorySettings.Report.OutputPath
        try {
            $script:MemorySettings.Report.Formats = @('Csv')
            $script:MemorySettings.Report.OutputPath = Join-Path $output 'csv-only'
            $csv = MemoryReport
            $csv.HtmlPath | Should -BeNullOrEmpty
            ($csv.Files | Where-Object Dataset -EQ 'sessions').Rows | Should -Be $script:MemoryReport.Counts['sessions']
            $script:MemorySettings.Report.Formats = @('Html')
            $script:MemorySettings.Report.OutputPath = Join-Path $output 'html-only'
            $html = MemoryReport
            $html.Files.Count | Should -Be 1
            $html.Counts['sessions'] | Should -Be $csv.Counts['sessions']
            $html.Counts['smtp'] | Should -Be $csv.Counts['smtp']
            @($html.Steps | Where-Object { $_ -like '*SELECT time_ms,end_ms,server,direction*' }).Count | Should -Be 0
            @(Get-ChildItem $html.Folder -Filter '*.csv').Count | Should -Be 0
        } finally {
            $script:MemorySettings.Report.Formats = $formats
            $script:MemorySettings.Report.OutputPath = $output
        }
    }
    It 'splits HTML chunks by estimated memory as well as row count' {
        $store = Open-ExlStore -Settings $script:MemorySettings
        try {
            $store.Exec("UPDATE session_step SET data=json_set(data,'$[0][10]','Sized '||hex(zeroblob(32000))) WHERE session_id IN (SELECT id FROM client_session WHERE skey LIKE 'bounded-%');")
        } finally { $store.Dispose() }
        $limit = $script:MemorySettings.Report.MaxHtmlRows
        $script:MemorySettings.Report.MaxHtmlRows = 200000
        try { $report = MemoryReport }
        finally { $script:MemorySettings.Report.MaxHtmlRows = $limit }
        $sessionChunks = @((Read-TestHtml $report.HtmlPath -Summary).Order | Where-Object { $_ -eq 'sessions' }).Count
        $sessionChunks | Should -BeGreaterThan 1
        $rows = HtmlRows $report.HtmlPath
        $rows.sessions.Count | Should -Be $report.Counts['sessions']
    }
    It 'cuts detail blocks by rows and size, contiguous and covering every row' {
        $limit = $script:MemorySettings.Report.MaxHtmlRows
        $script:MemorySettings.Report.MaxHtmlRows = 200000
        try { $report = MemoryReport }
        finally { $script:MemorySettings.Report.MaxHtmlRows = $limit }
        $html = Read-TestHtml $report.HtmlPath -Summary
        foreach ($property in $html.Meta.datasets.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties['detailColumns'] }) {
            $name = $property.Name; $next = 0
            $blocks = @($html.Blocks | Where-Object Set -EQ $name)
            foreach ($block in $blocks) {
                $block.First | Should -Be $next -Because "$name blocks are contiguous and ascending"
                $block.Count | Should -BeGreaterThan 0
                $block.Count | Should -BeLessOrEqual 500
                $block.Rows.Count | Should -Be $block.Count
                $block.Named | Should -Be $name
                $next += $block.Count
            }
            $next | Should -Be $html.Sets[$name].Count -Because "$name blocks cover every summary row"
            $property.Value.rows | Should -Be $html.Sets[$name].Count
        }
        # 260 sessions with a 64 KB timeline each: the size limit, not the row limit, cuts their blocks.
        @($html.Blocks | Where-Object Set -EQ 'sessions').Count | Should -BeGreaterThan 10
        @($html.Blocks | Where-Object Set -EQ 'sessions' | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum | Should -BeLessThan 100
        $full = Read-TestHtml $report.HtmlPath
        $timeline = $full.Meta.datasets.sessions.detailColumns[0]
        @($full.Sets.sessions | Where-Object { $_[$timeline] }).Count | Should -Be $full.Sets.sessions.Count
    }
    It 'spills within a shared small budget and preserves parallel versus sequential contents' {
        $budget = $script:MemorySettings.Report.MemoryBudgetMB
        $workers = $script:MemorySettings.Report.Parallelism
        $output = $script:MemorySettings.Report.OutputPath
        try {
            $script:MemorySettings.Report.MemoryBudgetMB = 64
            $script:MemorySettings.Report.Parallelism = 1
            $script:MemorySettings.Report.OutputPath = Join-Path $output 'budget-64-serial'
            $serial = MemoryReport
            $serial.Parallelism | Should -Be 1
            $serial.SpilledRows | Should -BeGreaterThan 0
            $serial.PeakBufferBytes | Should -BeLessOrEqual (40MB)
            $serial.DatabaseCacheMB | Should -Be 16
            $script:MemorySettings.Report.MemoryBudgetMB = 256
            $script:MemorySettings.Report.Parallelism = 2
            $script:MemorySettings.Report.OutputPath = Join-Path $output 'budget-256-parallel'
            $parallel = MemoryReport
            $parallel.Parallelism | Should -Be 2
            $parallel.SpilledRows | Should -Be 0
            foreach ($file in $serial.Files | Where-Object Dataset -NE 'html') {
                $other = $parallel.Files | Where-Object Dataset -EQ $file.Dataset
                (Get-FileHash $file.Path).Hash | Should -Be (Get-FileHash $other.Path).Hash
            }
            $serialHtml = HtmlRows $serial.HtmlPath
            $parallelHtml = HtmlRows $parallel.HtmlPath
            foreach ($name in $serialHtml.Keys) {
                (ConvertTo-Json -InputObject @($serialHtml[$name]) -Depth 50 -Compress) |
                    Should -Be (ConvertTo-Json -InputObject @($parallelHtml[$name]) -Depth 50 -Compress)
            }
        } finally {
            $script:MemorySettings.Report.MemoryBudgetMB = $budget
            $script:MemorySettings.Report.Parallelism = $workers
            $script:MemorySettings.Report.OutputPath = $output
        }
    }
    It 'restores the caller SQLite cache after report generation' {
        $store = Open-ExlStore -Settings $script:MemorySettings -ReadOnly
        try {
            $store.Exec('PRAGMA cache_size=-65536;')
            [void](New-ExlReport -Store $store -Settings $script:MemorySettings -Period $script:MemoryPeriod -ReportType Detailed)
            $store.Query('PRAGMA cache_size;', $null).Rows[0][0] | Should -Be -65536
        } finally { $store.Dispose() }
    }
    It 'materializes spilled messages chronologically with complete subjects and routes' {
        $s = Import-ExlConfiguration -Path (New-TestConfig (Join-Path $TestDrive 'spilled-messages')) -Root $script:Root
        [void](Invoke-TestCollection $s)
        $s.Report.MemoryBudgetMB = 64
        $s.Report.Parallelism = 2
        $s.Report.MaxHtmlRows = 2
        $t = $script:Base.ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec(@"
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000)
INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,subject,log_id)
SELECT $t+x*1000,'EXCH01','DELIVER','<sort-'||(1001-x)||'@test>','sender@example.test',
 'recipient@example.test',hex(zeroblob(8192)),'sort-'||x FROM n;
"@)
        } finally { $store.Dispose() }
        $report = MemoryReport $s
        $report.SpilledRows | Should -BeGreaterThan 0
        $messages = @(Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' |
            Where-Object 'Message ID' -Like '<sort-*')
        $messages.Count | Should -Be 1000
        $messages[0].'Message ID' | Should -Be '<sort-1000@test>'
        $messages[-1].'Message ID' | Should -Be '<sort-1@test>'
        foreach ($message in $messages) {
            $message.Subject.Length | Should -Be 16384
            $message.Route | Should -Match 'DELIVER'
        }
        @(Get-ChildItem $report.Folder -Filter '.report-*.tmp*' -Force).Count | Should -Be 0
    }
    It 'logs report stages on the caller thread while CPU workers run' {
        $dir = Join-Path $TestDrive 'report-stages'
        $log = Start-ExlLog -Directory $dir
        try { [void](MemoryReport) }
        finally { Stop-ExlLog }
        $text = [IO.File]::ReadAllText($log)
        $text | Should -Match 'Report stage: Client sessions'
        $text | Should -Match 'Report stage: CSV exports'
        $text | Should -Match 'Report stage: HTML compression'
    }
    It 'propagates a CPU worker failure and cleans up without leaving background work' {
        $s = Import-ExlConfiguration -Path (New-TestConfig (Join-Path $TestDrive 'worker-failure')) -Root $script:Root
        [void](Invoke-TestCollection $s)
        $s.Report.Parallelism = 2
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("UPDATE session_step SET data='{}';") }
        finally { $store.Dispose() }
        { MemoryReport $s } | Should -Throw
        @(Get-ChildItem $s.Report.OutputPath -Recurse -Filter '.report-*.tmp*' -Force).Count | Should -Be 0
    }
    It 'keeps case-insensitive SMTP correlation and the full selected message journey' {
        $s = Import-ExlConfiguration -Path (New-TestConfig (Join-Path $TestDrive 'case-report')) -Root $script:Root
        [void](Invoke-TestCollection $s)
        $t = $script:Base.ToUnixTimeMilliseconds()
        $early = $t - 7200000
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,log_id) VALUES
 ($t,'EXCH01','RECEIVE','<Case-ID@Test>','sender@example.test','recipient@example.test','case-1'),
 ($t+1000,'EXCH01','DELIVER','<case-id@test>','sender@example.test','recipient@example.test','case-2'),
 ($early,'EXCH02','SEND','<Case-ID@Test>','sender@example.test','recipient@example.test','case-3');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,transcript) VALUES
 ($t,'EXCH01','Receive','case-1','<Case-ID@Test>','Accepted','Upper case transcript'),
 ($t+1000,'EXCH01','Send','case-2','<case-id@test>','Sent','Lower case transcript');
"@)
        } finally { $store.Dispose() }
        $report = MemoryReport $s
        $messages = @(Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';') |
            Where-Object 'Message ID' -In @('<Case-ID@Test>', '<case-id@test>')
        @($messages).Count | Should -Be 2
        foreach ($message in $messages) { $message.'SMTP sessions' | Should -Be '2' }
        ($messages | Where-Object 'Message ID' -CEQ '<Case-ID@Test>').Route | Should -Match 'EXCH02.*SEND'
        $rows = HtmlRows $report.HtmlPath
        $shown = $rows.messages | Where-Object { $_[15] -ceq '<Case-ID@Test>' }
        $shown[17].Count | Should -Be 2
    }
    It 'removes temporary report data and surfaces an export failure' {
        $template = $script:MemorySettings.Report.TemplatePath
        $bad = Join-Path $TestDrive 'invalid-report-template.html'
        [IO.File]::WriteAllText($bad, 'No report markers.')
        $script:MemorySettings.Report.TemplatePath = $bad
        try { { MemoryReport } | Should -Throw '*template must contain*' }
        finally { $script:MemorySettings.Report.TemplatePath = $template }
        @(Get-ChildItem $script:MemorySettings.Report.OutputPath -Recurse -Filter '.report-*.tmp*' -Force).Count | Should -Be 0
    }
    It 'builds a report in an output folder longer than MAX_PATH, with or without Report.ScratchFolder, and stops with a message beyond the SQLite bound' {
        $s = Import-ExlConfiguration -Path $script:MemoryConfig -Root $script:Root
        $s.Report.MemoryBudgetMB = 64
        $s.Report.OutputPath = Join-Path $TestDrive (@('a'.PadRight(60, 'a'), 'b'.PadRight(60, 'b'), 'c'.PadRight(60, 'c'), 'd'.PadRight(60, 'd')) -join '\')
        # The work file is opened through an extended path: the report folder may be longer than 260 characters.
        $inFolder = MemoryReport $s
        $inFolder.Folder.Length | Should -BeGreaterThan 260
        $inFolder.ScratchFolder | Should -Be $inFolder.Folder
        Test-Path -LiteralPath $inFolder.HtmlPath | Should -BeTrue
        # Beyond the 1040-byte bound of the SQLite Windows VFS the report stops and names the setting.
        $s.Report.OutputPath = Join-Path $TestDrive (@(1..9 | ForEach-Object { "$_".PadRight(120, 'x') }) -join '\')
        { MemoryReport $s } | Should -Throw '*The report folder*too long for the SQLite library*set Report.ScratchFolder*'
        $s.Report.OutputPath = Join-Path $TestDrive (@('a'.PadRight(60, 'a'), 'b'.PadRight(60, 'b'), 'c'.PadRight(60, 'c'), 'd'.PadRight(60, 'd')) -join '\')
        $s.Report.ScratchFolder = Join-Path $TestDrive 'scratch-long-output'
        $report = MemoryReport $s
        $report.Folder.Length | Should -BeGreaterThan 260
        Test-Path -LiteralPath $report.HtmlPath | Should -BeTrue
        $report.ScratchFolder | Should -Be $s.Report.ScratchFolder
        # The work file was used (rows were spooled to disk) and is gone.
        $report.SpilledRows | Should -BeGreaterThan 0
        $report.ScratchPeakBytes | Should -BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $report.Folder -Force -Filter '.report-*').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $s.Report.ScratchFolder -Force).Count | Should -Be 0
    }
    It 'puts the work file in the report folder when Report.ScratchFolder is empty, and logs where it is' {
        $s = Import-ExlConfiguration -Path $script:MemoryConfig -Root $script:Root
        $s.Report.MemoryBudgetMB = 64
        $s.Report.ScratchFolder | Should -BeNullOrEmpty
        $temp = [IO.Path]::GetTempPath()
        $tempBefore = @(Get-ChildItem -LiteralPath $temp -Force -Filter '.report-*.tmp*' -ErrorAction SilentlyContinue).Count
        $log = Start-ExlLog -Directory (Join-Path $TestDrive 'scratch-default-log')
        try { $report = MemoryReport $s } finally { Stop-ExlLog }
        $report.ScratchFolder | Should -Be $report.Folder
        $report.ScratchPeakBytes | Should -BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $report.Folder -Force -Filter '.report-*').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $temp -Force -Filter '.report-*.tmp*' -ErrorAction SilentlyContinue).Count | Should -Be $tempBefore
        [IO.File]::ReadAllText($log) | Should -Match ('Report I/O: .*work file in ' + [regex]::Escape($report.Folder) + ' \(.+ free at the start\)')
    }
    It 'uses Report.ScratchFolder for the work file, and explains a folder it cannot use' {
        $s = Import-ExlConfiguration -Path $script:MemoryConfig -Root $script:Root
        $s.Report.MemoryBudgetMB = 64
        $s.Report.ScratchFolder = Join-Path $TestDrive 'scratch-here'
        $report = MemoryReport $s
        $report.ScratchPeakBytes | Should -BeGreaterThan 0
        Test-Path -LiteralPath $s.Report.ScratchFolder | Should -BeTrue
        @(Get-ChildItem -LiteralPath $s.Report.ScratchFolder -Force).Count | Should -Be 0
        $s.Report.ScratchFolder = Join-Path $TestDrive (('s'.PadRight(120, 's')) + '\' + ('t'.PadRight(120, 't')))
        (MemoryReport $s).ScratchFolder | Should -Be $s.Report.ScratchFolder
        $s.Report.ScratchFolder = Join-Path $TestDrive (@(1..9 | ForEach-Object { "$_".PadRight(120, 's') }) -join '\')
        { MemoryReport $s } | Should -Throw '*too long for the SQLite library*Report.ScratchFolder*'
        $blocker = Join-Path $TestDrive 'scratch-is-a-file'
        [IO.File]::WriteAllText($blocker, 'x')
        $s.Report.ScratchFolder = Join-Path $blocker 'sub'
        { MemoryReport $s } | Should -Throw '*cannot be created*Report.ScratchFolder*'
    }
}

Describe 'HTML layouts' {
    BeforeAll {
        if (-not ('ElrTest.Crc32' -as [type])) {
            Add-Type -TypeDefinition @'
namespace ElrTest {
    public static class Crc32 {
        static readonly uint[] Table = Make();
        static uint[] Make() { var t = new uint[256]; for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[n] = c; } return t; }
        public static uint Of(byte[] bytes) { uint c = 0xFFFFFFFFu; foreach (var b in bytes) c = Table[(c ^ b) & 0xFF] ^ (c >> 8); return ~c; }
    }
}
'@
        }
        $script:LayoutConfig = New-TestConfig (Join-Path $TestDrive 'layout-report')
        $settings = Import-ExlConfiguration -Path $script:LayoutConfig -Root $script:Root
        [void](Invoke-TestCollection $settings)
        $script:LayoutPeriod = [pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }
        $t = $script:Base.ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $settings
        try {
            # 260 sessions whose timeline holds incompressible text: about 8 MB of data, far above a 1 MB threshold.
            $store.Exec(@"
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<260)
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,
 requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,
 total_ms,max_ms,bytes_in,bytes_out,last_error)
SELECT 'layout-'||x,'$(T 0 -W3C)', $t+x*1000,$t+x*1000,'contoso\layout-'||x,'Mapi','EXCH01','EXCH01',
 1,0,1,0,0,0,$t+x*1000,$t+x*1000,1,1,0,0,'Failure '||x FROM n;
INSERT INTO session_step(session_id,time_ms,data)
SELECT id,start_ms,json_array(json_array(start_ms,0,'EXCH01','EXCH01','Execute',500,1,1,1,1,
 'Timeline '||skey||' '||hex(randomblob(16000)),NULL,'FE',json('false'),0,NULL,NULL)) FROM client_session WHERE skey LIKE 'layout-%';
"@)
        } finally { $store.Dispose() }
        function LayoutSettings([hashtable]$Overrides = @{}) {
            $s = Import-ExlConfiguration -Path $script:LayoutConfig -Root $script:Root
            foreach ($k in $Overrides.Keys) { $s.Report[$k] = $Overrides[$k] }
            return $s
        }
        function LayoutReport([hashtable]$Overrides = @{}) {
            $s = LayoutSettings $Overrides
            $source = Open-ExlStore -Settings $s -ReadOnly
            try { New-ExlReport -Store $source -Settings $s -Period $script:LayoutPeriod -ReportType Detailed } finally { $source.Dispose() }
        }
        function LayoutRequest($Settings, [string]$Name) {
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs = $script:LayoutPeriod.StartMs; $q.EndMs = $script:LayoutPeriod.EndMs
            $q.Zone = $Settings.Zone
            $q.ConfiguredServers = [string[]]@($Settings.Servers.Name)
            $q.TemplatePath = $Settings.Report.TemplatePath
            $q.OutputFolder = Join-Path $Settings.Report.OutputPath $Name
            $q.Detailed = $true
            $q.WriteCsv = $false
            $q.MaxHtmlRows = 2
            return $q
        }
        function BuildRequest($Settings, $q) {
            $source = Open-ExlStore -Settings $Settings -ReadOnly
            try { return [ExchangeLogReport.ReportBuilder]::Build($source, $q) } finally { $source.Dispose() }
        }
        # The files of the manifest as the page finds them, with their text.
        function DataFiles($Report, $Html) {
            if ($Html.Meta.data.folder) { return @($Html.Meta.data.files | ForEach-Object { [pscustomobject]@{ Entry = $_; Text = [IO.File]::ReadAllText((Join-Path $Report.HtmlDataFolder $_.name)) } }) }
            $page = [IO.File]::ReadAllText($Report.HtmlPath)
            $inline = @([regex]::Matches($page, '<script>(__exl\.file\("[^"]+","[^"]+"\);\n[^<]*)</script>'))
            $files = @($Html.Meta.data.files)
            return @(0..($files.Count - 1) | ForEach-Object { [pscustomobject]@{ Entry = $files[$_]; Text = $inline[$_].Groups[1].Value } })
        }
        function AssertManifest($Report, $Html) {
            $files = DataFiles $Report $Html
            $files.Count | Should -BeGreaterThan 0
            foreach ($f in $files) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($f.Text)
                $bytes.Length | Should -Be $f.Entry.bytes -Because $f.Entry.name
                [ElrTest.Crc32]::Of($bytes) | Should -Be $f.Entry.crc -Because $f.Entry.name
                $f.Text.StartsWith("__exl.file(`"$($Html.Meta.data.id)`",`"$($f.Entry.name)`");`n") | Should -BeTrue -Because $f.Entry.name
            }
        }
        function AssertEveryRow($Report, $Html) {
            foreach ($p in $Html.Meta.datasets.PSObject.Properties) {
                $p.Value.rows | Should -Be $p.Value.total -Because $p.Name
                if ($p.Value.rows) { $Html.Sets[$p.Name].Count | Should -Be $p.Value.rows -Because $p.Name }
            }
            $Html.Meta.datasets.sessions.total | Should -Be $Report.Counts['sessions']
            $Html.Meta.datasets.sessions.total | Should -BeGreaterOrEqual 260
        }
    }
    It 'writes one file below the threshold, with every row of every table' {
        $r = LayoutReport @{ HtmlLayout = 'Auto'; SingleFileMaxMB = 4096 }
        $r.HtmlDataFolder | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $r.Folder 'ExchangeLogs_data') | Should -BeFalse
        $h = Read-TestHtml $r.HtmlPath -Summary
        $h.Meta.data.folder | Should -BeNullOrEmpty
        AssertEveryRow $r $h
        AssertManifest $r $h
        @(Get-ChildItem -LiteralPath $r.Folder -Recurse -Force -Filter '*.partial').Count | Should -Be 0
        (Get-Item -LiteralPath $r.HtmlPath).Length | Should -BeGreaterThan $r.HtmlDataBytes
    }
    It 'copies the main script of the template into the page, byte for byte, and writes no mark of the portal' {
        $r = LayoutReport @{ HtmlLayout = 'Folder' }
        $page = [IO.File]::ReadAllText($r.HtmlPath)
        $template = [IO.File]::ReadAllText((Join-Path $script:Root 'templates\Report.template.html'))
        $script = [IO.File]::ReadAllText((Join-Path $script:Root 'templates\Report.template.js'))
        # The template around its markers, the script where its marker was: the page ends with the script element that holds the file.
        $page.EndsWith("<script>`r`n" + $script + "</script>`r`n</body></html>`r`n") | Should -BeTrue
        $page.StartsWith($template.Substring(0, $template.IndexOf('%%CHUNKS%%'))) | Should -BeTrue
        $page | Should -Not -Match '%%(META|CHUNKS|SCRIPT)%%'
        $page | Should -Not -Match ([regex]::Escape('<script id="report-meta" type="application/json">{"served":true}'))
        $page | Should -Not -Match '<script src="report\.js">'
        $meta = [regex]::Match($page, '<script id="report-meta" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json -Depth 50
        $meta.PSObject.Properties['served'] | Should -BeNullOrEmpty
        $meta.data.folder | Should -Be 'ExchangeLogs_data'
    }
    It 'refuses a main script that would end its script element' {
        $folder = Join-Path $TestDrive 'bad-script'; [void][IO.Directory]::CreateDirectory($folder)
        Copy-Item -LiteralPath (Join-Path $script:Root 'templates\Report.template.html') -Destination $folder
        [IO.File]::WriteAllText((Join-Path $folder 'Report.template.js'), 'const x = "</SCRIPT>";')
        $s = LayoutSettings @{ TemplatePath = Join-Path $folder 'Report.template.html' }
        { BuildRequest $s (LayoutRequest $s 'bad-script') } | Should -Throw '*must not contain </script*'
    }
    It 'writes the page and a data folder when forced, with files that match the manifest' {
        $r = LayoutReport @{ HtmlLayout = 'Folder' }
        (Get-Item -LiteralPath $r.HtmlPath).Length | Should -BeLessThan 400KB
        $folder = Join-Path $r.Folder 'ExchangeLogs_data'
        $r.HtmlDataFolder | Should -Be $folder
        $h = Read-TestHtml $r.HtmlPath -Summary
        $h.Meta.data.folder | Should -Be 'ExchangeLogs_data'
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be $h.Meta.data.id
        AssertEveryRow $r $h
        AssertManifest $r $h
        @(Get-ChildItem -LiteralPath $folder -Force | Where-Object Name -NE '.exl-data').Count | Should -Be @($h.Meta.data.files).Count
        $r.HtmlDataFiles | Should -Be @($h.Meta.data.files).Count
        # Detail files are contiguous from row 0 and cover every row of their table.
        foreach ($p in $h.Meta.datasets.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties['detailColumns'] }) {
            $next = 0
            foreach ($f in @($h.Meta.data.files | Where-Object { $_.kind -eq 'd' -and $_.set -eq $p.Name })) {
                $f.first | Should -Be $next -Because $f.name
                $next += $f.rows
            }
            $next | Should -Be $p.Value.rows -Because $p.Name
        }
        @(Get-ChildItem -LiteralPath $r.Folder -Recurse -Force -Filter '*.partial').Count | Should -Be 0
    }
    It 'cuts the data files at the pack size and keeps each block whole' {
        $s = LayoutSettings @{ HtmlLayout = 'Folder' }
        $q = LayoutRequest $s 'packs'; $q.MaxHtmlRows = 0; $q.HtmlLayout = 'Folder'; $q.HtmlPackBytes = 200KB
        $r = BuildRequest $s $q
        $h = Read-TestHtml $r.HtmlPath -Summary
        $sessionDetails = @($h.Meta.data.files | Where-Object { $_.kind -eq 'd' -and $_.set -eq 'sessions' })
        $sessionDetails.Count | Should -BeGreaterThan 3
        foreach ($f in $sessionDetails) { if ($f.blocks -gt 1) { $f.bytes | Should -BeLessOrEqual (200KB + 4096) -Because $f.name } }
        AssertEveryRow $r $h
        AssertManifest $r $h
    }
    It 'switches to a folder above SingleFileMaxMB and inlines below, with the same data' {
        $folder = LayoutReport @{ HtmlLayout = 'Auto'; SingleFileMaxMB = 1 }
        $single = LayoutReport @{ HtmlLayout = 'Auto'; SingleFileMaxMB = 4096 }
        $folder.HtmlDataBytes | Should -BeGreaterThan 1MB
        $folder.HtmlDataFolder | Should -Not -BeNullOrEmpty
        $single.HtmlDataFolder | Should -BeNullOrEmpty
        $a = Read-TestHtml $folder.HtmlPath -Summary; $b = Read-TestHtml $single.HtmlPath -Summary
        @($a.Sets.Keys | Sort-Object) | Should -Be @($b.Sets.Keys | Sort-Object)
        foreach ($name in $a.Sets.Keys) { $a.Sets[$name].Count | Should -Be $b.Sets[$name].Count -Because $name }
        @($a.Order) | Should -Be @($b.Order)
        @($a.Meta.data.files.name) | Should -Be @($b.Meta.data.files.name)
    }
    It 'keeps MaxHtmlRows as an optional cap, and writes every row when it is 0' {
        $capped = LayoutReport @{ MaxHtmlRows = 2 }
        $h = Read-TestHtml $capped.HtmlPath -Summary
        foreach ($p in $h.Meta.datasets.PSObject.Properties) { $p.Value.rows | Should -BeLessOrEqual 2 -Because $p.Name }
        $h.Meta.datasets.sessions.total | Should -BeGreaterThan 2
        $all = LayoutReport @{ MaxHtmlRows = 0 }
        AssertEveryRow $all (Read-TestHtml $all.HtmlPath -Summary)
    }
    It 'warns in the log when MaxHtmlRows cut a table, and only then' {
        $dir = Join-Path $TestDrive 'layout-cap-log'
        $log = Start-ExlLog -Directory $dir
        try { $capped = LayoutReport @{ MaxHtmlRows = 200 } } finally { Stop-ExlLog }
        @($capped.HtmlCutTables) | Should -Contain ('sessions (200 of {0:N0} rows)' -f $capped.Counts['sessions'])
        $text = [IO.File]::ReadAllText($log)
        $text | Should -Match '\[WARN \] Report\.MaxHtmlRows = 200 cut the HTML tables .*sessions \(200 of [\d,]+ rows\).*Set Report\.MaxHtmlRows = 0 for every row.*200000'
        Remove-Item -LiteralPath $log
        $log = Start-ExlLog -Directory $dir
        try { $all = LayoutReport @{ MaxHtmlRows = 0 } } finally { Stop-ExlLog }
        @($all.HtmlCutTables).Count | Should -Be 0
        [IO.File]::ReadAllText($log) | Should -Not -Match 'MaxHtmlRows'
    }
    It 'replaces its own older data folder, and refuses a folder it did not write' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'own'; $q.HtmlLayout = 'Folder'
        $folder = Join-Path $q.OutputFolder 'ExchangeLogs_data'
        [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllText((Join-Path $folder '.exl-data'), "old`r`n")
        [IO.File]::WriteAllText((Join-Path $folder 'stray.js'), 'old')
        $r = BuildRequest $s $q
        Test-Path -LiteralPath (Join-Path $folder 'stray.js') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Not -Be 'old'
        # The same folder written as one file leaves no data folder behind.
        $q2 = LayoutRequest $s 'own'; $q2.HtmlLayout = 'SingleFile'
        [void](BuildRequest $s $q2)
        Test-Path -LiteralPath $folder | Should -BeFalse
        # A folder of that name without the marker is not touched.
        $q3 = LayoutRequest $s 'foreign'; $q3.HtmlLayout = 'Folder'
        $foreign = Join-Path $q3.OutputFolder 'ExchangeLogs_data'
        [void][IO.Directory]::CreateDirectory($foreign)
        [IO.File]::WriteAllText((Join-Path $foreign 'notes.txt'), 'mine')
        { BuildRequest $s $q3 } | Should -Throw '*not a report data folder*(it holds notes.txt)*'
        [IO.File]::ReadAllText((Join-Path $foreign 'notes.txt')) | Should -Be 'mine'
        @(Get-ChildItem -LiteralPath $q3.OutputFolder -Recurse -Force | Where-Object Name -Like '*.partial').Count | Should -Be 0
    }
    It 'replaces its own data folder that Explorer added desktop.ini or Thumbs.db to, and names any other entry' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'shell'; $q.HtmlLayout = 'Folder'
        $first = BuildRequest $s $q
        $folder = $first.HtmlDataFolder
        $ini = Join-Path $folder 'desktop.ini'
        [IO.File]::WriteAllText($ini, "[.ShellClassInfo]`r`n")
        [IO.File]::SetAttributes($ini, [IO.FileAttributes]'Hidden, System')
        [IO.File]::WriteAllText((Join-Path $folder 'Thumbs.db'), 'thumbs')
        # Explorer marks a folder it customised read-only.
        [IO.File]::SetAttributes($folder, [IO.FileAttributes]'ReadOnly, Directory')
        $q = LayoutRequest $s 'shell'; $q.HtmlLayout = 'Folder'
        $second = BuildRequest $s $q
        Test-Path -LiteralPath $ini | Should -BeFalse
        Test-Path -LiteralPath $folder | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be (Read-TestHtml $second.HtmlPath -Summary).Meta.data.id
        Test-Path -LiteralPath ($folder + '.previous') | Should -BeFalse
        # A read-only .partial folder left by an interrupted run is removed too.
        $partial = $folder + '.partial'
        [void][IO.Directory]::CreateDirectory($partial)
        [IO.File]::WriteAllText((Join-Path $partial 'desktop.ini'), "[.ShellClassInfo]`r`n")
        [IO.File]::SetAttributes((Join-Path $partial 'desktop.ini'), [IO.FileAttributes]'Hidden, System')
        [IO.File]::SetAttributes($partial, [IO.FileAttributes]'ReadOnly, Directory')
        $q = LayoutRequest $s 'shell'; $q.HtmlLayout = 'Folder'
        [void](BuildRequest $s $q)
        Test-Path -LiteralPath $partial | Should -BeFalse
        # The same marked folder with a file of the user is not replaced; the message names that file.
        [IO.File]::WriteAllText((Join-Path $folder 'desktop.ini'), "[.ShellClassInfo]`r`n")
        [IO.File]::WriteAllText((Join-Path $folder 'notes.txt'), 'mine')
        $q = LayoutRequest $s 'shell'; $q.HtmlLayout = 'Folder'
        { BuildRequest $s $q } | Should -Throw '*not a report data folder*(it holds notes.txt)*'
        [IO.File]::ReadAllText((Join-Path $folder 'notes.txt')) | Should -Be 'mine'
        Test-Path -LiteralPath (Join-Path $folder 'desktop.ini') | Should -BeTrue
    }
    It 'keeps the previous report and its data folder intact when a second build fails' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'rerun'; $q.HtmlLayout = 'Folder'
        $first = BuildRequest $s $q
        $folder = $first.HtmlDataFolder
        $id = (Read-TestHtml $first.HtmlPath -Summary).Meta.data.id
        $before = @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        $pageBefore = (Get-FileHash -LiteralPath $first.HtmlPath -Algorithm SHA256).Hash
        # A directory in place of the page's work file makes the second build fail once its data files are written.
        $blocker = $first.HtmlPath + '.partial'
        [void][IO.Directory]::CreateDirectory($blocker)
        try {
            $q = LayoutRequest $s 'rerun'; $q.HtmlLayout = 'Folder'
            { BuildRequest $s $q } | Should -Throw
        } finally { [IO.Directory]::Delete($blocker) }
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be $id
        @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) | Should -Be $before
        (Get-FileHash -LiteralPath $first.HtmlPath -Algorithm SHA256).Hash | Should -Be $pageBefore
        AssertManifest $first (Read-TestHtml $first.HtmlPath -Summary)
        @(Get-ChildItem -LiteralPath (Split-Path $first.HtmlPath) -Recurse -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.previous' }).Count | Should -Be 0
    }
    It 'keeps the earlier data folder whole when one of its files is held open without delete sharing' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'held'; $q.HtmlLayout = 'Folder'
        $first = BuildRequest $s $q
        $folder = $first.HtmlDataFolder
        $id = (Read-TestHtml $first.HtmlPath -Summary).Meta.data.id
        $before = @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        # An indexer or a scanner holding one .js open: the folder can be neither renamed nor deleted.
        $js = @(Get-ChildItem -LiteralPath $folder -Filter '*.js' | Sort-Object Name)[-1].FullName
        $handle = [IO.File]::Open($js, 'Open', 'Read', 'None')
        try {
            $q = LayoutRequest $s 'held'; $q.HtmlLayout = 'Folder'
            { BuildRequest $s $q } | Should -Throw
        } finally { $handle.Dispose() }
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be $id
        @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) | Should -Be $before
        AssertManifest $first (Read-TestHtml $first.HtmlPath -Summary)
        @(Get-ChildItem -LiteralPath (Split-Path $first.HtmlPath) -Recurse -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.previous' }).Count | Should -Be 0
    }
    It 'puts the earlier data folder back when the page cannot be replaced after the swap' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'swap'; $q.HtmlLayout = 'Folder'
        $first = BuildRequest $s $q
        $folder = $first.HtmlDataFolder
        $id = (Read-TestHtml $first.HtmlPath -Summary).Meta.data.id
        $before = @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        # The earlier page open without delete sharing: the data folders are swapped, then the page cannot be replaced.
        $handle = [IO.File]::Open($first.HtmlPath, 'Open', 'Read', 'Read')
        try {
            $q = LayoutRequest $s 'swap'; $q.HtmlLayout = 'Folder'
            { BuildRequest $s $q } | Should -Throw
        } finally { $handle.Dispose() }
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be $id
        @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) | Should -Be $before
        AssertManifest $first (Read-TestHtml $first.HtmlPath -Summary)
        @(Get-ChildItem -LiteralPath (Split-Path $first.HtmlPath) -Recurse -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.previous' }).Count | Should -Be 0
    }
    It 'renames back the earlier data folder that a process stopped between the two renames left as .previous' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'killed'; $q.HtmlLayout = 'Folder'
        $first = BuildRequest $s $q
        $folder = $first.HtmlDataFolder
        $id = (Read-TestHtml $first.HtmlPath -Summary).Meta.data.id
        $before = @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        # The state a process stopped after its first rename leaves: the earlier data only under .previous.
        [IO.Directory]::Move($folder, $folder + '.previous')
        # A run that fails then keeps the earlier data under the real name, whole.
        $blocker = $first.HtmlPath + '.partial'
        [void][IO.Directory]::CreateDirectory($blocker)
        try {
            $q = LayoutRequest $s 'killed'; $q.HtmlLayout = 'Folder'
            { BuildRequest $s $q } | Should -Throw
        } finally { [IO.Directory]::Delete($blocker) }
        Test-Path -LiteralPath ($folder + '.previous') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be $id
        @(Get-ChildItem -LiteralPath $folder -Force | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) | Should -Be $before
        AssertManifest $first (Read-TestHtml $first.HtmlPath -Summary)
        # Next to a folder of the real name, .previous is the older one: a run removes it and replaces the folder.
        [void][IO.Directory]::CreateDirectory($folder + '.previous')
        [IO.File]::WriteAllText((Join-Path ($folder + '.previous') '.exl-data'), "older`r`n")
        $q = LayoutRequest $s 'killed'; $q.HtmlLayout = 'Folder'
        $second = BuildRequest $s $q
        (Get-Content -LiteralPath (Join-Path $folder '.exl-data'))[0] | Should -Be (Read-TestHtml $second.HtmlPath -Summary).Meta.data.id
        AssertManifest $second (Read-TestHtml $second.HtmlPath -Summary)
        @(Get-ChildItem -LiteralPath (Split-Path $first.HtmlPath) -Recurse -Force | Where-Object { $_.Name -like '*.partial' -or $_.Name -like '*.previous' }).Count | Should -Be 0
    }
    It 'writes the data files in the order the page opens the tables, summaries first' {
        $r = LayoutReport @{ HtmlLayout = 'Folder' }
        $files = @((Read-TestHtml $r.HtmlPath -Summary).Meta.data.files)
        $ranked = 'servers', 'daily', 'users', 'operations', 'authentication', 'smtpclients', 'smtpdestinations', 'sessions', 'issues', 'messages'
        $kinds = -join ($files | ForEach-Object { $_.kind })
        $kinds | Should -Match '^c+d+$'
        $rank = @($files | ForEach-Object { 1000 * [int]($_.kind -eq 'd') + $ranked.IndexOf($_.set) })
        $rank | Should -Not -Contain -1
        $rank | Should -Be @($rank | Sort-Object)
    }
    It 'validates the layout and the limit of a request' {
        $s = LayoutSettings @{}
        $q = LayoutRequest $s 'invalid'; $q.HtmlLayout = 'Both'
        { BuildRequest $s $q } | Should -Throw "*Report.HtmlLayout must be 'Auto', 'SingleFile' or 'Folder'*"
        $q = LayoutRequest $s 'invalid2'; $q.SingleFileMaxMB = 0
        { BuildRequest $s $q } | Should -Throw '*SingleFileMaxMB must be 1 to 4096*'
    }
    It 'ships a page that carries the loader, its messages and the memory guard' {
        # The page and its main script, as a static report copies them together.
        $template = (Get-Content -LiteralPath (Join-Path $script:Root 'templates\Report.template.html') -Raw) + (Get-Content -LiteralPath (Join-Path $script:Root 'templates\Report.template.js') -Raw)
        foreach ($text in '__exl.file', '__exl.push', 'was not found next to this page', 'belongs to another report', 'Load anyway', 'Try again', 'Version : 1.5.1') {
            $template | Should -Match ([regex]::Escape($text)) -Because $text
        }
        $template | Should -Not -Match 'x-exl-'
    }
    It 'ships a page that previews the first rows of the table that opens while it loads' {
        # The page and its main script, as a static report copies them together.
        $template = (Get-Content -LiteralPath (Join-Path $script:Root 'templates\Report.template.html') -Raw) + (Get-Content -LiteralPath (Join-Path $script:Root 'templates\Report.template.js') -Raw)
        foreach ($text in 'function showPreview', 'timing.preview = performance.now()', 'previewRows', 'previewPasses', 'Available when the table is complete', 'filters, sort, search and export open when the table is complete') {
            $template | Should -Match ([regex]::Escape($text)) -Because $text
        }
    }
}

Describe 'Report review corrections' {
    BeforeAll {
        if (-not ('ReportReviewFixtures' -as [type])) { Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ReportReviewFixtures.cs') }
        function ReviewSettings([string]$Name) {
            $s = Import-ExlConfiguration -Path (New-TestConfig (Join-Path $TestDrive $Name)) -Root $script:Root
            [void](Invoke-TestCollection $s)
            $s.Report.Formats = @('Html')
            $s.Report.MaxHtmlRows = 1
            return $s
        }
        function ReviewRequest($Settings, [string]$Name = 'review') {
            $q = [ExchangeLogReport.ReportRequest]::new()
            $q.StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds()
            $q.EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds()
            $q.Zone = $Settings.Zone
            $q.ConfiguredServers = [string[]]@($Settings.Servers.Name)
            $q.TemplatePath = $Settings.Report.TemplatePath
            $q.OutputFolder = Join-Path $Settings.Report.OutputPath $Name
            $q.Detailed = $true
            $q.WriteCsv = $false
            $q.MaxHtmlRows = 1
            return $q
        }
        function ReviewRows([string]$Path) { (Read-TestHtml $Path).Sets }
    }
    It 'normalizes drive and UNC paths for SQLite without doubling an extended prefix' {
        $method = [ExchangeLogReport.Store].GetMethod('SqlitePath', [Reflection.BindingFlags]'Static,NonPublic')
        $local = [IO.Path]::GetFullPath((Join-Path $TestDrive 'native.sqlite'))
        $method.Invoke($null, @($local)) | Should -Be ('\\?\' + $local)
        $method.Invoke($null, @('\\?\' + $local)) | Should -Be ('\\?\' + $local)
        $method.Invoke($null, @('\\server.example.test\share\folder\db.sqlite')) |
            Should -Be '\\?\UNC\server.example.test\share\folder\db.sqlite'
        $method.Invoke($null, @('\\?\UNC\server.example.test\share\folder\db.sqlite')) |
            Should -Be '\\?\UNC\server.example.test\share\folder\db.sqlite'
    }
    It 'collects and exports complete reports with database and work paths longer than MAX_PATH' {
        $s = Import-ExlConfiguration -Path (New-TestConfig (Join-Path $TestDrive 'long-path-report')) -Root $script:Root
        $folder = Join-Path $TestDrive 'long paths with spaces'
        while ($folder.Length -lt 300) { $folder = Join-Path $folder 'nested folder with spaces' }
        [void][IO.Directory]::CreateDirectory($folder)
        $s.Storage.DatabasePath = Join-Path $folder 'source.sqlite'
        $s.Storage.DatabasePath.Length | Should -BeGreaterThan 260
        $s.Collection.Parallelism = 2
        $collection = Invoke-TestCollection $s
        $collection.Errors | Should -Be 0
        $collection.Statistics | Should -Match '2 parse thread'
        $s.Report.OutputPath = Join-Path $folder 'reports'
        $q = ReviewRequest $s
        $q.OutputFolder.Length | Should -BeGreaterThan 260
        $q.WriteCsv = $true
        $q.MaxHtmlRows = 200000
        $store = Open-ExlStore -Settings $s -ReadOnly
        try {
            $hash = (Get-FileHash -LiteralPath $s.Storage.DatabasePath).Hash
            $report = [ExchangeLogReport.ReportBuilder]::Build($store, $q)
            (Get-FileHash -LiteralPath $s.Storage.DatabasePath).Hash | Should -Be $hash
        } finally { $store.Dispose() }
        $report.StagedRows | Should -BeGreaterThan 0
        foreach ($file in $report.Files) { $file.Bytes | Should -BeGreaterThan 0 }
        $messages = @(Import-Csv -LiteralPath (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';')
        $messages.Count | Should -Be 3
        $messages.'Message ID' | Should -Contain '<msg-001@contoso.test>'
        $rows = ReviewRows $report.HtmlPath
        $rows.messages.Count | Should -Be 3
        $rows.sessions.Count | Should -Be $report.Counts['sessions']
        @(Get-ChildItem -LiteralPath $report.Folder -Force -Filter '.report-*.tmp*').Count | Should -Be 0
    }
    It 'returns independent samples and releases their registered buffers' {
        [ReportReviewFixtures]::IndependentSamplesAndRelease([ExchangeLogReport.ReportRequest], $TestDrive) | Should -BeTrue
    }
    It 'sorts explicit UTC keys identically in memory and on disk' {
        [ReportReviewFixtures]::SortUtc([ExchangeLogReport.ReportRequest], $TestDrive, $false) | Should -Be @(30L, 10L)
        [ReportReviewFixtures]::SortUtc([ExchangeLogReport.ReportRequest], $TestDrive, $true) | Should -Be @(30L, 10L)
    }
    It 'preserves a consumer error while draining and exposing another worker failure' {
        $messages = [ReportReviewFixtures]::WorkerAndConsumerFailures([ExchangeLogReport.ReportRequest], $TestDrive)
        $messages | Should -Be @('primary consumer failure', 'secondary worker failure')
    }
    It 'does not decode unshown message transcripts or sort them into scratch' {
        $s = ReviewSettings 'deferred-transcripts'
        $store = Open-ExlStore -Settings $s
        $t = $script:Base.ToUnixTimeMilliseconds()
        try {
            $store.Exec("DELETE FROM smtp_transaction; DELETE FROM message_event; DELETE FROM client_session; DELETE FROM session_step;")
            $store.Exec(@"
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100)
INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,subject,log_id)
SELECT $t+x*1000,'EXCH01','DELIVER','<defer-'||x||'@test>','sender@example.test','recipient@example.test','Subject','defer-'||x FROM n;
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100)
INSERT INTO smtp_transaction(time_ms,server,direction,role,session_id,message_id,status,transcript)
SELECT $t+x*1000,'EXCH01','Send','Hub','defer-'||x,'<defer-'||x||'@test>','Sent','Trace '||x||':'||hex(zeroblob(65536)) FROM n;
"@)
        } finally { $store.Dispose() }
        $q = ReviewRequest $s
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $report.Counts['messages'] | Should -Be 100
        $report.TranscriptReads | Should -Be 1
        $report.ScratchPeakBytes | Should -BeLessThan 1MB
        $rows = ReviewRows $report.HtmlPath
        $rows.messages[0][17][0][3] | Should -BeLike 'Trace 1:*'
        $rows.messages[0][17][0][3].Length | Should -BeGreaterThan 100000
        $q.OutputFolder = Join-Path $s.Report.OutputPath 'csv-only'
        $q.WriteCsv = $true; $q.WriteHtml = $false
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $csv = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $csv.TranscriptReads | Should -Be 100
        $csv.ScratchPeakBytes | Should -BeLessThan 1MB
        @(Import-Csv (Join-Path $csv.Folder 'ExchangeLogs-SmtpSessions.csv') -Delimiter ';').Count | Should -Be 100
    }
    It 'keeps all source statements on one snapshot during a concurrent write' {
        $s = ReviewSettings 'report-snapshot'
        $q = ReviewRequest $s
        $q.WriteCsv = $true
        $writer = Open-ExlStore -Settings $s
        $source = Open-ExlStore -Settings $s -ReadOnly
        $t = $script:Base.ToUnixTimeMilliseconds()
        $initial = $writer.Query('SELECT COUNT(*) FROM smtp_transaction;', $null).Rows[0][0]
        $code = { param($stage)
            if ($stage -eq 'CSV exports') {
                $writer.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,status) VALUES($t,'EXCH01','Receive','snapshot-new','Accepted');")
            }
        }.GetNewClosure()
        $q.Progress = [Action[string]]$code
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose(); $writer.Dispose() }
        $report.Counts['smtp'] | Should -Be $initial
        ($report.Files | Where-Object Dataset -EQ 'smtp').Rows | Should -Be $initial
        (Query $s 'SELECT COUNT(*) FROM smtp_transaction;')[0][0] | Should -Be ($initial + 1)
    }
    It 'skips session reconstruction in a Detailed Edge report' {
        $s = ReviewSettings 'edge-no-sessions'
        $q = ReviewRequest $s
        $q.Edge = $true; $q.EdgeServers = $q.ConfiguredServers
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("UPDATE session_step SET data='{}';") }
        finally { $store.Dispose() }
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $report.Counts.ContainsKey('sessions') | Should -BeFalse
        @($report.Steps | Where-Object { $_ -like '*LEFT JOIN session_step*' }).Count | Should -Be 0
    }
    It 'refuses malformed timeline JSON without a success-shaped partial timeline' {
        $s = ReviewSettings 'bad-session-json'
        $store = Open-ExlStore -Settings $s
        try { $store.Exec("UPDATE session_step SET data='[';") }
        finally { $store.Dispose() }
        $q = ReviewRequest $s
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { { [ExchangeLogReport.ReportBuilder]::Build($source, $q) } | Should -Throw '*Malformed client session timeline JSON*' }
        finally { $source.Dispose() }
    }
    It 'orders messages and route steps by UTC milliseconds across the repeated Paris hour' {
        $s = ReviewSettings 'dst-order'
        $first = ([DateTimeOffset]'2026-10-25T00:30:00.100Z').ToUnixTimeMilliseconds()
        $second = ([DateTimeOffset]'2026-10-25T01:10:00.100Z').ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("DELETE FROM smtp_transaction; DELETE FROM message_event; DELETE FROM client_session; DELETE FROM session_step;")
            $store.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,log_id) VALUES
 ($first,'EXCH01','RECEIVE','<z-first@test>','sender@example.test','recipient@example.test','dst-first'),
 ($first+100,'EXCH01','SUBMIT','<z-first@test>','sender@example.test','recipient@example.test','dst-submit'),
 ($first+200,'EXCH01','DELIVER','<z-first@test>','sender@example.test','recipient@example.test','dst-deliver'),
 ($second,'EXCH01','DELIVER','<a-second@test>','sender@example.test','recipient@example.test','dst-second');
"@)
        } finally { $store.Dispose() }
        $q = ReviewRequest $s
        $q.StartMs = $first - 1000; $q.EndMs = $second + 1000; $q.MaxHtmlRows = 10
        $q.WriteCsv = $true
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $messages = @(Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';')
        $messages.'Message ID' | Should -Be @('<z-first@test>', '<a-second@test>')
        $messages[0].Route | Should -Match 'RECEIVE(.|\n)*SUBMIT(.|\n)*DELIVER'
        $rows = ReviewRows $report.HtmlPath
        @($rows.messages[0][16] | ForEach-Object { $_[3] }) | Should -Be @('RECEIVE', 'SUBMIT', 'DELIVER')
    }
    It 'retains Unicode case-insensitive correlation without a custom collation in source queries' {
        $s = ReviewSettings 'unicode-message-ids'
        $q = ReviewRequest $s
        $q.MaxHtmlRows = 100; $q.WriteCsv = $true
        $t = $script:Base.ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,log_id) VALUES
 ($t,'EXCH01','RECEIVE','<ID-É@Test>','sender@example.test','recipient@example.test','unicode-1'),
 ($t+1000,'EXCH01','DELIVER','<id-é@test>','sender@example.test','recipient@example.test','unicode-2');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,transcript) VALUES
 ($t,'EXCH01','Receive','unicode-1','<ID-É@Test>','Accepted','First transcript'),
 ($t+1000,'EXCH01','Send','unicode-2','<id-é@test>','Sent','Second transcript');
"@)
        } finally { $store.Dispose() }
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $messages = @(Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' |
            Where-Object 'Message ID' -In @('<ID-É@Test>', '<id-é@test>'))
        $messages.Count | Should -Be 2
        foreach ($message in $messages) { $message.'SMTP sessions' | Should -Be '2' }
        @($report.Steps | Where-Object { $_ -like '*COLLATE EXL_REPORT_ID*' }).Count | Should -Be 0
        $rows = ReviewRows $report.HtmlPath
        foreach ($row in @($rows.messages | Where-Object { $_[15] -in @('<ID-É@Test>', '<id-é@test>') })) { $row[17].Count | Should -Be 2 }
    }
    It 'keeps refused mail of the same millisecond in the order 2.x read it (rowid, not server)' {
        $s = ReviewSettings 'refused-order'
        $q = ReviewRequest $s
        $q.MaxHtmlRows = 100; $q.WriteCsv = $true
        $t = $script:Base.ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("DELETE FROM smtp_transaction; DELETE FROM message_event;")
            # Same millisecond; the server and the status sort the opposite way to the rowid.
            $store.Exec(@"
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,mail_from,status,response) VALUES
 ($t,'EXCH02','Receive','refused-1','b@example.test','Rejected','550 5.7.1 relay denied'),
 ($t,'EXCH01','Receive','refused-2','a@example.test','Deferred','451 4.7.0 try later'),
 ($t,'EXCH03','Receive','refused-3','c@example.test','Deferred','451 4.7.0 try later'),
 ($t+1000,'EXCH01','Receive','refused-4','d@example.test','Rejected','550 5.7.1 relay denied');
"@)
        } finally { $store.Dispose() }
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $messages = @(Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';')
        $messages.Sender | Should -Be @('b@example.test', 'a@example.test', 'c@example.test', 'd@example.test')
    }
    It 'writes the sessions report from session_step rows in time order, under the session id' {
        $s = ReviewSettings 'session-steps'
        $q = ReviewRequest $s
        $q.MaxHtmlRows = 100; $q.WriteCsv = $true
        $t = $script:Base.ToUnixTimeMilliseconds()
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("DELETE FROM client_session; DELETE FROM session_step;")
            # Two sessions starting in the same millisecond (ids 7 then 5 inserted); session 5 was written by two batches, the later one first.
            foreach ($id in 7, 5) {
                $store.Exec("INSERT INTO client_session(id,skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out) VALUES($id,'k$id','d',$t,$($t+9000),'contoso\sess$id','Mapi',2,2,0,0,$t,$($t+9000),0,0,20,10,0,0);")
            }
            $step = { param($at, $action) "[[$at,$at,`"EXCH01`",null,`"$action`",200,1,10,10,0,null,null,`"FE`",false,0,null,null]]" }
            $store.Exec("INSERT INTO session_step(session_id,time_ms,data) VALUES(5,$($t+5000),'$(& $step ($t+5000) 'Second')'),(5,$t,'$(& $step $t 'First')'),(7,$t,'$(& $step $t 'Only')');")
        } finally { $store.Dispose() }
        $source = Open-ExlStore -Settings $s -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
        finally { $source.Dispose() }
        $sessions = @(Import-Csv (Join-Path $report.Folder 'ExchangeLogs-ClientSessions.csv') -Delimiter ';')
        $sessions.'Session ID' | Should -Be @('5', '7')
        $sessions[0].Timeline.IndexOf('First') | Should -BeLessThan $sessions[0].Timeline.IndexOf('Second')
        $sessions[0].Timeline | Should -Not -Match 'Only'
        $sessions[1].Timeline | Should -Match 'Only'
    }

    Context 'Message status' {
        BeforeAll {
            $script:StatusRows = @{}
            $s = ReviewSettings 'message-status'
            $q = ReviewRequest $s 'message-status'
            $q.MaxHtmlRows = 100; $q.WriteCsv = $true
            $t = $script:Base.ToUnixTimeMilliseconds()
            $script:n = 0
            # One tracking event per row: offset in seconds, event, recipients, recipient-status text, related recipient, server, connector, next host.
            $rows = [System.Collections.Generic.List[string]]::new()
            function Ev([string]$Id, [int]$At, [string]$Event, [string]$Rcpts, [string]$Status = $null, [string]$Related = $null, [string]$Server = 'EXCH01',
                [string]$Connector = $null, [string]$Peer = $null) {
                $script:n++
                $sql = { param($v) if ($null -eq $v -or $v -eq '') { 'NULL' } else { "'" + ($v -replace "'", "''") + "'" } }
                $rows.Add("($($t + $At * 1000 + $script:n),'$Server','$Event','<$Id@test>','sender@contoso.test',$(& $sql $Rcpts),$(& $sql $Status),$(& $sql $Related),'SMTP','status-$($script:n)',$(& $sql $Connector),$(& $sql $Peer))")
            }
            $expanded = '250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded'
            Ev 'dl-1' 1 RECEIVE 'dl@contoso.test'
            Ev 'dl-1' 2 EXPAND 'a@contoso.test;b@contoso.test;c@contoso.test' $null 'dl@contoso.test'
            Ev 'dl-1' 3 DROP 'dl@contoso.test' $expanded
            Ev 'dl-1' 4 DELIVER 'a@contoso.test'; Ev 'dl-1' 5 DELIVER 'b@contoso.test'; Ev 'dl-1' 6 DELIVER 'c@contoso.test'
            Ev 'dl-empty' 1 RECEIVE 'ping@contoso.test'
            Ev 'dl-empty' 2 EXPAND $null $null 'ping@contoso.test'
            Ev 'dl-empty' 3 DROP 'ping@contoso.test' $expanded
            Ev 'dl-late' 1 EXPAND $null $null 'dl2@contoso.test'
            Ev 'dl-late' 2 REDIRECT 'm1@contoso.test;m2@contoso.test' $null 'dl2@contoso.test'
            Ev 'dl-late' 3 DROP 'dl2@contoso.test' $expanded
            Ev 'dl-late' 4 DELIVER 'm1@contoso.test'; Ev 'dl-late' 5 DELIVER 'm2@contoso.test'
            Ev 'oof' 1 RECEIVE 'x@contoso.test'
            Ev 'oof' 2 DROP 'x@contoso.test' '250 2.1.5 RESOLVER.OOF.IntToExt; out-of-office not sent'
            Ev 'mixed' 1 RECEIVE 'a@contoso.test;b@contoso.test'
            Ev 'mixed' 2 DELIVER 'a@contoso.test'
            Ev 'mixed' 3 DROP 'b@contoso.test' '250 2.1.5 RESOLVER.MSGTYPE.AF; auto-forward blocked'
            Ev 'meeting' 1 RECEIVE 'p@contoso.test'
            Ev 'meeting' 2 DROP 'p@contoso.test' '250 2.1.5 RESOLVER.MER.Suppressed; recipient suppressed'
            Ev 'rule' 1 RECEIVE 'r@contoso.test'
            Ev 'rule' 2 DROP 'r@contoso.test' '250 2.1.5 StoreDriver.Rules; deleted by a mailbox rule'
            Ev 'agent' 1 RECEIVE 'a@contoso.test'
            Ev 'agent' 2 DROP 'a@contoso.test' 'QUEUE.TransportAgent; dropped by an agent'
            Ev 'agent' 3 DELIVER 'a@contoso.test'
            Ev 'multi-drop' 1 EXPAND 'g1m@contoso.test' $null 'g1@contoso.test'
            Ev 'multi-drop' 2 EXPAND 'g2m@contoso.test' $null 'g2@contoso.test'
            Ev 'multi-drop' 3 DROP 'g1@contoso.test;g2@contoso.test;u@contoso.test' "'250 2.1.5 RESOLVER.GRP.Expanded; x';'250 2.1.5 RESOLVER.GRP.Expanded; y';550 5.1.1 RESOLVER.ADR.RecipientNotFound"
            Ev 'multi-drop' 4 DELIVER 'g1m@contoso.test'; Ev 'multi-drop' 5 DELIVER 'g2m@contoso.test'
            Ev 'relay' 1 RECEIVE 'a@contoso.test;b@contoso.test'
            Ev 'relay' 2 DELIVER 'a@contoso.test'
            Ev 'relay' 3 SEND 'b@contoso.test'
            Ev 'handed' 1 RECEIVE 'h@contoso.test'
            Ev 'handed' 2 SEND 'h@contoso.test'
            # Mail that left the organization: SENDEXTERNAL through a Send connector to a server that is not collected, accepted by it, for a recipient
            # of a domain that is not ours (contoso.test is ours: the collection of the fixture delivered and sent its mail).
            $postfix = 'To Internet via Postfix'
            Ev 'ext-1' 1 RECEIVE 'a@contoso.test;partner@fabrikam.example'
            Ev 'ext-1' 2 DELIVER 'a@contoso.test'
            Ev 'ext-1' 3 SENDEXTERNAL 'partner@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 $postfix '203.0.113.5'
            Ev 'ext-2' 1 RECEIVE 'partner@fabrikam.example'
            Ev 'ext-2' 2 SENDEXTERNAL 'partner@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 $postfix '203.0.113.5'
            Ev 'intra' 1 RECEIVE 'h2@contoso.test'
            Ev 'intra' 2 SEND 'h2@contoso.test' '250 2.1.5 Recipient OK' $null EXCH01 'Intra-Organization SMTP Send Connector' 'EXCH03.contoso.test'
            Ev 'remote' 1 RECEIVE 'erin@contoso.test'
            Ev 'remote' 2 SENDEXTERNAL 'erin@contoso.test' '250 2.1.5 Recipient OK' $null EXCH01 'Outbound to Office 365' 'contoso-test.mail.protection.outlook.com'
            Ev 'journal' 1 SENDEXTERNAL 'partner@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 'Journal archive' '203.0.113.7'
            Ev 'refused' 1 SENDEXTERNAL 'partner@fabrikam.example' '421 4.4.2 Connection dropped' $null EXCH01 $postfix '203.0.113.5'
            Ev 'no-domain' 1 SENDEXTERNAL 'postmaster' '250 2.1.5 Ok' $null EXCH01 $postfix '203.0.113.5'
            Ev 'collected' 1 SENDEXTERNAL 'partner@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 $postfix 'EXCH02.contoso.test'
            Ev 'mixed-ext' 1 RECEIVE 'p1@fabrikam.example;h3@contoso.test'
            Ev 'mixed-ext' 2 SENDEXTERNAL 'p1@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 $postfix '203.0.113.5'
            Ev 'mixed-ext' 3 SEND 'h3@contoso.test' '250 2.1.5 Recipient OK' $null EXCH01 'Intra-Organization SMTP Send Connector' 'EXCH03.contoso.test'
            Ev 'mixed-ext-d' 1 RECEIVE 'd@contoso.test;p1@fabrikam.example;h3@contoso.test'
            Ev 'mixed-ext-d' 2 DELIVER 'd@contoso.test'
            Ev 'mixed-ext-d' 3 SENDEXTERNAL 'p1@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 $postfix '203.0.113.5'
            Ev 'mixed-ext-d' 4 SEND 'h3@contoso.test' '250 2.1.5 Recipient OK' $null EXCH01 'Intra-Organization SMTP Send Connector' 'EXCH03.contoso.test'
            Ev 'two-ext' 1 SENDEXTERNAL 'p2@fabrikam.example;p3@northwind.example' '250 2.1.5 Ok;550 5.1.1 User unknown' $null EXCH01 $postfix '203.0.113.5'
            Ev 'no-connector' 1 SENDEXTERNAL 'partner@fabrikam.example' '250 2.1.5 Ok' $null EXCH01 $null '203.0.113.5'
            # A remote mailbox of a hybrid organization: the categorizer resolves it to its routing address in the tenant, and the connector of the
            # Hybrid Configuration Wizard hands it to Exchange Online.
            $hcw = 'Outbound to Office 365 - 6f1c8b4e-1d2a-4b5c-9e3f-0a1b2c3d4e5f'
            $queued = '250 2.6.0 <hybrid@test> [InternalId=1, Hostname=AM0PR01MB0001.eurprd01.prod.outlook.com] Queued mail for delivery'
            Ev 'hybrid' 1 RECEIVE 'erin2@contoso.test'
            Ev 'hybrid' 2 RESOLVE 'erin2@contoso.mail.onmicrosoft.com' $null 'erin2@contoso.test'
            Ev 'hybrid' 3 SENDEXTERNAL 'erin2@contoso.mail.onmicrosoft.com' $queued $null EXCH01 $hcw 'contoso-test.mail.protection.outlook.com'
            # The same routing address through a connector of the company to the internet: the connector decides, not the domain of the tenant.
            Ev 'hybrid-relay' 1 RECEIVE 'erin3@contoso.test'
            Ev 'hybrid-relay' 2 RESOLVE 'erin3@contoso.mail.onmicrosoft.com' $null 'erin3@contoso.test'
            Ev 'hybrid-relay' 3 SENDEXTERNAL 'erin3@contoso.mail.onmicrosoft.com' $queued $null EXCH01 $postfix '203.0.113.5'
            $store = Open-ExlStore -Settings $s
            try {
                $store.Exec("DELETE FROM smtp_transaction; DELETE FROM message_event; DELETE FROM client_session; DELETE FROM session_step;")
                $store.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,recipient_status,related_recipient,source,log_id,connector,server_host) VALUES`n" + ($rows -join ",`n") + ';')
                # The rules of the collection with one connector of the company that stays inside (Collection.InternalConnectors).
                $script:StatusRules = $store.ReadMailFlowRules()
                $rules = $script:StatusRules.WithConfiguration($script:StatusRules.InternalDomains, [string[]]@('^Journal'), $null)
                $store.Exec("UPDATE metadata SET value='$($rules.RulesText())' WHERE key='mailflow_rules';")
            } finally { $store.Dispose() }
            $store = Open-ExlStore -Settings $s
            try {
                $store.RefreshServeRollups()
                $script:StatusRollups = @{}
                foreach ($r in $store.Query("SELECT r.identity,v.text,r.recipients FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0;", $null).Rows) { $script:StatusRollups[$r[0]] = $r }
                $script:StatusVerified = $store.VerifyServeRollups().Verified
            } finally { $store.Dispose() }
            $source = Open-ExlStore -Settings $s -ReadOnly
            try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
            finally { $source.Dispose() }
            foreach ($m in Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';') { $script:StatusRows[$m.'Message ID'] = $m }
            # The same rows without any known domain (no external status): only the status and the recipients of the external mail change.
            $store = Open-ExlStore -Settings $s
            try { $store.Exec("UPDATE metadata SET value='' WHERE key='mailflow_accepted_domains';") } finally { $store.Dispose() }
            $q.OutputFolder = $q.OutputFolder + '-nodomain'
            $source = Open-ExlStore -Settings $s -ReadOnly
            try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
            finally { $source.Dispose() }
            $script:NoDomainRows = @{}
            foreach ($m in Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';') { $script:NoDomainRows[$m.'Message ID'] = $m }
        }
        It 'marks the distribution list, not its members, as expanded' {
            $m = $script:StatusRows['<dl-1@test>']
            $m.Status | Should -Be 'Delivered'
            $m.'Recipient count' | Should -Be '3'
            $m.Delivered | Should -Be '3'
            $m.Recipients | Should -Be 'a@contoso.test; b@contoso.test; c@contoso.test; dl@contoso.test (Expanded)'
            $m.Events | Should -Be 'RECEIVE > EXPAND > DELIVER'
        }
        It 'suppresses an empty distribution list by design' {
            $m = $script:StatusRows['<dl-empty@test>']
            $m.Status | Should -Be 'Suppressed (by design)'
            $m.Recipients | Should -Be 'ping@contoso.test (Suppressed)'
            $m.Delivered | Should -Be '0'
            $m.Failed | Should -Be '0'
        }
        It 'does not call a list empty when its members arrive later' {
            $m = $script:StatusRows['<dl-late@test>']
            $m.Status | Should -Be 'Delivered'
            $m.Recipients | Should -Be 'm1@contoso.test; m2@contoso.test; dl2@contoso.test (Expanded)'
        }
        It 'counts suppressed recipients as neither dropped nor delivered' {
            $script:StatusRows['<oof@test>'].Status | Should -Be 'Suppressed (by design)'
            $script:StatusRows['<meeting@test>'].Status | Should -Be 'Suppressed (by design)'
            $m = $script:StatusRows['<mixed@test>']
            $m.Status | Should -Be 'Delivered'
            $m.Recipients | Should -Be 'a@contoso.test; b@contoso.test (Suppressed)'
            $m.Delivered | Should -Be '1'
        }
        It 'keeps real drops dropped and lets a later delivery win' {
            $script:StatusRows['<rule@test>'].Status | Should -Be 'Dropped'
            $script:StatusRows['<agent@test>'].Status | Should -Be 'Delivered'
            $m = $script:StatusRows['<multi-drop@test>']
            $m.Status | Should -Be 'Partially dropped'
            $m.Recipients | Should -Be 'g1m@contoso.test; g2m@contoso.test; u@contoso.test (Dropped); g1@contoso.test (Expanded); g2@contoso.test (Expanded)'
        }
        It 'names mail handed off outside the collected logs' {
            $script:StatusRows['<relay@test>'].Status | Should -Be 'Delivered and handed off'
            $script:StatusRows['<relay@test>'].Recipients | Should -Be 'a@contoso.test; b@contoso.test (Handed off)'
            $script:StatusRows['<handed@test>'].Status | Should -Be 'Handed off outside collection'
        }
        It 'lists each event once, in order of first appearance' {
            $script:StatusRows['<agent@test>'].Events | Should -Be 'RECEIVE > DROP > DELIVER'
            $script:StatusRows['<relay@test>'].Events | Should -Be 'RECEIVE > DELIVER > SEND'
        }
        It 'names mail accepted by a server outside the organization sent to external' {
            $m = $script:StatusRows['<ext-1@test>']
            $m.Status | Should -Be 'Delivered and sent to external'
            $m.Recipients | Should -Be 'a@contoso.test; partner@fabrikam.example (Sent to external)'
            $m.Delivered | Should -Be '1'
            $m.Events | Should -Be 'RECEIVE > DELIVER > SENDEXTERNAL'
            $m = $script:StatusRows['<ext-2@test>']
            $m.Status | Should -Be 'Sent to external'
            $m.Recipients | Should -Be 'partner@fabrikam.example (Sent to external)'
            $m.Delivered | Should -Be '0'
            $m.Failed | Should -Be '0'
        }
        It 'keeps a hand-off when the logs do not prove that the mail left the organization (<Id>)' -ForEach @(
            @{ Id = 'intra'; Recipients = 'h2@contoso.test (Handed off)' }
            @{ Id = 'remote'; Recipients = 'erin@contoso.test (Handed off)' }
            @{ Id = 'journal'; Recipients = 'partner@fabrikam.example (Handed off)' }
            @{ Id = 'refused'; Recipients = 'partner@fabrikam.example (Handed off)' }
            @{ Id = 'no-domain'; Recipients = 'postmaster (Handed off)' }
            @{ Id = 'collected'; Recipients = 'partner@fabrikam.example (Handed off)' }
            @{ Id = 'no-connector'; Recipients = 'partner@fabrikam.example (Handed off)' }) {
            $m = $script:StatusRows["<$Id@test>"]
            $m.Status | Should -Be 'Handed off outside collection'
            $m.Recipients | Should -Be $Recipients
        }
        It 'keeps the mail to a mailbox of the organization in Exchange Online a hand-off (hybrid routing address)' {
            $m = $script:StatusRows['<hybrid@test>']
            $m.Status | Should -Be 'Handed off outside collection'
            $m.Recipients | Should -Be 'erin2@contoso.mail.onmicrosoft.com (Handed off); erin2@contoso.test (Resolved)'
            $m.Events | Should -Be 'RECEIVE > RESOLVE > SENDEXTERNAL'
            $m = $script:StatusRows['<hybrid-relay@test>']
            $m.Status | Should -Be 'Sent to external'
            $m.Recipients | Should -Be 'erin3@contoso.mail.onmicrosoft.com (Sent to external); erin3@contoso.test (Resolved)'
        }
        It 'names each recipient of a message handed off in part outside the organization' {
            $m = $script:StatusRows['<mixed-ext@test>']
            $m.Status | Should -Be 'Handed off outside collection'
            $m.Recipients | Should -Be 'p1@fabrikam.example (Sent to external); h3@contoso.test (Handed off)'
            $m = $script:StatusRows['<mixed-ext-d@test>']
            $m.Status | Should -Be 'Delivered and handed off'
            $m.Recipients | Should -Be 'd@contoso.test; p1@fabrikam.example (Sent to external); h3@contoso.test (Handed off)'
            # One reply per recipient: the refused one stays a hand-off.
            $m = $script:StatusRows['<two-ext@test>']
            $m.Status | Should -Be 'Handed off outside collection'
            $m.Recipients | Should -Be 'p2@fabrikam.example (Sent to external); p3@northwind.example (Handed off)'
        }
        It 'gives the message rollups the status of the report, verified by recomputation' {
            $script:StatusVerified | Should -BeTrue
            foreach ($id in $script:StatusRows.Keys) {
                $script:StatusRollups[$id][1] | Should -Be $script:StatusRows[$id].Status -Because $id
                (($script:StatusRollups[$id][2] | ConvertFrom-Json) -join '; ') | Should -Be $script:StatusRows[$id].Recipients -Because $id
            }
        }
        It 'changes only the status and the recipients of the external mail, never its route' {
            $script:StatusRules.LearnedDomains | Should -Contain 'contoso.test'
            $script:NoDomainRows['<ext-1@test>'].Status | Should -Be 'Delivered and handed off'
            $script:NoDomainRows['<ext-2@test>'].Status | Should -Be 'Handed off outside collection'
            $script:NoDomainRows['<ext-2@test>'].Recipients | Should -Be 'partner@fabrikam.example (Handed off)'
            foreach ($id in $script:StatusRows.Keys) {
                $a = $script:StatusRows[$id]; $b = $script:NoDomainRows[$id]
                foreach ($p in $a.PSObject.Properties.Name) {
                    if ($p -in 'Status', 'Recipients') { continue }
                    $b.$p | Should -BeExactly $a.$p -Because "$id $p"
                }
            }
        }
    }

    Context 'Message route' {
        BeforeAll {
            $s = ReviewSettings 'message-route'
            $q = ReviewRequest $s 'message-route'
            $q.MaxHtmlRows = 100; $q.WriteCsv = $true
            $t = $script:Base.ToUnixTimeMilliseconds()
            $script:n = 0
            $quote = { param($v) if ($null -eq $v -or $v -eq '') { 'NULL' } else { "'" + ($v -replace "'", "''") + "'" } }
            $tracking = [System.Collections.Generic.List[string]]::new()
            $smtp = [System.Collections.Generic.List[string]]::new()
            # One tracking event: offset in seconds, event, recipients, recipient status, related recipient, server, internal id, source, client host, next host, connector.
            function Ev([string]$Id, [int]$At, [string]$Event, [string]$Rcpts, [string]$Status = $null, [string]$Related = $null, [string]$Server = 'EXCH02',
                [string]$Internal = $null, [string]$Source = 'SMTP', [string]$Client = $null, [string]$Peer = $null, [string]$Connector = $null) {
                $script:n++
                $tracking.Add("($($t + $At * 1000 + $script:n),'$Server','$Event','<$Id@test>','sender@contoso.test',$(& $quote $Rcpts),$(& $quote $Status),$(& $quote $Related),'$Source',$(& $quote $Internal),$(& $quote $Client),$(& $quote $Peer),$(& $quote $Connector),'route-$($script:n)')")
            }
            function Conv([string]$Id, [int]$At, [string]$Server, [string]$Direction, [string]$Role, [string]$Internal, [string]$Status, [string]$Response, [string]$Helo = $null) {
                $script:n++
                $smtp.Add("($($t + $At * 1000),'$Server','$Direction','$Role','route-session-$($script:n)',$(& $quote $Id),$(& $quote $Internal),'$Status',$(& $quote $Response),$(& $quote $Helo))")
            }
            $queued = '250 2.6.0 <c-1@test> [InternalId=5001, Hostname=EXCH02.contoso.test] Queued mail for delivery'
            Conv '<c-1@test>' 0 EXCH01 Receive FrontEnd 5001 Accepted $queued
            Conv '<c-1@test>' 5 EXCH01 Send FrontEnd 5001 Sent $queued
            Ev 'c-1' 3 RECEIVE 'a@contoso.test;b@contoso.test;dl@contoso.test' $null $null EXCH02 5001 SMTP 'EXCH01.contoso.test'
            Ev 'c-1' 10 EXPAND 'm1@contoso.test;m2@contoso.test' $null 'dl@contoso.test' EXCH02 5001 ROUTING
            Ev 'c-1' 11 DROP 'dl@contoso.test' '250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded' $null EXCH02 5001 ROUTING
            Ev 'c-1' 12 AGENTINFO $null $null $null EXCH02 5001 AGENT
            Ev 'c-1' 20 RECEIVE 'a@contoso.test;m1@contoso.test' $null $null EXCH01 5002 SMTP 'EXCH02.contoso.test'
            Ev 'c-1' 20 SEND 'a@contoso.test;m1@contoso.test' '250 2.1.5 Recipient OK' $null EXCH02 5001 SMTP $null 'EXCH01.contoso.test' 'Intra-Org'
            Ev 'c-1' 20 SEND 'b@contoso.test' '250 2.1.5 Recipient OK' $null EXCH02 5001 SMTP $null 'EXCH03.contoso.test' 'Intra-Org'
            Ev 'c-1' 21 DELIVER 'a@contoso.test;m1@contoso.test' ';DefaultFolderType:JunkEmail' $null EXCH01 5002 STOREDRIVER
            foreach ($k in 1..5) { Ev 'c-1' (30 * $k) DEFER 'm2@contoso.test' '451 4.3.2 recipient thread limit exceeded' $null EXCH02 5001 SMTP $null $null 'Intra-Org' }
            Ev 'c-1' 200 DELIVER 'm2@contoso.test' $null $null EXCH02 5001 STOREDRIVER
            Ev 'c-1' 300 RECEIVE 'z@contoso.test' $null $null EXCH01 $null STOREDRIVER
            Ev 'c-1' 301 SUBMIT 'z@contoso.test' $null $null EXCH01 $null STOREDRIVER
            Ev 'c-1' 302 DELIVER 'z@contoso.test' $null $null EXCH01 $null STOREDRIVER
            # Conversations between two collected servers: a Hub receiving from EXCH02 (a leg of the submission, not a new one), and a Hub send
            # that no tracking RECEIVE answers (it follows the tracking SEND to EXCH03 of the same second).
            Conv '<c-1@test>' 20 EXCH01 Receive Hub $null Accepted $queued 'EXCH02.contoso.test'
            Conv '<c-1@test>' 20 EXCH02 Send Hub $null Sent '250 2.6.0 <c-1@test> [InternalId=9001, Hostname=EXCH03.contoso.test] Queued mail for delivery'
            # An Edge: the conversation from the internet starts the submission; the tracking RECEIVE of the same leg and the send to the organization follow it.
            Conv '<edge-1@test>' 0 EDGE01 Receive Edge 6001 Accepted '250 2.6.0 <edge-1@test> [InternalId=6001, Hostname=EDGE01.perimeter.test] Queued mail for delivery' 'mail.fabrikam.example'
            Ev 'edge-1' 1 RECEIVE 'alice@contoso.test' $null $null EDGE01 6001 SMTP 'mail.fabrikam.example'
            Ev 'edge-1' 2 SENDEXTERNAL 'alice@contoso.test' '250 2.6.0 Queued' $null EDGE01 6001 SMTP $null 'EXCH01.contoso.test' 'EdgeSync - Inbound'
            Conv '<edge-1@test>' 2 EDGE01 Send Edge 6001 Sent '250 2.6.0 <edge-1@test> [InternalId=9002, Hostname=EXCH01.contoso.test] Queued mail for delivery'
            # A list without member, a list expanded on another server, a hop received but not delivered, a duplicate delivery.
            Ev 'c-3' 1 RECEIVE 'dl0@contoso.test' $null $null EXCH01
            Ev 'c-3' 2 EXPAND $null $null 'dl0@contoso.test' EXCH01
            Ev 'c-3' 3 DROP 'dl0@contoso.test' '250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded' $null EXCH01
            Ev 'c-4' 1 RECEIVE 'dl9@contoso.test' $null $null EXCH01
            Ev 'c-4' 3 DROP 'dl9@contoso.test' '250 2.1.5 RESOLVER.GRP.Expanded; distribution list expanded' $null EXCH01
            Ev 'c-5' 1 SEND 'q@contoso.test' '250 2.1.5 Recipient OK' $null EXCH02 7001 SMTP $null 'EXCH01.contoso.test' 'Intra-Org'
            Ev 'c-5' 1 RECEIVE 'q@contoso.test' $null $null EXCH01 7002 SMTP 'EXCH02.contoso.test'
            Ev 'c-6' 1 RECEIVE 'v@contoso.test' $null $null EXCH01 8001
            Ev 'c-6' 2 DUPLICATEDELIVER 'v@contoso.test' $null $null EXCH01 8001 STOREDRIVER
            Ev 'c-2' 1 RECEIVE 'x@contoso.test' $null $null EXCH01
            foreach ($k in 1..3) { Ev 'c-2' (1 + $k) DROP 'x@contoso.test' 'QUEUE.TransportAgent; dropped by an agent' $null EXCH01 }
            # DELIVER status texts as Exchange writes them (one entry per recipient), and transport status texts that are not folders.
            $triple = '08DF1A2B3C4D5E6F;2026-10-22T08:15:30.1234567Z;ClientSubmitTime:2026-10-22T08:15:29.0000000Z'
            Ev 'fold-1' 1 DELIVER 'a@contoso.test' '250 2.0.0 Delivered' $null EXCH01 $null STOREDRIVER
            Ev 'fold-2' 1 DELIVER 'a@contoso.test;b@contoso.test;c@contoso.test' ';;Copies to me' $null EXCH01 $null STOREDRIVER
            Ev 'fold-3' 1 DELIVER 'a@contoso.test;b@contoso.test' "$triple;DefaultFolderType:JunkEmail" $null EXCH01 $null STOREDRIVER
            Ev 'fold-4' 1 DELIVER 'a@contoso.test' 'DefaultFolderType:DeletedItems;' $null EXCH01 $null STOREDRIVER
            Ev 'fold-5' 1 DELIVER 'a@contoso.test;b@contoso.test' "$triple;$triple" $null EXCH01 $null STOREDRIVER
            Ev 'fold-6' 1 DELIVER 'a@contoso.test;b@contoso.test' 'Alerts;00B. Project files' $null EXCH01 $null STOREDRIVER
            Ev 'fold-7' 1 DELIVER 'a@contoso.test' 'StoreDriver.Rules; moved by a rule' $null EXCH01 $null STOREDRIVER
            Ev 'fold-8' 1 DELIVER 'a@contoso.test' $triple $null EXCH01 $null STOREDRIVER
            Ev 'fold-9' 1 DELIVER 'a@contoso.test' '2026-10-22T08:15:30.123Z;ClientSubmitTime:2026-10-22T08:15:29.0000000Z' $null EXCH01 $null STOREDRIVER
            # A front-end conversation and the tracking RECEIVE it queued on the same server, without the same internal id (reply without it, or
            # another one), with it, and two entries of the same message from the same host a second apart.
            $full = [System.Collections.Generic.List[string]]::new()
            function Entry([string]$Id, [long]$Ms, [string]$Internal, [string]$Rcpts, [string]$Helo = 'mail1.partner.test', [string]$Status = 'Accepted',
                [string]$Response = "250 2.6.0 <$Id@test> [InternalId=$Internal, Hostname=EXCH01.contoso.test] Queued mail for delivery") {
                $script:n++
                $full.Add("($($t + $Ms),'EXCH01','Receive','FrontEnd','entry-session-$($script:n)','<$Id@test>',$(& $quote $Internal),'$Status',$(& $quote $Response),'$Helo','sender@contoso.test',$(& $quote $Rcpts),'198.51.100.7:41000')")
            }
            Ev 'pair-1' 500 RECEIVE 'p@contoso.test' $null $null EXCH01 'A1' SMTP 'mail1.partner.test'
            Entry 'pair-1' (500000 + 600) 'B1' 'p@contoso.test'
            Ev 'pair-2' 500 RECEIVE 'p@contoso.test' $null $null EXCH01 'A2' SMTP 'mail1.partner.test'
            Entry 'pair-2' (500000 + 600) 'A2' 'p@contoso.test'
            Ev 'pair-3' 600 RECEIVE 'r1@contoso.test' $null $null EXCH01 'A31' SMTP 'mail1.partner.test'
            Ev 'pair-3' 601 RECEIVE 'r2@contoso.test' $null $null EXCH01 'A32' SMTP 'mail1.partner.test'
            Entry 'pair-3' (600000 + 800) '771' 'r1@contoso.test'
            Entry 'pair-3' (601000 + 800) '772' 'r2@contoso.test'
            # A deferred attempt of the same host 30 s before the accepted retry; neither reply carries an internal id.
            Ev 'pair-4' 700 RECEIVE 'r4@contoso.test' $null $null EXCH01 'A4' SMTP 'mail1.partner.test'
            Entry 'pair-4' (700000 - 30600) $null 'r4@contoso.test' -Status 'Deferred' -Response '451 4.7.0 Temporary server error. Please try again later.'
            Entry 'pair-4' (700000 - 600) $null 'r4@contoso.test' -Response '250 2.6.0 <pair-4@test> Queued mail for delivery'
            $script:n++
            $smtp.Add("($($t + 400000),'EXCH01','Receive','FrontEnd','route-refused',NULL,NULL,'Rejected','550 5.1.1 RecipientNotFound',NULL)")
            $store = Open-ExlStore -Settings $s
            try {
                $store.Exec("DELETE FROM smtp_transaction; DELETE FROM message_event; DELETE FROM client_session; DELETE FROM session_step;")
                $store.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,recipient_status,related_recipient,source,internal_id,client_host,server_host,connector,log_id) VALUES`n" + ($tracking -join ",`n") + ';')
                $store.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,role,session_id,message_id,internal_id,status,response,helo) VALUES`n" + ($smtp -join ",`n") + ';')
                $store.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,role,session_id,message_id,internal_id,status,response,helo,mail_from,rcpts,remote_ep) VALUES`n" + ($full -join ",`n") + ';')
            } finally { $store.Dispose() }
            $source = Open-ExlStore -Settings $s -ReadOnly
            try { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) }
            finally { $source.Dispose() }
            $script:RouteT = $t
            $script:RoutePage = $report.HtmlPath
            $script:RouteCsv = @{}
            foreach ($m in Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';') { $script:RouteCsv[$m.'Message ID'] = $m }
            $script:RouteHtml = @{}
            foreach ($m in (ReviewRows $report.HtmlPath).messages) { $script:RouteHtml[[string]$m[15]] = @($m[16]) }
        }
        It 'orders the front-end conversations around the receive they caused and keeps milliseconds' {
            $steps = $script:RouteHtml['<c-1@test>']
            @($steps | Select-Object -First 3 | ForEach-Object { $_[3] }) | Should -Be @('Accepted', 'RECEIVE', 'Sent')
            foreach ($step in $steps) { $step.Count | Should -Be 7 }
            $steps[1][6] | Should -Be ($script:RouteT + 3000 + 3)
            $script:RouteCsv['<c-1@test>'].Route | Should -Match '(?m)^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} \| EXCH01 \| SMTP Receive \(FrontEnd\) \| Accepted'
        }
        It 'folds the expansion of a list into one step' {
            $steps = $script:RouteHtml['<c-1@test>']
            @($steps | Where-Object { $_[3] -eq 'EXPAND' }).Count | Should -Be 1
            @($steps | Where-Object { $_[3] -eq 'EXPAND' })[0][4] | Should -Match 'distribution list dl@contoso\.test expanded to 2 recipients: m1@contoso\.test; m2@contoso\.test'
            @($steps | Where-Object { $_[3] -like 'DROP*' }).Count | Should -Be 0
            $script:RouteCsv['<c-1@test>'].Events | Should -Be 'RECEIVE > EXPAND > AGENTINFO > SEND > DELIVER > DEFER > SUBMIT'
        }
        It 'folds a hop with its delivery and names the folder' {
            $steps = $script:RouteHtml['<c-1@test>']
            $hop = @($steps | Where-Object { $_[3] -eq 'SEND > DELIVER' })
            $hop.Count | Should -Be 1
            $hop[0][4] | Should -Match 'to EXCH01\.contoso\.test \| 2 recipients: a@contoso\.test \(Inbox\); m1@contoso\.test \(folder .Junk Email.\) \| delivered \d\d:\d\d:\d\d \| 250 2\.1\.5 Recipient OK'
            $plain = @($steps | Where-Object { $_[3] -eq 'SEND' })
            $plain.Count | Should -Be 1
            $plain[0][4] | Should -Match 'to EXCH03\.contoso\.test \(not collected\)'
            @($steps | Where-Object { $_[3] -eq 'DELIVER' -and $_[4] -match 'a@contoso\.test' }).Count | Should -Be 0
        }
        It 'folds a deferral storm and shows the final delivery' {
            $steps = $script:RouteHtml['<c-1@test>']
            $storm = @($steps | Where-Object { $_[3] -like 'DEFER*' })
            $storm.Count | Should -Be 1
            $storm[0][3] | Should -Match '^DEFER .5 \(\d\d:\d\d:\d\d.\d\d:\d\d:\d\d\)$'
            $storm[0][4] | Should -Match 'recipient thread limit exceeded'
            $final = @($steps | Where-Object { $_[3] -eq 'DELIVER' -and $_[4] -match 'm2@contoso\.test' })
            $final.Count | Should -Be 1
            $final[0][4] | Should -Match '\| Inbox$'
        }
        It 'numbers the submissions of a message' {
            $steps = $script:RouteHtml['<c-1@test>']
            $second = $script:RouteT + 300000
            @($steps | Where-Object { $_[6] -lt $second } | ForEach-Object { $_[5] } | Select-Object -Unique) | Should -Be @(1)
            @($steps | Where-Object { $_[6] -ge $second } | ForEach-Object { $_[5] } | Select-Object -Unique) | Should -Be @(2)
            @($steps | Where-Object { $_[6] -ge $second }).Count | Should -Be 3
            $lines = @($script:RouteCsv['<c-1@test>'].Route -split "`n")
            $lines.Count | Should -Be $steps.Count
            $lines[0] | Should -Match ' \| submission 1$'
            $lines[-1] | Should -Match ' \| submission 2$'
        }
        It 'keeps a conversation between collected servers and one with no tracking RECEIVE in the submission of the SEND that made it' {
            $steps = $script:RouteHtml['<c-1@test>']
            @($steps | Where-Object { $_[2] -like 'SMTP * (Hub)' } | ForEach-Object { $_[2] }) | Should -Be @('SMTP Receive (Hub)', 'SMTP Send (Hub)')
            @($steps | Where-Object { $_[6] -lt ($script:RouteT + 300000) } | ForEach-Object { $_[5] } | Select-Object -Unique) | Should -Be @(1)
        }
        It 'puts the whole route of a message through an Edge in one submission' {
            $steps = $script:RouteHtml['<edge-1@test>']
            @($steps | ForEach-Object { $_[2] }) | Should -Contain 'SMTP Send (Edge)'
            @($steps | ForEach-Object { $_[5] } | Select-Object -Unique) | Should -Be @(1)
        }
        It 'names an empty list, a list expanded elsewhere, a received hop and a duplicate delivery' {
            $empty = @($script:RouteHtml['<c-3@test>'] | Where-Object { $_[3] -like 'DROP*' })
            $empty.Count | Should -Be 1
            $empty[0][4] | Should -Match 'distribution list is empty'
            @($script:RouteHtml['<c-4@test>'] | ForEach-Object { $_[3] }) | Should -Contain 'EXPAND (expanded on another server)'
            @($script:RouteHtml['<c-5@test>'] | ForEach-Object { $_[3] }) | Should -Contain 'SEND > RECEIVE'
            @($script:RouteHtml['<c-5@test>'] | Where-Object { $_[3] -eq 'RECEIVE' }).Count | Should -Be 0
            @($script:RouteHtml['<c-6@test>'] | ForEach-Object { $_[3] }) | Should -Contain 'DELIVER (duplicate suppressed)'
        }
        It 'folds identical consecutive drops' {
            $steps = $script:RouteHtml['<c-2@test>']
            $drops = @($steps | Where-Object { $_[3] -like 'DROP*' })
            $drops.Count | Should -Be 1
            $drops[0][3] | Should -Match '^DROP .3 \('
            $drops[0][4] | Should -Match 'deleted by a transport agent'
        }
        It 'reads the folder of each delivered recipient from its own status entry and shows a transport status as it is' {
            $deliver = { param($id) @($script:RouteHtml["<$id@test>"] | Where-Object { $_[3] -eq 'DELIVER' })[0][4] }
            & $deliver 'fold-1' | Should -Match '\| a@contoso\.test \| 250 2\.0\.0 Delivered$'
            & $deliver 'fold-1' | Should -Not -Match 'folder'
            & $deliver 'fold-2' | Should -Match '\| a@contoso\.test \(Inbox\); b@contoso\.test \(Inbox\); c@contoso\.test \(folder .Copies to me.\)$'
            & $deliver 'fold-3' | Should -Match '\| a@contoso\.test \(Inbox\); b@contoso\.test \(folder .Junk Email.\)$'
            & $deliver 'fold-4' | Should -Match '\| a@contoso\.test \| folder .Deleted Items.$'
            & $deliver 'fold-5' | Should -Match '\| a@contoso\.test; b@contoso\.test \| Inbox$'
            & $deliver 'fold-6' | Should -Match '\| a@contoso\.test \(folder .Alerts.\); b@contoso\.test \(folder .00B\. Project files.\)$'
            & $deliver 'fold-7' | Should -Match '\| a@contoso\.test \| StoreDriver\.Rules; moved by a rule$'
            & $deliver 'fold-8' | Should -Match '\| a@contoso\.test \| Inbox$'
            $script:RouteCsv['<fold-1@test>'].Route | Should -Match '\| 250 2\.0\.0 Delivered \| submission 1$'
        }
        It 'pairs a front-end conversation with the tracking RECEIVE it queued, with or without the same internal id' {
            foreach ($id in 'pair-1', 'pair-2') {
                $steps = @($script:RouteHtml["<$id@test>"])
                @($steps | ForEach-Object { $_[2] }) | Should -Be @('SMTP Receive (FrontEnd)', 'Tracking') -Because $id
                @($steps | ForEach-Object { $_[5] } | Select-Object -Unique) | Should -Be @(1) -Because $id
            }
        }
        It 'pairs each conversation with the RECEIVE that shares its recipients when the same host sends twice in a second' {
            $steps = @($script:RouteHtml['<pair-3@test>'])
            $steps.Count | Should -Be 4
            @($steps | ForEach-Object { if ($_[2] -eq 'Tracking') { $_[4] -replace '^.*?(r\d)@.*$', '$1' } else { $_[4] -replace '^.*InternalId=(\d+).*$', '$1' } }) | Should -Be @('771', 'r1', '772', 'r2')
            @($steps | ForEach-Object { $_[5] }) | Should -Be @(1, 1, 2, 2)
        }
        It 'pairs the RECEIVE with the accepted conversation, not with a deferred attempt of the same host before it' {
            $steps = @($script:RouteHtml['<pair-4@test>'])
            $steps.Count | Should -Be 3
            $deferred = @($steps | Where-Object { $_[3] -eq 'Deferred' })
            $accepted = @($steps | Where-Object { $_[3] -eq 'Accepted' })
            $receive = @($steps | Where-Object { $_[2] -eq 'Tracking' })
            $deferred.Count | Should -Be 1; $accepted.Count | Should -Be 1; $receive.Count | Should -Be 1
            $accepted[0][5] | Should -Be $receive[0][5]
            $deferred[0][5] | Should -Not -Be $receive[0][5]
        }
        It 'reads a delivery time alone in a DELIVER status as the Inbox, never as a folder' {
            $deliver = @($script:RouteHtml['<fold-9@test>'] | Where-Object { $_[3] -eq 'DELIVER' })[0][4]
            $deliver | Should -Match '\| a@contoso\.test \| Inbox$'
        }
        It 'ships the route grouped by submission with the agent steps behind a button' {
            $page = Get-Content -LiteralPath $script:RoutePage -Raw
            $page | Should -Match 'sub-head'
            $page | Should -Match 'Show agent steps'
            $page | Should -Match 'origin outside collected logs'
            $page | Should -Match 'expanded list'
            $page | Should -Match 'handed off outside collection'
            $page | Should -Match 'toggle\.type = "button"'
        }
        It 'gives the mail refused during the SMTP conversation the same step shape' {
            $refused = @($script:RouteHtml[""])
            $refused.Count | Should -Be 1
            $refused[0].Count | Should -Be 7
            $refused[0][5] | Should -Be 1
            $refused[0][6] | Should -Be ($script:RouteT + 400000)
        }
    }

    Context 'Route of a large distribution list' {
        It 'builds the route of a list of 2,000 members in linear time' {
            $s = ReviewSettings 'message-route-large'
            $q = ReviewRequest $s 'message-route-large'
            $q.MaxHtmlRows = 100; $q.WriteCsv = $true
            $t = $script:Base.ToUnixTimeMilliseconds()
            $members = 1..2000 | ForEach-Object { 'm{0}@contoso.test' -f $_ }
            $all = $members -join ';'
            $rows = [System.Collections.Generic.List[string]]::new()
            $script:bign = 0
            $add = {
                param([int]$At, [string]$Server, [string]$Event, [string]$Rcpts, [string]$Related, [string]$Internal, [string]$Source, [string]$Client, [string]$Peer, [string]$Connector)
                $script:bign++
                $q1 = { param($v) if ($v) { "'" + $v + "'" } else { 'NULL' } }
                $rows.Add("($($t + $At * 1000 + $script:bign),'$Server','$Event','<big@test>','sender@contoso.test',$(& $q1 $Rcpts),NULL,$(& $q1 $Related),'$Source',$(& $q1 $Internal),$(& $q1 $Client),$(& $q1 $Peer),$(& $q1 $Connector),'big-$($script:bign)')")
            }
            & $add 0 EXCH01 RECEIVE 'dl@contoso.test' $null 1 SMTP 'EXCH00.contoso.test' $null $null
            & $add 1 EXCH01 EXPAND $all 'dl@contoso.test' 1 ROUTING $null $null $null
            & $add 2 EXCH01 SEND $all $null 1 SMTP $null 'EXCH02.contoso.test' 'Intra-Org'
            foreach ($m in $members) { & $add 3 EXCH02 DELIVER $m $null 2 STOREDRIVER $null $null $null }
            $store = Open-ExlStore -Settings $s
            try {
                $store.Exec("DELETE FROM smtp_transaction; DELETE FROM message_event; DELETE FROM client_session; DELETE FROM session_step;")
                for ($i = 0; $i -lt $rows.Count; $i += 500) {
                    $chunk = $rows.GetRange($i, [Math]::Min(500, $rows.Count - $i))
                    $store.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,sender,recipients,recipient_status,related_recipient,source,internal_id,client_host,server_host,connector,log_id) VALUES`n" + ($chunk -join ",`n") + ';')
                }
            } finally { $store.Dispose() }
            $source = Open-ExlStore -Settings $s -ReadOnly
            try { $took = Measure-Command { $report = [ExchangeLogReport.ReportBuilder]::Build($source, $q) } }
            finally { $source.Dispose() }
            # The guard is generous: the folding of 2,000 deliveries into one hop took a fraction of this once the lookups were indexed.
            $took.TotalSeconds | Should -BeLessThan 2
            $route = @((Import-Csv (Join-Path $report.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' | Where-Object 'Message ID' -eq '<big@test>').Route -split "`n")
            @($route | Where-Object { $_ -match ' SEND > DELIVER ' }).Count | Should -Be 1
            $route[0] | Should -Match ' \| submission 1$'
        }
    }
}

Describe 'Retention' {
    It 'deletes aggregates after RetentionDays and details after DetailRetentionDays' {
        $dir = Join-Path $TestDrive 'retention'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        [void](Invoke-TestCollection $s)
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("UPDATE access_event SET time_ms = time_ms - 20 * 86400000; UPDATE access_usage SET day = '2000-01-01' WHERE user = 'contoso\carol';")
            $p = Invoke-ExlRetention -Store $store -Settings $s
            $p.Events | Should -BeGreaterThan 0
            $p.Usage | Should -Be 1
        } finally { $store.Dispose() }
        (Query $s 'SELECT COUNT(*) FROM access_event')[0][0] | Should -Be 0
        (Query $s 'SELECT COUNT(*) FROM smtp_transaction')[0][0] | Should -Be 5
    }
}

Describe 'SMTP authenticated identity' {
    # Synthetic fixtures only. The front-end/back-end dialogue follows the grammar read in a real Exchange protocol log (AUTH LOGIN, "data=<account>
    # context=authenticated" written by the server, "Proxy session was successfully set up", X-EXPS EXCHANGEAUTH with the technical identity
    # "[unrecognized]", XPROXY with the SID of the front-end session). No real mail transaction is part of that evidence: the transactions below
    # are simulated, and the result of this Describe does not replace a run on a candidate server.
    BeforeAll {
        $script:Secrets = @{ User = 'sentinel-user'; Password = 'SENTINELPASSWORD123456'; Blob = 'SENTINELBLOBXXXXXXXXXXXXXXXX' }
        function B64([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Text)) }
        function AuthSession([string]$Connector, [string]$Id, [double]$Minute, [string]$Local, [string]$Remote, $Steps, [int]$FirstSequence = 0) {
            $n = $FirstSequence
            $flat = { param($items) foreach ($item in $items) { if ($item -is [array]) { & $flat $item } else { $item } } }
            foreach ($s in @(& $flat $Steps)) {
                if ($s -eq 'GAP') { $n++; continue }
                $evt = $null; $data = ''; $ctx = ''
                if ($s -eq '+') { $evt = '+' }
                elseif ($s.StartsWith('-')) { $evt = '-'; $ctx = $s.Substring(1) }
                elseif ($s.StartsWith('C ')) { $evt = '<'; $data = $s.Substring(2) }
                elseif ($s.StartsWith('S ')) { $evt = '>'; $data = $s.Substring(2) }
                elseif ($s.StartsWith('E ')) { $evt = '*'; $split = $s.Substring(2).Split('|', 2); $data = $split[0]; $ctx = $split[1] }
                else { throw "Unknown step '$s'" }
                $cells = foreach ($x in $data, $ctx) { if ($x -match '[,"]') { '"' + $x.Replace('"', '""') + '"' } else { $x } }
                $minute = $Minute + ($n - $FirstSequence) * 0.0002
                # A front end ends its session after the mailbox server accepted the hand-over (the 235 of the front end is written after the XPROXY of the back end).
                if ($evt -eq '-') { $minute += 0.6 }
                "$(T $minute),$Connector,$Id,$n,$Local,$Remote,$evt,$($cells -join ',')"
                $n++
            }
        }
        function AuthHello([string]$Helo) { '+'; 'S 220 EXCH01.contoso.test Microsoft ESMTP MAIL Service ready'; "C EHLO $Helo"; 'S 250 EXCH01.contoso.test Hello' }
        function AuthTx([string]$From, [string]$Id) {
            "C MAIL FROM:<$From>"; 'S 250 2.1.0 Sender OK'; 'C RCPT TO:<bob@contoso.test>'; 'S 250 2.1.5 Recipient OK'; 'C DATA'; 'S 354 Start mail input; end with <CRLF>.<CRLF>'
            "S 250 2.6.0 <$Id@contoso.test> [InternalId=9001, Hostname=EXCH01.contoso.test] Queued mail for delivery"
        }
        function AuthLogin([string]$Identity, [switch]$Proxied, [switch]$Fail) {
            'C AUTH LOGIN'; 'S 334 VXNlcm5hbWU6'; "C $(B64 $script:Secrets.User)"; 'S 334 UGFzc3dvcmQ6'; "C $(B64 $script:Secrets.Password)"
            if ($Fail) { 'S 535 5.7.3 Authentication unsuccessful'; return }
            if ($Identity) { "E $Identity|authenticated" }
            if ($Proxied) { "E |Proxy session was successfully set up. Session for $Identity will now be proxied" }
            'S 235 2.7.0 Authentication successful'
        }
        function AuthPlain([string]$Identity) {
            "C AUTH PLAIN $(B64 "`0$($script:Secrets.User)`0$($script:Secrets.Password)")"
            if ($Identity) { "E $Identity|authenticated" }
            'S 235 2.7.0 Authentication successful'
        }
        function AuthBack([string]$Sid, [string]$Ip, [int]$Port, [string]$Domain, [string]$Sender, [string]$Id, [switch]$Reject) {
            AuthHello 'EXCH01.contoso.test'
            "C X-EXPS EXCHANGEAUTH $($script:Secrets.Blob)"; 'E [unrecognized]|authenticated'; 'S 235 2.7.0 Authentication successful'
            "C XPROXY SID=$Sid IP=$Ip PORT=$Port DOMAIN=$Domain CAPABILITIES=0"
            if ($Reject) { 'S 550 5.7.0 XPROXY rejected' } else { 'S 250 2.0.0 XPROXY OK' }
            AuthTx $Sender $Id
            'C QUIT'; 'S 221 2.0.0 Service closing transmission channel'; '-Local'
        }
        function New-AuthLogs([string]$Root, [ValidateSet('All', 'FE', 'Hub')][string]$Part = 'All') {
            $smtp = '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
            $header = '#Software: Microsoft Exchange Server', '#Log-type: SMTP Receive Protocol Log', "#Date: $(T 0)", $smtp
            $recv = 'TransportRoles\Logs\{0}\ProtocolLog\SmtpReceive\RECV2026100109-1.LOG'
            $fe = 'EXCH01\Client Frontend EXCH01'; $feLocal = '10.0.0.1:587'
            $cp = 'EXCH01\Client Proxy EXCH01'; $beLocal = '10.0.0.1:465'
            if ($Part -ne 'Hub') {
                $lines = @($header)
                # Proxied submissions: the front end has the account, the back end only the technical identity.
                $lines += AuthSession $fe '08DA0000000000A1' 40 $feLocal '10.2.0.1:50101' @((AuthHello 'thunderbird.contoso.test'), (AuthLogin 'proxy.user@contoso.test' -Proxied), '-Local')
                $lines += AuthSession $fe '08DA0000000000A3' 41 $feLocal '10.2.0.3:50103' @((AuthHello 'amb.contoso.test'), (AuthLogin 'amb.one@contoso.test' -Proxied), '-Local')
                $lines += AuthSession $fe '08DA0000000000A3' 41.5 $feLocal '10.2.0.3:50103' @((AuthHello 'amb.contoso.test'), (AuthLogin 'amb.two@contoso.test' -Proxied), '-Local')
                $lines += AuthSession $fe '08DA0000000000A4' 42 $feLocal '10.2.0.4:50104' @((AuthHello 'machine.contoso.test'), (AuthLogin 'EXCH01$' -Proxied), '-Local')
                # Direct sessions.
                $lines += AuthSession $fe '08DA000000000D01' 43 $feLocal '10.2.1.1:50201' @((AuthHello 'relay.contoso.test'), (AuthPlain 'direct.user@contoso.test'), (AuthTx 'sender.a@vendor.example' 'msg-auth-d1'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D02' 43.2 $feLocal '10.2.1.1:50202' @((AuthHello 'relay.contoso.test'), (AuthLogin 'CONTOSO\Other.User'), (AuthTx 'sender.b@vendor.example' 'msg-auth-d1b'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D03' 43.4 $feLocal '10.2.1.1:50203' @((AuthHello 'relay.contoso.test'), (AuthTx 'sender.c@vendor.example' 'msg-auth-d1c'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D04' 44 $feLocal '10.2.1.2:50204' @((AuthHello 'noidentity.contoso.test'), (AuthLogin ''), (AuthTx 'sender.d@vendor.example' 'msg-auth-d2'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D05' 44.2 $feLocal '10.2.1.3:50205' @((AuthHello 'retry.contoso.test'), (AuthLogin '' -Fail), (AuthPlain 'retry.user@contoso.test'), (AuthTx 'sender.e@vendor.example' 'msg-auth-d3'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D06' 44.4 $feLocal '10.2.1.4:50206' @((AuthHello 'failed.contoso.test'), (AuthLogin '' -Fail), (AuthTx 'sender.f@vendor.example' 'msg-auth-d3b'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D07' 45 $feLocal '10.2.1.5:50207' @(
                    (AuthHello 'snapshot.contoso.test'), (AuthLogin 'snap.one@contoso.test'), (AuthTx 'sender.g@vendor.example' 'msg-auth-s1'), 'C RSET', 'S 250 2.0.0 Resetting', (AuthTx 'sender.g@vendor.example' 'msg-auth-s2'),
                    'C STARTTLS', 'S 220 2.0.0 SMTP server ready', 'E |TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded using bulk encryption algorithm CALG_AES_256', 'C EHLO snapshot.contoso.test', 'S 250 EXCH01.contoso.test Hello',
                    (AuthTx 'sender.g@vendor.example' 'msg-auth-s3'), (AuthLogin 'snap.two@contoso.test'), (AuthTx 'sender.g@vendor.example' 'msg-auth-s4'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D08' 45.5 $feLocal '10.2.1.6:50208' @((AuthHello 'machine.contoso.test'), 'C AUTH NTLM', 'E MACHINE01$|authenticated', 'S 235 2.7.0 Authentication successful', (AuthTx 'sender.h@vendor.example' 'msg-auth-d5'), 'C QUIT', 'S 221 bye', '-Local')
                $lines += AuthSession $fe '08DA000000000D09' 46 $feLocal '10.2.1.7:50209' @((AuthHello 'gap.contoso.test'), (AuthLogin 'gap.user@contoso.test'), 'GAP', (AuthTx 'sender.i@vendor.example' 'msg-auth-d7'), 'C QUIT', 'S 221 bye', '-Local')
                $long = @(AuthHello 'long.contoso.test'; AuthLogin 'long.user@contoso.test')
                foreach ($i in 1..600) { $long += AuthTx 'bulk@vendor.example' ('msg-auth-long-{0:000}' -f $i) }
                $lines += AuthSession $fe '08DA000000000D10' 47 $feLocal '10.2.1.9:50210' @($long, 'C QUIT', 'S 221 bye', '-Local')
                Write-Log (Join-Path $Root ('EXCH01\Exchange\' + ($recv -f 'FrontEnd'))) $lines
            }
            if ($Part -ne 'FE') {
                $lines = @($header)
                $lines += AuthSession $cp '08DA00000000B001' 40.1 $beLocal '10.0.0.1:41701' @(AuthBack '08DA0000000000A1' '10.2.0.1' 50101 'thunderbird.contoso.test' 'newsletter@vendor.example' 'msg-auth-b1')
                $lines += AuthSession $cp '08DA00000000B002' 40.3 $beLocal '10.0.0.1:41702' @(AuthBack '08DA0000000000FF' '10.2.0.9' 50109 'unknown.contoso.test' 'sender.j@vendor.example' 'msg-auth-b2')
                $lines += AuthSession $cp '08DA00000000B003' 40.5 $beLocal '10.0.0.1:41703' @(AuthBack '08DA0000000000A1' '10.9.9.9' 50101 'thunderbird.contoso.test' 'sender.k@vendor.example' 'msg-auth-b3')
                $lines += AuthSession $cp '08DA00000000B004' 41.55 $beLocal '10.0.0.1:41704' @(AuthBack '08DA0000000000A3' '10.2.0.3' 50103 'amb.contoso.test' 'sender.l@vendor.example' 'msg-auth-b4')
                $lines += AuthSession $cp '08DA00000000B005' 42.1 $beLocal '10.0.0.1:41705' @(AuthBack '08DA0000000000A4' '10.2.0.4' 50104 'machine.contoso.test' 'sender.m@vendor.example' 'msg-auth-b5')
                $lines += AuthSession $cp '08DA00000000B006' 42.3 $beLocal '10.0.0.1:41706' @(AuthBack '08DA0000000000A1' '10.2.0.1' 50101 'thunderbird.contoso.test' 'sender.n@vendor.example' 'msg-auth-b6' -Reject)
                Write-Log (Join-Path $Root ('EXCH01\Exchange\' + ($recv -f 'Hub'))) $lines
                $trkFields = '#Fields: date-time,client-ip,client-hostname,server-ip,server-hostname,source-context,connector-id,source,event-id,internal-message-id,message-id,network-message-id,recipient-address,recipient-status,total-bytes,recipient-count,related-recipient-address,reference,message-subject,sender-address,return-path,message-info,directionality,tenant-id,original-client-ip,original-server-ip,custom-data,transport-traffic-type,log-id,schema-version'
                $trk = { param($min, $id, $connector, $sender) "$(T $min),10.2.0.1,thunderbird.contoso.test,10.0.0.2,,08DA000000000001;$(T $min);0,$connector,SMTP,RECEIVE,2001,<$id@contoso.test>,net-$id,bob@contoso.test,,2048,1,,,Authenticated submission,$sender,$sender,,Originating,,,,,Email,$([guid]::NewGuid()),15.02.2562.045" }
                Write-Log (Join-Path $Root 'EXCH01\Exchange\TransportRoles\Logs\MessageTracking\MSGTRK2026100109-1.LOG') @(
                    '#Software: Microsoft Exchange Server', '#Version: 15.02.2562.045', '#Log-type: Message Tracking Log', "#Date: $(T 0)", $trkFields
                    (& $trk 40.1 'msg-auth-b1' 'EXCH01\Client Proxy EXCH01' 'newsletter@vendor.example')
                    (& $trk 43 'msg-auth-d1' 'EXCH01\Client Frontend EXCH01' 'sender.a@vendor.example'))
            }
        }
        function AuthTable($Settings, [string]$Like = '<msg-auth-%') {
            $table = [ordered]@{}
            foreach ($r in (Query $Settings "SELECT message_id, COALESCE(auth_user,''), COALESCE(auth_mechanism,''), COALESCE(auth_result,'-'), COALESCE(auth_attempt_result,'-'), COALESCE(auth_source,'-') FROM smtp_transaction WHERE message_id LIKE '$Like' ORDER BY message_id")) {
                $table[[string]$r[0]] = (@($r[1], $r[2], $r[3], $r[4], $r[5]) -join '|')
            }
            return $table
        }
        function AuthJson($Settings) { ConvertTo-Json -InputObject (AuthTable $Settings) -Compress }
        function HtmlSets([string]$Path) { (Read-TestHtml $Path).Sets }
        function AuthCsv($Report, [string]$Name) { Import-Csv -LiteralPath (Join-Path $Report.Folder "ExchangeLogs-$Name.csv") -Delimiter ';' }
        function AuthReport($Settings) {
            $store = Open-ExlStore -Settings $Settings -ReadOnly
            try { New-ExlReport -Store $store -Settings $Settings -Period ([pscustomobject]@{ StartMs = $script:Base.AddHours(-1).ToUnixTimeMilliseconds(); EndMs = $script:Base.AddHours(2).ToUnixTimeMilliseconds() }) -ReportType Detailed }
            finally { $store.Dispose() }
        }

        $script:AuthExpected = [ordered]@{
            '<msg-auth-b1@contoso.test>'   = 'proxy.user@contoso.test|LOGIN|Succeeded|Succeeded|FrontEndProxy'
            '<msg-auth-b2@contoso.test>'   = '||Unknown|Unknown|Missing'
            '<msg-auth-b3@contoso.test>'   = '||Unknown|Unknown|Missing'
            '<msg-auth-b4@contoso.test>'   = '||Unknown|Unknown|Ambiguous'
            '<msg-auth-b5@contoso.test>'   = '||Unknown|Unknown|Missing'
            '<msg-auth-b6@contoso.test>'   = '||Unknown|Unknown|Missing'
            '<msg-auth-d1@contoso.test>'   = 'direct.user@contoso.test|PLAIN|Succeeded|Succeeded|Direct'
            '<msg-auth-d1b@contoso.test>'  = 'contoso\other.user|LOGIN|Succeeded|Succeeded|Direct'
            '<msg-auth-d1c@contoso.test>'  = '||Not attempted|Not attempted|NotApplicable'
            '<msg-auth-d2@contoso.test>'   = '|LOGIN|Succeeded|Succeeded|Missing'
            '<msg-auth-d3@contoso.test>'   = 'retry.user@contoso.test|PLAIN|Succeeded|Succeeded|Direct'
            '<msg-auth-d3b@contoso.test>'  = '|LOGIN|Failed|Failed|NotApplicable'
            '<msg-auth-d5@contoso.test>'   = '|NTLM|Succeeded|Succeeded|NotApplicable'
            '<msg-auth-d7@contoso.test>'   = '||Unknown|Unknown|Missing'
            '<msg-auth-s1@contoso.test>'   = 'snap.one@contoso.test|LOGIN|Succeeded|Succeeded|Direct'
            '<msg-auth-s2@contoso.test>'   = 'snap.one@contoso.test|LOGIN|Succeeded|Succeeded|Direct'
            '<msg-auth-s3@contoso.test>'   = '||Not attempted|Not attempted|NotApplicable'
            '<msg-auth-s4@contoso.test>'   = 'snap.two@contoso.test|LOGIN|Succeeded|Succeeded|Direct'
        }

        $script:AuthDir = Join-Path $TestDrive 'smtp-auth'
        $script:AuthConfig = New-TestConfig $script:AuthDir
        New-AuthLogs (Join-Path $script:AuthDir 'logs-src') 'All'
        $script:AuthSettings = Import-ExlConfiguration -Path $script:AuthConfig -Root $script:Root
        $script:AuthRun = Invoke-TestCollection $script:AuthSettings
        $script:AuthBaseline = AuthTable $script:AuthSettings
    }
    It 'shows the account proved by the front end for the proxied submission, apart from the sender' {
        $script:AuthBaseline['<msg-auth-b1@contoso.test>'] | Should -Be $script:AuthExpected['<msg-auth-b1@contoso.test>']
        (Query $script:AuthSettings "SELECT mail_from, auth_user FROM smtp_transaction WHERE message_id = '<msg-auth-b1@contoso.test>'")[0] -join '|' | Should -Be 'newsletter@vendor.example|proxy.user@contoso.test'
        (Query $script:AuthSettings "SELECT COUNT(*) FROM smtp_auth_fragment WHERE role = 'FrontEnd' AND session_id = '08DA0000000000A1'")[0][0] | Should -Be 1
        (Query $script:AuthSettings "SELECT COUNT(*) FROM smtp_transaction WHERE session_id = '08DA0000000000A1'")[0][0] | Should -Be 0
    }
    It 'reads the identity of direct sessions per authentication attempt and keeps failed and missing proofs apart' {
        foreach ($id in 'd1', 'd1b', 'd1c', 'd2', 'd3', 'd3b', 'd5') {
            $key = "<msg-auth-$id@contoso.test>"
            $script:AuthBaseline[$key] | Should -Be $script:AuthExpected[$key] -Because $key
        }
    }
    It 'evaluates the state of every MAIL: RSET keeps the account, STARTTLS resets it, a second login is a new proof' {
        foreach ($id in 's1', 's2', 's3', 's4') {
            $key = "<msg-auth-$id@contoso.test>"
            $script:AuthBaseline[$key] | Should -Be $script:AuthExpected[$key] -Because $key
        }
    }
    It 'never takes the technical identity, a machine account or an unproved front end for a user' {
        foreach ($id in 'b2', 'b5', 'b6', 'd5') {
            $key = "<msg-auth-$id@contoso.test>"
            $script:AuthBaseline[$key] | Should -Be $script:AuthExpected[$key] -Because $key
        }
        (Query $script:AuthSettings "SELECT COUNT(*) FROM smtp_transaction WHERE auth_user LIKE '[[]%' OR auth_user LIKE '%$' OR auth_user LIKE '%unrecognized%' OR auth_user = 'machine01$'")[0][0] | Should -Be 0
    }
    It 'refuses ambiguous or spoofed front-end evidence instead of choosing the first, the last or the closest' {
        $script:AuthBaseline['<msg-auth-b4@contoso.test>'] | Should -Be $script:AuthExpected['<msg-auth-b4@contoso.test>']
        $script:AuthBaseline['<msg-auth-b3@contoso.test>'] | Should -Be $script:AuthExpected['<msg-auth-b3@contoso.test>']
        $script:AuthBaseline['<msg-auth-b6@contoso.test>'] | Should -Be $script:AuthExpected['<msg-auth-b6@contoso.test>']
    }
    It 'does not prove an account across a gap of sequence numbers' {
        $script:AuthBaseline['<msg-auth-d7@contoso.test>'] | Should -Be $script:AuthExpected['<msg-auth-d7@contoso.test>']
    }
    It 'splits a long session into compact chunks and maps every transaction to its own proof' {
        (Query $script:AuthSettings "SELECT COUNT(*) FROM smtp_auth_fragment WHERE session_id = '08DA000000000D10'")[0][0] | Should -Be 3
        (Query $script:AuthSettings "SELECT MAX(length(observations)) FROM smtp_auth_fragment")[0][0] | Should -BeLessThan 20000
        (Query $script:AuthSettings "SELECT COUNT(*) FROM smtp_transaction WHERE message_id LIKE '<msg-auth-long-%' AND auth_user = 'long.user@contoso.test' AND auth_source = 'Direct' AND auth_mechanism = 'LOGIN'")[0][0] | Should -Be 600
        (Query $script:AuthSettings "SELECT COUNT(DISTINCT auth_sequence) FROM smtp_transaction WHERE message_id LIKE '<msg-auth-long-%'")[0][0] | Should -Be 600
    }
    It 'removes the AUTH payloads, challenges and tokens before storing the evidence' {
        $text = (Query $script:AuthSettings "SELECT group_concat(observations || coalesce(coverage, '') || coalesce(proxy_helo, '')) FROM smtp_auth_fragment")[0][0]
        foreach ($secret in $script:Secrets.Values + (B64 $script:Secrets.User) + (B64 $script:Secrets.Password) + 'VXNlcm5hbWU6' + 'UGFzc3dvcmQ6') { $text | Should -Not -Match ([regex]::Escape($secret)) }
        $text | Should -Not -Match 'unrecognized'
    }
    It 'gives the same proofs whatever the order of the files, the threads and the restarts' {
        $one = AuthJson $script:AuthSettings
        $one | Should -Be (ConvertTo-Json -InputObject $script:AuthBaseline -Compress)
        # Nothing new to read: the collector restarts without touching the proofs.
        (Invoke-TestCollection $script:AuthSettings).Lines | Should -Be 0
        AuthJson $script:AuthSettings | Should -Be $one
        $fragments = (Query $script:AuthSettings 'SELECT COUNT(*) FROM smtp_auth_fragment')[0][0]
        foreach ($order in 'Hub,FE', 'FE,Hub') {
            $dir = Join-Path $TestDrive ('smtp-auth-' + $order.Replace(',', '-'))
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            foreach ($part in $order.Split(',')) { New-AuthLogs (Join-Path $dir 'logs-src') $part; [void](Invoke-TestCollection $s) }
            AuthJson $s | Should -Be $one -Because $order
            (Query $s 'SELECT COUNT(*) FROM smtp_auth_fragment')[0][0] | Should -Be $fragments -Because $order
        }
        $dir = Join-Path $TestDrive 'smtp-auth-parallel'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir @{ 'Parallelism            = 0' = 'Parallelism            = 6'; 'MaxFilesPerServer      = 4' = 'MaxFilesPerServer      = 1' }) -Root $script:Root
        New-AuthLogs (Join-Path $dir 'logs-src') 'All'
        $guard = 0
        do { $r = Invoke-TestCollection $s; $guard++ } while ($r.Lines -gt 0 -and $guard -lt 60)
        AuthJson $s | Should -Be $one -Because 'six threads, one file per run'
    }
    It 'keeps the old transactions as "not available" when a version 5 database is opened, without reading the logs again' {
        $dir = Join-Path $TestDrive 'smtp-auth-v5'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        New-AuthLogs (Join-Path $dir 'logs-src') 'All'
        [void](Invoke-TestCollection $s)
        $rows = (Query $s 'SELECT id, time_ms, server, role, session_id, message_id, status, mail_from FROM smtp_transaction ORDER BY id') | ForEach-Object { $_ -join '|' }
        $offsets = (Query $s 'SELECT path, offset, size FROM source_file ORDER BY path') | ForEach-Object { $_ -join '|' }
        $store = Open-ExlStore -Settings $s
        try {
            Remove-TestServeSchema $store
            $store.Exec('DROP INDEX ix_smtp_auth_fragment; DROP INDEX ix_smtp_auth_evidence; DROP INDEX ix_smtp_auth_fragment_page; DROP INDEX ix_smtp_auth_scope; DROP TABLE smtp_auth_fragment;')
            foreach ($column in 'auth_user', 'auth_mechanism', 'auth_result', 'auth_attempt_result', 'auth_source', 'auth_fragment_id', 'auth_sequence', 'auth_evidence_id') { $store.Exec("ALTER TABLE smtp_transaction DROP COLUMN $column;") }
            $store.Exec("UPDATE metadata SET value = '5' WHERE key = 'schema_version';")
        } finally { $store.Dispose() }
        (Invoke-TestCollection $s).Lines | Should -Be 0
        (Query $s "SELECT value FROM metadata WHERE key = 'schema_version'")[0][0] | Should -Be ([ExchangeLogReport.Store]::SchemaVersion)
        [ExchangeLogReport.Store]::SchemaVersion | Should -Be '13'
        @((Query $s "SELECT name FROM pragma_table_info('smtp_transaction') WHERE name LIKE 'auth_%' ORDER BY name") | ForEach-Object { $_[0] }) |
            Should -Be @('auth_attempt_result', 'auth_evidence_id', 'auth_fragment_id', 'auth_mechanism', 'auth_result', 'auth_sequence', 'auth_source', 'auth_user')
        @((Query $s "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'ix_%auth%' ORDER BY name") | ForEach-Object { $_[0] }) |
            Should -Be @('ix_authfrag_candidate_scope', 'ix_authfrag_candidates', 'ix_authfrag_last', 'ix_authfrag_origin_page', 'ix_authfrag_proxy_page', 'ix_authfrag_proxy_replay', 'ix_authfrag_replay', 'ix_smtp_auth_evidence', 'ix_smtp_auth_fragment', 'ix_smtp_auth_fragment_page', 'ix_smtp_auth_scope')
        @((Query $s "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ux_authfrag_origin'") | ForEach-Object { $_[0] }) | Should -Be @('ux_authfrag_origin')
        (Query $s 'SELECT COUNT(*) FROM smtp_auth_fragment')[0][0] | Should -Be 0
        (Query $s 'SELECT COUNT(*) FROM smtp_transaction WHERE auth_source IS NOT NULL OR auth_user IS NOT NULL')[0][0] | Should -Be 0
        (Query $s 'SELECT id, time_ms, server, role, session_id, message_id, status, mail_from FROM smtp_transaction ORDER BY id') | ForEach-Object { $_ -join '|' } | Should -Be $rows
        (Query $s 'SELECT path, offset, size FROM source_file ORDER BY path') | ForEach-Object { $_ -join '|' } | Should -Be $offsets
        $report = AuthReport $s
        $row = @(AuthCsv $report 'SmtpSessions') | Where-Object 'Message ID' -EQ '<msg-auth-b1@contoso.test>'
        @($row.'Authenticated user', $row.'Identity evidence', $row.'Authentication result') | Should -Be @('Not available', 'Legacy', 'Unknown')
    }
    It 'keeps the account along the transaction after the transcript expires and while a front-end proof is still used' {
        $dir = Join-Path $TestDrive 'smtp-auth-retention'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        New-AuthLogs (Join-Path $dir 'logs-src') 'All'
        [void](Invoke-TestCollection $s)
        $before = AuthJson $s
        $day = 86400000
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("UPDATE smtp_transaction SET time_ms = time_ms - 20 * $day, end_ms = end_ms - 20 * $day; UPDATE smtp_auth_fragment SET first_ms = first_ms - 20 * $day, last_ms = last_ms - 20 * $day;")
            $p = Invoke-ExlRetention -Store $store -Settings $s
            $p.Transcripts | Should -BeGreaterThan 0
            $p.AuthFragments | Should -Be 0
        } finally { $store.Dispose() }
        (Query $s 'SELECT COUNT(*) FROM smtp_transaction WHERE transcript IS NOT NULL')[0][0] | Should -Be 0
        AuthJson $s | Should -Be $before
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("UPDATE smtp_auth_fragment SET first_ms = first_ms - 70 * $day, last_ms = last_ms - 70 * $day WHERE role = 'FrontEnd';")
            [void](Invoke-ExlRetention -Store $store -Settings $s)
        } finally { $store.Dispose() }
        (Query $s "SELECT COUNT(*) FROM smtp_auth_fragment WHERE session_id = '08DA0000000000A1'")[0][0] | Should -Be 1
        AuthJson $s | Should -Be $before
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("UPDATE smtp_transaction SET time_ms = time_ms - 70 * $day, end_ms = end_ms - 70 * $day; UPDATE smtp_auth_fragment SET first_ms = first_ms - 70 * $day, last_ms = last_ms - 70 * $day;")
            $p = Invoke-ExlRetention -Store $store -Settings $s
            $p.AuthFragments | Should -BeGreaterThan 0
        } finally { $store.Dispose() }
        (Query $s 'SELECT COUNT(*) FROM smtp_auth_fragment')[0][0] | Should -Be 0
    }
    It 'answers the evidence queries through their indexes' {
        function Plan([string]$Sql) { (@((Query $script:AuthSettings "EXPLAIN QUERY PLAN $Sql") | ForEach-Object { $_[3] })) -join ' ' }
        $origins = Plan "SELECT COALESCE(source_key,''), first_offset, COALESCE(origin_first_ms,first_ms), MIN(first_ms), MAX(last_ms), COUNT(*) FROM smtp_auth_fragment WHERE server='EXCH01' AND role='Hub' AND direction='Receive' AND session_id='x' AND (COALESCE(origin_first_ms,first_ms),COALESCE(source_key,''),first_offset)>(0,'',0) GROUP BY COALESCE(origin_first_ms,first_ms),COALESCE(source_key,''),first_offset ORDER BY 3,1,2 LIMIT 32"
        $origins | Should -Match 'ix_authfrag_origin_page'
        $origins | Should -Not -Match 'TEMP B-TREE|SCAN smtp_auth_fragment'
        $parts = Plan "SELECT id FROM smtp_auth_fragment WHERE server='EXCH01' AND role='Hub' AND direction='Receive' AND session_id='x' AND COALESCE(source_key,'')='key' AND first_offset=0 AND COALESCE(origin_first_ms,first_ms)=0 AND id>0 ORDER BY id LIMIT 32"
        $parts | Should -Match 'ix_authfrag_origin_page'
        $parts | Should -Not -Match 'TEMP B-TREE|SCAN smtp_auth_fragment'
        $candidates = Plan "SELECT server FROM smtp_auth_fragment WHERE session_id='x' AND role='FrontEnd' AND direction='Receive' AND first_ms<=1 AND last_ms>=0 AND server>'' GROUP BY server ORDER BY server LIMIT 32"
        $candidates | Should -Match 'ix_authfrag_candidate_scope'
        $candidates | Should -Not -Match 'TEMP B-TREE|SCAN smtp_auth_fragment'
        $dependents = Plan "SELECT server,direction,role,session_id,id FROM smtp_auth_fragment WHERE proxy_sid='x' AND first_ms<=1 AND last_ms>=0 AND id>0 ORDER BY id LIMIT 128"
        $dependents | Should -Match 'ix_authfrag_proxy_replay'
        $dependents | Should -Not -Match 'TEMP B-TREE|SCAN smtp_auth_fragment'
        Plan 'SELECT id, auth_sequence FROM smtp_transaction WHERE auth_fragment_id = 1' | Should -Match 'ix_smtp_auth_fragment'
        Plan 'SELECT id FROM smtp_transaction WHERE auth_fragment_id = 1 AND auth_sequence > 3 ORDER BY auth_sequence, id LIMIT 32' | Should -Match 'ix_smtp_auth_fragment_page|ix_smtp_auth_fragment'
        Plan "SELECT DISTINCT auth_fragment_id FROM smtp_transaction WHERE server = 'EXCH01' AND role = 'Hub' AND direction = 'Receive' AND session_id = 'x' AND auth_fragment_id IS NOT NULL" | Should -Match 'ix_smtp_auth_scope'
        Plan 'SELECT id FROM smtp_transaction WHERE auth_evidence_id = 1' | Should -Match 'ix_smtp_auth_evidence'
    }
    It 'exposes the authenticated user, apart from the mechanism and the sender, in the SMTP client, session, message and popup views' {
        $report = AuthReport $script:AuthSettings
        $names = @((AuthCsv $report 'SmtpSessions')[0].PSObject.Properties.Name)
        @($names[-5..-1]) | Should -Be @('Authentication mechanism', 'Authentication result', 'Last AUTH attempt', 'Authenticated user', 'Identity evidence')
        $names | Should -Contain 'Authentication'
        $sessions = @(AuthCsv $report 'SmtpSessions')
        $b1 = $sessions | Where-Object 'Message ID' -EQ '<msg-auth-b1@contoso.test>'
        @($b1.'Mail from', $b1.'Authenticated user', $b1.'Authentication mechanism', $b1.'Authentication result', $b1.'Last AUTH attempt', $b1.'Identity evidence') |
            Should -Be @('newsletter@vendor.example', 'proxy.user@contoso.test', 'LOGIN', 'Succeeded', 'Succeeded', 'Front end proxy')
        $b2 = $sessions | Where-Object 'Message ID' -EQ '<msg-auth-b2@contoso.test>'
        @($b2.'Authenticated user', $b2.'Identity evidence') | Should -Be @('Not available', 'Missing')
        (($sessions | Where-Object 'Message ID' -EQ '<msg-auth-d1c@contoso.test>').'Authentication mechanism') | Should -Be 'None'
        (($sessions | Where-Object 'Message ID' -EQ '<msg-auth-b4@contoso.test>').'Identity evidence') | Should -Be 'Ambiguous'
        (($sessions | Where-Object 'Message ID' -EQ '<msg-auth-d1@contoso.test>').'Identity evidence') | Should -Be 'Direct server log'
        (($sessions | Where-Object 'Message ID' -EQ '<msg-auth-d1b@contoso.test>').'Authenticated user') | Should -Be 'contoso\other.user'
        $client = @(AuthCsv $report 'SmtpClients') | Where-Object { $_.'Remote IP' -eq '10.2.1.1' -and $_.HELO -eq 'relay.contoso.test' }
        $client.'Authenticated users' | Should -Be 'contoso\other.user, direct.user@contoso.test'
        @($client.'Authentication mechanism', $client.'Authentication result', $client.'Identity evidence', $client.'Transactions without authenticated user') |
            Should -Be @('LOGIN, None, PLAIN', 'Not attempted, Succeeded', 'Direct server log, Not applicable', '1')
        $client.Authentication | Should -Not -Match 'direct.user'
        $messages = @(AuthCsv $report 'Messages') | Where-Object 'Message ID' -EQ '<msg-auth-b1@contoso.test>'
        $messages.Route | Should -Match 'Authenticated user proxy\.user@contoso\.test'
        $messages.Route | Should -Match 'Identity evidence Front end proxy'
        $messages.Route | Should -Match 'envelope sender newsletter@vendor\.example'
        $html = HtmlSets $report.HtmlPath
        $row = $html.smtpclients | Where-Object { $_[0] -eq '10.2.1.1' -and $_[1] -eq 'relay.contoso.test' }
        @($row[17..22]) | Should -Be @('LOGIN, None, PLAIN', 'Not attempted, Succeeded', 'Not attempted, Succeeded', 'contoso\other.user, direct.user@contoso.test', 'Direct server log, Not applicable', 1)
        $popup = @($row[16]) | Where-Object { $_[7] -eq '<msg-auth-d1@contoso.test>' }
        $popup.Count | Should -Be 14
        @($popup[9], $popup[10], $popup[11], $popup[12], $popup[13]) | Should -Be @('PLAIN', 'Succeeded', 'Succeeded', 'direct.user@contoso.test', 'Direct server log')
        # The page and its main script, as a static report copies them together.
        $template = (Get-Content -LiteralPath (Join-Path $script:Root 'templates\Report.template.html') -Raw) + (Get-Content -LiteralPath (Join-Path $script:Root 'templates\Report.template.js') -Raw)
        $template | Should -Match 'Authentication mechanism", "Authentication result", "Last AUTH attempt", "Authenticated user", "Identity evidence"'
        $template | Should -Match 'td2\.colSpan = headers\.length'
    }
    It 'never writes a password, a token or a challenge to the report, and cleans old transcripts when they are read' {
        $dir = Join-Path $TestDrive 'smtp-auth-legacy'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        New-AuthLogs (Join-Path $dir 'logs-src') 'All'
        [void](Invoke-TestCollection $s)
        $t = $script:Base.AddMinutes(50).ToUnixTimeMilliseconds()
        $legacy = ("12:00:00.000 S: 220 legacy.example", "12:00:00.001 C: AUTH LOGIN", "12:00:00.002 S: 334 VXNlcm5hbWU6", "12:00:00.003 C: LEGACYUSERB64", "12:00:00.004 S: 334 UGFzc3dvcmQ6",
            "12:00:00.005 C: LEGACYPASSB64", "12:00:00.006 S: 235 2.7.0 Authentication successful LEGACYSECRET", "12:00:00.007 C: MAIL FROM:<legacy@vendor.example>") -join "`n"
        $store = Open-ExlStore -Settings $s
        try {
            $store.Exec("INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,remote_ep,helo,mail_from,rcpt_count,rcpts,message_id,status,response,transcript) VALUES($t,$t,'EXCH01','Receive','FrontEnd','legacy-connector','legacy-session','203.0.113.77:1234','legacy.example','legacy@vendor.example',1,'bob@contoso.test','<msg-legacy@contoso.test>','Accepted','250 queued','$legacy');")
        } finally { $store.Dispose() }
        $report = AuthReport $s
        $everything = New-Object System.Text.StringBuilder
        foreach ($file in Get-ChildItem -LiteralPath $report.Folder -Filter '*.csv') { [void]$everything.Append([IO.File]::ReadAllText($file.FullName)) }
        $sets = HtmlSets $report.HtmlPath
        foreach ($name in $sets.Keys) { [void]$everything.Append((ConvertTo-Json -InputObject @($sets[$name]) -Depth 50 -Compress)) }
        $text = $everything.ToString()
        foreach ($secret in $script:Secrets.Values + (B64 $script:Secrets.User) + (B64 $script:Secrets.Password) + 'VXNlcm5hbWU6' + 'UGFzc3dvcmQ6' + 'LEGACYUSERB64' + 'LEGACYPASSB64' + 'LEGACYSECRET') {
            $text | Should -Not -Match ([regex]::Escape($secret)) -Because $secret
        }
        $transcript = (@(AuthCsv $report 'SmtpSessions') | Where-Object 'Message ID' -EQ '<msg-legacy@contoso.test>').Transcript
        $transcript | Should -Match 'AUTH LOGIN'
        $transcript | Should -Match '334 \[redacted\]'
        $transcript | Should -Match '235 2\.7\.0 Authentication successful'
        $own = (@(AuthCsv $report 'SmtpSessions') | Where-Object 'Message ID' -EQ '<msg-auth-b1@contoso.test>').Transcript
        $own | Should -Match 'X-EXPS EXCHANGEAUTH \[redacted\]'
        $own | Should -Match 'XPROXY SID=08DA0000000000A1'
    }

    Context 'same-host loopback handover' {
        BeforeAll {
            $dir = Join-Path $TestDrive 'smtp-auth-loopback'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $header = '#Software: Microsoft Exchange Server', '#Log-type: SMTP Receive Protocol Log', "#Date: $(T 0)",
                '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
            $paths = @{
                FE = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive\RECV2026100109-1.LOG'
                Hub = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\Hub\ProtocolLog\SmtpReceive\RECV2026100109-1.LOG'
                Other = Join-Path $dir 'missing\EXCH02\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive\RECV2026100109-1.LOG'
                Mailbox = Join-Path $dir 'logs-src\EXCH01\Exchange\TransportRoles\Logs\Mailbox\ProtocolLog\SmtpReceive\RECV2026100109-1.LOG'
            }
            $lines = @{ FE = @($header); Hub = @($header); Other = @($header); Mailbox = @($header) }
            $cases = [ordered]@{
                ipv4 = @{}; ipv6 = @{ Local = '[::1]:587'; Remote = '[::1]:55000'; Ip = '::1' }
                clientip = @{ Ip = '127.0.0.2' }; clientport = @{ Port = 55001 }
                remote = @{ Remote = '10.3.0.1:55000'; Ip = '10.3.0.1' }
                peer = @{ Peer = '10.0.0.2:44000' }; server = @{ Other = $true }
                malformed = @{ Local = '[::1]junk:587' }; empty = @{ Local = '' }
                wildcard = @{ Local = '0.0.0.0:587' }; hubwildcard = @{ HubLocal = '0.0.0.0:465'; Peer = '0.0.0.0:44000' }
                portless = @{ Local = '127.0.0.1' }; mixed = @{ Local = '[::1]:587' }
                role = @{ Mailbox = $true }; notechnical = @{ NoTechnical = $true }
                refusedauth = @{ RefusedAuth = $true }; noproxyreply = @{ NoProxyReply = $true }
                refusedproxy = @{ RefusedProxy = $true }; ambiguous = @{ Ambiguous = $true }
            }
            $feTimes = @(-80,-75,-70,-65,-60,-55,-50,-45,-40,-35,-30,-25,0,10,20,30,41,45,70,100,190,190,2759)
            $hubTimes = @(100,110,120,121,125,130,135,140,141,145,149,150,157,158,159,160,180,190,192,194,196,198,200,202,204,2600,2601,2755,2758,2759)
            function TimedLoopbackRows($Rows, [long[]]$Offsets, [DateTimeOffset]$Origin) {
                for ($i = 0; $i -lt $Rows.Count; $i++) {
                    $stamp = $Origin.AddMilliseconds($Offsets[$i]).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    $stamp + $Rows[$i].Substring($Rows[$i].IndexOf(','))
                }
            }
            $n = 0
            foreach ($name in $cases.Keys) {
                $n++; $c = $cases[$name]
                $local = '127.0.0.1:587'; $remote = '127.0.0.1:55000'; $ip = '127.0.0.1'; $port = 55000
                $hubLocal = '10.0.0.1:465'; $peer = '10.0.0.1:44000'
                if ($c.ContainsKey('Local')) { $local = $c.Local }; if ($c.ContainsKey('Remote')) { $remote = $c.Remote }
                if ($c.ContainsKey('Ip')) { $ip = $c.Ip }; if ($c.ContainsKey('Port')) { $port = $c.Port }
                if ($c.ContainsKey('Peer')) { $peer = $c.Peer }; if ($c.ContainsKey('HubLocal')) { $hubLocal = $c.HubLocal }
                $server = if ($c['Other']) { 'EXCH02' } else { 'EXCH01' }
                $sid = '08DA00000000FA{0:00}' -f $n; $beSid = '08DA00000000BA{0:00}' -f $n
                $origin = $script:Base.AddMinutes(80 + $n)
                $front = @(
                    (AuthHello 'loop.contoso.test'), 'C STARTTLS', 'S 220 Ready', 'E |TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded'
                    'C EHLO loop.contoso.test', 'S 250 Hello', 'S 250 AUTH LOGIN', 'C NOOP', 'S 250 OK'
                    'C AUTH LOGIN', 'S 334 VXNlcm5hbWU6', "C $(B64 $script:Secrets.User)", 'S 334 UGFzc3dvcmQ6'
                    'E loop.user@contoso.test|authenticated', "C $(B64 $script:Secrets.Password)"
                    'E |Inbound session annotation', 'E |Inbound proxy annotation'
                    'E |Proxy session was successfully set up. Session for loop.user@contoso.test will now be proxied'
                    'S 235 2.7.0 Authentication successful', '-Local'
                )
                $rows = @(AuthSession "$server\Client Frontend $server" $sid 80 $local $remote $front)
                $rows.Count | Should -Be 23
                $key = if ($c['Other']) { 'Other' } else { 'FE' }
                $lines[$key] += TimedLoopbackRows $rows $feTimes $origin
                if ($c['Ambiguous']) { $lines[$key] += TimedLoopbackRows $rows $feTimes ($origin.AddMilliseconds(1)) }
                $authCommand = if ($c['NoTechnical']) { 'C NOOP' } else { "C X-EXPS EXCHANGEAUTH $($script:Secrets.Blob)" }
                $authReply = if ($c['RefusedAuth']) { 'S 535 Authentication refused' } elseif ($c['NoTechnical']) { 'S 250 OK' } else { 'S 235 2.7.0 Authentication successful' }
                $proxyReply = if ($c['NoProxyReply']) { 'E |No proxy reply' } elseif ($c['RefusedProxy']) { 'S 550 Proxy refused' } else { 'S 250 XPROXY OK' }
                $back = @(
                    (AuthHello "$server.contoso.test"), 'C STARTTLS', 'S 220 Ready', 'E |TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded'
                    "C EHLO $server.contoso.test", 'S 250 Hello', 'S 250 X-EXPS EXCHANGEAUTH'
                    $authCommand, 'S 334 challenge', 'E [unrecognized]|authenticated', $authReply
                    "C XPROXY SID=$sid IP=$ip PORT=$port DOMAIN=loop.contoso.test CAPABILITIES=0"
                    'E |Inbound proxy annotation', 'E |Inbound proxy annotation', $proxyReply
                    'C MAIL FROM:<sender@vendor.example>', 'S 250 Sender OK', 'C RCPT TO:<bob@contoso.test>', 'S 250 Recipient OK'
                    'C DATA', 'S 354 Start mail input', 'E |Inbound message annotation'
                    "S 250 2.6.0 <loop-$name@contoso.test> [InternalId=9001, Hostname=EXCH01.contoso.test] Queued mail for delivery"
                    'E |Inbound message annotation', 'C QUIT', 'S 221 bye', '-Local'
                )
                $rows = @(AuthSession 'EXCH01\Client Proxy EXCH01' $beSid 80 $hubLocal $peer $back)
                $rows.Count | Should -Be 30
                $key = if ($c['Mailbox']) { 'Mailbox' } else { 'Hub' }
                $lines[$key] += TimedLoopbackRows $rows $hubTimes $origin
            }
            foreach ($key in $paths.Keys) { Write-Log $paths[$key] $lines[$key] }
            [void](Invoke-TestCollection $s)
            $script:LoopbackTable = AuthTable $s '<loop-%'
            $script:LoopbackCases = $cases
        }
        It 'correlates real-shaped IPv4 and IPv6 loopback clients through the same physical host at 192ms' {
            foreach ($name in 'ipv4', 'ipv6') {
                $script:LoopbackTable["<loop-$name@contoso.test>"] | Should -Be 'loop.user@contoso.test|LOGIN|Succeeded|Succeeded|FrontEndProxy' -Because $name
            }
        }
        It 'rejects incompatible endpoints, source servers, roles and unowned or refused handshakes' {
            foreach ($name in $script:LoopbackCases.Keys | Where-Object { $_ -notin 'ipv4', 'ipv6', 'ambiguous' }) {
                $script:LoopbackTable.Contains("<loop-$name@contoso.test>") | Should -BeTrue -Because $name
                $script:LoopbackTable["<loop-$name@contoso.test>"] | Should -Not -Match 'loop.user@contoso.test' -Because $name
            }
        }
        It 'does not select either of two compatible front-end epochs sharing a SID' {
            $script:LoopbackTable['<loop-ambiguous@contoso.test>'] | Should -Be '||Unknown|Unknown|Ambiguous'
        }
    }

    # Review corrections: continuity of the front-end proof, barrier after the 235, long connections, mechanism of a failed attempt.
    Context 'review corrections' {
        BeforeAll {
            $u64 = B64 $script:Secrets.User; $p64 = B64 $script:Secrets.Password
            $alice = 'alice@contoso.test'
            $fe = 'EXCH01\Client Frontend EXCH01'; $feLocal = '10.0.0.1:587'; $cp = 'EXCH01\Client Proxy EXCH01'; $beLocal = '10.0.0.1:465'
            $pre = @('C AUTH LOGIN', 'S 334 VXNlcm5hbWU6', "C $u64", 'S 334 UGFzc3dvcmQ6', "C $p64")
            $ok = 'S 235 2.7.0 Authentication successful'; $bad = 'S 535 5.7.3 Authentication unsuccessful'
            $id = { param($u) "E $u|authenticated" }
            $px = { param($u) "E |Proxy session was successfully set up. Session for $u will now be proxied" }
            $plain = "C AUTH PLAIN $(B64 "`0$($script:Secrets.User)`0$($script:Secrets.Password)")"
            $smtp = '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
            $header = '#Software: Microsoft Exchange Server', '#Log-type: SMTP Receive Protocol Log', "#Date: $(T 0)", $smtp
            $recv = 'EXCH01\Exchange\TransportRoles\Logs\{0}\ProtocolLog\SmtpReceive\RECV2026100109-1.LOG'

            # Proxied cases: the steps of the front end between the greeting and the end of the session.
            $proxied = [ordered]@{
                p1  = @{ Steps = @($pre, (& $id $alice), (& $px $alice), $ok); Expect = "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy" }
                p2  = @{ Steps = @($pre, $ok, (& $id $alice), (& $px $alice)); Expect = "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy" }
                p3  = @{ Steps = @($pre, (& $id $alice), (& $px $alice), 'GAP', $ok); Expect = '||Unknown|Unknown|Missing' }
                p4  = @{ Steps = @($pre, $ok, 'GAP', (& $id $alice), (& $px $alice)); Expect = '||Unknown|Unknown|Missing' }
                p5  = @{ Steps = @($pre, (& $id $alice), 'GAP', (& $px $alice), $ok); Expect = '||Unknown|Unknown|Missing' }
                p6  = @{ Steps = @('C AUTH LOGIN', 'GAP', 'S 334 VXNlcm5hbWU6', "C $u64", 'S 334 UGFzc3dvcmQ6', "C $p64", (& $id $alice), (& $px $alice), $ok); Expect = '||Unknown|Unknown|Missing' }
                p7  = @{ Steps = @('GAP', $pre, (& $id $alice), (& $px $alice), $ok); Expect = "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy" }
                p8  = @{ Steps = @($pre, $ok, 'C NOOP', 'S 250 2.0.0 OK', (& $id $alice), (& $px $alice)); Expect = '||Unknown|Unknown|Missing' }
                p9  = @{ Steps = @($pre, $ok, (& $id $alice), (& $px 'bob@contoso.test')); Expect = '||Unknown|Unknown|Ambiguous' }
                p10 = @{ Steps = @($pre, (& $id $alice), (& $px $alice), $ok, $pre, $bad); Expect = '||Unknown|Unknown|Missing' }
                p11 = @{ Steps = @($pre, (& $id $alice), (& $px $alice), $ok, 'C STARTTLS', 'S 220 2.0.0 SMTP server ready', 'E |TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded using bulk encryption algorithm CALG_AES_256'); Expect = '||Unknown|Unknown|Missing' }
                p12 = @{ Steps = @($pre, $bad, $pre, (& $id $alice), (& $px $alice), $ok); Expect = "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy" }
            }
            # Direct cases (server log of the session that received the submission).
            $tx = { param($n) AuthTx "s-$n@vendor.example" "msg-reg-$n" }
            $direct = [ordered]@{
                g1  = @{ Steps = @($pre, $bad, (& $tx 'g1')); Expect = @{ g1 = '|LOGIN|Failed|Failed|NotApplicable' } }
                g2  = @{ Steps = @($plain, $bad, (& $tx 'g2')); Expect = @{ g2 = '|PLAIN|Failed|Failed|NotApplicable' } }
                g3  = @{ Steps = @($plain, (& $id $alice), $ok, 'C AUTH LOGIN', 'S 503 5.5.1 Already authenticated', (& $tx 'g3')); Expect = @{ g3 = "$alice|PLAIN|Succeeded|Failed|Direct" } }
                g4  = @{ Steps = @($plain, (& $id $alice), $ok, $plain, $bad, (& $tx 'g4')); Expect = @{ g4 = '||Unknown|Failed|Ambiguous' } }
                g5  = @{ Steps = @($pre, $bad, (& $tx 'g5a'), $pre, (& $id $alice), $ok, (& $tx 'g5b')); Expect = @{ g5a = '|LOGIN|Failed|Failed|NotApplicable'; g5b = "$alice|LOGIN|Succeeded|Succeeded|Direct" } }
                g6  = @{ Steps = @($plain, $ok, 'C NOOP', 'S 250 2.0.0 OK', (& $id $alice), (& $tx 'g6')); Expect = @{ g6 = '|PLAIN|Succeeded|Succeeded|Missing' } }
                g7  = @{ Steps = @($plain, $ok, (& $id $alice), (& $tx 'g7')); Expect = @{ g7 = "$alice|PLAIN|Succeeded|Succeeded|Direct" } }
                g8  = @{ Steps = @($plain, $ok, (& $id $alice), (& $id 'bob@contoso.test'), (& $tx 'g8')); Expect = @{ g8 = '||Unknown|Succeeded|Ambiguous' } }
            }

            $script:RegDir = Join-Path $TestDrive 'smtp-auth-regression'
            $script:RegSettings = Import-ExlConfiguration -Path (New-TestConfig $script:RegDir) -Root $script:Root
            $feLines = @($header); $hubLines = @($header)
            $n = 0
            foreach ($name in $proxied.Keys) {
                $n++
                $sid = '08DA0000000F{0:0000}' -f $n; $ip = "10.3.0.$n"; $port = 50000 + $n; $helo = "r$n.contoso.test"
                $feLines += AuthSession $fe $sid (60 + $n * 0.5) $feLocal "${ip}:$port" @((AuthHello $helo), $proxied[$name].Steps, '-Local')
                $hubLines += AuthSession $cp ('08DA0000000E{0:0000}' -f $n) (60.1 + $n * 0.5) $beLocal "10.0.0.1:$(42000 + $n)" @(AuthBack $sid $ip $port $helo "sender-$name@vendor.example" "msg-reg-$name")
            }
            foreach ($name in $direct.Keys) {
                $n++
                $feLines += AuthSession $fe ('08DA0000000D{0:0000}' -f $n) (60 + $n * 0.5) $feLocal "10.3.1.${n}:51000" @((AuthHello "d$n.contoso.test"), $direct[$name].Steps, 'C QUIT', 'S 221 bye', '-Local')
            }
            Write-Log (Join-Path (Join-Path $script:RegDir 'logs-src') ($recv -f 'FrontEnd')) $feLines
            Write-Log (Join-Path (Join-Path $script:RegDir 'logs-src') ($recv -f 'Hub')) $hubLines
            [void](Invoke-TestCollection $script:RegSettings)
            $script:RegTable = AuthTable $script:RegSettings '<msg-reg-%'
            $script:RegProxied = $proxied; $script:RegDirect = $direct
        }
        It 'keeps a front-end proof only when the attempt is covered without a gap, and keeps the valid and retried proofs' {
            foreach ($name in $script:RegProxied.Keys) {
                $script:RegTable["<msg-reg-$name@contoso.test>"] | Should -Be $script:RegProxied[$name].Expect -Because $name
            }
        }
        It 'does not attribute an identity written after a command that is not part of the authentication, and never takes the first of two conflicting annotations' {
            foreach ($name in 'g6', 'g7', 'g8') {
                foreach ($message in $script:RegDirect[$name].Expect.Keys) { $script:RegTable["<msg-reg-$message@contoso.test>"] | Should -Be $script:RegDirect[$name].Expect[$message] -Because $name }
            }
            $script:RegTable['<msg-reg-p8@contoso.test>'] | Should -Be '||Unknown|Unknown|Missing'
            $script:RegTable['<msg-reg-p9@contoso.test>'] | Should -Be '||Unknown|Unknown|Ambiguous'
        }
        It 'keeps the mechanism of the attempt after a failure and after a refusal following a success' {
            foreach ($name in 'g1', 'g2', 'g3', 'g4', 'g5') {
                foreach ($message in $script:RegDirect[$name].Expect.Keys) { $script:RegTable["<msg-reg-$message@contoso.test>"] | Should -Be $script:RegDirect[$name].Expect[$message] -Because $name }
            }
            $report = AuthReport $script:RegSettings
            $csv = @(AuthCsv $report 'SmtpSessions')
            ($csv | Where-Object 'Message ID' -EQ '<msg-reg-g1@contoso.test>').'Authentication mechanism' | Should -Be 'LOGIN'
            ($csv | Where-Object 'Message ID' -EQ '<msg-reg-g1@contoso.test>').'Authenticated user' | Should -Be 'Not available'
            (Get-ChildItem -LiteralPath $report.Folder -Filter '*.csv' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join '' | Should -Not -Match 'SENTINEL'
        }
        It 'binds Alice at the original handshake across commit and restart, while later Bob and explicit 503 only affect new handshakes' {
            foreach ($change in 'Bob', '503') {
                foreach ($order in 'FE,Hub', 'Hub,FE') {
                    $dir = Join-Path $TestDrive "smtp-auth-history-$change-$($order.Replace(',', '-'))"
                    $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
                    $sid = '08DA000000001A01'; $oldSid = '08DA000000001B01'; $newSid = '08DA000000001B02'
                    $fePath = Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')
                    $hubPath = Join-Path (Join-Path $dir 'logs-src') ($recv -f 'Hub')
                    $a = @(AuthSession $fe $sid 100 $feLocal '10.3.8.1:54000' @((AuthHello 'historical.contoso.test'), (AuthLogin $alice -Proxied)))
                    $a += AuthSession $fe $sid 100.2 $feLocal '10.3.8.1:54000' @(AuthTx 'sender@vendor.example' 'hist-direct-a') -FirstSequence $a.Count
                    $back = @(AuthBack $sid '10.3.8.1' 54000 'historical.contoso.test' 'sender@vendor.example' 'hist-old-a' | Select-Object -SkipLast 3)
                    $b = @(AuthSession $cp $oldSid 100.1 $beLocal '10.0.0.1:44001' $back)
                    foreach ($part in $order.Split(',')) {
                        $path = if ($part -eq 'FE') { $fePath } else { $hubPath }
                        $lines = if ($part -eq 'FE') { $a } else { $b }
                        Write-Log $path @($header + $lines)
                        [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddHours(-1))
                        [void](Invoke-TestCollection $s)
                    }
                    (AuthTable $s '<hist-%')['<hist-old-a@contoso.test>'] | Should -Be "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy"
                    $changeSteps = if ($change -eq 'Bob') {
                        @($plain, (& $id 'bob@contoso.test'), (& $px 'bob@contoso.test'), $ok)
                    } else { @($plain, 'S 503 5.5.1 Already authenticated') }
                    $more = @(AuthSession $fe $sid 101 $feLocal '10.3.8.1:54000' $changeSteps -FirstSequence $a.Count)
                    $more += AuthSession $fe $sid 101.2 $feLocal '10.3.8.1:54000' @((AuthTx 'sender@vendor.example' 'hist-direct-b'), '-Local') -FirstSequence ($a.Count + $more.Count)
                    $fe2 = $fePath.Replace('-1.LOG', '-2.LOG')
                    Write-Log $fe2 @($header + $more)
                    $hub2 = $hubPath.Replace('-1.LOG', '-2.LOG')
                    $late = @(AuthSession $cp $oldSid 101.3 $beLocal '10.0.0.1:44001' @((AuthTx 'sender@vendor.example' 'hist-old-b'), '-Local') -FirstSequence $b.Count)
                    $late += AuthSession $cp $newSid 101.1 $beLocal '10.0.0.1:44002' @(AuthBack $sid '10.3.8.1' 54000 'historical.contoso.test' 'sender@vendor.example' 'hist-new')
                    Write-Log $hub2 @($header + $late)
                    [void](Invoke-TestCollection $s)
                    $table = AuthTable $s '<hist-%'
                    foreach ($message in 'hist-old-a', 'hist-old-b') { $table["<$message@contoso.test>"] | Should -Be "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy" -Because "$change $order $message" }
                    $user = if ($change -eq 'Bob') { 'bob@contoso.test' } else { $alice }
                    $mech = if ($change -eq 'Bob') { 'PLAIN' } else { 'LOGIN' }
                    $attempt = if ($change -eq 'Bob') { 'Succeeded' } else { 'Failed' }
                    $table['<hist-new@contoso.test>'] | Should -Be "$user|$mech|Succeeded|$attempt|FrontEndProxy"
                    $table['<hist-direct-a@contoso.test>'] | Should -Be "$alice|LOGIN|Succeeded|Succeeded|Direct"
                    $table['<hist-direct-b@contoso.test>'] | Should -Be "$user|$mech|Succeeded|$attempt|Direct"
                    (Invoke-TestCollection $s).Lines | Should -Be 0
                }
            }
        }
        It 'retracts a contradictory historical interval after restart without changing an independent later Bob interval' {
            $dir = Join-Path $TestDrive 'smtp-auth-historical-conflict'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $sid = '08DA000000002A01'
            $fePath = Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')
            $a = @(AuthSession $fe $sid 110 $feLocal '10.3.8.2:54001' @((AuthHello 'conflict.contoso.test'), (AuthLogin $alice -Proxied)))
            $a += AuthSession $fe $sid 110.2 $feLocal '10.3.8.2:54001' @('C NOOP', 'S 250 OK') -FirstSequence $a.Count
            Write-Log $fePath @($header + $a)
            [IO.File]::SetLastWriteTimeUtc($fePath, [DateTime]::UtcNow.AddHours(-1))
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'Hub')) @($header + @(AuthSession $cp '08DA000000002B01' 110.1 $beLocal '10.0.0.1:44003' @(AuthBack $sid '10.3.8.2' 54001 'conflict.contoso.test' 'sender@vendor.example' 'conflict-old')))
            [void](Invoke-TestCollection $s)
            (AuthTable $s '<conflict-%')['<conflict-old@contoso.test>'] | Should -Be "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy"
            $store = Open-ExlStore -Settings $s
            try { $store.Exec("UPDATE smtp_auth_fragment SET observations=replace(observations,'alice@contoso.test','wrong@contoso.test'), conflicted=1, conflict_positions='9' WHERE session_id='$sid';") } finally { $store.Dispose() }
            $more = @(AuthSession $fe $sid 111 $feLocal '10.3.8.2:54001' @($plain, (& $id 'bob@contoso.test'), (& $px 'bob@contoso.test'), $ok) -FirstSequence $a.Count)
            $more += AuthSession $fe $sid 111.2 $feLocal '10.3.8.2:54001' @('C NOOP', 'S 250 OK', '-Local') -FirstSequence ($a.Count + $more.Count)
            Write-Log ($fePath.Replace('-1.LOG', '-2.LOG')) @($header + $more)
            Write-Log (Join-Path (Join-Path $dir 'logs-src') (($recv -f 'Hub').Replace('-1.LOG', '-2.LOG'))) @($header + @(AuthSession $cp '08DA000000002B02' 111.1 $beLocal '10.0.0.1:44004' @(AuthBack $sid '10.3.8.2' 54001 'conflict.contoso.test' 'sender@vendor.example' 'conflict-new')))
            [void](Invoke-TestCollection $s)
            $table = AuthTable $s '<conflict-%'
            $table['<conflict-old@contoso.test>'] | Should -Be '||Unknown|Unknown|Ambiguous'
            $table['<conflict-new@contoso.test>'] | Should -Be 'bob@contoso.test|PLAIN|Succeeded|Succeeded|FrontEndProxy'
            (Invoke-TestCollection $s).Lines | Should -Be 0
        }
        It 'does not bind a future AUTH, an unobserved suffix, or a future valid EHLO to an earlier handshake' {
            foreach ($variant in 'future', 'suffix', 'helo') {
                $dir = Join-Path $TestDrive "smtp-auth-no-retroactive-$variant"
                $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
                $sid = '08DA000000004A01'
                $fePath = Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')
                $start = if ($variant -eq 'future') { 131 } else { 130 }
                $a = @(AuthSession $fe $sid $start $feLocal '10.3.8.4:54003' @((AuthHello 'time.contoso.test'), (AuthLogin $alice -Proxied)))
                if ($variant -ne 'suffix') { $a += AuthSession $fe $sid 131.2 $feLocal '10.3.8.4:54003' @('C NOOP', 'S 250 OK', '-Local') -FirstSequence $a.Count }
                Write-Log $fePath @($header + $a)
                [IO.File]::SetLastWriteTimeUtc($fePath, [DateTime]::UtcNow.AddHours(-1))
                $back = @(AuthBack $sid '10.3.8.4' 54003 'time.contoso.test' 'sender@vendor.example' "time-$variant" | Select-Object -SkipLast 3)
                if ($variant -eq 'helo') { $back[2] = 'C EHLO impostor.contoso.test'; $back += 'C EHLO EXCH01.contoso.test'; $back += 'S 250 OK' }
                Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'Hub')) @($header + @(AuthSession $cp '08DA000000004B01' 130.1 $beLocal '10.0.0.1:44005' @($back, '-Local')))
                [void](Invoke-TestCollection $s)
                (AuthTable $s '<time-%')["<time-$variant@contoso.test>"] | Should -Be '||Unknown|Unknown|Missing' -Because $variant
            }
        }
        It 'requires an owned 235, preserves the real-shaped asynchronous handoff, and fails closed after reply-queue overflow' {
            $dir = Join-Path $TestDrive 'smtp-auth-response-owner'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $lines = @($header)
            $n = 0
            foreach ($reply in '220 not AUTH success', '250 not AUTH success', '235 AUTH success') {
                $n++
                $lines += AuthSession $fe "08DA000000005A0$n" (140 + $n) $feLocal "10.3.8.5:$(55000 + $n)" @((AuthHello 'owned.contoso.test'), $plain, (& $id $alice), "S $reply", (AuthTx 'sender@vendor.example' "owner-$n"), '-Local')
            }
            $lines += AuthSession $fe '08DA000000005A04' 144 $feLocal '10.3.8.5:55004' @((AuthHello 'owned.contoso.test'), (@('C NOOP') * 9), $plain, (& $id $alice), $ok, (AuthTx 'sender@vendor.example' 'owner-4'), '-Local')
            $sid = '08DA000000005A05'
            $a = @(AuthSession $fe $sid 145 $feLocal '10.3.8.5:55005' @((AuthHello 'owned.contoso.test'), $pre, (& $id $alice)))
            $a += AuthSession $fe $sid 145.05 $feLocal '10.3.8.5:55005' @((& $px $alice)) -FirstSequence $a.Count
            $a += AuthSession $fe $sid 145.07 $feLocal '10.3.8.5:55005' @($ok, '-Local') -FirstSequence $a.Count
            $lines += $a
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) $lines
            $back = @(AuthSession $cp '08DA000000005B05' 145.01 $beLocal '10.0.0.1:44006' @((AuthHello 'EXCH01.contoso.test'), "C X-EXPS EXCHANGEAUTH $($script:Secrets.Blob)", 'E [unrecognized]|authenticated', $ok))
            $back += AuthSession $cp '08DA000000005B05' 145.04 $beLocal '10.0.0.1:44006' @("C XPROXY SID=$sid IP=10.3.8.5 PORT=55005 DOMAIN=owned.contoso.test") -FirstSequence $back.Count
            $back += AuthSession $cp '08DA000000005B05' 145.06 $beLocal '10.0.0.1:44006' @('S 250 XPROXY OK') -FirstSequence $back.Count
            $back += AuthSession $cp '08DA000000005B05' 145.08 $beLocal '10.0.0.1:44006' @((AuthTx 'different-sender@vendor.example' 'owner-async'), '-Local') -FirstSequence $back.Count
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'Hub')) @($header + $back)
            [void](Invoke-TestCollection $s)
            $table = AuthTable $s '<owner-%'
            foreach ($i in 1, 2, 4) { $table["<owner-$i@contoso.test>"] | Should -Not -Match '^alice@' }
            $table['<owner-3@contoso.test>'] | Should -Be "$alice|PLAIN|Succeeded|Succeeded|Direct"
            $table['<owner-async@contoso.test>'] | Should -Be "$alice|LOGIN|Succeeded|Succeeded|FrontEndProxy"
        }
        It 'rolls back fragments, enrichment and file offsets atomically and restores the same FileWork before a fresh Collector retries' {
            foreach ($batch in 1, 32, 500000) {
                foreach ($stage in 'fragment', 'auth', 'offset') {
                    $dir = Join-Path $TestDrive "smtp-auth-rollback-$batch-$stage"
                    $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
                    $path = Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')
                    $steps = foreach ($i in 1..30) { AuthTx 'sender@vendor.example' "rollback-$i" }
                    Write-Log $path @($header + @(AuthSession $fe '08DA000000006A01' 150 $feLocal '10.3.8.6:55006' @((AuthHello 'rollback.contoso.test'), (AuthPlain $alice), $steps, '-Local')))
                    $store = Open-ExlStore -Settings $s
                    try {
                        $o = [ExchangeLogReport.CollectorOptions]::new()
                        $o.RunId = $store.StartRun('Collect', 'rollback', 'synthetic', '1.0.0')
                        $o.BatchRows = $batch; $o.BatchSeconds = 3600; $o.Parallelism = 6
                        $o.MaxFilesPerServer = 1; $o.DetailCutoffMs = $o.NowMs
                        $o.DisableTriggersDuringApply = $false   # the failures below are injected by SQL triggers, which only run on a connection that has triggers on
                        $job = [ExchangeLogReport.SourceJob]::new()
                        $job.Server = 'EXCH01'; $job.Kind = 'SmtpReceive'; $job.Role = 'FrontEnd'; $job.Folder = Split-Path $path
                        $job.Filter = [IO.Path]::GetFileName($path)
                        $collector = [ExchangeLogReport.Collector]::new($store, $o)
                        $collector.Plan(@($job), [DateTime]::MinValue)
                        $job.Files.Count | Should -Be 1
                        $trigger = switch ($stage) {
                            'fragment' { 'BEFORE INSERT ON smtp_auth_fragment' }
                            'auth' { 'BEFORE UPDATE OF auth_user ON smtp_transaction' }
                            'offset' { 'BEFORE UPDATE OF offset ON source_file' }
                        }
                        $store.Exec("CREATE TRIGGER fail_smtp $trigger BEGIN SELECT RAISE(ABORT,'synthetic rollback'); END;")
                        $run = $collector.Start(@($job))
                        while (-not $run.Wait(1000)) { }
                        $run.Error | Should -Not -BeNullOrEmpty
                        $store.Query('SELECT COUNT(*) FROM smtp_transaction', $null).Rows[0][0] | Should -Be 0
                        $store.Query('SELECT COUNT(*) FROM smtp_auth_fragment', $null).Rows[0][0] | Should -Be 0
                        $store.Query('SELECT COUNT(*) FROM source_file WHERE offset>0', $null).Rows[0][0] | Should -Be 0
                        $state = $job.Files[0].State
                        @($state.Id, $state.Offset, $state.Lines, $state.Kept, $state.Noise) | Should -Be @(0L, 0L, 0L, 0L, 0L)
                        @(Get-ChildItem -LiteralPath (Split-Path $s.Storage.DatabasePath) -Force -Filter '.report-*').Count | Should -Be 0
                        $store.Exec('DROP TRIGGER fail_smtp;')
                        $job.FilesApplied = 0
                        $retry = [ExchangeLogReport.Collector]::new($store, $o)
                        $run = $retry.Start(@($job))
                        while (-not $run.Wait(1000)) { }
                        $run.Error | Should -BeNullOrEmpty
                        $store.Query("SELECT COUNT(*),SUM(auth_user='$alice' AND auth_source='Direct' AND auth_mechanism='PLAIN') FROM smtp_transaction", $null).Rows[0] -join '|' | Should -Be '30|30'
                        $state.Offset | Should -Be ([IO.FileInfo]::new($path).Length)
                        $state.Id | Should -BeGreaterThan 0
                        $again = [ExchangeLogReport.Collector]::new($store, $o)
                        $again.Plan(@($job), [DateTime]::MinValue)
                        $job.Files.Count | Should -Be 0
                    } finally { $store.Dispose() }
                }
            }
        }
        It 'keeps replay pages and MAIL lookup pages isolated across identity resets and repeated enrichment' {
            $dir = Join-Path $TestDrive 'smtp-auth-reused-pages'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $steps = @((AuthHello 'reuse.contoso.test'), (AuthPlain $alice))
            $tls = @('C STARTTLS', 'S 220 Ready', 'E |TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded using bulk encryption algorithm CALG_AES_256', 'C EHLO reuse.contoso.test', 'S 250 Hello')
            foreach ($phase in 'first', 'second', 'none') {
                if ($phase -eq 'second') { $steps += $tls; $steps += @(AuthPlain 'bob@contoso.test') }
                if ($phase -eq 'none') { $steps += $tls }
                foreach ($i in 1..270) { $steps += @(AuthTx "$phase$i@vendor.example" "reuse-$phase-$i") }
            }
            $steps += '-Local'
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) @($header + @(AuthSession $fe '08DA000000008A01' 158 $feLocal '10.3.8.8:55009' $steps))
            [void](Invoke-TestCollection $s)
            $store = Open-ExlStore -Settings $s
            $resolver = $null; $writer = $null; $tx = $null
            try {
                $first = $store.Query("SELECT MIN(id) FROM smtp_transaction WHERE message_id LIKE '<reuse-first-%';", $null).Rows[0][0]
                $columns = @($store.Query('PRAGMA table_info(smtp_transaction);', $null).Rows | ForEach-Object { $_[1] } | Where-Object { $_ -ne 'id' })
                foreach ($copy in 1..280) {
                    $values = foreach ($column in $columns) {
                        switch ($column) {
                            'time_ms' { "time_ms+$copy" }
                            'end_ms' { "end_ms+$copy" }
                            'message_id' { "'<reuse-copy-$copy@contoso.test>'" }
                            default { "[$column]" }
                        }
                    }
                    $store.Exec("INSERT INTO smtp_transaction($($columns -join ',')) SELECT $($values -join ',') FROM smtp_transaction WHERE id=$first;")
                }
                $store.Exec("UPDATE smtp_transaction SET auth_user='stale@test',auth_mechanism='stale',auth_result='stale',auth_attempt_result='stale',auth_source='stale',auth_evidence_id=NULL;")
                $engine = [ExchangeLogReport.Collector].Assembly
                $writer = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.Writer'), [object[]]@($store))
                $resolver = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.AuthResolver'), [object[]]@($store, $writer, [long]600000))
                $tx = $store.Begin(); $writer.Use($tx)
                $resolver.Touch('EXCH01', 'Receive', 'FrontEnd', '08DA000000008A01'); $resolver.Flush($tx)
                $resolver.Updated | Should -Be 1090
                $resolver.Touch('EXCH01', 'Receive', 'FrontEnd', '08DA000000008A01'); $resolver.Flush($tx)
                $resolver.Updated | Should -Be 1090
                $tx.Commit(); $tx.Dispose(); $tx = $null
                $store.Query("SELECT COUNT(*) FROM smtp_transaction WHERE (message_id LIKE '<reuse-first-%' OR message_id LIKE '<reuse-copy-%') AND auth_user='$alice' AND auth_mechanism='PLAIN' AND auth_result='Succeeded' AND auth_attempt_result='Succeeded' AND auth_source='Direct' AND auth_evidence_id>0;", $null).Rows[0][0] | Should -Be 550
                $store.Query("SELECT COUNT(*) FROM smtp_transaction WHERE message_id LIKE '<reuse-second-%' AND auth_user='bob@contoso.test' AND auth_mechanism='PLAIN' AND auth_source='Direct' AND auth_evidence_id>0;", $null).Rows[0][0] | Should -Be 270
                $store.Query("SELECT COUNT(*) FROM smtp_transaction WHERE message_id LIKE '<reuse-none-%' AND auth_user IS NULL AND auth_mechanism IS NULL AND auth_result='Not attempted' AND auth_attempt_result='Not attempted' AND auth_source='NotApplicable' AND auth_evidence_id IS NULL;", $null).Rows[0][0] | Should -Be 270
            } finally {
                if ($tx) { $tx.Dispose() }
                if ($resolver) { $resolver.Dispose() }
                if ($writer) { $writer.Dispose() }
                $store.Dispose()
            }
            @(Get-ChildItem -LiteralPath (Split-Path $s.Storage.DatabasePath) -Filter '.report-*' -Force).Count | Should -Be 0
        }
        It 'replays legacy six-cell format-1 aliases beside format-2 parts without changing retained transaction IDs or offsets' {
                $dir = Join-Path $TestDrive 'smtp-auth-format-aliases'
                $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
                New-AuthLogs (Join-Path $dir 'logs-src')
                [void](Invoke-TestCollection $s)
                $before = AuthJson $s
                $ids = (Query $s 'SELECT id,auth_sequence FROM smtp_transaction ORDER BY id') | ForEach-Object { $_ -join '|' }
                $offsets = (Query $s 'SELECT id,offset,lines,kept,noise FROM source_file ORDER BY id') | ForEach-Object { $_ -join '|' }
                $store = Open-ExlStore -Settings $s
                try {
                    $store.Exec(@"
INSERT INTO smtp_auth_fragment(source_file_id,source_key,first_offset,part,first_ms,last_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,first_sequence,last_sequence,complete_start,complete_end,coverage,proxy_sid,proxy_ip,proxy_port,proxy_helo,observations,conflicted)
SELECT source_file_id,source_key,first_offset,-1-part,origin_first_ms,last_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,first_sequence,last_sequence,complete_start,complete_end,coverage,proxy_sid,proxy_ip,proxy_port,proxy_helo,
(SELECT json_group_array(json_array(json_extract(value,'$[0]'),json_extract(value,'$[1]'),json_extract(value,'$[2]'),json_extract(value,'$[3]'),json_extract(value,'$[4]'),json_extract(value,'$[5]'))) FROM json_each(f.observations)),conflicted
FROM smtp_auth_fragment f WHERE evidence_format=2;
UPDATE smtp_transaction SET auth_fragment_id=(
 SELECT l.id FROM smtp_auth_fragment old JOIN smtp_auth_fragment l
 ON l.server=old.server AND l.direction=old.direction AND l.role=old.role AND l.source_key=old.source_key
 AND l.session_id=old.session_id AND l.first_offset=old.first_offset AND l.first_ms=old.origin_first_ms
 AND l.part=-1-old.part AND l.evidence_format IS NULL
 WHERE old.id=smtp_transaction.auth_fragment_id
) WHERE auth_fragment_id IS NOT NULL;
"@)
                } finally { $store.Dispose() }
                $references = (Query $s 'SELECT id,auth_fragment_id FROM smtp_transaction ORDER BY id') | ForEach-Object { $_ -join '|' }
                foreach ($pass in 1, 2) {
                    $store = Open-ExlStore -Settings $s
                    try {
                        $engine = [ExchangeLogReport.Collector].Assembly
                        $writer = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.Writer'), [object[]]@($store))
                        $resolver = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.AuthResolver'), [object[]]@($store, $writer, [long]600000))
                        $scopes = $store.Query('SELECT DISTINCT server,direction,role,session_id FROM smtp_auth_fragment', $null).Rows
                        $tx = $store.Begin()
                        try {
                            $writer.Use($tx)
                            foreach ($scope in $scopes) { $resolver.Touch($scope[0], $scope[1], $scope[2], $scope[3]) }
                            $resolver.Flush($tx)
                            $tx.Commit()
                        } finally { $resolver.Dispose(); $writer.Dispose(); $tx.Dispose() }
                    } finally { $store.Dispose() }
                    AuthJson $s | Should -Be $before
                    (Query $s 'SELECT id,auth_sequence FROM smtp_transaction ORDER BY id') | ForEach-Object { $_ -join '|' } | Should -Be $ids
                    (Query $s 'SELECT id,auth_fragment_id FROM smtp_transaction ORDER BY id') | ForEach-Object { $_ -join '|' } | Should -Be $references
                    (Query $s 'SELECT id,offset,lines,kept,noise FROM source_file ORDER BY id') | ForEach-Object { $_ -join '|' } | Should -Be $offsets
                    (Invoke-TestCollection $s).Lines | Should -Be 0
                }
            }
        It 'continues after coverage and encoded-byte early seals and maps MAIL to the part that actually contains it' {
                $dir = Join-Path $TestDrive 'smtp-auth-early-seals'
                $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
                $gaps = foreach ($i in 1..150) { 'C NOOP'; 'S 250 OK'; 'GAP' }
                $wide = ('用户' * 240) + '@test'
                $annotations = foreach ($i in 1..300) { & $id $wide }
                $mails = foreach ($i in 1..300) { "C MAIL FROM:<wide$i@vendor.example>"; 'S 250 OK' }
                $lines = @($header)
                $lines += AuthSession $fe '08DA000000007A01' 155 $feLocal '10.3.8.7:55007' @((AuthHello 'coverage.contoso.test'), (AuthPlain $alice), $gaps, (AuthTx 'sender@vendor.example' 'gap-before'), (AuthPlain 'recovered@contoso.test'), (AuthTx 'sender@vendor.example' 'gap-after'), '-Local')
                $lines += AuthSession $fe '08DA000000007A02' 156 $feLocal '10.3.8.7:55008' @((AuthHello 'bytes.contoso.test'), (AuthPlain $wide), $annotations, $mails, (AuthTx 'sender@vendor.example' 'byte-after'), '-Local')
                Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) $lines
                [void](Invoke-TestCollection $s)
                $table = AuthTable $s '<gap-%'
                $table['<gap-before@contoso.test>'] | Should -Be '||Unknown|Unknown|Missing'
                $table['<gap-after@contoso.test>'] | Should -Be 'recovered@contoso.test|PLAIN|Succeeded|Succeeded|Direct'
                (Query $s "SELECT COUNT(*),SUM(auth_user='$wide' AND auth_source='Direct') FROM smtp_transaction WHERE session_id='08DA000000007A02'")[0] -join '|' | Should -Be '301|301'
                (Query $s "SELECT MAX(json_array_length(observations)),MAX(length(CAST(observations AS BLOB))),MAX(1+length(coverage)-length(replace(coverage,',',''))) FROM smtp_auth_fragment WHERE session_id IN ('08DA000000007A01','08DA000000007A02')")[0][0] | Should -BeLessOrEqual 256
                (Query $s "SELECT MAX(length(CAST(observations AS BLOB))) FROM smtp_auth_fragment WHERE session_id='08DA000000007A02'")[0][0] | Should -BeLessOrEqual 128KB
                (Query $s "SELECT MAX(1+length(coverage)-length(replace(coverage,',',''))) FROM smtp_auth_fragment WHERE session_id='08DA000000007A01'")[0][0] | Should -BeLessOrEqual 64
                (Query $s "SELECT COUNT(*) FROM smtp_transaction t JOIN smtp_auth_fragment f ON f.id=t.auth_fragment_id WHERE t.session_id IN ('08DA000000007A01','08DA000000007A02') AND NOT EXISTS(SELECT 1 FROM json_each(f.observations) WHERE json_extract(value,'$[0]')='M' AND json_extract(value,'$[2]')=t.auth_sequence)")[0][0] | Should -Be 0
                (Query $s "SELECT COUNT(*) FROM smtp_auth_fragment WHERE session_id='08DA000000007A02' AND json_array_length(observations)<250 AND length(CAST(observations AS BLOB))>100000")[0][0] | Should -BeGreaterThan 0
            }
        It 'carries a connection of more than 8192 observations in bounded parts, without losing one transaction' {
            $dir = Join-Path $TestDrive 'smtp-auth-long'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $count = 8300
            $mails = foreach ($i in 1..$count) { "C MAIL FROM:<u$i@vendor.example>"; 'S 250 2.1.0 Sender OK' }
            $lines = @($header) + (AuthSession $fe '08DA000000000E01' 60 $feLocal '10.3.2.1:52000' @((AuthHello 'huge.contoso.test'), (AuthPlain 'long.user@contoso.test'), $mails, 'C QUIT', 'S 221 bye', '-Local'))
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) $lines
            [void](Invoke-TestCollection $s)
            (Query $s "SELECT COUNT(*), SUM(auth_user = 'long.user@contoso.test' AND auth_source = 'Direct' AND auth_result = 'Succeeded') FROM smtp_transaction WHERE session_id = '08DA000000000E01'")[0] -join '|' | Should -Be "$count|$count"
            $frag = (Query $s "SELECT COUNT(*), MIN(part), MAX(json_array_length(observations)), SUM(complete_end), MAX(LENGTH(observations)) FROM smtp_auth_fragment WHERE session_id = '08DA000000000E01'")[0]
            $frag[0] | Should -BeGreaterOrEqual ([math]::Ceiling($count / 256))
            $frag[1] | Should -Be (-$frag[0])
            $frag[2] | Should -BeLessOrEqual 256
            $frag[3] | Should -Be 1
            $frag[4] | Should -BeLessThan 30000
        }
        It 'does not keep a connection in memory: the evidence of a long connection is written in parts and the spool is removed afterwards' {
            $dir = Join-Path $TestDrive 'smtp-auth-spool'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $mails = foreach ($i in 1..3000) { "C MAIL FROM:<k$i@vendor.example>"; 'S 250 2.1.0 Sender OK' }
            $lines = @($header) + (AuthSession $fe '08DA000000000E03' 60 $feLocal '10.3.2.3:52002' @((AuthHello 'spool.contoso.test'), (AuthPlain 'spool.user@contoso.test'), $mails, 'C QUIT', 'S 221 bye', '-Local'))
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) $lines
            [void](Invoke-TestCollection $s)
            @(Get-ChildItem -LiteralPath (Join-Path $dir 'data') -Force | Where-Object Name -Like '.report-*') | Should -BeNullOrEmpty
            (Query $s "SELECT COUNT(*) FROM smtp_transaction WHERE session_id = '08DA000000000E03' AND auth_source = 'Direct'")[0][0] | Should -Be 3000
        }
        It 'does not limit the lifetime of a connection: 65600 transactions of one session are all attributed, without any "Overflow" reason' {
            $dir = Join-Path $TestDrive 'smtp-auth-overflow'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $count = 65600
            $mails = foreach ($i in 1..$count) { "C MAIL FROM:<o$i@vendor.example>"; 'S 250 2.1.0 Sender OK' }
            $lines = @($header) + (AuthSession $fe '08DA000000000E02' 60 $feLocal '10.3.2.2:52001' @((AuthHello 'over.contoso.test'), (AuthPlain 'over.user@contoso.test'), $mails, 'C QUIT', 'S 221 bye', '-Local'))
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) $lines
            [void](Invoke-TestCollection $s)
            $rows = Query $s "SELECT auth_source, COUNT(*), COUNT(DISTINCT auth_sequence), MIN(auth_user), MAX(auth_user), MIN(auth_result) FROM smtp_transaction WHERE session_id = '08DA000000000E02' GROUP BY auth_source"
            @($rows).Count | Should -Be 1
            @($rows[0]) -join '|' | Should -Be "Direct|$count|$count|over.user@contoso.test|over.user@contoso.test|Succeeded"
            (Query $s "SELECT COUNT(*), MAX(json_array_length(observations)), SUM(complete_end) FROM smtp_auth_fragment WHERE session_id = '08DA000000000E02'")[0][1] | Should -BeLessOrEqual 256
            (Query $s "SELECT COUNT(*) FROM smtp_auth_fragment WHERE session_id = '08DA000000000E02'")[0][0] | Should -BeGreaterOrEqual ([math]::Ceiling($count / 256))
            (Query $s "SELECT COUNT(*) FROM smtp_transaction WHERE auth_source = 'Overflow'")[0][0] | Should -Be 0
            # A development-only size-limit reason is unavailable evidence, never a new result.
            $store = Open-ExlStore -Settings $script:RegSettings
            try { $store.Exec("UPDATE smtp_transaction SET auth_source = 'Overflow', auth_user = NULL, auth_result = 'Unknown' WHERE message_id = '<msg-reg-g7@contoso.test>';") } finally { $store.Dispose() }
            $row = @(AuthCsv (AuthReport $script:RegSettings) 'SmtpSessions') | Where-Object 'Message ID' -EQ '<msg-reg-g7@contoso.test>'
            @($row.'Authenticated user', $row.'Identity evidence') | Should -Be @('Not available', 'Missing')
        }
        It 'keeps the identity exact at the sealing boundaries of a part (255, 256 and 257 transactions)' {
            $dir = Join-Path $TestDrive 'smtp-auth-edges'
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
            $steps = @()
            $n = 0
            foreach ($size in 255, 256, 257, 512) {
                $n++
                $mails = foreach ($i in 1..$size) { "C MAIL FROM:<e$i@vendor.example>"; 'S 250 2.1.0 Sender OK' }
                $steps += , @("08DA00000000F00$n", (70 + $n * 5), "10.3.9.${n}:53000", $size, $mails)
            }
            $lines = @($header)
            foreach ($x in $steps) { $lines += AuthSession $fe $x[0] $x[1] $feLocal $x[2] @((AuthHello 'edge.contoso.test'), (AuthPlain 'edge.user@contoso.test'), $x[4], 'C QUIT', 'S 221 bye', '-Local') }
            Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) $lines
            [void](Invoke-TestCollection $s)
            foreach ($x in $steps) {
                $sid = $x[0]; $size = $x[3]
                (Query $s "SELECT COUNT(*), COUNT(DISTINCT auth_sequence), SUM(auth_user = 'edge.user@contoso.test' AND auth_source = 'Direct') FROM smtp_transaction WHERE session_id = '$sid'")[0] -join '|' | Should -Be "$size|$size|$size" -Because $sid
                (Query $s "SELECT MAX(json_array_length(observations)), SUM(complete_end) FROM smtp_auth_fragment WHERE session_id = '$sid'")[0] -join '|' | Should -Match '^(\d+)\|1$' -Because $sid
            }
        }
        Context 'offline proxy load' {
            BeforeAll {
                $loadProbe = Join-Path $TestDrive 'smtp-auth-proxy-load.ps1'
                @'
param($Root, $Config, $WarmConfig, $Count, $Mode, $LateSource, $LateTarget)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'ExchangeLogReport.psd1') -Force
Initialize-ExlEngine -Root $Root
# The page cache is pinned (Store.CacheKilobytes below) so that the memory measured is that of the collection: the collection keeps that cache
# (CollectorOptions.CacheKilobytes 0) instead of its own (1 GB by default).
& (Get-Module ExchangeLogReport) {
    $create = ${function:New-ExlCollector}
    Set-Item -Path function:script:New-ExlCollector -Value ({
        param($Store, $Settings, $RunId)
        $collector = & $create -Store $Store -Settings $Settings -RunId $RunId
        [ExchangeLogReport.Collector].GetField('_o', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($collector).CacheKilobytes = 0
        $collector
    }.GetNewClosure())
}
$probeTypes = @"
using System;
using System.Diagnostics;
using System.Threading;
public sealed class ProxyLoadSample : IDisposable {
    readonly Thread thread; volatile bool stop;
    long lastGc = -1;
    // ManagedPeak is the heap size including garbage not yet collected: it is bounded by the allocation budget of the
    // generation 0, which depends on the cache of the processor. LivePeak is the largest heap size measured right after a
    // garbage collection (what the code retains); Gen0Peak is the largest generation 0 size seen before a collection.
    public long ManagedBase, ManagedPeak, ManagedEnd, LivePeak, Gen0Peak, PrivateBase, PrivatePeak, Samples;
    void SampleCollections() {
        var info = GC.GetGCMemoryInfo(GCKind.Any);
        if (info.Index == lastGc) return;
        lastGc = info.Index;
        long live = 0;
        foreach (var generation in info.GenerationInfo) live += generation.SizeAfterBytes;
        LivePeak = Math.Max(LivePeak, live);
        Gen0Peak = Math.Max(Gen0Peak, info.GenerationInfo[0].SizeBeforeBytes);
    }
    public ProxyLoadSample() {
        ManagedBase = GC.GetTotalMemory(true); ManagedPeak = ManagedBase;
        SampleCollections();
        PrivateBase = SmtpProcessMemory.PrivateBytes();
        PrivatePeak = PrivateBase;
        thread = new Thread(() => {
            while (!stop) {
                ManagedPeak = Math.Max(ManagedPeak, GC.GetTotalMemory(false));
                SampleCollections();
                PrivatePeak = Math.Max(PrivatePeak, SmtpProcessMemory.PrivateBytes());
                Samples++; Thread.Sleep(20);
            }
        });
        thread.IsBackground = true; thread.Start();
    }
    public void Dispose() { stop = true; thread.Join(); ManagedEnd = GC.GetTotalMemory(true); SampleCollections(); }
}
"@
Add-Type -TypeDefinition ($probeTypes + [IO.File]::ReadAllText((Join-Path $Root '..\tests\SmtpProcessMemory.cs')))
function Collect($s) {
    $store = Open-ExlStore -Settings $s
    try {
        $run = $store.StartRun('Collect', 'proxy-load', 'synthetic', '1.0.0')
        & (Get-Module ExchangeLogReport) { param($s,$st,$r)
            Invoke-ExlCollection -Store $st -Settings $s -RunId $r -Servers @($s.Servers[0]) 6>$null
        } $s $store $run
    } finally { $store.Dispose() }
}
function ReadRow($s, $sql) {
    $store = Open-ExlStore -Settings $s -ReadOnly
    try { return ,@($store.Query($sql, $null).Rows[0]) } finally { $store.Dispose() }
}
function Replay($s, $groups) {
    $store = Open-ExlStore -Settings $s
    $phases = @()
    try {
        $engine = [ExchangeLogReport.Collector].Assembly
        $writer = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.Writer'), [object[]]@($store))
        try {
            foreach ($generation in 1,2) {
                $resolver = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.AuthResolver'), [object[]]@($store,$writer,[long]600000))
                try {
                    $passes = if ($groups) { 2 } else { 1 }
                    for ($pass = 1; $pass -le $passes; $pass++) {
                        $sample = [ProxyLoadSample]::new()
                        $watch = [Diagnostics.Stopwatch]::StartNew()
                        $tx = $store.Begin()
                        try {
                            $writer.Use($tx)
                            $priorUpdated = $resolver.Updated; $priorReplayed = $resolver.Replayed
                            if ($groups) {
                                for ($i=1; $i -le $Count; $i++) { $resolver.Touch('EXCH01','Receive','FrontEnd',('A{0:X15}' -f $i)) }
                            } else { $resolver.Touch('EXCH01','Receive','Hub','08DA000000009B01') }
                            $queued = $resolver.Count
                            $resolver.Flush($tx)
                            $tx.Commit()
                        } finally { $tx.Dispose(); $sample.Dispose() }
                        $phases += @{
                            generation=$generation; pass=$pass; queued=$queued; pendingAfter=$resolver.Count;
                            updated=($resolver.Updated-$priorUpdated); replayed=($resolver.Replayed-$priorReplayed);
                            elapsedSeconds=$watch.Elapsed.TotalSeconds; memory=$sample
                        }
                    }
                } finally { $resolver.Dispose() }
                if (-not $groups) { break }
            }
        } finally { $writer.Dispose() }
    } finally { $store.Dispose() }
    return $phases
}
[ExchangeLogReport.Store]::CacheKilobytes = 8192
[void](Collect (Import-ExlConfiguration -Path $WarmConfig -Root $Root))
$s = Import-ExlConfiguration -Path $Config -Root $Root
$s.Collection.Parallelism = 1; $s.Storage.DetailRetentionDays = 0
$watch = [Diagnostics.Stopwatch]::StartNew()
$sample = [ProxyLoadSample]::new()
try { $initial = Collect $s } finally { $sample.Dispose() }
$initialSeconds = $watch.Elapsed.TotalSeconds
$before = ReadRow $s "SELECT COUNT(*),SUM(auth_source='Missing') FROM smtp_transaction WHERE role='Hub';"
$late = $null
if ($Mode -eq 'groups') {
    [void][IO.Directory]::CreateDirectory((Split-Path $LateTarget))
    [IO.File]::Move($LateSource,$LateTarget)
    $lateSample = [ProxyLoadSample]::new(); $lw = [Diagnostics.Stopwatch]::StartNew()
    try { $lateResult = Collect $s } finally { $lateSample.Dispose() }
    $late = @{elapsedSeconds=$lw.Elapsed.TotalSeconds; memory=$lateSample; errors=$lateResult.Errors; lines=$lateResult.Lines}
}
$rowsSql = if ($Mode -eq 'groups') {
    "WITH RECURSIVE expected(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM expected WHERE n<$Count)
     SELECT COUNT(*),COUNT(DISTINCT t.session_id),SUM(t.auth_user='scale-'||e.n||'@contoso.test' AND t.auth_mechanism='LOGIN' AND t.auth_source='FrontEndProxy' AND t.auth_result='Succeeded' AND t.auth_attempt_result='Succeeded' AND t.auth_user<>t.mail_from)
     FROM expected e LEFT JOIN smtp_transaction t ON t.session_id=printf('B%015X',e.n) AND t.role='Hub';"
} else {
    "SELECT COUNT(*),COUNT(DISTINCT auth_sequence),SUM(auth_user='load.user@contoso.test' AND auth_mechanism='LOGIN' AND auth_source='FrontEndProxy' AND auth_result='Succeeded' AND auth_attempt_result='Succeeded' AND auth_user<>mail_from),COUNT(DISTINCT auth_fragment_id||':'||auth_sequence)
     FROM smtp_transaction WHERE role='Hub' AND session_id='08DA000000009B01';"
}
$rows = ReadRow $s $rowsSql
$phases = @(Replay $s ($Mode -eq 'groups'))
$after = ReadRow $s $rowsSql
$parts = ReadRow $s "SELECT COUNT(*),MAX(json_array_length(observations)),MAX(length(CAST(observations AS BLOB))),SUM(conflicted),SUM(complete_end),COUNT(DISTINCT role||':'||session_id) FROM smtp_auth_fragment;"
$totals = ReadRow $s "SELECT COUNT(*),SUM(role='FrontEnd'),SUM(auth_source IN ('Overflow','Ambiguous')) FROM smtp_transaction;"
$references = ReadRow $s "SELECT COUNT(*) FROM smtp_transaction t LEFT JOIN smtp_auth_fragment f ON f.id=t.auth_fragment_id WHERE f.id IS NULL;"
$offsets = ReadRow $s "SELECT COUNT(*),SUM(offset=size) FROM source_file;"
$data = @{
    mode=$Mode; count=[int]$Count; workers=1; rows=$rows; after=$after; before=$before;
    parts=$parts; totals=$totals; missingReferences=$references; offsets=$offsets;
    memory=$sample; elapsedSeconds=$initialSeconds; errors=$initial.Errors; lines=$initial.Lines;
    late=$late; resolver=$phases; scopeBudgetPerReplay=2;
    scratchRemaining=@(Get-ChildItem -LiteralPath (Split-Path $s.Storage.DatabasePath) -Force |
        Where-Object { $_.Name -like '.report-*' -or $_.Name -like '.smtp-*' }).Count
}
'SMTP_PROXY_LOAD_JSON=' + ($data | ConvertTo-Json -Depth 8 -Compress)
'@ | Set-Content -LiteralPath $loadProbe -Encoding utf8
                function Run-ProxyLoadProbe($config, $warm, $count, $mode, $lateSource = '', $lateTarget = '') {
                    $out = Join-Path (Split-Path $config) 'probe.stdout.txt'
                    $err = Join-Path (Split-Path $config) 'probe.stderr.txt'
                    $args = @('-NoProfile','-File',"`"$loadProbe`"","`"$script:Root`"","`"$config`"","`"$warm`"",$count,$mode,"`"$lateSource`"","`"$lateTarget`"")
                    $p = Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $args -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
                    $deadline = if ($env:EXL_PROXY_LOAD_DEADLINE) { [DateTimeOffset]::Parse($env:EXL_PROXY_LOAD_DEADLINE) } else { [DateTimeOffset]::UtcNow.AddMinutes(10) }
                    $remaining = [int][math]::Min([int]::MaxValue,[math]::Max(1,($deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds))
                    if (-not $p.WaitForExit($remaining)) { $p.Kill($true); $p.WaitForExit(5000) | Out-Null; throw "Proxy load child PID $($p.Id) exceeded its deadline; evidence: $out, $err" }
                    $p.ExitCode | Should -Be 0 -Because ([IO.File]::ReadAllText($err))
                    $json = Get-Content -LiteralPath $out | Where-Object { $_.StartsWith('SMTP_PROXY_LOAD_JSON=') } | Select-Object -Last 1
                    $json | Should -Not -BeNullOrEmpty
                    $m = $json.Substring('SMTP_PROXY_LOAD_JSON='.Length) | ConvertFrom-Json
                    $m | Add-Member -NotePropertyName childPid -NotePropertyValue $p.Id
                    if ($env:EXL_PROXY_LOAD_ARTIFACTS) {
                        $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $env:EXL_PROXY_LOAD_ARTIFACTS "smtp-auth-proxy-$mode-$count.json")
                    }
                    Write-Host ("SMTP proxy load: " + ($m | ConvertTo-Json -Depth 10 -Compress))
                    return $m
                }
                function New-ProxyLoadConfig($dir) {
                    $config = New-TestConfig $dir
                    Remove-Item -LiteralPath (Join-Path $dir 'logs-src') -Recurse -Force
                    return $config
                }
            }
            It 'measures 160000 real-shaped proxied MAILs against a 20000 reference in fresh processes' {
                $measurements = @()
                foreach ($count in 20000,160000) {
                    $dir = Join-Path $TestDrive "proxy-load-$count"
                    $config = New-ProxyLoadConfig $dir
                    $warm = New-TestConfig (Join-Path $dir 'warm')
                    $sid = '08DA000000009A01'; $hubSid = '08DA000000009B01'
                    Write-Log (Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')) @($header + @(AuthSession $fe $sid 120 $feLocal '10.3.9.1:55009' @((AuthHello 'load.contoso.test'),(AuthLogin 'load.user@contoso.test' -Proxied),'-Local')))
                    $prefix = @(AuthSession $cp $hubSid 120.1 $beLocal '10.0.0.1:44009' @(AuthBack $sid '10.3.9.1' 55009 'load.contoso.test' 'sender@vendor.example' 'unused' | Select-Object -First 9))
                    $seq = $prefix.Count; $clock = $script:Base.AddMinutes(120.2)
                    for ($file=0; $file -lt 4; $file++) {
                        $path = Join-Path (Join-Path $dir 'logs-src') (($recv -f 'Hub').Replace('-1.LOG', "-$($file+1).LOG"))
                        [void][IO.Directory]::CreateDirectory((Split-Path $path))
                        $w = [IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($true))
                        try {
                            foreach ($line in $header) { $w.WriteLine($line) }
                            if ($file -eq 0) { foreach ($line in $prefix) { $w.WriteLine($line) } }
                            for ($i=0; $i -lt ($count/4); $i++) {
                                $time=$clock.AddMilliseconds($seq).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                                $w.WriteLine("$time,$cp,$hubSid,$seq,$beLocal,10.0.0.1:44009,<,MAIL FROM:<sender@vendor.example>,"); $seq++
                                $time=$clock.AddMilliseconds($seq).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                                $w.WriteLine("$time,$cp,$hubSid,$seq,$beLocal,10.0.0.1:44009,>,250 2.1.0 Sender OK,"); $seq++
                            }
                            if ($file -eq 3) { $w.WriteLine("$($clock.AddMilliseconds($seq).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")),$cp,$hubSid,$seq,$beLocal,10.0.0.1:44009,-,,Local") }
                        } finally { $w.Dispose() }
                        [IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddHours(-1))
                    }
                    $m = Run-ProxyLoadProbe $config $warm $count 'mail'
                    $measurements += $m
                    $m.rows -join '|' | Should -Be "$count|$count|$count|$count"
                    $m.after -join '|' | Should -Be ($m.rows -join '|')
                    $m.totals -join '|' | Should -Be "$count|0|0"
                    $m.parts[1] | Should -BeLessOrEqual 256
                    $m.parts[2] | Should -BeLessOrEqual 128KB
                    $m.parts[3] | Should -Be 0
                    $m.parts[4] | Should -Be 2
                    $m.parts[5] | Should -Be 2
                    $m.missingReferences[0] | Should -Be 0
                    $m.offsets -join '|' | Should -Be '5|5'
                    $m.errors | Should -Be 0
                    $m.scratchRemaining | Should -Be 0
                    $m.memory.Samples | Should -BeGreaterThan 1
                    ($m.memory.PrivatePeak-$m.memory.PrivateBase) | Should -BeLessOrEqual 64MB
                    # The bound is on what the resolver retains: the largest heap measured right after a collection, not the heap size
# including garbage that the generation 0 budget (a function of the processor cache) has not collected yet.
                    ($m.resolver[0].memory.LivePeak-$m.resolver[0].memory.ManagedBase) | Should -BeLessOrEqual 16MB
                    $m.resolver[0].updated | Should -Be 0
                    $m.resolver[0].pendingAfter | Should -Be 0
                }
                $small=$measurements[0]; $large=$measurements[1]
                ($large.memory.ManagedEnd-$large.memory.ManagedBase)-($small.memory.ManagedEnd-$small.memory.ManagedBase) | Should -BeLessOrEqual 8MB
                ($large.resolver[0].memory.ManagedEnd-$large.resolver[0].memory.ManagedBase)-($small.resolver[0].memory.ManagedEnd-$small.resolver[0].memory.ManagedBase) | Should -BeLessOrEqual 8MB
            }
            It 'keeps 4100 independent late FrontEnd proxy groups across committed resolver generations and fanout' {
                $count=4100; $dir=Join-Path $TestDrive 'proxy-load-groups'
                $config=New-ProxyLoadConfig $dir; $warm=New-TestConfig (Join-Path $dir 'warm')
                $lateSource=Join-Path $dir 'late-frontend.LOG'
                $hubPath=Join-Path (Join-Path $dir 'logs-src') ($recv -f 'Hub')
                $lateTarget=Join-Path (Join-Path $dir 'logs-src') ($recv -f 'FrontEnd')
                [void][IO.Directory]::CreateDirectory((Split-Path $hubPath))
                $fw=[IO.StreamWriter]::new($lateSource,$false,[Text.UTF8Encoding]::new($true))
                $hw=[IO.StreamWriter]::new($hubPath,$false,[Text.UTF8Encoding]::new($true))
                try {
                    foreach ($line in $header) { $fw.WriteLine($line); $hw.WriteLine($line) }
                    for ($i=1; $i -le $count; $i++) {
                        $sid='A{0:X15}' -f $i; $backend='B{0:X15}' -f $i; $port=20000+$i
                        foreach ($line in (AuthSession $fe $sid 125 $feLocal "10.3.9.2:$port" @((AuthHello "scale-$i.contoso.test"),(AuthLogin "scale-$i@contoso.test" -Proxied),'-Local'))) { $fw.WriteLine($line) }
                        foreach ($line in (AuthSession $cp $backend 125.1 $beLocal "10.0.0.1:$(30000+$i)" @(AuthBack $sid '10.3.9.2' $port "scale-$i.contoso.test" 'sender@vendor.example' "scale-$i"))) { $hw.WriteLine($line) }
                    }
                } finally { $fw.Dispose(); $hw.Dispose() }
                $m=Run-ProxyLoadProbe $config $warm $count 'groups' $lateSource $lateTarget
                $m.before -join '|' | Should -Be "$count|$count"
                $m.rows -join '|' | Should -Be "$count|$count|$count"
                $m.after -join '|' | Should -Be ($m.rows -join '|')
                $m.totals -join '|' | Should -Be "$count|0|0"
                $m.parts[5] | Should -Be ($count*2)
                $m.parts[3] | Should -Be 0
                $m.errors | Should -Be 0
                $m.late.errors | Should -Be 0
                $m.offsets -join '|' | Should -Be '2|2'
                $m.missingReferences[0] | Should -Be 0
                $m.resolver.Count | Should -Be 4
                foreach ($phase in $m.resolver) {
                    $phase.queued | Should -Be $count
                    $phase.replayed | Should -BeGreaterOrEqual ($count*2)
                    $phase.updated | Should -Be 0
                    $phase.pendingAfter | Should -Be 0
                }
                $m.scratchRemaining | Should -Be 0
            }
        }
        It 'measures actual managed and private memory for 20000, 80000 and 160000 MAILs across four files in fresh processes' -Tag 'Measurement' {
            $probe = Join-Path $TestDrive 'smtp-auth-memory.ps1'
            @'
param($Root, $Config, $WarmConfig, $Count, $Workers)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'ExchangeLogReport.psd1') -Force
Initialize-ExlEngine -Root $Root
# The page cache is pinned (Store.CacheKilobytes below) so that the memory measured is that of the collection: the collection keeps that cache
# (CollectorOptions.CacheKilobytes 0) instead of its own (1 GB by default).
& (Get-Module ExchangeLogReport) {
    $create = ${function:New-ExlCollector}
    Set-Item -Path function:script:New-ExlCollector -Value ({
        param($Store, $Settings, $RunId)
        $collector = & $create -Store $Store -Settings $Settings -RunId $RunId
        [ExchangeLogReport.Collector].GetField('_o', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($collector).CacheKilobytes = 0
        $collector
    }.GetNewClosure())
}
$probeTypes = @"
using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
public sealed class AuthMemorySampler : IDisposable {
    readonly Thread thread;
    volatile bool stop;
    long lastGc = -1;
    // See ProxyLoadSample: ManagedPeak includes garbage not yet collected, LivePeak is measured right after collections.
    // PrivateEnd is read after the full collection of Dispose: the private bytes the measured work leaves behind.
    public long ManagedBase, PrivateBase, ManagedPeak, LivePeak, Gen0Peak, PrivatePeak, PrivateEnd, Samples;
    void SampleCollections() {
        var info = GC.GetGCMemoryInfo(GCKind.Any);
        if (info.Index == lastGc) return;
        lastGc = info.Index;
        long live = 0;
        foreach (var generation in info.GenerationInfo) live += generation.SizeAfterBytes;
        LivePeak = Math.Max(LivePeak, live);
        Gen0Peak = Math.Max(Gen0Peak, info.GenerationInfo[0].SizeBeforeBytes);
    }
    public AuthMemorySampler() {
        ManagedBase = GC.GetTotalMemory(true);
        SampleCollections();
        PrivateBase = SmtpProcessMemory.PrivateBytes();
        ManagedPeak = ManagedBase; PrivatePeak = PrivateBase;
        thread = new Thread(() => {
            while (!stop) {
                ManagedPeak = Math.Max(ManagedPeak, GC.GetTotalMemory(false));
                SampleCollections();
                PrivatePeak = Math.Max(PrivatePeak, SmtpProcessMemory.PrivateBytes());
                Samples++; Thread.Sleep(20);
            }
        });
        thread.IsBackground = true; thread.Start();
    }
    public void Dispose() { stop = true; thread.Join(); GC.GetTotalMemory(true); SampleCollections(); PrivateEnd = SmtpProcessMemory.PrivateBytes(); }
    public static long[] Tracker(Assembly engine, string folder, int count) {
        var headType = engine.GetType("ExchangeLogReport.AuthFragment");
        var head = Activator.CreateInstance(headType, true);
        foreach (var name in new[] { "Server", "Direction", "Role", "SessionId", "SourceKey" })
            headType.GetField(name).SetValue(head, name == "Direction" ? "Receive" : name == "Role" ? "FrontEnd" : "memory");
        headType.GetField("FirstMs").SetValue(head, 1000L);
        var spool = Activator.CreateInstance(engine.GetType("ExchangeLogReport.SmtpSpool"), new object[] { folder });
        try {
            var type = engine.GetType("ExchangeLogReport.SmtpAuthTracker");
            var tracker = Activator.CreateInstance(type, new object[] { true, head, spool, 1L });
            var line = type.GetMethod("Line"); var mail = type.GetMethod("Mail");
            var args = new object[] { "+", false, false, 1000L, 0L, 0L, "", "", null, null, false };
            line.Invoke(tracker, args);
            args[0] = "<"; args[1] = true; args[4] = 1L; args[6] = "AUTH PLAIN [redacted]";
            line.Invoke(tracker, args);
            args[0] = "*"; args[1] = false; args[4] = 2L; args[6] = "memory.user@contoso.test"; args[7] = "authenticated";
            line.Invoke(tracker, args);
            args[0] = ">"; args[2] = true; args[4] = 3L; args[6] = "235 Authentication successful"; args[7] = "";
            line.Invoke(tracker, args);
            var m = new object[] { 1000L, 4L, 4L, true };
            var watch = Stopwatch.StartNew();
            using (var sample = new AuthMemorySampler()) {
                for (int i = 0; i < count; i++) {
                    long seq = 4L + i * 2L;
                    args[0] = "<"; args[1] = true; args[2] = false; args[3] = 1000L + seq; args[4] = seq; args[5] = seq;
                    args[6] = "MAIL FROM:<sender@vendor.example>";
                    line.Invoke(tracker, args);
                    m[0] = args[3]; m[1] = seq; m[2] = seq; mail.Invoke(tracker, m);
                    args[0] = ">"; args[1] = false; args[2] = true; args[4] = seq + 1; args[5] = seq + 1; args[6] = "250 OK";
                    line.Invoke(tracker, args);
                }
                long end = GC.GetTotalMemory(true);
                GC.KeepAlive(tracker); GC.KeepAlive(spool);
                sample.Dispose();
                return new[] { sample.ManagedBase, sample.ManagedPeak, end, sample.Samples, (long)watch.ElapsedMilliseconds,
                    (long)spool.GetType().GetField("Parts").GetValue(spool), (long)(int)type.GetProperty("Live").GetValue(tracker), sample.LivePeak };
            }
        } finally { ((IDisposable)spool).Dispose(); }
    }
}
"@
Add-Type -TypeDefinition ($probeTypes + [IO.File]::ReadAllText((Join-Path $Root '..\tests\SmtpProcessMemory.cs')))
function Collect($settings) {
    $store = Open-ExlStore -Settings $settings
    try {
        $run = $store.StartRun('Collect', 'memory', 'synthetic', '1.0.0')
        return & (Get-Module ExchangeLogReport) { param($s,$st,$r)
            Invoke-ExlCollection -Store $st -Settings $s -RunId $r -Servers @($s.Servers[0]) 6>$null
        } $settings $store $run
    } finally { $store.Dispose() }
}
$cache = [ExchangeLogReport.Store]::CacheKilobytes
try {
    [ExchangeLogReport.Store]::CacheKilobytes = 8192
    $warm = Import-ExlConfiguration -Path $WarmConfig -Root $Root
    [void](Collect $warm)
    $s = Import-ExlConfiguration -Path $Config -Root $Root
    $s.Collection.Parallelism = [int]$Workers
    $s.Storage.DetailRetentionDays = 0
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $collectGc = @([GC]::CollectionCount(0), [GC]::CollectionCount(1), [GC]::CollectionCount(2))
    $sample = [AuthMemorySampler]::new()
    try { $result = Collect $s }
    finally { $sample.Dispose() }
    $collectGc = @(([GC]::CollectionCount(0)-$collectGc[0]), ([GC]::CollectionCount(1)-$collectGc[1]), ([GC]::CollectionCount(2)-$collectGc[2]))
    $end = [GC]::GetTotalMemory($true)
    $collectionSeconds = $watch.Elapsed.TotalSeconds
    $tracker = [AuthMemorySampler]::Tracker([ExchangeLogReport.Collector].Assembly, (Split-Path $s.Storage.DatabasePath), [int]$Count)
    $store = Open-ExlStore -Settings $s
    try {
        $engine = [ExchangeLogReport.Collector].Assembly
        $writer = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.Writer'), [object[]]@($store))
        $resolver = [Activator]::CreateInstance($engine.GetType('ExchangeLogReport.AuthResolver'), [object[]]@($store, $writer, [long]600000))
        $tx = $store.Begin()
        try {
            $writer.Use($tx)
            $resolver.Touch('EXCH01', 'Receive', 'FrontEnd', 'warm-absent-scope')
            $resolver.Flush($tx)
            $resolver.Touch('EXCH01', 'Receive', 'FrontEnd', '08DA000000003A01')
            $resolverPasses = [int](160000 / [int]$Count)
            $gcBefore = @([GC]::CollectionCount(0), [GC]::CollectionCount(1), [GC]::CollectionCount(2))
            $rs = [AuthMemorySampler]::new()
            $rw = [Diagnostics.Stopwatch]::StartNew()
            try {
                # Equal work lets every volume exercise the GC's transient allocation budget.
                for ($pass = 0; $pass -lt $resolverPasses; $pass++) {
                    if ($pass -gt 0) { $resolver.Touch('EXCH01', 'Receive', 'FrontEnd', '08DA000000003A01') }
                    $resolver.Flush($tx)
                }
            } finally { $rs.Dispose() }
            $resolverEnd = [GC]::GetTotalMemory($true)
            $resolverMemory = @{
                managedBase=$rs.ManagedBase; managedPeak=$rs.ManagedPeak; livePeak=$rs.LivePeak; gen0Peak=$rs.Gen0Peak; managedEnd=$resolverEnd;
                privateBase=$rs.PrivateBase; privatePeak=$rs.PrivatePeak; samples=$rs.Samples;
                elapsedSeconds=$rw.Elapsed.TotalSeconds; replayed=$resolver.Replayed; updated=$resolver.Updated;
                passes=$resolverPasses; workItems=([int]$Count * $resolverPasses);
                gcCollections=@(([GC]::CollectionCount(0)-$gcBefore[0]), ([GC]::CollectionCount(1)-$gcBefore[1]), ([GC]::CollectionCount(2)-$gcBefore[2]));
                serverGc=[Runtime.GCSettings]::IsServerGC
            }
            $tx.Commit()
        } finally { $resolver.Dispose(); $writer.Dispose(); $tx.Dispose() }
    } finally { $store.Dispose() }
    $store = Open-ExlStore -Settings $s -ReadOnly
    try {
        $row = $store.Query("SELECT COUNT(*), COUNT(DISTINCT auth_sequence), SUM(auth_user='memory.user@contoso.test' AND auth_mechanism='PLAIN' AND auth_result='Succeeded' AND auth_source='Direct') FROM smtp_transaction WHERE session_id='08DA000000003A01';", $null).Rows[0]
        $parts = $store.Query("SELECT COUNT(*), MAX(json_array_length(observations)), MAX(length(CAST(observations AS BLOB))), SUM(complete_end), SUM(conflicted) FROM smtp_auth_fragment WHERE session_id='08DA000000003A01';", $null).Rows[0]
    } finally { $store.Dispose() }
    $data = @{
        count=[int]$Count; workers=[int]$Workers; rows=@($row); parts=@($parts);
        managedBase=$sample.ManagedBase; managedPeak=$sample.ManagedPeak; managedEnd=$end; livePeak=$sample.LivePeak; gen0Peak=$sample.Gen0Peak;
        privateBase=$sample.PrivateBase; privatePeak=$sample.PrivatePeak; privateEnd=$sample.PrivateEnd; samples=$sample.Samples;
        gcCollections=$collectGc; gcSettings=@{ concurrent=[bool][GC]::GetConfigurationVariables()['ConcurrentGC']; serverGc=[Runtime.GCSettings]::IsServerGC; gen0MaxBudget=[long][GC]::GetConfigurationVariables()['GCGen0MaxBudget']; conserveMemory=[long][GC]::GetConfigurationVariables()['GCConserveMem'] };
        elapsedSeconds=$collectionSeconds; errors=$result.Errors; tracker=$tracker; resolver=$resolverMemory;
        scratchRemaining=@(Get-ChildItem -LiteralPath (Split-Path $s.Storage.DatabasePath) -Force -Filter '.report-*').Count
    }
    'SMTP_MEMORY_JSON=' + ($data | ConvertTo-Json -Depth 8 -Compress)
} finally { [ExchangeLogReport.Store]::CacheKilobytes = $cache }
'@ | Set-Content -LiteralPath $probe -Encoding utf8
            $measurements = @()
            foreach ($case in @(@{ Count = 20000; Workers = 1 }, @{ Count = 80000; Workers = 1 }, @{ Count = 160000; Workers = 1 }, @{ Count = 160000; Workers = 2 })) {
                $count = $case.Count
                $dir = Join-Path $TestDrive "smtp-auth-memory-$count-$($case.Workers)"
                $config = New-TestConfig $dir
                $warm = New-TestConfig (Join-Path $dir 'warm')
                $seq = 0
                $clock = $script:Base.AddMinutes(120).AddSeconds(1)
                for ($file = 0; $file -lt 4; $file++) {
                    $path = Join-Path (Join-Path $dir 'logs-src') (($recv -f 'FrontEnd').Replace('-1.LOG', "-$($file + 1).LOG"))
                    [void][IO.Directory]::CreateDirectory((Split-Path $path))
                    $w = [IO.StreamWriter]::new($path, $false, [Text.UTF8Encoding]::new($true))
                    try {
                        foreach ($line in $header) { $w.WriteLine($line) }
                        if ($file -eq 0) {
                            foreach ($line in (AuthSession $fe '08DA000000003A01' 120 $feLocal '10.3.8.3:54002' @((AuthHello 'memory.contoso.test'), (AuthPlain 'memory.user@contoso.test')))) { $w.WriteLine($line); $seq++ }
                        }
                        for ($i = 0; $i -lt ($count / 4); $i++) {
                            $time = $clock.AddMilliseconds($seq).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                            $w.WriteLine("$time,$fe,08DA000000003A01,$seq,$feLocal,10.3.8.3:54002,<,MAIL FROM:<sender@vendor.example>,"); $seq++
                            $time = $clock.AddMilliseconds($seq).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                            $w.WriteLine("$time,$fe,08DA000000003A01,$seq,$feLocal,10.3.8.3:54002,>,250 OK,"); $seq++
                        }
                        if ($file -eq 3) { $w.WriteLine("$($clock.AddMilliseconds($seq).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")),$fe,08DA000000003A01,$seq,$feLocal,10.3.8.3:54002,-,,Local") }
                    } finally { $w.Dispose() }
                    [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddHours(-1))
                }
                # The garbage collector of the probe is pinned: a generation 0 budget of 16 MB (the runtime otherwise adapts it to the load
                # of the machine, up to 128 MB) and no background collection, so that the garbage the peaks include is bounded.
                $gcPin = [ordered]@{ DOTNET_GCgen0size = '0x1000000'; DOTNET_GCgen0MaxBudget = '0x1000000'; DOTNET_gcConcurrent = '0'; DOTNET_GCConserveMemory = '0' }
                $gcSaved = @{}; foreach ($name in $gcPin.Keys) { $gcSaved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $gcPin[$name]) }
                try { $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $probe $script:Root $config $warm $count $case.Workers 2>&1 }
                finally { foreach ($name in $gcPin.Keys) { [Environment]::SetEnvironmentVariable($name, $gcSaved[$name]) } }
                $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
                $json = $output | Where-Object { "$_".StartsWith('SMTP_MEMORY_JSON=') } | Select-Object -Last 1
                $json | Should -Not -BeNullOrEmpty
                $m = "$json".Substring('SMTP_MEMORY_JSON='.Length) | ConvertFrom-Json
                $measurements += $m
                Write-Host ("SMTP actual memory: " + ($m | ConvertTo-Json -Depth 8 -Compress))
                $m.rows -join '|' | Should -Be "$count|$count|$count"
                $m.parts[1] | Should -BeLessOrEqual 256
                $m.parts[2] | Should -BeLessOrEqual 128KB
                $m.parts[3] | Should -Be 1
                $m.parts[4] | Should -Be 0
                $m.scratchRemaining | Should -Be 0
                $m.samples | Should -BeGreaterThan 1
                $m.gcSettings.concurrent | Should -BeFalse
                $m.gcSettings.serverGc | Should -BeFalse
                $m.gcSettings.gen0MaxBudget | Should -Be 16MB
                # What the collection retains: the private bytes left after its last collection of every generation. Its peak is that
                # plus the garbage of one generation 0 budget (Gen0Peak, pinned to 16 MB above) and the
                # pages of the pinned SQLite cache.
                ($m.privateEnd - $m.privateBase) | Should -BeLessOrEqual 32MB
                ($m.privatePeak - $m.privateBase) | Should -BeLessOrEqual ($m.gen0Peak + 32MB)
                # The bound is on what the resolver retains (largest heap measured right after a collection), not on the heap size
                # that includes garbage the generation 0 budget has not collected yet.
                ($m.resolver.livePeak - $m.resolver.managedBase) | Should -BeLessOrEqual 16MB
                $m.resolver.updated | Should -Be 0
                $m.resolver.workItems | Should -Be 160000
                $m.resolver.replayed | Should -Be (2 * $m.resolver.passes)
                $m.tracker[5] | Should -BeGreaterThan 0
                $m.tracker[6] | Should -BeLessOrEqual 256
            }
            $small = $measurements[0]; $large = $measurements[2]
            ($large.managedEnd - $large.managedBase) - ($small.managedEnd - $small.managedBase) | Should -BeLessOrEqual 8MB
            ($large.tracker[2] - $large.tracker[0]) - ($small.tracker[2] - $small.tracker[0]) | Should -BeLessOrEqual 2MB
            # The peaks that do not grow with the volume are those of what the tracker and the resolver retain (the heap right after each
            # collection); their peaks with garbage are bounded by the generation 0 budget, not by the volume.
            ($large.tracker[7] - $large.tracker[0]) | Should -BeLessOrEqual ([math]::Max(8MB, 1.5 * ($small.tracker[7] - $small.tracker[0])))
            ($large.resolver.managedEnd - $large.resolver.managedBase) - ($small.resolver.managedEnd - $small.resolver.managedBase) | Should -BeLessOrEqual 8MB
            ($large.resolver.livePeak - $large.resolver.managedBase) | Should -BeLessOrEqual ([math]::Max(8MB, 1.5 * ($small.resolver.livePeak - $small.resolver.managedBase)))
            foreach ($m in $measurements) { ($m.tracker[1] - $m.tracker[0]) | Should -BeLessOrEqual ($m.tracker[7] - $m.tracker[0] + 16MB + 8MB) }
            ($large.privateEnd - $large.privateBase) | Should -BeLessOrEqual ([math]::Max(16MB, 1.5 * ($small.privateEnd - $small.privateBase)))
        }
    }
}

Describe 'Command line and periods' {
    It 'takes the range from the period parameters, and refuses a period parameter that does not belong to -Range' {
        Resolve-ExlRange -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -Default 'Last7Days' | Should -Be 'Custom'
        Resolve-ExlRange -Range Custom -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -Default 'Last7Days' | Should -Be 'Custom'
        Resolve-ExlRange -Month '2026-09' -Default 'Last7Days' | Should -Be 'Month'
        Resolve-ExlRange -Range Day -Date '2026-09-28' -Default 'Last7Days' | Should -Be 'Day'
        Resolve-ExlRange -Range Last30Days -Default 'Last7Days' | Should -Be 'Last30Days'
        Resolve-ExlRange -Default 'Last7Days' | Should -Be 'Last7Days'
        { Resolve-ExlRange -Range Last7Days -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -Default 'Last7Days' } | Should -Throw '-Start / -End define the period of the report (-Range Custom) and cannot be combined with -Range Last7Days*'
        { Resolve-ExlRange -Range Day -Month '2026-09' -Default 'Last7Days' } | Should -Throw '-Month defines the period*-Range Day*'
        { Resolve-ExlRange -Month '2026-09' -Date '2026-09-28' -Default 'Last7Days' } | Should -Throw '*use only one of them.'
        # -Start without -End: a custom period that is refused, not the default range.
        $range = Resolve-ExlRange -Start '2026-10-01 08:00' -Default 'Last7Days'
        $range | Should -Be 'Custom'
        { Resolve-ExlPeriod -Range $range -Start '2026-10-01 08:00' -Zone ([TimeZoneInfo]::Utc) } | Should -Throw '*requires -Start and -End*'
        $p = Resolve-ExlPeriod -Range Custom -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -Zone ([TimeZoneInfo]::Utc) -Now ([DateTimeOffset]'2026-10-05T12:00:00Z')
        $p.StartMs | Should -Be ([DateTimeOffset]'2026-10-01T08:00:00Z').ToUnixTimeMilliseconds()
        $p.EndMs | Should -Be ([DateTimeOffset]'2026-10-01T12:00:00Z').ToUnixTimeMilliseconds()
    }
    It 'names every parameter that the mode does not use, with the reason' {
        $collect = @(Get-ExlIgnoredParameter -Mode Collect -Name 'Mode', 'Start', 'End', 'Server', 'ConfigPath')
        $collect.Count | Should -Be 1
        $collect[0] | Should -BeLike '-Start, -End ignored with -Mode Collect: a collection reads every new log line, whatever its date*'
        @(Get-ExlIgnoredParameter -Mode Report -Name 'Range', 'Start', 'End', 'User', 'Server', 'Collect', 'NoCollect', 'OutputPath').Count | Should -Be 0
        @(Get-ExlIgnoredParameter -Mode Collect -Name 'Collect')[0] | Should -Be '-Collect ignored with -Mode Collect: used by -Mode Report only.'
        $status = @(Get-ExlIgnoredParameter -Mode Status -Name 'Range', 'User', 'Server')
        $status.Count | Should -Be 3
        $status[0] | Should -BeLike '-Range ignored with -Mode Status: *whole database*'
        $status[1] | Should -Be '-User ignored with -Mode Status: used by -Mode Report only.'
        @(Get-ExlIgnoredParameter -Mode Discover -Name 'ConnectTo', 'Credential').Count | Should -Be 0
        @(Get-ExlIgnoredParameter -Mode Discover -Name 'Date')[0] | Should -BeLike '-Date ignored with -Mode Discover: *reads no log line*'
        @(Get-ExlIgnoredParameter -Mode Report -Name 'ConnectTo') | Should -Be '-ConnectTo ignored with -Mode Report: used by -Mode Discover only.'
    }
}

Describe 'Entry script' {
    BeforeAll {
        # The entry script emits UTF-8; native stdout is decoded using the caller's console encoding.
        $script:EntryOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    }
    AfterAll {
        [Console]::OutputEncoding = $script:EntryOutputEncoding
    }
    It 'documents the as-is support boundary and every e-mail opt-in' {
        $help = Get-Help (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -Full
        $expected = @(
            'This Script is a Personal project.'
            'It''s provided "AS-IS". It''s not an official Microsoft product so no support can be expected from Microsoft.'
            'As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.'
        ) -join ' '
        $notes = [regex]::Replace(($help.alertSet.alert.Text -join ' '), '\s+', ' ').Trim()
        $notes.EndsWith($expected, [StringComparison]::Ordinal) | Should -BeTrue
        $readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw
        $disclaimer = [regex]::Match($readme, '(?ms)^## Disclaimer\r?\n\s*(.+?)(?=^## |\z)').Groups[1].Value
        [regex]::Replace($disclaimer, '\s+', ' ').Trim() | Should -BeExactly $expected
        $description = $help.description.Text -join ' '
        $description | Should -Match 'disabled in the delivered configuration'
        $description | Should -Match 'Mail\.Enabled'
        $description | Should -Match ([regex]::Escape('-SendMail:$false'))
        $description | Should -Match 'MailTest sends a test message'
        $description | Should -Not -Match 'never sends anything'
    }
    It 'uses the manifest version in the runtime and the entry-script help' {
        $version = (Import-PowerShellDataFile (Join-Path $script:Root 'ExchangeLogReport.psd1')).ModuleVersion
        $moduleVersion = & (Get-Module ExchangeLogReport) { $script:ToolVersion }
        $moduleVersion | Should -Be $version
        $help = Get-Help (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -Full
        ($help.alertSet.alert.Text -join ' ') | Should -Match ('Version\s*:\s*' + [regex]::Escape($version))
    }
    It 'Status on a new installation confirms the configuration and creates no database' {
        $dir = Join-Path $TestDrive 'fresh'
        $cfg = New-TestConfig $dir
        $output = & pwsh -NoProfile -File (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -DevelopmentMode -Mode Status -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Ready for the first collection'
        $output | Should -Not -Match 'ignored with'
        Test-Path -LiteralPath (Join-Path $dir 'data') | Should -BeFalse
    }
    It 'Report with -HtmlLayout Folder writes the page and its data folder for this run only' {
        $dir = Join-Path $TestDrive 'layout-cli'
        $cfg = New-TestConfig $dir
        $s = Import-ExlConfiguration -Path $cfg -Root $script:Root
        [void](Invoke-TestCollection $s)
        $start = $script:Base.AddHours(-1); $end = $script:Base.AddHours(2)
        $entry = Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'
        $output = & pwsh -NoProfile -File $entry -DevelopmentMode -Start $start.ToString('o') -End $end.ToString('o') -ReportType Detailed -NoCollect -HtmlLayout Folder -ConfigPath $cfg 2>&1 | Out-String
        $output | Should -Match 'ExchangeLogs_data\s+\d+ files'
        $page = Get-ChildItem -LiteralPath (Join-Path $dir 'reports') -Recurse -Filter 'ExchangeLogs.html' | Select-Object -First 1
        Test-Path -LiteralPath (Join-Path $page.DirectoryName 'ExchangeLogs_data\.exl-data') | Should -BeTrue
        $single = & pwsh -NoProfile -File $entry -DevelopmentMode -Start $start.ToString('o') -End $end.ToString('o') -ReportType Detailed -NoCollect -ConfigPath $cfg 2>&1 | Out-String
        $single | Should -Not -Match 'ExchangeLogs_data'
        $help = (Get-Help $entry -Parameter HtmlLayout).description.Text -join ' '
        $help | Should -Match 'Report.HtmlLayout'
    }
    It 'Report with -Collect collects, reports and returns 2 when a server cannot be read' {
        $dir = Join-Path $TestDrive 'script'
        $cfg = New-TestConfig $dir
        $start = $script:Base.AddHours(-1); $end = $script:Base.AddHours(2)
        # -Start / -End alone: custom period (-Range Custom implied), never the default range.
        $output = & pwsh -NoProfile -File (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -DevelopmentMode -Start $start.ToString('o') -End $end.ToString('o') -ReportType Detailed -Collect -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $output | Should -Match 'Report \W Detailed \W Custom'
        $zone = (Import-ExlConfiguration -Path $cfg -Root $script:Root).Zone
        $output | Should -Match ([regex]::Escape((Format-ExlRange $start.ToUnixTimeMilliseconds() $end.ToUnixTimeMilliseconds() $zone)))
        $output | Should -Match 'EXCH02'
        $output | Should -Match 'Report ready'
        @(Get-ChildItem (Join-Path $dir 'reports') -Recurse -Filter '*.html').Count | Should -Be 1
    }
    It 'never ignores a period parameter silently' {
        $dir = Join-Path $TestDrive 'period'
        $cfg = New-TestConfig $dir
        $entry = Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'
        # A period with a mode that does not use it: run, with the reason.
        $output = & pwsh -NoProfile -File $entry -DevelopmentMode -Mode Status -Range Custom -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -User alice -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match '-Range, -Start, -End ignored with -Mode Status: -Mode Status describes the whole database'
        $output | Should -Match '-User ignored with -Mode Status'
        # A period that contradicts -Range: error, nothing is run.
        $output = & pwsh -NoProfile -File $entry -DevelopmentMode -Range Last7Days -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'cannot be combined with -Range Last7Days'
        Test-Path -LiteralPath (Join-Path $dir 'data') | Should -BeFalse
        # Two kinds of period: refused by the parameter sets before the script runs.
        { & $entry -Month 2026-09 -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -ConfigPath $cfg } | Should -Throw -ErrorId 'AmbiguousParameterSet*'
        { & $entry -Date 2026-09-28 -Month 2026-09 -ConfigPath $cfg } | Should -Throw -ErrorId 'AmbiguousParameterSet*'
        $syntax = (Get-Command $entry).ParameterSets
        ($syntax | Where-Object Name -eq 'Custom').Parameters | Where-Object Name -in 'Start', 'End' | ForEach-Object IsMandatory | Should -Be $true, $true
    }
}

Describe 'Report and age of the data' {
    BeforeAll {
        $script:AgeDir = Join-Path $TestDrive 'age'
        $script:AgeCfg = New-TestConfig $script:AgeDir
        $script:AgeEntry = Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'
        $script:AgeSettings = Import-ExlConfiguration -Path $script:AgeCfg -Root $script:Root
        function Set-LastCollection([long]$EndedMs) {
            $store = Open-ExlStore -Settings $script:AgeSettings
            try { $store.Exec("UPDATE run SET ended_ms = $EndedMs, started_ms = MIN(started_ms, $EndedMs);") } finally { $store.Dispose() }
        }
    }
    It 'stops with the next step when nothing has been collected yet' {
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'No collection in the database yet: run .*-Mode Collect.* first'
        $output | Should -Not -Match 'Reading the new log lines'
        Test-Path -LiteralPath (Join-Path $script:AgeDir 'data') | Should -BeFalse
    }
    It 'reads the database without collecting after a recent collection' {
        $null = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Mode Collect -ConfigPath $script:AgeCfg 2>&1
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Data\s+collected until .* ago\)'
        $output | Should -Not -Match 'Reading the new log lines'
        $output | Should -Match 'Report ready'
    }
    It 'reads the new log lines first when the last collection is older than MaxDataAgeMinutes' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Set-LastCollection ($now - 3 * 3600000)
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match 'more than 90 min \(Report.MaxDataAgeMinutes\): the new log lines are read first'
        $output | Should -Match 'Reading the new log lines'
        $output | Should -Match 'Report ready'
    }
    It 'does not collect for a period that ends before the last collection, nor with -NoCollect or MaxDataAgeMinutes = 0' {
        $now = [DateTimeOffset]::UtcNow
        Set-LastCollection ($now.AddHours(-3).ToUnixTimeMilliseconds())
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Start $now.AddHours(-6).ToString('o') -End $now.AddHours(-4).ToString('o') -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match 'the period is complete'
        $output | Should -Not -Match 'Reading the new log lines'
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -NoCollect -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match '-NoCollect'
        $output | Should -Not -Match 'Reading the new log lines'
        $never = Join-Path $script:AgeDir 'never.config.psd1'
        [IO.File]::WriteAllText($never, [IO.File]::ReadAllText($script:AgeCfg).Replace('MaxDataAgeMinutes     = 90', 'MaxDataAgeMinutes     = 0'), [Text.UTF8Encoding]::new($true))
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -ConfigPath $never 2>&1 | Out-String
        $output | Should -Match 'add -Collect to read the new log lines first'
        $output | Should -Not -Match 'Reading the new log lines'
    }
    It 'collects with -Collect whatever the age, refuses -Collect with -NoCollect, and never waits for a running collection' {
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -Collect -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match '-Collect: the new log lines are read first'
        $output | Should -Match 'Reading the new log lines'
        $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -Collect -NoCollect -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match '-Collect and -NoCollect cannot be used together'
        # Old data and a collection running (its lock is held): the report uses the data as it is.
        Set-LastCollection ([DateTimeOffset]::UtcNow.AddHours(-3).ToUnixTimeMilliseconds())
        $held = [IO.FileStream]::new($script:AgeSettings.Storage.DatabasePath + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            $output = & pwsh -NoProfile -File $script:AgeEntry -DevelopmentMode -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        }
        finally { $held.Dispose() }
        $output | Should -Match 'a collection is running .*: the report uses the data already collected'
        $output | Should -Not -Match 'Reading the new log lines'
        $output | Should -Match 'Report ready'
    }
}
Describe 'Parallel collection' {
    It 'gives the same data with one thread, with several threads, one file per server, and the client sessions evicted from memory' {
        $counts = foreach ($run in @(@{ Threads = 1; Evict = 20000; PerServer = 4 }, @{ Threads = 6; Evict = 20000; PerServer = 4 }, @{ Threads = 6; Evict = 1; PerServer = 1 }, @{ Threads = 1; Evict = 1; PerServer = 1 })) {
            $threads = $run.Threads
            $dir = Join-Path $TestDrive "parallel$threads-$($run.Evict)"
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir @{ 'PopImap         = $false' = 'PopImap         = $true'; 'Parallelism            = 0' = "Parallelism            = $threads"; 'MaxFilesPerServer      = 4' = "MaxFilesPerServer      = $($run.PerServer)" }) -Root $script:Root
            $s.Collection.Parallelism | Should -Be $threads
            $s.Collection.MaxFilesPerServer | Should -Be $run.PerServer
            [ExchangeLogReport.Collector]::EvictAboveKeys = $run.Evict
            try { $r = Invoke-TestCollection $s } finally { [ExchangeLogReport.Collector]::EvictAboveKeys = 20000 }
            $r.Statistics | Should -Match "$threads parse thread"
            $r.Statistics | Should -Match 'waiting for a file to read \d+[.,]\d s, waiting for room in the queue \d+[.,]\d s'
            $r.Statistics | Should -Match 'rows \d+[.,]\d s \(SMTP \d+[.,]\d s, message tracking \d+[.,]\d s\)'
            if ($run.PerServer -eq 1) { $r.Statistics | Should -Match 'at most 1 file\(s\) of one server' }
            # Counts, and the content that depends on the order of the files (accounts learnt from HttpProxy, SMTP identities, rollups).
            (Query $s "SELECT (SELECT COUNT(*) FROM access_usage), (SELECT SUM(requests) FROM access_usage), (SELECT COUNT(*) FROM access_event), (SELECT COUNT(*) FROM access_event WHERE recovered_ms IS NOT NULL),
                (SELECT COUNT(*) FROM client_session), (SELECT SUM(requests) FROM client_session), (SELECT COUNT(*) FROM smtp_transaction), (SELECT COUNT(*) FROM message_event),
                (SELECT COUNT(*) FROM access_client), (SELECT COUNT(*) FROM access_action), (SELECT SUM(lines) FROM noise),
                (SELECT group_concat(k, ';') FROM (SELECT user || '|' || protocol || '|' || requests AS k FROM access_usage ORDER BY k)),
                (SELECT group_concat(k, ';') FROM (SELECT skey || '|' || start_ms || '|' || end_ms || '|' || requests || '|' || COALESCE(auth_modes, '-') AS k FROM client_session ORDER BY k)),
                (SELECT group_concat(k, ';') FROM (SELECT day || '|' || user || '|' || protocol || '|' || auth_type || '|' || requests AS k FROM access_client ORDER BY k)),
                (SELECT group_concat(k, ';') FROM (SELECT session_id || '|' || time_ms || '|' || COALESCE(auth_user, '-') || '|' || COALESCE(auth_result, '-') AS k FROM smtp_transaction ORDER BY k)),
                (SELECT COUNT(*) FROM message_rollup), (SELECT SUM(smtp_count) FROM message_rollup), (SELECT SUM(events_count) FROM message_rollup)")[0] -join ','
        }
        $counts[0] | Should -Be $counts[1]
        $counts[0] | Should -Be $counts[2]
        $counts[0] | Should -Be $counts[3]
    }
    It 'merges the SMTP and message tracking files with the other files in proportion to their bytes, after HttpProxy for the back-end files' {
        $at = [datetime]::new(2026, 10, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $file = { param([string]$Kind, [string]$Name, [int]$Minute, [long]$Length, [string]$Server = 'EX1', [long]$Offset = 0)
            $j = [ExchangeLogReport.SourceJob]::new(); $j.Server = $Server; $j.Kind = $Kind
            $w = [ExchangeLogReport.FileWork]::new(); $w.Job = $j; $w.Name = $Name; $w.Path = $Name; $w.Length = $Length; $w.LastWriteUtc = $at.AddMinutes($Minute)
            $w.State = [ExchangeLogReport.FileState]::new(); $w.State.Offset = $Offset
            $w }
        # Main stream 300 bytes (two HttpProxy files, then a back-end file older than both), filler 150 bytes: one filler file after each main file.
        $plan = @(
            (& $file 'Tracking' 'F3' 30 50), (& $file 'HttpProxy' 'H2' 20 100), (& $file 'Iis' 'B1' 0 100), (& $file 'SmtpReceive' 'F1' 5 50),
            (& $file 'HttpProxy' 'H1' 10 100), (& $file 'Tracking' 'F2' 10 80 'EX1' 30))
        $order = @([ExchangeLogReport.ParseSchedule]::Order([ExchangeLogReport.FileWork[]]$plan) | ForEach-Object Name)
        $order -join ',' | Should -Be 'H1,F1,H2,F2,B1,F3'
        # Every planned file once; each stream keeps its order (last write, then the larger file first).
        @($order | Sort-Object) -join ',' | Should -Be 'B1,F1,F2,F3,H1,H2'
        $tie = @((& $file 'Tracking' 'small' 0 10), (& $file 'Tracking' 'large' 0 90), (& $file 'HttpProxy' 'p2' 1 10), (& $file 'HttpProxy' 'p1' 0 10))
        @([ExchangeLogReport.ParseSchedule]::Order([ExchangeLogReport.FileWork[]]$tie) | ForEach-Object Name) -join ',' | Should -Be 'p1,large,p2,small'
        # A larger filler: two filler files per main file, the shares of the bytes taken stay within one file of the plan.
        $big = @(foreach ($i in 1..4) { & $file 'HttpProxy' "H$i" $i 100 }) + @(foreach ($i in 1..8) { & $file 'SmtpSend' "S$i" $i 100 })
        $sequence = @([ExchangeLogReport.ParseSchedule]::Order([ExchangeLogReport.FileWork[]]$big))
        $sequence.Name -join ',' | Should -Be 'H1,S1,S2,H2,S3,S4,H3,S5,S6,H4,S7,S8'
        $taken = 0L; $filler = 0L
        foreach ($w in $sequence) {
            $taken += $w.Length; if ($w.Job.Kind -eq 'SmtpSend') { $filler += $w.Length }
            [Math]::Abs($filler - $taken * 800 / 1200) | Should -BeLessOrEqual 100
        }
        # The gate: no back-end file before every HttpProxy file is applied; the filler (and nothing else) is taken meanwhile.
        $schedule = [ExchangeLogReport.ParseSchedule]::new([ExchangeLogReport.FileWork[]]@((& $file 'HttpProxy' 'H' 0 100), (& $file 'MapiBackEnd' 'M' 0 100), (& $file 'Tracking' 'T1' 5 10), (& $file 'Tracking' 'T2' 6 10)))
        $schedule.FirstCount | Should -Be 1
        $schedule.Take($false, $null).Name | Should -Be 'H'
        $schedule.Take($false, $null).Name | Should -Be 'T1'
        $schedule.Take($false, $null).Name | Should -Be 'T2'
        $schedule.Take($false, $null) | Should -BeNullOrEmpty
        $schedule.Count | Should -Be 1
        $schedule.Take($true, $null).Name | Should -Be 'M'
        $schedule.Count | Should -Be 0
        # A file of a server that already reads MaxFilesPerServer files is passed over, in the same stream first.
        $busy = [ExchangeLogReport.ParseSchedule]::new([ExchangeLogReport.FileWork[]]@((& $file 'HttpProxy' 'A1' 0 100 'A'), (& $file 'HttpProxy' 'B1' 1 100 'B'), (& $file 'Tracking' 'A2' 0 100 'A')))
        $notA = [Func[ExchangeLogReport.FileWork, bool]] { param($w) $w.Job.Server -ne 'A' }
        $busy.Take($true, $notA).Name | Should -Be 'B1'
        $busy.Take($true, $notA) | Should -BeNullOrEmpty
        $busy.Take($true, $null).Name | Should -Be 'A2'
        $busy.Take($true, $null).Name | Should -Be 'A1'
        # Bytes already read do not count (the read position of a known file).
        [ExchangeLogReport.ParseSchedule]::PlannedBytes((& $file 'Tracking' 'grown' 0 80 'EX1' 30)) | Should -Be 50
        [ExchangeLogReport.ParseSchedule]::PlannedBytes((& $file 'Tracking' 'shorter' 0 80 'EX1' 100)) | Should -Be 80
    }
    It 'refuses a number of threads out of range' {
        $dir = Join-Path $TestDrive 'parallelbad'
        { Import-ExlConfiguration -Path (New-TestConfig $dir @{ 'Parallelism            = 0' = 'Parallelism            = 99' }) -Root $script:Root } | Should -Throw '*Collection.Parallelism must be a whole number between 0 and 64*'
    }
}

Describe 'E-mail' {
    BeforeAll {
        if (-not ('ElrTest.FakeSmtp' -as [type])) {
            Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace ElrTest
{
    /// <summary>A minimal SMTP server for the tests: EHLO, STARTTLS or implicit TLS, AUTH LOGIN / PLAIN, MAIL, RCPT, DATA, QUIT.</summary>
    public sealed class FakeSmtp : IDisposable
    {
        readonly TcpListener _listener = new TcpListener(IPAddress.Loopback, 0);
        readonly Thread _thread;
        public int Port;
        public X509Certificate2 Certificate;
        public bool OfferStartTls, ImplicitTls, OfferLogin = true, OfferPlain = true;
        public string User, Password, RefuseRecipient;
        public string AuthUser, AuthPassword, Mechanism, From;
        public bool UsedTls;
        public List<string> Commands = new List<string>(), Recipients = new List<string>(), Messages = new List<string>();

        public FakeSmtp()
        {
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _thread = new Thread(Loop) { IsBackground = true };
            _thread.Start();
        }

        void Loop()
        {
            while (true)
            {
                TcpClient client;
                try { client = _listener.AcceptTcpClient(); } catch { return; }
                try { using (client) Serve(client.GetStream()); } catch { }
            }
        }

        Stream _s;
        string Line()
        {
            var b = new List<byte>();
            while (true) { int x = _s.ReadByte(); if (x < 0) return null; if (x == '\n') break; if (x != '\r') b.Add((byte)x); }
            return Encoding.ASCII.GetString(b.ToArray());
        }
        void Send(string l) { var b = Encoding.ASCII.GetBytes(l + "\r\n"); _s.Write(b, 0, b.Length); _s.Flush(); }
        bool _tls;
        void Secure() { var ssl = new SslStream(_s, false); ssl.AuthenticateAsServer(Certificate, false, false); _s = ssl; UsedTls = true; _tls = true; }

        void Serve(Stream stream)
        {
            _s = stream;
            _tls = false;
            if (ImplicitTls) Secure();
            Send("220 fake.test ESMTP ready");
            while (true)
            {
                string l = Line();
                if (l == null) return;
                lock (Commands) Commands.Add(l.StartsWith("AUTH PLAIN ") ? "AUTH PLAIN ***" : l);
                string u = l.ToUpperInvariant();
                if (u.StartsWith("EHLO"))
                {
                    Send("250-fake.test Hello");
                    Send("250-SIZE 10000000");
                    if (OfferStartTls && !_tls) Send("250-STARTTLS");
                    var auth = new List<string>();
                    if (OfferLogin) auth.Add("LOGIN");
                    if (OfferPlain) auth.Add("PLAIN");
                    if (auth.Count > 0) Send("250-AUTH " + string.Join(" ", auth));
                    Send("250 8BITMIME");
                }
                else if (u == "STARTTLS") { Send("220 2.0.0 ready for TLS"); Secure(); }
                else if (u == "AUTH LOGIN")
                {
                    Mechanism = "LOGIN";
                    Send("334 VXNlcm5hbWU6"); AuthUser = Encoding.UTF8.GetString(Convert.FromBase64String(Line()));
                    Send("334 UGFzc3dvcmQ6"); AuthPassword = Encoding.UTF8.GetString(Convert.FromBase64String(Line()));
                    Send(AuthUser == User && AuthPassword == Password ? "235 2.7.0 Authentication successful" : "535 5.7.3 Authentication unsuccessful");
                }
                else if (u.StartsWith("AUTH PLAIN "))
                {
                    Mechanism = "PLAIN";
                    var parts = Encoding.UTF8.GetString(Convert.FromBase64String(l.Substring(11))).Split('\0');
                    AuthUser = parts[1]; AuthPassword = parts[2];
                    Send(AuthUser == User && AuthPassword == Password ? "235 2.7.0 Authentication successful" : "535 5.7.3 Authentication unsuccessful");
                }
                else if (u.StartsWith("MAIL FROM:")) { From = l.Substring(10); Send("250 2.1.0 Sender OK"); }
                else if (u.StartsWith("RCPT TO:"))
                {
                    string r = l.Substring(8).Trim('<', '>', ' ');
                    if (RefuseRecipient != null && r == RefuseRecipient) Send("550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipient not found");
                    else { Recipients.Add(r); Send("250 2.1.5 Recipient OK"); }
                }
                else if (u == "DATA")
                {
                    Send("354 Start mail input; end with <CRLF>.<CRLF>");
                    var sb = new StringBuilder();
                    string d;
                    while ((d = Line()) != null && d != ".") sb.Append(d.StartsWith("..") ? d.Substring(1) : d).Append("\r\n");
                    lock (Messages) Messages.Add(sb.ToString());
                    Send("250 2.6.0 <fake-1@fake.test> [InternalId=1] Queued mail for delivery");
                }
                else if (u == "QUIT") { Send("221 2.0.0 Bye"); return; }
                else Send("500 5.3.3 Unrecognized command");
            }
        }

        public void Dispose() { try { _listener.Stop(); } catch { } }

        /// <summary>Self-signed certificate of the server (exportable key, as SslStream needs on Windows).</summary>
        public static X509Certificate2 NewCertificate(string name)
        {
            using (var rsa = System.Security.Cryptography.RSA.Create(2048))
            {
                var req = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=" + name, rsa, System.Security.Cryptography.HashAlgorithmName.SHA256, System.Security.Cryptography.RSASignaturePadding.Pkcs1);
                var san = new SubjectAlternativeNameBuilder(); san.AddDnsName(name); req.CertificateExtensions.Add(san.Build());
                using (var c = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30)))
                    return new X509Certificate2(c.Export(X509ContentType.Pfx, "t"), "t", X509KeyStorageFlags.Exportable);
            }
        }
    }
}
'@
        }
        $script:Cert = [ElrTest.FakeSmtp]::NewCertificate('localhost')
        function New-MailSettings([int]$Port, [string]$Encryption = 'None', [string]$Authentication = 'Anonymous', [string]$User, [string]$Password, [string]$Thumbprint) {
            $m = [ExchangeLogReport.MailSettings]::new()
            $m.Server = 'localhost'; $m.Port = $Port; $m.Encryption = $Encryption; $m.Authentication = $Authentication; $m.UserName = $User; $m.Password = $Password
            $m.CertificateThumbprint = $Thumbprint; $m.From = 'elr@contoso.test'; $m.To = [string[]]@('team@contoso.test'); $m.Cc = [string[]]@('boss@contoso.test'); $m.TimeoutSeconds = 10
            return $m
        }
        function New-Content([string]$Subject = 'Test') {
            $c = [ExchangeLogReport.MailContent]::new(); $c.Subject = $Subject; $c.Text = "line 1`r`n.line starting with a dot"; $c.Html = '<p>html</p>'
            return $c
        }
        function Set-MailBlock([string]$Text, [string]$Values) {
            # The Mail section of a configuration replaced by these values.
            return [regex]::Replace($Text, '(?ms)^    Mail = @\{.*?^    \}', ('    Mail = @{ ' + $Values.Replace('$', '$$') + ' }'))
        }
        function Get-Part([string]$Message, [string]$ContentType) {
            # Decoded body of the first MIME part of this type.
            $m = [regex]::Match($Message, "Content-Type: $([regex]::Escape($ContentType))[^\r\n]*\r\n(?:[^\r\n]+\r\n)*\r\n([A-Za-z0-9+/=\r\n]+?)\r\n--")
            if (-not $m.Success) { return $null }
            return [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
        }
    }

    It 'loads a configuration without Mail section, and checks every Mail value' {
        $s = Import-ExlConfiguration -Path (Join-Path $script:Root 'config\ExchangeLogReport.config.psd1') -Root $script:Root
        $s.Mail.Enabled | Should -BeFalse
        $s.Mail.Port | Should -Be 25
        $dir = Join-Path $TestDrive 'mailcfg'
        $cfg = New-TestConfig $dir
        $text = [IO.File]::ReadAllText($cfg)
        $bad = Set-MailBlock $text "Enabled = `$true; Encryption = 'None'; Authentication = 'Basic'; From = 'Report <elr@contoso.test>'; To = @('team@contoso.test', 'not an address'); Colour = 'red'"
        [IO.File]::WriteAllText($cfg, $bad)
        $err = $null
        try { Import-ExlConfiguration -Path $cfg -Root $script:Root } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Mail.Colour is not a known setting'
        $err | Should -Match "Mail.Authentication = 'Basic' sends a password: it needs Mail.Encryption = 'StartTls' or 'Tls'"
        $err | Should -Match "'Report <elr@contoso.test>' is not an e-mail address"
        $err | Should -Match "'not an address' is not an e-mail address"
        $err | Should -Match 'Mail.Enabled is \$true but Mail.SmtpServer is not set'
        [IO.File]::WriteAllText($cfg, (Set-MailBlock $text "SmtpServer = 'smtp.contoso.test'; Encryption = 'Tls'; From = 'elr@contoso.test'; To = @('team@contoso.test')"))
        $ok = Import-ExlConfiguration -Path $cfg -Root $script:Root
        $ok.Mail.Port | Should -Be 465
        $ok.Mail.Subject | Should -Be '{Title} - {Type} report - {Period}'
    }

    It 'sends anonymously in clear: MIME message with text, HTML, attachment and dot-stuffing' {
        $server = [ElrTest.FakeSmtp]::new()
        try {
            $content = New-Content 'Exchange report – October'
            $a = [ExchangeLogReport.MailAttachment]::new(); $a.Name = 'report café.zip'; $a.ContentType = 'application/zip'; $a.Content = [byte[]](1..200)
            $content.Attachments.Add($a)
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port), $content)
            $r.Sent | Should -BeTrue -Because $r.Error
            $r.AuthenticationUsed | Should -Be 'Anonymous'
            $r.Tls | Should -BeNullOrEmpty
            $server.Recipients | Should -Be @('team@contoso.test', 'boss@contoso.test')
            $message = $server.Messages[0]
            $message | Should -Match 'Subject: =\?utf-8\?B\?'
            $message | Should -Match 'filename\*=utf-8''''report%20caf%C3%A9\.zip'
            [Text.Encoding]::UTF8.GetString((Get-Part $message 'text/plain')) | Should -Be "line 1`r`n.line starting with a dot"
            [Text.Encoding]::UTF8.GetString((Get-Part $message 'text/html')) | Should -Be '<p>html</p>'
            (Get-Part $message 'application/zip') | Should -Be ([byte[]](1..200))
            $server.Commands | Should -Contain 'QUIT'
        } finally { $server.Dispose() }
    }

    It 'uses STARTTLS and Basic authentication (AUTH LOGIN), the certificate pinned by its thumbprint' {
        $server = [ElrTest.FakeSmtp]::new(); $server.Certificate = $script:Cert; $server.OfferStartTls = $true; $server.User = 'CONTOSO\svc-smtp'; $server.Password = 'P@ss w0rd!'
        try {
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls' 'Basic' 'CONTOSO\svc-smtp' 'P@ss w0rd!' $script:Cert.Thumbprint), (New-Content))
            $r.Sent | Should -BeTrue -Because $r.Error
            $server.UsedTls | Should -BeTrue
            $server.Mechanism | Should -Be 'LOGIN'
            $r.Tls | Should -Match '^TLS 1\.[23], '
            $r.AuthenticationUsed | Should -Be 'Basic (AUTH LOGIN, CONTOSO\svc-smtp)'
            $r.Certificate | Should -Match ([regex]::Escape($script:Cert.Thumbprint))
            ($r.Transcript -join "`n") | Should -Not -Match ([regex]::Escape([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('P@ss w0rd!'))))
            ($r.Transcript -join "`n") | Should -Match '\(password\)'
        } finally { $server.Dispose() }
    }

    It 'uses TLS from the first byte (SMTPS) and AUTH PLAIN when LOGIN is not offered' {
        $server = [ElrTest.FakeSmtp]::new(); $server.Certificate = $script:Cert; $server.ImplicitTls = $true; $server.OfferLogin = $false; $server.User = 'relay@contoso.test'; $server.Password = 'secret'
        try {
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'Tls' 'Basic' 'relay@contoso.test' 'secret' $script:Cert.Thumbprint), (New-Content))
            $r.Sent | Should -BeTrue -Because $r.Error
            $server.Mechanism | Should -Be 'PLAIN'
            $server.AuthPassword | Should -Be 'secret'
        } finally { $server.Dispose() }
    }

    It 'never sends in clear when STARTTLS is required, and refuses an untrusted certificate' {
        $server = [ElrTest.FakeSmtp]::new()
        try {
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls'), (New-Content))
            $r.Sent | Should -BeFalse
            $r.Error | Should -Match 'does not offer STARTTLS'
            @($server.Commands | Where-Object { $_ -like 'MAIL FROM*' }).Count | Should -Be 0
        } finally { $server.Dispose() }
        $server = [ElrTest.FakeSmtp]::new(); $server.Certificate = $script:Cert; $server.OfferStartTls = $true
        try {
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls'), (New-Content))
            $r.Sent | Should -BeFalse
            $r.Error | Should -Match 'certificate of the server is not trusted'
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls' -Thumbprint ('0' * 40)), (New-Content))
            $r.Error | Should -Match 'not the one of Mail.CertificateThumbprint'
        } finally { $server.Dispose() }
    }

    It 'explains a wrong password, a server without Kerberos and a refused recipient' {
        $server = [ElrTest.FakeSmtp]::new(); $server.Certificate = $script:Cert; $server.OfferStartTls = $true; $server.User = 'u'; $server.Password = 'right'; $server.RefuseRecipient = 'boss@contoso.test'
        try {
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls' 'Basic' 'u' 'wrong' $script:Cert.Thumbprint), (New-Content))
            $r.Sent | Should -BeFalse
            $r.Error | Should -Match '535 5.7.3'
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls' 'Kerberos' -Thumbprint $script:Cert.Thumbprint), (New-Content))
            $r.Error | Should -Match 'does not offer Kerberos \(AUTH GSSAPI\); it offers LOGIN, PLAIN'
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port 'StartTls' 'Basic' 'u' 'right' $script:Cert.Thumbprint), (New-Content))
            $r.Sent | Should -BeTrue
            $r.Refused | Should -Match '^boss@contoso.test: 550 5.1.10'
        } finally { $server.Dispose() }
    }

    It 'keeps the password of the SMTP account protected by DPAPI, readable by this account only' {
        $dir = Join-Path $TestDrive 'mailcred'
        $s = Import-ExlConfiguration -Path (New-TestConfig $dir) -Root $script:Root
        $s.Mail.CredentialFile = Join-Path $dir 'mail.credential'
        $credential = [pscredential]::new('CONTOSO\svc-smtp', (ConvertTo-SecureString 'Sup3r-secret' -AsPlainText -Force))
        Save-ExlMailCredential -Settings $s -Credential $credential
        $raw = Get-Content -LiteralPath $s.Mail.CredentialFile -Raw
        $raw | Should -Not -Match 'Sup3r-secret'
        ($raw | ConvertFrom-Json).UserName | Should -Be 'CONTOSO\svc-smtp'
        $back = & (Get-Module ExchangeLogReport) { param($x) Read-ExlMailCredential -Settings $x } $s
        $back.Password | Should -Be 'Sup3r-secret'
        (Get-Acl -LiteralPath $s.Mail.CredentialFile).AreAccessRulesProtected | Should -BeTrue
        $s.Mail.Authentication = 'Basic'; $s.Mail.Encryption = 'StartTls'
        $smtp = & (Get-Module ExchangeLogReport) { param($x) New-ExlMailSettings -Settings $x } $s
        $smtp.UserName | Should -Be 'CONTOSO\svc-smtp'
    }

    It 'lists the main problems of a Detailed report in the body, and the kinds without any' {
        $report = [ExchangeLogReport.ReportResult]::new(); $report.Folder = $TestDrive; $report.Title = 'Exchange Log Report'
        $users = [ExchangeLogReport.ReportHighlight]::new(); $users.Title = 'Users with unresolved failures'; $users.Hint = 'h'; $users.Columns = [string[]]@('User', 'Unresolved'); $users.Total = 12
        foreach ($i in 1..10) { $users.Rows.Add([string[]]@("contoso\user$i", '1')) }
        $smtp = [ExchangeLogReport.ReportHighlight]::new(); $smtp.Title = 'SMTP clients with refused or deferred mail'; $smtp.Hint = 'h'; $smtp.Columns = [string[]]@('Client'); $smtp.Total = 0
        $report.Highlights.Add($users); $report.Highlights.Add($smtp)
        $mail = [ExchangeLogReport.ReportMail]::Build($report, 's', 'Exchange Log Report', 'p', 'Detailed', 'PC1', 'None', 1MB)
        $mail.Html | Should -Match 'Users with unresolved failures \(12, first 10\)'
        $mail.Html | Should -Match 'contoso\\user10'
        $mail.Html | Should -Match 'None in this period: smtp clients with refused or deferred mail'
        $mail.Text | Should -Match 'MAIN PROBLEMS'
        # A Usage report has no highlights: no section.
        $usage = [ExchangeLogReport.ReportMail]::Build([ExchangeLogReport.ReportResult]@{ Folder = $TestDrive; Title = 't' }, 's', 't', 'p', 'Usage', 'PC1', 'None', 1MB)
        $usage.Html | Should -Not -Match 'Main problems'
    }
    It 'leaves out a report larger than MaxAttachmentMB, and says where it is' {
        $folder = Join-Path $TestDrive 'bigreport'
        [void][IO.Directory]::CreateDirectory($folder)
        $htmlPath = Join-Path $folder 'ExchangeLogs.html'
        $random = [byte[]]::new(300000); [Random]::new(1).NextBytes($random)
        [IO.File]::WriteAllBytes($htmlPath, $random)
        $report = [ExchangeLogReport.ReportResult]::new(); $report.Folder = $folder; $report.HtmlPath = $htmlPath; $report.Title = 'Exchange Log Report'
        $small = [ExchangeLogReport.ReportMail]::Build($report, 's', 'Exchange Log Report', 'p', 'Usage', 'PC1', 'Html', 1MB)
        $small.Attachments.Count | Should -Be 1
        $small.Attachments[0].Name | Should -Be 'ExchangeLogs.html'
        $small.OmittedBytes | Should -Be 0
        $big = [ExchangeLogReport.ReportMail]::Build($report, 's', 'Exchange Log Report', 'p', 'Usage', 'PC1', 'Html', 100000)
        $big.Attachments.Count | Should -Be 0
        $big.OmittedBytes | Should -BeGreaterThan 100000
        $big.Html | Should -Match 'larger than Mail.MaxAttachmentMB'
        $big.Text | Should -Match ([regex]::Escape($folder))
    }
    It 'attaches a folder report as one zip with the page and its data folder' {
        $folder = Join-Path $TestDrive 'folderreport'
        $data = Join-Path $folder 'ExchangeLogs_data'
        [void][IO.Directory]::CreateDirectory($data)
        [IO.File]::WriteAllText((Join-Path $folder 'ExchangeLogs.html'), '<html>page</html>')
        [IO.File]::WriteAllText((Join-Path $data '.exl-data'), "id`r`n")
        [IO.File]::WriteAllText((Join-Path $data 's-sessions-001.js'), '__exl.file("id","s-sessions-001.js");')
        $report = [ExchangeLogReport.ReportResult]::new(); $report.Folder = $folder; $report.Title = 't'
        $report.HtmlPath = Join-Path $folder 'ExchangeLogs.html'; $report.HtmlDataFolder = $data
        $mail = [ExchangeLogReport.ReportMail]::Build($report, 's', 't', 'p', 'Usage', 'PC1', 'Html', 1MB)
        $mail.Attachments.Count | Should -Be 1
        $mail.Attachments[0].Name | Should -Be 'ExchangeLogs.zip'
        $ms = [IO.MemoryStream]::new($mail.Attachments[0].Content); $zip = [IO.Compression.ZipArchive]::new($ms)
        try { @($zip.Entries.FullName | Sort-Object) | Should -Be @(@('ExchangeLogs.html', 'ExchangeLogs_data/.exl-data', 'ExchangeLogs_data/s-sessions-001.js') | Sort-Object) }
        finally { $zip.Dispose(); $ms.Dispose() }
        $mail.Text | Should -Match 'needs its ExchangeLogs_data folder: extract the zip'
        @(Get-ChildItem -LiteralPath $folder -Force -Filter '.mail-*').Count | Should -Be 0
    }
    It 'leaves out a large folder report without building the archive' {
        $folder = Join-Path $TestDrive 'bigfolderreport'
        $data = Join-Path $folder 'ExchangeLogs_data'
        [void][IO.Directory]::CreateDirectory($data)
        [IO.File]::WriteAllText((Join-Path $folder 'ExchangeLogs.html'), '<html>page</html>')
        $random = [byte[]]::new(200000); [Random]::new(2).NextBytes($random)
        foreach ($i in 1..3) { [IO.File]::WriteAllBytes((Join-Path $data "s-sessions-00$i.js"), $random) }
        $report = [ExchangeLogReport.ReportResult]::new(); $report.Folder = $folder; $report.Title = 't'
        $report.HtmlPath = Join-Path $folder 'ExchangeLogs.html'; $report.HtmlDataFolder = $data
        $mail = [ExchangeLogReport.ReportMail]::Build($report, 's', 't', 'p', 'Usage', 'PC1', 'Html', 10KB)
        $mail.Attachments.Count | Should -Be 0
        $mail.OmittedBytes | Should -Be (600000 + 17)
        $mail.Text | Should -Match 'about \d+\.\d MB\) is larger than Mail.MaxAttachmentMB'
        $mail.Text | Should -Match ([regex]::Escape($folder))
        @(Get-ChildItem -LiteralPath $folder -Force -Filter '.mail-*').Count | Should -Be 0
    }
    It 'puts the data folder in the archive when Attach is Zip' {
        $folder = Join-Path $TestDrive 'zipfolderreport'
        $data = Join-Path $folder 'ExchangeLogs_data'
        [void][IO.Directory]::CreateDirectory($data)
        [IO.File]::WriteAllText((Join-Path $folder 'ExchangeLogs.html'), '<html>page</html>')
        [IO.File]::WriteAllText((Join-Path $folder 'ExchangeLogs-Users.csv'), 'User')
        [IO.File]::WriteAllText((Join-Path $data 's-users-001.js'), 'x')
        $report = [ExchangeLogReport.ReportResult]::new(); $report.Folder = $folder; $report.Title = 't'
        $report.HtmlPath = Join-Path $folder 'ExchangeLogs.html'; $report.HtmlDataFolder = $data
        foreach ($f in 'ExchangeLogs.html', 'ExchangeLogs-Users.csv') { $file = [ExchangeLogReport.ReportFile]::new(); $file.Path = Join-Path $folder $f; $report.Files.Add($file) }
        $mail = [ExchangeLogReport.ReportMail]::Build($report, 's', 't', 'p', 'Usage', 'PC1', 'Zip', 1MB)
        $ms = [IO.MemoryStream]::new($mail.Attachments[0].Content); $zip = [IO.Compression.ZipArchive]::new($ms)
        try { @($zip.Entries.FullName | Sort-Object) | Should -Be @(@('ExchangeLogs-Users.csv', 'ExchangeLogs.html', 'ExchangeLogs_data/s-users-001.js') | Sort-Object) }
        finally { $zip.Dispose(); $ms.Dispose() }
    }
    It 'sends the report with its summary (-SendMail), and tests the settings (-Mode MailTest)' {
        $server = [ElrTest.FakeSmtp]::new()
        try {
            $dir = Join-Path $TestDrive 'mailreport'
            $cfg = New-TestConfig $dir
            $text = Set-MailBlock ([IO.File]::ReadAllText($cfg)) "SmtpServer = 'localhost'; Port = $($server.Port); Encryption = 'None'; From = 'elr@contoso.test'; To = @('team@contoso.test'); Attach = 'Zip'"
            [IO.File]::WriteAllText($cfg, $text)
            $entry = Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'
            $output = & pwsh -NoProfile -File $entry -DevelopmentMode -Mode MailTest -ConfigPath $cfg 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
            $output | Should -Match 'Test message sent'
            $output | Should -Match 'S: 250 2.6.0'
            $output = & pwsh -NoProfile -File $entry -DevelopmentMode -Range Last24Hours -ReportType Detailed -Collect -SendMail -ConfigPath $cfg 2>&1 | Out-String
            $output | Should -Match 'Sending the report by e-mail'
            $output | Should -Match 'Sent to team@contoso.test'
            $output | Should -Match 'ExchangeLogs_Detailed_\S+\.zip \(.+\) attached'
            $server.Messages.Count | Should -Be 2
            $message = $server.Messages[1]
            $html = [Text.Encoding]::UTF8.GetString((Get-Part $message 'text/html'))
            $html | Should -Match 'Detailed report'
            $html | Should -Match 'EXCH01'
            # Detailed: the main problems of the period in the body (top 10 per kind), or the kinds without any.
            $html | Should -Match 'Main problems'
            $html | Should -Match 'Users with unresolved failures \(|None in this period: users with unresolved failures'
            $html | Should -Match 'Client sessions that failed \(|client sessions that failed'
            $zip = Get-Part $message 'application/zip'
            $zip.Length | Should -BeGreaterThan 1000
            $ms = [IO.MemoryStream]::new($zip); $archive = [IO.Compression.ZipArchive]::new($ms)
            ($archive.Entries.Name -join ',') | Should -Match 'ExchangeLogs-Servers\.csv'
            $archive.Dispose()
            # -SendMail:$false wins over Mail.Enabled.
            [IO.File]::WriteAllText($cfg, $text.Replace("Attach = 'Zip' }", "Attach = 'Zip'; Enabled = `$true }"))
            $output = & pwsh -NoProfile -File $entry -DevelopmentMode -Range Last24Hours -NoCollect -SendMail:$false -ConfigPath $cfg 2>&1 | Out-String
            $output | Should -Not -Match 'Sending the report by e-mail'
            $server.Messages.Count | Should -Be 2
        } finally { $server.Dispose() }
    }
}

Describe 'Console characters' {
    It 'uses only characters of the classic console fonts outside the emoji style' {
        $safe = [Collections.Generic.HashSet[int]]::new()
        foreach ($c in (0x20..0x7E) + (0xA0..0xFF)) { [void]$safe.Add($c) }
        foreach ($c in '☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼⌂₧ƒ⌐░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αΓπΣστΦΘΩδ∞φε∩≡≥≤⌠⌡≈∙√ⁿ■'.ToCharArray()) { [void]$safe.Add([int]$c) }
        $module = Get-Module ExchangeLogReport
        $used = [Collections.Generic.List[string]]::new()
        $sets = & $module { (Get-ExlIconSet 'Symbols'), (Get-ExlIconSet 'Ascii'), (Get-ExlFrameSet 'Symbols' 'Lucida Console'), (Get-ExlFrameSet 'Ascii' $null) }
        foreach ($set in $sets) { foreach ($key in $set.Keys) { $used.Add("$key=$($set[$key])") } }
        $bad = @($used | Where-Object { $v = $_.Substring($_.IndexOf('=') + 1); @($v.ToCharArray() | Where-Object { -not $safe.Contains([int]$_) }).Count -gt 0 })
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Exact message counts' {
    BeforeAll {
        # Old algorithm: two scratch tables keyed by the managed EXL_REPORT_ID collation, one INSERT OR IGNORE per row.
        function Get-OldCounts($Folder, $Events) {
            $flags = [Reflection.BindingFlags]"NonPublic,Public,Instance"
            $scratchType = [ExchangeLogReport.ReportBuilder].Assembly.GetType('ExchangeLogReport.ReportScratch')
            $scratch = [Activator]::CreateInstance($scratchType, $flags, $null, @([string]$Folder, [long]64MB), $null)
            try {
                $run = { param($sql) $c = $scratchType.GetMethod('Command', $flags).Invoke($scratch, @($sql)); try { $c } catch { throw } }
                $c = & $run 'CREATE TABLE ms(server TEXT COLLATE EXL_REPORT_ID, identity TEXT COLLATE BINARY, PRIMARY KEY(server,identity)) WITHOUT ROWID; CREATE TABLE mh(server TEXT COLLATE EXL_REPORT_ID, hour INTEGER, identity TEXT COLLATE BINARY, PRIMARY KEY(server,hour,identity)) WITHOUT ROWID;'
                [void]$c.ExecuteNonQuery(); $c.Dispose()
                $a = & $run 'INSERT OR IGNORE INTO ms VALUES(@s,@i);'; $h = & $run 'INSERT OR IGNORE INTO mh VALUES(@s,@h,@i);'
                foreach ($e in $Events) {
                    foreach ($x in $a, $h) { $x.Parameters.Clear(); [void]$x.Parameters.AddWithValue('@s', $e[0]); [void]$x.Parameters.AddWithValue('@i', $e[2]) }
                    [void]$h.Parameters.AddWithValue('@h', [long]$e[1])
                    [void]$a.ExecuteNonQuery(); [void]$h.ExecuteNonQuery()
                }
                $a.Dispose(); $h.Dispose()
                $servers = @{}; $hours = @{}
                $r = & $run 'SELECT server,COUNT(*) FROM ms GROUP BY server;'; $rd = $r.ExecuteReader()
                while ($rd.Read()) { $servers[$rd.GetString(0).ToLowerInvariant()] = $rd.GetInt64(1) }; $rd.Dispose(); $r.Dispose()
                $r = & $run 'SELECT server,hour,COUNT(*) FROM mh GROUP BY server,hour;'; $rd = $r.ExecuteReader()
                while ($rd.Read()) { $hours["$($rd.GetString(0).ToLowerInvariant())|$($rd.GetInt64(1))"] = $rd.GetInt64(2) }; $rd.Dispose(); $r.Dispose()
                @{ Servers = $servers; Hours = $hours }
            } finally { $scratch.Dispose() }
        }
        function Get-NewCounts($Folder, $Events) {
            $flags = [Reflection.BindingFlags]"NonPublic,Public,Instance"
            $scratchType = [ExchangeLogReport.ReportBuilder].Assembly.GetType('ExchangeLogReport.ReportScratch')
            $scratch = [Activator]::CreateInstance($scratchType, $flags, $null, @([string]$Folder, [long]64MB), $null)
            try {
                $counts = [Activator]::CreateInstance([ExchangeLogReport.ReportBuilder].Assembly.GetType('ExchangeLogReport.ExactMessageCounts'), $flags, $null, @($scratch), $null)
                try {
                    foreach ($e in $Events) { $counts.Add($e[0], [long]$e[1], $e[2]) }
                    $servers = [Collections.Generic.List[object]]::new(); $hours = [Collections.Generic.List[object]]::new()
                    $counts.Read([Action[string, long]]{ param($s, $n) $servers.Add(@($s, $n)) }, [Action[string, long, long]]{ param($s, $h, $n) $hours.Add(@($s, $h, $n)) })
                } finally { $counts.Dispose() }
                @{ Servers = $servers; Hours = $hours }
            } finally { $scratch.Dispose() }
        }
    }
    It 'matches the old scratch-table semantics on a mixed-case, hour-crossing stream' {
        $folder = Join-Path $TestDrive 'counts'; [void](New-Item -ItemType Directory -Path $folder)
        # Rows are in time order (hour ascending), as the report query guarantees. Identities fall back to internal ids upstream.
        $events = @(
            @('Exch01', 10, '<a@x>'), @('EXCH01', 10, '<a@x>'), @('exch01', 10, '<A@x>'), @('Exch02', 10, '<a@x>'),
            @('EXCH01', 10, 'internal-1'), @('Exch01', 11, '<a@x>'), @('exch01', 11, '<a@x>'), @('EXCH02', 11, '<b@x>'),
            @('Edge', 11, 'internal-1'), @('EXCH01', 13, '<A@x>'), @('Exch02', 13, '<a@x>'), @('', 13, '<e@x>'), @('edge', 14, 'internal-1'))
        $old = Get-OldCounts $folder $events
        $new = Get-NewCounts $folder $events
        $new.Servers.Count | Should -Be $old.Servers.Count
        foreach ($s in $new.Servers) { $s[1] | Should -Be $old.Servers[$s[0].ToLowerInvariant()] }
        $new.Hours.Count | Should -Be $old.Hours.Count
        foreach ($h in $new.Hours) { $h[2] | Should -Be $old.Hours["$($h[0].ToLowerInvariant())|$($h[1])"] }
        # First spelling is kept, identities differing by case are distinct.
        ($new.Servers | Where-Object { $_[0] -ceq 'Exch01' })[1] | Should -Be 3
        @($new.Servers | Where-Object { $_[0] -ceq 'EXCH01' -or $_[0] -ceq 'exch01' }).Count | Should -Be 0
        (@($new.Hours | Where-Object { $_[0] -ceq 'Exch01' -and $_[1] -eq 10 }))[0][2] | Should -Be 3
        (@($new.Hours | Where-Object { $_[0] -ceq 'Exch01' -and $_[1] -eq 11 }))[0][2] | Should -Be 1
        (@($new.Servers | Where-Object { $_[0] -ceq '' }))[0][1] | Should -Be 1
        @(Get-ChildItem $folder -Force).Count | Should -Be 0
    }
    It 'rejects events that go back in time' {
        $folder = Join-Path $TestDrive 'counts-order'; [void](New-Item -ItemType Directory -Path $folder)
        { Get-NewCounts $folder @(@('S', 5, 'a'), @('S', 4, 'b')) } | Should -Throw '*time order*'
    }
}
