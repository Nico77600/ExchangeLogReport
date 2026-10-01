#Requires -Version 7.4
<#
.SYNOPSIS
    Exchange Log Report - PowerShell module.

.DESCRIPTION
    Helper functions used by Invoke-ExchangeLogReport.ps1, organised in regions in the
    order of an execution:

        1. Console and log        Write-Exl* functions (what the administrator sees)
        2. Configuration          Import-ExlConfiguration (reads and checks the .psd1 file)
        3. Engine                 Initialize-ExlEngine (SQLite + compiled C# engine)
        4. Periods                Resolve-ExlPeriod
        5. Sources                Get-ExlSources (log folders of each Exchange server)
        6. Collection             Invoke-ExlCollection (log files -> SQLite)
        7. Report                 New-ExlReport (SQLite -> CSV / HTML)
        8. Status and maintenance Show-ExlStatus, Invoke-ExlRetention, Enter-ExlLock

    Reading and parsing the log files, the database and the report files are handled by
    the C# engine (src\Engine.*.cs), compiled on first use.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.3.1
    History : see CHANGELOG.md
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.3.1'
$script:ToolRoot = $PSScriptRoot
$script:LogWriter = $null
$script:LogPath = $null
# ---------------------------------------------------------------------------------------------
# Console theme (same rules as Purview DLP Report):
#   - ANSI colours are disabled when the output is redirected (scheduled task) or NO_COLOR is
#     set; EXL_FORCE_COLOR=1 forces them.
#   - Icons: emoji in Windows Terminal / VS Code, symbols of the classic console fonts elsewhere.
#     EXL_ICONS = Emoji | Symbols | Ascii forces a style.
# ---------------------------------------------------------------------------------------------
$script:C = @{ Reset = ''; Bold = ''; Dim = ''; Accent = ''; AccentBg = ''; Cyan = ''; Green = ''; Yellow = ''; Red = ''; White = '' }
if ($env:EXL_FORCE_COLOR -eq '1' -or (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR)) {
    $e = [char]27
    $script:C = @{
        Reset = "$e[0m"; Bold = "$e[1m"; Dim = "$e[90m"; White = "$e[97m"
        Accent = "$e[38;2;214;62;115m"; AccentBg = "$e[48;2;177;31;75m$e[97m"
        Cyan = "$e[38;2;97;214;214m"; Green = "$e[38;2;80;200;120m"; Yellow = "$e[38;2;240;200;90m"; Red = "$e[38;2;240;90;90m"
    }
}
$script:IconStyle = if ($env:EXL_ICONS -in 'Emoji', 'Symbols', 'Ascii') { $env:EXL_ICONS }
    elseif ([Console]::IsOutputRedirected) { 'Symbols' }
    elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') { 'Emoji' }
    else { 'Symbols' }

function Get-ExlIconSet {
    <# Icons of one console style. Symbols: only characters of the classic console fonts. #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    $u = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    switch ($Style) {
        'Emoji' { return @{
                Logo = & $u 0x1F4EC; Ok = & $u 0x2705; Warn = (& $u 0x26A0) + [char]0xFE0F; Fail = & $u 0x274C; Info = & $u 0x1F539; Skip = & $u 0x23E9
                Database = & $u 0x1F4BE; Plan = & $u 0x1F50E; Server = & $u 0x1F5A5; Download = & $u 0x1F4E5; Report = & $u 0x1F4CA; Calendar = & $u 0x1F4C5
                File = & $u 0x1F4C4; Folder = & $u 0x1F4C1; Clock = & $u 0x23F3; Mail = & $u 0x1F4E8; Target = & $u 0x1F3AF; Log = & $u 0x1F4DD
                Done = & $u 0x1F389; People = & $u 0x1F465; Chart = & $u 0x1F4C8; Broom = & $u 0x1F9F9; Filter = & $u 0x1F9F9
            } }
        'Symbols' { return @{
                Logo = & $u 0x2666; Ok = & $u 0x221A; Warn = & $u 0x25B2; Fail = & $u 0x00D7; Info = & $u 0x2022; Skip = & $u 0x00BB
                Database = & $u 0x25A0; Plan = & $u 0x25BA; Server = & $u 0x2261; Download = & $u 0x2193; Report = & $u 0x2261; Calendar = & $u 0x263C
                File = & $u 0x25AC; Folder = & $u 0x2302; Clock = & $u 0x25CB; Mail = '@'; Target = & $u 0x25D9; Log = & $u 0x00B6
                Done = & $u 0x221A; People = & $u 0x2192; Chart = & $u 0x2191; Broom = & $u 0x00F7; Filter = & $u 0x00F7
            } }
        default { return @{
                Logo = '*'; Ok = '+'; Warn = '!'; Fail = 'x'; Info = '-'; Skip = '>'; Database = '#'; Plan = '?'; Server = '='; Download = 'v'; Report = '='
                Calendar = ':'; File = '-'; Folder = '>'; Clock = '~'; Mail = '@'; Target = 'o'; Log = '='; Done = '*'; People = '&'; Chart = '^'; Broom = '/'; Filter = '/'
            } }
    }
}

function Get-ExlFrameSet {
    <# Frame characters: rounded corners, square with the fonts that lack them (Lucida Console, raster font). #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style, [AllowNull()][string]$FontName)
    if ($Style -eq 'Ascii') { return @{ TopLeft = [char]'+'; TopRight = [char]'+'; BottomLeft = [char]'+'; BottomRight = [char]'+'; Horizontal = [char]'-'; Vertical = [char]'|' } }
    if ($Style -eq 'Symbols' -and $FontName -in 'Lucida Console', 'Terminal') {
        return @{ TopLeft = [char]0x250C; TopRight = [char]0x2510; BottomLeft = [char]0x2514; BottomRight = [char]0x2518; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
    }
    return @{ TopLeft = [char]0x256D; TopRight = [char]0x256E; BottomLeft = [char]0x2570; BottomRight = [char]0x256F; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
}

function Get-ExlFrame {
    if ($script:Frame) { return $script:Frame }
    $engine = [bool]('ExchangeLogReport.ConsoleFont' -as [type])
    $font = if ($script:IconStyle -eq 'Symbols' -and $engine) { [ExchangeLogReport.ConsoleFont]::FaceName() }
    $frame = Get-ExlFrameSet $script:IconStyle $font
    if ($script:IconStyle -ne 'Symbols' -or $engine) { $script:Frame = $frame }
    return $frame
}

$script:Icons = Get-ExlIconSet $script:IconStyle
$script:Frame = $null
$script:IconPad = if ($script:IconStyle -eq 'Emoji') { ' ' } else { '  ' }

#region 1. Console and log ---------------------------------------------------------------

function Get-ExlIcon { param([Parameter(Mandatory)][string]$Name) return $script:Icons[$Name] + $script:IconPad }

function Format-ExlNumber {
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($null -eq $Value) { return '-' }
    return ([long]$Value).ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Format-ExlDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $t = [TimeSpan]::FromTicks([long]([Math]::Max(0.0, $Seconds) * 10000000))
    if ($t.TotalDays -ge 2) { return '{0} d {1:00} h' -f [int][Math]::Floor($t.TotalDays), $t.Hours }
    if ($t.TotalHours -ge 1) { return '{0} h {1:00} min' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0} min {1:00} s' -f $t.Minutes, $t.Seconds }
    return '{0:0.0} s' -f $t.TotalSeconds
}

function Format-ExlBytes {
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:0.00} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:0.0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:0} KB' -f ($Bytes / 1KB) }
    return '{0:0} B' -f $Bytes
}

