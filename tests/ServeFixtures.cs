using System;
using System.Reflection;
using Microsoft.Data.Sqlite;

public static class ServeFixtures
{
    public static string RawBaseline(object store)
    {
        var result = new System.Text.StringBuilder();
        var tables = new System.Collections.Generic.List<string>();
        using (var c = Connection(store).CreateCommand())
        {
            // source_fields is the schema-10 storage form of source_file.fields (compared through the logical value below), not a source table; the SMTP client
            // structures (schema 11, with smtp_transaction.client_id) are derived from the transactions, like the rollup, and so are the span-bound metadata rows and the mail flow per hour (schema 12).
            // access_client.auth_type and client_session.auth_modes are added by the authentication fold ('' and NULL on the rows it copies): left out like client_id.
            c.CommandText = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('message_rollup','message_rollup_dirty','message_rollup_value','source_fields','smtp_client_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty','mail_flow_hour','mail_flow_dirty') ORDER BY name;";
            using (var r = c.ExecuteReader()) while (r.Read()) tables.Add(r.GetString(0));
        }
        foreach (string table in tables)
        {
            var columns = new System.Collections.Generic.List<string>();
            using (var c = Connection(store).CreateCommand())
            {
                c.CommandText = "PRAGMA table_info(\"" + table + "\");";
                using (var r = c.ExecuteReader()) while (r.Read()) if (r.GetString(1) != "msg_hash" && r.GetString(1) != "fields_id" && r.GetString(1) != "client_id" &&
                    !(table == "access_client" && r.GetString(1) == "auth_type") && !(table == "client_session" && r.GetString(1) == "auth_modes")) columns.Add("\"" + r.GetString(1).Replace("\"", "\"\"") + "\"");
            }
            // Logical '#Fields' text: the dictionary text of a schema-10 row, else the row's own column (schema 6 to 9).
            bool dictionary = false;
            if (table == "source_file")
                using (var c = Connection(store).CreateCommand())
                {
                    c.CommandText = "SELECT COUNT(*) FROM pragma_table_info('source_file') WHERE name='fields_id';";
                    dictionary = Convert.ToInt64(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != 0;
                }
            var selected = new System.Collections.Generic.List<string>(columns);
            if (dictionary) selected[selected.IndexOf("\"fields\"")] = "COALESCE((SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id),\"fields\")";
            result.Append(table).Append(':').Append(string.Join(",", columns)).Append('\n');
            using (var c = Connection(store).CreateCommand())
            {
                c.CommandText = "SELECT " + string.Join(",", selected) + " FROM \"" + table + "\"" +
                    (table == "metadata" ? " WHERE key NOT IN ('schema_version','message_hash_algorithm','tool_version','rollup_max_span_ms','session_max_span_ms','mailflow_accepted_domains','mailflow_rules')" : "") +
                    " ORDER BY " + string.Join(",", selected) + ";";
                using (var r = c.ExecuteReader()) while (r.Read())
                {
                    for (int i=0; i<r.FieldCount; i++)
                    {
                        object value = r.IsDBNull(i) ? null : r.GetValue(i);
                        string text = value == null ? "" : value is byte[] ? Convert.ToBase64String((byte[])value) :
                            Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
                        result.Append(value == null ? "NULL" : value.GetType().Name).Append(':').Append(text.Length).Append(':').Append(text);
                    }
                    result.Append('\n');
                }
            }
        }
        return result.ToString();
    }

    /// <summary>
    /// The content of message_rollup as the readers see it (codes decoded through message_rollup_value, first_ms/last_ms through COALESCE), typed and length-prefixed.
    /// Dictionary codes are not stable across a migration, so a comparison between two shapes or histories is made on this value.
    /// </summary>
    public static string DecodedRollup(object store)
    {
        var result = new System.Text.StringBuilder();
        using (var c = Connection(store).CreateCommand())
        {
            c.CommandText = "SELECT r.id,CASE r.kind WHEN 0 THEN 'message' WHEN 1 THEN 'smtp' END,r.identity,r.msg_hash,COALESCE(r.first_ms,r.member_first_ms),COALESCE(r.last_ms,r.member_last_ms),r.member_first_ms,r.member_last_ms," +
                "s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count FROM message_rollup r " +
                "LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events ORDER BY r.id;";
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    for (int i = 0; i < r.FieldCount; i++)
                    {
                        object value = r.IsDBNull(i) ? null : r.GetValue(i);
                        string text = value == null ? "" : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
                        result.Append(value == null ? "NULL" : value.GetType().Name).Append(':').Append(text.Length).Append(':').Append(text).Append('|');
                    }
                    result.Append('\n');
                }
        }
        return result.ToString();
    }

