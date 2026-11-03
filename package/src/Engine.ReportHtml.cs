// =============================================================================
//  Exchange Log Report - engine, part 4b: HTML report (data files and page)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 3.0.0
//
//  The page and its data. Every table is written first as data files (plain JavaScript: __exl.file / __exl.push
//  statements with gzip + base64 payloads); the report then either copies those files into the page (one file) or
//  keeps them in <FilePrefix>_data next to a small page. Both layouts use the same data, read by the same loader.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace ExchangeLogReport
{
    public static partial class ReportBuilder
    {
        // ------------------------------------------------------------------ template
        // templates\Report.template.html holds three markers, each exactly once: the report description (META), the data files of a single-file
        // report (CHUNKS) and the main script (SCRIPT), which is the file of the same name with the extension .js (Report.template.js). A static
        // report copies the script into the page; the portal serves it as report.js (ServedPage).

        internal const string TemplateName = "Report.template.html";
        internal static readonly string[] TemplateMarkers = { "%%META%%", "%%CHUNKS%%", "%%SCRIPT%%" };
        internal static string TemplateScriptPath(string templatePath) { return Path.ChangeExtension(templatePath, ".js"); }

        /// <summary>The markers of the template, each exactly once, and a main script that can be copied into a script element.</summary>
        internal static void CheckTemplate(string template, string script, string path)
        {
            foreach (var marker in TemplateMarkers)
            {
                int first = template.IndexOf(marker, StringComparison.Ordinal);
                if (first < 0 || template.IndexOf(marker, first + 1, StringComparison.Ordinal) >= 0) throw new InvalidDataException("The template must contain " + marker + " exactly once: " + path);
            }
            if (script != null && script.IndexOf("</script", StringComparison.OrdinalIgnoreCase) >= 0)
                throw new InvalidDataException("The main script of the template must not contain </script: " + TemplateScriptPath(path));
        }

        /// <summary>
        /// The page of the portal: the template without data files, with {"served":true} as the description and its main script as report.js
        /// (the element that holds the SCRIPT marker becomes &lt;script src="report.js"&gt;).
        /// </summary>
        internal static string ServedPage(string template, string script, string path)
        {
            CheckTemplate(template, script, path);
            var main = new System.Text.RegularExpressions.Regex(@"<script>\s*%%SCRIPT%%\s*</script>", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
            if (!main.IsMatch(template)) throw new InvalidDataException("The template must hold its main script as <script>%%SCRIPT%%</script>: " + path);
            return main.Replace(template.Replace("%%CHUNKS%%", "").Replace("%%META%%", "{\"served\":true}"), "<script src=\"report.js\"></script>", 1);
        }

        // ------------------------------------------------------------------ HTML

        static void WriteValue(Utf8JsonWriter w, object v)
        {
            if (v == null || v is DBNull) { w.WriteNullValue(); return; }
            var s = v as string; if (s != null) { w.WriteStringValue(s); return; }
            if (v is long) { w.WriteNumberValue((long)v); return; }
            if (v is int) { w.WriteNumberValue((int)v); return; }
            if (v is double) { w.WriteNumberValue((double)v); return; }
            if (v is bool) { w.WriteBooleanValue((bool)v); return; }
            var list = v as string[];
            if (list != null) { w.WriteStartArray(); foreach (var x in list) w.WriteStringValue(x); w.WriteEndArray(); return; }
            var rows = v as IEnumerable<object[]>;
            if (rows != null) { w.WriteStartArray(); foreach (var r in rows) WriteValue(w, r); w.WriteEndArray(); return; }
            var arr = v as object[];
            if (arr != null) { w.WriteStartArray(); foreach (var x in arr) WriteValue(w, x); w.WriteEndArray(); return; }
            w.WriteStringValue(Convert.ToString(v, CultureInfo.InvariantCulture));
        }

        // Order in which the page opens its tables: the overview needs servers and daily, so they come first, and the
        // tables that are cheap to decode come before the large ones.
        static readonly string[] HtmlDatasetOrder = { "servers", "daily", "users", "operations", "authentication", "smtpclients", "smtpdestinations", "sessions", "issues", "messages" };

        static List<Dataset> HtmlDatasets(List<Dataset> sets)
        {
            Func<Dataset, int> rank = d => { int i = Array.IndexOf(HtmlDatasetOrder, d.Name); return i < 0 ? int.MaxValue : i; };
            return sets.Where(x => x.Html).Select((d, i) => new { d, i }).OrderBy(x => rank(x.d)).ThenBy(x => x.i).Select(x => x.d).ToList();
        }

        // Columns of "steps" kind (timelines, routes, transcripts, clients) stay out of the summary rows: the page
        // decodes them only for the row that is opened. The server cards read their protocol detail when the page
        // loads, and the daily rows are small, so those two datasets stay whole.
        static int[] DetailColumns(Dataset d)
        {
            if (d.Name == "servers" || d.Name == "daily") return new int[0];
            return d.Columns.Select((c, i) => new { c, i }).Where(x => x.c.Kind == "steps").Select(x => x.i).ToArray();
        }

        // A block of detail rows is cut at this many rows or uncompressed bytes: the page decodes a whole block to open one row.
        const int DetailBlockRows = 500, DetailBlockBytes = 512 * 1024;

        sealed class HtmlBatch { public List<object[]> Rows; public int First; }
        sealed class DetailBlock { public int First, Count; public string Data; }
        sealed class HtmlBlocks { public string Summary; public int First, Count; public List<DetailBlock> Details = new List<DetailBlock>(); }

        static Utf8JsonWriter JsonWriter(Stream gz) { return new Utf8JsonWriter(gz, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }); }

        // Summary row: the detail slots are null, their values travel in the detail blocks.
        static void WriteSummaryRow(Utf8JsonWriter w, object[] row, bool[] detail)
        {
            w.WriteStartArray();
            for (int i = 0; i < row.Length; i++) { if (detail[i]) w.WriteNullValue(); else WriteValue(w, row[i]); }
            w.WriteEndArray();
        }

        static string Chunk(string name, HtmlBatch batch, int[] detailColumns)
        {
            var detail = new bool[batch.Rows.Count == 0 ? 0 : batch.Rows.Max(r => r.Length)];
            foreach (var k in detailColumns) if (k < detail.Length) detail[k] = true;
            using (var ms = new MemoryStream())
            {
                using (var gz = new GZipStream(ms, CompressionLevel.Optimal, true))
                using (var w = JsonWriter(gz))
                {
                    w.WriteStartObject();
                    w.WriteString("set", name);
                    w.WritePropertyName("rows");
                    w.WriteStartArray();
                    foreach (var row in batch.Rows) { WriteSummaryRow(w, row, detail); w.Flush(); }
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                return Convert.ToBase64String(ms.GetBuffer(), 0, (int)ms.Length);
            }
        }

        static string DetailPack(string name, List<object[]> rows, int[] detailColumns)
        {
            using (var ms = new MemoryStream())
            {
                using (var gz = new GZipStream(ms, CompressionLevel.Optimal, true))
                using (var w = JsonWriter(gz))
                {
                    w.WriteStartObject();
                    w.WriteString("set", name);
                    w.WritePropertyName("rows");
                    w.WriteStartArray();
                    foreach (var row in rows)
                    {
                        w.WriteStartArray();
                        foreach (var k in detailColumns) WriteValue(w, row[k]);
                        w.WriteEndArray();
                    }
                    w.WriteEndArray();
                    w.WriteEndObject();
                }
                return Convert.ToBase64String(ms.GetBuffer(), 0, (int)ms.Length);
            }
        }

        // The summary chunk of a batch and the detail blocks of its rows; blocks are contiguous and ascending.
        static HtmlBlocks Blocks(string name, HtmlBatch batch, int[] detailColumns)
        {
            var result = new HtmlBlocks { Summary = Chunk(name, batch, detailColumns), First = batch.First, Count = batch.Rows.Count };
            if (detailColumns.Length == 0) return result;
            var rows = new List<object[]>(); long bytes = 0; int first = batch.First;
            Action cut = () =>
            {
                if (rows.Count == 0) return;
                result.Details.Add(new DetailBlock { First = first, Count = rows.Count, Data = DetailPack(name, rows, detailColumns) });
                first += rows.Count; rows = new List<object[]>(); bytes = 0;
            };
            foreach (var row in batch.Rows)
            {
                rows.Add(row);
                // Rough size of the JSON the block will hold; the exact byte count is not needed to bound the block.
                foreach (var k in detailColumns) bytes += ReportMemory.Bytes(row[k]) / 2;
                if (rows.Count >= DetailBlockRows || bytes >= DetailBlockBytes) cut();
            }
            cut();
            return result;
        }

        static IEnumerable<HtmlBatch> HtmlBatches(Dataset d, int limit, long maxBytes, TranscriptCache cache)
        {
            var batch = new HtmlBatch { Rows = new List<object[]>() };
            long bytes = 0; int next = 0;
            foreach (var source in d.Rows.Take(limit))
            {
                var row = cache.Row(source);
                long size = ReportMemory.Bytes(row);
                if (batch.Rows.Count > 0 && size > maxBytes - bytes) { next += batch.Rows.Count; yield return batch; batch = new HtmlBatch { Rows = new List<object[]>(), First = next }; bytes = 0; }
                batch.Rows.Add(row); bytes += size;
                if (batch.Rows.Count >= 5000 || bytes >= maxBytes) { next += batch.Rows.Count; yield return batch; batch = new HtmlBatch { Rows = new List<object[]>(), First = next }; bytes = 0; }
            }
            if (batch.Rows.Count > 0) yield return batch;
        }


        // ------------------------------------------------------------------ data files and page

        /// <summary>Name of the folder that holds the data files of a report: next to the page, named after the file prefix.</summary>
        internal static string HtmlDataFolderName(ReportRequest q) { return q.FilePrefix + "_data"; }
        internal const string HtmlDataMarker = ".exl-data";

        // A data file is a pack of consecutive blocks of one dataset and one kind (c: summary chunks, d: detail blocks).
        sealed class HtmlDataFile
        {
            public string Name, Kind, Set;
            public int First, Rows, Blocks;
            public long Bytes;
            public uint Crc;
            public int Rank;
        }

        // One writer per report: blocks are appended, in the order they are produced, to packs of about PackBytes of file
        // content. A pack is closed once the next block would not fit (a block larger than a pack is a pack of its own),
        // so that a large report is a few hundred files instead of thousands. The CRC-32 is computed while writing.
        sealed class HtmlDataWriter : IDisposable
        {
            sealed class Pack
            {
                public FileStream Stream;
                public HtmlDataFile File;
                public uint Crc = 0xFFFFFFFFu;
            }

            readonly string _folder, _id;
            readonly long _packBytes;
            readonly Dictionary<string, Pack> _open = new Dictionary<string, Pack>();
            readonly Dictionary<string, int> _sequence = new Dictionary<string, int>();
            readonly List<HtmlDataFile> _files = new List<HtmlDataFile>();
            static readonly uint[] CrcTable = MakeCrcTable();

            public HtmlDataWriter(string folder, string id, long packBytes)
            {
                _folder = folder; _id = id; _packBytes = packBytes;
                Directory.CreateDirectory(folder);
            }

            public List<HtmlDataFile> Files { get { return _files; } }
            public long Bytes { get { return _files.Sum(x => x.Bytes); } }

            static uint[] MakeCrcTable()
            {
                var table = new uint[256];
                for (uint n = 0; n < 256; n++)
                {
                    uint c = n;
                    for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                    table[n] = c;
                }
                return table;
            }

            void Write(Pack p, byte[] bytes)
            {
                p.Stream.Write(bytes, 0, bytes.Length);
                uint c = p.Crc;
                for (int i = 0; i < bytes.Length; i++) c = CrcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
                p.Crc = c;
                p.File.Bytes += bytes.Length;
            }

            void Seal(Pack p)
            {
                p.File.Crc = ~p.Crc;
                p.Stream.Dispose();
                p.Stream = null;
            }

            public void Add(char kind, string set, int first, int count, string base64)
            {
                string key = kind + ":" + set;
                string line = "__exl.push(\"" + kind + "\",\"" + set + "\"," + first.ToString(CultureInfo.InvariantCulture) + "," + count.ToString(CultureInfo.InvariantCulture) + ",\"" + base64 + "\");\n";
                var bytes = Encoding.ASCII.GetBytes(line);
                Pack p;
                _open.TryGetValue(key, out p);
                if (p != null && p.File.Blocks > 0 && p.File.Bytes + bytes.Length > _packBytes) { Seal(p); _open.Remove(key); p = null; }
                if (p == null)
                {
                    int n;
                    _sequence.TryGetValue(key, out n); n++; _sequence[key] = n;
                    string name = (kind == 'c' ? "s-" : "d-") + set + "-" + n.ToString("000", CultureInfo.InvariantCulture) + ".js";
                    var file = new HtmlDataFile { Name = name, Kind = kind.ToString(), Set = set, First = first };
                    p = new Pack { File = file, Stream = new FileStream(Path.Combine(_folder, name), FileMode.CreateNew, FileAccess.Write, FileShare.Read, 65536) };
                    _open[key] = p; _files.Add(file);
                    Write(p, Encoding.ASCII.GetBytes("__exl.file(\"" + _id + "\",\"" + name + "\");\n"));
                }
                Write(p, bytes);
                p.File.Rows += count; p.File.Blocks++;
            }

            /// <summary>The files of a dataset are complete: its open packs are closed.</summary>
            public void Close(string set)
            {
                foreach (var kind in new[] { "c:", "d:" })
                {
                    Pack p;
                    if (_open.TryGetValue(kind + set, out p)) { Seal(p); _open.Remove(kind + set); }
                }
            }

            public void Dispose()
            {
                foreach (var p in _open.Values) if (p.Stream != null) p.Stream.Dispose();
                _open.Clear();
            }
        }

        // Files Windows Explorer adds to a folder it has displayed; they are not user data.
        static readonly string[] HtmlDataShellFiles = { "desktop.ini", "Thumbs.db" };

        // The data folder of an earlier report is replaced only when this tool wrote it: the marker file, .js files and
        // the Explorer files above, nothing else. Returns the entries that make an existing folder someone else's (every
        // entry when the marker is missing); the list is empty when the folder is absent, empty or written by this tool.
        static List<string> ForeignHtmlDataEntries(string folder)
        {
            var foreign = new List<string>();
            if (!Directory.Exists(folder)) return foreign;
            bool marked = File.Exists(Path.Combine(folder, HtmlDataMarker));
            foreach (var entry in Directory.EnumerateFileSystemEntries(folder))
            {
                string name = Path.GetFileName(entry);
                if (Directory.Exists(entry)) { foreign.Add(name + Path.DirectorySeparatorChar); continue; }
                bool known = string.Equals(name, HtmlDataMarker, StringComparison.OrdinalIgnoreCase) || name.EndsWith(".js", StringComparison.OrdinalIgnoreCase)
                    || HtmlDataShellFiles.Contains(name, StringComparer.OrdinalIgnoreCase);
                if (!marked || !known) foreign.Add(name);
            }
            return foreign;
        }

        // Any other folder of that name is left alone and the report fails with a message that names what it holds.
        static void CheckHtmlDataFolder(string folder)
        {
            var foreign = ForeignHtmlDataEntries(folder);
            if (foreign.Count == 0) return;
            string list = string.Join(", ", foreign.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).Take(5))
                + (foreign.Count > 5 ? " and " + (foreign.Count - 5).ToString(CultureInfo.InvariantCulture) + " more" : "");
            throw new IOException("The folder " + folder + " already exists and is not a report data folder written by this tool (it holds " + list + "): remove or rename it, or change the report file prefix.");
        }

        // Explorer marks a folder it customised (desktop.ini) read-only and the shell files hidden and system; a read-only
        // directory or file cannot be deleted, so both are cleared before this tool removes or renames a folder it wrote.
        static void ClearHtmlDataAttributes(string folder)
        {
            File.SetAttributes(folder, FileAttributes.Directory);
            foreach (var name in HtmlDataShellFiles)
            {
                string shell = Path.Combine(folder, name);
                if (File.Exists(shell)) File.SetAttributes(shell, FileAttributes.Normal);
            }
        }

        static void DeleteHtmlDataFolder(string folder)
        {
            if (!Directory.Exists(folder)) return;
            ClearHtmlDataAttributes(folder);
            Directory.Delete(folder, true);
        }

        // Before a report is written: a data folder of that name must be one this tool may replace, and the .partial
        // folder left by an interrupted run is removed. A .previous folder with nothing under the real name is the earlier
        // report's data of a run stopped between its two renames: it is renamed back to the real name. Next to a folder of
        // the real name, .previous is the older of the two and is removed. The existing folder itself stays until the new
        // report is complete.
        static void PrepareHtmlDataFolder(string folder)
        {
            DeleteHtmlDataFolder(folder + ".partial");
            string previous = folder + ".previous";
            if (!Directory.Exists(folder) && Directory.Exists(previous)) Directory.Move(previous, folder);
            else DeleteHtmlDataFolder(previous);
            CheckHtmlDataFolder(folder);
        }

        // Once the new report is written: the data folder of the earlier report is checked again (it may have changed
        // while the report was written) and renamed to <folder>.previous in one operation, so nothing of it is deleted
        // until the new report is in place. Returns false when there was no earlier folder.
        static bool RetireHtmlDataFolder(string folder)
        {
            if (!Directory.Exists(folder)) return false;
            CheckHtmlDataFolder(folder);
            ClearHtmlDataAttributes(folder);
            Directory.Move(folder, folder + ".previous");
            return true;
        }

        static string HtmlMeta(ReportRequest q, List<Dataset> htmlSets, ReportResult result, int limit, HtmlDataWriter data, string id, string folderName)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    w.WriteString("title", q.Title);
                    w.WriteString("toolVersion", q.ToolVersion);
                    w.WriteString("generated", q.Generated);
                    w.WriteString("timeZone", q.TimeZoneName);
                    w.WriteString("periodStart", TimeUtil.Format(q.StartMs, q.Zone, "yyyy-MM-dd HH:mm"));
                    w.WriteString("periodEnd", TimeUtil.Format(q.EndMs, q.Zone, "yyyy-MM-dd HH:mm"));
                    w.WriteBoolean("detailed", q.Detailed);
                    w.WriteBoolean("edge", q.Edge);
                    w.WriteBoolean("includeRouting", q.IncludeRoutingDetails);
                    w.WriteBoolean("includeSessions", q.IncludeSessionDetails);
                    w.WriteNumber("slowRequestMs", q.SlowRequestMs);
                    w.WritePropertyName("users"); WriteValue(w, (q.Users ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray());
                    w.WritePropertyName("servers"); WriteValue(w, (q.Servers ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray());
                    w.WritePropertyName("configuredServers"); WriteValue(w, q.ConfiguredServers ?? new string[0]);
                    w.WritePropertyName("notes"); WriteValue(w, result.Notes.ToArray());
                    w.WritePropertyName("datasets");
                    w.WriteStartObject();
                    foreach (var d in htmlSets)
                    {
                        int rows = (int)Math.Min((long)d.Rows.Count, limit);
                        w.WritePropertyName(d.Name);
                        w.WriteStartObject();
                        w.WriteNumber("rows", rows);
                        w.WriteNumber("total", d.Rows.Count);
                        w.WritePropertyName("columns");
                        w.WriteStartArray();
                        foreach (var c in d.Columns)
                        {
                            w.WriteStartObject(); w.WriteString("name", c.Name); w.WriteString("kind", c.Kind); w.WriteBoolean("grid", c.Grid); w.WriteEndObject();
                        }
                        w.WriteEndArray();
                        var detailColumns = DetailColumns(d);
                        if (detailColumns.Length > 0)
                        {
                            w.WritePropertyName("detailColumns");
                            w.WriteStartArray();
                            foreach (var k in detailColumns) w.WriteNumberValue(k);
                            w.WriteEndArray();
                        }
                        w.WriteEndObject();
                    }
                    w.WriteEndObject();
                    // Every data file in the order the page reads them; folder is null when the files were copied into the page.
                    w.WritePropertyName("data");
                    w.WriteStartObject();
                    w.WriteString("id", id);
                    if (folderName == null) w.WriteNull("folder"); else w.WriteString("folder", folderName);
                    w.WriteNumber("packBytes", q.HtmlPackBytes);
                    w.WritePropertyName("files");
                    w.WriteStartArray();
                    foreach (var f in data.Files)
                    {
                        w.WriteStartObject();
                        w.WriteString("name", f.Name); w.WriteString("kind", f.Kind); w.WriteString("set", f.Set);
                        w.WriteNumber("first", f.First); w.WriteNumber("rows", f.Rows); w.WriteNumber("blocks", f.Blocks);
                        w.WriteNumber("bytes", f.Bytes); w.WriteNumber("crc", f.Crc);
                        w.WriteEndObject();
                    }
                    w.WriteEndArray();
                    w.WriteEndObject();
                    w.WriteEndObject();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        // Every dataset goes to the data writer first, one dataset after the other (its summary and detail packs side by
        // side); only the block being written is kept.
        static void WriteHtmlData(Store store, ReportRequest q, List<Dataset> htmlSets, int limit, HtmlDataWriter data)
        {
            var cache = new TranscriptCache(store, Math.Min(16L * 1048576, q.WorkingBudgetBytes / 8));
            try
            {
                long chunkBytes = Math.Min(1048576, (q.WorkingBudgetBytes - cache.LimitBytes) / q.EffectiveParallelism / 8);
                foreach (var d in htmlSets)
                {
                    var detailColumns = DetailColumns(d);
                    foreach (var blocks in OrderedWork(HtmlBatches(d, limit, chunkBytes, cache),
                        q, batch => batch.Rows.Sum(row => ReportMemory.Bytes(row)) * 8, batch => Blocks(d.Name, batch, detailColumns), cache.LimitBytes))
                    {
                        data.Add('c', d.Name, blocks.First, blocks.Count, blocks.Summary);
                        foreach (var block in blocks.Details) data.Add('d', d.Name, block.First, block.Count, block.Data);
                    }
                    data.Close(d.Name);
                }
            }
            finally { cache.Clear(); }
        }

        static void WriteText(Stream stream, string text)
        {
            var bytes = new UTF8Encoding(false).GetBytes(text);
            stream.Write(bytes, 0, bytes.Length);
        }

        static ReportFile WriteHtml(Store store, ReportRequest q, List<Dataset> sets, ReportResult result, string path)
        {
            string template = File.ReadAllText(q.TemplatePath, Encoding.UTF8);
            CheckTemplate(template, null, q.TemplatePath);
            string script = File.ReadAllText(TemplateScriptPath(q.TemplatePath), Encoding.UTF8);
            CheckTemplate(template, script, q.TemplatePath);
            var htmlSets = HtmlDatasets(sets);
            int limit = q.MaxHtmlRows > 0 ? q.MaxHtmlRows : int.MaxValue;
            foreach (var d in htmlSets)
                if (d.Rows.Count > limit) result.HtmlCutTables.Add(d.Name + " (" + limit.ToString("N0", CultureInfo.InvariantCulture) + " of " + d.Rows.Count.ToString("N0", CultureInfo.InvariantCulture) + " rows)");
            string folderName = HtmlDataFolderName(q), folder = Path.Combine(q.OutputFolder, folderName), folderPartial = folder + ".partial", pagePartial = path + ".partial";
            string id = Guid.NewGuid().ToString("N");
            string previous = folder + ".previous";
            PrepareHtmlDataFolder(folder);
            bool done = false, inline = true, retired = false;
            long pageBytes = 0, dataBytes = 0; int dataFiles = 0;
            var data = new HtmlDataWriter(folderPartial, id, q.HtmlPackBytes);
            try
            {
                File.WriteAllText(Path.Combine(folderPartial, HtmlDataMarker), id + "\r\n" + q.Generated + "\r\n", new UTF8Encoding(false));
                WriteHtmlData(store, q, htmlSets, limit, data);
                data.Dispose();
                // Summary packs first, in the order the page opens the tables, then the detail packs.
                foreach (var f in data.Files) { int r = Array.IndexOf(HtmlDatasetOrder, f.Set); f.Rank = (f.Kind == "c" ? 0 : 1000) + (r < 0 ? 999 : r); }
                var ordered = data.Files.Select((f, i) => new { f, i }).OrderBy(x => x.f.Rank).ThenBy(x => x.i).Select(x => x.f).ToList();
                data.Files.Clear(); data.Files.AddRange(ordered);
                dataBytes = data.Bytes; dataFiles = data.Files.Count;
                string layout = q.HtmlLayout ?? "Auto";
                inline = string.Equals(layout, "SingleFile", StringComparison.OrdinalIgnoreCase)
                    || (string.Equals(layout, "Auto", StringComparison.OrdinalIgnoreCase) && dataBytes <= (long)q.SingleFileMaxMB * 1048576);
                string meta = HtmlMeta(q, htmlSets, result, limit, data, id, inline ? null : folderName);
                using (var page = new FileStream(pagePartial, FileMode.Create, FileAccess.Write, FileShare.None, 65536))
                {
                    int start = 0;
                    var buffer = new byte[65536];
                    foreach (var marker in TemplateMarkers.OrderBy(x => template.IndexOf(x, StringComparison.Ordinal)))
                    {
                        int at = template.IndexOf(marker, StringComparison.Ordinal);
                        WriteText(page, template.Substring(start, at - start));
                        if (marker == "%%META%%") WriteText(page, meta);
                        else if (marker == "%%SCRIPT%%") WriteText(page, script);
                        else if (inline)
                            foreach (var f in data.Files)
                            {
                                WriteText(page, "<script>");
                                using (var input = new FileStream(Path.Combine(folderPartial, f.Name), FileMode.Open, FileAccess.Read, FileShare.Read, 65536))
                                {
                                    int n;
                                    while ((n = input.Read(buffer, 0, buffer.Length)) > 0) page.Write(buffer, 0, n);
                                }
                                WriteText(page, "</script>\n");
                            }
                        start = at + marker.Length;
                    }
                    WriteText(page, template.Substring(start));
                    pageBytes = page.Length;
                }
                // The earlier report keeps its data folder, under <folder>.previous, until the new page is in place.
                retired = RetireHtmlDataFolder(folder);
                if (inline) Directory.Delete(folderPartial, true);
                else Directory.Move(folderPartial, folder);
                File.Move(pagePartial, path, true);
                done = true;
            }
            finally
            {
                data.Dispose();
                if (!done)
                {
                    // Best effort: the failure being reported is the first one. The earlier data folder goes back under
                    // its name; a folder found there now can only be the new one.
                    try
                    {
                        if (retired && Directory.Exists(previous))
                        {
                            DeleteHtmlDataFolder(folder);
                            Directory.Move(previous, folder);
                        }
                    }
                    catch { }
                    try { DeleteHtmlDataFolder(folderPartial); } catch { }
                    try { if (File.Exists(pagePartial)) File.Delete(pagePartial); } catch { }
                }
            }
            if (retired)
            {
                try { DeleteHtmlDataFolder(previous); }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
                {
                    result.HtmlPreviousDataFolder = previous;
                    result.Notes.Add("The data folder of the earlier report could not be removed: delete " + previous + ".");
                }
            }
            result.HtmlDataFolder = inline ? null : folder;
            result.HtmlDataFiles = dataFiles;
            result.HtmlDataBytes = dataBytes;
            return new ReportFile { Path = path, Dataset = "html", Rows = sets.Sum(d => (long)d.Rows.Count), Bytes = pageBytes + (inline ? 0 : dataBytes) };
        }
    }
}
