#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

# The portal page in a real browser: Serve on a synthetic store collected from generated logs, the page opened in a hidden headless Microsoft
# Edge driven through the DevTools protocol (tests\support\Cdp.ps1). Tagged Browser: skipped where Edge is not installed.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'support\Cdp.ps1')
    $script:NoEdge = -not (Get-ExlEdgePath)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'support\Cdp.ps1')
    $script:Root = Join-Path (Split-Path $PSScriptRoot -Parent) 'package'
    $script:Work = Join-Path $script:Root ('bin\t\p' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:Edge = $null; $script:Portal = $null
    if (-not (Get-ExlEdgePath)) { return }
    # A synthetic store: three servers, two days of generated logs, one collection.
    $demo = & (Join-Path $PSScriptRoot 'New-DemoDatabase.ps1') -Destination (Join-Path $script:Work 'demo') | ConvertFrom-Json
    $script:Database = $demo.Database
    $script:Settings = Import-ExlConfiguration -Path $demo.Config -Root $script:Root
    # The generator writes Negotiate and Basic only: four EWS requests of one real user of DEMO01 signed in with OAuth are appended to its newest EWS
    # log (the fields of its own header, the times after its last line), then the store collects them as the script does.
    $model = $null
    # The real users of EWS that the store already counts (noise such as health mailboxes is never kept).
    $known = Open-ExlStore -Settings $script:Settings -ReadOnly
    try { $real = @($known.Query("SELECT DISTINCT user FROM access_client WHERE protocol='Ews';", $null).Rows | ForEach-Object { [string]$_[0] }) } finally { $known.Dispose() }
    foreach ($ews in @(Get-ChildItem -LiteralPath (Join-Path $script:Work 'demo\synthetic-logs\DEMO01') -Recurse -Filter 'HttpProxy_*.LOG' | Where-Object { $_.Directory.Name -eq 'Ews' } | Sort-Object Name -Descending)) {
        $text = [IO.File]::ReadAllText($ews.FullName)
        $fields = (@($text -split "`r?`n" | Where-Object { $_.StartsWith('#Fields: ') })[-1]).Substring(9).Split(',')
        $rows = @($text -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') } | ConvertFrom-Csv -Header $fields | Where-Object { $_.DateTime -ne 'DateTime' })
        $model = @($rows | Where-Object { $_.AuthenticatedUser -and $_.HttpStatus -eq '200' -and $real -contains $_.AuthenticatedUser.Trim().ToLowerInvariant() } | Select-Object -Last 1)
        if ($model.Count) { $model = $model[0]; break }
    }
    $at = [DateTimeOffset]::Parse($rows[-1].DateTime, [Globalization.CultureInfo]::InvariantCulture)
    $script:OAuthUser = $model.AuthenticatedUser.Trim().ToLowerInvariant()
    $lines = foreach ($k in 1..4) {
        $v = @{}; foreach ($name in $fields) { $v[$name] = $model.$name }
        $v.DateTime = $at.AddSeconds($k).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $v.RequestId = [guid]::NewGuid().ToString(); $v.AuthenticationType = 'OAuth'; $v.IsAuthenticated = 'True'
        (@($fields | ForEach-Object { $x = [string]$v[$_]; if ($x -match '[,"]') { '"' + $x.Replace('"', '""') + '"' } else { $x } })) -join ','
    }
    [IO.File]::AppendAllText($ews.FullName, $(if ($text.EndsWith("`n")) { '' } else { "`r`n" }) + ($lines -join "`r`n") + "`r`n")
    $collect = Open-ExlStore -Settings $script:Settings
    try {
        $run = $collect.StartRun('Collect', 'SYNTHETIC', 'SYNTHETIC', '3.0.0')
        $collection = Invoke-ExlCollection -Store $collect -Settings $script:Settings -RunId $run
        $collect.EndRun($run, 'Completed', $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
    } finally { $collect.Dispose() }
    $script:OAuthLines = $collection.Lines
    # Two requests of an account Exchange logged by its SID, that no line names (unresolved), appended and collected the same way. Their type is the
    # model's (not a token): the OAuth figures of the tests below stay those of the four lines above.
    $script:SidUser = 's-1-5-21-9-9-9-4242'
    $sidLines = foreach ($k in 5..6) {
        $v = @{}; foreach ($name in $fields) { $v[$name] = $model.$name }
        $v.DateTime = $at.AddSeconds($k).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        $v.RequestId = [guid]::NewGuid().ToString(); $v.IsAuthenticated = 'True'; $v.AuthenticatedUser = $script:SidUser.ToUpperInvariant(); $v.ClientIpAddress = '10.9.9.42'
        (@($fields | ForEach-Object { $x = [string]$v[$_]; if ($x -match '[,"]') { '"' + $x.Replace('"', '""') + '"' } else { $x } })) -join ','
    }
    [IO.File]::AppendAllText($ews.FullName, ($sidLines -join "`r`n") + "`r`n")
    # Two messages a Send connector handed to a mail server outside the organization, appended to the newest message tracking log of DEMO01 (the
    # fields of its own header): one sent to external only, one delivered here too. The sender and the delivered recipient are of a domain of the store.
    $tracking = @(Get-ChildItem -LiteralPath (Join-Path $script:Work 'demo\synthetic-logs\DEMO01') -Recurse -Filter 'MSGTRK*.LOG' | Where-Object Name -NotLike 'MSGTRKM*' | Sort-Object Name -Descending)[0]
    $trackingText = [IO.File]::ReadAllText($tracking.FullName)
    $trackingFields = (@($trackingText -split "`r?`n" | Where-Object { $_.StartsWith('#Fields: ') })[-1]).Substring(9).Split(',')
    $known = Open-ExlStore -Settings $script:Settings -ReadOnly
    try { $ours = ([string]$known.Query("SELECT recipients FROM message_event WHERE event_id='DELIVER' AND recipients LIKE '%@%' ORDER BY id LIMIT 1;", $null).Rows[0][0]).Split(';')[0] } finally { $known.Dispose() }
    $trackingLine = { param([int]$Second, [string]$Event, [string]$Id, [string]$Recipient, [string]$Status, [string]$Source, [string]$Connector = '', [string]$Peer = '')
        $v = @{ 'date-time' = $at.AddSeconds($Second).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture); 'event-id' = $Event
            'message-id' = $Id; 'recipient-address' = $Recipient; 'recipient-status' = $Status; source = $Source; 'connector-id' = $Connector; 'server-hostname' = $Peer; 'server-ip' = $Peer
            'sender-address' = $ours; 'return-path' = $ours; directionality = 'Originating'; 'message-subject' = 'Order'; 'internal-message-id' = '4242'; 'recipient-count' = '1'
            'total-bytes' = '2048'; 'log-id' = [guid]::NewGuid().ToString() }
        (@($trackingFields | ForEach-Object { [string]$v[$_] })) -join ',' }
    $postfix = 'To Internet via Postfix'
    $externalLines = @(
        (& $trackingLine 10 'SENDEXTERNAL' '<external-1@demo.invalid>' 'partner@fabrikam.example' '250 2.1.5 Ok' 'SMTP' $postfix '203.0.113.5')
        (& $trackingLine 11 'DELIVER' '<external-2@demo.invalid>' $ours '250 2.0.0 Delivered' 'STOREDRIVER')
        (& $trackingLine 12 'SENDEXTERNAL' '<external-2@demo.invalid>' 'partner@fabrikam.example' '250 2.1.5 Ok' 'SMTP' $postfix '203.0.113.5'))
    [IO.File]::AppendAllText($tracking.FullName, $(if ($trackingText.EndsWith("`n")) { '' } else { "`r`n" }) + ($externalLines -join "`r`n") + "`r`n")
    $collect = Open-ExlStore -Settings $script:Settings
    try {
        $run = $collect.StartRun('Collect', 'SYNTHETIC', 'SYNTHETIC', '3.0.0')
        $collection = Invoke-ExlCollection -Store $collect -Settings $script:Settings -RunId $run
        $collect.EndRun($run, 'Completed', $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
    } finally { $collect.Dispose() }
    # The three days of the report time zone that end today: every generated line (the default selection, today, may hold one hour of logs only).
    $script:AuthDays = 'day=' + [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $script:Settings.Zone).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + '&days=3'
    $script:SourceHash = (Get-FileHash -LiteralPath $script:Database).Hash
    $o = [ExchangeLogReport.ServeOptions]::new()
    $o.DatabasePath = $script:Database; $o.WebRoot = Join-Path $script:Root 'templates'; $o.Port = 0; $o.NoBrowser = $true
    $o.ReadyFile = Join-Path $script:Work 'ready.json'; $o.ReadyFileWithToken = $true; $o.RequestTimeoutSeconds = 30; $o.AggregateTimeoutSeconds = 60
    $o.Zone = $script:Settings.Zone
    $task = [ExchangeLogReport.ServeHost]::RunAsync($o, [Threading.CancellationToken]::None)
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $o.ReadyFile)) {
        if ($task.IsCompleted) { $task.GetAwaiter().GetResult(); throw 'Serve stopped before it was ready.' }
        if ($wait.Elapsed.TotalSeconds -gt 30) { throw 'Serve was not ready within 30 s.' }
        Start-Sleep -Milliseconds 50
    }
    $ready = Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
    $script:Portal = [pscustomobject]@{ Task = $task; Url = $ready.url.TrimEnd('/'); Token = $ready.token }
    $script:Edge = Start-ExlEdge -WorkFolder $script:Work
    # The page of the portal, opened by its launch address.
    Open-ExlPage $script:Edge "$($script:Portal.Url)/#token=$($script:Portal.Token)"
    $script:Loaded = Wait-ExlJs $script:Edge 'window.__exlStats && __exlStats.seq > 0' 120
    # The mode of the overview hook of the tests below, kept in the session storage of the portal's origin (read by the hook at each load).
    function Set-OverviewMode([string]$Mode) {
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions"
        Wait-ExlJs $script:Edge 'location.protocol === "http:" && document.getElementById("day-bar")' 120 | Should -BeTrue -Because 'the portal page is open'
        [void](Invoke-ExlJs $script:Edge "(() => { if ('$Mode') sessionStorage.setItem('exl-test-overview', '$Mode'); else sessionStorage.removeItem('exl-test-overview'); return true; })()")
    }
}

