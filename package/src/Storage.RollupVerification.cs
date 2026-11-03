#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Globalization;
using System.Text;
using System.Text.Json;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport.Storage;

internal static class StorageRollupVerification
{
    public static readonly string[] Tables = ["message_rollup", "message_rollup_dirty"];
    // Exact canonical derived objects of each supported shape: schemas 8, 9, 10, 11 and 12 (delivered earlier, verified as is with the recipient rules they
    // were written with) and the current schema 13.
    private static readonly Dictionary<int, Dictionary<string, string?>> Shapes = new() { [8] = ExpectedObjects(8), [9] = ExpectedObjects(9), [10] = ExpectedObjects(10), [11] = ExpectedObjects(11), [12] = ExpectedObjects(12), [13] = ExpectedObjects(13) };
    // A schema-12 database written before the covering indexes and the span bounds: accepted as a copy SOURCE only (the copy migrates it with
    // --migrate, or keeps that shape); a staged migrated copy must have the final shape.
    private static readonly Dictionary<string, string?> PreRelease12 = ExpectedObjects(12, preRelease: true);
    // A schema-12 database written with the covering indexes and the span bounds, but rollup indexes without events_count and kind: a copy SOURCE
    // only, as PreRelease12.
    private static readonly Dictionary<string, string?> Covering12 = ExpectedObjects(12, covering12: true);
    // A schema-12 database written with rollup indexes that end with events_count and kind, but without direction and servers, the mail flow per hour
    // and the indexes ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success: a copy SOURCE only, as PreRelease12.
    private static readonly Dictionary<string, string?> Tracked12 = ExpectedObjects(12, tracked12: true);
    // Names introduced by schemas 8 to 13, whichever shape: a schema 6/7 source must not already own any of them. ix_session_time exists since the
    // first schema (client_session is not a derived table); only its definition changed with schema 12.
    private static readonly HashSet<string> ReservedNames = new(Shapes[8].Keys.Concat(Shapes[9].Keys).Concat(Shapes[10].Keys).Concat(Shapes[11].Keys).Concat(Shapes[12].Keys).Concat(Shapes[13].Keys)
        .Where(name => name != "ix_session_time"), StringComparer.Ordinal);
    // Schema 9 dropped these; a schema-9 or -10 database must not carry them (schema 8 and 7 databases legitimately do and are not inspected for them).
    private static readonly string[] ObsoleteIndexes = ["ix_msg_hash", "ix_smtp_hash", "ix_session_latest"];
    // Schema 11 dropped ix_smtp_latest too (ix_smtp_flow starts with time_ms).
    private static readonly string[] ObsoleteIndexes11 = ["ix_msg_hash", "ix_smtp_hash", "ix_session_latest", "ix_smtp_latest"];
    // Schema 11: the dictionary of message_rollup and the SMTP client structures. They are added by the migration (not derived rollup tables of the source).
    public const string RollupValueTable = "message_rollup_value";
    public static readonly string[] SmtpClientTables = ["smtp_client_value", "smtp_client", "smtp_client_hour", "smtp_client_pending", "smtp_client_dirty"];
    // Every table whose objects a schema-11 database must not carry in any other shape.
    private static readonly string[] DerivedTables11 = ["message_rollup", "message_rollup_dirty", RollupValueTable, "smtp_client_value", "smtp_client", "smtp_client_hour", "smtp_client_pending", "smtp_client_dirty",
        "mail_flow_hour", "mail_flow_dirty"];
    // Schema 12: the mail flow per hour (derived from the tracking events and the SMTP transactions), added by the migration or the shape upgrade.
    public static readonly string[] MailFlowTables = ["mail_flow_hour", "mail_flow_dirty"];
    // Schema 10: the '#Fields' text dictionary of source_file (a table that is added by the migration, not a derived rollup table).
    public const string SourceFieldsTable = "source_fields";
    // The per-identity statements are prepared once per verification pass and bound again for every identity (as the engine's
    // Store.CachedVerificationReads). The environment variable, read once per process, set to 1 selects a new command per statement
    // instead: the reference path the storage tests compare with (same statements, parameters, values and failures).
    internal const string UncachedReadsVariable = "EXCHANGELOGREPORT_STORAGE_VERIFICATION_UNCACHED";
    internal static bool CachedReads = Environment.GetEnvironmentVariable(UncachedReadsVariable) != "1";
    // The message identities are verified by the engine's merge scan (each source table and the rollup read once, in identity order). The environment
    // variable, read once per process, set to 1 selects the per-identity point reads instead: the reference path the storage tests compare with.
    internal const string PointReadsVariable = "EXCHANGELOGREPORT_STORAGE_VERIFICATION_POINT";
    internal static bool PointReads = Environment.GetEnvironmentVariable(PointReadsVariable) == "1";
    public static string Method => PointReads ? "per-identity" : "merge-scan";

