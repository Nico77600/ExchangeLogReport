# Changelog — Exchange Log Report

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the developer guide, Annex C).
Author: Nicolas Fabert.

## [3.0.0] — 2026-11-03

Exchange Log Report now has three ways to read the same collected history: the **Usage** report (unchanged), the **Detailed** report (now with every row, in one file or in a page plus its data folder), and a new **local portal in the browser** that shows client sessions, messages, routes and SMTP conversations on demand, without building a report first. The package is a complete Windows x64 folder with its own PowerShell: nothing to install.

Version 3.0.0 follows 2.1.1 directly (there is no 2.2) and carries the 2.1.0 and 2.1.1 fixes. It replaces the separate `ExchangeLogReportAngular` pilot (0.3.0), which is retired; its changes are listed here.

### What changed for you

- **Portal (`Start-Portal.cmd`): the Detailed report page in your browser.** Opens `http://127.0.0.1:<port>`, bound to this computer only, with a private link per start. The page is the Detailed report's own page (`templates\Report.template.html` and its script), served by Serve on the collected history: the same tiles (with **Users on OAuth**), server cards, activity by day and seven tabs (Client sessions, Failed and slow requests, Users, Operations, Authentication, Messages, SMTP clients); a row opens its timeline, its route or its transcript, and **Export view to CSV** writes the filtered list. It never collects, never sends mail and never changes the database. The page is served by the tool itself: nothing to build or install, no separate web folder.
- **Portal: the day bar.** The portal opens on the day of the newest collected data, in the days of `Report.TimeZone`. The day bar above the overview chooses the days: **1 day**, **3 days**, **7 days**, **Previous day**, **Next day**, **Jump to day**, or **From** / **To** and **Apply** (up to 31 days), with **Server** and **User**; the day buttons show the rows of each day of the open list. It is the only period control of the portal (the static report keeps its From/To inputs under the tabs). The selection is kept in the address, and a new selection cancels the requests of the view it replaces. The page does not refresh itself: after the next collection, reload it or click **Apply**.
- **Portal: every row of a large selection.** A list (client sessions, failed and slow requests, messages) of at most `ClientRowsMax` rows (`-ClientRowsMax`, default 50,000) is loaded in the page and works as in the Detailed report (**Loaded**); a larger one is browsed on the server (**Remote**): the exact total, a scrollbar that reaches any row, the same columns, filters, value lists, search and details, sorted by its time in both directions; a filter that narrows it to `ClientRowsMax` rows loads them in the page (**Server selection**). The caption of a Remote list names the rows of the selection, and the filtered count once the filters are counted. The day buttons scroll to the rows of each day (their tooltip says *Scroll to* the day on a Remote list, *Read* the day *alone* otherwise). **Export view** of a Remote list writes every row of the selection with the filters of the list, with the columns and the cells of the Export view of the page: the server streams the CSV file day by day through a single-use address that only this computer can open, valid for 60 seconds, and the download list of the browser shows its progress. The file has the lines the page would write for the same rows, in the order of the list on the server (by time, then by row): inside the repeated hour of a daylight-saving change, and among rows of the same millisecond in a sort oldest first, the page orders the same lines differently. One export runs at a time, so that the overview and the other tables keep loading while it streams.
- **Portal: filters and search over the whole period.** Every filter, value list and search of a Remote list runs on the server, with the filter language of the report page, over every day of the selection. A filter that an index answers (status, direction, servers, an exact Message-ID, a user) is counted at once; any other one is read day by day under a time budget (`-ScanBudgetMs`, default 2,000 ms), two days at a time, and the result line shows the matches so far and the days searched, with **Stop**. A filter applied while the value lists are still being counted waits for a busy server (**Waiting for the server**); a count or a page that the page no longer needs (a newer filter) stops at once on the server. The first page of every list is read before any list is loaded whole, the value lists of the messages' Status, Direction and Servers appear at once, and a filter typed while the rows of a narrowed selection load is kept. An exact Message-ID (`=<id>`) is found at once when it is stored as typed, in lower case or in upper case; another spelling is searched in every message on request (**Search every spelling**), as the Detailed report matches it in any case. The dotted capital I matches i in the filters of the page and of the portal alike.
- **Portal: responsive under load.** The page loads the overview, the period tables and the lists in three lanes and keeps one request free for what you open. Serve admits at most two aggregate requests (overview, users, operations, authentication) and one export at once, keeps one worker of four for the unfiltered pages, the details and the report description (`Busy` otherwise, and the page waits), and answers a repeated overview, users, operations or authentication request from memory until the database changes. The aggregate requests have 60 s (`-AggregateTimeoutSeconds`), the lists and details 15 s (`-RequestTimeoutSeconds`); a request stopped by its deadline is retried once by the page, and the console prints one line per request stopped by its deadline (`Serve: 504 /api/overview/servers after 60,012 ms (deadline 60 s)`). A request whose page has gone ends on the server without stopping the portal. A database whose mail flow triggers or indexes are missing is refused (`ShapeRequired`) until one collection rebuilds them.
- **Launchers.** `Run-Collector.cmd` (discover, collect, status, reports) and `Database-Storage.cmd` (database audit and maintenance) replace `pwsh -File Invoke-ExchangeLogReport.ps1` in the daily routine. The package verifies its own files before anything runs; a launcher that refuses the package says why and what to do, and `Start-Portal.cmd` (and `Run-Collector.cmd` started without arguments) keeps its window open until a key is pressed. The launchers start a signed release only: an unsigned build is started with `powershell\pwsh.exe -File Invoke-ExchangeLogReport.ps1 … -DevelopmentMode`. `Run-Collector.cmd` uses the server garbage collector: a large first collection is faster and needs several GB of memory.
- **Detailed report with every row.** `Report.MaxHtmlRows` now defaults to 0 (every row of every table). Above `Report.SingleFileMaxMB` (200 MB) the report is a small `ExchangeLogs.html` page plus an `ExchangeLogs_data` folder: keep them together, zip both to send them (e-mail attaches that zip). Tables open while the file loads; a table too large for the computer that opens it offers **Load anyway**. `Report.HtmlLayout` (`Auto`, `SingleFile`, `Folder`) and `-HtmlLayout` choose the layout.
- **Report work folder.** The report's temporary file is written in the report folder, or in `Report.ScratchFolder` when set; choose a folder with enough free space (a very large report needs a few GB). Paths longer than 260 characters are supported. The system temporary folder is never used.
- **Message statuses renamed.** `Relayed` → **Handed off outside collection**, `Delivered and relayed` → **Delivered and handed off**, recipient suffix `(Sent)` → **(Handed off)**. New **Suppressed (by design)** / **(Suppressed)** for mail Exchange chose not to deliver (out-of-office and automatic replies that must not leave, suppressed recipients, empty distribution lists); a distribution list replaced by its members shows **(Expanded)** and is not counted. The `Events` column lists each event once. Update any saved CSV filter on the old words.
- **Sent to external.** A message that a Send connector handed to a mail server outside your organization, and that this server accepted, is **Sent to external** (or **Delivered and sent to external** when some recipients were delivered here), in green, with **(Sent to external)** after each such recipient: in the Messages tab and CSV, the portal and its Status filter. The logs alone decide (a `SENDEXTERNAL` event to a server that is not collected, through a connector that is not internal, accepted by that server, for a recipient whose domain is not one of yours); your domains, and their sub-domains, are learnt from the mail your servers deliver and send, and `Collection.InternalDomains` and `Collection.InternalConnectors` add the ones the logs do not show (journaling, archiving, an internal relay). Mail to your mailboxes in Exchange Online through the connector of the Hybrid Configuration Wizard (`Outbound to Office 365 - …`) stays a hand-off. Anything the logs do not prove stays **Handed off outside collection**. `-Mode Status` says whether the status is on and lists the domains the tool learnt. Only the `Status` and `Recipients` cells of those messages change; every other cell and file is unchanged.
- **Route and transcripts.** The route is in travel order, grouped by submission, with milliseconds and `| submission n` in the CSV; agent steps are folded; a stored SMTP transcript is the one transaction with the opening and closing of its session (earlier transactions are a one-line marker). Transcripts collected before 3.0 are shown as stored.
- **Authentication types of client access.** The reports and the portal show how every client signed in (OAuth, Negotiate, NTLM, Kerberos, Basic, Forms...), for successful requests too, so you can check whether ActiveSync, EWS and Outlook are on OAuth: an **Authentication** tab in the Usage and Detailed reports and in the portal (one row per protocol and type: users, clients, devices; a row opens its users and devices), an **Authentication** column on Users, Clients and Client sessions (a value list in the portal), the overview tile **Users on OAuth**, an **Authentication** line in the report e-mail and **Users on Basic authentication** among the main problems of the Detailed report. Collected logs keep the type as Exchange wrote it; rows collected by an earlier version show *Unknown*.
- **One identity for OAuth users.** Exchange logs token (OAuth) requests by the security identifier (SID) of the account; the collector now pairs that SID with the account from the logs themselves (the account's own ActiveSync, OWA and ECP lines anchored on its mailbox at once; the Outlook back-end lines of the same client once seen on two days) and merges the rows, so a user is one row in Users, Client sessions and the **Users on OAuth** tile. Any disagreement between the lines makes a SID ambiguous and nothing is merged; a collection applies the evidence it reads at its end, so the result does not depend on the order of the files; a later disagreement keeps the merge and names the account in the log and in `-Mode Status`. The rows already stored under a SID are renamed and merged exactly (daily figures added, client rows merged, overlapping sessions joined); a `sam@suffix` row of a resolved account merges too, so a user who was two rows becomes one. SIDs stored while no evidence was gathered are named from the ActiveSync, OWA and ECP lines already collected, read again for their evidence within `Collection.EvidenceRescanMBPerRun` per collection, over several collections if needed. A SID the logs cannot name stays visible as a SID (an **unresolved SID** pill, an **Identifiers** table with its evidence and hints, a line in `-Mode Status`), and `Collection.IdentityMapFile` names it; a SID named before its first token request reads *resolved (paired in advance)* in the **Identifiers** table, as in `-Mode Status`; `Collection.ResolveSids = $false` keeps the SIDs as logged. No directory is queried. The 3.0.0 database gains the small `identity_map` table (created at the next collection; a storage copy opened writable adds it empty). The CSV files keep their columns.
- **SMTP clients** are pre-aggregated per client and hour (fast lists in the portal); the authenticated user, the Edge report, the `web.config` log-folder discovery and the memory-bounded Detailed report of 2.1 are unchanged.
- **Database maintenance (`Database-Storage.cmd`).** `--storage-audit` measures what takes space (read-only JSON); `--storage-copy` writes a **new** compacted (`--vacuum`), migrated (`--migrate`) or repacked (`--repack`) copy and verifies it; the original is never changed. Needed only when the portal refuses an older database or to measure. A copy into a deep folder (paths longer than 260 characters) works as any other; a destination whose staged copy would pass the 1,040 bytes of a SQLite file name is refused before anything is written. It runs in the bundled PowerShell and starts in a few seconds.
- **Time zone.** The delivered `Report.TimeZone` is `Romance Standard Time` (as in 2.1.1); `Europe/Paris` still works.
- **Faster lists and counts on large databases.** Schema 12 adds covering indexes for the messages and client sessions of a period and bounds the index range by the longest stored journey and session: a day far from the newest data reads only that day's index range.
- **Portal messages as in the Detailed report.** The portal's messages are the tracked messages and the mail refused during the SMTP conversation, as in the Detailed report: an SMTP transaction with a Message-ID and no tracking event (its server's tracking logs are not collected) stays in the transactions of its SMTP client. In the derived rollup such a sent transaction is now **Sent (SMTP)** (it was *Not completed (SMTP)*), and the two rollup covering indexes also hold `events_count` and `kind`. A database written by an earlier 3.0.0 test build gets both at its next writable open (one collection) or by `--storage-copy --migrate`; until then the portal refuses it (422 `MigrationRequired`).
- **Portal overview of a week in seconds.** Schema 12 keeps the mail flow per hour and server (`mail_flow_hour`, derived from the rows and verified by recomputation) and the route servers in the rollup indexes: the overview reads them instead of every tracking event and SMTP transaction of the period, with the figures of the Detailed report. A database written by an earlier 3.0.0 test build gets them at its next collection (or `Database-Storage.cmd --storage-copy --migrate`); until then the portal refuses it (`MigrationRequired`).
- **Faster verification.** `VerifyServeRollups` and the storage copy verification read the tracking and SMTP tables once in message order (sorted next to the database: keep about 15 % of its size free there) instead of looking every message up; every check is kept. A run stops after 600 s without progress or at 24 h, and reports its estimate from the file size, the peak size of its sort files (`SortPeakBytes`) and the longest time between two heartbeats (`MaxProgressGapMs`).

