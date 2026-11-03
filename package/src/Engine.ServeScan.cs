using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    // =================================================================================================================================
    // The list layer of the three day-sliced lists of the page (messages, client sessions, failed and slow requests): keyset pages on the
    // list key (cursor, dir, skip inside an order window, size), exact counts with a histogram (/count) and value lists (/facets), with the
    // filters of the page (ServeCellFilter). What an index answers exactly is a condition of the statement (seek class); every other filter is
    // a test of the cells of the rows (scan class), read chunk by chunk under a time budget: each chunk is at most ChunkRows index entries of
    // the window, so a request answers within its budget plus one chunk and the page continues from scannedTo. A scan reads only the fields
    // of the columns it tests (CellSource) and builds those cells alone; the rows a list returns are then read whole and built as every list
    // builds them (ConvertRow, IssueCells).
    // =================================================================================================================================

    /// <summary>An answer that may stop before the end of its window; only a complete one is kept by the result cache.</summary>
    internal interface IServePartial { bool Finished { get; } }

    internal sealed class ServeCount : IServePartial
    {
        public bool cached { get; set; }
        public long total { get; set; }
        public List<long[]> buckets { get; set; }
        public bool complete { get; set; }
        public string scannedTo { get; set; }
        public int budgetMs { get; set; }
        /// <summary>Messages: true when an exact Message-ID is stored in none of the spellings the index is asked for (ServePage.exactMiss).</summary>
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public bool? exactMiss { get; set; }
        bool IServePartial.Finished { get { return complete; } }
    }

    internal sealed class ServeFacets : IServePartial
    {
        public bool cached { get; set; }
        public Dictionary<string, List<object[]>> columns { get; set; }
        public List<string> truncated { get; set; }
        public bool complete { get; set; }
        public string scannedTo { get; set; }
        public int budgetMs { get; set; }
        bool IServePartial.Finished { get { return complete; } }
    }

    internal sealed partial class ServeRead
    {
        /// <summary>Index entries of one chunk of a scan.</summary>
        internal static int ChunkRows = 20000;
        /// <summary>
        /// Time budget of a filtered list page (milliseconds) when the request names none: the page asks while the user types, and continues a page
        /// that stopped from its scannedTo. The counts and the value lists keep the budget of Serve (ScanBudgetMs).
        /// </summary>
        internal static int ListBudgetMs = 500;

        /// <summary>The keyset shape of a view: its list key and key index, the FROM ... WHERE of its selection, its rows and how they become cells.</summary>
        sealed class Keyset
        {
            internal string View, Key, Id, From, KeyIndex, Select;
            internal Func<ServeFilter, string> WindowWhere;
            /// <summary>" FROM ... WHERE &lt;the selection&gt;" with an index hint; joined: with the tables the fields of the light statements may read.</summary>
            internal Func<ServeFilter, string, bool, string> Where;
            internal Func<object[], ServeRow> Convert;
            /// <summary>Filters of the selection that read the rows themselves (not index-only): such a list is read chunk by chunk.</summary>
            internal Func<ServeFilter, bool> Heavy;
            internal CellSource Cells;
        }

        static string SelectList(string select, string from) { return select.Substring("SELECT ".Length, select.IndexOf(from, StringComparison.Ordinal) - "SELECT ".Length); }
        Keyset Shape(string view)
        {
            if (view == "messages")
                return new Keyset
                {
                    View = view, Key = "r.member_last_ms", Id = "r.id", From = "message_rollup r", Select = SelectList(MessageSelect, " FROM message_rollup r"),
                    WindowWhere = f => MessageBounds(f),
                    Where = (f, hint, joined) => " FROM message_rollup r" + hint + " WHERE " + MessageWhere(f),
                    Convert = row => ConvertRow("messages", row.Skip(1).ToArray()),
                    Heavy = ScopedMessages, Cells = MessageCells()
                };
            if (view == "sessions")
                return new Keyset
                {
                    View = view, Key = "c.start_ms", Id = "c.id", From = "client_session c", KeyIndex = "ix_session_time", Select = SelectList(SessionSelect, " FROM client_session c"),
                    WindowWhere = f => "c.start_ms<@t AND c.start_ms>=@sf AND c.end_ms>=@f" + OrderWindow(f, "c.start_ms"),
                    Where = (f, hint, joined) => " FROM client_session c" + hint + " WHERE " + SessionWhere(f),
                    Convert = row => ConvertRow("sessions", row.Skip(1).ToArray()),
                    Heavy = f => f.User != null || f.Server != null || f.Status != null, Cells = SessionCells
                };
            return new Keyset
            {
                View = "issues", Key = "e.time_ms", Id = "e.id", From = "access_event e", KeyIndex = "ix_event_time", Select = "e.id," + ReportBuilder.IssueFields,
                WindowWhere = f => "e.time_ms>=@f AND e.time_ms<@t" + OrderWindow(f, "e.time_ms"),
                Where = (f, hint, joined) => (joined ? ReportBuilder.IssueFrom.Replace(" FROM access_event e ", " FROM access_event e" + hint + " ") : " FROM access_event e" + hint + " ") + "WHERE " + IssueWhere(f),
                Convert = IssueCells,
                Heavy = f => false, Cells = IssueCellSource()
            };
        }
        /// <summary>The failed and slow requests of the selection: successes only with a user filter, as in a report filtered on users.</summary>
        static string IssueWhere(ServeFilter f)
        {
            return "e.time_ms>=@f AND e.time_ms<@t" + OrderWindow(f, "e.time_ms") + AccessFilter(f, "e") +
                (f.User == null ? " AND e.outcome<>'Success'" : "") + (f.Status == null ? "" : " AND e.outcome=@status COLLATE NOCASE");
        }
        /// <summary>A row of the requests (list key, id, IssueFields) as the list returns it, with its resolution.</summary>
        ServeRow IssueCells(object[] row)
        {
            var fields = new object[row.Length - 2];
            for (int i = 0; i < fields.Length; i++) fields[i] = row[i + 2] == null ? null : Packed.Unpack(row[i + 2]);
            string after;
            string resolution = Resolution(fields, out after);
            return new ServeRow { id = Long(row[1]), cells = ReportBuilder.IssueRow(fields, LocalIso, resolution, after) };
        }

        // ------------------------------------------------------------------------------------------------------------ cells column by column

        /// <summary>
        /// The cells of a list built one column at a time from the fields of its statement: Fields are the select expressions of the list (the id
        /// first), Needs the fields each cell reads, Cell its value. A scan reads only the fields of the cells it tests. Each cell is the value
        /// ConvertRow or IssueCells gives the same row (ServeDiagnostics.CompareListCells checks it on every row of a store).
        /// </summary>
        internal sealed class CellSource
        {
            internal string[] Fields;
            internal int[][] Needs;
            internal Func<Func<int, object>, object>[] Cell;
            internal CellSource(string select, int cells) { Fields = SplitSelect(select); Needs = new int[cells][]; Cell = new Func<Func<int, object>, object>[cells]; }
            internal void Def(int cell, Func<Func<int, object>, object> value, params int[] needs) { Cell[cell] = value; Needs[cell] = needs; }
        }
        /// <summary>The expressions of a select list, split at its top-level commas.</summary>
        internal static string[] SplitSelect(string select)
        {
            var parts = new List<string>(); int depth = 0, start = 0; bool quoted = false;
            for (int i = 0; i < select.Length; i++)
            {
                char ch = select[i];
                if (ch == '\'') quoted = !quoted;
                else if (!quoted && ch == '(') depth++;
                else if (!quoted && ch == ')') depth--;
                else if (!quoted && depth == 0 && ch == ',') { parts.Add(select.Substring(start, i - start)); start = i + 1; }
            }
            parts.Add(select.Substring(start));
            return parts.ToArray();
        }
        static string S(object v) { return v is byte[] ? Packed.Text(v) : v == null ? null : Convert.ToString(v, CultureInfo.InvariantCulture); }
        static long L(object v) { return v == null ? 0 : Convert.ToInt64(v, CultureInfo.InvariantCulture); }

        CellSource _sessionCells;
        // The client family of (protocol, user agent, device type), a pure function: remembered for the request (the agents repeat), bounded.
        readonly Dictionary<(string, string, string), string> _clientFamilies = new Dictionary<(string, string, string), string>();
        string ClientFamily(string protocol, string agent, string deviceType)
        {
            var key = (protocol, agent, deviceType); string family;
            if (_clientFamilies.TryGetValue(key, out family)) return family;
            if (_clientFamilies.Count >= RemoteHostMemoLimit) _clientFamilies.Clear();
            return _clientFamilies[key] = ReportBuilder.ClientFamily(protocol, agent, deviceType);
        }
        /// <summary>SessionFields (0..29) and the outcome of the counters (30), as SessionSummaryRow and ConvertRow read them.</summary>
        CellSource SessionCells
        {
            get
            {
                if (_sessionCells != null) return _sessionCells;
                var s = new CellSource(SelectList(SessionSelect, " FROM client_session c"), 26);
                Func<long, object> local = ms => ms > 0 ? Iso(ms) : null;
                s.Def(0, r => local(L(r(1))), 1); s.Def(1, r => local(L(r(2))), 2); s.Def(2, r => TimeUtil.Duration((L(r(2)) - L(r(1))) / 1000.0), 1, 2);
                s.Def(3, r => Text(r(30)), 30); s.Def(4, r => S(r(3)), 3); s.Def(5, r => S(r(4)), 4); s.Def(6, r => ClientFamily(S(r(4)), S(r(7)), S(r(9))), 4, 7, 9);
                s.Def(7, r => (S(r(6)) ?? "").Replace(",", ", "), 6); s.Def(8, r => (S(r(12)) ?? "").Replace(",", ", "), 12); s.Def(9, r => (S(r(13)) ?? "").Replace(",", ", "), 13);
                s.Def(10, r => L(r(14)), 14);
                s.Def(11, r =>
                {
                    long backEndErrors = 0; string backend = S(r(27));
                    if (backend != null) { int bar = backend.IndexOf('|'); long.TryParse(bar > 0 ? backend.Substring(0, bar) : backend, NumberStyles.Integer, CultureInfo.InvariantCulture, out backEndErrors); }
                    return L(r(16)) + backEndErrors;
                }, 16, 27);
                s.Def(12, r => L(r(17)), 17); s.Def(13, r => L(r(14)) > 0 ? (object)(L(r(22)) / L(r(14))) : null, 14, 22); s.Def(14, r => L(r(23)), 23);
                s.Def(15, r => ReportBuilder.Top(S(r(24)), 4), 24); s.Def(16, r => S(r(26)), 26); s.Def(17, r => S(r(10)), 10); s.Def(18, r => S(r(11)) == "0" ? null : S(r(11)), 11);
                s.Def(19, r => S(r(8)), 8); s.Def(20, r => S(r(5)), 5); s.Def(21, r => L(r(28)) > 0 ? (object)L(r(28)) : null, 28); s.Def(22, r => S(r(25)), 25);
                s.Def(23, r => S(r(7)), 7); s.Def(24, r => L(r(0)), 0); s.Def(25, r => AuthMode.Modes(S(r(29))), 29);
                return _sessionCells = s;
            }
        }
        /// <summary>The fields of MessageSelect (0..17), as ConvertRow reads them.</summary>
        CellSource MessageCells()
        {
            var s = new CellSource(SelectList(MessageSelect, " FROM message_rollup r"), 18);
            s.Def(0, r => Iso(Long(r(1))), 1); s.Def(1, r => Iso(Long(r(2))), 2); s.Def(2, r => TimeUtil.Duration((Long(r(2)) - Long(r(1))) / 1000.0), 1, 2);
            s.Def(3, r => RollupText(r(3)), 3); s.Def(4, r => r(4), 4); s.Def(5, r => JsonSerializer.Deserialize<string[]>(Text(r(5))), 5);
            s.Def(6, r => r(6), 6); s.Def(7, r => r(7), 7); s.Def(8, r => r(8), 8); s.Def(9, r => r(9), 9); s.Def(10, r => r(10), 10);
            s.Def(11, r => RollupText(r(11)), 11); s.Def(12, r => RollupText(r(12)), 12); s.Def(13, r => RollupText(r(13)), 13); s.Def(14, r => r(14), 14);
            s.Def(15, r => KindName(r(16)) == "message" ? r(15) : null, 15, 16); s.Def(16, r => KindName(r(16)), 16); s.Def(17, r => r(17), 17);
            return s;
        }
        /// <summary>The id and IssueFields (1..23), as IssueCells reads them (the values unpacked).</summary>
        CellSource IssueCellSource()
        {
            var s = new CellSource("e.id," + ReportBuilder.IssueFields, 25);
            Func<Func<int, object>, int, object> u = (r, i) => { var v = r(i + 1); return v == null ? null : Packed.Unpack(v); };
            Func<Func<int, object>, string[]> resolution = r =>
            {
                var fields = new object[23];
                foreach (int i in new[] { 0, 3, 4, 19, 20 }) fields[i] = u(r, i);
                string after;
                string value = Resolution(fields, out after);
                return new[] { value, after };
            };
            s.Def(0, r => LocalIso(L(u(r, 0))), 1);
            foreach (int k in new[] { 1, 2, 3, 4, 5, 6, 8, 9, 10, 15, 16, 17, 19 }) { int i = k; s.Def(k, r => S(u(r, i)), i + 1); }
            s.Def(7, r => Identity.Client(S(u(r, 7))), 8);
            foreach (int k in new[] { 11, 12, 13, 14, 18 }) { int i = k; s.Def(k, r => u(r, i), i + 1); }
            s.Def(20, r => resolution(r)[0], 1, 4, 5, 20, 21); s.Def(21, r => resolution(r)[1], 1, 4, 5, 20, 21);
            s.Def(22, r => S(u(r, 21)), 22); s.Def(23, r => S(u(r, 7)), 8); s.Def(24, r => S(u(r, 22)), 23);
            return s;
        }

        // ------------------------------------------------------------------------------------------------------------ seek conditions

        /// <summary>
        /// The conditions of the statement for the filters an index answers exactly, and the terms they apply: Status, Direction and Servers of the
        /// messages (dictionary codes whose text passes the test), the exact Message-ID of "=x" (UNIQUE(kind, identity): the identities stored as typed,
        /// in lower case or in upper case; when none is stored, no row (ExactMiss), or with anyCase=1 a test of the cells, case-insensitive like the
        /// others), the values of a User list (ix_session_user, ix_event_user).
        /// </summary>
        sealed class Seek
        {
            internal string Sql = "", Hint;
            internal readonly Dictionary<string, object> Parameters = new Dictionary<string, object>(StringComparer.Ordinal);
            internal readonly HashSet<ServeTerm> Applied = new HashSet<ServeTerm>();
            /// <summary>An exact Message-ID stored in none of the three spellings: the selection is empty without reading a row.</summary>
            internal bool ExactMiss;
        }
        static readonly Dictionary<string, string> CodeColumns = new Dictionary<string, string>(StringComparer.Ordinal) { { "Status", "r.status" }, { "Direction", "r.direction" }, { "Servers", "r.servers" } };
        Seek SeekOf(Keyset k, ServeFilter f, ServeCellFilter filter)
        {
            var seek = new Seek();
            int n = 0;
            foreach (var term in filter.Terms)
            {
                string column;
                if (k.View == "messages" && CodeColumns.TryGetValue(term.Column.Name, out column))
                {
                    if (_rollupValues == null) RollupValues();
                    var codes = _rollupValues.Where(kv => term.Test(kv.Value.Length == 0 ? null : kv.Value)).Select(kv => kv.Key).OrderBy(x => x).ToList();
                    if (codes.Count > 4096) continue;
                    bool none = term.Test(null);
                    string list = string.Join(",", codes.Select(x => x.ToString(CultureInfo.InvariantCulture)));
                    seek.Sql += codes.Count == 0 ? (none ? " AND " + column + " IS NULL" : " AND 0") : " AND (" + column + " IN(" + list + ")" + (none ? " OR " + column + " IS NULL" : "") + ")";
                    seek.Applied.Add(term);
                }
                else if (k.View == "messages" && term.Column.Name == "Message ID" && term.Exact != null && seek.Hint == null)
                {
                    var stored = StoredIdentities(term.Exact).Where(x => term.Test(x)).ToList();
                    if (stored.Count == 0)
                    {
                        // Another spelling of a Message-ID is found by reading every row of the window: only when the request asks for it.
                        if (f.AnyCase) continue;
                        seek.Sql += " AND 0"; seek.ExactMiss = true; seek.Applied.Add(term);
                        continue;
                    }
                    var names = stored.Select(x => { string p = "@mid" + (n++).ToString(CultureInfo.InvariantCulture); seek.Parameters[p] = x; return p; }).ToList();
                    seek.Sql += " AND r.kind=0 AND r.identity IN(" + string.Join(",", names) + ")";
                    seek.Hint = "";
                    seek.Applied.Add(term);
                }
                else if ((k.View == "sessions" || k.View == "issues") && term.Column.Name == "User" && term.Values != null && !term.Exclude && seek.Hint == null)
                {
                    string alias = k.View == "sessions" ? "c" : "e";
                    var names = term.Values.Select(v => { string p = "@mu" + (n++).ToString(CultureInfo.InvariantCulture); seek.Parameters[p] = v; return p; }).ToList();
                    seek.Sql += " AND " + alias + ".user IN(" + string.Join(",", names) + ")";
                    seek.Hint = k.View == "sessions" ? " INDEXED BY ix_session_user" : " INDEXED BY ix_event_user";
                    seek.Applied.Add(term);
                }
            }
            if (seek.Hint == null)
                seek.Hint = k.View == "messages" ? " INDEXED BY " + MessageIndex(f) : " INDEXED BY " + k.KeyIndex;
            return seek;
        }
        /// <summary>The Message-IDs of the rollup stored as typed, in lower case or in upper case (ASCII): three seeks of UNIQUE(kind, identity).</summary>
        List<string> StoredIdentities(string typed)
        {
            var stored = new List<string>();
            using (var c = Command("SELECT identity FROM message_rollup WHERE kind=0 AND identity IN(@x,lower(@x),upper(@x));"))
            {
                c.Parameters.AddWithValue("@x", typed);
                using (var r = c.ExecuteReader()) while (r.Read()) stored.Add(r.GetString(0));
            }
            return stored;
        }
        void RollupValues()
        {
            var values = new Dictionary<long, string>();
            using (var c = Command("SELECT id,text FROM message_rollup_value;"))
            using (var r = c.ExecuteReader()) while (r.Read()) values[r.GetInt64(0)] = r.GetString(1);
            _rollupValues = values;
        }

        // ------------------------------------------------------------------------------------------------------------ keyset statements

        static string Cursor(long key, long id) { return key.ToString(CultureInfo.InvariantCulture) + "." + id.ToString(CultureInfo.InvariantCulture); }
        static string OrderBy(Keyset k, ServeFilter f) { string d = f.Ascending ? "" : " DESC"; return " ORDER BY " + k.Key + d + "," + k.Id + d; }
        // A position in the list order is compared as a row value (key, id); the key alone bounds the index range as well: the covering key indexes hold
        // other columns between the key and the rowid, so the row value by itself is only a filter of the range.
        static string After(Keyset k, ServeFilter f, string key, string id)
        {
            return " AND " + k.Key + (f.Ascending ? ">=" : "<=") + key + " AND (" + k.Key + "," + k.Id + ")" + (f.Ascending ? ">" : "<") + "(" + key + "," + id + ")";
        }
        /// <summary>The far end of a chunk: every row of its last key (a chunk ends between two keys).</summary>
        static string Until(Keyset k, ServeFilter f) { return " AND " + k.Key + (f.Ascending ? "<=" : ">=") + "@bk"; }
        /// <param name="page">A list page: ListBudgetMs when the request names no budget.</param>
        int Budget(ServeFilter f, bool page = false)
        {
            int cap = Math.Max(100, Math.Min(_options.ScanBudgetMs, _options.RequestTimeoutSeconds * 1000 - 1000));
            return f.BudgetMs.HasValue ? Math.Min(f.BudgetMs.Value, cap) : page ? Math.Min(ListBudgetMs, cap) : cap;
        }
        /// <summary>
        /// True when the cursor is not a position of the window of the list key: the order window, and the period itself for the requests (a session
        /// may start before the period, a journey end after it). The page of such a cursor is empty.
        /// </summary>
        static bool OutsideWindow(string view, ServeFilter f)
        {
            if (!f.CursorKey.HasValue) return false;
            long key = f.CursorKey.Value;
            return (f.OrderFrom.HasValue && key < f.OrderFrom.Value) || (f.OrderTo.HasValue && key >= f.OrderTo.Value) || (view == "issues" && (key < f.From || key >= f.To));
        }
        SqliteCommand KeysetCommand(string sql, ServeFilter f, Seek seek)
        {
            var c = FilterCommand(sql, f);
            foreach (var kv in seek.Parameters) c.Parameters.AddWithValue(kv.Key, kv.Value);
            if (f.CursorKey.HasValue) { c.Parameters.AddWithValue("@ck", f.CursorKey.Value); c.Parameters.AddWithValue("@cid", f.CursorId.Value); }
            return c;
        }
        /// <summary>
        /// Steps the statement of a command on the connection's own handle (SQLitePCL) and gives each row as a column accessor: the values of the light
        /// statements of a scan, without the per-value cost of the data reader (INTEGER long, FLOAT double, TEXT string, BLOB byte[], NULL null, as
        /// the data reader gives them). The deadline interrupts it like any statement of the connection.
        /// </summary>
        void RawRows(SqliteCommand c, Action<Func<int, object>> row) { RawRows(c, value => { row(value); return true; }); }
        /// <summary>RawRows that stops stepping the statement when row returns false.</summary>
        void RawRows(SqliteCommand c, Func<Func<int, object>, bool> row)
        {
            var statement = Prepared(c);
            try
            {
                Func<int, object> value = k => Value(statement, k);
                int rc;
                while ((rc = SQLitePCL.raw.sqlite3_step(statement)) == SQLitePCL.raw.SQLITE_ROW) if (!row(value)) return;
                if (rc != SQLitePCL.raw.SQLITE_DONE) throw new SqliteException(SQLitePCL.raw.sqlite3_errmsg(_db.Handle).utf8_to_string(), rc);
            }
            finally { SQLitePCL.raw.sqlite3_finalize(statement); }
        }
        /// <summary>The statement of a command prepared on the connection's own handle, with its parameters bound (the caller finalizes it).</summary>
        SQLitePCL.sqlite3_stmt Prepared(SqliteCommand c)
        {
            _cancel.ThrowIfCancellationRequested();
            var handle = _db.Handle;
            SQLitePCL.sqlite3_stmt statement;
            int rc = SQLitePCL.raw.sqlite3_prepare_v2(handle, c.CommandText, out statement);
            if (rc != SQLitePCL.raw.SQLITE_OK) throw new SqliteException(SQLitePCL.raw.sqlite3_errmsg(handle).utf8_to_string(), rc);
            try
            {
                foreach (SqliteParameter p in c.Parameters)
                {
                    int i = SQLitePCL.raw.sqlite3_bind_parameter_index(statement, p.ParameterName);
                    if (i == 0) continue;
                    object v = p.Value;
                    if (v == null || v is DBNull) SQLitePCL.raw.sqlite3_bind_null(statement, i);
                    else if (v is long l) SQLitePCL.raw.sqlite3_bind_int64(statement, i, l);
                    else if (v is int n) SQLitePCL.raw.sqlite3_bind_int64(statement, i, n);
                    else if (v is double d) SQLitePCL.raw.sqlite3_bind_double(statement, i, d);
                    else if (v is string s) SQLitePCL.raw.sqlite3_bind_text(statement, i, s);
                    else throw new InvalidOperationException("Unsupported parameter type in a scan statement.");
                }
            }
            catch { SQLitePCL.raw.sqlite3_finalize(statement); throw; }
            return statement;
        }
        static object Value(SQLitePCL.sqlite3_stmt statement, int k)
        {
            switch (SQLitePCL.raw.sqlite3_column_type(statement, k))
            {
                case SQLitePCL.raw.SQLITE_INTEGER: return SQLitePCL.raw.sqlite3_column_int64(statement, k);
                case SQLitePCL.raw.SQLITE_FLOAT: return SQLitePCL.raw.sqlite3_column_double(statement, k);
                case SQLitePCL.raw.SQLITE_TEXT: return SQLitePCL.raw.sqlite3_column_text(statement, k).utf8_to_string();
                case SQLitePCL.raw.SQLITE_BLOB: return SQLitePCL.raw.sqlite3_column_blob(statement, k).ToArray();
                default: return null;
            }
        }
        /// <summary>
        /// Steps the statement of a command (as RawRows) and gives each distinct combination of the values of its columns once, with the number of
        /// rows that hold it. A row is keyed by the bytes of its values (the type of each, then the integer, the float, or the bytes of the text or
        /// the BLOB) without decoding them; a combination is decoded once, its values as RawRows gives them.
        /// </summary>
        List<KeyValuePair<object[], long>> CountRows(SqliteCommand c)
        {
            var statement = Prepared(c);
            try
            {
                int width = SQLitePCL.raw.sqlite3_column_count(statement), rc;
                var groups = new List<KeyValuePair<object[], long>>();
                var keys = new List<byte[]>();
                var index = new Dictionary<int, List<int>>();
                var key = new byte[256];
                while ((rc = SQLitePCL.raw.sqlite3_step(statement)) == SQLitePCL.raw.SQLITE_ROW)
                {
                    int length = 0;
                    for (int k = 0; k < width; k++)
                    {
                        int type = SQLitePCL.raw.sqlite3_column_type(statement, k);
                        if (key.Length < length + 13) Array.Resize(ref key, key.Length * 2);
                        key[length++] = (byte)type;
                        if (type == SQLitePCL.raw.SQLITE_INTEGER) { System.Buffers.Binary.BinaryPrimitives.WriteInt64LittleEndian(key.AsSpan(length), SQLitePCL.raw.sqlite3_column_int64(statement, k)); length += 8; }
                        else if (type == SQLitePCL.raw.SQLITE_FLOAT) { System.Buffers.Binary.BinaryPrimitives.WriteInt64LittleEndian(key.AsSpan(length), BitConverter.DoubleToInt64Bits(SQLitePCL.raw.sqlite3_column_double(statement, k))); length += 8; }
                        else if (type == SQLitePCL.raw.SQLITE_TEXT || type == SQLitePCL.raw.SQLITE_BLOB)
                        {
                            var bytes = SQLitePCL.raw.sqlite3_column_blob(statement, k);
                            while (key.Length < length + 4 + bytes.Length) Array.Resize(ref key, key.Length * 2);
                            System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(key.AsSpan(length), bytes.Length); length += 4;
                            bytes.CopyTo(key.AsSpan(length)); length += bytes.Length;
                        }
                    }
                    var row = new ReadOnlySpan<byte>(key, 0, length);
                    var hash = new HashCode(); hash.AddBytes(row);
                    int code = hash.ToHashCode(), found = -1;
                    List<int> bucket;
                    if (index.TryGetValue(code, out bucket)) { foreach (int g in bucket) if (row.SequenceEqual(keys[g])) { found = g; break; } }
                    else index[code] = bucket = new List<int>(1);
                    if (found >= 0) { groups[found] = new KeyValuePair<object[], long>(groups[found].Key, groups[found].Value + 1); continue; }
                    var values = new object[width];
                    for (int k = 0; k < width; k++) values[k] = Value(statement, k);
                    bucket.Add(groups.Count); keys.Add(row.ToArray()); groups.Add(new KeyValuePair<object[], long>(values, 1));
                }
                if (rc != SQLitePCL.raw.SQLITE_DONE) throw new SqliteException(SQLitePCL.raw.sqlite3_errmsg(_db.Handle).utf8_to_string(), rc);
                return groups;
            }
            finally { SQLitePCL.raw.sqlite3_finalize(statement); }
        }
        static object[] Values(SqliteDataReader r)
        {
            var row = new object[r.FieldCount];
            for (int n = 0; n < row.Length; n++) row[n] = r.IsDBNull(n) ? null : r.GetValue(n);
            return row;
        }
        static string RowsSql(Keyset k, ServeFilter f, Seek seek) { return "SELECT " + k.Key + "," + k.Select + k.Where(f, seek.Hint, true) + seek.Sql; }
        /// <summary>
        /// The conditions that bound the index range of a statement on the list key: the order window, then the position terms (each " AND ..."). They
        /// lead the WHERE clause: SQLite bounds the range by the first range terms of a column, and the selection also bounds the key by the period
        /// and the span (a looser bound over a longer period).
        /// </summary>
        static string Lead(Keyset k, ServeFilter f, string bounds)
        {
            string all = OrderWindow(f, k.Key) + bounds;
            return all.Length == 0 ? "" : all.Substring(" AND ".Length);
        }
        /// <summary>The statement with the leading conditions first in its WHERE clause (the first WHERE of the statement is its own).</summary>
        static string Led(string sql, string lead)
        {
            if (lead.Length == 0) return sql;
            int at = sql.IndexOf(" WHERE ", StringComparison.Ordinal) + " WHERE ".Length;
            return sql.Substring(0, at) + lead + " AND " + sql.Substring(at);
        }

        /// <summary>
        /// The chunks of a scan: from the position, the key of the ChunkRows-th index entry of the window in the list order (from the index entries, in
        /// key order alone, no sort); the chunk holds every row up to that key included. Null when the window ends first.
        /// </summary>
        long? Boundary(Keyset k, ServeFilter f, long[] position)
        {
            string from = k.View == "messages" ? "message_rollup r INDEXED BY " + MessageIndex(f) : k.From + " INDEXED BY " + k.KeyIndex;
            using (var c = FilterCommand(Led("SELECT " + k.Key + " FROM " + from + " WHERE " + k.WindowWhere(f), Lead(k, f, position == null ? "" : After(k, f, "@pk", "@pid"))) +
                " ORDER BY " + k.Key + (f.Ascending ? "" : " DESC") + " LIMIT 1 OFFSET " + (ChunkRows - 1).ToString(CultureInfo.InvariantCulture) + ";", f))
            {
                if (position != null) { c.Parameters.AddWithValue("@pk", position[0]); c.Parameters.AddWithValue("@pid", position[1]); }
                object key = c.ExecuteScalar();
                return key == null || key is DBNull ? (long?)null : Long(key);
            }
        }
        /// <summary>The position after every row of a key in the list order (row ids are positive).</summary>
        static long[] Past(long key, ServeFilter f) { return new[] { key, f.Ascending ? long.MaxValue : 0L }; }
        /// <summary>The rows up to a position of the list order included (@uk, @uid), the key bounding the range as in After.</summary>
        static string UpTo(Keyset k, ServeFilter f)
        {
            return " AND " + k.Key + (f.Ascending ? "<=" : ">=") + "@uk AND (" + k.Key + "," + k.Id + ")" + (f.Ascending ? "<=" : ">=") + "(@uk,@uid)";
        }
        /// <summary>The key and the id of a position "key.id" given by ScanChunks.</summary>
        static long[] Position(string cursor)
        {
            int dot = cursor.IndexOf('.');
            return new[] { long.Parse(cursor.Substring(0, dot), NumberStyles.None, CultureInfo.InvariantCulture), long.Parse(cursor.Substring(dot + 1), NumberStyles.None, CultureInfo.InvariantCulture) };
        }

        /// <summary>
        /// Reads the rows of the window after the cursor, chunk by chunk, in the list order: the fields of the cells of the columns wanted (asked again
        /// before each chunk), those cells (the others null), the test; each row that passes is given to take with its list key and id, until take
        /// returns false (the goal is reached), the window ends or the budget is spent. scannedTo: the position the request examined up to (the
        /// cursor to continue from); finished: the window was read to its end; following: take stopped before a passing row already read or before
        /// rows of the window not read yet (always when an unordered scan stops). Unordered (ordered false): each row that passes is given to take as
        /// it is read, in a cells array that the next row reuses.
        /// </summary>
        /// <param name="page">A list page: the budget of a page (Budget).</param>
        void ScanChunks(Keyset k, ServeFilter f, Seek seek, Func<IEnumerable<ServeViewColumn>> wanted, Func<object[], bool> test, Func<long, long, object[], bool> take,
            out string scannedTo, out bool finished, out bool following, bool ordered = true, bool page = false)
        {
            var clock = Stopwatch.StartNew();
            int budget = Budget(f, page);
            var source = k.Cells;
            int width = source.Cell.Length;
            long[] position = f.CursorKey.HasValue ? new[] { f.CursorKey.Value, f.CursorId.Value } : null;
            scannedTo = null; finished = false; following = false;
            for (;;)
            {
                var columns = wanted().Select(c => c.Cell).Distinct().OrderBy(x => x).ToArray();
                var fields = columns.SelectMany(c => source.Needs[c]).Distinct().OrderBy(x => x).ToArray();
                var at = new int[source.Fields.Length];
                for (int i = 0; i < fields.Length; i++) at[fields[i]] = i + 2;
                bool joined = fields.Any(i => source.Fields[i].Contains("i.", StringComparison.Ordinal));
                string rows = "SELECT " + k.Key + "," + k.Id + (fields.Length > 0 ? "," + string.Join(",", fields.Select(i => source.Fields[i])) : "") + k.Where(f, seek.Hint, joined) + seek.Sql;
                var bound = Boundary(k, f, position);
                // The rows of a chunk are read in index order without a sort (the statement has no ORDER BY); the rows that pass are then given in the list
                // order, or as they are read when the order does not matter (in a cells array that the next row of the chunk reuses).
                var passed = new List<KeyValuePair<long[], object[]>>();
                bool stopped = false;
                using (var c = KeysetCommand(Led(rows, Lead(k, f, (position == null ? "" : After(k, f, "@pk", "@pid")) + (bound == null ? "" : Until(k, f)))) + ";", f, seek))
                {
                    if (position != null) { c.Parameters.AddWithValue("@pk", position[0]); c.Parameters.AddWithValue("@pid", position[1]); }
                    if (bound != null) c.Parameters.AddWithValue("@bk", bound.Value);
                    var raw = new object[fields.Length + 2];
                    Func<int, object> field = i => raw[at[i]];
                    var reused = ordered ? null : new object[width];
                    string stop = null;
                    RawRows(c, value =>
                    {
                        for (int n = 0; n < raw.Length; n++) raw[n] = value(n);
                        var cells = reused ?? new object[width];
                        foreach (int cell in columns) cells[cell] = source.Cell[cell](field);
                        if (test != null && !test(cells)) return true;
                        if (ordered) { passed.Add(new KeyValuePair<long[], object[]>(new[] { Long(raw[0]), Long(raw[1]) }, cells)); return true; }
                        long key = Long(raw[0]), id = Long(raw[1]);
                        if (take(key, id, cells)) return true;
                        stop = Cursor(key, id);
                        return false;
                    });
                    if (stop != null) { scannedTo = stop; following = true; stopped = true; }
                }
                if (stopped) return;
                if (ordered) passed.Sort((a, b) => { int x = a.Key[0].CompareTo(b.Key[0]); if (x == 0) x = a.Key[1].CompareTo(b.Key[1]); return f.Ascending ? x : -x; });
                for (int j = 0; j < passed.Count; j++)
                {
                    var row = passed[j];
                    if (!take(row.Key[0], row.Key[1], row.Value)) { scannedTo = Cursor(row.Key[0], row.Key[1]); following = j + 1 < passed.Count || bound != null; return; }
                }
                if (bound == null) { finished = true; return; }
                position = Past(bound.Value, f);
                scannedTo = Cursor(position[0], position[1]);
                if (clock.ElapsedMilliseconds >= budget) return;
            }
        }

        /// <summary>The columns a test reads: those of its terms, and every text and list column for free words.</summary>
        static IEnumerable<ServeViewColumn> Tested(ServeCellFilter filter, HashSet<ServeTerm> applied)
        {
            var columns = filter.Terms.Where(t => !applied.Contains(t)).Select(t => t.Column);
            if (filter.Words.Count > 0) columns = columns.Concat(filter.View.Columns.Where(c => c.Kind == "text" || c.Kind == "list"));
            return columns.Distinct();
        }

        /// <summary>The whole rows of ids (at most a page), in the list order.</summary>
        List<ServeRow> RowsById(Keyset k, ServeFilter f, Seek seek, List<long> ids)
        {
            var rows = new List<ServeRow>();
            var noCursor = new ServeFilter { From = f.From, To = f.To, OrderFrom = f.OrderFrom, OrderTo = f.OrderTo, User = f.User, Server = f.Server, Status = f.Status, Ascending = f.Ascending };
            for (int i = 0; i < ids.Count; i += 500)
            {
                string list = string.Join(",", ids.Skip(i).Take(500).Select(x => x.ToString(CultureInfo.InvariantCulture)));
                using (var c = KeysetCommand(Led(RowsSql(k, noCursor, seek), Lead(k, noCursor, "")) + " AND " + k.Id + " IN(" + list + ")" + OrderBy(k, f) + ";", noCursor, seek))
                using (var r = c.ExecuteReader())
                    while (r.Read()) { _cancel.ThrowIfCancellationRequested(); rows.Add(k.Convert(Values(r))); }
            }
            return rows;
        }

        // ------------------------------------------------------------------------------------------------------------ list, count, facets

        ServeCellFilter FilterOf(string view, ServeFilter f) { return ServeCellFilter.Parse(ServeView.Get(view), f.Query ?? new System.Collections.Specialized.NameValueCollection(), _options.Zone); }

        /// <summary>One keyset page of a day-sliced list (messages, sessions, issues) with the filters of the page.</summary>
        internal ServePage Keyed(string view, ServeFilter f)
        {
            var k = Shape(view);
            var columns = view == "issues" ? IssueColumns : Columns(view);
            var filter = FilterOf(view, f);
            var page = new ServePage { columns = columns, rows = new List<ServeRow>(), size = f.Size, total = null };
            if (OutsideWindow(view, f) || (view == "messages" && NoMessageStatus(f)))
            { page.exhausted = true; page.complete = true; return page; }
            var seek = SeekOf(k, f, filter);
            if (seek.ExactMiss) { page.exhausted = true; page.complete = true; page.exactMiss = true; return page; }
            var test = filter.Predicate(seek.Applied);
            if (test == null && !k.Heavy(f))
            {
                long lastKey = 0;
                using (var c = KeysetCommand(Led(RowsSql(k, f, seek), Lead(k, f, f.CursorKey.HasValue ? After(k, f, "@ck", "@cid") : "")) + OrderBy(k, f) + " LIMIT @limit" + (f.Skip > 0 ? " OFFSET @skip" : "") + ";", f, seek))
                {
                    c.Parameters.AddWithValue("@limit", f.Size + 1); c.Parameters.AddWithValue("@skip", f.Skip);
                    using (var r = c.ExecuteReader())
                        while (r.Read())
                        {
                            _cancel.ThrowIfCancellationRequested();
                            var raw = Values(r);
                            if (page.rows.Count < f.Size) lastKey = Long(raw[0]);
                            page.rows.Add(k.Convert(raw));
                        }
                }
                bool more = page.rows.Count > f.Size;
                if (more) page.rows.RemoveAt(page.rows.Count - 1);
                page.hasMore = more; page.exhausted = !more; page.complete = true;
                page.nextCursor = more ? Cursor(lastKey, page.rows[page.rows.Count - 1].id) : null;
                if (f.Skip > 0 && page.rows.Count > 0) page.skipped = f.Skip;
                return page;
            }
            int skip = f.Skip, skipped = 0;
            var ids = new List<long>();
            long last = 0;
            bool full = false;
            string scanned; bool finished, following;
            // The page ends on its last row: a row after it is known only when the chunk that filled the page holds one.
            ScanChunks(k, f, seek, () => Tested(filter, seek.Applied), test, (key, id, cells) =>
            {
                if (skip > 0) { skip--; skipped++; return true; }
                ids.Add(id); last = key;
                full = ids.Count == f.Size;
                return !full;
            }, out scanned, out finished, out following, page: true);
            page.rows = RowsById(k, f, seek, ids);
            page.budgetMs = Budget(f, true);
            if (f.Skip > 0) page.skipped = skipped;
            if (full)
            {
                page.hasMore = following; page.exhausted = !following; page.complete = true;
                page.nextCursor = page.scannedTo = following ? Cursor(last, ids[ids.Count - 1]) : null;
            }
            else if (finished) { page.hasMore = false; page.exhausted = true; page.complete = true; page.nextCursor = null; }
            else { page.hasMore = true; page.exhausted = false; page.complete = false; page.nextCursor = page.scannedTo = scanned; }
            return page;
        }

        /// <summary>
        /// The exact number of rows of an order window (one day at most) with the filters of the page, and their histogram on the list key (UTC
        /// milliseconds floored to bucketMs). A scan answers what it counted within its budget: complete=false and scannedTo, from which the page
        /// asks again with cursor.
        /// </summary>
        internal ServeCount Count(string view, ServeFilter f)
        {
            var k = Shape(view);
            var filter = FilterOf(view, f);
            var counts = new SortedDictionary<long, long>();
            var answer = new ServeCount { cached = false, buckets = new List<long[]>(), complete = true, budgetMs = Budget(f) };
            if (OutsideWindow(view, f) || (view == "messages" && NoMessageStatus(f))) return answer;
            var seek = SeekOf(k, f, filter);
            if (seek.ExactMiss) { answer.exactMiss = true; return answer; }
            var test = filter.Predicate(seek.Applied);
            long b = f.BucketMs;
            if (test == null && !k.Heavy(f))
            {
                using (var c = KeysetCommand(Led("SELECT (" + k.Key + "/@b)*@b,COUNT(*)" + k.Where(f, seek.Hint, false) + seek.Sql, Lead(k, f, f.CursorKey.HasValue ? After(k, f, "@ck", "@cid") : "")) + " GROUP BY 1;", f, seek))
                {
                    c.Parameters.AddWithValue("@b", b);
                    using (var r = c.ExecuteReader()) while (r.Read()) counts[r.GetInt64(0)] = r.GetInt64(1);
                }
            }
            else
            {
                string scanned; bool finished, following;
                ScanChunks(k, f, seek, () => Tested(filter, seek.Applied), test, (key, id, cells) => { long at = key / b * b; long n; counts.TryGetValue(at, out n); counts[at] = n + 1; return true; }, out scanned, out finished, out following, false);
                answer.complete = finished; answer.scannedTo = finished ? null : scanned;
            }
            foreach (var kv in counts) { answer.buckets.Add(new[] { kv.Key, kv.Value }); answer.total += kv.Value; }
            return answer;
        }

        /// <summary>
        /// The fields of a view whose values repeat (the dictionary codes and the kind of the messages; the protocol, the client, the servers, the
        /// software, the authentication types and the outcome of the sessions): a value list whose cells read these fields alone is counted per distinct
        /// combination of them. The authentication types of a session (auth_modes) are stored with their request counts ("Negotiate=57;OAuth=3"), so
        /// their groups are nearly one per session: grouping them saves the building of the cells, not the reading of the rows.
        /// </summary>
        static readonly Dictionary<string, int[]> GroupFields = new Dictionary<string, int[]>(StringComparer.Ordinal)
        {
            { "messages", new[] { 3, 11, 12, 13, 16 } },
            { "sessions", new[] { 4, 7, 9, 10, 11, 12, 13, 29, 30 } },
        };
        /// <summary>Diagnostics: the value lists are counted from the cells of every row, also the columns of GroupFields.</summary>
        bool _cellFacets;

        /// <summary>
        /// The value lists of the page for an order window: per column, each value with its number of rows (the parts of a joined value and the
        /// items of a list counted one by one); a column with more than its cap of values is in truncated (the page gives it a text box). Without a
        /// filter the statement cannot answer, the columns of GroupFields (Status, Direction, Servers and Kind of the messages from the index entries)
        /// are counted per group of their fields (Grouped); the other columns from the cells of the rows, every column in one pass per chunk, until each
        /// has more values than its cap or the budget is spent; the groups then cover the rows that pass examined.
        /// </summary>
        internal ServeFacets Facets(string view, ServeFilter f)
        {
            var k = Shape(view);
            var v = ServeView.Get(view);
            var filter = FilterOf(view, f);
            var wanted = (f.Columns ?? v.Columns.Where(c => c.Kind == "text" || c.Kind == "list").Select(c => c.Name).ToArray()).Select(name =>
            {
                var c = v.Find(name);
                if (c == null || (c.Kind != "text" && c.Kind != "list")) throw new ServeError(400, "InvalidParameter", "columns must name text or list columns of the view.");
                return c;
            }).Distinct().ToArray();
            var answer = new ServeFacets { cached = false, columns = new Dictionary<string, List<object[]>>(StringComparer.Ordinal), truncated = new List<string>(), complete = true, budgetMs = Budget(f) };
            var counts = wanted.ToDictionary(c => c, c => new Dictionary<string, long>(StringComparer.Ordinal));
            var over = new HashSet<ServeViewColumn>();
            Func<ServeViewColumn, int> cap = c => f.Cap ?? (c.Listed ? 300 : 50);
            Action<ServeViewColumn, string, long> add = (c, value, n) =>
            {
                if (over.Contains(c) || value.Length == 0) return;
                var d = counts[c]; long x;
                if (d.TryGetValue(value, out x)) d[value] = x + n;
                else if (d.Count >= cap(c)) { over.Add(c); d.Clear(); }
                else d[value] = n;
            };
            Action<ServeViewColumn, object, long> count = (c, value, n) =>
            {
                if (value == null) return;
                if (value is string[] items) { foreach (var item in items) if (item != null) add(c, item, n); return; }
                string text = ServeExpression.Flat(value);
                if (c.Listed && text.Contains(", ", StringComparison.Ordinal)) { foreach (var part in text.Split(", ")) add(c, part, n); }
                else add(c, text, n);
            };
            if (!OutsideWindow(view, f) && !(view == "messages" && NoMessageStatus(f)))
            {
                var seek = SeekOf(k, f, filter);
                var test = filter.Predicate(seek.Applied);
                int[] fields;
                var groupable = test == null && !_cellFacets && GroupFields.TryGetValue(view, out fields) ? new HashSet<int>(fields) : null;
                var grouped = groupable == null ? new ServeViewColumn[0] : wanted.Where(c => k.Cells.Needs[c.Cell].All(groupable.Contains)).ToArray();
                var free = wanted.Except(grouped).ToArray();
                string scanned = null; bool finished = true, following;
                if (free.Length > 0)
                    ScanChunks(k, f, seek, () => free.Where(c => !over.Contains(c)).Concat(Tested(filter, seek.Applied)), test,
                        (key, id, cells) => { bool live = false; foreach (var c in free) if (!over.Contains(c)) { count(c, cells[c.Cell], 1); live |= !over.Contains(c); } return live; },
                        out scanned, out finished, out following, false);
                answer.complete = finished || free.All(over.Contains); answer.scannedTo = answer.complete ? null : scanned;
                if (grouped.Length > 0) Grouped(k, f, seek, grouped, answer.scannedTo, count);
            }
            foreach (var c in wanted)
            {
                if (over.Contains(c)) { answer.truncated.Add(c.Name); continue; }
                answer.columns[c.Name] = counts[c].OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => new object[] { x.Key, x.Value }).ToList();
            }
            return answer;
        }

        /// <summary>
        /// Counts value lists whose cells read the fields of GroupFields alone: one statement over the window from the cursor (up to the position upTo
        /// included when the scan of the other columns stopped there), its rows grouped in memory by those fields (CountRows: no sort, no value decoded
        /// per row), each cell built once per group as a scan builds it, and counted with the rows of its group.
        /// </summary>
        void Grouped(Keyset k, ServeFilter f, Seek seek, ServeViewColumn[] columns, string upTo, Action<ServeViewColumn, object, long> count)
        {
            var source = k.Cells;
            var fields = columns.SelectMany(c => source.Needs[c.Cell]).Distinct().OrderBy(x => x).ToArray();
            var at = new int[source.Fields.Length];
            for (int i = 0; i < fields.Length; i++) at[fields[i]] = i;
            long[] end = upTo == null ? null : Position(upTo);
            string range = (f.CursorKey.HasValue ? After(k, f, "@ck", "@cid") : "") + (end == null ? "" : UpTo(k, f));
            List<KeyValuePair<object[], long>> groups;
            using (var c = KeysetCommand(Led("SELECT " + string.Join(",", fields.Select(i => source.Fields[i])) + k.Where(f, seek.Hint, false) + seek.Sql, Lead(k, f, range)) + ";", f, seek))
            {
                if (end != null) { c.Parameters.AddWithValue("@uk", end[0]); c.Parameters.AddWithValue("@uid", end[1]); }
                groups = CountRows(c);
            }
            foreach (var group in groups)
            {
                Func<int, object> field = i => group.Key[at[i]];
                foreach (var column in columns) count(column, source.Cell[column.Cell](field), group.Value);
            }
        }

        /// <summary>Diagnostics: the plans of the page, of the count and of the chunk boundary of a keyset request ("statement => plan").</summary>
        internal List<string> ExplainKeyset(string view, ServeFilter f)
        {
            var k = Shape(view);
            var seek = SeekOf(k, f, FilterOf(view, f));
            ExplainPlans = new List<string>();
            try
            {
                Action<SqliteCommand> parameters = c =>
                {
                    FilterParameters(c, f);
                    foreach (var kv in seek.Parameters) c.Parameters.AddWithValue(kv.Key, kv.Value);
                    if (f.CursorKey.HasValue) { c.Parameters.AddWithValue("@ck", f.CursorKey.Value); c.Parameters.AddWithValue("@cid", f.CursorId.Value); }
                };
                Explain(Led(RowsSql(k, f, seek), Lead(k, f, f.CursorKey.HasValue ? After(k, f, "@ck", "@cid") : "")) + OrderBy(k, f) + " LIMIT @limit" + (f.Skip > 0 ? " OFFSET @skip" : "") + ";", parameters);
                Explain(Led("SELECT (" + k.Key + "/@b)*@b,COUNT(*)" + k.Where(f, seek.Hint, false) + seek.Sql, Lead(k, f, f.CursorKey.HasValue ? After(k, f, "@ck", "@cid") : "")) + " GROUP BY 1;", parameters);
                string from = k.View == "messages" ? "message_rollup r INDEXED BY " + MessageIndex(f) : k.From + " INDEXED BY " + k.KeyIndex;
                Explain(Led("SELECT " + k.Key + " FROM " + from + " WHERE " + k.WindowWhere(f), Lead(k, f, After(k, f, "@pk", "@pid"))) + " ORDER BY " + k.Key + (f.Ascending ? "" : " DESC") + " LIMIT 1 OFFSET 19999;", parameters);
                return ExplainPlans;
            }
            finally { ExplainPlans = null; }
        }

        /// <summary>
        /// Diagnostics: every row of the lists of a period built column by column (CellSource) and whole (ConvertRow, IssueCells); the differences
        /// found ("view id column: whole | by column"), at most 20.
        /// </summary>
        internal List<string> CompareListCells(ServeFilter f)
        {
            var differences = new List<string>();
            foreach (string view in new[] { "messages", "sessions", "issues" })
            {
                var k = Shape(view);
                var seek = SeekOf(k, f, FilterOf(view, f));
                var whole = new Dictionary<long, object[]>();
                using (var c = KeysetCommand(RowsSql(k, f, seek) + ";", f, seek))
                using (var r = c.ExecuteReader()) while (r.Read()) { var row = k.Convert(Values(r)); whole[row.id] = row.cells; }
                var all = ServeView.Get(view).Columns;
                var byColumn = new Dictionary<long, object[]>();
                string scanned; bool finished, following;
                ScanChunks(k, f, seek, () => all, null, (key, id, cells) => { byColumn[id] = cells; return true; }, out scanned, out finished, out following);
                if (!finished || byColumn.Count != whole.Count)
                    differences.Add(view + ": " + whole.Count.ToString(CultureInfo.InvariantCulture) + " rows whole, " + byColumn.Count.ToString(CultureInfo.InvariantCulture) + " by column");
                foreach (var kv in whole)
                {
                    object[] cells;
                    if (!byColumn.TryGetValue(kv.Key, out cells)) continue;
                    foreach (var col in all)
                    {
                        string a = JsonSerializer.Serialize(kv.Value[col.Cell]), b = JsonSerializer.Serialize(cells[col.Cell]);
                        if (a != b && differences.Count < 20) differences.Add(view + " " + kv.Key.ToString(CultureInfo.InvariantCulture) + " " + col.Name + ": " + a + " | " + b);
                    }
                }
            }
            // The value lists counted per group of fields equal the value lists counted from the cells of every row, for each day window of the period.
            foreach (string view in new[] { "messages", "sessions" })
                for (long day = f.From; day < f.To; day += 86400000)
                {
                    var window = new ServeFilter { From = f.From, To = f.To, OrderFrom = day, OrderTo = Math.Min(f.To, day + 86400000) };
                    string grouped, cells;
                    try { _cellFacets = false; grouped = JsonSerializer.Serialize(Facets(view, window)); _cellFacets = true; cells = JsonSerializer.Serialize(Facets(view, window)); }
                    finally { _cellFacets = false; }
                    if (grouped != cells && differences.Count < 20)
                        differences.Add(view + " value lists of " + Iso(day) + ": grouped " + grouped.Substring(0, Math.Min(400, grouped.Length)) + " | by cell " + cells.Substring(0, Math.Min(400, cells.Length)));
                }
            return differences;
        }
    }
}