    public static SqliteConnection Connection(object store)
    {
        return (SqliteConnection)store.GetType().GetProperty("Connection", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(store);
    }

    public static void ForceHashCollision(object store)
    {
        // Test-only deterministic collision, never installed in the production engine.
        Connection(store).CreateFunction<string, long?>("exl_msg_hash", s => s == null ? (long?)null : 17L, isDeterministic: true);
    }

    public static void ForceInvalidNullHash(object store)
    {
        Connection(store).CreateFunction<string, long?>("exl_msg_hash", s => s == null ? 17L : MessageHash(s), isDeterministic: true);
    }

    public static void RefreshServeRollups(object store)
    {
        using (var tx = Connection(store).BeginTransaction())
        {
            store.GetType().GetMethod("ReconcileMessageRollups").Invoke(store, new object[] { tx });
            tx.Commit();
        }
    }

    // A sent SMTP-only transaction as the rows of the older shapes name it ('Not completed (SMTP)'; the current rules say 'Sent (SMTP)').
    const string OlderSmtpStatusSql = "INSERT OR IGNORE INTO message_rollup_value(text) VALUES('Not completed (SMTP)');" +
        "UPDATE message_rollup SET status=(SELECT id FROM message_rollup_value WHERE text='Not completed (SMTP)') WHERE status IN(SELECT id FROM message_rollup_value WHERE text='Sent (SMTP)');";

    // What the current schema-12 shape adds to the shape of the earlier 3.0 builds: the mail flow per hour (tables and triggers) and three indexes.
    const string Current12Sql = "DROP TRIGGER IF EXISTS tr_message_event_flow_insert; DROP TRIGGER IF EXISTS tr_message_event_flow_update; DROP TRIGGER IF EXISTS tr_message_event_flow_delete;" +
        "DROP TRIGGER IF EXISTS tr_smtp_transaction_flow_insert; DROP TRIGGER IF EXISTS tr_smtp_transaction_flow_update; DROP TRIGGER IF EXISTS tr_smtp_transaction_flow_delete;" +
        "DROP TABLE IF EXISTS mail_flow_hour; DROP TABLE IF EXISTS mail_flow_dirty;" +
        "DROP INDEX IF EXISTS ix_msg_noid_flow; DROP INDEX IF EXISTS ix_event_resolution; DROP INDEX IF EXISTS ix_usage_day_success;";

    // The shape of a schema-12 database written before the covering indexes and the span bounds.
    const string PreRelease12Sql = Current12Sql + "DROP TRIGGER IF EXISTS tr_rollup_span_insert; DROP TRIGGER IF EXISTS tr_rollup_span_update;" +
        "DROP TRIGGER IF EXISTS tr_session_span_insert; DROP TRIGGER IF EXISTS tr_session_span_update;" +
        "DELETE FROM metadata WHERE key IN('rollup_max_span_ms','session_max_span_ms');" +
        "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last; DROP INDEX IF EXISTS ix_session_time;" +
        "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms); CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms);" +
        "CREATE INDEX ix_session_time ON client_session(start_ms);" + OlderSmtpStatusSql;

    // The shape of a schema-12 database written with the covering indexes and the span bounds, before events_count and kind joined the rollup indexes.
    const string Covering12Sql = Current12Sql + "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last;" +
        "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status); CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms,member_first_ms);" +
        OlderSmtpStatusSql;

    // The shape of a schema-12 database written with events_count and kind in the rollup indexes, before direction, servers and the mail flow per hour.
    const string Tracked12Sql = Current12Sql + "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last;" +
        "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms,member_first_ms,status,events_count,kind); CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms,member_first_ms,events_count,kind);";

    // The schema-12 shape of a schema-13 database: the message_event UPDATE trigger does not watch the columns of the external status, and metadata has no
    // rules of the external status. The rollup rows keep their labels, as in a real schema-12 file (the migration recomputes them). A schema-12 file is left as is.
    const string Watched13 = ",connector,server_ip,server_host";
    static void DowngradeTo12(SqliteCommand c)
    {
        c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
        if (Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != "13") return;
        c.CommandText = "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='tr_message_event_rollup_update';";
        string trigger = (string)c.ExecuteScalar();
        if (trigger == null || !trigger.Contains(Watched13)) throw new InvalidOperationException("Unexpected schema-13 UPDATE trigger.");
        c.CommandText = "DROP TRIGGER tr_message_event_rollup_update;" + trigger.Replace(Watched13, "") + ";" +
            "DELETE FROM metadata WHERE key IN('mailflow_accepted_domains','mailflow_rules'); UPDATE metadata SET value='12' WHERE key='schema_version';";
        c.ExecuteNonQuery();
    }

    // Synthetic test fixtures only: the schema-12 shape of a schema-13 database (see DowngradeTo12).
    public static void ConvertToSchema12(object storeOrConnection)
    {
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            DowngradeTo12(c);
            tx.Commit();
        }
    }