    // The sort files of the merge scan go to the folder of the verified database (process-wide sqlite3_temp_directory, reset after the pass), which
    // must have 15 % of the file free (at least 1 GB); a copy destination already has three times the source free. The setting is process-wide and
    // must not change while another connection of the process has temporary files open: the storage passes run one after the other, alone in the process.
    private static string SortDirectory(SqliteConnection db, int version)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(db.DataSource))!;
        long bytes;
        using (var size = db.CreateCommand())
        {
            size.CommandText = "SELECT (SELECT page_count FROM pragma_page_count())*(SELECT page_size FROM pragma_page_size());";
            bytes = Convert.ToInt64(size.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
        long needed = Math.Max(Store.MinSortSpaceBytes, (long)Math.Ceiling(bytes * Store.SortSpaceShare));
        long free = -1;
        try { free = new DriveInfo(Path.GetPathRoot(directory)!).AvailableFreeSpace; } catch (ArgumentException) { } catch (IOException) { }
        if (free >= 0 && free < needed)
            throw new StorageFailure("Schema-" + version + " derived rollup verification needs about 15 % of the database size free next to the database for its sort files (" +
                (needed / 1e9).ToString("N1", CultureInfo.InvariantCulture) + " GB needed, " + (free / 1e9).ToString("N1", CultureInfo.InvariantCulture) + " GB free in " + directory + "); no destination was published.");
        using var pragma = db.CreateCommand();
        pragma.CommandText = "PRAGMA temp_store_directory='" + directory.Replace("'", "''") + "';";
        pragma.ExecuteNonQuery();
        return directory;
    }

    private static string ServeIndex(string name) => Store.ServeRollupIndexes.Single(index => index[0] == name)[2];

    private static Dictionary<string, string?> ExpectedObjects(int version, bool preRelease = false, bool covering12 = false, bool tracked12 = false)
    {
        bool covering = version >= 12 && !preRelease;
        var result = new Dictionary<string, string?>(StringComparer.Ordinal) {
            ["message_rollup"] = version >= 11 ? Store.ServeRollupTableSql : """
CREATE TABLE message_rollup(
 id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, identity TEXT COLLATE BINARY NOT NULL,
 msg_hash INTEGER, first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL,
 member_first_ms INTEGER NOT NULL, member_last_ms INTEGER NOT NULL, status TEXT NOT NULL,
 sender TEXT, recipients TEXT NOT NULL, recipient_count INTEGER NOT NULL, delivered INTEGER NOT NULL,
 failed INTEGER NOT NULL, subject TEXT, size_kb INTEGER, direction TEXT, servers TEXT, events TEXT,
 events_count INTEGER NOT NULL, smtp_count INTEGER NOT NULL, UNIQUE(kind,identity))
""",
            ["sqlite_autoindex_message_rollup_1"] = null,
            ["message_rollup_dirty"] = """
CREATE TABLE message_rollup_dirty(kind TEXT NOT NULL,identity TEXT COLLATE BINARY NOT NULL,msg_hash INTEGER,
 PRIMARY KEY(kind,identity)) WITHOUT ROWID
""",
            // Schema 12: the covering indexes (definitions shared with the engine that creates them).
            ["ix_rollup_last"] = covering12 ? Store.ServeRollupIndexesCovering12[0][2] : tracked12 ? Store.ServeRollupIndexesTracked12[0][2] : covering ? ServeIndex("ix_rollup_last") :
                version == 8 ? "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms DESC,id DESC)" : "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms)",
            ["ix_rollup_status_last"] = covering12 ? Store.ServeRollupIndexesCovering12[1][2] : tracked12 ? Store.ServeRollupIndexesTracked12[1][2] : covering ? ServeIndex("ix_rollup_status_last") :
                version == 8 ? "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms DESC,id DESC)" :
                version >= 11 ? "CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms)" : "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms)",
            // Schemas 8 and 9 carry the wide exact-identity indexes; schema 10 keeps the hash and the time only (the exact BINARY compare is on the row).
            ["ix_msg_identity_time"] = version < 10 ? "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,message_id COLLATE BINARY,time_ms,id)" : "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)",
            ["ix_smtp_identity_time"] = version < 10 ? "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,message_id COLLATE BINARY,time_ms,id)" : "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)"
        };
        if (version < 11) result["ix_smtp_latest"] = version == 8 ? "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms DESC,id DESC)" : "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms)";
        if (version == 8) result["ix_session_latest"] = "CREATE INDEX ix_session_latest ON client_session(start_ms DESC,id DESC)";
        if (version >= 12)
        {
            // client_session is not a derived table: its index and triggers are checked by name and exact definition (a schema-12 database written
            // before the covering index still has the start_ms-only index and no span triggers).
            result["ix_session_time"] = covering ? ServeIndex("ix_session_time") : Store.SessionTimeIndex11;
            if (covering) foreach (var trigger in Store.ServeSpanTriggers) result[trigger[0]] = trigger[2];
            // The current shape: the mail flow per hour (tables and triggers) and the indexes of the overview and of the unresolved failures.
            if (covering && !covering12 && !tracked12)
            {
                foreach (var name in new[] { "ix_msg_noid_flow", "ix_event_resolution", "ix_usage_day_success" }) result[name] = ServeIndex(name);
                foreach (var table in Store.MailFlowTables) result[table[0]] = table[1];
                foreach (var trigger in Store.MailFlowTriggers) result[trigger[0]] = trigger[2];
            }
        }
        if (version >= 10)
        {
            result[SourceFieldsTable] = "CREATE TABLE source_fields(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)";
            result["sqlite_autoindex_source_fields_1"] = null;
        }
        if (version >= 11)
        {
            // Schema 11: the rollup dictionary and the SMTP client structures (definitions shared with the engine that creates them).
            result[RollupValueTable] = Store.ServeRollupValueTableSql;
            result["sqlite_autoindex_message_rollup_value_1"] = null;
            foreach (var table in Store.SmtpClientTables) result[table[0]] = table[1];
            result["sqlite_autoindex_smtp_client_value_1"] = null;
            foreach (var index in Store.SmtpClientIndexes) result[index[0]] = index[2];
            foreach (var trigger in Store.SmtpClientTriggers) result[trigger[0]] = trigger[1];
        }
        foreach (string table in new[] { "message_event", "smtp_transaction" })
        foreach (string operation in new[] { "INSERT", "UPDATE", "DELETE" })
        {
            string name = "tr_" + table + "_rollup_" + operation.ToLowerInvariant();
            // Schemas 12 and 13: the engine's definitions (the UPDATE trigger of message_event also watches recipient_status and related_recipient
            // since 12, and connector, server_ip and server_host since 13). Schemas 8 to 11 keep the literal definitions below: the shape a database of that schema has.
            if (version >= 12) { result[name] = Store.ServeRollupTriggerSql(table, operation, version); continue; }
            string body = "";
            foreach (string row in operation == "UPDATE" ? new[] { "OLD", "NEW" } : new[] { operation == "DELETE" ? "OLD" : "NEW" })
            {
                body += "INSERT INTO message_rollup_dirty SELECT 'message'," + row + ".message_id,exl_msg_hash(" + row + ".message_id) WHERE " + row + ".message_id IS NOT NULL ON CONFLICT(kind,identity) DO UPDATE SET msg_hash=excluded.msg_hash;";
                if (table == "smtp_transaction")
                    body += "INSERT OR IGNORE INTO message_rollup_dirty SELECT 'smtp',CAST(" + row + ".id AS TEXT),NULL WHERE " + row + ".message_id IS NULL;";
            }
            // Schemas 9 to 11 list only the columns the rollup is derived from; schema 8 listed every source column.
            string update = operation == "UPDATE" ? (table == "message_event"
                ? (version == 8 ? " OF id,message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference"
                    : " OF id,message_id,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality")
                : (version == 8 ? " OF id,message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,status,auth_user"
                    : " OF id,message_id,time_ms,end_ms,server,direction,mail_from,rcpts,status")) : "";
            result[name] = "CREATE TRIGGER " + name + " AFTER " + operation + update + " ON " + table + " BEGIN " + body + " END";
        }
        return result;
    }

    // Ignore formatting only outside quoted SQL tokens; literal values remain exact.
    private static string Canonical(string sql)
    {
        var text = new StringBuilder();
        char quote = '\0';
        for (int i = 0; i < sql.Length; i++)
        {
            char c = sql[i];
            if (quote != '\0')
            {
                text.Append(c);
                if (c == quote)
                {
                    if (i + 1 < sql.Length && sql[i + 1] == quote) text.Append(sql[++i]);
                    else quote = '\0';
                }
            }
            else if (c is '\'' or '"' or '`' or '[')
            {
                quote = c == '[' ? ']' : c;
                text.Append(c);
            }
            else if (!char.IsWhiteSpace(c)) text.Append(c);
        }
        return text.ToString().TrimEnd(';');
    }

    private static StorageFailure Failure(int version = 13) => new("Schema-" + version + " derived rollup verification failed; no destination was published.");

    public static void CheckSource(SqliteConnection db, int version)
    {
        if (version is >= 8 and <= 13) { Verify(db, version, preRelease: version == 12 && !(HasShape12(db) && HasAuthShape(db))); return; }
        using var command = db.CreateCommand();
        command.CommandText = "SELECT name,tbl_name FROM sqlite_schema;";
        using (var reader = command.ExecuteReader())
        {
            int objects = 0;
            while (reader.Read())
            {
                if (++objects > 10000) throw Failure(version);
                if (ReservedNames.Contains(reader.GetString(0)) || Tables.Contains(reader.GetString(1), StringComparer.Ordinal))
                    throw new StorageFailure("A legacy schema already contains reserved schema-8 derived objects; refusing ambiguous migration.");
            }
        }
        command.CommandText = "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='sqlite_sequence';";
        if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
        {
            command.CommandText = "SELECT count(*) FROM sqlite_sequence WHERE name='message_rollup';";
            if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
        }
    }

    /// <param name="version">The exact derived-object shape and recipient rules to require: 8, 9, 10 or 11 (delivered schema sources, rows recomputed
    /// with the rules they were written with), 12 (rows recomputed by the engine without the external status) or 13 (the current schema, rows
    /// recomputed by the engine with the stored rules of the external status).</param>
    /// <summary>
    /// True when a schema-12 database has the covering indexes and both span-bound metadata rows (one query); false for a schema-12 database written
    /// before them. The rest of the shape is checked by Verify.
    /// </summary>
    public static bool HasShape12(SqliteConnection db)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT (SELECT count(*) FROM sqlite_schema WHERE type='index' AND (name,sql) IN (VALUES('ix_rollup_last',@a),('ix_rollup_status_last',@b),('ix_session_time',@c)))" +
            "+(SELECT count(*) FROM metadata WHERE key IN('rollup_max_span_ms','session_max_span_ms'));";
        command.Parameters.AddWithValue("@a", ServeIndex("ix_rollup_last"));
        command.Parameters.AddWithValue("@b", ServeIndex("ix_rollup_status_last"));
        command.Parameters.AddWithValue("@c", ServeIndex("ix_session_time"));
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) == 5;
    }

    /// <summary>
    /// True when the database has the authentication columns of the current shape: access_client.auth_type as its seventh key column and
    /// client_session.auth_modes (the table columns, never the stored CREATE TABLE text).
    /// </summary>
    public static bool HasAuthShape(SqliteConnection db)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT (SELECT count(*) FROM pragma_table_info('access_client') WHERE pk>0)=7 AND " +
            "(SELECT count(*) FROM pragma_table_info('access_client') WHERE name='auth_type' AND pk=7)=1 AND " +
            "(SELECT count(*) FROM pragma_table_info('client_session') WHERE name='auth_modes')=1;";
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) == 1;
    }

    /// <summary>
    /// True when a schema-12 database has every object of the current shape but the authentication columns (Step3_12: written by an earlier 3.0 build
    /// before them). Accepted as a copy SOURCE only, as PreRelease12; its derived objects are verified as those of the current shape.
    /// </summary>
    public static bool IsStep3_12(SqliteConnection db) => HasShape12(db) && !HasAuthShape(db);

    /// <summary>True when a schema-12 database has the ix_rollup_last of Tracked12 (events_count and kind, without direction and servers).</summary>
    public static bool IsTracked12(SqliteConnection db)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT sql FROM sqlite_schema WHERE type='index' AND name='ix_rollup_last';";
        return command.ExecuteScalar() is string sql && Canonical(sql) == Canonical(Store.ServeRollupIndexesTracked12[0][2]);
    }

    /// <summary>True when a schema-12 database has the covering ix_rollup_last without events_count and kind (the shape of Covering12).</summary>
    public static bool IsCovering12(SqliteConnection db)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT sql FROM sqlite_schema WHERE type='index' AND name='ix_rollup_last';";
        return command.ExecuteScalar() is string sql && Canonical(sql) == Canonical(Store.ServeRollupIndexesCovering12[0][2]);
    }

    /// <param name="preRelease">Schema 12 only: accept the shape of a schema-12 database written before the covering indexes and the span bounds
    /// (a copy source; the span-bound checks are then skipped) or with covering rollup indexes without events_count and kind (Covering12). The rows of
    /// such a database give a sent SMTP-only transaction the status 'Not completed (SMTP)' (ReportBuilder.SmtpOnlyStatus). A Step3_12 database
    /// (IsStep3_12) is verified as the current shape without the authentication columns.</param>
    public static void Verify(SqliteConnection db, int version = 13, bool preRelease = false)
    {
        if (preRelease && version != 12) throw new ArgumentOutOfRangeException(nameof(preRelease));
        bool step3 = preRelease && IsStep3_12(db);
        if (step3) preRelease = false;
        // The current shape has the authentication columns (the same wording as the engine's VerifyServeSchema).
        if (version >= 12 && !preRelease && !step3 && !HasAuthShape(db))
            throw new StorageFailure("InvalidServeSchema: access_client.auth_type is missing or is not the seventh key column, or client_session.auth_modes is missing; no destination was published.");
        bool covering12 = preRelease && IsCovering12(db);
        bool tracked12 = preRelease && !covering12 && IsTracked12(db);
        var Objects = covering12 ? Covering12 : tracked12 ? Tracked12 : preRelease ? PreRelease12 : Shapes[version];
        bool spans = version >= 12 && (!preRelease || covering12 || tracked12);
        // The rows of a Tracked12 database already name a sent SMTP-only transaction 'Sent (SMTP)'.
        bool sentStatus = !preRelease || tracked12;
        try
        {
            if (StorageSafety.Metadata(db, "schema_version") != version.ToString(CultureInfo.InvariantCulture) ||
                StorageSafety.Metadata(db, "message_hash_algorithm") != "fnv1a64-utf8-v1") throw Failure(version);
            var found = new HashSet<string>(StringComparer.Ordinal);
            using (var command = db.CreateCommand())
            {
                command.CommandText = "SELECT name,tbl_name,sql FROM sqlite_schema;";
                using var reader = command.ExecuteReader();
                int objects = 0;
                while (reader.Read())
                {
                    if (++objects > 10000) throw Failure(version);
                    string name = reader.GetString(0);
                    if (version >= 9 && (version >= 11 ? ObsoleteIndexes11 : ObsoleteIndexes).Contains(name)) throw Failure(version);
                    if (!Objects.TryGetValue(name, out string? expected))
                    {
                        if ((version >= 11 ? DerivedTables11 : Tables).Contains(reader.GetString(1), StringComparer.Ordinal)) throw Failure(version);
                        continue;
                    }
                    string? sql = reader.IsDBNull(2) ? null : reader.GetString(2);
                    if (expected is null ? sql is not null : sql is null || Canonical(expected) != Canonical(sql)) throw Failure(version);
                    found.Add(name);
                }
            }
            if (found.Count != Objects.Count) throw Failure(version);
            if (version >= 10)
            {
                // The dictionary side of source_file: the column exists and no row points at a missing header text.
                using var columns = db.CreateCommand();
                columns.CommandText = "SELECT count(*) FROM pragma_table_info('source_file') WHERE name='fields_id';";
                if (Convert.ToInt64(columns.ExecuteScalar(), CultureInfo.InvariantCulture) != 1) throw Failure(version);
                columns.CommandText = "SELECT count(*) FROM source_file s WHERE s.fields_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM source_fields d WHERE d.id=s.fields_id);";
                if (Convert.ToInt64(columns.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
            }
            if (version >= 11)
            {
                using var column = db.CreateCommand();
                column.CommandText = "SELECT count(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id' AND type='INTEGER';";
                if (Convert.ToInt64(column.ExecuteScalar(), CultureInfo.InvariantCulture) != 1) throw Failure(version);
            }
            db.CreateFunction<string, long?>("exl_msg_hash", Store.MessageHash, isDeterministic: true);
            db.CreateFunction<string, string>("exl_remote_host", Identity.RemoteHost, isDeterministic: true);
            // The merge scan sorts the projection of the source tables: a larger cache merges fewer runs, and the sort files go next to the database.
            using (var limits = db.CreateCommand())
            {
                limits.CommandText = "PRAGMA temp_store=FILE; PRAGMA cache_size=-" + (PointReads ? "8192" : "65536") + ";";
                limits.ExecuteNonQuery();
            }
            string? sortDirectory = PointReads ? null : SortDirectory(db, version);
            using var tx = db.BeginTransaction(deferred: true);
            SqliteCommand Command(string sql)
            {
                var command = db.CreateCommand();
                command.Transaction = tx;
                command.CommandTimeout = 0;
                command.CommandText = sql;
                return command;
            }
            try
            {
            using (var dirty = Command("SELECT count(*) FROM message_rollup_dirty;"))
                if (Convert.ToInt64(dirty.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
            if (spans)
            {
                // Schema 12: each span bound is one non-negative integer text, not lower than the span of any stored row (covering index scans).
                foreach (var (key, span) in new[] { ("rollup_max_span_ms", Store.RollupSpanSql), ("session_max_span_ms", Store.SessionSpanSql) })
                using (var bound = Command("SELECT (SELECT count(*) FROM metadata WHERE key=@k),(SELECT count(*) FROM metadata WHERE key=@k AND typeof(value)='text' AND value=CAST(CAST(value AS INTEGER) AS TEXT) AND CAST(value AS INTEGER)>=0)," +
                    "(SELECT CAST(value AS INTEGER) FROM metadata WHERE key=@k),(" + span + ");"))
                {
                    bound.Parameters.AddWithValue("@k", key);
                    using var state = bound.ExecuteReader();
                    if (!state.Read() || state.GetInt64(0) != 1 || state.GetInt64(1) != 1 || state.GetInt64(2) < state.GetInt64(3)) throw Failure(version);
                }
            }
            using (var sequence = Command("SELECT count(*),coalesce(min(seq),0),count(*) FILTER(WHERE typeof(name)<>'text' OR typeof(seq)<>'integer'),(SELECT coalesce(max(id),0) FROM message_rollup) FROM sqlite_sequence WHERE name='message_rollup';"))
            using (var state = sequence.ExecuteReader())
            {
                if (!state.Read()) throw Failure(version);
                long count = state.GetInt64(0), maximumId = state.GetInt64(3);
                if (count > 1 || state.GetInt64(2) != 0 ||
                    (count == 0 ? maximumId > 0 : state.GetInt64(1) < maximumId)) throw Failure(version);
            }
            // Schemas 11 and 12 store codes: the row is read back through the dictionary (a missing code reads as NULL and fails the comparison; the dangling-code
            // check below covers the nullable columns) and first_ms/last_ms must be NULL exactly when they equal the member bounds.
            string storedColumns = version >= 11
                ? "SELECT r.id,r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count FROM message_rollup r LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events"
                : "SELECT id,kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count FROM message_rollup r";
            // The stored values a row must have (kind .. smtp_count) from its summary row, event count and SMTP time bounds; the comparison with columns 1..20.
            object?[] Expected(string kind, string identity, object hash, object?[] row, long events, long? smtpFirst, long? smtpLast)
            {
                long rowFirst = Convert.ToInt64(row[0], CultureInfo.InvariantCulture), rowLast = Convert.ToInt64(row[1], CultureInfo.InvariantCulture);
                long first = rowFirst, last = rowLast;
                if (smtpFirst.HasValue) { first = Math.Min(first, smtpFirst.Value); last = Math.Max(last, smtpLast!.Value); }
                return version >= 11
                    ? [kind == "smtp" ? 1L : 0L, identity, hash, rowFirst == first ? null : rowFirst, rowLast == last ? null : rowLast, first, last, row[3], row[4],
                        JsonSerializer.Serialize(row[5]), row[6], row[7], row[8], row[9], row[10], row[11],
                        row[12], row[13], events, row[14]]
                    : [kind, identity, hash, row[0], row[1], first, last, row[3], row[4],
                        JsonSerializer.Serialize(row[5]), row[6], row[7], row[8], row[9], row[10], row[11],
                        row[12], row[13], events, row[14]];
            }
            void Compare(object?[] expected, SqliteDataReader actual)
            {
                if (actual.GetInt64(0) <= 0) throw Failure(version);
                for (int i = 0; i < expected.Length; i++)
                {
                    object value = actual.GetValue(i + 1);
                    object wanted = expected[i] ?? DBNull.Value;
                    if (wanted is int integer) wanted = (long)integer;
                    if (!Equals(value, wanted)) throw Failure(version);
                }
            }
            // The per-identity statements of the engine's verification (@h, @m, @sid bound to the current identity). Cached: one command per statement
            // text for the whole pass, prepared at its first execution and bound again for every identity; otherwise a new command per statement.
            using var reads = new Store.VerificationReads(sql => Command(sql), CachedReads);
            // Schema 13: the rules of the external status the rows were written with (metadata); schema 12: no external status.
            MailFlowRules mailFlow = version >= 13 ? MailFlowRules.Read(sql => Command(sql)) : MailFlowRules.Off;
            // Per identity: a key stream against the stored rows in the same order, each key recomputed through point reads (the reference path; the
            // SMTP rows without Message-ID in both modes).
            void VerifyKeys(string keysSql, string storedSql)
            {
                using var keys = Command(keysSql);
                using var stored = Command(storedSql);
                using var raw = keys.ExecuteReader();
                using var actual = stored.ExecuteReader();
                while (raw.Read())
                {
                    string kind = raw.GetString(0), identity = raw.GetString(1);
                    object hash = raw.GetValue(2);
                    if (!actual.Read()) throw Failure(version);
                    reads.Identity(kind, identity, hash);
                    // Schema 12 and 13 rows are recomputed by the engine; schema 8 to 11 rows by the recipient rules they were written with. Both return the
                    // MIN/MAX(time_ms) of the SMTP rows the row counts (same WHERE as the SMTP count), which widen the member bounds.
                    long events;
                    long? smtpFirst, smtpLast;
                    var row = version >= 12
                        ? ReportBuilder.ReadServeRollupBounds(reads.Command, kind, identity, reads.Reuse, out events, out smtpFirst, out smtpLast, sentStatus: sentStatus, rules: mailFlow)
                        : StorageLegacyRollup.Read(reads.Command, kind, identity, reads.Reuse, out events, out smtpFirst, out smtpLast);
                    if (row is null) throw Failure(version);
                    Compare(Expected(kind, identity, hash, row, events, smtpFirst, smtpLast), actual);
                }
                if (actual.Read()) throw Failure(version);
            }
            const string SmtpKeys = "SELECT 'smtp',CAST(id AS TEXT),NULL FROM smtp_transaction WHERE message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted')";
            string smtpKind = version >= 11 ? "1" : "'smtp'", messageKind = version >= 11 ? "0" : "'message'";
            if (PointReads)
            {
                foreach (string table in new[] { "message_event", "smtp_transaction" })
                using (var hashes = Command("SELECT count(*) FROM " + table + " WHERE msg_hash IS NOT exl_msg_hash(message_id);"))
                    if (Convert.ToInt64(hashes.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
                VerifyKeys("""
SELECT 'message' AS kind,message_id COLLATE BINARY AS identity,msg_hash FROM message_event WHERE message_id IS NOT NULL
UNION SELECT 'message',message_id COLLATE BINARY,msg_hash FROM smtp_transaction WHERE message_id IS NOT NULL
UNION 
""" + SmtpKeys + " ORDER BY kind COLLATE BINARY,identity COLLATE BINARY;",
                    storedColumns + " ORDER BY " + (version >= 11 ? "r.kind" : "kind COLLATE BINARY") + ",identity COLLATE BINARY;");
            }
            else
            {
                // The message identities by the engine's merge scan (every source row's hash is checked on the way); the rules plug is the engine's for
                // schemas 12 and 13 and the frozen schema 8-11 rules otherwise. The stored rows of kind message are walked through UNIQUE(kind,identity).
                ReportBuilder.RollupRules rules = version >= 12 ? new ReportBuilder.EngineRollupRules { SentSmtpStatus = sentStatus, MailFlow = mailFlow } : new StorageLegacyRollup.LegacyRules();
                var scan = new Store.RollupMergeScan(sql => Command(sql), rules, (failure, table) => Failure(version), () => { });
                using (var stored = Command(storedColumns + " WHERE r.kind=" + messageKind + " ORDER BY r.identity COLLATE BINARY;"))
                using (var actual = stored.ExecuteReader())
                    scan.Run(actual, (identity, row) => Compare(Expected("message", identity.Name, identity.Hash, identity.Row, identity.EventCount, identity.SmtpFirst, identity.SmtpLast), row));
                VerifyKeys(SmtpKeys + " ORDER BY 2 COLLATE BINARY;", storedColumns + " WHERE r.kind=" + smtpKind + " ORDER BY r.identity COLLATE BINARY;");
            }
            if (version >= 11)
            {
                using var dangling = Command("SELECT 1 FROM message_rollup r WHERE NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.status)" +
                    " OR (r.direction IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.direction))" +
                    " OR (r.servers IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.servers))" +
                    " OR (r.events IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.events)) LIMIT 1;");
                if (dangling.ExecuteScalar() is not null) throw Failure(version);
                // The SMTP client structures equal a full recomputation from the transactions (same proof as VerifyServeRollups).
                Store.VerifySmtpClientsCore(sql => Command(sql), null);
            }
            // Schema 12: the mail flow per hour equals a full recomputation from the tracking events and the SMTP transactions (same proof as VerifyServeRollups).
            if (version >= 12 && !preRelease) Store.VerifyMailFlowCore(sql => Command(sql), null);
            }
            finally
            {
                if (sortDirectory is not null) using (var reset = Command("PRAGMA temp_store_directory='';")) reset.ExecuteNonQuery();
            }
        }
        catch (Exception error) when (error is SqliteException or InvalidOperationException or InvalidDataException or FormatException or OverflowException)
        {
            throw Failure(version);
        }
    }

    public static void VerifyAddedSequence(SqliteConnection db, bool addedTable)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT sql FROM sqlite_schema WHERE type='table' AND name='sqlite_sequence';";
        if (command.ExecuteScalar() is not string sql || Canonical(sql) != Canonical("CREATE TABLE sqlite_sequence(name,seq)")) throw Failure();
        if (addedTable)
        {
            command.CommandText = "SELECT count(*) FROM sqlite_sequence WHERE name IS NOT 'message_rollup';";
            if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure();
        }
        command.CommandText = "SELECT count(*),coalesce(max(seq),0),(SELECT coalesce(max(id),0) FROM message_rollup),count(*) FILTER(WHERE typeof(name)<>'text' OR typeof(seq)<>'integer') FROM sqlite_sequence WHERE name='message_rollup';";
        using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.GetInt64(0) != (reader.GetInt64(2) > 0 ? 1 : 0) ||
            reader.GetInt64(1) != reader.GetInt64(2) || reader.GetInt64(3) != 0) throw Failure();
    }
}
