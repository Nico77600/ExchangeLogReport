// =============================================================================
//  Exchange Log Report - engine, part 5: client sessions and back-end correlation
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.4.0
//
//  A client session is what one client did for one user on one day, until it
//  stays idle longer than SessionIdleMinutes. Its key depends on the protocol:
//    Mapi       user | client address | mailbox GUID | client instance (X-ClientInfo of Outlook)
//    Eas        user | user agent (device model and build; mobile devices change address all the time)
//    Imap4/Pop3 user | client address
//    others     user | client address | user agent
//  The same key is computed from the front-end logs (HttpProxy, IIS) and from the
//  back-end logs, which is how one session gathers several log files:
//    MapiBackEnd  Logging\MapiHttp\Mailbox: Outlook version, cached mode, MAPI status codes
//                 (an HTTP 200 can carry a MAPI failure), same RequestId as HttpProxy
//    EasBackEnd   W3SVC2 (Exchange Back End): ActiveSync errors hidden behind HTTP 200
//                 (DeviceNotProvisioned, UserDisabledForSync...), access state, EAS version
//    Imap4/Pop3   front end (client address, logon, proxy target) and back end (every
//                 command and its result). Back-end connections only know the front-end
//                 server: they are attached to the matching session at the end of the run.
//  Sessions keep their counters, plus a timeline ("steps") written per log file:
//  every failure, slow request and milestone (Connect, Provision, logon...) and the
//  first requests of the session are kept one by one; the other successes are folded
//  into "batch" steps. Long healthy sessions stay small, problems keep their detail.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>One step of a session timeline (one request, or a batch of successful requests).</summary>
    sealed class SessionStep
    {
        public long T, T2, TotalMs, MaxMs, FileId;
        public string Front, Back, Action, Detail, RequestId, Source = "FE", Needle, Needle2;
        public int Status, Count = 1, Failures;
        public bool Batch;
        public Dictionary<string, int> BatchActions;
    }

    sealed class ClientSession
    {
        public long Id;
        public string Key, Day, User, Protocol, Mailbox, UserAgent, DeviceId, DeviceType, Software, Mode, FirstError, LastError, BackEndNote;
        public long Start = long.MaxValue, End, Requests, Successes, Failures, Slow, FirstSuccess, LastSuccess, FirstFailure, LastFailure;
        public long TotalMs, MaxMs, BytesIn, BytesOut, Connections, BackEndErrors;
        public SortedSet<string> Fronts = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        public SortedSet<string> Backs = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        public List<string> Ips = new List<string>();
        public Dictionary<string, long> Actions = new Dictionary<string, long>(StringComparer.Ordinal);
        public Dictionary<string, long> Statuses = new Dictionary<string, long>(StringComparer.Ordinal);
        public List<SessionStep> Steps = new List<SessionStep>();
        public List<long> Absorbed = new List<long>();
        public bool LastWasFailure, Dead;
    }

    public sealed partial class Collector
    {
        readonly Dictionary<string, List<ClientSession>> _sessions = new Dictionary<string, List<ClientSession>>(StringComparer.Ordinal);
        readonly Dictionary<string, List<ClientSession>> _byUser = new Dictionary<string, List<ClientSession>>(StringComparer.Ordinal);
        readonly Dictionary<string, string> _accounts = new Dictionary<string, string>(StringComparer.Ordinal);
        readonly List<DeferredBackEnd> _deferred = new List<DeferredBackEnd>();
        SqliteTransaction _tx;   // transaction of the file being read (session lookups must run inside it)

        static readonly HashSet<string> Milestones = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Connect", "Disconnect", "Bind", "Unbind", "Provision", "FolderSync", "OPTIONS", "login", "authenticate", "logout",
            "user", "pass", "quit", "POST auth.owa", "GET logoff.owa", "CreateItem", "SendMail", "SmartReply", "SmartForward", "Logon"
        };
        static readonly Regex EasLogToken = new Regex(@"(?:^|_)(Error|As|Ver1|PrxFrom):([^_&]*)", RegexOptions.Compiled);

        // ================================================================ identities

        /// <summary>Accounts already known as "domain\sam": IMAP, POP and back-end logs often give "sam" or the UPN only.</summary>
        void LoadAccounts()
        {
            using (var c = _store.Command("SELECT DISTINCT user FROM access_usage WHERE instr(user, '\\') > 0;"))
            using (var r = c.ExecuteReader()) while (r.Read()) LearnAccount(r.GetString(0));
        }

        void LearnAccount(string user)
        {
            string bare = Identity.Bare(user), known;
            if (string.IsNullOrEmpty(bare)) return;
            if (!_accounts.TryGetValue(bare, out known)) _accounts[bare] = user;
            else if (known != null && !string.Equals(known, user, StringComparison.Ordinal)) _accounts[bare] = null;   // two domains: ambiguous
        }

        /// <summary>"sam" or "sam@upn-suffix" becomes "domain\sam" when that account is known (and not ambiguous).</summary>
        string Canonical(string user)
        {
            if (user == null) return null;
            if (user.IndexOf('\\') >= 0) { LearnAccount(user); return user; }
            string canon;
            return _accounts.TryGetValue(Identity.Bare(user), out canon) && canon != null ? canon : user;
        }

        // ================================================================ request enrichment

        /// <summary>Protocol action of a request: ActiveSync command, MAPI request type, OWA/EWS action, else method and last URL segment.</summary>
        void Enrich(AccessRecord r, string query, string clientRequestId, string anchor)
        {
            string protocol = r.Protocol ?? "";
            if (protocol.Equals("Eas", StringComparison.OrdinalIgnoreCase) || (r.Url != null && r.Url.StartsWith("/Microsoft-Server-ActiveSync", StringComparison.OrdinalIgnoreCase)))
            {
                string cmd = Identity.QueryValue(query, "Cmd");
                if (cmd != null) r.Action = cmd;
                else if (string.Equals(r.Method, "OPTIONS", StringComparison.OrdinalIgnoreCase)) r.Action = "OPTIONS";
                r.DeviceId = Identity.QueryValue(query, "DeviceId");
                r.DeviceType = Identity.QueryValue(query, "DeviceType");
            }
            else if (protocol.Equals("Mapi", StringComparison.OrdinalIgnoreCase))
            {
                string rt = Identity.Token(clientRequestId, "RT");
                if (rt != null) r.Action = rt;
                r.ClientInstance = Identity.ClientInstance(Identity.Token(clientRequestId, "CI"));
                r.MailboxGuid = Identity.MailboxGuid(anchor) ?? Identity.MailboxGuid(Identity.QueryValue(query, "MailboxId"));
            }
            if (string.IsNullOrEmpty(r.Action))
            {
                string url = (r.Url ?? "").TrimEnd('/');
                int slash = url.LastIndexOf('/');
                string last = slash >= 0 ? url.Substring(slash + 1) : url;
                r.Action = ((r.Method ?? "") + " " + (last.Length == 0 ? "/" : last)).Trim();
            }
            r.Action = Identity.Cap(r.Action, 80);
        }

        static string Describe(AccessRecord r)
        {
            var parts = new List<string>();
            string status = r.Status.ToString(CultureInfo.InvariantCulture);
            if (r.SubStatus.HasValue && r.SubStatus.Value > 0) status += "." + r.SubStatus.Value.ToString(CultureInfo.InvariantCulture);
            if (r.Status > 0 && r.Source != "Imap4" && r.Source != "Pop3") parts.Add("HTTP " + status);
            if (!string.IsNullOrEmpty(r.ErrorCode)) parts.Add(r.ErrorCode);
            if (r.Win32.HasValue && r.Win32.Value > 0 && (r.ErrorCode == null || r.ErrorCode.IndexOf(r.Win32.Value.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal) < 0))
                parts.Add("Win32 " + r.Win32.Value.ToString(CultureInfo.InvariantCulture));
            if (r.BackEndStatus.HasValue && r.BackEndStatus.Value != r.Status) parts.Add("back end " + r.BackEndStatus.Value.ToString(CultureInfo.InvariantCulture));
            return Identity.Cap(string.Join(", ", parts), 300);
        }

        // ================================================================ sessions in memory

        static string SessionKey(string day, string user, string protocol, string ip, string agent, string device, string mailboxGuid, string instance)
        {
            string p = protocol ?? "Other";
            switch (p.ToLowerInvariant())
            {
                // ActiveSync: the user agent identifies the device model and OS build; OPTIONS requests carry no DeviceId.
                case "eas": return day + "|" + user + "|Eas|ua:" + Identity.Cap(agent, 120);
                case "mapi": return day + "|" + user + "|Mapi|" + ip + "|" + mailboxGuid + "|" + instance;
                case "imap4":
                case "pop3": return day + "|" + user + "|" + p + "|" + ip;
                default: return day + "|" + user + "|" + p + "|" + ip + "|" + Identity.Cap(agent, 120);
            }
        }

        void ResetSessions()
        {
            _sessions.Clear();
            _byUser.Clear();
        }

        ClientSession NewSession(string key, string day, string user, string protocol)
        {
            var s = new ClientSession { Key = key, Day = day, User = user, Protocol = protocol };
            Index(s);
            return s;
        }

        void Index(ClientSession s)
        {
            string k = s.Day + "|" + s.User + "|" + s.Protocol;
            List<ClientSession> list;
            if (!_byUser.TryGetValue(k, out list)) { list = new List<ClientSession>(); _byUser[k] = list; }
            list.Add(s);
        }

        /// <summary>Session of a key that contains the time t (with the idle gap); bridging sessions are merged; a new one otherwise.</summary>
        ClientSession FindSession(string key, long t, Func<ClientSession> create)
        {
            List<ClientSession> list;
            if (!_sessions.TryGetValue(key, out list)) { list = LoadSessions(key); _sessions[key] = list; }
            long idle = _o.SessionIdleMs;
            var hits = list.Where(s => t >= s.Start - idle && t <= s.End + idle).ToList();
            if (hits.Count == 0) { var created = create(); list.Add(created); return created; }
            // t fills the gap between sessions: they become one, the oldest stored session survives.
            var keep = hits.OrderBy(s => s.Id > 0 ? 0 : 1).ThenBy(s => s.Id).First();
            foreach (var drop in hits)
            {
                if (ReferenceEquals(drop, keep)) continue;
                Merge(keep, drop);
                list.Remove(drop);
            }
            return keep;
        }

        void Merge(ClientSession into, ClientSession from)
        {
            if (ReferenceEquals(into, from)) return;
            from.Dead = true;
            if (from.Id > 0) into.Absorbed.Add(from.Id);
            into.Absorbed.AddRange(from.Absorbed);
            into.Start = Math.Min(into.Start, from.Start); into.End = Math.Max(into.End, from.End);
            into.Requests += from.Requests; into.Successes += from.Successes; into.Failures += from.Failures; into.Slow += from.Slow;
            into.TotalMs += from.TotalMs; into.MaxMs = Math.Max(into.MaxMs, from.MaxMs); into.BytesIn += from.BytesIn; into.BytesOut += from.BytesOut;
            into.Connections += from.Connections; into.BackEndErrors += from.BackEndErrors;
            into.FirstSuccess = MinPositive(into.FirstSuccess, from.FirstSuccess); into.LastSuccess = Math.Max(into.LastSuccess, from.LastSuccess);
            if (from.FirstFailure > 0 && (into.FirstFailure == 0 || from.FirstFailure < into.FirstFailure)) { into.FirstFailure = from.FirstFailure; into.FirstError = from.FirstError ?? into.FirstError; }
            if (from.LastFailure > into.LastFailure) { into.LastFailure = from.LastFailure; into.LastError = from.LastError ?? into.LastError; }
            foreach (var x in from.Fronts) into.Fronts.Add(x);
            foreach (var x in from.Backs) into.Backs.Add(x);
            foreach (var x in from.Ips) if (!into.Ips.Contains(x)) into.Ips.Add(x);
            foreach (var kv in from.Actions) Inc(into.Actions, kv.Key, kv.Value);
            foreach (var kv in from.Statuses) Inc(into.Statuses, kv.Key, kv.Value);
            into.Mailbox = into.Mailbox ?? from.Mailbox; into.UserAgent = into.UserAgent ?? from.UserAgent; into.DeviceId = into.DeviceId ?? from.DeviceId;
            into.DeviceType = into.DeviceType ?? from.DeviceType; into.Software = into.Software ?? from.Software; into.Mode = into.Mode ?? from.Mode;
            into.BackEndNote = into.BackEndNote ?? from.BackEndNote;
            into.Steps.AddRange(from.Steps);
            from.Steps.Clear();
        }

        static long MinPositive(long a, long b) { return a <= 0 ? b : b <= 0 ? a : Math.Min(a, b); }

        static void Inc(Dictionary<string, long> d, string key, long n)
        {
            if (string.IsNullOrEmpty(key)) return;
            long v; d.TryGetValue(key, out v); d[key] = v + n;
        }

        static string Join(Dictionary<string, long> d)
        {
            return d.Count == 0 ? null : string.Join(";", d.OrderByDescending(x => x.Value).ThenBy(x => x.Key, StringComparer.Ordinal).Select(x => x.Key.Replace(";", ",").Replace("=", ":") + "=" + x.Value.ToString(CultureInfo.InvariantCulture)));
        }

        static void Split(string text, Dictionary<string, long> d)
        {
            if (string.IsNullOrEmpty(text)) return;
            foreach (var part in text.Split(';'))
            {
                int eq = part.LastIndexOf('=');
                long n;
                if (eq > 0 && long.TryParse(part.Substring(eq + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) Inc(d, part.Substring(0, eq), n);
            }
        }

        List<ClientSession> LoadSessions(string key)
        {
            var list = new List<ClientSession>();
            using (var c = _store.Command(@"SELECT id,day,start_ms,end_ms,user,protocol,mailbox,client_ip,user_agent,device_id,device_type,software,client_mode,front_ends,back_ends,
requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses,
first_error,last_error,backend,connections FROM client_session WHERE skey=@k;", _tx))
            {
                c.Parameters.AddWithValue("@k", key);
                using (var r = c.ExecuteReader())
                {
                    Func<int, string> s = i => r.IsDBNull(i) ? null : r.GetString(i);
                    while (r.Read())
                    {
                        var x = new ClientSession
                        {
                            Id = r.GetInt64(0), Key = key, Day = s(1), Start = r.GetInt64(2), End = r.GetInt64(3), User = s(4), Protocol = s(5), Mailbox = s(6),
                            UserAgent = s(8), DeviceId = s(9), DeviceType = s(10), Software = s(11), Mode = s(12),
                            Requests = r.GetInt64(15), Successes = r.GetInt64(16), Failures = r.GetInt64(17), Slow = r.GetInt64(18),
                            FirstSuccess = r.GetInt64(19), LastSuccess = r.GetInt64(20), FirstFailure = r.GetInt64(21), LastFailure = r.GetInt64(22),
                            TotalMs = r.GetInt64(23), MaxMs = r.GetInt64(24), BytesIn = r.GetInt64(25), BytesOut = r.GetInt64(26),
                            FirstError = s(29), LastError = s(30), Connections = r.GetInt64(32)
                        };
                        foreach (var ip in (s(7) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) x.Ips.Add(ip.Trim());
                        foreach (var f in (s(13) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) x.Fronts.Add(f.Trim());
                        foreach (var b in (s(14) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) x.Backs.Add(b.Trim());
                        Split(s(27), x.Actions); Split(s(28), x.Statuses);
                        string be = s(31);
                        if (be != null)
                        {
                            int bar = be.IndexOf('|');
                            long n;
                            if (bar > 0 && long.TryParse(be.Substring(0, bar), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) { x.BackEndErrors = n; x.BackEndNote = bar + 1 < be.Length ? be.Substring(bar + 1) : null; }
                        }
                        list.Add(x);
                        Index(x);
                    }
                }
            }
            return list;
        }

        static void Extend(ClientSession s, long t)
        {
            if (t < s.Start) s.Start = t;
            if (t > s.End) s.End = t;
        }

        void AddToSession(FileContext c, AccessRecord r, bool failure, bool slow)
        {
            if (r.FromBackEnd && r.Session == null) return;
            var s = r.Session;
            if (s == null)
            {
                string day = _days.Day(r.TimeMs);
                string key = SessionKey(day, r.User, r.Protocol, r.ClientIp, r.UserAgent, r.DeviceId, r.MailboxGuid, r.ClientInstance);
                s = FindSession(key, r.TimeMs, () => NewSession(key, day, r.User, r.Protocol));
            }
            c.Touched.Add(s);
            Extend(s, r.TimeMs);
            s.Requests++;
            if (failure)
            {
                s.Failures++;
                string why = Describe(r);
                if (s.FirstFailure == 0 || r.TimeMs < s.FirstFailure) { s.FirstFailure = r.TimeMs; s.FirstError = (r.Action + ": " + why).Trim(' ', ':'); }
                if (r.TimeMs >= s.LastFailure) { s.LastFailure = r.TimeMs; s.LastError = (r.Action + ": " + why).Trim(' ', ':'); }
            }
            else
            {
                s.Successes++;
                s.FirstSuccess = MinPositive(s.FirstSuccess, r.TimeMs);
                if (r.TimeMs > s.LastSuccess) s.LastSuccess = r.TimeMs;
            }
            if (slow) s.Slow++;
            s.TotalMs += r.DurationMs; s.MaxMs = Math.Max(s.MaxMs, r.DurationMs); s.BytesIn += r.BytesIn; s.BytesOut += r.BytesOut;
            string front = r.FromBackEnd ? null : c.Server;
            string back = r.FromBackEnd ? c.Server : Identity.ServerName(r.TargetServer);
            if (front != null) s.Fronts.Add(front);
            if (back != null) s.Backs.Add(back);
            if (!r.FromBackEnd && r.ClientIp != null && !s.Ips.Contains(r.ClientIp) && s.Ips.Count < 20) s.Ips.Add(r.ClientIp);
            if (s.UserAgent == null && r.UserAgent != null) s.UserAgent = Identity.Cap(r.UserAgent, 300);
            if (s.DeviceId == null && r.DeviceId != null) s.DeviceId = r.DeviceId;
            if (s.DeviceType == null && r.DeviceType != null) s.DeviceType = r.DeviceType;
            if (s.Mailbox == null && r.Mailbox != null) s.Mailbox = r.Mailbox;
            Inc(s.Actions, r.Action ?? "?", 1);
            Inc(s.Statuses, StatusLabel(r), 1);
            var step = new SessionStep
            {
                T = r.TimeMs, T2 = r.TimeMs, Front = front, Back = back, Action = r.Action ?? "?", Status = r.Status, TotalMs = r.DurationMs, MaxMs = r.DurationMs,
                Failures = failure ? 1 : 0, Detail = failure ? Describe(r) : slow ? "Slow request" : r.Detail, RequestId = r.RequestId, Source = r.FromBackEnd ? "BE" : "FE",
                FileId = c.FileId, Needle = r.Needle ?? r.RequestId, Needle2 = r.Needle2
            };
            bool notable = failure || slow || s.Requests <= _o.SessionDetailRequests || Milestones.Contains(step.Action) || s.LastWasFailure || r.Detail != null;
            AddStep(s, step, notable);
            s.LastWasFailure = failure;
        }

        static string StatusLabel(AccessRecord r)
        {
            if (r.Source == "Imap4" || r.Source == "Pop3") return r.Status >= 400 ? "NO" : "OK";
            return r.Status.ToString(CultureInfo.InvariantCulture);
        }

        void AddStep(ClientSession s, SessionStep step, bool notable)
        {
            var steps = s.Steps;
            var last = steps.Count > 0 ? steps[steps.Count - 1] : null;
            bool full = steps.Count >= _o.MaxSegmentSteps && !(step.Failures > 0 && steps.Count < 2 * _o.MaxSegmentSteps);
            if (!notable || full)
            {
                if (last != null && last.Batch && last.Front == step.Front && last.Back == step.Back && step.T >= last.T && (full || step.T - last.T2 <= 900000))
                {
                    if (step.T > last.T2) last.T2 = step.T;
                    last.Count += step.Count; last.Failures += step.Failures; last.TotalMs += step.TotalMs; last.MaxMs = Math.Max(last.MaxMs, step.MaxMs);
                    int n; last.BatchActions.TryGetValue(step.Action, out n); last.BatchActions[step.Action] = n + step.Count;
                    return;
                }
                step.Batch = true;
                step.BatchActions = new Dictionary<string, int>(StringComparer.Ordinal) { { step.Action, step.Count } };
                step.Detail = null; step.RequestId = null; step.Needle = null; step.Needle2 = null;
            }
            steps.Add(step);
        }

        // ================================================================ sessions in the database

        void FlushSessions(FileContext c) { FlushSessions(c.Tx, c.Touched); }

        void FlushSessions(SqliteTransaction tx, HashSet<ClientSession> touched)
        {
            if (touched.Count == 0) return;
            const string cols = "skey,day,start_ms,end_ms,user,protocol,mailbox,client_ip,user_agent,device_id,device_type,software,client_mode,front_ends,back_ends," +
                "requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses," +
                "first_error,last_error,backend,connections,updated_ms";
            string[] names = cols.Split(',').Select(n => "@" + n).ToArray();
            using (var insert = _store.Command("INSERT INTO client_session(" + cols + ") VALUES(" + string.Join(",", names) + ") RETURNING id;", tx))
            using (var update = _store.Command("UPDATE client_session SET " + string.Join(",", cols.Split(',').Select(n => n + "=@" + n)) + " WHERE id=@id;", tx))
            using (var step = _store.Command("INSERT INTO session_step(session_id,time_ms,data) VALUES(@id,@t,@d);", tx))
            using (var repoint = _store.Command("UPDATE session_step SET session_id=@id WHERE session_id=@old;", tx))
            using (var delete = _store.Command("DELETE FROM client_session WHERE id=@old;", tx))
            {
                foreach (var n in names) { insert.Parameters.Add(n, SqliteType.Text); update.Parameters.Add(n, SqliteType.Text); }
                update.Parameters.Add("@id", SqliteType.Integer);
                step.Parameters.Add("@id", SqliteType.Integer); step.Parameters.Add("@t", SqliteType.Integer); step.Parameters.Add("@d", SqliteType.Text);
                repoint.Parameters.Add("@id", SqliteType.Integer); repoint.Parameters.Add("@old", SqliteType.Integer);
                delete.Parameters.Add("@old", SqliteType.Integer);
                long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                foreach (var s in touched)
                {
                    if (s.Dead) continue;
                    var cmd = s.Id == 0 ? insert : update;
                    Func<object, object> v = o => o ?? DBNull.Value;
                    var p = cmd.Parameters;
                    p["@skey"].Value = s.Key; p["@day"].Value = s.Day; p["@start_ms"].Value = s.Start; p["@end_ms"].Value = s.End; p["@user"].Value = s.User;
                    p["@protocol"].Value = s.Protocol; p["@mailbox"].Value = v(s.Mailbox);
                    p["@client_ip"].Value = v(s.Ips.Count == 0 ? null : string.Join(",", s.Ips.Take(10)));
                    p["@user_agent"].Value = v(s.UserAgent); p["@device_id"].Value = v(s.DeviceId); p["@device_type"].Value = v(s.DeviceType);
                    p["@software"].Value = v(s.Software); p["@client_mode"].Value = v(s.Mode);
                    p["@front_ends"].Value = v(s.Fronts.Count == 0 ? null : string.Join(",", s.Fronts));
                    p["@back_ends"].Value = v(s.Backs.Count == 0 ? null : string.Join(",", s.Backs));
                    p["@requests"].Value = s.Requests; p["@successes"].Value = s.Successes; p["@failures"].Value = s.Failures; p["@slow"].Value = s.Slow;
                    p["@first_success_ms"].Value = s.FirstSuccess; p["@last_success_ms"].Value = s.LastSuccess;
                    p["@first_failure_ms"].Value = s.FirstFailure; p["@last_failure_ms"].Value = s.LastFailure;
                    p["@total_ms"].Value = s.TotalMs; p["@max_ms"].Value = s.MaxMs; p["@bytes_in"].Value = s.BytesIn; p["@bytes_out"].Value = s.BytesOut;
                    p["@actions"].Value = v(Join(s.Actions)); p["@statuses"].Value = v(Join(s.Statuses));
                    p["@first_error"].Value = v(Identity.Cap(s.FirstError, 400)); p["@last_error"].Value = v(Identity.Cap(s.LastError, 400));
                    p["@backend"].Value = s.BackEndErrors > 0 || s.BackEndNote != null ? (object)(s.BackEndErrors.ToString(CultureInfo.InvariantCulture) + "|" + (s.BackEndNote ?? "")) : DBNull.Value;
                    p["@connections"].Value = s.Connections; p["@updated_ms"].Value = now;
                    if (s.Id == 0) s.Id = Convert.ToInt64(insert.ExecuteScalar(), CultureInfo.InvariantCulture);
                    else { update.Parameters["@id"].Value = s.Id; update.ExecuteNonQuery(); }
                    foreach (var old in s.Absorbed)
                    {
                        repoint.Parameters["@id"].Value = s.Id; repoint.Parameters["@old"].Value = old; repoint.ExecuteNonQuery();
                        delete.Parameters["@old"].Value = old; delete.ExecuteNonQuery();
                    }
                    s.Absorbed.Clear();
                    if (s.Steps.Count > 0)
                    {
                        step.Parameters["@id"].Value = s.Id; step.Parameters["@t"].Value = s.Steps.Min(x => x.T); step.Parameters["@d"].Value = StepsJson(s.Steps);
                        step.ExecuteNonQuery();
                        s.Steps.Clear();
                    }
                }
            }
            touched.Clear();
        }

        /// <summary>Steps as compact JSON: [t, t2, front, back, action, status, count, avgMs, maxMs, failures, detail, requestId, source, batch, fileId, needle, needle2].</summary>
        static string StepsJson(List<SessionStep> steps)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartArray();
                    foreach (var s in steps)
                    {
                        w.WriteStartArray();
                        w.WriteNumberValue(s.T); w.WriteNumberValue(s.T2);
                        Str(w, s.Front); Str(w, s.Back);
                        Str(w, s.Batch ? string.Join(", ", s.BatchActions.OrderByDescending(x => x.Value).Select(x => x.Key + " x" + x.Value.ToString(CultureInfo.InvariantCulture))) : s.Action);
                        w.WriteNumberValue(s.Status); w.WriteNumberValue(s.Count); w.WriteNumberValue(s.Count > 0 ? s.TotalMs / s.Count : 0); w.WriteNumberValue(s.MaxMs);
                        w.WriteNumberValue(s.Failures); Str(w, s.Detail); Str(w, s.RequestId); Str(w, s.Source); w.WriteBooleanValue(s.Batch);
                        w.WriteNumberValue(s.FileId); Str(w, s.Needle); Str(w, s.Needle2);
                        w.WriteEndArray();
                    }
                    w.WriteEndArray();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        static void Str(Utf8JsonWriter w, string s) { if (s == null) w.WriteNullValue(); else w.WriteStringValue(s); }

        // ================================================================ operations and clients (usage aggregates)

        sealed class ActionAcc { public string Day, Protocol, Action; public long Requests, Failures, Slow, TotalMs, MaxMs; }

        sealed class ClientAcc
        {
            public string Day, User, Protocol, Ip, Agent, DeviceId, DeviceType;
            public long Requests, Failures, First = long.MaxValue, Last;
        }

        static void CountAction(FileContext c, string day, AccessRecord r, bool failure, bool slow)
        {
            string action = r.Action ?? "?";
            string key = day + "|" + r.Protocol + "|" + action;
            ActionAcc a;
            if (!c.Actions.TryGetValue(key, out a)) { a = new ActionAcc { Day = day, Protocol = r.Protocol ?? "Other", Action = action }; c.Actions[key] = a; }
            a.Requests++;
            if (failure) a.Failures++;
            if (slow) a.Slow++;
            a.TotalMs += r.DurationMs; a.MaxMs = Math.Max(a.MaxMs, r.DurationMs);
        }

        static void CountClient(FileContext c, string day, AccessRecord r, bool failure)
        {
            string agent = Identity.Cap(r.UserAgent, 300) ?? "", device = r.DeviceId ?? "", ip = r.ClientIp ?? "";
            string key = day + "|" + r.User + "|" + r.Protocol + "|" + ip + "|" + agent + "|" + device;
            ClientAcc a;
            if (!c.Clients.TryGetValue(key, out a)) { a = new ClientAcc { Day = day, User = r.User, Protocol = r.Protocol ?? "Other", Ip = ip, Agent = agent, DeviceId = device }; c.Clients[key] = a; }
            a.Requests++;
            if (failure) a.Failures++;
            if (r.DeviceType != null) a.DeviceType = r.DeviceType;
            a.First = Math.Min(a.First, r.TimeMs); a.Last = Math.Max(a.Last, r.TimeMs);
        }

        void FlushActions(FileContext c)
        {
            if (c.Actions.Count == 0) return;
            using (var cmd = _store.Command(@"INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES(@d,@s,@p,@a,@n,@f,@sl,@t,@m)
ON CONFLICT(day,server,protocol,action) DO UPDATE SET requests=requests+excluded.requests, failures=failures+excluded.failures, slow=slow+excluded.slow,
 total_ms=total_ms+excluded.total_ms, max_ms=MAX(max_ms,excluded.max_ms);", c.Tx))
            {
                foreach (var n in new[] { "@d", "@s", "@p", "@a", "@n", "@f", "@sl", "@t", "@m" }) cmd.Parameters.Add(n, SqliteType.Text);
                var p = cmd.Parameters;
                foreach (var a in c.Actions.Values)
                {
                    p["@d"].Value = a.Day; p["@s"].Value = c.Server; p["@p"].Value = a.Protocol; p["@a"].Value = a.Action; p["@n"].Value = a.Requests;
                    p["@f"].Value = a.Failures; p["@sl"].Value = a.Slow; p["@t"].Value = a.TotalMs; p["@m"].Value = a.MaxMs;
                    cmd.ExecuteNonQuery();
                }
            }
        }

        void FlushClients(FileContext c)
        {
            if (c.Clients.Count == 0) return;
            using (var cmd = _store.Command(@"INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,requests,failures,first_ms,last_ms,servers)
VALUES(@d,@u,@p,@ip,@ua,@dev,@dt,@n,@f,@fi,@la,@s)
ON CONFLICT(day,user,protocol,client_ip,user_agent,device_id) DO UPDATE SET requests=requests+excluded.requests, failures=failures+excluded.failures,
 device_type=COALESCE(excluded.device_type,device_type), first_ms=MIN(first_ms,excluded.first_ms), last_ms=MAX(last_ms,excluded.last_ms),
 servers=CASE WHEN servers IS NULL THEN excluded.servers WHEN instr(','||servers||',', ','||excluded.servers||',') > 0 THEN servers ELSE servers||','||excluded.servers END;", c.Tx))
            {
                foreach (var n in new[] { "@d", "@u", "@p", "@ip", "@ua", "@dev", "@dt", "@n", "@f", "@fi", "@la", "@s" }) cmd.Parameters.Add(n, SqliteType.Text);
                var p = cmd.Parameters;
                foreach (var a in c.Clients.Values)
                {
                    p["@d"].Value = a.Day; p["@u"].Value = a.User; p["@p"].Value = a.Protocol; p["@ip"].Value = a.Ip; p["@ua"].Value = a.Agent; p["@dev"].Value = a.DeviceId;
                    p["@dt"].Value = (object)a.DeviceType ?? DBNull.Value; p["@n"].Value = a.Requests; p["@f"].Value = a.Failures;
                    p["@fi"].Value = a.First; p["@la"].Value = a.Last; p["@s"].Value = c.Server;
                    cmd.ExecuteNonQuery();
                }
            }
        }

        // ================================================================ MAPI over HTTP back end

        /// <summary>
        /// Logging\MapiHttp\Mailbox on the mailbox server. Requests are already counted from the front
        /// end; the back end adds the Outlook version and mode, the MAPI status of each request and the
        /// milestones (Connect, Disconnect, address book Bind / Unbind) with their back-end detail.
        /// </summary>
        long ParseMapiBackEnd(FileContext c)
        {
            long offset = c.State.Offset;
            int iTime = -1, iReq = -1, iType = -1, iHttp = -1, iResp = -1, iStat = -1, iRet = -1, iLat = -1, iEmail = -1, iUser = -1, iMbx = -1, iIp = -1,
                iCafe = -1, iCookie = -1, iInfo = -1, iSoft = -1, iVer = -1, iMode = -1, iOps = -1, iErr = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("DateTime"); iReq = m.Index("RequestId"); iType = m.Index("RequestType"); iHttp = m.Index("HttpStatusCode");
                iResp = m.Index("ResponseCode"); iStat = m.Index("StatusCode"); iRet = m.Index("ReturnCode"); iLat = m.Index("TotalRequestLatency");
                iEmail = m.Index("AuthenticatedUserEmail"); iUser = m.Index("AuthenticatedUser"); iMbx = m.Index("MailboxId"); iIp = m.Index("ClientIP");
                iCafe = m.Index("SourceCafeServer"); iCookie = m.Index("SessionCookie"); iInfo = m.Index("MapiClientInfo"); iSoft = m.Index("ClientSoftware");
                iVer = m.Index("ClientSoftwareVersion"); iMode = m.Index("ClientMode"); iOps = m.Index("OperationSpecific"); iErr = m.Index("GenericErrors");
            };
            if (c.Map.Load(c.State.Fields)) bind();
            foreach (var kv in LogReader.ReadLines(c.Path, offset))
            {
                string line = kv.Key;
                offset = kv.Value;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line[0] == '#')
                {
                    if (line.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase)) { c.Map.Load(line); c.State.Fields = line; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (line.StartsWith("DateTime,", StringComparison.Ordinal)) { Noise(c, "Header", 1); continue; }
                if (iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!TimeUtil.TryParseUtc(c.Split.Get(iTime), out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.DetailCutoffMs) { Noise(c, "Older than detail retention (back end)", 1); continue; }
                string software = c.Split.Get(iSoft);
                if (_probeAgents != null && software != null && _probeAgents.IsMatch(software)) { Noise(c, "Monitoring probe (client software)", 1); continue; }
                string raw = c.Split.Get(iEmail);
                string other = c.Split.Get(iUser);
                if (raw == null && other != null && !other.Equals("Anonymous", StringComparison.OrdinalIgnoreCase)) raw = other;
                string user = Identity.User(raw), ip = c.Split.Get(iIp);
                string why = ClientNoise(user, null, null, ip, null, 200);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                user = Canonical(user);
                string day = _days.Day(t), type = c.Split.Get(iType) ?? "?";
                string key = SessionKey(day, user, "Mapi", ip, null, null, Identity.MailboxGuid(c.Split.Get(iMbx)), Identity.ClientInstance(c.Split.Get(iInfo)));
                var s = FindSession(key, t, () => NewSession(key, day, user, "Mapi"));
                c.Touched.Add(s);
                Extend(s, t);
                s.Backs.Add(c.Server);
                string cafe = Identity.ServerName(c.Split.Get(iCafe));
                if (ip != null && !s.Ips.Contains(ip) && s.Ips.Count < 20) s.Ips.Add(ip);
                string version = c.Split.Get(iVer);
                if (software != null && s.Software == null) s.Software = software + (version != null ? " " + version : "");
                string mode = c.Split.Get(iMode);
                if (mode == "0") mode = null;   // unknown
                if (mode != null) s.Mode = mode;
                int http = c.Split.GetInt(iHttp, 200);
                long resp = c.Split.GetLong(iResp, 0), stat = c.Split.GetLong(iStat, 0), ret = c.Split.GetLong(iRet, 0);
                bool failed = http >= 400 || resp != 0 || stat != 0;
                var detail = new List<string>();
                detail.Add("MAPI " + (failed ? "failed" : "OK") + " (ResponseCode " + resp + ", StatusCode " + stat + (ret != 0 ? ", ReturnCode " + ret : "") + ")");
                string ops = c.Split.Get(iOps);
                if (ops != null) detail.Add(ops.Trim().TrimEnd(';'));
                if (software != null) detail.Add(software + (version != null ? " " + version : ""));
                if (mode != null) detail.Add("mode " + mode);
                string err = c.Split.Get(iErr);
                if (failed && err != null) detail.Add(Identity.Cap(err, 200));
                string text = string.Join("; ", detail);
                if (failed)
                {
                    s.BackEndErrors++;
                    string e = "MAPI " + type + ": " + text;
                    if (s.FirstError == null) s.FirstError = e;
                    s.LastError = e;
                    if (s.FirstFailure == 0 || t < s.FirstFailure) s.FirstFailure = t;
                    if (t > s.LastFailure) s.LastFailure = t;
                }
                if (failed || Milestones.Contains(type))
                {
                    long lat = c.Split.GetLong(iLat, 0);
                    AddStep(s, new SessionStep
                    {
                        T = t, T2 = t, Front = cafe, Back = c.Server, Action = type, Status = http, TotalMs = lat, MaxMs = lat, Failures = failed ? 1 : 0,
                        Detail = Identity.Cap(text, 400), RequestId = c.Split.Get(iReq), Source = "BE", FileId = c.FileId, Needle = c.Split.Get(iReq)
                    }, true);
                }
            }
            return offset;
        }

        // ================================================================ ActiveSync back end (IIS W3SVC2)

        /// <summary>
        /// Exchange Back End web site. Only ActiveSync lines are read: their "Log=" parameter holds the
        /// ActiveSync result that the HTTP status hides (an HTTP 200 can be DeviceNotProvisioned or
        /// UserDisabledForSync), the access state of the device and the protocol version.
        /// </summary>
        long ParseEasBackEnd(FileContext c)
        {
            long offset = c.State.Offset;
            int iDate = -1, iTime = -1, iMethod = -1, iStem = -1, iQuery = -1, iUser = -1, iAgent = -1, iStatus = -1, iTaken = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iDate = m.Index("date"); iTime = m.Index("time"); iMethod = m.Index("cs-method"); iStem = m.Index("cs-uri-stem"); iQuery = m.Index("cs-uri-query");
                iUser = m.Index("cs-username"); iAgent = m.Index("cs(User-Agent)"); iStatus = m.Index("sc-status"); iTaken = m.Index("time-taken");
            };
            if (c.Map.Load(c.State.Fields)) bind();
            foreach (var kv in LogReader.ReadLines(c.Path, offset))
            {
                string line = kv.Key;
                offset = kv.Value;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line[0] == '#')
                {
                    if (line.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase)) { c.Map.Load(line); c.State.Fields = line; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (line.IndexOf("/Microsoft-Server-ActiveSync", StringComparison.OrdinalIgnoreCase) < 0) { Noise(c, "Back-end traffic other than ActiveSync", 1); continue; }
                if (iDate < 0 || iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ' ');
                long t;
                if (!TimeUtil.TryParseUtc(c.Split.Get(iDate) + " " + c.Split.Get(iTime), out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.DetailCutoffMs) { Noise(c, "Older than detail retention (back end)", 1); continue; }
                string user = Identity.User(c.Split.Get(iUser)), agent = c.Split.Get(iAgent);
                if (agent != null) agent = agent.Replace('+', ' ');
                int status = c.Split.GetInt(iStatus, 0);
                string why = ClientNoise(user, null, agent, null, c.Split.Get(iStem), status);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                user = Canonical(user);
                string query = c.Split.Get(iQuery) ?? "";
                string cmd = Identity.QueryValue(query, "Cmd") ?? c.Split.Get(iMethod) ?? "?";
                string device = Identity.QueryValue(query, "DeviceId");
                string error = null, access = null, version = null;
                int logAt = query.IndexOf("Log=", StringComparison.OrdinalIgnoreCase);
                if (logAt >= 0)
                    foreach (Match m in EasLogToken.Matches(query.Substring(logAt + 4)))
                    {
                        string v = Uri.UnescapeDataString(m.Groups[2].Value);
                        switch (m.Groups[1].Value)
                        {
                            case "Error": error = v; break;
                            case "As": access = v; break;
                            case "Ver1": version = v.Length >= 2 ? v.Substring(0, v.Length - 1) + "." + v.Substring(v.Length - 1) : v; break;
                        }
                    }
                string day = _days.Day(t);
                string key = SessionKey(day, user, "Eas", null, agent, device, null, null);
                var s = FindSession(key, t, () => NewSession(key, day, user, "Eas"));
                c.Touched.Add(s);
                Extend(s, t);
                s.Backs.Add(c.Server);
                if (version != null) s.Software = "ActiveSync " + version;
                if (access != null) s.Mode = "Access " + access;
                if (s.DeviceId == null && device != null) s.DeviceId = device;
                if (error != null || status >= 400)
                {
                    s.BackEndErrors++;
                    string text = (error != null ? "ActiveSync error " + error : "HTTP " + status) + (access != null ? " (device access " + access + ")" : "");
                    string e = cmd + ": " + text;
                    if (s.FirstError == null) s.FirstError = e;
                    s.LastError = e;
                    if (s.FirstFailure == 0 || t < s.FirstFailure) s.FirstFailure = t;
                    if (t > s.LastFailure) s.LastFailure = t;
                    long taken = c.Split.GetLong(iTaken, 0);
                    AddStep(s, new SessionStep
                    {
                        T = t, T2 = t, Back = c.Server, Action = cmd, Status = status, TotalMs = taken, MaxMs = taken, Failures = 1, Detail = text, Source = "BE",
                        FileId = c.FileId, Needle = c.Split.Get(iDate) + " " + c.Split.Get(iTime) + " ",
                        Needle2 = Identity.QueryValue(query, "Cmd") != null ? "Cmd=" + cmd : c.Split.Get(iStem)
                    }, true);
                }
            }
            return offset;
        }

        // ================================================================ POP3 / IMAP4 (optional)

        sealed class PiLine { public long T, Ms, In, Out; public string Command, Params, Result, Needle; }

        sealed class PiConnection
        {
            public string Id, ClientIp, User, BackEnd;
            public long Start, Last, StartOffset, EndOffset;
            public int Lines;
            public bool Closed;   // LOGOUT / QUIT seen: complete even if CloseSession is not written yet
            public List<PiLine> Commands = new List<PiLine>();
        }

        sealed class DeferredBackEnd
        {
            public string Day, User, Protocol, Server, FrontIp;
            public long Start, End, Requests, Successes, Failures, Slow, TotalMs, MaxMs, BytesIn, BytesOut, FirstFailure, LastFailure, FirstSuccess, LastSuccess;
            public string FirstError, LastError;
            public Dictionary<string, long> Actions = new Dictionary<string, long>(StringComparer.Ordinal);
            public List<SessionStep> Steps = new List<SessionStep>();
        }

        /// <summary>
        /// Logging\Imap4 and Logging\Pop3: IMAP4*/POP3* files are the front end (client address, logon,
        /// back-end server), IMAP4BE*/POP3BE* files the back end (each command with its result).
        /// Connections are read whole and emitted once: while the file is active, the read position stops
        /// at the first line of the oldest connection still open, and every connection that has a line
        /// after that position is kept for the next collection (it is read again complete).
        /// </summary>
        long ParsePopImap(FileContext c, string protocol)
        {
            bool backEnd = Path.GetFileName(c.Path).StartsWith(protocol.ToUpperInvariant() + "BE", StringComparison.OrdinalIgnoreCase);
            var open = new Dictionary<string, PiConnection>(StringComparer.Ordinal);
            var done = new List<PiConnection>();
            long offset = c.State.Offset, lineStart = offset, fileLastMs = 0;
            int iTime = -1, iSess = -1, iClient = -1, iUser = -1, iDur = -1, iIn = -1, iOut = -1, iCmd = -1, iParams = -1, iCtx = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("dateTime"); iSess = m.Index("sessionId"); iClient = m.Index("cIp"); iUser = m.Index("user"); iDur = m.Index("duration");
                iIn = m.Index("rqsize"); iOut = m.Index("rpsize"); iCmd = m.Index("command"); iParams = m.Index("parameters"); iCtx = m.Index("context");
            };
            if (c.Map.Load(c.State.Fields)) bind();
            foreach (var kv in LogReader.ReadLines(c.Path, offset))
            {
                string line = kv.Key;
                long start = lineStart;
                lineStart = kv.Value;
                offset = kv.Value;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line[0] == '#')
                {
                    if (line.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase)) { c.Map.Load(line); c.State.Fields = line; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (iTime < 0 || iSess < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!TimeUtil.TryParseUtc(c.Split.Get(iTime), out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t > fileLastMs) fileLastMs = t;
                string sid = c.Split.Get(iSess) ?? "", cmd = c.Split.Get(iCmd) ?? "";
                PiConnection x;
                if (cmd.Equals("OpenSession", StringComparison.OrdinalIgnoreCase) || !open.TryGetValue(sid, out x))
                {
                    // Session ids restart with the service: a new OpenSession closes the previous connection of that id.
                    if (open.TryGetValue(sid, out x)) { x.Closed = true; done.Add(x); }
                    x = new PiConnection { Id = sid, Start = t, StartOffset = start, ClientIp = Identity.Host(c.Split.Get(iClient)) };
                    open[sid] = x;
                }
                x.Lines++;
                x.Last = t;
                x.EndOffset = kv.Value;
                string user = c.Split.Get(iUser);
                if (user != null && (x.User == null || x.User.IndexOf('@') > 0)) x.User = user;
                string ctx = c.Split.Get(iCtx);
                if (ctx != null && x.BackEnd == null)
                {
                    var proxy = Regex.Match(ctx, @"Proxy:([^:;""]+)");
                    if (proxy.Success) x.BackEnd = Identity.ServerName(proxy.Groups[1].Value);
                }
                if (cmd.Equals("CloseSession", StringComparison.OrdinalIgnoreCase))
                {
                    x.Commands.Add(new PiLine { T = t, Command = cmd, In = c.Split.GetLong(iIn, 0), Out = c.Split.GetLong(iOut, 0) });
                    x.Closed = true;
                    done.Add(x);
                    open.Remove(sid);
                    continue;
                }
                if (!cmd.Equals("OpenSession", StringComparison.OrdinalIgnoreCase))
                    x.Commands.Add(new PiLine
                    {
                        T = t, Command = cmd, Params = c.Split.Get(iParams), Result = ResultOf(ctx), Ms = c.Split.GetLong(iDur, 0),
                        In = c.Split.GetLong(iIn, 0), Out = c.Split.GetLong(iOut, 0), Needle = c.Split.Get(iTime) + "," + sid + ","
                    });
                if (cmd.Equals("logout", StringComparison.OrdinalIgnoreCase) || cmd.Equals("quit", StringComparison.OrdinalIgnoreCase)) x.Closed = true;
            }
            bool active = _o.NowMs - c.LastWriteMs < _o.SmtpIdleMs;
            long safe = offset;
            foreach (var x in open.Values)
            {
                // Still open and recently active: it can receive lines after the end of the file.
                if (active && !x.Closed && fileLastMs - x.Last < _o.SmtpIdleMs) safe = Math.Min(safe, x.StartOffset);
                else done.Add(x);
            }
            // A finished connection that has lines after the read position would be read again in part:
            // move the position back to its first line, until no connection crosses it.
            bool moved = true;
            while (moved)
            {
                moved = false;
                foreach (var x in done)
                    if (x.StartOffset < safe && x.EndOffset > safe) { safe = x.StartOffset; moved = true; }
            }
            foreach (var x in done) if (x.EndOffset <= safe) EmitPopImap(c, x, protocol, backEnd);
            return safe;
        }

        /// <summary>"R=OK;Msg=..." gives "OK"; "R=""a2 NO LOGIN failed.""" gives "NO LOGIN failed.".</summary>
        static string ResultOf(string context)
        {
            if (string.IsNullOrEmpty(context)) return null;
            int r = context.IndexOf("R=", StringComparison.Ordinal);
            if (r < 0) return null;
            string v;
            if (r + 2 < context.Length && context[r + 2] == '"')
            {
                int end = context.IndexOf('"', r + 3);
                v = end > r ? context.Substring(r + 3, end - r - 3) : context.Substring(r + 3);
            }
            else
            {
                int end = context.IndexOf(';', r);
                v = end > r ? context.Substring(r + 2, end - r - 2) : context.Substring(r + 2);
            }
            var tagged = Regex.Match(v, @"^[A-Za-z]*\d+\s+(.*)$");
            return (tagged.Success ? tagged.Groups[1].Value : v).Trim();
        }

        static bool PiFailed(string result)
        {
            if (string.IsNullOrEmpty(result)) return false;
            return result.StartsWith("NO", StringComparison.OrdinalIgnoreCase) || result.StartsWith("BAD", StringComparison.OrdinalIgnoreCase) || result.StartsWith("-ERR", StringComparison.OrdinalIgnoreCase);
        }

        void EmitPopImap(FileContext c, PiConnection x, string protocol, bool backEnd)
        {
            string user = Identity.User(x.User);
            if (user == null)
            {
                bool logonFailed = x.Commands.Any(l => PiFailed(l.Result) && (l.Command.Equals("login", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("authenticate", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("pass", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("user", StringComparison.OrdinalIgnoreCase)));
                Noise(c, logonFailed ? protocol + " logon failed (the account is not logged)" : protocol + " connection without logon", x.Lines);
                return;
            }
            string why = ClientNoise(user, null, null, backEnd ? null : x.ClientIp, null, 200);
            if (why != null) { Noise(c, why, x.Lines); return; }
            c.Result.Kept += x.Lines;
            user = Canonical(user);
            DeferredBackEnd deferred = null;
            if (backEnd && x.Start >= _o.DetailCutoffMs)
            {
                deferred = new DeferredBackEnd { Day = _days.Day(x.Start), User = user, Protocol = protocol, Server = c.Server, FrontIp = x.ClientIp, Start = x.Start, End = x.Last };
                _deferred.Add(deferred);
            }
            bool first = true;
            int index = 0;
            foreach (var l in x.Commands)
            {
                index++;
                string cmd = l.Command;
                if (cmd.Equals("CloseSession", StringComparison.OrdinalIgnoreCase)) continue;
                // The back end repeats the logon of the front end (IMAP authenticate, POP AUTH) and the capability exchange.
                if (backEnd && (cmd.Equals("authenticate", StringComparison.OrdinalIgnoreCase) || cmd.Equals("auth", StringComparison.OrdinalIgnoreCase)
                    || cmd.Equals("capability", StringComparison.OrdinalIgnoreCase) || cmd.Equals("capa", StringComparison.OrdinalIgnoreCase))) continue;
                bool failed = PiFailed(l.Result);
                bool logon = cmd.Equals("login", StringComparison.OrdinalIgnoreCase) || cmd.Equals("pass", StringComparison.OrdinalIgnoreCase) || cmd.Equals("user", StringComparison.OrdinalIgnoreCase);
                var r = new AccessRecord
                {
                    TimeMs = l.T, Source = protocol, Protocol = protocol, User = user, ClientIp = backEnd ? null : x.ClientIp, Action = cmd.ToUpperInvariant(),
                    Status = failed ? (logon ? 401 : 400) : 200, ErrorCode = failed ? Identity.Cap(l.Result, 300) : null, DurationMs = l.Ms, BytesIn = l.In, BytesOut = l.Out,
                    TargetServer = backEnd ? null : x.BackEnd, FromBackEnd = backEnd,
                    // One id per command (access_event is unique per server, source and request id); session ids restart with the service.
                    RequestId = protocol + " " + c.Server + " #" + x.Id + "/" + index.ToString(CultureInfo.InvariantCulture) + "@" + l.T.ToString(CultureInfo.InvariantCulture),
                    Needle = l.Needle,
                    Detail = first && !backEnd ? "Connection " + x.Id + " from " + x.ClientIp + (x.BackEnd != null ? ", proxied to " + x.BackEnd : "") : null
                };
                HandleAccess(c, r);
                if (!backEnd && first)
                {
                    // One connection more for the session of this client.
                    var s = FindSession(SessionKey(_days.Day(l.T), user, protocol, x.ClientIp, null, null, null, null), l.T, () => NewSession(SessionKey(_days.Day(l.T), user, protocol, x.ClientIp, null, null, null, null), _days.Day(l.T), user, protocol));
                    if (l.T >= _o.DetailCutoffMs) { s.Connections++; c.Touched.Add(s); }
                }
                first = false;
                if (deferred != null)
                {
                    bool slow = !failed && _o.SlowRequestMs > 0 && l.Ms >= _o.SlowRequestMs && !LongRunning(r);
                    deferred.Requests++;
                    if (failed)
                    {
                        deferred.Failures++;
                        string e = r.Action + ": " + l.Result;
                        if (deferred.FirstFailure == 0) { deferred.FirstFailure = l.T; deferred.FirstError = e; }
                        deferred.LastFailure = l.T; deferred.LastError = e;
                    }
                    else { deferred.Successes++; deferred.FirstSuccess = MinPositive(deferred.FirstSuccess, l.T); deferred.LastSuccess = Math.Max(deferred.LastSuccess, l.T); }
                    if (slow) deferred.Slow++;
                    deferred.TotalMs += l.Ms; deferred.MaxMs = Math.Max(deferred.MaxMs, l.Ms); deferred.BytesIn += l.In; deferred.BytesOut += l.Out;
                    Inc(deferred.Actions, r.Action, 1);
                    deferred.Steps.Add(new SessionStep
                    {
                        T = l.T, T2 = l.T, Back = c.Server, Action = r.Action, Status = r.Status, TotalMs = l.Ms, MaxMs = l.Ms, Failures = failed ? 1 : 0,
                        Detail = Identity.Cap((l.Params != null && !l.Params.Contains("*****") ? l.Params + " -> " : "") + (l.Result ?? ""), 300), Source = "BE",
                        RequestId = r.RequestId, FileId = c.FileId, Needle = l.Needle
                    });
                }
            }
        }

        /// <summary>
        /// Attaches the back-end IMAP/POP connections of this run to the session of their client: same
        /// user and protocol, the back-end server among the proxy targets, overlapping times. Without a
        /// match (front end not collected), the connection gets its own session "via" the front end.
        /// </summary>
        void CompleteBackEnd()
        {
            if (_deferred.Count == 0) return;
            var touched = new HashSet<ClientSession>();
            using (var tx = _store.Begin())
            {
                _tx = tx;
                try
                {
                    foreach (var d in _deferred)
                    {
                        ClientSession s = null;
                        List<ClientSession> list;
                        if (_byUser.TryGetValue(d.Day + "|" + d.User + "|" + d.Protocol, out list))
                            s = list.Where(x => !x.Dead && x.Backs.Contains(d.Server) && x.Start - 120000 <= d.End && x.End + 120000 >= d.Start)
                                    .OrderBy(x => Math.Abs(x.Start - d.Start)).FirstOrDefault();
                        if (s == null)
                        {
                            string key = null;
                            using (var q = _store.Command(@"SELECT skey FROM client_session WHERE user=@u AND protocol=@p AND day=@d AND start_ms <= @e AND end_ms >= @s
     AND instr(','||COALESCE(back_ends,'')||',', ','||@srv||',') > 0 ORDER BY abs(start_ms-@s0) LIMIT 1;", tx))
                            {
                                q.Parameters.AddWithValue("@u", d.User); q.Parameters.AddWithValue("@p", d.Protocol); q.Parameters.AddWithValue("@d", d.Day);
                                q.Parameters.AddWithValue("@e", d.End + 120000); q.Parameters.AddWithValue("@s", d.Start - 120000); q.Parameters.AddWithValue("@srv", d.Server);
                                q.Parameters.AddWithValue("@s0", d.Start);
                                key = q.ExecuteScalar() as string;
                            }
                            if (key != null) s = FindSession(key, d.Start, () => NewSession(key, d.Day, d.User, d.Protocol));
                        }
                        if (s == null)
                        {
                            string key = d.Day + "|" + d.User + "|" + d.Protocol + "|via:" + d.FrontIp;
                            s = FindSession(key, d.Start, () => NewSession(key, d.Day, d.User, d.Protocol));
                            if (s.Ips.Count == 0 && d.FrontIp != null) s.Ips.Add(d.FrontIp + " (front end)");
                        }
                        touched.Add(s);
                        Extend(s, d.Start); Extend(s, d.End);
                        s.Backs.Add(d.Server);
                        s.Requests += d.Requests; s.Successes += d.Successes; s.Failures += d.Failures; s.Slow += d.Slow;
                        s.TotalMs += d.TotalMs; s.MaxMs = Math.Max(s.MaxMs, d.MaxMs); s.BytesIn += d.BytesIn; s.BytesOut += d.BytesOut;
                        s.FirstSuccess = MinPositive(s.FirstSuccess, d.FirstSuccess); s.LastSuccess = Math.Max(s.LastSuccess, d.LastSuccess);
                        if (d.FirstFailure > 0 && (s.FirstFailure == 0 || d.FirstFailure < s.FirstFailure)) { s.FirstFailure = d.FirstFailure; s.FirstError = d.FirstError; }
                        if (d.LastFailure > s.LastFailure) { s.LastFailure = d.LastFailure; s.LastError = d.LastError; }
                        foreach (var kv in d.Actions) Inc(s.Actions, kv.Key, kv.Value);
                        foreach (var step in d.Steps) AddStep(s, step, true);
                    }
                    FlushSessions(tx, touched);
                    tx.Commit();
                }
                finally { _tx = null; }
            }
            _deferred.Clear();
        }
    }
}
