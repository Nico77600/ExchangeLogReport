// =============================================================================
//  Exchange Log Report - engine, part 5: client sessions and back-end correlation
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 3.0.0
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
//  Sessions keep their counters, plus a timeline ("steps") per log file: every
//  failure, slow request and milestone (Connect, Provision, logon...) and the first
//  requests of the session are kept one by one; the other successes are folded into
//  "batch" steps. Long healthy sessions stay small, problems keep their detail.
//  The back-end logs are parsed by the parse threads (records only); the sessions
//  are only touched by the apply thread, and written once per batch of files.
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

    /// <summary>Steps of one session written for one log file (MaxSessionSteps applies per file).</summary>
    sealed class FileSteps { public int Count; public SessionStep Last; }

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
        public Dictionary<string, long> Auths = new Dictionary<string, long>(StringComparer.Ordinal);   // authentication type tokens of the front-end requests
        public List<SessionStep> Steps = new List<SessionStep>();
        public Dictionary<long, FileSteps> PerFile = new Dictionary<long, FileSteps>();
        public List<long> Absorbed = new List<long>();
        public bool LastWasFailure, Dead;
    }

    /// <summary>A MAPI or ActiveSync back-end line of a real user, as read by a parse thread.</summary>
    sealed class BackEndLine
    {
        public long T, Ms;
        public int Status;
        public bool Failed;
        public string User, Ip, MailboxGuid, Instance, Type, Cafe, Software, Version, Mode, Text, RequestId;
        public string Upn;   // MAPI back end: the UPN of the authenticated user (SID evidence)
        public string Agent, Device, Error, Access, Needle, Needle2, HasCmd;
    }

    /// <summary>What the logs say of one security identifier: one row of identity_map.</summary>
    sealed class IdentityEntry
    {
        public string Sid, User, Status = IdentityMap.Unresolved;
        public readonly Dictionary<string, Dictionary<string, long>> Names = new Dictionary<string, Dictionary<string, long>>(StringComparer.Ordinal);   // kind -> name -> lines
        public readonly Dictionary<string, long[]> Days = new Dictionary<string, long[]>(StringComparer.Ordinal);   // back-end kind -> first and last UTC day of its lines
        public readonly Dictionary<string, long> Hints = new Dictionary<string, long>(StringComparer.Ordinal);   // account the device reported (or "eas-backend:" account of its device) -> lines
        public long Lines, FirstMs, LastMs;
        public long? ResolvedMs, AppliedMs;
        public bool Dirty;
        public bool System;     // User matches Noise.SystemUserPatterns
        public bool Unmerged;   // merged with User, then no longer resolved in this collection (the merge stays)
        public string Ignored;  // the mapping file entry the logs contradict (null: none)

        /// <summary>The account the rows of the SID were merged with while it was resolved, for a SID no longer resolved (null otherwise).</summary>
        public string MergedWith { get { return Status != IdentityMap.Resolved && AppliedMs != null ? User : null; } }
    }

    /// <summary>
    /// Evidence of the security identifiers (SIDs) Exchange logs as the user of token (OAuth) requests, and their resolution: a SID resolves
    /// to an account only when every line that pairs it with a name names that account. Within one kind of evidence every name must be the
    /// same account (same bare name, same domain when both have one), and the kinds must agree with each other; any disagreement makes the SID
    /// ambiguous: it stays as logged. The anchor kind (the account's own ActiveSync, OWA or ECP lines) resolves at once; the mapi-backend kind
    /// (a join of the back end with the front end) resolves alone only when its lines span two days at least, or with a mapping file entry that
    /// names the same account. The manual mapping file ranks last and never overrides the logs. Resolution takes effect in two steps: the
    /// collection writes the requests of the SIDs resolved when it started under their account (Freeze), and its evidence is applied to the
    /// stored rows by the pass at its end, once every file's evidence is in.
    /// </summary>
    sealed class IdentityMap
    {
        public const string Resolved = "resolved", Ambiguous = "ambiguous", Unresolved = "unresolved";
        public const string Anchor = "anchor", MapiBackEnd = "mapi-backend", File = "file";
        /// <summary>Prefix of a hint: the account the ActiveSync back end logged for a device the front end saw under the SID (never used to merge).</summary>
        public const string EasBackEnd = "eas-backend";
        const string DaysKind = "days";
        static readonly string[] LogKinds = { Anchor, MapiBackEnd };
        internal static readonly string[] Kinds = { Anchor, MapiBackEnd, File };
        public const int MaxNames = 8, MaxHints = 4;
        const long DayMs = 86400000L;

        readonly Dictionary<string, IdentityEntry> _entries = new Dictionary<string, IdentityEntry>(StringComparer.Ordinal);
        Dictionary<string, string> _frozen = new Dictionary<string, string>(StringComparer.Ordinal);   // SID -> account when the collection started (null: system account)
        readonly Func<string, string> _canonical;
        readonly Func<string, bool> _system;

        /// <summary>canonical: the account form of a name ("sam@suffix" to the known "domain\sam"); system: the SystemUserPatterns test.</summary>
        public IdentityMap(Func<string, string> canonical, Func<string, bool> system) { _canonical = canonical; _system = system; }

        public IEnumerable<IdentityEntry> Entries { get { return _entries.Values; } }
        public bool Has(string sid) { return _entries.ContainsKey(sid); }

        public void Load(IdentityEntry e)
        {
            e.System = e.User != null && _system(e.User);
            _entries[e.Sid] = e;
        }

        IdentityEntry Get(string sid, long t)
        {
            IdentityEntry e;
            if (!_entries.TryGetValue(sid, out e)) { e = new IdentityEntry { Sid = sid, FirstMs = t, LastMs = t, Dirty = true }; _entries[sid] = e; }
            return e;
        }

        static void Span(IdentityEntry e, long first, long last)
        {
            if (first < e.FirstMs) e.FirstMs = first;
            if (last > e.LastMs) e.LastMs = last;
        }

        /// <summary>The SIDs resolved now are the ones TryResolve answers until the next call (the start of a collection).</summary>
        public void Freeze()
        {
            var frozen = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var e in _entries.Values)
                if (e.Status == Resolved && e.User != null) frozen[e.Sid] = e.System ? null : e.User;
            _frozen = frozen;
        }

        /// <summary>Lines of one kind of evidence (first and last time) that pair the SID with a name (lower case, as logged); re-evaluates the SID.</summary>
        public void Add(string sid, string kind, string name, long lines, long first, long last, long now)
        {
            if (string.IsNullOrEmpty(name) || Identity.IsSid(name)) return;
            name = name.Replace(';', ',');
            var e = Get(sid, first);
            Dictionary<string, long> names;
            if (!e.Names.TryGetValue(kind, out names)) { names = new Dictionary<string, long>(StringComparer.Ordinal); e.Names[kind] = names; }
            long n;
            if (!names.TryGetValue(name, out n) && names.Count >= MaxNames) return;
            names[name] = n + lines;
            Span(e, first, last);
            if (kind != Anchor && kind != File)
            {
                long d0 = first / DayMs, d1 = last / DayMs;
                long[] days;
                if (!e.Days.TryGetValue(kind, out days)) e.Days[kind] = new[] { d0, d1 };
                else { days[0] = Math.Min(days[0], d0); days[1] = Math.Max(days[1], d1); }
            }
            e.Dirty = true;
            Evaluate(e, now);
        }

        /// <summary>An account seen with the SID that is not evidence (ActiveSync User=, or the eas-backend account of its device): a hint, never used to merge.</summary>
        public void Hint(string sid, string value, long lines, long first, long last)
        {
            if (string.IsNullOrEmpty(value)) return;
            value = value.Replace(';', ',');
            var e = Get(sid, first);
            long n;
            if (!e.Hints.TryGetValue(value, out n) && e.Hints.Count >= MaxHints) return;
            e.Hints[value] = n + lines;
            Span(e, first, last);
            e.Dirty = true;
        }

        /// <summary>A request recorded under the SID.</summary>
        public void Observe(string sid, long t)
        {
            var e = Get(sid, t);
            e.Lines++;
            Span(e, t, t);
            // The requests of a SID resolved to a system account are written under the SID and removed by the next pass.
            if (e.Status == Resolved && e.System) e.AppliedMs = null;
            e.Dirty = true;
        }

        /// <summary>
        /// The account of a SID resolved when the collection started (Freeze); false for any other SID and for a SID resolved to a system account
        /// (its rows become noise).
        /// </summary>
        public bool TryResolve(string sid, out string user)
        {
            return _frozen.TryGetValue(sid, out user) && user != null;
        }

        public static string Domain(string name)
        {
            int b = name.IndexOf('\\');
            return b > 0 ? name.Substring(0, b) : null;
        }

        /// <summary>Two names of one account: the same bare name, and the same domain when both have one.</summary>
        public static bool SameAccount(string a, string b)
        {
            if (!string.Equals(Identity.Bare(a), Identity.Bare(b), StringComparison.Ordinal)) return false;
            string da = Domain(a), db = Domain(b);
            return da == null || db == null || string.Equals(da, db, StringComparison.Ordinal);
        }

        static bool Agree(Dictionary<string, long> names)
        {
            var list = names.Keys.ToList();
            for (int i = 0; i < list.Count; i++)
                for (int j = i + 1; j < list.Count; j++)
                    if (!SameAccount(list[i], list[j])) return false;
            return true;
        }

        /// <summary>The name of an agreeing kind: the "domain\sam" form first, then the most lines, then the ordinal order.</summary>
        static string Pick(Dictionary<string, long> names)
        {
            return names.OrderBy(x => x.Key.IndexOf('\\') > 0 ? 0 : 1).ThenByDescending(x => x.Value).ThenBy(x => x.Key, StringComparer.Ordinal).First().Key;
        }

        /// <summary>The lines of a back-end kind fall on two different days at least.</summary>
        static bool TwoDays(IdentityEntry e, string kind)
        {
            long[] days;
            return e.Days.TryGetValue(kind, out days) && days[1] > days[0];
        }

        /// <summary>
        /// The status and account of a SID from its evidence. A SID whose rows were merged with an account keeps that account (MergedWith) when
        /// later evidence makes it ambiguous or unresolved: the merge is not undone, and Unmerged marks the change for the collection log.
        /// </summary>
        public void Evaluate(IdentityEntry e, long now)
        {
            string best = null, bestKind = null;
            bool ambiguous = false;
            var picks = new List<string>();
            foreach (var kind in LogKinds)
            {
                Dictionary<string, long> names;
                if (!e.Names.TryGetValue(kind, out names) || names.Count == 0) continue;
                if (!Agree(names)) { ambiguous = true; continue; }
                string pick = Pick(names);
                if (picks.Any(p => !SameAccount(p, pick))) ambiguous = true;
                picks.Add(pick);
                if (best == null) { best = pick; bestKind = kind; }
            }
            Dictionary<string, long> file;
            string manual = e.Names.TryGetValue(File, out file) && file.Count > 0 ? Pick(file) : null;
            string status, user = null;
            e.Ignored = null;
            if (ambiguous) { status = Ambiguous; if (manual != null) e.Ignored = manual; }
            else if (best != null)
            {
                bool contradicted = manual != null && !SameAccount(manual, best);
                if (contradicted) e.Ignored = manual;
                if (bestKind == Anchor || TwoDays(e, bestKind) || (manual != null && !contradicted)) { status = Resolved; user = best; }
                else status = Unresolved;
            }
            else if (manual != null) { status = Resolved; user = manual; }
            else status = Unresolved;
            if (user != null) user = _canonical(user);
            if (status != Resolved && e.AppliedMs != null && e.User != null)
            {
                // Rows already merged with e.User stay with it.
                if (status == e.Status) return;
                if (e.Status == Resolved) e.Unmerged = true;
                e.Status = status;
                e.Dirty = true;
                return;
            }
            if (status == e.Status && string.Equals(user, e.User, StringComparison.Ordinal)) return;
            if (status == Resolved) { e.ResolvedMs = now; e.AppliedMs = null; }
            e.Status = status;
            e.User = user;
            e.System = user != null && _system(user);
            e.Dirty = true;
        }

        /// <summary>
        /// "anchor:contoso\hank=312;mapi-backend:hank@contoso.test=40;days:mapi-backend=20390-20391": the evidence by kind rank, then most lines,
        /// then name; then the first and last day of each back-end kind.
        /// </summary>
        public static string NamesText(IdentityEntry e)
        {
            var parts = new List<string>();
            foreach (var kind in Kinds)
            {
                Dictionary<string, long> names;
                if (!e.Names.TryGetValue(kind, out names)) continue;
                foreach (var kv in names.OrderByDescending(x => x.Value).ThenBy(x => x.Key, StringComparer.Ordinal))
                    parts.Add(kind + ":" + kv.Key + "=" + kv.Value.ToString(CultureInfo.InvariantCulture));
            }
            foreach (var kv in e.Days.OrderBy(x => x.Key, StringComparer.Ordinal))
                parts.Add(DaysKind + ":" + kv.Key + "=" + kv.Value[0].ToString(CultureInfo.InvariantCulture) + "-" + kv.Value[1].ToString(CultureInfo.InvariantCulture));
            return parts.Count == 0 ? null : string.Join(";", parts);
        }

        /// <summary>The names text as shown to the operator: the evidence, without the days of the back-end kinds.</summary>
        public static string EvidenceText(string names)
        {
            if (string.IsNullOrEmpty(names)) return names;
            var parts = names.Split(';').Where(p => !p.StartsWith(DaysKind + ":", StringComparison.Ordinal)).ToArray();
            return parts.Length == 0 ? null : string.Join(";", parts);
        }

        public static string HintsText(IdentityEntry e)
        {
            if (e.Hints.Count == 0) return null;
            return string.Join(";", e.Hints.OrderByDescending(x => x.Value).ThenBy(x => x.Key, StringComparer.Ordinal).Select(kv => kv.Key + "=" + kv.Value.ToString(CultureInfo.InvariantCulture)));
        }

        /// <summary>The names text read back (the kind "file" is left out: the mapping file is read again at every collection; unknown kinds too).</summary>
        public static void ParseNames(string text, IdentityEntry e)
        {
            if (string.IsNullOrEmpty(text)) return;
            foreach (var part in text.Split(';'))
            {
                int colon = part.IndexOf(':'), eq = part.LastIndexOf('=');
                if (colon <= 0 || eq <= colon) continue;
                string kind = part.Substring(0, colon), value = part.Substring(eq + 1);
                if (kind == DaysKind)
                {
                    int dash = value.IndexOf('-');
                    long d0, d1;
                    if (dash > 0 && long.TryParse(value.Substring(0, dash), NumberStyles.Integer, CultureInfo.InvariantCulture, out d0)
                        && long.TryParse(value.Substring(dash + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out d1))
                        e.Days[part.Substring(colon + 1, eq - colon - 1)] = new[] { d0, d1 };
                    continue;
                }
                long n;
                if (kind == File || Array.IndexOf(Kinds, kind) < 0 || !long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) continue;
                Dictionary<string, long> names;
                if (!e.Names.TryGetValue(kind, out names)) { names = new Dictionary<string, long>(StringComparer.Ordinal); e.Names[kind] = names; }
                names[part.Substring(colon + 1, eq - colon - 1)] = n;
            }
        }

        public static void ParseHints(string text, IdentityEntry e)
        {
            if (string.IsNullOrEmpty(text)) return;
            foreach (var part in text.Split(';'))
            {
                int eq = part.LastIndexOf('=');
                long n;
                if (eq > 0 && long.TryParse(part.Substring(eq + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) e.Hints[part.Substring(0, eq)] = n;
            }
        }
    }

    /// <summary>The evidence one HttpProxy file gives for one SID (parse thread): names paired with it by the anchor, accounts its device reported.</summary>
    sealed class FileEvidence
    {
        public Dictionary<string, long> Names, Hints;
        public long FirstMs = long.MaxValue, LastMs;
    }

    public sealed partial class Collector
    {
        readonly Dictionary<string, List<ClientSession>> _sessions = new Dictionary<string, List<ClientSession>>(StringComparer.Ordinal);
        readonly Dictionary<string, List<ClientSession>> _byUser = new Dictionary<string, List<ClientSession>>(StringComparer.Ordinal);
        readonly Dictionary<string, string> _accounts = new Dictionary<string, string>(StringComparer.Ordinal);
        readonly List<DeferredBackEnd> _deferred = new List<DeferredBackEnd>();
        SqliteTransaction _tx;   // transaction in progress (session lookups must run inside it)

        static readonly HashSet<string> Milestones = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Connect", "Disconnect", "Bind", "Unbind", "Provision", "FolderSync", "OPTIONS", "login", "authenticate", "logout",
            "user", "pass", "quit", "POST auth.owa", "GET logoff.owa", "CreateItem", "SendMail", "SmartReply", "SmartForward", "Logon"
        };
        static readonly Regex EasLogToken = new Regex(@"(?:^|_)(Error|As|Ver1|PrxFrom):([^_&]*)", RegexOptions.Compiled);
        static readonly Regex ProxyTargetRx = new Regex(@"Proxy:([^:;""]+)", RegexOptions.Compiled);
        static readonly Regex TaggedResultRx = new Regex(@"^[A-Za-z]*\d+\s+(.*)$", RegexOptions.Compiled);

        // ================================================================ identities

        /// <summary>Accounts already known as "domain\sam": IMAP, POP and back-end logs often give "sam" or the UPN only.</summary>
        void LoadAccounts()
        {
            // One seek per user in ix_usage_user (user, day): DISTINCT read the whole index, one entry per user, server,
            // protocol and day of the retention.
            using (var c = _store.Command("SELECT user FROM access_usage WHERE user > @after ORDER BY user LIMIT 1;"))
            {
                var after = c.Parameters.Add("@after", SqliteType.Text);
                after.Value = "";
                while (true)
                {
                    var user = c.ExecuteScalar() as string;
                    if (user == null) break;
                    if (user.IndexOf('\\') > 0) LearnAccount(user);
                    after.Value = user;
                }
            }
        }

        void LearnAccount(string user)
        {
            string bare = Identity.Bare(user), known;
            if (string.IsNullOrEmpty(bare)) return;
            if (!_accounts.TryGetValue(bare, out known)) _accounts[bare] = user;
            else if (known != null && !string.Equals(known, user, StringComparison.Ordinal)) _accounts[bare] = null;   // two domains: ambiguous
        }

        /// <summary>
        /// A SID resolved when the collection started becomes its account; "sam" or "sam@upn-suffix" becomes "domain\sam" when that account is known
        /// (and not ambiguous).
        /// </summary>
        string Canonical(string user)
        {
            return CanonicalOf(user, _identities != null && user != null && user.Length > 4 && user[0] == 's');
        }

        /// <summary>Canonical, with the SID lookup only when maybeSid (the caller knows whether the name can be a SID).</summary>
        string CanonicalOf(string user, bool maybeSid)
        {
            if (user == null) return null;
            string resolved;
            if (maybeSid && _identities.TryResolve(user, out resolved)) user = resolved;
            if (user.IndexOf('\\') >= 0) { LearnAccount(user); return user; }
            string canon;
            return _accounts.TryGetValue(Identity.Bare(user), out canon) && canon != null ? canon : user;
        }

        /// <summary>The account form of a name by the bare-name rule alone (nothing is learnt).</summary>
        string CanonicalName(string name)
        {
            if (name == null || name.IndexOf('\\') >= 0) return name;
            string canon;
            return _accounts.TryGetValue(Identity.Bare(name), out canon) && canon != null ? canon : name;
        }

        // ================================================================ security identifiers (token requests)

        IdentityMap _identities;   // null when Collection.ResolveSids is false
        // Apply thread: the MAPI client sessions the front end logged under a SID (day | key after the user -> SID; null: two SIDs) for the MAPI back
        // end, and the ActiveSync devices seen under a SID (device -> SID; null: two SIDs) for the hints of the ActiveSync back end. Bounded, emptied
        // with the sessions.
        readonly Dictionary<string, string> _sidKeys = new Dictionary<string, string>(StringComparer.Ordinal);
        readonly Dictionary<string, string> _sidDevices = new Dictionary<string, string>(StringComparer.Ordinal);
        const int SidIndexMax = 100000, FileEvidenceSids = 1000, LoggedSids = 10;
        const string SidNoiseReason = "System or health mailbox (resolved from a SID)";
        readonly List<string> _messages = new List<string>();   // "LEVEL|text" lines for the collection log
        long _identityNow;
        SourceJob[] _planned;      // the jobs of the last Plan: the configured log folders and whether each was found

        /// <summary>The lines this collector wrote for the collection log since the last call ("LEVEL|text").</summary>
        public string[] TakeMessages()
        {
            var lines = _messages.ToArray();
            _messages.Clear();
            return lines;
        }

        static bool SidForm(string user) { return user != null && user.Length > 4 && user[0] == 's' && Identity.IsSid(user); }

        long IdentityNow() { return _identityNow > 0 ? _identityNow : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }

        /// <summary>identity_map whole (a few rows per OAuth user), then the entries of the mapping file, which rank last.</summary>
        void LoadIdentities()
        {
            if (!_o.ResolveSids) return;
            _identities = new IdentityMap(CanonicalName, IsSystemIdentity);
            _identityNow = _o.NowMs;
            var hadFile = new HashSet<string>(StringComparer.Ordinal);
            if (_store.HasTable("identity_map"))
                using (var c = _store.Command("SELECT sid,user,status,names,hints,lines,first_ms,last_ms,resolved_ms,applied_ms FROM identity_map;"))
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        var e = new IdentityEntry
                        {
                            Sid = r.GetString(0), User = r.IsDBNull(1) ? null : r.GetString(1), Status = r.GetString(2), Lines = r.GetInt64(5), FirstMs = r.GetInt64(6), LastMs = r.GetInt64(7),
                            ResolvedMs = r.IsDBNull(8) ? (long?)null : r.GetInt64(8), AppliedMs = r.IsDBNull(9) ? (long?)null : r.GetInt64(9)
                        };
                        string names = r.IsDBNull(3) ? null : r.GetString(3);
                        if (names != null && (names.StartsWith(IdentityMap.File + ":", StringComparison.Ordinal) || names.Contains(";" + IdentityMap.File + ":"))) hadFile.Add(e.Sid);
                        IdentityMap.ParseNames(names, e);
                        IdentityMap.ParseHints(r.IsDBNull(4) ? null : r.GetString(4), e);
                        _identities.Load(e);
                    }
            if (_o.ManualIdentities != null)
                foreach (var kv in _o.ManualIdentities)
                {
                    string sid = Identity.User(kv.Key), name = Identity.User(kv.Value);
                    if (!SidForm(sid) || name == null) continue;
                    _identities.Add(sid, IdentityMap.File, name, 1, _o.NowMs, _o.NowMs, _o.NowMs);
                }
            foreach (var e in _identities.Entries)
            {
                if (hadFile.Contains(e.Sid)) e.Dirty = true;
                _identities.Evaluate(e, _o.NowMs);
            }
        }

        /// <summary>The mapping file entries the logs contradict, and the SIDs merged with an account that are no longer resolved.</summary>
        void ReportIdentityWarnings()
        {
            if (_identities == null) return;
            foreach (var e in _identities.Entries.Where(x => x.Ignored != null).OrderBy(x => x.Sid, StringComparer.Ordinal))
                _messages.Add("WARN|Mapping file entry for " + e.Sid + " ignored: " + (e.Status == IdentityMap.Ambiguous ? "the logs name more than one account" :
                    "the logs name " + (e.Status == IdentityMap.Resolved ? e.User : string.Join(", ", EvidenceNames(e, false)))) + ".");
            foreach (var e in _identities.Entries.Where(x => x.Unmerged).OrderBy(x => x.Sid, StringComparer.Ordinal))
            {
                _messages.Add("WARN|Identities: " + e.Sid + " is " + e.Status + (e.Status == IdentityMap.Ambiguous ? " (the logs name " + string.Join(", ", EvidenceNames(e, false)) + ")" : "") +
                    "; its rows of earlier collections stay merged with " + e.User + " and its new rows stay under the SID. Check the requests of " + e.User + ".");
                e.Unmerged = false;
            }
        }

        /// <summary>The names the evidence pairs with the SID, by kind rank (with the mapping file entry when file).</summary>
        static IEnumerable<string> EvidenceNames(IdentityEntry e, bool file)
        {
            return IdentityMap.Kinds.Where(k => (file || k != IdentityMap.File) && e.Names.ContainsKey(k))
                .SelectMany(k => e.Names[k].Keys.OrderBy(n => n, StringComparer.Ordinal)).Distinct(StringComparer.Ordinal);
        }

        /// <summary>
        /// Every SID-form user already stored gets an entry (unresolved until evidence names it), so that the status lists it: one seek per
        /// user of ix_usage_user in the range of the SIDs, and its totals.
        /// </summary>
        void RegisterStoredSids()
        {
            if (_identities == null || _store.ReadOnly) return;
            using (var c = _store.Command("SELECT user FROM access_usage WHERE user > @after AND user < 's-1.' ORDER BY user LIMIT 1;"))
            using (var totals = _store.Command("SELECT SUM(requests), MIN(first_ms), MAX(last_ms) FROM access_usage WHERE user=@u;"))
            {
                var after = c.Parameters.Add("@after", SqliteType.Text);
                var u = totals.Parameters.Add("@u", SqliteType.Text);
                after.Value = "s-1-";
                while (true)
                {
                    var user = c.ExecuteScalar() as string;
                    if (user == null) break;
                    after.Value = user;
                    if (!SidForm(user) || _identities.Has(user)) continue;
                    u.Value = user;
                    using (var r = totals.ExecuteReader())
                    {
                        if (!r.Read() || r.IsDBNull(0)) continue;
                        var e = new IdentityEntry { Sid = user, Lines = r.GetInt64(0), FirstMs = r.GetInt64(1), LastMs = r.GetInt64(2), Dirty = true };
                        _identities.Load(e);
                        _identities.Evaluate(e, _o.NowMs);
                    }
                }
            }
        }

        /// <summary>
        /// After the plan of a collection and before its files are read: the next part of the evidence scan of the HttpProxy lines collected while
        /// no evidence was gathered, then the pass that renames the stored rows of the SIDs resolved; then the SIDs resolved are frozen for the
        /// collection. With ResolveSids $false the scan state is cleared, so that the lines collected meanwhile are scanned once evidence is gathered.
        /// </summary>
        public void PrepareIdentities()
        {
            if (_store.ReadOnly) return;
            if (_identities == null) { ClearEvidenceScan(); return; }
            ContinueEvidenceScan();
            ApplyResolvedIdentities();
            _identities.Freeze();
        }

        const string EvidenceScanKey = "identity_evidence_scan", EvidenceCursorKey = "identity_evidence_scan_cursor";

        string StoredMetadata(string key)
        {
            using (var c = _store.Command("SELECT value FROM metadata WHERE key=@k;"))
            {
                c.Parameters.AddWithValue("@k", key);
                return c.ExecuteScalar() as string;
            }
        }

        void ClearEvidenceScan()
        {
            using (var c = _store.Command("SELECT COUNT(*) FROM metadata WHERE key IN (@a,@b);"))
            {
                c.Parameters.AddWithValue("@a", EvidenceScanKey); c.Parameters.AddWithValue("@b", EvidenceCursorKey);
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) == 0) return;
            }
            using (var tx = _store.Begin())
            using (var c = _store.Command("DELETE FROM metadata WHERE key IN (@a,@b);", tx))
            {
                c.Parameters.AddWithValue("@a", EvidenceScanKey); c.Parameters.AddWithValue("@b", EvidenceCursorKey);
                c.ExecuteNonQuery();
                tx.Commit();
            }
        }

        /// <summary>
        /// Position of the evidence scan: the files it covers (source_file ids up to Bound, lines logged before BeforeMs: what was collected before
        /// evidence was gathered) and, per server, the last file id done. Text "bound=12;before=1793000000000;EXCH01=7;EXCH02=12".
        /// </summary>
        sealed class EvidenceScan
        {
            public long Bound, BeforeMs;
            public readonly Dictionary<string, long> Done = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);

            public long DoneOf(string server) { long id; return Done.TryGetValue(server, out id) ? id : 0; }

            public static EvidenceScan Parse(string text)
            {
                if (string.IsNullOrEmpty(text)) return null;
                var s = new EvidenceScan();
                foreach (var part in text.Split(';'))
                {
                    int eq = part.LastIndexOf('=');
                    long v;
                    if (eq <= 0 || !long.TryParse(part.Substring(eq + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) continue;
                    string k = part.Substring(0, eq);
                    if (k == "bound") s.Bound = v; else if (k == "before") s.BeforeMs = v; else s.Done[k] = v;
                }
                return s.Bound > 0 && s.BeforeMs > 0 ? s : null;
            }

            public override string ToString()
            {
                return "bound=" + Bound.ToString(CultureInfo.InvariantCulture) + ";before=" + BeforeMs.ToString(CultureInfo.InvariantCulture) +
                    string.Concat(Done.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase).Select(x => ";" + x.Key + "=" + x.Value.ToString(CultureInfo.InvariantCulture)));
            }
        }

        /// <summary>
        /// The ActiveSync, OWA and ECP HttpProxy lines collected while no evidence was gathered (the files known when evidence gathering started,
        /// up to their stored read position, lines logged before that start) are read again for their evidence only; nothing else is taken from
        /// them. Bounded: at most Collection.EvidenceRescanMBPerRun per collection (the file that crosses it is read whole), in source_file order,
        /// with one position per server, so that it finishes over several collections; the files of a configured server whose log folder the
        /// plan did not find wait for a collection that finds it; the files of a server or folder no longer configured, or older than the
        /// retention, are skipped. The scan is not started when no SID stored is unresolved, and ends when every file is done or every SID stored is
        /// resolved (metadata identity_evidence_scan); the position and the evidence gathered are written in one transaction.
        /// </summary>
        void ContinueEvidenceScan()
        {
            if (StoredMetadata(EvidenceScanKey) != null) return;
            var scan = EvidenceScan.Parse(StoredMetadata(EvidenceCursorKey));
            Func<bool> needed = () => _identities.Entries.Any(e => e.Status == IdentityMap.Unresolved && e.Lines > 0);
            if (scan == null)
            {
                long bound;
                using (var c = _store.Command("SELECT COALESCE(MAX(id),0) FROM source_file;")) bound = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
                if (bound == 0 || !needed()) { SaveEvidenceScan(null); return; }
                scan = new EvidenceScan { Bound = bound, BeforeMs = _o.NowMs };
            }
            else if (!needed())
            {
                SaveEvidenceScan(null);
                _messages.Add("INFO|Identities: evidence scan of the lines already collected ended: every SID stored is resolved or ambiguous.");
                return;
            }
            if (_planned == null) return;
            var folders = _planned.Where(j => string.Equals(j.Kind, "HttpProxy", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(j.Folder)).ToList();
            var files = new List<Tuple<long, string, string, long, long>>();
            using (var c = _store.Command("SELECT id, server, path, offset, COALESCE(last_write_ms,0) FROM source_file WHERE kind='HttpProxy' AND offset > 0 AND id <= @b ORDER BY id;"))
            {
                c.Parameters.AddWithValue("@b", scan.Bound);
                using (var r = c.ExecuteReader())
                    while (r.Read()) files.Add(Tuple.Create(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetInt64(3), r.GetInt64(4)));
            }
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var memo = new Memo { Days = new DayCache(_o.Zone) };
            var held = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            long lines = 0, bytes = 0, budget = Math.Max(0, _o.EvidenceRescanBytesPerRun);
            int read = 0, missing = 0, failed = 0, left = 0;
            bool full = false;
            foreach (var f in files)
            {
                long id = f.Item1; string server = f.Item2, path = f.Item3;
                if (id <= scan.DoneOf(server)) continue;
                string folder = Path.GetFileName(Path.GetDirectoryName(path) ?? "");
                bool evidence = folder.Equals("Eas", StringComparison.OrdinalIgnoreCase) || folder.Equals("Owa", StringComparison.OrdinalIgnoreCase) || folder.Equals("Ecp", StringComparison.OrdinalIgnoreCase);
                var job = folders.FirstOrDefault(j => string.Equals(j.Server, server, StringComparison.OrdinalIgnoreCase) && Under(path, j.Folder));
                bool eligible = evidence && job != null && f.Item5 >= _o.RetentionCutoffMs;
                // A server whose folder was not found, and every server once the budget is spent, keep their position: nothing after it is marked done.
                if (full || held.Contains(server)) { if (eligible) left++; continue; }
                if (!eligible) { scan.Done[server] = id; continue; }
                if (!job.FolderFound) { held.Add(server); left++; continue; }
                if (read > 0 && bytes >= budget) { full = true; left++; continue; }
                if (!File.Exists(path)) { missing++; scan.Done[server] = id; continue; }
                var c = new ParseContext("HttpProxy", 0)
                {
                    Result = new FileResult { Server = server, Kind = "HttpProxy", Path = path }, Server = server, Path = path, StartOffset = 0,
                    EvidenceOnly = true, EvidenceLimit = f.Item4, EvidenceBeforeMs = scan.BeforeMs, Split = memo.Split, Memo = memo, Days = memo.Days
                };
                try { ParseHttpProxy(c); }
                catch (IOException) { failed++; scan.Done[server] = id; continue; }
                catch (UnauthorizedAccessException) { failed++; scan.Done[server] = id; continue; }
                memo.Trim();
                read++; lines += c.Result.Lines; bytes += f.Item4;
                MergeEvidence(c);
                scan.Done[server] = id;
            }
            bool complete = left == 0 || !needed();
            SaveEvidenceScan(complete ? null : scan);
            _messages.Add("INFO|" + string.Format(CultureInfo.InvariantCulture,
                "Identities: evidence read again from {0} ActiveSync, OWA and ECP HttpProxy file(s) already collected ({1:N0} lines, {2:N1} MB, {3:0.0} s; {4} no longer on disk, {5} unreadable); {6}; {7} SID(s) resolved, {8} unresolved, {9} ambiguous",
                read, lines, bytes / 1048576.0, clock.Elapsed.TotalSeconds, missing, failed,
                complete ? "the evidence scan is complete" : left.ToString(CultureInfo.InvariantCulture) + " file(s) left for the next collections" + (held.Count > 0 ? " (log folder not found on " + string.Join(", ", held) + ")" : ""),
                _identities.Entries.Count(e => e.Status == IdentityMap.Resolved && e.Lines > 0), _identities.Entries.Count(e => e.Status == IdentityMap.Unresolved), _identities.Entries.Count(e => e.Status == IdentityMap.Ambiguous)));
        }

        static bool Under(string path, string folder)
        {
            string root = folder.TrimEnd('\\', '/');
            return path.Length > root.Length + 1 && path.StartsWith(root, StringComparison.OrdinalIgnoreCase) && (path[root.Length] == '\\' || path[root.Length] == '/');
        }

        /// <summary>
        /// The scan position (null: the scan is done, metadata identity_evidence_scan) and every identity changed, in one transaction. A failure is
        /// logged and leaves the identities to the next write; the next collection reads the same files again.
        /// </summary>
        void SaveEvidenceScan(EvidenceScan scan)
        {
            List<IdentityEntry> flushed = null;
            using (var writer = new Writer(_store))
            {
                _writer = writer;
                try
                {
                    using (var tx = _store.Begin())
                    {
                        writer.Use(tx);
                        try
                        {
                            flushed = FlushIdentities();
                            using (var c = _store.Command("INSERT INTO metadata(key,value) VALUES(@k,@v) ON CONFLICT(key) DO UPDATE SET value=excluded.value;", tx))
                            {
                                c.Parameters.AddWithValue("@k", scan == null ? EvidenceScanKey : EvidenceCursorKey);
                                c.Parameters.AddWithValue("@v", scan == null ? _o.NowMs.ToString(CultureInfo.InvariantCulture) : scan.ToString());
                                c.ExecuteNonQuery();
                            }
                            if (scan == null)
                                using (var c = _store.Command("DELETE FROM metadata WHERE key=@k;", tx)) { c.Parameters.AddWithValue("@k", EvidenceCursorKey); c.ExecuteNonQuery(); }
                            tx.Commit();
                        }
                        catch (Exception ex)
                        {
                            try { tx.Rollback(); } catch (Exception) { }
                            if (flushed != null) foreach (var e in flushed) e.Dirty = true;
                            _messages.Add("WARN|Identities: the position of the evidence scan could not be saved (" + ex.Message + "); the next collection reads the same files again.");
                        }
                    }
                }
                finally { _writer = null; }
            }
        }

        /// <summary>Parse thread, HttpProxy: what the line says of a SID (a name with the SID as anchor mailbox; the account a SID's device reported).</summary>
        void GatherEvidence(ParseContext c, string user, string protocol, string anchor, string stem, string query, int iIsAuth, long t)
        {
            bool eas = protocol.Equals("Eas", StringComparison.OrdinalIgnoreCase);
            if (user[0] == 's' && Identity.IsSid(user))
            {
                if (!eas) return;
                string reported = Identity.QueryValue(query, "User");
                if (reported != null) AddFileEvidence(c, user, null, reported.Trim().ToLowerInvariant(), t);
                return;
            }
            if (anchor == null || anchor.Length < 9 || (anchor[0] != 'S' && anchor[0] != 's')) return;
            // ActiveSync syncs the caller's own mailbox; OWA and ECP too, except an explicit logon to another mailbox (/owa/<smtp>/...).
            if (!eas && !((protocol.Equals("Owa", StringComparison.OrdinalIgnoreCase) || protocol.Equals("Ecp", StringComparison.OrdinalIgnoreCase)) && !ExplicitLogon(stem))) return;
            if (!string.Equals(c.Split.Get(iIsAuth), "True", StringComparison.OrdinalIgnoreCase)) return;
            string sid = Identity.AnchorSid(anchor);
            if (sid != null) AddFileEvidence(c, sid, user, null, t);
        }

        /// <summary>"/owa/alice@contoso.com/..." opens another mailbox: its second segment is an address.</summary>
        static bool ExplicitLogon(string stem)
        {
            if (string.IsNullOrEmpty(stem)) return false;
            int a = stem.IndexOf('/', 1);
            if (a < 0) return false;
            int b = stem.IndexOf('/', a + 1);
            string segment = b < 0 ? stem.Substring(a + 1) : stem.Substring(a + 1, b - a - 1);
            return segment.IndexOf('@') >= 0;
        }

        static void AddFileEvidence(ParseContext c, string sid, string name, string hint, long t)
        {
            if (c.Evidence == null) c.Evidence = new Dictionary<string, FileEvidence>(StringComparer.Ordinal);
            FileEvidence e;
            if (!c.Evidence.TryGetValue(sid, out e))
            {
                if (c.Evidence.Count >= FileEvidenceSids) return;
                e = new FileEvidence();
                c.Evidence[sid] = e;
            }
            if (t < e.FirstMs) e.FirstMs = t;
            if (t > e.LastMs) e.LastMs = t;
            var d = name != null ? (e.Names ?? (e.Names = new Dictionary<string, long>(StringComparer.Ordinal))) : (e.Hints ?? (e.Hints = new Dictionary<string, long>(StringComparer.Ordinal)));
            string key = name ?? hint;
            long n;
            if (!d.TryGetValue(key, out n) && d.Count >= (name != null ? IdentityMap.MaxNames : IdentityMap.MaxHints)) return;
            d[key] = n + 1;
        }

        /// <summary>Apply thread: the evidence of a file into the identity map (it takes effect at the end of the collection).</summary>
        void MergeEvidence(ParseContext c)
        {
            if (_identities == null || c.Evidence == null) return;
            long now = IdentityNow();
            foreach (var kv in c.Evidence)
            {
                if (kv.Value.Names != null) foreach (var n in kv.Value.Names) _identities.Add(kv.Key, IdentityMap.Anchor, n.Key, n.Value, kv.Value.FirstMs, kv.Value.LastMs, now);
                if (kv.Value.Hints != null) foreach (var h in kv.Value.Hints) _identities.Hint(kv.Key, h.Key, h.Value, kv.Value.FirstMs, kv.Value.LastMs);
            }
            c.Evidence = null;
        }

        /// <summary>Apply thread: a record whose user is a SID (before Canonical).</summary>
        void ObserveSid(AccessRecord r)
        {
            _identities.Observe(r.User, r.TimeMs);
            if (r.DeviceId == null || !string.Equals(r.Protocol, "Eas", StringComparison.OrdinalIgnoreCase)) return;
            string known;
            if (!_sidDevices.TryGetValue(r.DeviceId, out known)) { if (_sidDevices.Count < SidIndexMax) _sidDevices[r.DeviceId] = r.User; }
            else if (known != null && !string.Equals(known, r.User, StringComparison.Ordinal)) _sidDevices[r.DeviceId] = null;
        }

        /// <summary>A MAPI session under a SID whose key carries the mailbox GUID and the Outlook instance: the key the MAPI back end joins on.</summary>
        void IndexSidSession(ClientSession s)
        {
            if (_identities == null || s.Key == null || !string.Equals(s.Protocol, "Mapi", StringComparison.OrdinalIgnoreCase) || !SidForm(s.User)) return;
            int skip = s.Day.Length + 1 + s.User.Length + 1;
            if (s.Key.Length < skip || string.CompareOrdinal(s.Key, 0, s.Day + "|" + s.User + "|", 0, skip) != 0) return;
            string rest = s.Key.Substring(skip);
            // "Mapi|ip|mailbox|instance": without the mailbox GUID or the instance, sessions of different people on one address share the key.
            var parts = rest.Split('|');
            if (parts.Length != 4 || parts[2].Length == 0 || parts[3].Length == 0) return;
            string k = s.Day + "|" + rest, known;
            if (!_sidKeys.TryGetValue(k, out known)) { if (_sidKeys.Count < SidIndexMax) _sidKeys[k] = s.User; }
            else if (known != null && !string.Equals(known, s.User, StringComparison.Ordinal)) _sidKeys[k] = null;
        }

        /// <summary>Writes one identity (the transaction of the writer in use).</summary>
        void FlushIdentity(IdentityEntry e)
        {
            var w = _writer.IdentityUpsert;
            w.Set(0, e.Sid); w.Set(1, e.User); w.Set(2, e.Status); w.Set(3, IdentityMap.NamesText(e)); w.Set(4, IdentityMap.HintsText(e));
            w.Set(5, e.Lines); w.Set(6, e.FirstMs); w.Set(7, e.LastMs); w.Set(8, e.User != null ? (object)e.ResolvedMs : null); w.Set(9, e.AppliedMs);
            w.Run();
            e.Dirty = false;
        }

        /// <summary>Writes the identities changed since the last write (the transaction of the writer in use); returns them, for a rollback.</summary>
        List<IdentityEntry> FlushIdentities()
        {
            var flushed = new List<IdentityEntry>();
            if (_identities == null) return flushed;
            foreach (var e in _identities.Entries)
            {
                if (!e.Dirty) continue;
                FlushIdentity(e);
                flushed.Add(e);
            }
            return flushed;
        }

        sealed class RenameCounts { public long Usage, Clients, Events, Sessions, Merged, NoiseLines; }

        /// <summary>A row of a table the pass renames is stored under the user (seeks on the user indexes).</summary>
        bool HasRows(SqliteTransaction tx, string user)
        {
            using (var c = _store.Command("SELECT EXISTS(SELECT 1 FROM access_usage WHERE user=@x) OR EXISTS(SELECT 1 FROM client_session WHERE user=@x) " +
                "OR EXISTS(SELECT 1 FROM access_client WHERE user=@x) OR EXISTS(SELECT 1 FROM access_event WHERE user=@x);", tx))
            {
                c.Parameters.AddWithValue("@x", user);
                return Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0;
            }
        }

        /// <summary>
        /// The rows stored under the SIDs resolved and not applied yet are renamed to their account and merged exactly with the account's rows, with the
        /// collector's own rules: the daily aggregates by the upsert of the writer, the client rows by the same merge, the sessions by the merge of a
        /// request that bridges two sessions. After a SID resolved to "domain\sam", the stored "sam" and "sam@..." forms of that account are renamed the
        /// same way. A SID resolved to a system account has its rows removed and counted as noise. A SID with no row stored (paired in advance: the
        /// account's own lines name it before any token request) is marked applied and nothing is renamed. One transaction per SID, which writes
        /// that SID's identity row; a failure leaves it for the next collection. The other identities are written in a transaction of their own.
        /// Start and end of every collection.
        /// </summary>
        void ApplyResolvedIdentities()
        {
            if (_identities == null || _store.ReadOnly) return;
            long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var work = _identities.Entries.Where(e => e.Status == IdentityMap.Resolved && e.User != null && e.AppliedMs == null).OrderBy(e => e.Sid, StringComparer.Ordinal).ToList();
            if (work.Count == 0 && !_identities.Entries.Any(e => e.Dirty)) return;
            ResetSessions();
            var total = new RenameCounts();
            var resolved = new List<string>();
            int removed = 0;
            using (var writer = new Writer(_store))
            {
                _writer = writer;
                try
                {
                    foreach (var e in work)
                    {
                        string target = CanonicalName(e.User);
                        bool system = IsSystemIdentity(target), stored = false;
                        var counts = new RenameCounts();
                        using (var tx = _store.Begin())
                        {
                            _writer.Use(tx);
                            _tx = tx;
                            try
                            {
                                stored = HasRows(tx, e.Sid) || e.Lines > 0;
                                if (stored)
                                {
                                    RenameUser(tx, e.Sid, target, system, counts);
                                    // The other forms too when rows were stored under the SID once: they may hold its rows, renamed to a form the
                                    // account had before ("sam@suffix" before "domain\sam" was known).
                                    if (!system && target.IndexOf('\\') > 0)
                                    {
                                        LearnAccount(target);
                                        string known;
                                        if (_accounts.TryGetValue(Identity.Bare(target), out known) && string.Equals(known, target, StringComparison.Ordinal))
                                            foreach (var form in OtherForms(tx, target)) RenameUser(tx, form, target, false, counts);
                                    }
                                }
                                e.User = target;
                                e.System = system;
                                e.AppliedMs = now;
                                FlushIdentity(e);
                                tx.Commit();
                            }
                            catch (Exception ex)
                            {
                                try { tx.Rollback(); } catch (Exception) { }
                                e.AppliedMs = null;
                                e.Dirty = true;
                                _messages.Add("WARN|Identities: the rows of " + e.Sid + " could not be renamed to " + target + " (" + ex.GetType().Name + ": " + ex.Message + "); the next collection tries again.");
                                continue;
                            }
                            finally { _tx = null; if (stored) ResetSessions(); }
                        }
                        if (!stored) continue;
                        total.Usage += counts.Usage; total.Clients += counts.Clients; total.Events += counts.Events; total.Sessions += counts.Sessions; total.Merged += counts.Merged; total.NoiseLines += counts.NoiseLines;
                        if (system) removed++;
                        else resolved.Add(e.Sid + " -> " + target + ", " + string.Join("+", IdentityMap.Kinds.Where(k => e.Names.ContainsKey(k) && e.Names[k].Count > 0).Take(1)));
                    }
                    if (_identities.Entries.Any(e => e.Dirty))
                    {
                        List<IdentityEntry> flushed = null;
                        using (var tx = _store.Begin())
                        {
                            _writer.Use(tx);
                            try
                            {
                                flushed = FlushIdentities();
                                tx.Commit();
                            }
                            catch (Exception ex)
                            {
                                try { tx.Rollback(); } catch (Exception) { }
                                if (flushed != null) foreach (var e in flushed) e.Dirty = true;
                                _messages.Add("WARN|Identities: the identity map could not be written (" + ex.GetType().Name + ": " + ex.Message + "); the next write tries again.");
                            }
                        }
                    }
                }
                finally { _writer = null; }
            }
            if (resolved.Count > 0 || removed > 0)
                _messages.Add("INFO|" + string.Format(CultureInfo.InvariantCulture, "Identities: {0} SID(s) resolved{1}{2}; rows renamed: {3} usage, {4} client, {5} events, {6} sessions ({7} merged)",
                    resolved.Count, resolved.Count > 0 ? " (" + string.Join("; ", resolved.Take(LoggedSids)) + (resolved.Count > LoggedSids ? "; and " + (resolved.Count - LoggedSids).ToString(CultureInfo.InvariantCulture) + " more" : "") + ")" : "",
                    removed > 0 ? "; " + removed.ToString(CultureInfo.InvariantCulture) + " SID(s) resolved to a system account, " + total.NoiseLines.ToString(CultureInfo.InvariantCulture) + " request(s) removed as noise" : "",
                    total.Usage, total.Clients, total.Events, total.Sessions, total.Merged));
        }

        /// <summary>The stored "sam" and "sam@..." forms of an account "domain\sam" (seeks on ix_usage_user and ix_session_user).</summary>
        List<string> OtherForms(SqliteTransaction tx, string account)
        {
            string bare = Identity.Bare(account);
            var forms = new SortedSet<string>(StringComparer.Ordinal);
            foreach (var table in new[] { "access_usage", "client_session" })
                using (var c = _store.Command("SELECT DISTINCT user FROM " + table + " WHERE user=@b OR (user >= @lo AND user < @hi);", tx))
                {
                    c.Parameters.AddWithValue("@b", bare); c.Parameters.AddWithValue("@lo", bare + "@"); c.Parameters.AddWithValue("@hi", bare + "A");
                    using (var r = c.ExecuteReader()) while (r.Read()) forms.Add(r.GetString(0));
                }
            forms.Remove(account);
            return forms.Where(f => !SidForm(f) && string.Equals(Identity.Bare(f), bare, StringComparison.Ordinal)).ToList();
        }

        /// <summary>Renames (or, for a system account, removes as noise) every stored row of one user; the sessions that then share a key merge.</summary>
        void RenameUser(SqliteTransaction tx, string from, string to, bool system, RenameCounts counts)
        {
            Func<string, SqliteCommand> cmd = sql =>
            {
                var c = _store.Command(sql, tx);
                c.Parameters.AddWithValue("@x", from);
                c.Parameters.AddWithValue("@n", to);
                return c;
            };
            if (system)
            {
                var byServer = new List<Tuple<string, long>>();
                using (var c = cmd("SELECT server, SUM(requests) FROM access_usage WHERE user=@x GROUP BY server;"))
                using (var r = c.ExecuteReader()) while (r.Read()) byServer.Add(Tuple.Create(r.GetString(0), r.GetInt64(1)));
                foreach (var s in byServer)
                {
                    var noise = _writer.Noise;
                    noise.Set(0, _o.RunId); noise.Set(1, s.Item1); noise.Set(2, "HttpProxy"); noise.Set(3, SidNoiseReason); noise.Set(4, s.Item2);
                    noise.Run();
                    counts.NoiseLines += s.Item2;
                }
                using (var c = cmd("DELETE FROM session_step WHERE session_id IN (SELECT id FROM client_session WHERE user=@x);")) c.ExecuteNonQuery();
                using (var c = cmd("DELETE FROM client_session WHERE user=@x;")) counts.Sessions += c.ExecuteNonQuery();
                using (var c = cmd("DELETE FROM access_event WHERE user=@x;")) counts.Events += c.ExecuteNonQuery();
                using (var c = cmd("DELETE FROM access_client WHERE user=@x;")) counts.Clients += c.ExecuteNonQuery();
                using (var c = cmd("DELETE FROM access_usage WHERE user=@x;")) counts.Usage += c.ExecuteNonQuery();
                return;
            }
            // Daily usage: the rows of the SID added to the account's by the writer's own upsert (sums, minimum, maximum, the client of the later row).
            using (var c = cmd("INSERT INTO access_usage(" + Writer.UsageColumns + ") SELECT day,server,@n,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out," +
                "total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent,slow FROM access_usage WHERE user=@x ORDER BY day,server,protocol " + Writer.UsageMerge))
                counts.Usage += c.ExecuteNonQuery();
            using (var c = cmd("DELETE FROM access_usage WHERE user=@x;")) c.ExecuteNonQuery();
            RenameClients(tx, from, to, counts);
            using (var c = cmd("UPDATE access_event SET user=@n WHERE user=@x;")) counts.Events += c.ExecuteNonQuery();
            RenameSessions(tx, from, to, counts, cmd);
        }

        /// <summary>
        /// access_client: a row of the SID changes owner, or merges into the account's row of the same key as the writer's upsert would (the SID's row
        /// as the incoming one); the software of the account's row is kept, else the SID's.
        /// </summary>
        void RenameClients(SqliteTransaction tx, string from, string to, RenameCounts counts)
        {
            var rows = new List<object[]>();
            using (var c = _store.Command("SELECT day,protocol,client_ip,user_agent,device_id,auth_type,device_type,software,requests,failures,first_ms,last_ms,servers FROM access_client WHERE user=@x;", tx))
            {
                c.Parameters.AddWithValue("@x", from);
                using (var r = c.ExecuteReader()) while (r.Read()) { var row = new object[13]; r.GetValues(row); rows.Add(row); }
            }
            const string key = " WHERE day=@d AND user=@u AND protocol=@p AND client_ip=@ip AND user_agent=@ua AND device_id=@dev AND auth_type=@a;";
            Action<SqliteCommand, object[], string> bind = (c, row, user) =>
            {
                c.Parameters.AddWithValue("@d", row[0]); c.Parameters.AddWithValue("@u", user); c.Parameters.AddWithValue("@p", row[1]); c.Parameters.AddWithValue("@ip", row[2]);
                c.Parameters.AddWithValue("@ua", row[3]); c.Parameters.AddWithValue("@dev", row[4]); c.Parameters.AddWithValue("@a", row[5]);
            };
            foreach (var x in rows)
            {
                object[] t = null;
                using (var c = _store.Command("SELECT device_type,software,requests,failures,first_ms,last_ms,servers FROM access_client" + key, tx))
                {
                    bind(c, x, to);
                    using (var r = c.ExecuteReader()) if (r.Read()) { t = new object[7]; r.GetValues(t); }
                }
                if (t == null)
                {
                    using (var c = _store.Command("UPDATE access_client SET user=@n" + key, tx)) { bind(c, x, from); c.Parameters.AddWithValue("@n", to); c.ExecuteNonQuery(); }
                }
                else
                {
                    // The writer's rule, the SID's row as the incoming one: its device type, else the account's.
                    object deviceType = x[6] is DBNull ? t[0] : x[6];
                    var servers = (t[6] as string ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).ToList();
                    foreach (var s in (x[12] as string ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) if (!servers.Contains(s, StringComparer.Ordinal)) servers.Add(s);
                    using (var c = _store.Command("UPDATE access_client SET requests=requests+@r, failures=failures+@f, device_type=@dt, software=COALESCE(software,@sw), first_ms=MIN(first_ms,@fm), last_ms=MAX(last_ms,@lm), servers=@s" + key, tx))
                    {
                        bind(c, x, to);
                        c.Parameters.AddWithValue("@r", x[8]); c.Parameters.AddWithValue("@f", x[9]); c.Parameters.AddWithValue("@dt", deviceType); c.Parameters.AddWithValue("@sw", x[7]);
                        c.Parameters.AddWithValue("@fm", x[10]); c.Parameters.AddWithValue("@lm", x[11]); c.Parameters.AddWithValue("@s", servers.Count == 0 ? (object)DBNull.Value : string.Join(",", servers));
                        c.ExecuteNonQuery();
                    }
                    using (var c = _store.Command("DELETE FROM access_client" + key, tx)) { bind(c, x, from); c.ExecuteNonQuery(); }
                }
                counts.Clients++;
            }
        }

        /// <summary>
        /// client_session: user and key renamed (the key is "day|user|rest"); then the sessions of one key that overlap within SessionIdleMinutes merge,
        /// the stored session with the smaller id surviving, as FindSession merges the sessions a request bridges (steps re-pointed, absorbed rows deleted).
        /// </summary>
        void RenameSessions(SqliteTransaction tx, string from, string to, RenameCounts counts, Func<string, SqliteCommand> cmd)
        {
            const string matches = " WHERE user=@x AND substr(skey,1,length(day)+length(@x)+2) = day||'|'||@x||'|'";
            const string renamed = "day||'|'||@n||'|'||substr(skey,length(day)+length(@x)+3)";
            var keys = new List<string>();
            using (var c = cmd("SELECT DISTINCT " + renamed + " FROM client_session" + matches + ";"))
            using (var r = c.ExecuteReader()) while (r.Read()) keys.Add(r.GetString(0));
            if (keys.Count == 0) return;
            using (var c = cmd("UPDATE client_session SET user=@n, skey=" + renamed + matches + ";")) counts.Sessions += c.ExecuteNonQuery();
            var touched = new HashSet<ClientSession>();
            long idle = _o.SessionIdleMs;
            foreach (var key in keys)
            {
                var list = LoadSessions(key);
                if (list.Count < 2) continue;
                list.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.Id.CompareTo(b.Id));
                var current = list[0];
                for (int i = 1; i < list.Count; i++)
                {
                    var s = list[i];
                    if (s.Start > current.End + idle) { current = s; continue; }
                    var keep = Older(s, current) ? s : current;
                    var drop = ReferenceEquals(keep, s) ? current : s;
                    Merge(keep, drop);
                    touched.Remove(drop);
                    touched.Add(keep);
                    counts.Merged++;
                    current = keep;
                }
            }
            FlushSessions(tx, touched);
        }

        // ================================================================ request enrichment (parse threads)

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

        // ================================================================ sessions in memory (apply thread)

        static string SessionKey(string day, string user, string protocol, string ip, string agent, string device, string mailboxGuid, string instance)
        {
            return day + "|" + user + "|" + SessionKeyRest(protocol, ip, agent, device, mailboxGuid, instance);
        }

        /// <summary>Session key after "day|user|" (computed by the parse threads; the account is made canonical by the apply thread).</summary>
        static string SessionKeyRest(string protocol, string ip, string agent, string device, string mailboxGuid, string instance)
        {
            string p = protocol ?? "Other";
            switch (p.ToLowerInvariant())
            {
                // ActiveSync: the user agent identifies the device model and OS build; OPTIONS requests carry no DeviceId.
                case "eas": return "Eas|ua:" + Identity.Cap(agent, 120);
                case "mapi": return "Mapi|" + ip + "|" + mailboxGuid + "|" + instance;
                case "imap4":
                case "pop3": return p + "|" + ip;
                default: return p + "|" + ip + "|" + Identity.Cap(agent, 120);
            }
        }

        void ResetSessions()
        {
            _sessions.Clear();
            _byUser.Clear();
            _sidKeys.Clear();
            _sidDevices.Clear();
            // The database is the reference again: the sessions committed by this run are found there.
            _storedDays.Clear();
            try { LoadStoredDays(); } catch (SqliteException) { }
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
            IndexSidSession(s);
        }

        void Unindex(ClientSession s)
        {
            List<ClientSession> list;
            string k = s.Day + "|" + s.User + "|" + s.Protocol;
            if (!_byUser.TryGetValue(k, out list)) return;
            list.Remove(s);
            if (list.Count == 0) _byUser.Remove(k);
        }

        /// <summary>Session of a key that contains the time t (with the idle gap); bridging sessions are merged; a new one otherwise.</summary>
        ClientSession FindSession(string key, long t, Func<ClientSession> create)
        {
            List<ClientSession> list;
            if (!_sessions.TryGetValue(key, out list))
            {
                // Only the days that have sessions in the database are looked up there (a first collection, or a new day,
                // creates its sessions without one query per key).
                int bar = key.IndexOf('|');
                list = bar > 0 && _storedDays.Contains(key.Substring(0, bar)) ? LoadSessions(key) : new List<ClientSession>();
                _sessions[key] = list;
            }
            long idle = _o.SessionIdleMs;
            ClientSession keep = null;
            int hits = 0;
            foreach (var s in list)
            {
                if (t < s.Start - idle || t > s.End + idle) continue;
                hits++;
                // The oldest stored session survives a merge.
                if (keep == null || Older(s, keep)) keep = s;
            }
            if (keep == null) { var created = create(); list.Add(created); return created; }
            if (hits > 1)
            {
                // t fills the gap between sessions: they become one.
                foreach (var drop in list.Where(s => !ReferenceEquals(s, keep) && t >= s.Start - idle && t <= s.End + idle).ToList())
                {
                    Merge(keep, drop);
                    list.Remove(drop);
                    Unindex(drop);
                }
            }
            return keep;
        }

        static bool Older(ClientSession a, ClientSession b)
        {
            int ra = a.Id > 0 ? 0 : 1, rb = b.Id > 0 ? 0 : 1;
            return ra != rb ? ra < rb : a.Id < b.Id;
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
            foreach (var kv in from.Auths) Inc(into.Auths, kv.Key, kv.Value);
            into.Mailbox = into.Mailbox ?? from.Mailbox; into.UserAgent = into.UserAgent ?? from.UserAgent; into.DeviceId = into.DeviceId ?? from.DeviceId;
            into.DeviceType = into.DeviceType ?? from.DeviceType; into.Software = into.Software ?? from.Software; into.Mode = into.Mode ?? from.Mode;
            into.BackEndNote = into.BackEndNote ?? from.BackEndNote;
            into.Steps.AddRange(from.Steps);
            from.Steps.Clear();
            if (_batch != null) { _batch.Touched.Remove(from); _batch.Touched.Add(into); }
        }

        static long MinPositive(long a, long b) { return a <= 0 ? b : b <= 0 ? a : Math.Min(a, b); }

        static void Inc(Dictionary<string, long> d, string key, long n)
        {
            if (string.IsNullOrEmpty(key)) return;
            long v; d.TryGetValue(key, out v); d[key] = v + n;
        }

        struct JoinEntry { public string Key; public long Value; public int Index; }

        // Count descending, then key (ordinal), then the dictionary order: the order of a stable sort on count and key.
        static readonly Comparison<JoinEntry> JoinOrder = (a, b) =>
        {
            int c = b.Value.CompareTo(a.Value);
            if (c == 0) c = string.CompareOrdinal(a.Key, b.Key);
            return c != 0 ? c : a.Index.CompareTo(b.Index);
        };

        // Join (apply thread): the entries and the text, reused from one session to the next.
        readonly List<JoinEntry> _joinEntries = new List<JoinEntry>();
        readonly StringBuilder _joinText = new StringBuilder();

        /// <summary>"key=count;..." by count descending then key (ordinal); null when empty.</summary>
        string Join(Dictionary<string, long> d)
        {
            if (d.Count == 0) return null;
            var entries = _joinEntries;
            entries.Clear();
            foreach (var kv in d) entries.Add(new JoinEntry { Key = kv.Key, Value = kv.Value, Index = entries.Count });
            entries.Sort(JoinOrder);
            var text = _joinText.Clear();
            for (int i = 0; i < entries.Count; i++)
            {
                if (i > 0) text.Append(';');
                text.Append(entries[i].Key.Replace(";", ",").Replace("=", ":")).Append('=').Append(entries[i].Value.ToString(CultureInfo.InvariantCulture));
            }
            entries.Clear();
            return text.ToString();
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

        SqliteCommand _loadSessions;

        List<ClientSession> LoadSessions(string key)
        {
            var list = new List<ClientSession>();
            if (_loadSessions == null || _loadSessions.Connection == null)
            {
                _loadSessions = _store.Command(@"SELECT id,day,start_ms,end_ms,user,protocol,mailbox,client_ip,user_agent,device_id,device_type,software,client_mode,front_ends,back_ends,
requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses,
first_error,last_error,backend,connections,auth_modes FROM client_session WHERE skey=@k;");
                _loadSessions.Parameters.Add("@k", SqliteType.Text);
            }
            var c = _loadSessions;
            c.Transaction = _tx;
            c.Parameters[0].Value = key;
            using (var r = c.ExecuteReader())
            {
                Func<int, string> s = i => Packed.Text(r.GetValue(i));
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
                    Split(s(27), x.Actions); Split(s(28), x.Statuses); Split(s(33), x.Auths);
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
            return list;
        }

        /// <summary>
        /// Sessions already written and not touched by the files still to come are dropped from memory once the
        /// collection has moved on by more than two days (a long backfill stays small in memory). A session needed
        /// again is read back from the database.
        /// </summary>
        /// <summary>Session keys kept in memory before the old ones are evicted (lowered by the tests).</summary>
        public static int EvictAboveKeys = 20000;

        void EvictSessions(List<ParsedFile> files)
        {
            if (_sessions.Count < EvictAboveKeys || files.Count == 0) return;
            // Only the files that feed the sessions: the SMTP and message tracking files are read beside them (ParseSchedule) and may be
            // ahead in time; they would evict sessions that the next files still extend (read back from the database: same result, slower).
            long newest = 0;
            foreach (var p in files) if (p.Work.Group != 1 && p.Result.LastMs > newest) newest = p.Result.LastMs;
            if (newest == 0) return;
            // A request extends a session only within SessionIdleMinutes of its end, and the files are read in the order
            // of their last write: a session that ended hours before the newest line read stops growing. An evicted
            // session is read again from the database if a later line needs it (back-end logs, late files).
            long limit = newest - Math.Max(6 * 3600000L, 4 * _o.SessionIdleMs);
            var drop = new List<string>();
            foreach (var kv in _sessions)
            {
                bool old = true;
                foreach (var s in kv.Value) if (s.Id == 0 || s.End >= limit || s.Steps.Count > 0 || s.Absorbed.Count > 0) { old = false; break; }
                if (old) drop.Add(kv.Key);
            }
            foreach (var k in drop)
            {
                foreach (var s in _sessions[k]) { Unindex(s); _storedDays.Add(s.Day); }
                _sessions.Remove(k);
            }
        }

        /// <summary>Days that have client sessions in the database and not only in memory.</summary>
        readonly HashSet<string> _storedDays = new HashSet<string>(StringComparer.Ordinal);

        void LoadStoredDays()
        {
            // A session key starts with its day: one seek per stored day in ix_session_key. SELECT DISTINCT day read
            // every session (24 s at the start of each collection on a hard disk of the lab).
            using (var c = _store.Command("SELECT skey FROM client_session WHERE skey > @after ORDER BY skey LIMIT 1;"))
            {
                var after = c.Parameters.Add("@after", SqliteType.Text);
                after.Value = "";
                for (int guard = 0; guard < 100000; guard++)
                {
                    var key = c.ExecuteScalar() as string;
                    if (key == null) break;
                    int bar = key.IndexOf('|');
                    string day = bar > 0 ? key.Substring(0, bar) : key;
                    _storedDays.Add(day);
                    after.Value = day + "}";   // '}' sorts right after '|': past every key of this day
                }
            }
        }

        static void Extend(ClientSession s, long t)
        {
            if (t < s.Start) s.Start = t;
            if (t > s.End) s.End = t;
        }

        void Touch(ClientSession s) { _batch.Touched.Add(s); }

        void AddToSession(ApplyFile f, AccessRecord r, bool failure, bool slow)
        {
            if (r.FromBackEnd && r.Session == null) return;
            var s = r.Session;
            if (s == null)
            {
                string day = r.Day;
                string key = day + "|" + r.User + "|" + r.KeyRest;
                s = FindSession(key, r.TimeMs, () => NewSession(key, day, r.User, r.Protocol));
            }
            Touch(s);
            Extend(s, r.TimeMs);
            s.Requests++;
            if (failure)
            {
                s.Failures++;
                string why = r.Why;
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
            string front = r.FromBackEnd ? null : f.Server;
            string back = r.Back;
            if (front != null) s.Fronts.Add(front);
            if (back != null) s.Backs.Add(back);
            if (!r.FromBackEnd && r.ClientIp != null && s.Ips.Count < 20 && !s.Ips.Contains(r.ClientIp)) s.Ips.Add(r.ClientIp);
            if (s.UserAgent == null && r.UserAgent != null) s.UserAgent = r.Agent;
            if (s.DeviceId == null && r.DeviceId != null) s.DeviceId = r.DeviceId;
            if (s.DeviceType == null && r.DeviceType != null) s.DeviceType = r.DeviceType;
            if (s.Mailbox == null && r.Mailbox != null) s.Mailbox = r.Mailbox;
            Inc(s.Actions, r.Action ?? "?", 1);
            Inc(s.Statuses, StatusLabel(r), 1);
            if (!r.FromBackEnd) Inc(s.Auths, r.AuthToken, 1);
            string action = r.Action ?? "?";
            bool notable = failure || slow || s.Requests <= _o.SessionDetailRequests || Milestones.Contains(action) || s.LastWasFailure || r.Detail != null;
            // Most requests of a long session are folded into the last batch step: the step object is created only when it is kept.
            if (!FoldStep(s, f.FileId, r.TimeMs, front, back, action, failure ? 1 : 0, r.DurationMs, notable))
            {
                var step = new SessionStep
                {
                    T = r.TimeMs, T2 = r.TimeMs, Front = front, Back = back, Action = action, Status = r.Status, TotalMs = r.DurationMs, MaxMs = r.DurationMs,
                    Failures = failure ? 1 : 0, Detail = failure ? r.Why : slow ? "Slow request" : r.Detail, RequestId = r.RequestId, Source = r.FromBackEnd ? "BE" : "FE",
                    FileId = f.FileId, Needle = r.Needle ?? r.RequestId, Needle2 = r.Needle2
                };
                AddStep(s, step, notable);
            }
            s.LastWasFailure = failure;
        }

        /// <summary>
        /// The folding of AddStep for a step of one request (count 1) that is not created yet: true when the request was added to the last
        /// batch step of its file, false when AddStep must be called with the step (same rules, same order).
        /// </summary>
        bool FoldStep(ClientSession s, long fileId, long t, string front, string back, string action, int failures, long ms, bool notable)
        {
            FileSteps fs;
            if (!s.PerFile.TryGetValue(fileId, out fs)) return false;
            var last = fs.Last;
            bool full = fs.Count >= _o.MaxSegmentSteps && !(failures > 0 && fs.Count < 2 * _o.MaxSegmentSteps);
            if (notable && !full) return false;
            if (last == null || !last.Batch || last.Front != front || last.Back != back || t < last.T || !(full || t - last.T2 <= 900000)) return false;
            if (t > last.T2) last.T2 = t;
            last.Count += 1; last.Failures += failures; last.TotalMs += ms; last.MaxMs = Math.Max(last.MaxMs, ms);
            int n; last.BatchActions.TryGetValue(action, out n); last.BatchActions[action] = n + 1;
            return true;
        }

        // The texts of the HTTP statuses 100 to 599, as ToString gives them: no new string for every request.
        static readonly string[] StatusTexts = Enumerable.Range(100, 500).Select(n => n.ToString(CultureInfo.InvariantCulture)).ToArray();

        static string StatusLabel(AccessRecord r)
        {
            if (r.Source == "Imap4" || r.Source == "Pop3") return r.Status >= 400 ? "NO" : "OK";
            int status = r.Status;
            return status >= 100 && status < 600 ? StatusTexts[status - 100] : status.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Adds a step to the timeline written for its log file: up to MaxSessionSteps steps per session and file
        /// (twice as many for failures), the other successes folded into the last batch step of that file.
        /// </summary>
        void AddStep(ClientSession s, SessionStep step, bool notable)
        {
            FileSteps fs;
            if (!s.PerFile.TryGetValue(step.FileId, out fs)) { fs = new FileSteps(); s.PerFile[step.FileId] = fs; }
            var last = fs.Last;
            bool full = fs.Count >= _o.MaxSegmentSteps && !(step.Failures > 0 && fs.Count < 2 * _o.MaxSegmentSteps);
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
            s.Steps.Add(step);
            fs.Count++;
            fs.Last = step;
        }

        // ================================================================ sessions in the database

        void FlushSessions(SqliteTransaction tx, HashSet<ClientSession> touched)
        {
            if (touched.Count == 0) return;
            long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (var s in touched)
            {
                if (s.Dead) continue;
                var cmd = s.Id == 0 ? _writer.SessionInsert : _writer.SessionUpdate;
                cmd.Set(0, s.Key); cmd.Set(1, s.Day); cmd.Set(2, s.Start); cmd.Set(3, s.End); cmd.Set(4, s.User); cmd.Set(5, s.Protocol); cmd.Set(6, s.Mailbox);
                cmd.Set(7, s.Ips.Count == 0 ? null : string.Join(",", s.Ips.Take(10)));
                cmd.Set(8, s.UserAgent); cmd.Set(9, s.DeviceId); cmd.Set(10, s.DeviceType); cmd.Set(11, s.Software); cmd.Set(12, s.Mode);
                cmd.Set(13, s.Fronts.Count == 0 ? null : string.Join(",", s.Fronts));
                cmd.Set(14, s.Backs.Count == 0 ? null : string.Join(",", s.Backs));
                cmd.Set(15, s.Requests); cmd.Set(16, s.Successes); cmd.Set(17, s.Failures); cmd.Set(18, s.Slow);
                cmd.Set(19, s.FirstSuccess); cmd.Set(20, s.LastSuccess); cmd.Set(21, s.FirstFailure); cmd.Set(22, s.LastFailure);
                cmd.Set(23, s.TotalMs); cmd.Set(24, s.MaxMs); cmd.Set(25, s.BytesIn); cmd.Set(26, s.BytesOut);
                cmd.Set(27, Adaptive(Join(s.Actions))); cmd.Set(28, Adaptive(Join(s.Statuses)));
                cmd.Set(29, Identity.Cap(s.FirstError, 400)); cmd.Set(30, Identity.Cap(s.LastError, 400));
                cmd.Set(31, s.BackEndErrors > 0 || s.BackEndNote != null ? (object)(s.BackEndErrors.ToString(CultureInfo.InvariantCulture) + "|" + (s.BackEndNote ?? "")) : null);
                cmd.Set(32, s.Connections); cmd.Set(33, now); cmd.Set(34, Adaptive(Join(s.Auths)));
                if (s.Id == 0) s.Id = Convert.ToInt64(cmd.Scalar(), CultureInfo.InvariantCulture);
                else { cmd.Set(35, s.Id); cmd.Run(); }
                _store.NoteSessionSpan(s.End - s.Start);
                foreach (var old in s.Absorbed)
                {
                    _writer.SessionRepoint.Set(0, s.Id); _writer.SessionRepoint.Set(1, old); _writer.SessionRepoint.Run();
                    _writer.SessionDelete.Set(0, old); _writer.SessionDelete.Run();
                }
                s.Absorbed.Clear();
                if (s.Steps.Count > 0)
                {
                    long first = long.MaxValue;
                    foreach (var x in s.Steps) if (x.T < first) first = x.T;
                    _writer.SessionStep.Set(0, s.Id); _writer.SessionStep.Set(1, first); _writer.SessionStep.Set(2, PackSteps(s.Steps));
                    _writer.SessionStep.Run();
                    s.Steps.Clear();
                }
                s.PerFile.Clear();
            }
            touched.Clear();
            // The span bound of the sessions written (the apply connection runs with its triggers off).
            _store.FlushSpanBounds(tx);
        }

        // Apply thread: the JSON of the steps of a session is written into this buffer (kept from one session to the next) and packed from it.
        readonly System.Buffers.ArrayBufferWriter<byte> _stepsBuffer = new System.Buffers.ArrayBufferWriter<byte>(4096);
        Utf8JsonWriter _stepsWriter;

        /// <summary>
        /// The stored steps: the same bytes as Pack(StepsJson(steps)). The writer fills the reused buffer and the UTF-8 it wrote is packed in one
        /// piece (the JSON is ASCII, the default encoder escapes the rest: decoding it to a string and encoding it again gives the same bytes).
        /// </summary>
        byte[] PackSteps(List<SessionStep> steps)
        {
            _stepsBuffer.Clear();
            if (_stepsWriter == null) _stepsWriter = new Utf8JsonWriter(_stepsBuffer); else _stepsWriter.Reset(_stepsBuffer);
            WriteSteps(_stepsWriter, steps);
            _stepsWriter.Flush();
            return PackUtf8(_stepsBuffer.WrittenSpan);
        }

        /// <summary>Steps as compact JSON: [t, t2, front, back, action, status, count, avgMs, maxMs, failures, detail, requestId, source, batch, fileId, needle, needle2].</summary>
        static string StepsJson(List<SessionStep> steps)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms)) WriteSteps(w, steps);
                return Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
            }
        }

        static void WriteSteps(Utf8JsonWriter w, List<SessionStep> steps)
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

        static void Str(Utf8JsonWriter w, string s) { if (s == null) w.WriteNullValue(); else w.WriteStringValue(s); }

        // ================================================================ operations and clients (usage aggregates)

        sealed class ActionAcc { public string Day, Server, Protocol, Action; public long Requests, Failures, Slow, TotalMs, MaxMs; }

        sealed class ClientAcc
        {
            public string Day, Server, User, Protocol, Ip, Agent, DeviceId, DeviceType, Auth;
            public long Requests, Failures, First = long.MaxValue, Last;
        }

        void FlushActions()
        {
            var w = _writer.Action;
            foreach (var a in _batch.Actions.Values)
            {
                w.Set(0, a.Day); w.Set(1, a.Server); w.Set(2, a.Protocol); w.Set(3, a.Action); w.Set(4, a.Requests);
                w.Set(5, a.Failures); w.Set(6, a.Slow); w.Set(7, a.TotalMs); w.Set(8, a.MaxMs);
                w.Run();
            }
            _batch.Actions.Clear();
        }

        void FlushClients()
        {
            var w = _writer.Client;
            foreach (var a in _batch.Clients.Values)
            {
                w.Set(0, a.Day); w.Set(1, a.User); w.Set(2, a.Protocol); w.Set(3, a.Ip); w.Set(4, a.Agent); w.Set(5, a.DeviceId);
                w.Set(6, a.DeviceType); w.Set(7, a.Requests); w.Set(8, a.Failures); w.Set(9, a.First); w.Set(10, a.Last); w.Set(11, a.Server); w.Set(12, a.Auth ?? "");
                w.Run();
            }
            _batch.Clients.Clear();
        }

        // ================================================================ MAPI over HTTP back end

        /// <summary>
        /// Logging\MapiHttp\Mailbox on the mailbox server. Requests are already counted from the front
        /// end; the back end adds the Outlook version and mode, the MAPI status of each request and the
        /// milestones (Connect, Disconnect, address book Bind / Unbind) with their back-end detail.
        /// </summary>
        long ParseMapiBackEnd(ParseContext c)
        {
            long offset = c.StartOffset;
            int iTime = -1, iReq = -1, iType = -1, iHttp = -1, iResp = -1, iStat = -1, iRet = -1, iLat = -1, iEmail = -1, iUser = -1, iMbx = -1, iIp = -1,
                iCafe = -1, iInfo = -1, iSoft = -1, iVer = -1, iMode = -1, iOps = -1, iErr = -1, iUpn = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("DateTime"); iReq = m.Index("RequestId"); iType = m.Index("RequestType"); iHttp = m.Index("HttpStatusCode");
                iResp = m.Index("ResponseCode"); iStat = m.Index("StatusCode"); iRet = m.Index("ReturnCode"); iLat = m.Index("TotalRequestLatency");
                iEmail = m.Index("AuthenticatedUserEmail"); iUser = m.Index("AuthenticatedUser"); iMbx = m.Index("MailboxId"); iIp = m.Index("ClientIP");
                iCafe = m.Index("SourceCafeServer"); iInfo = m.Index("MapiClientInfo"); iSoft = m.Index("ClientSoftware");
                iVer = m.Index("ClientSoftwareVersion"); iMode = m.Index("ClientMode"); iOps = m.Index("OperationSpecific"); iErr = m.Index("GenericErrors");
                iUpn = m.Index("UPN");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset, c.Memo != null ? c.Memo.Read : null))
            {
                offset = line.NextOffset;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line.First == '#')
                {
                    if (line.StartsWith("#Fields:")) { string text = line.Text(); c.Map.Load(text); c.Fields = text; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (line.StartsWith("DateTime,")) { Noise(c, "Header", 1); continue; }
                if (iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!c.Split.TryTime(iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.DetailCutoffMs) { Noise(c, "Older than detail retention (back end)", 1); continue; }
                var memo = c.Memo;
                string software = c.Split.GetCached(iSoft);
                if (_probeAgents != null && software != null && Remember(memo.ProbeAgents, software, x => _probeAgents.IsMatch(x))) { Noise(c, "Monitoring probe (client software)", 1); continue; }
                string raw = c.Split.GetCached(iEmail);
                string other = c.Split.GetCached(iUser);
                if (raw == null && other != null && !other.Equals("Anonymous", StringComparison.OrdinalIgnoreCase)) raw = other;
                string user = UserOf(memo, raw), ip = c.Split.GetCached(iIp);
                string why = ClientNoise(memo, user, null, null, ip, null, 200);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                string version = c.Split.Get(iVer);
                string mode = c.Split.Get(iMode);
                if (mode == "0") mode = null;   // unknown
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
                c.BackEnd.Add(new BackEndLine
                {
                    T = t, User = user, Ip = ip, MailboxGuid = Identity.MailboxGuid(c.Split.Get(iMbx)), Instance = Identity.ClientInstance(c.Split.Get(iInfo)),
                    Type = c.Split.Get(iType) ?? "?", Cafe = Identity.ServerName(c.Split.Get(iCafe)), Software = software, Version = version, Mode = mode,
                    Status = http, Failed = failed, Text = string.Join("; ", detail), Ms = c.Split.GetLong(iLat, 0), RequestId = c.Split.Get(iReq),
                    Upn = _o.ResolveSids ? UserOf(memo, c.Split.GetCached(iUpn)) : null
                });
            }
            return offset;
        }

        void ApplyMapiBackEnd(ApplyFile f, BackEndLine b)
        {
            string day = _days.Day(b.T);
            if (_identities != null && _sidKeys.Count > 0)
            {
                // The same Outlook instance (client instance GUID) on the same mailbox as a session the front end logged under a SID: the back end
                // names the person. Without the instance or the mailbox, two people on one address can share the key: no evidence.
                string name = b.Upn ?? b.User, sid;
                if (name != null && b.Instance != null && b.MailboxGuid != null && !SidForm(name)
                    && _sidKeys.TryGetValue(day + "|" + SessionKeyRest("Mapi", b.Ip, null, null, b.MailboxGuid, b.Instance), out sid) && sid != null)
                    _identities.Add(sid, IdentityMap.MapiBackEnd, name, 1, b.T, b.T, IdentityNow());
            }
            string user = Canonical(b.User);
            string key = SessionKey(day, user, "Mapi", b.Ip, null, null, b.MailboxGuid, b.Instance);
            var s = FindSession(key, b.T, () => NewSession(key, day, user, "Mapi"));
            Touch(s);
            Extend(s, b.T);
            s.Backs.Add(f.Server);
            if (b.Ip != null && s.Ips.Count < 20 && !s.Ips.Contains(b.Ip)) s.Ips.Add(b.Ip);
            if (b.Software != null && s.Software == null) s.Software = b.Software + (b.Version != null ? " " + b.Version : "");
            if (b.Mode != null) s.Mode = b.Mode;
            if (b.Failed)
            {
                s.BackEndErrors++;
                string e = "MAPI " + b.Type + ": " + b.Text;
                if (s.FirstError == null) s.FirstError = e;
                s.LastError = e;
                if (s.FirstFailure == 0 || b.T < s.FirstFailure) s.FirstFailure = b.T;
                if (b.T > s.LastFailure) s.LastFailure = b.T;
            }
            if (b.Failed || Milestones.Contains(b.Type))
            {
                AddStep(s, new SessionStep
                {
                    T = b.T, T2 = b.T, Front = b.Cafe, Back = f.Server, Action = b.Type, Status = b.Status, TotalMs = b.Ms, MaxMs = b.Ms, Failures = b.Failed ? 1 : 0,
                    Detail = Identity.Cap(b.Text, 400), RequestId = b.RequestId, Source = "BE", FileId = f.FileId, Needle = b.RequestId
                }, true);
            }
        }

        // ================================================================ ActiveSync back end (IIS W3SVC2)

        /// <summary>
        /// Exchange Back End web site. Only ActiveSync lines are read: their "Log=" parameter holds the
        /// ActiveSync result that the HTTP status hides (an HTTP 200 can be DeviceNotProvisioned or
        /// UserDisabledForSync), the access state of the device and the protocol version.
        /// </summary>
        long ParseEasBackEnd(ParseContext c)
        {
            long offset = c.StartOffset;
            int iDate = -1, iTime = -1, iMethod = -1, iStem = -1, iQuery = -1, iUser = -1, iAgent = -1, iStatus = -1, iTaken = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iDate = m.Index("date"); iTime = m.Index("time"); iMethod = m.Index("cs-method"); iStem = m.Index("cs-uri-stem"); iQuery = m.Index("cs-uri-query");
                iUser = m.Index("cs-username"); iAgent = m.Index("cs(User-Agent)"); iStatus = m.Index("sc-status"); iTaken = m.Index("time-taken");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset, c.Memo != null ? c.Memo.Read : null))
            {
                offset = line.NextOffset;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line.First == '#')
                {
                    if (line.StartsWith("#Fields:")) { string text = line.Text(); c.Map.Load(text); c.Fields = text; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (!line.Contains("/Microsoft-Server-ActiveSync")) { Noise(c, "Back-end traffic other than ActiveSync", 1); continue; }
                if (iDate < 0 || iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ' ');
                long t;
                if (!c.Split.TryTime(iDate, iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.DetailCutoffMs) { Noise(c, "Older than detail retention (back end)", 1); continue; }
                var memo = c.Memo;
                string user = UserOf(memo, c.Split.GetCached(iUser)), agent = PlusAgent(memo, c.Split.GetCached(iAgent));
                int status = c.Split.GetInt(iStatus, 0);
                string why = ClientNoise(memo, user, null, agent, null, c.Split.GetCached(iStem), status);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                string query = c.Split.Get(iQuery) ?? "";
                string queryCmd = Identity.QueryValue(query, "Cmd");
                string cmd = queryCmd ?? c.Split.Get(iMethod) ?? "?";
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
                c.BackEnd.Add(new BackEndLine
                {
                    T = t, User = user, Agent = agent, Device = Identity.QueryValue(query, "DeviceId"), Type = cmd, Error = error, Access = access, Version = version,
                    Status = status, Ms = c.Split.GetLong(iTaken, 0), Needle = c.Split.Get(iDate) + " " + c.Split.Get(iTime) + " ",
                    Needle2 = queryCmd != null ? "Cmd=" + cmd : c.Split.Get(iStem)
                });
            }
            return offset;
        }

        void ApplyEasBackEnd(ApplyFile f, BackEndLine b)
        {
            if (_identities != null && b.Device != null && b.User != null && _sidDevices.Count > 0 && !SidForm(b.User))
            {
                // A device the front end saw under one SID only: the account the back end logged for that device (its Basic requests) is a hint. The
                // back end logs a token request under the SID, so the name may be another person's on the same device: never used to merge.
                string sid;
                if (_sidDevices.TryGetValue(b.Device, out sid) && sid != null) _identities.Hint(sid, IdentityMap.EasBackEnd + ":" + b.User, 1, b.T, b.T);
            }
            string user = Canonical(b.User);
            string day = _days.Day(b.T);
            string key = SessionKey(day, user, "Eas", null, b.Agent, b.Device, null, null);
            var s = FindSession(key, b.T, () => NewSession(key, day, user, "Eas"));
            Touch(s);
            Extend(s, b.T);
            s.Backs.Add(f.Server);
            if (b.Version != null) s.Software = "ActiveSync " + b.Version;
            if (b.Access != null) s.Mode = "Access " + b.Access;
            if (s.DeviceId == null && b.Device != null) s.DeviceId = b.Device;
            if (b.Error != null || b.Status >= 400)
            {
                s.BackEndErrors++;
                string text = (b.Error != null ? "ActiveSync error " + b.Error : "HTTP " + b.Status) + (b.Access != null ? " (device access " + b.Access + ")" : "");
                string e = b.Type + ": " + text;
                if (s.FirstError == null) s.FirstError = e;
                s.LastError = e;
                if (s.FirstFailure == 0 || b.T < s.FirstFailure) s.FirstFailure = b.T;
                if (b.T > s.LastFailure) s.LastFailure = b.T;
                AddStep(s, new SessionStep
                {
                    T = b.T, T2 = b.T, Back = f.Server, Action = b.Type, Status = b.Status, TotalMs = b.Ms, MaxMs = b.Ms, Failures = 1, Detail = text, Source = "BE",
                    FileId = f.FileId, Needle = b.Needle, Needle2 = b.Needle2
                }, true);
            }
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
        long ParsePopImap(ParseContext c, string protocol)
        {
            bool backEnd = Path.GetFileName(c.Path).StartsWith(protocol.ToUpperInvariant() + "BE", StringComparison.OrdinalIgnoreCase);
            c.PopImapBackEnd = backEnd;
            var open = new Dictionary<string, PiConnection>(StringComparer.Ordinal);
            var done = new List<PiConnection>();
            long offset = c.StartOffset, lineStart = offset, fileLastMs = 0;
            int iTime = -1, iSess = -1, iClient = -1, iUser = -1, iDur = -1, iIn = -1, iOut = -1, iCmd = -1, iParams = -1, iCtx = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("dateTime"); iSess = m.Index("sessionId"); iClient = m.Index("cIp"); iUser = m.Index("user"); iDur = m.Index("duration");
                iIn = m.Index("rqsize"); iOut = m.Index("rpsize"); iCmd = m.Index("command"); iParams = m.Index("parameters"); iCtx = m.Index("context");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset, c.Memo != null ? c.Memo.Read : null))
            {
                long start = lineStart;
                lineStart = line.NextOffset;
                offset = line.NextOffset;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line.First == '#')
                {
                    if (line.StartsWith("#Fields:")) { string text = line.Text(); c.Map.Load(text); c.Fields = text; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (iTime < 0 || iSess < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!c.Split.TryTime(iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
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
                x.EndOffset = line.NextOffset;
                string user = c.Split.Get(iUser);
                if (user != null && (x.User == null || x.User.IndexOf('@') > 0)) x.User = user;
                string ctx = c.Split.Get(iCtx);
                if (ctx != null && x.BackEnd == null)
                {
                    var proxy = ProxyTargetRx.Match(ctx);
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
            foreach (var x in done)
            {
                if (x.EndOffset > safe) continue;
                // Noise is decided here (no shared state needed): connections without logon and probes.
                string user = Identity.User(x.User);
                if (user == null)
                {
                    bool logonFailed = x.Commands.Any(l => PiFailed(l.Result) && (l.Command.Equals("login", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("authenticate", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("pass", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("user", StringComparison.OrdinalIgnoreCase)));
                    Noise(c, logonFailed ? protocol + " logon failed (the account is not logged)" : protocol + " connection without logon", x.Lines);
                    continue;
                }
                string why = ClientNoise(c.Memo, user, null, null, backEnd ? null : x.ClientIp, null, 200);
                if (why != null) { Noise(c, why, x.Lines); continue; }
                c.Result.Kept += x.Lines;
                c.PopImap.Add(x);
            }
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
            var tagged = TaggedResultRx.Match(v);
            return (tagged.Success ? tagged.Groups[1].Value : v).Trim();
        }

        static bool PiFailed(string result)
        {
            if (string.IsNullOrEmpty(result)) return false;
            return result.StartsWith("NO", StringComparison.OrdinalIgnoreCase) || result.StartsWith("BAD", StringComparison.OrdinalIgnoreCase) || result.StartsWith("-ERR", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>Apply stage of one POP or IMAP connection of a real user (noise already removed by the parse stage).</summary>
        void EmitPopImap(ApplyFile f, PiConnection x, string protocol, bool backEnd)
        {
            string user = Canonical(Identity.User(x.User));
            DeferredBackEnd deferred = null;
            if (backEnd && x.Start >= _o.DetailCutoffMs)
            {
                deferred = new DeferredBackEnd { Day = _days.Day(x.Start), User = user, Protocol = protocol, Server = f.Server, FrontIp = x.ClientIp, Start = x.Start, End = x.Last };
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
                    RequestId = protocol + " " + f.Server + " #" + x.Id + "/" + index.ToString(CultureInfo.InvariantCulture) + "@" + l.T.ToString(CultureInfo.InvariantCulture),
                    Needle = l.Needle,
                    Detail = first && !backEnd ? "Connection " + x.Id + " from " + x.ClientIp + (x.BackEnd != null ? ", proxied to " + x.BackEnd : "") : null
                };
                HandleAccess(f, r);
                if (!backEnd && first)
                {
                    // One connection more for the session of this client.
                    string day = _days.Day(l.T);
                    string key = SessionKey(day, user, protocol, x.ClientIp, null, null, null, null);
                    var s = FindSession(key, l.T, () => NewSession(key, day, user, protocol));
                    if (l.T >= _o.DetailCutoffMs) { s.Connections++; Touch(s); }
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
                        T = l.T, T2 = l.T, Back = f.Server, Action = r.Action, Status = r.Status, TotalMs = l.Ms, MaxMs = l.Ms, Failures = failed ? 1 : 0,
                        Detail = Identity.Cap((l.Params != null && !l.Params.Contains("*****") ? l.Params + " -> " : "") + (l.Result ?? ""), 300), Source = "BE",
                        RequestId = r.RequestId, FileId = f.FileId, Needle = l.Needle
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
            using (var writer = new Writer(_store))
            using (var tx = _store.Begin())
            {
                _writer = writer;
                _writer.Use(tx);
                _tx = tx;
                var touched = new HashSet<ClientSession>();
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
                finally { _tx = null; _writer = null; }
            }
            _deferred.Clear();
        }
    }
}
