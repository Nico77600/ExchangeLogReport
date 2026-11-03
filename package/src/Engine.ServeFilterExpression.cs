using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace ExchangeLogReport
{
    // =================================================================================================================================
    // The filter language of the report page on the server: the column expressions (compileNum, compileTime, compileText of
    // Report.template.js), its search syntax (parseSearch: free words, field:value, -field:value, field>n, "quoted phrase"), its value
    // lists (m.<Column>, x.<Column>) and its free words. Every test runs on the cells the list returns for a row, by column, so a filter
    // selects on the server exactly what the page selects on its loaded rows. Times are compared as the page compares them: wall-clock
    // seconds of the report time zone. Text is lowered by Lower, as the page lowers it (the dotted capital I becomes i first).
    // =================================================================================================================================

    /// <summary>A compiled column expression: a test of one cell value, or the error the page shows for the text typed.</summary>
    internal sealed class ServeExpression
    {
        internal readonly Func<object, bool> Test;
        internal readonly string Error;
        /// <summary>Text "=x" (not negated, x not empty): x as typed, case kept.</summary>
        internal string Exact;
        ServeExpression(Func<object, bool> test, string error) { Test = test; Error = error; }
        static ServeExpression Fail(string message) { return new ServeExpression(null, message); }
        /// <summary>
        /// Text in lower case as the page compares it: the dotted capital I (U+0130), the one letter whose full lower case mapping changes the length, becomes
        /// i, then the invariant lower case.
        /// </summary>
        internal static string Lower(string text) { return text.Replace('\u0130', 'i').ToLowerInvariant(); }

        /// <summary>The expression of a column of kind num, time or text/list; null when nothing is typed. split: the column joins values with ", ".</summary>
        internal static ServeExpression Column(string kind, string text, bool split)
        {
            if (text.Trim().Length == 0) return null;
            return kind == "num" ? Num(text) : kind == "time" ? Time(text) : Text(text, split);
        }

        const string N = "-?[0-9]+(?:\\.[0-9]+)?";
        static readonly Regex NumRange = new Regex("^(" + N + ")?\\.\\.(" + N + ")?$", RegexOptions.CultureInvariant);
        static readonly Regex NumOne = new Regex("^(<=|>=|<|>|=|!=)?(" + N + ")$", RegexOptions.CultureInvariant);
        static readonly Regex Blank = new Regex("[\\s,]", RegexOptions.CultureInvariant);
        internal static double? Number(object v)
        {
            if (v is long l) return l;
            if (v is int i) return i;
            if (v is double d) return d;
            if (v is float f) return f;
            if (v is decimal m) return (double)m;
            return null;
        }
        static double Parse(string s) { return double.Parse(s, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture); }

        static ServeExpression Num(string text)
        {
            string t = Blank.Replace(text, "");
            var m = NumRange.Match(t);
            if (m.Success && (m.Groups[1].Success || m.Groups[2].Success))
            {
                double lo = m.Groups[1].Success ? Parse(m.Groups[1].Value) : double.NegativeInfinity, hi = m.Groups[2].Success ? Parse(m.Groups[2].Value) : double.PositiveInfinity;
                if (lo > hi) return Fail("The start of the range is above its end.");
                return new ServeExpression(v => { var x = Number(v); return x.HasValue && x.Value >= lo && x.Value <= hi; }, null);
            }
            m = NumOne.Match(t);
            if (!m.Success) return Fail("A number is expected: 5000, >5000, >=10, <3, <=3, 100..200, =0, !=0.");
            double n = Parse(m.Groups[2].Value);
            switch (m.Groups[1].Value)
            {
                case ">": return new ServeExpression(v => { var x = Number(v); return x.HasValue && x.Value > n; }, null);
                case ">=": return new ServeExpression(v => { var x = Number(v); return x.HasValue && x.Value >= n; }, null);
                case "<": return new ServeExpression(v => { var x = Number(v); return x.HasValue && x.Value < n; }, null);
                case "<=": return new ServeExpression(v => { var x = Number(v); return x.HasValue && x.Value <= n; }, null);
                case "!=": return new ServeExpression(v => { var x = Number(v); return !x.HasValue || x.Value != n; }, null);
                default: return new ServeExpression(v => { var x = Number(v); return x.HasValue && x.Value == n; }, null);
            }
        }

        // A time bound: a date, a date and time, or a time of day (any day). [lo, hi) covers what was typed (the day, the minute or the second), in
        // wall-clock seconds of the report time zone.
        static readonly Regex TimeText = new Regex("^(?:([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)?|([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?)$", RegexOptions.CultureInvariant);
        struct Operand { public bool Tod; public double Lo, Hi; }
        static Operand? TimeOperand(string text)
        {
            var m = TimeText.Match(text.Trim());
            if (!m.Success) return null;
            bool date = m.Groups[1].Success;
            Group hh = m.Groups[date ? 4 : 7], mm = m.Groups[date ? 5 : 8], ss = m.Groups[date ? 6 : 9];
            int h = hh.Success ? int.Parse(hh.Value, CultureInfo.InvariantCulture) : 0, mi = mm.Success ? int.Parse(mm.Value, CultureInfo.InvariantCulture) : 0,
                s = ss.Success ? int.Parse(ss.Value, CultureInfo.InvariantCulture) : 0;
            if (h > 23 || mi > 59 || s > 59) return null;
            double unit = ss.Success ? 1 : hh.Success ? 60 : 86400, clock = h * 3600 + mi * 60 + s;
            if (!date) return new Operand { Tod = true, Lo = clock, Hi = clock + unit };
            int year = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), month = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture), day = int.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture);
            // Date.UTC reads the years 0 to 99 as 1900 to 1999; a month or a day out of range is not a date.
            if (year <= 99) year += 1900;
            if (month < 1 || month > 12 || day < 1 || day > DateTime.DaysInMonth(year, month)) return null;
            double start = (new DateTime(year, month, day, 0, 0, 0, DateTimeKind.Utc) - DateTime.UnixEpoch).TotalSeconds;
            return new Operand { Tod = false, Lo = start + clock, Hi = start + clock + unit };
        }
        static double TimeOfDay(double v) { return ((v % 86400) + 86400) % 86400; }
        static ServeExpression Time(string text)
        {
            string t = text.Trim();
            var bad = Fail("A time is expected: 2026-10-10, >=2026-10-10 10:00, <10:30, 10:00..10:15, 2026-10-10..2026-10-12.");
            int cut = t.IndexOf("..", StringComparison.Ordinal);
            if (cut >= 0)
            {
                string sa = t.Substring(0, cut).Trim(), sb = t.Substring(cut + 2).Trim();
                Operand? a = sa.Length > 0 ? TimeOperand(sa) : null, b = sb.Length > 0 ? TimeOperand(sb) : null;
                if ((sa.Length > 0 && a == null) || (sb.Length > 0 && b == null) || (a == null && b == null)) return bad;
                if (a != null && b != null && a.Value.Tod != b.Value.Tod) return Fail("A range cannot mix dates and times of day.");
                bool tod = (a ?? b).Value.Tod;
                double lo = a.HasValue ? a.Value.Lo : double.NegativeInfinity, hi = b.HasValue ? b.Value.Hi : double.PositiveInfinity;
                if (!tod && lo >= hi) return Fail("The start of the range is after its end.");
                // 22:00..02:00 wraps over midnight.
                return new ServeExpression(v => { var n = Number(v); if (!n.HasValue) return false; double x = tod ? TimeOfDay(n.Value) : n.Value; return lo < hi ? x >= lo && x < hi : x >= lo || x < hi; }, null);
            }
            var m = Regex.Match(t, "^(<=|>=|<|>|=)?\\s*(.+)$", RegexOptions.CultureInvariant | RegexOptions.Singleline);
            var o = m.Success ? TimeOperand(m.Groups[2].Value) : null;
            if (o == null) return bad;
            bool day = o.Value.Tod; double low = o.Value.Lo, high = o.Value.Hi;
            Func<double, bool> compare;
            switch (m.Groups[1].Value)
            {
                case ">": compare = x => x >= high; break;
                case ">=": compare = x => x >= low; break;
                case "<": compare = x => x < low; break;
                case "<=": compare = x => x < high; break;
                default: compare = x => x >= low && x < high; break;
            }
            return new ServeExpression(v => { var n = Number(v); return n.HasValue && compare(day ? TimeOfDay(n.Value) : n.Value); }, null);
        }

        // Text: contains, case-insensitive; "=x" is exactly x, "!x" does not contain x, "!=x" is not exactly x ("=" alone: empty). split: "=x" also
        // matches one of the parts of a value joined with ", ".
        internal static string Flat(object v)
        {
            if (v == null) return "";
            if (v is string s) return s;
            if (v is string[] list) return string.Join(", ", list);
            if (v is IEnumerable<object> items) return string.Join(", ", items.Select(x => Convert.ToString(x, CultureInfo.InvariantCulture)));
            return Convert.ToString(v, CultureInfo.InvariantCulture);
        }
        static IEnumerable<string> Items(object v)
        {
            if (v is string[] list) return list;
            if (v is IEnumerable<object> items && !(v is string)) return items.Select(x => Convert.ToString(x, CultureInfo.InvariantCulture));
            return null;
        }
        static ServeExpression Text(string text, bool split)
        {
            string t = text.Trim(); bool exact = false, not = false;
            if (t.StartsWith("!=", StringComparison.Ordinal)) { exact = true; not = true; t = t.Substring(2); }
            else if (t.StartsWith("=", StringComparison.Ordinal)) { exact = true; t = t.Substring(1); }
            else if (t.StartsWith("!", StringComparison.Ordinal)) { not = true; t = t.Substring(1); }
            string typed = t.Trim();
            t = Lower(typed);
            if (t.Length == 0 && !exact) return Fail("Some text is expected after !.");
            Func<object, bool> inner;
            Func<object, bool> same = v => { string s = Lower(Flat(v)); return s == t || (split && s.Contains(", ", StringComparison.Ordinal) && s.Split(", ").Contains(t)); };
            if (exact) inner = t.Length == 0 ? v => Flat(v).Length == 0 : v => { var items = Items(v); return items != null ? items.Any(p => Lower(p) == t) : same(v); };
            // A list is searched item by item (the same unless the text itself holds a comma).
            else if (t.Contains(',')) inner = v => v != null && Lower(Flat(v)).Contains(t, StringComparison.Ordinal);
            else inner = v =>
            {
                if (v == null) return false;
                var items = Items(v);
                return items != null ? items.Any(p => Lower(p).Contains(t, StringComparison.Ordinal)) : Lower(Flat(v)).Contains(t, StringComparison.Ordinal);
            };
            var e = new ServeExpression(not ? v => !inner(v) : inner, null);
            if (exact && !not && typed.Length > 0) e.Exact = typed;
            return e;
        }
    }

    /// <summary>A column of a view as the page's table holds it: its dataset column, its index in the cells of the list, whether its list joins values.</summary>
    internal sealed class ServeViewColumn
    {
        internal string Name, Kind, Key;
        internal int Cell;
        internal bool Listed;
    }

    /// <summary>
    /// The columns of the day-sliced lists the page filters (the dataset columns of report-meta but the detail ones), with the columns that the
    /// page shows as joined value lists (the filters of its tabs).
    /// </summary>
    internal sealed class ServeView
    {
        internal readonly string Name;
        internal readonly ServeViewColumn[] Columns;
        internal readonly ServeViewColumn Key;
        ServeView(string name, string[] dataset, ServeColumn[] list, string[] listed, string key)
        {
            Name = name;
            var cells = list.Select(c => c.name).ToList();
            Columns = dataset.Select(d => { int colon = d.LastIndexOf(':'); return new { Name = d.Substring(0, colon), Kind = d.Substring(colon + 1) }; })
                .Where(d => d.Kind != "steps")
                .Select(d => new ServeViewColumn { Name = d.Name, Kind = d.Kind, Cell = cells.IndexOf(d.Name), Listed = listed.Contains(d.Name), Key = Normal(d.Name) })
                .Where(c => c.Cell >= 0).ToArray();
            Key = Columns.First(c => c.Name == key);
        }
        static ServeView _messages, _sessions, _issues;
        internal static ServeView Get(string view)
        {
            if (view == "messages") return _messages ??= new ServeView("messages", ReportBuilder.ServeMessageColumns, ServeRead.MessageColumns, new[] { "Status", "Direction" }, "Last event");
            if (view == "sessions") return _sessions ??= new ServeView("sessions", ReportBuilder.SessionColumns, ServeRead.SessionColumns, new[] { "Outcome", "Protocol", "Client", "Front ends", "Back ends", "Authentication" }, "Start");
            if (view == "issues") return _issues ??= new ServeView("issues", ReportBuilder.IssueColumns, ServeColumn.Parse(ReportBuilder.IssueColumns), new[] { "Server", "Protocol", "Outcome", "Resolution" }, "Time");
            return null;
        }
        internal ServeViewColumn Find(string name) { return Columns.FirstOrDefault(c => c.Name == name); }
        internal static string Normal(string s) { return Regex.Replace(s.ToLowerInvariant(), "[^a-z0-9]", ""); }
        /// <summary>True when the name is one of the filter parameters of this view: f.|m.|x.&lt;Column&gt;.</summary>
        internal bool FilterParameter(string name)
        {
            return name != null && name.Length > 2 && (name.StartsWith("f.", StringComparison.Ordinal) || name.StartsWith("m.", StringComparison.Ordinal) || name.StartsWith("x.", StringComparison.Ordinal)) &&
                Find(name.Substring(2)) != null;
        }
    }

    /// <summary>One filter of a request on one column: the test of a cell value; the selected values of a list; the exact text of "=x".</summary>
    internal sealed class ServeTerm
    {
        internal ServeViewColumn Column;
        internal Func<object, bool> Test;
        internal string[] Values;
        internal bool Exclude;
        internal string Exact;
        internal string Label;
    }

    /// <summary>
    /// The filters of a request in the page's language: f.&lt;Column&gt; (a text box), m.&lt;Column&gt; (values of a list, |-separated) with x.&lt;Column&gt;=1
    /// (exclude them), q (the search text, read as the page reads it) and w (free words, |-separated, lower case). Terms are tests of one column;
    /// words must each appear in a text or list cell of the row.
    /// </summary>
    internal sealed class ServeCellFilter
    {
        internal readonly List<ServeTerm> Terms = new List<ServeTerm>();
        internal readonly List<string> Words = new List<string>();
        internal readonly ServeView View;
        readonly TimeZoneInfo _zone;
        ServeCellFilter(ServeView view, TimeZoneInfo zone) { View = view; _zone = zone; }
        internal bool Empty { get { return Terms.Count == 0 && Words.Count == 0; } }

        static readonly Regex Term = new Regex("(-?)([A-Za-z][A-Za-z0-9]*)(:|>=|<=|>|<)(\"[^\"]*\"|\\S*)|\"([^\"]*)\"|(\\S+)", RegexOptions.CultureInvariant);

        internal static ServeCellFilter Parse(ServeView view, NameValueCollection query, TimeZoneInfo zone)
        {
            var filter = new ServeCellFilter(view, zone);
            if (view == null) return filter;
            foreach (string key in query.AllKeys)
            {
                if (key == null || key.Length < 3 || key[1] != '.') continue;
                var c = view.Find(key.Substring(2));
                if (c == null) continue;
                string value = query[key];
                if (key[0] == 'f')
                {
                    var e = ServeExpression.Column(c.Kind, value, c.Listed);
                    if (e == null) continue;
                    if (e.Error != null) throw new ServeError(400, "InvalidFilter", c.Name + ": " + e.Error);
                    filter.Terms.Add(new ServeTerm { Column = c, Test = e.Test, Exact = c.Kind == "text" || c.Kind == "list" ? e.Exact : null, Label = c.Name + " " + value.Trim() });
                }
                else if (key[0] == 'm')
                {
                    var values = value.Split('|').Where(v => v.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
                    if (values.Length == 0) continue;
                    bool exclude = query["x." + c.Name] == "1";
                    filter.Terms.Add(new ServeTerm { Column = c, Values = values, Exclude = exclude, Test = MultiTest(c, new HashSet<string>(values, StringComparer.Ordinal), exclude),
                        Label = c.Name + (exclude ? " not in " : " in ") + (values.Length <= 2 ? string.Join(", ", values) : values.Length.ToString(CultureInfo.InvariantCulture) + " values") });
                }
                else if (key[0] == 'x' && value != "1") throw new ServeError(400, "InvalidFilter", key + " must be 1.");
            }
            if (query["w"] != null) foreach (string w in query["w"].Split('|')) if (w.Length > 0) filter.Words.Add(ServeExpression.Lower(w));
            if (query["q"] != null) filter.Search(query["q"]);
            return filter;
        }

        // A value of a list: text compared whole (and by its ", " parts in a joined list), a list cell by its items; "exclude" keeps the rows without one.
        static Func<object, bool> MultiTest(ServeViewColumn c, HashSet<string> selected, bool exclude)
        {
            if (c.Kind == "list")
                return v => { var items = v as string[]; bool hit = items != null && items.Any(selected.Contains); return hit != exclude; };
            return v =>
            {
                string text = ServeExpression.Flat(v);
                bool hit = text.Length > 0 && (selected.Contains(text) || (c.Listed && text.Contains(", ", StringComparison.Ordinal) && text.Split(", ").Any(selected.Contains)));
                return hit != exclude;
            };
        }

        /// <summary>The search text as the page parses it: unknown or ambiguous fields and text fields with a comparison count as free words; invalid expressions are left out.</summary>
        void Search(string text)
        {
            foreach (Match m in Term.Matches(text))
            {
                if (!m.Groups[2].Success)
                {
                    string w = ServeExpression.Lower(m.Groups[5].Success ? m.Groups[5].Value : m.Groups[6].Value);
                    if (w.Length > 0) Words.Add(w);
                    continue;
                }
                string key = ServeView.Normal(m.Groups[2].Value), op = m.Groups[3].Value, value = Regex.Replace(m.Groups[4].Value, "^\"|\"$", "");
                if (value.Trim().Length == 0) continue;
                var c = View.Columns.FirstOrDefault(x => x.Key == key);
                if (c == null)
                {
                    var near = View.Columns.Where(x => x.Key.StartsWith(key, StringComparison.Ordinal)).ToArray();
                    if (near.Length != 1) { Words.Add(ServeExpression.Lower(m.Value)); continue; }
                    c = near[0];
                }
                if (op != ":" && c.Kind != "num" && c.Kind != "time") { Words.Add(ServeExpression.Lower(m.Value)); continue; }
                var e = ServeExpression.Column(c.Kind, op == ":" ? value : op + value, c.Listed);
                if (e == null || e.Error != null) continue;
                bool not = m.Groups[1].Value == "-";
                var test = e.Test;
                Terms.Add(new ServeTerm { Column = c, Test = not ? v => !test(v) : test, Exact = !not && (c.Kind == "text" || c.Kind == "list") ? e.Exact : null, Label = m.Value });
            }
        }

        /// <summary>The value of a column of a row for the tests: the cell, a time as wall-clock seconds of the report time zone.</summary>
        internal object Value(ServeViewColumn c, object[] cells)
        {
            object v = cells[c.Cell];
            if (c.Kind != "time" || v == null) return v;
            long ms;
            if (v is string s) ms = DateTimeOffset.ParseExact(s, "O", CultureInfo.InvariantCulture, DateTimeStyles.None).ToUnixTimeMilliseconds();
            else { var n = ServeExpression.Number(v); if (!n.HasValue) return v; ms = (long)n.Value; }
            return (ms + _zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(ms)).TotalMilliseconds) / 1000.0;
        }

        /// <summary>The test of the terms (but those the statement already applies) and of the words on the cells of a row; null when nothing remains to test.</summary>
        internal Func<object[], bool> Predicate(HashSet<ServeTerm> applied)
        {
            var terms = Terms.Where(t => applied == null || !applied.Contains(t)).ToArray();
            if (terms.Length == 0 && Words.Count == 0) return null;
            var words = Words.ToArray();
            var searched = View.Columns.Where(c => c.Kind == "text" || c.Kind == "list").ToArray();
            return cells =>
            {
                foreach (var t in terms) if (!t.Test(Value(t.Column, cells))) return false;
                if (words.Length == 0) return true;
                var lowered = new List<string>(searched.Length);
                foreach (var c in searched)
                {
                    object v = cells[c.Cell];
                    if (v == null) continue;
                    if (v is string[] items) { foreach (var item in items) if (item != null) lowered.Add(ServeExpression.Lower(item)); }
                    else { string text = ServeExpression.Flat(v); if (text.Length > 0) lowered.Add(ServeExpression.Lower(text)); }
                }
                foreach (var w in words) if (!lowered.Any(x => x.Contains(w, StringComparison.Ordinal))) return false;
                return true;
            };
        }

        /// <summary>What the filters say, as the result line of the page says it.</summary>
        internal string Describe()
        {
            var parts = Terms.Select(t => t.Label).ToList();
            if (Words.Count > 0) parts.Add("words " + string.Join(" ", Words.Select(w => "\"" + w + "\"")));
            return string.Join("; ", parts);
        }
    }
}
