# A hidden headless Microsoft Edge driven through the DevTools protocol (CDP), for the browser-level tests and the captures of the portal.
# Dot-source this file. Never a visible window: --headless=new and Start-Process -WindowStyle Hidden; a private profile folder per session,
# deleted at Stop-ExlEdge.

function Get-ExlEdgePath {
    @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Start-ExlEdge {
    param([Parameter(Mandatory)][string]$WorkFolder, [int]$Width = 1600, [int]$Height = 1100)
    $edge = Get-ExlEdgePath
    if (-not $edge) { throw 'Microsoft Edge is not installed.' }
    $profileFolder = Join-Path $WorkFolder ('edge-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($profileFolder)
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $probe.Start(); $port = $probe.LocalEndpoint.Port } finally { $probe.Stop() }
    $arguments = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
        '--allow-file-access-from-files', "--user-data-dir=`"$profileFolder`"", "--window-size=$Width,$Height", '--force-device-scale-factor=1',
        "--remote-debugging-port=$port", 'about:blank')
    $process = Start-Process -FilePath $edge -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $target = $null
    for ($i = 0; $i -lt 100 -and -not $target; $i++) {
        try { $target = (Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 2) | Where-Object type -EQ 'page' | Select-Object -First 1 }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $target) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; throw 'The DevTools endpoint of Edge was not reached.' }
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.KeepAliveInterval = [TimeSpan]::Zero
    [void]$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $session = [pscustomobject]@{ Process = $process; Profile = $profileFolder; Socket = $socket; Id = 0; Events = [Collections.Generic.List[object]]::new(); Width = $Width; Height = $Height }
    [void](Invoke-ExlCdp $session 'Emulation.setDeviceMetricsOverride' @{ width = $Width; height = $Height; deviceScaleFactor = 1; mobile = $false })
    [void](Invoke-ExlCdp $session 'Page.enable')
    [void](Invoke-ExlCdp $session 'Network.enable')
    return $session
}

# Sends one command and returns its result; the events received meanwhile are kept in $Session.Events.
function Invoke-ExlCdp {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Method, [hashtable]$Params = @{}, [int]$TimeoutSeconds = 60)
    $Session.Id++
    $id = $Session.Id
    $json = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    [void]$Session.Socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(1048576)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "CDP $Method did not answer within $TimeoutSeconds s." }
        $stream = [IO.MemoryStream]::new()
        do {
            $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
            try { $received = $Session.Socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cancel.Token).GetAwaiter().GetResult() } finally { $cancel.Dispose() }
            $stream.Write($buffer, 0, $received.Count)
        } while (-not $received.EndOfMessage)
        # Dates stay the strings the page returned.
        $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json -Depth 50 -DateKind String
        if ($message.PSObject.Properties['id'] -and $message.id -eq $id) {
            if ($message.PSObject.Properties['error']) { throw "CDP $Method : $($message.error.message)" }
            return $message.result
        }
        if ($message.PSObject.Properties['method']) { $Session.Events.Add($message) }
    }
}

# Evaluates a JavaScript expression in the page (a promise is awaited) and returns its value; a page exception is thrown.
function Invoke-ExlJs {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Expression, [int]$TimeoutSeconds = 60)
    $out = Invoke-ExlCdp $Session 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true; awaitPromise = $true } -TimeoutSeconds $TimeoutSeconds
    if ($out.PSObject.Properties['exceptionDetails']) {
        $detail = $out.exceptionDetails
        $text = if ($detail.PSObject.Properties['exception'] -and $detail.exception.PSObject.Properties['description']) { $detail.exception.description } else { $detail.text }
        throw "Page exception: $text"
    }
    if ($out.result.PSObject.Properties['value']) { return $out.result.value }
    return $null
}

# Waits until a JavaScript expression is truthy (polled every 200 ms); false at the timeout.
function Wait-ExlJs {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Expression, [int]$TimeoutSeconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { if ((Invoke-ExlJs $Session "!!($Expression)") -eq $true) { return $true } } catch { }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Open-ExlPage {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Url)
    [void](Invoke-ExlCdp $Session 'Page.navigate' @{ url = $Url })
}

# The addresses of the requests the page sent since the session started (or since the last Clear-ExlRequests).
function Get-ExlRequests {
    param([Parameter(Mandatory)]$Session)
    [void](Invoke-ExlCdp $Session 'Runtime.evaluate' @{ expression = '0'; returnByValue = $true })
    @($Session.Events | Where-Object { $_.method -eq 'Network.requestWillBeSent' } | ForEach-Object { $_.params.request.url })
}
function Clear-ExlRequests { param([Parameter(Mandatory)]$Session) $Session.Events.Clear() }

function Save-ExlScreenshot {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Path, [switch]$FullPage)
    $params = @{ format = 'png' }
    if ($FullPage) {
        $height = [int](Invoke-ExlJs $Session 'Math.ceil(document.documentElement.scrollHeight)')
        $params.clip = @{ x = 0; y = 0; width = $Session.Width; height = [Math]::Max($Session.Height, $height); scale = 1 }
        $params.captureBeyondViewport = $true
    }
    $shot = Invoke-ExlCdp $Session 'Page.captureScreenshot' $params
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($shot.data))
}

function Stop-ExlEdge {
    param($Session)
    if (-not $Session) { return }
    try { [void](Invoke-ExlCdp $Session 'Browser.close' -TimeoutSeconds 5) } catch { }
    try { $Session.Socket.Dispose() } catch { }
    if (-not $Session.Process.HasExited) { [void]$Session.Process.WaitForExit(5000) }
    if (-not $Session.Process.HasExited) { Stop-Process -Id $Session.Process.Id -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$($Session.Profile)*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $Session.Profile); $i++) {
        try { Remove-Item -LiteralPath $Session.Profile -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250 }
    }
}