function Format-ExlLocalTime {
    param([Parameter(Mandatory)][long]$UnixMs, [Parameter(Mandatory)][TimeZoneInfo]$Zone, [string]$Format = 'yyyy-MM-dd HH:mm')
    return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($UnixMs), $Zone).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function Format-ExlRange {
    param([long]$StartMs, [long]$EndMs, [TimeZoneInfo]$Zone)
    return '{0} {2} {1}' -f (Format-ExlLocalTime $StartMs $Zone), (Format-ExlLocalTime $EndMs $Zone), [char]0x2192
}

function Start-ExlLog {
    <# Opens (or continues) today's log file and deletes the log files older than the retention. #>
    param([Parameter(Mandatory)][string]$Directory, [int]$RetentionDays = 14)
    [void][IO.Directory]::CreateDirectory($Directory)
    $script:LogPath = Join-Path $Directory ('ExchangeLogReport_{0:yyyyMMdd}.log' -f (Get-Date))
    $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:LogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $script:LogWriter.AutoFlush = $true
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'ExchangeLogReport_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt $limit | Remove-Item -Force -ErrorAction SilentlyContinue
    return $script:LogPath
}

function Stop-ExlLog { if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null } }

function Write-ExlLog {
    <# One line in the log file only. The log never contains colours or icons. #>
    param([ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO', [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if ($script:LogWriter) { $script:LogWriter.WriteLine(('{0:yyyy-MM-ddTHH:mm:ss.fffzzz} [{1,-5}] {2}' -f (Get-Date), $Level, $Message)) }
}

function Write-ExlBanner {
    <# Title card at the start of an execution, followed by the context rows (label -> @(Icon, Text)). #>
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle, [System.Collections.Specialized.OrderedDictionary]$Details)
    $C = $script:C; $F = Get-ExlFrame; $width = 74
    $right = "v$($script:ToolVersion) $([char]0x00B7) Nicolas Fabert"
    $iconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
    $left = "  $($script:Icons.Logo)  $Title"
    $gap = [Math]::Max(1, $width - ($left.Length - $script:Icons.Logo.Length + $iconWidth) - $right.Length - 2)
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.TopLeft, [string]::new($F.Horizontal, $width), $F.TopRight, $C.Reset)
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}{11}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Bold, $left, $C.Reset, [string]::new(' ', $gap), $C.Dim, $right, '  ', ($C.Accent + $F.Vertical), $C.Reset)
    if ($Subtitle) {
        $sub = "     $Subtitle"
        if ($sub.Length -gt $width - 2) { $sub = $sub.Substring(0, $width - 5) + '...' }
        Write-Host ("  {0}{1}{2}{3}{4}{5}{0}{6}{2}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Dim, $sub.PadRight($width), $C.Reset, $F.Vertical)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            $icon, $text = if ($value -is [array]) { (Get-ExlIcon $value[0]), $value[1] } else { '   ', $value }
            Write-Host ("     {0}{1}{2,-10}{3} {4}" -f $icon, $C.Dim, $key, $C.Reset, $text)
        }
    }
    Write-ExlLog 'STEP' "=== $Title v$($script:ToolVersion) ==="
    if ($Details) { foreach ($key in $Details.Keys) { $v = $Details[$key]; Write-ExlLog 'INFO' ("{0}: {1}" -f $key, $(if ($v -is [array]) { $v[1] } else { $v })) } }
}

function Write-ExlStep {
    <# Step header with a coloured number pill and an icon:  ─ 3/5 ─ 📥  Reading the logs #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int]$Total, [Parameter(Mandatory)][string]$Title, [string]$Icon = 'Info')
    $C = $script:C
    Write-Host ''
    Write-Host ("  {0} {1}/{2} {3} {4}{5}{6}{3}" -f $C.AccentBg, $Number, $Total, $C.Reset, (Get-ExlIcon $Icon), $C.Bold, $Title)
    Write-ExlLog 'STEP' "[$Number/$Total] $Title"
}

function Write-ExlItem {
    <# One indented result line with a status icon, also written to the log. #>
    param([ValidateSet('Ok', 'Warn', 'Fail', 'Info', 'Skip')][string]$Status = 'Info', [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    $color = @{ Ok = $script:C.Green; Warn = $script:C.Yellow; Fail = $script:C.Red; Info = ''; Skip = $script:C.Dim }[$Status]
    $level = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO' }[$Status]
    $symbol = Get-ExlIcon $(if ($Icon) { $Icon } else { $Status })
    $textColor = if ($Status -in 'Warn', 'Fail', 'Skip') { $color } else { '' }
    Write-Host ("      {0}{1}{2}{3}{4}{2}" -f $color, $symbol, $script:C.Reset, $textColor, $Text)
    Write-ExlLog $level $Text
}

function Write-ExlTableRow {
    <# One aligned row of the collection table: server, source, files, read, lines, kept, noise, duration, rate. #>
    param([switch]$Header, [ValidateSet('Ok', 'Warn', 'Fail', 'Skip')][string]$Status = 'Ok', [string]$Server, [string]$Source, [string]$Files,
        [string]$Read, $Lines, $Kept, [string]$Noise, [string]$Duration, [string]$Rate)
    $C = $script:C
    if ($Header) {
        Write-Host ("      {0}{1}{2,-10} {3,-19} {4,9} {5,10} {6,12} {7,10} {8,7} {9,10} {10,10}{11}" -f $C.Dim, ('  ' + $script:IconPad), 'Server', 'Source', 'Files', 'Read', 'Lines', 'Kept', 'Noise', 'Duration', 'Rate', $C.Reset)
        return
    }
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red; Skip = $C.Dim }[$Status]
    $keptText = Format-ExlNumber $Kept
    $keptColor = if ([long]$Kept -gt 0) { $C.White + $C.Bold } else { $C.Dim }
    Write-Host ("      {0}{1}{2}{3,-10} {4,-19} {5,9} {6,10} {7,12} {8}{9,10}{2} {10,7} {11,10} {12}{13,10}{2}" -f $color, (Get-ExlIcon $Status), $C.Reset, $Server, $Source, $Files, $Read,
        (Format-ExlNumber $Lines), $keptColor, $keptText, $Noise, $Duration, $C.Dim, $Rate)
    Write-ExlLog $(if ($Status -eq 'Ok' -or $Status -eq 'Skip') { 'OK' } else { 'WARN' }) ("{0} {1}: files {2}, read {3}, {4} lines, {5} kept, noise {6}, {7}, {8}" -f $Server, $Source, $Files, $Read, (Format-ExlNumber $Lines), $keptText, $Noise, $Duration, $Rate)
}

function Write-ExlSummary {
    <# Final summary card (label -> @(Icon, Text)). #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values, [ValidateSet('Ok', 'Warn', 'Fail')][string]$Status = 'Ok')
    $C = $script:C; $F = Get-ExlFrame; $width = 74
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red }[$Status]
    $icon = $script:Icons[@{ Ok = 'Done'; Warn = 'Warn'; Fail = 'Fail' }[$Status]]
    $iconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
    $head = " $icon  $Title "
    $rest = [Math]::Max(2, $width - 1 - ($head.Length - $icon.Length + $iconWidth))
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}{0}{5}{6}{7}" -f $color, $F.TopLeft, $F.Horizontal, $C.Bold, $head, ($C.Reset + $color), ([string]::new($F.Horizontal, $rest) + $F.TopRight), $C.Reset)
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        $rowIcon, $text = if ($value -is [array]) { (Get-ExlIcon $value[0]), $value[1] } else { '   ', $value }
        Write-Host ("    {0}{1}{2,-10}{3} {4}" -f $rowIcon, $C.Dim, $key, $C.Reset, $text)
        Write-ExlLog 'INFO' ("Summary - {0}: {1}" -f $key, $text)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $color, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    Write-Host ''
}