### Breaking changes

1. **Database schema 6 → 13.** The first collection (or the first report) with 3.0 upgrades the database, each schema step in one transaction, and re-reconciles every tracked message once (from a schema-12 database written by a 3.0.0 test build, only the messages with a `SENDEXTERNAL` event). Plan exclusive write access of about 3 to 5 minutes, plus a few minutes to build the covering indexes, and 6 GB of free disk for a 20 GB database (less for a smaller one). **A database upgraded by 3.0 cannot be opened by 2.x again.** The portal never upgrades a database: it refuses an older schema and says so. Schema 12 keys `access_client` by the authentication type too and adds `client_session.auth_modes`; a database written by a 3.0.0 test build without them is folded at its next writable open (a report or `-Mode Status` on it folds it once too), and the portal refuses it (`MigrationRequired`) until then.
2. **Layout unchanged for the collector.** `config\`, `data\`, `reports\` and `logs\` stay where 2.1.1 had them, and a scheduled task that runs `pwsh -File <folder>\Invoke-ExchangeLogReport.ps1` keeps working. The package adds `powershell\` and `sqlite-tools\` beside them and the launchers at its root.
3. **No .NET host.** The pilot's `host\ExchangeLogReportAngular.exe` and its report portal (`--reports`, `--port`, `--scratch`, `--ready-file*`, `--edge`, `/api/reports`) are gone, and `host\` no longer exists. A 3.0.0 test build updated in place must lose its `web\` folder and `Angular-THIRD-PARTY-LICENSES.txt`: the package verifier refuses them as unexpected files. `Database-Storage.cmd` keeps the same commands, options, JSON output and exit codes; it now runs in the bundled PowerShell and starts in a few seconds.
4. **`Report.MaxHtmlRows`.** A configuration written by 2.x still says `200000`: the HTML tables stay capped and a warning names them. Set it to `0` for every row. New keys with safe defaults: `Report.HtmlLayout`, `Report.SingleFileMaxMB`, `Report.ScratchFolder`, `Collection.DeferRollups`, `Collection.InternalDomains`, `Collection.InternalConnectors`.
5. **Status words and CSV columns** (above): `Status`, `Route`, `Events` values changed. `ClientSessions.csv` has a new column `Authentication` before `Timeline`, which moves to column 27 (written only with `IncludeSessionDetails`): read it by its header name. `Users.csv` and `Clients.csv` gain a last column `Authentication`, and a new `Authentication.csv` is written. Every other column keeps its place.
6. **Package integrity.** The owner-signed manifest `PackageIntegrity.psd1` now also covers the launchers, the report page script, the SQLite tool and the PowerShell runtime; the verifier is `src\Test-PackageIntegrity.ps1`, as in 2.1.
7. **Requirements.** Windows x64 only for the portable package (the collector scripts still run on any PowerShell 7.4+). `-Mode Discover` still uses Windows PowerShell 5.1 and the Exchange cmdlets.

### Fixed

- SQLite paths use Windows extended paths (as in 2.1.0): database, collector workers, report work file and storage tool; the 240-character work-folder rule of the pilot is gone, and the remaining bound is the 1040 bytes of the SQLite Windows VFS.
- The delivered `Report.TimeZone` and the default used when it is absent are `Romance Standard Time`, the native Windows Paris zone (as in 2.1.1). Winter/summer rules and explicit `Europe/Paris` configurations remain supported.
- The resolver memory tests measure the live heap after a collection (`GC.GetGCMemoryInfo`) instead of the heap size including garbage not yet collected, so the 16 MB bound no longer depends on the cache size of the processor; the threshold is unchanged.

### Upgrade from 2.1.1, step by step

1. **Back up** `data\ExchangeLogReport.sqlite` (stop the hourly task first; with WAL, copy `.sqlite`, `-wal` and `-shm` together or use a SQLite backup). Keep that copy until you are satisfied: 2.x cannot read the upgraded database.
2. Extract `ExchangeLogReport-3.0.0-win-x64.zip` into a **new** folder (for example `E:\Tools\ExchangeLogReport-3.0`). Check the signature of `Invoke-ExchangeLogReport.ps1` (Properties, Digital Signatures: Nicolas Fabert).
3. Copy your `config\ExchangeLogReport.config.psd1` (and `config\ExchangeLogReport.paths.psd1`) and your `data\` folder **to the same relative places** in the new folder (or set `Storage.DatabasePath` to its current place). In the configuration, set `MaxHtmlRows = 0` (or keep a cap on purpose).
4. Run `Run-Collector.cmd -Mode Status`: it shows the schema upgrade to 13 and the retained history. The first run can take minutes on a large database; do not stop it.
5. Re-point the scheduled tasks to `Run-Collector.cmd` (README, Get started), delete the 2.x tasks, then `Run-Collector.cmd -Mode Collect`.
6. Run a report as before (`-Mode Report -ReportType Detailed -Range Last24Hours`) and open the portal (`Start-Portal.cmd`). Remove the 2.x folder when you no longer need it; never point 2.x at the upgraded database.

### Validation

Validated on the staging tree of this release and on its built package, under the package's own PowerShell 7.6.7 and Pester 6.1.0 with `Set-StrictMode -Version Latest`: the collector and report suite (271 tests), storage maintenance (44, run in its own process), SQLite optimization (49), the comparison with 2.1.1 (41), the Serve suites (backend 160, the portal page in a hidden headless Microsoft Edge 75, rollup verification 141, SMTP clients 36, initialization 10, performance 3, measurement gate 3), the workflows (14), package integrity (30, plus 5 that need the owner signature and run on the signed release), the packaged Serve and storage suites against the built package on a synthetic database (5 and 5), the PSScriptAnalyzer stage (no syntax error) and a build of the package. The two resolver memory tests keep the 16 MB bound. Starting the storage tool compiles the engine and the storage sources in memory: about 4 s with a warm file cache, 7 s cold. Figures of the earlier measurements below are historical lab results, not capacity guarantees.

### Details
#### Message status, transcripts and route
##### Changed
- Message status: `Relayed` becomes `Handed off outside collection`, `Delivered and relayed` becomes
  `Delivered and handed off`, and the per-recipient suffix `(Sent)` becomes `(Handed off)`. The labels appear in the
  Messages CSV, the static report and the Serve message status filter and rollups.
- Message status: `Suppressed (by design)` (overall) and `(Suppressed)` (per recipient) cover mail the organization
  chose not to deliver: out-of-office replies and automatic forwards or replies that must not cross the boundary
  (`RESOLVER.OOF.*`, `RESOLVER.MSGTYPE.AF/AR`), recipients suppressed by `RESOLVER.MER.Suppressed`, and a distribution
  list that expanded to no member. Rule-deleted mail (`StoreDriver.Rules`), transport-agent deletions and the other
  drops stay `Dropped`.
- A distribution list that was replaced by its members is shown as `(Expanded)` after the real recipients and is not
  counted; the DROP that only reports the expansion is no longer an event of its own.
- The `Events` column of the Messages CSV and static report lists each event once, in order of first appearance (Serve
  rollups already did).
- Schema 12: the message rollup triggers watch `recipient_status` and `related_recipient`, and the migration reconciles
  every tracking identity again in one transaction (rows keep their ids). Serve refuses a schema-11 database until a
  writable collection or a verified copy migration has run.
- Message status: `Sent to external` (overall), `Delivered and sent to external` and `(Sent to external)` (per
  recipient) for a recipient that a `SENDEXTERNAL` event proves left the organization: its next host (`server-hostname`,
  else `server-ip`) is not a collected server (configured, a server of the same message, or an address the logs show for
  a collected server), its connector is not internal (`Intra-Organization SMTP Send Connector`, `EdgeSync - Inbound to `,
  `Inbound Proxy `, `Outbound to Office 365`, plus `Collection.InternalConnectors`; an event without a connector counts as
  internal), its `recipient-status` is a `2xx` reply, and its domain is known and not accepted. The accepted domains are
  learnt by the collector from the recipients of `DELIVER` and of `Incoming` `RECEIVE` and the senders of `STOREDRIVER`
  `SUBMIT`/`RECEIVE` (at most 4,096), then from the senders of other `Originating` events (only while fewer than 1,024
  are known), plus `Collection.InternalDomains`; a learnt or configured domain covers its sub-domains. Without any known
  domain no recipient is sent to external, and a domain of the first sources that arrives when 4,096 are known turns the
  status off for the database (`saturated` in the rules, a warning in the collection log and in `-Mode Status`). `SEND`
  stays `Handed off`, and so does the route step: the `Route` cell is unchanged. The static report, the portal, the
  rollups and both verifications read the same stored rules (`metadata` `mailflow_accepted_domains` and
  `mailflow_rules`). Other configured lists, the first known domain or a full set rewrite the rules with the next commit
  and queue every message with a `SENDEXTERNAL` event again; the other domains and addresses a collection learns are
  kept in `metadata` `mailflow_pending` with each commit and applied once at its end, with one scan that queues only the
  messages with a recipient in those domains (or their sub-domains) or sent to those addresses (an interrupted collection
  leaves them to the next one). Rules of another rule version keep their learnt domains. A schema-12 database is verified
  without the external status.
- Schema 13: the `message_event` UPDATE rollup trigger also watches `connector`, `server_ip` and `server_host`. The
  migration from schema 12 is one transaction: the triggers, then one pass over the stored tracking events that learns
  the accepted domains and the addresses of the collected servers and queues the identities with a `SENDEXTERNAL`
  event, the rules written in `metadata`, then those identities reconciled again (ids kept, the sequence only moves
  forward). Its time is bounded by the size of `message_event` (one full read) and by the number of messages with a
  `SENDEXTERNAL` event (their rollup rows are rewritten, and the WAL grows by about those rows): on a large database,
  measure it on a copy first. An interrupted migration leaves schema 12, and the next writable open runs it again;
  Serve refuses a schema-12 database until then. A report or `-Mode Status` that opens an older database upgrades it
  once, under the collector lock: it waits up to 2 minutes for a running collection, then stops and asks to run it
  again after the collection. Report pill: the two new statuses are green (on an Edge report too), and the recipients
  heading of a mixed message counts the recipients sent to external and those handed off.
- Users, Identifiers: a SID resolved before any of its own lines reads `resolved (paired in advance)`, as `-Mode Status`
  counts it.
- Storage maintenance (`Database-Storage.cmd --storage-copy`): schema 13 is the current schema; `--migrate` takes a schema
  6 to 12 copy to schema 13 (a schema-12 copy: the tracking rows of the messages with a `SENDEXTERNAL` event recomputed,
  the two `metadata` rows of the rules excluded from the comparison and verified by recomputation, the dictionary rows
  above the source maximum allowed). A schema-12 source copied without `--migrate` is verified by the engine rules without
  the external status. The tracking rollup rows of a schema 8 to 11 source are recomputed by the current recipient rules
  during the copy migration and verified by exact recomputation; every other column, every id, every SMTP-only row and
  every dictionary row is compared with the source, and `sqlite_sequence` of `message_rollup` is verified not lower. A
  schema 8 to 11 source (live, or copied without `--migrate`) is verified with the recipient rules it was written with
  (frozen in the storage tool), not with the current rules. The evidence report names the rule set (`derivedRollups.rulesVersion`)
  and the recomputed columns (`rollupRules`). The free-space reserve (three times the source) also covers the WAL of the
  reconciliation.
- SMTP transcripts: a stored transcript is the one transaction it belongs to, with the opening of its session (connection,
  banner, EHLO, STARTTLS, authentication, redacted as before), the lines that led to its MAIL FROM, and the closing of the
  session. The transactions before and after it are replaced by a marker with their line count, so a session carrying
  many messages no longer repeats the same conversation in every row. The opening is cut at 4,000 characters and the
  transcript at 12,000, and the transaction itself is never the part that is cut first. Transcripts stored by earlier
  collections are not rewritten.
- Route: the Messages route is rebuilt in the order the mail travelled instead of the order the logs were written
  (a front end logs its conversation when it ends), and each step carries its submission number and UTC milliseconds.
  The CSV `Route` shows the time with milliseconds and ends each line with `| submission n`. A distribution list and its
  expansion are one `EXPAND` step, a hop and its delivery are one `SEND > DELIVER` step (the folder is named when it is
  not the Inbox), identical consecutive deferrals or drops are one step (`DEFER ×n`), and drop reasons are written in
  words. Mail refused during the SMTP conversation has the same step shape.
- Messages (static report and Serve): the route is grouped by submission, with a header telling who submitted the
  message, or that its origin is outside the collected logs. Agent steps (`AGENTINFO`) are hidden behind a "Show agent
  steps" button, drops the organization chose are neutral, and the recipient list reads "N recipients + M expanded
  lists".
- Route submissions: an SMTP conversation received from another collected server, or sent without a tracking RECEIVE
  behind it, belongs to the submission of the tracking `SEND` that carried it instead of starting a new one; only mail
  entering through a front end, an Edge or an unknown host starts a submission. The "(+n)" of a long recipient list is
  no longer shown as a recipient chip.
- The schema 12 migration queues each message once; the first open after the upgrade re-reconciles the message
  rollups of every tracked message, so its duration grows with the database.
- Route, DELIVER steps: the folder of each recipient is read from its own entry of the status (an item id with its
  delivery and client submit times is the Inbox, `DefaultFolderType:X` a default folder, any other text the folder an
  Inbox rule moved the item to). A recipient filed in Junk Email is no longer shown in the Inbox because another
  recipient of the same step was, and a transport status in a DELIVER (an SMTP code such as `250 2.0.0 Delivered`, a
  `RESOLVER.`, `QUEUE.` or `StoreDriver.` text) is shown as it is instead of as `folder «…»`.
- Route submissions: an SMTP conversation received by a front end, an Edge or from an unknown host is paired with the
  tracking RECEIVE it queued on the same server when their internal ids differ or are missing (a reply without
  `InternalId=`): within a minute, the RECEIVE that shares the most of a recipient, the sender and the client (HELO name
  or address), each RECEIVE with one conversation. Both get the same submission, and the conversation is placed just
  before its RECEIVE. The static report reads the recipients of the conversations for this (Serve already did).
- Serve rollup verification: the statements of the per-identity checks are prepared once and bound again for every
  identity instead of being prepared for each one, and the second SMTP `MIN/MAX(time_ms)` read per identity is gone
  (the bounds come from the `COUNT/MIN/MAX` statement that already counts the same rows). The statements, the
  comparisons and the deadline of the release gate are unchanged. Measured on a local synthetic store (93,637 identities,
  same machine, three runs each): 36.6-39.8 s before, 17.7-18.8 s after.
- Serve rollup verification deadline: the default deadline of `VerifyServeRollups` (both entry points) is 300 s or 300 µs
  per row of `message_rollup` plus `smtp_transaction`, whichever is larger, at most 24 h (the rows are counted in the
  verification snapshot through their covering indexes; 150 µs per row is the rate measured on the reference VM before the
  prepared statements, doubled for cold caches, slower disks and shared VMs). An explicit `VerifyServeRollupsWithDeadline`
  wins and accepts 1 to 86,400 s (was 3,600). `Store.VerifySmtpClients()` uses the same rule over `smtp_transaction`. The
  result reports `DeadlineSeconds`, `DeadlineExplicit`, `DeadlineRows` and `IdentitiesPerSecond` (`SmtpClientVerification`:
  `DeadlineSeconds`, `DeadlineRows`), and a timeout names the deadline, how it was set, and the identities verified and
  the time spent before it. The verification holds one read snapshot for its whole run, so in WAL mode what a collection
  commits meanwhile stays in the `-wal` file: run it when no collection is running, or on a `VACUUM INTO` copy. The
  five-minute target on the 100,000-message reference fixture is kept as a performance test of its own.
- Storage maintenance (`Database-Storage.cmd --storage-copy`): the rollup verification runs twice per maintenance, on the
  live source and on the staged copy, with no deadline. Its duration grows with the rollup rows (about 18 minutes per pass
  for 5.5 million rows on 2 vCPU). The source file is held read-shared for the whole run, so a collection cannot write to
  it meanwhile: schedule the maintenance outside collection (stop the scheduled task, or between two collections). The
  JSON report books the source pass as its own phase, `sourceRollupVerification`.
- Storage maintenance rollup verification: both passes (live source and staged copy) use the per-identity statements of
  the Serve verification, prepared once per pass and bound again for every identity, and read the SMTP time bounds from
  the `COUNT/MIN/MAX` statement that already counts the same rows instead of a second `MIN/MAX(time_ms)` query. Both
  recipient rule sets (schema 12 and the frozen schema 8 to 11 rules) use them. The statements, the comparisons and the
  failures are unchanged; the report states `derivedRollups.preparedStatements`. Measured on a local synthetic store
  (93,637 identities, 321 MB, one verification pass, four runs each on a shared machine): 40.1-47.9 s before, 8.8-20.3 s
  after.
- Route submissions: without an internal id, only an accepted conversation (status `Accepted`) is paired with a tracking
  RECEIVE; a deferred or rejected attempt of the same client shortly before (same sender, recipients and HELO, a 4xx/5xx
  reply) no longer takes the RECEIVE of the accepted retry and does not start the submission of the message. The pairing
  needs the conversation and the tracking RECEIVE on the same server: a front end proxying to another mailbox server is
  still not paired.
- Route, DELIVER steps: a delivery time alone in a recipient entry (without the item id before it) is read as the Inbox,

#### Schema 9 and measurement-harness corrections
- Schema 9 replaces schema 8 for Serve. Existing schema-8 databases are upgraded only by a writable
  collector/Store open or by `Database-Storage.cmd --storage-copy --migrate` on a new copy; Serve still never
  migrates a source. The upgrade is one transaction that changes no source or `message_rollup` row.
  - Drops `ix_msg_hash` and `ix_smtp_hash` (strict prefixes of `ix_msg_identity_time` / `ix_smtp_identity_time`;
    no query filters on the hash alone) and `ix_session_latest` (the session list reads `ix_session_time` backwards).
    The exact binary `message_id` comparison after every hash lookup is unchanged.
  - Recreates `ix_smtp_latest`, `ix_rollup_last` and `ix_rollup_status_last` ascending (the rowid `id` is their implicit
    last key, so `ORDER BY ... DESC, id DESC` is a backward scan without a sorter) so appends in time order fill pages.
  - Narrows the `UPDATE OF` column lists of the rollup triggers to the columns the rollup is derived from.
    Dropped from `message_event`: source, internal_id, recipient_status, client_ip, client_host, server_host,
    connector, source_context, related_recipient, reference. Dropped from `smtp_transaction`: role, connector,
    remote_ep, local_ep, helo, tls, auth, rcpt_count, auth_user.
  - Fresh and schema 6/7/8 databases end with the same index/trigger set; `VerifyServeRollups` and the storage
    maintenance verification require that exact set (schema-8 sources are still verified against their own shape).
- `ReconcileMessageRollups` prepares its statements once per call and reads the SMTP count and time bounds of an
  identity in one query; stored rollup values are unchanged. Collection statistics now report
  `message rollups N s (K keys)`.
- Comparison harness: a `.sqlite-wal`/`.sqlite-shm` sidecar that vanishes during output sampling is also recognised when
  the not-found error is wrapped in an invocation exception; other errors still stop the run. The child receipt keeps the
  engine's per-phase `Statistics` string as `collectionStatistics` (null when an engine does not provide it).
- Serve and the storage tools required/produced schema 9 at this step; schema 10 below supersedes it.

#### Schema 10, collection without triggers while applying, SMTP clients memo
- Schema 10 replaces schema 9 for Serve and the storage tools. Databases of schema 6, 7, 8 and 9 are upgraded only by a
  writable collector/Store open or by `Database-Storage.cmd --storage-copy --migrate` on a new copy; Serve never migrates.
  One transaction, idempotent, rolled back as a whole on any failure; no source row, `message_rollup` row or dirty-queue
  row changes. A fresh database and databases migrated from 6, 7, 8 or 9 end with the same `sqlite_master`
  (index/trigger/derived-table definitions are compared by the tests).
  - `ix_msg_identity_time` / `ix_smtp_identity_time` keep `(msg_hash,time_ms)` only (the rowid `id` is the implicit last
    key, so `ORDER BY time_ms,id` needs no sorter). The hash is still only an accelerator: every lookup keeps
    `msg_hash=@h AND message_id=@m COLLATE BINARY`, the exact compare now being made on the table row.
  - New table `source_fields(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)` and column `source_file.fields_id`: the
    `#Fields` header text of a log file is stored once per distinct text. The migration inserts the distinct texts,
    points every row at its text, compares every row byte for byte with its dictionary text, and only then clears the
    old `source_file.fields` (a mismatch aborts the migration). Readers use `COALESCE(dictionary text, fields)`, so a
    row without `fields_id` (a non-text value, or a row written by an external tool) is still read from its own column.
    The collector writes `fields=NULL, fields_id=<id>`; the text round-trips byte for byte (tests include empty text,
    CR/LF, padding, case variants, Unicode and a 5000-character header).
  - `VerifyServeRollups` and the storage maintenance verification require the schema-10 objects (and a `fields_id` that
    points at an existing dictionary row); schema-8 and schema-9 sources are still verified against their own exact
    shape. The verifier groups the exact identities with one sequential table scan and a sorter (`NOT INDEXED`), since the
    narrowed index no longer carries the Message-ID. The copy fingerprint compares the logical `#Fields` text, not its
    storage form; the maintenance receipt lists the added table/column as an exclusion and reports `fieldsDictionary`.
