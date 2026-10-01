# Changelog — Exchange Log Report

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the guide, Annex C).
Author: Nicolas Fabert.

## [1.3.1] — 2026-10-01

### Added
- `tools\New-DocumentationImages.ps1`: renders the graphics of the GitHub README (banner, why, how it works, noise, sessions and messages) in a light and a dark version, from the cards and flow blocks of the guide, with its CSS and icons.
- **HTML guide** `docs\ExchangeLogReport-Guide.html`, same format as the other tools (Purview DLP Report): self-contained (images inline), sidebar with parts and chapters, light/dark theme, copy buttons, print layout. Built from the Markdown guide by the new `tools\Build-Documentation.ps1`.

### Changed
- Guide: what is removed before storage (chapter 3) and the client session and message correlation (chapter 11) are now shown as cards and flows.
- Guide reorganised in four parts (Understand, Set up, Use, Maintain) and annexes, with a quick start, cards, steps and callouts; content updated to 1.3 (six tabs, SMTP clients, refusals in Messages).
- The package ships the HTML guide only (rebuilt by `tools\New-ExchangeLogReportPackage.ps1` before copying); the Markdown source and the images stay in the development folder.
- Screenshots of the guide taken from the lab report with generated traffic, anonymised (Contoso names), and a capture of the console of a detailed report.

### Fixed
- Detail dialogs: in the small tables (transactions of an SMTP client, client sessions of a user, clients and devices), times, servers, statuses and counters no longer wrap in the middle of a word.
- Console banner: the subtitle is shorter and can no longer push the right border of the frame.

## [1.3.0] — 2026-10-01

### Changed
- **Simpler HTML report: six tabs** — Client sessions, Failed and slow requests, Users, Operations, Messages, SMTP clients. Every CSV file is still written.
  - *Clients and devices* is now in the detail of each user, with the client sessions of that user (click one to open it).
  - *SMTP sessions* is replaced by **SMTP clients**: one row per SMTP client (address + HELO) with servers, connectors, volume, refusals, recipients, senders, TLS, authentication and last error; the detail lists its transactions (up to 200, refusals first) with their SMTP transcript. Hops between the collected Exchange servers are left out. Also in the Usage report.
  - *Messages* also lists the mail refused during the SMTP conversation (no Message-ID): *Rejected (SMTP)*, *Deferred (SMTP)*, *Not completed (SMTP)*.
  - *Servers* and *Daily* tabs removed: the server cards and the activity chart show them (and their CSV files remain).

### Fixed
- Deliveries to the mailbox servers (port 475, response `250 2.0.0 OK <message-id>`) are now attached to their message: their SMTP session is in the route.
- **Authenticated submissions (port 587)** were lost: the front end hands the session over to a mailbox server right after AUTH, so the front-end session had no `MAIL FROM` and was counted as a connection without message, and the mailbox server logged the front end as the client. The real client is now read from the `XPROXY` command (address, port, HELO) and the front-end part is counted as *Client submission proxied to a mailbox server*.
## [1.2.0] — 2026-10-01

### Added
- **Clickable timeline steps** (Client sessions): every field kept for the request (all the fields of a failed or slow request, or of a `FullDetailUsers` request; time, servers, status and duration otherwise) and **where its raw lines are**: the front-end and back-end log files (server, folder, hourly file) with a ready-to-copy `Select-String` command — RequestId for HttpProxy, IIS and MAPI, time and command for the ActiveSync back end, time and session for IMAP/POP. Raw lines are still never stored.
- Each timeline step keeps the id of its log file (`source_file`) and the text that finds its line; the CSV timeline lists the log files of each step.

### Validated
- Lab: the commands of an Outlook `Execute` (HttpProxy on EXCH02) and of a blocked ActiveSync `FolderSync` (`W3SVC2` on EXCH01, `Error:UserDisabledForSync`) return exactly the raw lines.

## [1.1.0] — 2026-10-01

### Added
- **Client sessions** (Detailed report, tab *Client sessions*, `ClientSessions.csv`): one row per session — what one client did for one user on one day until idle for `SessionIdleMinutes` — with outcome (*OK*, *Recovered*, *Intermittent errors*, *Failed at end*, *Failed*), client, addresses, front-end and back-end servers, requests, failures, slow requests, latency, operations, Outlook version and mode or mobile device, first and last error, and a **timeline** behind a click (every failure, slow request and milestone, the other successes folded into batches). `IncludeSessionDetails` / `-IncludeSessionDetails` adds the timeline to the CSV.
- **Correlation of front-end and back-end logs**: MAPI over HTTP (`Logging\MapiHttp\Mailbox`: Outlook version, cached mode, MAPI status codes behind HTTP 200, same `RequestId` as HttpProxy), ActiveSync (`W3SVC2`, Exchange Back End: `DeviceNotProvisioned`, `UserDisabledForSync`… behind HTTP 200, device access state, protocol version), POP3/IMAP4 (front end and back end).
- MAPI request type (`RT:`) and Outlook client instance (`CI:`) read from `ClientRequestId`; ActiveSync command, device ID and device type from `UrlQuery`.
- **Rejected Basic logons** attributed to their account from IIS (`401.1`, Win32 `1326` wrong password, `1909` locked, `1330` expired…), where HttpProxy only logs an anonymous 401.
- **Slow requests**: successes slower than `SlowRequestMs` (5,000 ms) are kept with outcome *Slow*; long-polling requests are excluded (`LongRunningPatterns`: Outlook NotificationWait, ActiveSync Ping, RPC/HTTP, OWA notifications, PowerShell, IMAP IDLE).
- Usage views **Clients and devices** (user × protocol × user agent or device: versions, addresses, servers) and **Operations** (protocol × operation: share, failure rate, slow, average and maximum latency).
- Optional **POP3 / IMAP4** source (`Sources.PopImap`): connections without logon and failed logons whose account is not logged are noise; back-end commands (with `NO` / `BAD` / `-ERR` results) are attached to the session of the client.
- Identities: `sam` or `sam@upn-suffix` (IMAP, POP, back-end logs) become `domain\sam` when the account is known.
- Database schema 2: tables `access_action`, `access_client`, `client_session`, `session_step`, column `access_usage.slow`; an existing database is upgraded at the next collection.