#endregion

#region 2. Configuration ------------------------------------------------------------------

function Resolve-ExlPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Get-ExlTimeZone {
    <# Accepts an IANA name (Europe/Paris) or a Windows name (Romance Standard Time). #>
    param([Parameter(Mandatory)][string]$Id)
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Id) } catch { }
    $windowsId = $null
    if ([TimeZoneInfo]::TryConvertIanaIdToWindowsId($Id, [ref]$windowsId)) { try { return [TimeZoneInfo]::FindSystemTimeZoneById($windowsId) } catch { } }
    throw "Unknown time zone '$Id' (Report.TimeZone). Use a name such as 'Europe/Paris' or 'Romance Standard Time'."
}

function Import-ExlConfiguration {
    <#
    .SYNOPSIS
        Reads the configuration file, checks every value and returns it with absolute paths.
        All problems are reported together so that they can be fixed in one go.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Root = $script:ToolRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { $config = Import-PowerShellDataFile -LiteralPath $Path }
    catch { throw "The configuration file is not valid PowerShell data ($Path): $($_.Exception.Message)" }

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($section in 'Sources', 'Noise', 'Collection', 'Storage', 'Report', 'Logging') {
        if (-not $config.ContainsKey($section) -or $config[$section] -isnot [hashtable]) { $errors.Add("Section '$section' is missing.") }
    }
    if (-not $config.ContainsKey('Servers') -or @($config.Servers).Count -eq 0) { $errors.Add("Section 'Servers' must list at least one Exchange server.") }
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }

    function Get-Value([hashtable]$Section, [string]$SectionName, [string]$Key, $Default, [switch]$Required) {
        if ($Section.ContainsKey($Key) -and $null -ne $Section[$Key] -and "$($Section[$Key])" -ne '') { return $Section[$Key] }
        if ($Required) { $errors.Add("$SectionName.$Key is required.") }
        return $Default
    }
    function Test-Int($Value, [string]$Name, [long]$Min, [long]$Max) {
        $n = 0L
        if (-not [long]::TryParse("$Value", [ref]$n) -or $n -lt $Min -or $n -gt $Max) { $errors.Add("$Name must be a whole number between $Min and $Max (current value: '$Value').") }
        return [int]$n
    }
    function Test-Bool($Value, [string]$Name) {
        if ($Value -isnot [bool]) { $errors.Add("$Name must be `$true or `$false (current value: '$Value').") ; return $false }
        return $Value
    }
    function Test-Patterns($Value, [string]$Name) {
        $list = @($Value | Where-Object { $_ })
        foreach ($p in $list) { try { [void][regex]::new($p) } catch { $errors.Add("$Name contains an invalid regular expression: '$p'.") } }
        return [string[]]$list
    }

    # ---- servers -------------------------------------------------------------------------------
    $servers = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($s in @($config.Servers)) {
        $index++
        if ($s -isnot [hashtable]) { $errors.Add("Servers[$index] must be a @{ } block."); continue }
        $name = [string]$s['Name']
        if (-not $name) { $errors.Add("Servers[$index].Name is required."); continue }
        $exchange = [string]$s['ExchangePath']
        if (-not $exchange) { $exchange = "\\$name\c$\Program Files\Microsoft\Exchange Server\V15" }
        $iis = [string]$s['IisLogPath']
        if (-not $iis) { $iis = "\\$name\c$\inetpub\logs\LogFiles" }
        $servers.Add([pscustomobject][ordered]@{
                Name                = $name.ToUpperInvariant()
                ExchangePath        = $exchange.TrimEnd('\')
                IisLogPath          = $iis.TrimEnd('\')
                HttpProxyPath       = if ($s['HttpProxyPath']) { [string]$s['HttpProxyPath'] } else { Join-Path $exchange 'Logging\HttpProxy' }
                LoggingPath         = if ($s['LoggingPath']) { [string]$s['LoggingPath'] } else { Join-Path $exchange 'Logging' }
                TransportLogPath    = if ($s['TransportLogPath']) { [string]$s['TransportLogPath'] } else { Join-Path $exchange 'TransportRoles\Logs' }
                MessageTrackingPath = if ($s['MessageTrackingPath']) { [string]$s['MessageTrackingPath'] } else { Join-Path $exchange 'TransportRoles\Logs\MessageTracking' }
            })
    }
    $duplicates = @($servers | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
    foreach ($d in $duplicates) { $errors.Add("Server '$d' is listed more than once.") }

    $src = $config.Sources; $n = $config.Noise; $c = $config.Collection; $st = $config.Storage; $r = $config.Report; $l = $config.Logging
    $settings = [ordered]@{
        ConfigPath = [IO.Path]::GetFullPath($Path)
        Servers    = $servers.ToArray()
        Sources    = [ordered]@{
            HttpProxy       = Test-Bool (Get-Value $src 'Sources' 'HttpProxy' $true) 'Sources.HttpProxy'
            IisFrontEnd     = Test-Bool (Get-Value $src 'Sources' 'IisFrontEnd' $true) 'Sources.IisFrontEnd'
            SmtpReceive     = Test-Bool (Get-Value $src 'Sources' 'SmtpReceive' $true) 'Sources.SmtpReceive'
            SmtpSend        = Test-Bool (Get-Value $src 'Sources' 'SmtpSend' $true) 'Sources.SmtpSend'
            MessageTracking = Test-Bool (Get-Value $src 'Sources' 'MessageTracking' $true) 'Sources.MessageTracking'
            TransportRoles  = [string[]]@(Get-Value $src 'Sources' 'TransportRoles' @('FrontEnd', 'Hub', 'Mailbox'))
            IisSite         = [string](Get-Value $src 'Sources' 'IisSite' 'W3SVC1')
            MapiBackEnd     = Test-Bool (Get-Value $src 'Sources' 'MapiBackEnd' $true) 'Sources.MapiBackEnd'
            EasBackEnd      = Test-Bool (Get-Value $src 'Sources' 'EasBackEnd' $true) 'Sources.EasBackEnd'
            IisBackEndSite  = [string](Get-Value $src 'Sources' 'IisBackEndSite' 'W3SVC2')
            PopImap         = Test-Bool (Get-Value $src 'Sources' 'PopImap' $false) 'Sources.PopImap'
        }
        Noise      = [ordered]@{
            SystemUserPatterns     = Test-Patterns (Get-Value $n 'Noise' 'SystemUserPatterns' @()) 'Noise.SystemUserPatterns'
            ProbeUserAgentPatterns = Test-Patterns (Get-Value $n 'Noise' 'ProbeUserAgentPatterns' @()) 'Noise.ProbeUserAgentPatterns'
            ProbeUrlPatterns       = Test-Patterns (Get-Value $n 'Noise' 'ProbeUrlPatterns' @()) 'Noise.ProbeUrlPatterns'
            ProbeSenderPatterns    = Test-Patterns (Get-Value $n 'Noise' 'ProbeSenderPatterns' @()) 'Noise.ProbeSenderPatterns'
            ExcludedClientIps      = [string[]]@(Get-Value $n 'Noise' 'ExcludedClientIps' @() | Where-Object { $_ })
            IgnoredTrackingEvents  = [string[]]@(Get-Value $n 'Noise' 'IgnoredTrackingEvents' @() | Where-Object { $_ })
        }
        Collection = [ordered]@{
            BackfillDays           = Test-Int (Get-Value $c 'Collection' 'BackfillDays' 14) 'Collection.BackfillDays' 1 365
            RecoveryWindowMinutes  = Test-Int (Get-Value $c 'Collection' 'RecoveryWindowMinutes' 30) 'Collection.RecoveryWindowMinutes' 1 1440
            SmtpSessionIdleMinutes = Test-Int (Get-Value $c 'Collection' 'SmtpSessionIdleMinutes' 10) 'Collection.SmtpSessionIdleMinutes' 1 120
            FullDetailUsers        = [string[]]@(Get-Value $c 'Collection' 'FullDetailUsers' @() | Where-Object { $_ })
            StoreAllRequests       = Test-Bool (Get-Value $c 'Collection' 'StoreAllRequests' $false) 'Collection.StoreAllRequests'
            SessionIdleMinutes     = Test-Int (Get-Value $c 'Collection' 'SessionIdleMinutes' 30) 'Collection.SessionIdleMinutes' 1 720
            SlowRequestMs          = Test-Int (Get-Value $c 'Collection' 'SlowRequestMs' 5000) 'Collection.SlowRequestMs' 0 3600000
            LongRunningPatterns    = Test-Patterns (Get-Value $c 'Collection' 'LongRunningPatterns' @('^Mapi\|NotificationWait\|', '^Eas\|Ping\|', '^RpcHttp\|', '^Owa\|.*(notificationchannel|/ev\.owa)', '^PowerShell\|', '^Imap4\|IDLE\|')) 'Collection.LongRunningPatterns'
            SessionDetailRequests  = Test-Int (Get-Value $c 'Collection' 'SessionDetailRequests' 40) 'Collection.SessionDetailRequests' 0 100000
            MaxSessionSteps        = Test-Int (Get-Value $c 'Collection' 'MaxSessionSteps' 80) 'Collection.MaxSessionSteps' 10 100000
        }
        Storage    = [ordered]@{
            DatabasePath        = Resolve-ExlPath ([string](Get-Value $st 'Storage' 'DatabasePath' '.\data\ExchangeLogReport.sqlite')) $Root
            RetentionDays       = Test-Int (Get-Value $st 'Storage' 'RetentionDays' 60) 'Storage.RetentionDays' 1 3650
            DetailRetentionDays = Test-Int (Get-Value $st 'Storage' 'DetailRetentionDays' 14) 'Storage.DetailRetentionDays' 1 3650
        }
        Report     = [ordered]@{
            DefaultRange          = [string](Get-Value $r 'Report' 'DefaultRange' 'Last7Days')
            DefaultType           = [string](Get-Value $r 'Report' 'DefaultType' 'Usage')
            TimeZone              = [string](Get-Value $r 'Report' 'TimeZone' 'Europe/Paris')
            OutputPath            = Resolve-ExlPath ([string](Get-Value $r 'Report' 'OutputPath' '.\reports')) $Root
            FilePrefix            = [string](Get-Value $r 'Report' 'FilePrefix' 'ExchangeLogs')
            Formats               = [string[]]@(Get-Value $r 'Report' 'Formats' @('Csv', 'Html'))
            IncludeRoutingDetails = Test-Bool (Get-Value $r 'Report' 'IncludeRoutingDetails' $true) 'Report.IncludeRoutingDetails'
            IncludeSessionDetails = Test-Bool (Get-Value $r 'Report' 'IncludeSessionDetails' $true) 'Report.IncludeSessionDetails'
            CsvDelimiter          = [string](Get-Value $r 'Report' 'CsvDelimiter' ';')
            MaxHtmlRows           = Test-Int (Get-Value $r 'Report' 'MaxHtmlRows' 200000) 'Report.MaxHtmlRows' 1000 2000000
            Title                 = [string](Get-Value $r 'Report' 'Title' 'Exchange Server usage and troubleshooting')
            TemplatePath          = Join-Path $Root 'templates\Report.template.html'
        }
        Logging    = [ordered]@{
            Path          = Resolve-ExlPath ([string](Get-Value $l 'Logging' 'Path' '.\logs')) $Root
            RetentionDays = Test-Int (Get-Value $l 'Logging' 'RetentionDays' 14) 'Logging.RetentionDays' 1 3650
        }
    }
    if ($settings.Storage.DetailRetentionDays -gt $settings.Storage.RetentionDays) { $errors.Add('Storage.DetailRetentionDays cannot be greater than Storage.RetentionDays.') }
    foreach ($role in $settings.Sources.TransportRoles) { if ($role -notin 'FrontEnd', 'Hub', 'Mailbox') { $errors.Add("Sources.TransportRoles accepts FrontEnd, Hub and Mailbox (current value: '$role').") } }
    if ($settings.Report.DefaultRange -notin 'Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth') { $errors.Add('Report.DefaultRange must be Last24Hours, Last7Days, Last30Days or PreviousMonth.') }
    if ($settings.Report.DefaultType -notin 'Usage', 'Detailed') { $errors.Add("Report.DefaultType must be 'Usage' or 'Detailed'.") }
    if (-not $settings.Report.Formats.Count -or @($settings.Report.Formats | Where-Object { $_ -notin 'Csv', 'Html' }).Count) { $errors.Add("Report.Formats must contain 'Csv', 'Html' or both.") }
    if ($settings.Report.CsvDelimiter -notin ';', ',', "`t", '|') { $errors.Add("Report.CsvDelimiter must be ';', ',', '|' or a tab.") }
    if (-not $settings.Report.FilePrefix -or $settings.Report.FilePrefix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { $errors.Add('Report.FilePrefix must be a valid file name part.') }
    try { $settings['Zone'] = Get-ExlTimeZone $settings.Report.TimeZone } catch { $errors.Add($_.Exception.Message) }
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }
    return $settings
}

#endregion

#region 3. Engine (SQLite + compiled C#) ------------------------------------------------------

function Initialize-ExlEngine {
    <#
    .SYNOPSIS
        Loads SQLite (lib\sqlite) and the C# engine. The engine is compiled from src\Engine.*.cs
        into bin\ the first time, and again only when a source file changes (hash in the file name).
    #>
    [CmdletBinding()]
    param([string]$Root = $script:ToolRoot)
    if ('ExchangeLogReport.Store' -as [type]) { return }
    $lib = Join-Path $Root 'lib\sqlite'
    $arch = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' }
    $native = Join-Path $lib "runtimes\$arch\e_sqlite3.dll"
    if (-not (Test-Path -LiteralPath $native)) { throw "SQLite native library not found: $native" }
    [void][Runtime.InteropServices.NativeLibrary]::Load($native)
    foreach ($name in 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.batteries_v2', 'Microsoft.Data.Sqlite') {
        Add-Type -LiteralPath (Join-Path $lib "$name.dll")
    }
    [SQLitePCL.Batteries_V2]::Init()

    $sources = @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Filter 'Engine.*.cs' -File | Sort-Object Name)
    if (-not $sources.Count) { throw "Engine source files not found in $(Join-Path $Root 'src')." }
    $hasher = [Security.Cryptography.SHA256]::Create()
    $all = [Text.StringBuilder]::new()
    foreach ($f in $sources) { [void]$all.Append($f.Name).Append((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) }
    $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($all.ToString()))).Replace('-', '').Substring(0, 16)
    $hasher.Dispose()
    $bin = Join-Path $Root 'bin'
    $dll = Join-Path $bin "ExchangeLogReport.Engine.$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        [void][IO.Directory]::CreateDirectory($bin)
        $references = @(
            (Join-Path $lib 'Microsoft.Data.Sqlite.dll'), 'System.IO.Compression', 'System.Text.Json', 'System.Text.Encodings.Web', 'System.Data.Common', 'System.Linq',
            'System.Collections', 'System.Text.RegularExpressions', 'System.Runtime', 'System.Memory', 'System.ComponentModel.Primitives', 'System.ComponentModel',
            'System.Transactions.Local', 'System.Text.Encoding.Extensions', 'System.Runtime.Extensions', 'System.IO', 'System.Runtime.InteropServices', 'System.Console',
            'System.Collections.NonGeneric', 'System.Diagnostics.Process', 'System.Linq.Expressions', 'netstandard')
        $staging = Join-Path $bin ("compile-{0}.dll" -f [guid]::NewGuid().ToString('N'))
        Add-Type -LiteralPath $sources.FullName -ReferencedAssemblies $references -OutputAssembly $staging -OutputType Library -IgnoreWarnings -WarningAction SilentlyContinue
        Move-Item -LiteralPath $staging -Destination $dll -Force
        Get-ChildItem -LiteralPath $bin -Filter 'ExchangeLogReport.Engine.*.dll' | Where-Object FullName -ne $dll | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $bin -Filter 'compile-*.dll' | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not ('ExchangeLogReport.Store' -as [type])) { Add-Type -LiteralPath $dll }
}

