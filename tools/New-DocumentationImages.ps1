#Requires -Version 7.4
<#
.SYNOPSIS
    Renders the graphics of the GitHub README (docs\images\readme-*.png) from the administrator guide.

.DESCRIPTION
    GitHub renders Markdown only: the custom blocks of the guide (cards, flow) and its theme are lost.
    This tool renders them as images, with the CSS of the built HTML guide and the icons of
    tools\Build-Documentation.ps1, in a light and a dark version (2x resolution), so that the README
    and the guide always look the same. The README chooses the version with <picture>.

        readme-banner     the hero of the guide, with three key figures
        readme-why        the two questions (cards block "Usage" / "Troubleshooting", chapter 1)
        readme-how        the collection pipeline (first flow block, chapter 2) and the two reports
        readme-noise      what is removed before storage (cards block of chapter 3) and the lab figures
        readme-sessions   client session and message correlation (flow blocks of chapter 11)

    The screenshots (report-*.png and console-*.png for the guide, readme-report-*.png and
    readme-console-report.png for the README, cropped at 2x) are not produced here: they are taken
    from a real report and a real console run on a lab, with anonymised names.

.PARAMETER OutputFolder
    Default: docs\images next to the tools folder.

.PARAMETER KeepWork
    Keeps the work folder (HTML pages of the graphics) and shows its path.

.EXAMPLE
    .\tools\Build-Documentation.ps1 ; .\tools\New-DocumentationImages.ps1
    The guide is built first: its HTML holds the CSS of the graphics.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.4.0
    Part of : Exchange Log Report (repository tool, not in the package)
#>
[CmdletBinding()]
param(
    [string]$OutputFolder,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputFolder) { $OutputFolder = Join-Path $root 'docs\images' }
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found: it takes the screenshots (headless mode).' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('elr-doc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work, $OutputFolder -Force | Out-Null