- The collection apply thread no longer runs the rollup/hash triggers on its own write connection
  (`SQLITE_DBCONFIG_ENABLE_TRIGGER`, switched off before its statements are prepared and switched on again in a `finally`,
  also after a failure or a cancellation). With a trigger whose body or WHEN calls a function, SQLite opens a statement
  journal for every INSERT inside the batch transaction. The effects of `tr_message_event_rollup_insert` and
  `tr_smtp_transaction_rollup_insert` are written by the code instead, for every row that was really inserted: the
  `message_rollup_dirty` upsert `('message', Message-ID, hash)` and, for an SMTP row without Message-ID,
  `('smtp', rowid, NULL)`, flushed in the same transaction before the reconciliation. The hash is still bound by the code
  and the exact BINARY Message-ID compare is unchanged.
  - Triggers stay defined and active for every other connection (Serve, verifiers, external writers) and outside the
    apply window; `Store.Purge` enables them again before deleting. Trigger-based protections or audit triggers that
    an administrator added to this database are not run by the collector's own apply thread.
  - Writes audited while the triggers are off: INSERT OR IGNORE into `message_event` / `smtp_transaction` (reproduced),
    `UPDATE smtp_transaction SET auth_user, auth_mechanism, auth_result, auth_attempt_result, auth_source,
    auth_evidence_id` (none of these columns is in the schema-9 `UPDATE OF` lists of the rollup or hash triggers),
    and no DELETE (retention runs in `Purge`, with triggers on).
  - `CollectorOptions.DisableTriggersDuringApply` (default `true`) keeps the old path available; `RollupQueueTrace`
    records the queue just before each reconciliation for the equivalence test.
