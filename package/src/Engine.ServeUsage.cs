using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    // =================================================================================================================================
    // The report's own datasets in Serve: /api/report-meta (what the static report's meta carries), /api/overview/servers (servers and daily),
    // /api/requests (failed and slow requests, keyset pages), /api/requests/{requestId}, /api/users, /api/users/{id}, /api/operations,
    // /api/authentication and /api/authentication/{id}.
    // The column lists, statements and row builders are the report's (ReportBuilder, Engine.Report.cs and Engine.ReportSessions.cs); the
    // filters are Serve's (server NOCASE, user substring with escaped LIKE) and times are ISO 8601 strings.
    // The daily tables (access_usage, access_client, access_action) are read for the days of [from, to) in ServeOptions.Zone, narrowed by the
    // optional orderFrom/orderTo window.
    // =================================================================================================================================
    internal sealed partial class ServeRead
    {
        static object LocalIso(long ms) { return ms > 0 ? Iso(ms) : null; }

        /// <summary>The window [from, to) of a daily read (the period narrowed by orderFrom/orderTo) and its days d0..d1; false when it is empty.</summary>
        bool DayWindow(ServeFilter f, out long from, out long to, out string d0, out string d1)
        {
            from = Math.Max(f.From, f.OrderFrom ?? f.From); to = Math.Min(f.To, f.OrderTo ?? f.To);
            d0 = d1 = null;
            if (from >= to) return false;
            d0 = TimeUtil.Day(from, _options.Zone); d1 = TimeUtil.Day(to - 1, _options.Zone);
            return true;
        }

        /// <summary>
        /// Diagnostics (ServeDiagnostics.ExplainReportDatasets): when set, Read runs EXPLAIN QUERY PLAN of each statement instead, records
        /// "statement => plan" and returns no row.
        /// </summary>
        internal List<string> ExplainPlans;
        internal void Explain(string sql, Action<SqliteCommand> parameters)
        {
            using (var c = Command("EXPLAIN QUERY PLAN " + sql))
            {
                parameters(c);
                foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(sql, "@[A-Za-z0-9_]+"))
                    if (!c.Parameters.Contains(m.Value)) c.Parameters.AddWithValue(m.Value, 0L);
                var lines = new List<string>();
                using (var r = c.ExecuteReader()) while (r.Read()) lines.Add(r.GetString(3));
                ExplainPlans.Add(sql + " => " + string.Join(" | ", lines));
            }
        }

        /// <summary>Rows of a statement with the filter parameters, @d0/@d1 and the extra parameters; values unpacked as the report reads them.</summary>
        IEnumerable<object[]> Read(string sql, ServeFilter f, string d0, string d1, Dictionary<string, object> extra = null)
        {
            Action<SqliteCommand> parameters = c =>
            {
                FilterParameters(c, f);
                c.Parameters.AddWithValue("@d0", (object)d0 ?? DBNull.Value); c.Parameters.AddWithValue("@d1", (object)d1 ?? DBNull.Value);
                if (extra != null) foreach (var kv in extra) c.Parameters.AddWithValue(kv.Key, kv.Value ?? DBNull.Value);
            };
            if (ExplainPlans != null) { Explain(sql, parameters); yield break; }
            using (var c = Command(sql))
            {
                parameters(c);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        var row = new object[r.FieldCount];
                        for (int i = 0; i < row.Length; i++) row[i] = r.IsDBNull(i) ? null : Packed.Unpack(r.GetValue(i));
                        yield return row;
                    }
            }
        }

        static string AccessFilter(ServeFilter f, string alias)
        {
            return (f.Server == null ? "" : " AND " + alias + ".server=@s COLLATE NOCASE") +
                (f.User == null ? "" : " AND (" + alias + ".user LIKE @u ESCAPE '\\' OR " + alias + ".mailbox LIKE @u ESCAPE '\\')");
        }
        static string UsageFilter(ServeFilter f)
        {
            return (f.Server == null ? "" : " AND server=@s COLLATE NOCASE") + (f.User == null ? "" : " AND (user LIKE @u ESCAPE '\\' OR mailbox LIKE @u ESCAPE '\\')");
        }

        // MAX(last_success_ms) of a user, protocol and day (the report's "recovered later" test), read from the index entries of ix_usage_day_success
        // (day, user, protocol, last_success_ms: one seek, no row read) and kept for the request (at most LastSuccessMemo keys), or preloaded for a
        // range of days by PreloadLastSuccess. After DaySeeks seeks of one day, the index entries of that day are read once in order (an index-only
        // count): the next seeks of the day find their pages in the cache instead of reading each one from the disk (a page of the failed requests
        // seeks the last successes of a few hundred users of its day).
        readonly Dictionary<string, long> _lastSuccess = new Dictionary<string, long>(StringComparer.Ordinal);
        const int LastSuccessMemo = 1 << 20, DaySeeks = 64;
        SqliteCommand _lastSuccessCommand;
        string _preloadFrom, _preloadTo;
        readonly Dictionary<string, int> _successSeeks = new Dictionary<string, int>(StringComparer.Ordinal);
        static string SuccessKey(string user, string protocol, string day) { return user + "\n" + protocol + "\n" + day; }
        long LastSuccess(string user, string protocol, string day)
        {
            if (user == null || protocol == null) return 0;
            string key = SuccessKey(user, protocol, day);
            long value;
            if (_lastSuccess.TryGetValue(key, out value)) return value;
            // A preloaded day holds every key of that day: a key that is not there has no success.
            if (_preloadFrom != null && string.CompareOrdinal(day, _preloadFrom) >= 0 && string.CompareOrdinal(day, _preloadTo) <= 0) return 0;
            int seeks;
            _successSeeks.TryGetValue(day, out seeks);
            _successSeeks[day] = seeks + 1;
            if (seeks + 1 == DaySeeks)
                using (var c = Command(LastSuccessDaySql)) { c.Parameters.AddWithValue("@ld", day); c.ExecuteScalar(); }
            if (_lastSuccessCommand == null)
            {
                _lastSuccessCommand = Command(LastSuccessSql);
                _lastSuccessCommand.Parameters.Add("@lu", SqliteType.Text); _lastSuccessCommand.Parameters.Add("@ld", SqliteType.Text); _lastSuccessCommand.Parameters.Add("@lp", SqliteType.Text);
            }
            _cancel.ThrowIfCancellationRequested();
            _lastSuccessCommand.Parameters["@lu"].Value = user; _lastSuccessCommand.Parameters["@ld"].Value = day; _lastSuccessCommand.Parameters["@lp"].Value = protocol;
            value = Long(_lastSuccessCommand.ExecuteScalar());
            if (_lastSuccess.Count >= LastSuccessMemo) _lastSuccess.Clear();
            return _lastSuccess[key] = value;
        }
        const string LastSuccessDaySql = "SELECT COUNT(*) FROM access_usage INDEXED BY ix_usage_day_success WHERE day=@ld;";
        const string LastSuccessSql = "SELECT COALESCE(MAX(last_success_ms),0) FROM access_usage INDEXED BY ix_usage_day_success WHERE day=@ld AND user=@lu AND protocol=@lp;";
        // Every last success of days @d0..@d1 from the index entries of ix_usage_day_success (day, user, protocol): no sort, the maximum over the servers in C#.
        const string LastSuccessRangeSql = "SELECT user, protocol, day, last_success_ms FROM access_usage INDEXED BY ix_usage_day_success WHERE day >= @d0 AND day <= @d1 AND last_success_ms > 0;";
        /// <summary>Reads MAX(last_success_ms) of every (user, protocol, day) of days d0..d1 at once (the static report's dictionary).</summary>
        void PreloadLastSuccess(string d0, string d1)
        {
            _lastSuccess.Clear(); _preloadFrom = null;
            using (var c = Command(LastSuccessRangeSql))
            {
                c.Parameters.AddWithValue("@d0", d0); c.Parameters.AddWithValue("@d1", d1);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        string key = SuccessKey(r.GetString(0), r.GetString(1), r.GetString(2));
                        long value = r.GetInt64(3), old;
                        if (!_lastSuccess.TryGetValue(key, out old) || value > old) _lastSuccess[key] = value;
                    }
            }
            _preloadFrom = d0; _preloadTo = d1;
        }
        string Resolution(object[] issue, out string after) { return ReportBuilder.IssueResolution(issue, _options.Zone, LastSuccess, out after); }

        // The failures of a window that the resolution reads: the six fields it needs, from the index entries of ix_event_resolution (ix_event_user for
        // one exact user), without the iis_status join; a failure whose recovery was recorded (Recovered) is not read.
        static string UnresolvedSelection(ServeFilter f, bool exactUser)
        {
            return "SELECT e.time_ms,e.server,e.protocol,e.user,e.outcome,e.recovered_ms FROM access_event e INDEXED BY " + (exactUser ? "ix_event_user" : "ix_event_resolution") +
                " WHERE " + (exactUser ? "e.user=@eu AND " : "") + "e.time_ms>=@a AND e.time_ms<@b" + AccessFilter(f, "e") +
                " AND e.outcome NOT IN('Success','Slow') AND COALESCE(e.recovered_ms,0)<=0;";
        }
        // Up to this many distinct (user, protocol, day) keys the last successes are read key by key; above, the days are preloaded.
        const int LastSuccessSeeks = 50000;
        struct Failure { public long Time, Recovered; public string Server, Protocol, User, Outcome; }

        /// <summary>
        /// Unresolved failures of [from, to) per server and per user (the report's counts), of one user (exact) when exactUser is given. The failures are
        /// read first; their last successes then come from one read of the days (many keys) or from one seek per key (few keys).
        /// </summary>
        void Unresolved(ServeFilter f, long from, long to, string exactUser, Dictionary<string, long> byServer, Dictionary<string, long> byUser)
        {
            string sql = UnresolvedSelection(f, exactUser != null);
            Action<SqliteCommand> parameters = c => { FilterParameters(c, f); c.Parameters.AddWithValue("@a", from); c.Parameters.AddWithValue("@b", to); c.Parameters.AddWithValue("@eu", (object)exactUser ?? DBNull.Value); };
            if (ExplainPlans != null) { Explain(sql, parameters); Explain(LastSuccessRangeSql, c => { }); return; }
            var zone = _options.Zone;
            // The day of an instant, kept per quarter hour: every change of offset is on a quarter hour.
            var days = new Dictionary<long, string>();
            Func<long, string> day = ms =>
            {
                long q = Math.DivRem(ms, 900000L, out long rest) - (rest < 0 ? 1 : 0);
                string d;
                if (!days.TryGetValue(q, out d)) days[q] = d = TimeUtil.Day(q * 900000L, zone);
                return d;
            };
            var failures = new List<Failure>();
            var keys = new HashSet<string>(StringComparer.Ordinal);
            using (var c = Command(sql))
            {
                parameters(c);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        var x = new Failure { Time = r.GetInt64(0), Server = r.GetString(1), Protocol = r.IsDBNull(2) ? null : r.GetString(2), User = r.IsDBNull(3) ? null : r.GetString(3),
                            Outcome = r.GetString(4), Recovered = r.IsDBNull(5) ? 0 : r.GetInt64(5) };
                        failures.Add(x);
                        if (x.User != null && x.Protocol != null && keys.Count <= LastSuccessSeeks)
                        { keys.Add(SuccessKey(x.User, x.Protocol, day(x.Time))); keys.Add(SuccessKey(x.User, x.Protocol, day(x.Time + 86400000L))); }
                    }
            }
            if (failures.Count == 0) return;
            if (keys.Count > LastSuccessSeeks) PreloadLastSuccess(day(from), day(to - 1 + 86400000L));
            foreach (var x in failures)
            {
                string after;
                if (ReportBuilder.IssueResolution(x.Time, x.User, x.Protocol, x.Outcome, x.Recovered, zone, day, LastSuccess, false, out after) != "Unresolved") continue;
                string user = x.User ?? "";
                long n;
                byServer.TryGetValue(x.Server, out n); byServer[x.Server] = n + 1;
                byUser.TryGetValue(user, out n); byUser[user] = n + 1;
            }
        }

        /// <summary>
        /// The unresolved counts of [from, to) per server and per user, read on a read-only connection of their own while this one reads the
        /// aggregates of the same request (same deadline); inline when only the plans are wanted. Wait with Joined.
        /// </summary>
        Task<Dictionary<string, long>[]> UnresolvedAside(ServeFilter f, long from, long to)
        {
            Func<ServeRead, Dictionary<string, long>[]> count = db =>
            {
                var result = new[] { new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase), new Dictionary<string, long>(StringComparer.Ordinal) };
                db.Unresolved(f, from, to, null, result[0], result[1]);
                return result;
            };
            if (ExplainPlans != null) return Task.FromResult(count(this));
            return Task.Run(() => { using (var db = new ServeRead(_options, _cancel)) return count(db); });
        }
        /// <summary>The result of UnresolvedAside; a failure of this connection first waits for it, so no read outlives the request.</summary>
        static Dictionary<string, long>[] Joined(Task<Dictionary<string, long>[]> aside, Action work)
        {
            try { work(); }
            catch { try { aside.Wait(); } catch (AggregateException) { } throw; }
            return aside.GetAwaiter().GetResult();
        }

        static readonly ServeColumn[] IssueColumns = ServeColumn.Parse(ReportBuilder.IssueColumns);
        static readonly ServeColumn[] UserListColumns = ServeColumn.Parse(ReportBuilder.UserColumns.Take(13).Concat(new[] { ReportBuilder.UserColumns[15] }));

        // ------------------------------------------------------------------------------------------------------------ overview: servers, daily

        /// <summary>
        /// The servers and daily datasets of the selection. Real users, active days, first and last activity, protocols and the verdict of a server
        /// cannot be summed over days: servers is always computed over the whole period [from, to). orderFrom/orderTo narrow the daily rows only,
        /// which can be summed: a request with a window returns the daily rows of that window and no servers (null).
        /// The mail flow of the whole hours of the period is read from mail_flow_hour, that of the partial hours at its two ends from the rows, and the
        /// Messages of a server from the rollup (ServerMessages). A user filter selects the mail flow by address text, which the hourly table does not
        /// hold: the rows of the whole period are read then.
        /// </summary>
        internal object OverviewServers(ServeFilter f)
        {
            long from, to; string d0, d1;
            var daily = new Dictionary<string, ReportBuilder.DayStats>(StringComparer.OrdinalIgnoreCase);
            var servers = new Dictionary<string, ReportBuilder.ServerStats>(StringComparer.OrdinalIgnoreCase);
            var byServer = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            bool window = f.OrderFrom.HasValue || f.OrderTo.HasValue;
            if (DayWindow(f, out from, out to, out d0, out d1))
            {
                // The unresolved failures are counted on a connection of their own while this one reads the aggregates.
                var aside = window ? null : UnresolvedAside(f, from, to);
                Action aggregates = () =>
                {
                    string usage = " FROM access_usage WHERE day >= @d0 AND day <= @d1" + UsageFilter(f);
                    if (window) ReportBuilder.UsageByDay(sql => Read(sql, f, d0, d1), usage, daily);
                    else servers = ReportBuilder.UsageByServer(sql => Read(sql, f, d0, d1), usage, daily);
                    var flowRange = new List<KeyValuePair<string, long[]>>();
                    var usageNames = new HashSet<string>(servers.Keys, StringComparer.OrdinalIgnoreCase);
                    if (f.User != null) { FlowRows(f, from, to, window, true, servers, daily, flowRange); if (!window) Respell(servers, usageNames, _flowNames); }
                    else
                    {
                        // The plans of every statement are wanted whatever the period: both parts are explained.
                        bool explain = ExplainPlans != null;
                        long hA = Store.CeilHour(from), hB = Store.FloorHour(to);
                        if (hA >= hB && !explain) FlowRows(f, from, to, window, false, servers, daily, flowRange);
                        else
                        {
                            FlowHours(f, hA, hB, window, servers, daily, flowRange);
                            if (from < hA || explain) FlowRows(f, from, Math.Min(hA, to), window, false, servers, daily, flowRange);
                            // The plans of the partial hours are those of the same statements: explained once.
                            if (hB < to && !explain) FlowRows(f, Math.Max(hB, from), to, window, false, servers, daily, flowRange);
                        }
                        if (!window) ServerMessages(f, from, to, servers);
                        // A server seen only in the mail flow is named as the static report names it: the smallest (BINARY) of its spellings in the period.
                        if (!window) Respell(servers, usageNames, _flowNames);
                    }
                    if (!window) ReportBuilder.FinishServers(servers, daily, flowRange);
                };
                if (aside == null) aggregates();
                else foreach (var kv in Joined(aside, aggregates)[0]) byServer[kv.Key] = kv.Value;
            }
            var dailyRows = d0 == null ? new List<object[]>() : ReportBuilder.DailyRows(daily, d0, d1);
            return new { cached = false, from = Iso(f.From), to = Iso(f.To), firstDay = d0, lastDay = d1,
                servers = window ? null : new { columns = ServeColumn.Parse(ReportBuilder.ServerColumns),
                    rows = Numbered(ReportBuilder.ServerRows(servers, byServer, SourceServers().ToArray(), f.Server == null ? null : new[] { f.Server }, LocalIso)) },
                daily = new { columns = ServeColumn.Parse(ReportBuilder.DailyColumns), rows = Numbered(dailyRows) } };
        }
        // The spellings of the servers of the mail flow of a request: the smallest (BINARY) one of each server.
        readonly Dictionary<string, string> _flowNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string FlowName(string name)
        {
            string known;
            if (name != null && (!_flowNames.TryGetValue(name, out known) || Store.CompareUtf8Binary(name, known) < 0)) _flowNames[name] = name;
            return name;
        }
        /// <summary>Gives each server that the client access figures did not name the smallest spelling the mail flow saw (the static report's sorted grouping).</summary>
        static void Respell(Dictionary<string, ReportBuilder.ServerStats> servers, HashSet<string> usageNames, Dictionary<string, string> names)
        {
            foreach (var kv in names)
            {
                if (usageNames.Contains(kv.Key)) continue;
                var current = servers.Keys.FirstOrDefault(k => string.Equals(k, kv.Key, StringComparison.OrdinalIgnoreCase));
                if (current == null || string.Equals(current, kv.Value, StringComparison.Ordinal)) continue;
                var stats = servers[current]; servers.Remove(current); servers[kv.Value] = stats;
            }
        }
        static ReportBuilder.ServerStats ServerOf(Dictionary<string, ReportBuilder.ServerStats> servers, string name)
        {
            ReportBuilder.ServerStats s;
            if (!servers.TryGetValue(name, out s)) servers[name] = s = new ReportBuilder.ServerStats();
            return s;
        }
        static ReportBuilder.DayStats DayOf(Dictionary<string, ReportBuilder.DayStats> daily, string key)
        {
            ReportBuilder.DayStats d;
            if (!daily.TryGetValue(key, out d)) daily[key] = d = new ReportBuilder.DayStats();
            return d;
        }

        /// <summary>
        /// The mail flow of [a, b) from the tracking events and SMTP transactions, as the static report counts it: SMTP per server, direction and status
        /// and per hour, deliveries and failures per server, distinct identities per server and hour, first and last times. messages: the distinct
        /// identities per server over [a, b) too (a user filter; otherwise ServerMessages gives them for the whole period).
        /// </summary>
        void FlowRows(ServeFilter f, long a, long b, bool window, bool messages, Dictionary<string, ReportBuilder.ServerStats> servers,
            Dictionary<string, ReportBuilder.DayStats> daily, List<KeyValuePair<string, long[]>> flowRange)
        {
            var range = new Dictionary<string, object> { { "@a", a }, { "@b", b } };
            const string period = " WHERE e.time_ms>=@a AND e.time_ms<@b";
            string smtp = " FROM smtp_transaction e INDEXED BY ix_smtp_flow" + period + SourceFilter(f, "e", true);
            string tracking = " FROM message_event e INDEXED BY ix_msg_flow" + period + SourceFilter(f, "e", false);
            if (!window)
            foreach (var r in Read("SELECT e.server, e.direction, e.status, COUNT(*)" + smtp + " GROUP BY e.server, e.direction, e.status;", f, null, null, range))
            {
                var s = ServerOf(servers, FlowName(Text(r[0]))); long n = Long(r[3]);
                if (Text(r[1]) == "Receive") s.SmtpIn += n; else s.SmtpOut += n;
                if (Text(r[2]) == "Rejected") s.SmtpRejected += n;
            }
            foreach (var r in Read("SELECT e.time_ms/3600000, e.server, e.direction, COUNT(*)" + smtp + " GROUP BY 1, 2, 3;", f, null, null, range))
            {
                var d = DayOf(daily, TimeUtil.Day(Long(r[0]) * 3600000L, _options.Zone) + "|" + Text(r[1]));
                if (Text(r[2]) == "Receive") d.SmtpIn += Long(r[3]); else d.SmtpOut += Long(r[3]);
            }
            // Message figures as the report counts them: deliveries, failures, distinct identities per server over the window and per server and hour.
            if (!window)
            foreach (var r in Read("SELECT e.server, SUM(e.event_id='DELIVER'), SUM(e.event_id IN('FAIL','DSN')), MIN(e.time_ms), MAX(e.time_ms)" +
                (messages ? ", COUNT(DISTINCT COALESCE(e.message_id, e.internal_id))" : "") + tracking + " GROUP BY e.server COLLATE NOCASE;", f, null, null, range))
            {
                var s = ServerOf(servers, FlowName(Text(r[0]) ?? ""));
                s.Deliveries += Long(r[1]); s.MessageFailures += Long(r[2]);
                if (messages) s.Messages += Long(r[5]);
                flowRange.Add(new KeyValuePair<string, long[]>(Text(r[0]) ?? "", new[] { Long(r[3]), Long(r[4]) }));
            }
            // An hour whose events have no identity adds no daily row (the static report counts identities only).
            foreach (var r in Read("SELECT e.time_ms/3600000, e.server, COUNT(DISTINCT COALESCE(e.message_id, e.internal_id))" + tracking + " GROUP BY 1, e.server COLLATE NOCASE;", f, null, null, range))
                if (Long(r[2]) > 0) DayOf(daily, TimeUtil.Day(Long(r[0]) * 3600000L, _options.Zone) + "|" + (Text(r[1]) ?? "")).Messages += Long(r[2]);
            if (!window)
                foreach (var r in Read("SELECT e.server, MIN(e.time_ms), MAX(e.time_ms)" + smtp + " GROUP BY e.server;", f, null, null, range))
                    flowRange.Add(new KeyValuePair<string, long[]>(Text(r[0]), new[] { Long(r[1]), Long(r[2]) }));
        }

        /// <summary>The mail flow of the whole hours [hA, hB) from mail_flow_hour (the same figures as FlowRows, but Messages per server).</summary>
        void FlowHours(ServeFilter f, long hA, long hB, bool window, Dictionary<string, ReportBuilder.ServerStats> servers,
            Dictionary<string, ReportBuilder.DayStats> daily, List<KeyValuePair<string, long[]>> flowRange)
        {
            var range = new Dictionary<string, object> { { "@a", hA }, { "@b", hB } };
            string where = " FROM mail_flow_hour WHERE hour_ms>=@a AND hour_ms<@b" + (f.Server == null ? "" : " AND server=@s COLLATE NOCASE");
            // server is NOCASE: GROUP BY groups the spellings of a server, MIN(server COLLATE BINARY) keeps one.
            if (!window)
            foreach (var r in Read("SELECT MIN(server COLLATE BINARY), SUM(deliveries), SUM(failures), MIN(tracking_first_ms), MAX(tracking_last_ms), SUM(smtp_in), SUM(smtp_out), SUM(smtp_rejected)," +
                " MIN(smtp_first_ms), MAX(smtp_last_ms)" + where + " GROUP BY server;", f, null, null, range))
            {
                string name = FlowName(Text(r[0]));
                var s = ServerOf(servers, name);
                s.Deliveries += Long(r[1]); s.MessageFailures += Long(r[2]); s.SmtpIn += Long(r[5]); s.SmtpOut += Long(r[6]); s.SmtpRejected += Long(r[7]);
                if (r[3] != null) flowRange.Add(new KeyValuePair<string, long[]>(name, new[] { Long(r[3]), Long(r[4]) }));
                if (r[8] != null) flowRange.Add(new KeyValuePair<string, long[]>(name, new[] { Long(r[8]), Long(r[9]) }));
            }
            // Daily rows: the day of each hour in the report time zone; an hour without SMTP transaction or identity adds none.
            foreach (var r in Read("SELECT hour_ms, server, messages, smtp_in, smtp_out" + where + ";", f, null, null, range))
            {
                if (Long(r[2]) + Long(r[3]) + Long(r[4]) == 0) continue;
                var d = DayOf(daily, TimeUtil.Day(Long(r[0]), _options.Zone) + "|" + Text(r[1]));
                d.Messages += Long(r[2]); d.SmtpIn += Long(r[3]); d.SmtpOut += Long(r[4]);
            }
        }

        /// <summary>
        /// Messages per server over [from, to) as the static report counts them (ExactMessageCounts): the distinct identities COALESCE(message_id,
        /// internal_id) of the tracking events of each server, from the rollup instead of the events:
        ///  - a journey whose member bounds lie inside the period has every tracking event inside it: it counts once for each server of its servers
        ///    set, read from the index entries of ix_rollup_last alone;
        ///  - a journey crossing a bound of the period (two index ranges of rollup_max_span_ms each) counts once for each server of its events inside
        ///    the period, read through its identity (the hash finds the rows, the Message-ID is compared on the row);
        ///  - an event without Message-ID counts by its internal_id (ix_msg_noid_flow), unless that text is also the Message-ID of an event of the same
        ///    server in the period, which the first two parts counted.
        /// </summary>
        void ServerMessages(ServeFilter f, long from, long to, Dictionary<string, ReportBuilder.ServerStats> servers)
        {
            var counts = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            Action<string, long> add = (name, n) => { long v; counts.TryGetValue(name, out v); counts[name] = v + n; };
            long span = RollupSpanMs;
            var range = new Dictionary<string, object> { { "@a", from }, { "@b", to },
                { "@ab", span > long.MaxValue - from ? long.MaxValue : from + span }, { "@bb", span > long.MaxValue - to ? long.MaxValue : to + span } };
            const string tracked = " AND r.kind=0 AND r.events_count>0";
            foreach (var r in Read("SELECT r.servers, COUNT(*) FROM message_rollup r INDEXED BY ix_rollup_last WHERE r.member_last_ms>=@a AND r.member_last_ms<@b AND r.member_first_ms>=@a" +
                tracked + " GROUP BY r.servers;", f, null, null, range))
                foreach (string name in (RollupText(r[0]) ?? "").Split(new[] { " > " }, StringSplitOptions.None)) add(name, Long(r[1]));
            // A journey that crosses the start has member_last_ms in [from, from + span); one that crosses the end, in [to, to + span).
            var crossing = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (string sql in new[] {
                "SELECT r.identity, r.msg_hash FROM message_rollup r INDEXED BY ix_rollup_last WHERE r.member_last_ms>=@a AND r.member_last_ms<@ab AND r.member_first_ms<@a" + tracked + ";",
                "SELECT r.identity, r.msg_hash FROM message_rollup r INDEXED BY ix_rollup_last WHERE r.member_last_ms>=@b AND r.member_last_ms<@bb AND r.member_first_ms<@b" + tracked + ";" })
                foreach (var r in Read(sql, f, null, null, range)) crossing[Text(r[0])] = r[1];
            const string inside = "SELECT DISTINCT e.server FROM message_event e INDEXED BY ix_msg_identity_time WHERE e.msg_hash=@h AND e.time_ms>=@a AND e.time_ms<@b AND e.message_id=@m COLLATE BINARY;";
            if (ExplainPlans != null) Explain(inside, c => { c.Parameters.AddWithValue("@m", ""); });
            else if (crossing.Count > 0)
                using (var c = Command(inside))
                {
                    var h = c.Parameters.Add("@h", SqliteType.Integer); var m = c.Parameters.Add("@m", SqliteType.Text);
                    c.Parameters.AddWithValue("@a", from); c.Parameters.AddWithValue("@b", to);
                    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var kv in crossing)
                    {
                        _cancel.ThrowIfCancellationRequested();
                        h.Value = kv.Value ?? DBNull.Value; m.Value = kv.Key; seen.Clear();
                        using (var r = c.ExecuteReader()) while (r.Read()) if (seen.Add(r.GetString(0))) add(r.GetString(0), 1);
                    }
                }
            foreach (var r in Read("SELECT MIN(e.server), COUNT(DISTINCT e.internal_id) FROM message_event e INDEXED BY ix_msg_noid_flow WHERE e.message_id IS NULL AND e.time_ms>=@a AND e.time_ms<@b" +
                " AND NOT EXISTS(SELECT 1 FROM message_event x INDEXED BY ix_msg_identity_time WHERE x.msg_hash=exl_msg_hash(e.internal_id) AND x.time_ms>=@a AND x.time_ms<@b" +
                " AND x.message_id=e.internal_id COLLATE BINARY AND x.server=e.server COLLATE NOCASE) GROUP BY e.server COLLATE NOCASE;", f, null, null, range))
                add(Text(r[0]) ?? "", Long(r[1]));
            foreach (var kv in counts)
                if (kv.Value > 0 && (f.Server == null || string.Equals(kv.Key, f.Server, StringComparison.OrdinalIgnoreCase))) ServerOf(servers, kv.Key).Messages += kv.Value;
        }

        static List<ServeRow> Numbered(IEnumerable<object[]> rows) { long id = 0; return rows.Select(r => new ServeRow { id = ++id, cells = r }).ToList(); }

        // ------------------------------------------------------------------------------------------------------------ failed and slow requests

        /// <summary>
        /// One keyset page of the failed and slow requests (access_event, the report's issues): [from, to) on time_ms, the order window, the cursor
        /// (time_ms, id) compared as a row value, newest first (dir=asc: oldest first), skip rows inside a window, the filters of the page
        /// (Engine.ServeScan.cs). Successes are listed only with a user filter, as in a report filtered on users.
        /// </summary>
        internal ServePage Requests(ServeFilter f) { return Keyed("issues", f); }
        /// <summary>The statement of a keyset page of the requests without filters of the page, whose plan ExplainReportDatasets reports.</summary>
        internal static string RequestSelection(ServeFilter f)
        {
            string direction = f.Ascending ? "" : " DESC";
            return "SELECT e.id," + ReportBuilder.IssueFields + ReportBuilder.IssueFrom.Replace(" FROM access_event e ", " FROM access_event e INDEXED BY ix_event_time ") +
                "WHERE e.time_ms>=@f AND e.time_ms<@t" + OrderWindow(f, "e.time_ms") +
                (f.CursorKey.HasValue ? " AND (e.time_ms,e.id)" + (f.Ascending ? ">" : "<") + "(@ck,@cid)" : "") + AccessFilter(f, "e") +
                (f.User == null ? " AND e.outcome<>'Success'" : "") + (f.Status == null ? "" : " AND e.outcome=@status COLLATE NOCASE") +
                " ORDER BY e.time_ms" + direction + ",e.id" + direction + " LIMIT @limit" + (f.Skip > 0 ? " OFFSET @skip" : "") + ";";
        }

        /// <summary>
        /// The issue rows of one request id (the "Fields kept for this request" of a timeline step): user is the session's user (exact), [from, to) the
        /// step's time window; read through ix_event_user. When the user's range has none and the window is at most one hour, the window is read
        /// by time (ix_event_time): a request stored without a user or with another spelling of it. Without user the window must be at most one
        /// hour. Every outcome is listed, oldest first, at most 100 rows.
        /// </summary>
        internal object Request(string requestId, ServeFilter f)
        {
            bool narrow = f.To - f.From <= RequestScanMs;
            if (f.User == null && !narrow) throw new ServeError(400, "UserRequired", "user (the exact user of the session) is required for a window of more than one hour.");
            var rows = f.User == null ? new List<ServeRow>() : RequestRows(RequestDetailSelection, requestId, f);
            // A request whose stored user is empty or spelled otherwise than the session's: the events of a window of at most one hour, by time.
            if (rows.Count == 0 && narrow) rows = RequestRows(RequestTimeSelection, requestId, f);
            if (rows.Count == 0) throw new ServeError(404, "NotFound", "No request with this ID for this user and period.");
            return new { requestId, columns = IssueColumns, rows };
        }
        List<ServeRow> RequestRows(string sql, string requestId, ServeFilter f)
        {
            var rows = new List<ServeRow>();
            using (var c = FilterCommand(sql, f))
            {
                c.Parameters.AddWithValue("@eu", (object)f.User ?? DBNull.Value); c.Parameters.AddWithValue("@rid", requestId);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        var row = new object[r.FieldCount - 1];
                        for (int i = 0; i < row.Length; i++) row[i] = r.IsDBNull(i + 1) ? null : Packed.Unpack(r.GetValue(i + 1));
                        string after;
                        string resolution = Resolution(row, out after);
                        rows.Add(new ServeRow { id = r.GetInt64(0), cells = ReportBuilder.IssueRow(row, LocalIso, resolution, after) });
                    }
            }
            return rows;
        }
        // The widest window the request detail reads by time alone (ix_event_time), when the user's range has no row of the request.
        const long RequestScanMs = 3600000;
        internal static readonly string RequestDetailSelection = "SELECT e.id," + ReportBuilder.IssueFields +
            ReportBuilder.IssueFrom.Replace(" FROM access_event e ", " FROM access_event e INDEXED BY ix_event_user ") +
            "WHERE e.user=@eu AND e.time_ms>=@f AND e.time_ms<@t AND e.request_id=@rid ORDER BY e.time_ms,e.id LIMIT 100;";
        internal static readonly string RequestTimeSelection = "SELECT e.id," + ReportBuilder.IssueFields +
            ReportBuilder.IssueFrom.Replace(" FROM access_event e ", " FROM access_event e INDEXED BY ix_event_time ") +
            "WHERE e.time_ms>=@f AND e.time_ms<@t AND e.request_id=@rid ORDER BY e.time_ms,e.id LIMIT 100;";

        // ------------------------------------------------------------------------------------------------------------ users

        /// <summary>The id of a user in a URL: base64url (no padding) of its UTF-8 name.</summary>
        internal static string UserKey(string user) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(user)).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }
        internal static string UserName(string key) { return KeyText(key, "Unknown user id."); }
        /// <summary>The UTF-8 text of a base64url id (UserKey); 404 with the given message when it is not one.</summary>
        static string KeyText(string key, string unknown)
        {
            if (key.Length > 1400 || !System.Text.RegularExpressions.Regex.IsMatch(key, "^[A-Za-z0-9_-]+$", System.Text.RegularExpressions.RegexOptions.CultureInvariant) || key.Length % 4 == 1)
                throw new ServeError(404, "NotFound", unknown);
            string b64 = key.Replace('-', '+').Replace('_', '/');
            b64 += new string('=', (4 - b64.Length % 4) % 4);
            try { return new UTF8Encoding(false, true).GetString(Convert.FromBase64String(b64)); }
            catch (Exception e) when (e is FormatException || e is ArgumentException) { throw new ServeError(404, "NotFound", unknown); }
        }

        /// <summary>
        /// The access_client rows of a selection (the report's clients filters): the server within the servers list, the user by its account name
        /// (access_client has no mailbox column, so a user filter that matches a mailbox name only finds no client row).
        /// </summary>
        static string ClientsWhere(ServeFilter f)
        {
            return " FROM access_client WHERE day >= @d0 AND day <= @d1" + (f.Server == null ? "" : " AND instr(','||lower(COALESCE(servers,''))||',',','||lower(@s)||',')>0") +
                (f.User == null ? "" : " AND user LIKE @u ESCAPE '\\'");
        }

        /// <summary>
        /// The users of the selection (the report's users dataset without its two detail columns), whole: most requests first, then the user name
        /// (ordinal), a total order with a unique last key.
        /// </summary>
        internal object Users(ServeFilter f)
        {
            long from, to; string d0, d1;
            var rows = new List<ServeKeyRow>();
            if (DayWindow(f, out from, out to, out d0, out d1))
            {
                // The unresolved failures are counted on a connection of their own while this one reads the users; their column is set afterwards.
                var aside = UnresolvedAside(f, from, to);
                List<object[]> list = null;
                var byUser = Joined(aside, () => list = ReportBuilder.UserRows(sql => Read(sql, f, d0, d1), " FROM access_usage WHERE day >= @d0 AND day <= @d1" + UsageFilter(f),
                    new Dictionary<string, long>(StringComparer.Ordinal), null, LocalIso, false, ClientsWhere(f)))[1];
                foreach (var r in list) { long n; byUser.TryGetValue((string)r[0] ?? "", out n); r[7] = n; }
                foreach (var r in list.OrderByDescending(r => Long(r[5])).ThenBy(r => (string)r[0], StringComparer.Ordinal))
                    rows.Add(new ServeKeyRow { id = UserKey((string)r[0]), cells = r.Take(13).Concat(new[] { r[15] }).ToArray() });
            }
            return new { cached = false, columns = UserListColumns, rows, total = rows.Count, from = Iso(f.From), to = Iso(f.To), firstDay = d0, lastDay = d1 };
        }

        bool HasIdentityMap()
        {
            using (var c = Command("SELECT 1 FROM sqlite_master WHERE type='table' AND name='identity_map';")) return c.ExecuteScalar() != null;
        }

        /// <summary>One user of the selection with its protocol detail and its clients and devices; 404 when the user has no usage in the selection.</summary>
        internal object User(string key, ServeFilter f)
        {
            string user = UserName(key);
            long from, to; string d0, d1;
            if (!DayWindow(f, out from, out to, out d0, out d1)) throw new ServeError(404, "NotFound", "No such user in this selection.");
            var exact = new Dictionary<string, object> { { "@eu", user } };
            var byUser = new Dictionary<string, long>(StringComparer.Ordinal);
            Unresolved(f, from, to, user, new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase), byUser);
            var devices = new List<object[]>();
            string clients = " FROM access_client INDEXED BY ix_client_user WHERE user=@eu AND day >= @d0 AND day <= @d1" +
                (f.Server == null ? "" : " AND instr(','||lower(COALESCE(servers,''))||',',','||lower(@s)||',')>0");
            foreach (var r in Read(ReportBuilder.ClientSql(clients), f, d0, d1, exact)) devices.Add(ReportBuilder.DeviceRow(ReportBuilder.ClientRow(r, LocalIso)));
            // The security identifiers of the user (identity_map, absent from a database of an earlier 3.0 build): resolved to it, or the user itself.
            Dictionary<string, List<object[]>> identities = null;
            if (HasIdentityMap())
            {
                identities = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
                foreach (var r in Read(ReportBuilder.IdentitySql + " WHERE user=@eu ORDER BY sid;", f, d0, d1, exact)) ReportBuilder.AddIdentity(identities, r, LocalIso);
                foreach (var r in Read(ReportBuilder.IdentitySql + " WHERE sid=@eu;", f, d0, d1, exact)) ReportBuilder.AddIdentity(identities, r, LocalIso);
            }
            var list = ReportBuilder.UserRows(sql => Read(sql, f, d0, d1, exact), " FROM access_usage INDEXED BY ix_usage_user WHERE user=@eu AND day >= @d0 AND day <= @d1" + UsageFilter(f),
                byUser, new Dictionary<string, List<object[]>>(StringComparer.Ordinal) { { user, devices } }, LocalIso, true, clients, identities);
            if (list.Count == 0) throw new ServeError(404, "NotFound", "No such user in this selection.");
            return new { id = key, title = "User", columns = ServeColumn.Parse(ReportBuilder.UserColumns), cells = list[0] };
        }

        // ------------------------------------------------------------------------------------------------------------ operations

        /// <summary>The operations of the selection (server-wide: no user filter), whole: by protocol, most requests first, then the operation name.</summary>
        internal object Operations(ServeFilter f)
        {
            long from, to; string d0, d1;
            var rows = new List<object[]>();
            if (DayWindow(f, out from, out to, out d0, out d1))
                rows = ReportBuilder.OperationRows(sql => Read(sql, f, d0, d1), " FROM access_action WHERE day >= @d0 AND day <= @d1" + (f.Server == null ? "" : " AND server=@s COLLATE NOCASE"),
                    " ORDER BY protocol, SUM(requests) DESC, action;");
            return new { cached = false, columns = ServeColumn.Parse(ReportBuilder.OperationColumns), rows = Numbered(rows), total = rows.Count, from = Iso(f.From), to = Iso(f.To), firstDay = d0, lastDay = d1 };
        }

        // ------------------------------------------------------------------------------------------------------------ authentication

        internal static readonly ServeColumn[] AuthenticationColumns = ServeColumn.Parse(ReportBuilder.AuthenticationColumns);
        static readonly ServeColumn[] AuthenticationListColumns = ServeColumn.Parse(ReportBuilder.AuthenticationColumns.Take(12));
        /// <summary>The id of an authentication row in a URL: the UserKey of "protocol\nmode".</summary>
        internal static string AuthKey(string protocol, string mode) { return UserKey((protocol ?? "") + "\n" + (mode ?? "")); }

        /// <summary>
        /// The authentication types of the selection (the report's authentication dataset without its clients detail), whole: one row per protocol and
        /// authentication type, by protocol, most users first, then the type.
        /// </summary>
        internal object Authentication(ServeFilter f)
        {
            long from, to; string d0, d1;
            var rows = new List<ServeKeyRow>();
            if (DayWindow(f, out from, out to, out d0, out d1))
                foreach (var r in ReportBuilder.AuthenticationRows(sql => Read(sql, f, d0, d1), ClientsWhere(f), LocalIso, false))
                    rows.Add(new ServeKeyRow { id = AuthKey((string)r[0], (string)r[1]), cells = r.Take(12).ToArray() });
            return new { cached = false, columns = AuthenticationListColumns, rows, total = rows.Count, from = Iso(f.From), to = Iso(f.To), firstDay = d0, lastDay = d1 };
        }

        /// <summary>One authentication row of the selection with its clients (the statement of the list restricted to one protocol); 404 when the selection has none.</summary>
        internal object AuthenticationDetail(string key, ServeFilter f)
        {
            const string Unknown = "Unknown authentication id.";
            string text = KeyText(key, Unknown);
            int cut = text.IndexOf('\n');
            if (cut < 0) throw new ServeError(404, "NotFound", Unknown);
            string protocol = text.Substring(0, cut), mode = text.Substring(cut + 1);
            long from, to; string d0, d1;
            if (!DayWindow(f, out from, out to, out d0, out d1)) throw new ServeError(404, "NotFound", "No such authentication type in this selection.");
            var exact = new Dictionary<string, object> { { "@ap", protocol } };
            var row = ReportBuilder.AuthenticationRows(sql => Read(sql, f, d0, d1, exact), ClientsWhere(f) + " AND protocol=@ap COLLATE NOCASE", LocalIso)
                .FirstOrDefault(r => string.Equals((string)r[1], mode, StringComparison.Ordinal));
            if (row == null) throw new ServeError(404, "NotFound", "No such authentication type in this selection.");
            return new { id = key, title = "Authentication", columns = AuthenticationColumns, cells = row };
        }

        // ------------------------------------------------------------------------------------------------------------ report meta

        /// <summary>Local days of [from, to) in a zone, newest first: [day, start, end) with the period's own bounds on the first and last day.</summary>
        internal static List<Tuple<string, long, long>> Days(ServeFilter f, TimeZoneInfo zone)
        {
            var days = new List<Tuple<string, long, long>>();
            DateTime local = TimeUtil.ToLocal(f.From, zone).Date;
            long start = f.From;
            while (start < f.To)
            {
                if (days.Count == 400) throw new ServeError(422, "PeriodTooLarge", "More than 400 days; narrow the period.");
                local = local.AddDays(1);
                long next = Math.Min(f.To, TimeUtil.LocalToUnixMs(local, zone));
                if (next > start) days.Add(Tuple.Create(TimeUtil.Day(start, zone), start, next));
                start = Math.Max(start, next);
            }
            days.Reverse();
            return days;
        }

        static string UsersCountSql(ServeFilter f) { return "SELECT COUNT(DISTINCT user) FROM access_usage WHERE day >= @d0 AND day <= @d1" + UsageFilter(f) + ";"; }
        static string OperationsCountSql(ServeFilter f)
        {
            return "SELECT COUNT(*) FROM (SELECT 1 FROM access_action WHERE day >= @d0 AND day <= @d1" + (f.Server == null ? "" : " AND server=@s COLLATE NOCASE") + " GROUP BY protocol, action);";
        }

        /// <summary>
        /// Plans of every statement of the report datasets for a selection (EXPLAIN QUERY PLAN only): report-meta counts, overview servers and daily,
        /// users and one user, operations, the keyset page of the requests (first page, then a cursor inside a window with skip), the request detail and
        /// the last-success lookup.
        /// </summary>
        internal List<string> ExplainReportDatasets(ServeFilter f)
        {
            ExplainPlans = new List<string>();
            try
            {
                ReportMeta(f);
                OverviewServers(f);
                Users(f);
                try { User(UserKey("explain"), f); } catch (ServeError) { }
                Operations(f);
                Authentication(f);
                try { AuthenticationDetail(AuthKey("Eas", "Basic"), f); } catch (ServeError) { }
                Action<SqliteCommand> none = c => FilterParameters(c, f);
                Explain(RequestSelection(f), none);
                var next = new ServeFilter { From = f.From, To = f.To, Server = f.Server, User = f.User, OrderFrom = f.From, OrderTo = f.To, CursorKey = 0, CursorId = 0, Skip = 1 };
                Explain(RequestSelection(next), c => FilterParameters(c, next));
                Explain(RequestDetailSelection, none);
                Explain(RequestTimeSelection, none);
                Explain(LastSuccessSql, c => { });
                return ExplainPlans;
            }
            finally { ExplainPlans = null; }
        }

        /// <summary>The report columns of a day-sliced list (messages, sessions, issues): its dataset in report-meta, the columns of the page's table.</summary>
        internal static ServeColumn[] ListDataset(string view)
        {
            return view == "sessions" ? ServeColumn.Parse(ReportBuilder.SessionColumns) : view == "issues" ? IssueColumns : ServeColumn.Parse(ReportBuilder.ServeMessageColumns);
        }
        /// <summary>The columns of the rows of a day-sliced list (Keyed).</summary>
        internal static ServeColumn[] ListColumns(string view) { return view == "issues" ? IssueColumns : Columns(view); }

        /// <summary>
        /// What the static report's meta carries, for the selection: the datasets (columns, kinds, grid flags, detail columns), the exact row counts of
        /// the period-aggregated users and operations, and the pack manifest: one pack per period-aggregated dataset, one per (day-sliced dataset, day),
        /// newest day first. The day-sliced lists carry no row count (their counts are per day requests of their own).
        /// </summary>
        internal object ReportMeta(ServeFilter f)
        {
            var zone = _options.Zone;
            var days = Days(f, zone);
            string d0 = TimeUtil.Day(f.From, zone), d1 = TimeUtil.Day(f.To - 1, zone);
            long users, operations;
            users = Long(Read(UsersCountSql(f), f, d0, d1).Select(r => r[0]).FirstOrDefault());
            operations = Long(Read(OperationsCountSql(f), f, d0, d1).Select(r => r[0]).FirstOrDefault());
            bool withOperations = f.User == null;
            var notes = new List<string>();
            if (TimeUtil.ToLocal(f.From, zone).TimeOfDay != TimeSpan.Zero || TimeUtil.ToLocal(f.To, zone).TimeOfDay != TimeSpan.Zero)
                notes.Add("Client access usage is aggregated per day: the first and last day of the period are counted as whole days.");
            if (!withOperations) notes.Add("Operations are measured per server, not per user: the Operations view is not built when the selection is filtered on a user.");
            notes.Add("SMTP clients are grouped per server, direction, role, connector, address, HELO name and authenticated account.");
            notes.Add("Outcome in the list of client sessions is computed from the session counters; the timeline in the detail of a session may refine it.");
            if (f.User != null) notes.Add("User filter: the portal matches the user and mailbox names that contain the text; the SMTP figures include the transactions authenticated by that account.");

            var sets = new List<Tuple<string, ServeColumn[], string, string, ServeColumn[], long?>>
            {
                Tuple.Create("servers", ServeColumn.Parse(ReportBuilder.ServerColumns), "/api/overview/servers", (string)null, ServeColumn.Parse(ReportBuilder.ServerColumns), (long?)null),
                Tuple.Create("daily", ServeColumn.Parse(ReportBuilder.DailyColumns), "/api/overview/servers", (string)null, ServeColumn.Parse(ReportBuilder.DailyColumns), (long?)null),
                Tuple.Create("users", ServeColumn.Parse(ReportBuilder.UserColumns), "/api/users", "/api/users/{id}", UserListColumns, (long?)users),
            };
            if (withOperations) sets.Add(Tuple.Create("operations", ServeColumn.Parse(ReportBuilder.OperationColumns), "/api/operations", (string)null, ServeColumn.Parse(ReportBuilder.OperationColumns), (long?)operations));
            sets.Add(Tuple.Create("authentication", AuthenticationColumns, "/api/authentication", "/api/authentication/{id}", AuthenticationListColumns, (long?)null));
            sets.Add(Tuple.Create("smtpclients", SmtpClientColumns, "/api/smtp/clients", "/api/smtp/clients/{id}", SmtpClientColumns, (long?)null));
            sets.Add(Tuple.Create("sessions", ListDataset("sessions"), "/api/sessions", "/api/sessions/{id}", SessionColumns, (long?)null));
            sets.Add(Tuple.Create("issues", ListDataset("issues"), "/api/requests", (string)null, IssueColumns, (long?)null));
            sets.Add(Tuple.Create("messages", ListDataset("messages"), "/api/messages", "/api/messages/{id}", MessageColumns, (long?)null));
            sets.Add(Tuple.Create("smtp", SmtpColumns, "/api/smtp/transactions", "/api/smtp/transactions/{id}", SmtpColumns, (long?)null));
            var sliced = new HashSet<string>(new[] { "sessions", "issues", "messages", "smtp" }, StringComparer.Ordinal);

            string query = "from=" + Uri.EscapeDataString(Iso(f.From)) + "&to=" + Uri.EscapeDataString(Iso(f.To)) +
                (f.Server == null ? "" : "&server=" + Uri.EscapeDataString(f.Server)) + (f.User == null ? "" : "&user=" + Uri.EscapeDataString(f.User));
            var datasets = new Dictionary<string, object>(StringComparer.Ordinal);
            var files = new List<object>();
            foreach (var set in sets)
            {
                string name = set.Item1;
                var columns = set.Item2;
                // The report's detail columns: the "steps" columns, except on the servers and daily datasets, which the page reads whole.
                int[] detail = name == "servers" || name == "daily" ? new int[0] : columns.Select((c, i) => new { c, i }).Where(x => x.c.kind == "steps").Select(x => x.i).ToArray();
                // Absent figures are left out, never sent as an estimate.
                var entry = new Dictionary<string, object>(StringComparer.Ordinal);
                if (set.Item6.HasValue) { entry["rows"] = set.Item6.Value; entry["total"] = set.Item6.Value; }
                entry["columns"] = columns;
                if (detail.Length > 0) entry["detailColumns"] = detail;
                entry["list"] = set.Item3; entry["detail"] = set.Item4; entry["listColumns"] = set.Item5.Select(c => c.name).ToArray();
                entry["daySliced"] = sliced.Contains(name);
                datasets[name] = entry;
                if (!sliced.Contains(name))
                {
                    var pack = new Dictionary<string, object>(StringComparer.Ordinal) { { "name", name }, { "kind", "c" }, { "set", name } };
                    if (set.Item6.HasValue) pack["rows"] = set.Item6.Value;
                    pack["url"] = set.Item3 + "?" + query;
                    files.Add(pack);
                    continue;
                }
                for (int k = 0; k < days.Count; k++)
                {
                    // The newest day has no upper bound and the oldest no lower bound on the sort key: a sort key may lie outside the period.
                    string orderFrom = k == days.Count - 1 ? null : Iso(days[k].Item2), orderTo = k == 0 ? null : Iso(days[k].Item3);
                    files.Add(new { name = name + "-" + days[k].Item1, kind = "c", set = name, day = days[k].Item1, orderFrom, orderTo,
                        url = set.Item3 + "?" + query + (orderFrom == null ? "" : "&orderFrom=" + Uri.EscapeDataString(orderFrom)) + (orderTo == null ? "" : "&orderTo=" + Uri.EscapeDataString(orderTo)) });
                }
            }
            // slowRequestMs: the default threshold of a report request (the collector classified the slow requests with its own setting).
            return new { served = true, title = "Exchange Server usage and troubleshooting", toolVersion = ProductVersion, generated = Iso(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),
                timeZone = zone.Id, timeZoneIana = IanaZone(zone), periodStart = TimeUtil.Format(f.From, zone, "yyyy-MM-dd HH:mm"), periodEnd = TimeUtil.Format(f.To, zone, "yyyy-MM-dd HH:mm"),
                from = Iso(f.From), to = Iso(f.To), firstDay = d0, lastDay = d1, detailed = true, edge = false, includeRouting = true, includeSessions = true,
                slowRequestMs = new ReportRequest().SlowRequestMs, users = f.User == null ? new string[0] : new[] { f.User }, servers = f.Server == null ? new string[0] : new[] { f.Server },
                configuredServers = SourceServers(), notes, clientRowsMax = _options.ClientRowsMax, scanBudgetMs = Math.Min(_options.ScanBudgetMs, _options.RequestTimeoutSeconds * 1000), aggregateTimeoutSeconds = _options.AggregateTimeoutSeconds,
                datasets, data = new { files } };
        }
    }
}
