// =============================================================================
//  Exchange Log Report - engine, part 3: collector (log files -> SQLite)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.6.1
//
//  One call of ProcessFile reads the new part of one log file, keeps the lines of
//  real users / real messages, counts the others by reason ("noise"), and saves
//  the new read position in the same transaction: an interrupted collection
//  restarts exactly where it stopped, without duplicates.
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
        readonly Dictionary<string, List<long[]>> _pending = new Dictionary<string, List<long[]>>(StringComparer.Ordinal);
        readonly List<long[]> _recovered = new List<long[]>();

        static readonly Regex QueuedRx = new Regex(@"<([^>\s]+)>[^\[]*\[InternalId=(\d+)", RegexOptions.Compiled);
        static readonly Regex AcceptedIdRx = new Regex(@"^2\d\d\s+[\d.]+\s+\S*\s*<([^>\s]+@[^>\s]+)>", RegexOptions.Compiled);
        static readonly Regex InternetIdRx = new Regex(@"InternetMessageId\s*<([^>\s]+)>", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        static readonly Regex TlsRx = new Regex(@"SP_PROT_(TLS|SSL)(\d)_(\d)", RegexOptions.Compiled);
        static readonly Regex CafeRx = new Regex(@"cafeReqId=([0-9a-fA-F-]{36})", RegexOptions.Compiled);

        public long RecoveredCount { get { return _recovered.Count; } }

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
        }

        static Regex Build(string[] patterns)
        {
            var list = (patterns ?? new string[0]).Where(p => !string.IsNullOrWhiteSpace(p)).ToArray();
            if (list.Length == 0) return null;
            return new Regex(string.Join("|", list.Select(p => "(?:" + p + ")")), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);
        }

        // ================================================================ noise rules

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

        // ================================================================ file processing

        sealed class FileContext
        {
            public FileState State;
            public FileResult Result;
            public SqliteTransaction Tx;
            public string Server, Role, Path;
            public long LastWriteMs, FileId;
            public FieldMap Map = new FieldMap();
            public FieldSplitter Split = new FieldSplitter();
            public Dictionary<string, UsageAcc> Usage = new Dictionary<string, UsageAcc>(StringComparer.Ordinal);
            public Dictionary<string, ActionAcc> Actions = new Dictionary<string, ActionAcc>(StringComparer.Ordinal);
            public Dictionary<string, ClientAcc> Clients = new Dictionary<string, ClientAcc>(StringComparer.Ordinal);
            public HashSet<ClientSession> Touched = new HashSet<ClientSession>();
            public SqliteCommand InsertEvent, InsertIis, InsertSmtp, InsertMessage;
        }

        sealed class UsageAcc
        {
            public string Day, Server, User, Protocol, Mailbox, ClientIp, UserAgent;
            public long Requests, Successes, ClientErrors, ServerErrors, BytesIn, BytesOut, TotalMs, MaxMs, LastSuccessMs, LastFailureMs, Slow;
            public long FirstMs = long.MaxValue, LastMs;
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
        }

        static void Noise(FileContext c, string reason, long lines)
        {
            long n;
            c.Result.NoiseReasons.TryGetValue(reason, out n);
            c.Result.NoiseReasons[reason] = n + lines;
            c.Result.Noise += lines;
        }

        static void Seen(FileContext c, long t)
        {
            if (c.Result.FirstMs == 0 || t < c.Result.FirstMs) c.Result.FirstMs = t;
            if (t > c.Result.LastMs) c.Result.LastMs = t;
        }

        /// <summary>Reads the new part of one file. Kind: HttpProxy, Iis, SmtpReceive, SmtpSend, Tracking, MapiBackEnd, EasBackEnd, Imap4 or Pop3.</summary>
        public FileResult ProcessFile(string server, string kind, string role, string path)
        {
            var result = new FileResult { Server = server, Kind = kind, Path = path };
            var clock = Stopwatch.StartNew();
            int deferredMark = _deferred.Count;
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists) { result.Error = "File not found"; return result; }
                var state = _store.GetFile(server, kind, path) ?? new FileState { Server = server, Kind = kind, Path = path };
                long length = info.Length;
                if (length < state.Offset) { state.Offset = 0; state.Fields = null; result.Reset = true; }
                if (length == state.Offset) { result.Unchanged = true; return result; }
                long startOffset = state.Offset, newOffset;
                using (var tx = _store.Begin())
                {
                    _tx = tx;
                    var c = new FileContext
                    {
                        State = state, Result = result, Tx = tx, Server = server, Role = role, Path = path,
                        LastWriteMs = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                    };
                    c.FileId = _store.FileId(state, tx);
                    switch (kind)
                    {
                        case "HttpProxy": newOffset = ParseHttpProxy(c); break;
                        case "Iis": newOffset = ParseIis(c); break;
                        case "SmtpReceive": newOffset = ParseSmtp(c, "Receive"); break;
                        case "SmtpSend": newOffset = ParseSmtp(c, "Send"); break;
                        case "Tracking": newOffset = ParseTracking(c); break;
                        case "MapiBackEnd": newOffset = ParseMapiBackEnd(c); break;
                        case "EasBackEnd": newOffset = ParseEasBackEnd(c); break;
                        case "Imap4": newOffset = ParsePopImap(c, "Imap4"); break;
                        case "Pop3": newOffset = ParsePopImap(c, "Pop3"); break;
                        default: throw new ArgumentException("Unknown log kind: " + kind);
                    }
                    FlushUsage(c);
                    FlushActions(c);
                    FlushClients(c);
                    FlushSessions(c);
                    foreach (var cmd in new[] { c.InsertEvent, c.InsertIis, c.InsertSmtp, c.InsertMessage }) if (cmd != null) cmd.Dispose();
                    state.Offset = newOffset;
                    state.Size = length;
                    state.LastWriteMs = c.LastWriteMs;
                    state.Lines += result.Lines; state.Kept += result.Kept; state.Noise += result.Noise;
                    if (result.FirstMs > 0 && (state.FirstMs == 0 || result.FirstMs < state.FirstMs)) state.FirstMs = result.FirstMs;
                    if (result.LastMs > state.LastMs) state.LastMs = result.LastMs;
                    _store.SaveFile(state, tx);
                    _store.AddNoise(_o.RunId, server, kind, result.NoiseReasons, tx);
                    tx.Commit();
                    _tx = null;
                }
                result.BytesRead = newOffset - startOffset;
            }
            catch (Exception ex)
            {
                _tx = null;
                result.Error = ex.GetType().Name + ": " + ex.Message;
                // The transaction was rolled back: sessions in memory may hold lines that are not saved.
                ResetSessions();
                if (_deferred.Count > deferredMark) _deferred.RemoveRange(deferredMark, _deferred.Count - deferredMark);
            }
            result.Seconds = clock.Elapsed.TotalSeconds;
            return result;
        }

        // ================================================================ HttpProxy

        long ParseHttpProxy(FileContext c)
        {
            long offset = c.State.Offset;
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
            if (c.Map.Load(c.State.Fields)) bind();
            string folder = Path.GetFileName(Path.GetDirectoryName(c.Path));
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
                if (t < _o.RetentionCutoffMs) { Noise(c, "Older than retention", 1); continue; }
                int status = c.Split.GetInt(iStatus, 0);
                string user = Identity.User(c.Split.Get(iUser));
                string mailbox = Identity.Mailbox(c.Split.Get(iAnchor));
                string agent = c.Split.Get(iAgent), ip = c.Split.Get(iIp), url = c.Split.Get(iStem);
                if (status == 0 && user == null && url == null) { Noise(c, "Unreadable line", 1); continue; }
                string why = ClientNoise(user, mailbox, agent, ip, url, status);
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
                HandleAccess(c, r);
            }
            return offset;
        }

        // ================================================================ IIS (front end)

        long ParseIis(FileContext c)
        {
            long offset = c.State.Offset;
            int iDate = -1, iTime = -1, iMethod = -1, iStem = -1, iQuery = -1, iUser = -1, iIp = -1, iAgent = -1, iStatus = -1, iSub = -1, iWin = -1, iOut = -1, iIn = -1, iTaken = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iDate = m.Index("date"); iTime = m.Index("time"); iMethod = m.Index("cs-method"); iStem = m.Index("cs-uri-stem");
                iQuery = m.Index("cs-uri-query"); iUser = m.Index("cs-username"); iIp = m.Index("c-ip"); iAgent = m.Index("cs(User-Agent)");
                iStatus = m.Index("sc-status"); iSub = m.Index("sc-substatus"); iWin = m.Index("sc-win32-status");
                iOut = m.Index("sc-bytes"); iIn = m.Index("cs-bytes"); iTaken = m.Index("time-taken");
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
                if (iDate < 0 || iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ' ');
                long t;
                if (!TimeUtil.TryParseUtc(c.Split.Get(iDate) + " " + c.Split.Get(iTime), out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.RetentionCutoffMs) { Noise(c, "Older than retention", 1); continue; }
                int status = c.Split.GetInt(iStatus, 0);
                string user = Identity.User(c.Split.Get(iUser));
                string agent = c.Split.Get(iAgent);
                if (agent != null) agent = agent.Replace('+', ' ');
                string ip = c.Split.Get(iIp), url = c.Split.Get(iStem), query = c.Split.Get(iQuery);
                string why = ClientNoise(user, null, agent, ip, url, status);
                if (why != null) { Noise(c, why, 1); continue; }
                var cafe = query == null ? null : CafeRx.Match(query);
                if (cafe != null && cafe.Success)
                {
                    // Proxied request: HttpProxy has the full record. IIS adds the sub-status and Win32 status of failures.
                    // A 401 with an account and an IIS sub-status / Win32 error is a logon rejected by IIS itself
                    // (HttpProxy logs it as anonymous); a plain 401 of the back end is already in HttpProxy with its user.
                    bool denied = status == 401 && user != null && (c.Split.GetInt(iSub, 0) > 0 || c.Split.GetLong(iWin, 0) != 0);
                    if (status >= 400 && t >= _o.DetailCutoffMs)
                    {
                        if (c.InsertIis == null)
                        {
                            c.InsertIis = _store.Command("INSERT OR REPLACE INTO iis_status(server,request_id,time_ms,status,sub_status,win32,time_taken) VALUES(@s,@r,@t,@st,@sub,@w,@tt);", c.Tx);
                            foreach (var p in new[] { "@s", "@r", "@t", "@st", "@sub", "@w", "@tt" }) c.InsertIis.Parameters.Add(p, SqliteType.Text);
                        }
                        var ps = c.InsertIis.Parameters;
                        ps["@s"].Value = c.Server; ps["@r"].Value = cafe.Groups[1].Value; ps["@t"].Value = t; ps["@st"].Value = status;
                        ps["@sub"].Value = c.Split.GetInt(iSub, 0); ps["@w"].Value = c.Split.GetLong(iWin, 0); ps["@tt"].Value = c.Split.GetLong(iTaken, 0);
                        c.InsertIis.ExecuteNonQuery();
                        c.Result.Kept++; c.Result.Stored++;
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
                        HandleAccess(c, rejected);
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
                HandleAccess(c, r);
            }
            return offset;
        }

        // ================================================================ client access: aggregates, details, recovery

        void HandleAccess(FileContext c, AccessRecord r)
        {
            r.User = Canonical(r.User);
            string outcome = Outcome(r.Status);
            bool failure = outcome != "Success";
            bool slow = !failure && _o.SlowRequestMs > 0 && r.DurationMs >= _o.SlowRequestMs && !LongRunning(r);
            string day = _days.Day(r.TimeMs);
            string key = day + "|" + r.User + "|" + r.Protocol;
            UsageAcc u;
            if (!c.Usage.TryGetValue(key, out u))
            {
                u = new UsageAcc { Day = day, Server = c.Server, User = r.User, Protocol = r.Protocol };
                c.Usage[key] = u;
            }
            u.Requests++;
            if (outcome == "Success") { u.Successes++; if (r.TimeMs > u.LastSuccessMs) u.LastSuccessMs = r.TimeMs; }
            else
            {
                if (outcome == "ServerError") u.ServerErrors++; else u.ClientErrors++;
                if (r.TimeMs > u.LastFailureMs) u.LastFailureMs = r.TimeMs;
            }
            if (slow) u.Slow++;
            u.BytesIn += r.BytesIn; u.BytesOut += r.BytesOut; u.TotalMs += r.DurationMs;
            if (r.DurationMs > u.MaxMs) u.MaxMs = r.DurationMs;
            if (r.TimeMs < u.FirstMs) u.FirstMs = r.TimeMs;
            if (r.TimeMs >= u.LastMs)
            {
                u.LastMs = r.TimeMs;
                if (!r.FromBackEnd) { u.ClientIp = r.ClientIp; u.UserAgent = Identity.Cap(r.UserAgent, 300); }
            }
            if (r.Mailbox != null) u.Mailbox = r.Mailbox;
            CountAction(c, day, r, failure, slow);
            if (!r.FromBackEnd) CountClient(c, day, r, failure);
            if (r.TimeMs >= _o.DetailCutoffMs) AddToSession(c, r, failure, slow);

            string recoveryKey = r.User + "|" + r.Protocol;
            if (!failure) Resolve(recoveryKey, r.TimeMs);
            bool keepDetail = failure || slow || _o.StoreAllRequests || Watched(r.User, r.Mailbox);
            if (!keepDetail || r.TimeMs < _o.DetailCutoffMs) return;
            long id = InsertEvent(c, r, slow ? "Slow" : outcome);
            if (failure && id > 0) AddPending(recoveryKey, id, r.TimeMs);
        }

        bool LongRunning(AccessRecord r)
        {
            return _longRunning != null && _longRunning.IsMatch(r.Protocol + "|" + (r.Action ?? "") + "|" + (r.Url ?? ""));
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

        long InsertEvent(FileContext c, AccessRecord r, string outcome)
        {
            if (c.InsertEvent == null)
            {
                c.InsertEvent = _store.Command(@"INSERT OR IGNORE INTO access_event(time_ms,server,source,protocol,user,mailbox,client_ip,user_agent,method,url,action,status,sub_status,win32,backend_status,error_code,target_server,auth_type,routing,bytes_in,bytes_out,duration_ms,outcome,request_id,errors)
VALUES(@t,@s,@src,@p,@u,@m,@ip,@ua,@me,@url,@a,@st,@sub,@w,@b,@e,@ts,@at,@ro,@bi,@bo,@d,@o,@rid,@err) RETURNING id;", c.Tx);
                foreach (var p in new[] { "@t", "@s", "@src", "@p", "@u", "@m", "@ip", "@ua", "@me", "@url", "@a", "@st", "@sub", "@w", "@b", "@e", "@ts", "@at", "@ro", "@bi", "@bo", "@d", "@o", "@rid", "@err" })
                    c.InsertEvent.Parameters.Add(p, SqliteType.Text);
            }
            var ps = c.InsertEvent.Parameters;
            Func<object, object> v = x => x ?? DBNull.Value;
            ps["@t"].Value = r.TimeMs; ps["@s"].Value = c.Server; ps["@src"].Value = r.Source; ps["@p"].Value = v(r.Protocol);
            ps["@u"].Value = v(r.User); ps["@m"].Value = v(r.Mailbox); ps["@ip"].Value = v(r.ClientIp); ps["@ua"].Value = v(Identity.Cap(r.UserAgent, 300));
            ps["@me"].Value = v(r.Method); ps["@url"].Value = v(Identity.Cap(r.Url, 300)); ps["@a"].Value = v(r.Action); ps["@st"].Value = r.Status;
            ps["@sub"].Value = v(r.SubStatus); ps["@w"].Value = v(r.Win32); ps["@b"].Value = v(r.BackEndStatus); ps["@e"].Value = v(r.ErrorCode);
            ps["@ts"].Value = v(r.TargetServer); ps["@at"].Value = v(r.AuthType); ps["@ro"].Value = v(r.Routing); ps["@bi"].Value = r.BytesIn;
            ps["@bo"].Value = r.BytesOut; ps["@d"].Value = r.DurationMs; ps["@o"].Value = outcome; ps["@rid"].Value = v(r.RequestId); ps["@err"].Value = v(r.Errors);
            object id = c.InsertEvent.ExecuteScalar();
            if (id == null || id is DBNull) return 0;
            c.Result.Stored++;
            return Convert.ToInt64(id);
        }

        void AddPending(string key, long id, long t)
        {
            List<long[]> list;
            if (!_pending.TryGetValue(key, out list)) { list = new List<long[]>(); _pending[key] = list; }
            list.Add(new[] { id, t });
        }

        /// <summary>A success of the same user and protocol after a failure (within the window) marks the failure as recovered.</summary>
        void Resolve(string key, long t)
        {
            List<long[]> list;
            if (!_pending.TryGetValue(key, out list)) return;
            for (int i = list.Count - 1; i >= 0; i--)
            {
                long failedAt = list[i][1];
                if (t >= failedAt && t - failedAt <= _o.RecoveryWindowMs) { _recovered.Add(new[] { list[i][0], t }); list.RemoveAt(i); }
                else if (t - failedAt > _o.RecoveryWindowMs) list.RemoveAt(i);
            }
            if (list.Count == 0) _pending.Remove(key);
        }

        void LoadPendingFailures()
        {
            if (_store.ReadOnly) return;
            using (var c = _store.Command("SELECT id, user, protocol, time_ms FROM access_event WHERE outcome <> 'Success' AND recovered_ms IS NULL AND time_ms >= @since;"))
            {
                c.Parameters.AddWithValue("@since", _o.NowMs - 2 * 86400000L);
                using (var r = c.ExecuteReader())
                    while (r.Read()) if (!r.IsDBNull(1)) AddPending(r.GetString(1) + "|" + (r.IsDBNull(2) ? "" : r.GetString(2)), r.GetInt64(0), r.GetInt64(3));
            }
        }

        /// <summary>Writes the back-end connections and the recoveries found during the collection. Call once, after the last file.</summary>
        public long Complete()
        {
            CompleteBackEnd();
            if (_recovered.Count == 0) return 0;
            using (var tx = _store.Begin())
            using (var c = _store.Command("UPDATE access_event SET recovered_ms=@r WHERE id=@id AND recovered_ms IS NULL;", tx))
            {
                var pr = c.Parameters.Add("@r", SqliteType.Integer); var pid = c.Parameters.Add("@id", SqliteType.Integer);
                foreach (var x in _recovered) { pid.Value = x[0]; pr.Value = x[1]; c.ExecuteNonQuery(); }
                tx.Commit();
            }
            long n = _recovered.Count;
            _recovered.Clear();
            return n;
        }

        void FlushUsage(FileContext c)
        {
            if (c.Usage.Count == 0) return;
            using (var cmd = _store.Command(@"INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent,slow)
VALUES(@d,@s,@u,@p,@m,@rq,@ok,@ce,@se,@bi,@bo,@tm,@mx,@f,@l,@ls,@lf,@ip,@ua,@sl)
ON CONFLICT(day,server,user,protocol) DO UPDATE SET
 mailbox=COALESCE(excluded.mailbox,mailbox), requests=requests+excluded.requests, successes=successes+excluded.successes,
 client_errors=client_errors+excluded.client_errors, server_errors=server_errors+excluded.server_errors, slow=slow+excluded.slow,
 bytes_in=bytes_in+excluded.bytes_in, bytes_out=bytes_out+excluded.bytes_out, total_ms=total_ms+excluded.total_ms,
 max_ms=MAX(max_ms,excluded.max_ms), first_ms=MIN(first_ms,excluded.first_ms),
 client_ip=CASE WHEN excluded.client_ip IS NULL THEN client_ip WHEN client_ip IS NULL OR excluded.last_ms>=last_ms THEN excluded.client_ip ELSE client_ip END,
 user_agent=CASE WHEN excluded.user_agent IS NULL THEN user_agent WHEN user_agent IS NULL OR excluded.last_ms>=last_ms THEN excluded.user_agent ELSE user_agent END,
 last_ms=MAX(last_ms,excluded.last_ms), last_success_ms=MAX(last_success_ms,excluded.last_success_ms),
 last_failure_ms=MAX(last_failure_ms,excluded.last_failure_ms);", c.Tx))
            {
                var names = new[] { "@d", "@s", "@u", "@p", "@m", "@rq", "@ok", "@ce", "@se", "@bi", "@bo", "@tm", "@mx", "@f", "@l", "@ls", "@lf", "@ip", "@ua", "@sl" };
                foreach (var n in names) cmd.Parameters.Add(n, SqliteType.Text);
                var ps = cmd.Parameters;
                foreach (var u in c.Usage.Values)
                {
                    ps["@d"].Value = u.Day; ps["@s"].Value = u.Server; ps["@u"].Value = u.User; ps["@p"].Value = u.Protocol ?? "Other";
                    ps["@m"].Value = (object)u.Mailbox ?? DBNull.Value; ps["@rq"].Value = u.Requests; ps["@ok"].Value = u.Successes;
                    ps["@ce"].Value = u.ClientErrors; ps["@se"].Value = u.ServerErrors; ps["@bi"].Value = u.BytesIn; ps["@bo"].Value = u.BytesOut;
                    ps["@tm"].Value = u.TotalMs; ps["@mx"].Value = u.MaxMs; ps["@f"].Value = u.FirstMs; ps["@l"].Value = u.LastMs;
                    ps["@ls"].Value = u.LastSuccessMs; ps["@lf"].Value = u.LastFailureMs;
                    ps["@ip"].Value = (object)u.ClientIp ?? DBNull.Value; ps["@ua"].Value = (object)u.UserAgent ?? DBNull.Value; ps["@sl"].Value = u.Slow;
                    cmd.ExecuteNonQuery();
                }
            }
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
        long ParseSmtp(FileContext c, string direction)
        {
            var sessions = new Dictionary<string, SmtpSession>(StringComparer.Ordinal);
            long offset = c.State.Offset, lineStart = offset, fileLastMs = 0;
            int iTime = -1, iConn = -1, iSess = -1, iLocal = -1, iRemote = -1, iEvt = -1, iData = -1, iCtx = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("date-time"); iConn = m.Index("connector-id"); iSess = m.Index("session-id"); iLocal = m.Index("local-endpoint");
                iRemote = m.Index("remote-endpoint"); iEvt = m.Index("event"); iData = m.Index("data"); iCtx = m.Index("context");
            };
            if (c.Map.Load(c.State.Fields)) bind();
            bool receive = direction == "Receive";
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
                if (iSess < 0 || iEvt < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!TimeUtil.TryParseUtc(c.Split.Get(iTime), out t)) { Noise(c, "Unreadable line", 1); continue; }
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

        void EmitSession(FileContext c, SmtpSession s, string direction)
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
                if (c.InsertSmtp == null)
                {
                    c.InsertSmtp = _store.Command(@"INSERT OR IGNORE INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,internal_id,status,response,transcript)
VALUES(@t,@e,@s,@d,@ro,@c,@sid,@l,@r,@h,@tls,@a,@f,@n,@rc,@m,@i,@st,@resp,@tr);", c.Tx);
                    foreach (var p in new[] { "@t", "@e", "@s", "@d", "@ro", "@c", "@sid", "@l", "@r", "@h", "@tls", "@a", "@f", "@n", "@rc", "@m", "@i", "@st", "@resp", "@tr" })
                        c.InsertSmtp.Parameters.Add(p, SqliteType.Text);
                }
                Func<object, object> v = o => o ?? DBNull.Value;
                var ps = c.InsertSmtp.Parameters;
                ps["@t"].Value = x.StartMs; ps["@e"].Value = x.EndMs > 0 ? (object)x.EndMs : DBNull.Value; ps["@s"].Value = c.Server;
                ps["@d"].Value = direction; ps["@ro"].Value = v(c.Role); ps["@c"].Value = v(s.Connector); ps["@sid"].Value = s.Id;
                ps["@l"].Value = v(s.Local);
                if (s.ProxyIp != null)
                {
                    // Show the real client of a proxied submission, not the front end that relayed it.
                    ps["@r"].Value = s.ProxyIp + (s.ProxyPort != null ? ":" + s.ProxyPort : "");
                    ps["@h"].Value = v(s.ProxyHelo);
                    ps["@a"].Value = "Authenticated client (proxied by " + (Identity.ServerName(s.Helo) ?? "front end") + ")";
                }
                else { ps["@r"].Value = v(s.Remote); ps["@h"].Value = v(s.Helo); ps["@a"].Value = v(s.Auth); }
                ps["@tls"].Value = v(s.Tls);
                ps["@f"].Value = v(x.MailFrom); ps["@n"].Value = x.Rcpts.Count;
                ps["@rc"].Value = v(Identity.Cap(string.Join(";", x.Rcpts), 4000)); ps["@m"].Value = v(x.MessageId); ps["@i"].Value = v(x.InternalId);
                ps["@st"].Value = TxnStatus(x, direction); ps["@resp"].Value = v(Identity.Cap(x.Response ?? x.LastError, 500));
                ps["@tr"].Value = x.StartMs >= _o.DetailCutoffMs ? (object)Transcript(s, x) : DBNull.Value;
                if (c.InsertSmtp.ExecuteNonQuery() > 0) c.Result.Stored++;
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

        long ParseTracking(FileContext c)
        {
            long offset = c.State.Offset;
            var idx = new Dictionary<string, int>();
            string[] names = { "date-time", "client-ip", "client-hostname", "server-ip", "server-hostname", "source-context", "connector-id", "source",
                "event-id", "internal-message-id", "message-id", "network-message-id", "recipient-address", "recipient-status", "total-bytes",
                "recipient-count", "related-recipient-address", "reference", "message-subject", "sender-address", "return-path", "message-info",
                "directionality", "log-id" };
            Action bind = () => { foreach (var n in names) idx[n] = c.Map.Index(n); };
            if (c.Map.Load(c.State.Fields)) bind();
            Func<string, string> get = n => { int i; return idx.TryGetValue(n, out i) ? c.Split.Get(i) : null; };
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
                if (!c.Map.Loaded) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!TimeUtil.TryParseUtc(get("date-time"), out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.RetentionCutoffMs) { Noise(c, "Older than retention", 1); continue; }
                string evt = (get("event-id") ?? "").ToUpperInvariant();
                if (_ignoredEvents.Contains(evt)) { Noise(c, "Shadow redundancy event (" + evt + ")", 1); continue; }
                string sender = (get("sender-address") ?? "").ToLowerInvariant();
                string recipients = (get("recipient-address") ?? "").ToLowerInvariant();
                if (IsSystemAddress(sender)) { Noise(c, "System or probe message", 1); continue; }
                if (recipients.Length > 0 && recipients.Split(';').All(a => a.Length == 0 || IsSystemAddress(a))) { Noise(c, "System or probe message", 1); continue; }
                c.Result.Kept++;
                if (c.InsertMessage == null)
                {
                    c.InsertMessage = _store.Command(@"INSERT OR IGNORE INTO message_event(time_ms,server,event_id,source,message_id,internal_id,network_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_ip,server_host,connector,source_context,related_recipient,reference,directionality,message_info,return_path,log_id)
VALUES(@t,@s,@e,@src,@m,@i,@n,@snd,@r,@rs,@rc,@b,@subj,@cip,@ch,@sip,@sh,@con,@ctx,@rel,@ref,@dir,@info,@ret,@log);", c.Tx);
                    foreach (var p in new[] { "@t", "@s", "@e", "@src", "@m", "@i", "@n", "@snd", "@r", "@rs", "@rc", "@b", "@subj", "@cip", "@ch", "@sip", "@sh", "@con", "@ctx", "@rel", "@ref", "@dir", "@info", "@ret", "@log" })
                        c.InsertMessage.Parameters.Add(p, SqliteType.Text);
                }
                Func<object, object> v = o => o == null || (o is string && ((string)o).Length == 0) ? DBNull.Value : o;
                var ps = c.InsertMessage.Parameters;
                ps["@t"].Value = t; ps["@s"].Value = c.Server; ps["@e"].Value = evt; ps["@src"].Value = v(get("source"));
                ps["@m"].Value = v(get("message-id")); ps["@i"].Value = v(get("internal-message-id")); ps["@n"].Value = v(get("network-message-id"));
                ps["@snd"].Value = v(sender); ps["@r"].Value = v(Identity.Cap(recipients, 8000)); ps["@rs"].Value = v(Identity.Cap(get("recipient-status"), 2000));
                ps["@rc"].Value = c.Split.GetInt(idx["recipient-count"], 0); ps["@b"].Value = c.Split.GetLong(idx["total-bytes"], 0);
                ps["@subj"].Value = v(Identity.Cap(get("message-subject"), 300)); ps["@cip"].Value = v(get("client-ip")); ps["@ch"].Value = v(get("client-hostname"));
                ps["@sip"].Value = v(get("server-ip")); ps["@sh"].Value = v(get("server-hostname")); ps["@con"].Value = v(get("connector-id"));
                ps["@ctx"].Value = v(Identity.Cap(get("source-context"), 400)); ps["@rel"].Value = v(Identity.Cap(get("related-recipient-address"), 1000));
                ps["@ref"].Value = v(Identity.Cap(get("reference"), 300)); ps["@dir"].Value = v(get("directionality"));
                ps["@info"].Value = v(Identity.Cap(get("message-info"), 400)); ps["@ret"].Value = v(get("return-path")); ps["@log"].Value = v(get("log-id"));
                if (c.InsertMessage.ExecuteNonQuery() > 0) c.Result.Stored++;
            }
            return offset;
        }
    }
}
