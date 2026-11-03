// =============================================================================
//  Exchange Log Report - engine, part 4: report (SQLite -> CSV + HTML)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 3.0.0
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
        // 0 = every row of every table in the HTML report; a value caps each table (CSV files are always complete).
        public int MaxHtmlRows;
        // Auto: one HTML file while the data to put in it is at most SingleFileMaxMB, else the page and a <FilePrefix>_data folder.
        public string HtmlLayout = "Auto";
        public int SingleFileMaxMB = 200;
        // Size of one data file of the HTML report (a block is never split).
        public long HtmlPackBytes = 8L * 1048576;
        // Folder of the report work file; empty = the report folder (a short path either way: the SQLite library cannot open a longer one).
        public string ScratchFolder;
        public int MemoryBudgetMB = 512, Parallelism;
        public Action<string> Progress;
        public int EffectiveParallelism { get { return Parallelism > 0 ? Parallelism : Math.Max(1, Math.Min(4, Environment.ProcessorCount - 1)); } }
        internal long WorkingBudgetBytes { get { return (long)MemoryBudgetMB * 1048576 / 4; } }
        internal int DatabaseCacheMB { get { return Math.Min(256, MemoryBudgetMB / 4); } }
        // Edge report: every server of the report is an Edge Transport server (SMTP and message tracking only):
        // no client access dataset, SMTP destinations added, Edge layout in the HTML file.
        public bool Edge;
        public string[] EdgeServers = new string[0];
        internal ReportScratch Scratch;
    }

    /// <summary>
    /// What the logs prove about the edge of the organization, for the "Sent to external" status of a recipient: the accepted domains learnt
    /// from the tracking events (metadata mailflow_accepted_domains), and the rules the rows were written with (metadata mailflow_rules): the
    /// Send connectors that stay inside (defaults and Collection.InternalConnectors), the domains configured as ours (Collection.InternalDomains),
    /// the servers whose logs are collected (their names, and the addresses the logs show for them) and whether the set of learnt domains is
    /// full. Every reader of the message status (collection, report, Serve, verification) reads the same stored rules, so a recomputation gives
    /// the stored row. External false: no recipient is ever sent to external (a database of schema 12). Saturated: the set of learnt domains is
    /// full, so it cannot be trusted to hold every domain of ours: no recipient is sent to external either.
    /// </summary>
    public sealed class MailFlowRules
    {
        public const int RulesVersion = 1;
        /// <summary>At most this many learnt domains; a domain of a strong source that arrives when the set is full saturates it.</summary>
        public const int MaxLearnedDomains = 4096;
        /// <summary>The sender of an Originating event (the weakest source: a relay of applications is Originating too) is learnt only while the set holds fewer domains.</summary>
        public const int MaxOriginatingDomains = 1024;
        /// <summary>At most this many addresses of collected servers.</summary>
        public const int MaxServerAddresses = 1024;
        public const string DomainsKey = "mailflow_accepted_domains", RulesKey = "mailflow_rules", PendingKey = "mailflow_pending";
        /// <summary>
        /// The Send connectors of Exchange itself that hand a message to another transport service of the organization: the intra-organization
        /// connector, the EdgeSync connector of an Edge into its site, the front-end proxy, and the connector the Hybrid Configuration Wizard
        /// creates for Exchange Online (Outbound to Office 365 - GUID), whose recipients are mailboxes of the organization in the cloud.
        /// </summary>
        public static readonly string[] DefaultInternalConnectors = { "^Intra-Organization SMTP Send Connector$", "^EdgeSync - Inbound to ", "^Inbound Proxy ", "^Outbound to Office 365" };
        const string SentToExternal = "Sent to external";

        readonly SortedSet<string> _learned = new SortedSet<string>(StringComparer.Ordinal);
        readonly SortedSet<string> _servers = new SortedSet<string>(StringComparer.Ordinal);
        string[] _domains = new string[0], _connectors = new string[0], _defaults = DefaultInternalConnectors;
        System.Text.RegularExpressions.Regex _internal;
        int _addresses;
        public bool External = true;

        /// <summary>The rules of a database without the external status (schema 12 and older): every SENDEXTERNAL stays a hand-off.</summary>
        public static MailFlowRules Off { get { return new MailFlowRules { External = false }; } }
        internal static string SentToExternalStatus { get { return SentToExternal; } }

        public string[] LearnedDomains { get { return _learned.ToArray(); } }
        public int LearnedCount { get { return _learned.Count; } }
        public string[] InternalDomains { get { return (string[])_domains.Clone(); } }
        public string[] InternalConnectors { get { return (string[])_connectors.Clone(); } }
        public string[] Servers { get { return _servers.ToArray(); } }
        public int ServerCount { get { return _servers.Count; } }
        /// <summary>The set of learnt domains is full: it may miss a domain of ours, so no recipient is sent to external.</summary>
        public bool Saturated { get; private set; }
        /// <summary>At least one domain is known as ours: without one, every recipient would look foreign, so none is sent to external.</summary>
        public bool HasDomains { get { return _learned.Count + _domains.Length > 0; } }
        /// <summary>The rules can name a recipient sent to external: on, not saturated, and at least one domain known.</summary>
        public bool Active { get { return External && !Saturated && HasDomains; } }

        /// <summary>A copy with the configured lists of a collection: the learnt domains and the saturation are kept, the servers only ever grow.</summary>
        public MailFlowRules WithConfiguration(IEnumerable<string> internalDomains, IEnumerable<string> internalConnectors, IEnumerable<string> servers)
        {
            var copy = new MailFlowRules { External = External, Saturated = Saturated, _defaults = DefaultInternalConnectors, _addresses = _addresses };
            foreach (var d in _learned) copy._learned.Add(d);
            foreach (var s in _servers) copy._servers.Add(s);
            foreach (var s in servers ?? new string[0]) { string k = ServerKey(s); if (k.Length > 0) copy._servers.Add(k); }
            copy._domains = (internalDomains ?? new string[0]).Select(d => (d ?? "").Trim().TrimStart('@', '.').ToLowerInvariant()).Where(d => d.Length > 0)
                .Distinct(StringComparer.Ordinal).OrderBy(d => d, StringComparer.Ordinal).ToArray();
            copy._connectors = (internalConnectors ?? new string[0]).Where(p => !string.IsNullOrWhiteSpace(p)).Distinct(StringComparer.Ordinal).ToArray();
            return copy;
        }

        /// <summary>A copy of these rules (same lists, domains, servers and state).</summary>
        public MailFlowRules Copy() { var c = WithConfiguration(_domains, _connectors, null); c._defaults = _defaults; return c; }

        /// <summary>
        /// Adds a domain proved to be ours (lower case). strong: a DELIVER or Incoming RECEIVE recipient, or the sender of a STOREDRIVER event;
        /// otherwise the sender of an Originating event, learnt only below MaxOriginatingDomains. A strong domain that arrives when the set is full
        /// saturates it. True when the rules changed.
        /// </summary>
        internal bool Learn(string domain, bool strong = true)
        {
            if (string.IsNullOrEmpty(domain) || Saturated || _learned.Contains(domain)) return false;
            if (_learned.Count >= MaxLearnedDomains)
            {
                if (!strong) return false;
                Saturated = true;
                return true;
            }
            if (!strong && _learned.Count >= MaxOriginatingDomains) return false;
            _learned.Add(domain);
            return true;
        }

        /// <summary>
        /// The accepted domains a tracking event proves, strongest first: the recipients of a DELIVER (a mailbox here received it) and of an
        /// Incoming RECEIVE (mail from outside addressed to us), the sender of a STOREDRIVER SUBMIT or RECEIVE (a mailbox here sent it), then the
        /// sender of any other Originating event. Returns the number of changes.
        /// </summary>
        public int LearnFrom(string evt, string source, string sender, string recipients, string directionality)
        {
            int added = 0;
            if (evt == "DELIVER" || (evt == "RECEIVE" && string.Equals(directionality, "Incoming", StringComparison.OrdinalIgnoreCase)))
                foreach (var r in (recipients ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)) if (Learn(DomainOf(r))) added++;
            if (string.Equals(source, "STOREDRIVER", StringComparison.OrdinalIgnoreCase) && (evt == "SUBMIT" || evt == "RECEIVE"))
            { if (Learn(DomainOf(sender))) added++; }
            else if (string.Equals(directionality, "Originating", StringComparison.OrdinalIgnoreCase))
            { if (Learn(DomainOf(sender), false)) added++; }
            return added;
        }

        /// <summary>
        /// The address of a collected server that a tracking event shows: its server-ip, when its server-hostname names the server that logged
        /// the event or another collected server (the name and the address of one host). True when the address was added.
        /// </summary>
        public bool LearnServerAddress(string server, string serverHost, string serverIp)
        {
            if (string.IsNullOrWhiteSpace(serverIp) || string.IsNullOrWhiteSpace(serverHost) || _addresses >= MaxServerAddresses) return false;
            System.Net.IPAddress ip;
            if (!System.Net.IPAddress.TryParse(serverIp.Trim(), out ip)) return false;
            string host = ServerKey(serverHost);
            if (host != ServerKey(server) && !_servers.Contains(host)) return false;
            if (!_servers.Add(ServerKey(serverIp))) return false;
            _addresses++;
            return true;
        }

        /// <summary>The domain of an address (lower case); null without a usable one (no '@', an address literal, a space or an angle bracket).</summary>
        internal static string DomainOf(string address)
        {
            if (string.IsNullOrEmpty(address)) return null;
            string a = address.Trim();
            int at = a.LastIndexOf('@');
            if (at < 1 || at == a.Length - 1) return null;
            string d = a.Substring(at + 1).ToLowerInvariant();
            if (d[0] == '[' || d[0] == '.' || d.IndexOfAny(new[] { ' ', '<', '>', ';', ',', '"', '\'', '\t' }) >= 0) return null;
            System.Net.IPAddress ip;
            if (System.Net.IPAddress.TryParse(d, out ip)) return null;
            return d;
        }

        /// <summary>A domain or one of its parent domains is in the set (mail.contoso.com is in a set that holds contoso.com).</summary>
        internal static bool InDomainSet(string domain, ICollection<string> set)
        {
            if (string.IsNullOrEmpty(domain) || set.Count == 0) return false;
            for (string d = domain; ; )
            {
                if (set.Contains(d)) return true;
                int dot = d.IndexOf('.');
                if (dot < 0 || dot == d.Length - 1) return false;
                d = d.Substring(dot + 1);
            }
        }

        /// <summary>The accepted domains: a learnt or a configured one, exactly or as a parent domain.</summary>
        public bool IsAcceptedDomain(string domain)
        {
            if (string.IsNullOrEmpty(domain)) return false;
            if (InDomainSet(domain, _learned)) return true;
            foreach (var d in _domains) if (domain == d || domain.EndsWith("." + d, StringComparison.Ordinal)) return true;
            return false;
        }

        /// <summary>A recipient whose domain is known and not one of ours; false when its domain is unusable, no domain is known or the set is full.</summary>
        internal bool IsForeign(string recipient)
        {
            if (Saturated || !HasDomains) return false;
            string d = DomainOf(recipient);
            return d != null && !IsAcceptedDomain(d);
        }

        /// <summary>A connector that stays inside: a default or configured one, or no connector at all (nothing is claimed from a missing field).</summary>
        public bool IsInternalConnector(string connector)
        {
            if (string.IsNullOrWhiteSpace(connector)) return true;
            if (_internal == null)
                _internal = new System.Text.RegularExpressions.Regex(string.Join("|", _defaults.Concat(_connectors).Select(p => "(?:" + p + ")")),
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
            return _internal.IsMatch(connector);
        }

        internal bool IsCollected(string peer) { return !string.IsNullOrEmpty(peer) && _servers.Contains(peer); }

        /// <summary>The name a server is compared by: the first label of a host name in lower case; an address as written.</summary>
        internal static string ServerKey(string host)
        {
            if (string.IsNullOrWhiteSpace(host)) return "";
            string h = host.Trim();
            System.Net.IPAddress ip;
            if (System.Net.IPAddress.TryParse(h, out ip)) return h.ToLowerInvariant();
            return ReportBuilder.RouteBuilder.Short(h);
        }

        /// <summary>The next host of a SEND event: server-hostname, else server-ip.</summary>
        internal static string PeerKey(string serverHost, string serverIp) { return ServerKey(string.IsNullOrWhiteSpace(serverHost) ? serverIp : serverHost); }

        /// <summary>A reply that accepts the recipient: a 2xx SMTP code.</summary>
        internal static bool Accepted(string reply)
        {
            if (string.IsNullOrEmpty(reply)) return false;
            string r = reply.TrimStart();
            return r.Length >= 3 && r[0] == '2' && char.IsDigit(r[1]) && char.IsDigit(r[2]) && (r.Length == 3 || !char.IsDigit(r[3]));
        }

        public string DomainsText() { return string.Join(";", _learned); }

        public string RulesText()
        {
            var buffer = new System.Buffers.ArrayBufferWriter<byte>(256);
            using (var w = new Utf8JsonWriter(buffer))
            {
                w.WriteStartObject();
                w.WriteNumber("version", RulesVersion);
                foreach (var list in new[] { new KeyValuePair<string, IEnumerable<string>>("defaultConnectors", _defaults), new KeyValuePair<string, IEnumerable<string>>("internalConnectors", _connectors),
                    new KeyValuePair<string, IEnumerable<string>>("internalDomains", _domains), new KeyValuePair<string, IEnumerable<string>>("servers", _servers) })
                {
                    w.WriteStartArray(list.Key);
                    foreach (var x in list.Value) w.WriteStringValue(x);
                    w.WriteEndArray();
                }
                w.WriteBoolean("saturated", Saturated);
                w.WriteEndObject();
            }
            return Encoding.UTF8.GetString(buffer.WrittenSpan);
        }

        /// <summary>
        /// The rules of the two metadata texts (null: absent). Without rules text the defaults apply; an unreadable one gives no external status.
        /// Rules of another rule version keep their learnt domains, servers and saturation with External false: the next collection writes them
        /// again with the rules of this version, so the domains it learnt are not lost.
        /// </summary>
        public static MailFlowRules Parse(string rulesText, string domainsText)
        {
            var rules = new MailFlowRules();
            foreach (var d in (domainsText ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)) rules._learned.Add(d.Trim().ToLowerInvariant());
            if (string.IsNullOrEmpty(rulesText)) return rules;
            try
            {
                using (var doc = JsonDocument.Parse(rulesText))
                {
                    var root = doc.RootElement;
                    Func<string, string[]> list = name => root.GetProperty(name).EnumerateArray().Select(e => e.GetString()).Where(x => x != null).ToArray();
                    JsonElement flag;
                    if (root.TryGetProperty("saturated", out flag) && flag.ValueKind == JsonValueKind.True) rules.Saturated = true;
                    if (root.GetProperty("version").GetInt32() != RulesVersion)
                    {
                        rules.External = false;
                        JsonElement servers;
                        if (root.TryGetProperty("servers", out servers) && servers.ValueKind == JsonValueKind.Array)
                            foreach (var e in servers.EnumerateArray()) if (e.ValueKind == JsonValueKind.String) rules._servers.Add(e.GetString());
                        rules.CountAddresses();
                        return rules;
                    }
                    rules._defaults = list("defaultConnectors");
                    rules._connectors = list("internalConnectors");
                    rules._domains = list("internalDomains");
                    foreach (var s in list("servers")) rules._servers.Add(s);
                    rules.CountAddresses();
                    rules.IsInternalConnector("x");
                }
            }
            catch (Exception e) when (e is JsonException || e is KeyNotFoundException || e is InvalidOperationException || e is ArgumentException || e is FormatException) { return Off; }
            return rules;
        }

        void CountAddresses()
        {
            System.Net.IPAddress ip;
            _addresses = _servers.Count(s => System.Net.IPAddress.TryParse(s, out ip));
        }

        /// <summary>The stored rules of a database, read with the command factory of the caller (its connection and transaction).</summary>
        internal static MailFlowRules Read(Func<string, SqliteCommand> command)
        {
            string rules = null, domains = null;
            using (var c = command("SELECT key,value FROM metadata WHERE key IN('" + RulesKey + "','" + DomainsKey + "');"))
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    string v = r.IsDBNull(1) ? null : Convert.ToString(r.GetValue(1), CultureInfo.InvariantCulture);
                    if (r.GetString(0) == RulesKey) rules = v; else domains = v;
                }
            return Parse(rules, domains);
        }

        /// <summary>
        /// The domains and server addresses that a collection learnt and has not applied yet (metadata mailflow_pending, JSON): the collection
        /// applies them once, at its end; one that was interrupted leaves them to the next. Empty lists when there are none.
        /// </summary>
        public static void ParsePending(string text, out string[] domains, out string[] servers)
        {
            string[] d = new string[0], s = new string[0];
            if (!string.IsNullOrEmpty(text))
                try
                {
                    using (var doc = JsonDocument.Parse(text))
                    {
                        var root = doc.RootElement;
                        Func<string, string[]> list = name =>
                        {
                            JsonElement e;
                            return root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out e) && e.ValueKind == JsonValueKind.Array
                                ? e.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()).ToArray() : new string[0];
                        };
                        d = list("domains"); s = list("servers");
                    }
                }
                catch (JsonException) { }
            domains = d; servers = s;
        }

        public static string PendingText(IEnumerable<string> domains, IEnumerable<string> servers)
        {
            var buffer = new System.Buffers.ArrayBufferWriter<byte>(256);
            using (var w = new Utf8JsonWriter(buffer))
            {
                w.WriteStartObject();
                w.WriteStartArray("domains"); foreach (var d in domains) w.WriteStringValue(d); w.WriteEndArray();
                w.WriteStartArray("servers"); foreach (var s in servers) w.WriteStringValue(s); w.WriteEndArray();
                w.WriteEndObject();
            }
            return Encoding.UTF8.GetString(buffer.WrittenSpan);
        }

        /// <summary>Adds learnt domains and server addresses (the pending ones of an earlier collection), with the bounds of learning.</summary>
        internal void AddLearnt(IEnumerable<string> domains, IEnumerable<string> servers)
        {
            foreach (var d in domains) Learn((d ?? "").Trim().ToLowerInvariant());
            System.Net.IPAddress ip;
            foreach (var s in servers)
                if (!string.IsNullOrEmpty(s) && _addresses < MaxServerAddresses && System.Net.IPAddress.TryParse(s, out ip) && _servers.Add(s)) _addresses++;
        }

        /// <summary>The same rules and domains (the texts the metadata holds).</summary>
        public bool SameAs(MailFlowRules other)
        {
            return other != null && External == other.External && RulesText() == other.RulesText() && DomainsText() == other.DomainsText();
        }
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
        public ReportRows Rows = new ReportRows();
        public bool Html = true;
        internal long SessionsWithFailures, FailedSessionCount;
        internal List<object[]> FailureSample = new List<object[]>();
        public Dataset(string name, string fileName) { Name = name; FileName = fileName; }
        internal Dataset(string name, string fileName, ReportScratch scratch) : this(name, fileName) { Rows = new ReportRows(scratch); }
        public Column Add(string name, string kind) { var c = new Column(name, kind); Columns.Add(c); return c; }
    }

    public sealed class ReportFile { public string Path, Dataset; public long Rows, Bytes; }

    public sealed class ReportResult
    {
        public string Folder, HtmlPath, Title;
        public List<ReportFile> Files = new List<ReportFile>();
        public Dictionary<string, long> Counts = new Dictionary<string, long>();
        public List<string> Notes = new List<string>();
        /// <summary>Rows of the servers dataset: server, verdict, real users, requests, failed, unresolved, protocols, first, last, days, SMTP in, out, rejected, messages...</summary>
        public List<object[]> ServerRows = new List<object[]>();
        /// <summary>Time of each step, slowest first (execution log).</summary>
        public List<string> Steps = new List<string>();
        /// <summary>Detailed report: the main problems of the period, for the body of the e-mail (top 10 per kind).</summary>
        public List<ReportHighlight> Highlights = new List<ReportHighlight>();
        public long PeakBufferBytes, SpilledRows;
        public int MemoryBudgetMB, Parallelism;
        public int DatabaseCacheMB;
        public long TranscriptReads, TranscriptBytes, ScratchPeakBytes;
        /// <summary>Folder of the report work file and the free space of its drive when the report started (-1: unknown).</summary>
        public string ScratchFolder;
        public long ScratchFreeBytes;
        /// <summary>Folder of the data files next to the page; null when the report is one HTML file.</summary>
        public string HtmlDataFolder;
        public int HtmlDataFiles;
        public long HtmlDataBytes;
        /// <summary>The data folder of the earlier report (renamed .previous) when it could not be removed once the new report was
        /// in place; null otherwise. The report is complete either way and Notes says to delete it.</summary>
        public string HtmlPreviousDataFolder;
        /// <summary>HTML tables cut by Report.MaxHtmlRows, as "name (rows of total rows)"; empty when every row is in the page.</summary>
        public List<string> HtmlCutTables = new List<string>();
        public long StagedRows;
    }

    /// <summary>One kind of problem of a Detailed report and its first rows (e-mail summary).</summary>
    public sealed class ReportHighlight
    {
        public string Title, Hint;
        public string[] Columns;
        public List<string[]> Rows = new List<string[]>();
        /// <summary>Number of items of this kind in the report (the rows are the first 10).</summary>
        public long Total;
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
            var watch = System.Diagnostics.Stopwatch.StartNew();
            long n = 0;
            try
            {
                using (var c = store.Command(sql, p))
                using (var r = c.ExecuteReader())
                {
                    int transcript = -1;
                    for (int i = 0; i < r.FieldCount; i++) if (string.Equals(r.GetName(i), "transcript", StringComparison.OrdinalIgnoreCase)) transcript = i;
                    while (r.Read())
                    {
                        var row = new object[r.FieldCount];
                        for (int i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : Packed.Unpack(r.GetValue(i));
                        // Transcripts stored before the AUTH payloads were removed at collection are cleaned when they are read.
                        if (transcript >= 0 && row[transcript] is string) row[transcript] = SmtpAuth.RedactTranscript((string)row[transcript]);
                        if (_steps != null && transcript >= 0 && row[transcript] is string)
                        {
                            _transcriptReads++;
                            _transcriptBytes += ((string)row[transcript]).Length * 2L;
                        }
                        n++;
                        yield return row;
                    }
                }
            }
            finally { Timed(watch, n, sql); }
        }

        static IEnumerable<List<T>> Batches<T>(IEnumerable<T> rows, int size, Func<T, int> weight = null)
        {
            var batch = new List<T>();
            int count = 0;
            foreach (var row in rows)
            {
                batch.Add(row); count += weight == null ? 1 : Math.Max(1, weight(row));
                if (count >= size) { yield return batch; batch = new List<T>(); count = 0; }
            }
            if (batch.Count > 0) yield return batch;
        }

        /// <summary>Time of each step of the report being built (query and use of its rows, files), for the execution log.</summary>
        [ThreadStatic] static List<KeyValuePair<double, string>> _steps;
        [ThreadStatic] static long _transcriptReads, _transcriptBytes;

        static void Timed(System.Diagnostics.Stopwatch watch, long rows, string what)
        {
            if (_steps == null) return;
            string text = what.Length > 140 ? what.Substring(0, 140) + "..." : what;
            _steps.Add(new KeyValuePair<double, string>(watch.Elapsed.TotalSeconds, rows.ToString("N0", CultureInfo.InvariantCulture) + " rows: " + text));
        }

        static long L(object v) { return v == null ? 0 : Convert.ToInt64(v, CultureInfo.InvariantCulture); }

        static string S(object v)
        {
            if (v is byte[]) return Packed.Text(v);
            return v == null ? null : Convert.ToString(v, CultureInfo.InvariantCulture);
        }

        static T Get<T>(Dictionary<string, T> d, string key) where T : new()
        {
            T v;
            if (!d.TryGetValue(key, out v)) { v = new T(); d[key] = v; }
            return v;
        }

        internal sealed class ServerStats
        {
            public long Users, Requests, Failed, Unresolved, FirstMs, LastMs, Days, SmtpIn, SmtpOut, SmtpRejected, Messages, Deliveries, MessageFailures;
            public List<object[]> Protocols = new List<object[]>();
        }

        internal sealed class DayStats { public long Users, Requests, Failed, SmtpIn, SmtpOut, Messages; }

        // ------------------------------------------------------------------ datasets shared with Serve
        // Column lists, statements and row builders of the servers, daily, users, issues and operations datasets. The report reads
        // them through its store; Serve reads them through its read-only connection, with its own filters and ISO times.

        internal static readonly string[] IssueColumns = { "Time:time", "Server:text", "Source:text", "Protocol:text", "User:text", "Mailbox:text", "Client IP:text", "Client:text",
            "Method:text", "URL:text", "Action:text", "Status:num", "Sub-status:num", "Win32 status:num", "Back-end status:num", "Error code:text",
            "Target server:text", "Authentication:text", "Duration (ms):num", "Outcome:text", "Resolution:text", "Recovered after:text",
            "Request ID:text", "User agent:text", "Errors:text" };
        internal static readonly string[] ServerColumns = { "Server:text", "Verdict:text", "Real users:num", "Requests:num", "Failed requests:num", "Unresolved failures:num",
            "Protocols:text", "First activity:time", "Last activity:time", "Active days:num", "SMTP received:num", "SMTP sent:num",
            "SMTP rejected:num", "Messages:num", "Deliveries:num", "Message failures:num", "Protocol detail:steps" };
        internal static readonly string[] DailyColumns = { "Day:text", "Server:text", "Real users:num", "Requests:num", "Failed requests:num", "SMTP received:num", "SMTP sent:num", "Messages:num" };
        internal static readonly string[] UserColumns = { "User:text", "Mailbox:text", "Protocols:text", "Clients:text", "Servers:text", "Requests:num", "Failed requests:num",
            "Unresolved failures:num", "Active days:num", "First seen:time", "Last seen:time", "Last client IP:text", "Last user agent:text", "Protocol detail:steps",
            "Clients and devices:steps", "Authentication:text", "Identifiers:steps" };
        internal static readonly string[] AuthenticationColumns = { "Protocol:text", "Authentication:text", "OAuth possible:text", "Users:num", "Clients:num", "Devices:num",
            "Requests:num", "Failed requests:num", "Active days:num", "First seen:time", "Last seen:time", "Servers:text", "Clients detail:steps" };
        internal static readonly string[] OperationColumns = { "Protocol:text", "Operation:text", "Requests:num", "Share of protocol (%):num", "Failures:num", "Failure rate (%):num",
            "Slow:num", "Average (ms):num", "Max (ms):num", "Servers:text" };

        /// <summary>The fields of an issue row (indexes used by IssueResolution and IssueRow), and the join that completes them from the IIS log.</summary>
        internal const string IssueFields = "e.time_ms,e.server,e.source,e.protocol,e.user,e.mailbox,e.client_ip,e.user_agent,e.method,e.url,e.action,e.status," +
            "COALESCE(e.sub_status,i.sub_status),COALESCE(e.win32,i.win32),e.backend_status,e.error_code,e.target_server,e.auth_type," +
            "COALESCE(NULLIF(e.duration_ms,0),i.time_taken),e.outcome,e.recovered_ms,e.request_id,e.errors";
        internal const string IssueFrom = " FROM access_event e LEFT JOIN iis_status i ON i.server=e.server AND i.request_id=e.request_id ";

        /// <summary>
        /// Resolution of an issue row (IssueFields): Slow success, Recovered (recovered_ms), Recovered later (a later success of the same user and
        /// protocol the same day or the next, lastSuccess(user, protocol, day) = MAX(last_success_ms) of access_usage, 0 when none), Unresolved; ""
        /// for a success.
        /// </summary>
        internal static string IssueResolution(object[] r, TimeZoneInfo zone, Func<string, string, string, long> lastSuccess, out string after)
        {
            return IssueResolution(L(r[0]), S(r[4]), S(r[3]), S(r[19]), L(r[20]), zone, ms => TimeUtil.Day(ms, zone), lastSuccess, true, out after);
        }

        /// <summary>
        /// The same resolution from the fields it reads: time, user, protocol, outcome, recovered_ms. day(ms) is the day of an instant in zone;
        /// describe=false leaves after null (the resolution alone, for the counts).
        /// </summary>
        internal static string IssueResolution(long t, string user, string protocol, string outcome, long recovered, TimeZoneInfo zone, Func<long, string> day,
            Func<string, string, string, long> lastSuccess, bool describe, out string after)
        {
            after = null;
            if (outcome == "Slow") return "Slow success";
            if (outcome == "Success") return "";
            if (recovered > 0) { if (describe) after = TimeUtil.Duration((recovered - t) / 1000.0); return "Recovered"; }
            long later = Math.Max(lastSuccess(user, protocol, day(t)), lastSuccess(user, protocol, day(t + 86400000L)));
            if (later > t) { if (describe) after = "later (" + TimeUtil.Format(later, zone, "yyyy-MM-dd HH:mm") + ")"; return "Recovered later"; }
            return "Unresolved";
        }

        internal static object[] IssueRow(object[] r, Func<long, object> local, string resolution, string after)
        {
            return new object[] { local(L(r[0])), S(r[1]), S(r[2]), S(r[3]), S(r[4]), S(r[5]), S(r[6]), Identity.Client(S(r[7])), S(r[8]), S(r[9]), S(r[10]),
                r[11], r[12], r[13], r[14], S(r[15]), S(r[16]), S(r[17]), r[18], S(r[19]), resolution, after, S(r[21]), S(r[7]), S(r[22]) };
        }

        /// <summary>Client access figures per server (and per day x server into daily) from access_usage; usageWhere = " FROM access_usage WHERE ...".</summary>
        internal static Dictionary<string, ServerStats> UsageByServer(Func<string, IEnumerable<object[]>> rows, string usageWhere, Dictionary<string, DayStats> daily)
        {
            var servers = new Dictionary<string, ServerStats>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in rows("SELECT server, COUNT(DISTINCT user), SUM(requests), SUM(client_errors+server_errors), MIN(first_ms), MAX(last_ms), COUNT(DISTINCT day)" + usageWhere + " GROUP BY server;"))
            {
                var s = Get(servers, S(r[0]));
                s.Users = L(r[1]); s.Requests = L(r[2]); s.Failed = L(r[3]); s.FirstMs = L(r[4]); s.LastMs = L(r[5]); s.Days = L(r[6]);
            }
            foreach (var r in rows("SELECT server, protocol, SUM(requests), SUM(client_errors+server_errors)" + usageWhere + " GROUP BY server, protocol ORDER BY 3 DESC;"))
                Get(servers, S(r[0])).Protocols.Add(new object[] { S(r[1]), L(r[2]), L(r[3]) });
            UsageByDay(rows, usageWhere, daily);
            return servers;
        }

        /// <summary>Client access figures per day x server into daily, from access_usage.</summary>
        internal static void UsageByDay(Func<string, IEnumerable<object[]>> rows, string usageWhere, Dictionary<string, DayStats> daily)
        {
            foreach (var r in rows("SELECT day, server, COUNT(DISTINCT user), SUM(requests), SUM(client_errors+server_errors)" + usageWhere + " GROUP BY day, server;"))
            {
                var d = Get(daily, S(r[0]) + "|" + S(r[1]));
                d.Users = L(r[2]); d.Requests = L(r[3]); d.Failed = L(r[4]);
            }
        }

        /// <summary>Servers without client access (Edge Transport, mail flow only): activity dates from the mail flow ranges, days from the daily mail flow.</summary>
        internal static void FinishServers(Dictionary<string, ServerStats> servers, Dictionary<string, DayStats> daily, IEnumerable<KeyValuePair<string, long[]>> flowRange)
        {
            foreach (var kv in flowRange)
            {
                var s = Get(servers, kv.Key);
                if (s.Requests > 0) continue;
                if (s.FirstMs == 0 || kv.Value[0] < s.FirstMs) s.FirstMs = kv.Value[0];
                if (kv.Value[1] > s.LastMs) s.LastMs = kv.Value[1];
            }
            foreach (var kv in servers.Where(x => x.Value.Requests == 0))
                kv.Value.Days = daily.Count(d => d.Key.EndsWith("|" + kv.Key, StringComparison.OrdinalIgnoreCase) && d.Value.SmtpIn + d.Value.SmtpOut + d.Value.Messages > 0);
        }

        /// <summary>Rows of the servers dataset: every configured server (within the server filter) first, used or not, then the other servers seen.</summary>
        internal static List<object[]> ServerRows(Dictionary<string, ServerStats> servers, Dictionary<string, long> unresolvedByServer, string[] configured, string[] filterServers, Func<long, object> local)
        {
            var rows = new List<object[]>();
            var names = new List<string>();
            var filter = new HashSet<string>((filterServers ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)), StringComparer.OrdinalIgnoreCase);
            foreach (var n in configured ?? new string[0]) if ((filter.Count == 0 || filter.Contains(n)) && !names.Contains(n, StringComparer.OrdinalIgnoreCase)) names.Add(n);
            foreach (var n in servers.Keys.OrderBy(x => x)) if (!names.Contains(n, StringComparer.OrdinalIgnoreCase)) names.Add(n);
            foreach (var n in names)
            {
                ServerStats s;
                if (!servers.TryGetValue(n, out s)) s = new ServerStats();
                long unresolved; unresolvedByServer.TryGetValue(n, out unresolved);
                bool access = s.Users > 0, mail = s.SmtpIn + s.SmtpOut + s.Messages > 0;
                string verdict = access && mail ? "In use" : access ? "Client access only" : mail ? "Mail flow only" : "No real usage";
                rows.Add(new object[] { n, verdict, s.Users, s.Requests, s.Failed, unresolved,
                    string.Join(", ", s.Protocols.Select(p => p[0] + " " + L(p[1]).ToString("N0", CultureInfo.InvariantCulture))),
                    local(s.FirstMs), local(s.LastMs), s.Days, s.SmtpIn, s.SmtpOut, s.SmtpRejected, s.Messages, s.Deliveries, s.MessageFailures, s.Protocols });
            }
            return rows;
        }

        /// <summary>Rows of the daily dataset (days d0..d1 of the period, ordinal order of "day|server").</summary>
        internal static List<object[]> DailyRows(Dictionary<string, DayStats> daily, string d0, string d1)
        {
            var rows = new List<object[]>();
            foreach (var kv in daily.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                var key = kv.Key.Split('|');
                if (string.CompareOrdinal(key[0], d0) < 0 || string.CompareOrdinal(key[0], d1) > 0) continue;
                rows.Add(new object[] { key[0], key[1], kv.Value.Users, kv.Value.Requests, kv.Value.Failed, kv.Value.SmtpIn, kv.Value.SmtpOut, kv.Value.Messages });
            }
            return rows;
        }

        /// <summary>A clients-and-devices row of a user's detail, from a row of the clients dataset.</summary>
        internal static object[] DeviceRow(object[] c) { return new object[] { c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[11], c[13] }; }

        /// <summary>The identity_map rows (security identifiers Exchange logged as the user of token requests), for the Identifiers detail of the users.</summary>
        internal const string IdentitySql = "SELECT sid,user,status,names,hints,lines,first_ms,last_ms FROM identity_map";

        /// <summary>
        /// An identity_map row (IdentitySql) in the Identifiers detail: [security identifier, status, evidence, hints, requests, first seen, last seen],
        /// under the SID itself and under its account (resolved, or the account its rows were merged with: status "ambiguous, merged with ...").
        /// A SID resolved without any line of its own was named before its first token request: "resolved (paired in advance)", as -Mode Status says.
        /// </summary>
        internal static void AddIdentity(Dictionary<string, List<object[]>> identitiesOf, object[] r, Func<long, object> local)
        {
            string status = S(r[2]);
            if (status != IdentityMap.Resolved && S(r[1]) != null) status += ", merged with " + S(r[1]);
            else if (status == IdentityMap.Resolved && L(r[5]) == 0) status += " (paired in advance)";
            var cells = new object[] { S(r[0]), status, IdentityMap.EvidenceText(S(r[3])), S(r[4]), L(r[5]), local(L(r[6])), local(L(r[7])) };
            Get(identitiesOf, S(r[0])).Add(cells);
            string user = S(r[1]);
            if (user != null && user != S(r[0])) Get(identitiesOf, user).Add(cells);
        }

        /// <summary>Every identity_map row by user (null when the database has no identity_map: a database of an earlier 3.0 build opened read-only).</summary>
        internal static Dictionary<string, List<object[]>> IdentityRows(Store store, Func<string, IEnumerable<object[]>> rows, Func<long, object> local)
        {
            if (!store.HasTable("identity_map")) return null;
            var identitiesOf = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
            foreach (var r in rows(IdentitySql + " ORDER BY sid;")) AddIdentity(identitiesOf, r, local);
            return identitiesOf;
        }

        /// <summary>
        /// Rows of the users dataset from access_usage (usageWhere = " FROM access_usage WHERE ..."), most requests first. details=false leaves the
        /// protocol detail and the clients and devices out (null) and does not read the protocol detail. The authentication types of a user come from
        /// access_client (clientsWhere = " FROM access_client WHERE ..."); null for a user without client rows.
        /// </summary>
        internal static List<object[]> UserRows(Func<string, IEnumerable<object[]>> rows, string usageWhere, Dictionary<string, long> unresolvedByUser,
            Dictionary<string, List<object[]>> clientsOf, Func<long, object> local, bool details, string clientsWhere, Dictionary<string, List<object[]>> identitiesOf = null)
        {
            var modes = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var r in rows("SELECT user, group_concat(DISTINCT auth_type)" + clientsWhere + " GROUP BY user;"))
                modes[S(r[0]) ?? ""] = AuthMode.ModesOf(S(r[1]));
            var lastSeen = new Dictionary<string, object[]>(StringComparer.Ordinal);
            foreach (var r in rows("SELECT user, client_ip, user_agent FROM (SELECT user, client_ip, user_agent, ROW_NUMBER() OVER (PARTITION BY user ORDER BY last_ms DESC) AS rn" + usageWhere + ") WHERE rn = 1;"))
                lastSeen[S(r[0])] = r;
            var clients = new Dictionary<string, Dictionary<string, long>>(StringComparer.Ordinal);
            foreach (var r in rows("SELECT user, user_agent, SUM(requests)" + usageWhere + " GROUP BY user, user_agent;"))
            {
                var c = Get(clients, S(r[0]));
                string family = Identity.Client(S(r[1]));
                long n; c.TryGetValue(family, out n); c[family] = n + L(r[2]);
            }
            var detail = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
            if (details)
                foreach (var r in rows("SELECT user, protocol, SUM(requests), SUM(client_errors+server_errors), MAX(last_ms), group_concat(DISTINCT server)" + usageWhere + " GROUP BY user, protocol ORDER BY 3 DESC;"))
                    Get(detail, S(r[0])).Add(new object[] { S(r[1]), L(r[2]), L(r[3]), local(L(r[4])), (S(r[5]) ?? "").Replace(",", ", ") });
            var result = new List<object[]>();
            foreach (var r in rows("SELECT user, MAX(mailbox), SUM(requests), SUM(client_errors+server_errors), MIN(first_ms), MAX(last_ms), group_concat(DISTINCT server), group_concat(DISTINCT protocol), COUNT(DISTINCT day)" + usageWhere + " GROUP BY user ORDER BY SUM(requests) DESC;"))
            {
                string user = S(r[0]);
                object[] last; lastSeen.TryGetValue(user, out last);
                Dictionary<string, long> fam; clients.TryGetValue(user, out fam);
                long unresolved; unresolvedByUser.TryGetValue(user, out unresolved);
                List<object[]> det; detail.TryGetValue(user, out det);
                List<object[]> devices = null; if (clientsOf != null) clientsOf.TryGetValue(user, out devices);
                string mode; modes.TryGetValue(user ?? "", out mode);
                List<object[]> ids = null; if (identitiesOf != null && user != null) identitiesOf.TryGetValue(user, out ids);
                result.Add(new object[] { user, S(r[1]), (S(r[7]) ?? "").Replace(",", ", "),
                    fam == null ? null : string.Join(", ", fam.OrderByDescending(x => x.Value).Select(x => x.Key)),
                    (S(r[6]) ?? "").Replace(",", ", "), L(r[2]), L(r[3]), unresolved, L(r[8]), local(L(r[4])), local(L(r[5])),
                    last == null ? null : S(last[1]), last == null ? null : S(last[2]),
                    details ? det ?? new List<object[]>() : null, details ? devices ?? new List<object[]>() : null, mode,
                    details ? ids ?? new List<object[]>() : null });
            }
            return result;
        }

        /// <summary>
        /// Rows of the authentication dataset from access_client (clientsWhere = " FROM access_client WHERE ..."): one row per protocol and display mode
        /// (AuthMode.Of of the stored token; two tokens of one mode merge), with the distinct users, clients (user x user agent x device), devices,
        /// requests, failures, active days, first and last seen, servers, and the clients behind the row. Protocol (ordinal, ignoring case), then most
        /// users first, then mode. details=false leaves the clients detail out (null) and does not build it: one statement grouped by protocol and
        /// token gives the figures, and the clients are read only for a protocol where two of its rows have one display mode (two tokens of one mode,
        /// or two spellings of the protocol), whose distinct counts cannot be added.
        /// </summary>
        internal static List<object[]> AuthenticationRows(Func<string, IEnumerable<object[]>> rows, string clientsWhere, Func<long, object> local, bool details = true)
        {
            if (details) return AuthenticationClientRows(rows, clientsWhere, local, true);
            var byKey = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
            foreach (var r in rows("SELECT protocol, auth_type, COUNT(DISTINCT user), COUNT(DISTINCT user||char(10)||user_agent||char(10)||device_id), COUNT(DISTINCT nullif(device_id,'')), " +
                "SUM(requests), SUM(failures), MIN(first_ms), MAX(last_ms), COUNT(DISTINCT day), group_concat(DISTINCT servers)" + clientsWhere + " GROUP BY protocol, auth_type ORDER BY protocol, auth_type;"))
            {
                string key = (S(r[0]) ?? "").ToLowerInvariant() + "\n" + AuthMode.Of(S(r[1]));
                List<object[]> same;
                if (!byKey.TryGetValue(key, out same)) byKey[key] = same = new List<object[]>();
                same.Add(r);
            }
            var exact = new HashSet<string>(byKey.Where(x => x.Value.Count > 1).Select(x => x.Key.Substring(0, x.Key.IndexOf('\n'))), StringComparer.Ordinal);
            var result = new List<object[]>();
            foreach (var x in byKey)
            {
                if (exact.Contains(x.Key.Substring(0, x.Key.IndexOf('\n')))) continue;
                var r = x.Value[0];
                var servers = new SortedSet<string>((S(r[10]) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).Where(s => s.Length > 0), StringComparer.OrdinalIgnoreCase);
                long first = L(r[7]);
                result.Add(new object[] { S(r[0]), AuthMode.Of(S(r[1])), AuthMode.OAuthPossible(S(r[0])), L(r[2]), L(r[3]), L(r[4]), L(r[5]), L(r[6]),
                    L(r[9]), local(first > 0 ? first : 0), local(Math.Max(0, L(r[8]))), string.Join(", ", servers), null });
            }
            foreach (string protocol in exact)
                result.AddRange(AuthenticationClientRows(rows, clientsWhere + " AND protocol='" + protocol.Replace("'", "''") + "' COLLATE NOCASE", local, false));
            return result.OrderBy(x => (string)x[0] ?? "", StringComparer.OrdinalIgnoreCase).ThenByDescending(x => (long)x[3]).ThenBy(x => (string)x[1], StringComparer.Ordinal).ToList();
        }

        /// <summary>The rows of AuthenticationRows from the clients of the selection: one statement grouped by client, one by day.</summary>
        static List<object[]> AuthenticationClientRows(Func<string, IEnumerable<object[]>> rows, string clientsWhere, Func<long, object> local, bool details)
        {
            var groups = new Dictionary<string, AuthGroup>(StringComparer.Ordinal);
            Func<string, string, AuthGroup> group = (protocol, mode) =>
            {
                string key = (protocol ?? "").ToLowerInvariant() + "\n" + mode;
                AuthGroup g;
                if (!groups.TryGetValue(key, out g)) groups[key] = g = new AuthGroup { Protocol = protocol, Mode = mode };
                return g;
            };
            foreach (var r in rows("SELECT protocol, auth_type, user, user_agent, device_id, MAX(device_type), SUM(requests), SUM(failures), MIN(first_ms), MAX(last_ms), group_concat(DISTINCT servers)" +
                clientsWhere + " GROUP BY protocol, auth_type, user, user_agent, device_id ORDER BY protocol, auth_type, user, user_agent, device_id;"))
            {
                string protocol = S(r[0]), user = S(r[2]) ?? "", agent = S(r[3]) ?? "", device = S(r[4]) ?? "", type = S(r[5]);
                var g = group(protocol, AuthMode.Of(S(r[1])));
                var servers = (S(r[10]) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
                g.Users.Add(user);
                if (device.Length > 0) g.Devices.Add(device);
                foreach (var s in servers) g.Servers.Add(s);
                long requests = L(r[6]), failures = L(r[7]), first = L(r[8]), last = L(r[9]);
                g.Requests += requests; g.Failures += failures;
                if (first > 0 && (g.First == 0 || first < g.First)) g.First = first;
                if (last > g.Last) g.Last = last;
                string clientKey = user + "\n" + agent + "\n" + device;
                AuthClient c;
                if (!g.Clients.TryGetValue(clientKey, out c))
                {
                    g.Clients[clientKey] = c = new AuthClient { User = user, Client = details ? ClientFamily(protocol, agent, type) : null, Type = type, Device = device.Length == 0 ? null : device };
                    g.Order.Add(c);
                }
                if (c.Type == null) c.Type = type;
                if (details) foreach (var s in servers) c.Servers.Add(s);
                c.Requests += requests; c.Failures += failures; if (last > c.Last) c.Last = last;
            }
            foreach (var r in rows("SELECT protocol, auth_type, day" + clientsWhere + " GROUP BY protocol, auth_type, day;"))
                group(S(r[0]), AuthMode.Of(S(r[1]))).Days.Add(S(r[2]) ?? "");
            var result = new List<object[]>();
            foreach (var g in groups.Values.Where(x => x.Users.Count > 0).OrderBy(x => x.Protocol ?? "", StringComparer.OrdinalIgnoreCase).ThenByDescending(x => x.Users.Count).ThenBy(x => x.Mode, StringComparer.Ordinal))
                result.Add(new object[] { g.Protocol, g.Mode, AuthMode.OAuthPossible(g.Protocol), (long)g.Users.Count, (long)g.Clients.Count, (long)g.Devices.Count, g.Requests, g.Failures,
                    (long)g.Days.Count, local(g.First), local(g.Last), string.Join(", ", g.Servers),
                    details ? g.Order.Select(c => new object[] { c.User, c.Client, c.Type, c.Device, string.Join(", ", c.Servers), c.Requests, c.Failures, local(c.Last) }).ToList() : null });
            return result;
        }

        sealed class AuthGroup
        {
            public string Protocol, Mode;
            public long Requests, Failures, First, Last;
            public HashSet<string> Users = new HashSet<string>(StringComparer.Ordinal), Devices = new HashSet<string>(StringComparer.Ordinal), Days = new HashSet<string>(StringComparer.Ordinal);
            public SortedSet<string> Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            public Dictionary<string, AuthClient> Clients = new Dictionary<string, AuthClient>(StringComparer.Ordinal);
            public List<AuthClient> Order = new List<AuthClient>();
        }

        sealed class AuthClient
        {
            public string User, Client, Type, Device;
            public long Requests, Failures, Last;
            public SortedSet<string> Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        }

        /// <summary>
        /// The authentication figures of the e-mail from the Authentication cell of the users rows: users with a recorded type (other than Unknown),
        /// users that used OAuth, Basic, or Windows authentication (Negotiate, NTLM, Kerberos) at least once. A user of two modes counts in both.
        /// </summary>
        static void CountAuthentication(Dataset users, Dictionary<string, long> counts)
        {
            int column = users.Columns.FindIndex(x => x.Name == "Authentication");
            long known = 0, oauth = 0, basic = 0, integrated = 0;
            foreach (var r in users.Rows)
            {
                var modes = (S(r[column]) ?? "").Split(new[] { ", " }, StringSplitOptions.RemoveEmptyEntries);
                if (!modes.Any(m => m != "Unknown")) continue;
                known++;
                if (modes.Any(AuthMode.IsOAuth)) oauth++;
                if (modes.Any(AuthMode.IsBasic)) basic++;
                if (modes.Any(AuthMode.IsIntegrated)) integrated++;
            }
            counts["usersWithAuth"] = known; counts["usersOnOAuth"] = oauth; counts["usersOnBasic"] = basic; counts["usersOnIntegrated"] = integrated;
        }

        // ------------------------------------------------------------------ build

        public static ReportResult Build(Store store, ReportRequest q)
        {
            if (q.MemoryBudgetMB < 64 || q.MemoryBudgetMB > 16384) throw new ArgumentOutOfRangeException("MemoryBudgetMB", "Report memory budget must be 64 to 16384 MB.");
            if (q.Parallelism < 0 || q.Parallelism > 16) throw new ArgumentOutOfRangeException("Parallelism", "Report parallelism must be 0 to 16.");
            if (q.MaxHtmlRows < 0) throw new ArgumentOutOfRangeException("MaxHtmlRows", "Report.MaxHtmlRows must be 0 (every row) or a row count.");
            if (q.SingleFileMaxMB < 1 || q.SingleFileMaxMB > 4096) throw new ArgumentOutOfRangeException("SingleFileMaxMB", "Report.SingleFileMaxMB must be 1 to 4096.");
            if (q.HtmlPackBytes < 1024) throw new ArgumentOutOfRangeException("HtmlPackBytes", "The HTML data file size must be at least 1 KB.");
            if (!new[] { "Auto", "SingleFile", "Folder" }.Contains(q.HtmlLayout ?? "", StringComparer.OrdinalIgnoreCase)) throw new ArgumentOutOfRangeException("HtmlLayout", "Report.HtmlLayout must be 'Auto', 'SingleFile' or 'Folder'.");
            var result = new ReportResult { Folder = q.OutputFolder, Title = q.Title };
            Directory.CreateDirectory(q.OutputFolder);
            long previousCache = L(store.Query("PRAGMA cache_size;", null).Rows[0][0]);
            _steps = new List<KeyValuePair<double, string>>();
            _transcriptReads = 0; _transcriptBytes = 0;
            long scratchFree;
            result.ScratchFolder = ReportScratch.Folder(q.ScratchFolder, q.OutputFolder, out scratchFree);
            result.ScratchFreeBytes = scratchFree;
            var scratch = new ReportScratch(result.ScratchFolder, (long)q.MemoryBudgetMB * 1048576);
            var errors = new ReportErrors();
            bool snapshot = false;
            try
            {
                q.Scratch = scratch;
                store.Exec("PRAGMA cache_size=-" + (q.DatabaseCacheMB * 1024).ToString(CultureInfo.InvariantCulture) + ";");
                store.BeginReportSnapshot(); snapshot = true;
                Build(store, q, result);
                result.PeakBufferBytes = scratch.PeakBufferBytes;
                result.SpilledRows = scratch.SpilledRows;
                result.StagedRows = scratch.StagedRows;
                result.MemoryBudgetMB = q.MemoryBudgetMB;
                result.Parallelism = q.EffectiveParallelism;
                result.DatabaseCacheMB = q.DatabaseCacheMB;
                result.TranscriptReads = _transcriptReads;
                result.TranscriptBytes = _transcriptBytes;
            }
            catch (Exception error) { errors.Add(error); }
            finally
            {
                foreach (var error in scratch.WorkerFailures) errors.Add(error);
                q.Scratch = null;
                if (snapshot) errors.Run(store.EndReportSnapshot);
                errors.Run(() => store.Exec("PRAGMA cache_size=" + previousCache.ToString(CultureInfo.InvariantCulture) + ";"));
                errors.Run(() => result.Steps = _steps.OrderByDescending(x => x.Key).Select(x => x.Key.ToString("0.0", CultureInfo.InvariantCulture) + " s, " + x.Value).ToList());
                _steps = null;
                errors.Run(scratch.Dispose);
                result.ScratchPeakBytes = scratch.PeakFileBytes;
            }
            errors.ThrowIfAny();
            return result;
        }

        static void Build(Store store, ReportRequest q, ReportResult result)
        {
            Directory.CreateDirectory(q.OutputFolder);
            var zone = q.Zone;
            string d0 = TimeUtil.Day(q.StartMs, zone), d1 = TimeUtil.Day(q.EndMs - 1, zone), d2 = TimeUtil.Day(q.EndMs + 86400000L, zone);
            Func<long, object> local = ms => ms > 0 ? (object)TimeUtil.ToLocalSeconds(ms, zone) : null;

            if (q.Progress != null) q.Progress("Client access failures");
            // ---- client access: failures and their resolution --------------------------------------
            var f = new Sql(); f.P["@t0"] = q.StartMs; f.P["@t1"] = q.EndMs; f.P["@d0"] = d0; f.P["@d2"] = d2;
            string fu = f.Users(q.Users, "e.user", "e.mailbox"), fs = f.Servers(q.Servers, "e.server");
            var lastSuccess = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (var r in Rows(store, "SELECT user, protocol, day, MAX(last_success_ms) FROM access_usage WHERE day >= @d0 AND day <= @d2 GROUP BY user, protocol, day;", f.P))
                lastSuccess[S(r[0]) + "|" + S(r[1]) + "|" + S(r[2])] = L(r[3]);
            bool withSuccesses = q.Detailed && q.Users.Any(u => !string.IsNullOrWhiteSpace(u));
            var issues = new Dataset("issues", "ClientAccess-Requests", q.Scratch) { Html = q.Detailed };
            foreach (var n in IssueColumns) { var p = n.Split(':'); issues.Add(p[0], p[1]); }
            var unresolvedByServer = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var unresolvedByUser = new Dictionary<string, long>(StringComparer.Ordinal);
            var unresolvedDetail = new Dictionary<string, UnresolvedUser>(StringComparer.Ordinal);
            string issueSql = "SELECT " + IssueFields + IssueFrom +
                "WHERE e.time_ms >= @t0 AND e.time_ms < @t1" + fu + fs + (withSuccesses ? "" : " AND e.outcome <> 'Success'") + " ORDER BY e.time_ms;";
            Func<string, string, string, long> lastSuccessOf = (u, p, d) => { long x; return lastSuccess.TryGetValue(u + "|" + p + "|" + d, out x) ? x : 0; };
            foreach (var r in Rows(store, issueSql, f.P))
            {
                long t = L(r[0]);
                string server = S(r[1]), user = S(r[4]), protocol = S(r[3]);
                string after;
                string resolution = IssueResolution(r, zone, lastSuccessOf, out after);
                if (resolution == "Unresolved")
                {
                    long n;
                    unresolvedByServer.TryGetValue(server, out n); unresolvedByServer[server] = n + 1;
                    unresolvedByUser.TryGetValue(user ?? "", out n); unresolvedByUser[user ?? ""] = n + 1;
                    if (q.Detailed)
                    {
                        UnresolvedUser u;
                        if (!unresolvedDetail.TryGetValue(user ?? "", out u)) { u = new UnresolvedUser(); unresolvedDetail[user ?? ""] = u; }
                        u.Count++;
                        if (protocol != null) u.Protocols.Add(protocol);
                        if (server != null) u.Servers.Add(server);
                        if (t >= u.LastMs) { u.LastMs = t; u.LastError = FailureText(r[11], r[12], r[13], r[14], S(r[15])); }
                    }
                }
                issues.Rows.Add(IssueRow(r, local, resolution, after));
            }

            // ---- client access aggregates ------------------------------------------------------------
            if (q.Progress != null) q.Progress("Client access aggregates");
            var a = new Sql(); a.P["@d0"] = d0; a.P["@d1"] = d1;
            string au = a.Users(q.Users, "user", "mailbox"), asv = a.Servers(q.Servers, "server");
            string usageWhere = " FROM access_usage WHERE day >= @d0 AND day <= @d1" + au + asv;
            var daily = new Dictionary<string, DayStats>(StringComparer.OrdinalIgnoreCase);
            var servers = UsageByServer(sql => Rows(store, sql, a.P), usageWhere, daily);

            // ---- mail flow aggregates ----------------------------------------------------------------
            if (q.Progress != null) q.Progress("Mail flow aggregates");
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
            // Keep the covering source scan and chronology. Exact binary identities live in the bounded, disk-backed
            // report scratch database, not a hash-only set or an unbounded collection of managed strings.
            var msgRange = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
            using (var counts = new ExactMessageCounts(q.Scratch))
            {
            foreach (var r in Rows(store, "SELECT time_ms, server, event_id, COALESCE(message_id, internal_id)" + msgWhere + " ORDER BY time_ms;", m.P))
            {
                long t = L(r[0]);
                string server = S(r[1]) ?? "", ev = S(r[2]), id = S(r[3]);
                var s = Get(servers, server);
                if (ev == "DELIVER") s.Deliveries++; else if (ev == "FAIL" || ev == "DSN") s.MessageFailures++;
                long[] range;
                if (!msgRange.TryGetValue(server, out range)) msgRange[server] = new[] { t, t }; else range[1] = t;
                if (id == null) continue;
                counts.Add(server, t / 3600000L, id);
            }
            counts.Read((server, n) => Get(servers, server).Messages = n,
                (server, hour, n) => Get(daily, TimeUtil.Day(hour * 3600000L, zone) + "|" + server).Messages += n);
            }
            // Servers without client access (Edge Transport, mail flow only): activity dates and days from the mail flow.
            var flowRange = new List<KeyValuePair<string, long[]>>(msgRange);
            foreach (var r in Rows(store, "SELECT server, MIN(time_ms), MAX(time_ms)" + smtpWhere + " GROUP BY server;", m.P))
                flowRange.Add(new KeyValuePair<string, long[]>(S(r[0]), new[] { L(r[1]), L(r[2]) }));
            FinishServers(servers, daily, flowRange);

            // ---- servers dataset: every configured server appears, used or not --------------------------
            var serverSet = new Dataset("servers", "Servers");
            foreach (var n in ServerColumns) { var p = n.Split(':'); serverSet.Add(p[0], p[1]); }
            serverSet.Columns[16].Grid = false; serverSet.Columns[16].Csv = false;
            foreach (var row in ServerRows(servers, unresolvedByServer, q.ConfiguredServers, q.Servers, local)) serverSet.Rows.Add(row);
            // Summary of the e-mail (columns as above, before the Edge report drops the client access ones).
            result.ServerRows = serverSet.Rows.Select(r => (object[])r.Clone()).ToList();

            // ---- daily dataset ----------------------------------------------------------------------------
            var dailySet = new Dataset("daily", "Daily");
            foreach (var n in DailyColumns) { var p = n.Split(':'); dailySet.Add(p[0], p[1]); }
            foreach (var row in DailyRows(daily, d0, d1)) dailySet.Rows.Add(row);

            // ---- users dataset ----------------------------------------------------------------------------
            if (q.Progress != null) q.Progress("Users and clients");
            var userSet = new Dataset("users", "Users", q.Scratch);
            foreach (var n in UserColumns) { var p = n.Split(':'); userSet.Add(p[0], p[1]); }
            userSet.Columns[13].Grid = false; userSet.Columns[13].Csv = false;
            userSet.Columns[14].Grid = false; userSet.Columns[14].Csv = false;
            userSet.Columns[16].Grid = false; userSet.Columns[16].Csv = false;
            // Clients and devices: a CSV of their own, and the detail of each user in the HTML report.
            var clientSet = BuildClients(store, q, d0, d1, local);
            clientSet.Html = false;
            var clientsOf = new Dictionary<string, List<object[]>>(StringComparer.Ordinal);
            foreach (var c in clientSet.Rows) Get(clientsOf, S(c[0])).Add(DeviceRow(c));
            // The access_client rows of the clients dataset (same user and server filters).
            string clientsWhere = " FROM access_client WHERE day >= @d0 AND day <= @d1" + a.Users(q.Users, "user") + ServerFilter(q.Servers, a.P, "','||COALESCE(servers,'')||','");
            var identitiesOf = IdentityRows(store, sql => Rows(store, sql, a.P), local);
            foreach (var row in UserRows(sql => Rows(store, sql, a.P), usageWhere, unresolvedByUser, clientsOf, local, true, clientsWhere, identitiesOf)) userSet.Rows.Add(row);
            Dataset authenticationSet = null;
            if (!q.Edge)
            {
                authenticationSet = new Dataset("authentication", "Authentication", q.Scratch);
                foreach (var n in AuthenticationColumns) { var p = n.Split(':'); authenticationSet.Add(p[0], p[1]); }
                authenticationSet.Columns[12].Grid = false; authenticationSet.Columns[12].Csv = false;
                foreach (var row in AuthenticationRows(sql => Rows(store, sql, a.P), clientsWhere, local)) authenticationSet.Rows.Add(row);
                CountAuthentication(userSet, result.Counts);
            }

            // ---- detailed datasets ------------------------------------------------------------------------
            Dataset messageSet = null, smtpSet = null, sessionSet = null;
            if (q.Detailed)
            {
                if (!q.Edge)
                {
                    if (q.Progress != null) q.Progress("Client sessions");
                    sessionSet = BuildSessions(store, q, local);
                }
                if (q.Progress != null) q.Progress("Message journeys");
                messageSet = BuildMessages(store, q, tu, su, ts, m.P, local);
                smtpSet = BuildSmtp(store, q, su, ss, m.P, local);
                smtpSet.Html = false;
            }
            var detailWatch = System.Diagnostics.Stopwatch.StartNew();
            if (q.Progress != null) q.Progress("SMTP client/destination details");
            var smtpClientSet = BuildSmtpClients(store, q, su, ss, m.P, local);
            var smtpDestinationSet = q.Edge ? BuildSmtpDestinations(store, q, su, ss, m.P, local) : null;
            Timed(detailWatch, smtpClientSet.Rows.Count + (smtpDestinationSet == null ? 0 : smtpDestinationSet.Rows.Count), "SMTP client/destination details");
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
                sets.Add(authenticationSet);
                sets.Add(smtpClientSet);
                if (q.Detailed) { sets.Add(sessionSet); sets.Add(issues); sets.Add(messageSet); sets.Add(smtpSet); }
            }
            foreach (var d in sets) result.Counts[d.Name] = d.Rows.Count;
            if (q.Detailed) result.Highlights = BuildHighlights(q, unresolvedDetail, sessionSet, smtpClientSet, smtpDestinationSet, authenticationSet);
            if (sessionSet != null && sets.Contains(sessionSet))
                result.Counts["sessionsWithFailures"] = sessionSet.SessionsWithFailures;
            if (q.WriteCsv)
            {
                if (q.Progress != null) q.Progress("CSV exports");
                var csvWatch = System.Diagnostics.Stopwatch.StartNew();
                foreach (var d in sets)
                {
                    var file = WriteCsv(d, Path.Combine(q.OutputFolder, q.FilePrefix + "-" + d.FileName + ".csv"), q.CsvDelimiter);
                    result.Files.Add(file);
                    result.Counts[d.Name] = file.Rows;
                }
                Timed(csvWatch, sets.Sum(x => (long)x.Rows.Count), "CSV files of the datasets");
                string accessPath = Path.Combine(q.OutputFolder, q.FilePrefix + "-ClientAccess-Daily.csv");
                if (!q.Edge) result.Files.Add(WriteAccessCsv(store, accessPath, q.CsvDelimiter, "SELECT day, server, user, mailbox, protocol, requests, successes, client_errors, server_errors, slow, bytes_in, bytes_out, CASE WHEN requests > 0 THEN total_ms / requests END, max_ms, first_ms, last_ms, client_ip, user_agent" + usageWhere + " ORDER BY day, server, user, protocol;", a.P, zone));
            }
            if (q.WriteHtml)
            {
                if (q.Progress != null) q.Progress("HTML compression");
                result.HtmlPath = Path.Combine(q.OutputFolder, q.FilePrefix + ".html");
                var htmlWatch = System.Diagnostics.Stopwatch.StartNew();
                result.Files.Add(WriteHtml(store, q, sets, result, result.HtmlPath));
                Timed(htmlWatch, sets.Where(x => x.Html).Sum(x => q.MaxHtmlRows > 0 ? (long)Math.Min(x.Rows.Count, q.MaxHtmlRows) : x.Rows.Count), "HTML file");
            }
        }

        // ------------------------------------------------------------------ main problems (e-mail summary)

        sealed class UnresolvedUser
        {
            public long Count, LastMs;
            public string LastError;
            public SortedSet<string> Protocols = new SortedSet<string>(StringComparer.OrdinalIgnoreCase), Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        }

        /// <summary>"401.1 Win32 1326", "200 back end 503 DeviceNotProvisioned": what failed, as short as possible.</summary>
        static string FailureText(object status, object sub, object win32, object backEnd, string errorCode)
        {
            var sb = new StringBuilder();
            if (status != null) { sb.Append(L(status)); if (sub != null && L(sub) != 0) sb.Append('.').Append(L(sub)); }
            if (win32 != null && L(win32) != 0) sb.Append(" Win32 ").Append(L(win32));
            if (backEnd != null && L(backEnd) != 0 && L(backEnd) != L(status)) sb.Append(" back end ").Append(L(backEnd));
            if (!string.IsNullOrWhiteSpace(errorCode)) sb.Append(' ').Append(errorCode.Length > 60 ? errorCode.Substring(0, 60) + "..." : errorCode);
            return sb.ToString().Trim();
        }

        static string Cell(object v, int max = 70)
        {
            string s = S(v) ?? "";
            s = s.Replace("\r", " ").Replace("\n", " ").Trim();
            return s.Length > max ? s.Substring(0, max) + "..." : s;
        }

        static string LocalText(object localSeconds)
        {
            return localSeconds == null ? "" : DateTimeOffset.FromUnixTimeSeconds(L(localSeconds)).UtcDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        }

        static List<object[]> TopRows(IEnumerable<object[]> rows, Comparison<object[]> compare, out long total)
        {
            total = 0;
            var top = new List<object[]>(11);
            foreach (var row in rows)
            {
                total++;
                KeepTopRow(top, row, compare);
            }
            return top;
        }

        static void KeepTopRow(List<object[]> top, object[] row, Comparison<object[]> compare)
        {
            int i = top.FindIndex(x => compare(row, x) < 0);
            if (i < 0) i = top.Count;
            if (i >= 10) return;
            top.Insert(i, row);
            if (top.Count > 10) top.RemoveAt(10);
        }

        static int SessionSeverity(string outcome) { return outcome == "Failed" ? 0 : outcome == "Failed at end" ? 1 : outcome == "Intermittent errors" ? 2 : 9; }

        /// <summary>
        /// The main problems of a Detailed report, 10 per kind, worst first: users with unresolved failures, client
        /// sessions that failed (Failed, Failed at end, Intermittent errors; Recovered sessions are left out), SMTP
        /// clients with refused or deferred transactions, and on an Edge report the SMTP destinations with failures.
        /// </summary>
        static List<ReportHighlight> BuildHighlights(ReportRequest q, Dictionary<string, UnresolvedUser> unresolved, Dataset sessions, Dataset smtpClients, Dataset destinations,
            Dataset authentication)
        {
            var list = new List<ReportHighlight>();
            if (!q.Edge)
            {
                var users = new ReportHighlight { Title = "Users with unresolved failures", Hint = "Failed requests not followed by a success of the same user and protocol.", Columns = new[] { "User", "Unresolved", "Protocols", "Servers", "Last failure", "Last error" } };
                users.Total = unresolved.Count;
                foreach (var kv in unresolved.OrderByDescending(x => x.Value.Count).ThenBy(x => x.Key, StringComparer.Ordinal).Take(10))
                    users.Rows.Add(new[] { Cell(kv.Key, 50), kv.Value.Count.ToString("N0", CultureInfo.InvariantCulture), string.Join(", ", kv.Value.Protocols), string.Join(", ", kv.Value.Servers),
                        TimeUtil.Format(kv.Value.LastMs, q.Zone, "yyyy-MM-dd HH:mm"), Cell(kv.Value.LastError) });
                list.Add(users);

                if (sessions != null)
                {
                    int iStart = sessions.Columns.FindIndex(x => x.Name == "Start"), iOutcome = sessions.Columns.FindIndex(x => x.Name == "Outcome"), iUser = sessions.Columns.FindIndex(x => x.Name == "User");
                    int iProtocol = sessions.Columns.FindIndex(x => x.Name == "Protocol"), iClient = sessions.Columns.FindIndex(x => x.Name == "Client"), iRequests = sessions.Columns.FindIndex(x => x.Name == "Requests");
                    int iFailures = sessions.Columns.FindIndex(x => x.Name == "Failures"), iError = sessions.Columns.FindIndex(x => x.Name == "Last error");
                    var h = new ReportHighlight { Title = "Client sessions that failed", Hint = "Failed, failed at end or intermittent errors (recovered sessions are not listed).", Columns = new[] { "User", "Client", "Outcome", "Failures", "Start", "Last error" } };
                    h.Total = sessions.FailedSessionCount;
                    foreach (var r in sessions.FailureSample)
                        h.Rows.Add(new[] { Cell(r[iUser], 50), Cell(S(r[iProtocol]) + " " + S(r[iClient]), 50), S(r[iOutcome]), L(r[iFailures]).ToString("N0", CultureInfo.InvariantCulture) + " / " + L(r[iRequests]).ToString("N0", CultureInfo.InvariantCulture),
                            LocalText(r[iStart]), Cell(r[iError]) });
                    list.Add(h);
                }

                if (authentication != null)
                {
                    // One row per protocol with users on Basic (the authentication rows are one per protocol and mode), most users first.
                    var basic = authentication.Rows.Where(r => S(r[1]) == "Basic").OrderByDescending(r => L(r[3])).ThenBy(r => S(r[0]), StringComparer.OrdinalIgnoreCase).ToList();
                    var h = new ReportHighlight { Title = "Users on Basic authentication", Hint = "Clients that send a user name and password with every request: ActiveSync devices and applications to move to OAuth.", Columns = new[] { "Protocol", "Users", "Devices", "Requests", "Last seen" } };
                    h.Total = basic.Count;
                    foreach (var r in basic.Take(10))
                        h.Rows.Add(new[] { S(r[0]), L(r[3]).ToString("N0", CultureInfo.InvariantCulture), L(r[5]).ToString("N0", CultureInfo.InvariantCulture), L(r[6]).ToString("N0", CultureInfo.InvariantCulture), LocalText(r[10]) });
                    list.Add(h);
                }
            }
            if (smtpClients != null)
            {
                long total;
                var refused = TopRows(smtpClients.Rows.Where(r => L(r[6]) + L(r[7]) > 0), (a, b) =>
                {
                    int c = (L(b[6]) + L(b[7])).CompareTo(L(a[6]) + L(a[7]));
                    return c != 0 ? c : L(b[4]).CompareTo(L(a[4]));
                }, out total);
                var h = new ReportHighlight { Title = "SMTP clients with refused or deferred mail", Hint = "Applications, devices or servers whose messages were rejected or deferred.", Columns = new[] { "Client", "Transactions", "Rejected", "Deferred", "Last seen", "Last error" } };
                h.Total = total;
                foreach (var r in refused)
                    h.Rows.Add(new[] { Cell(S(r[0]) + (string.IsNullOrEmpty(S(r[1])) ? "" : " (" + S(r[1]) + ")"), 60), L(r[4]).ToString("N0", CultureInfo.InvariantCulture), L(r[6]).ToString("N0", CultureInfo.InvariantCulture),
                        L(r[7]).ToString("N0", CultureInfo.InvariantCulture), LocalText(r[14]), Cell(r[15]) });
                list.Add(h);
            }
            if (destinations != null)
            {
                long total;
                var failing = TopRows(destinations.Rows.Where(r => L(r[6]) + L(r[7]) > 0),
                    (a, b) => (L(b[6]) + L(b[7])).CompareTo(L(a[6]) + L(a[7])), out total);
                var h = new ReportHighlight { Title = "SMTP destinations with failures", Hint = "Remote servers that deferred or refused mail sent by the Edge Transport servers.", Columns = new[] { "Destination", "Transactions", "Deferred", "Failed", "Last seen", "Last error" } };
                h.Total = total;
                foreach (var r in failing)
                    h.Rows.Add(new[] { Cell(S(r[0]) + (string.IsNullOrEmpty(S(r[1])) ? "" : " (" + S(r[1]) + ")"), 60), L(r[4]).ToString("N0", CultureInfo.InvariantCulture), L(r[6]).ToString("N0", CultureInfo.InvariantCulture),
                        L(r[7]).ToString("N0", CultureInfo.InvariantCulture), LocalText(r[13]), Cell(r[14]) });
                list.Add(h);
            }
            return list;
        }

        // ------------------------------------------------------------------ messages: one row per message

        // Internal (with JourneySummary): the rollup reconciliation keeps one summary for all its keys (RollupReads).
        internal sealed class Journey
        {
            public string MessageId, Sender, Subject, Direction;
            public long First, Last, Size, MaxCount;
            public List<object[]> Events = new List<object[]>();
        }

        static Dataset BuildMessages(Store store, ReportRequest q, string userFilter, string smtpUserFilter, string serverFilter, Dictionary<string, object> p, Func<long, object> local)
        {
            var set = new Dataset("messages", "Messages", q.Scratch);
            foreach (var n in new[] { "First event:time", "Last event:time", "Duration:text", "Status:text", "Sender:text", "Recipients:list", "Recipient count:num",
                "Delivered:num", "Failed:num", "Subject:text", "Size (KB):num", "Direction:text", "Servers:text", "Events:text", "SMTP sessions:num",
                "Message ID:text", "Route:steps", "SMTP transcripts:steps" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[16].Grid = false; set.Columns[16].Csv = q.IncludeRoutingDetails;
            set.Columns[17].Grid = false; set.Columns[17].Csv = false;
            string selection = "SELECT msg_hash,message_id FROM message_event WHERE time_ms >= @t0 AND time_ms < @t1 AND message_id IS NOT NULL" + userFilter + serverFilter;

            // Only compact metadata is staged (the recipients of a conversation only when the route is built: they pair a
            // conversation with its tracking RECEIVE, as Serve does). Source reads keep the existing binary indexes;
            // case-insensitive matching is indexed in the private scratch database, not in the source.
            var links = new MessageSmtpLinks(q.Scratch);
            var rules = MailFlowRules.Read(sql => store.Command(sql));
            string smtpSql = "SELECT message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,status,response," +
                (q.IncludeRoutingDetails && q.WriteHtml ? "CASE WHEN transcript IS NOT NULL THEN id END" : "NULL") +
                ",session_id," + SmtpAuthView.Columns + ",internal_id," + (q.IncludeRoutingDetails ? "rcpts" : "NULL") + " FROM smtp_transaction WHERE (msg_hash,message_id) IN (" + selection + ") ORDER BY message_id,id;";
            foreach (var row in Rows(store, smtpSql, p)) links.Add(row);
            Journey j = null;
            Action flush = () =>
            {
                if (j != null) set.Rows.Add(JourneyRow(j, links.Read(j.MessageId), q, local, rules), j.First, 0);
            };
            foreach (var r in Rows(store, "SELECT message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference,server_ip FROM message_event WHERE (msg_hash,message_id) IN (" + selection + ") ORDER BY message_id,time_ms,id;", p))
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
            links.Dispose();
            // Mail refused during the SMTP conversation (relay denied, unknown recipient, size...): no Message-ID,
            // no tracking event. One row each, so that every message problem is in the same view.
            foreach (var r in Rows(store, "SELECT time_ms,end_ms,server,role,connector,remote_ep,helo,tls,auth,mail_from,rcpts,status,response," +
                (q.IncludeRoutingDetails && q.WriteHtml ? "CASE WHEN transcript IS NOT NULL THEN id END" : "NULL") + ",session_id," + SmtpAuthView.Columns + " FROM smtp_transaction " +
                "WHERE time_ms >= @t0 AND time_ms < @t1 AND direction='Receive' AND message_id IS NULL AND status <> 'Accepted'" + smtpUserFilter + serverFilter + RefusedMailOrder, p))
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
                AddAuthentication(parts, SmtpAuthView.Fields(r, 15), S(r[9]));
                if (S(r[12]) != null) parts.Add(S(r[12]));
                var route = new List<object[]> { new object[] { local(t), S(r[2]), "SMTP Receive" + (S(r[3]) != null ? " (" + S(r[3]) + ")" : ""), S(r[11]), string.Join(" | ", parts), 1L, t } };
                var transcripts = new List<object[]>();
                if (r[13] != null) transcripts.Add(new object[] { local(t), S(r[2]), "Receive " + S(r[14]), new TranscriptRef(L(r[13])) });
                set.Rows.Add(new object[] {
                    local(t), local(end), TimeUtil.Duration((end - t) / 1000.0), status, S(r[9]), rcpts.Select(x => x + " (" + S(r[11]) + ")").ToArray(),
                    (long)rcpts.Length, 0L, status == "Rejected (SMTP)" ? (long)rcpts.Length : 0L, null, null, "Incoming (SMTP)", S(r[2]), "SMTP " + S(r[11]), 1L,
                    null, q.IncludeRoutingDetails ? route : new List<object[]>(), transcripts }, t, 0);
            }
            set.Rows.SortByTime();
            return set;
        }

        static readonly HashSet<string> Final = new HashSet<string>(StringComparer.Ordinal) { "Delivered", "Failed", "Dropped", "Poison", "Suppressed" };
        // Names a distribution list or an alias that was replaced by its members: shown, never counted as a recipient.
        static readonly HashSet<string> Alias = new HashSet<string>(StringComparer.Ordinal) { "Expanded", "Resolved", "Redirected" };
        const string HandedOff = "Handed off";

        internal sealed class JourneySummary
        {
            readonly Dictionary<string, string> status = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            readonly List<string> order = new List<string>(), servers = new List<string>(), events = new List<string>();
            readonly HashSet<string> eventSet = new HashSet<string>(StringComparer.Ordinal);
            // A list is empty only when no event names a member for it: noMember (EXPAND without members), givers (events naming members),
            // confirmed (a DROP states that the list was expanded). Decided when the row is built, so that a member event arriving
            // after the empty EXPAND still counts.
            readonly HashSet<string> noMember = new HashSet<string>(StringComparer.OrdinalIgnoreCase), givers = new HashSet<string>(StringComparer.OrdinalIgnoreCase),
                confirmed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool dropped, suppressed;
            // The next host of the last hand-off of a recipient when that hand-off may have left the organization (a SENDEXTERNAL through a connector
            // that is not internal, accepted by the remote server, for a recipient of a foreign domain); decided in Row, once every server of the
            // journey is known (a host of the journey is a collected server).
            readonly Dictionary<string, string> outside = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            /// <summary>The rules of the external status (null or External false: a SENDEXTERNAL is a hand-off like a SEND).</summary>
            internal MailFlowRules Rules;
            /// <summary>Empties the summary for the next message, as a new one (the reconciliation uses one for all its keys).</summary>
            internal JourneySummary Reset()
            {
                status.Clear(); order.Clear(); servers.Clear(); events.Clear(); eventSet.Clear();
                noMember.Clear(); givers.Clear(); confirmed.Clear(); outside.Clear();
                dropped = false; suppressed = false;
                return this;
            }
            void Set(string rcpt, string value)
            {
                if (string.IsNullOrEmpty(rcpt)) return;
                string current;
                if (!status.TryGetValue(rcpt, out current)) order.Add(rcpt);
                else if (current == "Delivered" && value != "Failed") return;
                status[rcpt] = value;
            }
            string Current(string rcpt) { string cur; return status.TryGetValue(rcpt, out cur) ? cur : null; }
            void Transit(string[] rcpts) { foreach (var x in rcpts) if (!status.ContainsKey(x)) Set(x, "In transit"); }

            /// <summary>Entries of a recipient-status text: separated by ';' outside single quotes (an entry can quote text holding ';').</summary>
            internal static List<string> SplitEntries(string text)
            {
                var list = new List<string>();
                if (string.IsNullOrEmpty(text)) return list;
                var sb = new StringBuilder();
                bool quoted = false;
                foreach (char c in text)
                {
                    // The quotes only delimit an entry; the readers (route, summary) want its text.
                    if (c == '\'') { quoted = !quoted; continue; }
                    if (c == ';' && !quoted) { list.Add(sb.ToString()); sb.Clear(); }
                    else sb.Append(c);
                }
                list.Add(sb.ToString());
                return list;
            }
            /// <summary>Entry of the k-th of n recipients: one entry per recipient, or one entry for all; otherwise unknown (null).</summary>
            internal static string Entry(List<string> entries, int k, int n)
            {
                if (entries.Count == n) return entries[k];
                return entries.Count == 1 ? entries[0] : null;
            }
            // A lone recipient owns the whole text, whatever ';' it holds: the quoting of the entries is only needed to tell several recipients apart.
            internal static string EntryOf(string text, List<string> entries, int k, int n) { return n == 1 ? text?.Replace("'", "") : Entry(entries, k, n); }
            internal static bool IsExpansion(string entry) { return entry != null && entry.Contains("RESOLVER.GRP.Expanded"); }
            // Mail the organization chose not to deliver, by design: out-of-office replies that must not cross the boundary,
            // automatic forwards and replies to external recipients, and recipients suppressed by the meeting-forward rules.
            internal static bool IsSuppression(string entry)
            {
                return entry != null && (entry.Contains("RESOLVER.OOF.ExtToInt") || entry.Contains("RESOLVER.OOF.IntToExt")
                    || entry.Contains("RESOLVER.MSGTYPE.AF") || entry.Contains("RESOLVER.MSGTYPE.AR") || entry.Contains("RESOLVER.MER.Suppressed"));
            }

            /// <param name="connector">connector-id of the event; peer: MailFlowRules.PeerKey of its next host (both read for SENDEXTERNAL only).</param>
            internal void Add(string server, string evt, string recipients, string recipientStatus, string related, string connector = null, string peer = null)
            {
                evt = evt ?? "";
                var rcpts = (recipients ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
                if (!servers.Contains(server, StringComparer.OrdinalIgnoreCase)) servers.Add(server);
                // A DROP that only reports a list expansion is the end of the EXPAND, not an event of its own.
                List<string> entries = null;
                bool[] expansion = null;
                if (evt == "DROP")
                {
                    entries = SplitEntries(recipientStatus);
                    expansion = new bool[rcpts.Length];
                    for (int k = 0; k < rcpts.Length; k++)
                    {
                        string e = EntryOf(recipientStatus, entries, k, rcpts.Length);
                        expansion[k] = e != null ? IsExpansion(e) : Current(rcpts[k]) == "Expanded";
                    }
                }
                if (!(expansion != null && expansion.Length > 0 && expansion.All(x => x)) && eventSet.Add(evt)) events.Add(evt);
                string cur;
                switch (evt)
                {
                    case "DELIVER": foreach (var x in rcpts) Set(x, "Delivered"); break;
                    // SENDEXTERNAL: handed over by SMTP outside the transport services of the organization (an Edge Transport server to the
                    // mailbox servers or the internet, a mailbox server to a smart host or the internet). A hand-off, unless the logs prove that
                    // it left the organization: then the recipient is sent to external (decided in Row).
                    case "SEND": case "SENDEXTERNAL":
                        {
                            bool external = evt == "SENDEXTERNAL" && Rules != null && Rules.Active && !string.IsNullOrEmpty(peer) && !Rules.IsInternalConnector(connector);
                            List<string> replies = external && rcpts.Length > 1 ? SplitEntries(recipientStatus) : null;
                            for (int k = 0; k < rcpts.Length; k++)
                            {
                                string x = rcpts[k];
                                if (status.TryGetValue(x, out cur) && Final.Contains(cur)) continue;
                                Set(x, HandedOff);
                                outside[x] = external && MailFlowRules.Accepted(EntryOf(recipientStatus, replies, k, rcpts.Length)) && Rules.IsForeign(x) ? peer : null;
                            }
                        }
                        break;
                    case "FAIL": foreach (var x in rcpts) Set(x, "Failed"); break;
                    case "DEFER": foreach (var x in rcpts) { if (!status.TryGetValue(x, out cur) || !Final.Contains(cur)) Set(x, "Deferred"); } break;
                    case "POISONMESSAGE": foreach (var x in rcpts) Set(x, "Poison"); break;
                    case "EXPAND":
                        Transit(rcpts);
                        if (related != null)
                        {
                            if (rcpts.Length > 0) givers.Add(related); else noMember.Add(related);
                            cur = Current(related);
                            if (cur == null || !Final.Contains(cur)) Set(related, "Expanded");
                        }
                        break;
                    case "DROP":
                        if (rcpts.Length == 0) dropped = true;
                        for (int k = 0; k < rcpts.Length; k++)
                        {
                            string x = rcpts[k], e = EntryOf(recipientStatus, entries, k, rcpts.Length);
                            cur = Current(x);
                            if (expansion[k]) { confirmed.Add(x); if (cur == null || !Final.Contains(cur) || cur == "Dropped") Set(x, "Expanded"); }
                            else if (IsSuppression(e)) { Set(x, "Suppressed"); suppressed = true; }
                            else { Set(x, "Dropped"); dropped = true; }
                        }
                        break;
                    case "RESOLVE": case "REDIRECT":
                        Transit(rcpts);
                        if (related != null)
                        {
                            if (rcpts.Length > 0) givers.Add(related);
                            cur = Current(related);
                            if (cur != null && !rcpts.Contains(related, StringComparer.OrdinalIgnoreCase) && !Final.Contains(cur) && !Alias.Contains(cur))
                                Set(related, evt == "RESOLVE" ? "Resolved" : "Redirected");
                        }
                        break;
                    default: Transit(rcpts); break;
                }
            }
            /// <param name="duration">false: no Duration text (null), for a caller that does not keep it (the rollup reconciliation).</param>
            internal object[] Row(Journey j, long smtpCount, Func<long, object> local, List<object[]> steps, List<object[]> transcripts, bool duration = true)
            {
                foreach (var d in noMember)
                    if (!givers.Contains(d) && confirmed.Contains(d) && Current(d) == "Expanded") { status[d] = "Suppressed"; suppressed = true; }
                // A hand-off that may have left the organization is sent to external when its next host is not a collected server (a configured
                // server or a server of this journey).
                if (outside.Count > 0)
                {
                    var journeyServers = new HashSet<string>(servers.Select(s => MailFlowRules.ServerKey(s)), StringComparer.Ordinal);
                    foreach (var pair in outside)
                    {
                        string cur;
                        if (pair.Value != null && status.TryGetValue(pair.Key, out cur) && cur == HandedOff && !journeyServers.Contains(pair.Value) && !Rules.IsCollected(pair.Value))
                            status[pair.Key] = MailFlowRules.SentToExternalStatus;
                    }
                }
                var finals = order.Where(r => !Alias.Contains(status[r])).ToList();
                var aliases = order.Where(r => Alias.Contains(status[r])).ToList();
                int total = finals.Count;
                int delivered = 0, failed = 0, sent = 0, external = 0, deferred = 0, drop = 0, supp = 0, transit = 0;
                foreach (var r in finals)
                    switch (status[r])
                    {
                        case "Delivered": delivered++; break;
                        case "Failed": case "Poison": failed++; break;
                        case HandedOff: sent++; break;
                        case "Sent to external": external++; break;
                        case "Deferred": deferred++; break;
                        case "Dropped": drop++; break;
                        case "Suppressed": supp++; break;
                        default: transit++; break;
                    }
                string overall;
                if (total == 0) overall = dropped ? "Dropped" : suppressed ? "Suppressed (by design)" : "In transit";
                else if (failed == total) overall = "Failed";
                else if (failed > 0) overall = "Partially failed";
                else if (drop > 0) overall = delivered + sent + external + deferred + transit == 0 ? "Dropped" : "Partially dropped";
                else if (supp == total) overall = "Suppressed (by design)";
                else if (delivered + supp == total) overall = "Delivered";
                else if (external > 0 && delivered + external + supp == total) overall = delivered > 0 ? "Delivered and sent to external" : "Sent to external";
                else if (delivered + external + sent + supp == total) overall = delivered > 0 ? "Delivered and handed off" : "Handed off outside collection";
                else if (deferred > 0) overall = "Deferred";
                else overall = "In transit";
                return new object[] {
                    local(j.First), local(j.Last), duration ? TimeUtil.Duration((j.Last - j.First) / 1000.0) : null, overall, j.Sender,
                    finals.Select(r => status[r] == "Delivered" ? r : r + " (" + status[r] + ")")
                        .Concat(aliases.Select(r => r + " (" + status[r] + ")")).ToArray(),
                    Math.Max(j.MaxCount, (long)total), (long)delivered, (long)failed, j.Subject, j.Size > 0 ? (object)(long)Math.Ceiling(j.Size / 1024.0) : null,
                    j.Direction, string.Join(" > ", servers), string.Join(" > ", events), smtpCount, j.MessageId, steps, transcripts };
            }
        }

        /// <param name="clock">Wall-clock text of a UTC time as the steps show it; by default derived from <paramref name="local"/> (seconds on the caller's clock).</param>
        /// <param name="rules">The stored rules of the external status (MailFlowRules.Read of the database the events come from).</param>
        static object[] JourneyRow(Journey j, List<object[]> sessions, ReportRequest q, Func<long, object> local, MailFlowRules rules, Func<long, string> clock = null)
        {
            var summary = new JourneySummary { Rules = rules };
            // e: 14 server_host, 15 connector, 20 server_ip
            foreach (var e in j.Events) summary.Add(S(e[2]), S(e[3]) ?? "", S(e[7]), S(e[8]), S(e[18]), S(e[15]), MailFlowRules.PeerKey(S(e[14]), S(e[20])));
            var steps = new List<object[]>();
            if (q.IncludeRoutingDetails)
            {
                // The servers whose logs are available: the configured ones and every server the message itself went through.
                var collected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var n in q.ConfiguredServers ?? new string[0]) collected.Add(RouteBuilder.Short(n));
                foreach (var e in j.Events) collected.Add(RouteBuilder.Short(S(e[2])));
                steps = RouteBuilder.Build(j, sessions, collected, local, clock ?? (ms => ClockOfSeconds(L(local(ms)))));
            }
            var transcripts = new List<object[]>();
            if (sessions != null)
                foreach (var s in sessions)
                    if (s[16] != null)
                        transcripts.Add(new object[] { local(L(s[1])), S(s[3]), S(s[4]) + " " + S(s[17]), new TranscriptRef(L(s[16])) });
            return summary.Row(j, sessions == null ? 0L : sessions.Count, local, steps, transcripts);
        }

        static string ClockOfSeconds(long seconds) { return TimeSpan.FromSeconds(((seconds % 86400) + 86400) % 86400).ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture); }
        internal static string ClockOfUtcMs(long ms) { return ClockOfSeconds(ms / 1000); }

        /// <summary>Authentication facts of an SMTP step: the account proved by the server, kept apart from the mechanism and from the envelope sender.</summary>
        static void AddAuthentication(List<string> parts, string[] auth, string envelopeSender)
        {
            parts.Add("Authentication mechanism " + auth[0]);
            parts.Add("Authentication result " + auth[1]);
            parts.Add("Authenticated user " + auth[3]);
            parts.Add("Identity evidence " + auth[4]);
            if (!string.IsNullOrEmpty(envelopeSender)) parts.Add("envelope sender " + envelopeSender);
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
                "Status:text", "Response:text", "Session ID:text", "Transcript:text", "Authentication mechanism:text", "Authentication result:text",
                "Last AUTH attempt:text", "Authenticated user:text", "Identity evidence:text" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[18].Grid = false; set.Columns[18].Csv = q.IncludeRoutingDetails;
            string where = " FROM smtp_transaction WHERE time_ms >= @t0 AND time_ms < @t1" +
                userFilter.Replace("sender", "mail_from").Replace("recipients", "rcpts") + serverFilter;
            string sql = "SELECT time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,status,response,session_id," +
                (q.IncludeRoutingDetails ? "transcript" : "NULL") + "," + SmtpAuthView.Columns + where + SmtpTimeOrder;
            int count = checked((int)L(store.Query("SELECT COUNT(*)" + where + ";", new System.Collections.Hashtable(p)).Rows[0][0]));
            // CSV-only details are streamed once from the source, never copied into the temporary report database.
            set.Rows = new ReportRows(() => SmtpRows(store, sql, p, local), count);
            return set;
        }

        static IEnumerable<object[]> SmtpRows(Store store, string sql, Dictionary<string, object> p, Func<long, object> local)
        {
            foreach (var r in Rows(store, sql, p))
            {
                var auth = SmtpAuthView.Fields(r, 19);
                yield return new object[] { local(L(r[0])), local(L(r[1])), S(r[2]), S(r[3]), S(r[4]), S(r[5]), S(r[6]), S(r[7]), S(r[8]), S(r[9]), S(r[10]),
                    S(r[11]), r[12], (S(r[13]) ?? "").Replace(";", "; "), S(r[14]), S(r[15]), S(r[16]), S(r[17]), S(r[18]), auth[0], auth[1], auth[2], auth[3], auth[4] };
            }
        }

        // ------------------------------------------------------------------ SMTP clients

        // Transactions of the same millisecond keep the order of ix_smtp_flow(time_ms,server,direction,status) then rowid, which
        // is what 2.x read implicitly: with only "ORDER BY time_ms" the order of ties followed whichever index the planner chose.
        const string SmtpTimeOrder = " ORDER BY time_ms,server,direction,status,id;";

        // Refused mail of the Messages view (message_id IS NULL): 2.x filtered on ix_smtp_message and sorted by "time_ms" only, so transactions of
        // the same millisecond kept the rowid order of that scan, not the order of ix_smtp_flow. Their order is the order of the Messages file.
        const string RefusedMailOrder = " ORDER BY time_ms,id;";

        /// <summary>
        /// One row per SMTP client (remote address + HELO name): the applications, devices, servers and
        /// users that send mail to the collected servers, with their volume and refusals. Hops between the
        /// collected Exchange servers (HELO of a configured server, delivery to the mailbox role) are left out.
        /// The Detailed report keeps up to 200 transactions per client (refusals first) with their transcript.
        /// </summary>
        static Dataset BuildSmtpClients(Store store, ReportRequest q, string userFilter, string serverFilter, Dictionary<string, object> p, Func<long, object> local)
        {
            var set = new Dataset("smtpclients", "SmtpClients", q.Scratch);
            foreach (var n in new[] { "Remote IP:text", "HELO:text", "Servers:text", "Connectors:text", "Transactions:num", "Accepted:num", "Rejected:num",
                "Deferred:num", "Not completed:num", "Recipients:num", "Senders:text", "TLS:text", "Authentication:text", "First seen:time", "Last seen:time",
                "Last error:text", "Transactions detail:steps", "Authentication mechanism:text", "Authentication result:text", "Last AUTH attempt:text",
                "Authenticated users:text", "Identity evidence:text", "Transactions without authenticated user:num" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[16].Grid = false; set.Columns[16].Csv = false;
            var exchange = new HashSet<string>((q.ConfiguredServers ?? new string[0]).Select(x => x.ToUpperInvariant()), StringComparer.OrdinalIgnoreCase);
            var clients = new Dictionary<string, SmtpClient>(StringComparer.OrdinalIgnoreCase);
            var transactions = q.Detailed && q.WriteHtml ? new ReportRows(q.Scratch) : null;
            var accounts = new SmtpAuthAccounts(q.Scratch);
            foreach (var r in Rows(store, "SELECT time_ms,server,connector,remote_ep,helo,tls,auth,mail_from,rcpt_count,status,response,message_id,id,role," + SmtpAuthView.Columns + " FROM smtp_transaction " +
                "WHERE time_ms >= @t0 AND time_ms < @t1 AND direction='Receive'" + userFilter + serverFilter + SmtpTimeOrder, p))
            {
                string helo = S(r[4]), role = S(r[13]);
                if (string.Equals(role, "Mailbox", StringComparison.OrdinalIgnoreCase)) continue;
                if (helo != null && exchange.Contains(Identity.ServerName(helo) ?? "")) continue;
                string ip = Identity.Host(S(r[3])) ?? "";
                SmtpClient c;
                string key = ip + "|" + (helo ?? "");
                if (!clients.TryGetValue(key, out c)) { c = new SmtpClient { Id = clients.Count + 1, Ip = ip, Helo = helo, First = L(r[0]) }; clients[key] = c; }
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
                var auth = SmtpAuthView.Fields(r, 14);
                c.AuthMechanism.Add(auth[0]); c.AuthResult.Add(auth[1]); c.AuthAttempt.Add(auth[2]); c.AuthEvidence.Add(auth[4]);
                if (r[17] == null) c.WithoutUser++; else accounts.Add(c.Id, S(r[17]));
                string from = string.IsNullOrEmpty(S(r[7])) ? "<>" : S(r[7]);
                long k; c.Senders.TryGetValue(from, out k); c.Senders[from] = k + 1;
                if (transactions != null)
                    transactions.Add(new object[] { local(t), S(r[1]), S(r[2]), status, from, L(r[8]), S(r[10]), S(r[11]), q.IncludeRoutingDetails ? (object)L(r[12]) : null,
                        auth[0], auth[1], auth[2], auth[3], auth[4] },
                        t, c.Id, status == "Accepted" ? 1 : 0);
            }
            foreach (var batch in Batches(clients.Values.OrderByDescending(x => x.Count).Select(c => new {
                Client = c, Detail = transactions == null ? new List<object[]>() : transactions.Sample(c.Id, c.Count)
            }), 500, x => x.Detail.Count))
            {
                ReferenceTranscripts(batch.SelectMany(x => x.Detail), 8);
                foreach (var item in batch)
                {
                    var c = item.Client; var detail = item.Detail;
                    set.Rows.Add(new object[] { c.Ip, c.Helo, string.Join(", ", c.Servers.OrderBy(x => x)), string.Join(", ", c.Connectors.OrderBy(x => x)), c.Count, c.Accepted,
                        c.Rejected, c.Deferred, c.Incomplete, c.Recipients,
                        string.Join(", ", c.Senders.OrderByDescending(x => x.Value).Take(3).Select(x => x.Key + " x" + x.Value.ToString(CultureInfo.InvariantCulture))) + (c.Senders.Count > 3 ? " (+" + (c.Senders.Count - 3) + ")" : ""),
                        c.Tls.Count == 0 ? "No" : string.Join(", ", c.Tls.OrderBy(x => x)), c.Auth.Count == 0 ? "Anonymous" : string.Join(", ", c.Auth.OrderBy(x => x)),
                        local(c.First), local(c.Last), c.LastError, detail,
                        string.Join(", ", c.AuthMechanism), string.Join(", ", c.AuthResult), string.Join(", ", c.AuthAttempt),
                        accounts.List(c.Id), string.Join(", ", c.AuthEvidence), c.WithoutUser });
                }
            }
            accounts.Dispose();
            if (transactions != null) transactions.Dispose();
            return set;
        }

        sealed class SmtpClient
        {
            public long Id, WithoutUser;
            public SortedSet<string> AuthMechanism = new SortedSet<string>(StringComparer.Ordinal), AuthResult = new SortedSet<string>(StringComparer.Ordinal);
            public SortedSet<string> AuthAttempt = new SortedSet<string>(StringComparer.Ordinal), AuthEvidence = new SortedSet<string>(StringComparer.Ordinal);
            public string Ip, Helo, LastError;
            public long First, Last, Count, Accepted, Rejected, Deferred, Incomplete, Recipients;
            public SortedSet<string> Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase), Connectors = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            public SortedSet<string> Tls = new SortedSet<string>(StringComparer.Ordinal), Auth = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            public Dictionary<string, long> Senders = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
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
            var set = new Dataset("smtpdestinations", "SmtpDestinations", q.Scratch);
            foreach (var n in new[] { "Remote IP:text", "Remote host:text", "Connector:text", "Servers:text", "Transactions:num", "Sent:num", "Deferred:num", "Failed:num",
                "Not completed:num", "Recipients:num", "Senders:text", "TLS:text", "First seen:time", "Last seen:time", "Last error:text", "Transactions detail:steps" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[15].Grid = false; set.Columns[15].Csv = false;
            var targets = new Dictionary<string, SmtpTarget>(StringComparer.OrdinalIgnoreCase);
            var transactions = q.Detailed && q.WriteHtml ? new ReportRows(q.Scratch) : null;
            foreach (var r in Rows(store, "SELECT time_ms,server,connector,remote_ep,tls,mail_from,rcpt_count,status,response,message_id,id,transcript IS NOT NULL FROM smtp_transaction " +
                "WHERE time_ms >= @t0 AND time_ms < @t1 AND direction='Send'" + userFilter + serverFilter + SmtpTimeOrder, p))
            {
                string ip = Identity.Host(S(r[3])) ?? "", connector = S(r[2]) ?? "";
                SmtpTarget c;
                if (!targets.TryGetValue(ip + "|" + connector, out c)) { c = new SmtpTarget { Id = targets.Count + 1, Ip = ip, Connector = connector, First = L(r[0]) }; targets[ip + "|" + connector] = c; }
                long t = L(r[0]);
                string status = S(r[7]) ?? "";
                c.Last = t; c.Count++;
                switch (status)
                {
                    case "Sent": c.Sent++; break;
                    case "Rejected": c.Failed++; c.LastError = S(r[8]); break;
                    case "Deferred": c.Deferred++; c.LastError = S(r[8]); break;
                    default: c.Incomplete++; break;
                }
                if (L(r[11]) != 0) { c.WithTranscript.Enqueue(L(r[10])); if (c.WithTranscript.Count > 3) c.WithTranscript.Dequeue(); }
                c.Recipients += L(r[6]);
                c.Servers.Add(S(r[1]) ?? "");
                if (S(r[4]) != null) c.Tls.Add(S(r[4]));
                string from = string.IsNullOrEmpty(S(r[5])) ? "<>" : S(r[5]);
                long k; c.Senders.TryGetValue(from, out k); c.Senders[from] = k + 1;
                if (transactions != null)
                    transactions.Add(new object[] { local(t), S(r[1]), S(r[2]), status, from, L(r[6]), S(r[8]), S(r[9]), q.IncludeRoutingDetails ? (object)L(r[10]) : null },
                        t, c.Id, status == "Sent" ? 1 : 0);
            }
            // Remote host: the name in the 220 banner, from the last transcripts of each destination.
            var banners = new TranscriptCache(store, Math.Min(16L * 1048576, q.WorkingBudgetBytes / 8));
            q.Scratch.Working(banners.LimitBytes);
            foreach (var c in targets.Values)
                foreach (var id in c.WithTranscript.Reverse())
                {
                    string s = banners.Get(id); if (s == null) continue;
                    var b = BannerRx.Match(s); if (b.Success) { c.Host = b.Groups[1].Value; break; }
                }
            q.Scratch.Working(0);
            banners.Clear();
            foreach (var batch in Batches(targets.Values.OrderByDescending(x => x.Count).Select(c => new {
                Target = c, Detail = transactions == null ? new List<object[]>() : transactions.Sample(c.Id, c.Count)
            }), 500, x => x.Detail.Count))
            {
                ReferenceTranscripts(batch.SelectMany(x => x.Detail), 8);
                foreach (var item in batch)
                {
                    var c = item.Target; var detail = item.Detail;
                    set.Rows.Add(new object[] { c.Ip, c.Host, c.Connector, string.Join(", ", c.Servers), c.Count, c.Sent, c.Deferred, c.Failed, c.Incomplete, c.Recipients,
                        string.Join(", ", c.Senders.OrderByDescending(x => x.Value).Take(3).Select(x => x.Key + " x" + x.Value.ToString(CultureInfo.InvariantCulture))) + (c.Senders.Count > 3 ? " (+" + (c.Senders.Count - 3) + ")" : ""),
                        c.Tls.Count == 0 ? "No" : string.Join(", ", c.Tls), local(c.First), local(c.Last), c.LastError, detail });
                }
            }
            if (transactions != null) transactions.Dispose();
            return set;
        }

        sealed class SmtpTarget
        {
            public long Id;
            public string Ip, Host, Connector, LastError;
            public long First, Last, Count, Sent, Deferred, Failed, Incomplete, Recipients;
            public SortedSet<string> Servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase), Tls = new SortedSet<string>(StringComparer.Ordinal);
            public Dictionary<string, long> Senders = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            /// <summary>Ids of the last transactions with a transcript (remote host of the 220 banner).</summary>
            public Queue<long> WithTranscript = new Queue<long>();
        }

        // ------------------------------------------------------------------ CSV

        internal static string Csv(object v, string sep)
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
                        lines.Add(string.Join(" | ", step.Take(c.Name == "Route" ? 6 : step.Length).Select((x, i) =>
                        {
                            // The route keeps its precision (the order of events within a second matters) and the submission each step belongs to.
                            if (c.Name == "Route" && i == 5) return x != null ? "submission " + S(x) : null;
                            if (i == 0 && x != null)
                                return DateTimeOffset.FromUnixTimeSeconds(L(x)).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
                                    + (c.Name == "Route" && step.Length > 6 && step[6] != null ? "." + (((L(step[6]) % 1000) + 1000) % 1000).ToString("000", CultureInfo.InvariantCulture) : "");
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
            string partial = path + ".partial";
            using (var w = new StreamWriter(partial, false, new UTF8Encoding(true)))
            {
                w.Write(string.Join(sep, cols.Select(x => Csv(x.c.Name, sep))));
                w.Write("\r\n");
                foreach (var row in d.Rows)
                {
                    w.Write(string.Join(sep, cols.Select(x => { object v = row[x.i]; string t = CsvCell(v, x.c); return Csv(t ?? v, sep); })));
                    w.Write("\r\n");
                }
            }
            File.Move(partial, path, true);
            return new ReportFile { Path = path, Dataset = d.Name, Rows = d.Rows.Count, Bytes = new FileInfo(path).Length };
        }

        static ReportFile WriteAccessCsv(Store store, string path, string sep, string sql, Dictionary<string, object> p, TimeZoneInfo zone)
        {
            string[] header = { "Day", "Server", "User", "Mailbox", "Protocol", "Requests", "Successes", "Client errors", "Server errors", "Slow", "Bytes in", "Bytes out",
                "Average (ms)", "Max (ms)", "First seen", "Last seen", "Last client IP", "Last user agent" };
            long rows = 0;
            string partial = path + ".partial";
            using (var w = new StreamWriter(partial, false, new UTF8Encoding(true)))
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
            File.Move(partial, path, true);
            return new ReportFile { Path = path, Dataset = "access", Rows = rows, Bytes = new FileInfo(path).Length };
        }
    }
}
