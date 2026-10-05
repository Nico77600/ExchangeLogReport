// =============================================================================
//  Exchange Log Report - engine, part 4: report (SQLite -> CSV + HTML)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.6.1
//
//  Datasets (HTML tabs: sessions, issues, users, operations, messages, smtpclients; servers and daily
//  feed the server cards and the chart; every dataset is also a CSV file). Edge report (every server of
//  the report is an Edge Transport server): servers, daily, smtpclients, smtpdestinations, messages, smtp.
//    servers     one row per server: is it really used? (users, requests, mail flow)
//    daily       one row per day x server
//    users       one row per real user (protocols, clients, servers, failures), with its clients and devices
//    clients     one row per user x protocol x client (user agent or device): versions, devices, addresses (CSV)
//    operations  one row per protocol x operation: volume, failures, latency (server-wide)
//    smtpclients one row per SMTP client (address + HELO): applications and devices sending mail
//    smtpdestinations  Edge report: one row per SMTP destination (address + send connector): where the Edge sends mail
//    access      one row per day x server x user x protocol (CSV only: can be large)
//    sessions    Detailed: ONE ROW PER CLIENT SESSION, with its timeline (front and back end) behind
//    issues      Detailed: failed and slow requests with their resolution (recovered or not)
//    messages    Detailed: ONE ROW PER MESSAGE, with its route (tracking + SMTP) behind, and the mail
//                refused during the SMTP conversation (no Message-ID)
//    smtp        Detailed: one row per SMTP transaction, with the session transcript (CSV)
//  Times in the datasets are local wall-clock seconds of the report time zone.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public sealed class ReportRequest
    {
        public long StartMs, EndMs, DetailCutoffMs;
        public TimeZoneInfo Zone = TimeZoneInfo.Utc;
        public string TimeZoneName = "UTC";
        public string[] Users = new string[0], Servers = new string[0], ConfiguredServers = new string[0];
        public bool Detailed, IncludeRoutingDetails = true, IncludeSessionDetails = true, WriteCsv = true, WriteHtml = true;
        public string OutputFolder, FilePrefix = "ExchangeLogs", CsvDelimiter = ";", TemplatePath;
        public string Title = "Exchange Server usage and troubleshooting", ToolVersion = "", Generated = "";
        public long RecoveryWindowMs = 1800000, SlowRequestMs = 5000;
        public int MaxHtmlRows = 200000;
        // Edge report: every server of the report is an Edge Transport server (SMTP and message tracking only):
        // no client access dataset, SMTP destinations added, Edge layout in the HTML file.
        public bool Edge;
        public string[] EdgeServers = new string[0];
    }

    /// <summary>Kinds: text, num, time (local seconds), list (string[]), steps (list of rows).</summary>
    public sealed class Column
    {
        public string Name, Kind;
        public bool Grid = true, Csv = true;
        public Column(string name, string kind) { Name = name; Kind = kind; }
    }

    public sealed class Dataset
    {
        public string Name, FileName;
        public List<Column> Columns = new List<Column>();
        public List<object[]> Rows = new List<object[]>();
        public bool Html = true;
        public Dataset(string name, string fileName) { Name = name; FileName = fileName; }
        public Column Add(string name, string kind) { var c = new Column(name, kind); Columns.Add(c); return c; }
    }

    public sealed class ReportFile { public string Path, Dataset; public long Rows, Bytes; }

    public sealed class ReportResult
    {
        public string Folder, HtmlPath;
        public List<ReportFile> Files = new List<ReportFile>();
        public Dictionary<string, long> Counts = new Dictionary<string, long>();
        public List<string> Notes = new List<string>();
    }

    public static partial class ReportBuilder
    {
        // ------------------------------------------------------------------ filters

        sealed class Sql
        {
            public readonly Dictionary<string, object> P = new Dictionary<string, object>();
            int _n;
            public string Users(string[] users, params string[] columns)
            {
                var parts = new List<string>();
                foreach (var u in users ?? new string[0])
                {
                    if (string.IsNullOrWhiteSpace(u)) continue;
                    string name = "@u" + (_n++);
                    P[name] = "%" + u.Trim().ToLowerInvariant() + "%";
                    foreach (var col in columns) parts.Add("lower(" + col + ") LIKE " + name);
                }
                return parts.Count == 0 ? "" : " AND (" + string.Join(" OR ", parts) + ")";
            }
            public string Servers(string[] servers, string column)
            {
                var names = new List<string>();
                foreach (var s in servers ?? new string[0])
                {
                    if (string.IsNullOrWhiteSpace(s)) continue;
                    string name = "@s" + (_n++);
                    P[name] = s.Trim().ToLowerInvariant();
                    names.Add(name);
                }
                return names.Count == 0 ? "" : " AND lower(" + column + ") IN (" + string.Join(",", names) + ")";
            }
        }

        static IEnumerable<object[]> Rows(Store store, string sql, Dictionary<string, object> p)
        {
            using (var c = store.Command(sql, p))
            using (var r = c.ExecuteReader())
            {
                while (r.Read())
                {
                    var row = new object[r.FieldCount];
                    for (int i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                    yield return row;
                }
            }
        }

        static long L(object v) { return v == null ? 0 : Convert.ToInt64(v, CultureInfo.InvariantCulture); }
        static string S(object v) { return v == null ? null : Convert.ToString(v, CultureInfo.InvariantCulture); }

        static T Get<T>(Dictionary<string, T> d, string key) where T : new()
        {
            T v;
            if (!d.TryGetValue(key, out v)) { v = new T(); d[key] = v; }
            return v;
        }

        sealed class ServerStats
        {
            public long Users, Requests, Failed, Unresolved, FirstMs, LastMs, Days, SmtpIn, SmtpOut, SmtpRejected, Messages, Deliveries, MessageFailures;
            public List<object[]> Protocols = new List<object[]>();
        }

        sealed class DayStats { public long Users, Requests, Failed, SmtpIn, SmtpOut, Messages; }

        // ------------------------------------------------------------------ build

        public static ReportResult Build(Store store, ReportRequest q)
        {
            var result = new ReportResult { Folder = q.OutputFolder };
            Directory.CreateDirectory(q.OutputFolder);
            var zone = q.Zone;
            string d0 = TimeUtil.Day(q.StartMs, zone), d1 = TimeUtil.Day(q.EndMs - 1, zone), d2 = TimeUtil.Day(q.EndMs + 86400000L, zone);
            Func<long, object> local = ms => ms > 0 ? (object)TimeUtil.ToLocalSeconds(ms, zone) : null;

            // ---- client access: failures and their resolution --------------------------------------
            var f = new Sql(); f.P["@t0"] = q.StartMs; f.P["@t1"] = q.EndMs; f.P["@d0"] = d0; f.P["@d2"] = d2;
            string fu = f.Users(q.Users, "e.user", "e.mailbox"), fs = f.Servers(q.Servers, "e.server");
            var lastSuccess = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (var r in Rows(store, "SELECT user, protocol, day, MAX(last_success_ms) FROM access_usage WHERE day >= @d0 AND day <= @d2 GROUP BY user, protocol, day;", f.P))
                lastSuccess[S(r[0]) + "|" + S(r[1]) + "|" + S(r[2])] = L(r[3]);
            bool withSuccesses = q.Detailed && q.Users.Any(u => !string.IsNullOrWhiteSpace(u));
            var issues = new Dataset("issues", "ClientAccess-Requests") { Html = q.Detailed };
            foreach (var n in new[] { "Time:time", "Server:text", "Source:text", "Protocol:text", "User:text", "Mailbox:text", "Client IP:text", "Client:text",
                "Method:text", "URL:text", "Action:text", "Status:num", "Sub-status:num", "Win32 status:num", "Back-end status:num", "Error code:text",
                "Target server:text", "Authentication:text", "Duration (ms):num", "Outcome:text", "Resolution:text", "Recovered after:text",
                "Request ID:text", "User agent:text", "Errors:text" })
            { var p = n.Split(':'); issues.Add(p[0], p[1]); }
            var unresolvedByServer = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var unresolvedByUser = new Dictionary<string, long>(StringComparer.Ordinal);
            string issueSql = "SELECT e.time_ms,e.server,e.source,e.protocol,e.user,e.mailbox,e.client_ip,e.user_agent,e.method,e.url,e.action,e.status," +
                "COALESCE(e.sub_status,i.sub_status),COALESCE(e.win32,i.win32),e.backend_status,e.error_code,e.target_server,e.auth_type," +
                "COALESCE(NULLIF(e.duration_ms,0),i.time_taken),e.outcome,e.recovered_ms,e.request_id,e.errors " +
                "FROM access_event e LEFT JOIN iis_status i ON i.server=e.server AND i.request_id=e.request_id " +
                "WHERE e.time_ms >= @t0 AND e.time_ms < @t1" + fu + fs + (withSuccesses ? "" : " AND e.outcome <> 'Success'") + " ORDER BY e.time_ms;";
            foreach (var r in Rows(store, issueSql, f.P))
            {
                long t = L(r[0]);
                string server = S(r[1]), user = S(r[4]), protocol = S(r[3]), outcome = S(r[19]);
                string resolution = "", after = null;
                if (outcome == "Slow") resolution = "Slow success";
                else if (outcome != "Success")
                {
                    long recovered = L(r[20]);
                    if (recovered > 0) { resolution = "Recovered"; after = TimeUtil.Duration((recovered - t) / 1000.0); }
                    else
                    {
                        long later = 0, x;
                        foreach (var day in new[] { TimeUtil.Day(t, zone), TimeUtil.Day(t + 86400000L, zone) })
                            if (lastSuccess.TryGetValue(user + "|" + protocol + "|" + day, out x) && x > later) later = x;
                        if (later > t) { resolution = "Recovered later"; after = "later (" + TimeUtil.Format(later, zone, "yyyy-MM-dd HH:mm") + ")"; }
                        else
                        {
                            resolution = "Unresolved";
                            long n;
                            unresolvedByServer.TryGetValue(server, out n); unresolvedByServer[server] = n + 1;
                            unresolvedByUser.TryGetValue(user ?? "", out n); unresolvedByUser[user ?? ""] = n + 1;
                        }
                    }
                }
                issues.Rows.Add(new object[] { local(t), server, S(r[2]), protocol, user, S(r[5]), S(r[6]), Identity.Client(S(r[7])), S(r[8]), S(r[9]), S(r[10]),
                    r[11], r[12], r[13], r[14], S(r[15]), S(r[16]), S(r[17]), r[18], outcome, resolution, after, S(r[21]), S(r[7]), S(r[22]) });
            }

            // ---- client access aggregates ------------------------------------------------------------
            var a = new Sql(); a.P["@d0"] = d0; a.P["@d1"] = d1;
            string au = a.Users(q.Users, "user", "mailbox"), asv = a.Servers(q.Servers, "server");
            string usageWhere = " FROM access_usage WHERE day >= @d0 AND day <= @d1" + au + asv;
            var servers = new Dictionary<string, ServerStats>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in Rows(store, "SELECT server, COUNT(DISTINCT user), SUM(requests), SUM(client_errors+server_errors), MIN(first_ms), MAX(last_ms), COUNT(DISTINCT day)" + usageWhere + " GROUP BY server;", a.P))
            {
                var s = Get(servers, S(r[0]));
                s.Users = L(r[1]); s.Requests = L(r[2]); s.Failed = L(r[3]); s.FirstMs = L(r[4]); s.LastMs = L(r[5]); s.Days = L(r[6]);
            }
            foreach (var r in Rows(store, "SELECT server, protocol, SUM(requests), SUM(client_errors+server_errors)" + usageWhere + " GROUP BY server, protocol ORDER BY 3 DESC;", a.P))
                Get(servers, S(r[0])).Protocols.Add(new object[] { S(r[1]), L(r[2]), L(r[3]) });
            var daily = new Dictionary<string, DayStats>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in Rows(store, "SELECT day, server, COUNT(DISTINCT user), SUM(requests), SUM(client_errors+server_errors)" + usageWhere + " GROUP BY day, server;", a.P))
            {
                var d = Get(daily, S(r[0]) + "|" + S(r[1]));
                d.Users = L(r[2]); d.Requests = L(r[3]); d.Failed = L(r[4]);
            }

            // ---- mail flow aggregates ----------------------------------------------------------------
            var m = new Sql(); m.P["@t0"] = q.StartMs; m.P["@t1"] = q.EndMs;
            string su = m.Users(q.Users, "mail_from", "rcpts"), ss = m.Servers(q.Servers, "server");
            string tu = m.Users(q.Users, "sender", "recipients"), ts = m.Servers(q.Servers, "server");
            string smtpWhere = " FROM smtp_transaction WHERE time_ms >= @t0 AND time_ms < @t1" + su + ss;
            string msgWhere = " FROM message_event WHERE time_ms >= @t0 AND time_ms < @t1" + tu + ts;
            foreach (var r in Rows(store, "SELECT server, direction, status, COUNT(*)" + smtpWhere + " GROUP BY server, direction, status;", m.P))
            {
                var s = Get(servers, S(r[0]));
                long n = L(r[3]);
                if (S(r[1]) == "Receive") s.SmtpIn += n; else s.SmtpOut += n;
                if (S(r[2]) == "Rejected") s.SmtpRejected += n;
            }
            foreach (var r in Rows(store, "SELECT time_ms/3600000, server, direction, COUNT(*)" + smtpWhere + " GROUP BY 1, 2, 3;", m.P))
            {
                var d = Get(daily, TimeUtil.Day(L(r[0]) * 3600000L, zone) + "|" + S(r[1]));
                if (S(r[2]) == "Receive") d.SmtpIn += L(r[3]); else d.SmtpOut += L(r[3]);
            }
            foreach (var r in Rows(store, "SELECT server, COUNT(DISTINCT COALESCE(message_id, internal_id)), SUM(CASE WHEN event_id='DELIVER' THEN 1 ELSE 0 END), SUM(CASE WHEN event_id IN ('FAIL','DSN') THEN 1 ELSE 0 END)" + msgWhere + " GROUP BY server;", m.P))
            {
                var s = Get(servers, S(r[0]));
                s.Messages = L(r[1]); s.Deliveries = L(r[2]); s.MessageFailures = L(r[3]);
            }
            foreach (var r in Rows(store, "SELECT time_ms/3600000, server, COUNT(DISTINCT COALESCE(message_id, internal_id))" + msgWhere + " GROUP BY 1, 2;", m.P))
                Get(daily, TimeUtil.Day(L(r[0]) * 3600000L, zone) + "|" + S(r[1])).Messages += L(r[2]);
            // Servers without client access (Edge Transport, mail flow only): activity dates and days from the mail flow.
            foreach (var r in Rows(store, "SELECT server, MIN(time_ms), MAX(time_ms)" + smtpWhere + " GROUP BY server UNION ALL SELECT server, MIN(time_ms), MAX(time_ms)" + msgWhere + " GROUP BY server;", m.P))
            {
                var s = Get(servers, S(r[0]));
                if (s.Requests > 0) continue;
                if (s.FirstMs == 0 || L(r[1]) < s.FirstMs) s.FirstMs = L(r[1]);
                if (L(r[2]) > s.LastMs) s.LastMs = L(r[2]);
            }
            foreach (var kv in servers.Where(x => x.Value.Requests == 0))
                kv.Value.Days = daily.Count(d => d.Key.EndsWith("|" + kv.Key, StringComparison.OrdinalIgnoreCase) && d.Value.SmtpIn + d.Value.SmtpOut + d.Value.Messages > 0);

            // ---- servers dataset: every configured server appears, used or not --------------------------
            var serverSet = new Dataset("servers", "Servers");
            foreach (var n in new[] { "Server:text", "Verdict:text", "Real users:num", "Requests:num", "Failed requests:num", "Unresolved failures:num",
                "Protocols:text", "First activity:time", "Last activity:time", "Active days:num", "SMTP received:num", "SMTP sent:num",
                "SMTP rejected:num", "Messages:num", "Deliveries:num", "Message failures:num", "Protocol detail:steps" })
            { var p = n.Split(':'); serverSet.Add(p[0], p[1]); }
            serverSet.Columns[16].Grid = false; serverSet.Columns[16].Csv = false;
            var names = new List<string>();
            var filter = new HashSet<string>((q.Servers ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)), StringComparer.OrdinalIgnoreCase);
            foreach (var n in q.ConfiguredServers ?? new string[0]) if ((filter.Count == 0 || filter.Contains(n)) && !names.Contains(n, StringComparer.OrdinalIgnoreCase)) names.Add(n);
            foreach (var n in servers.Keys.OrderBy(x => x)) if (!names.Contains(n, StringComparer.OrdinalIgnoreCase)) names.Add(n);
            foreach (var n in names)
            {
                ServerStats s;
                if (!servers.TryGetValue(n, out s)) s = new ServerStats();
                long unresolved; unresolvedByServer.TryGetValue(n, out unresolved);
                bool access = s.Users > 0, mail = s.SmtpIn + s.SmtpOut + s.Messages > 0;
                string verdict = access && mail ? "In use" : access ? "Client access only" : mail ? "Mail flow only" : "No real usage";
                long firstMs = s.FirstMs, lastMs = s.LastMs;
                serverSet.Rows.Add(new object[] { n, verdict, s.Users, s.Requests, s.Failed, unresolved,
                    string.Join(", ", s.Protocols.Select(p => p[0] + " " + L(p[1]).ToString("N0", CultureInfo.InvariantCulture))),
                    local(firstMs), local(lastMs), s.Days, s.SmtpIn, s.SmtpOut, s.SmtpRejected, s.Messages, s.Deliveries, s.MessageFailures, s.Protocols });
            }

            // ---- daily dataset ----------------------------------------------------------------------------
            var dailySet = new Dataset("daily", "Daily");
            foreach (var n in new[] { "Day:text", "Server:text", "Real users:num", "Requests:num", "Failed requests:num", "SMTP received:num", "SMTP sent:num", "Messages:num" })
            { var p = n.Split(':'); dailySet.Add(p[0], p[1]); }
            foreach (var kv in daily.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                var key = kv.Key.Split('|');
                if (string.CompareOrdinal(key[0], d0) < 0 || string.CompareOrdinal(key[0], d1) > 0) continue;
                dailySet.Rows.Add(new object[] { key[0], key[1], kv.Value.Users, kv.Value.Requests, kv.Value.Failed, kv.Value.SmtpIn, kv.Value.SmtpOut, kv.Value.Messages });
            }

            // ---- users dataset ----------------------------------------------------------------------------
            var userSet = new Dataset("users", "Users");
            foreach (var n in new[] { "User:text", "Mailbox:text", "Protocols:text", "Clients:text", "Servers:text", "Requests:num", "Failed requests:num",
                "Unresolved failures:num", "Active days:num", "First seen:time", "Last seen:time", "Last client IP:text", "Last user agent:text", "Protocol detail:steps",
                "Clients and devices:steps" })
            { var p = n.Split(':'); userSet.Add(p[0], p[1]); }
            userSet.Columns[13].Grid = false; userSet.Columns[13].Csv = false;
            userSet.Columns[14].Grid = false; userSet.Columns[14].Csv = false;
            // Clients and devices: a CSV of their own, and the detail of each user in the HTML report.
            var clientSet = BuildClients(store, q, d0, d1, local);
            clientSet.Html = false;
            var clientsOf = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
            foreach (var c in clientSet.Rows)
                Get(clientsOf, S(c[0])).Add(new object[] { c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[11] });
            var lastSeen = new Dictionary<string, object[]>(StringComparer.Ordinal);
            foreach (var r in Rows(store, "SELECT user, client_ip, user_agent FROM (SELECT user, client_ip, user_agent, ROW_NUMBER() OVER (PARTITION BY user ORDER BY last_ms DESC) AS rn" + usageWhere + ") WHERE rn = 1;", a.P))
                lastSeen[S(r[0])] = r;
            var clients = new Dictionary<string, Dictionary<string, long>>(StringComparer.Ordinal);
            foreach (var r in Rows(store, "SELECT user, user_agent, SUM(requests)" + usageWhere + " GROUP BY user, user_agent;", a.P))
            {
                var c = Get(clients, S(r[0]));
                string family = Identity.Client(S(r[1]));
                long n; c.TryGetValue(family, out n); c[family] = n + L(r[2]);
            }
            var detail = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
            foreach (var r in Rows(store, "SELECT user, protocol, SUM(requests), SUM(client_errors+server_errors), MAX(last_ms), group_concat(DISTINCT server)" + usageWhere + " GROUP BY user, protocol ORDER BY 3 DESC;", a.P))
                Get(detail, S(r[0])).Add(new object[] { S(r[1]), L(r[2]), L(r[3]), local(L(r[4])), (S(r[5]) ?? "").Replace(",", ", ") });
            foreach (var r in Rows(store, "SELECT user, MAX(mailbox), SUM(requests), SUM(client_errors+server_errors), MIN(first_ms), MAX(last_ms), group_concat(DISTINCT server), group_concat(DISTINCT protocol), COUNT(DISTINCT day)" + usageWhere + " GROUP BY user ORDER BY SUM(requests) DESC;", a.P))
            {
                string user = S(r[0]);
                object[] last; lastSeen.TryGetValue(user, out last);
                Dictionary<string, long> fam; clients.TryGetValue(user, out fam);
                long unresolved; unresolvedByUser.TryGetValue(user, out unresolved);
                List<object[]> det; detail.TryGetValue(user, out det);
                List<object[]> devices; clientsOf.TryGetValue(user, out devices);
                userSet.Rows.Add(new object[] { user, S(r[1]), (S(r[7]) ?? "").Replace(",", ", "),
                    fam == null ? null : string.Join(", ", fam.OrderByDescending(x => x.Value).Select(x => x.Key)),
                    (S(r[6]) ?? "").Replace(",", ", "), L(r[2]), L(r[3]), unresolved, L(r[8]), local(L(r[4])), local(L(r[5])),
                    last == null ? null : S(last[1]), last == null ? null : S(last[2]), det ?? new List<object[]>(), devices ?? new List<object[]>() });
            }

            // ---- detailed datasets ------------------------------------------------------------------------
            Dataset messageSet = null, smtpSet = null, sessionSet = null;
            if (q.Detailed)
            {
                sessionSet = BuildSessions(store, q, local);
                messageSet = BuildMessages(store, q, tu, su, ts, m.P, local);
                smtpSet = BuildSmtp(store, q, su, ss, m.P, local);
                smtpSet.Html = false;
            }
            var smtpClientSet = BuildSmtpClients(store, q, su, ss, m.P, local);
            var smtpDestinationSet = q.Edge ? BuildSmtpDestinations(store, q, su, ss, m.P, local) : null;
            var operationSet = q.Users.Any(u => !string.IsNullOrWhiteSpace(u)) ? null : BuildOperations(store, q, d0, d1);

            // ---- notes ------------------------------------------------------------------------------------
            if (q.DetailCutoffMs > q.StartMs)
                result.Notes.Add((q.Edge ? "SMTP transcripts are kept " : "Request-level failures, client sessions and SMTP transcripts are kept ") + Math.Round((DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - q.DetailCutoffMs) / 86400000.0) +
                    " days: before " + TimeUtil.Format(q.DetailCutoffMs, zone, "yyyy-MM-dd HH:mm") + " the report shows the daily aggregates only.");
            if (q.Edge)
                result.Notes.Add("Edge Transport report: SMTP protocol logs and message tracking of " + string.Join(", ", q.EdgeServers) + ". An Edge Transport server has no client access (no IIS, HttpProxy, MAPI, ActiveSync, POP or IMAP).");
            else
            {
                if (TimeUtil.ToLocal(q.StartMs, zone).TimeOfDay != TimeSpan.Zero || TimeUtil.ToLocal(q.EndMs, zone).TimeOfDay != TimeSpan.Zero)
                    result.Notes.Add("Client access usage is aggregated per day: the first and last day of the period are counted as whole days.");
                if (operationSet == null) result.Notes.Add("Operations are measured per server, not per user: the Operations view is not built when the report is filtered on users.");
            }

            // ---- files ------------------------------------------------------------------------------------
            List<Dataset> sets;
            if (q.Edge)
            {
                // Client access columns mean nothing on an Edge Transport server: left out of the files.
                var clientAccess = new[] { "Real users", "Requests", "Failed requests", "Unresolved failures", "Protocols", "Protocol detail" };
                DropColumns(serverSet, clientAccess);
                DropColumns(dailySet, clientAccess);
                sets = new List<Dataset> { serverSet, dailySet, smtpClientSet, smtpDestinationSet };
                if (q.Detailed) { sets.Add(messageSet); sets.Add(smtpSet); }
            }
            else
            {
                sets = new List<Dataset> { serverSet, dailySet, userSet, clientSet };
                if (operationSet != null) sets.Add(operationSet);
                sets.Add(smtpClientSet);
                if (q.Detailed) { sets.Add(sessionSet); sets.Add(issues); sets.Add(messageSet); sets.Add(smtpSet); }
            }
            foreach (var d in sets) result.Counts[d.Name] = d.Rows.Count;
            if (sessionSet != null && sets.Contains(sessionSet))
            {
                int outcome = sessionSet.Columns.FindIndex(x => x.Name == "Outcome");
                result.Counts["sessionsWithFailures"] = sessionSet.Rows.Count(r => { var o = S(r[outcome]) ?? ""; return o != "OK" && o != "OK (slow)"; });
            }
            if (q.WriteCsv)
            {
                foreach (var d in sets) result.Files.Add(WriteCsv(d, Path.Combine(q.OutputFolder, q.FilePrefix + "-" + d.FileName + ".csv"), q.CsvDelimiter));
                string accessPath = Path.Combine(q.OutputFolder, q.FilePrefix + "-ClientAccess-Daily.csv");
                if (!q.Edge) result.Files.Add(WriteAccessCsv(store, accessPath, q.CsvDelimiter, "SELECT day, server, user, mailbox, protocol, requests, successes, client_errors, server_errors, slow, bytes_in, bytes_out, CASE WHEN requests > 0 THEN total_ms / requests END, max_ms, first_ms, last_ms, client_ip, user_agent" + usageWhere + " ORDER BY day, server, user, protocol;", a.P, zone));
            }
            if (q.WriteHtml)
            {
                result.HtmlPath = Path.Combine(q.OutputFolder, q.FilePrefix + ".html");
                result.Files.Add(WriteHtml(q, sets, result.Notes, result.HtmlPath));
            }
            return result;
        }

        // ------------------------------------------------------------------ messages: one row per message

        sealed class Journey
        {
            public string MessageId, Sender, Subject, Direction;
            public long First, Last, Size, MaxCount;
            public List<object[]> Events = new List<object[]>();
        }

        static Dataset BuildMessages(Store store, ReportRequest q, string userFilter, string smtpUserFilter, string serverFilter, Dictionary<string, object> p, Func<long, object> local)
        {
            var set = new Dataset("messages", "Messages");
            foreach (var n in new[] { "First event:time", "Last event:time", "Duration:text", "Status:text", "Sender:text", "Recipients:list", "Recipient count:num",
                "Delivered:num", "Failed:num", "Subject:text", "Size (KB):num", "Direction:text", "Servers:text", "Events:text", "SMTP sessions:num",
                "Message ID:text", "Route:steps", "SMTP transcripts:steps" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[16].Grid = false; set.Columns[16].Csv = q.IncludeRoutingDetails;
            set.Columns[17].Grid = false; set.Columns[17].Csv = false;
            string selection = "SELECT message_id FROM message_event WHERE time_ms >= @t0 AND time_ms < @t1 AND message_id IS NOT NULL" + userFilter + serverFilter;

            var smtp = new Dictionary<string, List<object[]>>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in Rows(store, "SELECT message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,status,response,transcript,session_id FROM smtp_transaction WHERE message_id IN (" + selection + ") ORDER BY time_ms;", p))
                Get(smtp, S(r[0])).Add(r);

            Journey j = null;
            Action flush = () => { if (j != null) set.Rows.Add(JourneyRow(j, smtp, q, local)); };
            foreach (var r in Rows(store, "SELECT message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference FROM message_event WHERE message_id IN (" + selection + ") ORDER BY message_id, time_ms, id;", p))
            {
                string id = S(r[0]);
                if (j == null || !string.Equals(j.MessageId, id, StringComparison.Ordinal))
                {
                    flush();
                    j = new Journey { MessageId = id, First = L(r[1]) };
                }
                j.Last = L(r[1]);
                if (j.Sender == null) j.Sender = S(r[6]);
                if (j.Subject == null) j.Subject = S(r[11]);
                if (j.Direction == null) j.Direction = S(r[17]);
                j.Size = Math.Max(j.Size, L(r[10]));
                j.MaxCount = Math.Max(j.MaxCount, L(r[9]));
                j.Events.Add(r);
            }
            flush();
            // Mail refused during the SMTP conversation (relay denied, unknown recipient, size...): no Message-ID,
            // no tracking event. One row each, so that every message problem is in the same view.
            foreach (var r in Rows(store, "SELECT time_ms,end_ms,server,role,connector,remote_ep,helo,tls,auth,mail_from,rcpts,status,response,transcript,session_id FROM smtp_transaction " +
                "WHERE time_ms >= @t0 AND time_ms < @t1 AND direction='Receive' AND message_id IS NULL AND status <> 'Accepted'" + smtpUserFilter + serverFilter + " ORDER BY time_ms;", p))
            {
                long t = L(r[0]), end = r[1] == null ? t : L(r[1]);
                var rcpts = (S(r[10]) ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries).Where(x => x.Trim().Length > 0).ToArray();
                string status = S(r[11]) == "Deferred" ? "Deferred (SMTP)" : S(r[11]) == "Rejected" ? "Rejected (SMTP)" : "Not completed (SMTP)";
                var parts = new List<string>();
                if (S(r[5]) != null) parts.Add("remote " + S(r[5]));
                if (S(r[4]) != null) parts.Add(S(r[4]));
                if (S(r[6]) != null) parts.Add("HELO " + S(r[6]));
                if (S(r[7]) != null) parts.Add(S(r[7]));
                if (S(r[8]) != null) parts.Add("auth " + S(r[8]));
                if (S(r[12]) != null) parts.Add(S(r[12]));
                var route = new List<object[]> { new object[] { local(t), S(r[2]), "SMTP Receive" + (S(r[3]) != null ? " (" + S(r[3]) + ")" : ""), S(r[11]), string.Join(" | ", parts) } };
                var transcripts = new List<object[]>();
                if (q.IncludeRoutingDetails && S(r[13]) != null) transcripts.Add(new object[] { local(t), S(r[2]), "Receive " + S(r[14]), S(r[13]) });
                set.Rows.Add(new object[] {
                    local(t), local(end), TimeUtil.Duration((end - t) / 1000.0), status, S(r[9]), rcpts.Select(x => x + " (" + S(r[11]) + ")").ToArray(),
                    (long)rcpts.Length, 0L, status == "Rejected (SMTP)" ? (long)rcpts.Length : 0L, null, null, "Incoming (SMTP)", S(r[2]), "SMTP " + S(r[11]), 1L,
                    null, q.IncludeRoutingDetails ? route : new List<object[]>(), transcripts });
            }
            set.Rows.Sort((x, y) => Comparer<long>.Default.Compare(L(x[0]), L(y[0])));
            return set;
        }

        static readonly HashSet<string> Final = new HashSet<string>(StringComparer.Ordinal) { "Delivered", "Failed", "Dropped", "Poison" };

        static object[] JourneyRow(Journey j, Dictionary<string, List<object[]>> smtp, ReportRequest q, Func<long, object> local)
        {
            var status = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var order = new List<string>();
            var servers = new List<string>();
            var events = new List<string>();
            var steps = new List<object[]>();
            Action<string, string> set = (rcpt, value) =>
            {
                if (string.IsNullOrEmpty(rcpt)) return;
                string current;
                if (!status.TryGetValue(rcpt, out current)) order.Add(rcpt);
                else if (current == "Delivered" && value != "Failed") return;
                status[rcpt] = value;
            };
            bool dropped = false;
            foreach (var e in j.Events)
            {
                string server = S(e[2]), evt = S(e[3]) ?? "", source = S(e[4]);
                var rcpts = (S(e[7]) ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
                if (!servers.Contains(server, StringComparer.OrdinalIgnoreCase)) servers.Add(server);
                if (events.Count == 0 || events[events.Count - 1] != evt) events.Add(evt);
                switch (evt)
                {
                    case "DELIVER": foreach (var x in rcpts) set(x, "Delivered"); break;
                    // SENDEXTERNAL: handed over by SMTP outside the transport services of the organization (an Edge
                    // Transport server to the mailbox servers or the internet): same meaning as SEND for the report.
                    case "SEND": case "SENDEXTERNAL": foreach (var x in rcpts) { string cur; if (!status.TryGetValue(x, out cur) || !Final.Contains(cur)) set(x, "Sent"); } break;
                    case "FAIL": foreach (var x in rcpts) set(x, "Failed"); break;
                    case "DEFER": foreach (var x in rcpts) { string cur; if (!status.TryGetValue(x, out cur) || !Final.Contains(cur)) set(x, "Deferred"); } break;
                    case "DROP": dropped = true; foreach (var x in rcpts) set(x, "Dropped"); break;
                    case "POISONMESSAGE": foreach (var x in rcpts) set(x, "Poison"); break;
                    case "EXPAND": foreach (var x in rcpts) set(x, "Expanded"); break;
                    default: foreach (var x in rcpts) if (!status.ContainsKey(x)) set(x, "In transit"); break;
                }
                steps.Add(new object[] { local(L(e[1])), server, "Tracking", evt, StepDetail(e, rcpts) });
            }
            List<object[]> sessions;
            smtp.TryGetValue(j.MessageId ?? "", out sessions);
            var transcripts = new List<object[]>();
            if (sessions != null)
                foreach (var s in sessions)
                {
                    var parts = new List<string>();
                    if (S(s[7]) != null) parts.Add("remote " + S(s[7]));
                    if (S(s[6]) != null) parts.Add(S(s[6]));
                    if (S(s[9]) != null) parts.Add("HELO " + S(s[9]));
                    if (S(s[10]) != null) parts.Add(S(s[10]));
                    if (S(s[11]) != null) parts.Add("auth " + S(s[11]));
                    if (S(s[15]) != null) parts.Add(S(s[15]));
                    steps.Add(new object[] { local(L(s[1])), S(s[3]), "SMTP " + S(s[4]) + (S(s[5]) != null ? " (" + S(s[5]) + ")" : ""), S(s[14]), string.Join(" | ", parts) });
                    if (q.IncludeRoutingDetails && S(s[16]) != null)
                        transcripts.Add(new object[] { local(L(s[1])), S(s[3]), S(s[4]) + " " + S(s[17]), S(s[16]) });
                }
            steps.Sort((x, y) => Comparer<long>.Default.Compare(L(x[0]), L(y[0])));
            var finals = order.Where(r => status[r] != "Expanded").ToList();
            int total = finals.Count;
            int delivered = finals.Count(r => status[r] == "Delivered"), failed = finals.Count(r => status[r] == "Failed" || status[r] == "Poison");
            int sent = finals.Count(r => status[r] == "Sent"), deferred = finals.Count(r => status[r] == "Deferred"), drop = finals.Count(r => status[r] == "Dropped");
            string overall;
            if (total == 0) overall = dropped ? "Dropped" : "In transit";
            else if (failed == total) overall = "Failed";
            else if (failed > 0) overall = "Partially failed";
            else if (drop > 0) overall = drop == total ? "Dropped" : "Partially dropped";
            else if (delivered == total) overall = "Delivered";
            else if (delivered + sent == total) overall = delivered > 0 ? "Delivered and relayed" : "Relayed";
            else if (deferred > 0) overall = "Deferred";
            else overall = "In transit";
            var recipients = finals.Select(r => status[r] == "Delivered" ? r : r + " (" + status[r] + ")").ToArray();
            return new object[] {
                local(j.First), local(j.Last), TimeUtil.Duration((j.Last - j.First) / 1000.0), overall, j.Sender, recipients,
                Math.Max(j.MaxCount, (long)total), (long)delivered, (long)failed, j.Subject, j.Size > 0 ? (object)(long)Math.Ceiling(j.Size / 1024.0) : null,
                j.Direction, string.Join(" > ", servers), string.Join(" > ", events), sessions == null ? 0L : (long)sessions.Count, j.MessageId,
                q.IncludeRoutingDetails ? steps : new List<object[]>(), transcripts };
        }

        static string StepDetail(object[] e, string[] rcpts)
        {
            // e: 4 source, 8 recipient_status, 12 client_ip, 13 client_host, 14 server_host, 15 connector, 16 source_context, 18 related_recipient
            var parts = new List<string>();
            string evt = S(e[3]) ?? "";
            if (S(e[4]) != null) parts.Add(S(e[4]));
            string client = S(e[13]) ?? S(e[12]);
            string peer = S(e[14]);
            if (evt == "RECEIVE" && client != null) parts.Add("from " + client);
            if ((evt == "SEND" || evt == "SENDEXTERNAL") && peer != null) parts.Add("to " + peer);
            if (S(e[15]) != null) parts.Add("connector " + S(e[15]));
            if (rcpts.Length > 0) parts.Add(rcpts.Length <= 3 ? string.Join("; ", rcpts) : string.Join("; ", rcpts.Take(3)) + " (+" + (rcpts.Length - 3) + ")");
            if (S(e[18]) != null) parts.Add("related " + Identity.Cap(S(e[18]), 120));
            if (S(e[8]) != null) parts.Add(Identity.Cap(S(e[8]), 250));
            if (evt != "RECEIVE" && evt != "SEND" && evt != "SENDEXTERNAL" && S(e[16]) != null && parts.Count < 3) parts.Add(Identity.Cap(S(e[16]), 160));
            return string.Join(" | ", parts);
        }

        // ------------------------------------------------------------------ SMTP transactions

        static Dataset BuildSmtp(Store store, ReportRequest q, string userFilter, string serverFilter, Dictionary<string, object> p, Func<long, object> local)
        {
            var set = new Dataset("smtp", "SmtpSessions");
            foreach (var n in new[] { "Time:time", "End:time", "Server:text", "Direction:text", "Role:text", "Connector:text", "Remote:text", "Local:text",
                "HELO:text", "TLS:text", "Authentication:text", "Mail from:text", "Recipient count:num", "Recipients:text", "Message ID:text",
                "Status:text", "Response:text", "Session ID:text", "Transcript:text" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[18].Grid = false; set.Columns[18].Csv = q.IncludeRoutingDetails;
            foreach (var r in Rows(store, "SELECT time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,status,response,session_id,transcript FROM smtp_transaction WHERE time_ms >= @t0 AND time_ms < @t1" + userFilter.Replace("sender", "mail_from").Replace("recipients", "rcpts") + serverFilter + " ORDER BY time_ms;", p))
                set.Rows.Add(new object[] { local(L(r[0])), local(L(r[1])), S(r[2]), S(r[3]), S(r[4]), S(r[5]), S(r[6]), S(r[7]), S(r[8]), S(r[9]), S(r[10]),
                    S(r[11]), r[12], (S(r[13]) ?? "").Replace(";", "; "), S(r[14]), S(r[15]), S(r[16]), S(r[17]), S(r[18]) });
            return set;
        }

        // ------------------------------------------------------------------ SMTP clients

        /// <summary>
        /// One row per SMTP client (remote address + HELO name): the applications, devices, servers and
        /// users that send mail to the collected servers, with their volume and refusals. Hops between the
        /// collected Exchange servers (HELO of a configured server, delivery to the mailbox role) are left out.
        /// The Detailed report keeps up to 200 transactions per client (refusals first) with their transcript.
        /// </summary>
        static Dataset BuildSmtpClients(Store store, ReportRequest q, string userFilter, string serverFilter, Dictionary<string, object> p, Func<long, object> local)
        {
            var set = new Dataset("smtpclients", "SmtpClients");
            foreach (var n in new[] { "Remote IP:text", "HELO:text", "Servers:text", "Connectors:text", "Transactions:num", "Accepted:num", "Rejected:num",
                "Deferred:num", "Not completed:num", "Recipients:num", "Senders:text", "TLS:text", "Authentication:text", "First seen:time", "Last seen:time",
                "Last error:text", "Transactions detail:steps" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[16].Grid = false; set.Columns[16].Csv = false;
            var exchange = new HashSet<string>((q.ConfiguredServers ?? new string[0]).Select(x => x.ToUpperInvariant()), StringComparer.OrdinalIgnoreCase);
            var clients = new Dictionary<string, SmtpClient>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in Rows(store, "SELECT time_ms,server,connector,remote_ep,helo,tls,auth,mail_from,rcpt_count,status,response,message_id,transcript,role FROM smtp_transaction " +
                "WHERE time_ms >= @t0 AND time_ms < @t1 AND direction='Receive'" + userFilter + serverFilter + " ORDER BY time_ms;", p))
            {
                string helo = S(r[4]), role = S(r[13]);
                if (string.Equals(role, "Mailbox", StringComparison.OrdinalIgnoreCase)) continue;
                if (helo != null && exchange.Contains(Identity.ServerName(helo) ?? "")) continue;
                string ip = Identity.Host(S(r[3])) ?? "";
                SmtpClient c;
                string key = ip + "|" + (helo ?? "");
                if (!clients.TryGetValue(key, out c)) { c = new SmtpClient { Ip = ip, Helo = helo, First = L(r[0]) }; clients[key] = c; }
                long t = L(r[0]);
                string status = S(r[9]) ?? "";
                c.Last = t; c.Count++;
                switch (status)
                {
                    case "Accepted": c.Accepted++; break;
                    case "Rejected": c.Rejected++; c.LastError = S(r[10]); break;
                    case "Deferred": c.Deferred++; c.LastError = S(r[10]); break;
                    default: c.Incomplete++; break;
                }
                c.Recipients += L(r[8]);
                c.Servers.Add(S(r[1]) ?? ""); if (S(r[2]) != null) c.Connectors.Add(S(r[2]));
                if (S(r[5]) != null) c.Tls.Add(S(r[5]));
                if (S(r[6]) != null) c.Auth.Add(S(r[6]));
                string from = string.IsNullOrEmpty(S(r[7])) ? "<>" : S(r[7]);
                long k; c.Senders.TryGetValue(from, out k); c.Senders[from] = k + 1;
                if (q.Detailed)
                    c.Transactions.Add(new object[] { local(t), S(r[1]), S(r[2]), status, from, L(r[8]), S(r[10]), S(r[11]), q.IncludeRoutingDetails ? S(r[12]) : null });
            }
            int statusIndex = 3;
            foreach (var c in clients.Values.OrderByDescending(x => x.Count))
            {
                var detail = c.Transactions;
                if (detail.Count > 200)
                {
                    var refused = detail.Where(x => S(x[statusIndex]) != "Accepted").Reverse().Take(150).ToList();
                    var accepted = detail.Where(x => S(x[statusIndex]) == "Accepted").Reverse().Take(200 - refused.Count).ToList();
                    detail = refused.Concat(accepted).OrderBy(x => L(x[0])).ToList();
                }
                set.Rows.Add(new object[] { c.Ip, c.Helo, string.Join(", ", c.Servers.OrderBy(x => x)), string.Join(", ", c.Connectors.OrderBy(x => x)), c.Count, c.Accepted,
                    c.Rejected, c.Deferred, c.Incomplete, c.Recipients,
                    string.Join(", ", c.Senders.OrderByDescending(x => x.Value).Take(3).Select(x => x.Key + " x" + x.Value.ToString(CultureInfo.InvariantCulture))) + (c.Senders.Count > 3 ? " (+" + (c.Senders.Count - 3) + ")" : ""),
                    c.Tls.Count == 0 ? "No" : string.Join(", ", c.Tls.OrderBy(x => x)), c.Auth.Count == 0 ? "Anonymous" : string.Join(", ", c.Auth.OrderBy(x => x)),
                    local(c.First), local(c.Last), c.LastError, detail });
            }
            return set;
        }

        sealed class SmtpClient
        {
            public string Ip, Helo, LastError;
            public long First, Last, Count, Accepted, Rejected, Deferred, Incomplete, Recipients;
            public SortedSet<string> Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase), Connectors = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            public SortedSet<string> Tls = new SortedSet<string>(StringComparer.Ordinal), Auth = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            public Dictionary<string, long> Senders = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            public List<object[]> Transactions = new List<object[]>();
        }

        /// <summary>Removes columns (and their values in every row) from a dataset.</summary>
        static void DropColumns(Dataset d, IEnumerable<string> names)
        {
            var drop = new HashSet<int>(d.Columns.Select((c, i) => new { c, i }).Where(x => names.Contains(x.c.Name)).Select(x => x.i));
            if (drop.Count == 0) return;
            d.Columns = d.Columns.Where((c, i) => !drop.Contains(i)).ToList();
            for (int r = 0; r < d.Rows.Count; r++) d.Rows[r] = d.Rows[r].Where((v, i) => !drop.Contains(i)).ToArray();
        }

        // ------------------------------------------------------------------ SMTP destinations (Edge report)

        static readonly System.Text.RegularExpressions.Regex BannerRx = new System.Text.RegularExpressions.Regex(@"(?m)^\S+ S: 220[ -](\S+)", System.Text.RegularExpressions.RegexOptions.Compiled);

        /// <summary>
        /// One row per SMTP destination of the Edge Transport servers (remote address + send connector): Exchange
        /// Online, the MX of the internet domains, the mailbox servers of the organization (EdgeSync), with volume,
        /// deferrals and failures. The remote host is the name in its 220 banner (SMTP transcript, DetailRetentionDays).
        /// The Detailed report keeps up to 200 transactions per destination (failures first) with their transcript.
        /// </summary>
        static Dataset BuildSmtpDestinations(Store store, ReportRequest q, string userFilter, string serverFilter, Dictionary<string, object> p, Func<long, object> local)
        {
            var set = new Dataset("smtpdestinations", "SmtpDestinations");
            foreach (var n in new[] { "Remote IP:text", "Remote host:text", "Connector:text", "Servers:text", "Transactions:num", "Sent:num", "Deferred:num", "Failed:num",
                "Not completed:num", "Recipients:num", "Senders:text", "TLS:text", "First seen:time", "Last seen:time", "Last error:text", "Transactions detail:steps" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[15].Grid = false; set.Columns[15].Csv = false;
            var targets = new Dictionary<string, SmtpTarget>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in Rows(store, "SELECT time_ms,server,connector,remote_ep,tls,mail_from,rcpt_count,status,response,message_id,transcript FROM smtp_transaction " +
                "WHERE time_ms >= @t0 AND time_ms < @t1 AND direction='Send'" + userFilter + serverFilter + " ORDER BY time_ms;", p))
            {
                string ip = Identity.Host(S(r[3])) ?? "", connector = S(r[2]) ?? "";
                SmtpTarget c;
                if (!targets.TryGetValue(ip + "|" + connector, out c)) { c = new SmtpTarget { Ip = ip, Connector = connector, First = L(r[0]) }; targets[ip + "|" + connector] = c; }
                long t = L(r[0]);
                string status = S(r[7]) ?? "", transcript = S(r[10]);
                c.Last = t; c.Count++;
                switch (status)
                {
                    case "Sent": c.Sent++; break;
                    case "Rejected": c.Failed++; c.LastError = S(r[8]); break;
                    case "Deferred": c.Deferred++; c.LastError = S(r[8]); break;
                    default: c.Incomplete++; break;
                }
                if (transcript != null) { var b = BannerRx.Match(transcript); if (b.Success) c.Host = b.Groups[1].Value; }
                c.Recipients += L(r[6]);
                c.Servers.Add(S(r[1]) ?? "");
                if (S(r[4]) != null) c.Tls.Add(S(r[4]));
                string from = string.IsNullOrEmpty(S(r[5])) ? "<>" : S(r[5]);
                long k; c.Senders.TryGetValue(from, out k); c.Senders[from] = k + 1;
                if (q.Detailed)
                    c.Transactions.Add(new object[] { local(t), S(r[1]), S(r[2]), status, from, L(r[6]), S(r[8]), S(r[9]), q.IncludeRoutingDetails ? transcript : null });
            }
            const int statusIndex = 3;
            foreach (var c in targets.Values.OrderByDescending(x => x.Count))
            {
                var detail = c.Transactions;
                if (detail.Count > 200)
                {
                    var failed = detail.Where(x => S(x[statusIndex]) != "Sent").Reverse().Take(150).ToList();
                    var sent = detail.Where(x => S(x[statusIndex]) == "Sent").Reverse().Take(200 - failed.Count).ToList();
                    detail = failed.Concat(sent).OrderBy(x => L(x[0])).ToList();
                }
                set.Rows.Add(new object[] { c.Ip, c.Host, c.Connector, string.Join(", ", c.Servers), c.Count, c.Sent, c.Deferred, c.Failed, c.Incomplete, c.Recipients,
                    string.Join(", ", c.Senders.OrderByDescending(x => x.Value).Take(3).Select(x => x.Key + " x" + x.Value.ToString(CultureInfo.InvariantCulture))) + (c.Senders.Count > 3 ? " (+" + (c.Senders.Count - 3) + ")" : ""),
                    c.Tls.Count == 0 ? "No" : string.Join(", ", c.Tls), local(c.First), local(c.Last), c.LastError, detail });
            }
            return set;
        }

        sealed class SmtpTarget
        {
            public string Ip, Host, Connector, LastError;
            public long First, Last, Count, Sent, Deferred, Failed, Incomplete, Recipients;
            public SortedSet<string> Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase), Tls = new SortedSet<string>(StringComparer.Ordinal);
            public Dictionary<string, long> Senders = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            public List<object[]> Transactions = new List<object[]>();
        }

        // ------------------------------------------------------------------ CSV

        static string Csv(object v, string sep)
        {
            if (v == null) return "";
            string s;
            if (v is string) s = (string)v;
            else if (v is long || v is int || v is double) return Convert.ToString(v, CultureInfo.InvariantCulture);
            else s = Convert.ToString(v, CultureInfo.InvariantCulture);
            if (s.Length > 0 && "=+-@\t\r".IndexOf(s[0]) >= 0) s = "'" + s;
            if (s.IndexOf(sep, StringComparison.Ordinal) >= 0 || s.IndexOf('"') >= 0 || s.IndexOf('\n') >= 0 || s.IndexOf('\r') >= 0) s = "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }

        static string CsvCell(object v, Column c)
        {
            if (v == null) return null;
            switch (c.Kind)
            {
                case "time": return DateTimeOffset.FromUnixTimeSeconds(L(v)).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                case "list": return string.Join("; ", (string[])v);
                case "steps":
                    var lines = new List<string>();
                    foreach (var step in (List<object[]>)v)
                        lines.Add(string.Join(" | ", step.Select((x, i) =>
                        {
                            if (i == 0 && x != null) return DateTimeOffset.FromUnixTimeSeconds(L(x)).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                            // Nested rows (log files of a timeline step): "role server path" separated by ";".
                            var nested = x as IEnumerable<object[]>;
                            if (nested != null) return string.Join("; ", nested.Select(n => string.Join(" ", n.Take(4).Where(y => y != null).Select(S))));
                            return S(x);
                        })));
                    return string.Join("\n", lines);
                default: return null;
            }
        }

        static ReportFile WriteCsv(Dataset d, string path, string sep)
        {
            var cols = d.Columns.Select((c, i) => new { c, i }).Where(x => x.c.Csv).ToList();
            using (var w = new StreamWriter(path, false, new UTF8Encoding(true)))
            {
                w.Write(string.Join(sep, cols.Select(x => Csv(x.c.Name, sep))));
                w.Write("\r\n");
                foreach (var row in d.Rows)
                {
                    w.Write(string.Join(sep, cols.Select(x => { object v = row[x.i]; string t = CsvCell(v, x.c); return Csv(t ?? v, sep); })));
                    w.Write("\r\n");
                }
            }
            return new ReportFile { Path = path, Dataset = d.Name, Rows = d.Rows.Count, Bytes = new FileInfo(path).Length };
        }

        static ReportFile WriteAccessCsv(Store store, string path, string sep, string sql, Dictionary<string, object> p, TimeZoneInfo zone)
        {
            string[] header = { "Day", "Server", "User", "Mailbox", "Protocol", "Requests", "Successes", "Client errors", "Server errors", "Slow", "Bytes in", "Bytes out",
                "Average (ms)", "Max (ms)", "First seen", "Last seen", "Last client IP", "Last user agent" };
            long rows = 0;
            using (var w = new StreamWriter(path, false, new UTF8Encoding(true)))
            {
                w.Write(string.Join(sep, header.Select(h => Csv(h, sep))));
                w.Write("\r\n");
                foreach (var r in Rows(store, sql, p))
                {
                    r[14] = r[14] == null ? null : TimeUtil.Format(L(r[14]), zone, "yyyy-MM-dd HH:mm:ss");
                    r[15] = r[15] == null ? null : TimeUtil.Format(L(r[15]), zone, "yyyy-MM-dd HH:mm:ss");
                    w.Write(string.Join(sep, r.Select(v => Csv(v, sep))));
                    w.Write("\r\n");
                    rows++;
                }
            }
            return new ReportFile { Path = path, Dataset = "access", Rows = rows, Bytes = new FileInfo(path).Length };
        }

        // ------------------------------------------------------------------ HTML

        static void WriteValue(Utf8JsonWriter w, object v)
        {
            if (v == null || v is DBNull) { w.WriteNullValue(); return; }
            var s = v as string; if (s != null) { w.WriteStringValue(s); return; }
            if (v is long) { w.WriteNumberValue((long)v); return; }
            if (v is int) { w.WriteNumberValue((int)v); return; }
            if (v is double) { w.WriteNumberValue((double)v); return; }
            if (v is bool) { w.WriteBooleanValue((bool)v); return; }
            var list = v as string[];
            if (list != null) { w.WriteStartArray(); foreach (var x in list) w.WriteStringValue(x); w.WriteEndArray(); return; }
            var rows = v as IEnumerable<object[]>;
            if (rows != null) { w.WriteStartArray(); foreach (var r in rows) WriteValue(w, r); w.WriteEndArray(); return; }
            var arr = v as object[];
            if (arr != null) { w.WriteStartArray(); foreach (var x in arr) WriteValue(w, x); w.WriteEndArray(); return; }
            w.WriteStringValue(Convert.ToString(v, CultureInfo.InvariantCulture));
        }

        static string Chunk(string name, List<object[]> rows, int start, int count)
        {
            using (var ms = new MemoryStream())
            {
                using (var gz = new GZipStream(ms, CompressionLevel.Optimal, true))
                using (var w = new Utf8JsonWriter(gz, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
                {
                    w.WriteStartObject();
                    w.WriteString("set", name);
                    w.WritePropertyName("rows");
                    w.WriteStartArray();
                    for (int i = start; i < start + count; i++) WriteValue(w, rows[i]);
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                return Convert.ToBase64String(ms.GetBuffer(), 0, (int)ms.Length);
            }
        }

        static ReportFile WriteHtml(ReportRequest q, List<Dataset> sets, List<string> notes, string path)
        {
            string template = File.ReadAllText(q.TemplatePath, Encoding.UTF8);
            foreach (var marker in new[] { "%%META%%", "%%CHUNKS%%" })
            {
                int first = template.IndexOf(marker, StringComparison.Ordinal);
                if (first < 0 || template.IndexOf(marker, first + 1, StringComparison.Ordinal) >= 0) throw new InvalidDataException("The template must contain " + marker + " exactly once: " + q.TemplatePath);
            }
            var chunks = new StringBuilder();
            string meta;
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("title", q.Title);
                    w.WriteString("toolVersion", q.ToolVersion);
                    w.WriteString("generated", q.Generated);
                    w.WriteString("timeZone", q.TimeZoneName);
                    w.WriteString("periodStart", TimeUtil.Format(q.StartMs, q.Zone, "yyyy-MM-dd HH:mm"));
                    w.WriteString("periodEnd", TimeUtil.Format(q.EndMs, q.Zone, "yyyy-MM-dd HH:mm"));
                    w.WriteBoolean("detailed", q.Detailed);
                    w.WriteBoolean("edge", q.Edge);
                    w.WriteBoolean("includeRouting", q.IncludeRoutingDetails);
                    w.WriteBoolean("includeSessions", q.IncludeSessionDetails);
                    w.WriteNumber("slowRequestMs", q.SlowRequestMs);
                    w.WritePropertyName("users"); WriteValue(w, (q.Users ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray());
                    w.WritePropertyName("servers"); WriteValue(w, (q.Servers ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray());
                    w.WritePropertyName("configuredServers"); WriteValue(w, q.ConfiguredServers ?? new string[0]);
                    w.WritePropertyName("notes"); WriteValue(w, notes.ToArray());
                    w.WritePropertyName("datasets");
                    w.WriteStartObject();
                    foreach (var d in sets.Where(x => x.Html))
                    {
                        int rows = Math.Min(d.Rows.Count, q.MaxHtmlRows);
                        w.WritePropertyName(d.Name);
                        w.WriteStartObject();
                        w.WriteNumber("rows", rows);
                        w.WriteNumber("total", d.Rows.Count);
                        w.WritePropertyName("columns");
                        w.WriteStartArray();
                        foreach (var c in d.Columns)
                        {
                            w.WriteStartObject(); w.WriteString("name", c.Name); w.WriteString("kind", c.Kind); w.WriteBoolean("grid", c.Grid); w.WriteEndObject();
                        }
                        w.WriteEndArray();
                        w.WriteEndObject();
                        for (int s = 0; s < rows; s += 5000)
                            chunks.Append("<script type=\"application/x-exl-chunk\">").Append(Chunk(d.Name, d.Rows, s, Math.Min(5000, rows - s))).Append("</script>\n");
                    }
                    w.WriteEndObject();
                    w.WriteEndObject();
                }
                meta = Encoding.UTF8.GetString(ms.ToArray());
            }
            string html = template.Replace("%%META%%", meta).Replace("%%CHUNKS%%", chunks.ToString());
            File.WriteAllText(path, html, new UTF8Encoding(false));
            return new ReportFile { Path = path, Dataset = "html", Rows = sets.Sum(d => (long)d.Rows.Count), Bytes = new FileInfo(path).Length };
        }
    }
}
