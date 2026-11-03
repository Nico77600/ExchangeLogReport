if (-not ('ServeFixtures' -as [type])) {
    $project = Split-Path $PSScriptRoot -Parent
    Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ServeFixtures.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies @(
        (Join-Path $project 'package\lib\sqlite\Microsoft.Data.Sqlite.dll'),
        'System.Runtime', 'System.Data.Common', 'System.Reflection', 'System.Net.Sockets', 'System.Net.Primitives',
        'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard'
    )
}

function Complete-StorageFixture($Store) {
    $tx = $Store.Begin()
    try { $Store.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
}

# The tracking rollup rows of the -StatusRules messages as the schema 8 to 11 engine wrote them (pre-12 recipient vocabulary), on a schema-11 shaped
# database (status as a message_rollup_value code). The downgrade helper keeps the schema-12 labels; only the identities whose rows differ between the two
# rule sets are rewritten, and each must exist exactly once. Only status and recipients are rewritten: these two messages have no EXPAND or DROP, so
# recipient_count, delivered and failed are the same under both rule sets (the frozen-rules plain copy recomputes and compares every column). A
# -StatusRules message with an EXPAND or a DROP would need those three columns rewritten too.
function Set-LegacyRollupVocabulary([Microsoft.Data.Sqlite.SqliteConnection]$Connection) {
    $c = $Connection.CreateCommand()
    try {
        $c.CommandText = "INSERT OR IGNORE INTO message_rollup_value(text) VALUES('Relayed'),('Delivered and relayed');"
        [void]$c.ExecuteNonQuery()
        foreach ($row in @(
                @('<out@example.invalid>', 'Relayed', '["b@example.invalid (Sent)"]'),
                @('<relay@example.invalid>', 'Delivered and relayed', '["a@example.invalid","b@example.invalid (Sent)"]'))) {
            $c.CommandText = "UPDATE message_rollup SET status=(SELECT id FROM message_rollup_value WHERE text='$($row[1])'), recipients='$($row[2])' WHERE kind=0 AND identity='$($row[0])';"
            if ($c.ExecuteNonQuery() -ne 1) { throw "Legacy rollup vocabulary: no tracking row for $($row[0])." }
        }
    } finally { $c.Dispose() }
}

function Set-LegacyStorageFixture([Microsoft.Data.Sqlite.SqliteConnection]$Connection, [ValidateSet(6, 7, 8, 9, 10, 11)][int]$Schema, [switch]$RollupVocabulary) {
    # Schema 11: the previous current shape (codes, SMTP client structures, UPDATE trigger without the two recipient status columns, rows in the pre-12
    # recipient vocabulary when -RollupVocabulary is given).
    # Schema 10: the shape before it (text rollup columns, no SMTP client structures, ix_smtp_latest).
    # Schema 9: the shape before it (wide exact-identity indexes, '#Fields' text in source_file.fields, no dictionary).
    # Schema 8: the shape before it (hash-only and DESC latest indexes, full-column UPDATE triggers).
    if ($Schema -in 8, 9, 10, 11) {
        [ServeFixtures]::ConvertToLegacySyntheticFixture($Connection, 11)
        if ($RollupVocabulary) { Set-LegacyRollupVocabulary $Connection }
        if ($Schema -lt 11) { [ServeFixtures]::ConvertToLegacySyntheticFixture($Connection, $Schema) }
        return
    }
    # Schema 6/7: first the shape of schema 12 before its covering indexes and span bounds (the start_ms-only ix_session_time of every older schema)
    # and before the authentication columns.
    [ServeFixtures]::ConvertToStep3Schema12($Connection)
    [ServeFixtures]::ConvertToPreReleaseSchema12($Connection)
    $c = $Connection.CreateCommand()
    try {
        $c.CommandText = @'
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_insert;
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_update;
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_delete;
DROP INDEX IF EXISTS ix_smtp_client;
DROP INDEX IF EXISTS ix_smtp_unknown_peer;
ALTER TABLE smtp_transaction DROP COLUMN client_id;
DROP TABLE smtp_client_hour;
DROP TABLE smtp_client;
DROP TABLE smtp_client_value;
DROP TABLE smtp_client_pending;
DROP TABLE smtp_client_dirty;
DROP TABLE message_rollup_value;
UPDATE source_file SET fields=(SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id) WHERE fields_id IS NOT NULL;
ALTER TABLE source_file DROP COLUMN fields_id;
DROP TABLE source_fields;
DROP TRIGGER tr_message_event_rollup_insert;
DROP TRIGGER tr_message_event_rollup_update;
DROP TRIGGER tr_message_event_rollup_delete;
DROP TRIGGER tr_smtp_transaction_rollup_insert;
DROP TRIGGER tr_smtp_transaction_rollup_update;
DROP TRIGGER tr_smtp_transaction_rollup_delete;
DROP INDEX ix_msg_identity_time;
DROP INDEX ix_smtp_identity_time;
DROP INDEX IF EXISTS ix_smtp_latest;
DROP INDEX IF EXISTS ix_session_latest;
DROP TABLE message_rollup_dirty;
DROP TABLE message_rollup;
'@
        if ($Schema -eq 6) {
            $c.CommandText += @'
DROP TRIGGER tr_message_event_hash_insert;
DROP TRIGGER tr_message_event_hash_update;
DROP TRIGGER tr_smtp_transaction_hash_insert;
DROP TRIGGER tr_smtp_transaction_hash_update;
DROP INDEX IF EXISTS ix_msg_hash;
DROP INDEX IF EXISTS ix_smtp_hash;
ALTER TABLE message_event DROP COLUMN msg_hash;
ALTER TABLE smtp_transaction DROP COLUMN msg_hash;
CREATE INDEX ix_msg_id ON message_event(message_id);
CREATE INDEX ix_smtp_message ON smtp_transaction(message_id);
DELETE FROM metadata WHERE key='message_hash_algorithm';
'@
        }
        # A genuine schema-7 database owns the hash-only indexes ix_msg_hash and ix_smtp_hash (schemas 9 and later have none).
        if ($Schema -eq 7) { $c.CommandText += 'CREATE INDEX ix_msg_hash ON message_event(msg_hash);CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);' }
        $c.CommandText += "UPDATE metadata SET value='$Schema' WHERE key='schema_version';"
        [void]$c.ExecuteNonQuery()
        # Remove the empty SQLite AUTOINCREMENT system table left by the schema-8 fixture.
        $c.CommandText = 'VACUUM;'
        [void]$c.ExecuteNonQuery()
    } finally { $c.Dispose() }
}
