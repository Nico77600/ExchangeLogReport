#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Exchange Log Report - automated tests (Pester 5 or later).
    Author  : Nicolas Fabert
    Version : 1.3.1

    Run:  Invoke-Pester -Path .\tests\ExchangeLogReport.Tests.ps1 -Output Detailed

    No Exchange server is needed: the tests write log files with the exact headers and
    line shapes of Exchange Server SE (HttpProxy, IIS front end and back end, MAPI over HTTP
    back end, IMAP4 front end and back end, SMTP receive/send protocol logs, message
    tracking), including the noise seen in a real lab: health mailboxes, Managed Availability
    probes, anonymous 401 challenges, Azure load balancer SMTP and IMAP probes and shadow
    redundancy events.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
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
        $text = $text.Replace("'.\data\ExchangeLogReport.sqlite'", "'$Directory\data\test.sqlite'").Replace("Path          = '.\logs'", "Path          = '$Directory\toollogs'").Replace("OutputPath            = '.\reports'", "OutputPath            = '$Directory\reports'")
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
        (Query $script:Settings "SELECT transcript FROM smtp_transaction WHERE direction='Receive' AND status='Accepted'")[0][0] | Should -Match 'BDAT 2048 LAST'
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
        $state = (Query $s "SELECT offset, size FROM source_file WHERE kind='SmtpReceive'")[0]
        $state[0] | Should -BeLessThan $state[1]
        [IO.File]::AppendAllText($file.FullName, "$now,$c,08DF0000000000FF,2,10.0.0.1:25,10.1.1.60:5000,<,RCPT TO:<bob@contoso.test>,`r`n$now,$c,08DF0000000000FF,3,10.0.0.1:25,10.1.1.60:5000,<,DATA,`r`n$now,$c,08DF0000000000FF,4,10.0.0.1:25,10.1.1.60:5000,>,""250 2.6.0 <msg-009@contoso.test> [InternalId=9, Hostname=EXCH01] Queued mail for delivery"",`r`n$now,$c,08DF0000000000FF,5,10.0.0.1:25,10.1.1.60:5000,-,,Local`r`n")
        [void](Invoke-TestCollection $s)
        (Query $s "SELECT status, message_id FROM smtp_transaction WHERE mail_from='eve@contoso.test'")[0] | Should -Be @('Accepted', '<msg-009@contoso.test>')
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
        (Query $s "SELECT value FROM metadata WHERE key='schema_version'")[0][0] | Should -Be '2'
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

Describe 'Entry script' {
    It 'Status on a new installation confirms the configuration and creates no database' {
        $dir = Join-Path $TestDrive 'fresh'
        $cfg = New-TestConfig $dir
        $output = & pwsh -NoProfile -File (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -Mode Status -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Ready for the first collection'
        Test-Path -LiteralPath (Join-Path $dir 'data') | Should -BeFalse
    }
    It 'Report collects, reports and returns 2 when a server cannot be read' {
        $dir = Join-Path $TestDrive 'script'
        $cfg = New-TestConfig $dir
        $start = $script:Base.AddHours(-1).ToString('o'); $end = $script:Base.AddHours(2).ToString('o')
        $output = & pwsh -NoProfile -File (Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1') -Range Custom -Start $start -End $end -ReportType Detailed -ConfigPath $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $output | Should -Match 'EXCH02'
        $output | Should -Match 'Report ready'
        @(Get-ChildItem (Join-Path $dir 'reports') -Recurse -Filter '*.html').Count | Should -Be 1
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
