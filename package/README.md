# Exchange Log Report

A modern Log Parser for Exchange Server SE on-premises that reads IIS, HTTP Proxy, MAPI, ActiveSync, POP/IMAP, SMTP and tracking logs, removes noise before storage and reports real usage and troubleshooting details.

This folder contains everything needed to run the tool: `Invoke-ExchangeLogReport.ps1`, the module and its C# engine, the configuration, the report template, the SQLite library and the guides. Tests and build tools stay outside it, in the repository.

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows. Unblock them once, from this folder:
>
> ```powershell
> Get-ChildItem . -Recurse -File | Unblock-File
> ```

## Requirements

- Exchange Server SE or Subscription Edition on-premises.
- PowerShell 7.4 or later; `-Mode Discover` uses Windows PowerShell 5.1 for Exchange cmdlets.
- Local administrator of every Exchange server to read log folders over administrative shares.
- SYSTEM on an Exchange server, or a domain account with logon as a batch job on an administration server.
- SQLite is bundled in `lib\sqlite`.

## Quick start

```powershell
# On EXCH01, in PowerShell 7 as administrator, in the folder of the tool

# 1 · List the servers: one @{ Name = 'EXCH01' } line per server, in Servers
notepad .\config\ExchangeLogReport.config.psd1

# 2 · Find the log folders, with your administrator account (not as SYSTEM)
.\Invoke-ExchangeLogReport.ps1 -Mode Discover

# 3 · Collect every hour, as SYSTEM; the first run, now, reads 14 days of logs
$pwsh = 'E:\Tools\pwsh\pwsh.exe'
$tool = 'E:\Tools\ExchangeLogReport\Invoke-ExchangeLogReport.ps1'
$run  = "$pwsh -NoProfile -ExecutionPolicy Bypass -File $tool"
schtasks /Create /F /RU SYSTEM /RL HIGHEST /TN "Exchange Log Report - collect" `
    /SC HOURLY /TR "$run -Mode Collect"
schtasks /Run /TN "Exchange Log Report - collect"

# 4 · Check, once the first run is over: every server and every source has data
.\Invoke-ExchangeLogReport.ps1 -Mode Status
```

## Content

| Item | Role |
|---|---|
| `config\` | Configuration file to edit and discover. |
| `docs\` | User and developer guides, Markdown and self-contained HTML. |
| `lib\` | Bundled SQLite libraries. |
| `src\` | PowerShell helper and C# engine sources, compiled on first use. |
| `templates\` | HTML report template. |
| `Invoke-ExchangeLogReport.ps1` | Entry script. |
| `ExchangeLogReport.psd1` | Module manifest. |
| `ExchangeLogReport.psm1` | Module loader. |
| `README.md` | This package readme. |
| `LICENSE` | MIT license. |
| `THIRD-PARTY-NOTICES.md` | Notices for bundled components. |

## Documentation

- [User guide](docs/ExchangeLogReport-UserGuide.md) - also `docs/ExchangeLogReport-UserGuide.html`, a single file to open locally
- [Developer guide](docs/ExchangeLogReport-Guide.md) - also `docs/ExchangeLogReport-Guide.html`

Project page, releases and change log: https://github.com/Nico77600/ExchangeLogReport

License: [MIT](LICENSE). Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