    // Synthetic test fixtures only: a schema-12 database with rollup indexes without direction and servers, and without the mail flow per hour; the version stays 12.
    public static void ConvertToTrackedSchema12(object storeOrConnection)
    {
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            DowngradeTo12(c);
            c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
            if (Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != "12") throw new InvalidOperationException("Only a schema-12 fixture has an earlier test-build shape.");
            c.CommandText = Tracked12Sql;
            c.ExecuteNonQuery();
            tx.Commit();
        }
    }

    // Synthetic test fixtures only: a schema-12 database with covering rollup indexes without events_count and kind; the version stays 12.
    public static void ConvertToCoveringSchema12(object storeOrConnection)
    {
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            DowngradeTo12(c);
            c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
            if (Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != "12") throw new InvalidOperationException("Only a schema-12 fixture has a covering pre-release shape.");
            c.CommandText = Covering12Sql;
            c.ExecuteNonQuery();
            tx.Commit();
        }
    }

    // Synthetic test fixtures only: a schema-12 database of the step-3 shape (every current object, access_client without the authentication key
    // column, client_session without auth_modes); the version stays 12. Rows that differ only by their authentication type are merged into the row
    // of the old key, as the collector of that shape counted them.
    public static void ConvertToStep3Schema12(object storeOrConnection)
    {
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            DowngradeTo12(c);
            c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
            if (Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != "12") throw new InvalidOperationException("Only a schema-12 fixture has a step-3 shape.");
            c.CommandText = Step3Sql;
            c.ExecuteNonQuery();
            tx.Commit();
        }
    }

    const string Step3Sql = @"
CREATE TEMP TABLE keep AS SELECT day,user,protocol,client_ip,user_agent,device_id,MAX(device_type) AS device_type,MAX(software) AS software,SUM(requests) AS requests,SUM(failures) AS failures,
 MIN(first_ms) AS first_ms,MAX(last_ms) AS last_ms,group_concat(servers) AS servers FROM access_client GROUP BY day,user,protocol,client_ip,user_agent,device_id;
DROP TABLE access_client;
CREATE TABLE access_client(
  day TEXT NOT NULL, user TEXT NOT NULL, protocol TEXT NOT NULL, client_ip TEXT NOT NULL, user_agent TEXT NOT NULL, device_id TEXT NOT NULL,
  device_type TEXT, software TEXT, requests INTEGER NOT NULL, failures INTEGER NOT NULL,
  first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, servers TEXT,
  PRIMARY KEY(day, user, protocol, client_ip, user_agent, device_id)) WITHOUT ROWID;