AfterAll {
    Stop-ExlEdge $script:Edge
    if ($script:Portal -and -not $script:Portal.Task.IsCompleted) {
        try { Invoke-WebRequest -Uri "$($script:Portal.Url)/api/shutdown" -Method Post -Headers @{ 'X-Portal-Token' = $script:Portal.Token } -SkipHttpErrorCheck | Out-Null } catch { }
        [void]$script:Portal.Task.Wait(15000)
    }
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'The portal page in a browser' -Tag Browser -Skip:$script:NoEdge {
    It 'opens on the client sessions tab, with the day bar above the overview and the tabs' {
        $script:Loaded | Should -BeTrue -Because 'the client sessions tab draws its rows'
        # The address follows the state of the page a moment after a pass.
        Wait-ExlJs $script:Edge '/tab=sessions/.test(location.hash)' 30 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(() => {
  const top = id => document.getElementById(id).getBoundingClientRect().top;
  return { tab: document.querySelector("#tabs button.active").firstChild.textContent, rows: document.querySelectorAll("#spacer .grid-row").length,
    shown: __exlStats.shown, bar: !!document.getElementById("day-bar"), aboveTabs: top("day-bar") < top("tabs"), aboveChart: top("day-bar") < top("activity-block"),
    barVisible: top("day-bar") < innerHeight, buttons: [...document.querySelectorAll("#day-bar button")].map(b => b.textContent),
    hero: [...document.querySelectorAll(".hero-actions button")].map(b => b.textContent), hash: location.hash, overlay: document.getElementById("loading").hidden };
})()
'@
        $state.tab | Should -BeExactly 'Client sessions'
        $state.rows | Should -BeGreaterThan 0
        $state.shown | Should -BeGreaterThan 0
        $state.bar | Should -BeTrue
        $state.aboveTabs | Should -BeTrue
        $state.aboveChart | Should -BeTrue
        $state.barVisible | Should -BeTrue
        foreach ($label in '1 day', '3 days', '7 days', 'Previous day', 'Next day', 'Apply') { $state.buttons | Should -Contain $label }
        $state.hero | Should -Contain 'Stop portal'
        @($state.hero | Where-Object { $_ -match '^(Dark|Light) theme$' }).Count | Should -Be 1
        $state.hash | Should -Not -Match 'token'
        $state.hash | Should -Match 'tab=sessions'
        $state.overlay | Should -BeTrue
    }

    It 'filters the rows with the search of the report' {
        # The three days that hold every generated line, at any hour: the default selection (today) may hold the sessions of one user only.
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions&$script:AuthDays"
        Wait-ExlJs $script:Edge 'window.__exlStats && __exlStats.seq > 0 && document.querySelectorAll("#spacer .grid-row").length > 0' 120 | Should -BeTrue
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const user = document.querySelector("#spacer .grid-row").children[4].textContent, before = __exlStats.seq, total = __exlStats.shown;
  const input = document.querySelector("#filters input[type=search]");
  input.value = `user:"=${user}"`; input.dispatchEvent(new Event("input"));
  for (let i = 0; i < 100 && __exlStats.seq === before; i++) await new Promise(r => setTimeout(r, 100));
  const users = [...document.querySelectorAll("#spacer .grid-row")].map(r => r.children[4].textContent);
  const result = { user, total, shown: __exlStats.shown, users, state: document.getElementById("result-state").textContent };
  input.value = ""; input.dispatchEvent(new Event("input"));
  const cleared = __exlStats.seq;
  for (let i = 0; i < 100 && __exlStats.seq === cleared; i++) await new Promise(r => setTimeout(r, 100));
  return result;
})()
'@
        $result.shown | Should -BeGreaterThan 0
        $result.shown | Should -BeLessThan $result.total
        @($result.users | Where-Object { $_ -ne $result.user }).Count | Should -Be 0
        $result.state | Should -Match '^\d[\d,]* of \d[\d,]* rows'
        # The tests below read the page as it opens by default.
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions"
        Wait-ExlJs $script:Edge 'window.__exlStats && __exlStats.seq > 0' 120 | Should -BeTrue
    }

    It 'opens a client session with its timeline, and a step with its raw-line command and Copy' {
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  const rows = [...document.querySelectorAll("#spacer .grid-row")];
  for (const row of rows.slice(0, 25)) {
    row.click();
    for (let i = 0; i < 100 && !(dialog.open && document.querySelector("#detail-body dl")); i++) await sleep(100);
    const step = document.querySelector("#detail-body .timeline li.clickable");
    if (step) {
      step.querySelector(".what").click();
      for (let i = 0; i < 50 && !document.querySelector("#detail-body .step-more .cmd"); i++) await sleep(100);
      const cmd = document.querySelector("#detail-body .step-more .cmd");
      for (let i = 0; i < 20 && !/open=/.test(location.hash); i++) await sleep(100);
      if (cmd) return { title: document.getElementById("detail-title").textContent, command: cmd.querySelector("pre").textContent,
        copy: cmd.querySelector("button").textContent, timeline: document.querySelector("#detail-body h3").textContent, open: location.hash };
    }
    dialog.close(); await sleep(100);
  }
  return null;
})()
'@
        $result | Should -Not -BeNullOrEmpty -Because 'one of the first sessions has a step whose raw lines are known'
        $result.command | Should -Match "^Select-String -LiteralPath '.+' -SimpleMatch '.+'"
        $result.copy | Should -BeExactly 'Copy'
        $result.open | Should -Match 'open=\d+'
        (Invoke-ExlJs $script:Edge '(() => { document.getElementById("detail").close(); return true; })()') | Should -BeTrue
    }

    It 'never puts the token in the address of a request or of the page' {
        $requests = @(Get-ExlRequests $script:Edge)
        @($requests | Where-Object { $_ -like "*/api/*" }).Count | Should -BeGreaterThan 3
        @($requests | Where-Object { $_.Contains($script:Portal.Token) }).Count | Should -Be 0
        @($requests | Where-Object { $_ -match '[?&#]token=' }).Count | Should -Be 0
        (Invoke-ExlJs $script:Edge 'location.href').Contains($script:Portal.Token) | Should -BeFalse
    }

    It 'reopens the same days, tab and row from a copied address (open=) in the same tab, without the token' {
        $copied = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  document.querySelector("#spacer .grid-row").click();
  for (let i = 0; i < 100 && !(dialog.open && /open=/.test(location.hash)); i++) await sleep(100);
  return { href: location.href, title: document.getElementById("detail-title").textContent };
})()
'@
        $copied.href | Should -Match 'open=\d+'
        $copied.href | Should -Not -Match 'token'
        $open = [regex]::Match($copied.href, 'open=(\d+)').Groups[1].Value
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge $copied.href
        Wait-ExlJs $script:Edge 'document.getElementById("detail") && document.getElementById("detail").open && document.querySelector("#detail-body dl")' 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge '({ title: document.getElementById("detail-title").textContent, hash: location.hash, tab: document.querySelector("#tabs button.active").firstChild.textContent })'
        $state.title | Should -BeExactly $copied.title
        $state.tab | Should -BeExactly 'Client sessions'
        $state.hash | Should -Match "open=$open(&|$)"
        (Invoke-ExlJs $script:Edge '(() => { document.getElementById("detail").close(); return true; })()') | Should -BeTrue
    }

    It 'moves the selection with the day bar: Previous day, Next day, 3 days, a day chip and a server, each by a reload' {
        # Clicks the day bar on the page that is open and waits for the page that the new selection loads.
        function Step([string]$Action, [string]$Ready) {
            [void](Invoke-ExlJs $script:Edge "(() => { window.__exlBefore = true; setTimeout(() => { $Action }, 0); return true; })()")
            Wait-ExlJs $script:Edge "!window.__exlBefore && document.getElementById('day-caption') && window.__exlStats && __exlStats.seq > 0 && ($Ready)" 120 | Should -BeTrue -Because $Action
            Invoke-ExlJs $script:Edge '({ caption: document.getElementById("day-caption").textContent, hash: location.hash, chips: [...document.querySelectorAll("#day-bar .day-chip")].map(b => b.dataset.day), rows: document.querySelectorAll("#spacer .grid-row").length })'
        }
        $click = { param([string]$Text) "[...document.querySelectorAll('#day-bar button')].find(b => b.textContent === '$Text').click();" }
        $caption = Invoke-ExlJs $script:Edge 'document.getElementById("day-caption").textContent'
        $newest = [regex]::Match($caption, '^Day (\d{4}-\d{2}-\d{2})').Groups[1].Value
        $newest | Should -Match '^\d{4}-\d{2}-\d{2}$'
        $older = ([datetime]::ParseExact($newest, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).AddDays(-1).ToString('yyyy-MM-dd')
        $state = Step (& $click 'Previous day') "/^Day $older /.test(document.getElementById('day-caption').textContent)"
        $state.hash | Should -Match "day=$older"
        $state.hash | Should -Match 'days=1'
        $state.hash | Should -Match 'tab=sessions'
        $state.rows | Should -BeGreaterThan 0 -Because 'the demo store has two days of data'
        $state = Step (& $click 'Next day') "/^Day $newest /.test(document.getElementById('day-caption').textContent)"
        $state.hash | Should -Match "day=$newest"
        $state = Step (& $click '3 days') "/^3 days, /.test(document.getElementById('day-caption').textContent)"
        $state.hash | Should -Match 'days=3'
        @($state.chips).Count | Should -Be 3
        $state.chips[0] | Should -BeExactly $newest
        $state.chips[1] | Should -BeExactly $older
        $state = Step "[...document.querySelectorAll('#day-bar .day-chip')].find(b => b.dataset.day === '$older').click();" "/^Day $older /.test(document.getElementById('day-caption').textContent)"
        $state.hash | Should -Match 'days=1'
        $server = Invoke-ExlJs $script:Edge '[...document.getElementById("day-server").options].map(o => o.value).filter(v => v)[0]'
        $server | Should -Not -BeNullOrEmpty
        $state = Step "document.getElementById('day-server').value = '$server'; document.getElementById('day-apply').click();" "document.getElementById('day-caption').textContent.includes(', server $server')"
        $state.hash | Should -Match "server=$server"
        # A custom period longer than 31 days is refused in the page, without a reload.
        $refused = Invoke-ExlJs $script:Edge @'
(async () => {
  const from = document.getElementById("day-from"), to = document.getElementById("day-to"), hash = location.hash;
  from.value = "2026-01-01T00:00"; to.value = "2026-03-01T00:00";
  document.getElementById("day-apply").click();
  await new Promise(r => setTimeout(r, 500));
  return { notice: (document.getElementById("portal-notice") || {}).textContent || "", invalid: from.classList.contains("invalid"), same: location.hash === hash };
})()
'@
        $refused.notice | Should -Match '^Choose at most 31 days'
        $refused.invalid | Should -BeTrue
        $refused.same | Should -BeTrue
    }

    It 'draws the first rows of the open table before the overview has answered' {
        # A test script in the page holds the overview request (/api/overview/servers) until the test releases it, or answers it with a
        # retryable 504 the first n times; the server and the page are unchanged.
        $script:Hook = (Invoke-ExlCdp $script:Edge 'Page.addScriptToEvaluateOnNewDocument' @{ source = @'
(() => {
  if (location.protocol !== "http:") return;
  const mode = sessionStorage.getItem("exl-test-overview") || "", real = window.fetch.bind(window);
  const t = window.__exlTest = { calls: 0, release: null };
  const gate = mode === "hold" ? new Promise(r => { t.release = r; }) : Promise.resolve();
  let fail = /^504x\d$/.test(mode) ? Number(mode.slice(4)) : 0;
  window.fetch = async (input, init) => {
    if (String(typeof input === "string" ? input : input.url).startsWith("/api/overview/servers")) {
      t.calls++;
      if (fail > 0) {
        fail--;
        return new Response(JSON.stringify({ error: { code: "Deadline", message: "The request exceeded its deadline of 60 s (injected by the test).", retryable: true, retryAfterSeconds: 1 } }),
          { status: 504, headers: { "Content-Type": "application/json", "Retry-After": "1" } });
      }
      await gate;
    }
    return real(input, init);
  };
})();
'@ }).identifier
        Set-OverviewMode 'hold'
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions"
        Wait-ExlJs $script:Edge 'window.__exlTest && __exlTest.calls > 0 && document.querySelectorAll("#spacer .grid-row").length > 0' 120 | Should -BeTrue -Because 'the rows do not wait for the overview'
        $held = Invoke-ExlJs $script:Edge '({ messages: document.getElementById("metric-messages").textContent, cards: document.querySelectorAll("#cards .card").length, overlay: document.getElementById("loading").hidden, calls: __exlTest.calls })'
        $held.messages | Should -BeExactly '...'
        $held.cards | Should -Be 0
        $held.overlay | Should -BeTrue
        [void](Invoke-ExlJs $script:Edge '(() => { __exlTest.release(); return true; })()')
        Wait-ExlJs $script:Edge 'document.getElementById("metric-messages").textContent !== "..." && document.querySelectorAll("#cards .card").length > 0' 120 | Should -BeTrue
    }

    It 'draws the users and the operations while the overview is held: three lanes' {
        # The overview has a lane of its own; the period tables do not wait for it (the hook above holds /api/overview/servers).
        Set-OverviewMode 'hold'
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions"
        Wait-ExlJs $script:Edge 'window.__exlTest && __exlTest.calls > 0 && __exlTiming.ready.users && __exlTiming.ready.operations' 120 | Should -BeTrue -Because 'users and operations do not wait for the overview'
        $held = Invoke-ExlJs $script:Edge '({ servers: !!__exlTiming.ready.servers, daily: !!__exlTiming.ready.daily, messages: document.getElementById("metric-messages").textContent, rows: document.querySelectorAll("#spacer .grid-row").length })'
        $held.servers | Should -BeFalse
        $held.daily | Should -BeFalse
        $held.messages | Should -BeExactly '...'
        [void](Invoke-ExlJs $script:Edge '(() => { __exlTest.release(); return true; })()')
        Wait-ExlJs $script:Edge '__exlTiming.ready.servers && document.querySelectorAll("#cards .card").length > 0' 120 | Should -BeTrue
    }

    It 'retries a retryable 504 of the overview once, then shows the error and Try again on the second one' {
        $run = {
            param([string]$Mode)
            Set-OverviewMode $Mode
            Open-ExlPage $script:Edge 'about:blank'
            Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
            Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions"
        }
        & $run '504x1'
        Wait-ExlJs $script:Edge 'window.__exlTest && document.querySelectorAll("#cards .card").length > 0' 120 | Should -BeTrue -Because 'the second request answers'
        $once = Invoke-ExlJs $script:Edge '({ calls: __exlTest.calls, retry: document.querySelectorAll(".retry").length })'
        $once.calls | Should -Be 2
        $once.retry | Should -Be 0
        & $run '504x2'
        Wait-ExlJs $script:Edge 'document.querySelector("#progress .retry")' 120 | Should -BeTrue -Because 'the page retries a 504 once only'
        $twice = Invoke-ExlJs $script:Edge '({ calls: __exlTest.calls, text: document.getElementById("progress-text").textContent, cards: document.querySelectorAll("#cards .card").length })'
        $twice.calls | Should -Be 2
        $twice.text | Should -Match 'exceeded its deadline'
        $twice.cards | Should -Be 0
        [void](Invoke-ExlJs $script:Edge '(() => { document.querySelector("#progress .retry").click(); return true; })()')
        Wait-ExlJs $script:Edge 'document.querySelectorAll("#cards .card").length > 0 && !document.querySelector(".retry")' 120 | Should -BeTrue -Because 'Try again reads the overview again'
        (Invoke-ExlJs $script:Edge '__exlTest.calls') | Should -Be 3
        Set-OverviewMode ''
        [void](Invoke-ExlCdp $script:Edge 'Page.removeScriptToEvaluateOnNewDocument' @{ identifier = $script:Hook })
    }

    It 'computes whole days of the report time zone, also across a daylight-saving change and in a +05:30 zone' {
        $days = Invoke-ExlJs $script:Edge @'
(() => {
  const H = 3600000, iso = ms => new Date(ms).toISOString(), out = {};
  const paris = __exlPortal.days("Europe/Paris"), len = (d, k) => d.start(d.add(k, 1)) - d.start(k);
  out.parisLengths = ["2026-03-29", "2026-10-24", "2026-10-25"].map(k => len(paris, k) / H);
  out.parisStarts = [iso(paris.start("2026-10-25")), iso(paris.start("2026-10-26"))];
  const week = paris.ending("2026-10-28", 7), list = paris.slices(week);
  out.weekDays = list.map(s => s.day); out.weekHours = (week.to - week.from) / H;
  out.partition = list.every((s, k) => k + 1 >= list.length || s.from === list[k + 1].to) && list[0].to === week.to && list[6].from === week.from;
  out.shift = [paris.shift(paris.dayPeriod("2026-10-24"), 1), paris.shift(paris.dayPeriod("2026-10-25"), 1)].map(p => [iso(p.from), iso(p.to)]);
  out.shiftBack = paris.shift(paris.ending("2026-10-29", 7), -1).from === paris.ending("2026-10-28", 7).from;
  out.of = [paris.of(Date.parse("2026-10-25T22:30:00Z")), paris.of(Date.parse("2026-10-25T23:30:00Z"))];
  const partial = paris.slices({ from: paris.start("2026-10-14") + 5 * H, to: paris.start("2026-10-15") + 2 * H });
  out.partial = [partial.map(s => s.day), (partial[0].to - partial[0].from) / H];
  out.endDay = paris.endDay(paris.ending("2026-10-15", 3)); out.count = paris.count(paris.ending("2026-10-15", 3));
  out.defaultDay = paris.endDay(paris.defaultPeriod(Date.parse("2026-10-15T16:30:00Z")));
  const kolkata = __exlPortal.days("Asia/Kolkata");
  out.kolkata = [iso(kolkata.start("2026-10-15")), kolkata.slices(kolkata.ending("2026-10-15", 3)).map(s => (s.to - s.from) / H), kolkata.of(Date.parse("2026-10-14T18:45:00Z")), kolkata.of(Date.parse("2026-10-14T18:15:00Z"))];
  const santiago = __exlPortal.days("America/Santiago");
  out.santiago = [iso(santiago.start("2026-09-06")), len(santiago, "2026-09-05") / H, len(santiago, "2026-09-06") / H, santiago.slices(santiago.ending("2026-09-07", 3)).map(s => s.day)];
  return out;
})()
'@
        @($days.parisLengths) | Should -Be @(23, 24, 25)
        @($days.parisStarts) | Should -Be @('2026-10-24T22:00:00.000Z', '2026-10-25T23:00:00.000Z')
        @($days.weekDays) | Should -Be @('2026-10-28', '2026-10-27', '2026-10-26', '2026-10-25', '2026-10-24', '2026-10-23', '2026-10-22')
        $days.weekHours | Should -Be (7 * 24 + 1)
        $days.partition | Should -BeTrue
        @($days.shift[0]) | Should -Be @('2026-10-24T22:00:00.000Z', '2026-10-25T23:00:00.000Z')
        @($days.shift[1]) | Should -Be @('2026-10-25T23:00:00.000Z', '2026-10-26T23:00:00.000Z')
        $days.shiftBack | Should -BeTrue
        @($days.of) | Should -Be @('2026-10-25', '2026-10-26')
        @($days.partial[0]) | Should -Be @('2026-10-15', '2026-10-14')
        $days.partial[1] | Should -Be 2
        $days.endDay | Should -BeExactly '2026-10-15'
        $days.count | Should -Be 3
        $days.defaultDay | Should -BeExactly '2026-10-15'
        # Exact local midnights: a +05:30 day starts at 18:30 UTC.
        $days.kolkata[0] | Should -BeExactly '2026-10-14T18:30:00.000Z'
        @($days.kolkata[1]) | Should -Be @(24, 24, 24)
        $days.kolkata[2] | Should -BeExactly '2026-10-15'
        $days.kolkata[3] | Should -BeExactly '2026-10-14'
        # A day that starts at 01:00 because the clock moves forward at midnight.
        $days.santiago[0] | Should -BeExactly '2026-09-06T04:00:00.000Z'
        $days.santiago[1] | Should -Be 24
        $days.santiago[2] | Should -Be 23
        @($days.santiago[3]) | Should -Be @('2026-09-07', '2026-09-06', '2026-09-05')
    }

    It 'retries busy, unavailable and deadline answers as the API says, and nothing else' {
        $delays = Invoke-ExlJs $script:Edge @'
(() => {
  const d = __exlPortal.retryDelay, r = (s, x) => ({ retryable: true, retryAfterSeconds: s, ...x });
  return [d(429, null, "3", 0), d(429, null, null, 2), d(429, null, null, 3), d(503, r(1), null, 0), d(503, r(1), null, 3), d(503, { retryable: false }, null, 0),
    d(504, r(2), null, 0), d(504, r(2), null, 1), d(504, r(99), null, 0), d(504, { retryable: true }, null, 0), d(500, r(1), null, 0), d(404, null, null, 0), d(401, null, null, 0)];
})()
'@
        @($delays | ForEach-Object { if ($null -eq $_) { 'none' } else { [string]$_ } }) | Should -Be @('3000', '1000', 'none', '1000', 'none', 'none', '2000', 'none', '2000', '2000', 'none', 'none', 'none')
    }

    It 'shows the authentication types in the Authentication tab with its users and devices, and the share of the users on OAuth in the tile' {
        $script:OAuthLines | Should -Be 4
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=authentication&$script:AuthDays"
        Wait-ExlJs $script:Edge '(() => { const b = document.querySelector("#tabs button.active"); return !!b && b.firstChild.textContent === "Authentication" && document.querySelectorAll("#spacer .grid-row").length > 0 && /%$/.test(document.getElementById("metric-auth").textContent); })()' 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  const heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent), lines = [...document.querySelectorAll("#spacer .grid-row")];
  const p = heads.indexOf("Protocol"), a = heads.indexOf("Authentication"), u = heads.indexOf("Users");
  const pairs = lines.map(r => `${r.children[p].textContent}|${r.children[a].textContent}`), users = lines.map(r => Number(r.children[u].textContent.replace(/,/g, "")));
  let detail = null;
  const target = lines.find(r => r.children[p].textContent === "Ews" && r.children[a].textContent === "OAuth");
  if (target) {
    target.click();
    for (let i = 0; i < 100 && !(dialog.open && [...document.querySelectorAll("#detail-body h3")].some(h => /^Users and devices/.test(h.textContent))); i++) await sleep(100);
    const h = [...document.querySelectorAll("#detail-body h3")].find(x => /^Users and devices/.test(x.textContent));
    detail = h ? { title: document.getElementById("detail-title").textContent, users: [...h.nextElementSibling.querySelectorAll("tr")].slice(1).map(t => t.children[0].textContent) } : null;
    dialog.close();
  }
  return { heads, pairs, users, detail, tile: document.getElementById("metric-auth").textContent, note: document.getElementById("metric-auth-note").textContent, tiles: document.querySelectorAll(".metrics .tile").length };
})()
'@
        foreach ($h in 'Protocol', 'Authentication', 'OAuth possible', 'Users', 'Clients', 'Devices') { $state.heads | Should -Contain $h }
        $state.pairs | Should -Contain 'Eas|Basic'
        $state.pairs | Should -Contain 'Ews|OAuth'
        # Sorted by Users, most first.
        for ($i = 1; $i -lt @($state.users).Count; $i++) { $state.users[$i] | Should -BeLessOrEqual $state.users[$i - 1] }
        $state.detail | Should -Not -BeNullOrEmpty
        $state.detail.title | Should -BeExactly 'Ews - OAuth'
        $state.detail.users | Should -Contain $script:OAuthUser
        $state.tile | Should -Match '^\d+ %$'
        $state.note | Should -Match 'on Basic'
        $state.tiles | Should -Be 5
    }

    It 'lists the authentication types of the client sessions and selects the sessions on OAuth' {
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=sessions&$script:AuthDays"
        Wait-ExlJs $script:Edge '(() => { const h = [...document.querySelectorAll("#grid-head div")].map(x => x.textContent), c = document.querySelectorAll("#grid-filter > div")[h.indexOf("Authentication")]; return !!(c && c.querySelector(".multi-button")) && document.querySelectorAll("#spacer .grid-row").length > 0; })()' 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  const b = document.querySelectorAll("#grid-filter > div")[heads.indexOf("Authentication")].querySelector(".multi-button");
  b.click(); await sleep(300);
  const labels = [...document.querySelector(".multi-panel").querySelectorAll("label")].filter(l => l.children.length === 3);
  const values = labels.map(l => l.children[1].textContent);
  const before = __exlStats.seq;
  labels.find(l => l.children[1].textContent === "OAuth").querySelector("input").click();
  for (let i = 0; i < 100 && __exlStats.seq === before; i++) await sleep(100);
  await sleep(300);
  const lines = [...document.querySelectorAll("#spacer .grid-row")];
  return { values, auth: lines.map(r => r.children[heads.indexOf("Authentication")].textContent), users: lines.map(r => r.children[heads.indexOf("User")].textContent), hash: location.hash };
})()
'@
        foreach ($v in 'Negotiate', 'Basic', 'OAuth') { $state.values | Should -Contain $v }
        @($state.auth).Count | Should -BeGreaterThan 0
        @($state.auth | Where-Object { $_ -notmatch '\bOAuth\b' }).Count | Should -Be 0
        @($state.users | Select-Object -Unique) | Should -Be @($script:OAuthUser)
        $state.hash | Should -Match 'm\.Authentication=OAuth'
    }

    It 'shows the authentication types of a user in the Users dialog: its clients and devices and its client sessions' {
        $query = [Uri]::EscapeDataString("user:`"=$($script:OAuthUser)`"")
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=users&$script:AuthDays&q=$query"
        Wait-ExlJs $script:Edge '__exlTiming.ready.sessions && document.querySelectorAll("#spacer .grid-row").length === 1' 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  document.querySelector("#spacer .grid-row").click();
  const find = re => [...document.querySelectorAll("#detail-body h3")].find(h => re.test(h.textContent));
  for (let i = 0; i < 200 && !(dialog.open && find(/^Clients and devices/) && find(/^Client sessions \(/)); i++) await sleep(100);
  const table = re => { const h = find(re); if (!h) return null; const rows = [...h.nextElementSibling.querySelectorAll("tr")]; const head = [...rows[0].children].map(c => c.textContent), k = head.indexOf("Authentication");
    return { head, cells: rows.slice(1).map(r => k < 0 ? null : r.children[k].textContent) }; };
  const r = { devices: table(/^Clients and devices/), sessions: table(/^Client sessions \(/) };
  dialog.close(); return r;
})()
'@
        $state.devices.head | Should -Contain 'Authentication'
        @($state.devices.cells | Where-Object { $_ -match '\bOAuth\b' }).Count | Should -BeGreaterThan 0
        $state.sessions.head | Should -Contain 'Authentication'
        @($state.sessions.cells | Where-Object { $_ -match '\bOAuth\b' }).Count | Should -BeGreaterThan 0
    }

    It 'marks a user still logged as a security identifier with the unresolved SID pill, and lists its Identifiers in the Users dialog' {
        $query = [Uri]::EscapeDataString("user:`"=$($script:SidUser)`"")
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=users&$script:AuthDays&q=$query"
        Wait-ExlJs $script:Edge '__exlTiming.ready.sessions && document.querySelectorAll("#spacer .grid-row").length === 1' 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  const heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent), row = document.querySelector("#spacer .grid-row");
  const pill = row.children[heads.indexOf("User")].querySelector(".pill");
  const grid = pill ? { text: pill.textContent, warn: pill.classList.contains("warn"), title: pill.title } : null;
  row.click();
  const find = re => [...document.querySelectorAll("#detail-body h3")].find(h => re.test(h.textContent));
  for (let i = 0; i < 200 && !(dialog.open && find(/^Identifiers/)); i++) await sleep(100);
  const h = find(/^Identifiers/);
  const rows = h ? [...h.nextElementSibling.nextElementSibling.querySelectorAll("tr")] : [];
  const r = { grid, heading: h ? h.textContent : null, head: rows.length ? [...rows[0].children].map(c => c.textContent) : [], cells: rows.slice(1).map(t => [...t.children].map(c => c.textContent)),
    dialogPill: !!document.querySelector("#detail-body dd .pill.warn") };
  dialog.close(); return r;
})()
'@
        $state.grid | Should -Not -BeNullOrEmpty
        $state.grid.text | Should -BeExactly $script:SidUser
        $state.grid.warn | Should -BeTrue
        $state.grid.title | Should -Match '^Unresolved security identifier: Exchange logs token \(OAuth\) requests by SID'
        $state.heading | Should -BeExactly 'Identifiers (1)'
        @($state.head) -join '|' | Should -BeExactly 'Security identifier|Status|Evidence|Hints|Requests|First seen|Last seen'
        $state.cells[0][0] | Should -BeExactly $script:SidUser
        $state.cells[0][1] | Should -BeExactly 'unresolved'
        $state.cells[0][4] | Should -BeExactly '2'
        $state.dialogPill | Should -BeTrue
    }

    It 'shows the mail accepted by a server outside the organization as sent to external, in green (<Status>)' -ForEach @(
        @{ Status = 'Sent to external'; Recipients = 'partner@fabrikam.example (Sent to external)' }, @{ Status = 'Delivered and sent to external'; Recipients = $null }) {
        $query = [Uri]::EscapeDataString("status:`"=$Status`"")
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge "$($script:Portal.Url)/#tab=messages&$script:AuthDays&q=$query"
        Wait-ExlJs $script:Edge 'document.querySelectorAll("#spacer .grid-row").length === 1' 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(() => {
  const heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent), row = document.querySelector("#spacer .grid-row");
  const pill = row.children[heads.indexOf("Status")].querySelector(".pill");
  return { text: pill ? pill.textContent : null, good: !!pill && pill.classList.contains("good"), recipients: row.children[heads.indexOf("Recipients")].textContent };
})()
'@
        $state.text | Should -BeExactly $Status
        $state.good | Should -BeTrue
        if ($Recipients) { $state.recipients | Should -BeExactly $Recipients }
    }

    It 'never calls the API from a static report of the same store' {
        $q = [ExchangeLogReport.ReportRequest]::new()
        $period = Invoke-ExlJs $script:Edge '(() => { const p = new URLSearchParams(location.hash.slice(1)); return document.getElementById("day-caption").textContent; })()'
        $period | Should -Not -BeNullOrEmpty
        $q.EndMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $q.StartMs = $q.EndMs - 3 * 86400000
        $q.Detailed = $true; $q.WriteHtml = $true; $q.WriteCsv = $false; $q.MemoryBudgetMB = 64; $q.Parallelism = 1; $q.HtmlLayout = 'SingleFile'
        $q.ConfiguredServers = [string[]]@($script:Settings.Servers.Name); $q.Zone = $script:Settings.Zone; $q.TimeZoneName = $script:Settings.Report.TimeZone
        $q.TemplatePath = Join-Path $script:Root 'templates\Report.template.html'
        $q.OutputFolder = Join-Path $script:Work 'static-report'
        $store = Open-ExlStore -Settings $script:Settings -ReadOnly
        try { $report = [ExchangeLogReport.ReportBuilder]::Build($store, $q) } finally { $store.Dispose() }
        Clear-ExlRequests $script:Edge
        Open-ExlPage $script:Edge ([Uri]::new($report.HtmlPath).AbsoluteUri)
        Wait-ExlJs $script:Edge 'window.__exlStats && __exlStats.seq > 0' 60 | Should -BeTrue
        $requests = @(Get-ExlRequests $script:Edge)
        $requests.Count | Should -BeGreaterThan 0
        @($requests | Where-Object { $_ -match '/api/' -or $_ -match '^https?:' }).Count | Should -Be 0
        (Invoke-ExlJs $script:Edge '!!window.__exlPortal || !!document.getElementById("day-bar")') | Should -BeFalse
        (Invoke-ExlJs $script:Edge '[...document.querySelectorAll("#tabs button")].some(b => b.firstChild.textContent === "Authentication")') | Should -BeTrue
    }

    It 'stops the portal from its page, and the database is unchanged' {
        Open-ExlPage $script:Edge "$($script:Portal.Url)/"
        Wait-ExlJs $script:Edge 'document.getElementById("portal-stop")' 60 | Should -BeTrue
        (Invoke-ExlJs $script:Edge '(async () => { document.getElementById("portal-stop").click(); for (let i = 0; i < 50 && !document.getElementById("portal-notice"); i++) await new Promise(r => setTimeout(r, 100)); return document.getElementById("portal-notice").textContent; })()') |
            Should -Match 'The portal is stopped'
        $script:Portal.Task.Wait(15000) | Should -BeTrue
        $script:Portal.Task.GetAwaiter().GetResult()
        (Get-FileHash -LiteralPath $script:Database).Hash | Should -Be $script:SourceHash
    }
}

Describe 'The portal page browsing a selection on the server' -Tag Browser -Skip:$script:NoEdge {
    BeforeAll {
        # Two UTC days (13 and 14 October 2026): 12,000 client sessions and 12,000 messages (more than ClientRowsMax = 10,000: browsed on the server),
        # 2,500 failed and slow requests (loaded in the page), the rows of Serve.FilterCases.json, and the usage of three users.
        $script:RemoteWork = Join-Path $script:Work 'remote'; [void][IO.Directory]::CreateDirectory($script:RemoteWork)
        $script:D0 = [DateTimeOffset]::Parse('2026-10-14T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
        $a = $script:D0 - 86400000
        $script:RemoteDb = Join-Path $script:RemoteWork 'remote.sqlite'
        $store = [ExchangeLogReport.Store]::new($script:RemoteDb, $false, 'synthetic')
        try {
            $store.Exec(@"
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<11999)
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,user_agent,client_ip,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,auth_modes)
SELECT 'k'||i,'2026-10-14',$a+(i/2)*28800,$a+(i/2)*28800+(i%7)*60000,CASE WHEN i%11=0 THEN 'USER'||(i%37) WHEN i%37=36 THEN char(304)||'STANBUL' ELSE 'user'||(i%37) END,
 CASE i%4 WHEN 0 THEN 'Mapi' WHEN 1 THEN 'Ews' WHEN 2 THEN 'Owa' ELSE 'Eas' END,CASE i%3 WHEN 0 THEN 'EX1' WHEN 1 THEN 'EX1,EX2' ELSE 'EX2' END,'EX3',
 CASE i%3 WHEN 0 THEN 'Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0.17928)' WHEN 1 THEN 'Mozilla/5.0' ELSE 'Apple-iPhone/1.0' END,'10.0.0.'||(i%9),
 i%10,i%10-(CASE WHEN i%5=0 AND i%10>0 THEN 1 ELSE 0 END),CASE WHEN i%5=0 AND i%10>0 THEN 1 ELSE 0 END,CASE WHEN i%9=0 THEN 1 ELSE 0 END,
 $a+(i/2)*28800,$a+(i/2)*28800+1000,CASE WHEN i%5=0 THEN $a+(i/2)*28800+500 ELSE 0 END,CASE WHEN i%5=0 THEN $a+(i/2)*28800+500 ELSE 0 END,100,50,0,0,
 CASE WHEN i%20=0 THEN 'OAuth=5;Basic=1' WHEN i%4=3 THEN 'Basic='||(i%10+1) WHEN i%4=2 THEN 'FBA='||(i%10+1) WHEN i%13=1 THEN NULL ELSE 'Negotiate='||(i%10+1) END FROM n;
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<11999)
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count)
SELECT $a+i*14200+500,'EX1','RECEIVE',CASE WHEN i=7 THEN '<M7@Invalid>' ELSE '<m'||i||'@invalid>' END,'a'||i,CASE WHEN i%17=0 THEN 'ALPHA'||(i%13)||'@invalid' ELSE 'alpha'||(i%13)||'@invalid' END,'r'||(i%5)||'@invalid;s@invalid','subject '||(i%23),(i%3)+1 FROM n
UNION ALL SELECT $a+i*14200+1500,'EX2',CASE WHEN i%9=0 THEN 'FAIL' ELSE 'DELIVER' END,CASE WHEN i=7 THEN '<M7@Invalid>' ELSE '<m'||i||'@invalid>' END,'b'||i,'alpha'||(i%13)||'@invalid','r'||(i%5)||'@invalid',NULL,1 FROM n;
WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<2499)
INSERT INTO access_event(time_ms,server,source,protocol,user,client_ip,user_agent,method,url,action,status,outcome,request_id)
SELECT $a+i*69000+7,CASE i%2 WHEN 0 THEN 'EX1' ELSE 'EX2' END,'HttpProxy',CASE i%4 WHEN 0 THEN 'Mapi' WHEN 1 THEN 'Owa' WHEN 2 THEN 'Ews' ELSE 'Eas' END,'user'||(i%29),'10.0.0.1','Mozilla/5.0','POST',
 CASE i%3 WHEN 0 THEN '/owa/service.svc' WHEN 1 THEN '/EWS/Exchange.asmx' ELSE '/mapi/emsmdb/' END,'Execute',CASE i%4 WHEN 0 THEN 500 WHEN 1 THEN 400 WHEN 2 THEN 200 ELSE 503 END,
 CASE WHEN i%50=0 THEN 'Success' WHEN i%4=0 THEN 'ServerError' WHEN i%4=1 THEN 'ClientError' WHEN i%4=2 THEN 'Slow' ELSE 'ServerError' END,'q'||i FROM n;
INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms) VALUES
('2026-10-14','EX1','user3','Mapi',NULL,10,10,0,0,1,1,10,5,$($script:D0),$($script:D0 + 1000),$($script:D0 + 1000),0),
('2026-10-14','EX1','user4','Mapi',NULL,9,9,0,0,1,1,10,5,$($script:D0),$($script:D0 + 1000),$($script:D0 + 1000),0),
('2026-10-13','EX2','user5','Ews',NULL,8,8,0,0,1,1,10,5,$a,$($a + 1000),$($a + 1000),0);
"@)
            $tx = $store.Begin(); try { $store.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
        } finally { $store.Dispose() }
        $script:RemoteHash = (Get-FileHash -LiteralPath $script:RemoteDb).Hash
        # Small chunks and a short budget: a scan of these rows takes several answers, as a scan of a large store does.
        $script:ChunkField = [ExchangeLogReport.ServeHost].Assembly.GetType('ExchangeLogReport.ServeRead').GetField('ChunkRows', [Reflection.BindingFlags]'Static,NonPublic,Public')
        $script:Chunk = $script:ChunkField.GetValue($null); $script:ChunkField.SetValue($null, 4)
        $o = [ExchangeLogReport.ServeOptions]::new()
        $o.DatabasePath = $script:RemoteDb; $o.WebRoot = Join-Path $script:Root 'templates'; $o.Port = 0; $o.NoBrowser = $true
        $o.ReadyFile = Join-Path $script:RemoteWork 'ready.json'; $o.ReadyFileWithToken = $true; $o.RequestTimeoutSeconds = 30; $o.AggregateTimeoutSeconds = 60
        $o.Zone = [TimeZoneInfo]::Utc; $o.ClientRowsMax = 10000; $o.ScanBudgetMs = 100
        $task = [ExchangeLogReport.ServeHost]::RunAsync($o, [Threading.CancellationToken]::None)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $o.ReadyFile)) {
            if ($task.IsCompleted) { $task.GetAwaiter().GetResult(); throw 'Serve stopped before it was ready.' }
            if ($wait.Elapsed.TotalSeconds -gt 30) { throw 'Serve was not ready within 30 s.' }
            Start-Sleep -Milliseconds 50
        }
        $ready = Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
        $script:Remote = [pscustomobject]@{ Task = $task; Url = $ready.url.TrimEnd('/'); Token = $ready.token }
        $script:RemoteSelection = 'day=2026-10-14&days=2'
        # Opens the page of this host with the selection of the two days and the rest of the address, and waits for Ready.
        function Open-Remote([string]$Hash, [string]$Ready = 'window.__exlStats && __exlStats.seq > 0') {
            Open-ExlPage $script:Edge 'about:blank'
            Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
            Open-ExlPage $script:Edge "$($script:Remote.Url)/#token=$($script:Remote.Token)&$script:RemoteSelection&$Hash"
            Wait-ExlJs $script:Edge $Ready 120 | Should -BeTrue -Because $Hash
        }
        # The server's exact count of a list with the filters of a case: every day pack, a scan continued from scannedTo.
        function Remote-Count([string]$View, [hashtable]$Params) {
            $path = @{ sessions = '/api/sessions'; messages = '/api/messages'; issues = '/api/requests' }[$View]
            $query = "from=2026-10-13T00%3A00%3A00Z&to=2026-10-15T00%3A00%3A00Z&" + ((@($Params.Keys | ForEach-Object { [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$Params[$_]) })) -join '&')
            $total = 0L
            foreach ($day in '&orderFrom=2026-10-14T00%3A00%3A00Z', '&orderTo=2026-10-14T00%3A00%3A00Z') {
                $cursor = $null
                do {
                    $r = Invoke-RestMethod -Uri ("$($script:Remote.Url)$path/count?$query$day" + $(if ($cursor) { "&cursor=$cursor" } else { '' })) -Headers @{ 'X-Portal-Token' = $script:Remote.Token }
                    $total += [long]$r.total; $cursor = if ($r.complete) { $null } else { $r.scannedTo }
                } while ($cursor)
            }
            return $total
        }
        function Grouped([long]$N) { $N.ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }
        # The downloads of the page go to a folder of the test (never the Downloads folder of the person); a file is complete once no partial file remains.
        function Set-Downloads([string]$Folder) {
            if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force }
            [void][IO.Directory]::CreateDirectory($Folder)
            [void](Invoke-ExlCdp $script:Edge 'Browser.setDownloadBehavior' @{ behavior = 'allow'; downloadPath = $Folder; eventsEnabled = $true })
        }
        function Wait-Download([string]$Folder, [string]$Name) {
            $path = Join-Path $Folder $Name; $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $path) -or @(Get-ChildItem -LiteralPath $Folder -Filter '*.crdownload').Count) {
                if ($clock.Elapsed.TotalSeconds -gt 60) { throw "The download $Name did not complete in $Folder." }
                Start-Sleep -Milliseconds 100
            }
            return $path
        }
        # The export of the server for a list and the query of the selection of the page (two UTC days), by its ticket.
        function Ticket-Export([string]$View, [string]$Query) {
            $issued = Invoke-WebRequest -Uri "$($script:Remote.Url)/api/export/ticket" -Method Post -Headers @{ 'X-Portal-Token' = $script:Remote.Token } -ContentType 'application/json' `
                -Body (@{ view = $View; query = "from=2026-10-13T00%3A00%3A00.000Z&to=2026-10-15T00%3A00%3A00.000Z$Query" } | ConvertTo-Json -Compress)
            $answer = Invoke-WebRequest -Uri ($script:Remote.Url + ($issued.Content | ConvertFrom-Json).url)
            return ,$answer.RawContentStream.ToArray()
        }
        $script:Settled ='window.__exlStats && __exlStats.seq > 0 && !/Counting|so far|Loading/.test(document.getElementById("result-state").textContent)'
    }

    AfterAll {
        if ($script:ChunkField) { $script:ChunkField.SetValue($null, $script:Chunk) }
        if ($script:Remote -and -not $script:Remote.Task.IsCompleted) {
            try { Invoke-WebRequest -Uri "$($script:Remote.Url)/api/shutdown" -Method Post -Headers @{ 'X-Portal-Token' = $script:Remote.Token } -SkipHttpErrorCheck | Out-Null } catch { }
            [void]$script:Remote.Task.Wait(15000)
        }
    }

    It 'draws the first page before any count, then browses the exact total on the server (Remote)' {
        # A test script in the page holds every count (/count) until the test releases it.
        $script:CountHook = (Invoke-ExlCdp $script:Edge 'Page.addScriptToEvaluateOnNewDocument' @{ source = @'
(() => {
  if (location.protocol !== "http:" || sessionStorage.getItem("exl-test-count") !== "hold") return;
  const real = window.fetch.bind(window), t = window.__exlCount = { held: 0, release: null };
  const gate = new Promise(r => { t.release = r; });
  window.fetch = async (input, init) => { if (/\/count\?/.test(String(typeof input === "string" ? input : input.url))) { t.held++; await gate; } return real(input, init); };
})();
'@ }).identifier
        Open-ExlPage $script:Edge "$($script:Remote.Url)/#token=$($script:Remote.Token)"
        Wait-ExlJs $script:Edge 'document.getElementById("day-bar")' 120 | Should -BeTrue
        [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.setItem("exl-test-count", "hold"); return true; })()')
        Open-Remote 'tab=sessions' 'window.__exlCount && __exlCount.held > 0 && document.querySelectorAll("#spacer .grid-row").length > 0'
        $held = Invoke-ExlJs $script:Edge '({ rows: document.querySelectorAll("#spacer .grid-row").length, held: __exlCount.held, seq: __exlStats.seq })'
        $held.rows | Should -BeGreaterThan 0
        $held.seq | Should -Be 0 -Because 'the tab opens when the counts are in'
        [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.removeItem("exl-test-count"); __exlCount.release(); return true; })()')
        Wait-ExlJs $script:Edge $script:Settled 120 | Should -BeTrue
        $state = Invoke-ExlJs $script:Edge @'
(() => {
  const b = document.querySelector("#tabs button.active");
  return { tab: b.firstChild.textContent, count: b.querySelector(".count").textContent, pill: b.querySelector(".mode").textContent, caption: document.getElementById("tab-caption").textContent,
    result: document.getElementById("result-state").textContent, height: document.getElementById("spacer").getBoundingClientRect().height, period: document.querySelector(".period-bar").hidden,
    export: document.getElementById("export").disabled, exportTitle: document.getElementById("export").title, chips: [...document.querySelectorAll("#day-bar .day-chip")].map(c => `${c.dataset.day}=${c.querySelector(".n").textContent}`),
    chipTitle: document.querySelector("#day-bar .day-chip").title };
})()
'@
        $state.tab | Should -BeExactly 'Client sessions'
        $state.count | Should -BeExactly '12,000'
        $state.pill | Should -BeExactly 'Remote'
        $state.caption | Should -Match 'Browsing the 12,000 rows of the selection on the server - sorted by Start, newest first\.'
        $state.result | Should -BeExactly '12,000 of 12,000 rows'
        $state.height | Should -Be (12000 * 36)
        $state.period | Should -BeTrue -Because 'the day bar is the period of the portal'
        $state.export | Should -BeFalse -Because 'a list browsed on the server is exported by the server'
        $state.exportTitle | Should -BeExactly 'Exports every row of the selection with the filters of the list, in the order of the list: the server writes the file day by day, and the download list of the browser shows its progress.'
        $state.caption | Should -Match 'Filters, value lists, the search and Export view run on the server over the whole period; sorting by another column opens when the selection holds at most 10,000 rows\.$'
        @($state.chips) -join '|' | Should -BeExactly '2026-10-14=6,000|2026-10-13=6,000'
        $state.chipTitle | Should -BeExactly 'Scroll to 2026-10-14' -Because 'a day button of a list browsed on the server scrolls to that day'
        [void](Invoke-ExlCdp $script:Edge 'Page.removeScriptToEvaluateOnNewDocument' @{ identifier = $script:CountHook })
    }

    It 'paints the rows of any rank: a drag of the scrollbar to 80 % shows ordered rows at rank 0.8 x total' {
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const v = document.getElementById("viewport"), sleep = ms => new Promise(r => setTimeout(r, ms));
  v.scrollTop = 0.8 * (v.scrollHeight - v.clientHeight); v.dispatchEvent(new Event("scroll"));
  for (let i = 0; i < 100; i++) { await sleep(100); if (document.querySelectorAll("#spacer .grid-row").length && !document.querySelector("#spacer .grid-row.loading")) break; }
  const rows = [...document.querySelectorAll("#spacer .grid-row")];
  return { loading: !!document.querySelector("#spacer .grid-row.loading"), ranks: rows.map(r => Number(r.dataset.row)), starts: rows.map(r => r.children[0].textContent), top: __exlStats.topRank,
    shown: v.clientHeight / 36 };
})()
'@
        $result.loading | Should -BeFalse
        $expected = [Math]::Floor(0.8 * (12000 - $result.shown))
        [Math]::Abs($result.top - $expected) | Should -BeLessOrEqual 1
        $ranks = @($result.ranks); $starts = @($result.starts)
        for ($k = 1; $k -lt $ranks.Count; $k++) { $ranks[$k] | Should -Be ($ranks[$k - 1] + 1); [string]::CompareOrdinal($starts[$k - 1], $starts[$k]) | Should -BeGreaterOrEqual 0 }
    }

    It 'scrolls to the first row of a day from the day bar and marks the day of the first visible row' {
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  [...document.querySelectorAll("#day-bar .day-chip")].find(c => c.dataset.day === "2026-10-13").click();
  for (let i = 0; i < 100; i++) { await sleep(100); if (!document.querySelector("#spacer .grid-row.loading")) break; }
  const current = document.querySelector("#day-bar .day-chip.current");
  return { top: __exlStats.topRank, hash: location.hash, current: current ? current.dataset.day : null };
})()
'@
        [Math]::Abs($result.top - 6000) | Should -BeLessOrEqual 1
        $result.current | Should -BeExactly '2026-10-13'
        $result.hash | Should -Match 'days=2' -Because 'the chip scrolls, it does not read another period'
    }

    It 'sorts by the list key in both directions, and says when the other columns sort' {
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")], before = __exlStats.seq;
  heads.find(h => h.textContent === "Start").click();
  for (let i = 0; i < 100 && __exlStats.seq === before; i++) await sleep(100);
  for (let i = 0; i < 100 && document.querySelector("#spacer .grid-row.loading"); i++) await sleep(100);
  const user = heads.find(h => h.textContent === "User");
  return { first: document.querySelector("#spacer .grid-row").children[0].textContent, asc: heads.find(h => h.textContent === "Start").classList.contains("asc"),
    title: user.title, nosort: user.classList.contains("nosort"), caption: document.getElementById("tab-caption").textContent };
})()
'@
        $result.first | Should -BeExactly '2026-10-13 00:00:00'
        $result.asc | Should -BeTrue
        $result.nosort | Should -BeTrue
        $result.title | Should -BeExactly 'Sort by User is available when the selection holds at most 10,000 rows: narrow the period or filter the list'
        $result.caption | Should -Match 'sorted by Start, oldest first'
    }

    It 'reads the first page of every list before the whole load of a list loaded in the page' {
        # A test script holds every keyset page of 2,000 failed requests (the whole load of a list loaded in the page) until the test releases them.
        $hook = (Invoke-ExlCdp $script:Edge 'Page.addScriptToEvaluateOnNewDocument' @{ source = @'
(() => {
  if (location.protocol !== "http:" || sessionStorage.getItem("exl-test-hold") !== "issues") return;
  const real = window.fetch.bind(window), t = window.__exlHold = { held: 0, release: null };
  const gate = new Promise(r => { t.release = r; });
  window.fetch = async (input, init) => { const url = String(typeof input === "string" ? input : input.url); if (/\/api\/requests\?/.test(url) && /[?&]size=2000(&|$)/.test(url)) { t.held++; await gate; } return real(input, init); };
})();
'@ }).identifier
        try {
            Open-ExlPage $script:Edge 'about:blank'
            Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
            Open-ExlPage $script:Edge "$($script:Remote.Url)/#token=$($script:Remote.Token)"
            Wait-ExlJs $script:Edge 'document.getElementById("day-bar")' 120 | Should -BeTrue
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.setItem("exl-test-hold", "issues"); return true; })()')
            Open-Remote 'tab=sessions' 'window.__exlHold && __exlHold.held > 0 && __exlTiming.ready.messages && __exlTiming.ready.sessions'
            $state = Invoke-ExlJs $script:Edge '({ issues: !!__exlTiming.ready.issues, messages: !!__exlTiming.ready.messages, held: __exlHold.held, pill: [...document.querySelectorAll("#tabs button")].find(b => b.firstChild.textContent === "Messages").querySelector(".mode").textContent })'
            $state.messages | Should -BeTrue -Because 'the first page of the messages does not wait for the whole load of the failed requests'
            $state.issues | Should -BeFalse -Because 'the whole load of the failed requests is held'
            $state.pill | Should -BeExactly 'Remote'
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.removeItem("exl-test-hold"); __exlHold.release(); return true; })()')
            Wait-ExlJs $script:Edge '__exlTiming.ready.issues' 120 | Should -BeTrue
        } finally {
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.removeItem("exl-test-hold"); return true; })()')
            [void](Invoke-ExlCdp $script:Edge 'Page.removeScriptToEvaluateOnNewDocument' @{ identifier = $hook })
        }
    }

    It 'lists the values of the server, counts a filter on the server and switches to the page when it narrows the selection' {
        Open-Remote 'tab=sessions' $script:Settled
        Wait-ExlJs $script:Edge '(() => { const h = [...document.querySelectorAll("#grid-head div")].map(x => x.textContent), c = document.querySelectorAll("#grid-filter > div")[h.indexOf("Protocol")]; return !!(c && c.querySelector(".multi-button")); })()' 120 | Should -BeTrue -Because 'the value lists come from /facets'
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  for (let i = 0; i < 200; i++) { const b = document.querySelectorAll("#grid-filter > div")[heads.indexOf("Protocol")].querySelector(".multi-button"); b.click(); await sleep(50); const p = document.querySelector(".multi-panel"); if (p && !p.textContent.includes("counting")) break; if (p) b.click(); await sleep(200); }
  const panel = document.querySelector(".multi-panel"), labels = [...panel.querySelectorAll("label")].filter(l => l.children.length === 3);
  const values = labels.map(l => `${l.children[1].textContent}=${l.children[2].textContent}`);
  labels.find(l => l.children[1].textContent === "Mapi").querySelector("input").click();
  const chip = () => document.getElementById("server-chip");
  for (let i = 0; i < 300 && !(chip() && !chip().hidden && /rows \(narrowed/.test(document.getElementById("result-state").textContent)); i++) await sleep(100);
  await sleep(600);
  const b = document.querySelector("#tabs button.active");
  return { values, pill: b.querySelector(".mode").textContent, chip: chip() ? chip().textContent : null, result: document.getElementById("result-state").textContent,
    sortable: [...document.querySelectorAll("#grid-head div")].every(h => !h.classList.contains("nosort")), export: document.getElementById("export").disabled, hash: location.hash };
})()
'@
        @($result.values) -join ',' | Should -BeExactly 'Eas=3,000,Ews=3,000,Mapi=3,000,Owa=3,000'
        $result.pill | Should -BeExactly 'Loaded'
        $result.chip | Should -BeLike 'Server selection: Protocol in Mapi*'
        $result.result | Should -BeExactly '3,000 of 3,000 rows (narrowed on the server: Protocol in Mapi)'
        $result.sortable | Should -BeTrue
        $result.export | Should -BeFalse
        $result.hash | Should -Match 'm\.Protocol=Mapi'
        $back = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  document.querySelector("#server-chip button").click();
  for (let i = 0; i < 100 && !/^12,000 of 12,000 rows$/.test(document.getElementById("result-state").textContent); i++) await sleep(100);
  return { pill: document.querySelector("#tabs button.active .mode").textContent, result: document.getElementById("result-state").textContent, chip: document.getElementById("server-chip").hidden };
})()
'@
        $back.pill | Should -BeExactly 'Remote'
        $back.result | Should -BeExactly '12,000 of 12,000 rows'
        $back.chip | Should -BeTrue
    }

    It 'lists the authentication types of the sessions from the server, each with the count of the server' {
        Open-Remote 'tab=sessions' $script:Settled
        Wait-ExlJs $script:Edge '(() => { const h = [...document.querySelectorAll("#grid-head div")].map(x => x.textContent), c = document.querySelectorAll("#grid-filter > div")[h.indexOf("Authentication")]; return !!(c && c.querySelector(".multi-button")); })()' 120 | Should -BeTrue
        $values = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  for (let i = 0; i < 200; i++) { const b = document.querySelectorAll("#grid-filter > div")[heads.indexOf("Authentication")].querySelector(".multi-button"); b.click(); await sleep(50); const p = document.querySelector(".multi-panel"); if (p && !p.textContent.includes("counting")) break; if (p) b.click(); await sleep(200); }
  const labels = [...document.querySelector(".multi-panel").querySelectorAll("label")].filter(l => l.children.length === 3);
  const values = labels.map(l => [l.children[1].textContent, l.children[2].textContent]);
  return values;
})()
'@
        @($values | ForEach-Object { $_[0] } | Sort-Object) -join ',' | Should -BeExactly 'Basic,Forms,Negotiate,OAuth'
        foreach ($v in @($values)) { $v[1] | Should -BeExactly (Grouped (Remote-Count 'sessions' @{ 'm.Authentication' = $v[0] })) -Because $v[0] }
    }

    It 'counts a filter the server scans progressively, with Stop, and keeps the rows found' {
        # Chunks of one row: the 6,000 sessions of a day are 3,000 chunks, read in several times the budget of 100 ms (about 0.8 s on the
        # development computer, 0.5 s in chunks of four rows), so the newest day is counted in several answers and the page shows the matches
        # as they are counted.
        $chunk = $script:ChunkField.GetValue($null); $script:ChunkField.SetValue($null, 1)
        try {
            $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  const input = () => document.querySelectorAll("#grid-filter > div")[heads.indexOf("User")].querySelector("input");
  input().value = "user1"; input().dispatchEvent(new Event("input"));
  let progress = null;
  for (let i = 0; i < 500 && !progress; i++) { await sleep(20); const t = document.getElementById("result-state").textContent; if (/matches so far - searched \d+ of 2 days \(newest first\)/.test(t)) progress = t; }
  const stop = document.getElementById("scan-stop"), visible = !!stop && !stop.hidden;
  if (stop) stop.click();
  for (let i = 0; i < 100 && !/^Stopped/.test(document.getElementById("result-state").textContent); i++) await sleep(50);
  const stopped = document.getElementById("result-state").textContent;
  input().value = "user"; input().dispatchEvent(new Event("input"));
  for (let i = 0; i < 300 && !/^\d[\d,]* of 12,000 rows - User user$/.test(document.getElementById("result-state").textContent); i++) await sleep(100);
  return { progress, visible, stopped, final: document.getElementById("result-state").textContent, pill: document.querySelector("#tabs button.active .mode").textContent,
    caption: document.getElementById("tab-caption").textContent };
})()
'@
        } finally { $script:ChunkField.SetValue($null, $chunk) }
        $result.progress | Should -Not -BeNullOrEmpty -Because 'a scan of small chunks under a 100 ms budget answers in several parts'
        $result.visible | Should -BeTrue
        $result.stopped | Should -Match '^Stopped: [\d,]+ matches so far - searched \d of 2 days \(newest first\)$'
        $n = Grouped (Remote-Count 'sessions' @{ 'f.User' = 'user' })
        $result.final | Should -BeExactly "$n of 12,000 rows - User user"
        $result.pill | Should -BeExactly 'Remote'
        $result.caption | Should -Match "Browsing $([regex]::Escape($n)) of the 12,000 rows of the selection on the server - sorted by Start, (newest|oldest) first\." -Because 'the caption names the filtered count once it is final'
    }

    It 'applies a filter of the address while the value lists are still being counted, and waits for a busy server (<Days> days)' -ForEach @(@{ Days = 2 }, @{ Days = 31 }) {
        # A test script holds every value list request for 10 s, answers the first eight filtered counts 429 Busy with the server's text, and
        # records the result lines and the most filtered counts in flight at once.
        $hook = (Invoke-ExlCdp $script:Edge 'Page.addScriptToEvaluateOnNewDocument' @{ source = @'
(() => {
  if (location.protocol !== "http:" || sessionStorage.getItem("exl-test-busy") !== "hold") return;
  const real = window.fetch.bind(window), t = window.__exlBusyCounts = { busy: 0, flight: 0, most: 0, facets: 0, lines: [] };
  setInterval(() => { const e = document.getElementById("result-state"); if (e && e.textContent && t.lines[t.lines.length - 1] !== e.textContent) t.lines.push(e.textContent); }, 5);
  window.fetch = async (input, init) => {
    const url = String(typeof input === "string" ? input : input.url);
    if (/\/facets\?/.test(url)) { t.facets++; await new Promise(r => setTimeout(r, 10000)); return real(input, init); }
    if (!/\/count\?/.test(url) || !/[?&](m\.|f\.)/.test(url)) return real(input, init);
    t.flight++; t.most = Math.max(t.most, t.flight);
    try {
      if (t.busy++ < 8) { await new Promise(r => setTimeout(r, 50)); return new Response(JSON.stringify({ error: { code: "Busy", message: "Concurrency limit reached; retry explicitly." } }), { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "1" } }); }
      return await real(input, init);
    } finally { t.flight--; }
  };
})();
'@ }).identifier
        try {
            Open-ExlPage $script:Edge 'about:blank'
            Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
            Open-ExlPage $script:Edge "$($script:Remote.Url)/#token=$($script:Remote.Token)"
            Wait-ExlJs $script:Edge 'document.getElementById("day-bar")' 120 | Should -BeTrue
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.setItem("exl-test-busy", "hold"); return true; })()')
            Open-ExlPage $script:Edge "$($script:Remote.Url)/#day=2026-10-14&days=$Days&tab=sessions&m.Protocol=Mapi"
            Wait-ExlJs $script:Edge 'window.__exlBusyCounts && document.getElementById("server-chip") && !document.getElementById("server-chip").hidden && /narrowed on the server/.test(document.getElementById("result-state").textContent)' 120 | Should -BeTrue
            $state = Invoke-ExlJs $script:Edge '({ lines: __exlBusyCounts.lines, most: __exlBusyCounts.most, busy: __exlBusyCounts.busy, facets: __exlBusyCounts.facets, result: document.getElementById("result-state").textContent, pill: document.querySelector("#tabs button.active .mode").textContent })'
            $state.result | Should -BeExactly '3,000 of 3,000 rows (narrowed on the server: Protocol in Mapi)'
            $state.pill | Should -BeExactly 'Loaded'
            $state.busy | Should -BeGreaterThan 8 -Because 'every busy answer was retried'
            $state.facets | Should -BeGreaterThan 0 -Because 'the value lists were still being counted'
            $state.most | Should -BeLessOrEqual 2 -Because 'the days are counted two at a time'
            @($state.lines) | Should -Contain 'Waiting for the server: other requests are in progress...'
            @($state.lines | Where-Object { $_ -match 'Concurrency limit|retry explicitly|busy with other requests' }) | Should -BeNullOrEmpty
        } finally {
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.removeItem("exl-test-busy"); return true; })()')
            [void](Invoke-ExlCdp $script:Edge 'Page.removeScriptToEvaluateOnNewDocument' @{ identifier = $hook })
        }
    }

    It 'counts a contains filter typed while the value lists are still being counted, through busy answers' {
        $hook = (Invoke-ExlCdp $script:Edge 'Page.addScriptToEvaluateOnNewDocument' @{ source = @'
(() => {
  if (location.protocol !== "http:" || sessionStorage.getItem("exl-test-busy") !== "hold") return;
  const real = window.fetch.bind(window), t = window.__exlBusyCounts = { busy: 0, facets: 0, lines: [] };
  setInterval(() => { const e = document.getElementById("result-state"); if (e && e.textContent && t.lines[t.lines.length - 1] !== e.textContent) t.lines.push(e.textContent); }, 5);
  window.fetch = async (input, init) => {
    const url = String(typeof input === "string" ? input : input.url);
    if (/\/facets\?/.test(url)) { t.facets++; await new Promise(r => setTimeout(r, 10000)); return real(input, init); }
    if (/\/count\?/.test(url) && /[?&]f\.User=/.test(url) && t.busy++ < 6)
      return new Response(JSON.stringify({ error: { code: "Busy", message: "Concurrency limit reached; retry explicitly." } }), { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "1" } });
    return real(input, init);
  };
})();
'@ }).identifier
        try {
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.setItem("exl-test-busy", "hold"); return true; })()')
            Open-Remote 'tab=sessions' 'window.__exlBusyCounts && window.__exlStats && __exlStats.seq > 0'
            $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  const input = () => document.querySelectorAll("#grid-filter > div")[heads.indexOf("User")].querySelector("input");
  const typedEarly = __exlBusyCounts.facets > 0;
  input().value = "user1"; input().dispatchEvent(new Event("input"));
  for (let i = 0; i < 600 && !/narrowed on the server/.test(document.getElementById("result-state").textContent); i++) await sleep(100);
  return { typedEarly, lines: __exlBusyCounts.lines, busy: __exlBusyCounts.busy, result: document.getElementById("result-state").textContent };
})()
'@
            $result.typedEarly | Should -BeTrue -Because 'the value lists were still being counted'
            $n = Grouped (Remote-Count 'sessions' @{ 'f.User' = 'user1' })
            $result.result | Should -BeExactly "$n of $n rows (narrowed on the server: User user1)"
            $result.busy | Should -BeGreaterThan 6
            @($result.lines) | Should -Contain 'Waiting for the server: other requests are in progress...'
            @($result.lines | Where-Object { $_ -match 'Concurrency limit|retry explicitly|busy with other requests' }) | Should -BeNullOrEmpty
        } finally {
            [void](Invoke-ExlJs $script:Edge '(() => { sessionStorage.removeItem("exl-test-busy"); return true; })()')
            [void](Invoke-ExlCdp $script:Edge 'Page.removeScriptToEvaluateOnNewDocument' @{ identifier = $hook })
        }
    }

    It 'keeps the last of three values typed in a row: the selection of an earlier one is not loaded' {
        Open-Remote 'tab=sessions' $script:Settled
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  const input = () => document.querySelectorAll("#grid-filter > div")[heads.indexOf("User")].querySelector("input");
  for (const v of ["user1", "user12", "user"]) { input().value = v; input().dispatchEvent(new Event("input")); await sleep(300); }
  for (let i = 0; i < 600 && !/^[\d,]+ of 12,000 rows - User user$/.test(document.getElementById("result-state").textContent); i++) await sleep(100);
  await sleep(1500);
  return { result: document.getElementById("result-state").textContent, pill: document.querySelector("#tabs button.active .mode").textContent, box: input().value, chip: document.getElementById("server-chip").hidden };
})()
'@
        $result.result | Should -BeExactly "$(Grouped (Remote-Count 'sessions' @{ 'f.User' = 'user' })) of 12,000 rows - User user"
        $result.pill | Should -BeExactly 'Remote'
        $result.box | Should -BeExactly 'user'
        $result.chip | Should -BeTrue
    }

    It 'gives every filter case the count of the server, in both modes (<Name>)' -ForEach @(
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Serve.FilterCases.json') -Raw | ConvertFrom-Json -AsHashtable).cases | ForEach-Object { @{ Name = "$($_.view) $(($_.params.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"; Case = $_ } }) {
        # The address of the filters: the values of a list as the page keeps them; a box expression as a field of the search (a column the page shows
        # as a list of values has no box: the search takes the same expression).
        $hash = "tab=$($Case.view)"; $search = @()
        foreach ($kv in $Case.params.GetEnumerator()) {
            if ($kv.Key.StartsWith('m.')) { foreach ($v in ([string]$kv.Value).Split('|')) { $hash += '&' + [Uri]::EscapeDataString($kv.Key) + '=' + [Uri]::EscapeDataString($v) } }
            elseif ($kv.Key.StartsWith('f.')) { $search += (($kv.Key.Substring(2).ToLowerInvariant() -replace '[^a-z0-9]', '') + ':"' + $kv.Value + '"') }
            elseif ($kv.Key -eq 'q') { $search += [string]$kv.Value }
            else { $hash += '&' + [Uri]::EscapeDataString($kv.Key) + '=' + [Uri]::EscapeDataString([string]$kv.Value) }
        }
        if ($search) { $hash += '&q=' + [Uri]::EscapeDataString($search -join ' ') }
        Open-Remote $hash $script:Settled
        $text = Invoke-ExlJs $script:Edge 'document.getElementById("result-state").textContent'
        $shown = [long](([regex]::Match($text, '^([\d,]+) of ')).Groups[1].Value -replace ',', '')
        $shown | Should -Be (Remote-Count $Case.view $Case.params) -Because $text
    }

    It 'opens a row with the detail dialog of the static report, and the same row again from its address by id' {
        Open-Remote 'tab=sessions' $script:Settled
        $first = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  document.querySelector("#spacer .grid-row").click();
  for (let i = 0; i < 100 && !(dialog.open && /open=\d+/.test(location.hash) && document.querySelector("#detail-body dl")); i++) await sleep(100);
  const r = { title: document.getElementById("detail-title").textContent, fields: [...document.querySelectorAll("#detail-body dl dt")].map(x => x.textContent), href: location.href };
  dialog.close(); return r;
})()
'@
        $first.fields | Should -Contain 'Outcome'
        $first.href | Should -Match 'open=\d+'
        Open-ExlPage $script:Edge 'about:blank'
        Wait-ExlJs $script:Edge 'location.href === "about:blank"' 30 | Should -BeTrue
        Open-ExlPage $script:Edge $first.href
        Wait-ExlJs $script:Edge 'document.getElementById("detail") && document.getElementById("detail").open && document.querySelector("#detail-body dl")' 120 | Should -BeTrue
        (Invoke-ExlJs $script:Edge 'document.getElementById("detail-title").textContent') | Should -BeExactly $first.title
        [void](Invoke-ExlJs $script:Edge '(() => { document.getElementById("detail").close(); return true; })()')
    }

    It 'lists the client sessions of a user from the server when the sessions are browsed there' {
        Open-Remote 'tab=users' ($script:Settled + ' && __exlTiming.ready.sessions')
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), dialog = document.getElementById("detail");
  [...document.querySelectorAll("#spacer .grid-row")].find(r => r.children[0].textContent === "user3").click();
  for (let i = 0; i < 200 && !(dialog.open && [...document.querySelectorAll("#detail-body h3")].some(h => /^Client sessions \(/.test(h.textContent))); i++) await sleep(100);
  const h = [...document.querySelectorAll("#detail-body h3")].find(x => /^Client sessions/.test(x.textContent));
  return { heading: h ? h.textContent : null, rows: h ? h.nextElementSibling.querySelectorAll("tr").length - 1 : -1 };
})()
'@
        $result.heading | Should -BeExactly "Client sessions (first 200 of $(Grouped (Remote-Count 'sessions' @{ 'm.User' = 'user3' })), newest first)"
        $result.rows | Should -Be 200
        [void](Invoke-ExlJs $script:Edge '(() => { document.getElementById("detail").close(); return true; })()')
    }

    It 'loads a list of at most ClientRowsMax rows in the page (Loaded), with the export of the rows shown' {
        Open-Remote 'tab=issues' $script:Settled
        $state = Invoke-ExlJs $script:Edge '({ pill: document.querySelector("#tabs button.active .mode").textContent, result: document.getElementById("result-state").textContent, export: document.getElementById("export").disabled, nosort: !!document.querySelector("#grid-head div.nosort") })'
        $state.pill | Should -BeExactly 'Loaded'
        $state.result | Should -Match '^2,450 of 2,450 rows'
        $state.export | Should -BeFalse
        $state.nosort | Should -BeFalse
    }

    It 'exports every row of a list browsed on the server through a single-use ticket, with the filters of the list' {
        $folder = Join-Path $script:RemoteWork 'downloads-remote'
        Set-Downloads $folder
        Open-Remote 'tab=sessions' $script:Settled
        Clear-ExlRequests $script:Edge
        $name = 'sessions-2026-10-13-2026-10-14.csv'
        $heads = Invoke-ExlJs $script:Edge '(() => { document.getElementById("export").click(); return [...document.querySelectorAll("#grid-head div")].map(h => h.textContent); })()'
        $file = Wait-Download $folder $name
        $bytes = [IO.File]::ReadAllBytes($file)
        @($bytes[0..2]) -join ',' | Should -BeExactly '239,187,191'
        $lines = [Text.Encoding]::UTF8.GetString($bytes).Substring(1) -split "`r`n"
        $lines[-1] | Should -BeExactly ''
        $lines.Count - 2 | Should -Be 12000
        $lines[0] | Should -BeExactly (@($heads) -join ';')
        # The download address holds the ticket alone: no token, no filter.
        @(Get-ExlRequests $script:Edge | Where-Object { $_ -match '/api/export/ticket$' }).Count | Should -Be 1
        $download = @($script:Edge.Events | Where-Object { $_.method -eq 'Browser.downloadWillBegin' } | ForEach-Object { $_.params.url })
        $download.Count | Should -Be 1
        $download[0] | Should -Match '^http://127\.0\.0\.1:\d+/api/export/[0-9a-f]{64}\.csv$'
        (Invoke-WebRequest -Uri $download[0] -SkipHttpErrorCheck).StatusCode | Should -Be 404 -Because 'a ticket is used once'
        # A filter of the list that keeps it on the server: the export holds the rows the server counts for it.
        Remove-Item -LiteralPath $file
        $result = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), heads = [...document.querySelectorAll("#grid-head div")].map(h => h.textContent);
  const input = document.querySelectorAll("#grid-filter > div")[heads.indexOf("User")].querySelector("input");
  input.value = "!user12"; input.dispatchEvent(new Event("input"));
  for (let i = 0; i < 600 && !/^[\d,]+ of 12,000 rows - User !user12$/.test(document.getElementById("result-state").textContent); i++) await sleep(100);
  document.getElementById("export").click();
  return { result: document.getElementById("result-state").textContent, pill: document.querySelector("#tabs button.active .mode").textContent };
})()
'@
        $result.pill | Should -BeExactly 'Remote'
        $n = Remote-Count 'sessions' @{ 'f.User' = '!user12' }
        $result.result | Should -BeExactly "$(Grouped $n) of 12,000 rows - User !user12"
        $lines = [IO.File]::ReadAllText((Wait-Download $folder $name), [Text.Encoding]::UTF8) -split "`r`n"
        $lines.Count - 2 | Should -Be $n
        @($lines[1..($lines.Count - 2)] | Where-Object { ($_ -split ';')[4] -match 'user12' }).Count | Should -Be 0
    }

    # The fixture is in UTC and no two of its rows share a millisecond: the files are equal byte for byte. The lines are always the same; their order
    # differs inside the repeated hour of a daylight-saving change (the page sorts by the time it shows, the server by instant) and, in an
    # ascending sort, for rows of the same millisecond (the page keeps the newest id first, the server the oldest).
    It 'writes from the server the same bytes as the export of the rows the page holds (<Name>)' -ForEach @(
        @{ Name = 'failed requests'; Hash = 'tab=issues'; Query = ''; View = 'issues'; Ready = $null; Sort = $null },
        @{ Name = 'failed requests, search protocol:owa'; Hash = 'tab=issues&q=protocol%3Aowa'; Query = '&q=protocol%3Aowa'; View = 'issues'; Ready = $null; Sort = $null },
        @{ Name = 'messages narrowed on the server, sorted by Last event'; Hash = 'tab=messages&m.Status=Partially%20failed'; Query = '&m.Status=Partially%20failed'; View = 'messages'; Ready = 'narrowed on the server'; Sort = 'Last event' }) {
        $folder = Join-Path $script:RemoteWork 'downloads-both'
        Set-Downloads $folder
        $ready = if ($Ready) { "$script:Settled && /$Ready/.test(document.getElementById('result-state').textContent)" } else { $script:Settled }
        Open-Remote $Hash $ready
        $state = Invoke-ExlJs $script:Edge @"
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), sort = $(if ($Sort) { "'$Sort'" } else { 'null' });
  if (sort) { const before = __exlStats.seq; [...document.querySelectorAll('#grid-head div')].find(h => h.textContent === sort).click(); for (let i = 0; i < 100 && __exlStats.seq === before; i++) await sleep(100); }
  const b = document.querySelector('#tabs button.active');
  document.getElementById('export').click();
  return { pill: b.querySelector('.mode').textContent, result: document.getElementById('result-state').textContent };
})()
"@
        $state.pill | Should -BeExactly 'Loaded'
        $client = [IO.File]::ReadAllBytes((Wait-Download $folder "$View-view.csv"))
        $server = Ticket-Export $View $Query
        $client.Length | Should -BeGreaterThan 1000 -Because $state.result
        $server.Length | Should -Be $client.Length
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($server)) | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($client)))
    }

    It 'shows the reason of the server when it issues no export ticket, at once' {
        # Sixteen tickets wait to be downloaded (tickets of an export without rows): the server issues no other one until a download.
        $none = 'from=2026-10-13T00%3A00%3A00Z&to=2026-10-15T00%3A00%3A00Z&f.Protocol=zzzz'
        $waiting = @(foreach ($i in 1..16) {
            ((Invoke-WebRequest -Uri "$($script:Remote.Url)/api/export/ticket" -Method Post -Headers @{ 'X-Portal-Token' = $script:Remote.Token } -ContentType 'application/json' `
                -Body (@{ view = 'issues'; query = $none } | ConvertTo-Json -Compress)).Content | ConvertFrom-Json).url })
        try {
            Open-Remote 'tab=sessions' $script:Settled
            Clear-ExlRequests $script:Edge
            $state = Invoke-ExlJs $script:Edge @'
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), began = performance.now();
  document.getElementById("export").click();
  for (let i = 0; i < 100 && !/^The export could not start/.test(document.getElementById("result-state").textContent); i++) await sleep(50);
  return { result: document.getElementById("result-state").textContent, ms: performance.now() - began };
})()
'@
            $state.result | Should -BeExactly 'The export could not start: 16 exports are waiting to be downloaded: export the view again in a minute.'
            $state.ms | Should -BeLessThan 900 -Because 'the page does not retry a ticket refused for this reason'
            @(Get-ExlRequests $script:Edge | Where-Object { $_ -match '/api/export/ticket$' }).Count | Should -Be 1
        } finally {
            foreach ($url in $waiting) { Invoke-WebRequest -Uri ($script:Remote.Url + $url) -SkipHttpErrorCheck | Out-Null }
        }
    }

    It 'waits for the server while it holds its aggregate workers, beyond three busy answers, and then loads' {
        # A test script answers the overview 429 Busy the first five times.
        $hook = (Invoke-ExlCdp $script:Edge 'Page.addScriptToEvaluateOnNewDocument' @{ source = @'
(() => {
  if (location.protocol !== "http:") return;
  const real = window.fetch.bind(window), t = window.__exlBusy = { calls: 0, waiting: null };
  const watch = setInterval(() => {
    for (const id of ["progress-text", "loading-text"]) { const e = document.getElementById(id); if (e && /^Waiting for the server/.test(e.textContent)) t.waiting = e.textContent; }
    if (t.calls > 5) clearInterval(watch);
  }, 5);
  window.fetch = async (input, init) => {
    if (String(typeof input === "string" ? input : input.url).startsWith("/api/overview/servers") && t.calls++ < 5) {
      return new Response(JSON.stringify({ error: { code: "Busy", message: "Aggregate requests are at their concurrency limit; retry explicitly." } }), { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "1" } });
    }
    return real(input, init);
  };
})();
'@ }).identifier
        Open-Remote 'tab=issues' 'window.__exlBusy && document.querySelectorAll("#cards .card").length > 0'
        $state = Invoke-ExlJs $script:Edge '({ calls: __exlBusy.calls, waiting: __exlBusy.waiting, retry: document.querySelectorAll(".retry").length })'
        $state.calls | Should -Be 6
        $state.waiting | Should -BeExactly 'Waiting for the server: other requests are in progress...'
        $state.retry | Should -Be 0
        [void](Invoke-ExlCdp $script:Edge 'Page.removeScriptToEvaluateOnNewDocument' @{ identifier = $hook })
    }

    It 'leaves the store unchanged' {
        $script:Remote.Task.IsCompleted | Should -BeFalse
        Invoke-WebRequest -Uri "$($script:Remote.Url)/api/shutdown" -Method Post -Headers @{ 'X-Portal-Token' = $script:Remote.Token } -SkipHttpErrorCheck | Out-Null
        $script:Remote.Task.Wait(15000) | Should -BeTrue
        (Get-FileHash -LiteralPath $script:RemoteDb).Hash | Should -Be $script:RemoteHash
    }
}