- SMTP clients: the `exl_remote_host` SQL function is memoized per request connection (bounded, thread-safe); the
  response bytes are unchanged.
- Test expectations changed by the schema bump: schema 9 became 10 in the Serve/rollup/storage tests; the "newer
  schema" fixtures use 11; the failure injections that are SQL triggers on `message_rollup`, `smtp_auth_fragment`,
  `smtp_transaction` or `source_file` run with `DisableTriggersDuringApply = $false`, and a trigger-free injection
  (exhausted rollup sequence) covers the default path.
- Observed on scratch copies of synthetic data only (no 24 GB benchmark; the machine was noisy, results are not a promise):
  - Size, storage copy with `--vacuum`, schema 9 versus `--migrate --vacuum`: 299,500-event copy 649,314,304 to
    622,018,560 bytes (`source_file` 15,663,104 to 4,669,440; the two identity indexes 21,495,808 + 3,031,040 to
    7,176,192 + 1,032,192); 29,955-event copy 88,260,608 to 75,694,080 bytes.
  - Apply thread, 315,714 tracking events: rows 19.2 s with the triggers on versus 3.6 s with them off on a quiet run
    (wall 29.2 s versus 9.5 s); repeated runs on a loaded machine varied widely (rows 17.0 to 36.7 s with the triggers off,
    37.3 to 38.8 s on). With one batch, one parse thread and ids included, message_rollup and both source tables hashed
    identically for the previous engine, the trigger path and the code path (two passes each).
  - `message_rollup` rows of kind `smtp` are identified by the rowid of the transaction, which depends on the order in
    which parsed files reach the apply thread; two runs of the same logs with several parse threads therefore differ in
    those identities with or without triggers. VerifyServeRollups passes in every case.
  - SMTP clients endpoint, 100 rows: median 1275 and 1343 ms without the memo, 1156 and 1260 ms with it, same body hash.
#### Schema 11, pre-aggregated SMTP clients, message_rollup dictionary codes
- Schema 11 replaces schema 10 for Serve and the storage tools. Databases of schema 6 to 10 are upgraded only by a writable
  collector/Store open or by `Database-Storage.cmd --storage-copy --migrate` on a new copy; Serve never migrates. A fresh
  database and a migrated one end with the same `sqlite_master` (the tests compare it from every earlier schema).
- **SMTP clients.** The list, the export, the detail and the transactions of an SMTP client no longer group every transaction of the period at
  each request. New tables `smtp_client_value` (dictionary of the text values), `smtp_client` (one row per client: server NOCASE, direction,
  role, connector, peer, HELO, account), `smtp_client_hour` (additive counters per client x UTC hour x status/TLS/mechanism/result/attempt/source)
  and the queues `smtp_client_pending` / `smtp_client_dirty`; new column `smtp_transaction.client_id` (NULL when no endpoint was observed: such a
  transaction stays a group of its own); new indexes `ux_smtp_client`, `ix_smtp_client(client_id,time_ms)`, `ix_smtp_unknown_peer` (partial) and
  `ix_smtp_client_hour(hour_ms,client_id)`; three triggers (`tr_smtp_transaction_client_insert/update/delete`) for every writer that is not the
  collector's apply thread, the retention and a collection that keeps the triggers on.
  - Serve reads whole hours from the buckets and only the partial hours at both ends (and the transactions without client) from the rows. A page is
    found newest hour first (stopping as soon as a whole hour has produced enough clients, which is exact because every older client ranks after
    them) and only those clients are aggregated; a user filter (substring LIKE) reads the matching rows newest first and completes the candidates
    through `ix_smtp_client`; the export aggregates the buckets in SQL. A period of sparse data jumps over empty hours.
  - The answers are unchanged: same ids (`MIN(id)` of the group in the selection), same cells and types, same errors (404 for an unknown or
    out-of-selection client), sets sorted in ordinal order, same order. `tests\Serve.SmtpClients.Tests.ps1` compares the HTTP answers with the
    schema-10 query (kept as a test-only reference, `SmtpClientReference.cs`, run on a schema-10 copy of the same data) on a randomized edge-case
    fixture (empty/NULL/IPv6/odd endpoints, case, NULL and empty HELO/role/connector, every evidence source including the retired Overflow, hour
    boundaries, many rows in one millisecond, LIKE wildcards, pages and sizes), 3 seeds x 600 cases, after the reconciliation of an external writer
    and after the 10 to 11 migration.
  - The collector maintains the structures itself in the batch transaction (`Engine.SmtpClients.cs`, `SmtpClientMaintenance`): the client of a
    transaction is computed before the INSERT, the account resolved by the authentication resolver moves the transaction to the client of its
    account (re-keyed in memory when the batch inserted it, otherwise both buckets are recomputed from the rows), a client left without transaction
    is deleted, and a rolled back batch forgets what it created. Memory is bounded whatever the batch size (small key cache, early write of the
    pending buckets, streamed recomputation). With `DisableTriggersDuringApply = false` the triggers queue the work and the batch commit drains it.
  - `ReconcileMessageRollups` (and `RefreshServeRollups`, and `Purge`) also drain the SMTP client queues. While a queue is not empty Serve answers
    **503 `SmtpClientsPending`** (`RollupPending` when the rollup queue is not empty either) instead of an out-of-date list.
  - `VerifyServeRollups` also proves the structures (`SmtpClientsVerified`, `SmtpClientRows`, `SmtpClientHourRows`; `Store.VerifySmtpClients()` alone):
    every `client_id` equals the key recomputed from its row (NULL if and only if there is no observed endpoint), no duplicate or orphan client, no
    dangling reference, and `smtp_client_hour` equals the grouping of the rows in both directions; the canonical tables, indexes and triggers are part of
    the exact schema check. `ExplainSmtpClients` lists the plan of each statement of the list.
  - `Identity.RemoteHost` (was `ServeRead.RemoteHost`) is shared by the collector, the migration, Serve and the verifier; the `exl_remote_host` SQL
    function is registered on every Store connection.
  - Known limit: `INSERT OR REPLACE` by an external writer deletes the replaced row without running the DELETE trigger (SQLite runs it only with
    `recursive_triggers`); the verification reports the difference. The collector and the retention never use it.
- **message_rollup (dictionary codes, B1/B3/B4).** `message_rollup_value(id,text UNIQUE)` holds the repeated texts; `kind` is 0 (message) or 1 (smtp)
  and `status`, `direction`, `servers`, `events` are integer codes (NULL stays NULL for the three nullable ones). `first_ms`/`last_ms` are NULL when
  equal to `member_first_ms`/`member_last_ms` (readers use COALESCE). `ix_smtp_latest` is dropped (`ix_smtp_flow` starts with `time_ms`) and listed
  among the obsolete indexes; `ix_rollup_status_last` is `(status,member_last_ms)` without collation.
  - The integrity constraint **`UNIQUE(kind,identity)` and the upsert that relies on it are kept** (the replacement of that constraint by code was
    measured but is not part of this schema); `kind` additionally has `CHECK(kind IN(0,1))`. The upsert no longer rewrites `msg_hash`.
  - The status filter is resolved to codes first, with the same case-insensitive text comparison: no code gives an empty page, one code an equality
    on the ordered index, several codes (texts that differ only by case) an `IN` list. `OverviewCounts` decodes the groups and sorts them in ordinal
    order. Dictionary codes are never reused and are stable only within a database: compare two histories through the decoded content.
- **Message counts and lists.** Without a server or user filter the membership test is wrapped in
  `CASE WHEN member_first_ms>=@from AND member_last_ms<@to THEN 1 ELSE <exact test> END`: `member_first_ms` is the time of an existing event or SMTP
  row and never exceeds `member_last_ms`, so a journey entirely inside the period has a member in it. The result is identical (tests compare the counts
  and the first page with the plain predicate on 120+ random periods); the exact source lookups are only done for the journeys that cross a bound.
  The counts statement fixes its access path: the range of `ix_rollup_last` when at most 10 percent of the table ends at or after the period start,
  otherwise one sequential read of the table (`NOT INDEXED`); left alone the planner walked the whole status index.
