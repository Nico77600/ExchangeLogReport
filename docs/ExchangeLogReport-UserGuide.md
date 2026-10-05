---
title: Exchange Log Report
subtitle: User guide
version: 1.6.1
author: Nicolas Fabert
updated: 2026-10-05
---

# Exchange Log Report — User guide

> What you need before the first report, then one command per everyday question: **is this server still used?**, **what happened to this user?**, **where did this message go?**, **what failed during this incident?** How the tool works, the configuration in detail, every tab of the report and the internals are in the [developer guide](ExchangeLogReport-Guide.md).

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows and fail to run. Before using this project, unblock every file in the downloaded folder:
>
> ```powershell
> Get-ChildItem "C:\Chemin\Du\Dossier" -Recurse -File -Force | Unblock-File
> ```
>
> Replace the example path with the folder where you downloaded or extracted this project.

```cards
checklist | Prerequisites | Chapter 1: PowerShell, the account, the network, the logging, then the one-time setup.
terminal | Everyday use | Chapter 2: one command per question, and the tab of the report that answers it.
calendar | Period and filters | Chapter 3: the period of the report, its type, users, servers, and `-NoCollect`.
file | Results | Chapter 4: where the report is written, exit codes, the usual warnings.
```

<!-- icon: checklist -->
## 1. Prerequisites

| Item | Requirement |
|---|---|
| Exchange | Exchange Server SE, on-premises. Mailbox servers and Edge Transport servers. |
| PowerShell | **7.4 or later** (`pwsh`) on the collector — a portable zip is enough. **Windows PowerShell 5.1** (built into Windows Server) for `-Mode Discover` only. |
| Account | **Local administrator of every Exchange server** (the logs are read through `\\<server>\C$`). On an Exchange server: **SYSTEM**, nothing to configure. On an administration server: a **domain account** (not a local account), with *Log on as a batch job* on that server. |
| Exchange role | *View-Only Organization Management*, for `-Mode Discover` only. The collection and the reports need no Exchange role. |
| Network | SMB (445) from the collector to every Exchange server. From an administration server, also HTTP (80) to one Exchange server for `-Mode Discover`. |
| Logging | SMTP: `ProtocolLoggingLevel Verbose` on the connectors to analyse. POP/IMAP: protocol log on (optional). HttpProxy, IIS, MAPI and message tracking are on by default. |
| Edge Transport | Its own copy of the tool **on the Edge itself**, run as SYSTEM or a local administrator: SMTP and message tracking only. |

> [!WARNING]
> The collecting account is local administrator of the Exchange servers: treat it like an Exchange administrator account (password in a vault, no interactive logon). The tool itself only reads: it never changes a setting and never sends anything.

