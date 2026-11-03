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
    public sealed class ServeRollupVerification
    {
        public bool Verified { get; internal set; }
        public int SchemaVersion { get; internal set; }
        public long RowsVerified { get; internal set; }
        public long TrackingIdentities { get; internal set; }
        public long SmtpOnlyIdentities { get; internal set; }
        public long MissingMessageIdSmtpIdentities { get; internal set; }
        public long SourceHashGroupsVerified { get; internal set; }
        public bool SourceHashesVerified { get; internal set; }
        public bool SchemaObjectsVerified { get; internal set; }
        /// <summary>Schema 11: the SMTP client structures equal a full recomputation from the transactions (see VerifySmtpClientsCore).</summary>
        public bool SmtpClientsVerified { get; internal set; }
        public long SmtpClientRows { get; internal set; }
        public long SmtpClientHourRows { get; internal set; }
        /// <summary>Schema 12: mail_flow_hour equals a full recomputation from the tracking events and SMTP transactions (see VerifyMailFlowCore).</summary>
        public bool MailFlowVerified { get; internal set; }
        public long MailFlowRows { get; internal set; }
        public bool ReadOnlySnapshot { get; internal set; }
        public bool CallerSnapshotUsed { get; internal set; }
        public int CacheKilobytes { get; internal set; }
        public double ElapsedMilliseconds { get; internal set; }
        /// <summary>Deadline the run had: explicit (VerifyServeRollupsWithDeadline) or the 24 h cap of a default run.</summary>
        public int DeadlineSeconds { get; internal set; }
        public bool DeadlineExplicit { get; internal set; }
        /// <summary>Seconds the run is expected to need at most: 3 x FileBytes read at 20 MB/s, 300 s to 24 h (reported; not a deadline).</summary>
        public int EstimatedSeconds { get; internal set; }
        /// <summary>page_count x page_size of the verified snapshot.</summary>
        public long FileBytes { get; internal set; }
        /// <summary>A run that makes no progress (no SQLite step, no identity) for this long is stopped as stalled.</summary>
        public int StallSeconds { get; internal set; }
        /// <summary>Identities verified per second by the per-identity checks (RowsVerified over the time of that loop).</summary>
        public long IdentitiesPerSecond { get; internal set; }
        /// <summary>"merge-scan" (the source tables and the rollup are each read once, in identity order) or "per-identity" (the reference path).</summary>
        public string Method { get; internal set; }
        /// <summary>Source rows read by the merge scan (tracking events plus SMTP transactions); 0 for the per-identity path.</summary>
        public long SourceRowsScanned { get; internal set; }
        /// <summary>Pages the identity verification (merge scan or per-identity reads, before the table-wide checks) fetched outside the page cache of its connection (SQLITE_DBSTATUS_CACHE_MISS): its I/O pattern, whatever the disk.</summary>
        public long CacheMissPages { get; internal set; }
        /// <summary>Folder of the sort files of the merge scan (the folder of the database) and its free bytes before the run (-1 when unknown).</summary>
        public string TempDirectory { get; internal set; }
        public long TempFreeBytes { get; internal set; }
        /// <summary>Largest total size of the sort files (etilqs_* in TempDirectory) seen during the run, sampled by the stall watchdog every 5 s at most.</summary>
        public long SortPeakBytes { get; internal set; }
        /// <summary>Longest time between two heartbeats of the run (a SQLite progress step or a verified identity): the margin left to StallSeconds.</summary>
        public long MaxProgressGapMs { get; internal set; }
    }

    public sealed partial class Store
    {
        internal const int MinVerificationDeadlineSeconds = 300, MaxVerificationDeadlineSeconds = 86400;
        /// <summary>
        /// A verification that makes no progress for StallSeconds (no SQLite step: the progress handler runs every 1000 virtual-machine steps, also while
        /// sorting; no verified identity) is stopped: a healthy run on a slow disk keeps stepping, a dead disk or a hung file does not.
        /// </summary>
        internal const int StallSeconds = 600;
        internal static int VerificationStallSeconds = StallSeconds;
        /// <summary>Estimate of a run: EstimateMargin x the file read at EstimateBytesPerSecond (a sequential rate any disk sustains).</summary>
        internal const int EstimateBytesPerSecond = 20000000, EstimateMargin = 3;
        /// <summary>Test hook, called with the count of verified identities after each identity.</summary>
        internal static Action<long> VerificationIdentityHook;

        /// <summary>Seconds a verification of a file of fileBytes is expected to need at most: 3 x bytes at 20 MB/s, at least 300 s and at most 24 h.</summary>
        internal static int VerificationEstimateSeconds(long fileBytes)
        {
            double seconds = Math.Ceiling(Math.Max(0L, fileBytes) * (double)EstimateMargin / EstimateBytesPerSecond);
            return (int)Math.Max(MinVerificationDeadlineSeconds, Math.Min(MaxVerificationDeadlineSeconds, seconds));
        }

        /// <summary>"deadline of N s (how it was set; the estimate)", shared by the timeout messages of both verifications.</summary>
        static string VerificationDeadlineText(int seconds, bool explicitDeadline, int estimatedSeconds, long fileBytes)
        {
            var c = CultureInfo.InvariantCulture;
            return "deadline of " + seconds.ToString("N0", c) + " s (" + (explicitDeadline ? "explicit deadline" : "24 h cap") + "; estimated " +
                estimatedSeconds.ToString("N0", c) + " s from " + (fileBytes / 1e9).ToString("N1", c) + " GB at " + (EstimateBytesPerSecond / 1e6).ToString("N0", c) + " MB/s)";
        }

        internal static string VerificationTimeoutMessage(int seconds, bool explicitDeadline, long verified, double elapsedSeconds, int estimatedSeconds, long fileBytes)
        {
            var c = CultureInfo.InvariantCulture;
            double rate = elapsedSeconds > 0 ? verified / elapsedSeconds : 0;
            return "Serve rollup verification exceeded its " + VerificationDeadlineText(seconds, explicitDeadline, estimatedSeconds, fileBytes) +
                " after verifying " + verified.ToString("N0", c) + " identities in " + elapsedSeconds.ToString("N0", c) + " s (" + rate.ToString("N0", c) +
                " identities/s); no verification result was published and no database changes were made. Run it when no collection is running, or pass a longer deadline to VerifyServeRollupsWithDeadline.";
        }

        internal static string VerificationStallMessage(string what, int stallSeconds, long verified, double elapsedSeconds)
        {
            var c = CultureInfo.InvariantCulture;
            return what + " made no progress for " + stallSeconds.ToString("N0", c) + " s (last progress after " + verified.ToString("N0", c) + " identities, " +
                elapsedSeconds.ToString("N0", c) + " s into the run); the disk or the database file is not responding. No verification result was published and no database changes were made.";
        }

        static void CheckVerificationDeadline(int timeoutSeconds)
        {
            if (timeoutSeconds < 1 || timeoutSeconds > MaxVerificationDeadlineSeconds) throw new ArgumentOutOfRangeException(nameof(timeoutSeconds), timeoutSeconds, "The verification deadline must be 1 to 86400 seconds.");
        }

        /// <summary>
        /// Stops a verification that makes no progress for StallSeconds: a timer compares the last heartbeat of the read connection (its progress handler
        /// and the verified identities) with the clock and cancels the run's deadline (which interrupts SQLite) when it is older.
        /// </summary>
        sealed class VerificationWatch : IDisposable
        {
            readonly Timer _timer;
            readonly long _limitTicks;
            readonly ServeRead _read;
            int _stalled;
            string _sortDirectory;
            long _sortPeakBytes;
            internal VerificationWatch(ServeRead read, CancellationTokenSource deadline, int stallSeconds)
            {
                _read = read;
                _limitTicks = stallSeconds * Stopwatch.Frequency;
                read.Progress();
                read.ResetProgressGap();
                int period = Math.Max(100, Math.Min(stallSeconds * 250, 5000));
                _timer = new Timer(_ =>
                {
                    SampleSortFiles();
                    if (Stopwatch.GetTimestamp() - read.LastProgress() <= _limitTicks) return;
                    Interlocked.Exchange(ref _stalled, 1);
                    try { deadline.Cancel(); } catch (ObjectDisposedException) { }
                }, null, period, period);
            }
            internal bool Stalled { get { return Volatile.Read(ref _stalled) == 1; } }
            /// <summary>The folder whose etilqs_* sort files the timer adds up (null: none is sampled).</summary>
            internal string SortDirectory { set { Volatile.Write(ref _sortDirectory, value); } }
            internal long SortPeakBytes { get { return Interlocked.Read(ref _sortPeakBytes); } }
            internal long MaxProgressGapMs { get { return _read.MaxProgressGapTicks() * 1000 / Stopwatch.Frequency; } }
            /// <summary>
            /// Adds up the sizes of the sort files now and keeps the largest total. Each file is asked for its own size: a directory listing can report
            /// a stale size for a file that is still open.
            /// </summary>
            internal void SampleSortFiles()
            {
                string directory = Volatile.Read(ref _sortDirectory);
                if (directory == null) return;
                long total = 0;
                try
                {
                    foreach (string file in Directory.EnumerateFiles(directory, "etilqs_*"))
                        try { total += new FileInfo(file).Length; } catch (IOException) { } catch (UnauthorizedAccessException) { }
                }
                catch (IOException) { return; }
                catch (UnauthorizedAccessException) { return; }
                long peak;
                while (total > (peak = Interlocked.Read(ref _sortPeakBytes)) && Interlocked.CompareExchange(ref _sortPeakBytes, total, peak) != peak) { }
            }
            public void Dispose() { using (var done = new ManualResetEvent(false)) { if (_timer.Dispose(done)) done.WaitOne(); } }
        }

        /// <summary>
        /// Explicit maintenance validation of committed schema 13, never called by Serve or collection.
        /// The derived rows are recomputed in a read-only snapshot by a merge scan: the tracking events and the SMTP transactions are each read once,
        /// sorted by their BINARY Message-ID, and compared with message_rollup read in the same order (RollupMergeScan); every row is checked on the way.
        /// The sort files go to the folder of the database (about 15 % of its size must be free there). A default run has no row budget: it is stopped
        /// when it makes no progress for 600 s, and at 24 h at most (VerifyServeRollupsWithDeadline sets an explicit deadline, which wins when shorter);
        /// the result reports the estimate from the file size. Memory retains only the current identity's recipient/status summary, not its event history.
        /// This does not replace baseline source fingerprints or schema/trigger inventory comparison.
        /// The snapshot is one read transaction for the whole run: in WAL mode no checkpoint passes it, so what a collection
        /// commits meanwhile stays in the -wal file until the verification ends. Run it when no collection is running (stop the
        /// scheduled task, or between two collections), or on a copy (VerifyServeRollups(SqliteConnection) on a VACUUM INTO copy).
        /// </summary>
        public ServeRollupVerification VerifyServeRollups()
        {
            return VerifyCommittedServeRollups(0, CancellationToken.None);
        }

        /// <summary>
        /// Explicit maintenance validation of the SMTP client structures alone (also part of VerifyServeRollups): every client_id, the client dimension and the hourly
        /// buckets equal a recomputation from the SMTP transactions, and no work is queued. Committed data in a read-only snapshot, never repairs. Deadline rule of
        /// VerifyServeRollups: stopped after 600 s without progress, at 24 h at most; the estimate from the file size is reported.
        /// </summary>
        public SmtpClientVerification VerifySmtpClients()
        {
            if (_reportSnapshot != null) throw new InvalidOperationException("Verify committed SMTP clients outside an active report snapshot.");
            using (var c = Command("SELECT 1;")) c.ExecuteScalar();
            var clock = Stopwatch.StartNew();
            int stall = VerificationStallSeconds, estimate = 0; long bytes = 0;
            using (var deadline = new CancellationTokenSource())
            {
                VerificationWatch watch = null;
                try
                {
                    deadline.CancelAfter(TimeSpan.FromSeconds(MaxVerificationDeadlineSeconds));
                    using (var read = new ServeRead(new ServeOptions { DatabasePath = FilePath, MmapMB = 0 }, deadline.Token))
                    {
                        watch = new VerificationWatch(read, deadline, stall);
                        read.Ready(requireShape: false);
                        VerifyServeSchema(read);
                        bytes = read.FileBytes();
                        estimate = VerificationEstimateSeconds(bytes);
                        var result = VerifySmtpClientsCore(sql => read.Command(sql), () => { read.Progress(); deadline.Token.ThrowIfCancellationRequested(); });
                        result.DeadlineSeconds = MaxVerificationDeadlineSeconds; result.EstimatedSeconds = estimate; result.FileBytes = bytes; result.StallSeconds = stall;
                        return result;
                    }
                }
                catch (Exception e) when ((e is SqliteException || e is OperationCanceledException) && deadline.IsCancellationRequested)
                {
                    var ci = CultureInfo.InvariantCulture;
                    if (watch != null && watch.Stalled) throw new TimeoutException(VerificationStallMessage("SMTP client verification", stall, 0, clock.Elapsed.TotalSeconds), e);
                    throw new TimeoutException("SMTP client verification exceeded its " + VerificationDeadlineText(MaxVerificationDeadlineSeconds, false, estimate, bytes) + " after " +
                        clock.Elapsed.TotalSeconds.ToString("N0", ci) + " s; no verification result was published and no database changes were made. Run it when no collection is running.", e);
                }
                finally { if (watch != null) watch.Dispose(); }
            }
        }

        public ServeRollupVerification VerifyServeRollupsWithDeadline(int timeoutSeconds, CancellationToken cancellationToken)
        {
            CheckVerificationDeadline(timeoutSeconds);
            return VerifyCommittedServeRollups(timeoutSeconds, cancellationToken);
        }

        ServeRollupVerification VerifyCommittedServeRollups(int timeoutSeconds, CancellationToken cancellationToken)
        {
            if (_reportSnapshot != null) throw new InvalidOperationException("Verify committed rollups outside an active report snapshot.");
            // An active caller transaction must not be mistaken for the committed database being verified.
            using (var c = Command("SELECT 1;")) c.ExecuteScalar();
            return VerifyServeRollupsFile(FilePath, timeoutSeconds, cancellationToken);
        }

        /// <summary>
        /// No Store constructor or migration. The supplied connection must have an open read-only main file.
        /// Verification opens its OWN bounded snapshot of that file; caller transactions, cancellation handlers,
        /// PRAGMAs and connection lifetime are untouched. Use an immutable/staged copy for fingerprint binding.
        /// Canonical hash/rollup DDL is checked; the caller still compares all other baseline schema and data.
        /// The deadline rule is the one of the Store entry point.
        /// </summary>
        public static ServeRollupVerification VerifyServeRollups(SqliteConnection db)
        {
            return VerifyServeRollupsFile(ReadOnlyDataSource(db), 0, CancellationToken.None);
        }

        public static ServeRollupVerification VerifyServeRollupsWithDeadline(SqliteConnection db, int timeoutSeconds, CancellationToken cancellationToken)
        {
            string path = ReadOnlyDataSource(db);
            CheckVerificationDeadline(timeoutSeconds);
            return VerifyServeRollupsFile(path, timeoutSeconds, cancellationToken);
        }

        static string ReadOnlyDataSource(SqliteConnection db)
        {
            if (db == null) throw new ArgumentNullException(nameof(db));
            if (db.State != System.Data.ConnectionState.Open || SQLitePCL.raw.sqlite3_db_readonly(db.Handle, "main") != 1)
                throw new InvalidOperationException("Supply an open read-only main database connection; the verifier never changes its mode.");
            return db.DataSource;
        }

        /// <summary>The merge scan (true, the default) or the per-identity recomputation (the reference path the tests compare with).</summary>
        internal static bool MergeVerification = true;
        /// <summary>Page cache of the verification connection: the external sort of the merge scan merges fewer runs with a larger cache.</summary>
        internal const int VerificationCacheKilobytes = 65536;
        /// <summary>Free space the sort files of the merge scan need next to the database: 15 % of the file, at least 1 GB.</summary>
        internal const double SortSpaceShare = 0.15;
        internal const long MinSortSpaceBytes = 1L << 30;

        /// <summary>
        /// The folder of the database receives the sort files (sqlite3_temp_directory, process-wide, restored after the run; when the pragma is refused,
        /// the TMP variable of the process, which also moves Path.GetTempPath). Both settings are process-wide and must not change while another
        /// connection of the process has temporary files open: the verification runs alone in its process (Serve never calls it, the storage passes are
        /// sequential). The folder must have SortSpaceShare of the file free. Returns the restore action.
        /// </summary>
        static Action UseSortDirectory(ServeRead read, string path, long fileBytes, ServeRollupVerification result)
        {
            string directory = Path.GetDirectoryName(Path.GetFullPath(path));
            result.TempDirectory = directory; result.TempFreeBytes = -1;
            try { result.TempFreeBytes = new DriveInfo(Path.GetPathRoot(directory)).AvailableFreeSpace; } catch (ArgumentException) { } catch (IOException) { }
            long needed = Math.Max(MinSortSpaceBytes, (long)Math.Ceiling(fileBytes * SortSpaceShare));
            if (result.TempFreeBytes >= 0 && result.TempFreeBytes < needed)
            {
                var c = CultureInfo.InvariantCulture;
                throw new IOException("Serve rollup verification needs about 15 % of the database size free next to the database for its sort files (" +
                    (needed / 1e9).ToString("N1", c) + " GB needed, " + (result.TempFreeBytes / 1e9).ToString("N1", c) + " GB free in " + directory +
                    "); free space or verify a copy on another volume.");
            }
            if (read.SetTempDirectory(directory)) return () => read.SetTempDirectory("");
            string previous = Environment.GetEnvironmentVariable("TMP");
            Environment.SetEnvironmentVariable("TMP", directory);
            return () => Environment.SetEnvironmentVariable("TMP", previous);
        }

        // timeoutSeconds 0: a default run (24 h cap). Either way the run is stopped when it makes no progress for StallSeconds.
        static ServeRollupVerification VerifyServeRollupsFile(string path, int timeoutSeconds, CancellationToken cancellationToken)
        {
            var clock = Stopwatch.StartNew();
            bool explicitDeadline = timeoutSeconds > 0;
            int stall = VerificationStallSeconds;
            var result = new ServeRollupVerification { SchemaVersion = 13, ReadOnlySnapshot = true, CacheKilobytes = MergeVerification ? VerificationCacheKilobytes : 16384,
                DeadlineExplicit = explicitDeadline, DeadlineSeconds = explicitDeadline ? timeoutSeconds : MaxVerificationDeadlineSeconds, StallSeconds = stall,
                Method = MergeVerification ? "merge-scan" : "per-identity" };
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(result.DeadlineSeconds));
                VerificationWatch watch = null;
                try
                {
                    using (var read = new ServeRead(new ServeOptions { DatabasePath = path, MmapMB = 0, CacheKilobytes = result.CacheKilobytes }, deadline.Token))
                    {
                        watch = new VerificationWatch(read, deadline, stall);
                        read.Ready(requireShape: false);
                        VerifyServeSchema(read);
                        result.SchemaObjectsVerified = true;
                        result.FileBytes = read.FileBytes();
                        result.EstimatedSeconds = VerificationEstimateSeconds(result.FileBytes);
                        var identities = Stopwatch.StartNew();
                        Action progress = () =>
                        {
                            read.Progress();
                            if (VerificationIdentityHook != null) VerificationIdentityHook(result.RowsVerified);
                            deadline.Token.ThrowIfCancellationRequested();
                        };
                        // The rows are recomputed with the rules they were written with (the stored rules of the external status).
                        var rules = MailFlowRules.Read(read.Command);
                        using (var reads = new VerificationReads(read, CachedVerificationReads))
                        {
                            if (MergeVerification)
                            {
                                Action restore = UseSortDirectory(read, path, result.FileBytes, result);
                                watch.SortDirectory = result.TempDirectory;
                                try { VerifyMessageRollupsMerged(read, result, progress, rules); }
                                finally { watch.SampleSortFiles(); watch.SortDirectory = null; restore(); }
                            }
                            else VerifyMessageRollupsPerIdentity(read, reads, result, progress, rules);
                            using (var c = read.Command("SELECT id FROM smtp_transaction WHERE message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted') ORDER BY id;"))
                            using (var r = c.ExecuteReader())
                            while (r.Read())
                            {
                                string identity = r.GetInt64(0).ToString(CultureInfo.InvariantCulture);
                                reads.Identity("smtp", identity, DBNull.Value);
                                VerifyServeRollupIdentity(reads, "smtp", identity, DBNull.Value, rules);
                                result.MissingMessageIdSmtpIdentities++;
                                result.RowsVerified++;
                                progress();
                            }
                        }
                        // The I/O of the identity verification (the checks below are the same on both paths).
                        result.CacheMissPages = read.CacheMissPages();
                        double loopSeconds = identities.Elapsed.TotalSeconds;
                        result.IdentitiesPerSecond = loopSeconds > 0 ? (long)Math.Round(result.RowsVerified / loopSeconds) : result.RowsVerified;
                        long rows, maxId;
                        using (var c = read.Command("SELECT COUNT(*),COALESCE(MAX(id),0) FROM message_rollup;"))
                        using (var r = c.ExecuteReader()) { r.Read(); rows = r.GetInt64(0); maxId = r.GetInt64(1); }
                        if (rows != result.RowsVerified) throw new InvalidDataException("InvalidServeRollup: extra or missing derived identities.");
                        // The span bounds Serve narrows its index ranges with cover every stored row (two covering index scans).
                        foreach (var bound in new[] { new[] { "rollup_max_span_ms", RollupSpanSql, "a stored journey span" }, new[] { "session_max_span_ms", SessionSpanSql, "a stored client session span" } })
                            using (var c = read.Command("SELECT (SELECT CAST(value AS INTEGER) FROM metadata WHERE key='" + bound[0] + "')>=(" + bound[1] + ");"))
                                if (ServeRead.Long(c.ExecuteScalar()) != 1) throw new InvalidDataException("InvalidServeRollup: " + bound[0] + " is lower than " + bound[2] + ".");
                        // Every code a row references exists in the dictionary (a dangling nullable code would otherwise read back as NULL).
                        using (var c = read.Command("SELECT 1 FROM message_rollup r WHERE NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.status)" +
                            " OR (r.direction IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.direction))" +
                            " OR (r.servers IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.servers))" +
                            " OR (r.events IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.events)) LIMIT 1;"))
                            if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidServeRollup: a row references a code that is not in message_rollup_value.");
                        using (var c = read.Command("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';"))
                        using (var r = c.ExecuteReader())
                        {
                            if (!r.Read())
                            {
                                if (rows != 0) throw new InvalidDataException("InvalidServeRollupSequence: missing stable-ID sequence.");
                            }
                            else if (!(r.GetValue(0) is long) || r.GetInt64(0) < maxId || r.Read())
                                throw new InvalidDataException("InvalidServeRollupSequence: invalid or duplicate stable-ID sequence.");
                        }
                        // Schema 11: the SMTP client dimension, the client of every transaction and the hourly buckets, recomputed from the rows.
                        var clients = VerifySmtpClientsCore(sql => read.Command(sql), () => { read.Progress(); deadline.Token.ThrowIfCancellationRequested(); });
                        result.SmtpClientsVerified = clients.Verified; result.SmtpClientRows = clients.Clients; result.SmtpClientHourRows = clients.HourRows;
                        // Schema 12: the mail flow per hour, recomputed from the tracking events and the SMTP transactions.
                        result.MailFlowRows = VerifyMailFlowCore(sql => read.Command(sql), () => { read.Progress(); deadline.Token.ThrowIfCancellationRequested(); });
                        result.MailFlowVerified = true;
                        deadline.Token.ThrowIfCancellationRequested();
                        result.SourceHashesVerified = true; result.Verified = true;
                        result.SortPeakBytes = watch.SortPeakBytes; result.MaxProgressGapMs = watch.MaxProgressGapMs;
                        result.ElapsedMilliseconds = clock.Elapsed.TotalMilliseconds;
                        return result;
                    }
                }
                catch (Exception e) when ((e is SqliteException || e is OperationCanceledException) && deadline.IsCancellationRequested)
                {
                    if (watch != null && watch.Stalled)
                        throw new TimeoutException(VerificationStallMessage("Serve rollup verification", stall, result.RowsVerified, clock.Elapsed.TotalSeconds), e);
                    cancellationToken.ThrowIfCancellationRequested();
                    throw new TimeoutException(VerificationTimeoutMessage(result.DeadlineSeconds, explicitDeadline, result.RowsVerified, clock.Elapsed.TotalSeconds,
                        result.EstimatedSeconds, result.FileBytes), e);
                }
                finally { if (watch != null) watch.Dispose(); }
            }
        }

        /// <summary>The message identities (kind 0) by the merge scan: events, SMTP transactions and rollup rows each read once in BINARY identity order.</summary>
        static void VerifyMessageRollupsMerged(ServeRead read, ServeRollupVerification result, Action progress, MailFlowRules rules)
        {
            var scan = new RollupMergeScan(read.Command, new ReportBuilder.EngineRollupRules { MailFlow = rules }, (failure, table) =>
                failure == RollupMergeScan.Failure.NullHash ? new InvalidDataException("InvalidSourceHash: NULL message identity has a non-NULL hash in " + table + ".") :
                failure == RollupMergeScan.Failure.Hash ? new InvalidDataException("InvalidSourceHash: noncanonical message identity/hash in " + table + ".") :
                failure == RollupMergeScan.Failure.Order ? new InvalidDataException("InvalidSourceHash: message identities of " + table + " are not in BINARY order (invalid text encoding).") :
                failure == RollupMergeScan.Failure.Extra ? new InvalidDataException("InvalidServeRollup: extra derived identity.") :
                failure == RollupMergeScan.Failure.Missing ? new InvalidDataException("InvalidServeRollup: missing derived identity.") :
                (Exception)new InvalidDataException("InvalidServeRollup: duplicate exact derived identity."),
                () => { result.RowsVerified++; progress(); });
            using (var c = read.Command(RollupMergeScan.StoredSql))
            using (var stored = c.ExecuteReader())
                scan.Run(stored, (expected, r) =>
                {
                    if (!(r.GetValue(0) is long) || r.GetInt64(0) < 1) throw new InvalidDataException("InvalidServeRollup: URL identity must be a positive INTEGER.");
                    CompareRollupRow(ExpectedRollupRow("message", expected.Name, expected.Hash, expected.Row, expected.EventCount, expected.SmtpFirst, expected.SmtpLast), r);
                });
            result.TrackingIdentities = scan.TrackingIdentities; result.SmtpOnlyIdentities = scan.SmtpOnlyIdentities;
            result.SourceHashGroupsVerified = scan.EventGroups + scan.SmtpGroups; result.SourceRowsScanned = scan.SourceRows;
        }

        /// <summary>The message identities (kind 0) one at a time (the reference path): identity list from each source table, then point reads per identity.</summary>
        static void VerifyMessageRollupsPerIdentity(ServeRead read, VerificationReads reads, ServeRollupVerification result, Action progress, MailFlowRules rules)
        {
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            {
                using (var c = read.Command("SELECT 1 FROM " + table + " WHERE message_id IS NULL AND msg_hash IS NOT NULL LIMIT 1;"))
                    if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidSourceHash: NULL message identity has a non-NULL hash in " + table + ".");
                // The identity indexes hold (msg_hash,time_ms) only (schema 10): the distinct exact identities come from one sequential scan of the
                // table grouped by the BINARY Message-ID, with one sorter spilled to temporary files by ServeRead. NOT INDEXED keeps the planner from
                // walking the hash index instead, which would read one table row at random per index entry.
                using (var c = read.Command("SELECT msg_hash,message_id FROM " + table + " NOT INDEXED" +
                    " WHERE message_id IS NOT NULL GROUP BY msg_hash,message_id COLLATE BINARY ORDER BY msg_hash,message_id COLLATE BINARY;"))
                using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    object hash = r.GetValue(0), rawIdentity = r.GetValue(1);
                    string identity = rawIdentity as string;
                    if (identity == null || !(hash is long) || (long)hash != MessageHash(identity))
                        throw new InvalidDataException("InvalidSourceHash: noncanonical message identity/hash in " + table + ".");
                    result.SourceHashGroupsVerified++;
                    reads.Identity("message", identity, hash);
                    if (table == "smtp_transaction" && reads.Scalar("SELECT 1 FROM message_event WHERE msg_hash=@h AND message_id=@m COLLATE BINARY LIMIT 1;") != null) continue;
                    VerifyServeRollupIdentity(reads, "message", identity, hash, rules);
                    if (table == "message_event") result.TrackingIdentities++;
                    else result.SmtpOnlyIdentities++;
                    result.RowsVerified++;
                    progress();
                }
            }
        }

        /// <summary>
        /// Merge scan of the message identities (kind 0): the tracking events (EventsSql) and the SMTP transactions (SmtpSql) are each read once, sorted by
        /// their BINARY Message-ID (time_ms,id within one identity), and the stored rollup rows (StoredSql, the UNIQUE(kind,identity) index in the same
        /// order) are walked alongside. One identity is in memory at a time. Every source row is checked: a NULL Message-ID has a NULL hash, any other row
        /// the canonical hash of its Message-ID. The rows of an identity give the expected rollup row through the rules plug (tracking identities) or the
        /// SMTP-only row (rule-independent); a stored identity below the current one is extra, above it the current one is missing, the same one twice a
        /// duplicate. Also used by the storage verification (its own command factory, comparison and rules).
        /// </summary>
        internal sealed class RollupMergeScan
        {
            internal const string EventsSql = "SELECT message_id,msg_hash,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality,recipient_status,related_recipient,connector,server_host,server_ip" +
                " FROM message_event NOT INDEXED ORDER BY message_id COLLATE BINARY,time_ms,id;";
            internal const string SmtpSql = "SELECT message_id,msg_hash,time_ms,end_ms,server,mail_from,rcpts,status,direction FROM smtp_transaction NOT INDEXED ORDER BY message_id COLLATE BINARY,time_ms,id;";
            internal const string StoredSql = "SELECT r.id,r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count" +
                " FROM message_rollup r LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events" +
                " WHERE r.kind=0 ORDER BY r.identity COLLATE BINARY;";
            internal enum Failure { NullHash, Hash, Order, Extra, Missing, Duplicate }

            /// <summary>The source side of one identity: its summary row (18 slots), event count and the time bounds of its SMTP rows (null when none).</summary>
            internal sealed class Identity
            {
                public string Name; public object Hash; public object[] Row; public long EventCount; public long? SmtpFirst, SmtpLast; public bool Tracking;
            }

            sealed class Stream : IDisposable
            {
                readonly SqliteCommand _command; readonly string _table; readonly RollupMergeScan _scan;
                internal readonly SqliteDataReader Reader;
                internal bool Ok; internal string Id;
                internal Stream(RollupMergeScan scan, string sql, string table)
                {
                    _scan = scan; _table = table; _command = scan._command(sql); Reader = _command.ExecuteReader();
                }
                /// <summary>Moves to the next row with a Message-ID (rows without one sort first and are only checked for their NULL hash).</summary>
                internal void Next()
                {
                    while (true)
                    {
                        if (!Reader.Read()) { Ok = false; Id = null; return; }
                        _scan.SourceRows++;
                        object raw = Reader.GetValue(0), hash = Reader.GetValue(1);
                        if (raw is DBNull) { if (!(hash is DBNull)) throw _scan._fail(Failure.NullHash, _table); continue; }
                        string id = raw as string;
                        if (id == null || !(hash is long) || (long)hash != MessageHash(id)) throw _scan._fail(Failure.Hash, _table);
                        if (Id != null && !ReferenceEquals(Id, id) && CompareUtf8Binary(Id, id) > 0) throw _scan._fail(Failure.Order, _table);
                        Ok = true; Id = id; return;
                    }
                }
                public void Dispose() { Reader.Dispose(); _command.Dispose(); }
            }

            readonly Func<string, SqliteCommand> _command;
            readonly ReportBuilder.RollupRules _rules;
            readonly Func<Failure, string, Exception> _fail;
            readonly Action _identityDone;
            internal long TrackingIdentities, SmtpOnlyIdentities, EventGroups, SmtpGroups, SourceRows;

            /// <param name="identityDone">Called after each identity was compared (counters, heartbeat, deadline).</param>
            internal RollupMergeScan(Func<string, SqliteCommand> command, ReportBuilder.RollupRules rules, Func<Failure, string, Exception> fail, Action identityDone)
            {
                _command = command; _rules = rules; _fail = fail; _identityDone = identityDone;
            }

            static readonly IComparer<string> Binary = Comparer<string>.Create(CompareUtf8Binary);
            static readonly List<object[]> NoSteps = new List<object[]>(), NoTranscripts = new List<object[]>();

            static object[] SmtpProjection(SqliteDataReader r)
            {
                var row = new object[7];
                for (int i = 0; i < row.Length; i++) { object v = r.GetValue(i + 2); row[i] = v is DBNull ? null : v; }
                return row;
            }

            /// <param name="stored">The stored rows of the identities, in BINARY identity order, identity in column 2.</param>
            /// <param name="compare">Compares the expected values of an identity with the current stored row (throws on a difference).</param>
            internal void Run(SqliteDataReader stored, Action<Identity, SqliteDataReader> compare)
            {
                using (var events = new Stream(this, EventsSql, "message_event"))
                using (var smtp = new Stream(this, SmtpSql, "smtp_transaction"))
                {
                    events.Next(); smtp.Next();
                    bool storedOk = stored.Read();
                    string storedId = storedOk ? stored.GetString(2) : null;
                    var servers = new SortedSet<string>(Binary);
                    var current = new Identity();
                    while (events.Ok || smtp.Ok)
                    {
                        string id = !events.Ok ? smtp.Id : !smtp.Ok ? events.Id : CompareUtf8Binary(events.Id, smtp.Id) <= 0 ? events.Id : smtp.Id;
                        current.Name = id; current.Hash = MessageHash(id).Value; current.EventCount = 0; current.SmtpFirst = null; current.SmtpLast = null;
                        current.Tracking = events.Ok && string.Equals(events.Id, id, StringComparison.Ordinal);
                        if (current.Tracking)
                        {
                            EventGroups++; TrackingIdentities++;
                            _rules.Begin(id);
                            do { _rules.Event(events.Reader); current.EventCount++; events.Next(); }
                            while (events.Ok && string.Equals(events.Id, id, StringComparison.Ordinal));
                        }
                        else SmtpOnlyIdentities++;
                        long count = 0;
                        object[] first = null, last = null;
                        servers.Clear();
                        if (smtp.Ok && string.Equals(smtp.Id, id, StringComparison.Ordinal))
                        {
                            SmtpGroups++;
                            do
                            {
                                long time = smtp.Reader.GetInt64(2);
                                current.SmtpFirst = current.SmtpFirst.HasValue ? Math.Min(current.SmtpFirst.Value, time) : time;
                                current.SmtpLast = current.SmtpLast.HasValue ? Math.Max(current.SmtpLast.Value, time) : time;
                                count++;
                                if (!current.Tracking)
                                {
                                    last = SmtpProjection(smtp.Reader);
                                    if (first == null) first = last;
                                    servers.Add(ReportBuilder.ServeText(last[2]));
                                }
                                smtp.Next();
                            }
                            while (smtp.Ok && string.Equals(smtp.Id, id, StringComparison.Ordinal));
                        }
                        current.Row = current.Tracking ? _rules.Row(count) : ReportBuilder.SmtpOnlyRow("message", first, last, System.Linq.Enumerable.ToArray(servers), count, id, false, NoSteps, NoTranscripts, _rules.SentSmtpStatus);
                        if (storedOk && CompareUtf8Binary(storedId, id) < 0) throw _fail(Failure.Extra, "message_rollup");
                        if (!storedOk || CompareUtf8Binary(storedId, id) > 0) throw _fail(Failure.Missing, "message_rollup");
                        compare(current, stored);
                        storedOk = stored.Read();
                        storedId = storedOk ? stored.GetString(2) : null;
                        if (storedOk && string.Equals(storedId, id, StringComparison.Ordinal)) throw _fail(Failure.Duplicate, "message_rollup");
                        _identityDone();
                    }
                    if (storedOk) throw _fail(Failure.Extra, "message_rollup");
                }
            }

            /// <summary>Test seam: the extra/missing/duplicate decisions of Run for given source and stored identity lists (BINARY order), without SQL.</summary>
            internal static string Classify(string[] source, string[] stored)
            {
                int s = 0;
                for (int i = 0; i < source.Length; i++)
                {
                    if (s < stored.Length && CompareUtf8Binary(stored[s], source[i]) < 0) return "extra";
                    if (s >= stored.Length || CompareUtf8Binary(stored[s], source[i]) > 0) return "missing";
                    s++;
                    if (s < stored.Length && string.Equals(stored[s], source[i], StringComparison.Ordinal)) return "duplicate";
                }
                return s < stored.Length ? "extra" : "verified";
            }
        }

        static readonly string[] RollupColumns = { "kind", "identity", "msg_hash", "first_ms", "last_ms", "member_first_ms", "member_last_ms",
            "status", "sender", "recipients", "recipient_count", "delivered", "failed", "subject", "size_kb",
            "direction", "servers", "events", "events_count", "smtp_count" };

        /// <summary>
        /// The 20 stored values (kind .. smtp_count, schema 11/12: codes compared through their text) an identity must have, from its summary row,
        /// its event count and the time bounds of its SMTP rows: first_ms/last_ms are NULL exactly when they equal the member bounds.
        /// </summary>
        internal static object[] ExpectedRollupRow(string kind, string identity, object hash, object[] summary, long eventCount, long? smtpFirst, long? smtpLast)
        {
            long summaryFirst = Convert.ToInt64(summary[0], CultureInfo.InvariantCulture), summaryLast = Convert.ToInt64(summary[1], CultureInfo.InvariantCulture);
            long first = summaryFirst, last = summaryLast;
            if (smtpFirst.HasValue) { first = Math.Min(first, smtpFirst.Value); last = Math.Max(last, smtpLast.Value); }
            return new object[] { kind == "smtp" ? (long)MessageKindSmtp : (long)MessageKindMessage, identity, hash, summaryFirst == first ? null : (object)summaryFirst, summaryLast == last ? null : (object)summaryLast, first, last, summary[3], summary[4],
                JsonSerializer.Serialize(summary[5]), summary[6], summary[7], summary[8], summary[9], summary[10],
                summary[11], summary[12], summary[13], eventCount, summary[14] };
        }

        /// <summary>Compares the expected values with columns 1..20 of a stored row read by RollupMergeScan.StoredSql (or the per-identity read).</summary>
        static void CompareRollupRow(object[] expected, SqliteDataReader r)
        {
            for (int i = 0; i < expected.Length; i++)
                if (!object.Equals(expected[i] ?? DBNull.Value, r.GetValue(i + 1)))
                    throw new InvalidDataException("InvalidServeRollup: derived column mismatch: " + RollupColumns[i] + ".");
        }

        /// <summary>
        /// Exact check that mail_flow_hour equals the recomputation of every hour and server from the rows (MailFlowRecomputeSql), compared both ways, and
        /// that no bucket waits in mail_flow_dirty. Throws InvalidDataException at the first difference; returns the number of rows. Read-only.
        /// </summary>
        internal static long VerifyMailFlowCore(Func<string, SqliteCommand> command, Action tick)
        {
            Action step = () => { if (tick != null) tick(); };
            using (var c = command("SELECT EXISTS(SELECT 1 FROM mail_flow_dirty);"))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw new InvalidDataException("InvalidMailFlow: unreconciled mail flow work is queued.");
            step();
            // Both sides are projected column by column with the spelling of the server as its bytes (hex): the spelling is part of the proof in both
            // directions, whatever the collation of the column the operands come from.
            int width;
            using (var c = command("SELECT COUNT(*) FROM pragma_table_info('mail_flow_hour');")) width = Convert.ToInt32(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            string names = string.Join(",", Enumerable.Range(1, width).Select(i => "c" + i.ToString(CultureInfo.InvariantCulture)));
            string projected = string.Join(",", Enumerable.Range(1, width).Select(i => i == 2 ? "hex(c2)" : "c" + i.ToString(CultureInfo.InvariantCulture)));
            string sides = "WITH recomputed(" + names + ") AS (" + MailFlowRecomputeSql + "), stored(" + names + ") AS (SELECT * FROM mail_flow_hour) ";
            using (var c = command(sides + "SELECT EXISTS(SELECT " + projected + " FROM recomputed EXCEPT SELECT " + projected + " FROM stored);"))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw new InvalidDataException("InvalidMailFlow: mail_flow_hour differs from the rows.");
            step();
            using (var c = command(sides + "SELECT EXISTS(SELECT " + projected + " FROM stored EXCEPT SELECT " + projected + " FROM recomputed);"))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw new InvalidDataException("InvalidMailFlow: mail_flow_hour differs from the rows.");
            step();
            using (var c = command("SELECT COUNT(*) FROM mail_flow_hour;")) return Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
        }

        static void VerifyServeSchema(ServeRead read)
        {
            var expected = new Dictionary<string, string[]>(StringComparer.Ordinal)
            {
                { "message_rollup", new[] { "table", "message_rollup", ServeRollupTableSql } },
                { "message_rollup_dirty", new[] { "table", "message_rollup_dirty", ServeRollupDirtyTableSql } },
                { "message_rollup_value", new[] { "table", "message_rollup_value", ServeRollupValueTableSql } },
                { "sqlite_autoindex_message_rollup_value_1", new[] { "index", "message_rollup_value", (string)null } },
                { "sqlite_autoindex_message_rollup_1", new[] { "index", "message_rollup", (string)null } },
                { "sqlite_autoindex_smtp_client_value_1", new[] { "index", "smtp_client_value", (string)null } },
                { "sqlite_sequence", new[] { "table", "sqlite_sequence", "CREATE TABLE sqlite_sequence(name,seq)" } },
                { "source_fields", new[] { "table", "source_fields", SourceFieldsTableSql } },
                { "sqlite_autoindex_source_fields_1", new[] { "index", "source_fields", (string)null } }
            };
            foreach (var index in ServeRollupIndexes) expected.Add(index[0], new[] { "index", index[1], index[2] });
            foreach (var trigger in ServeSpanTriggers) expected.Add(trigger[0], new[] { "trigger", trigger[1], trigger[2] });
            foreach (var table in SmtpClientTables) expected.Add(table[0], new[] { "table", table[0], table[1] });
            foreach (var index in SmtpClientIndexes) expected.Add(index[0], new[] { "index", index[1], index[2] });
            foreach (var trigger in SmtpClientTriggers) expected.Add(trigger[0], new[] { "trigger", "smtp_transaction", trigger[1] });
            foreach (var table in MailFlowTables) expected.Add(table[0], new[] { "table", table[0], table[1] });
            foreach (var trigger in MailFlowTriggers) expected.Add(trigger[0], new[] { "trigger", trigger[1], trigger[2] });
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            {
                foreach (string operation in new[] { "INSERT", "UPDATE", "DELETE" })
                    expected.Add("tr_" + table + "_rollup_" + operation.ToLowerInvariant(), new[] { "trigger", table, ServeRollupTriggerSql(table, operation) });
                foreach (bool insert in new[] { true, false })
                    expected.Add("tr_" + table + (insert ? "_hash_insert" : "_hash_update"), new[] { "trigger", table, MessageHashTriggerSql(table, insert) });
            }
            foreach (var entry in expected)
            using (var c = read.Command("SELECT type,tbl_name,sql FROM sqlite_master WHERE name=@name;"))
            {
                c.Parameters.AddWithValue("@name", entry.Key);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read() || !string.Equals(r.GetString(0), entry.Value[0], StringComparison.Ordinal) ||
                        !string.Equals(r.GetString(1), entry.Value[1], StringComparison.Ordinal) ||
                        !string.Equals(r.IsDBNull(2) ? null : r.GetString(2).Trim().TrimEnd(';'), entry.Value[2], StringComparison.Ordinal) || r.Read())
                        throw new InvalidDataException("InvalidServeSchema: missing or noncanonical object: " + entry.Key + ".");
                }
            }
            bool clientId = false;
            using (var c = read.Command("PRAGMA table_info(smtp_transaction);"))
            using (var r = c.ExecuteReader()) while (r.Read()) if (string.Equals(r.GetString(1), "client_id", StringComparison.Ordinal) && string.Equals(r.GetString(2), "INTEGER", StringComparison.Ordinal)) clientId = true;
            if (!clientId) throw new InvalidDataException("InvalidServeSchema: smtp_transaction.client_id is missing.");
            bool fieldsId = false;
            using (var c = read.Command("PRAGMA table_info(source_file);"))
            using (var r = c.ExecuteReader()) while (r.Read()) if (string.Equals(r.GetString(1), "fields_id", StringComparison.Ordinal)) fieldsId = true;
            if (!fieldsId) throw new InvalidDataException("InvalidServeSchema: source_file.fields_id is missing.");
            using (var c = read.Command("SELECT COUNT(*) FROM pragma_table_info('client_session') WHERE name='auth_modes';"))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 1) throw new InvalidDataException("InvalidServeSchema: client_session.auth_modes is missing.");
            using (var c = read.Command("SELECT (SELECT COUNT(*) FROM pragma_table_info('access_client') WHERE pk>0)=7 AND (SELECT COUNT(*) FROM pragma_table_info('access_client') WHERE name='auth_type' AND pk=7)=1;"))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 1) throw new InvalidDataException("InvalidServeSchema: access_client.auth_type is missing or is not the seventh key column.");
            using (var c = read.Command("SELECT 1 FROM source_file s WHERE s.fields_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM source_fields d WHERE d.id=s.fields_id) LIMIT 1;"))
                if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidServeSchema: source_file.fields_id points at a missing source_fields row.");
            // Schema 9 removed these (schema 11 also ix_smtp_latest); a leftover means the database was not migrated (or was altered), not that it is merely larger.
            foreach (string obsolete in ObsoleteServeIndexes)
                using (var c = read.Command("SELECT 1 FROM sqlite_master WHERE name=@name;"))
                {
                    c.Parameters.AddWithValue("@name", obsolete);
                    if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidServeSchema: obsolete object present: " + obsolete + ".");
                }
            // The span bounds Serve reads for every request: one row each, a non-negative integer text (the data check is in the rollup verification).
            foreach (string key in ServeSpanMetadata)
                using (var c = read.Command("SELECT COUNT(*),SUM(typeof(value)='text' AND value=CAST(CAST(value AS INTEGER) AS TEXT) AND CAST(value AS INTEGER)>=0) FROM metadata WHERE key=@key;"))
                {
                    c.Parameters.AddWithValue("@key", key);
                    using (var r = c.ExecuteReader())
                        if (!r.Read() || r.GetInt64(0) != 1 || r.IsDBNull(1) || r.GetInt64(1) != 1)
                            throw new InvalidDataException("InvalidServeSchema: missing or noncanonical span bound: " + key + ".");
                }
            using (var c = read.Command("SELECT name FROM sqlite_master WHERE tbl_name IN('message_rollup','message_rollup_dirty','message_rollup_value','smtp_client_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty');"))
            using (var r = c.ExecuteReader())
                while (r.Read())
                    if (!expected.ContainsKey(r.GetString(0)))
                        throw new InvalidDataException("InvalidServeSchema: unexpected object attached to a derived table.");
        }

        /// <summary>
        /// Verification statements bound to one identity at a time. Cached (the default): one command per statement text for the whole run,
        /// prepared at its first execution and bound again for every identity. Otherwise a new command per statement, disposed after it (the
        /// reference path the tests compare with). The statements, their parameters and the values read are the same either way.
        /// Also used by the host storage maintenance verification, with its own command factory (its connection and transaction).
        /// </summary>
        internal sealed class VerificationReads : IDisposable
        {
            sealed class Bound { public SqliteCommand Command; public SqliteParameter H, M, Sid; public long Identity = -1; }
            readonly Func<string, SqliteCommand> _read;
            readonly bool _cached;
            readonly Dictionary<string, Bound> _commands = new Dictionary<string, Bound>(StringComparer.Ordinal);
            object _hash; string _identity; long _sid, _current;

            internal VerificationReads(ServeRead read, bool cached) : this(read.Command, cached) { }

            /// <param name="command">Creates a new, unbound command for a statement text; the commands it returns are owned by this object when cached.</param>
            internal VerificationReads(Func<string, SqliteCommand> command, bool cached) { _read = command; _cached = cached; }

            internal bool Reuse { get { return _cached; } }

            internal void Identity(string kind, string identity, object hash)
            {
                _hash = hash; _identity = identity; _sid = kind == "smtp" ? long.Parse(identity, CultureInfo.InvariantCulture) : 0L;
                _current++;
            }

            /// <summary>The command of a statement, bound to the current identity (@h, @m, @sid); cached commands are owned by this object.</summary>
            internal SqliteCommand Command(string sql)
            {
                if (!_cached)
                {
                    var c = _read(sql);
                    c.Parameters.AddWithValue("@h", _hash);
                    c.Parameters.AddWithValue("@m", _identity);
                    c.Parameters.AddWithValue("@sid", _sid);
                    return c;
                }
                Bound b;
                if (!_commands.TryGetValue(sql, out b))
                {
                    b = new Bound { Command = _read(sql) };
                    b.H = b.Command.Parameters.AddWithValue("@h", _hash); b.M = b.Command.Parameters.AddWithValue("@m", _identity); b.Sid = b.Command.Parameters.AddWithValue("@sid", _sid);
                    _commands.Add(sql, b);
                }
                else if (b.Identity != _current) { b.H.Value = _hash; b.M.Value = _identity; b.Sid.Value = _sid; }
                b.Identity = _current;
                return b.Command;
            }

            internal object Scalar(string sql)
            {
                var c = Command(sql);
                try { return c.ExecuteScalar(); } finally { if (!_cached) c.Dispose(); }
            }

            public void Dispose() { foreach (var b in _commands.Values) b.Command.Dispose(); _commands.Clear(); }
        }

        /// <summary>The verification reuses the commands of its statements for the whole run; false: a new command per statement (tests compare both).</summary>
        internal static bool CachedVerificationReads = true;

        static void VerifyServeRollupIdentity(VerificationReads reads, string kind, string identity, object hash, MailFlowRules rules)
        {
            long count;
            long? smtpFirst, smtpLast;
            // The summary of the source rows and, from the same COUNT/MIN/MAX statement, the time bounds of the SMTP rows it counted.
            var summary = ReportBuilder.ReadServeRollupBounds(reads.Command, kind, identity, reads.Reuse, out count, out smtpFirst, out smtpLast, rules: rules);
            if (summary == null) throw new InvalidDataException("InvalidServeRollup: source identity could not be summarized.");
            var expected = ExpectedRollupRow(kind, identity, hash, summary, count, smtpFirst, smtpLast);
            var c = reads.Command("SELECT r.id,r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count" +
                " FROM message_rollup r LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events" +
                " WHERE r.kind=@k AND r.identity=@m COLLATE BINARY;");
            try
            {
                if (!c.Parameters.Contains("@k")) c.Parameters.AddWithValue("@k", 0L);
                c.Parameters["@k"].Value = kind == "smtp" ? MessageKindSmtp : MessageKindMessage;
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read()) throw new InvalidDataException("InvalidServeRollup: missing derived identity.");
                    if (!(r.GetValue(0) is long) || r.GetInt64(0) < 1) throw new InvalidDataException("InvalidServeRollup: URL identity must be a positive INTEGER.");
                    CompareRollupRow(expected, r);
                    if (r.Read()) throw new InvalidDataException("InvalidServeRollup: duplicate exact derived identity.");
                }
            }
            finally { if (!reads.Reuse) c.Dispose(); }
        }
    }
}