- **Migration 10 to 11** (`MigrateSchema11`): one transaction, any failure rolls back everything (tests inject a failure at the version write and at the
  client assignment). The rollup keeps its ids and its AUTOINCREMENT sequence (read before the old table is dropped, re-applied as `MAX(seq, old)`), the
  old rows are compared with the new ones, decoded, before the old table is dropped, the client structures are derived with one scan and proved by the
  verification recomputation, and `ix_smtp_latest` is dropped. Databases of schema 6 and 7 go straight to schema 11 in their own transaction.
  `Database-Storage.cmd --storage-copy --migrate` accepts schemas 6 to 11 and verifies the copy: an existing `message_rollup` (schema 8 to 10) is compared
  through its decoded logical rows, the added tables and `client_id` are explicit exclusions, and the exact schema-11 objects and the client structures are
  verified. The migration rewrites `message_rollup` and `smtp_transaction.client_id`: it needs free disk space for the write-ahead log (about 6 GB for the
  prototype database of 20 GB) and keeps the database unavailable while it runs (estimated 3 to 5 minutes at that size from prototypes; not yet run by
  this implementation on such a database).
- Test expectations changed by the schema bump: schema 10 became 11 in the Serve/rollup/storage tests, the "newer schema" fixtures use 12, the
  fixtures that built a schema-10 shape (`ConvertToLegacySyntheticFixture`, `Storage.Fixtures.ps1`) first remove the SMTP client structures and decode
  the rollup, comparisons of `message_rollup` use the decoded content (`ServeFixtures.DecodedRollup`), tests that cited `ix_smtp_latest` use another
  index, the plans of the SMTP clients are asserted per statement, and the failure injected on the schema version is on `'11'`.
- Observed on synthetic data only. The prototype figures that motivated the schema (copy of a 20 GB database, list of 7 days about 8 to 21 s before and 13 to
  65 ms after, +199 MB for the client structures, about -530 MB for the rollup codes, the NULL bounds and the dropped index; the further -225 MB of the prototype that replaced UNIQUE(kind,identity) is not taken) were measured outside this repository and are not re-measured here; no full
  collection of that database was run with the final code (the expected +50 s for the client maintenance on 1.9 million SMTP transactions is unconfirmed).

#### Collection pipeline
- Unchanged structure: `Collection.Parallelism` parse threads (0 = one per processor, 2 to 16; explicit 1 to 64) read one file each and feed one
  apply thread, the single writer of the database; `Collection.MaxFilesPerServer` (default 4) still spreads the reads over the servers.
- Queue between the parse threads and the apply thread: FIFO, bounded by the bytes read of the queued files (384 MiB, `QueueBytes`; at least 2 files
  whatever their size) and by a file count (`QueueMaxFiles` 256, or twice the parse threads when larger). A parse thread waits for room instead of
  holding more parsed records in memory. Engine constants, not configuration keys.
- `LogReader.Lines` (`Engine.Text.cs`) reads the next 512 KiB of a file ahead on the thread pool while the current buffer is split; a small file that a
  first read does not fill is never read ahead. Bytes and lines are the same as without the read ahead.
- Record lists of applied files (HttpProxy/IIS requests, tracking rows) are pooled and handed to the next files (bounded per kind and capacity, dropped
  at the end of every collection); the emptied batch of the last commit is reused by the next one.
- Commits unchanged: one transaction per batch of files, every `BatchSeconds` (30) or `BatchRows` (500,000 rows).
- WAL: a background thread copies the WAL into the database every `CheckpointSeconds` (10), and back to back while the WAL is above half of
  `WalRestartBytes`; above `WalRestartBytes` (4 GiB; 0 = no bound) the apply thread copies and truncates it between two transactions. With nothing
  queued and a WAL above half the bound, the apply thread commits before it waits.
- Page cache of the apply connection during a collection: `CacheKilobytes` 1 GiB (1048576; 0 = keep the store cache), set back to the store's 256 MiB at
  the end. Reports keep the 256 MiB cache.
- GC latency mode `SustainedLowLatency` while the apply thread runs (background full collections only), restored at the end, also after a failure.
- `CollectorOptions` fields above (`BatchSeconds`, `BatchRows`, `CheckpointSeconds`, `WalRestartBytes`, `CacheKilobytes`, `DisableTriggersDuringApply`,
  `DeferRollupsAboveBytes`) are engine options, not keys of the configuration file.
- New configuration key `Collection.DeferRollups` (`Never` default, `Auto`, `Always`): `Never` reconciles the message rollups with every commit;
  `Always` reconciles them once after the last batch, in chunks of 100,000 keys; `Auto` does so only for an initial import into an empty `message_rollup`
  of more than `DeferRollupsAboveBytes` (5 GiB) planned. Deferred rollups of a stopped run leave Serve answering 503 until the next collection, `Purge`
  or `RefreshServeRollups` drains them; except with `Always`, a leftover queue of more than 100,000 keys is drained before the first batch.
- Statistics line extended: parse threads waiting for a file to read and for room in the queue, rows split into SMTP and message tracking, SMTP clients,
  SMTP authentication flushes, compression (apply and parse threads), message rollup mode and keys, `rollup reads` / `rollup writes`, WAL copies at
  short intervals, WAL restarts and their wait, max WAL, gen1+/gen2 collections, `file reads` (main / filler streams) and
  `parse threads waiting for the reads` (main / filler).

#### Static HTML report: tables open while the file loads
- `ExchangeLogs.html` keeps the `steps` columns (timelines, routes, SMTP transcripts, clients and devices) out of the summary rows. For every dataset
  except `servers` and `daily`, they are written in `<script type="application/x-exl-detail" data-set data-first data-count>` blocks (gzip + base64
  JSON, about 500 rows or 512 KB each, contiguous and ascending); the summary row holds null in those columns and `meta.datasets[set].detailColumns`
  lists their positions. The page decodes the block of a row only when that row is opened. Report description and rows written are unchanged otherwise
  (`rows` is still the number of rows emitted, limited by `MaxHtmlRows`).
- Summary chunks are grouped per dataset in the order `servers`, `daily`, `users`, `operations`, `smtpclients`, `smtpdestinations`, `sessions`, `issues`,
  `messages`; batching and the working-memory bound of the HTML writer are unchanged.
- Template 1.4.0: the overview shows as soon as `servers` and `daily` are decoded and each table opens when its own rows are complete (a loading line
  replaces the full-screen overlay); decoding yields by time budget. A filter row under the grid header (text contains / `=` / `!` / `!=`, numbers `>`
  `>=` `<` `<=` `a..b`, times and days, multi-select lists with row counts and "exclude selected"), a From/To period applied to the first time column of
  each table, search syntax `field:value`, `-field:value`, `field>n`, `field:a..b` (an unknown `field:` token is also searched as free text), the state
  kept in the address, "Clear filters" and "Clear period", and a "N of M rows" line with the active filters. Distinct values, search text (open table
  only) and sort keys are built once per table; the first search or text sort shows "Indexing..." / "Sorting...".
- Details dialog: only the last click draws, a block that cannot be decoded gives a short message, and the step detail says when the failed and slow
  requests are still loading. Edge overview tiles that count SMTP clients and destinations use the report description and are refreshed when those tables
  are complete.
- The test helpers rebuild the full rows from summary chunks and detail blocks.

#### Static HTML report: every row, single file or page and data folder
##### Added

- `Report.HtmlLayout` (`Auto`, `SingleFile`, `Folder`; `-HtmlLayout` for one run) and `Report.SingleFileMaxMB` (200). The data of the report is
  always written first as data files (plain JavaScript, `__exl.file` / `__exl.push` lines carrying the same gzip + base64 blocks as before); `Auto` then
  copies them into the page when they total at most `SingleFileMaxMB`, else keeps them in a `<FilePrefix>_data` folder (marker `.exl-data`, packs of
  about 8 MB) next to a small page whose manifest lists every file with its rows, size and CRC-32. The folder is replaced only when the tool wrote it.
  Detail files of a folder report are loaded when a row is opened. A moved or unzipped-without-folder page says which folder is missing, with a
  "Try again" button; `#verify` in the address checks the CRC-32 of the files.
- Memory guard in the page: a table whose estimated size does not fit the computer (a quarter of its memory, at most 2 GB; `#maxbytes=<n>` overrides)
  is not loaded on its own; its tab says so and offers "Load anyway".
- `Report.ScratchFolder`: folder of the report work file (default: the report folder). The log line `Report I/O` names the folder used and its free
  space at the start of the report.
- Mail: a report with a data folder is attached as one zip holding the page and the folder (`Attach = Html` or `Zip`); the archive is built in a file
  and a report more than ten times `Mail.MaxAttachmentMB` is left out without building it.

##### Changed

- `Report.MaxHtmlRows` defaults to 0: every row of every table is in the HTML report (a value from 1,000 to 2,000,000 still caps each table).
  An existing configuration that still says `MaxHtmlRows = 200000` (the value written by earlier versions) keeps that cap: set it to 0 for every
  row. A report whose tables were cut by the cap writes a warning naming them in the log.
- Template 1.5.0: tables are kept in compact typed columns (numbers and times in `Float64Array`, text and lists as ids into a dictionary of distinct
  strings), filters, sort and search work on those ids, and rows are rebuilt only to draw, open or export them. Sorting packs the key and the row
  number in one number and uses the native typed-array sort.
- Free words of the search match inside one cell value (one text value or one list item), not across the cells of a row.
- The data of the HTML report is no longer in `application/x-exl-chunk` / `x-exl-detail` script blocks (see above); the helper that reads a report
  in the tests follows the manifest.

##### Fixed

- The report work file (`.report-<guid>.tmp`) is created in `Report.ScratchFolder` when it is set, else in the report folder (by design, no
  fallback to the system temporary folder, which is often the smallest volume of a server). A work folder that cannot be created, that has less than
  256 MB free, or whose full name exceeds the 1040 bytes that the SQLite Windows VFS accepts, stops the report with a message that names
  `Report.ScratchFolder`. Paths longer than 260 characters are supported.
- A Folder report written again into the same folder keeps the previous report's data folder until the new page and folder are complete: a run that
  fails (disk full, template error, interrupted process) leaves the previous report readable. The earlier folder is checked again just before it is
  replaced, then renamed `<prefix>_data.previous` in one operation and deleted only once the new page is in place; when the new folder or page cannot
  be put in place the earlier folder is renamed back, whole. A folder that cannot be renamed (one of its files held open without delete sharing by an
  indexer or a scanner) stops the run with nothing of it deleted. An earlier folder that cannot be deleted at the end is left as
  `<prefix>_data.previous`, with a WARN in the log and a note in the result; the next run removes it. A process stopped between the two renames
  leaves the earlier folder only as `<prefix>_data.previous`: the next run renames it back to `<prefix>_data` before it writes anything.