function Open-ExlStore {
    param([Parameter(Mandatory)]$Settings, [switch]$ReadOnly)
    $path = $Settings.Storage.DatabasePath
    if ($ReadOnly -and -not (Test-Path -LiteralPath $path)) { throw "The database does not exist yet: $path. Run a collection first (-Mode Collect)." }
    return [ExchangeLogReport.Store]::new($path, [bool]$ReadOnly, $script:ToolVersion)
}

#endregion

#region 4. Periods ------------------------------------------------------------------------------

function ConvertTo-ExlUnixMs {
    <# Text date -> Unix ms. Without an explicit offset (Z, +02:00) the date is read in the report time zone. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][TimeZoneInfo]$Zone)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Text -match '(Z|[+-]\d{2}:?\d{2})$') { return [DateTimeOffset]::Parse($Text, $culture).ToUnixTimeMilliseconds() }
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-dd HH:mm', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss')
    $local = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text, $formats, $culture, [Globalization.DateTimeStyles]::None, [ref]$local)) {
        throw "Invalid date '$Text'. Use yyyy-MM-dd, 'yyyy-MM-dd HH:mm' or an ISO 8601 value with an offset."
    }
    return [ExchangeLogReport.TimeUtil]::LocalToUnixMs($local, $Zone)
}