#region Guide assets ---------------------------------------------------------------------------------
function ConvertTo-ReadmeInline([string]$Text) {
    # Inline Markdown of a guide block (code, bold, italic) -> HTML.
    $h = [Net.WebUtility]::HtmlEncode($Text.Trim())
    $h = [regex]::Replace($h, '`([^`]+)`', '<code>$1</code>')
    $h = [regex]::Replace($h, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    return [regex]::Replace($h, '(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])', '<em>$1</em>')
}

function Get-ReadmeAssets {
    $builder = Join-Path $root 'tools\Build-Documentation.ps1'
    $guideHtml = Join-Path $root 'docs\ExchangeLogReport-Guide.html'
    $guideMd = Join-Path $root 'docs\ExchangeLogReport-Guide.md'
    if (-not (Test-Path $guideHtml)) { throw 'docs\ExchangeLogReport-Guide.html not found: run tools\Build-Documentation.ps1 first (it holds the CSS of the graphics).' }
    # Icons: the $Icons table of the documentation builder, read without running the builder.
    $ast = [Management.Automation.Language.Parser]::ParseFile($builder, [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Icons' }, $true)
    if (-not $assign) { throw "Icon table not found in $builder." }
    $md = [IO.File]::ReadAllText($guideMd) -replace "`r`n", "`n"
    $blocks = foreach ($m in [regex]::Matches($md, '(?s)```(flow|cards)\n(.*?)\n```')) {
        $lines = @($m.Groups[2].Value -split "`n" | Where-Object { $_.Trim() })
        [pscustomobject]@{ Kind = $m.Groups[1].Value; Lines = $lines; First = $lines[0].Split('|')[1].Trim() }
    }
    [pscustomobject]@{
        Icons   = & ([scriptblock]::Create($assign.Right.Extent.Text))
        Css     = [regex]::Match([IO.File]::ReadAllText($guideHtml), '(?s)<style>(.*?)</style>').Groups[1].Value
        Version = [regex]::Match($md, '(?m)^version:\s*(\S+)').Groups[1].Value
        Blocks  = @($blocks)
    }
}

function Get-GuideBlock([string]$Kind, [string]$FirstTitle) {
    # A cards or flow block of the guide, found by the title of its first item.
    $block = $assets.Blocks | Where-Object { $_.Kind -eq $Kind -and $_.First -eq $FirstTitle } | Select-Object -First 1
    if (-not $block) { throw "Guide block not found: $Kind starting with '$FirstTitle' (docs\ExchangeLogReport-Guide.md)." }
    return $block.Lines
}

function Get-ReadmeIcon([string]$Name, [string]$Class = 'icon') {
    $path = $assets.Icons[$Name]; if (-not $path) { $path = $assets.Icons['info'] }
    "<svg class=""$Class"" viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.7"" stroke-linecap=""round"" stroke-linejoin=""round"">$path</svg>"
}

function ConvertTo-ReadmeFlow([string[]]$Lines, [switch]$Vertical) {
    # Vertical: the nodes are stacked, icon on the left, with a downward arrow and its label.
    $items = foreach ($l in $Lines) {
        $icon, $title, $sub = $l.Split('|', 3).ForEach({ $_.Trim() })
        $title = [Net.WebUtility]::HtmlEncode($title); $sub = [Net.WebUtility]::HtmlEncode($sub)
        if ($Vertical) {
            if ($icon -eq 'arrow') {
                $note = if ($sub) { "<span class=""flow-sub"">$sub</span>" } else { '' }
                "<div class=""rb-varrow""><svg viewBox=""0 0 12 30""><path d=""M6 1v26M1 21l5 6 5-6"" fill=""none"" stroke=""currentColor"" stroke-width=""1.6""/></svg><span class=""flow-label"">$title</span>$note</div>"
            } else {
                "<div class=""rb-vnode""><div class=""flow-icon"">$(Get-ReadmeIcon $icon)</div><div><div class=""flow-title"">$title</div><div class=""flow-text"">$sub</div></div></div>"
            }
        } elseif ($icon -eq 'arrow') {
            "<div class=""flow-arrow""><span class=""flow-label"">$title</span><svg viewBox=""0 0 40 12""><path d=""M0 6h36M31 1l6 5-6 5"" fill=""none"" stroke=""currentColor"" stroke-width=""1.6""/></svg><span class=""flow-sub"">$sub</span></div>"
        } else {
            "<div class=""flow-node""><div class=""flow-icon"">$(Get-ReadmeIcon $icon)</div><div class=""flow-title"">$title</div><div class=""flow-text"">$sub</div></div>"
        }
    }
    $class = if ($Vertical) { 'flow rb-vflow' } else { 'flow rb-flow' }
    "<div class=""$class"">$($items -join '')</div>"
}

function ConvertTo-ReadmeCards([string[]]$Lines, [string]$Class = '') {
    $items = foreach ($l in $Lines) {
        $icon, $title, $text = $l.Split('|', 3).ForEach({ $_.Trim() })
        "<div class=""card-item""><div class=""card-icon"">$(Get-ReadmeIcon $icon)</div><div><div class=""card-title"">$(ConvertTo-ReadmeInline $title)</div><div class=""card-text"">$(ConvertTo-ReadmeInline $text)</div></div></div>"
    }
    "<div class=""cards $Class"">$($items -join '')</div>"
}

function Get-ReadmePill([string]$Text, [string]$Tone) { "<span class=""rb-pill"" style=""--tone: var(--cp-$Tone)"">$Text</span>" }
#endregion

#region Graphics ---------------------------------------------------------------------------------------
$Script:ReadmeCss = @'
html, body { background: #ffffff; }
html[data-theme="dark"], html[data-theme="dark"] body { background: #0d1117; }
:root { --cp-info: #0078d4; --cp-violet: #7c3aed; --cp-teal: #0d9488; }
html[data-theme="dark"] { --cp-info: #4da6ff; --cp-violet: #a78bfa; --cp-teal: #2dd4bf; }
body { display: block; margin: 0; padding: 0; }
.canvas { padding: 6px; }
.rb-pill { display: inline-block; padding: 1px 10px; margin: 8px 6px 0 0; border-radius: 999px; font-size: 11.5px; font-weight: 600; line-height: 1.6;
  color: var(--tone); background: color-mix(in srgb, var(--tone) 11%, transparent); border: 1px solid color-mix(in srgb, var(--tone) 38%, transparent); }
.rb-caption { font-size: 11.5px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--cp-accent); margin: 0 0 8px 4px; }
.rb-caption span { color: var(--cp-text-muted); font-weight: 600; letter-spacing: 0.04em; text-transform: none; font-size: 12.5px; }
/* Banner */
.rb-hero { margin: 0; padding: 32px 36px 30px; }
.rb-hero-grid { position: relative; display: grid; grid-template-columns: minmax(0, 1fr) 250px; gap: 34px; align-items: center; }
.rb-hero h1 { font-size: 35px; }
.rb-hero .lead { margin: 18px 0 0; font-size: 17px; max-width: none; }
.rb-hero .badges { margin: 20px 0 0; }
.rb-stats { position: relative; display: grid; gap: 10px; }
.rb-stat { display: flex; align-items: center; gap: 14px; padding: 12px 16px; border-radius: 14px; background: var(--cp-panel-strong); border: 1px solid var(--cp-border); box-shadow: 0 1px 2px rgba(0, 0, 0, 0.08); }
.rb-stat b { font-size: 28px; line-height: 1; color: var(--cp-accent); font-weight: 750; min-width: 64px; text-align: center; }
.rb-stat span { font-size: 13px; color: var(--cp-text-muted); line-height: 1.35; }
.rb-stat strong { display: block; color: var(--cp-text); font-size: 14px; }
.rb-statrow { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
.rb-statrow .rb-stat { flex-direction: column; align-items: flex-start; gap: 6px; background: var(--cp-surface); }
.rb-statrow .rb-stat b { min-width: 0; text-align: left; }
/* Cards and flows */
.cards { margin: 0; }
.rb-cards2 { grid-template-columns: 1fr 1fr; }
.rb-flow { margin: 0; flex-wrap: nowrap; padding: 18px; gap: 4px; }
.rb-flow .flow-node { flex: 1 1 0; min-width: 0; padding: 14px 10px; }
.rb-flow .flow-title { font-size: 13.5px; overflow-wrap: anywhere; }
.rb-flow .flow-arrow { min-width: 0; width: 92px; flex: 0 0 92px; }
.rb-flow .flow-sub { max-width: 92px; }
.rb-space { height: 18px; }
/* How it works: vertical pipeline and the two reports */
.rb-hiw { display: grid; grid-template-columns: minmax(0, 1.08fr) minmax(0, 1fr); gap: 16px; align-items: stretch; }
.rb-col { display: flex; flex-direction: column; }
.rb-vflow { flex: 1; flex-direction: column; flex-wrap: nowrap; align-items: stretch; justify-content: center; gap: 0; margin: 0; padding: 16px 18px; }
.rb-vnode { display: flex; align-items: center; gap: 14px; padding: 11px 16px; border-radius: 12px; background: var(--cp-surface); border: 1px solid var(--cp-border); }
.rb-vnode .flow-icon { margin: 0; flex-shrink: 0; }
.rb-vnode .flow-text { margin-top: 1px; }
.rb-varrow { display: flex; align-items: center; gap: 10px; min-height: 36px; padding-left: 31px; }
.rb-varrow svg { width: 12px; height: 28px; color: var(--cp-accent); flex-shrink: 0; }
.rb-varrow .flow-sub { max-width: none; font-size: 12px; }
.rb-modes { flex: 1; display: flex; flex-direction: column; gap: 10px; }
.rb-modes .card-item { flex: 1; align-items: center; }
.rb-modes .card-title { display: flex; align-items: center; gap: 8px; }
.rb-chip { font-size: 11px; font-weight: 600; padding: 0 8px; border-radius: 999px; border: 1px solid var(--cp-border); color: var(--cp-text-muted); }
.rb-chip.hot { color: var(--cp-accent-fg); background: var(--cp-accent); border-color: var(--cp-accent); }
'@

function Save-Screenshot([string]$Html, [string]$Png, [int]$Width, [int]$Height, [int]$Scale = 1) {
    $url = 'file:///' + ($Html -replace '\\', '/')
    $profile = Join-Path $work 'edge-profile'
    if (Test-Path $Png) { Remove-Item $Png -Force }
    # Start-Process, not &: an Edge helper process can keep the output pipe open after the capture.
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=`"$profile`"", "--window-size=$Width,$Height", "--force-device-scale-factor=$Scale", "--screenshot=`"$Png`"", "`"$url`"")
    $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(45)
    while (-not (Test-Path $Png) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (-not $proc.WaitForExit(10000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $Png)) { throw "Screenshot not written: $Png" }
}

function Get-PageHeight([string]$Html, [int]$Width) {
    # Height of the .canvas element: the page writes it in body[data-h], read with --dump-dom.
    $url = 'file:///' + ($Html -replace '\\', '/')
    $dom = Join-Path $work ('dom-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.html')
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=`"$(Join-Path $work 'edge-profile')`"", "--window-size=$Width,2000", '--dump-dom', "`"$url`"")
    $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
    if (-not $proc.WaitForExit(45000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    # Edge helper processes inherit the output handle: read in shared mode, retry until written.
    $m = $null
    for ($i = 0; $i -lt 20 -and -not ($m -and $m.Success); $i++) {
        $stream = [IO.File]::Open($dom, 'Open', 'Read', 'ReadWrite')
        try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
        $m = [regex]::Match($text, 'data-h="(\d+)"')
        if (-not $m.Success) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $m.Success) { throw "Height not measured: $Html" }
    return [int]$m.Groups[1].Value
}

function New-ReadmeGraphic {
    # One graphic, light and dark: HTML page -> height measured by Edge -> 2x screenshot.
    param([string]$Name, [string]$Body, [int]$Width = 1080)
    $pages = @{}
    foreach ($theme in 'light', 'dark') {
        $html = "<!doctype html><html lang=""en"" data-theme=""$theme""><head><meta charset=""utf-8""><style>$($assets.Css)`n$($Script:ReadmeCss)</style></head>" +
            "<body><div class=""canvas"" style=""width:$($Width)px"">$Body</div><script>document.body.setAttribute('data-h', Math.ceil(document.querySelector('.canvas').getBoundingClientRect().height));</script></body></html>"
        $pages[$theme] = Join-Path $work "readme-$Name-$theme.html"
        [IO.File]::WriteAllText($pages[$theme], $html, [Text.UTF8Encoding]::new($false))
    }
    $height = Get-PageHeight $pages['light'] $Width
    foreach ($theme in 'light', 'dark') { Save-Screenshot $pages[$theme] (Join-Path $OutputFolder "readme-$Name-$theme.png") $Width $height 2 }
    Write-Host "  readme-$Name (light, dark)"
}

$Script:assets = Get-ReadmeAssets
$mid = '&middot;'
Write-Host 'Rendering the README graphics (light and dark, 2x)...'

# Banner: the hero of the guide, with three key figures (lab measurement of chapter 12).
$badges = @(
    "<span class=""badge badge-accent"">Version $($assets.Version)</span>"
    "<span class=""badge"">$(Get-ReadmeIcon 'terminal' 'icon-sm')PowerShell 7.4+</span>"
    "<span class=""badge"">$(Get-ReadmeIcon 'shield' 'icon-sm')Read-only for Exchange</span>"
    "<span class=""badge"">$(Get-ReadmeIcon 'tag' 'icon-sm')MIT license</span>"
) -join ''
$banner = "<header class=""hero rb-hero""><div class=""rb-hero-grid""><div>" +
    "<div class=""hero-top""><div class=""hero-logo"">$(Get-ReadmeIcon 'server')</div><div><div class=""eyebrow"">Exchange Server SE $mid on-premises</div><h1>Exchange Log Report</h1></div></div>" +
    "<p class=""lead"">A modern <strong>Log Parser</strong>: reads the IIS, HTTP Proxy, MAPI, ActiveSync, POP/IMAP, SMTP and tracking logs of <strong>every server</strong>, removes the noise <strong>before</strong> storage, and answers <strong>is this server really used?</strong> and <strong>what happened to this user or this message?</strong></p>" +
    "<div class=""badges"">$badges</div></div>" +
    "<div class=""rb-stats"">" +
    "<div class=""rb-stat""><b>7</b><span><strong>log sources</strong>read incrementally</span></div>" +
    "<div class=""rb-stat""><b>99.9%</b><span><strong>noise removed</strong>before storage (lab)</span></div>" +
    "<div class=""rb-stat""><b>2</b><span><strong>reports</strong>usage, troubleshooting</span></div>" +
    "</div></div></header>"
New-ReadmeGraphic -Name 'banner' -Body $banner

# Why: the two questions of chapter 1.
New-ReadmeGraphic -Name 'why' -Body (ConvertTo-ReadmeCards (Get-GuideBlock 'cards' 'Usage') 'rb-cards2')

# How it works: the pipeline of chapter 2 (vertical) and the two reports.
$reports = @(
    [pscustomobject]@{ Icon = 'chart'; Name = 'Usage'; Chip = '<span class="rb-chip">summary</span>'; Text = 'Which servers are really used, by whom, with which clients and devices; operations, SMTP clients, mail flow.'; Pills = (Get-ReadmePill 'In use' 'success') + (Get-ReadmePill 'Client access only' 'warning') + (Get-ReadmePill 'No real usage' 'danger') }
    [pscustomobject]@{ Icon = 'search'; Name = 'Detailed'; Chip = '<span class="rb-chip hot">troubleshooting</span>'; Text = 'Client sessions with their timeline, failed and slow requests with their resolution, one row per message with its route.'; Pills = (Get-ReadmePill 'Recovered' 'success') + (Get-ReadmePill 'Slow' 'warning') + (Get-ReadmePill 'Unresolved' 'danger') }
    [pscustomobject]@{ Icon = 'people'; Name = 'One or more users'; Chip = '<span class="rb-chip">-User</span>'; Text = 'Every view filtered on the users of an incident: their sessions, devices, requests and messages.'; Pills = '' }
)
$reportHtml = ($reports | ForEach-Object { "<div class=""card-item""><div class=""card-icon"">$(Get-ReadmeIcon $_.Icon)</div><div><div class=""card-title"">$($_.Name) $($_.Chip)</div><div class=""card-text"">$($_.Text)</div><div>$($_.Pills)</div></div></div>" }) -join ''
$how = "<div class=""rb-hiw""><div class=""rb-col""><div class=""rb-caption"">One collection <span>$mid from the Exchange logs to the reports</span></div>$(ConvertTo-ReadmeFlow (Get-GuideBlock 'flow' 'Exchange servers') -Vertical)</div>" +
    "<div class=""rb-col""><div class=""rb-caption"">Two reports <span>$mid the same database, two questions</span></div><div class=""rb-modes"">$reportHtml</div></div></div>"
New-ReadmeGraphic -Name 'how' -Body $how

# Noise: the cards of chapter 3 and the lab figures of chapter 12.
$figures = @(
    [pscustomobject]@{ Value = '5.5 M'; Label = 'lines read'; Detail = '1.81 GB, 9,422 files' }
    [pscustomobject]@{ Value = '4,891'; Label = 'lines kept'; Detail = 'real users and messages' }
    [pscustomobject]@{ Value = '99.9%'; Label = 'noise removed'; Detail = 'counted by reason' }
    [pscustomobject]@{ Value = '18 MB'; Label = 'database'; Detail = '60 days of history' }
)
$figureHtml = ($figures | ForEach-Object { "<div class=""rb-stat""><b>$($_.Value)</b><span><strong>$($_.Label)</strong>$($_.Detail)</span></div>" }) -join ''
$noise = "<div class=""rb-caption"">Removed before storage <span>$mid counted by reason, never stored</span></div>" + (ConvertTo-ReadmeCards (Get-GuideBlock 'cards' 'System mailboxes') 'rb-cards2') +
    "<div class=""rb-space""></div><div class=""rb-caption"">Measured on a lab <span>$mid 4 servers, 60 days of logs</span></div><div class=""rb-statrow"">$figureHtml</div>"
New-ReadmeGraphic -Name 'noise' -Body $noise

# Sessions and messages: the two correlation flows of chapter 11.
$sessions = "<div class=""rb-caption"">Client session <span>$mid front end and back end in one timeline</span></div>" + (ConvertTo-ReadmeFlow (Get-GuideBlock 'flow' 'Front end')) +
    "<div class=""rb-space""></div><div class=""rb-caption"">Message <span>$mid one row per Message-ID, every server</span></div>" + (ConvertTo-ReadmeFlow (Get-GuideBlock 'flow' 'SMTP conversation'))
New-ReadmeGraphic -Name 'sessions' -Body $sessions
#endregion

Get-ChildItem $OutputFolder -Filter 'readme-*.png' | Select-Object Name, @{ n = 'KB'; e = { [math]::Round($_.Length / 1KB) } } | Format-Table -AutoSize | Out-String | Write-Host
# Edge helper processes of the temporary profile, if any are left.
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$work*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($KeepWork) { Write-Host "Work folder: $work" } else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