- A report data folder to which Explorer added `desktop.ini` or `Thumbs.db` is still replaced, also when Explorer marked the folder read-only (as it
  does for a folder it customised), and so is a read-only `.partial` folder left by an interrupted run; any other foreign entry stops the report with a
  message that names it.
- Page: `__exlVerifyAll()` on a single-file report no longer lists the tables already loaded as damaged (their statements are dropped after loading:
  they are checked while loading with `#verify`, and listed in `unchecked` otherwise). A damaged single-file report shows the real cause (for example
  the row count of the file) and no "Try again" button, which could not succeed; a folder report that fails keeps "Try again" and reads the failed file
  again whole.
- Page: the next block of a table is decoded while the rows of the current one are added to the table, and `__exlTiming` gives the time spent waiting
  for decoded blocks and adding rows per table (`decodeMs`, `appendMs`). Measured on the synthetic 1.5 M-session Folder report (Edge
  headless, five runs before, three after): first table 15.7-17.3 s before, 15.7-16.5 s after. The marks put about 10.6 s of the
  sessions table in waiting for decoded blocks (base64, gunzip and `JSON.parse`, mostly on the main thread) and 3.3 s in adding rows,
  so overlapping the two gains little; decoding three blocks ahead measured the same (15.6-16.1 s).
- Page: `__exlVerifyAll()` on a folder report reads every file again through a script of its own, so a file the loader is consuming at the same
  time is no longer reported as damaged.
- Template 1.5.1: the table that opens (the tab of the address, else the first one) shows its first rows while it is still loading, as soon as its
  first block is added and the overview is drawn: the grid head, the rows loaded so far in file order with the virtual scroller and row details, and
  "Loading n of N rows: filters, sort, search and export open when the table is complete" (refreshed every 500 ms at most). The search, the column
  filters, the sort, "Clear filters" and the export are disabled until the table is complete; the tab then opens as before, with the filters and
  sort of the address. That table is loaded right after the small tables, before the other large ones. `__exlTiming.preview`/`previewRows` and
  `__exlStats.previewPasses` give the time and rows of the first preview; preview draws do not change `__exlStats.seq`.
  The loading line is redrawn at most every 100 ms (and after the last block of each file) and its bar no longer animates
  its width: with the preview rows on screen, the width transition laid the page out again at every frame and doubled the
  time spent waiting for decoded blocks. Measured on the synthetic 1.5 M-session Folder report (headless, same machine,
  pages of the same report written with the 1.5.0 and 1.5.1 templates, three runs each, interleaved): first rows 1.1-1.2 s
  (Edge) and 1.1-1.5 s (Chrome); first table 17.1-20.3 s before and 13.0-13.9 s after (Edge), 15.0-16.4 s and 12.7-13.7 s
  (Chrome); every table loaded 44.7-56.0 s before and 24.8-28.6 s after (Edge), 38.9-45.2 s and 24.1-25.9 s (Chrome). On the
  150,000-session single-file report: first rows 0.85-1.0 s, every table 3.4-4.6 s before and 2.7-3.4 s after.

#### Server garbage collector for Run-Collector.cmd
- `Run-Collector.cmd` starts the bundled PowerShell with the server garbage collector, 4 heaps not tied to processors (`DOTNET_gcServer=1`,
  `DOTNET_GCHeapCount=4`, `DOTNET_GCNoAffinitize=1`). The setting is per process, so it applies to every mode of this launcher; the portal launcher and
  a scheduled task that starts `pwsh.exe -File Invoke-ExchangeLogReport.ps1` directly keep the workstation collector unless they set the same variables.
- Measured once on one Azure VM, synthetic 14 days (132.5 GB, 12829 files), with `Collection.Parallelism = 1` and `MaxFilesPerServer = 1` (imposed by the
  comparison harness; not the production default). Results are not committed to this repository.
  - Comparison harness, workstation garbage collector: legacy collection 1815.5 s, 3.0 collection 1720.9 s. Usage/Detailed outputs identical for
    7 of 8 and 10 of 12 files (`ExchangeLogs.html` and `ExchangeLogs-ClientSessions.csv` differ); Serve startup about 0.5 to 0.9 s.
  - Separate collection runs of the new engine of the same logs: workstation 1749.3 s (pauses 161.3 s, peak working set 3808 MB); server garbage collector,
    4 heaps 1440.0 s (-17.7%; pauses 38.5 s, peak 4178 MB); the same plus `GCNoAffinitize` (the launcher setting) 1440.6 s (pauses 30.0 s, peak 4103 MB).
    Same files, lines and kept rows in every run. The two workstation baselines (1720.9 s and 1749.3 s) are different runs.
  - The reports were not measured with the server garbage collector.

#### Known behaviour
- `sqlite_sequence` of `message_rollup` advances by about one number per reconciled identity that already has a row, while `MAX(id)` does not change (the schema 12 migration, which reconciles every tracking identity once, advanced it by 3.7 million on the 5.5 million-row bench database). The reconciliation writes each row with `INSERT … ON CONFLICT(kind,identity) DO UPDATE` on an `AUTOINCREMENT` table: SQLite allocates the next rowid before the conflict turns the statement into an update, and records it in `sqlite_sequence`. It is harmless and intended to stay: ids remain unique and are never reused, the id of an existing row (its Serve URL) does not change, the verification only requires `seq >= MAX(id)`, and the 64-bit range is not a constraint. Avoiding it would take an `UPDATE` then an `INSERT` per key in every collection. A gap between `seq` and `MAX(id)` is therefore not a sign of lost rows.
- `VerifyServeRollups` reads the whole database in one read transaction, whose default deadline grows with the rows (300 s or 300 µs per row of `message_rollup` plus `smtp_transaction`, at most 24 h). In WAL mode no checkpoint passes that snapshot, so everything a collection commits while the verification runs stays in the `-wal` file (on the drive of the database) until it ends. Run it when no collection is running (stop the scheduled task, or between two collections: a store with unreconciled work is refused anyway), or on a copy (`VerifyServeRollups(SqliteConnection)` on a `VACUUM INTO` copy); do not shorten the retention or skip the verification to make it fit.

## [2.1.1] — 2026-10-14

### Fixed
- The delivered `Report.TimeZone` and the default used when it is absent are now `Romance Standard Time`, the native Windows Paris zone. Winter/summer rules and explicit `Europe/Paris` configurations remain supported.

## [2.1.0] — 2026-10-13

The SMTP clients, the SMTP CSV files and the Messages route show the authenticated user, and large Detailed reports run within a bounded memory budget. Version 2.0.1 was only a local candidate and was never published; its changes are listed here.

