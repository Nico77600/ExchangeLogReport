using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public sealed class ServeOptions
    {
        public string DatabasePath { get; set; }
        public string WebRoot { get; set; }
        public int Port { get; set; } = 8765;
        public bool NoBrowser { get; set; }
        public string ReadyFile { get; set; }
        public bool ReadyFileWithToken { get; set; }
        /// <summary>Deadline of a list, a detail or an export request (seconds).</summary>
        public int RequestTimeoutSeconds { get; set; } = 15;
        /// <summary>Deadline of the aggregate requests /api/overview and /api/overview/counts (seconds): they read every event of their period.</summary>
        public int AggregateTimeoutSeconds { get; set; } = 60;
        public int MmapMB { get; set; }
        public int MaxConcurrency { get; set; } = 4;
        /// <summary>Page cache of each read connection (16 MiB for a request; the rollup verification uses a larger one).</summary>
        internal int CacheKilobytes { get; set; } = 16384;
        /// <summary>
        /// Time zone of the days of the daily tables (access_usage, access_client, access_action: the collection time zone) and of the day packs of
        /// /api/report-meta. Default: the time zone of this computer, which is the browser's on the loopback portal.
        /// </summary>
        public TimeZoneInfo Zone { get; set; } = TimeZoneInfo.Local;
        /// <summary>Largest selection the page loads whole (10,000..1,000,000), returned by /api/report-meta; above, the page browses it on the server.</summary>
        public int ClientRowsMax { get; set; } = 50000;
        /// <summary>Time budget of one scan request (milliseconds, 100..120,000), returned by /api/report-meta capped at the request deadline.</summary>
        public int ScanBudgetMs { get; set; } = 2000;
    }

    /// <summary>
    /// An export ticket (POST /api/export/ticket): the right to download once, within TicketSeconds of its issue, the CSV of one list of the page with
    /// one query (the selection and the filters of the list, validated when it is issued). Its 256-bit random name is the only credential of the
    /// download (a download of the browser sends no header) and gives access to that export alone.
    /// </summary>
    internal sealed class ServeExportTicket
    {
        internal const int TicketSeconds = 60, MaxTickets = 16;
        /// <summary>The clock of the tickets (milliseconds); the tests move it.</summary>
        internal static Func<long> Clock = () => Environment.TickCount64;
        internal string View;
        internal System.Collections.Specialized.NameValueCollection Query;
        internal ServeFilter Filter;
        internal long Expires;
    }

    public static class ServeHost
    {
        public static void Run(ServeOptions options) { RunAsync(options, CancellationToken.None).GetAwaiter().GetResult(); }
        public static Task RunAsync(ServeOptions options) { return RunAsync(options, CancellationToken.None); }
        public static async Task RunAsync(ServeOptions options, CancellationToken cancellationToken)
        {
            if (options == null) throw new ArgumentNullException(nameof(options));
            if (options.Port < 0 || options.Port > 65535 || options.RequestTimeoutSeconds < 1 || options.RequestTimeoutSeconds > 120 ||
                options.AggregateTimeoutSeconds < 1 || options.AggregateTimeoutSeconds > 120 ||
                options.MmapMB < 0 || options.MmapMB > 256 || options.MaxConcurrency < 1 || options.MaxConcurrency > 8 ||
                options.ClientRowsMax < 10000 || options.ClientRowsMax > 1000000 || options.ScanBudgetMs < 100 || options.ScanBudgetMs > 120000 ||
                options.Zone == null)
                throw new ArgumentOutOfRangeException(nameof(options), "Port 0..65535, timeouts 1..120s, mmap 0..256 MB, concurrency 1..8, client rows 10000..1000000, scan budget 100..120000 ms, a time zone.");
            options.DatabasePath = Path.GetFullPath(options.DatabasePath);
            options.WebRoot = Path.GetFullPath(options.WebRoot);
            CheckPath(options.WebRoot, options.WebRoot);
            var site = Site.Load(options.WebRoot);
            if (options.ReadyFile != null && File.Exists(options.ReadyFile)) throw new IOException("Ready file exists; refusing to overwrite it.");
            int port = options.Port;
            if (port == 0)
            {
                var probe = new TcpListener(IPAddress.Loopback, 0);
                try { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; } finally { probe.Stop(); }
            }
            string origin = "http://127.0.0.1" + (port == 80 ? "" : ":" + port.ToString(CultureInfo.InvariantCulture));
            byte[] tokenBytes = RandomNumberGenerator.GetBytes(32);
            string token = Convert.ToHexString(tokenBytes).ToLowerInvariant();
            string url = origin + "/#token=" + token;
            using (var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            using (var listener = new HttpListener())
            using (var slots = new SemaphoreSlim(options.MaxConcurrency))
            using (var cache = new ServeCache(options.DatabasePath))
            {
                listener.Prefixes.Add(origin + "/");
                try { listener.Start(); }
                catch (HttpListenerException error)
                {
                    string message = "HttpListener could not bind " + origin +
                        ". Windows HTTP.sys may require an administrator-approved URL ACL for this exact 127.0.0.1 prefix (or another free port). No URL ACL, firewall or service setting was changed. " + error.Message;
                    try
                    {
                        if (options.ReadyFile != null)
                            WriteReady(options.ReadyFile, JsonSerializer.Serialize(new {
                                status = "blocked",
                                code = error.NativeErrorCode == 5 ? "HttpListenerAccessDenied" : "HttpListenerBindFailed",
                                nativeErrorCode = error.NativeErrorCode, message,
                                url = origin + "/", port, mode = "Serve", readOnly = true, processId = Environment.ProcessId }));
                    }
                    finally { CryptographicOperations.ZeroMemory(tokenBytes); }
                    throw new InvalidOperationException(message, error);
                }
                bool readyCreated = false;
                ConsoleCancelEventHandler interrupt = (s,e) => { e.Cancel = true; stop.Cancel(); };
                Console.CancelKeyPress += interrupt;
                var running = new List<Task>();
                var tickets = new ConcurrentDictionary<string, ServeExportTicket>(StringComparer.Ordinal);
                // Admission classes in progress: [Aggregate] the period aggregates and the exports, at most MaxConcurrency - 2 (at least one); [Exports]
                // the exports among them, at most ExportLimit: an export has no total deadline, so another aggregate admission remains for the overview
                // while it streams (with at least four workers); [Lists] the requests of the list layer that may scan (the counts, the value lists and
                // the filtered list pages), at most MaxConcurrency - 1. Aggregates and lists together stay below MaxConcurrency (at least one): one
                // worker always answers the unfiltered pages, the details and the report description.
                var admitted = new int[4];
                int aggregateLimit = Math.Max(1, options.MaxConcurrency - 2), listLimit = Math.Max(1, options.MaxConcurrency - 1);
                // Takes an admission of a class (an export takes one of the aggregates too), or nothing when a limit would be passed.
                Func<int, bool> admit = admission =>
                {
                    if (admission == Light) return true;
                    if (admission == Exports && Interlocked.Increment(ref admitted[Exports]) > ExportLimit) { Interlocked.Decrement(ref admitted[Exports]); return false; }
                    int counted = admission == Exports ? Aggregate : admission;
                    if (Interlocked.Increment(ref admitted[counted]) <= (counted == Aggregate ? aggregateLimit : listLimit) &&
                        Volatile.Read(ref admitted[Aggregate]) + Volatile.Read(ref admitted[Lists]) <= listLimit) return true;
                    Interlocked.Decrement(ref admitted[counted]);
                    if (admission == Exports) Interlocked.Decrement(ref admitted[Exports]);
                    return false;
                };
                Action<int> dismiss = admission =>
                {
                    if (admission == Light) return;
                    Interlocked.Decrement(ref admitted[admission == Exports ? Aggregate : admission]);
                    if (admission == Exports) Interlocked.Decrement(ref admitted[Exports]);
                };
                using (var work = new BlockingCollection<KeyValuePair<HttpListenerContext, int>>(options.MaxConcurrency))
                using (stop.Token.Register(() => listener.Stop()))
                try
                {
                    // SQLite steps synchronously; fixed workers leave the pool free for admission and deadlines.
                    for (int i = 0; i < options.MaxConcurrency; i++)
                        running.Add(Task.Factory.StartNew(() => {
                            foreach (var request in work.GetConsumingEnumerable())
                            {
                                // The admission of a request ends before its response is closed: a client that sends its next request as soon as it has
                                // read an answer finds the worker free.
                                int released = 0;
                                Action release = () => { if (Interlocked.Exchange(ref released, 1) == 0) { dismiss(request.Value); slots.Release(); } };
                                try { Handle(request.Key, options, site, origin, tokenBytes, stop, cache, tickets, release, request.Value == Lists); }
                                // The response of one request failed (its client left): that request ends, the host serves the next ones.
                                catch (Exception e) when (e is HttpListenerException || e is IOException || e is ObjectDisposedException || e is InvalidOperationException)
                                {
                                    Abort(request.Key.Response);
                                    string left = null;
                                    try { left = request.Key.Request.Url.AbsolutePath; } catch (Exception u) when (u is InvalidOperationException || u is ObjectDisposedException) { }
                                    Console.WriteLine("Serve: client left before the answer of " + Logged(left));
                                }
                                catch { stop.Cancel(); throw; }
                                finally { release(); }
                            }
                        }, CancellationToken.None, TaskCreationOptions.LongRunning | TaskCreationOptions.DenyChildAttach, TaskScheduler.Default));
                    if (options.ReadyFile != null)
                    {
                        WriteReady(options.ReadyFile, JsonSerializer.Serialize(new {
                            status = "ready", url = origin + "/", port, mode = "Serve", readOnly = true, processId = Environment.ProcessId,
                            token = options.ReadyFileWithToken ? token : null }));
                        readyCreated = true;
                    }
                    Console.WriteLine("Serve (read-only): " + origin + "/");
                    if (!options.NoBrowser)
                    {
                        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
                        catch { throw new InvalidOperationException("Could not open the browser. Restart with -NoBrowser -ReadyFile <private path> -ReadyFileWithToken for an explicit private automation token. The token was not logged."); }
                    }
                    else if (!options.ReadyFileWithToken || options.ReadyFile == null)
                        Console.WriteLine("Browser suppressed. For authenticated automation, explicitly request a private ReadyFile with ReadyFileWithToken.");
                    // The download of an export ticket (a link the browser follows and does not retry) waits for its export admission and for a
                    // worker, up to RequestTimeoutSeconds, instead of being turned away as busy; at most MaxTickets downloads wait at once.
                    int downloads = 0;
                    Func<HttpListenerContext, Task> admitDownload = async waiting =>
                    {
                        try
                        {
                            try
                            {
                                var waited = Stopwatch.StartNew();
                                if (Interlocked.Increment(ref downloads) <= ServeExportTicket.MaxTickets)
                                    for (;;)
                                    {
                                        if (admit(Exports))
                                        {
                                            if (slots.Wait(0)) { work.Add(new KeyValuePair<HttpListenerContext, int>(waiting, Exports)); return; }
                                            dismiss(Exports);
                                        }
                                        if (stop.IsCancellationRequested || waited.Elapsed.TotalSeconds >= options.RequestTimeoutSeconds) break;
                                        await Task.Delay(100).ConfigureAwait(false);
                                    }
                            }
                            finally { Interlocked.Decrement(ref downloads); }
                            await Busy(waiting, options, site, stop.Token, "The export waited for the other requests of the portal: export the view again in a moment.").ConfigureAwait(false);
                        }
                        catch (Exception e) when (e is InvalidOperationException || e is ObjectDisposedException) { Abort(waiting.Response); }
                    };
                    while (!stop.IsCancellationRequested)
                    {
                        HttpListenerContext context;
                        try { context = await listener.GetContextAsync().ConfigureAwait(false); }
                        catch (Exception e) when ((e is HttpListenerException || e is ObjectDisposedException) && stop.IsCancellationRequested) { break; }
                        // An aggregate or a request of the list layer is admitted without taking a worker beyond the share of its class; an answer the
                        // result cache holds is a light request.
                        int admission = Light;
                        string candidate = null;
                        try { candidate = SafeUrlPath(context.Request.RawUrl); } catch (ServeError) { }
                        if (candidate != null && ExportTicketPath.IsMatch(candidate))
                        {
                            // What refuses a download without its ticket is checked before the wait, without a worker; the worker takes the ticket away.
                            ServeError refused = DownloadRefusal(context.Request, origin, tickets, ExportTicketPath.Match(candidate).Groups["ticket"].Value);
                            if (refused != null) await Refuse(context, options, site, stop.Token, refused).ConfigureAwait(false);
                            else _ = admitDownload(context);
                            continue;
                        }
                        if (candidate != null && !(ServeCache.Cached(candidate) && cache.Contains(ServeCache.Key(candidate, context.Request.QueryString))))
                            admission = AggregatePath(candidate) ? Aggregate : candidate == "/api/export.csv" ? Exports : ListPath(candidate, context.Request.QueryString) ? Lists : Light;
                        if (!admit(admission))
                        {
                            await Busy(context, options, site, stop.Token, admission == Aggregate ? "Aggregate requests are at their concurrency limit; retry explicitly." :
                                admission == Exports ? "Exports are at their concurrency limit; retry explicitly." :
                                "Counts, value lists and filtered list pages are at their concurrency limit; retry explicitly.").ConfigureAwait(false);
                            continue;
                        }
                        if (!slots.Wait(0))
                        {
                            dismiss(admission);
                            await Busy(context, options, site, stop.Token, "Concurrency limit reached; retry explicitly.").ConfigureAwait(false);
                            continue;
                        }
                        work.Add(new KeyValuePair<HttpListenerContext, int>(context, admission));
                    }
                }
                finally
                {
                    stop.Cancel(); listener.Stop(); work.CompleteAdding();
                    try { await Task.WhenAll(running).ConfigureAwait(false); }
                    finally
                    {
                        Console.CancelKeyPress -= interrupt;
                        try { if (readyCreated) File.Delete(options.ReadyFile); }
                        finally { CryptographicOperations.ZeroMemory(tokenBytes); }
                    }
                }
            }
        }

        /// <summary>429 Busy with Retry-After: 1, answered by the listener loop without a worker.</summary>
        static Task Busy(HttpListenerContext context, ServeOptions options, Site site, CancellationToken stop, string message)
        {
            return Answer(context, site, stop, options.RequestTimeoutSeconds, 429, new { error = new { code = "Busy", message } }, "1");
        }
        /// <summary>The refusal of a request, answered by the listener loop without a worker, as a worker answers it.</summary>
        static Task Refuse(HttpListenerContext context, ServeOptions options, Site site, CancellationToken stop, ServeError refused)
        {
            return Answer(context, site, stop, options.RequestTimeoutSeconds, refused.Status,
                new { error = new { code = refused.Code, message = refused.Message, retryable = false, retryAfterSeconds = (int?)null } }, null);
        }
        static async Task Answer(HttpListenerContext context, Site site, CancellationToken stop, int seconds, int status, object body, string retryAfter)
        {
            using var answer = CancellationTokenSource.CreateLinkedTokenSource(stop);
            answer.CancelAfter(TimeSpan.FromSeconds(seconds));
            using var abort = answer.Token.Register(() => Abort(context.Response));
            try
            {
                Headers(context.Response, site.Policy);
                if (retryAfter != null) context.Response.Headers["Retry-After"] = retryAfter;
                // The answer to a HEAD has the headers of the answer and no body.
                byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(body);
                context.Response.StatusCode = status; context.Response.ContentType = "application/json; charset=utf-8";
                context.Response.ContentLength64 = bytes.Length;
                if (context.Request.HttpMethod != "HEAD") await context.Response.OutputStream.WriteAsync(bytes, 0, bytes.Length, answer.Token).ConfigureAwait(false);
                context.Response.Close();
            }
            // A response that fails ends that request only: the listener loop goes on.
            catch (Exception e) when (e is IOException || e is HttpListenerException || e is ObjectDisposedException || e is OperationCanceledException || e is InvalidOperationException) { Abort(context.Response); }
        }

        static void WriteReady(string path, string json)
        {
            var security = new FileSecurity();
            var owner = WindowsIdentity.GetCurrent().User;
            security.SetOwner(owner); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.FullControl, AccessControlType.Allow));
            using (var stream = FileSystemAclExtensions.Create(new FileInfo(Path.GetFullPath(path)), FileMode.CreateNew,
                FileSystemRights.FullControl, FileShare.Read, 4096, FileOptions.None, security))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(json);
        }

        static void Headers(HttpListenerResponse response, string policy)
        {
            response.Headers["Cache-Control"] = "no-store";
            response.Headers["Pragma"] = "no-cache";
            response.Headers["X-Content-Type-Options"] = "nosniff";
            response.Headers["X-Frame-Options"] = "DENY";
            response.Headers["Referrer-Policy"] = "no-referrer";
            response.Headers["Content-Security-Policy"] = policy;
        }
        static async Task Json(HttpListenerResponse response, int status, object value, CancellationToken cancel)
        {
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
            response.StatusCode = status; response.ContentType = "application/json; charset=utf-8";
            response.ContentLength64 = bytes.Length;
            await response.OutputStream.WriteAsync(bytes, 0, bytes.Length, cancel).ConfigureAwait(false);
        }
        static async Task Bytes(HttpListenerResponse response, int status, byte[] bytes, CancellationToken cancel)
        {
            response.StatusCode = status; response.ContentType = "application/json; charset=utf-8";
            response.ContentLength64 = bytes.Length;
            await response.OutputStream.WriteAsync(bytes, 0, bytes.Length, cancel).ConfigureAwait(false);
        }
        static void Abort(HttpListenerResponse response)
        {
            try { response.Abort(); }
            catch (Exception e) when (e is HttpListenerException || e is ObjectDisposedException || e is IOException) { }
        }
        static bool Auth(HttpListenerRequest request, byte[] expected)
        {
            string supplied = request.Headers["X-Portal-Token"];
            if (supplied == null || supplied.Length != 64) return false;
            byte[] actual;
            try { actual = Convert.FromHexString(supplied); } catch (FormatException) { return false; }
            bool ok = CryptographicOperations.FixedTimeEquals(actual, expected);
            CryptographicOperations.ZeroMemory(actual); return ok;
        }
        static void LocalRequest(HttpListenerRequest request, string origin)
        {
            LocalRequest(request.RemoteEndPoint, request.Headers["Host"], request.Headers["Origin"], request.Headers["Sec-Fetch-Site"], request.Url.Query.Length, origin);
        }
        /// <summary>Every request, an export ticket's download included: from the loopback, for the exact authority of the portal, from its own pages.</summary>
        static void LocalRequest(IPEndPoint remote, string host, string supplied, string site, int queryLength, string origin)
        {
            if (remote == null || !IPAddress.IsLoopback(remote.Address) || !string.Equals(host, origin.Substring("http://".Length), StringComparison.Ordinal))
                throw new ServeError(403, "LocalOnly", "Only the exact loopback authority is allowed.");
            if ((supplied != null && !string.Equals(supplied, origin, StringComparison.Ordinal)) ||
                (site != null && site != "same-origin" && site != "none"))
                throw new ServeError(403, "OriginDenied", "Cross-origin requests are not allowed.");
            if (queryLength > 4096) throw new ServeError(400, "QueryTooLong", "Query is too long.");
        }
        static readonly string[] BaseParameters = { "from","to","server","user" };
        static readonly string[] ListParameters = { "from","to","server","user","status","page","size" };
        // The lists read one day at a time by the portal also take a window on their sort key (ServeFilter.OrderFrom/OrderTo).
        static readonly string[] SlicedListParameters = ListParameters.Concat(new[] { "orderFrom", "orderTo" }).ToArray();
        // The period-aggregated report datasets read the daily tables; the window narrows the days they read.
        static readonly string[] DailyParameters = BaseParameters.Concat(new[] { "orderFrom", "orderTo" }).ToArray();
        // The keyset lists (messages, client sessions, failed and slow requests): a cursor instead of a page, and the filters of the page (q, w and the
        // f., m., x. parameters of the columns of the view, ServeCellFilter). A request with page is the offset list (page and size: automation and
        // the measurement tools), which takes no keyset parameter.
        static readonly string[] KeysetListParameters = SlicedListParameters.Except(new[] { "page" }).Concat(new[] { "cursor", "dir", "skip", "budgetMs", "q", "w", "anyCase" }).ToArray();
        // The exact count of an order window with its histogram, and its value lists: the parameters of the list but its paging.
        static readonly string[] CountParameters = BaseParameters.Concat(new[] { "status", "orderFrom", "orderTo", "cursor", "dir", "bucketMs", "budgetMs", "q", "w", "anyCase" }).ToArray();
        static readonly string[] FacetParameters = CountParameters.Except(new[] { "bucketMs" }).Concat(new[] { "columns", "cap" }).ToArray();
        static readonly Regex KeysetPath = new Regex(@"^/api/(?<view>messages|sessions|requests)(?:/(?<part>count|facets))?$", RegexOptions.CultureInvariant);
        static string KeysetView(string name) { return name == "requests" ? "issues" : name; }
        // The download of an export ticket, and the list query a ticket is issued for: the parameters of a keyset list but its paging and its window
        // (the export reads every day of the selection, every page of each day).
        static readonly Regex ExportTicketPath = new Regex(@"^/api/export/(?<ticket>[0-9a-f]{64})\.csv$", RegexOptions.CultureInvariant);
        static readonly string[] TicketParameters = { "from", "to", "server", "user", "status", "dir", "q", "w", "anyCase" };
        static readonly string[] ExportPageParameters = TicketParameters.Concat(new[] { "orderFrom", "orderTo", "cursor", "size", "budgetMs" }).ToArray();
        /// <summary>Rows of one keyset page of an export.</summary>
        internal static int ExportPageRows = 2000;
        // The aggregates read every row of their period: they have their own deadline (AggregateTimeoutSeconds) and share at most MaxConcurrency - 2
        // workers. The report description has the aggregate deadline but is a light request at admission (two small counts of the daily tables).
        static bool AggregatePath(string path)
        {
            return path == "/api/overview" || path == "/api/overview/counts" || path == "/api/overview/servers" || path == "/api/users" || path == "/api/operations" ||
                path == "/api/authentication" || AuthenticationDetailPath.IsMatch(path);
        }
        static readonly Regex AuthenticationDetailPath = new Regex(@"^/api/authentication/(?<id>[A-Za-z0-9_-]+)$", RegexOptions.CultureInvariant);
        static bool AggregateDeadline(string path) { return AggregatePath(path) || path == "/api/report-meta"; }
        // The admission classes of a request (the index of its counter): light, aggregate, a request of the list layer that may scan, an export (the
        // download of an export ticket, /api/export.csv), counted among the aggregates too.
        const int Light = 0, Aggregate = 1, Lists = 2, Exports = 3;
        const int ExportLimit = 1;
        /// <summary>
        /// The refusal of the download of an export ticket that does not need the ticket: the check of every request, then a method other than GET, a
        /// parameter or a body (a probe of the address, such as a HEAD, does not spend the ticket), then a ticket that is not waiting (unknown, used or
        /// expired). Null for a download to admit.
        /// </summary>
        static ServeError DownloadRefusal(HttpListenerRequest request, string origin, ConcurrentDictionary<string, ServeExportTicket> tickets, string name)
        {
            try { LocalRequest(request, origin); } catch (ServeError refused) { return refused; }
            if (request.HttpMethod != "GET") return new ServeError(405, "Method", "GET required.");
            if (request.RawUrl.Contains('?') || request.HasEntityBody)
                return new ServeError(400, "InvalidParameter", "An export ticket takes no parameter: it exports the selection it was issued for.");
            ServeExportTicket ticket;
            return tickets.TryGetValue(name, out ticket) && ServeExportTicket.Clock() < ticket.Expires ? null : UnknownTicket();
        }
        static ServeError UnknownTicket() { return new ServeError(404, "NotFound", "This export ticket is unknown, used or expired: export the view again from the page."); }
        /// <summary>A path as the console prints it: the name of an export ticket never appears in it.</summary>
        static string Logged(string path) { return path == null ? "?" : Regex.Replace(path, "[0-9a-f]{64}", "<ticket>", RegexOptions.CultureInvariant); }
        /// <summary>
        /// A request of the list layer that may scan: a count or value lists of a keyset list, or a keyset page with a filter of the page (q, w, f., m.,
        /// x.). An unfiltered page and the offset list are light.
        /// </summary>
        static bool ListPath(string path, System.Collections.Specialized.NameValueCollection query)
        {
            var keyset = KeysetPath.Match(path);
            if (!keyset.Success) return false;
            if (keyset.Groups["part"].Value.Length > 0) return true;
            if (query["page"] != null) return false;
            foreach (string key in query.AllKeys)
                if (key != null && (key == "q" || key == "w" || (key.Length > 2 && key[1] == '.' && (key[0] == 'f' || key[0] == 'm' || key[0] == 'x')))) return true;
            return false;
        }
        // The loopback connections of the requests are listed in the TCP table of this computer (1), once one of them has been found there.
        static int _tcpTable;
        /// <summary>
        /// Ends a request of the list layer whose client has gone (a page cancels a superseded count or page by closing its connection): its scan stops at
        /// the next step of SQLite and its worker serves the next request instead of reading to its budget. The connection is looked up in the TCP table
        /// every 250 ms; a request is ended only when its connection is listed in another state than Established, or is no longer listed while the
        /// table lists the connections of the requests.
        /// </summary>
        static Timer Watch(HttpListenerRequest request, CancellationTokenSource departed)
        {
            IPEndPoint local, remote;
            try { local = request.LocalEndPoint; remote = request.RemoteEndPoint; }
            catch (Exception e) when (e is InvalidOperationException || e is ObjectDisposedException) { return null; }
            if (local == null || remote == null) return null;
            Timer timer = null;
            timer = new Timer(_ =>
            {
                try
                {
                    System.Net.NetworkInformation.TcpState? state = null;
                    foreach (var c in System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpConnections())
                        if (c.LocalEndPoint.Equals(local) && c.RemoteEndPoint.Equals(remote)) { state = c.State; break; }
                    if (state == System.Net.NetworkInformation.TcpState.Established) { Volatile.Write(ref _tcpTable, 1); return; }
                    if (state.HasValue || Volatile.Read(ref _tcpTable) == 1) { departed.Cancel(); timer.Dispose(); }
                }
                catch (Exception e) when (e is System.Net.NetworkInformation.NetworkInformationException || e is ObjectDisposedException || e is InvalidOperationException) { }
            }, null, Timeout.Infinite, Timeout.Infinite);
            timer.Change(0, 250);
            return timer;
        }
        // Keep SQLite steps on the owning worker, including rows read after a CSV write.
        /// <param name="watch">A request of the list layer: it ends as soon as its client has gone (Watch).</param>
        static void Handle(HttpListenerContext context, ServeOptions options, Site site, string origin, byte[] token, CancellationTokenSource stop, ServeCache cache,
            ConcurrentDictionary<string, ServeExportTicket> tickets, Action release, bool watch)
        {
            var response = context.Response;
            // submitted: the answer of this request has started (its status and headers are sent): an error after it can only abort the response.
            bool streaming = false, submitted = false, shutdown = false;
            var clock = Stopwatch.StartNew();
            string path = null;
            int deadlineSeconds = options.RequestTimeoutSeconds;
            using (var departed = new CancellationTokenSource())
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, departed.Token))
            using (var watcher = watch ? Watch(context.Request, departed) : null)
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(deadlineSeconds));
                using var abortStream = deadline.Token.Register(() => { if (Volatile.Read(ref streaming)) Abort(response); });
                try
                {
                    Headers(response, site.Policy);
                    var request = context.Request;
                    LocalRequest(request, origin);
                    path = SafeUrlPath(request.RawUrl);
                    if (AggregateDeadline(path))
                    {
                        // The aggregates read every event of their period: their own deadline, from the start of the request.
                        deadlineSeconds = options.AggregateTimeoutSeconds;
                        deadline.CancelAfter(TimeSpan.FromSeconds(Math.Max(0.001, deadlineSeconds - clock.Elapsed.TotalSeconds)));
                    }
                    if (!path.StartsWith("/api/", StringComparison.Ordinal))
                    {
                        if (request.HttpMethod != "GET" && request.HttpMethod != "HEAD") throw new ServeError(405, "Method", "GET or HEAD required.");
                        // The page refuses a request before it writes (ServeError); a failed write ends in the filter of the catch below.
                        site.Serve(response, request, path, deadline.Token).GetAwaiter().GetResult();
                        return;
                    }
                    var download = ExportTicketPath.Match(path);
                    if (download.Success)
                    {
                        // The ticket is its only credential: a download refused for another reason keeps it; it is taken away at the first presentation
                        // of a download to answer, before any byte of the answer.
                        string name = download.Groups["ticket"].Value;
                        ServeExportTicket ticket;
                        var refused = DownloadRefusal(request, origin, tickets, name);
                        if (refused != null) throw refused;
                        if (!tickets.TryRemove(name, out ticket) || ServeExportTicket.Clock() >= ticket.Expires) throw UnknownTicket();
                        using (Watch(request, departed))
                            Export(response, options, ticket, deadline, () => Volatile.Write(ref streaming, true));
                        return;
                    }
                    if (!Auth(request, token)) throw new ServeError(401, "Unauthorized", "X-Portal-Token is required.");
                    if (path == "/api/shutdown")
                    {
                        if (request.HttpMethod != "POST" || request.QueryString.Count != 0 || request.HasEntityBody)
                            throw new ServeError(400, "InvalidShutdown", "Use an authenticated empty POST without query parameters.");
                        submitted = true;
                        Json(response, 200, new { stopped = true }, deadline.Token).GetAwaiter().GetResult();
                        shutdown = true; return;
                    }
                    if (path == "/api/export/ticket")
                    {
                        if (request.HttpMethod != "POST" || request.RawUrl.Contains('?') || !request.HasEntityBody)
                            throw new ServeError(400, "InvalidTicketRequest", "Use an authenticated POST without query parameters, with the JSON body {\"view\": <list>, \"query\": <the query of the list>}.");
                        var issued = IssueTicket(request, options, tickets);
                        submitted = true;
                        Json(response, 200, issued, deadline.Token).GetAwaiter().GetResult();
                        return;
                    }
                    if (request.HttpMethod != "GET") throw new ServeError(405, "Method", "GET required.");
                    if (request.HasEntityBody) throw new ServeError(400, "InvalidBody", "GET bodies are not accepted.");
                    bool meta = path == "/api/meta";
                    var keyset = KeysetPath.Match(path);
                    string part = keyset.Success ? keyset.Groups["part"].Value : null;
                    // A list without page is a keyset list; page selects the offset list, which takes no keyset parameter.
                    bool offset = keyset.Success && part.Length == 0 && keyset.Groups["view"].Value != "requests" && request.QueryString["page"] != null;
                    var filter = keyset.Success && !offset ? ServeFilter.Parse(request.QueryString,
                        part == "count" ? CountParameters : part == "facets" ? FacetParameters : KeysetListParameters, 2000, ServeView.Get(KeysetView(keyset.Groups["view"].Value))) :
                        ServeFilter.Parse(request.QueryString, meta ? new string[0] :
                        path == "/api/export.csv" ? ListParameters.Concat(new[]{"view"}).Except(new[]{"page","size"}).ToArray() :
                        path == "/api/overview" || path == "/api/overview/counts" || path == "/api/report-meta" ? BaseParameters :
                        path == "/api/overview/servers" || path == "/api/users" || Regex.IsMatch(path, @"^/api/users/[A-Za-z0-9_-]+$") ||
                        path == "/api/authentication" || AuthenticationDetailPath.IsMatch(path) ? DailyParameters :
                        path == "/api/operations" ? DailyParameters.Except(new[]{"user"}).ToArray() :
                        path == "/api/requests" ? KeysetListParameters :
                        path.StartsWith("/api/requests/", StringComparison.Ordinal) ? new[]{"from","to","user"} :
                        Regex.IsMatch(path, @"^/api/smtp/clients/[1-9]\d*$") ? BaseParameters.Concat(new[]{"status"}).ToArray() :
                        Regex.IsMatch(path, @"^/api/(?:messages|sessions|smtp(?:/transactions)?)/[1-9]\d*$") ? BaseParameters :
                        path == "/api/messages" || path == "/api/sessions" || path == "/api/smtp/transactions" ? SlicedListParameters : ListParameters,
                        // The SMTP clients are grouped over the whole selection for every page: the page of the portal takes them in one page.
                        path == "/api/smtp/clients" ? options.ClientRowsMax : 500);
                    // A count reads one day pack of the list: its order window, open on the outer side of the newest and of the oldest day only; a period of
                    // one day (at most 25 hours) is its own pack. The part of the period inside the window is at most 25 hours, with one bound or two.
                    if (part != null && part.Length > 0 && Math.Min(filter.To, filter.OrderTo ?? long.MaxValue) - Math.Max(filter.From, filter.OrderFrom ?? long.MinValue) > 25 * 3600000L)
                        throw new ServeError(400, "WindowRequired", "A count and value lists read one day of the list: give its orderFrom and orderTo (the newest day may omit orderTo, the oldest orderFrom).");
                    if (meta && !File.Exists(options.DatabasePath))
                    { submitted = true; Json(response, 200, ServeRead.MissingMeta(), deadline.Token).GetAwaiter().GetResult(); return; }
                    // The data version is read before the snapshot of the request: an answer is stored under the version it may be older than, never newer.
                    string cacheKey = ServeCache.Cached(path) ? ServeCache.Key(path, request.QueryString) : null;
                    long? version = cacheKey != null ? cache.Version() : null;
                    if (version.HasValue)
                    {
                        byte[] hit = cache.Get(cacheKey, version.Value);
                        if (hit != null) { submitted = true; Bytes(response, 200, hit, deadline.Token).GetAwaiter().GetResult(); return; }
                    }
                    using (var db = new ServeRead(options, deadline.Token))
                    {
                        if (meta) { var answer = db.Meta(options); submitted = true; Json(response, 200, answer, deadline.Token).GetAwaiter().GetResult(); return; }
                        db.Ready();
                        object result;
                        if (keyset.Success)
                        {
                            string view = KeysetView(keyset.Groups["view"].Value);
                            result = offset ? db.Page(view, filter) : part == "count" ? db.Count(view, filter) : part == "facets" ? (object)db.Facets(view, filter) : db.Keyed(view, filter);
                        }
                        else if (path == "/api/overview") result = db.Overview(filter);
                        else if (path == "/api/overview/counts") result = db.OverviewCounts(filter);
                        else if (path == "/api/smtp/clients") result = db.Page("smtpclients", filter);
                        else if (path == "/api/smtp/transactions") result = db.Page("smtp", filter);
                        else if (path == "/api/report-meta") result = db.ReportMeta(filter);
                        else if (path == "/api/overview/servers") result = db.OverviewServers(filter);

                        else if (path == "/api/users") result = db.Users(filter);
                        else if (path == "/api/operations") result = db.Operations(filter);
                        else if (path == "/api/authentication") result = db.Authentication(filter);
                        else if (path.StartsWith("/api/authentication/", StringComparison.Ordinal))
                        {
                            var match = AuthenticationDetailPath.Match(path);
                            if (!match.Success) throw new ServeError(404, "NotFound", "Unknown authentication id.");
                            result = db.AuthenticationDetail(match.Groups["id"].Value, filter);
                        }
                        else if (path.StartsWith("/api/users/", StringComparison.Ordinal))
                        {
                            var match = Regex.Match(path, @"^/api/users/(?<id>[A-Za-z0-9_-]+)$");
                            if (!match.Success) throw new ServeError(404, "NotFound", "Unknown user id.");
                            result = db.User(match.Groups["id"].Value, filter);
                        }
                        else if (path.StartsWith("/api/requests/", StringComparison.Ordinal))
                        {
                            var match = Regex.Match(path, @"^/api/requests/(?<id>[^/]{1,256})$");
                            if (!match.Success) throw new ServeError(404, "NotFound", "Unknown request ID.");
                            result = db.Request(match.Groups["id"].Value, filter);
                        }
                        else if (Regex.IsMatch(path, @"^/api/smtp/clients/[1-9]\d*/transactions$"))
                        {
                            var match = Regex.Match(path, @"^/api/smtp/clients/(?<id>[1-9]\d*)/transactions$");
                            long id;
                            if (!long.TryParse(match.Groups["id"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out id))
                                throw new ServeError(404, "NotFound", "SMTP client not found.");
                            result = db.ClientTransactions(id, filter);
                        }
                        else if (path == "/api/export.csv")
                        {
                            if (filter.View != "messages" && filter.View != "sessions" && filter.View != "smtp" && filter.View != "smtp-transactions")
                                throw new ServeError(400, "InvalidView", "view must be messages, sessions, smtp or smtp-transactions.");
                            string view = filter.View == "smtp" ? "smtpclients" : filter.View == "smtp-transactions" ? "smtp" : filter.View;
                            response.ContentType = "text/csv; charset=utf-8";
                            response.Headers["Content-Disposition"] = "attachment; filename=\"" + filter.View + ".csv\"";
                            response.Headers["X-Export-Completion"] = "A complete chunked HTTP body is required; timeout or query failure aborts the stream.";
                            response.SendChunked = true;
                            // Validate/step the reader before sending the first byte.
                            using (var rows = db.ReadRows(view, filter, true).GetEnumerator())
                            {
                                bool more = rows.MoveNext();
                                streaming = true;
                                Write(response, "\uFEFF" + string.Join(";", ServeRead.Columns(view).Select(c => Csv(c.name))) + "\r\n", deadline.Token).GetAwaiter().GetResult();
                                while (more)
                                {
                                    deadline.Token.ThrowIfCancellationRequested();
                                    Write(response, string.Join(";", rows.Current.cells.Select(Csv)) + "\r\n", deadline.Token).GetAwaiter().GetResult();
                                    more = rows.MoveNext();
                                }
                            }
                            return;
                        }
                        else
                        {
                            var match = Regex.Match(path, @"^/api/(?<view>messages|sessions|smtp(?:/(?:clients|transactions))?)/(?<id>[1-9]\d*)$");
                            long id;
                            if (!match.Success || !long.TryParse(match.Groups["id"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out id))
                                throw new ServeError(404, "NotFound", "Unknown API route.");
                            result = match.Groups["view"].Value == "messages" ? db.Message(id, filter) :
                                match.Groups["view"].Value == "sessions" ? db.Session(id, filter) :
                                match.Groups["view"].Value == "smtp/clients" ? db.Client(id, filter) : db.Smtp(id, filter);
                        }
                        deadline.Token.ThrowIfCancellationRequested();
                        // A count or value lists stopped by the scan budget is not a complete answer: it is not kept.
                        if (version.HasValue && !(result is IServePartial partial && !partial.Finished))
                        {
                            byte[] body = JsonSerializer.SerializeToUtf8Bytes(result);
                            cache.Put(cacheKey, version.Value, body);
                            submitted = true;
                            Bytes(response, 200, body, deadline.Token).GetAwaiter().GetResult();
                        }
                        else { submitted = true; Json(response, 200, result, deadline.Token).GetAwaiter().GetResult(); }
                    }
                }
                catch (Exception error)
                {
                    // A client that has gone has nothing to read.
                    if (streaming || submitted || stop.IsCancellationRequested || departed.IsCancellationRequested) { Abort(response); }
                    else
                    {
                        var known = error as ServeError;
                        var sqlite = error as SqliteException;
                        int status = deadline.IsCancellationRequested ? 504 : known != null ? known.Status : sqlite != null && (sqlite.SqliteErrorCode == 5 || sqlite.SqliteErrorCode == 6) ? 503 :
                            sqlite != null && sqlite.SqliteErrorCode == 9 ? 504 : 500;
                        string code = status == 504 ? "Deadline" : known != null ? known.Code : status == 503 ? "DatabaseBusy" : "QueryFailed";
                        // 503 (busy, pending reconciliation) and 504 (deadline) are retryable: a deadline hit after real read work leaves the pages it read
                        // in the operating system cache, so one retry is cheaper.
                        if (status == 503) response.Headers["Retry-After"] = "1";
                        if (status == 504)
                        {
                            response.Headers["Retry-After"] = "2";
                            // One console line per 504 (Serve writes no log file): tells a cold cache from a structurally slow request.
                            Console.WriteLine("Serve: 504 " + Logged(path) + " after " + clock.ElapsedMilliseconds.ToString("N0", CultureInfo.InvariantCulture) +
                                " ms (deadline " + deadlineSeconds.ToString(CultureInfo.InvariantCulture) + " s)");
                        }
                        string message = status == 504 ? "The request exceeded its deadline of " + deadlineSeconds.ToString(CultureInfo.InvariantCulture) +
                            " s. The pages it read are now cached: retry once, then narrow the period or the server." :
                            known != null ? known.Message : "Request failed; no fallback or migration was performed.";
                        try { Json(response, status, new { error = new { code, message, retryable = status == 503 || status == 504,
                            retryAfterSeconds = status == 504 ? (int?)2 : status == 503 ? (int?)1 : null } }, CancellationToken.None).GetAwaiter().GetResult(); }
                        catch (Exception e) when (e is IOException || e is HttpListenerException || e is ObjectDisposedException || e is InvalidOperationException) { Abort(response); }
                    }
                }
                finally
                {
                    release();
                    try { response.Close(); }
                    catch (Exception e) when (e is IOException || e is HttpListenerException || e is ObjectDisposedException || e is InvalidOperationException) { }
                    if (shutdown) stop.Cancel();
                }
            }
        }
        static Task Write(HttpListenerResponse response, string text, CancellationToken cancel)
        { var bytes = Encoding.UTF8.GetBytes(text); return response.OutputStream.WriteAsync(bytes, 0, bytes.Length, cancel); }

        /// <summary>
        /// Issues an export ticket for the JSON body {"view": "sessions" | "issues" | "messages", "query": the list query of the page}: the query is
        /// parsed with the parameters of a ticket and the filters of the view (a bad query is refused here, not in the download), the expired tickets
        /// are dropped and at most MaxTickets wait to be downloaded.
        /// </summary>
        static object IssueTicket(HttpListenerRequest request, ServeOptions options, ConcurrentDictionary<string, ServeExportTicket> tickets)
        {
            if (!(request.ContentType ?? "").StartsWith("application/json", StringComparison.OrdinalIgnoreCase))
                throw new ServeError(415, "InvalidTicketRequest", "The body of a ticket request is JSON (Content-Type: application/json).");
            var body = new MemoryStream();
            var buffer = new byte[4096];
            int n;
            while ((n = request.InputStream.Read(buffer, 0, buffer.Length)) > 0)
            {
                body.Write(buffer, 0, n);
                if (body.Length > 16384) throw new ServeError(413, "InvalidTicketRequest", "The body of a ticket request is at most 16 KiB.");
            }
            string view, text;
            try
            {
                using (var json = JsonDocument.Parse(body.ToArray()))
                {
                    var root = json.RootElement;
                    JsonElement v, q;
                    if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Any(p => p.Name != "view" && p.Name != "query") ||
                        !root.TryGetProperty("view", out v) || v.ValueKind != JsonValueKind.String || !root.TryGetProperty("query", out q) || q.ValueKind != JsonValueKind.String)
                        throw new FormatException();
                    view = v.GetString(); text = q.GetString();
                }
            }
            catch (Exception e) when (e is JsonException || e is FormatException)
            { throw new ServeError(400, "InvalidTicketRequest", "The body of a ticket request is {\"view\": <list>, \"query\": <the query of the list>}."); }
            if (view != "sessions" && view != "issues" && view != "messages") throw new ServeError(400, "InvalidView", "view must be sessions, issues or messages.");
            if (text.Length > 4096) throw new ServeError(400, "QueryTooLong", "Query is too long.");
            var query = QueryOf(text);
            var filter = ServeFilter.Parse(query, TicketParameters, ExportPageRows, ServeView.Get(view));
            // An export reads every row of its period: the period is never the default of a list (the last seven days).
            if (query["from"] == null || query["to"] == null)
                throw new ServeError(400, "InvalidPeriod", "An export ticket is issued for an explicit period: give its from and to.");
            ServeCellFilter.Parse(ServeView.Get(view), query, options.Zone);
            ServeRead.Days(filter, options.Zone);
            long now = ServeExportTicket.Clock();
            foreach (var old in tickets) if (now >= old.Value.Expires) tickets.TryRemove(old.Key, out _);
            if (tickets.Count >= ServeExportTicket.MaxTickets)
                throw new ServeError(429, "Busy", ServeExportTicket.MaxTickets.ToString(CultureInfo.InvariantCulture) + " exports are waiting to be downloaded: export the view again in a minute.");
            byte[] random = RandomNumberGenerator.GetBytes(32);
            string name = Convert.ToHexString(random).ToLowerInvariant();
            CryptographicOperations.ZeroMemory(random);
            tickets[name] = new ServeExportTicket { View = view, Query = query, Filter = filter, Expires = now + ServeExportTicket.TicketSeconds * 1000L };
            return new { ticket = name, expiresInSeconds = ServeExportTicket.TicketSeconds, url = "/api/export/" + name + ".csv" };
        }

        /// <summary>The parameters of a query string as the listener reads those of a request ("+" is a space, %XX an escaped byte).</summary>
        static System.Collections.Specialized.NameValueCollection QueryOf(string text)
        {
            var query = new System.Collections.Specialized.NameValueCollection();
            Func<string, string> decode = s => Uri.UnescapeDataString(s.Replace('+', ' '));
            foreach (string pair in text.TrimStart('?').Split('&'))
            {
                if (pair.Length == 0) continue;
                int eq = pair.IndexOf('=');
                query.Add(decode(eq < 0 ? pair : pair.Substring(0, eq)), eq < 0 ? "" : decode(pair.Substring(eq + 1)));
            }
            return query;
        }

        /// <summary>
        /// Streams the CSV of an export ticket: the grid columns of the list's dataset, then its rows day by day (the newest day first, the oldest first
        /// with dir=asc), each day on a read-only connection of its own, in keyset pages of ExportPageRows rows with the filters of the ticket (a page
        /// that a scan ends at its budget continues from its cursor). No deadline in total: the deadline of the request is a stall watchdog, set again
        /// after each page; a client that leaves ends the stream.
        /// </summary>
        static void Export(HttpListenerResponse response, ServeOptions options, ServeExportTicket ticket, CancellationTokenSource deadline, Action started)
        {
            var view = ServeView.Get(ticket.View);
            var csv = new ServeExportCsv(ticket.View, options.Zone);
            var days = ServeRead.Days(ticket.Filter, options.Zone);
            // The window of each day on the list key, as report-meta gives the day packs: the newest day open above, the oldest open below.
            var windows = days.Select((d, k) => new[] { k == days.Count - 1 ? (long?)null : d.Item2, k == 0 ? (long?)null : d.Item3 }).ToList();
            if (ticket.Filter.Ascending) windows.Reverse();
            string budget = Math.Max(100, Math.Min(options.ScanBudgetMs, options.RequestTimeoutSeconds * 1000 - 1000)).ToString(CultureInfo.InvariantCulture);
            bool begun = false;
            foreach (var window in windows)
                using (var db = new ServeRead(options, deadline.Token))
                {
                    db.Ready();
                    if (!begun)
                    {
                        response.ContentType = "text/csv; charset=utf-8";
                        response.Headers["Content-Disposition"] = "attachment; filename=\"" + ticket.View + "-" + TimeUtil.Day(ticket.Filter.From, options.Zone) + "-" +
                            TimeUtil.Day(ticket.Filter.To - 1, options.Zone) + ".csv\"";
                        response.Headers["X-Export-Completion"] = "A complete chunked HTTP body is required; a stalled or failed read aborts the stream.";
                        response.SendChunked = true;
                        started();
                        Write(response, csv.Header(), deadline.Token).GetAwaiter().GetResult();
                        begun = true;
                    }
                    string cursor = null;
                    for (;;)
                    {
                        var query = new System.Collections.Specialized.NameValueCollection(ticket.Query);
                        if (window[0].HasValue) query["orderFrom"] = ServeRead.Iso(window[0]);
                        if (window[1].HasValue) query["orderTo"] = ServeRead.Iso(window[1]);
                        query["size"] = ExportPageRows.ToString(CultureInfo.InvariantCulture);
                        query["budgetMs"] = budget;
                        if (cursor != null) query["cursor"] = cursor;
                        var page = db.Keyed(ticket.View, ServeFilter.Parse(query, ExportPageParameters, ExportPageRows, view));
                        if (page.rows.Count > 0) Write(response, csv.Lines(page.rows), deadline.Token).GetAwaiter().GetResult();
                        deadline.CancelAfter(TimeSpan.FromSeconds(options.RequestTimeoutSeconds));
                        if (page.exhausted == true || page.nextCursor == null) break;
                        cursor = page.nextCursor;
                    }
                }
        }
        static string Csv(object value)
        {
            if (value == null || value is long || value is int || value is double) return ReportBuilder.Csv(value, ";");
            string text;
            if (value is string) text = (string)value;
            else if (value is IEnumerable<string>) text = string.Join("; ", (IEnumerable<string>)value);
            else text = Convert.ToString(value, CultureInfo.InvariantCulture);
            string leading = text.TrimStart();
            if (leading.Length > 0 && ("=+-@".IndexOf(leading[0]) >= 0 || text[0] == '\t' || text[0] == '\r' || text[0] == '\n')) text = "'" + text;
            return ReportBuilder.Csv(text, ";");
        }
        static string SafeUrlPath(string raw)
        {
            string path = raw.Split('?')[0];
            try { path = Uri.UnescapeDataString(path); }
            catch (UriFormatException) { throw new ServeError(400, "InvalidPath", "Malformed path."); }
            if (!path.StartsWith("/", StringComparison.Ordinal) || path.Contains('\\') || path.Contains('%') || path.Contains(':') ||
                path.Any(char.IsControl) || path.Split('/').Any(x => x == "." || x == ".."))
                throw new ServeError(400, "InvalidPath", "Unsafe path.");
            return path;
        }
        static void CheckPath(string root, string file)
        {
            string canonical = Path.GetFullPath(file);
            if (!canonical.Equals(root, StringComparison.OrdinalIgnoreCase) && !canonical.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new ServeError(400, "InvalidPath", "Path leaves web root.");
            var current = new DirectoryInfo(Path.GetDirectoryName(canonical));
            while (current != null)
            {
                if ((current.Attributes & FileAttributes.ReparsePoint) != 0) throw new ServeError(403, "ReparsePoint", "Reparse paths are not served.");
                current = current.Parent;
            }
            if ((File.GetAttributes(canonical) & FileAttributes.ReparsePoint) != 0) throw new ServeError(403, "ReparsePoint", "Reparse paths are not served.");
        }
        // script-src: 'self' and the hash of each inline script the page runs: every inline script without src or type (the theme, the queue of the
        // data files).
        static string ContentSecurity(string html)
        {
            var hashes = new StringBuilder();
            foreach (Match m in Regex.Matches(html, @"<script\b(?<attributes>[^>]*)>(?<body>[\s\S]*?)</script\s*>", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                string attributes = m.Groups["attributes"].Value, body = m.Groups["body"].Value;
                if (!Regex.IsMatch(attributes, @"(?:^|\s)(?:src|type)\s*=", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                    hashes.Append(" 'sha256-" + Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(body.Replace("\r\n", "\n").Replace('\r', '\n')))) + "'");
            }
            return "default-src 'self'; script-src 'self'" + hashes + "; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
        }

        /// <summary>
        /// The page of the portal: the Detailed report's own page, from the folder of the report template (WebRoot: the package's templates folder,
        /// Report.template.html and its main script Report.template.js). The page is built once at start from the template, without data, with the
        /// description {"served":true} and the main script as report.js; the only static paths are "/" (scoutTheme=light|dark is its one parameter)
        /// and "/report.js". No other file of the folder is served.
        /// </summary>
        sealed class Site
        {
            internal readonly string Policy;
            readonly byte[] _page, _script;
            Site(string policy, byte[] page, byte[] script) { Policy = policy; _page = page; _script = script; }

            internal static Site Load(string root)
            {
                string template = Path.Combine(root, ReportBuilder.TemplateName);
                if (!File.Exists(template))
                    throw new FileNotFoundException("The web root must be the folder of the report template (" + ReportBuilder.TemplateName + " and its script): " + root);
                string script = ReportBuilder.TemplateScriptPath(template);
                if (!File.Exists(script)) throw new FileNotFoundException("The report template needs its main script next to it: " + script);
                CheckPath(root, template); CheckPath(root, script);
                string page = ReportBuilder.ServedPage(File.ReadAllText(template, Encoding.UTF8), File.ReadAllText(script, Encoding.UTF8), template);
                var utf8 = new UTF8Encoding(false);
                return new Site(ContentSecurity(page), utf8.GetBytes(page), utf8.GetBytes(File.ReadAllText(script, Encoding.UTF8)));
            }

            internal Task Serve(HttpListenerResponse response, HttpListenerRequest request, string path, CancellationToken cancel)
            {
                bool head = request.HttpMethod == "HEAD";
                byte[] body = path == "/" ? _page : path == "/report.js" ? _script : null;
                if (body == null) throw new ServeError(404, "NotFound", "Static resource not found.");
                if (request.QueryString.Count != 0)
                {
                    string[] theme = path == "/" && request.QueryString.Count == 1 ? request.QueryString.GetValues("scoutTheme") : null;
                    if (theme == null || theme.Length != 1 || (theme[0] != "light" && theme[0] != "dark"))
                        throw new ServeError(400, "InvalidParameter", "The portal page takes no parameter but scoutTheme=light or dark; its selection is in the address after #.");
                }
                response.ContentType = (path == "/" ? "text/html" : "text/javascript") + "; charset=utf-8";
                response.ContentLength64 = body.Length;
                return head ? Task.CompletedTask : response.OutputStream.WriteAsync(body, 0, body.Length, cancel);
            }
        }
    }

    /// <summary>
    /// The CSV of the page's Export view (Report.template.js, the export of the rows shown), written by the server for the rows of a list it streams:
    /// a byte order mark and the names of the grid columns of the list's dataset, then one line per row, ";" between the cells and CRLF after each
    /// line. A cell is the text the table of the page shows (cellText): a time as the wall clock of the report time zone (yyyy-MM-dd HH:mm:ss), a
    /// number as the page writes it (a whole number grouped with ",", another one as en-GB writes it, at most three decimals), the items of a list
    /// joined with "; ", empty for a column the list does not carry; a text that starts with = + - @, a tab or a CR takes a leading ', a text that
    /// holds a quote, a ";", a CR or a LF is quoted. The same rows give the same lines as the export of the page (Serve.Page checks it). The order
    /// of the rows is that of the list on the server, by instant and id, where the page sorts the rows it holds by the time it shows, keeping the
    /// order it loaded them in for equal times: inside the repeated hour of a daylight-saving change, and for rows of the same millisecond in an
    /// ascending sort (the page keeps the newest id first), the same lines come in another order; elsewhere the files are equal byte for byte.
    /// </summary>
    internal sealed class ServeExportCsv
    {
        readonly string[] _names, _kinds;
        readonly int[] _cells;
        readonly TimeZoneInfo _zone;
        // The offset of the zone per quarter of an hour (every change of offset happens on a quarter of an hour), as the page keeps it.
        readonly Dictionary<long, long> _offsets = new Dictionary<long, long>();
        static readonly Regex Iso = new Regex(@"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$", RegexOptions.CultureInvariant);
        const double MaxSafe = 9007199254740991;

        internal ServeExportCsv(string view, TimeZoneInfo zone)
        {
            _zone = zone;
            var list = ServeRead.ListColumns(view).Select(c => c.name).ToList();
            var grid = ServeRead.ListDataset(view).Where(c => c.grid).ToArray();
            _names = grid.Select(c => c.name).ToArray(); _kinds = grid.Select(c => c.kind).ToArray(); _cells = grid.Select(c => list.IndexOf(c.name)).ToArray();
        }

        internal string Header() { return "\uFEFF" + string.Join(";", _names.Select(Escape)) + "\r\n"; }

        internal string Lines(IEnumerable<ServeRow> rows)
        {
            var text = new StringBuilder();
            foreach (var row in rows)
            {
                for (int j = 0; j < _names.Length; j++)
                {
                    if (j > 0) text.Append(';');
                    object v = _cells[j] < 0 ? null : row.cells[_cells[j]];
                    text.Append(Escape(_kinds[j] == "list" && v is System.Collections.IEnumerable items && !(v is string) ? Items(items, "; ") : Cell(_kinds[j], v)));
                }
                text.Append("\r\n");
            }
            return text.ToString();
        }

        internal static string Escape(string v)
        {
            if (v.Length > 0 && "=+-@\t\r".IndexOf(v[0]) >= 0) v = "'" + v;
            return v.IndexOfAny(new[] { '"', ';', '\r', '\n' }) >= 0 ? "\"" + v.Replace("\"", "\"\"") + "\"" : v;
        }

        string Cell(string kind, object v)
        {
            if (v == null) return "";
            if (kind == "time") return Stamp(v);
            if (kind == "num") return Number(v);
            return Text(v);
        }

        /// <summary>String(v) of the page; the items of an array joined with separator, an empty item for null (Array.prototype.join).</summary>
        static string Items(System.Collections.IEnumerable items, string separator)
        {
            var parts = new List<string>();
            foreach (object item in items) parts.Add(item == null ? "" : Text(item));
            return string.Join(separator, parts);
        }
        static string Text(object v)
        {
            if (v == null) return "";
            if (v is string s) return s;
            if (v is bool b) return b ? "true" : "false";
            if (v is double || v is float) return Script(Convert.ToDouble(v, CultureInfo.InvariantCulture));
            if (v is System.Collections.IEnumerable items) return Items(items, ",");
            return Convert.ToString(v, CultureInfo.InvariantCulture);
        }

        /// <summary>stamp() of the page: the wall clock of an ISO instant of the API in the report time zone, to the second (floor).</summary>
        string Stamp(object v)
        {
            double seconds;
            var s = v as string;
            if (s == null) seconds = ScriptNumber(v);
            else
            {
                var m = Iso.Match(s);
                if (!m.Success) return "NaN-NaN-NaN NaN:NaN:NaN";
                Func<int, int> at = i => int.Parse(m.Groups[i].Value, CultureInfo.InvariantCulture);
                long ms;
                try { ms = new DateTimeOffset(at(1), at(2), at(3), at(4), at(5), at(6), TimeSpan.Zero).ToUnixTimeMilliseconds(); }
                catch (ArgumentOutOfRangeException) { return "NaN-NaN-NaN NaN:NaN:NaN"; }
                if (m.Groups[7].Success) ms += int.Parse((m.Groups[7].Value + "00").Substring(0, 3), CultureInfo.InvariantCulture);
                string zone = m.Groups[8].Value;
                if (zone != "Z") ms -= (zone[0] == '-' ? -1 : 1) * (int.Parse(zone.Substring(1, 2), CultureInfo.InvariantCulture) * 60 + int.Parse(zone.Substring(4, 2), CultureInfo.InvariantCulture)) * 60000L;
                long q = (long)Math.Floor(ms / 900000.0), offset;
                if (!_offsets.TryGetValue(q, out offset))
                {
                    if (_offsets.Count > 20000) _offsets.Clear();
                    _offsets[q] = offset = (long)_zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(q * 900000)).TotalMilliseconds;
                }
                seconds = (ms + offset) / 1000.0;
            }
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || Math.Abs(seconds) > 8.64e12) return "NaN-NaN-NaN NaN:NaN:NaN";
            return DateTime.UnixEpoch.AddSeconds(Math.Floor(seconds)).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }

        /// <summary>number() of the page: "" for an empty value, a safe integer grouped with ",", any other number as toLocaleString("en-GB") writes it.</summary>
        static string Number(object v)
        {
            if (v is string s && s.Length == 0) return "";
            double x = ScriptNumber(v);
            if (Math.Floor(x) == x && Math.Abs(x) <= MaxSafe) return ((long)x).ToString("#,0", CultureInfo.InvariantCulture);
            if (double.IsNaN(x)) return "NaN";
            if (double.IsInfinity(x)) return x > 0 ? "\u221E" : "-\u221E";
            // The shortest digits of the number (as the browser's number formatting starts from them), rounded half up to three decimals.
            string digits; int point;
            Digits(Math.Abs(x), out digits, out point);
            int keep = point + 3;
            if (keep < digits.Length)
            {
                bool up = keep >= 0 && digits[keep] >= '5';
                digits = keep > 0 ? digits.Substring(0, keep) : "";
                if (up)
                {
                    var d = digits.ToCharArray();
                    int i = d.Length - 1;
                    while (i >= 0 && d[i] == '9') d[i--] = '0';
                    if (i >= 0) { d[i]++; digits = new string(d); }
                    else { digits = "1" + new string(d); point++; }
                }
            }
            string whole = point > 0 ? digits.PadRight(point, '0').Substring(0, point) : "0";
            string fraction = (point >= 0 ? (digits.Length > point ? digits.Substring(point) : "") : new string('0', -point) + digits).TrimEnd('0');
            var grouped = new StringBuilder();
            for (int i = 0; i < whole.Length; i++) { if (i > 0 && (whole.Length - i) % 3 == 0) grouped.Append(','); grouped.Append(whole[i]); }
            whole = grouped.ToString().TrimStart('0', ',');
            if (whole.Length == 0) whole = "0";
            return (x < 0 ? "-" : "") + whole + (fraction.Length > 0 ? "." + fraction : "");
        }

        /// <summary>Number(v) of the page for a value of the API.</summary>
        static double ScriptNumber(object v)
        {
            if (v == null) return 0;
            if (v is bool b) return b ? 1 : 0;
            if (v is string s)
            {
                s = s.Trim();
                double parsed;
                return s.Length == 0 ? 0 : double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) ? parsed : double.NaN;
            }
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch (Exception e) when (e is InvalidCastException || e is FormatException) { return double.NaN; }
        }

        /// <summary>String(x) of the page for a double: its shortest digits, in plain or exponential notation as JavaScript writes them.</summary>
        static string Script(double x)
        {
            if (double.IsNaN(x)) return "NaN";
            if (double.IsInfinity(x)) return x > 0 ? "Infinity" : "-Infinity";
            if (x == 0) return "0";
            string digits; int n;
            Digits(Math.Abs(x), out digits, out n);
            int k = digits.Length;
            string text = k <= n && n <= 21 ? digits + new string('0', n - k) : 0 < n && n <= 21 ? digits.Substring(0, n) + "." + digits.Substring(n) :
                -6 < n && n <= 0 ? "0." + new string('0', -n) + digits :
                digits.Substring(0, 1) + (k > 1 ? "." + digits.Substring(1) : "") + "e" + (n - 1 < 0 ? "-" : "+") + Math.Abs(n - 1).ToString(CultureInfo.InvariantCulture);
            return (x < 0 ? "-" : "") + text;
        }

        /// <summary>The shortest round-trip digits of a positive double (no leading or trailing zero) and the position of the decimal point in them.</summary>
        static void Digits(double x, out string digits, out int point)
        {
            string r = x.ToString("R", CultureInfo.InvariantCulture);
            int e = r.IndexOf('E'), exponent = 0;
            if (e >= 0) { exponent = int.Parse(r.Substring(e + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture); r = r.Substring(0, e); }
            int dot = r.IndexOf('.');
            digits = dot < 0 ? r : r.Remove(dot, 1);
            point = (dot < 0 ? r.Length : dot) + exponent;
            int zeros = 0;
            while (zeros < digits.Length - 1 && digits[zeros] == '0') zeros++;
            digits = digits.Substring(zeros); point -= zeros;
            digits = digits.TrimEnd('0');
            if (digits.Length == 0) { digits = "0"; point = 1; }
        }
    }

    /// <summary>
    /// The complete answers of the period aggregates (/api/overview/servers, /api/users, /api/operations, /api/authentication) and of the counts and value lists of the
    /// lists (/api/{messages|sessions|requests}/{count|facets}, when they read their window to its end) of one Serve host, kept while the database does
    /// not change: before each look-up a sentinel read-only connection reads PRAGMA data_version, whose value changes when another connection commits
    /// to the database, and a change empties the cache (Serve never writes). An answer is stored with "cached":true in place of its leading
    /// "cached":false; the least recently used answers go first above CapacityBytes (0 turns the cache off).
    /// </summary>
    internal sealed class ServeCache : IDisposable
    {
        internal static long CapacityBytes = 64L * 1048576;
        static readonly byte[] Fresh = Encoding.UTF8.GetBytes("{\"cached\":false,"), Stored = Encoding.UTF8.GetBytes("{\"cached\":true,");
        readonly string _path;
        readonly object _lock = new object();
        readonly Dictionary<string, LinkedListNode<KeyValuePair<string, byte[]>>> _entries = new Dictionary<string, LinkedListNode<KeyValuePair<string, byte[]>>>(StringComparer.Ordinal);
        readonly LinkedList<KeyValuePair<string, byte[]>> _recent = new LinkedList<KeyValuePair<string, byte[]>>();
        SqliteConnection _sentinel;
        long _version = long.MinValue, _bytes;

        internal ServeCache(string path) { _path = path; }

        internal static bool Cached(string path)
        {
            return path == "/api/overview/servers" || path == "/api/users" || path == "/api/operations" || path == "/api/authentication" ||
                Regex.IsMatch(path, @"^/api/(?:messages|sessions|requests)/(?:count|facets)$", RegexOptions.CultureInvariant);
        }

        /// <summary>The path and its parameters sorted by name (each name and value escaped): the same request whatever the order of its parameters.</summary>
        internal static string Key(string path, System.Collections.Specialized.NameValueCollection query)
        {
            var parts = new List<string>();
            foreach (string name in query.AllKeys)
                foreach (string value in query.GetValues(name) ?? new string[0])
                    parts.Add(Uri.EscapeDataString(name ?? "") + "=" + Uri.EscapeDataString(value ?? ""));
            parts.Sort(StringComparer.Ordinal);
            return path + "?" + string.Join("&", parts);
        }

        /// <summary>The data version of the database now (the cache is emptied when it changed), or null when it cannot be read: nothing is cached then.</summary>
        internal long? Version()
        {
            if (CapacityBytes <= 0) return null;
            lock (_lock)
            {
                try
                {
                    if (_sentinel == null)
                    {
                        if (!File.Exists(_path)) return null;
                        var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Store.SqlitePath(_path), Mode = SqliteOpenMode.ReadOnly,
                            Cache = SqliteCacheMode.Private, Pooling = false, DefaultTimeout = 1 }.ToString());
                        try { db.Open(); } catch { db.Dispose(); throw; }
                        _sentinel = db;
                    }
                    long version;
                    using (var c = _sentinel.CreateCommand()) { c.CommandText = "PRAGMA data_version;"; version = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture); }
                    if (version != _version) { _entries.Clear(); _recent.Clear(); _bytes = 0; _version = version; }
                    return version;
                }
                catch (SqliteException)
                {
                    if (_sentinel != null) { _sentinel.Dispose(); _sentinel = null; }
                    _entries.Clear(); _recent.Clear(); _bytes = 0; _version = long.MinValue;
                    return null;
                }
            }
        }

        internal bool Contains(string key) { lock (_lock) return _entries.ContainsKey(key); }

        internal byte[] Get(string key, long version)
        {
            lock (_lock)
            {
                LinkedListNode<KeyValuePair<string, byte[]>> node;
                if (version != _version || !_entries.TryGetValue(key, out node)) return null;
                _recent.Remove(node); _recent.AddFirst(node);
                return node.Value.Value;
            }
        }

        /// <summary>Keeps a complete answer read under version (an answer that does not start with "cached":false is not kept).</summary>
        internal void Put(string key, long version, byte[] body)
        {
            if (body.Length < Fresh.Length || !body.AsSpan(0, Fresh.Length).SequenceEqual(Fresh)) return;
            var stored = new byte[body.Length - 1];
            Stored.CopyTo(stored, 0);
            Buffer.BlockCopy(body, Fresh.Length, stored, Stored.Length, body.Length - Fresh.Length);
            lock (_lock)
            {
                if (version != _version || stored.Length > CapacityBytes) return;
                LinkedListNode<KeyValuePair<string, byte[]>> old;
                if (_entries.TryGetValue(key, out old)) { _recent.Remove(old); _bytes -= old.Value.Value.Length; }
                _entries[key] = _recent.AddFirst(new KeyValuePair<string, byte[]>(key, stored));
                _bytes += stored.Length;
                while (_bytes > CapacityBytes && _recent.Last != null)
                {
                    var last = _recent.Last; _recent.RemoveLast(); _entries.Remove(last.Value.Key); _bytes -= last.Value.Value.Length;
                }
            }
        }

        public void Dispose() { lock (_lock) { if (_sentinel != null) { _sentinel.Dispose(); _sentinel = null; } } }
    }
}