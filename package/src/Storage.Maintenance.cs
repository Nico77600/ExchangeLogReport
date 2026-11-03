#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport.Storage;

internal sealed class StorageMaintenance(StorageOptions options)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private sealed record Phase(string Stage, double DurationMs);
    private sealed record VacuumCapacity(string TempStore, string DestinationVolume, string TemporaryVolume,
        bool SharedVolumeBudget, long StagedBytes, long DestinationRequiredFreeBytes,
        long DestinationAvailableFreeBytes, long TemporaryRequiredFreeBytes, long TemporaryAvailableFreeBytes);

    public async Task<StorageAudit> AuditAsync()
    {
        try
        {
            using var source = new StorageSource(options.Database);
            StorageAudit result = await StorageAuditTool.RunAsync(options.Database, options.SqliteTool);
            source.VerifyUnchanged();
            return result;
        }
        catch (StorageFailure error) { throw new ApiError(422, error.Message); }
        catch (IOException) { throw new ApiError(409, "Source is unavailable or held by a writer. Close writers and retry the read-only audit."); }
    }

    public static async Task<int> RunCliAsync(StorageOptions options)
    {
        try
        {
            var storage = new StorageMaintenance(options);
            object report;
            if (options.StorageMode == StorageMode.Audit)
            {
                if (options.Output is not null) StorageSafety.NewFile(options.Output, options.Database);
                report = await storage.AuditAsync();
                if (options.Output is not null) await WriteNewReport(options.Output, report);
            }
            else report = await storage.CopyAsync();
            Console.WriteLine(JsonSerializer.Serialize(report, JsonOptions));
            return 0;
        }
        catch (Exception error)
        {
            string message = error is StorageFailure or ApiError ? error.Message : StorageCli.Describe(error);
            Console.Error.WriteLine("Storage operation failed: " + message);
            Console.WriteLine(JsonSerializer.Serialize(new { success = false, operation = options.StorageMode.ToString().ToLowerInvariant(), error = message }, JsonOptions));
            return 2;
        }
    }

    private const string IdentityTable = "identity_map";

    // The staged names add "." before the destination name and "." + 32 hexadecimal digits + ".vacuum.sqlite" + "-journal" after it.
    private const int StagedNameExtra = 1 + 1 + 32 + 14 + 8;
    private const int MaxSqlitePathBytes = 1040;

    private async Task<object> CopyAsync()
    {
        string destination = options.Destination!;
        string output = options.Output!;
        StorageSafety.NewFile(destination, options.Database);
        StorageSafety.NewFile(output, options.Database, destination);
        // The staged copies are written next to the destination under longer names (StagedNameExtra characters more, with their -journal sidecar):
        // SQLite opens a file name of at most MaxSqlitePathBytes UTF-8 bytes on Windows, extended prefix included, which is checked before any write.
        int stagedNameBytes = System.Text.Encoding.UTF8.GetByteCount(Store.SqlitePath(destination)) + StagedNameExtra;
        if (stagedNameBytes > MaxSqlitePathBytes)
            throw new StorageFailure("The destination path is too long for the copy staged next to it: its name would take " + stagedNameBytes.ToString(CultureInfo.InvariantCulture) +
                " UTF-8 bytes, more than the " + MaxSqlitePathBytes.ToString(CultureInfo.InvariantCulture) + " that SQLite opens on Windows. Choose a destination path at least " +
                (stagedNameBytes - MaxSqlitePathBytes).ToString(CultureInfo.InvariantCulture) + " bytes shorter; nothing was written.");
        using var source = new StorageSource(options.Database);
        using var sourceDb = StorageSafety.Open(options.Database, false);
        string? schema = StorageSafety.Metadata(sourceDb, "schema_version");
        if (Store.SchemaVersion != "13" || schema is not ("6" or "7" or "8" or "9" or "10" or "11" or "12" or "13") ||
            !int.TryParse(schema, NumberStyles.None, CultureInfo.InvariantCulture, out int sourceVersion) ||
            sourceVersion is < 6 or > 13)
            throw new StorageFailure("This copy maintenance profile supports delivered schemas 6 through 13 only; future or unknown schemas are rejected before destination writes.");
        // upgrade: any schema change of the copy (6 to 12 -> 13). rollupUpgrade: the derived tables are new (6/7 -> 13); a schema 8 to 12 source already
        // owns them and only gets other indexes and triggers. fieldsUpgrade (< 10): the source_fields dictionary is new, the logical '#Fields' text of source_file
        // is compared, not its storage form. clientsUpgrade (< 11): the SMTP client structures, the rollup dictionary and smtp_transaction.client_id are new, and
        // an existing message_rollup (8 to 10) is compared through its decoded logical rows (codes, COALESCE of the member bounds) with ids unchanged.
        // rulesUpgrade (8 to 12 -> 13): the tracking rollup rows are reconciled again by the current recipient rules (from 12: the identities with a SENDEXTERNAL
        // event, with the rules of the external status); their rule columns are verified by exact recomputation instead of equality with the source, and the
        // message_rollup sequence may advance (never go backwards). valuePreserved (11 or 12 -> 13): message_rollup_value keeps every row and id of the source,
        // new texts are appended above the source maximum. upgrade12 (6 to 11 -> 13): the objects schema 12 added (mail flow per hour, span bounds) are new.
        bool upgrade = options.Migrate && sourceVersion < 13;
        bool upgrade12 = options.Migrate && sourceVersion < 12;
        bool rollupUpgrade = options.Migrate && sourceVersion < 8;
        bool fieldsUpgrade = options.Migrate && sourceVersion < 10;
        bool hashUpgrade = upgrade && sourceVersion == 6;
        bool clientsUpgrade = options.Migrate && sourceVersion < 11;
        bool rulesUpgrade = options.Migrate && sourceVersion is >= 8 and < 13;
        // shapeUpgrade (12 written before the covering indexes, with covering rollup indexes without events_count and kind, or without direction, servers and
        // the mail flow per hour): the copy gets the current ix_rollup_last, ix_rollup_status_last and ix_session_time, ix_msg_noid_flow, ix_event_resolution,
        // ix_usage_day_success, the mail flow per hour and the span bounds (two metadata rows, four triggers) at its writable open,
        // and its SMTP-only rows get the current status of a sent transaction ('Sent (SMTP)'), so the rule columns of kind 0, the message_rollup
        // sequence and the dictionary rows above the source maximum are verified as for rulesUpgrade; no row of any other table changes.
        // A Step3_12 source (every object of the current shape but the authentication columns) is a shape upgrade too, whose only change is
        // authUpgrade; rollupShapeUpgrade is the shape upgrade of the earlier schema-12 shapes, which rebuilds and reconciles the derived objects.
        bool sourceAuth = sourceVersion >= 12 && StorageRollupVerification.HasAuthShape(sourceDb);
        bool sourceShape12 = sourceVersion < 12 || (StorageRollupVerification.HasShape12(sourceDb) && sourceAuth);
        bool shapeUpgrade = options.Migrate && !sourceShape12;
        bool sourceStep3 = !sourceShape12 && StorageRollupVerification.IsStep3_12(sourceDb);
        bool rollupShapeUpgrade = shapeUpgrade && !sourceStep3;
        // An earlier schema-12 shape keeps the comparison of its shape upgrade (codes compared as stored, dictionary rows above the source maximum allowed).
        bool valuePreserved = options.Migrate && (sourceVersion == 11 || (sourceVersion == 12 && !rollupShapeUpgrade));
        bool sourceCovering12 = !sourceShape12 && !sourceStep3 && StorageRollupVerification.IsCovering12(sourceDb);
        bool sourceTracked12 = !sourceShape12 && !sourceStep3 && !sourceCovering12 && StorageRollupVerification.IsTracked12(sourceDb);
        // authUpgrade (any migration of a source without the authentication columns): access_client is rebuilt with the key column auth_type ('' in every
        // copied row) and client_session gets auth_modes (NULL); both tables are compared on their source columns and the added values are counted.
        bool authUpgrade = options.Migrate && !sourceAuth;
        // mailFlowUpgrade: the mail flow per hour is new in the copy (any migration from schema 11 or older, any shape upgrade of an earlier schema-12
        // shape): its tables are derived from the copied tracking events and SMTP transactions and verified equal to a full recomputation.
        bool mailFlowUpgrade = upgrade12 || rollupShapeUpgrade;
        bool rollupRecomputed = rulesUpgrade || rollupShapeUpgrade;
        long? valueMaxId = valuePreserved || rollupShapeUpgrade ? Scalar(sourceDb, "SELECT coalesce(max(id),0) FROM message_rollup_value;") : null;
        string[] spanMetadata = upgrade12 || rollupShapeUpgrade ? Store.ServeSpanMetadata : [];
        // The rules of the external status (schema 13) are derived from the copied tracking events and the stored rules: written by the migration.
        string[] rulesMetadata = upgrade ? [MailFlowRules.DomainsKey, MailFlowRules.RulesKey] : [];
        string[] excludedMetadata = (hashUpgrade ? new[] { "schema_version", "message_hash_algorithm" } :
            upgrade ? new[] { "schema_version" } : Array.Empty<string>()).Concat(spanMetadata).Concat(rulesMetadata).ToArray();
        var sourceComparison = new LogicalComparison(hashUpgrade, excludedMetadata, [], rollupUpgrade) {
            RollupCodes = valuePreserved, RollupRulesMasked = rollupRecomputed, RollupSequenceAdvance = rollupRecomputed, RollupValueMaxId = valueMaxId
        };
        var targetComparison = sourceComparison with {
            AddedTables = (rollupUpgrade ? StorageRollupVerification.Tables : []).Concat(fieldsUpgrade ? [StorageRollupVerification.SourceFieldsTable] : [])
                .Concat(clientsUpgrade ? [StorageRollupVerification.RollupValueTable, .. StorageRollupVerification.SmtpClientTables] : [])
                .Concat(mailFlowUpgrade ? StorageRollupVerification.MailFlowTables : []).ToArray(),
            FieldsDictionary = fieldsUpgrade, ClientId = clientsUpgrade, RollupCodes = valuePreserved || (upgrade && sourceVersion is >= 8 and < 11), AuthColumns = authUpgrade
        };
        // A repack opens the copy writable, which gives a schema-12 copy written before the covering indexes the final shape: that is a migration.
        if (options.Repack && !options.Migrate && (schema != Store.SchemaVersion || !sourceShape12))
            throw new StorageFailure("--repack requires the current schema or explicit --migrate on the new copy.");
        string? toolVersion = StorageSafety.Metadata(sourceDb, "tool_version");
        if ((options.Migrate || options.Repack) && toolVersion is null)
            throw new StorageFailure("Source tool_version metadata is missing; refusing to introduce or overwrite unrelated metadata.");
        long required = checked(Math.Max(source.Bytes, 1048576) * 3 + 16 * 1048576);
        var drive = new DriveInfo(Path.GetPathRoot(destination)!);
        if (drive.AvailableFreeSpace < required)
            throw new StorageFailure("Insufficient destination free space. This operation conservatively requires at least three times source plus WAL bytes, with an additional safety margin. No copy was started.");
        var phases = new List<Phase>();
        var clock = Stopwatch.StartNew();
        void Phase(string stage) { phases.Add(new(stage, clock.Elapsed.TotalMilliseconds)); clock.Restart(); }
        StorageSafety.Integrity(sourceDb, false);
        Phase("sourceQuickCheck");
        StorageAudit beforeAudit = await StorageAuditTool.RunAsync(options.Database, options.SqliteTool);
        Phase("sourceAudit");
        var measurements = new List<object> { new { stage = "source", audit = beforeAudit } };
        List<LogicalTable> baseline = StorageFingerprint.Inventory(sourceDb);
        string[] addedBookkeepingTables = rollupUpgrade && !baseline.Any(table => table.Name == "sqlite_sequence")
            ? ["sqlite_sequence"] : [];
        // A copy opened writable (migration or repack) gets the 3.0.0 identity_map table, empty, when its source has none.
        bool identityAdded = ((options.Migrate && (upgrade || shapeUpgrade)) || options.Repack) && !baseline.Any(table => table.Name == IdentityTable);
        targetComparison = targetComparison with {
            AddedTables = targetComparison.AddedTables.Concat(addedBookkeepingTables).Concat(identityAdded ? [IdentityTable] : []).ToArray()
        };
        StorageRollupVerification.CheckSource(sourceDb, sourceVersion);
        Phase("sourceRollupVerification");
        List<LogicalDigest> before = StorageFingerprint.Compute(sourceDb, baseline, sourceComparison);
        Phase("sourceFingerprint");
        var owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string stage = Path.Combine(Path.GetDirectoryName(destination)!, "." + Path.GetFileName(destination) + "." + Guid.NewGuid().ToString("N") + ".stage.sqlite");
        string? vacuum = null;
        VacuumCapacity? vacuumCapacity = null;
        long? sequenceBefore = null, sequenceAfter = null;
        bool published = false;
        try
        {
            Reserve(stage, owned);
            using (var target = StorageSafety.Open(stage, true)) sourceDb.BackupDatabase(target);
            Phase("sqliteBackup");
            long repacked = 0;
            if (options.Migrate)
            {
                if (upgrade || shapeUpgrade) { using (new Store(stage, false, toolVersion)) { } }
                Phase("migration");
                measurements.Add(new { stage = "afterMigration", audit = await StorageAuditTool.RunAsync(stage, options.SqliteTool) });
                Phase("migrationAudit");
            }
            if (options.Repack)
            {
                using (var store = new Store(stage, false, toolVersion)) repacked = store.RepackSafeText();
                Phase("repack");
                measurements.Add(new { stage = "afterRepack", audit = await StorageAuditTool.RunAsync(stage, options.SqliteTool) });
                Phase("repackAudit");
            }
            using (var target = StorageSafety.Open(stage, true))
            {
                using var checkpoint = target.CreateCommand();
                checkpoint.CommandTimeout = 0;
                checkpoint.CommandText = "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; PRAGMA temp_store=FILE;";
                checkpoint.ExecuteNonQuery();
                if (options.Vacuum)
                {
                    long stageBytes = new FileInfo(stage).Length + (File.Exists(stage + "-wal") ? new FileInfo(stage + "-wal").Length : 0);
                    long vacuumRequired = checked(stageBytes * 2 + 16 * 1048576);
                    string temporaryDirectory = Path.GetTempPath();
                    StorageSafety.PlainPath(temporaryDirectory);
                    var temporaryDrive = new DriveInfo(Path.GetPathRoot(temporaryDirectory)!);
                    long destinationAvailable = drive.AvailableFreeSpace;
                    long temporaryAvailable = temporaryDrive.AvailableFreeSpace;
                    bool shared = StorageSafety.Same(drive.RootDirectory.FullName, temporaryDrive.RootDirectory.FullName);
                    vacuumCapacity = new("FILE", drive.RootDirectory.FullName, temporaryDrive.RootDirectory.FullName,
                        shared, stageBytes, vacuumRequired, destinationAvailable, vacuumRequired, temporaryAvailable);
                    if (destinationAvailable < vacuumRequired)
                        throw new StorageFailure("Insufficient remaining destination space for the full staged VACUUM. Free at least twice the staged database size plus the safety margin; no destination was published.");
                    if (!shared && temporaryAvailable < vacuumRequired)
                        throw new StorageFailure("Insufficient system temporary-drive space for FILE-backed VACUUM sorting. Free at least twice the staged database size plus the safety margin on the existing temp drive; no TEMP or global SQLite directory was changed.");
                    vacuum = Path.Combine(Path.GetDirectoryName(destination)!, "." + Path.GetFileName(destination) + "." + Guid.NewGuid().ToString("N") + ".vacuum.sqlite");
                    Reserve(vacuum, owned);
                    using var command = target.CreateCommand();
                    command.CommandTimeout = 0;
                    command.CommandText = "VACUUM INTO @file;";
                    command.Parameters.AddWithValue("@file", Store.SqlitePath(vacuum));
                    command.ExecuteNonQuery();
                }
            }
            Phase(options.Vacuum ? "vacuumIntoSibling" : "checkpointWithoutVacuum");
            string finalStage = vacuum ?? stage;
            using (var stagedGuard = new StorageSource(finalStage, allowVerifiedRename: true))
            using (var staged = StorageSafety.Open(finalStage, false))
            {
                StorageSafety.Integrity(staged, true);
                Phase("stagedIntegrityCheck");
                var after = StorageFingerprint.Compute(staged, baseline, targetComparison);
                StorageFingerprint.Compare(before, after, sourceComparison);
                if (identityAdded && Scalar(staged, "SELECT count(*) FROM " + IdentityTable + ";") != 0)
                    throw new StorageFailure("The identity_map table added to the copy is not empty; no destination was published.");
                if (rollupRecomputed)
                {
                    // The sequence row is left out of the digest: it exists on both sides or on neither, and it never goes backwards (URL ids are never reused).
                    sequenceBefore = RollupSequence(sourceDb);
                    sequenceAfter = RollupSequence(staged);
                    if ((sequenceBefore is null) != (sequenceAfter is null) || sequenceAfter < sequenceBefore)
                        throw new StorageFailure("The message_rollup id sequence of the migrated copy went backwards or disappeared; no destination was published.");
                }
                // Defensive: the digest of message_rollup_value up to the source's highest id and the compared row counts already prove
                // that no dictionary row was lost; this count states it on its own with a precise message.
                if ((valuePreserved || rollupShapeUpgrade) && Scalar(staged, "SELECT count(*) FROM message_rollup_value;") < Scalar(sourceDb, "SELECT count(*) FROM message_rollup_value;"))
                    throw new StorageFailure("The message_rollup_value dictionary of the migrated copy lost rows; no destination was published.");
                if (upgrade && StorageSafety.Metadata(staged, "schema_version") != Store.SchemaVersion)
                    throw new StorageFailure("Schema migration did not produce schema " + Store.SchemaVersion + "; no destination was published.");
                bool verifyRollups = sourceVersion >= 8 || upgrade;
                int targetVersion = upgrade ? 13 : sourceVersion;
                // A migrated copy must have the final schema-13 shape; a copy without --migrate keeps the shape of its source.
                if (verifyRollups) StorageRollupVerification.Verify(staged, targetVersion, preRelease: targetVersion == 12 && !options.Migrate && !sourceShape12);
                if (rollupUpgrade) StorageRollupVerification.VerifyAddedSequence(staged, addedBookkeepingTables.Length != 0);
                if (options.Migrate)
                {
                    if (StorageSafety.Metadata(staged, "message_hash_algorithm") != "fnv1a64-utf8-v1")
                        throw new StorageFailure("Hash algorithm metadata verification failed; no destination was published.");
                    staged.CreateFunction<string, long?>("exl_msg_hash", Store.MessageHash, isDeterministic: true);
                    foreach (string table in new[] { "message_event", "smtp_transaction" })
                    {
                        using var check = staged.CreateCommand();
                        check.CommandText = "SELECT count(*) FROM " + table + " WHERE msg_hash IS NOT exl_msg_hash(message_id);";
                        if (Convert.ToInt64(check.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
                            throw new StorageFailure("Hash backfill verification failed; no destination was published.");
                    }
                }
                Phase("logicalVerification");
                StorageAudit afterAudit = await StorageAuditTool.RunAsync(finalStage, options.SqliteTool);
                if (afterAudit.WalBytes != 0) throw new StorageFailure("Staged WAL is not empty; refusing to publish an incomplete standalone database.");
                Phase("stagedAudit");
                var sourceAfter = StorageFingerprint.Compute(sourceDb, baseline, sourceComparison);
                StorageFingerprint.Compare(before, sourceAfter, sourceComparison);
                source.VerifyUnchanged();
                stagedGuard.VerifyUnchanged();
                Phase("sourceUnchangedVerification");
                if (vacuum is not null)
                {
                    foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
                    {
                        string oldStage = stage + suffix;
                        if (StorageSafety.Exists(oldStage)) File.Delete(oldStage);
                        owned.Remove(oldStage);
                    }
                }
                var report = new {
                    success = true, version = StorageCli.Version, operation = "copy",
                    actions = new { migrate = options.Migrate, repack = options.Repack, vacuum = options.Vacuum },
                    sourceUnchanged = true, repackedCells = repacked, requiredFreeBytes = required, vacuumCapacity,
                    verification = new {
                        algorithm = "SHA-256 typed length-prefixed normalized logical rows v1",
                        exclusions = (hashUpgrade ? new[] { "added msg_hash only" } : Array.Empty<string>())
                            .Concat(excludedMetadata.Select(key => "metadata." + key))
                            .Concat(rollupUpgrade ? new[] { "added sqlite_sequence row for message_rollup only (validated against MAX(id))" } : Array.Empty<string>())
                            .Concat(fieldsUpgrade ? new[] { "added source_fields table and source_file.fields_id column only (source_file.fields is compared as its logical dictionary text)" } : Array.Empty<string>())
                            .Concat(clientsUpgrade ? new[] { "added message_rollup_value, smtp_client_value, smtp_client, smtp_client_hour, smtp_client_pending and smtp_client_dirty tables and smtp_transaction.client_id column only",
                                "ix_smtp_latest dropped (not data); an existing message_rollup is compared through its decoded rows (kind, status, direction, servers and events dictionary codes decoded, first_ms/last_ms through COALESCE of the member bounds)" } : Array.Empty<string>())
                            .Concat(rulesUpgrade ? new[] { "message_rollup status, recipients, recipient_count, delivered, failed and events of tracking identities (kind 0) are recomputed by the schema-13 rules and verified by exact recomputation, not by equality with the source; sqlite_sequence.seq of message_rollup may advance (verified >= source and >= MAX(id))" } : Array.Empty<string>())
                            .Concat(rollupShapeUpgrade ? new[] { sourceTracked12
                                ? "ix_rollup_last and ix_rollup_status_last rebuilt with direction and servers; ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success added"
                                : sourceCovering12
                                ? "ix_rollup_last and ix_rollup_status_last rebuilt with events_count, kind, direction and servers; ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success added"
                                : "ix_rollup_last, ix_rollup_status_last and ix_session_time rebuilt as covering indexes; ix_msg_noid_flow, ix_event_resolution and ix_usage_day_success added; span-bound metadata and triggers added",
                                "message_rollup status, recipients, recipient_count, delivered, failed and events of kind 0 are verified by exact recomputation, not by equality with the source (an SMTP-only identity with a Message-ID that was sent gets the status Sent (SMTP)); sqlite_sequence.seq of message_rollup may advance (verified >= source and >= MAX(id)); message_rollup_value rows above the source maximum " +
                                valueMaxId!.Value.ToString(CultureInfo.InvariantCulture) + " may be added; no row of any other table changes" } : Array.Empty<string>())
                            .Concat(valuePreserved ? new[] { "message_rollup_value rows added by the schema-13 reconciliation (ids above the source maximum " + valueMaxId!.Value.ToString(CultureInfo.InvariantCulture) + ") only; every source row is compared by id and text" } : Array.Empty<string>())
                            .Concat(mailFlowUpgrade ? new[] { "added mail_flow_hour and mail_flow_dirty tables and their six triggers only (derived from the copied tracking events and SMTP transactions)" } : Array.Empty<string>())
                            .Concat(identityAdded ? new[] { "added identity_map table and its index only (empty, verified COUNT(*) = 0)" } : Array.Empty<string>())
                            .Concat(authUpgrade ? new[] { sourceStep3
                                ? "access_client rebuilt with the key column auth_type (every copied row has ''); client_session.auth_modes added (NULL); no row of any other table changes"
                                : "access_client rebuilt with the key column auth_type (every copied row has ''); client_session.auth_modes added (NULL)" } : Array.Empty<string>()).ToArray(),
                        fieldsDictionary = new {
                            applicable = fieldsUpgrade, table = StorageRollupVerification.SourceFieldsTable, column = "fields_id",
                            contract = fieldsUpgrade ? "The '#Fields' text of every source_file row is compared byte for byte through the dictionary (COALESCE(source_fields.text, fields)); no row of any other table changes." : "No dictionary change."
                        },
                        smtpClients = new {
                            applicable = clientsUpgrade, tables = StorageRollupVerification.SmtpClientTables, column = "client_id",
                            contract = clientsUpgrade ? "client_id, the client dimension, the value dictionary and the hourly aggregates are derived from the copied SMTP transactions and verified equal to a full recomputation; no source row changes." : "No SMTP client change."
                        },
                        mailFlow = new {
                            applicable = verifyRollups && targetVersion >= 12 && (options.Migrate || sourceShape12 || sourceStep3), tables = StorageRollupVerification.MailFlowTables,
                            // recomputation: every hour and server of mail_flow_hour is compared both ways with the grouping of the rows, and the queue is empty.
                            method = "recomputation", added = mailFlowUpgrade,
                            contract = mailFlowUpgrade ? "mail_flow_hour is derived from the copied tracking events and SMTP transactions and verified equal to a full recomputation; no source row changes." :
                                "mail_flow_hour of the copy verified equal to a full recomputation from its rows."
                        },
                        derivedRollups = new {
                            applicable = verifyRollups, schemaVersion = verifyRollups ? targetVersion.ToString(CultureInfo.InvariantCulture) : null,
                            tables = verifyRollups ? StorageRollupVerification.Tables : [],
                            newlyAddedTables = rollupUpgrade ? StorageRollupVerification.Tables : [],
                            newlyAddedBookkeepingTables = addedBookkeepingTables, validated = verifyRollups,
                            dirtyQueueEmpty = verifyRollups, baselineTablesPreserved = sourceVersion >= 8,
                            rulesVersion = verifyRollups ? (targetVersion >= 13 ? "schema-13 recipient rules (engine, with the stored rules of the external status)" : targetVersion == 12 ? "schema-12 recipient rules (engine)" : "schema 8 to 11 recipient rules (frozen in the host)") : null,
                            // true: the per-identity statements were prepared once per pass and bound again for every identity.
                            preparedStatements = StorageRollupVerification.CachedReads,
                            // merge-scan: the source tables and the rollup were each read once in identity order; per-identity: point reads per identity.
                            method = StorageRollupVerification.Method,
                            contract = "Exact schema-" + targetVersion.ToString(CultureInfo.InvariantCulture) + " derived objects, empty dirty queue and exact raw-message-ID rollup consistency; read-only verification. Every pre-existing derived table remains in the baseline logical fingerprint."
                        },
                        rollupRules = new {
                            applicable = rollupRecomputed,
                            maskedColumns = rollupRecomputed ? new[] { "status", "recipients", "recipient_count", "delivered", "failed", "events" } : [],
                            maskedKinds = rollupRecomputed ? new[] { 0 } : [],
                            valueDictionaryMaxSourceId = valueMaxId, sequenceBefore, sequenceAfter
                        },
                        sourceMainSha256 = source.MainSha256, sourceWalSha256 = source.WalSha256,
                        destinationSha256 = stagedGuard.MainSha256, before, after,
                        note = "Cryptographic verification is strong evidence, not mathematical proof. All baseline columns, explicit keys and offsets are compared with strict SQLite types. Packed normalization is limited to approved transcript, step and display-text slots; other BLOBs stay typed bytes. Hidden rowid is ordering only; a changed normalized order fails closed."
                    },
                    before = beforeAudit, after = afterAudit, measurements, phases
                };
                // Both publications are no-overwrite moves. A race on the evidence path
                // after copy publication remains an explicit failure, never a success.
                string reportStage = output + "." + Guid.NewGuid().ToString("N") + ".building";
                Reserve(reportStage, owned);
                await SerializeFile(reportStage, report);
                staged.Dispose();
                StorageSafety.NewFile(destination, options.Database);
                StorageSafety.NewFile(output, options.Database, destination);
                File.Move(finalStage, destination);
                owned.Remove(finalStage);
                published = true;
                File.Move(reportStage, output);
                owned.Remove(reportStage);
                return report;
            }
        }
        catch (Exception error)
        {
            string reason = error is StorageFailure ? error.Message : StorageCli.Describe(error);
            if (published) reason += " A verified private copy was retained at the requested destination, but its report could not be committed; treat this run as failed.";
            throw new StorageFailure(reason);
        }
        finally
        {
            var failures = new List<string>();
            foreach (string file in owned.Reverse())
            {
                try { if (StorageSafety.Exists(file)) File.Delete(file); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failures.Add(Path.GetFileName(file)); }
            }
            if (failures.Count > 0)
                throw new StorageFailure("Private maintenance partials could not be removed. Inspect the selected destination/output folders; this run failed cleanup even if a verified copy/report was already published.");
        }
    }

    private static long Scalar(SqliteConnection db, string sql)
    {
        using var command = db.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }
    /// <summary>sqlite_sequence.seq of message_rollup, null when the database has no such row.</summary>
    private static long? RollupSequence(SqliteConnection db)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='sqlite_sequence';";
        if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) == 0) return null;
        command.CommandText = "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';";
        return command.ExecuteScalar() is object value and not DBNull ? Convert.ToInt64(value, CultureInfo.InvariantCulture) : null;
    }

    private static void Reserve(string path, HashSet<string> owned)
    {
        foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
            if (StorageSafety.Exists(path + suffix)) throw new StorageFailure("A generated private staging path already exists; no existing file was replaced.");
        using (new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        owned.Add(path);
        foreach (string suffix in new[] { "-wal", "-shm", "-journal" }) owned.Add(path + suffix);
    }
    private static async Task SerializeFile(string path, object value)
    {
        await using var stream = new FileStream(path, FileMode.Truncate, FileAccess.Write, FileShare.None);
        await JsonSerializer.SerializeAsync(stream, value, JsonOptions);
        await stream.FlushAsync();
        stream.Flush(flushToDisk: true);
    }
    private static async Task WriteNewReport(string output, object value)
    {
        string partial = output + "." + Guid.NewGuid().ToString("N") + ".building";
        bool created = false;
        try
        {
            using (new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            created = true;
            await SerializeFile(partial, value);
            File.Move(partial, output);
            created = false;
        }
        finally { if (created) File.Delete(partial); }
    }
}