### Security
- Full signed-package integrity, as in Purview DLP Report: besides the five PowerShell files, the separately owner-signed manifest `PackageIntegrity.psd1` fixes the raw SHA256 of all 12 C# sources, all six SQLite DLLs (both native architectures), the report template, both HTML guides, the README and the notices (28 files, plus `CHANGELOG.md` in a distribution). `src\Test-PackageIntegrity.ps1` authenticates the whole parent package before the module, the SQLite libraries or the engine are loaded (entry script, module import, every engine initialization, report template and Exchange helper), and rejects missing, changed, unknown or linked files, a wrong signer or a missing timestamp. The verifier is distributed only in `src`, once; the manifest stays at the package root and is generated and signed last, after final script signatures and timestamps. C# and DLLs are hash-protected by that signed manifest, not individually Authenticode-signed.
- The compiled engine cache is removed: the engine is compiled in memory from the verified sources at each start and no DLL in `bin\` is ever loaded, because a checksum stored next to an unsigned DLL cannot prove its origin. An old `bin\` is ignored. Starting costs a few seconds more.
- Not protected by the check: `config\ExchangeLogReport.config.psd1`, `config\ExchangeLogReport.paths.psd1`, `config\ExchangeLogReport.mail.credential`, and the `bin\`, `data\`, `logs\` and `reports\` folders. Any other file in `config\` is now refused. The package builder checks the source and the copy and no longer rebuilds the HTML guides.

### Changed
- Applied the existing public README disclaimer unchanged to the runtime README, entry script and module.
- Corrected the entry-script help to describe local writes, optional report e-mail and the test message sent by `-Mode MailTest`.
- Documented the complete PowerShell/C#/SQLite package, sensitive output data and the separate retention of exported reports and e-mail copies.
- These documentation changes do not alter installation paths. Existing configuration values and defaults are unchanged; the only new settings are the report memory and parallelism ones below.

### Added
- SMTP clients, the SMTP CSV files and the Messages route show the **authenticated user**, shown separately from the authentication mechanism and result and from the envelope sender. The value comes only from explicit successful server evidence (never from `MAIL FROM`, HELO, the client address or a decoded AUTH payload); when it is missing, ambiguous or unproven it shows *Not available*. Front-end submissions are matched to their back-end session by SID. Schema 5 to 6 is additive: no reset or rebuild, existing log read positions are kept, and earlier rows stay *Not available* (*Legacy*) without back-fill. New AUTH payloads, challenges and tokens are redacted before storage; earlier transcripts are redacted when a report or export is written, and stored database content is not rewritten. Verbose protocol logging remains required. Validated with the offline synthetic tests and with an isolated lab end-to-end run on an existing delivered message (collection plus Detailed report): the authenticated user, its mechanism and result appear in the SMTP client popup, the SMTP CSV and the Messages route of the HTML and CSV outputs.
- SMTP identity correction: an accepted proxy handoff retains its historical principal across later logins and collector restarts; explicit `503 Already authenticated` keeps the account and reports the refused attempt separately. Contradictory historical evidence retracts attribution. Long sessions drain evidence and completed transactions to bounded disk-backed parts, with no lifetime limit; proof updates and file offsets commit or roll back together.

### Fixed
- SQLite connections now use normalized Windows extended paths for the source database, collector workers and report scratch storage, so deeply nested output folders (including spaces and UNC paths) do not fail at the legacy 260-character boundary. Installation and output locations are unchanged.
- The delivered `Europe/Paris` time zone now falls back to the native Windows `Romance Standard Time` zone when ICU/IANA lookup is unavailable (for example with NLS). Winter/summer time rules are preserved; unknown IDs still stop configuration loading, and registry/data errors are no longer swallowed as an unknown name.
- Added `Report.MemoryBudgetMB` (default 512, 64 to 16,384 MB) and `Report.Parallelism` (default 0: up to four CPU workers, leaving one processor available). These settings affect reporting only; collection settings are unchanged.
- Report datasets now share an estimated memory budget and spill the largest retained dataset to disk only when needed. The budget partitions the source SQLite cache, temporary cache, retained rows and in-flight CPU work; runtime overhead, identity aggregates and individually oversized sessions/rows remain outside a hard process limit.
- Session JSON parsing, timeline reconstruction and HTML compression run on bounded CPU workers, with byte-based backpressure and ordered results. Database reads and temporary writes remain single-threaded. Old configurations receive the new defaults automatically.
- Message and sampled client/destination transcripts are retained as IDs, not expanded text, until an HTML row is actually emitted. A byte-bounded cache resolves complete text on the caller thread; rows beyond the HTML cap no longer inflate the temporary data or source sort.
- Scratch storage uses independent dataset tables and scoped group indexes. Compact SMTP links preserve Unicode case-insensitive matching in scratch while source reads use the existing binary indexes; no source schema/index or identifier-semantics change is required.
- Sampled row arrays are independent and intermediate datasets are released after use, including their charged group indexes. Message, route and sample chronology uses UTC milliseconds with stable ties, preserving the existing local display.
- Report statements share a read snapshot so SMTP counts and streamed exports cannot observe different collections. Unused Edge sessions are not rebuilt. Worker and cleanup failures remain visible behind the primary error, malformed timeline JSON fails explicitly, and in-flight output files have `.partial` names until closed and renamed.
- CSV-only SMTP transaction details are streamed directly from SQLite to the final CSV, avoiding a potentially much larger uncompressed copy in the temporary database. HTML-only reports do not read those transcripts. Report-stage starts are logged immediately to diagnose an interrupted or slow export.
- Spilled message rows are materialized in chronological order before export instead of performing one random temporary-database lookup per row; messages and their details remain complete.
- Large Detailed reports no longer retain all session timelines, message conversations and report datasets in RAM. Session reconstruction is batched, tracking and SMTP are correlated one message at a time, and large datasets use a report-local temporary SQLite file with an 8 MB page cache.
- HTML chunks are written progressively, bounded by row count and estimated memory size, instead of assembling the entire HTML payload in memory. CSV exports remain complete; `MaxHtmlRows` still limits only the HTML tables.
- SMTP client and Edge destination transaction samples are selected before loading their transcripts. The existing 200-transaction sample and failure priority are preserved, as are the full SMTP CSV and the top-10 e-mail summaries.
- Read-only report sorts can spill to disk instead of retaining their temporary data in RAM. Temporary report rows are removed on completion or a handled error; reports need additional free disk space while building and may take longer on slow storage.
- Discover and every collection now read the Exchange applications' `web.config` settings for moved MAPI HTTP back-end and HttpProxy log folders. Physical application paths come from IIS, including Exchange installed on another drive and relocated virtual directories.
- Both MAPI HTTP applications (`emsmdb` and `nspi`) are covered, even when they use different folders. Shared and overlapping log folders are collected once. The supported settings are `RequestDetailsLogger.MapiHttpMailboxLogFolder` and `RequestDetailsLogger.HttpProxyProtocolLogFolder`; native MAPI `LogPath` / `LogFilePath` and EWS back-end logs are different formats and are not added to the collection.
- Application settings support inherited values, scoped locations, `clear` / `remove`, `configSource` and external `file` settings. Invalid, inaccessible or encrypted settings produce application warnings and keep the previously known paths; other sources continue.
- The paths file records per-application folders. Collections follow changed or removed overrides and report drift; forced `MapiHttpPath`, `HttpProxyPath` or `LoggingPath` still win. An `ExchangePath` is an installation root, not a logging override. `-NoCollect` remains offline.

### Validated
- Full seven-day Detailed reports on an isolated lab database snapshot, with a 512 MiB report budget: 504,470 message-view rows and 1,029,919 SMTP transactions, 5.91 GiB of CSV/HTML output per run. One worker completed in 7 min 56 s at 771 MiB peak working set; two workers in 19 min 29 s at 570 MiB. Complete CSV hashes and decoded HTML rows matched; source and snapshot hashes were unchanged.
- These consecutive HDD runs had different cache/I/O conditions, not a controlled CPU speedup comparison. No parallel acceleration is demonstrated. The earlier 20-minute guard interrupted a progressing, multi-GiB SMTP CSV export; the completed runs retained memory and disk safeguards. In those report runs, no installed runtime was replaced, no collection was run and no mail was sent.

## [2.0.0] — 2026-10-07

A new collection engine: every server and every source is read at the same time, and the database is written in large transactions. The first collection of a production environment takes minutes instead of hours. The report can also be sent by e-mail.

### Changed
- **A report reads the database; it no longer collects first by default.** The daily routine is: the hourly scheduled collection reads the logs, and reports read the database.
  - A report reads the new log lines first only when the last collection is older than `Report.MaxDataAgeMinutes` (new, 90 min) **and** the period ends after it.
  - With no collection in the database, a report stops and asks for `-Mode Collect`: it never starts the first collection (14 days of logs) on its own.
  - While a collection is running, a report does not wait: it uses the data already collected.
  - The banner line **Data** gives the time of the last collection and what the report does.
  - New `-Collect` forces the collection first. `-NoCollect` still never collects.
  - Before, `-Range Last30Days` run without a scheduled collection started a collection of several hours before the report.
- **Parallel collection.** One parse thread per file reads every server and every source at the same time (`Collection.Parallelism`, default one per processor, 2 to 16, at below-normal priority). A single write thread uses the database. HttpProxy files are read first because they give the `domain\sam` accounts. SMTP and message tracking keep the threads busy meanwhile, and the back-end logs start once HttpProxy is written. The console shows one row per server and source as soon as that source is done, with a progress bar for the whole collection.
- **One transaction per batch of files** (30 s or 500,000 rows) instead of one per file, with the read positions of its files. An interrupted collection still resumes without duplicates. The client sessions stay in memory for the whole batch instead of being read and rewritten for every file.
- **Faster parsing and writing**:
  - lines are read and split as bytes;
  - field values and noise decisions are cached per thread;
  - the daily aggregates are computed by the parse threads;
  - SQLite statements are prepared once;
  - the page cache is 256 MB;
  - a new database uses 16 KB pages.
- **Recoveries** (a failure followed by a success of the same user) are resolved once, at the end of the collection. The result no longer depends on the order in which the files were read.
- **WAL.** It is copied into the database by a background thread during the collection, and emptied at the end. The execution log gives the time of each step and a statistics line: threads, write thread, commits, WAL copies, GC (developer guide 12.3).
- **Compressed storage.** SMTP transcripts and session timelines are stored compressed (Deflate, about 6 times smaller). Those written by 1.x stay readable. **A database written by 2.0.0 cannot be used by 1.x any more.**
- Retention deletes use the time indexes, and the SQLite statistics (`PRAGMA optimize`) are bounded.
- **Faster reports.**
  - A report now opens the database with the same 256 MB page cache as a collection, and sorts in memory. Before, it kept the 2 MB SQLite default and sorted in temporary files.
  - Messages per server and per hour are counted in one pass over a new covering index of the tracking events (`ix_msg_flow`). The SMTP counts use a covering index too (`ix_smtp_flow`). Both are built at the first opening of a 1.x database. Before, two `COUNT(DISTINCT …)` queries took most of a 30-day Usage report.
  - SMTP transcripts are read only for the transactions shown: none in a Usage report.
  - The execution log gives the slowest steps of every report (`Report step: …`).
- **Faster start of a collection.** The days that have client sessions and the `domain\sam` accounts are found by index seeks. Before, both reads went through whole tables: 24 s at the start of every collection on the lab hard disk, even with nothing new to read.

### Added
- **Report by e-mail.** The new `Mail` section of the configuration:
  - **Anonymous**, **Basic** (`AUTH LOGIN` / `PLAIN`, over TLS only) or **Kerberos** (`AUTH GSSAPI`, RFC 4752, without NTLM fallback);
  - **STARTTLS** (required by default) or implicit **TLS** (465), or no encryption;
  - the certificate is checked, or pinned with `CertificateThumbprint`.
  
  The body gives the summary of the report: period, real users, sessions, failures, messages and the verdict of every server. The report is attached as HTML (zipped above `MaxAttachmentMB`) or as a zip of every file, or not at all. A refused recipient or a message that is not sent gives exit code 2, and the report is still written.
- **`Collection.MaxFilesPerServer`** (default 4): files of one server read at the same time. The reads spread over the servers, and no server (nor the local disk of a collector that is an Exchange server) serves all the threads. The listing of the folders follows `Parallelism` too.
- **Main problems in the e-mail of a Detailed report**: 10 per kind, worst first — users with unresolved failures, client sessions that failed, SMTP clients with refused or deferred mail, SMTP destinations with failures (Edge). A kind without any problem is named on a *None in this period* line. A daily Detailed report sent by e-mail can be read without opening the attachment.
- **Two ways to use the tool**, documented as such: **recurring reporting** (scheduled tasks: the monthly usage and the daily Detailed report, written in HTML and sent by e-mail as an option; developer guide 7 C) and **troubleshooting on demand**. The user guide is rewritten as **one guided path**: set up once (steps 1 to 4: servers, `-Mode Discover`, the hourly task, `-Mode Status`), then branch **A** (steps 5 to 7: the two scheduled reports, open the report, option: by e-mail) or branch **B** (steps 5 to 7: Detailed report on the user and the period, client session, timeline to the raw log lines). Every step says what to do, gives one exact command on one example (EXCH01 to EXCH04, contoso.com, alice), what you should see and what to do if not; the README shows the same path.
- `-SendMail` (or `-SendMail:$false`) decides for one report run. `Mail.Enabled = $true` sends every report.
- **`-Mode MailTest`** sends a test message and shows the SMTP conversation, with the AUTH data masked. `-Mode MailTest -Credential` saves the account of `Basic` / `Kerberos` in `Mail.CredentialFile`, protected by DPAPI (`CredentialScope` `User` or `Computer`, file restricted to SYSTEM, the administrators and its writer). The credential file is never in the package.
- **Load test tools.** `tools\New-ExlSyntheticLogs.ps1` writes Exchange logs with the volumes of a production server (deterministic; `-Only` generates the logs of each lab server in place; `-Profile Decommission`: a barely used server and an unused one, for a decommissioning review). `tools\Measure-ExlCollection.ps1` measures a collection on them: duration, rate, database, peak memory and statistics (developer guide 12.2).

### Validated
- **A production-scale log set reproduced.** In the lab, 1.6.1 took 1 h 04 min for HttpProxy and **43 min 58 s for message tracking (273 KB/s)** on one server, the same order as measured in production on that log set (409 KB/s).
- **Load test** (2 servers × 14 days, 14.8 GB, 33.1 million lines, 7.0 million kept):
  - on a PC (8 logical processors, SSD), 1.6.1 took **29 min 45 s** and 2.0.0 takes **3 min 51 s to 4 min 21 s** (7 to 8 times faster);
  - the database is 2,116 MB instead of 2,562 MB;
  - the next collection with nothing new takes under 1 s.
- **A second production-scale log set** (4 servers × 14 days, 33.3 GB, 76.2 million lines; in production 1.6.1 took 6 h 36 min for 31.6 GB): 2.0.0 collects it in **13 min 18 s** on the PC, database 4.6 GB.
- **Lab, 1.6.1 against 2.0.0 on the same collector** (EXMBX1: 4 vCPU, 16 GB, Standard HDD; logs of 2 servers × 14 days through `E$`, 14.6 GB, 33.1 million lines; file cache emptied before each cold measure):
  - first collection: **4 h 55 min 49 s → 6 min 02 s** (× 49), database 2,522 → 2,212 MB;
  - next collection with nothing new: 7 min 17 s → 2.6 s;
  - Usage report, 30 days: **14 min 57 s → 2 min 30 s** cold, 27 s → 18 s warm;
  - Detailed report, 7 days: 15 min 36 s → 6 min 58 s cold, 52 s → 45 s warm;
  - 1.6.1 reproduced the production-scale log set: message tracking at 273 KB/s (44 min per server).
- **Lab, one server** (4 vCPU, Standard HDD), 7.2 GB:
  - read in about 2 min, 2 min 28 s with the end-of-run WAL copy;
  - with 16 KB pages, that copy took 22 s instead of 58 s with 4 KB pages.
- **E-mail on Exchange Server SE** (lab):
  - anonymous on 25, in clear and with STARTTLS (pinned certificate);
  - an untrusted certificate is refused;
  - Basic on 587; a wrong password gives `535`;
  - Kerberos on 587 with a saved account, including the security layer;
  - Kerberos as SYSTEM is refused by Exchange (`535 5.7.3 Unable to proxy authenticated session`, the computer account has no mailbox), and the tool explains why;
  - reports sent with `-SendMail` (Basic, Usage, 7 days, HTML 1.2 MB attached) and with `Mail.Enabled` (Kerberos, Detailed, 24 hours, HTML 3.3 MB attached);
  - a 7-day Detailed report whose zip (73 MB) is larger than `MaxAttachmentMB` is sent without attachment, and the console and the message say so.
## [1.6.1] — 2026-10-05

### Fixed
- **`-Start` / `-End` were ignored silently** without `-Range Custom`: `.\Invoke-ExchangeLogReport.ps1 -Start '2026-10-01 08:00' -End '2026-10-01 12:00'` built a report of the default range (`Report.DefaultRange`). The period parameters now select their range on their own: `-Start` / `-End` Custom, `-Month` Month, `-Date` Day (`-Range` can be left out, `-Range Custom -Start … -End …` still works).
- **No parameter is ignored silently any more.** The kinds of period are separate parameter sets: `-Start` requires `-End`, and `-Month`, `-Date` and `-Start` / `-End` cannot be combined (refused by PowerShell before the script runs). A period that contradicts `-Range` (`-Range Last7Days -Start …`) stops with an error. A parameter that the mode does not use is shown in yellow under the banner with the reason, for example *-Start, -End ignored with -Mode Collect: a collection reads every new log line, whatever its date* (period and report parameters with `-Mode Collect`, `Status` or `Discover`; `-Server` with `Status` or `Discover`; `-ConnectTo` / `-Credential` outside `Discover`).
- The *Mode* line of the banner showed only the mode: it shows the report type and the range again (`Report · Detailed · Custom`).
- `Get-Help .\Invoke-ExchangeLogReport.ps1` showed only the syntax: the `#Requires` line placed just before the help block hid it. The help now documents `-Month`, `-Date`, `-Start` and `-End` too.
- A report without collection (`-NoCollect`) checked the folders of every server to know its role: the role now comes from the data already collected (Edge SMTP logs and no client access log), and the servers are not contacted.
- A log folder that cannot be read (access denied: account that is not administrator of the server) stopped the access check, the collection or `-Mode Discover` with an error: it is now reported as *folder not found or not readable*, and a server whose folders cannot be read is treated as a mailbox server.

