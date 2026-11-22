# Exchange Log Report

A modern Log Parser for Exchange Server SE on-premises that reads IIS, HTTP Proxy, MAPI, ActiveSync, POP/IMAP, SMTP and tracking logs, removes noise before storage and reports real usage and troubleshooting details: a Usage report, a Detailed report, and a local read-only portal.

**Author:** Nicolas Fabert  
**Version:** 3.1.0

This folder is the complete Windows x64 package (`ExchangeLogReport-3.1.0-win-x64.zip`): the launchers, the scripts, the C# engine, the configuration, the report template (also the page of the portal), the SQLite library, the guides and its own PowerShell 7. Nothing else is installed. Tests and build tools stay outside it, in the repository.

> [!IMPORTANT]
> Windows marks files downloaded from the Internet. Once the ZIP is extracted (Quick start below), check the publisher first (right-click a `.ps1`, for example `Invoke-ExchangeLogReport.ps1`, Properties, Digital Signatures: `Nicolas Fabert`), then unblock this folder once, from Windows PowerShell opened in it:
>
> ```powershell
> Get-ChildItem . -Recurse -File -Force | Unblock-File
> ```

## Requirements

- Exchange Server SE or Subscription Edition on-premises.
- Windows x64. PowerShell 7 is inside the package (`powershell\`); the scripts alone run on PowerShell 7.4 or later. `-Mode Discover` uses Windows PowerShell 5.1 for the Exchange cmdlets.
- Local administrator of every Exchange server to read log folders over administrative shares.
- SYSTEM on an Exchange server, or a domain account with logon as a batch job on an administration server.
- A current desktop Edge, Chrome or Firefox, for the HTML reports and the portal.
- SMB signing required between the collector and the Exchange servers (developer guide, 4.3).
- SQLite is bundled in `lib\sqlite` and `sqlite-tools\`.

## Quick start

Check the download (publisher thumbprint `0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6`, `gh attestation verify <zip> --repo Nico77600/ExchangeLogReport`, the SBOM next to the ZIP: developer guide, 5.3). Extract the whole ZIP into a local folder that only the administrators and SYSTEM can change, preferably under `%ProgramFiles%` (`C:\Program Files\ExchangeLogReport`, the folder of every example of the guides): the account that collects writes `data\`, `reports\` and `logs\` only (developer guide, 5.2). Open Windows PowerShell as administrator in the folder. Each launcher verifies the package before it starts the PowerShell that is inside it.

| You want to | Run | You get |
|---|---|---|
| Set up once | `Run-Collector.cmd -Mode Discover`, then `Run-Collector.cmd -Mode Collect` by hand (the first collection reads 14 days), then the hourly collection task below, then `Run-Collector.cmd -Mode Status` | the log folders of every server, the first 14 days of history, a status line per server |
| **Usage report** | `Run-Collector.cmd -Range Last30Days` (a report is the default mode, Usage the default type) | `reports\ExchangeLogs_Usage_<period>_<time>\ExchangeLogs.html` + CSV files |
| **Detailed report** | `Run-Collector.cmd -ReportType Detailed -Range Last24Hours` | `reports\ExchangeLogs_Detailed_<period>_<time>\ExchangeLogs.html`; above 200 MB of data, also an `ExchangeLogs_data` folder that must stay next to the page |
| **The portal** (Serve mode) | `Start-Portal.cmd` | the Detailed report page opens in your browser on `http://127.0.0.1:<port>`, on the newest collected day, with the day bar under the tiles; stop it with **Stop portal** or Ctrl+C |
| Database maintenance (rare) | `Database-Storage.cmd` | the three usual commands; a read-only audit, or a **new** compacted or migrated copy |

Edit `config\ExchangeLogReport.config.psd1` first: one `@{ Name = 'EXCH01' }` line per server in `Servers`. Run the first collection by hand in the administrator window; it reads the last 14 days of logs and shows its progress:

```bat
Run-Collector.cmd -Mode Collect
```

Then schedule the hourly collection:

```bat
schtasks /Create /F /RU SYSTEM /RL HIGHEST /TN "Exchange Log Report - collect" /SC HOURLY /TR "\"C:\Program Files\ExchangeLogReport\Run-Collector.cmd\" -Mode Collect"
```

Always start the tool through `Run-Collector.cmd`, by hand and in the scheduled tasks: it checks the package, then starts the PowerShell inside it with the right settings. Large first collections need several GB of memory.

What you get, and what to do:

- **Reports** are written under `reports\`, one folder per run: `ExchangeLogs.html` and the CSV files. A large Detailed report also has an `ExchangeLogs_data` folder: keep it next to the page.
- **The portal** shows the same history in your browser, as the Detailed report page: the same tiles and tabs, and a row opens its timeline, route or transcript. It never collects, never sends mail and never changes the database.
- **Move by day** in the portal: it opens on the day of the newest data. In the day bar under the tiles, use **1 day**, **3 days**, **7 days**, **Previous day**, **Next day** or **Jump to day**; for any other period, set **From** and **To** and click **Apply**. A tab marked **Loaded** holds every row in the page; a tab marked **Remote** holds more than 50,000 rows and is read on the server. Either way, its filters, search and **Export view to CSV** cover the whole period.
- **If a launcher says *The package could not be verified***: extract the release ZIP again, unblock it and start the launcher again. Every other message is in the user guide, chapter 7.

## Content

| Item | Role |
|---|---|
| `Run-Collector.cmd` | Discovery, collection, status and reports. |
| `Start-Portal.cmd` | The local read-only portal. |
| `Database-Storage.cmd` | Database audit and new-copy maintenance. |
| `Invoke-ExchangeLogReport.ps1` | Entry script of the collector and of the portal. |
| `Database-Storage.ps1` | Entry script of the storage maintenance. |
| `ExchangeLogReport.psd1`, `ExchangeLogReport.psm1` | Module manifest and loader. |
| `config\` | Configuration file to edit and discover. |
| `docs\` | User and developer guides, self-contained HTML. |
| `lib\`, `sqlite-tools\` | Bundled SQLite libraries and command-line tool. |
| `src\` | Integrity verifier, Exchange PowerShell helper, and the C# sources of the engine and of the storage tool, compiled in memory at each start. |
| `templates\` | Report page template and its script: the HTML reports and the page of the portal. |
| `powershell\` | PowerShell 7 for Windows x64. |
| `src\Test-PackageIntegrity.ps1` | Verifier of the whole package (signatures and SHA256 of every protected file). |
| `PackageIntegrity.psd1` | Signed manifest of the protected files; `config\`, `bin\`, `data\`, `logs\` and `reports\` are not protected. |
| `README.md`, `CHANGELOG.md`, `SECURITY.md`, `LICENSE`, `THIRD-PARTY-NOTICES.md` | Documents and notices. |

`data\`, `reports\`, `logs\` and `bin\` are created at run time and are never part of the package.

## Documentation

- [User guide](docs/ExchangeLogReport-UserGuide.html) - the guided path, step by step; the portal; the database maintenance
- [Developer guide](docs/ExchangeLogReport-Guide.html) - the principles, configuration, correlation rules, data model, the portal, troubleshooting
- Change log: `CHANGELOG.md` in this folder - what changed, with the upgrade steps from 2.1.1
- Security policy: `SECURITY.md` in this folder

Project page and releases: https://github.com/Nico77600/ExchangeLogReport

License: MIT (`LICENSE` in this folder). Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Data handling

The package includes PowerShell scripts, C# source compiled in memory at each start, and third-party binaries (SQLite, the PowerShell runtime); it is not a plain-text PowerShell-only tool. A signed manifest (`PackageIntegrity.psd1`, at the package root) and `src\Test-PackageIntegrity.ps1` verify the signatures and the hash of every protected file before anything runs, including all C# sources, all six SQLite DLLs, the report template, the PowerShell runtime and the SQLite tool. C# sources, libraries and binaries are protected by raw SHA256 entries in the owner-signed manifest, not individually Authenticode-signed. The configuration is not protected, and no compiled copy is loaded from `bin\`. It is read-only for Exchange, but writes its database, reports and execution logs locally.

The portal runs on this computer only (`127.0.0.1`, port 8765 by default), with a private link for each start. It does not change firewall rules, URL reservations or services. Anyone who has the link reads everything the portal shows, and the link is on the command line of the browser at launch: never share it, start the portal in your own session; the filters in a copied address may contain account names.

When the tool runs elevated and an account that is not an administrator can write this folder, one of its code folders or a parent folder, it warns and names the account and the folder; `Security.RequireProtectedFolder = $true` refuses to run instead. On a server that does not trust the publisher root certificate, the package is still accepted on the pinned publisher certificate and the signed file hashes, with one warning; a modified file, a file without signature or a file signed by another certificate is never accepted.

Report e-mail is disabled in the delivered configuration. `-SendMail` or `Mail.Enabled` enables it; `-SendMail:$false` suppresses it for one report. `-Mode MailTest` sends a test message independently of `Mail.Enabled`.

Noise removal is not anonymisation. The database and reports can contain account names, e-mail and IP addresses, device identifiers, message subjects and SMTP transcripts. Restrict access to the output folders and review the recipients before enabling e-mail. Database retention does not delete exported HTML/CSV reports or copies sent by e-mail; their protection and deletion remain the operator's responsibility. The tool deletes reports only when `Report.RetentionDays` is set (default `0`: never), and never an export in the download folder of the browser or a copy made by `Database-Storage.cmd`; the logs are deleted after `Logging.RetentionDays` (14 days). Where the personal data goes and how to prune it, and a note for the operator who is responsible for it: developer guide, 10.1. Removing the tool: 5.5. The deployment security checklist is Annex D of the developer guide.

`StartTls` and `Tls` encrypt the report e-mail (`Mail.MinimumTls` sets the lowest TLS version accepted); Kerberos with `Encryption = 'None'` authenticates but does not encrypt. The revocation of the server certificate is checked only when `Mail.CheckRevocation` is `$true`, and a pinned thumbprint replaces the chain and name validation. `Mail.AllowedRecipientDomains` limits the recipients, and every send logs its To, Cc and Bcc. *No real usage* and the absence of warnings do not by themselves authorise a decommissioning (developer guide, chapter 9).

Passwords and other sign-in data of SMTP conversations are removed before the database stores them. Transcripts stored by an earlier version are masked in reports and CSV exports; the existing database content is not rewritten.

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
