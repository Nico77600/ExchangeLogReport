// =============================================================================
//  Exchange Log Report - engine, part 2: SQLite store
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.4.0
//
//  Tables (all times in Unix ms, UTC)
//    run              one row per execution
//    source_file      read position of every log file (server, kind, path) -> offset
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
        public long Total { get { return Usage + Events + IisStatus + Smtp + Messages + Sessions + Actions + Clients; } }
    }

    public sealed class Store : IDisposable
    {
        public const string SchemaVersion = "2";
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
                if (StoredSchemaVersion() >= int.Parse(SchemaVersion, System.Globalization.CultureInfo.InvariantCulture)) return;
                _db.Dispose();
                using (new Store(FilePath, false, toolVersion)) { }
                _db = new SqliteConnection(builder.ToString());
                _db.Open();
                Exec("PRAGMA busy_timeout=30000;");
                return;
            }
            // auto_vacuum must be chosen before the first table is created (new database only).
            Exec("PRAGMA auto_vacuum=INCREMENTAL;");
            Exec("PRAGMA journal_mode=WAL;");
            Exec("PRAGMA synchronous=NORMAL;");
            Exec("PRAGMA temp_store=MEMORY;");
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
  noise INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER, UNIQUE(server, kind, path));
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
CREATE INDEX IF NOT EXISTS ix_smtp_time ON smtp_transaction(time_ms);
CREATE INDEX IF NOT EXISTS ix_smtp_message ON smtp_transaction(message_id);
CREATE TABLE IF NOT EXISTS message_event(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, server TEXT NOT NULL, event_id TEXT, source TEXT,
  message_id TEXT, internal_id TEXT, network_id TEXT, sender TEXT, recipients TEXT, recipient_status TEXT,
  recipient_count INTEGER, total_bytes INTEGER, subject TEXT, client_ip TEXT, client_host TEXT, server_ip TEXT,
  server_host TEXT, connector TEXT, source_context TEXT, related_recipient TEXT, reference TEXT,
  directionality TEXT, message_info TEXT, return_path TEXT, log_id TEXT, UNIQUE(server, log_id));
CREATE INDEX IF NOT EXISTS ix_msg_time ON message_event(time_ms);
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
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("PRAGMA table_info(access_usage);"))
            using (var r = c.ExecuteReader()) while (r.Read()) columns.Add(r.GetString(1));
            if (!columns.Contains("slow")) Exec("ALTER TABLE access_usage ADD COLUMN slow INTEGER NOT NULL DEFAULT 0;");
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
                    for (int i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
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

        public FileState GetFile(string server, string kind, string path)
        {
            using (var c = Command("SELECT id,offset,size,last_write_ms,fields,first_ms,last_ms,lines,kept,noise FROM source_file WHERE server=@s AND kind=@k AND path=@p;"))
            {
                c.Parameters.AddWithValue("@s", server); c.Parameters.AddWithValue("@k", kind); c.Parameters.AddWithValue("@p", path);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read()) return null;
                    return new FileState
                    {
                        Id = r.GetInt64(0), Server = server, Kind = kind, Path = path,
                        Offset = r.GetInt64(1), Size = r.GetInt64(2), LastWriteMs = r.IsDBNull(3) ? 0 : r.GetInt64(3),
                        Fields = r.IsDBNull(4) ? null : r.GetString(4), FirstMs = r.IsDBNull(5) ? 0 : r.GetInt64(5),
                        LastMs = r.IsDBNull(6) ? 0 : r.GetInt64(6), Lines = r.GetInt64(7), Kept = r.GetInt64(8), Noise = r.GetInt64(9)
                    };
                }
            }
        }

        /// <summary>
        /// Read position of all known files of a server (lets PowerShell skip unchanged files quickly). A file
        /// whose position is before its end (an SMTP, IMAP or POP session still open when it was read) is
        /// read again even if it did not grow: once the file is idle, the held session is written.
        /// </summary>
        public Dictionary<string, long> KnownOffsets(string server)
        {
            var d = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("SELECT kind, path, offset FROM source_file WHERE server=@s;"))
            {
                c.Parameters.AddWithValue("@s", server);
                using (var r = c.ExecuteReader()) while (r.Read()) d[r.GetString(0) + "|" + r.GetString(1)] = r.GetInt64(2);
            }
            return d;
        }

        /// <summary>
        /// Id of the source_file row of a file (created if needed): timeline steps keep it to tell which log
        /// file holds the raw line of a request.
        /// </summary>
        public long FileId(FileState f, SqliteTransaction tx)
        {
            if (f.Id > 0) return f.Id;
            using (var c = Command(@"INSERT INTO source_file(server,kind,path,offset,size,updated_ms) VALUES(@s,@k,@p,@o,@z,@u) ON CONFLICT(server,kind,path) DO NOTHING;
SELECT id FROM source_file WHERE server=@s AND kind=@k AND path=@p;", tx))
            {
                c.Parameters.AddWithValue("@s", f.Server); c.Parameters.AddWithValue("@k", f.Kind); c.Parameters.AddWithValue("@p", f.Path);
                c.Parameters.AddWithValue("@o", f.Offset); c.Parameters.AddWithValue("@z", f.Size);
                c.Parameters.AddWithValue("@u", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                f.Id = Convert.ToInt64(c.ExecuteScalar());
                return f.Id;
            }
        }

        public void SaveFile(FileState f, SqliteTransaction tx)
        {
            using (var c = Command(@"INSERT INTO source_file(server,kind,path,offset,size,last_write_ms,fields,first_ms,last_ms,lines,kept,noise,updated_ms)
VALUES(@s,@k,@p,@o,@z,@w,@f,@fm,@lm,@l,@kp,@n,@u)
ON CONFLICT(server,kind,path) DO UPDATE SET offset=excluded.offset,size=excluded.size,last_write_ms=excluded.last_write_ms,
fields=excluded.fields,first_ms=excluded.first_ms,last_ms=excluded.last_ms,lines=excluded.lines,kept=excluded.kept,noise=excluded.noise,updated_ms=excluded.updated_ms;", tx))
            {
                c.Parameters.AddWithValue("@s", f.Server); c.Parameters.AddWithValue("@k", f.Kind); c.Parameters.AddWithValue("@p", f.Path);
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
            using (var tx = Begin())
            {
                p.Usage = Delete("DELETE FROM access_usage WHERE day < @d;", "@d", retentionCutoffDay, tx);
                p.Actions = Delete("DELETE FROM access_action WHERE day < @d;", "@d", retentionCutoffDay, tx);
                p.Clients = Delete("DELETE FROM access_client WHERE day < @d;", "@d", retentionCutoffDay, tx);
                Delete("DELETE FROM session_step WHERE session_id IN (SELECT id FROM client_session WHERE end_ms < @t);", "@t", detailCutoffMs, tx);
                p.Sessions = Delete("DELETE FROM client_session WHERE end_ms < @t;", "@t", detailCutoffMs, tx);
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
            Exec("PRAGMA incremental_vacuum;");
            Exec("PRAGMA optimize;");
            return p;
        }

        long Delete(string sql, string name, object value, SqliteTransaction tx)
        {
            using (var c = Command(sql, tx)) { c.Parameters.AddWithValue(name, value); return c.ExecuteNonQuery(); }
        }

        /// <summary>Writes the WAL into the database file (smaller files to copy, consistent backups).</summary>
        public void Checkpoint() { if (!ReadOnly) Exec("PRAGMA wal_checkpoint(TRUNCATE);"); }

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
