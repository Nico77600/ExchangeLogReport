#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Exchange Log Report - automated tests (Pester 5 or later).
    Author  : Nicolas Fabert
    Version : 2.0.0

    Run:  Invoke-Pester -Path .\tests\ExchangeLogReport.Tests.ps1 -Output Detailed

    No Exchange server is needed: the tests write log files with the exact headers and
    line shapes of Exchange Server SE (HttpProxy, IIS front end and back end, MAPI over HTTP
    back end, IMAP4 front end and back end, SMTP receive/send protocol logs, message
    tracking), including the noise seen in a real lab: health mailboxes, Managed Availability
    probes, anonymous 401 challenges, Azure load balancer SMTP and IMAP probes and shadow
    redundancy events.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Root = Join-Path $script:RepoRoot 'package'
    Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Root
    $script:Now = [DateTimeOffset]::UtcNow
    $script:Base = $script:Now.AddHours(-3)

    function T([double]$Minutes, [switch]$W3C) {
        $t = $script:Base.AddMinutes($Minutes).UtcDateTime
        if ($W3C) { return $t.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
        return $t.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
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
        $p = { param($min, $proto, $user, $status, $agent, $ip = '10.1.1.10', $anchor = '', $stem = '/mapi/emsmdb/', $id = [guid]::NewGuid().ToString(), $err = '')
            ProxyLine @{ DateTime = (T $min); RequestId = $id; MajorVersion = 15; MinorVersion = 2; Protocol = $proto; UrlHost = 'mail.contoso.test'; UrlStem = $stem
                AuthenticationType = 'Negotiate'; IsAuthenticated = [bool]$user; AuthenticatedUser = $user; AnchorMailbox = $anchor; UserAgent = $agent; ClientIpAddress = $ip
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
        Write-Log (Join-Path $ex 'Logging\HttpProxy\PowerShell\HttpProxy_2026100108-1.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $p 8 'PowerShell' 'CONTOSO\labadmin' 200 'Microsoft WinRM Client' 'fe80::90a2:c143:3f63:5f44%45' '' '/powershell')
        )
        # ---- MAPI over HTTP of Outlook (dave): front end, then the back-end log of the same requests -------------
        $mbx = '6f1c2a3b-1111-4222-8333-944455566677'; $ci = '{A1B2C3D4-0000-4000-8000-0000000000AA}'
        $outlook = 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928; Pro)'
        $script:MapiIds = @{}
        $mapi = { param($min, $rt, $n, $total = 35)
            $id = [guid]::NewGuid().ToString(); $script:MapiIds["$rt$n"] = $id
            ProxyLine @{ DateTime = (T $min); RequestId = $id; ClientRequestId = "R:{9F00AA11-2222-4333-8444-555566667777}:$n;RT:$rt;CI:$($ci):1;CID:<null>"; Protocol = 'Mapi'
                UrlStem = '/mapi/emsmdb/'; AuthenticationType = 'Negotiate'; IsAuthenticated = $true; AuthenticatedUser = 'CONTOSO\dave'; AnchorMailbox = "MailboxGuid~$mbx"
                UserAgent = $outlook; ClientIpAddress = '10.1.1.40'; ServerHostName = 'EXCH01'; HttpStatus = 200; BackEndStatus = 200; Method = 'POST'
                TargetServer = 'exch01.contoso.test'; RequestBytes = 300; ResponseBytes = 900; TotalRequestTime = $total; UrlQuery = "?MailboxId=$mbx@contoso.test" } }
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Mapi\HttpProxy_2026100108-2.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $mapi 10 'Connect' 1), (& $mapi 10.1 'Execute' 2), (& $mapi 10.2 'Execute' 3), (& $mapi 11 'NotificationWait' 4 60000), (& $mapi 12 'Execute' 5), (& $mapi 13 'Disconnect' 6)
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
        $ews = { param($min, $user, $total)
            ProxyLine @{ DateTime = (T $min); RequestId = [guid]::NewGuid().ToString(); Protocol = 'Ews'; UrlStem = '/EWS/Exchange.asmx'; AuthenticationType = 'Negotiate'
                IsAuthenticated = $true; AuthenticatedUser = $user; UserAgent = 'MacOutlook/16.89.24091630'; ClientIpAddress = '10.1.1.80'; ServerHostName = 'EXCH01'
                HttpStatus = 200; BackEndStatus = 200; Method = 'POST'; TargetServer = 'exch01.contoso.test'; TotalRequestTime = $total } }
        Write-Log (Join-Path $ex 'Logging\HttpProxy\Ews\HttpProxy_2026100108-2.LOG') @(
            "#Fields: $script:ProxyFields", $script:ProxyFields
            (& $ews 17 'CONTOSO\grace' 8000), (& $ews 18 'CONTOSO\frank' 50)
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

Describe 'Configuration' {
    It 'loads the delivered configuration with the default retention (60 days, details and logs 14 days)' {
        $s = Import-ExlConfiguration -Path (Join-Path $script:Root 'config\ExchangeLogReport.config.psd1') -Root $script:Root
        $s.Storage.RetentionDays | Should -Be 60
        $s.Storage.DetailRetentionDays | Should -Be 14
        $s.Logging.RetentionDays | Should -Be 14
        $s.Servers[0].HttpProxyPath | Should -Be '\\EXCH01\c$\Program Files\Microsoft\Exchange Server\V15\Logging\HttpProxy'
    }
    It 'reports every invalid value at once' {
        $path = Join-Path $TestDrive 'bad.psd1'
        (Get-Content $script:ConfigPath -Raw).Replace('DetailRetentionDays = 14', 'DetailRetentionDays = 90').Replace("DefaultType           = 'Usage'", "DefaultType           = 'Full'") | Set-Content -LiteralPath $path
        { Import-ExlConfiguration -Path $path -Root $script:Root } | Should -Throw -ExpectedMessage '*DetailRetentionDays*DefaultType*'
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
        # Handed over to the organization (SENDEXTERNAL on an Edge): relayed.
        (Import-Csv (Join-Path $r.Folder 'ExchangeLogs-Messages.csv') -Delimiter ';' | Where-Object 'Message ID' -eq '<edge-001@fabrikam.example>').Status | Should -Be 'Relayed'
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
    It 'keeps operations and clients for the usage views' {
        (Query $script:Settings "SELECT SUM(requests) FROM access_action WHERE protocol='Eas' AND action='FolderSync'")[0][0] | Should -Be 3
        (Query $script:Settings "SELECT device_type, requests FROM access_client WHERE user='contoso\erin' AND device_id='ERINPHONE1'")[0] | Should -Be @('iPhone', 5)
    }
    It 'merges two sessions when a request fills the gap between them' {
        $file = Get-ChildItem (Join-Path $script:Dir 'logs-src') -Recurse -Filter 'HttpProxy_2026100108-2.LOG' | Where-Object { $_.Directory.Name -eq 'Ews' }
        $line = { param($min) ProxyLine @{ DateTime = (T $min); RequestId = [guid]::NewGuid().ToString(); Protocol = 'Ews'; UrlStem = '/EWS/Exchange.asmx'; AuthenticationType = 'Negotiate'
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
        try { $store.Exec("DROP TABLE access_client; DROP TABLE client_session; DROP TABLE session_step; DROP TABLE access_action; UPDATE metadata SET value='1' WHERE key='schema_version';") } finally { $store.Dispose() }
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
        ([regex]::Matches($html, 'application/x-exl-chunk')).Count | Should -BeGreaterThan 3
        $html | Should -Match '"messages":\{"rows":3'
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
    It 'Status on a new installation confirms the configuration and creates no database' {
        $dir = Join-Path $TestDrive 'fresh'
        $cfg = New-TestConfig $dir
        $output = & pwsh -NoProfile -File (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -Mode Status -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Ready for the first collection'
        $output | Should -Not -Match 'ignored with'
        Test-Path -LiteralPath (Join-Path $dir 'data') | Should -BeFalse
    }
    It 'Report with -Collect collects, reports and returns 2 when a server cannot be read' {
        $dir = Join-Path $TestDrive 'script'
        $cfg = New-TestConfig $dir
        $start = $script:Base.AddHours(-1); $end = $script:Base.AddHours(2)
        # -Start / -End alone: custom period (-Range Custom implied), never the default range.
        $output = & pwsh -NoProfile -File (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -Start $start.ToString('o') -End $end.ToString('o') -ReportType Detailed -Collect -ConfigPath $cfg 2>&1 | Out-String
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
        $output = & pwsh -NoProfile -File $entry -Mode Status -Range Custom -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -User alice -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match '-Range, -Start, -End ignored with -Mode Status: -Mode Status describes the whole database'
        $output | Should -Match '-User ignored with -Mode Status'
        # A period that contradicts -Range: error, nothing is run.
        $output = & pwsh -NoProfile -File $entry -Range Last7Days -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -ConfigPath $cfg 2>&1 | Out-String
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
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'No collection in the database yet: run .*-Mode Collect.* first'
        $output | Should -Not -Match 'Reading the new log lines'
        Test-Path -LiteralPath (Join-Path $script:AgeDir 'data') | Should -BeFalse
    }
    It 'reads the database without collecting after a recent collection' {
        $null = & pwsh -NoProfile -File $script:AgeEntry -Mode Collect -ConfigPath $script:AgeCfg 2>&1
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Data\s+collected until .* ago\)'
        $output | Should -Not -Match 'Reading the new log lines'
        $output | Should -Match 'Report ready'
    }
    It 'reads the new log lines first when the last collection is older than MaxDataAgeMinutes' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Set-LastCollection ($now - 3 * 3600000)
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match 'more than 90 min \(Report.MaxDataAgeMinutes\): the new log lines are read first'
        $output | Should -Match 'Reading the new log lines'
        $output | Should -Match 'Report ready'
    }
    It 'does not collect for a period that ends before the last collection, nor with -NoCollect or MaxDataAgeMinutes = 0' {
        $now = [DateTimeOffset]::UtcNow
        Set-LastCollection ($now.AddHours(-3).ToUnixTimeMilliseconds())
        $output = & pwsh -NoProfile -File $script:AgeEntry -Start $now.AddHours(-6).ToString('o') -End $now.AddHours(-4).ToString('o') -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match 'the period is complete'
        $output | Should -Not -Match 'Reading the new log lines'
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -NoCollect -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match '-NoCollect'
        $output | Should -Not -Match 'Reading the new log lines'
        $never = Join-Path $script:AgeDir 'never.config.psd1'
        [IO.File]::WriteAllText($never, [IO.File]::ReadAllText($script:AgeCfg).Replace('MaxDataAgeMinutes     = 90', 'MaxDataAgeMinutes     = 0'), [Text.UTF8Encoding]::new($true))
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -ConfigPath $never 2>&1 | Out-String
        $output | Should -Match 'add -Collect to read the new log lines first'
        $output | Should -Not -Match 'Reading the new log lines'
    }
    It 'collects with -Collect whatever the age, refuses -Collect with -NoCollect, and never waits for a running collection' {
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -Collect -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $output | Should -Match '-Collect: the new log lines are read first'
        $output | Should -Match 'Reading the new log lines'
        $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -Collect -NoCollect -ConfigPath $script:AgeCfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match '-Collect and -NoCollect cannot be used together'
        # Old data and a collection running (its lock is held): the report uses the data as it is.
        Set-LastCollection ([DateTimeOffset]::UtcNow.AddHours(-3).ToUnixTimeMilliseconds())
        $held = [IO.FileStream]::new($script:AgeSettings.Storage.DatabasePath + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            $output = & pwsh -NoProfile -File $script:AgeEntry -Range Last7Days -ConfigPath $script:AgeCfg 2>&1 | Out-String
        }
        finally { $held.Dispose() }
        $output | Should -Match 'a collection is running .*: the report uses the data already collected'
        $output | Should -Not -Match 'Reading the new log lines'
        $output | Should -Match 'Report ready'
    }
}
Describe 'Parallel collection' {
    It 'gives the same data with one thread, with several threads, one file per server, and the client sessions evicted from memory' {
        $counts = foreach ($run in @(@{ Threads = 1; Evict = 20000; PerServer = 4 }, @{ Threads = 6; Evict = 20000; PerServer = 4 }, @{ Threads = 6; Evict = 1; PerServer = 1 })) {
            $threads = $run.Threads
            $dir = Join-Path $TestDrive "parallel$threads-$($run.Evict)"
            $s = Import-ExlConfiguration -Path (New-TestConfig $dir @{ 'PopImap         = $false' = 'PopImap         = $true'; 'Parallelism            = 0' = "Parallelism            = $threads"; 'MaxFilesPerServer      = 4' = "MaxFilesPerServer      = $($run.PerServer)" }) -Root $script:Root
            $s.Collection.Parallelism | Should -Be $threads
            $s.Collection.MaxFilesPerServer | Should -Be $run.PerServer
            [ExchangeLogReport.Collector]::EvictAboveKeys = $run.Evict
            try { $r = Invoke-TestCollection $s } finally { [ExchangeLogReport.Collector]::EvictAboveKeys = 20000 }
            $r.Statistics | Should -Match "$threads parse thread"
            if ($run.PerServer -eq 1) { $r.Statistics | Should -Match 'at most 1 file\(s\) of one server' }
            (Query $s "SELECT (SELECT COUNT(*) FROM access_usage), (SELECT SUM(requests) FROM access_usage), (SELECT COUNT(*) FROM access_event), (SELECT COUNT(*) FROM access_event WHERE recovered_ms IS NOT NULL),
                (SELECT COUNT(*) FROM client_session), (SELECT SUM(requests) FROM client_session), (SELECT COUNT(*) FROM smtp_transaction), (SELECT COUNT(*) FROM message_event),
                (SELECT COUNT(*) FROM access_client), (SELECT COUNT(*) FROM access_action), (SELECT SUM(lines) FROM noise)")[0] -join ','
        }
        $counts[0] | Should -Be $counts[1]
        $counts[0] | Should -Be $counts[2]
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
            $content = New-Content 'Rapport Exchange – septembre'
            $a = [ExchangeLogReport.MailAttachment]::new(); $a.Name = 'rapport été.zip'; $a.ContentType = 'application/zip'; $a.Content = [byte[]](1..200)
            $content.Attachments.Add($a)
            $r = [ExchangeLogReport.SmtpSender]::Send((New-MailSettings $server.Port), $content)
            $r.Sent | Should -BeTrue -Because $r.Error
            $r.AuthenticationUsed | Should -Be 'Anonymous'
            $r.Tls | Should -BeNullOrEmpty
            $server.Recipients | Should -Be @('team@contoso.test', 'boss@contoso.test')
            $message = $server.Messages[0]
            $message | Should -Match 'Subject: =\?utf-8\?B\?'
            $message | Should -Match 'filename\*=utf-8''''rapport%20%C3%A9t%C3%A9\.zip'
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
    It 'sends the report with its summary (-SendMail), and tests the settings (-Mode MailTest)' {
        $server = [ElrTest.FakeSmtp]::new()
        try {
            $dir = Join-Path $TestDrive 'mailreport'
            $cfg = New-TestConfig $dir
            $text = Set-MailBlock ([IO.File]::ReadAllText($cfg)) "SmtpServer = 'localhost'; Port = $($server.Port); Encryption = 'None'; From = 'elr@contoso.test'; To = @('team@contoso.test'); Attach = 'Zip'"
            [IO.File]::WriteAllText($cfg, $text)
            $entry = Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'
            $output = & pwsh -NoProfile -File $entry -Mode MailTest -ConfigPath $cfg 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
            $output | Should -Match 'Test message sent'
            $output | Should -Match 'S: 250 2.6.0'
            $output = & pwsh -NoProfile -File $entry -Range Last24Hours -ReportType Detailed -Collect -SendMail -ConfigPath $cfg 2>&1 | Out-String
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
            $output = & pwsh -NoProfile -File $entry -Range Last24Hours -NoCollect -SendMail:$false -ConfigPath $cfg 2>&1 | Out-String
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
