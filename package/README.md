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
| `src\` | Integrity verifier, Exchange PowerShell helper and C# engine sources, compiled in memory at each start. |
| `templates\` | HTML report template. |
| `Invoke-ExchangeLogReport.ps1` | Entry script. |
| `ExchangeLogReport.psd1` | Module manifest. |
| `ExchangeLogReport.psm1` | Module loader. |
| `src\Test-PackageIntegrity.ps1` | Verifier of the whole parent package (signatures and SHA256 of every protected file). |
| `PackageIntegrity.psd1` | Signed manifest of the protected files; `config\`, `bin\`, `data\`, `logs\` and `reports\` are not protected. |
| `README.md` | This package readme. |
| `LICENSE` | MIT license. |
| `THIRD-PARTY-NOTICES.md` | Notices for bundled components. |

## Documentation

- [User guide](docs/ExchangeLogReport-UserGuide.md) - also `docs/ExchangeLogReport-UserGuide.html`, a single file to open locally
- [Developer guide](docs/ExchangeLogReport-Guide.md) - also `docs/ExchangeLogReport-Guide.html`

Project page, releases and change log: https://github.com/Nico77600/ExchangeLogReport

License: [MIT](LICENSE). Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Data handling

The package includes PowerShell scripts, C# source compiled in memory at each start, and third-party SQLite binaries; it is not a plain-text PowerShell-only tool. A signed manifest (`PackageIntegrity.psd1`, at the package root) and `src\Test-PackageIntegrity.ps1` verify the signatures and the hash of every protected file before anything runs, including all 12 C# sources and all six SQLite DLLs. C# and DLLs are protected by raw SHA256 entries in the owner-signed manifest, not individually Authenticode-signed. The configuration is not protected, and no compiled copy is loaded from `bin\`. It is read-only for Exchange, but writes its database, reports and execution logs locally.

Report e-mail is disabled in the delivered configuration. `-SendMail` or `Mail.Enabled` enables it; `-SendMail:$false` suppresses it for one report. `-Mode MailTest` sends a test message independently of `Mail.Enabled`.

Noise removal is not anonymisation. The database and reports can contain account names, e-mail and IP addresses, device identifiers, message subjects and SMTP transcripts. Restrict access to the output folders and review the recipients before enabling e-mail. Database retention does not delete exported HTML/CSV reports or copies sent by e-mail; their protection and deletion remain the operator's responsibility.

SMTP AUTH payloads, challenges and tokens are removed before the database stores them. Transcripts stored by an earlier version are redacted in reports and CSV exports; the existing database content is not rewritten.

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