function Resolve-ExlPeriod {
    <#
    .SYNOPSIS
        Converts a range name into a [start, end) period in Unix milliseconds. The end is never later than now.
        Last24Hours / Last7Days / Last30Days, PreviousMonth, Month (-Month yyyy-MM), Day (-Date yyyy-MM-dd), Custom (-Start / -End).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth', 'Month', 'Day', 'Custom')][string]$Range,
        [string]$Month, [string]$Date, [string]$Start, [string]$End,
        [Parameter(Mandatory)][TimeZoneInfo]$Zone,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $nowMs = $Now.ToUnixTimeMilliseconds(); $nowMs -= $nowMs % 1000
    $day = 86400000L
    switch ($Range) {
        'Last24Hours' { $s = $nowMs - $day; $e = $nowMs }
        'Last7Days' { $s = $nowMs - 7 * $day; $e = $nowMs }
        'Last30Days' { $s = $nowMs - 30 * $day; $e = $nowMs }
        'PreviousMonth' {
            $local = [TimeZoneInfo]::ConvertTime($Now, $Zone).DateTime
            $first = [datetime]::new($local.Year, $local.Month, 1).AddMonths(-1)
            $s = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first, $Zone)
            $e = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first.AddMonths(1), $Zone)
        }
        'Month' {
            $first = [datetime]::MinValue
            if (-not $Month -or -not [datetime]::TryParseExact($Month, 'yyyy-MM', $culture, 'None', [ref]$first)) { throw '-Range Month requires -Month in the format yyyy-MM (for example -Month 2026-09).' }
            $s = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first, $Zone)
            $e = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first.AddMonths(1), $Zone)
        }
        'Day' {
            $d = [datetime]::MinValue
            if (-not $Date -or -not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', $culture, 'None', [ref]$d)) { throw '-Range Day requires -Date in the format yyyy-MM-dd.' }
            $s = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($d, $Zone)
            $e = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($d.AddDays(1), $Zone)
        }
        'Custom' {
            if (-not $Start -or -not $End) { throw '-Range Custom requires -Start and -End.' }
            $s = ConvertTo-ExlUnixMs $Start $Zone
            $e = ConvertTo-ExlUnixMs $End $Zone
        }
    }
    if ($e -gt $nowMs) { $e = $nowMs }
    if ($e -le $s) { throw "The requested period is empty or in the future ($Range)." }
    [pscustomobject]@{ Range = $Range; StartMs = [long]$s; EndMs = [long]$e }
}