### Added
- **User guide** (`docs\ExchangeLogReport-UserGuide.md` and `.html`): prerequisites and everyday commands only — one command per question (unused server, user problem, missing message, incident, monthly review, Edge, collection check), period and filters, results, exit codes and usual warnings. The existing guide becomes the **developer guide**; the README points to both.
- `tools\Build-Documentation.ps1` without parameter builds both HTML guides; a link to the other guide (GitHub anchor) points to its HTML file. The package contains both HTML guides.

### Changed
- Only `-Mode` and `-Range` remain positional (`.\Invoke-ExchangeLogReport.ps1 Report Last30Days`); the other parameters are named.

### Validated
- Lab: on EDGE1 (Edge, SYSTEM) and, in parallel, the four mailbox servers from an administration server (scheduled tasks with the domain account, copy of the database): `-Mode Discover`, `-Mode Collect`, report `-NoCollect`, `-Start` / `-End` without `-Range` (Custom, end replaced by now), `-Range Last7Days -Start …` (error, exit 1), `-Mode Status` with `-Start` / `-End` (shown as ignored), report with a collection by an account that cannot read the folders (warnings, exit 2, report written).

## [1.6.0] — 2026-10-05

### Added
- **Edge report**: when every server of the report is an Edge Transport server, the report shows the mail flow only — title *Edge Transport mail flow*, tiles *Inbound SMTP* / *Outbound SMTP* / *Messages*, server cards and daily chart in SMTP received and sent, tabs *Messages*, *SMTP clients* and the new **SMTP destinations**. No client access view or file (`Users`, `Clients`, `Operations`, `ClientSessions`, `ClientAccess-*`), and no client access column in `Servers` / `Daily`. Folder `<FilePrefix>_Edge<Type>_…`.
- **SMTP destinations** (`SmtpDestinations.csv`, Edge report): one row per destination of the Edge (remote address + send connector) — Exchange Online, internet MX, the mailbox servers of the organization — with the remote host of its 220 banner, sent, deferred, failed, recipients, senders, TLS and last error; transactions and SMTP transcripts behind a click (failures first).
- The role of the servers is resolved for a report without collection too (`-NoCollect`).

### Fixed
- A message handed over by an Edge Transport server (tracking event `SENDEXTERNAL`) stayed *In transit*: it is now *Relayed*, like `SEND`.
- A server without client access (Edge, or a mailbox server with mail flow only) showed *No real activity in the period* and 0 active days: its first and last activity and its active days now come from its mail flow.
- The null sender (`MAIL FROM:<>`, NDRs) was shown empty in the SMTP clients: shown as `<>`.

### Validated
- Lab: Edge report of EDGE1 with generated internet and outbound traffic (guide 14.3); it showed a routing loop of the lab (tenant `onmicrosoft.com` domain accepted as *InternalRelay* without send connector).

## [1.5.1] — 2026-10-05

### Fixed
- **A log file reached through another path was read again.** The read position of a file was kept per path: when `-Mode Discover` replaced the administrative share of the collector itself (`\\EXCH01\C$\…`) by its local path (`C:\…`), or returned a folder in another case, every file was read again from the beginning. SMTP transactions and tracking events were not duplicated (unique keys), but the **client access counters** (daily usage, operations, clients) of the files read twice were counted twice. Files are now identified by their path on their own server, case ignored (`\\EXCH01\D$\Logs\x.log` = `D:\Logs\x.log`).

### Changed
- Database schema 3: `source_file.file_key` (identity of the file), upgraded at the next opening. A file already read through two paths keeps one read position (the one read last); the counters already doubled before the upgrade are not corrected (they leave the database with the retention).

## [1.5.0] — 2026-10-05

### Added
- **Edge Transport servers**: only their **SMTP protocol logs** (`TransportRoles\Logs\Edge\ProtocolLog\SmtpReceive|SmtpSend`, new sources *SMTP in (Edge)* / *SMTP out (Edge)*, role `Edge` in the SMTP data) and their **message tracking** are read. No IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4 source, and no IIS check (`applicationHost.config`) on them.
- **Role detection** at every collection: registry key `EdgeTransportRole` when the tool runs on the Edge itself; on another server, the AD LDS folder of the Edge role (`TransportRoles\data\Adam`) without the client access folder (`FrontEnd\HttpProxy`). The console says *Edge Transport server (detected)*. `Role = 'Edge'` or `'Mailbox'` in a `Servers` block forces the role; `EdgeReceivePath` / `EdgeSendPath` force the folders.
- **`-Mode Discover` on an Edge Transport server**: local Exchange Management Shell of the Edge (snap-in, no remote PowerShell, no RBAC: SYSTEM is accepted); SMTP log folders and message tracking of the Edge, receive and send connectors whose logging is off; `Role = 'Edge'` in the paths file. From a mailbox server, a subscribed Edge listed in the configuration is recorded with its role (no longer reported as *not found in Exchange*).

### Changed
- The paths file records the role of every server (`Role`).
- Collection step 2 is now *Checking access to the servers and their log folders*.
- Guide: new chapter 4.2 (Edge Transport servers), chapters 6.1, 6.2 and 7, lab validation 14.3, troubleshooting.

### Fixed
- On an Edge Transport server the collection warned about IIS settings not readable and client access folders *not found* (HttpProxy, IIS front end, ActiveSync back end), ended with exit code 2, and never read the SMTP logs of the Edge (it looked for the `FrontEnd`, `Hub` and `Mailbox` folders only).

## [1.4.0] — 2026-10-01

### Added
- **`-Mode Discover`**: finds where every Exchange server really writes its logs — installation folder, SMTP protocol logs per role and direction, message tracking, POP3/IMAP4 — with the Exchange cmdlets run in **Windows PowerShell 5.1** (`src\Get-ExlExchangeSettings.ps1`: Exchange Management Shell on an Exchange server, Exchange remote PowerShell with Kerberos elsewhere, `-ConnectTo`, `-Credential`). *View-Only Organization Management* is enough. Folders on another drive are read through the administrative share of that drive. Every folder is checked from the collector; disabled message tracking, POP/IMAP and SMTP connector logging are reported. Result in `config\ExchangeLogReport.paths.psd1`.
- **IIS sites from `applicationHost.config`** (`\\<server>\ADMIN$`): log folder, format and target of Default Web Site, Exchange Back End and of every **custom site hosting Exchange virtual directories** (a second OWA/ECP site), recognised from its virtual directories alone. Custom front-end sites are read with the IIS front end, custom back-end sites with ActiveSync with the ActiveSync back end.
- **Checks at every collection**: `applicationHost.config` is read again, so a moved IIS log folder or a new/removed custom Exchange site is followed at once and reported until `-Mode Discover` records it; an optional folder that does not exist (SMTP, MAPI, POP/IMAP, custom site) is shown as *no folder*; **stale source** warning when HttpProxy or IIS has no file newer than `Collection.StaleSourceHours` (new setting, 24 h). `-Mode Status` flags stale sources too.
- Per-server path settings for each source (`FrontEndReceivePath`, `HubSendPath`, `IisFrontEndPath`, `MapiHttpPath`...), which win over the paths file; unknown keys in a `Servers` block are rejected.

### Changed
- Guide chapter 4: where to run the tool and with which account — **SYSTEM on an Exchange server**, or a **domain account local administrator of every Exchange server** (+ View-Only Organization Management for `-Mode Discover`, *Log on as a batch job* on the administration server); why a local account does not work; network flows. Chapter 6.1 rewritten around `-Mode Discover`, chapter 7 with the task of both options, new troubleshooting entries, lab validation 14.2.
- Exit code 2 now also means a stale source or IIS folders changed since `-Mode Discover`.
- The console shows where the paths of each server come from (Discover, configuration, defaults).

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
