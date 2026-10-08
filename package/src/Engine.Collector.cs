// =============================================================================
//  Exchange Log Report - engine, part 3: collector (log files -> SQLite)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  A collection has two stages (Engine.Pipeline.cs runs them):
//    1. PARSE  (several threads, one file each): reads the new part of a log file,
//              removes and counts the noise, and turns the lines of real users and
//              real messages into records. Nothing is shared between files: the
//              parsers only read the noise rules.
//    2. APPLY  (one thread, the only one that uses the database): client access
//              aggregates, client sessions, recoveries, then the rows, in batched
//              transactions. The read position of a file is saved in the same
//              transaction as its rows: an interrupted collection restarts exactly
//              where it stopped, without duplicates.
//
//  Kinds of log files
//    HttpProxy    Logging\HttpProxy\<protocol>\*.log    main source of client access
//    Iis          inetpub\logs\LogFiles\W3SVC1\*.log    front-end IIS: sub-status / Win32 status of
//                                                       proxied failures, requests never proxied,
//                                                       accounts rejected by Basic authentication
//    SmtpReceive  TransportRoles\Logs\<role>\ProtocolLog\SmtpReceive\*.log
//    SmtpSend     TransportRoles\Logs\<role>\ProtocolLog\SmtpSend\*.log
//    Tracking     TransportRoles\Logs\MessageTracking\MSGTRK*.log
//    MapiBackEnd  Logging\MapiHttp\Mailbox\*.log         see Engine.Sessions.cs
//    EasBackEnd   inetpub\logs\LogFiles\W3SVC2\*.log    see Engine.Sessions.cs
//    Imap4, Pop3  Logging\Imap4, Logging\Pop3           see Engine.Sessions.cs (optional)
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>Settings of a collection, filled by PowerShell from the configuration file.</summary>
    public sealed class CollectorOptions
    {
        public TimeZoneInfo Zone = TimeZoneInfo.Utc;
        public long RunId;
        public long NowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        public long RetentionCutoffMs;            // older lines are not stored at all
        public long DetailCutoffMs;               // older lines feed the aggregates only
        public long RecoveryWindowMs = 30 * 60000L;
        public long SmtpIdleMs = 10 * 60000L;
        public int MaxTranscriptLines = 200;
        public bool StoreAllRequests;
        public string[] FullDetailUsers = new string[0];
        public string[] SystemUserPatterns = new string[0];
        public string[] ProbeUserAgentPatterns = new string[0];
        public string[] ProbeUrlPatterns = new string[0];
        public string[] ProbeSenderPatterns = new string[0];
        public string[] ExcludedClientIps = new string[0];
        public string[] IgnoredTrackingEvents = new string[0];
        public long SessionIdleMs = 30 * 60000L;  // a client session ends after this inactivity
        public long SlowRequestMs = 5000;         // successful requests slower than this are kept as "Slow"
        public string[] LongRunningPatterns = new string[0]; // "Protocol|Action|Url" of long-polling requests (never slow)
        public int SessionDetailRequests = 40;    // first requests of a session always kept in its timeline
        public int MaxSegmentSteps = 80;          // timeline steps written per session and log file
        public int Parallelism;                   // files read at the same time (0: one per processor, 2 to 16)
        public int MaxFilesPerServer = 4;         // files of one server read at the same time (0: no limit)
        public double BatchSeconds = 30;          // a transaction is committed at least this often...
        public int BatchRows = 500000;            // ...or after this many rows
    }

    /// <summary>Outcome of one file.</summary>
    public sealed class FileResult
    {
        public string Server, Kind, Path, Error;
        public long BytesRead, Lines, Kept, Noise, Stored;
        public long FirstMs, LastMs;
        public bool Reset, Unchanged;
        public double Seconds;
        public Dictionary<string, long> NoiseReasons = new Dictionary<string, long>(StringComparer.Ordinal);
    }

    public sealed partial class Collector
    {
        readonly Store _store;
        readonly CollectorOptions _o;
        readonly Regex _systemUsers, _probeAgents, _probeUrls, _probeSenders, _longRunning;
        readonly HashSet<string> _ignoredEvents, _watched;
        readonly DayCache _days;

        static readonly Regex QueuedRx = new Regex(@"<([^>\s]+)>[^\[]*\[InternalId=(\d+)", RegexOptions.Compiled);
        static readonly Regex AcceptedIdRx = new Regex(@"^2\d\d\s+[\d.]+\s+\S*\s*<([^>\s]+@[^>\s]+)>", RegexOptions.Compiled);
        static readonly Regex InternetIdRx = new Regex(@"InternetMessageId\s*<([^>\s]+)>", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        static readonly Regex TlsRx = new Regex(@"SP_PROT_(TLS|SSL)(\d)_(\d)", RegexOptions.Compiled);
        static readonly Regex CafeRx = new Regex(@"cafeReqId=([0-9a-fA-F-]{36})", RegexOptions.Compiled);

        public long RecoveredCount { get; private set; }

        public Collector(Store store, CollectorOptions options)
        {
            _store = store;
            _o = options;
            _systemUsers = Build(options.SystemUserPatterns);
            _probeAgents = Build(options.ProbeUserAgentPatterns);
            _probeUrls = Build(options.ProbeUrlPatterns);
            _probeSenders = Build(options.ProbeSenderPatterns);
            _longRunning = Build(options.LongRunningPatterns);
            _ignoredEvents = new HashSet<string>((options.IgnoredTrackingEvents ?? new string[0]).Select(e => e.ToUpperInvariant()), StringComparer.Ordinal);
            _watched = new HashSet<string>((options.FullDetailUsers ?? new string[0]).Where(u => !string.IsNullOrWhiteSpace(u)).Select(u => u.Trim().ToLowerInvariant()), StringComparer.Ordinal);
            _days = new DayCache(options.Zone);
            LoadPendingFailures();
            LoadAccounts();
            LoadStoredDays();
        }

        static Regex Build(string[] patterns)
        {
            var list = (patterns ?? new string[0]).Where(p => !string.IsNullOrWhiteSpace(p)).ToArray();
            if (list.Length == 0) return null;
            return new Regex(string.Join("|", list.Select(p => "(?:" + p + ")")), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);
        }

        // ================================================================ noise rules (read only: used by the parse threads)

        bool IsSystemIdentity(string identity)
        {
            if (_systemUsers == null || string.IsNullOrEmpty(identity)) return false;
            return _systemUsers.IsMatch(identity) || _systemUsers.IsMatch(Identity.Bare(identity));
        }

        bool IsSystemAddress(string address)
        {
            if (string.IsNullOrEmpty(address)) return false;
            if (_probeSenders != null && _probeSenders.IsMatch(address)) return true;
            return IsSystemIdentity(address);
        }

        bool ExcludedIp(string ip)
        {
            if (string.IsNullOrEmpty(ip) || _o.ExcludedClientIps == null) return false;
            foreach (var prefix in _o.ExcludedClientIps) if (!string.IsNullOrEmpty(prefix) && ip.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        /// <summary>Reason why a client access line is not a real user request; null for a real user.</summary>
        string ClientNoise(string user, string mailbox, string agent, string ip, string url, int status)
        {
            if (_probeAgents != null && !string.IsNullOrEmpty(agent) && _probeAgents.IsMatch(agent)) return "Monitoring probe (user agent)";
            if (IsSystemIdentity(user) || (user == null && IsSystemIdentity(mailbox))) return "System or health mailbox";
            if (_probeUrls != null && !string.IsNullOrEmpty(url) && _probeUrls.IsMatch(url)) return "Health check URL";
            if (ExcludedIp(ip)) return "Excluded client address";
            if (user == null) return status == 401 ? "Authentication challenge (anonymous 401)" : "Anonymous request";
            return null;
        }

        /// <summary>
        /// Per parse thread: the values and verdicts already computed. Logs repeat the same accounts, agents, URLs and
        /// addresses millions of times (probes above all): each is normalised and tested against the noise rules once.
        /// </summary>
        sealed class Memo
        {
            public readonly FieldSplitter Split = new FieldSplitter();
            public DayCache Days;
            public readonly Dictionary<string, string> Users = new Dictionary<string, string>(StringComparer.Ordinal);
            public readonly Dictionary<string, string> Mailboxes = new Dictionary<string, string>(StringComparer.Ordinal);
            public readonly Dictionary<string, string> PlusAgents = new Dictionary<string, string>(StringComparer.Ordinal);
            public readonly Dictionary<string, bool> ProbeAgents = new Dictionary<string, bool>(StringComparer.Ordinal);
            public readonly Dictionary<string, bool> SystemIdentities = new Dictionary<string, bool>(StringComparer.Ordinal);
            public readonly Dictionary<string, bool> ProbeUrls = new Dictionary<string, bool>(StringComparer.Ordinal);
            public readonly Dictionary<string, bool> ExcludedIps = new Dictionary<string, bool>(StringComparer.Ordinal);
            public readonly Dictionary<string, bool> SystemAddresses = new Dictionary<string, bool>(StringComparer.Ordinal);

            /// <summary>Bounded memory: the dictionaries are emptied when one grows too large.</summary>
            public void Trim()
            {
                const int max = 100000;
                if (Users.Count > max || Mailboxes.Count > max || PlusAgents.Count > max || ProbeAgents.Count > max || SystemIdentities.Count > max || ProbeUrls.Count > max || ExcludedIps.Count > max || SystemAddresses.Count > max)
                {
                    Users.Clear(); Mailboxes.Clear(); PlusAgents.Clear(); ProbeAgents.Clear(); SystemIdentities.Clear(); ProbeUrls.Clear(); ExcludedIps.Clear(); SystemAddresses.Clear();
                }
            }
        }

        static TValue Remember<TValue>(Dictionary<string, TValue> d, string key, Func<string, TValue> compute)
        {
            TValue v;
            if (d.TryGetValue(key, out v)) return v;
            v = compute(key);
            d[key] = v;
            return v;
        }

        string UserOf(Memo m, string raw) { return raw == null ? null : Remember(m.Users, raw, Identity.User); }
        string MailboxOf(Memo m, string raw) { return raw == null ? null : Remember(m.Mailboxes, raw, Identity.Mailbox); }
        static string PlusAgent(Memo m, string raw) { return raw == null ? null : Remember(m.PlusAgents, raw, x => x.Replace('+', ' ')); }

        /// <summary>ClientNoise with the verdicts of this thread already known.</summary>
        string ClientNoise(Memo m, string user, string mailbox, string agent, string ip, string url, int status)
        {
            if (_probeAgents != null && !string.IsNullOrEmpty(agent) && Remember(m.ProbeAgents, agent, x => _probeAgents.IsMatch(x))) return "Monitoring probe (user agent)";
            if (_systemUsers != null)
            {
                if (!string.IsNullOrEmpty(user) && Remember(m.SystemIdentities, user, IsSystemIdentity)) return "System or health mailbox";
                if (user == null && !string.IsNullOrEmpty(mailbox) && Remember(m.SystemIdentities, mailbox, IsSystemIdentity)) return "System or health mailbox";
            }
            if (_probeUrls != null && !string.IsNullOrEmpty(url) && Remember(m.ProbeUrls, url, x => _probeUrls.IsMatch(x))) return "Health check URL";
            if (!string.IsNullOrEmpty(ip) && _o.ExcludedClientIps != null && _o.ExcludedClientIps.Length > 0 && Remember(m.ExcludedIps, ip, ExcludedIp)) return "Excluded client address";
            if (user == null) return status == 401 ? "Authentication challenge (anonymous 401)" : "Anonymous request";
            return null;
        }

        static string Outcome(int status)
        {
            if (status >= 100 && status < 400) return "Success";
            if (status >= 500) return "ServerError";
            if (status >= 400) return "ClientError";
            return "Incomplete";
        }

        bool Watched(string user, string mailbox)
        {
            if (_watched.Count == 0) return false;
            return (user != null && (_watched.Contains(user) || _watched.Contains(Identity.Bare(user)))) || (mailbox != null && _watched.Contains(mailbox));
        }

        // ================================================================ records

        /// <summary>One file being parsed by one thread: its new lines become records, nothing else is touched.</summary>
        sealed class ParseContext
        {
            public FileWork Work;
            public FileResult Result;
            public string Server, Role, Path, Fields;
            public long StartOffset, LastWriteMs;
            public FieldMap Map = new FieldMap();
            public FieldSplitter Split;
            public Memo Memo;
            public DayCache Days;
            public readonly List<AccessRecord> Access = new List<AccessRecord>();
            public readonly List<object[]> IisStatus = new List<object[]>();
            public readonly List<BackEndLine> BackEnd = new List<BackEndLine>();
            public readonly List<object[]> Smtp = new List<object[]>();
            public readonly List<object[]> Messages = new List<object[]>();
            public readonly List<PiConnection> PopImap = new List<PiConnection>();
            public bool PopImapBackEnd;
            // Aggregates of the file, by the account as logged (the apply thread makes it canonical when it merges them).
            public readonly Dictionary<string, UsageAcc> Usage = new Dictionary<string, UsageAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, ActionAcc> Actions = new Dictionary<string, ActionAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, ClientAcc> Clients = new Dictionary<string, ClientAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, List<long>> Successes = new Dictionary<string, List<long>>(StringComparer.Ordinal);
        }

        /// <summary>One file being applied (apply thread).</summary>
        sealed class ApplyFile
        {
            public string Server, Role, Kind, Path;
            public long FileId;
            public FileResult Result;
        }

        sealed class UsageAcc
        {
            public string Day, Server, User, Protocol, Mailbox, ClientIp, UserAgent;
            public long Requests, Successes, ClientErrors, ServerErrors, BytesIn, BytesOut, TotalMs, MaxMs, LastSuccessMs, LastFailureMs, Slow;
            public long FirstMs = long.MaxValue, LastMs, ClientMs;

            public void Merge(UsageAcc o)
            {
                Requests += o.Requests; Successes += o.Successes; ClientErrors += o.ClientErrors; ServerErrors += o.ServerErrors; Slow += o.Slow;
                BytesIn += o.BytesIn; BytesOut += o.BytesOut; TotalMs += o.TotalMs; MaxMs = Math.Max(MaxMs, o.MaxMs);
                LastSuccessMs = Math.Max(LastSuccessMs, o.LastSuccessMs); LastFailureMs = Math.Max(LastFailureMs, o.LastFailureMs);
                FirstMs = Math.Min(FirstMs, o.FirstMs); LastMs = Math.Max(LastMs, o.LastMs);
                if (o.ClientMs > 0 && o.ClientMs >= ClientMs) { ClientMs = o.ClientMs; ClientIp = o.ClientIp; UserAgent = o.UserAgent; }
                if (o.Mailbox != null) Mailbox = o.Mailbox;
            }
        }

        sealed class AccessRecord
        {
            public long TimeMs, BytesIn, BytesOut, DurationMs;
            public int Status;
            public int? SubStatus, Win32, BackEndStatus;
            public string Source, Protocol, User, Mailbox, ClientIp, UserAgent, Method, Url, Action, ErrorCode, TargetServer, AuthType, Routing, RequestId, Errors;
            public string DeviceId, DeviceType, ClientInstance, MailboxGuid, Detail;
            public string Needle, Needle2;    // text that finds the raw line in its log file (default: RequestId)
            public bool FromBackEnd;          // back-end log line (IMAP/POP back end): no client address of its own
            public ClientSession Session;     // session already resolved by the caller
            // Computed once (by the parse thread for HttpProxy and IIS, Prepared; by the apply thread otherwise).
            public bool Prepared, Failure, Slow;
            public string Outcome, Day, Agent, Why, Back, KeyRest;
        }

        static void Noise(ParseContext c, string reason, long lines)
        {
            long n;
            c.Result.NoiseReasons.TryGetValue(reason, out n);
            c.Result.NoiseReasons[reason] = n + lines;
            c.Result.Noise += lines;
        }

        static void Seen(ParseContext c, long t)
        {
            if (c.Result.FirstMs == 0 || t < c.Result.FirstMs) c.Result.FirstMs = t;
            if (t > c.Result.LastMs) c.Result.LastMs = t;
        }

        /// <summary>Parse stage of one file (any thread). Returns the new read position.</summary>
        long Parse(ParseContext c, string kind)
        {
            switch (kind)
            {
                case "HttpProxy": return ParseHttpProxy(c);
                case "Iis": return ParseIis(c);
                case "SmtpReceive": return ParseSmtp(c, "Receive");
                case "SmtpSend": return ParseSmtp(c, "Send");
                case "Tracking": return ParseTracking(c);
                case "MapiBackEnd": return ParseMapiBackEnd(c);
                case "EasBackEnd": return ParseEasBackEnd(c);
                case "Imap4": return ParsePopImap(c, "Imap4");
                case "Pop3": return ParsePopImap(c, "Pop3");
                default: throw new ArgumentException("Unknown log kind: " + kind);
            }
        }

        // ================================================================ HttpProxy

        long ParseHttpProxy(ParseContext c)
        {
            long offset = c.StartOffset;
            int iTime = -1, iReq = -1, iProto = -1, iStem = -1, iAction = -1, iAuthType = -1, iUser = -1, iAnchor = -1, iAgent = -1, iIp = -1,
                iStatus = -1, iBack = -1, iError = -1, iMethod = -1, iTarget = -1, iRouting = -1, iReqBytes = -1, iRespBytes = -1, iTotal = -1, iErrors = -1,
                iClientReq = -1, iQuery = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("DateTime"); iReq = m.Index("RequestId"); iProto = m.Index("Protocol"); iStem = m.Index("UrlStem");
                iAction = m.Index("ProtocolAction"); iAuthType = m.Index("AuthenticationType"); iUser = m.Index("AuthenticatedUser");
                iAnchor = m.Index("AnchorMailbox"); iAgent = m.Index("UserAgent"); iIp = m.Index("ClientIpAddress"); iStatus = m.Index("HttpStatus");
                iBack = m.Index("BackEndStatus"); iError = m.Index("ErrorCode"); iMethod = m.Index("Method"); iTarget = m.Index("TargetServer");
                iRouting = m.Index("RoutingType"); iReqBytes = m.Index("RequestBytes"); iRespBytes = m.Index("ResponseBytes");
                iTotal = m.Index("TotalRequestTime"); iErrors = m.Index("GenericErrors"); iClientReq = m.Index("ClientRequestId"); iQuery = m.Index("UrlQuery");
            };
            if (c.Map.Load(c.Fields)) bind();
            string folder = Path.GetFileName(Path.GetDirectoryName(c.Path));
            foreach (var line in LogReader.Lines(c.Path, offset))
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
                if (t < _o.RetentionCutoffMs) { Noise(c, "Older than retention", 1); continue; }
                int status = c.Split.GetInt(iStatus, 0);
                var memo = c.Memo;
                string user = UserOf(memo, c.Split.GetCached(iUser));
                string mailbox = MailboxOf(memo, c.Split.GetCached(iAnchor));
                string agent = c.Split.GetCached(iAgent), ip = c.Split.GetCached(iIp), url = c.Split.GetCached(iStem);
                if (status == 0 && user == null && url == null) { Noise(c, "Unreadable line", 1); continue; }
                string why = ClientNoise(memo, user, mailbox, agent, ip, url, status);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                string anchor = c.Split.Get(iAnchor), query = c.Split.Get(iQuery), clientReq = c.Split.Get(iClientReq);
                var r = new AccessRecord
                {
                    TimeMs = t, Source = "HttpProxy", Protocol = c.Split.Get(iProto) ?? folder, User = user, Mailbox = mailbox,
                    ClientIp = ip, UserAgent = agent, Method = c.Split.Get(iMethod), Url = url, Action = c.Split.Get(iAction),
                    Status = status, ErrorCode = Identity.Cap(c.Split.Get(iError), 300), TargetServer = c.Split.Get(iTarget),
                    AuthType = c.Split.Get(iAuthType), Routing = c.Split.Get(iRouting), RequestId = c.Split.Get(iReq),
                    BytesIn = c.Split.GetLong(iReqBytes, 0), BytesOut = c.Split.GetLong(iRespBytes, 0), DurationMs = c.Split.GetLong(iTotal, 0),
                    Errors = Identity.Cap(c.Split.Get(iErrors), 500)
                };
                Enrich(r, query, clientReq, anchor);
                int back = c.Split.GetInt(iBack, 0);
                if (back > 0) r.BackEndStatus = back;
                Prepare(c, r);
                c.Access.Add(r);
            }
            return offset;
        }

        // ================================================================ IIS (front end)

        long ParseIis(ParseContext c)
        {
            long offset = c.StartOffset;
            int iDate = -1, iTime = -1, iMethod = -1, iStem = -1, iQuery = -1, iUser = -1, iIp = -1, iAgent = -1, iStatus = -1, iSub = -1, iWin = -1, iOut = -1, iIn = -1, iTaken = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iDate = m.Index("date"); iTime = m.Index("time"); iMethod = m.Index("cs-method"); iStem = m.Index("cs-uri-stem");
                iQuery = m.Index("cs-uri-query"); iUser = m.Index("cs-username"); iIp = m.Index("c-ip"); iAgent = m.Index("cs(User-Agent)");
                iStatus = m.Index("sc-status"); iSub = m.Index("sc-substatus"); iWin = m.Index("sc-win32-status");
                iOut = m.Index("sc-bytes"); iIn = m.Index("cs-bytes"); iTaken = m.Index("time-taken");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset))
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
                if (iDate < 0 || iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ' ');
                long t;
                if (!c.Split.TryTime(iDate, iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.RetentionCutoffMs) { Noise(c, "Older than retention", 1); continue; }
                int status = c.Split.GetInt(iStatus, 0);
                var memo = c.Memo;
                string user = UserOf(memo, c.Split.GetCached(iUser));
                string agent = PlusAgent(memo, c.Split.GetCached(iAgent));
                string ip = c.Split.GetCached(iIp), url = c.Split.GetCached(iStem);
                string why = ClientNoise(memo, user, null, agent, ip, url, status);
                if (why != null) { Noise(c, why, 1); continue; }
                string query = c.Split.Get(iQuery);
                var cafe = query == null ? null : CafeRx.Match(query);
                if (cafe != null && cafe.Success)
                {
                    // Proxied request: HttpProxy has the full record. IIS adds the sub-status and Win32 status of failures.
                    // A 401 with an account and an IIS sub-status / Win32 error is a logon rejected by IIS itself
                    // (HttpProxy logs it as anonymous); a plain 401 of the back end is already in HttpProxy with its user.
                    bool denied = status == 401 && user != null && (c.Split.GetInt(iSub, 0) > 0 || c.Split.GetLong(iWin, 0) != 0);
                    if (status >= 400 && t >= _o.DetailCutoffMs)
                    {
                        c.IisStatus.Add(new object[] { c.Server, cafe.Groups[1].Value, t, (long)status, (long)c.Split.GetInt(iSub, 0), c.Split.GetLong(iWin, 0), c.Split.GetLong(iTaken, 0) });
                        c.Result.Kept++;
                    }
                    else if (denied) c.Result.Kept++;
                    else Noise(c, "Already in HttpProxy log", 1);
                    // Basic authentication rejected (401.1, Win32 1326 logon failure, 1909 locked, 1330 expired...):
                    // HttpProxy logs it as anonymous, only IIS knows the account that tried.
                    if (denied)
                    {
                        var rejected = new AccessRecord
                        {
                            TimeMs = t, Source = "IIS", Protocol = Identity.Protocol(url), User = user, ClientIp = ip, UserAgent = agent,
                            Method = c.Split.Get(iMethod), Url = url, Status = status, SubStatus = c.Split.GetInt(iSub, 0),
                            Win32 = (int)c.Split.GetLong(iWin, 0), BytesIn = c.Split.GetLong(iIn, 0), BytesOut = c.Split.GetLong(iOut, 0),
                            DurationMs = c.Split.GetLong(iTaken, 0), RequestId = cafe.Groups[1].Value, ErrorCode = LogonError((int)c.Split.GetLong(iWin, 0))
                        };
                        Enrich(rejected, query, null, null);
                        Prepare(c, rejected);
                        c.Access.Add(rejected);
                    }
                    continue;
                }
                if (status < 400) { Noise(c, "Served by IIS without proxy (success)", 1); continue; }
                // Rejected by IIS before reaching the proxy: a real failure that HttpProxy never sees.
                c.Result.Kept++;
                var r = new AccessRecord
                {
                    TimeMs = t, Source = "IIS", Protocol = Identity.Protocol(url), User = user, ClientIp = ip, UserAgent = agent,
                    Method = c.Split.Get(iMethod), Url = url, Status = status, SubStatus = c.Split.GetInt(iSub, 0),
                    Win32 = (int)c.Split.GetLong(iWin, 0), BytesIn = c.Split.GetLong(iIn, 0), BytesOut = c.Split.GetLong(iOut, 0),
                    DurationMs = c.Split.GetLong(iTaken, 0)
                };
                r.Needle = c.Split.Get(iDate) + " " + c.Split.Get(iTime) + " ";
                r.Needle2 = c.Split.Get(iUser);
                Enrich(r, query, null, null);
                Prepare(c, r);
                c.Access.Add(r);
            }
            return offset;
        }

        static string LogonError(int win32)
        {
            switch (win32)
            {
                case 1326: return "Logon failure: unknown user name or bad password (1326)";
                case 1909: return "Account locked out (1909)";
                case 1330: return "Password expired (1330)";
                case 1331: return "Account disabled (1331)";
                case 1907: return "Password must be changed (1907)";
                case 1793: return "Account expired (1793)";
                case 0: return "Authentication failed";
                default: return "Authentication failed (Win32 " + win32.ToString(System.Globalization.CultureInfo.InvariantCulture) + ")";
            }
        }

        // ================================================================ client access: aggregates, details, recovery

        /// <summary>What does not depend on the other files: outcome, slow, day, session key without the account.</summary>
        void Compute(AccessRecord r, DayCache days, string server)
        {
            r.Outcome = Outcome(r.Status);
            r.Failure = r.Outcome != "Success";
            r.Slow = !r.Failure && _o.SlowRequestMs > 0 && r.DurationMs >= _o.SlowRequestMs && !LongRunning(r);
            r.Day = days.Day(r.TimeMs);
            r.Agent = Identity.Cap(r.UserAgent, 300);
            if (r.Failure) r.Why = Describe(r);
            r.Back = r.FromBackEnd ? server : Identity.ServerName(r.TargetServer);
            r.KeyRest = SessionKeyRest(r.Protocol, r.ClientIp, r.UserAgent, r.DeviceId, r.MailboxGuid, r.ClientInstance);
        }

        /// <summary>Counts a request in usage, operations, clients and successes (by the account as given).</summary>
        static void Count(AccessRecord r, string server, Dictionary<string, UsageAcc> usage, Dictionary<string, ActionAcc> actions, Dictionary<string, ClientAcc> clients, Dictionary<string, List<long>> successes)
        {
            string key = r.Day + "|" + server + "|" + r.User + "|" + r.Protocol;
            UsageAcc u;
            if (!usage.TryGetValue(key, out u)) { u = new UsageAcc { Day = r.Day, Server = server, User = r.User, Protocol = r.Protocol }; usage[key] = u; }
            u.Requests++;
            if (!r.Failure) { u.Successes++; if (r.TimeMs > u.LastSuccessMs) u.LastSuccessMs = r.TimeMs; }
            else
            {
                if (r.Outcome == "ServerError") u.ServerErrors++; else u.ClientErrors++;
                if (r.TimeMs > u.LastFailureMs) u.LastFailureMs = r.TimeMs;
            }
            if (r.Slow) u.Slow++;
            u.BytesIn += r.BytesIn; u.BytesOut += r.BytesOut; u.TotalMs += r.DurationMs;
            if (r.DurationMs > u.MaxMs) u.MaxMs = r.DurationMs;
            if (r.TimeMs < u.FirstMs) u.FirstMs = r.TimeMs;
            if (r.TimeMs >= u.LastMs) u.LastMs = r.TimeMs;
            // Address and client of the latest front-end request (back-end lines have no client address of their own).
            if (!r.FromBackEnd && r.TimeMs >= u.ClientMs) { u.ClientMs = r.TimeMs; u.ClientIp = r.ClientIp; u.UserAgent = r.Agent; }
            if (r.Mailbox != null) u.Mailbox = r.Mailbox;

            string action = r.Action ?? "?";
            string ak = r.Day + "|" + server + "|" + r.Protocol + "|" + action;
            ActionAcc a;
            if (!actions.TryGetValue(ak, out a)) { a = new ActionAcc { Day = r.Day, Server = server, Protocol = r.Protocol ?? "Other", Action = action }; actions[ak] = a; }
            a.Requests++;
            if (r.Failure) a.Failures++;
            if (r.Slow) a.Slow++;
            a.TotalMs += r.DurationMs; a.MaxMs = Math.Max(a.MaxMs, r.DurationMs);

            if (!r.FromBackEnd)
            {
                string agent = r.Agent ?? "", device = r.DeviceId ?? "", ip = r.ClientIp ?? "";
                string ck = r.Day + "|" + r.User + "|" + r.Protocol + "|" + ip + "|" + agent + "|" + device + "|" + server;
                ClientAcc cl;
                if (!clients.TryGetValue(ck, out cl)) { cl = new ClientAcc { Day = r.Day, Server = server, User = r.User, Protocol = r.Protocol ?? "Other", Ip = ip, Agent = agent, DeviceId = device }; clients[ck] = cl; }
                cl.Requests++;
                if (r.Failure) cl.Failures++;
                if (r.DeviceType != null) cl.DeviceType = r.DeviceType;
                cl.First = Math.Min(cl.First, r.TimeMs); cl.Last = Math.Max(cl.Last, r.TimeMs);
            }

            if (!r.Failure)
            {
                string sk = r.User + "\u0001" + r.Protocol;
                List<long> list;
                if (!successes.TryGetValue(sk, out list)) { list = new List<long>(); successes[sk] = list; }
                list.Add(r.TimeMs);
            }
        }

        /// <summary>Parse thread: computes and counts a client access record of the file.</summary>
        void Prepare(ParseContext c, AccessRecord r)
        {
            if (c.Days == null) c.Days = new DayCache(_o.Zone);
            Compute(r, c.Days, c.Server);
            Count(r, c.Server, c.Usage, c.Actions, c.Clients, c.Successes);
            r.Prepared = true;
        }

        /// <summary>Apply thread: the aggregates of a file, with the canonical form of the accounts, into the batch.</summary>
        void MergeAggregates(ParseContext c)
        {
            var b = _batch;
            foreach (var u in c.Usage.Values)
            {
                string user = Canonical(u.User);
                string key = u.Day + "|" + u.Server + "|" + user + "|" + u.Protocol;
                UsageAcc into;
                if (!b.Usage.TryGetValue(key, out into)) { u.User = user; b.Usage[key] = u; }
                else into.Merge(u);
            }
            foreach (var a in c.Actions.Values)
            {
                string key = a.Day + "|" + a.Server + "|" + a.Protocol + "|" + a.Action;
                ActionAcc into;
                if (!b.Actions.TryGetValue(key, out into)) b.Actions[key] = a;
                else { into.Requests += a.Requests; into.Failures += a.Failures; into.Slow += a.Slow; into.TotalMs += a.TotalMs; into.MaxMs = Math.Max(into.MaxMs, a.MaxMs); }
            }
            foreach (var cl in c.Clients.Values)
            {
                string user = Canonical(cl.User);
                string key = cl.Day + "|" + user + "|" + cl.Protocol + "|" + cl.Ip + "|" + cl.Agent + "|" + cl.DeviceId + "|" + cl.Server;
                ClientAcc into;
                if (!b.Clients.TryGetValue(key, out into)) { cl.User = user; b.Clients[key] = cl; }
                else
                {
                    into.Requests += cl.Requests; into.Failures += cl.Failures; into.DeviceType = cl.DeviceType ?? into.DeviceType;
                    into.First = Math.Min(into.First, cl.First); into.Last = Math.Max(into.Last, cl.Last);
                }
            }
            foreach (var kv in c.Successes)
            {
                int sep = kv.Key.IndexOf('\u0001');
                string key = Canonical(kv.Key.Substring(0, sep)) + "|" + kv.Key.Substring(sep + 1);
                List<long> list;
                if (!_successes.TryGetValue(key, out list)) _successes[key] = kv.Value;
                else list.AddRange(kv.Value);
            }
        }

        /// <summary>
        /// Apply thread: the part of a client access record that depends on the other files (canonical account,
        /// client session, failures kept with their id for the recoveries). A record not prepared by its parse
        /// thread (IMAP, POP) is computed and counted here.
        /// </summary>
        void HandleAccess(ApplyFile f, AccessRecord r)
        {
            r.User = Canonical(r.User);
            if (!r.Prepared)
            {
                Compute(r, _days, f.Server);
                var b = _batch;
                var successes = new Dictionary<string, List<long>>(StringComparer.Ordinal);
                Count(r, f.Server, b.Usage, b.Actions, b.Clients, successes);
                foreach (var kv in successes) foreach (var t in kv.Value) AddSuccess(r.User + "|" + r.Protocol, t);
            }
            if (r.TimeMs >= _o.DetailCutoffMs) AddToSession(f, r, r.Failure, r.Slow);
            bool keepDetail = r.Failure || r.Slow || _o.StoreAllRequests || Watched(r.User, r.Mailbox);
            if (!keepDetail || r.TimeMs < _o.DetailCutoffMs) return;
            long id = InsertEvent(f, r, r.Slow ? "Slow" : r.Outcome);
            if (r.Failure && id > 0) _failures.Add(new PendingFailure { Id = id, Key = r.User + "|" + r.Protocol, TimeMs = r.TimeMs });
        }
        bool LongRunning(AccessRecord r)
        {
            return _longRunning != null && _longRunning.IsMatch(r.Protocol + "|" + (r.Action ?? "") + "|" + (r.Url ?? ""));
        }

        long InsertEvent(ApplyFile f, AccessRecord r, string outcome)
        {
            var w = _writer.InsertEvent;
            w.Set(0, r.TimeMs); w.Set(1, f.Server); w.Set(2, r.Source); w.Set(3, r.Protocol); w.Set(4, r.User); w.Set(5, r.Mailbox); w.Set(6, r.ClientIp);
            w.Set(7, r.Agent); w.Set(8, r.Method); w.Set(9, Identity.Cap(r.Url, 300)); w.Set(10, r.Action); w.Set(11, (long)r.Status);
            w.Set(12, r.SubStatus.HasValue ? (object)(long)r.SubStatus.Value : null); w.Set(13, r.Win32.HasValue ? (object)(long)r.Win32.Value : null);
            w.Set(14, r.BackEndStatus.HasValue ? (object)(long)r.BackEndStatus.Value : null); w.Set(15, r.ErrorCode); w.Set(16, r.TargetServer); w.Set(17, r.AuthType);
            w.Set(18, r.Routing); w.Set(19, r.BytesIn); w.Set(20, r.BytesOut); w.Set(21, r.DurationMs); w.Set(22, outcome); w.Set(23, r.RequestId); w.Set(24, r.Errors);
            object id = w.Scalar();
            _batch.Rows++;
            if (id == null || id is DBNull) return 0;
            f.Result.Stored++;
            return Convert.ToInt64(id);
        }

        // ---------------------------------------------------------------- recoveries

        sealed class PendingFailure { public long Id, TimeMs; public string Key; }

        readonly List<PendingFailure> _failures = new List<PendingFailure>();
        readonly Dictionary<string, List<long>> _successes = new Dictionary<string, List<long>>(StringComparer.Ordinal);

        void AddSuccess(string key, long t)
        {
            List<long> list;
            if (!_successes.TryGetValue(key, out list)) { list = new List<long>(); _successes[key] = list; }
            list.Add(t);
        }

        /// <summary>Failures of the last two days not recovered yet: a success of this collection can recover them.</summary>
        void LoadPendingFailures()
        {
            if (_store.ReadOnly) return;
            using (var c = _store.Command("SELECT id, user, protocol, time_ms FROM access_event WHERE outcome <> 'Success' AND recovered_ms IS NULL AND time_ms >= @since;"))
            {
                c.Parameters.AddWithValue("@since", _o.NowMs - 2 * 86400000L);
                using (var r = c.ExecuteReader())
                    while (r.Read()) if (!r.IsDBNull(1)) _failures.Add(new PendingFailure { Id = r.GetInt64(0), Key = r.GetString(1) + "|" + (r.IsDBNull(2) ? "" : r.GetString(2)), TimeMs = r.GetInt64(3) });
            }
        }

        /// <summary>
        /// A failure followed, within the recovery window, by a success of the same user and protocol (on any server)
        /// is recovered at the time of the first such success. Computed once all files are read, so that the order in
        /// which the files were read does not matter.
        /// </summary>
        List<long[]> ResolveRecoveries()
        {
            var recovered = new List<long[]>();
            foreach (var list in _successes.Values) list.Sort();
            foreach (var f in _failures)
            {
                List<long> list;
                if (!_successes.TryGetValue(f.Key, out list) || list.Count == 0) continue;
                int i = list.BinarySearch(f.TimeMs);
                if (i < 0) i = ~i;
                else while (i > 0 && list[i - 1] == f.TimeMs) i--;
                if (i < list.Count && list[i] - f.TimeMs <= _o.RecoveryWindowMs) recovered.Add(new[] { f.Id, list[i] });
            }
            return recovered;
        }

        /// <summary>Writes the back-end connections and the recoveries found during the collection. Call once, after the last file.</summary>
        public long Complete()
        {
            CompleteBackEnd();
            var recovered = ResolveRecoveries();
            _failures.Clear();
            _successes.Clear();
            if (recovered.Count == 0) return RecoveredCount = 0;
            using (var tx = _store.Begin())
            using (var c = _store.Command("UPDATE access_event SET recovered_ms=@r WHERE id=@id AND recovered_ms IS NULL;", tx))
            {
                var pr = c.Parameters.Add("@r", SqliteType.Integer); var pid = c.Parameters.Add("@id", SqliteType.Integer);
                long n = 0;
                foreach (var x in recovered) { pid.Value = x[0]; pr.Value = x[1]; n += c.ExecuteNonQuery(); }
                tx.Commit();
                return RecoveredCount = n;
            }
        }

        // ---------------------------------------------------------------- aggregates of a batch

        void FlushUsage()
        {
            var w = _writer.Usage;
            foreach (var u in _batch.Usage.Values)
            {
                w.Set(0, u.Day); w.Set(1, u.Server); w.Set(2, u.User); w.Set(3, u.Protocol ?? "Other"); w.Set(4, u.Mailbox); w.Set(5, u.Requests); w.Set(6, u.Successes);
                w.Set(7, u.ClientErrors); w.Set(8, u.ServerErrors); w.Set(9, u.BytesIn); w.Set(10, u.BytesOut); w.Set(11, u.TotalMs); w.Set(12, u.MaxMs);
                w.Set(13, u.FirstMs); w.Set(14, u.LastMs); w.Set(15, u.LastSuccessMs); w.Set(16, u.LastFailureMs); w.Set(17, u.ClientIp); w.Set(18, u.UserAgent); w.Set(19, u.Slow);
                w.Run();
            }
            _batch.Usage.Clear();
        }

        // ================================================================ SMTP protocol logs

        sealed class SmtpLine { public long Time; public string Tag, Data, Context; }

        sealed class SmtpTxn
        {
            public long StartMs, EndMs;
            public string MailFrom, MessageId, InternalId, Response, LastError;
            public List<string> Rcpts = new List<string>();
            public List<SmtpLine> Lines = new List<SmtpLine>();
            public bool DataSent;
        }

        sealed class SmtpSession
        {
            public string Id, Connector, Local, Remote, Helo, Tls, Auth;
            public string ProxyIp, ProxyPort, ProxyHelo;   // XPROXY: client submission proxied by a front end
            public bool Proxied;                          // front end: the session was handed over to a mailbox server
            public long StartMs, LastMs, StartOffset;
            public int Lines;
            public List<SmtpLine> Preamble = new List<SmtpLine>();
            public SmtpTxn Current;
            public List<SmtpTxn> Done = new List<SmtpTxn>();
        }

        /// <summary>
        /// SMTP protocol logs are read session by session. A session without any mail transaction
        /// (connect, banner, EHLO, QUIT: load balancer probes, port scanners, monitoring) is noise.
        /// Sessions still open at the end of the active file are not written: the read position stays
        /// at their first line so that the next collection reads them complete.
        /// </summary>
        long ParseSmtp(ParseContext c, string direction)
        {
            var sessions = new Dictionary<string, SmtpSession>(StringComparer.Ordinal);
            long offset = c.StartOffset, lineStart = offset, fileLastMs = 0;
            int iTime = -1, iConn = -1, iSess = -1, iLocal = -1, iRemote = -1, iEvt = -1, iData = -1, iCtx = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("date-time"); iConn = m.Index("connector-id"); iSess = m.Index("session-id"); iLocal = m.Index("local-endpoint");
                iRemote = m.Index("remote-endpoint"); iEvt = m.Index("event"); iData = m.Index("data"); iCtx = m.Index("context");
            };
            if (c.Map.Load(c.Fields)) bind();
            bool receive = direction == "Receive";
            foreach (var line in LogReader.Lines(c.Path, offset))
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
                if (iSess < 0 || iEvt < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!c.Split.TryTime(iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t > fileLastMs) fileLastMs = t;
                string sid = c.Split.Get(iSess) ?? "";
                string evt = c.Split.GetRaw(iEvt) ?? "";
                string data = c.Split.Get(iData) ?? "";
                string ctx = c.Split.Get(iCtx) ?? "";
                SmtpSession s;
                if (evt == "+")
                {
                    if (sessions.TryGetValue(sid, out s)) EmitSession(c, s, direction);
                    s = new SmtpSession { Id = sid, StartMs = t, StartOffset = start };
                    sessions[sid] = s;
                }
                else if (!sessions.TryGetValue(sid, out s))
                {
                    s = new SmtpSession { Id = sid, StartMs = t, StartOffset = start };
                    sessions[sid] = s;
                }
                s.Lines++;
                s.LastMs = t;
                if (s.Connector == null) s.Connector = c.Split.Get(iConn);
                if (s.Local == null) s.Local = c.Split.Get(iLocal);
                if (s.Remote == null) s.Remote = c.Split.Get(iRemote);
                bool command = receive ? evt == "<" : evt == ">";
                bool response = receive ? evt == ">" : evt == "<";
                var entry = new SmtpLine { Time = t, Tag = command ? "C:" : response ? "S:" : evt, Data = data, Context = ctx };
                // MAIL FROM opens a new transaction: its line is added to that transaction below.
                bool opensTransaction = command && data.TrimStart().StartsWith("MAIL FROM:", StringComparison.OrdinalIgnoreCase);
                var target = s.Current != null ? s.Current.Lines : s.Preamble;
                if (!opensTransaction && target.Count < _o.MaxTranscriptLines) target.Add(entry);

                if (evt == "*")
                {
                    string text = data + " " + ctx;
                    var tls = TlsRx.Match(text);
                    if (tls.Success) s.Tls = tls.Groups[1].Value + " " + tls.Groups[2].Value + "." + tls.Groups[3].Value;
                    var id = InternetIdRx.Match(text);
                    if (id.Success && s.Current != null && s.Current.MessageId == null) s.Current.MessageId = "<" + id.Groups[1].Value + ">";
                    if (text.IndexOf("Proxy session was successfully set up", StringComparison.OrdinalIgnoreCase) >= 0) s.Proxied = true;
                }
                else if (command)
                {
                    string cmd = data.TrimStart();
                    string up = cmd.ToUpperInvariant();
                    if (up.StartsWith("EHLO ") || up.StartsWith("HELO ")) s.Helo = cmd.Substring(5).Trim();
                    else if (up.StartsWith("XPROXY "))
                    {
                        // Client submission (587) proxied by a front end: the real client is in XPROXY.
                        foreach (var part in cmd.Substring(7).Split(' '))
                        {
                            int eq = part.IndexOf('=');
                            if (eq <= 0) continue;
                            string k = part.Substring(0, eq).ToUpperInvariant(), v = part.Substring(eq + 1);
                            if (k == "IP") s.ProxyIp = v; else if (k == "PORT") s.ProxyPort = v; else if (k == "DOMAIN") s.ProxyHelo = v;
                        }
                    }
                    else if (up.StartsWith("STARTTLS")) { if (s.Tls == null) s.Tls = "STARTTLS"; }
                    else if (up.StartsWith("AUTH ")) s.Auth = cmd.Substring(5).Trim().Split(' ')[0];
                    else if (up.StartsWith("X-EXPS")) s.Auth = ("X-EXPS " + (cmd.Length > 7 ? cmd.Substring(7).Trim().Split(' ')[0] : "")).Trim();
                    else if (up.StartsWith("MAIL FROM:"))
                    {
                        FinishTxn(s);
                        s.Current = new SmtpTxn { StartMs = t, MailFrom = Identity.SmtpAddress(cmd.Substring(10)) };
                        s.Current.Lines.Add(entry);
                    }
                    else if (up.StartsWith("RCPT TO:")) { if (s.Current != null) s.Current.Rcpts.Add(Identity.SmtpAddress(cmd.Substring(8))); }
                    else if (up.StartsWith("DATA") || up.StartsWith("BDAT")) { if (s.Current != null) s.Current.DataSent = true; }
                    else if (up.StartsWith("RSET") || up.StartsWith("QUIT")) FinishTxn(s);
                }
                else if (response && s.Current != null)
                {
                    string code = data.Length >= 3 ? data.Substring(0, 3) : data;
                    if (code.StartsWith("4") || code.StartsWith("5")) s.Current.LastError = data;
                    if (s.Current.DataSent && code != "354")
                    {
                        s.Current.Response = data;
                        s.Current.EndMs = t;
                        var q = QueuedRx.Match(data);
                        if (q.Success) { s.Current.MessageId = "<" + q.Groups[1].Value + ">"; s.Current.InternalId = q.Groups[2].Value; }
                        else if (s.Current.MessageId == null && code.StartsWith("2"))
                        {
                            // Delivery to a mailbox server (port 475): "250 2.0.0 OK <message-id> [Hostname=...]".
                            var id = AcceptedIdRx.Match(data);
                            if (id.Success) s.Current.MessageId = "<" + id.Groups[1].Value + ">";
                        }
                    }
                }
                if (evt == "-") { EmitSession(c, s, direction); sessions.Remove(sid); }
            }
            bool active = _o.NowMs - c.LastWriteMs < _o.SmtpIdleMs;
            long safe = offset;
            foreach (var s in sessions.Values)
            {
                if (active && fileLastMs - s.LastMs < _o.SmtpIdleMs) safe = Math.Min(safe, s.StartOffset);
                else EmitSession(c, s, direction);
            }
            return safe;
        }

        static void FinishTxn(SmtpSession s)
        {
            if (s.Current == null) return;
            s.Done.Add(s.Current);
            s.Current = null;
        }

        static string TxnStatus(SmtpTxn x, string direction)
        {
            string r = x.Response ?? "";
            if (r.StartsWith("2")) return direction == "Receive" ? "Accepted" : "Sent";
            if (r.StartsWith("5")) return "Rejected";
            if (r.StartsWith("4")) return "Deferred";
            if (x.LastError != null) return x.LastError.StartsWith("5") ? "Rejected" : "Deferred";
            return "Incomplete";
        }

        /// <summary>One smtp_transaction row per mail transaction of the session (columns of Writer.InsertSmtp).</summary>
        void EmitSession(ParseContext c, SmtpSession s, string direction)
        {
            FinishTxn(s);
            if (s.Done.Count == 0)
            {
                if (s.Proxied) { Noise(c, "Client submission proxied to a mailbox server (recorded there)", s.Lines); return; }
                string ip = s.Remote ?? "";
                int colon = ip.LastIndexOf(':');
                if (colon > 0) ip = ip.Substring(0, colon);
                long known;
                string reason = "Connection without message (" + ip + ")";
                if (!c.Result.NoiseReasons.TryGetValue(reason, out known) && c.Result.NoiseReasons.Count > 40) reason = "Connection without message (other addresses)";
                Noise(c, reason, s.Lines);
                return;
            }
            bool kept = false;
            foreach (var x in s.Done)
            {
                if (x.StartMs < _o.RetentionCutoffMs) continue;
                if (IsSystemAddress(x.MailFrom)) continue;
                string remote, helo, auth;
                if (s.ProxyIp != null)
                {
                    // Show the real client of a proxied submission, not the front end that relayed it.
                    remote = s.ProxyIp + (s.ProxyPort != null ? ":" + s.ProxyPort : "");
                    helo = s.ProxyHelo;
                    auth = "Authenticated client (proxied by " + (Identity.ServerName(s.Helo) ?? "front end") + ")";
                }
                else { remote = s.Remote; helo = s.Helo; auth = s.Auth; }
                c.Smtp.Add(new object[] {
                    x.StartMs, x.EndMs > 0 ? (object)x.EndMs : null, c.Server, direction, c.Role, s.Connector, s.Id, s.Local, remote, helo, s.Tls, auth,
                    x.MailFrom, (long)x.Rcpts.Count, Identity.Cap(string.Join(";", x.Rcpts), 4000), x.MessageId, x.InternalId, TxnStatus(x, direction),
                    Identity.Cap(x.Response ?? x.LastError, 500), x.StartMs >= _o.DetailCutoffMs ? Packed.Pack(Transcript(s, x)) : null });
                kept = true;
            }
            if (kept) c.Result.Kept += s.Lines;
            else Noise(c, "Probe or system message (SMTP)", s.Lines);
        }

        string Transcript(SmtpSession s, SmtpTxn x)
        {
            var sb = new StringBuilder();
            Action<SmtpLine> add = l =>
            {
                sb.Append(TimeUtil.Format(l.Time, _o.Zone, "HH:mm:ss.fff")).Append(' ').Append(l.Tag).Append(' ').Append(l.Data);
                if (!string.IsNullOrEmpty(l.Context)) sb.Append("  [").Append(l.Context).Append(']');
                sb.Append('\n');
            };
            foreach (var l in s.Preamble) add(l);
            foreach (var l in x.Lines) add(l);
            return Identity.Cap(sb.ToString(), 12000);
        }

        // ================================================================ message tracking

        static readonly string[] TrackingNames = { "date-time", "client-ip", "client-hostname", "server-ip", "server-hostname", "source-context", "connector-id", "source",
            "event-id", "internal-message-id", "message-id", "network-message-id", "recipient-address", "recipient-status", "total-bytes",
            "recipient-count", "related-recipient-address", "reference", "message-subject", "sender-address", "return-path", "message-info",
            "directionality", "log-id" };

        /// <summary>One message_event row per tracking event of a real message (columns of Writer.InsertMessage).</summary>
        long ParseTracking(ParseContext c)
        {
            long offset = c.StartOffset;
            var idx = new int[TrackingNames.Length];
            Action bind = () => { for (int i = 0; i < TrackingNames.Length; i++) idx[i] = c.Map.Index(TrackingNames[i]); };
            if (c.Map.Load(c.Fields)) bind();
            Func<int, string> get = i => c.Split.Get(idx[i]);
            Func<string, object> v = o => string.IsNullOrEmpty(o) ? null : o;
            foreach (var line in LogReader.Lines(c.Path, offset))
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
                if (!c.Map.Loaded) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!c.Split.TryTime(idx[0], out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.RetentionCutoffMs) { Noise(c, "Older than retention", 1); continue; }
                string evt = (get(8) ?? "").ToUpperInvariant();
                if (_ignoredEvents.Contains(evt)) { Noise(c, "Shadow redundancy event (" + evt + ")", 1); continue; }
                string sender = (c.Split.GetCached(idx[19]) ?? "").ToLowerInvariant();
                string recipients = (get(12) ?? "").ToLowerInvariant();
                if (sender.Length > 0 && Remember(c.Memo.SystemAddresses, sender, IsSystemAddress)) { Noise(c, "System or probe message", 1); continue; }
                if (recipients.Length > 0 && AllSystem(recipients)) { Noise(c, "System or probe message", 1); continue; }
                c.Result.Kept++;
                c.Messages.Add(new object[] {
                    t, c.Server, evt, v(get(7)), v(get(10)), v(get(9)), v(get(11)), v(sender), v(Identity.Cap(recipients, 8000)), v(Identity.Cap(get(13), 2000)),
                    (long)c.Split.GetInt(idx[15], 0), c.Split.GetLong(idx[14], 0), v(Identity.Cap(get(18), 300)), v(get(1)), v(get(2)), v(get(3)), v(get(4)), v(get(6)),
                    v(Identity.Cap(get(5), 400)), v(Identity.Cap(get(16), 1000)), v(Identity.Cap(get(17), 300)), v(get(22)), v(Identity.Cap(get(21), 400)), v(get(20)), v(get(23)) });
            }
            return offset;
        }

        bool AllSystem(string recipients)
        {
            int start = 0;
            while (start <= recipients.Length)
            {
                int end = recipients.IndexOf(';', start);
                if (end < 0) end = recipients.Length;
                if (end > start && !IsSystemAddress(recipients.Substring(start, end - start))) return false;
                start = end + 1;
            }
            return true;
        }
    }
}