#endregion

#region 5. Sources --------------------------------------------------------------------------------

function Get-ExlSources {
    <#
    .SYNOPSIS
        Lists the log folders to read for one server, as (Kind, Role, Label, Folder, Filter, Recurse) entries.
          HttpProxy    <HttpProxyPath>\<protocol>\*.log
          Iis          <IisLogPath>\<IisSite>\*.log (front end: Default Web Site)
          SmtpReceive  <TransportLogPath>\<role>\ProtocolLog\SmtpReceive (with Mailbox\...\Delivery|Submission)
          SmtpSend     <TransportLogPath>\<role>\ProtocolLog\SmtpSend
          Tracking     <MessageTrackingPath>\MSGTRK*.log (hub, delivery, submission, moderation)
          MapiBackEnd  <LoggingPath>\MapiHttp\Mailbox\*.log (Outlook MAPI over HTTP, back end)
          EasBackEnd   <IisLogPath>\<IisBackEndSite>\*.log (Exchange Back End web site: ActiveSync results)
          Imap4, Pop3  <LoggingPath>\Imap4, <LoggingPath>\Pop3 (optional: protocol logging must be enabled)
    #>
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$Settings)
    $src = $Settings.Sources
    $list = [Collections.Generic.List[object]]::new()
    $add = { param($Kind, $Role, $Label, $Folder, $Filter, $Recurse) $list.Add([pscustomobject]@{ Kind = $Kind; Role = $Role; Label = $Label; Folder = $Folder; Filter = $Filter; Recurse = $Recurse }) }
    if ($src.HttpProxy) { & $add 'HttpProxy' $null 'HttpProxy' $Server.HttpProxyPath '*.log' $true }
    if ($src.IisFrontEnd) { & $add 'Iis' $null 'IIS front end' (Join-Path $Server.IisLogPath $src.IisSite) '*.log' $false }
    if ($src.MapiBackEnd) { & $add 'MapiBackEnd' $null 'MAPI back end' (Join-Path $Server.LoggingPath 'MapiHttp\Mailbox') '*.log' $false }
    if ($src.EasBackEnd) { & $add 'EasBackEnd' $null 'EAS back end (IIS)' (Join-Path $Server.IisLogPath $src.IisBackEndSite) '*.log' $false }
    if ($src.PopImap) {
        & $add 'Imap4' $null 'IMAP4' (Join-Path $Server.LoggingPath 'Imap4') '*.log' $false
        & $add 'Pop3' $null 'POP3' (Join-Path $Server.LoggingPath 'Pop3') '*.log' $false
    }
    foreach ($role in $src.TransportRoles) {
        $protocolLog = Join-Path $Server.TransportLogPath "$role\ProtocolLog"
        if ($src.SmtpReceive) { & $add 'SmtpReceive' $role "SMTP in ($role)" (Join-Path $protocolLog 'SmtpReceive') '*.log' $true }
        if ($src.SmtpSend) { & $add 'SmtpSend' $role "SMTP out ($role)" (Join-Path $protocolLog 'SmtpSend') '*.log' $true }
    }
    if ($src.MessageTracking) { & $add 'Tracking' $null 'Tracking' $Server.MessageTrackingPath 'MSGTRK*.log' $false }
    return $list.ToArray()
}

function Get-ExlSourceFiles {
    <#
    .SYNOPSIS
        Files of one source that must be read: modified within BackfillDays and not read to their end
        (read position different from the file size: new lines, or a session held back). Oldest first.
    #>
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][hashtable]$Known, [Parameter(Mandatory)][datetime]$Since)
    $files = if ($Source.Recurse) { Get-ChildItem -LiteralPath $Source.Folder -Filter $Source.Filter -File -Recurse -ErrorAction SilentlyContinue }
             else { Get-ChildItem -LiteralPath $Source.Folder -Filter $Source.Filter -File -ErrorAction SilentlyContinue }
    $todo = [Collections.Generic.List[object]]::new()
    $total = 0
    foreach ($f in @($files)) {
        $total++
        $key = "$($Source.Kind)|$($f.FullName)"
        $isKnown = $Known.ContainsKey($key)
        if (-not $isKnown -and $f.LastWriteTimeUtc -lt $Since) { continue }
        if ($isKnown -and [long]$Known[$key] -eq $f.Length) { continue }
        $todo.Add($f)
    }
    [pscustomobject]@{ Total = $total; Files = @($todo | Sort-Object LastWriteTimeUtc, Name) }
}

function Test-ExlServerAccess {
    <# Checks that the log roots of a server can be read; returns the list of problems. #>
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$Settings)
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($s in Get-ExlSources $Server $Settings) {
        if (-not (Test-Path -LiteralPath $s.Folder -PathType Container) -and $s.Kind -notin 'SmtpReceive', 'SmtpSend', 'Imap4', 'Pop3', 'MapiBackEnd') {
            $problems.Add("$($s.Label): folder not found or not readable ($($s.Folder))")
        }
    }
    return $problems.ToArray()
}

#endregion

#region 6. Collection -----------------------------------------------------------------------------

function New-ExlCollector {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][long]$RunId)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $o = [ExchangeLogReport.CollectorOptions]::new()
    $o.Zone = $Settings.Zone
    $o.RunId = $RunId
    $o.NowMs = $now
    $o.RetentionCutoffMs = $now - [long]$Settings.Storage.RetentionDays * 86400000
    $o.DetailCutoffMs = $now - [long]$Settings.Storage.DetailRetentionDays * 86400000
    $o.RecoveryWindowMs = [long]$Settings.Collection.RecoveryWindowMinutes * 60000
    $o.SmtpIdleMs = [long]$Settings.Collection.SmtpSessionIdleMinutes * 60000
    $o.StoreAllRequests = $Settings.Collection.StoreAllRequests
    $o.FullDetailUsers = $Settings.Collection.FullDetailUsers
    $o.SystemUserPatterns = $Settings.Noise.SystemUserPatterns
    $o.ProbeUserAgentPatterns = $Settings.Noise.ProbeUserAgentPatterns
    $o.ProbeUrlPatterns = $Settings.Noise.ProbeUrlPatterns
    $o.ProbeSenderPatterns = $Settings.Noise.ProbeSenderPatterns
    $o.ExcludedClientIps = $Settings.Noise.ExcludedClientIps
    $o.IgnoredTrackingEvents = $Settings.Noise.IgnoredTrackingEvents
    $o.SessionIdleMs = [long]$Settings.Collection.SessionIdleMinutes * 60000
    $o.SlowRequestMs = [long]$Settings.Collection.SlowRequestMs
    $o.LongRunningPatterns = $Settings.Collection.LongRunningPatterns
    $o.SessionDetailRequests = $Settings.Collection.SessionDetailRequests
    $o.MaxSegmentSteps = $Settings.Collection.MaxSessionSteps
    return [ExchangeLogReport.Collector]::new($Store, $o)
}

