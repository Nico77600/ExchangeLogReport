using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    internal sealed class ServeError : Exception
    {
        internal readonly int Status;
        internal readonly string Code;
        internal ServeError(int status, string code, string message) : base(message) { Status = status; Code = code; }
    }

    internal sealed class ServeColumn
    {
        public string name { get; set; }
        public string kind { get; set; }
        public bool grid { get; set; } = true;
        internal static ServeColumn[] Parse(IEnumerable<string> names) { return names.Select(n => {
            int colon = n.LastIndexOf(':');
            return new ServeColumn { name = n.Substring(0, colon), kind = n.Substring(colon + 1), grid = !n.EndsWith(":steps", StringComparison.Ordinal) };
        }).ToArray(); }
    }
    internal sealed class ServeRow
    {
        public long id { get; set; }
        public object[] cells { get; set; }
    }
    /// <summary>A row of a list keyed by text (users: the base64url of the UTF-8 user name), opened by /api/users/{id}.</summary>
    internal sealed class ServeKeyRow
    {
        public string id { get; set; }
        public object[] cells { get; set; }
    }
    internal sealed class ServePage
    {
        public ServeColumn[] columns { get; set; }
        public List<ServeRow> rows { get; set; } = new List<ServeRow>();
        /// <summary>Page number of the offset lists; absent on the keyset lists.</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public int? page { get; set; }
        public int size { get; set; }
        public bool hasMore { get; set; }
        public long? total { get; set; }
        /// <summary>Keyset lists: the cursor of the last row returned ("key.id"), null when the window is exhausted.</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public string nextCursor { get; set; }
        /// <summary>Keyset lists: true when the request read to the end of its order window.</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public bool? exhausted { get; set; }
        /// <summary>Keyset lists read chunk by chunk (filters on the cells): the position examined up to, which is also the cursor to continue from.</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public string scannedTo { get; set; }
        /// <summary>Keyset lists: false when the scan budget ended the page before it held size rows or reached the end of its window.</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public bool? complete { get; set; }
        /// <summary>Keyset lists read chunk by chunk: the time budget of the request (milliseconds).</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public int? budgetMs { get; set; }
        /// <summary>Keyset lists with skip: the rows of the selection passed over by this request (a scan may stop before it passed over skip rows).</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public int? skipped { get; set; }
        /// <summary>
        /// Messages: true when an exact Message-ID (=x) is stored neither as typed, nor in lower case, nor in upper case: no row was searched for another
        /// spelling (anyCase=1 searches them).
        /// </summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public bool? exactMiss { get; set; }
    }
    internal sealed class ServeFilter
    {
        internal long From, To;
        /// <summary>
        /// Optional window [OrderFrom, OrderTo) on the sort key of a list (messages: member_last_ms; sessions: start_ms; SMTP transactions: time_ms).
        /// Membership is still [From, To): the window only selects which rows of the period the request lists, so disjoint windows that cover the key
        /// space list every row once, in the order of the whole list.
        /// </summary>
        internal long? OrderFrom, OrderTo;
        internal int Page = 1, Size = 100;
        internal string User, Server, Status, View;
        /// <summary>Keyset lists: continue after the row (CursorKey, CursorId) of the list order; Ascending: the order of the key (descending by default).</summary>
        internal long? CursorKey, CursorId;
        internal bool Ascending;
        /// <summary>Keyset lists: rows passed over inside the order window (0..10000, only with orderFrom and orderTo).</summary>
        internal int Skip;
        /// <summary>Messages: an exact Message-ID stored in none of the spellings the index is asked for is searched in every row (anyCase=1).</summary>
        internal bool AnyCase;
        /// <summary>The parameters of the request: the filters of the page (f., m., x., q, w) are compiled from them by ServeCellFilter.</summary>
        internal System.Collections.Specialized.NameValueCollection Query;
        /// <summary>Scan requests: a budget lower than Serve's (budgetMs); /count: the width of a histogram bucket; /facets: the columns and the cap of their lists.</summary>
        internal int? BudgetMs, Cap;
        internal long BucketMs = 900000;
        internal string[] Columns;
        /// <param name="maxSize">Largest page size the list accepts.</param>
        /// <param name="view">The view whose filter parameters (f.|m.|x.&lt;Column&gt;) the request may carry, besides the names allowed.</param>
        internal static ServeFilter Parse(System.Collections.Specialized.NameValueCollection query, string[] allowed, int maxSize = 500, ServeView view = null)
        {
            var names = new HashSet<string>(allowed, StringComparer.Ordinal);
            foreach (string key in query.AllKeys)
                if (key == null || !(names.Contains(key) || (view != null && view.FilterParameter(key))) || query.GetValues(key).Length != 1)
                    throw new ServeError(400, "InvalidParameter", "Unknown or repeated parameter.");
            var f = new ServeFilter();
            f.To = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (query["to"] != null) f.To = Time(query["to"]);
            f.From = query["from"] == null ? checked(f.To - 7L * 86400000) : Time(query["from"]);
            if (f.From >= f.To || f.From < DateTimeOffset.MinValue.ToUnixTimeMilliseconds())
                throw new ServeError(400, "InvalidPeriod", "from must precede to (exclusive), within the supported date range.");
            f.Page = Number(query["page"], 1, 1, 10001);
            f.Size = Number(query["size"], 100, 1, maxSize);
            if ((long)(f.Page - 1) * f.Size > 10000)
                throw new ServeError(400, "PageLimit", "Offset exceeds 10000; narrow the period or export CSV.");
            f.User = Text(query["user"]); f.Server = Text(query["server"]); f.Status = Text(query["status"]); f.View = query["view"];
            if (query["orderFrom"] != null) f.OrderFrom = Time(query["orderFrom"]);
            if (query["orderTo"] != null) f.OrderTo = Time(query["orderTo"]);
            if (f.OrderFrom.HasValue && f.OrderTo.HasValue && f.OrderFrom.Value >= f.OrderTo.Value)
                throw new ServeError(400, "InvalidOrderWindow", "orderFrom must precede orderTo (exclusive).");
            if (query["cursor"] != null)
            {
                var cursor = System.Text.RegularExpressions.Regex.Match(query["cursor"], @"^(\d{1,16})\.(\d{1,19})$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
                long key, id;
                if (!cursor.Success || !long.TryParse(cursor.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out key) ||
                    !long.TryParse(cursor.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out id))
                    throw new ServeError(400, "InvalidCursor", "cursor must be <key ms>.<row id>.");
                f.CursorKey = key; f.CursorId = id;
            }
            if (query["dir"] != null)
            {
                if (query["dir"] != "asc" && query["dir"] != "desc") throw new ServeError(400, "InvalidDirection", "dir must be asc or desc.");
                f.Ascending = query["dir"] == "asc";
            }
            if (query["skip"] != null)
            {
                f.Skip = Number(query["skip"], 0, 0, 10000);
                if (f.Skip > 0 && (!f.OrderFrom.HasValue || !f.OrderTo.HasValue))
                    throw new ServeError(400, "SkipWindow", "skip requires both orderFrom and orderTo.");
            }
            if (query["anyCase"] != null)
            {
                if (query["anyCase"] != "1") throw new ServeError(400, "InvalidParameter", "anyCase must be 1.");
                f.AnyCase = true;
            }
            if (query["day"] != null && !System.Text.RegularExpressions.Regex.IsMatch(query["day"], @"^\d{4}-\d{2}-\d{2}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                throw new ServeError(400, "InvalidDay", "day must be a date YYYY-MM-DD.");
            foreach (string key in query.AllKeys)
                if (key == "q" || key == "w" || (view != null && view.FilterParameter(key))) Text(query[key]);
            if (query["budgetMs"] != null) f.BudgetMs = Bounded(query["budgetMs"], "budgetMs", 100, 120000);
            if (query["bucketMs"] != null) f.BucketMs = Bounded(query["bucketMs"], "bucketMs", 1000, 86400000);
            if (query["cap"] != null) f.Cap = Bounded(query["cap"], "cap", 1, 300);
            // The columns of value lists are validated by their names (each a text or list column of the view, at most one per column), not by a length.
            if (query["columns"] != null)
            {
                f.Columns = query["columns"].Split('|').Where(x => x.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
                if (f.Columns.Length == 0 || (view != null && (f.Columns.Length > view.Columns.Length || f.Columns.Any(name =>
                    { var c = view.Find(name); return c == null || (c.Kind != "text" && c.Kind != "list"); }))))
                    throw new ServeError(400, "InvalidParameter", "columns must name text or list columns of the view.");
            }
            f.Query = query;
            return f;
        }
        static int Bounded(string s, string name, int min, int max)
        {
            int n;
            if (!int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n) || n < min || n > max)
                throw new ServeError(400, "InvalidParameter", name + " must be " + min.ToString(CultureInfo.InvariantCulture) + ".." + max.ToString(CultureInfo.InvariantCulture) + ".");
            return n;
        }
        static int Number(string s, int fallback, int min, int max)
        {
            if (s == null) return fallback;
            int n;
            if (!int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n) || n < min || n > max)
                throw new ServeError(400, "InvalidPage", "Invalid page or size.");
            return n;
        }
        static long Time(string s)
        {
            DateTimeOffset value;
            if (s.Length > 64 || !System.Text.RegularExpressions.Regex.IsMatch(s, @"T.*(?:Z|[+-]\d{2}:\d{2})$",
                System.Text.RegularExpressions.RegexOptions.CultureInvariant) ||
                !DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out value))
                throw new ServeError(400, "InvalidTime", "Use ISO 8601 with T and an explicit offset or Z.");
            return value.ToUnixTimeMilliseconds();
        }
        static string Text(string s)
        {
            if (s != null && (s.Length > 256 || s.Any(char.IsControl))) throw new ServeError(400, "InvalidFilter", "Filter is too long or contains control characters.");
            return string.IsNullOrEmpty(s) ? null : s;
        }
    }

    internal sealed partial class ServeRead : IDisposable
    {
        readonly SqliteConnection _db;
        readonly CancellationToken _cancel;
        readonly CancellationTokenRegistration _interrupt;
        readonly Dictionary<string, bool> _wholePeriod = new Dictionary<string, bool>(StringComparer.Ordinal);
        // exl_remote_host (schema 11: used by the verification only; the reads use smtp_client) is a pure function of the endpoint text: its results are
        // remembered for the life of this connection (one request, see Engine.Serve.cs) so each distinct endpoint is parsed once.
        // The lock only protects against a statement stepped by another thread; the cap bounds the memory of a very large selection.
        readonly Dictionary<string, string> _remoteHosts = new Dictionary<string, string>(StringComparer.Ordinal);
        const int RemoteHostMemoLimit = 65536;
        SqliteTransaction _tx;
        readonly ServeOptions _options;
        internal ServeRead(ServeOptions options, CancellationToken cancel)
        {
            if (!File.Exists(options.DatabasePath)) throw new ServeError(422, "DatabaseMissing", "Database not found; collect separately.");
            _cancel = cancel;
            _options = options;
            _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Store.SqlitePath(options.DatabasePath),
                Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Private, Pooling = false, DefaultTimeout = 1 }.ToString());
            try
            {
                _db.Open();
                _db.CreateFunction<string, string>("exl_remote_host", MemoizedRemoteHost, isDeterministic: true);
                // The message hash of a text (a look-up accelerator: every look-up through it compares the identity on the row).
                _db.CreateFunction<string, long?>("exl_msg_hash", Store.MessageHash, isDeterministic: true);
                using (var c = _db.CreateCommand())
                {
                    c.CommandText = "PRAGMA query_only=ON; PRAGMA busy_timeout=250; PRAGMA cache_size=-" + options.CacheKilobytes.ToString(CultureInfo.InvariantCulture) +
                        "; PRAGMA temp_store=FILE; PRAGMA mmap_size=" + (options.MmapMB * 1048576L).ToString(CultureInfo.InvariantCulture) + ";";
                    c.ExecuteNonQuery();
                }
                _lastProgress = Stopwatch.GetTimestamp();
                // Every 1000 virtual-machine steps (also while a sort runs): the deadline, and the heartbeat a verification watches.
                SQLitePCL.raw.sqlite3_progress_handler(_db.Handle, 1000, _ => { Progress(); return cancel.IsCancellationRequested ? 1 : 0; }, null);
                _interrupt = cancel.Register(() => SQLitePCL.raw.sqlite3_interrupt(_db.Handle));
                _tx = _db.BeginTransaction(deferred: true);
            }
            catch { _interrupt.Dispose(); _db.Dispose(); throw; }
        }
        string MemoizedRemoteHost(string endpoint)
        {
            if (string.IsNullOrEmpty(endpoint)) return RemoteHost(endpoint);
            lock (_remoteHosts)
            {
                string host;
                if (_remoteHosts.TryGetValue(endpoint, out host)) return host;
                host = RemoteHost(endpoint);
                if (_remoteHosts.Count >= RemoteHostMemoLimit) _remoteHosts.Clear();
                _remoteHosts[endpoint] = host;
                return host;
            }
        }
        long _lastProgress, _maxProgressGap;
        /// <summary>
        /// Records progress now (a SQLite progress step or a verified identity, both on the thread that owns the connection) and the longest gap between
        /// two of them; LastProgress: the Stopwatch timestamp of the latest progress of any kind.
        /// </summary>
        internal void Progress()
        {
            long now = Stopwatch.GetTimestamp();
            long gap = now - Volatile.Read(ref _lastProgress);
            if (gap > Volatile.Read(ref _maxProgressGap)) Volatile.Write(ref _maxProgressGap, gap);
            Volatile.Write(ref _lastProgress, now);
        }
        internal long LastProgress() { return Volatile.Read(ref _lastProgress); }
        /// <summary>Longest gap between two progress records (Stopwatch ticks) since ResetProgressGap.</summary>
        internal long MaxProgressGapTicks() { return Volatile.Read(ref _maxProgressGap); }
        internal void ResetProgressGap() { Volatile.Write(ref _maxProgressGap, 0); }
        /// <summary>
        /// Sets the directory of SQLite's temporary (sort) files: sqlite3_temp_directory, which is process-wide ('' restores the default). False when the
        /// pragma is refused. Runs without the deadline check, so a cancelled run still restores it.
        /// </summary>
        internal bool SetTempDirectory(string directory)
        {
            try
            {
                using (var c = _db.CreateCommand())
                {
                    c.Transaction = _tx;
                    c.CommandText = "PRAGMA temp_store_directory='" + directory.Replace("'", "''") + "';";
                    c.ExecuteNonQuery();
                }
                return true;
            }
            catch (SqliteException) { return false; }
        }
        /// <summary>Pages this connection read from the file (SQLITE_DBSTATUS_CACHE_MISS): a disk-independent measure of the I/O of its statements.</summary>
        internal long CacheMissPages()
        {
            int current, highwater;
            SQLitePCL.raw.sqlite3_db_status(_db.Handle, 7, out current, out highwater, 0);
            return current;
        }
        /// <summary>PRAGMA page_count x page_size of the snapshot.</summary>
        internal long FileBytes()
        {
            using (var c = Command("SELECT (SELECT page_count FROM pragma_page_count())*(SELECT page_size FROM pragma_page_size());")) return Long(c.ExecuteScalar());
        }
        internal SqliteCommand Command(string sql)
        {
            _cancel.ThrowIfCancellationRequested();
            var c = _db.CreateCommand(); c.Transaction = _tx; c.CommandText = sql; c.CommandTimeout = 1; return c;
        }
        internal static readonly int SupportedSchema = int.Parse(Store.SchemaVersion, CultureInfo.InvariantCulture);
        internal int Schema()
        {
            using (var c = Command("SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata';"))
                if (c.ExecuteScalar() == null) return 0;
            using (var c = Command("SELECT value FROM metadata WHERE key='schema_version';"))
            { int version; return int.TryParse(Convert.ToString(c.ExecuteScalar(), CultureInfo.InvariantCulture), out version) ? version : 0; }
        }
        /// <summary>Upper bounds of the journey and session spans (metadata, read by Ready): FilterCommand narrows the index ranges of a period with them.</summary>
        internal long RollupSpanMs, SessionSpanMs;
        /// <param name="requireShape">Serve requests: the covering indexes and the span bounds must exist (422 ShapeRequired otherwise) and the bounds are
        /// read. The verifications pass false: their exact schema check reports every difference itself.</param>
        internal void Ready(bool requireShape = true)
        {
            if (Schema() != SupportedSchema) throw new ServeError(422, "MigrationRequired", "Schema " + SupportedSchema.ToString(CultureInfo.InvariantCulture) + " is required. Serve never migrates; use an explicit writable collection or a verified copy migration.");
            if (requireShape) ReadShape();
            using (var c = Command("SELECT value FROM metadata WHERE key='message_hash_algorithm';"))
                if (!string.Equals(c.ExecuteScalar() as string, Store.MessageHashAlgorithm, StringComparison.Ordinal))
                    throw new ServeError(422, "IncompatibleHash", "Unknown message hash algorithm.");
            using (var c = Command("SELECT 1 FROM message_rollup_dirty LIMIT 1;"))
                if (c.ExecuteScalar() != null) throw new ServeError(503, "RollupPending", "A writable client committed unreconciled changes; finish collection reconciliation first.");
            // Schema 11: SMTP transactions written, changed or removed by a connection that did not maintain the client structures wait in these queues.
            using (var c = Command("SELECT EXISTS(SELECT 1 FROM smtp_client_pending) OR EXISTS(SELECT 1 FROM smtp_client_dirty);"))
                if (Long(c.ExecuteScalar()) != 0) throw new ServeError(503, "SmtpClientsPending", "A writable client committed unreconciled SMTP transactions; finish collection reconciliation first.");
            // Schema 12: tracking events and SMTP transactions written, changed or removed by a connection that did not maintain the mail flow per hour.
            if (requireShape)
                using (var c = Command("SELECT EXISTS(SELECT 1 FROM mail_flow_dirty);"))
                    if (Long(c.ExecuteScalar()) != 0) throw new ServeError(503, "MailFlowPending", "A writable client committed mail flow rows that are not aggregated yet; finish collection reconciliation first.");
        }
        const string ShapeMessage = "This database was written by an earlier 3.0 build and lacks the indexes or columns of this version. Run one collection on it (Run-Collector.cmd) or migrate a copy (Database-Storage.cmd --storage-copy --migrate); Serve never changes a database.";
        /// <summary>
        /// The objects of the current shape have their canonical definition: the covering message_rollup and client_session indexes and the mail flow
        /// tables; and the indexes of the mail flow and of the unresolved failures on their source tables (ix_msg_noid_flow, ix_event_resolution,
        /// ix_usage_day_success) and the six mail flow triggers (without one of them a writer could change the rows without queueing the hour it
        /// changes). The authentication columns exist (access_client.auth_type as the seventh key column, client_session.auth_modes). Both span
        /// bounds are non-negative integer texts; reads the bounds. The fold (EnsureServeShape12) rebuilds on these objects.
        /// </summary>
        void ReadShape()
        {
            // [type, name, canonical sql]
            var objects = new List<string[]>();
            foreach (var index in Store.ServeRollupIndexes)
                if (index[1] == "message_rollup" || index[1] == "client_session" || index[0] == "ix_msg_noid_flow" || index[0] == "ix_event_resolution" || index[0] == "ix_usage_day_success")
                    objects.Add(new[] { "index", index[0], index[2] });
            foreach (var table in Store.MailFlowTables) objects.Add(new[] { "table", table[0], table[1] });
            foreach (var trigger in Store.MailFlowTriggers) objects.Add(new[] { "trigger", trigger[0], trigger[2] });
            using (var c = Command("SELECT COUNT(*) FROM (VALUES" + string.Join(",", objects.Select((o, i) => "(@t" + i.ToString(CultureInfo.InvariantCulture) +
                ",@n" + i.ToString(CultureInfo.InvariantCulture) + ",@q" + i.ToString(CultureInfo.InvariantCulture) + ")")) +
                ") v WHERE NOT EXISTS(SELECT 1 FROM sqlite_master m WHERE m.type=v.column1 AND m.name=v.column2 AND m.sql=v.column3);"))
            {
                for (int i = 0; i < objects.Count; i++)
                {
                    string k = i.ToString(CultureInfo.InvariantCulture);
                    c.Parameters.AddWithValue("@t" + k, objects[i][0]); c.Parameters.AddWithValue("@n" + k, objects[i][1]); c.Parameters.AddWithValue("@q" + k, objects[i][2]);
                }
                if (Long(c.ExecuteScalar()) != 0) throw new ServeError(422, "ShapeRequired", ShapeMessage);
            }
            using (var c = Command("SELECT (SELECT COUNT(*) FROM pragma_table_info('access_client') WHERE name='auth_type' AND pk=7)+(SELECT COUNT(*) FROM pragma_table_info('client_session') WHERE name='auth_modes');"))
                if (Long(c.ExecuteScalar()) != 2) throw new ServeError(422, "ShapeRequired", ShapeMessage);
            long rollup = -1, session = -1;
            using (var c = Command("SELECT key,CAST(value AS INTEGER) FROM metadata WHERE key IN('rollup_max_span_ms','session_max_span_ms') AND typeof(value)='text' AND value=CAST(CAST(value AS INTEGER) AS TEXT);"))
            using (var r = c.ExecuteReader())
                while (r.Read()) { if (r.GetString(0) == "rollup_max_span_ms") rollup = r.GetInt64(1); else session = r.GetInt64(1); }
            if (rollup < 0 || session < 0) throw new ServeError(422, "ShapeRequired", ShapeMessage);
            RollupSpanMs = rollup; SessionSpanMs = session;
        }
        /// <summary>The servers whose logs were collected, as the database knows them: the report's "configured servers", so a route marks the same hosts "(not collected)" as the report does.</summary>
        List<string> SourceServers()
        {
            var servers = new List<string>();
            using (var c = Command("SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_file';"))
            if (c.ExecuteScalar() != null)
                using (var names = Command("SELECT DISTINCT server COLLATE NOCASE FROM source_file ORDER BY server COLLATE NOCASE;"))
                using (var r = names.ExecuteReader()) while (r.Read()) servers.Add(r.GetString(0));
            return servers;
        }
        internal object Meta(ServeOptions options)
        {
            int schema = Schema();
            var servers = SourceServers();
            long? first = null, last = null;
            using (var c = Command("SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_file';"))
            if (c.ExecuteScalar() != null)
            {
                using (var bounds = Command("SELECT MIN(NULLIF(first_ms,0)),MAX(NULLIF(last_ms,0)) FROM source_file;"))
                using (var r = bounds.ExecuteReader()) if (r.Read()) { if (!r.IsDBNull(0)) first = r.GetInt64(0); if (!r.IsDBNull(1)) last = r.GetInt64(1); }
            }
            return new { name = "Exchange Log Report", version = ProductVersion, schemaVersion = schema, supportedSchemaVersion = SupportedSchema,
                requiresMigration = schema != SupportedSchema, databaseBytes = new FileInfo(options.DatabasePath).Length,
                coveredFrom = Iso(first), coveredTo = Iso(last), servers, readOnly = true, mode = "Serve", timeZone = options.Zone.Id, timeZoneIana = IanaZone(options.Zone) };
        }
        internal static object MissingMeta() { return new { name = "Exchange Log Report", version = ProductVersion, schemaVersion = 0,
            supportedSchemaVersion = SupportedSchema, requiresMigration = true, databaseBytes = 0L, coveredFrom = (string)null, coveredTo = (string)null,
            servers = new string[0], readOnly = true, mode = "Serve" }; }
        /// <summary>The version of the product, as the portal answers it.</summary>
        internal const string ProductVersion = "3.0.0";
        /// <summary>The IANA name of a time zone (the page does its day arithmetic with Intl), null when it has none.</summary>
        internal static string IanaZone(TimeZoneInfo zone)
        {
            string iana;
            if (zone.HasIanaId) return zone.Id;
            return TimeZoneInfo.TryConvertWindowsIdToIanaId(zone.Id, out iana) ? iana : null;
        }
        internal static string Iso(long? ms) { return ms.HasValue ? DateTimeOffset.FromUnixTimeMilliseconds(ms.Value).ToString("O", CultureInfo.InvariantCulture) : null; }
        internal static long Long(object value) { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
        internal static string Text(object value) { return value == null || value is DBNull ? null : Packed.Text(value); }
        internal static string Like(string value) { return "%" + value.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%"; }
        internal SqliteCommand FilterCommand(string sql, ServeFilter f, long? id = null)
        {
            var c = Command(sql);
            FilterParameters(c, f, id);
            return c;
        }
        internal void FilterParameters(SqliteCommand c, ServeFilter f, long? id = null)
        {
            c.Parameters.AddWithValue("@f", f.From); c.Parameters.AddWithValue("@t", f.To);
            // The ends of the index ranges: journeys of the period end before to + span; sessions of the period start at or after from - span.
            c.Parameters.AddWithValue("@tb", RollupSpanMs > long.MaxValue - f.To ? long.MaxValue : f.To + RollupSpanMs);
            c.Parameters.AddWithValue("@sf", SessionSpanMs > f.From - long.MinValue / 2 ? long.MinValue / 2 : f.From - SessionSpanMs);
            if (f.OrderFrom.HasValue) c.Parameters.AddWithValue("@of", f.OrderFrom.Value);
            if (f.OrderTo.HasValue) c.Parameters.AddWithValue("@ot", f.OrderTo.Value);
            if (f.User != null) c.Parameters.AddWithValue("@u", Like(f.User));
            if (f.Server != null) c.Parameters.AddWithValue("@s", f.Server);
            if (f.Status != null) c.Parameters.AddWithValue("@status", f.Status);
            if (id.HasValue) c.Parameters.AddWithValue("@id", id.Value);
        }
        static string SourceFilter(ServeFilter f, string alias, bool smtp)
        {
            string result = f.Server == null ? "" : " AND " + alias + ".server=@s COLLATE NOCASE";
            if (f.User != null)
                result += " AND (" + alias + "." + (smtp ? "mail_from" : "sender") + " LIKE @u ESCAPE '\\' OR " +
                    alias + "." + (smtp ? "rcpts" : "recipients") + " LIKE @u ESCAPE '\\'" +
                    (smtp ? " OR " + alias + ".auth_user LIKE @u ESCAPE '\\'" : "") + ")";
            return result;
        }
        internal static bool ScopedMessages(ServeFilter f) { return f.User != null || f.Server != null; }
        // Schema 11: message_rollup.status is a dictionary code. The text filter (ASCII case-insensitive, as before) is resolved to codes first:
        // no code selects nothing, one code is an equality (ordered index read), several codes (texts that differ only by case) an IN list.
        readonly Dictionary<string, long[]> _statusCodes = new Dictionary<string, long[]>(StringComparer.Ordinal);
        long[] StatusCodes(string status)
        {
            long[] codes;
            if (_statusCodes.TryGetValue(status, out codes)) return codes;
            var list = new List<long>();
            using (var c = Command("SELECT id FROM message_rollup_value WHERE text=@s COLLATE NOCASE ORDER BY id;"))
            {
                c.Parameters.AddWithValue("@s", status);
                using (var r = c.ExecuteReader()) while (r.Read()) list.Add(r.GetInt64(0));
            }
            return _statusCodes[status] = list.ToArray();
        }
        /// <summary>True when a status filter names a text no rollup row can have: the selection is empty.</summary>
        internal bool NoMessageStatus(ServeFilter f) { return f.Status != null && StatusCodes(f.Status).Length == 0; }
        string MessageBounds(ServeFilter f)
        {
            string status = "";
            if (f.Status != null)
            {
                var codes = StatusCodes(f.Status);
                status = codes.Length == 0 ? " AND 0" : codes.Length == 1 ? " AND r.status=" + codes[0].ToString(CultureInfo.InvariantCulture) :
                    " AND r.status IN(" + string.Join(",", codes.Select(x => x.ToString(CultureInfo.InvariantCulture))) + ")";
            }
            // member_last_ms < to + span is implied by member_first_ms < to (ServeSpanMetadata); stated, it ends the index range.
            return "r.member_last_ms>=@f AND r.member_last_ms<@tb AND r.member_first_ms<@t" + OrderWindow(f, "r.member_last_ms") + status + " AND " + TrackedOrRefused;
        }
        /// <summary>
        /// The messages of the report: a tracked message (at least one tracking event) or mail refused during the SMTP conversation (kind 1, no
        /// Message-ID). An SMTP transaction with a Message-ID and no tracking event is not a message of the report; it stays in the transactions of
        /// its SMTP client. Part of every message path (list, probe, detail, export, counts); both columns are in the covering indexes.
        /// </summary>
        internal const string TrackedOrRefused = "(r.kind=1 OR r.events_count>0)";

        // The repeated texts of message_rollup (status, direction, servers, events), decoded once per request.
        Dictionary<long, string> _rollupValues;
        string RollupText(object code)
        {
            if (code == null || code is DBNull) return null;
            if (_rollupValues == null)
            {
                var values = new Dictionary<long, string>();
                using (var c = Command("SELECT id,text FROM message_rollup_value;"))
                using (var r = c.ExecuteReader()) while (r.Read()) values[r.GetInt64(0)] = r.GetString(1);
                _rollupValues = values;
            }
            string text;
            if (!_rollupValues.TryGetValue(Long(code), out text)) throw new InvalidDataException("InvalidServeRollup: a message_rollup code is not in message_rollup_value.");
            return text;
        }
        internal static string KindName(object code)
        {
            long kind = Long(code);
            if (kind == Store.MessageKindMessage) return "message";
            if (kind == Store.MessageKindSmtp) return "smtp";
            throw new InvalidDataException("InvalidServeRollup: unknown message_rollup kind.");
        }
        string SourceScan(string table, ServeFilter f)
        {
            if (f.User == null || f.Server != null) return "";
            return WholeSourcePeriod(table, f) ? " NOT INDEXED" : "";
        }
        bool WholeSourcePeriod(string table, ServeFilter f)
        {
            bool whole;
            if (!_wholePeriod.TryGetValue(table, out whole))
            {
                object first, last;
                using (var c = Command("SELECT time_ms FROM " + table + " ORDER BY time_ms LIMIT 1;")) first = c.ExecuteScalar();
                using (var c = Command("SELECT time_ms FROM " + table + " ORDER BY time_ms DESC LIMIT 1;")) last = c.ExecuteScalar();
                whole = first != null && last != null && f.From <= Long(first) && f.To > Long(last);
                _wholePeriod.Add(table, whole);
            }
            // A complete time range cannot benefit from fetching every wide row through the time index.
            return whole;
        }
        internal string MessageWhere(ServeFilter f, bool correlated = true)
        {
            string period = "e.time_ms>=@f AND e.time_ms<@t";
            // BINARY identity is authoritative; schema 7's NULL-hash invariant indexes missing-ID SMTP.
            if (!correlated && ScopedMessages(f))
                return MessageBounds(f) +
                    " AND ((r.kind=0 AND r.identity COLLATE BINARY IN(" +
                    "SELECT e.message_id COLLATE BINARY FROM message_event e" + SourceScan("message_event", f) + " WHERE e.message_id IS NOT NULL AND " + period + SourceFilter(f, "e", false) +
                    " UNION ALL SELECT e.message_id COLLATE BINARY FROM smtp_transaction e" + SourceScan("smtp_transaction", f) + " WHERE e.message_id IS NOT NULL AND " + period + SourceFilter(f, "e", true) +
                    ")) OR (r.kind=1 AND r.identity COLLATE BINARY IN(SELECT CAST(e.id AS TEXT) COLLATE BINARY FROM smtp_transaction e WHERE e.msg_hash IS NULL AND e.message_id IS NULL AND " +
                    period + SourceFilter(f, "e", true) + ")))";
            string exact = "((r.kind=0 AND (EXISTS(SELECT 1 FROM message_event e WHERE e.msg_hash=r.msg_hash AND e.message_id=r.identity COLLATE BINARY AND " +
                period + SourceFilter(f, "e", false) + ") OR EXISTS(SELECT 1 FROM smtp_transaction e WHERE e.msg_hash=r.msg_hash AND e.message_id=r.identity COLLATE BINARY AND " +
                period + SourceFilter(f, "e", true) + "))) OR (r.kind=1 AND EXISTS(SELECT 1 FROM smtp_transaction e WHERE e.id=CAST(r.identity AS INTEGER) AND " +
                period + SourceFilter(f, "e", true) + ")))";
            // Without a server or user filter a journey whose whole member interval lies inside the period has a member in the period: member_first_ms is the
            // time of an existing event or SMTP row (never an end time), and member_first_ms <= member_last_ms. The exact source lookups are then
            // only needed for the journeys that cross a bound of the period.
            if (!ScopedMessages(f))
                exact = "CASE WHEN r.member_first_ms>=@f AND r.member_last_ms<@t THEN 1 ELSE " + exact + " END";
            return MessageBounds(f) + " AND " + exact;
        }
        internal static string SessionWhere(ServeFilter f)
        {
            // start_ms >= from - span is implied by end_ms >= from (ServeSpanMetadata); stated, it starts the range of ix_session_time.
            return "c.start_ms<@t AND c.start_ms>=@sf AND c.end_ms>=@f" + OrderWindow(f, "c.start_ms") +
                (f.User == null ? "" : " AND (c.user LIKE @u ESCAPE '\\' OR c.mailbox LIKE @u ESCAPE '\\')") +
                (f.Server == null ? "" : " AND (instr(','||lower(COALESCE(c.front_ends,''))||',',','||lower(@s)||',')>0 OR instr(','||lower(COALESCE(c.back_ends,''))||',',','||lower(@s)||',')>0)") +
                (f.Status == null ? "" : " AND " + ReportBuilder.SessionOutcomeSql("c") + "=@status COLLATE NOCASE");
        }
        /// <summary>The sort-key window of a list (ServeFilter.OrderFrom/OrderTo), on the column the list is ordered by.</summary>
        internal static string OrderWindow(ServeFilter f, string column)
        {
            return (f.OrderFrom.HasValue ? " AND " + column + ">=@of" : "") + (f.OrderTo.HasValue ? " AND " + column + "<@ot" : "");
        }
        internal static string SmtpWhere(ServeFilter f)
        {
            return "e.time_ms>=@f AND e.time_ms<@t" + OrderWindow(f, "e.time_ms") + SourceFilter(f, "e", true) +
                (f.Status == null ? "" : " AND e.status=@status COLLATE NOCASE");
        }
        internal static readonly string MessageSelect = "SELECT r.id,COALESCE(r.first_ms,r.member_first_ms),COALESCE(r.last_ms,r.member_last_ms),r.status,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,r.direction,r.servers,r.events,r.smtp_count,r.identity,r.kind,r.events_count FROM message_rollup r WHERE ";
        // The session list reads client_session alone (ReportBuilder.SessionSummaryRow): one index range plus the rows of the page. Its Outcome is the
        // SQL outcome of the counters (the last column), the expression the status filter compares with.
        internal static readonly string SessionSelect = "SELECT " + ReportBuilder.SessionFields("c") + "," + ReportBuilder.SessionOutcomeSql("c") + " FROM client_session c WHERE ";
        internal static readonly string SmtpSelect = "SELECT e.id,e.time_ms,e.end_ms,e.server,e.direction,e.role,e.connector,e.remote_ep,e.mail_from,e.rcpt_count,e.rcpts,e.message_id,e.status," + SmtpAuthView.Columns + " FROM smtp_transaction e WHERE ";
        internal static readonly ServeColumn[] MessageColumns = ServeColumn.Parse(ReportBuilder.ServeMessageColumns.Take(16).Concat(new[] { "Kind:text", "Events count:num" }));
        // The columns of the report's sessions dataset but the timeline (its last column), which only the detail carries.
        internal static readonly ServeColumn[] SessionColumns = ServeColumn.Parse(ReportBuilder.SessionColumns.Take(ReportBuilder.SessionColumns.Length - 1));
        internal static readonly ServeColumn[] SmtpColumns = ServeColumn.Parse(new[] { "Time:time","End:time","Server:text","Direction:text","Role:text","Connector:text","Remote:text","Mail from:text","Recipient count:num","Recipients:text","Message ID:text","Status:text","Authentication mechanism:text","Authentication result:text","Last AUTH attempt:text","Authenticated user:text","Identity evidence:text" });
        internal static ServeColumn[] Columns(string view) { return view == "messages" ? MessageColumns : view == "sessions" ? SessionColumns : view == "smtpclients" ? SmtpClientColumns : SmtpColumns; }
        static string MessageIndex(ServeFilter f) { return f.Status == null ? "ix_rollup_last" : "ix_rollup_status_last"; }
        internal static int ProbeRows(ServeFilter f) { return Math.Max(256, 2 * ((f.Page - 1) * f.Size + f.Size + 1)); }
        internal string ProbeSelection(ServeFilter f)
        {
            // LIMIT is materialized before source lookups: rare filters cannot walk every unrelated journey.
            return "WITH candidates AS MATERIALIZED(SELECT * FROM message_rollup r INDEXED BY " + MessageIndex(f) +
                " WHERE " + MessageBounds(f) + Order("messages") + " LIMIT @probe) " +
                MessageSelect.Replace("message_rollup r WHERE", "candidates r WHERE") + MessageWhere(f);
        }
        internal string Selection(string view, ServeFilter f)
        {
            // Unscoped lists use the latest index; scoped sets seek exact identities instead of walking unrelated rows.
            return view == "messages" ? (ScopedMessages(f) ? MessageSelect : MessageSelect.Replace("message_rollup r WHERE",
                "message_rollup r INDEXED BY " + MessageIndex(f) + " WHERE")) + MessageWhere(f, correlated: false) :
                view == "sessions" ? SessionSelect + SessionWhere(f) : SmtpSelect + SmtpWhere(f);
        }
        internal static string Order(string view) { return view == "messages" ? " ORDER BY r.member_last_ms DESC,r.id DESC" : view == "sessions" ? " ORDER BY c.start_ms DESC,c.id DESC" : " ORDER BY e.time_ms DESC,e.id DESC"; }
        internal ServeRow ConvertRow(string view, object[] row)
        {
            if (view == "messages")
            {
                string kind = KindName(row[16]);
                return new ServeRow { id = Long(row[0]), cells = new object[] { Iso(Long(row[1])),Iso(Long(row[2])),
                    TimeUtil.Duration((Long(row[2])-Long(row[1]))/1000.0),RollupText(row[3]),row[4],JsonSerializer.Deserialize<string[]>(Text(row[5])),row[6],row[7],row[8],row[9],row[10],RollupText(row[11]),RollupText(row[12]),RollupText(row[13]),row[14],kind=="message"?row[15]:null,kind,row[17] } };
            }
            if (view == "sessions")
            {
                var session = ReportBuilder.SessionSummaryRow(row, ms => ms > 0 ? Iso(ms) : null);
                session[3] = Text(row[row.Length - 1]);
                return new ServeRow { id = Long(row[0]), cells = session };
            }
            var cells = row.Skip(1).ToArray();
            cells[0] = Iso(Long(cells[0])); cells[1] = cells[1] == null ? cells[0] : Iso(Long(cells[1]));
            if (view == "smtp")
            {
                var auth = SmtpAuthView.Fields(row, 13);
                for (int i = 0; i < auth.Length; i++) cells[12+i] = auth[i];
            }
            return new ServeRow { id = Long(row[0]), cells = cells };
        }
        internal IEnumerable<ServeRow> ReadRows(string view, ServeFilter f, bool all, bool probe = false)
        {
            if (view == "smtpclients")
            {
                foreach (var row in ClientRows(f, all)) yield return row;
                yield break;
            }
            if (view == "messages" && NoMessageStatus(f)) yield break;
            using (var c = FilterCommand((probe ? ProbeSelection(f) : Selection(view, f)) + Order(view) + (all ? ";" : " LIMIT @limit OFFSET @offset;"), f))
            {
                if (!all) { c.Parameters.AddWithValue("@limit", f.Size + 1); c.Parameters.AddWithValue("@offset", (f.Page - 1) * f.Size); }
                if (probe) c.Parameters.AddWithValue("@probe", ProbeRows(f));
                using (var r = c.ExecuteReader()) while (r.Read())
                {
                    _cancel.ThrowIfCancellationRequested();
                    var row = new object[r.FieldCount];
                    for (int n = 0; n < row.Length; n++) row[n] = r.IsDBNull(n) ? null : r.GetValue(n);
                    yield return ConvertRow(view, row);
                }
            }
        }
        internal ServePage Page(string view, ServeFilter f)
        {
            List<ServeRow> rows;
            if (view == "messages" && NoMessageStatus(f)) rows = new List<ServeRow>();
            else if (view == "messages" && ScopedMessages(f))
            {
                rows = ReadRows(view, f, false, probe: true).ToList();
                if (rows.Count <= f.Size)
                {
                    // A bounded count, not a total: a sparse period/status can already be exhausted by the probe.
                    using (var c = FilterCommand("SELECT COUNT(*) FROM(SELECT 1 FROM message_rollup r INDEXED BY " +
                        MessageIndex(f) + " WHERE " + MessageBounds(f) + Order("messages") + " LIMIT @probe);", f))
                    {
                        c.Parameters.AddWithValue("@probe", ProbeRows(f));
                        if (Long(c.ExecuteScalar()) == ProbeRows(f)) rows = ReadRows(view, f, false).ToList();
                    }
                }
            }
            else rows = ReadRows(view, f, false).ToList();
            bool more = rows.Count > f.Size;
            if (more) rows.RemoveAt(rows.Count-1);
            return new ServePage { columns = Columns(view), rows = rows, page = f.Page, size = f.Size, hasMore = more, total = null };
        }
        internal object Message(long id, ServeFilter f)
        {
            string kind = null, identity = null; object hash = DBNull.Value;
            if (NoMessageStatus(f)) throw new ServeError(404, "NotFound", "No message in this selection.");
            using (var c = FilterCommand("SELECT r.kind,r.identity,r.msg_hash FROM message_rollup r WHERE r.id=@id AND " + MessageWhere(f) + ";", f, id))
            using (var r = c.ExecuteReader()) if (r.Read()) { kind = KindName(r.GetValue(0)); identity = r.GetString(1); if (!r.IsDBNull(2)) hash = r.GetInt64(2); }
            if (kind == null) throw new ServeError(404, "NotFound", "No message in this selection.");
            long count;
            var cells = ReportBuilder.ReadServeMessage(sql => {
                var c = Command(sql); c.Parameters.AddWithValue("@m", identity);
                c.Parameters.AddWithValue("@h", hash);
                c.Parameters.AddWithValue("@sid", kind == "smtp" ? long.Parse(identity, CultureInfo.InvariantCulture) : 0L); return c;
            }, kind, identity, true, out count, SourceServers().ToArray(), MailFlowRules.Read(Command));
            cells[0] = Iso(Long(cells[0])); cells[1] = Iso(Long(cells[1]));
            foreach (int slot in new[] { 16,17 })
                foreach (var step in (IEnumerable<object[]>)cells[slot]) step[0] = Iso(Long(step[0]));
            var tracking = kind == "message" ? Evidence(false, identity, hash, null) : new List<object[]>();
            var conversations = Evidence(true, kind == "message" ? identity : null, hash, kind == "smtp" ? (long?)long.Parse(identity,CultureInfo.InvariantCulture) : null);
            cells = cells.Concat(new object[] { tracking, conversations }).ToArray();
            return new { id, title = "Message", columns = ServeColumn.Parse(ReportBuilder.ServeMessageColumns.Concat(new[] {"Tracking evidence:steps","SMTP evidence:steps"})), cells };
        }
        internal object Session(long id, ServeFilter f)
        {
            using (var c = FilterCommand("SELECT c.id FROM client_session c WHERE c.id=@id AND " + SessionWhere(f) + ";", f, id))
                if (c.ExecuteScalar() == null) throw new ServeError(404, "NotFound", "No client session in this selection.");
            return ReportBuilder.ReadServeSession(sql => { var c = Command(sql); c.Parameters.AddWithValue("@id", id); return c; }, id);
        }
        internal object Smtp(long id, ServeFilter f)
        {
            object[] row = null;
            using (var c = FilterCommand(SmtpSelect + "e.id=@id AND " + SmtpWhere(f) + ";", f, id))
            using (var r = c.ExecuteReader()) if (r.Read()) { row = new object[r.FieldCount]; for (int n=0;n<row.Length;n++) row[n]=r.IsDBNull(n)?null:r.GetValue(n); }
            if (row == null) throw new ServeError(404, "NotFound", "No SMTP transaction in this selection.");
            var cells = ConvertRow("smtp", row).cells.ToList();
            using (var c = FilterCommand("SELECT response,transcript FROM smtp_transaction WHERE id=@id;", f, id))
            using (var r = c.ExecuteReader()) if (r.Read()) { cells.Add(r.IsDBNull(0)?null:Text(r.GetValue(0))); cells.Add(r.IsDBNull(1)?null:SmtpAuth.RedactTranscript(Text(r.GetValue(1)))); }
            cells.Add(Evidence(true,null,DBNull.Value,id));
            return new { id, title = "SMTP conversation", columns = SmtpColumns.Concat(ServeColumn.Parse(new[]{"Response:text","Transcript:text","Stored evidence:steps"})).ToArray(), cells = cells.ToArray() };
        }
        List<object[]> Evidence(bool smtp, string identity, object hash, long? smtpId)
        {
            string projection = smtp ? "id,time_ms,end_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,internal_id,status,response,auth_user,auth_mechanism,auth_result,auth_attempt_result,auth_source,auth_fragment_id,auth_sequence,auth_evidence_id" : "*";
            string where = smtpId.HasValue ? "id=@sid" : "msg_hash=@h AND message_id=@m COLLATE BINARY";
            var rows = new List<object[]>();
            using (var c = Command("SELECT " + projection + " FROM " + (smtp ? "smtp_transaction" : "message_event") + " WHERE " + where + " ORDER BY time_ms,id;"))
            {
                c.Parameters.AddWithValue("@h",hash); c.Parameters.AddWithValue("@m",(object)identity??DBNull.Value);
                c.Parameters.AddWithValue("@sid",smtpId.HasValue?(object)smtpId.Value:DBNull.Value);
                using (var r = c.ExecuteReader()) while(r.Read())
                {
                    _cancel.ThrowIfCancellationRequested();
                    var fields = new Dictionary<string,object>(StringComparer.Ordinal);
                    for(int n=0;n<r.FieldCount;n++)
                    {
                        object value=r.IsDBNull(n)?null:r.GetValue(n);
                        fields[r.GetName(n)] = value is byte[] ? Text(value) : value;
                    }
                    rows.Add(new object[] { Iso(Long(fields["time_ms"])), fields["server"], smtp?"SMTP evidence":"Tracking evidence",
                        fields[smtp?"status":"event_id"], JsonSerializer.Serialize(fields) });
                }
            }
            return rows;
        }
        /// <summary>
        /// The access path of the message counts (no server or user filter): the range [from, to + span) of the covering ix_rollup_last (or of the status
        /// index), read from the index entries; only journeys crossing a bound of the period look up their source rows. Fixed explicitly: left alone, the
        /// planner chose to walk the whole status index for the GROUP BY. Scoped counts seek exact identities (no hint).
        /// </summary>
        string CountsIndex(ServeFilter f) { return ScopedMessages(f) ? "" : " INDEXED BY " + MessageIndex(f); }
        internal object OverviewCounts(ServeFilter f)
        {
            var rows = new List<ServeRow>(); long id = 0;
            var statuses = new List<KeyValuePair<string, long>>();
            if (!NoMessageStatus(f))
                using (var c = FilterCommand("SELECT r.status,COUNT(*) FROM message_rollup r" + CountsIndex(f) + " WHERE " + MessageWhere(f, correlated: false) + " GROUP BY r.status;", f))
                using (var r = c.ExecuteReader()) while(r.Read()) statuses.Add(new KeyValuePair<string, long>(RollupText(r.GetValue(0)), r.GetInt64(1)));
            // Groups are decoded, then sorted by their text (ordinal), the order the text column gave before the status became a code.
            foreach (var s in statuses.OrderBy(x => x.Key, StringComparer.Ordinal)) rows.Add(new ServeRow { id=++id, cells=new object[]{"Messages",s.Key,s.Value} });
            using (var c = FilterCommand("SELECT COUNT(*),COALESCE(SUM(c.requests),0) FROM client_session c WHERE " + SessionWhere(f) + ";", f))
            using (var r = c.ExecuteReader()) if(r.Read()) { rows.Add(new ServeRow { id=++id,cells=new object[]{"Client sessions","Retained sessions",r.GetInt64(0)} }); rows.Add(new ServeRow { id=++id,cells=new object[]{"Client sessions","Retained requests",r.GetInt64(1)} }); }
            using (var c = FilterCommand("SELECT e.status,COUNT(*) FROM smtp_transaction e WHERE " + SmtpWhere(f) + " GROUP BY e.status;", f))
            using (var r = c.ExecuteReader()) while(r.Read()) rows.Add(new ServeRow { id=++id,cells=new object[]{"SMTP transactions",r.IsDBNull(0)?"Unknown":r.GetString(0),r.GetInt64(1)} });
            return new { columns=ServeColumn.Parse(new[]{"Source:text","Status:text","Count:num"}),rows,
                from=Iso(f.From),to=Iso(f.To),basis="Retained event membership and client sessions; not daily access_usage totals. Usage HTML remains unchanged." };
        }
        public void Dispose()
        {
            _interrupt.Dispose();
            if (_lastSuccessCommand != null) _lastSuccessCommand.Dispose();
            SQLitePCL.raw.sqlite3_progress_handler(_db.Handle, 0, null, null);
            if (_tx != null) _tx.Dispose();
            _db.Dispose();
            lock (_remoteHosts) _remoteHosts.Clear();
        }
    }

    public static partial class ReportBuilder
    {
        internal static object ReadServeSession(Func<string, SqliteCommand> command, long id)
        {
            var input = new SessionInput();
            input.Row = ServeRows(command, "SELECT " + SessionFields("c") + " FROM client_session c WHERE c.id=@id;").Single();
            input.Steps = new List<Step>();
            foreach (var row in ServeRows(command, "SELECT data FROM session_step WHERE session_id=@id ORDER BY time_ms,rowid;")) ParseSteps(S(row[0]), input.Steps);
            var files = new Dictionary<long,string[]>();
            var ids = input.Steps.SelectMany(s=>s.Links).Select(x=>L(x[1])).Where(x=>x>0).Distinct().ToArray();
            for(int i=0;i<ids.Length;i+=500)
                foreach(var row in ServeRows(command, "SELECT id,server,kind,path FROM source_file WHERE id IN ("+string.Join(",",ids.Skip(i).Take(500).Select(x=>x.ToString(CultureInfo.InvariantCulture)))+");"))
                    files[L(row[0])] = new[]{ S(row[1]),S(row[2]),S(row[3]) };
            var cells = SessionRow(input,new ReportRequest { IncludeSessionDetails=true },t=>t,files,true);
            cells[0]=ServeRead.Iso(L(input.Row[1])); cells[1]=ServeRead.Iso(L(input.Row[2]));
            foreach(var step in (IEnumerable<object[]>)cells[SessionColumns.Length - 1]) step[0]=ServeRead.Iso(L(step[0]));
            var counts = ServeRows(command,"SELECT actions,statuses FROM client_session WHERE id=@id;").Single();
            cells=cells.Concat(new object[]{S(counts[0]),S(counts[1])}).ToArray();
            return new { id,title="Client session",columns=ServeColumn.Parse(SessionColumns.Concat(new[]{"All operations:text","Status counts:text"})),cells };
        }
    }
}