### Changed
- `ClientAccess-Issues.csv` is now `ClientAccess-Requests.csv` (failed and slow requests, and the requests of `FullDetailUsers`); HTML tab *Failed and slow requests*.
- Retention: client sessions and their timeline follow `DetailRetentionDays`; operations and clients follow `RetentionDays`.
- A log file whose read position is before its end (SMTP, IMAP or POP session still open) is read again at the next collection even if it did not grow, so that the held session is written once the file is idle (log rollover).
- Pester tests: 34 (MAPI front/back end, ActiveSync back end, IMAP front/back end, rejected Basic logon, slow requests, session merge across collections, IMAP connection held back, upgrade of a version 1.0 database).

### Validated
- Lab with generated traffic (Outlook MAPI over HTTP, iPhone ActiveSync with provisioning, OWA forms logon across sites, EWS, Outlook for Mac, IMAP/POP/SMTP client, application SMTP relay, wrong passwords, blocked ActiveSync, malformed EWS requests): see the guide, chapter 14.
## [1.0.0] — 2026-10-01

### Added
- Single entry point `Invoke-ExchangeLogReport.ps1` with three modes: `Report` (default), `Collect` (scheduled task), `Status`.
- Configuration file `config\ExchangeLogReport.config.psd1`, checked at start (all errors listed at once): servers (default administrative-share paths, per-server overrides), sources, noise rules, collection, storage, report, logging.
- Compiled C# engine (`src\Engine.*.cs`, compiled automatically on first use, like Purview DLP Report): incremental reading by byte offset (lines still being written are read at the next run), CSV/W3C parsing without per-field allocation, SQLite storage, CSV and HTML writing.
- Sources: HttpProxy (all protocols), IIS front end (`W3SVC1`), SMTP receive/send protocol logs (FrontEnd, Hub, Mailbox), message tracking (`MSGTRK*.log`). Columns found by name in `#Fields:`.
- Noise removed before storage and counted by reason: health/system mailboxes, computer accounts, Managed Availability probes (AMProbe, MapiHttpClient…), Exchange internal clients, load balancer health checks, anonymous 401 authentication challenges, SMTP sessions without `MAIL FROM` (by remote address), probe messages, shadow redundancy tracking events.
- Client access: daily usage per server × user × protocol; failed requests kept individually with IIS sub-status / Win32 status (`cafeReqId` ↔ HttpProxy `RequestId`); **recovery**: a failure followed by a success of the same user and protocol within `RecoveryWindowMinutes` (any server) is *Recovered*, later the same day *Recovered later*, otherwise *Unresolved*. `FullDetailUsers` keeps the successes of selected users.
- SMTP: one row per mail transaction with HELO, TLS, authentication, recipients, final response, Message-ID and InternalId, session transcript; open sessions at the end of the active file are read again complete at the next run.
- Messages: **one row per Message-ID** consolidated over all servers, with per-recipient status (Delivered, Relayed, Failed, Deferred, Dropped…), overall status, servers and events path, and the full **route** (tracking events + SMTP sessions in order) behind a click; `IncludeRoutingDetails` / `-IncludeRoutingDetails` adds the route and transcripts to the CSV files.
- Reports: *Usage* and *Detailed*, filters `-User` and `-Server`, periods Last24Hours, Last7Days, Last30Days, PreviousMonth, Month, Day, Custom. Every configured server appears with a verdict (*In use*, *Client access only*, *Mail flow only*, *No real usage*).
- Self-contained HTML dashboard (same design as Purview DLP Report): tiles, server cards with protocol bars and daily trend, activity chart, tabs with search, filters, sortable columns, virtual scrolling, detail dialog, export of the view.
- Retention: 60 days (usage, SMTP transactions, message tracking), 14 days (request-level failures, SMTP transcripts, execution logs); incremental vacuum.
- Modern console output (title card, numbered steps, collection table per server and source, noise summary, final card); daily log file; lock against simultaneous collections; exit codes 0 / 1 / 2.
- Pester tests (20) with log files generated in the exact Exchange formats; package tool `tools\New-ExchangeLogReportPackage.ps1`.

### Validated
- Lab EXCH01 to EXCH04, collector on EXCH01 as SYSTEM (PowerShell 7.6.6): 1.00 GB / 2,966,989 lines in 2 min 59 s, 99.9 % noise removed, database 16.4 MB; detailed 30-day report in 0.5 s.

### Known limitations
- Client access usage is aggregated per day: partial first/last days count as whole days (request-level failures are exact).
- An SMTP transaction rejected before the data has no Message-ID and appears only in the SMTP sessions view.
- Noise rules apply to new lines only; data already stored is not reclassified.
