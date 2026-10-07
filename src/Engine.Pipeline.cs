// =============================================================================
//  Exchange Log Report - engine, part 6: collection pipeline
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  1. Plan    the folders of every server and source are listed in parallel; a file
//             is read when it is new (modified within BackfillDays) or has grown.
//  2. Parse   N threads (Collection.Parallelism) read and parse one file each, every
//             server and source at the same time. Files are taken oldest first, in
//             three groups:
//               first    HttpProxy: it teaches the "domain\sam" form of the accounts
//               filler   SMTP and message tracking: no link with other files
//               then     IIS, MAPI and ActiveSync back end, IMAP, POP: they use the
//                        accounts learnt from HttpProxy, so they start once every
//                        HttpProxy file is applied (the filler keeps the threads busy)
//  3. Apply   one thread writes the database: one transaction per batch of files
//             (Collection.BatchSeconds / BatchRows), the read position of every file
//             saved with its rows. A file that cannot be read is reported and left
//             for the next collection; a database error stops the collection.
//  PowerShell polls the run (progress, sources finished) every few hundred ms.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>One log folder of one server (one row of the console table).</summary>
    public sealed class SourceJob
    {
        public int Index;
        public string Server, Kind, Role, Label, Folder, Filter = "*.log";
        public bool Recurse;
        // ---- plan
        public bool FolderFound;
        public int Total;
        public DateTime Newest = DateTime.MinValue;
        public string ListError;
        public List<FileWork> Files = new List<FileWork>();
        public long PlannedBytes;
        // ---- progress (written by the apply thread under the lock of the run)
        public int FilesRead, FilesApplied, Errors, Resets;
        public long Bytes, Lines, Kept, Noise, Stored;
        public double FirstStart = -1, LastEnd;       // seconds since the start of the run
        public double WorkSeconds;                    // time spent by the threads on its files (read, parse, write)
        public bool Done;
        public List<string> Warnings = new List<string>();
        public Dictionary<string, long> NoiseReasons = new Dictionary<string, long>(StringComparer.Ordinal);
        public double Seconds { get { return WorkSeconds; } }
        public double Span { get { return FirstStart < 0 ? 0 : Math.Max(0, LastEnd - FirstStart); } }
    }

    /// <summary>One file to read: where to resume, and the result once parsed.</summary>
    public sealed class FileWork
    {
        public SourceJob Job;
        public string Path, Name;
        public long Length;
        public DateTime LastWriteUtc;
        public FileState State;
        internal int Group;
    }

    public sealed class RunProgress
    {
        public int FilesPlanned, FilesDone, Errors, Workers;
        public long BytesPlanned, BytesDone, Lines, Kept;
        public double Seconds;
        public string[] Reading = new string[0];
    }

    /// <summary>
    /// A statement prepared once for the whole collection and run directly on the SQLite handle: binding by index,
    /// without the per-row parameter lookups of Microsoft.Data.Sqlite (a third of the write time on large collections).
    /// It runs in the transaction open on the connection.
    /// </summary>
    sealed class Prepared : IDisposable
    {
        readonly SQLitePCL.sqlite3 _db;
        readonly SQLitePCL.sqlite3_stmt _stmt;
        readonly int[] _index;

        public Prepared(Store store, string sql, int parameters)
        {
            _db = store.Connection.Handle;
            int rc = SQLitePCL.raw.sqlite3_prepare_v2(_db, sql, out _stmt);
            if (rc != SQLitePCL.raw.SQLITE_OK) throw new SqliteException("SQLite: " + SQLitePCL.raw.sqlite3_errmsg(_db).utf8_to_string() + " (" + sql + ")", rc);
            _index = new int[parameters];
            for (int i = 0; i < parameters; i++) _index[i] = SQLitePCL.raw.sqlite3_bind_parameter_index(_stmt, "@p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }

        public void Use(SqliteTransaction tx) { }

        byte[] _utf8 = new byte[4096];

        public void Set(int i, object value)
        {
            int k = _index[i];
            if (value == null || value is DBNull) SQLitePCL.raw.sqlite3_bind_null(_stmt, k);
            else if (value is string) BindText(k, (string)value);
            else if (value is byte[]) SQLitePCL.raw.sqlite3_bind_blob(_stmt, k, (byte[])value);
            else if (value is long) SQLitePCL.raw.sqlite3_bind_int64(_stmt, k, (long)value);
            else if (value is int) SQLitePCL.raw.sqlite3_bind_int64(_stmt, k, (int)value);
            else if (value is double) SQLitePCL.raw.sqlite3_bind_double(_stmt, k, (double)value);
            else if (value is bool) SQLitePCL.raw.sqlite3_bind_int64(_stmt, k, (bool)value ? 1 : 0);
            else BindText(k, Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture));
        }

        /// <summary>Text through a reused UTF-8 buffer (SQLite copies it): no array per value.</summary>
        void BindText(int k, string s)
        {
            int max = System.Text.Encoding.UTF8.GetMaxByteCount(s.Length);
            if (max > _utf8.Length) _utf8 = new byte[Math.Max(max, _utf8.Length * 2)];
            int n = System.Text.Encoding.UTF8.GetBytes(s, 0, s.Length, _utf8, 0);
            SQLitePCL.raw.sqlite3_bind_text(_stmt, k, new ReadOnlySpan<byte>(_utf8, 0, n));
        }

        public void Set(int i, long value) { SQLitePCL.raw.sqlite3_bind_int64(_stmt, _index[i], value); }

        void Check(int rc)
        {
            if (rc == SQLitePCL.raw.SQLITE_ROW || rc == SQLitePCL.raw.SQLITE_DONE) return;
            string message = SQLitePCL.raw.sqlite3_errmsg(_db).utf8_to_string();
            SQLitePCL.raw.sqlite3_reset(_stmt);
            throw new SqliteException("SQLite: " + message, rc);
        }

        /// <summary>Runs the statement; returns the number of rows changed.</summary>
        public int Run()
        {
            int rc = SQLitePCL.raw.sqlite3_step(_stmt);
            while (rc == SQLitePCL.raw.SQLITE_ROW) rc = SQLitePCL.raw.sqlite3_step(_stmt);
            Check(rc);
            int changes = SQLitePCL.raw.sqlite3_changes(_db);
            SQLitePCL.raw.sqlite3_reset(_stmt);
            return changes;
        }

        /// <summary>Runs the statement and returns the integer of the first row (RETURNING id), null without row.</summary>
        public object Scalar()
        {
            int rc = SQLitePCL.raw.sqlite3_step(_stmt);
            object value = null;
            if (rc == SQLitePCL.raw.SQLITE_ROW)
            {
                if (SQLitePCL.raw.sqlite3_column_type(_stmt, 0) != SQLitePCL.raw.SQLITE_NULL) value = SQLitePCL.raw.sqlite3_column_int64(_stmt, 0);
                while (rc == SQLitePCL.raw.SQLITE_ROW) rc = SQLitePCL.raw.sqlite3_step(_stmt);
            }
            Check(rc);
            SQLitePCL.raw.sqlite3_reset(_stmt);
            return value;
        }

        public void Dispose() { _stmt.Dispose(); }
    }

    /// <summary>Every statement written by a collection, prepared once.</summary>
    sealed class Writer : IDisposable
    {
        public Prepared InsertEvent, InsertIis, InsertSmtp, InsertMessage, Usage, Action, Client, SaveFile, Noise;
        public Prepared SessionInsert, SessionUpdate, SessionStep, SessionRepoint, SessionDelete;
        public const string SessionColumns = "skey,day,start_ms,end_ms,user,protocol,mailbox,client_ip,user_agent,device_id,device_type,software,client_mode,front_ends,back_ends," +
            "requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses," +
            "first_error,last_error,backend,connections,updated_ms";
        readonly List<Prepared> _all = new List<Prepared>();

        static string Values(int n) { return string.Join(",", Enumerable.Range(0, n).Select(i => "@p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture))); }

        Prepared Add(Store store, string sql, int n) { var p = new Prepared(store, sql, n); _all.Add(p); return p; }

        public Writer(Store store)
        {
            InsertEvent = Add(store, "INSERT OR IGNORE INTO access_event(time_ms,server,source,protocol,user,mailbox,client_ip,user_agent,method,url,action,status,sub_status,win32,backend_status,error_code,target_server,auth_type,routing,bytes_in,bytes_out,duration_ms,outcome,request_id,errors) VALUES(" + Values(25) + ") RETURNING id;", 25);
            InsertIis = Add(store, "INSERT OR REPLACE INTO iis_status(server,request_id,time_ms,status,sub_status,win32,time_taken) VALUES(" + Values(7) + ");", 7);
            InsertSmtp = Add(store, "INSERT OR IGNORE INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,internal_id,status,response,transcript) VALUES(" + Values(20) + ");", 20);
            InsertMessage = Add(store, "INSERT OR IGNORE INTO message_event(time_ms,server,event_id,source,message_id,internal_id,network_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_ip,server_host,connector,source_context,related_recipient,reference,directionality,message_info,return_path,log_id) VALUES(" + Values(25) + ");", 25);
            Usage = Add(store, @"INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent,slow)
VALUES(" + Values(20) + @")
ON CONFLICT(day,server,user,protocol) DO UPDATE SET
 mailbox=COALESCE(excluded.mailbox,mailbox), requests=requests+excluded.requests, successes=successes+excluded.successes,
 client_errors=client_errors+excluded.client_errors, server_errors=server_errors+excluded.server_errors, slow=slow+excluded.slow,
 bytes_in=bytes_in+excluded.bytes_in, bytes_out=bytes_out+excluded.bytes_out, total_ms=total_ms+excluded.total_ms,
 max_ms=MAX(max_ms,excluded.max_ms), first_ms=MIN(first_ms,excluded.first_ms),
 client_ip=CASE WHEN excluded.client_ip IS NULL THEN client_ip WHEN client_ip IS NULL OR excluded.last_ms>=last_ms THEN excluded.client_ip ELSE client_ip END,
 user_agent=CASE WHEN excluded.user_agent IS NULL THEN user_agent WHEN user_agent IS NULL OR excluded.last_ms>=last_ms THEN excluded.user_agent ELSE user_agent END,
 last_ms=MAX(last_ms,excluded.last_ms), last_success_ms=MAX(last_success_ms,excluded.last_success_ms),
 last_failure_ms=MAX(last_failure_ms,excluded.last_failure_ms);", 20);
            Action = Add(store, @"INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES(" + Values(9) + @")
ON CONFLICT(day,server,protocol,action) DO UPDATE SET requests=requests+excluded.requests, failures=failures+excluded.failures, slow=slow+excluded.slow,
 total_ms=total_ms+excluded.total_ms, max_ms=MAX(max_ms,excluded.max_ms);", 9);
            Client = Add(store, @"INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,requests,failures,first_ms,last_ms,servers) VALUES(" + Values(12) + @")
ON CONFLICT(day,user,protocol,client_ip,user_agent,device_id) DO UPDATE SET requests=requests+excluded.requests, failures=failures+excluded.failures,
 device_type=COALESCE(excluded.device_type,device_type), first_ms=MIN(first_ms,excluded.first_ms), last_ms=MAX(last_ms,excluded.last_ms),
 servers=CASE WHEN servers IS NULL THEN excluded.servers WHEN instr(','||servers||',', ','||excluded.servers||',') > 0 THEN servers ELSE servers||','||excluded.servers END;", 12);
            SaveFile = Add(store, "UPDATE source_file SET offset=@p1,size=@p2,last_write_ms=@p3,fields=@p4,first_ms=@p5,last_ms=@p6,lines=@p7,kept=@p8,noise=@p9,updated_ms=@p10 WHERE id=@p0;", 11);
            Noise = Add(store, "INSERT INTO noise(run_id,server,kind,reason,lines) VALUES(@p0,@p1,@p2,@p3,@p4) ON CONFLICT(run_id,server,kind,reason) DO UPDATE SET lines=lines+excluded.lines;", 5);
            int n = SessionColumns.Split(',').Length;
            SessionInsert = Add(store, "INSERT INTO client_session(" + SessionColumns + ") VALUES(" + Values(n) + ") RETURNING id;", n);
            SessionUpdate = Add(store, "UPDATE client_session SET " + string.Join(",", SessionColumns.Split(',').Select((c, i) => c + "=@p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture))) + " WHERE id=@p" + n.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";", n + 1);
            SessionStep = Add(store, "INSERT INTO session_step(session_id,time_ms,data) VALUES(@p0,@p1,@p2);", 3);
            SessionRepoint = Add(store, "UPDATE session_step SET session_id=@p0 WHERE session_id=@p1;", 2);
            SessionDelete = Add(store, "DELETE FROM client_session WHERE id=@p0;", 1);
        }

        public void Use(SqliteTransaction tx) { foreach (var p in _all) p.Use(tx); }
        public void Dispose() { foreach (var p in _all) p.Dispose(); }
    }

    /// <summary>A parsed file waiting for the apply thread.</summary>
    sealed class ParsedFile
    {
        public FileWork Work;
        public FileResult Result;
        public object Context;          // Collector.ParseContext
        public long StartOffset, NewOffset;
        public string Fields;
        public double Started, Ended;   // seconds since the start of the run
        public double ApplySeconds;     // time spent by the apply thread on its records
    }

    /// <summary>A collection running in the background. PowerShell polls it: Wait, Progress, TakeFinished.</summary>
    public sealed class CollectionRun
    {
        internal readonly object Lock = new object();
        internal readonly Stopwatch Clock = Stopwatch.StartNew();
        internal readonly CancellationTokenSource Cancel = new CancellationTokenSource();
        internal readonly ManualResetEventSlim Finished = new ManualResetEventSlim(false);
        internal readonly List<SourceJob> FinishedJobs = new List<SourceJob>();
        internal readonly List<string> LogLines = new List<string>();
        internal readonly Dictionary<int, string> Reading = new Dictionary<int, string>();
        internal int FilesPlanned, FilesDone, ErrorCount, WorkerCount;
        /// <summary>Most files of one server read at the same time (Collection.MaxFilesPerServer).</summary>
        public int PeakFilesPerServer { get; internal set; }
        internal long BytesPlanned, BytesDone, LinesDone, KeptDone;
        public SourceJob[] Jobs { get; internal set; }
        public Exception Error { get; internal set; }
        public bool Cancelled { get { return Cancel.IsCancellationRequested; } }
        public double Seconds { get; internal set; }
        /// <summary>Where the time went (execution log): parse threads busy, apply thread by task, waits, GC pauses.</summary>
        public string Statistics { get; internal set; }
        internal readonly double[] ApplyTimes = new double[8];   // access, back end, rows, sessions, aggregates, commit, wait, other
        internal double ParseBusy;
        internal int Batches;

        /// <summary>True when the collection is over (completed, failed or cancelled).</summary>
        public bool Wait(int milliseconds) { return Finished.Wait(milliseconds); }

        /// <summary>Stops the collection: the files already applied are kept, the batch in progress is rolled back.</summary>
        public void Stop() { Cancel.Cancel(); }

        public RunProgress Progress()
        {
            lock (Lock)
            {
                return new RunProgress
                {
                    FilesPlanned = FilesPlanned, FilesDone = FilesDone, Errors = ErrorCount, Workers = WorkerCount, BytesPlanned = BytesPlanned, BytesDone = BytesDone,
                    Lines = LinesDone, Kept = KeptDone, Seconds = Clock.Elapsed.TotalSeconds, Reading = Reading.Values.OrderBy(x => x, StringComparer.Ordinal).ToArray()
                };
            }
        }

        /// <summary>Sources whose files are all read and saved since the last call (one console row each).</summary>
        public SourceJob[] TakeFinished()
        {
            lock (Lock) { var a = FinishedJobs.ToArray(); FinishedJobs.Clear(); return a; }
        }

        /// <summary>Lines for the execution log (file errors, files read again from the beginning).</summary>
        public string[] TakeLog()
        {
            lock (Lock) { var a = LogLines.ToArray(); LogLines.Clear(); return a; }
        }
    }

    public sealed partial class Collector
    {
        // ================================================================ plan

        static readonly HashSet<string> FirstKinds = new HashSet<string>(StringComparer.Ordinal) { "HttpProxy" };
        static readonly HashSet<string> FillerKinds = new HashSet<string>(StringComparer.Ordinal) { "SmtpReceive", "SmtpSend", "Tracking" };

        /// <summary>
        /// Lists the files of every source in parallel. A file is read when it is not known yet and was modified
        /// since sinceUtc (first collection: BackfillDays), or when its read position is not its size (new lines, or
        /// an SMTP, IMAP or POP session held back). Known files are found by their identity (FileKey), so a file read
        /// through the administrative share before -Mode Discover and through its local path after is known.
        /// </summary>
        public void Plan(SourceJob[] jobs, DateTime sinceUtc)
        {
            var known = _store.KnownFiles();
            // Listing a folder is a few network round trips: twice the read threads, at most 16 folders at the same time.
            var options = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(2, Math.Min(16, EffectiveParallelism * 2)) };
            Parallel.ForEach(jobs, options, job =>
            {
                job.Files.Clear(); job.Total = 0; job.Newest = DateTime.MinValue; job.PlannedBytes = 0; job.ListError = null;
                try
                {
                    job.FolderFound = Directory.Exists(job.Folder);
                    if (!job.FolderFound) return;
                    var dir = new DirectoryInfo(job.Folder);
                    var enumeration = new EnumerationOptions { RecurseSubdirectories = job.Recurse, IgnoreInaccessible = true, MatchCasing = MatchCasing.CaseInsensitive };
                    foreach (var f in dir.EnumerateFiles(job.Filter ?? "*.log", enumeration))
                    {
                        job.Total++;
                        var write = f.LastWriteTimeUtc;
                        if (write > job.Newest) job.Newest = write;
                        FileState state;
                        bool isKnown = known.TryGetValue(job.Server + "|" + job.Kind + "|" + Store.FileKey(job.Server, f.FullName), out state);
                        if (!isKnown && write < sinceUtc) continue;
                        if (isKnown && state.Offset == f.Length) continue;
                        var copy = isKnown ? state.CopyFor(f.FullName) : new FileState { Server = job.Server, Kind = job.Kind, Path = f.FullName };
                        job.Files.Add(new FileWork { Job = job, Path = f.FullName, Name = f.Name, Length = f.Length, LastWriteUtc = write, State = copy });
                    }
                    job.Files.Sort((a, b) => a.LastWriteUtc != b.LastWriteUtc ? a.LastWriteUtc.CompareTo(b.LastWriteUtc) : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
                    job.PlannedBytes = job.Files.Sum(x => Math.Max(0, x.Length - (x.State.Offset <= x.Length ? x.State.Offset : 0)));
                }
                catch (Exception ex) { job.ListError = ex.GetType().Name + ": " + ex.Message; }
            });
        }

        // ================================================================ run

        public int EffectiveParallelism
        {
            get { return _o.Parallelism > 0 ? _o.Parallelism : Math.Max(2, Math.Min(16, Environment.ProcessorCount)); }
        }

        /// <summary>Starts the collection of the planned files in the background. Call Complete() once it is over.</summary>
        public CollectionRun Start(SourceJob[] jobs)
        {
            var run = new CollectionRun { Jobs = jobs };
            var all = jobs.SelectMany(j => j.Files).ToList();
            foreach (var w in all) w.Group = FirstKinds.Contains(w.Job.Kind) ? 0 : FillerKinds.Contains(w.Job.Kind) ? 1 : 2;
            Comparison<FileWork> byTime = (a, b) => a.LastWriteUtc != b.LastWriteUtc ? a.LastWriteUtc.CompareTo(b.LastWriteUtc) : b.Length.CompareTo(a.Length);
            var first = all.Where(w => w.Group == 0).ToList(); first.Sort(byTime);
            var filler = all.Where(w => w.Group == 1).ToList(); filler.Sort(byTime);
            var then = all.Where(w => w.Group == 2).ToList(); then.Sort(byTime);
            run.FilesPlanned = all.Count;
            run.BytesPlanned = jobs.Sum(j => j.PlannedBytes);
            int workers = Math.Max(1, Math.Min(EffectiveParallelism, Math.Max(1, all.Count)));
            run.WorkerCount = workers;
            foreach (var j in jobs) if (j.Files.Count == 0) j.Done = true;

            var queues = new[] { new LinkedList<FileWork>(first), new LinkedList<FileWork>(filler), new LinkedList<FileWork>(then) };
            var gate = new object();
            int firstLeft = first.Count;           // HttpProxy files not applied yet: the last group waits for them
            var output = new BlockingCollection<ParsedFile>(Math.Max(4, workers * 2));
            var token = run.Cancel.Token;
            int running = workers;
            // Files of each server being read: at most MaxFilesPerServer, so that the threads spread over the servers
            // and no server (or the local disk of the collector) serves all of them.
            var reading = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            int perServer = _o.MaxFilesPerServer;
            Func<LinkedList<FileWork>, FileWork> take = q =>
            {
                for (var node = q.First; node != null; node = node.Next)
                {
                    int n; reading.TryGetValue(node.Value.Job.Server, out n);
                    if (perServer > 0 && n >= perServer) continue;
                    q.Remove(node);
                    reading[node.Value.Job.Server] = n + 1;
                    if (n + 1 > run.PeakFilesPerServer) run.PeakFilesPerServer = n + 1;
                    return node.Value;
                }
                return null;
            };

            Func<FileWork> next = () =>
            {
                lock (gate)
                {
                    while (true)
                    {
                        if (token.IsCancellationRequested) return null;
                        var w = take(queues[0]);
                        if (w == null && firstLeft == 0) w = take(queues[2]);
                        if (w == null) w = take(queues[1]);
                        if (w != null) return w;
                        if (queues[0].Count == 0 && queues[1].Count == 0 && queues[2].Count == 0) return null;
                        Monitor.Wait(gate, 500);
                    }
                }
            };
            Action<FileWork> done = w =>
            {
                lock (gate) { reading[w.Job.Server]--; Monitor.PulseAll(gate); }
            };

            for (int i = 0; i < workers; i++)
            {
                int slot = i;
                var thread = new Thread(() =>
                {
                    var memo = new Memo { Days = new DayCache(_o.Zone) };
                    try
                    {
                        FileWork w;
                        while ((w = next()) != null)
                        {
                            lock (run.Lock) run.Reading[slot] = w.Job.Server + " " + w.Job.Label + " " + w.Name;
                            ParsedFile parsed;
                            try { parsed = ParseFile(w, run, memo); }
                            finally { done(w); }
                            memo.Trim();
                            lock (run.Lock) run.Reading.Remove(slot);
                            output.Add(parsed, token);
                        }
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { lock (run.Lock) { if (run.Error == null) run.Error = ex; } run.Cancel.Cancel(); }
                    finally { if (Interlocked.Decrement(ref running) == 0) output.CompleteAdding(); }
                }) { IsBackground = true, Name = "ELR parse " + slot.ToString(System.Globalization.CultureInfo.InvariantCulture), Priority = ThreadPriority.BelowNormal };
                thread.Start();
            }

            var apply = new Thread(() =>
            {
                var gcPause = GC.GetTotalPauseDuration();
                int gcCount = GC.CollectionCount(0);
                Thread checkpointer = null;
                var stopCheckpoints = new ManualResetEventSlim(false);
                try
                {
                    _writer = new Writer(_store);
                    _times = run.ApplyTimes;
                    // The WAL is copied into the database by a thread of its own (another connection): the commits of the
                    // apply thread only append to the WAL, the copy and its flush to the disk run at the same time.
                    _store.Exec("PRAGMA wal_autocheckpoint=0;");
                    checkpointer = new Thread(() => Checkpoints(stopCheckpoints)) { IsBackground = true, Name = "ELR checkpoint" };
                    checkpointer.Start();
                    var batchClock = Stopwatch.StartNew();
                    while (true)
                    {
                        long waitStart = Stopwatch.GetTimestamp();
                        ParsedFile p;
                        bool got = output.TryTake(out p, Timeout.Infinite, token);
                        _times[6] += Stopwatch.GetElapsedTime(waitStart).TotalSeconds;
                        if (!got) break;
                        if (_batch == null) { BeginBatch(); batchClock.Restart(); }
                        Apply(p, run);
                        if (p.Work.Group == 0)
                            lock (gate) { firstLeft--; if (firstLeft == 0) Monitor.PulseAll(gate); }
                        if (_batch.Rows >= _o.BatchRows || batchClock.Elapsed.TotalSeconds >= _o.BatchSeconds || (p.Work.Group == 0 && firstLeft == 0)) CommitBatch(run);
                    }
                    if (_batch != null) CommitBatch(run);
                    if (token.IsCancellationRequested && run.Error == null) throw new OperationCanceledException();
                }
                catch (OperationCanceledException) { RollbackBatch(); }
                catch (Exception ex)
                {
                    RollbackBatch();
                    lock (run.Lock) { if (run.Error == null) run.Error = ex; }
                    run.Cancel.Cancel();
                }
                finally
                {
                    lock (gate) Monitor.PulseAll(gate);
                    // Let the parse threads finish (they stop at the cancellation) before the database is used again.
                    try { foreach (var _ in output.GetConsumingEnumerable()) { } } catch (Exception) { }
                    if (_writer != null) { _writer.Dispose(); _writer = null; }
                    stopCheckpoints.Set();
                    if (checkpointer != null) checkpointer.Join();
                    _times = null;
                    run.Seconds = run.Clock.Elapsed.TotalSeconds;
                    var t = run.ApplyTimes;
                    double busy = t.Take(6).Sum() + t[7];
                    run.Statistics = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "{0:0.0} s, {1} parse thread(s) busy {2:0}% ({3:0.0} s), at most {17} file(s) of one server at the same time, apply thread busy {4:0}%: client access {5:0.0} s, back end {6:0.0} s, rows {7:0.0} s, sessions {8:0.0} s, aggregates {9:0.0} s, commits {10:0.0} s ({11} batches), waiting for files {12:0.0} s; WAL copied into the database in the background {15} time(s), {16:0.0} s; GC {13} collections, pauses {14:0.0} s",
                        run.Seconds, workers, 100 * run.ParseBusy / Math.Max(0.001, workers * run.Seconds), run.ParseBusy, 100 * busy / Math.Max(0.001, run.Seconds),
                        t[0], t[1], t[2], t[3], t[4], t[5], run.Batches, t[6], GC.CollectionCount(0) - gcCount, (GC.GetTotalPauseDuration() - gcPause).TotalSeconds, CheckpointCount, CheckpointSeconds, run.PeakFilesPerServer);
                    run.Finished.Set();
                }
            }) { IsBackground = true, Name = "ELR apply" };
            apply.Start();
            return run;
        }

        /// <summary>
        /// Copies the WAL into the database with its own connection (PASSIVE: never waits for the writer) every ten
        /// seconds, while the apply thread only appends to the WAL: the copy and its flush to the disk run at the same
        /// time as the parsing and the writing. Time spent in CheckpointSeconds (execution log).
        /// </summary>
        void Checkpoints(ManualResetEventSlim stop)
        {
            try
            {
                var builder = new SqliteConnectionStringBuilder { DataSource = _store.FilePath, Mode = SqliteOpenMode.ReadWrite, Pooling = false };
                using (var db = new SqliteConnection(builder.ToString()))
                {
                    db.Open();
                    using (var c = db.CreateCommand()) { c.CommandText = "PRAGMA busy_timeout=5000;"; c.ExecuteNonQuery(); }
                    using (var c = db.CreateCommand())
                    {
                        c.CommandText = "PRAGMA wal_checkpoint(PASSIVE);";
                        while (!stop.Wait(10000))
                        {
                            var watch = Stopwatch.StartNew();
                            try { c.ExecuteNonQuery(); CheckpointCount++; } catch (SqliteException) { }
                            CheckpointSeconds += watch.Elapsed.TotalSeconds;
                        }
                    }
                }
            }
            catch (Exception) { }
        }

        /// <summary>Background copies of the WAL into the database during the collection, and their time.</summary>
        public int CheckpointCount { get; private set; }
        public double CheckpointSeconds { get; private set; }

        /// <summary>Parse stage of one file (parse thread).</summary>
        ParsedFile ParseFile(FileWork w, CollectionRun run, Memo memo)
        {
            var result = new FileResult { Server = w.Job.Server, Kind = w.Job.Kind, Path = w.Path };
            var parsed = new ParsedFile { Work = w, Result = result, Started = run.Clock.Elapsed.TotalSeconds };
            var clock = Stopwatch.StartNew();
            try
            {
                var info = new FileInfo(w.Path);
                if (!info.Exists) { result.Error = "File not found"; return parsed; }
                long length = info.Length, start = w.State.Offset;
                string fields = w.State.Fields;
                if (length < start) { start = 0; fields = null; result.Reset = true; }
                parsed.StartOffset = start;
                if (length == start) { result.Unchanged = true; parsed.NewOffset = start; parsed.Fields = fields; return parsed; }
                var c = new ParseContext
                {
                    Work = w, Result = result, Server = w.Job.Server, Role = w.Job.Role, Path = w.Path, Fields = fields, StartOffset = start,
                    LastWriteMs = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds(), Split = memo.Split, Memo = memo, Days = memo.Days
                };
                parsed.NewOffset = Parse(c, w.Job.Kind);
                parsed.Fields = c.Fields;
                parsed.Context = c;
                w.Length = length;
                w.LastWriteUtc = info.LastWriteTimeUtc;
                result.BytesRead = parsed.NewOffset - start;
            }
            catch (Exception ex) { result.Error = ex.GetType().Name + ": " + ex.Message; parsed.Context = null; }
            finally
            {
                result.Seconds = clock.Elapsed.TotalSeconds;
                parsed.Ended = run.Clock.Elapsed.TotalSeconds;
                lock (run.Lock) run.ParseBusy += result.Seconds;
            }
            return parsed;
        }

        // ================================================================ apply (one thread)

        sealed class Batch
        {
            public SqliteTransaction Tx;
            public long Rows;
            public readonly Dictionary<string, UsageAcc> Usage = new Dictionary<string, UsageAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, ActionAcc> Actions = new Dictionary<string, ActionAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, ClientAcc> Clients = new Dictionary<string, ClientAcc>(StringComparer.Ordinal);
            public readonly HashSet<ClientSession> Touched = new HashSet<ClientSession>();
            public readonly Dictionary<string, long> Noise = new Dictionary<string, long>(StringComparer.Ordinal);
            public readonly List<ParsedFile> Files = new List<ParsedFile>();
        }

        Batch _batch;
        Writer _writer;
        double[] _times;   // apply thread: seconds per task (CollectionRun.ApplyTimes)

        void Time(int slot, long since) { if (_times != null) _times[slot] += Stopwatch.GetElapsedTime(since).TotalSeconds; }

        void BeginBatch()
        {
            _batch = new Batch { Tx = _store.Begin() };
            _tx = _batch.Tx;
            _writer.Use(_batch.Tx);
        }

        void RollbackBatch()
        {
            if (_batch == null) return;
            try { _batch.Tx.Rollback(); } catch (Exception) { }
            try { _batch.Tx.Dispose(); } catch (Exception) { }
            _batch = null;
            _tx = null;
            // Sessions in memory may hold requests that were not saved.
            ResetSessions();
        }

        void Apply(ParsedFile p, CollectionRun run)
        {
            var watch = Stopwatch.StartNew();
            try { ApplyFileRecords(p, run); }
            finally { p.ApplySeconds = watch.Elapsed.TotalSeconds; }
        }

        void ApplyFileRecords(ParsedFile p, CollectionRun run)
        {
            var w = p.Work;
            var job = w.Job;
            var r = p.Result;
            if (r.Error != null || r.Unchanged)
            {
                lock (run.Lock)
                {
                    if (r.Error != null) { job.Errors++; run.ErrorCount++; run.LogLines.Add("WARN|" + job.Server + " " + w.Path + ": " + r.Error); }
                    run.FilesDone++;
                    job.FilesApplied++;
                    run.BytesDone += Math.Max(0, w.Length - w.State.Offset);
                }
                _batch.Files.Add(p);
                return;
            }
            var c = (ParseContext)p.Context;
            var state = w.State;
            long mark = Stopwatch.GetTimestamp();
            var f = new ApplyFile { Server = job.Server, Role = job.Role, Kind = job.Kind, Path = w.Path, Result = r };
            f.FileId = _store.FileId(state, _batch.Tx);
            int slot = 2;
            switch (job.Kind)
            {
                case "HttpProxy":
                case "Iis":
                    slot = 0;
                    foreach (var a in c.Access) HandleAccess(f, a);
                    MergeAggregates(c);
                    foreach (var row in c.IisStatus)
                    {
                        var ins = _writer.InsertIis;
                        for (int i = 0; i < row.Length; i++) ins.Set(i, row[i]);
                        if (ins.Run() > 0) r.Stored++;
                        _batch.Rows++;
                    }
                    break;
                case "MapiBackEnd": slot = 1; foreach (var b in c.BackEnd) ApplyMapiBackEnd(f, b); break;
                case "EasBackEnd": slot = 1; foreach (var b in c.BackEnd) ApplyEasBackEnd(f, b); break;
                case "Imap4":
                case "Pop3": slot = 1; foreach (var x in c.PopImap) EmitPopImap(f, x, job.Kind, c.PopImapBackEnd); break;
                case "SmtpReceive":
                case "SmtpSend":
                    foreach (var row in c.Smtp)
                    {
                        var ins = _writer.InsertSmtp;
                        for (int i = 0; i < row.Length; i++) ins.Set(i, row[i]);
                        if (ins.Run() > 0) r.Stored++;
                        _batch.Rows++;
                    }
                    break;
                case "Tracking":
                    foreach (var row in c.Messages)
                    {
                        var ins = _writer.InsertMessage;
                        for (int i = 0; i < row.Length; i++) ins.Set(i, row[i]);
                        if (ins.Run() > 0) r.Stored++;
                        _batch.Rows++;
                    }
                    break;
            }
            Time(slot, mark);
            mark = Stopwatch.GetTimestamp();
            state.Offset = p.NewOffset;
            state.Fields = p.Fields;
            state.Size = w.Length;
            state.LastWriteMs = new DateTimeOffset(w.LastWriteUtc).ToUnixTimeMilliseconds();
            state.Lines += r.Lines; state.Kept += r.Kept; state.Noise += r.Noise;
            if (r.FirstMs > 0 && (state.FirstMs == 0 || r.FirstMs < state.FirstMs)) state.FirstMs = r.FirstMs;
            if (r.LastMs > state.LastMs) state.LastMs = r.LastMs;
            var save = _writer.SaveFile;
            save.Set(0, state.Id); save.Set(1, state.Offset); save.Set(2, state.Size); save.Set(3, state.LastWriteMs); save.Set(4, state.Fields);
            save.Set(5, state.FirstMs > 0 ? (object)state.FirstMs : null); save.Set(6, state.LastMs > 0 ? (object)state.LastMs : null);
            save.Set(7, state.Lines); save.Set(8, state.Kept); save.Set(9, state.Noise); save.Set(10, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            save.Run();
            foreach (var kv in r.NoiseReasons)
            {
                string key = job.Server + "\u0001" + job.Kind + "\u0001" + kv.Key;
                long n; _batch.Noise.TryGetValue(key, out n); _batch.Noise[key] = n + kv.Value;
            }
            _batch.Rows++;
            _batch.Files.Add(p);
            p.Context = null;
            Time(7, mark);
            lock (run.Lock)
            {
                run.FilesDone++;
                run.BytesDone += Math.Max(0, w.Length - p.StartOffset);
                run.LinesDone += r.Lines;
                run.KeptDone += r.Kept;
                job.FilesApplied++;
                if (r.Reset) { job.Resets++; run.LogLines.Add("WARN|" + w.Path + " was shorter than the position already read: read again from the beginning."); }
            }
        }

        void CommitBatch(CollectionRun run)
        {
            if (_batch == null) return;
            long mark = Stopwatch.GetTimestamp();
            FlushUsage();
            FlushActions();
            FlushClients();
            Time(4, mark); mark = Stopwatch.GetTimestamp();
            FlushSessions(_batch.Tx, _batch.Touched);
            Time(3, mark); mark = Stopwatch.GetTimestamp();
            var noise = _writer.Noise;
            foreach (var kv in _batch.Noise)
            {
                var parts = kv.Key.Split('\u0001');
                noise.Set(0, _o.RunId); noise.Set(1, parts[0]); noise.Set(2, parts[1]); noise.Set(3, parts[2]); noise.Set(4, kv.Value);
                noise.Run();
            }
            _batch.Tx.Commit();
            _batch.Tx.Dispose();
            Time(5, mark);
            run.Batches++;
            var files = _batch.Files;
            _batch = null;
            _tx = null;
            lock (run.Lock)
            {
                foreach (var p in files)
                {
                    var job = p.Work.Job;
                    var r = p.Result;
                    if (r.Error == null && !r.Unchanged)
                    {
                        job.FilesRead++; job.Bytes += r.BytesRead; job.Lines += r.Lines; job.Kept += r.Kept; job.Noise += r.Noise; job.Stored += r.Stored;
                        foreach (var kv in r.NoiseReasons) { long n; job.NoiseReasons.TryGetValue(kv.Key, out n); job.NoiseReasons[kv.Key] = n + kv.Value; }
                    }
                    job.WorkSeconds += r.Seconds + p.ApplySeconds;
                    if (job.FirstStart < 0 || p.Started < job.FirstStart) job.FirstStart = p.Started;
                    if (p.Ended > job.LastEnd) job.LastEnd = p.Ended;
                    if (!job.Done && job.FilesApplied >= job.Files.Count) { job.Done = true; run.FinishedJobs.Add(job); }
                }
            }
            EvictSessions(files);
        }
    }
}