function Invoke-ExlCollection {
    <#
    .SYNOPSIS
        Reads the new part of the log files of every server into the database. One table row per
        server and source; a progress bar per file. Returns the totals.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][long]$RunId, [object[]]$Servers)
    if (-not $Servers) { $Servers = $Settings.Servers }
    $collector = New-ExlCollector -Store $Store -Settings $Settings -RunId $RunId
    $since = [DateTime]::UtcNow.AddDays(-$Settings.Collection.BackfillDays)
    $totals = [ordered]@{ Files = 0L; Bytes = 0L; Lines = 0L; Kept = 0L; Noise = 0L; Stored = 0L; Errors = 0L; Recovered = 0L; Seconds = 0.0; Unreachable = [Collections.Generic.List[string]]::new(); NoiseReasons = @{} }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-ExlTableRow -Header
    foreach ($server in $Servers) {
        $known = @{}
        foreach ($kv in $Store.KnownOffsets($server.Name).GetEnumerator()) { $known[$kv.Key] = $kv.Value }
        foreach ($source in Get-ExlSources $server $Settings) {
            if (-not (Test-Path -LiteralPath $source.Folder -PathType Container)) {
                # SMTP, POP and IMAP protocol log folders exist only where protocol logging is enabled.
                if ($source.Kind -in 'SmtpReceive', 'SmtpSend', 'Imap4', 'Pop3', 'MapiBackEnd') { Write-ExlLog 'INFO' "$($server.Name) $($source.Label): no folder ($($source.Folder))"; continue }
                Write-ExlTableRow -Status Fail -Server $server.Name -Source $source.Label -Files '-' -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'not found' -Rate ''
                $totals.Unreachable.Add("$($server.Name) $($source.Label): $($source.Folder)")
                continue
            }
            $plan = Get-ExlSourceFiles -Source $source -Known $known -Since $since
            if (-not $plan.Files.Count) {
                if ($plan.Total) { Write-ExlTableRow -Status Skip -Server $server.Name -Source $source.Label -Files "0/$($plan.Total)" -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'up to date' -Rate '' }
                continue
            }
            $row = [ordered]@{ Files = 0; Bytes = 0L; Lines = 0L; Kept = 0L; Noise = 0L; Errors = 0; Seconds = 0.0 }
            $i = 0
            foreach ($file in $plan.Files) {
                $i++
                Write-Progress -Id 1 -Activity "$($server.Name) - $($source.Label)" -Status ("{0} ({1} of {2}, {3})" -f $file.Name, $i, $plan.Files.Count, (Format-ExlBytes $file.Length)) -PercentComplete ([int](100 * ($i - 1) / $plan.Files.Count))
                $r = $collector.ProcessFile($server.Name, $source.Kind, $source.Role, $file.FullName)
                if ($r.Error) {
                    $row.Errors++
                    Write-ExlLog 'WARN' ("{0} {1}: {2}" -f $server.Name, $file.FullName, $r.Error)
                    continue
                }
                if ($r.Unchanged) { continue }
                $row.Files++; $row.Bytes += $r.BytesRead; $row.Lines += $r.Lines; $row.Kept += $r.Kept; $row.Noise += $r.Noise; $row.Seconds += $r.Seconds
                $totals.Stored += $r.Stored
                foreach ($kv in $r.NoiseReasons.GetEnumerator()) { $totals.NoiseReasons[$kv.Key] = [long]$totals.NoiseReasons[$kv.Key] + $kv.Value }
                if ($r.Reset) { Write-ExlLog 'WARN' "$($file.FullName) was shorter than the position already read: read again from the beginning." }
            }
            Write-Progress -Id 1 -Activity "$($server.Name) - $($source.Label)" -Completed
            $noisePercent = if ($row.Lines) { '{0:0}%' -f (100.0 * $row.Noise / $row.Lines) } else { '-' }
            $rate = if ($row.Seconds -gt 0) { '{0}/s' -f (Format-ExlBytes ($row.Bytes / $row.Seconds)) } else { '' }
            $status = if ($row.Errors) { 'Warn' } else { 'Ok' }
            Write-ExlTableRow -Status $status -Server $server.Name -Source $source.Label -Files ("{0}/{1}" -f $row.Files, $plan.Total) -Read (Format-ExlBytes $row.Bytes) `
                -Lines $row.Lines -Kept $row.Kept -Noise $noisePercent -Duration (Format-ExlDuration $row.Seconds) -Rate $rate
            if ($row.Errors) { Write-ExlItem Warn ("{0} file(s) could not be read on {1} ({2}); see the log file." -f $row.Errors, $server.Name, $source.Label) }
            $totals.Files += $row.Files; $totals.Bytes += $row.Bytes; $totals.Lines += $row.Lines; $totals.Kept += $row.Kept; $totals.Noise += $row.Noise; $totals.Errors += $row.Errors
        }
    }
    $totals.Recovered = $collector.Complete()
    $totals.Seconds = $clock.Elapsed.TotalSeconds
    return [pscustomobject]$totals
}

#endregion

#region 7. Report ---------------------------------------------------------------------------------

function New-ExlReport {
    <# Builds the CSV and HTML files of a period into a new sub-folder of Report.OutputPath. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Period,
        [ValidateSet('Usage', 'Detailed')][string]$ReportType = 'Usage', [string[]]$User, [string[]]$Server, [bool]$IncludeRoutingDetails = $true, [bool]$IncludeSessionDetails = $true)
    $zone = $Settings.Zone
    $stamp = (Format-ExlLocalTime $Period.StartMs $zone 'yyyyMMdd-HHmm') + '_' + (Format-ExlLocalTime $Period.EndMs $zone 'yyyyMMdd-HHmm')
    $folderName = '{0}_{1}_{2}' -f $Settings.Report.FilePrefix, $ReportType, $stamp
    if ($User) { $folderName += '_' + (($User | ForEach-Object { ($_ -replace '[^\w@.-]', '_') }) -join '+') }
    $folderName += '_' + (Get-Date -Format 'HHmmss')
    $q = [ExchangeLogReport.ReportRequest]::new()
    $q.StartMs = $Period.StartMs; $q.EndMs = $Period.EndMs
    $q.DetailCutoffMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$Settings.Storage.DetailRetentionDays * 86400000
    $q.Zone = $zone; $q.TimeZoneName = $Settings.Report.TimeZone
    $q.Users = [string[]]@($User | Where-Object { $_ }); $q.Servers = [string[]]@($Server | Where-Object { $_ })
    $q.ConfiguredServers = [string[]]@($Settings.Servers | ForEach-Object Name)
    $q.Detailed = $ReportType -eq 'Detailed'
    $q.IncludeRoutingDetails = $IncludeRoutingDetails
    $q.IncludeSessionDetails = $IncludeSessionDetails
    $q.SlowRequestMs = [long]$Settings.Collection.SlowRequestMs
    $q.WriteCsv = 'Csv' -in $Settings.Report.Formats
    $q.WriteHtml = 'Html' -in $Settings.Report.Formats
    $q.OutputFolder = Join-Path $Settings.Report.OutputPath $folderName
    $q.FilePrefix = $Settings.Report.FilePrefix
    $q.CsvDelimiter = $Settings.Report.CsvDelimiter
    $q.TemplatePath = $Settings.Report.TemplatePath
    $q.Title = $Settings.Report.Title
    $q.ToolVersion = $script:ToolVersion
    $q.Generated = Format-ExlLocalTime ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) $zone 'yyyy-MM-dd HH:mm'
    $q.RecoveryWindowMs = [long]$Settings.Collection.RecoveryWindowMinutes * 60000
    $q.MaxHtmlRows = $Settings.Report.MaxHtmlRows
    return [ExchangeLogReport.ReportBuilder]::Build($Store, $q)
}

#endregion

#region 8. Status and maintenance ------------------------------------------------------------------

function Show-ExlStatus {
    <# Database content per server and source, and the noise set aside by the last collection. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings)
    $zone = $Settings.Zone; $K = $script:C; $dot = [char]0x00B7
    $counts = $Store.Query("SELECT (SELECT COUNT(*) FROM access_usage), (SELECT COUNT(*) FROM access_event), (SELECT COUNT(*) FROM smtp_transaction), (SELECT COUNT(*) FROM message_event), (SELECT COUNT(DISTINCT message_id) FROM message_event), (SELECT COUNT(DISTINCT user) FROM access_usage)", $null).Rows[0]
    Write-ExlItem Info ('{0}  ({1})' -f $Store.FilePath, (Format-ExlBytes $Store.FileBytes)) -Icon Database
    Write-ExlItem Info ('{0} real users {6} {1} daily usage rows {6} {2} failed requests kept {6} {3} SMTP transactions {6} {4} tracking events ({5} messages)' -f
        (Format-ExlNumber $counts[5]), (Format-ExlNumber $counts[0]), (Format-ExlNumber $counts[1]), (Format-ExlNumber $counts[2]), (Format-ExlNumber $counts[3]), (Format-ExlNumber $counts[4]), $dot) -Icon Chart
    $rows = $Store.Query("SELECT server, kind, COUNT(*), SUM(offset), SUM(lines), SUM(kept), SUM(noise), MIN(first_ms), MAX(last_ms), MAX(updated_ms) FROM source_file GROUP BY server, kind ORDER BY server, kind", $null).Rows
    if (-not $rows.Count) { Write-ExlItem Warn 'Nothing has been collected yet. Run: .\Invoke-ExchangeLogReport.ps1 -Mode Collect'; return }
    Write-Host ''
    Write-Host ('      {0}{1}{2,-10} {3,-12} {4,7} {5,10} {6,13} {7,11} {8,6}  {9,-33} {10}{11}' -f $K.Dim, ('  ' + $script:IconPad), 'Server', 'Source', 'Files', 'Read', 'Lines', 'Kept', 'Noise', 'Data from - to', 'Last read', $K.Reset)
    foreach ($r in $rows) {
        $noise = if ($r[4]) { '{0:0}%' -f (100.0 * $r[6] / $r[4]) } else { '-' }
        $range = if ($r[7]) { '{0} {1} {2}' -f (Format-ExlLocalTime $r[7] $zone 'yyyy-MM-dd HH:mm'), [char]0x2192, (Format-ExlLocalTime $r[8] $zone 'MM-dd HH:mm') } else { '-' }
        $last = if ($r[9]) { Format-ExlLocalTime $r[9] $zone 'yyyy-MM-dd HH:mm' } else { '-' }
        Write-Host ('      {0}{1}{2}{3,-10} {4,-12} {5,7} {6,10} {7,13} {8,11} {9,6}  {10,-33} {11}' -f $K.Green, (Get-ExlIcon 'Ok'), $K.Reset, $r[0], $r[1], (Format-ExlNumber $r[2]), (Format-ExlBytes ([double]$r[3])), (Format-ExlNumber $r[4]), (Format-ExlNumber $r[5]), $noise, $range, $last)
        Write-ExlLog 'INFO' ("Status {0} {1}: {2} files, {3} lines, {4} kept, noise {5}, {6}" -f $r[0], $r[1], $r[2], $r[4], $r[5], $noise, $range)
    }
    $configured = @($Settings.Servers | ForEach-Object Name)
    $collected = @($rows | ForEach-Object { [string]$_[0] } | Select-Object -Unique)
    foreach ($n in $configured) { if ($n -notin $collected) { Write-ExlItem Warn "$n is in the configuration but nothing has been collected from it yet." } }
    $last = $Store.Query("SELECT id, started_ms, status FROM run WHERE mode IN ('Collect','Report') AND files > 0 ORDER BY id DESC LIMIT 1", $null).Rows
    if ($last.Count) {
        $noise = $Store.Query("SELECT reason, SUM(lines) FROM noise WHERE run_id = @r GROUP BY reason ORDER BY 2 DESC LIMIT 12", @{ r = $last[0][0] }).Rows
        if ($noise.Count) {
            Write-Host ''
            Write-ExlItem Info ('Noise set aside by the last collection ({0}):' -f (Format-ExlLocalTime $last[0][1] $zone 'yyyy-MM-dd HH:mm')) -Icon Filter
            foreach ($n in $noise) { Write-Host ('          {0}{1,12}{2}  {3}' -f $K.Dim, (Format-ExlNumber $n[1]), $K.Reset, $n[0]) }
        }
    }
}

function Invoke-ExlRetention {
    <# Deletes what is older than Storage.RetentionDays (aggregates, messages) and DetailRetentionDays (request details, transcripts). #>
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cutoff = $now - [long]$Settings.Storage.RetentionDays * 86400000
    $detail = $now - [long]$Settings.Storage.DetailRetentionDays * 86400000
    $day = Format-ExlLocalTime $cutoff $Settings.Zone 'yyyy-MM-dd'
    $result = $Store.Purge($cutoff, $day, $detail)
    $Store.Checkpoint()
    return $result
}

function Enter-ExlLock {
    <# Prevents two executions from collecting at the same time. Release with Exit-ExlLock. #>
    param([Parameter(Mandatory)][string]$Path, [int]$TimeoutSeconds = 30)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
            $stream.SetLength(0)
            $bytes = [Text.Encoding]::UTF8.GetBytes(("{0} pid {1} since {2:o}" -f [Environment]::MachineName, $PID, (Get-Date)))
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            return $stream
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                $owner = try { [IO.File]::ReadAllText($Path) } catch { 'unknown' }
                throw "Another execution is already collecting ($owner). Wait for it to finish, or use -NoCollect to build a report from the data already collected."
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Exit-ExlLock { param($Lock) if ($Lock) { $Lock.Dispose() } }

#endregion