INSERT INTO access_client SELECT * FROM temp.keep;
DROP TABLE temp.keep;
CREATE INDEX ix_client_user ON access_client(user, day);
ALTER TABLE client_session DROP COLUMN auth_modes;";

    // Synthetic test fixtures only: a schema-12 database with the pre-release shape (old indexes, no span bounds); the version stays 12.
    public static void ConvertToPreReleaseSchema12(object storeOrConnection)
    {
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            DowngradeTo12(c);
            c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
            if (Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != "12") throw new InvalidOperationException("Only a schema-12 fixture has a pre-release shape.");
            c.CommandText = PreRelease12Sql;
            c.ExecuteNonQuery();
            tx.Commit();
        }
    }

    // Synthetic test fixtures only: production copy/verification must never call this conversion.
    public static void ConvertToLegacySyntheticFixture(object storeOrConnection, int version)
    {
        if (version != 6 && version != 7 && version != 8 && version != 9 && version != 10 && version != 11 && version != 12) throw new ArgumentOutOfRangeException(nameof(version));
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            DowngradeTo12(c);
            c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
            int current = Convert.ToInt32(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture);
            if (current < version || current > 12) throw new InvalidOperationException("Only downgrade a known synthetic schema 6/7/8/9/10/11/12/13 fixture.");
            if (version == 12) { tx.Commit(); return; }
            if (current == 12)
            {
                // Schema-11 shape of a schema-12 database: the message_event UPDATE trigger does not watch the two recipient status columns,
                // the covering indexes and span bounds do not exist, and access_client and client_session have no authentication columns.
                // The rollup rows keep their labels, as in a real schema-11 file (the migration recomputes them).
                c.CommandText = Step3Sql;
                c.ExecuteNonQuery();
                c.CommandText = PreRelease12Sql;
                c.ExecuteNonQuery();
                c.CommandText = "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='tr_message_event_rollup_update';";
                string trigger = (string)c.ExecuteScalar();
                const string watched = "directionality,recipient_status,related_recipient";
                if (trigger == null || !trigger.Contains(watched)) throw new InvalidOperationException("Unexpected schema-12 UPDATE trigger.");
                c.CommandText = "DROP TRIGGER tr_message_event_rollup_update;" + trigger.Replace(watched, "directionality") + ";" +
                    "UPDATE metadata SET value='11' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                current = 11;
                if (version == 11) { tx.Commit(); return; }
            }
            if (current == 11)
            {
                // Schema-10 shape of a schema-11 database: no SMTP client structures, message_rollup with text columns (ids and sequence kept), ix_smtp_latest back.
                long? sequence = null;
                c.CommandText = "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';";
                object seq = c.ExecuteScalar();
                if (seq != null && !(seq is DBNull)) sequence = Convert.ToInt64(seq, System.Globalization.CultureInfo.InvariantCulture);
                c.CommandText = "DROP TRIGGER IF EXISTS tr_smtp_transaction_client_insert; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_update; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_delete;" +
                    "DROP INDEX IF EXISTS ix_smtp_client; DROP INDEX IF EXISTS ix_smtp_unknown_peer; ALTER TABLE smtp_transaction DROP COLUMN client_id;" +
                    "DROP TABLE smtp_client_hour; DROP TABLE smtp_client; DROP TABLE smtp_client_value; DROP TABLE smtp_client_pending; DROP TABLE smtp_client_dirty;" +
                    "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last; ALTER TABLE message_rollup RENAME TO message_rollup_11;" +
                    "CREATE TABLE message_rollup(\n id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, identity TEXT COLLATE BINARY NOT NULL,\n msg_hash INTEGER, first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL,\n member_first_ms INTEGER NOT NULL, member_last_ms INTEGER NOT NULL, status TEXT NOT NULL,\n sender TEXT, recipients TEXT NOT NULL, recipient_count INTEGER NOT NULL, delivered INTEGER NOT NULL,\n failed INTEGER NOT NULL, subject TEXT, size_kb INTEGER, direction TEXT, servers TEXT, events TEXT,\n events_count INTEGER NOT NULL, smtp_count INTEGER NOT NULL, UNIQUE(kind,identity));" +
                    "INSERT INTO message_rollup(id,kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count) " +
                    "SELECT r.id,CASE r.kind WHEN 0 THEN 'message' ELSE 'smtp' END,r.identity,r.msg_hash,COALESCE(r.first_ms,r.member_first_ms),COALESCE(r.last_ms,r.member_last_ms),r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count " +
                    "FROM message_rollup_11 r JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events ORDER BY r.id;" +
                    "DROP TABLE message_rollup_11; DROP TABLE message_rollup_value;" +
                    "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms); CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms);" +
                    "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms);";
                c.ExecuteNonQuery();
                if (sequence.HasValue)
                {
                    c.CommandText = "UPDATE sqlite_sequence SET seq=MAX(seq,@s) WHERE name='message_rollup'; INSERT INTO sqlite_sequence(name,seq) SELECT 'message_rollup',@s WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='message_rollup');";
                    c.Parameters.AddWithValue("@s", sequence.Value);
                    c.ExecuteNonQuery();
                    c.Parameters.Clear();
                }
                c.CommandText = "UPDATE metadata SET value='10' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                current = 10;
                if (version == 10) { tx.Commit(); return; }
            }
            if (current == 10)
            {
                // Schema-9 shape of a schema-10 database: the identity indexes carry the exact Message-ID again, the '#Fields' text is back in
                // source_file.fields and the dictionary (with its fields_id column) does not exist.
                c.CommandText = "UPDATE source_file SET fields=(SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id) WHERE fields_id IS NOT NULL;" +
                    "ALTER TABLE source_file DROP COLUMN fields_id; DROP TABLE source_fields;" +
                    "DROP INDEX IF EXISTS ix_msg_identity_time; DROP INDEX IF EXISTS ix_smtp_identity_time;" +
                    "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,message_id COLLATE BINARY,time_ms,id);" +
                    "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,message_id COLLATE BINARY,time_ms,id);" +
                    "UPDATE metadata SET value='9' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                if (version == 9) { tx.Commit(); return; }
            }
            if (version == 8)
            {
                // Schema-8 shape of a schema-9 database: hash-only and DESC "latest" indexes, ascending-free rollup indexes, full-column UPDATE triggers.
                c.CommandText = "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last; DROP INDEX IF EXISTS ix_smtp_latest;" +
                    "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms DESC,id DESC);" +
                    "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms DESC,id DESC);" +
                    "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms DESC,id DESC);" +
                    "CREATE INDEX ix_session_latest ON client_session(start_ms DESC,id DESC);" +
                    "CREATE INDEX ix_msg_hash ON message_event(msg_hash);CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);";
                c.ExecuteNonQuery();
                foreach (var old in new[] {
                    new[] { "message_event", " OF id,message_id,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality",
                        " OF id,message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference" },
                    new[] { "smtp_transaction", " OF id,message_id,time_ms,end_ms,server,direction,mail_from,rcpts,status",
                        " OF id,message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,status,auth_user" } })
                {
                    c.CommandText = "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='tr_" + old[0] + "_rollup_update';";
                    string sql = (string)c.ExecuteScalar();
                    if (sql == null || !sql.Contains(old[1])) throw new InvalidOperationException("Unexpected schema-9 UPDATE trigger.");
                    c.CommandText = "DROP TRIGGER tr_" + old[0] + "_rollup_update;" + sql.Replace(old[1], old[2]) + ";";
                    c.ExecuteNonQuery();
                }
                c.CommandText = "UPDATE metadata SET value='8' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                tx.Commit();
                return;
            }
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            foreach (string operation in new[] { "insert", "update", "delete" })
            {
                c.CommandText = "DROP TRIGGER IF EXISTS tr_" + table + "_rollup_" + operation + ";";
                c.ExecuteNonQuery();
            }
            c.CommandText = "DROP TABLE IF EXISTS message_rollup; DROP TABLE IF EXISTS message_rollup_dirty;" +
                "DROP INDEX IF EXISTS ix_msg_identity_time; DROP INDEX IF EXISTS ix_smtp_identity_time;" +
                "DROP INDEX IF EXISTS ix_smtp_latest; DROP INDEX IF EXISTS ix_session_latest;";
            c.ExecuteNonQuery();
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            {
                c.CommandText = "PRAGMA table_info(" + table + ");";
                bool hasHash = false;
                using (var r = c.ExecuteReader()) while (r.Read()) if (r.GetString(1) == "msg_hash") hasHash = true;
                if (version == 7 && !hasHash) throw new InvalidOperationException("Schema 7 fixtures require an existing hash column.");
                if (version == 7)
                {
                    // A real schema-7 database carries the hash-only index that schema 9 no longer creates.
                    c.CommandText = "CREATE INDEX IF NOT EXISTS " + (table == "message_event" ? "ix_msg_hash ON message_event" : "ix_smtp_hash ON smtp_transaction") + "(msg_hash);";
                    c.ExecuteNonQuery();
                }
                if (version != 6) continue;
                c.CommandText = "DROP TRIGGER IF EXISTS tr_" + table + "_hash_insert; DROP TRIGGER IF EXISTS tr_" + table + "_hash_update;" +
                    "DROP INDEX IF EXISTS " + (table == "message_event" ? "ix_msg_hash" : "ix_smtp_hash") + ";" +
                    (hasHash ? "ALTER TABLE " + table + " DROP COLUMN msg_hash;" : "");
                c.ExecuteNonQuery();
            }
            if (version == 6)
            {
                c.CommandText = "CREATE INDEX IF NOT EXISTS ix_msg_id ON message_event(message_id);" +
                    "CREATE INDEX IF NOT EXISTS ix_smtp_message ON smtp_transaction(message_id);" +
                    "DELETE FROM metadata WHERE key='message_hash_algorithm';";
                c.ExecuteNonQuery();
            }
            c.CommandText = "UPDATE metadata SET value=@version WHERE key='schema_version';";
            c.Parameters.AddWithValue("@version", version.ToString(System.Globalization.CultureInfo.InvariantCulture));
            c.ExecuteNonQuery();
            tx.Commit();
        }
    }

    /// <summary>
    /// A consistent copy of a store (SQLite backup), downgraded to the shape of an earlier schema (6 to 10) and left open on the returned connection
    /// (exl_msg_hash registered): the same data, as that schema stored it. Synthetic test fixtures only.
    /// </summary>
    public static SqliteConnection LegacyCopy(object store, string destination, int version)
    {
        var to = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = destination, Pooling = false }.ToString());
        to.Open();
        Connection(store).BackupDatabase(to);
        to.CreateFunction<string, long?>("exl_msg_hash", MessageHash, isDeterministic: true);
        ConvertToLegacySyntheticFixture(to, version);
        return to;
    }

    public static void Populate(object store, long epoch, int count)
    {
        using (var tx = Connection(store).BeginTransaction())
        using (var c = Connection(store).CreateCommand())
        {
            c.Transaction = tx;
            c.CommandText = @"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<@n)
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count,total_bytes)
SELECT @t+i,'EX1','RECEIVE','<m'||i||'@invalid>','r'||i,'sender'||(i%30)||'@invalid','r@invalid',@subject,1,8192 FROM n;
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count,total_bytes)
SELECT time_ms+1000,server,'DELIVER',message_id,'d'||id,sender,recipients,subject,1,total_bytes FROM message_event WHERE event_id='RECEIVE';";
            c.Parameters.AddWithValue("@n", count);
            c.Parameters.AddWithValue("@t", epoch);
            c.Parameters.AddWithValue("@subject", new string('s', 240));
            c.ExecuteNonQuery();
            store.GetType().GetMethod("ReconcileMessageRollups").Invoke(store, new object[] { tx });
            tx.Commit();
        }
    }

    public static void Schema7Copy(string source, string destination)
    {
        if (System.IO.File.Exists(destination)) throw new System.IO.IOException("Destination exists.");
        using (var from = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = source, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
        using (var to = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = destination, Pooling = false }.ToString()))
        {
            from.Open(); to.Open(); from.BackupDatabase(to);
            to.CreateFunction<string, long?>("exl_msg_hash", MessageHash, isDeterministic: true);
            using (var tx = to.BeginTransaction())
            using (var c = to.CreateCommand())
            {
                c.Transaction = tx;
                c.CommandText = @"ALTER TABLE message_event ADD COLUMN msg_hash INTEGER;
ALTER TABLE smtp_transaction ADD COLUMN msg_hash INTEGER;
UPDATE message_event SET msg_hash=exl_msg_hash(message_id);
UPDATE smtp_transaction SET msg_hash=exl_msg_hash(message_id);
CREATE INDEX ix_msg_hash ON message_event(msg_hash);
CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);
DROP INDEX IF EXISTS ix_msg_id; DROP INDEX IF EXISTS ix_smtp_message;
INSERT INTO metadata VALUES('message_hash_algorithm','fnv1a64-utf8-v1');
UPDATE metadata SET value='7' WHERE key='schema_version';";
                c.ExecuteNonQuery(); tx.Commit();
            }
        }
    }

    static MethodInfo _messageHash;
    static long? MessageHash(string text)
    {
        if (_messageHash == null)
            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                var type = assembly.GetType("ExchangeLogReport.Store", false);
                if (type != null) { _messageHash = type.GetMethod("MessageHash"); break; }
            }
        if (_messageHash == null) throw new InvalidOperationException("Load the in-memory engine before the fixture.");
        return (long?)_messageHash.Invoke(null, new object[] { text });
    }

    public static string RawGet(int port, string target, string host, string token)
    {
        using (var tcp = new System.Net.Sockets.TcpClient())
        {
            tcp.ReceiveTimeout = 10000;
            tcp.SendTimeout = 10000;
            tcp.Connect("127.0.0.1", port);
            using (var stream = tcp.GetStream())
            using (var writer = new System.IO.StreamWriter(stream, new System.Text.UTF8Encoding(false), 1024, true))
            using (var reader = new System.IO.StreamReader(stream))
            {
                writer.NewLine = "\r\n";
                writer.Write("GET " + target + " HTTP/1.1\r\nHost: " + host + "\r\nX-Portal-Token: " + token + "\r\nConnection: close\r\n\r\n");
                writer.Flush();
                return reader.ReadToEnd();
            }
        }
    }
}
