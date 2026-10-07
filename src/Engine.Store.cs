// =============================================================================
//  Exchange Log Report - engine, part 2: SQLite store
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  Tables (all times in Unix ms, UTC)
//    run              one row per execution
//    source_file      read position of every log file (server, kind, file_key) -> offset; file_key is the
//                     identity of the file whatever the path used to reach it (see FileKey)
//    noise            lines set aside per execution, server, kind and reason
//    access_usage     client access, one row per day x server x user x protocol (aggregate)
//    access_action    client access, one row per day x server x protocol x action (latency per operation)
//    access_client    client access, one row per day x user x protocol x address x client (devices, versions)
//    client_session   one row per client session: user, protocol, client and address of one day, cut by inactivity
//    session_step     timeline of a session: one row per session and log file read (JSON steps)
//    access_event     client access requests kept individually: failures, slow requests (and watched users)
//    iis_status       IIS sub-status / Win32 status of failed proxied requests (by request id)
//    smtp_transaction one row per SMTP mail transaction (MAIL FROM ... end of data)
//    message_event    message tracking events of real messages
//  Raw log lines are never stored: only the normalised fields above.
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>Read position and counters of one log file.</summary>
    public sealed class FileState
    {
        public long Id;
        public string Server, Kind, Path, Fields;
        public long Offset, Size, LastWriteMs, FirstMs, LastMs, Lines, Kept, Noise;

        /// <summary>Copy of a known state for the path used now (its stored path is kept in the database).</summary>
        public FileState CopyFor(string path)
        {
            var c = (FileState)MemberwiseClone();
            c.Path = path;
            return c;
        }
    }

    /// <summary>Generic query result handed to PowerShell (status views).</summary>
    public sealed class TableResult
    {
        public string[] Columns = new string[0];
        public List<object[]> Rows = new List<object[]>();
    }

    public sealed class PurgeResult
    {
        public long Usage, Events, IisStatus, Smtp, Transcripts, Messages, Runs, Files, Sessions, Actions, Clients;
        public double DeleteSeconds, VacuumSeconds, OptimizeSeconds;
        public long Total { get { return Usage + Events + IisStatus + Smtp + Messages + Sessions + Actions + Clients; } }
    }

    public sealed class Store : IDisposable
    {
        public const string SchemaVersion = "5";
        /// <summary>SQLite page cache of a collection, in KB (set before opening the store; 256 MB by default).</summary>
        public static int CacheKilobytes = 262144;
        /// <summary>Page size of a NEW database (an existing one keeps its own). 16 KB: fewer and larger writes, on a
        /// hard disk the copy of the WAL into the database took 2.6 times less time than with 4 KB pages (lab, 2.0.0).</summary>
        public static int PageSize = 16384;
        readonly SqliteConnection _db;
        public string FilePath { get; private set; }
        public bool ReadOnly { get; private set; }

        public Store(string path, bool readOnly, string toolVersion)
        {
            FilePath = Path.GetFullPath(path);
            ReadOnly = readOnly;
            if (!readOnly) Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = FilePath,
                Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
                Cache = SqliteCacheMode.Private,
                Pooling = false
            };
            _db = new SqliteConnection(builder.ToString());
            _db.Open();
            Exec("PRAGMA busy_timeout=30000;");
            if (readOnly)
            {
                // A database of an older version (report without collection after an update): upgrade it
                // once (new tables and columns only), then go on read-only.
                if (StoredSchemaVersion() < int.Parse(SchemaVersion, System.Globalization.CultureInfo.InvariantCulture))
                {
                    _db.Dispose();
                    using (new Store(FilePath, false, toolVersion)) { }
                    _db = new SqliteConnection(builder.ToString());
                    _db.Open();
                    Exec("PRAGMA busy_timeout=30000;");
                }
                // A report reads index pages again and again (messages by id, steps by session) and sorts large sets:
                // the same page cache as a collection, and its sorts in memory instead of temporary files.
                Exec("PRAGMA cache_size=-" + CacheKilobytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
                Exec("PRAGMA temp_store=MEMORY;");
                return;
            }
            // auto_vacuum and page_size must be chosen before the first table is created (new database only).
            Exec("PRAGMA page_size=" + PageSize.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
            Exec("PRAGMA auto_vacuum=INCREMENTAL;");
            Exec("PRAGMA journal_mode=WAL;");
            Exec("PRAGMA synchronous=NORMAL;");
            Exec("PRAGMA temp_store=MEMORY;");
            // A collection writes large batches: a large page cache keeps the indexes in memory (the default 2 MB cache
            // made every row of a large database wait for the disk), and the WAL is copied to the database every 64 MB
            // instead of every 4 MB (fewer checkpoints, each one flushed to the disk).
            Exec("PRAGMA cache_size=-" + CacheKilobytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
            Exec("PRAGMA wal_autocheckpoint=16384;");
            Exec(Schema);
            Migrate();
            Exec("INSERT INTO metadata(key,value) VALUES('schema_version','" + SchemaVersion + "') ON CONFLICT(key) DO UPDATE SET value=excluded.value;");
            using (var c = Command("INSERT INTO metadata(key,value) VALUES('tool_version',@v) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"))
            {
                c.Parameters.AddWithValue("@v", toolVersion ?? "");
                c.ExecuteNonQuery();
            }
        }

        const string Schema = @"
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS run(
  id INTEGER PRIMARY KEY, mode TEXT, started_ms INTEGER, ended_ms INTEGER, status TEXT, host TEXT, account TEXT, version TEXT,
  files INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0, lines INTEGER NOT NULL DEFAULT 0,
  kept INTEGER NOT NULL DEFAULT 0, noise INTEGER NOT NULL DEFAULT 0, error TEXT);
CREATE TABLE IF NOT EXISTS source_file(
  id INTEGER PRIMARY KEY, server TEXT NOT NULL, kind TEXT NOT NULL, path TEXT NOT NULL,
  offset INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0, last_write_ms INTEGER, fields TEXT,
  first_ms INTEGER, last_ms INTEGER, lines INTEGER NOT NULL DEFAULT 0, kept INTEGER NOT NULL DEFAULT 0,
  noise INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER, file_key TEXT, UNIQUE(server, kind, path));
CREATE TABLE IF NOT EXISTS noise(
  run_id INTEGER NOT NULL, server TEXT NOT NULL, kind TEXT NOT NULL, reason TEXT NOT NULL, lines INTEGER NOT NULL,
  PRIMARY KEY(run_id, server, kind, reason)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS access_usage(
  day TEXT NOT NULL, server TEXT NOT NULL, user TEXT NOT NULL, protocol TEXT NOT NULL, mailbox TEXT,
  requests INTEGER NOT NULL, successes INTEGER NOT NULL, client_errors INTEGER NOT NULL, server_errors INTEGER NOT NULL,
  bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL, total_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL,
  first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, last_success_ms INTEGER NOT NULL, last_failure_ms INTEGER NOT NULL,
  client_ip TEXT, user_agent TEXT,
  PRIMARY KEY(day, server, user, protocol)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_usage_user ON access_usage(user, day);
CREATE TABLE IF NOT EXISTS access_event(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, server TEXT NOT NULL, source TEXT NOT NULL, protocol TEXT,
  user TEXT, mailbox TEXT, client_ip TEXT, user_agent TEXT, method TEXT, url TEXT, action TEXT,
  status INTEGER, sub_status INTEGER, win32 INTEGER, backend_status INTEGER, error_code TEXT, target_server TEXT,
  auth_type TEXT, routing TEXT, bytes_in INTEGER, bytes_out INTEGER, duration_ms INTEGER, outcome TEXT NOT NULL,
  request_id TEXT, recovered_ms INTEGER, errors TEXT, UNIQUE(server, source, request_id));
CREATE INDEX IF NOT EXISTS ix_event_time ON access_event(time_ms);
CREATE INDEX IF NOT EXISTS ix_event_user ON access_event(user, time_ms);
CREATE TABLE IF NOT EXISTS iis_status(
  server TEXT NOT NULL, request_id TEXT NOT NULL, time_ms INTEGER NOT NULL, status INTEGER, sub_status INTEGER,
  win32 INTEGER, time_taken INTEGER, PRIMARY KEY(server, request_id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS smtp_transaction(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, end_ms INTEGER, server TEXT NOT NULL, direction TEXT NOT NULL,
  role TEXT, connector TEXT, session_id TEXT NOT NULL, local_ep TEXT, remote_ep TEXT, helo TEXT, tls TEXT, auth TEXT,
  mail_from TEXT, rcpt_count INTEGER, rcpts TEXT, message_id TEXT, internal_id TEXT, status TEXT, response TEXT, transcript TEXT,
  UNIQUE(server, direction, session_id, time_ms));
-- 2.0.0: covering index of the SMTP aggregates of the reports (replaces ix_smtp_time).
CREATE INDEX IF NOT EXISTS ix_smtp_flow ON smtp_transaction(time_ms, server, direction, status);
CREATE INDEX IF NOT EXISTS ix_smtp_message ON smtp_transaction(message_id);
CREATE TABLE IF NOT EXISTS message_event(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, server TEXT NOT NULL, event_id TEXT, source TEXT,
  message_id TEXT, internal_id TEXT, network_id TEXT, sender TEXT, recipients TEXT, recipient_status TEXT,
  recipient_count INTEGER, total_bytes INTEGER, subject TEXT, client_ip TEXT, client_host TEXT, server_ip TEXT,
  server_host TEXT, connector TEXT, source_context TEXT, related_recipient TEXT, reference TEXT,
  directionality TEXT, message_info TEXT, return_path TEXT, log_id TEXT, UNIQUE(server, log_id));
-- 2.0.0: covering index of the mail flow aggregates of the reports (replaces ix_msg_time).
CREATE INDEX IF NOT EXISTS ix_msg_flow ON message_event(time_ms, server, event_id, message_id, internal_id);
CREATE INDEX IF NOT EXISTS ix_msg_id ON message_event(message_id);
CREATE TABLE IF NOT EXISTS access_action(
  day TEXT NOT NULL, server TEXT NOT NULL, protocol TEXT NOT NULL, action TEXT NOT NULL,
  requests INTEGER NOT NULL, failures INTEGER NOT NULL, slow INTEGER NOT NULL, total_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL,
  PRIMARY KEY(day, server, protocol, action)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS access_client(
  day TEXT NOT NULL, user TEXT NOT NULL, protocol TEXT NOT NULL, client_ip TEXT NOT NULL, user_agent TEXT NOT NULL, device_id TEXT NOT NULL,
  device_type TEXT, software TEXT, requests INTEGER NOT NULL, failures INTEGER NOT NULL,
  first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, servers TEXT,
  PRIMARY KEY(day, user, protocol, client_ip, user_agent, device_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_client_user ON access_client(user, day);
CREATE TABLE IF NOT EXISTS client_session(
  id INTEGER PRIMARY KEY, skey TEXT NOT NULL, day TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  user TEXT NOT NULL, protocol TEXT NOT NULL, mailbox TEXT, client_ip TEXT, user_agent TEXT, device_id TEXT, device_type TEXT,
  software TEXT, client_mode TEXT, front_ends TEXT, back_ends TEXT,
  requests INTEGER NOT NULL, successes INTEGER NOT NULL, failures INTEGER NOT NULL, slow INTEGER NOT NULL,
  first_success_ms INTEGER NOT NULL, last_success_ms INTEGER NOT NULL, first_failure_ms INTEGER NOT NULL, last_failure_ms INTEGER NOT NULL,
  total_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL, bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL,
  actions TEXT, statuses TEXT, first_error TEXT, last_error TEXT, backend TEXT, connections INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER);
CREATE INDEX IF NOT EXISTS ix_session_key ON client_session(skey);
CREATE INDEX IF NOT EXISTS ix_session_time ON client_session(start_ms);
CREATE INDEX IF NOT EXISTS ix_session_user ON client_session(user, start_ms);
CREATE TABLE IF NOT EXISTS session_step(session_id INTEGER NOT NULL, time_ms INTEGER NOT NULL, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS ix_step_session ON session_step(session_id, time_ms);
";

        /// <summary>Schema version written in the database (0 when unknown).</summary>
        int StoredSchemaVersion()
        {
            try
            {
                using (var c = Command("SELECT value FROM metadata WHERE key='schema_version';"))
                {
                    int v;
                    return int.TryParse(Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture), out v) ? v : 0;
                }
            }
            catch (SqliteException) { return 0; }
        }

        /// <summary>Upgrades a database created by an older version: new columns only, the data is kept.</summary>
        void Migrate()
        {
            // 2.0.0: ix_msg_flow and ix_smtp_flow (Schema) replace the indexes on the time of the tracking events and of
            // the SMTP transactions.
            Exec("DROP INDEX IF EXISTS ix_msg_time;");
            Exec("DROP INDEX IF EXISTS ix_smtp_time;");
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("PRAGMA table_info(access_usage);"))
            using (var r = c.ExecuteReader()) while (r.Read()) columns.Add(r.GetString(1));
            if (!columns.Contains("slow")) Exec("ALTER TABLE access_usage ADD COLUMN slow INTEGER NOT NULL DEFAULT 0;");

            // 1.5.1: identity of a log file (file_key). Files read before are keyed from their path; when the same
            // file was read through two paths (administrative share, then local path), the row read last keeps
            // the key and the others are left without key: never matched again, removed by the retention.
            columns.Clear();
            using (var c = Command("PRAGMA table_info(source_file);"))
            using (var r = c.ExecuteReader()) while (r.Read()) columns.Add(r.GetString(1));
            if (!columns.Contains("file_key"))
            {
                Exec("ALTER TABLE source_file ADD COLUMN file_key TEXT;");
                var rows = new List<object[]>();
                using (var c = Command("SELECT id, server, kind, path FROM source_file ORDER BY COALESCE(updated_ms, 0) DESC, id DESC;"))
                using (var r = c.ExecuteReader()) while (r.Read()) rows.Add(new object[] { r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3) });
                var seen = new HashSet<string>(StringComparer.Ordinal);
                using (var tx = Begin())
                using (var c = Command("UPDATE source_file SET file_key=@k WHERE id=@id;", tx))
                {
                    var key = c.Parameters.Add("@k", SqliteType.Text);
                    var id = c.Parameters.Add("@id", SqliteType.Integer);
                    foreach (var row in rows)
                    {
                        string k = FileKey((string)row[1], (string)row[3]);
                        if (!seen.Add((string)row[1] + "|" + (string)row[2] + "|" + k)) continue;
                        key.Value = k; id.Value = row[0];
                        c.ExecuteNonQuery();
                    }
                    tx.Commit();
                }
            }
            Exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_source_file_key ON source_file(server, kind, file_key);");
        }

        static readonly System.Text.RegularExpressions.Regex AdminShareRx =
            new System.Text.RegularExpressions.Regex(@"^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$", System.Text.RegularExpressions.RegexOptions.Compiled);

        /// <summary>
        /// Identity of a log file whatever the path used to reach it: a path through the administrative share of
        /// its own server (\\EXCH01\D$\Logs\x.log) is the local path on that server (D:\Logs\x.log), and the case
        /// is ignored (Windows paths). The collector reads a file through its share until -Mode Discover writes
        /// its local path, and Exchange may return a folder in another case: the file is not read twice.
        /// </summary>
        public static string FileKey(string server, string path)
        {
            if (string.IsNullOrEmpty(path)) return path;
            string p = path.Trim();
            var m = AdminShareRx.Match(p);
            if (m.Success && string.Equals(m.Groups[1].Value.Split('.')[0], (server ?? "").Split('.')[0], StringComparison.OrdinalIgnoreCase))
                p = m.Groups[2].Value + ":" + (m.Groups[3].Success && m.Groups[3].Length > 0 ? m.Groups[3].Value : "\\");
            return p.ToUpperInvariant();
        }

        internal SqliteConnection Connection { get { return _db; } }

        public SqliteTransaction Begin() { return _db.BeginTransaction(); }

        internal SqliteCommand Command(string sql, SqliteTransaction tx = null)
        {
            var c = _db.CreateCommand();
            c.CommandText = sql;
            c.Transaction = tx;
            c.CommandTimeout = 0;
            return c;
        }

        internal SqliteCommand Command(string sql, IDictionary<string, object> parameters, SqliteTransaction tx = null)
        {
            var c = Command(sql, tx);
            if (parameters != null) foreach (var p in parameters) c.Parameters.AddWithValue(p.Key, p.Value ?? DBNull.Value);
            return c;
        }

        public void Exec(string sql)
        {
            using (var c = Command(sql)) c.ExecuteNonQuery();
        }

        public long Scalar(string sql, Hashtable parameters)
        {
            using (var c = Command(sql, ToDictionary(parameters)))
            {
                object v = c.ExecuteScalar();
                return v == null || v is DBNull ? 0 : Convert.ToInt64(v);
            }
        }

        /// <summary>Runs a query and returns all rows (used by PowerShell for the status views).</summary>
        public TableResult Query(string sql, Hashtable parameters)
        {
            var result = new TableResult();
            using (var c = Command(sql, ToDictionary(parameters)))
            using (var r = c.ExecuteReader())
            {
                result.Columns = new string[r.FieldCount];
                for (int i = 0; i < r.FieldCount; i++) result.Columns[i] = r.GetName(i);
                while (r.Read())
                {
                    var row = new object[r.FieldCount];
                    for (int i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : Packed.Unpack(r.GetValue(i));
                    result.Rows.Add(row);
                }
            }
            return result;
        }

        static Dictionary<string, object> ToDictionary(Hashtable h)
        {
            var d = new Dictionary<string, object>();
            if (h != null) foreach (DictionaryEntry e in h) d["@" + e.Key.ToString().TrimStart('@')] = e.Value;
            return d;
        }

        // ---------------------------------------------------------------- executions

        public long StartRun(string mode, string host, string account, string version)
        {
            using (var c = Command("INSERT INTO run(mode,started_ms,status,host,account,version) VALUES(@m,@s,'Running',@h,@a,@v) RETURNING id;"))
            {
                c.Parameters.AddWithValue("@m", mode);
                c.Parameters.AddWithValue("@s", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                c.Parameters.AddWithValue("@h", (object)host ?? DBNull.Value);
                c.Parameters.AddWithValue("@a", (object)account ?? DBNull.Value);
                c.Parameters.AddWithValue("@v", (object)version ?? DBNull.Value);
                return Convert.ToInt64(c.ExecuteScalar());
            }
        }

        public void EndRun(long runId, string status, long files, long bytes, long lines, long kept, long noise, string error)
        {
            using (var c = Command("UPDATE run SET ended_ms=@e,status=@st,files=@f,bytes=@b,lines=@l,kept=@k,noise=@n,error=@err WHERE id=@id;"))
            {
                c.Parameters.AddWithValue("@e", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                c.Parameters.AddWithValue("@st", status);
                c.Parameters.AddWithValue("@f", files); c.Parameters.AddWithValue("@b", bytes); c.Parameters.AddWithValue("@l", lines);
                c.Parameters.AddWithValue("@k", kept); c.Parameters.AddWithValue("@n", noise);
                c.Parameters.AddWithValue("@err", (object)error ?? DBNull.Value);
                c.Parameters.AddWithValue("@id", runId);
                c.ExecuteNonQuery();
            }
        }

        /// <summary>Executions left "Running" by an interrupted process are closed as "Interrupted".</summary>
        public long CloseAbandonedRuns()
        {
            using (var c = Command("UPDATE run SET status='Interrupted', ended_ms=COALESCE(ended_ms,started_ms) WHERE status='Running';"))
                return c.ExecuteNonQuery();
        }

        // ---------------------------------------------------------------- files

        /// <summary>
        /// Read position of every known file, keyed "server|kind|FileKey" (the collection plan skips the files read to
        /// their end). A file whose position is before its end (an SMTP, IMAP or POP session still open when it was
        /// read) is read again even if it did not grow: once the file is idle, the held session is written.
        /// </summary>
        public Dictionary<string, FileState> KnownFiles()
        {
            var d = new Dictionary<string, FileState>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("SELECT id,server,kind,path,file_key,offset,size,last_write_ms,fields,first_ms,last_ms,lines,kept,noise FROM source_file WHERE file_key IS NOT NULL;"))
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    var f = new FileState
                    {
                        Id = r.GetInt64(0), Server = r.GetString(1), Kind = r.GetString(2), Path = r.GetString(3),
                        Offset = r.GetInt64(5), Size = r.GetInt64(6), LastWriteMs = r.IsDBNull(7) ? 0 : r.GetInt64(7),
                        Fields = r.IsDBNull(8) ? null : r.GetString(8), FirstMs = r.IsDBNull(9) ? 0 : r.GetInt64(9),
                        LastMs = r.IsDBNull(10) ? 0 : r.GetInt64(10), Lines = r.GetInt64(11), Kept = r.GetInt64(12), Noise = r.GetInt64(13)
                    };
                    d[f.Server + "|" + f.Kind + "|" + r.GetString(4)] = f;
                }
            return d;
        }

        /// <summary>
        /// Id of the source_file row of a file (created if needed): timeline steps keep it to tell which log
        /// file holds the raw line of a request. The path of a new row is the one used to read it.
        /// </summary>
        public long FileId(FileState f, SqliteTransaction tx)
        {
            if (f.Id > 0) return f.Id;
            using (var c = Command(@"INSERT INTO source_file(server,kind,path,file_key,offset,size,updated_ms) VALUES(@s,@k,@p,@fk,@o,@z,@u) ON CONFLICT DO NOTHING;
UPDATE source_file SET file_key=@fk WHERE server=@s AND kind=@k AND path=@p AND file_key IS NULL
  AND NOT EXISTS (SELECT 1 FROM source_file WHERE server=@s AND kind=@k AND file_key=@fk);
SELECT id FROM source_file WHERE server=@s AND kind=@k AND file_key=@fk;", tx))
            {
                c.Parameters.AddWithValue("@s", f.Server); c.Parameters.AddWithValue("@k", f.Kind); c.Parameters.AddWithValue("@p", f.Path);
                c.Parameters.AddWithValue("@fk", FileKey(f.Server, f.Path));
                c.Parameters.AddWithValue("@o", f.Offset); c.Parameters.AddWithValue("@z", f.Size);
                c.Parameters.AddWithValue("@u", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                f.Id = Convert.ToInt64(c.ExecuteScalar());
                return f.Id;
            }
        }

        /// <summary>Saves the read position of a file (row found by FileId; its stored path is kept).</summary>
        public void SaveFile(FileState f, SqliteTransaction tx)
        {
            FileId(f, tx);
            using (var c = Command(@"UPDATE source_file SET offset=@o,size=@z,last_write_ms=@w,fields=@f,first_ms=@fm,last_ms=@lm,lines=@l,kept=@kp,noise=@n,updated_ms=@u WHERE id=@id;", tx))
            {
                c.Parameters.AddWithValue("@id", f.Id);
                c.Parameters.AddWithValue("@o", f.Offset); c.Parameters.AddWithValue("@z", f.Size); c.Parameters.AddWithValue("@w", f.LastWriteMs);
                c.Parameters.AddWithValue("@f", (object)f.Fields ?? DBNull.Value);
                c.Parameters.AddWithValue("@fm", f.FirstMs > 0 ? (object)f.FirstMs : DBNull.Value);
                c.Parameters.AddWithValue("@lm", f.LastMs > 0 ? (object)f.LastMs : DBNull.Value);
                c.Parameters.AddWithValue("@l", f.Lines); c.Parameters.AddWithValue("@kp", f.Kept); c.Parameters.AddWithValue("@n", f.Noise);
                c.Parameters.AddWithValue("@u", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                c.ExecuteNonQuery();
            }
        }

        public void AddNoise(long runId, string server, string kind, Dictionary<string, long> reasons, SqliteTransaction tx)
        {
            if (reasons == null || reasons.Count == 0) return;
            using (var c = Command(@"INSERT INTO noise(run_id,server,kind,reason,lines) VALUES(@r,@s,@k,@why,@n)
ON CONFLICT(run_id,server,kind,reason) DO UPDATE SET lines=lines+excluded.lines;", tx))
            {
                var pr = c.Parameters.Add("@r", SqliteType.Integer); var ps = c.Parameters.Add("@s", SqliteType.Text);
                var pk = c.Parameters.Add("@k", SqliteType.Text); var pw = c.Parameters.Add("@why", SqliteType.Text);
                var pn = c.Parameters.Add("@n", SqliteType.Integer);
                foreach (var kv in reasons)
                {
                    pr.Value = runId; ps.Value = server; pk.Value = kind; pw.Value = kv.Key; pn.Value = kv.Value;
                    c.ExecuteNonQuery();
                }
            }
        }

        // ---------------------------------------------------------------- retention

        /// <summary>
        /// Deletes what is older than the retention. Aggregates, SMTP transactions and message tracking
        /// follow RetentionDays; request-level failures and SMTP transcripts follow DetailRetentionDays.
        /// </summary>
        public PurgeResult Purge(long retentionCutoffMs, string retentionCutoffDay, long detailCutoffMs)
        {
            var p = new PurgeResult();
            var clock = System.Diagnostics.Stopwatch.StartNew();
            using (var tx = Begin())
            {
                p.Usage = Delete("DELETE FROM access_usage WHERE day < @d;", "@d", retentionCutoffDay, tx);
                p.Actions = Delete("DELETE FROM access_action WHERE day < @d;", "@d", retentionCutoffDay, tx);
                p.Clients = Delete("DELETE FROM access_client WHERE day < @d;", "@d", retentionCutoffDay, tx);
                // start_ms <= end_ms: the index on start_ms finds the old sessions without reading all of them.
                Delete("DELETE FROM session_step WHERE session_id IN (SELECT id FROM client_session WHERE start_ms < @t AND end_ms < @t);", "@t", detailCutoffMs, tx);
                p.Sessions = Delete("DELETE FROM client_session WHERE start_ms < @t AND end_ms < @t;", "@t", detailCutoffMs, tx);
                p.Events = Delete("DELETE FROM access_event WHERE time_ms < @t;", "@t", detailCutoffMs, tx);
                p.IisStatus = Delete("DELETE FROM iis_status WHERE time_ms < @t;", "@t", detailCutoffMs, tx);
                p.Transcripts = Delete("UPDATE smtp_transaction SET transcript=NULL WHERE transcript IS NOT NULL AND time_ms < @t;", "@t", detailCutoffMs, tx);
                p.Smtp = Delete("DELETE FROM smtp_transaction WHERE time_ms < @t;", "@t", retentionCutoffMs, tx);
                p.Messages = Delete("DELETE FROM message_event WHERE time_ms < @t;", "@t", retentionCutoffMs, tx);
                p.Runs = Delete("DELETE FROM noise WHERE run_id IN (SELECT id FROM run WHERE started_ms < @t);", "@t", retentionCutoffMs, tx);
                p.Runs = Delete("DELETE FROM run WHERE started_ms < @t;", "@t", retentionCutoffMs, tx);
                // Positions of files that Exchange deleted long ago are no longer needed.
                p.Files = Delete("DELETE FROM source_file WHERE COALESCE(last_write_ms,0) < @t;", "@t", retentionCutoffMs, tx);
                tx.Commit();
            }
            p.DeleteSeconds = clock.Elapsed.TotalSeconds;
            Exec("PRAGMA incremental_vacuum;");
            p.VacuumSeconds = clock.Elapsed.TotalSeconds - p.DeleteSeconds;
            // ANALYZE of the tables that need it, on a sample: a full analysis of a large database reads all of it.
            Exec("PRAGMA analysis_limit=1000;");
            Exec("PRAGMA optimize;");
            p.OptimizeSeconds = clock.Elapsed.TotalSeconds - p.DeleteSeconds - p.VacuumSeconds;
            return p;
        }

        long Delete(string sql, string name, object value, SqliteTransaction tx)
        {
            using (var c = Command(sql, tx)) { c.Parameters.AddWithValue(name, value); return c.ExecuteNonQuery(); }
        }

        /// <summary>Writes the WAL into the database file (smaller files to copy, consistent backups).</summary>
        public void Checkpoint()
        {
            if (ReadOnly) return;
            Exec("PRAGMA wal_checkpoint(TRUNCATE);");
            // A collection copies the WAL itself (Collector.Checkpoints): automatic copies again afterwards.
            Exec("PRAGMA wal_autocheckpoint=16384;");
        }

        /// <summary>Size of the WAL file (written but not yet copied into the database).</summary>
        public long WalBytes { get { var f = new FileInfo(FilePath + "-wal"); return f.Exists ? f.Length : 0; } }

        public long FileBytes
        {
            get
            {
                long total = 0;
                foreach (var suffix in new[] { "", "-wal", "-shm" })
                {
                    var f = new FileInfo(FilePath + suffix);
                    if (f.Exists) total += f.Length;
                }
                return total;
            }
        }

        public void Dispose() { _db.Dispose(); }
    }
}