The commands to create the account and the group: [developer guide, 4.1](ExchangeLogReport-Guide.md#41-where-to-run-it-and-with-which-account).

### 1.1 One-time setup

```steps
Copy the tool | Unblock the files, then copy the folder to the collector, for example `E:\Tools\ExchangeLogReport`. No installer.
List the servers | `notepad .\config\ExchangeLogReport.config.psd1`: the server names in the `Servers` block are enough.
Check | `.\Invoke-ExchangeLogReport.ps1 -Mode Status` answers **Ready for the first collection**.
Find the log folders | `.\Invoke-ExchangeLogReport.ps1 -Mode Discover`, with **your administrator account** (View-Only Organization Management): SYSTEM has no Exchange role. Read the warnings: folder not readable, logging off.
First collection | `.\Invoke-ExchangeLogReport.ps1 -Mode Collect` with the account of the scheduled task: it reads the last 14 days of logs.
Schedule it | `-Mode Collect` every hour (below).
```

On an Exchange server, as SYSTEM:

```powershell
$action  = New-ScheduledTaskAction -Execute 'E:\Tools\pwsh\pwsh.exe' `
           -Argument '-NoProfile -ExecutionPolicy Bypass -File E:\Tools\ExchangeLogReport\Invoke-ExchangeLogReport.ps1 -Mode Collect' `
           -WorkingDirectory 'E:\Tools\ExchangeLogReport'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(1) -RepetitionInterval (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName 'Exchange Log Report - collect' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest
```

With a domain account on an administration server: [developer guide, chapter 7](ExchangeLogReport-Guide.md#7-scheduled-collection).

<!-- icon: terminal -->
## 2. Everyday use

Run the commands from the tool folder, in PowerShell 7. A report first collects what is new, with the account that runs it; add **`-NoCollect`** to use only what the hourly collection already stored: faster, no access to the Exchange servers needed, and it works while the scheduled collection is running.

### 2.1 Is this server still used?

```powershell
# Every server over 30 days: In use, Client access only, Mail flow only or No real usage
.\Invoke-ExchangeLogReport.ps1 -Range Last30Days

# Before decommissioning EXCH03: who still connects to it, and what still sends mail through it
.\Invoke-ExchangeLogReport.ps1 -Range Last30Days -Server EXCH03
```

Read the **server cards** (verdict, real users, protocols), the **Users** tab (Outlook builds, mobile devices still in use) and the **SMTP clients** tab (applications, printers and servers that still send mail).

### 2.2 A user has a problem

```powershell
# Everything about one user on one day: client sessions, failures, messages
.\Invoke-ExchangeLogReport.ps1 -Date 2026-10-04 -ReportType Detailed -User alice@contoso.com

# This morning only: what Outlook, the phone and the mail client of the user did
.\Invoke-ExchangeLogReport.ps1 -Start '2026-10-05 08:00' -End '2026-10-05 12:00' -ReportType Detailed -User alice

# Several users at once
.\Invoke-ExchangeLogReport.ps1 -Range Last24Hours -ReportType Detailed -User alice, bob
```

Open the **Client sessions** tab: one row per Outlook, ActiveSync device, OWA, EWS, IMAP or POP session, with its outcome (*OK*, *Recovered*, *Intermittent errors*, *Failed*). Click a row for its timeline; click a step to see where its raw log lines are.

### 2.3 A message did not arrive

```powershell
# Messages sent or received by a user over the last 24 hours, with their route
.\Invoke-ExchangeLogReport.ps1 -Range Last24Hours -ReportType Detailed -User bob@contoso.com
```

Open the **Messages** tab: status per recipient (*Delivered*, *Relayed*, *Failed*, *Deferred*...), and behind a click the route through every server and the SMTP transcripts. Mail refused during the SMTP conversation (relay denied, unknown recipient) has its own row: *Rejected (SMTP)*.

### 2.4 An incident on some servers

```powershell
# The incident window on two servers, from the data already collected
.\Invoke-ExchangeLogReport.ps1 -Start '2026-10-05 08:00' -End '2026-10-05 10:30' `
    -ReportType Detailed -Server EXCH01, EXCH02 -NoCollect
```

Open **Failed and slow requests**: all the users of one server failing at the same time is a server incident; *Recovered* means the same user succeeded afterwards, *Unresolved* that the problem stayed.

### 2.5 Monthly review

```powershell
.\Invoke-ExchangeLogReport.ps1 -Range PreviousMonth      # the previous calendar month
.\Invoke-ExchangeLogReport.ps1 -Month 2026-09            # a given month
```

The database keeps **60 days** of usage, messages and SMTP transactions, and **14 days** of detail (client sessions, failed requests, SMTP transcripts): a Detailed report on an older period has less detail.

### 2.6 Edge Transport server

On the Edge itself, the same commands. The report is an **Edge report**: messages through the Edge, **SMTP clients** (who sends to the Edge) and **SMTP destinations** (Exchange Online, the MX of the internet domains, the mailbox servers).

```powershell
.\Invoke-ExchangeLogReport.ps1 -Range Last7Days -ReportType Detailed
```

### 2.7 Is the collection working?

```powershell
# What the database contains, per server and source: dates of the data, last read, noise removed
.\Invoke-ExchangeLogReport.ps1 -Mode Status

# Last result of the scheduled task: 0 = success, 2 = finished with warnings, 1 = failure
Get-ScheduledTaskInfo -TaskName 'Exchange Log Report - collect' | Select-Object LastRunTime, LastTaskResult
```

A source whose newest data is old has stopped writing, or its logs were moved. `0xC000015B` (`3221225819`): the account of the task lacks *Log on as a batch job*.

### 2.8 After a CU, a new server or a moved log folder

```powershell
.\Invoke-ExchangeLogReport.ps1 -Mode Discover        # with your administrator account, then check the warnings
```

A new server is first added to the `Servers` block of the configuration.

<!-- icon: calendar -->
## 3. Period and filters

| Parameter | Values | Example |
|---|---|---|
| `-Range` | `Last24Hours`, `Last7Days` (default), `Last30Days`, `PreviousMonth` | `-Range Last30Days` |
| `-Date` | One calendar day, `yyyy-MM-dd` | `-Date 2026-10-04` |
| `-Month` | One calendar month, `yyyy-MM` | `-Month 2026-09` |
| `-Start` / `-End` | A period, start included and end excluded, in the time zone of the report; an end later than now is replaced by now | `-Start '2026-10-05 08:00' -End '2026-10-05 12:00'` |
| `-ReportType` | `Usage` (default): who uses which server. `Detailed`: + client sessions, failed and slow requests, messages | `-ReportType Detailed` |
| `-User` | Any part of the account (`domain\sam`), UPN or SMTP address; several separated by commas | `-User alice, bob@contoso.com` |
| `-Server` | One or more servers of the configuration | `-Server EXCH01, EXCH02` |
| `-NoCollect` | Report from the data already collected | `-NoCollect` |
| `-OutputPath` | Another folder for the report | `-OutputPath D:\Reports` |

> [!NOTE]
> **No parameter is ignored silently.**
> - `-Date`, `-Month` and `-Start` / `-End` select their period on their own: `-Range` is not needed.
> - `-Start` needs `-End`, and `-Date`, `-Month` and `-Start` / `-End` cannot be combined.
> - A period that contradicts `-Range` (`-Range Last7Days -Start …`) is an error: nothing runs.
> - A parameter that the mode does not use (a period with `-Mode Collect` or `-Mode Status`, for example) is shown in yellow under the banner, with the reason, and the command runs anyway.

<!-- icon: file -->
## 4. Results

Each report is written to a new folder under `reports\`, one per run, named after the report type, the period and the time (`ExchangeLogs_Detailed_…`). The console shows it at the end:

- **`<prefix>.html`** — the report: self-contained, it can be sent by mail or opened without internet access. Search, filters, sortable columns, *Export view to CSV*; click a row for its details.
- **`<prefix>-<view>.csv`** — the same data (Servers, Users, Messages...), always complete: separator `;`, opens directly in Excel.

| Exit code | Meaning |
|---|---|
| `0` | Success. |
| `2` | Finished with warnings: a server, a folder or a file could not be read, a source is stale, or the IIS log folders changed since `-Mode Discover`. The run went to the end: a report run still writes its report. |
| `1` | Failure: read the error in red, and the log file of the day in `logs\`. |

| Warning | What to do |
|---|---|
| *folder not found or not readable* | The account is not local administrator of that server, or the logs were moved: run `-Mode Discover`. |
| *SMTP protocol logging is off on …* (`-Mode Discover`) | That SMTP traffic is not in the reports: set `ProtocolLoggingLevel Verbose` on the connector if it matters. |
| *No log line newer than 24 h for …* / *Logging stopped, or the logs were moved* | The collection or the logging stopped, or the old folder is read: check the scheduled task, then run `-Mode Discover`. |
| *The paths file was written on …* | The tool folder was copied from another computer: run `-Mode Discover` on this one. |

Anything else: [developer guide, Annex A — Troubleshooting](ExchangeLogReport-Guide.md#annex-a--troubleshooting).
