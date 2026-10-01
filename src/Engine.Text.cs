// =============================================================================
//  Exchange Log Report - engine, part 1: text helpers
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 1.3.1
//  The src\Engine.*.cs files are compiled together by ExchangeLogReport.psm1
//  the first time they are used (and again whenever one of them changes).
//
//  Conventions used by the whole engine
//    - Every time stored in the database is a Unix epoch in MILLISECONDS (UTC).
//    - Exchange writes all its logs in UTC (ISO 8601 "Z" or W3C date + time).
//    - Usage days are calendar days (yyyy-MM-dd) of the report time zone.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace ExchangeLogReport
{
    /// <summary>
    /// Font of the classic Windows console (conhost). The console has no font fallback, so the
    /// module chooses the frame characters from it. Null outside a classic console or on error.
    /// </summary>
    public static class ConsoleFont
    {
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        struct ConsoleFontInfoEx
        {
            public uint Size; public uint Font; public short Width; public short Height; public int Family; public int Weight;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int handle);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetCurrentConsoleFontEx(IntPtr output, bool maximumWindow, ref ConsoleFontInfoEx info);

        public static string FaceName()
        {
            try
            {
                if (Console.IsOutputRedirected || !OperatingSystem.IsWindows()) return null;
                var info = new ConsoleFontInfoEx { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<ConsoleFontInfoEx>() };
                return GetCurrentConsoleFontEx(GetStdHandle(-11), false, ref info) ? info.FaceName : null;
            }
            catch { return null; }
        }
    }

    /// <summary>
    /// Reads the complete lines of a log file from a byte offset. The file is opened with full
    /// sharing: Exchange keeps the current log files open for writing. A last line without its
    /// end-of-line is not returned (still being written): it is read again at the next collection.
    /// Each line comes with the byte offset that follows it, which becomes the resume point.
    /// </summary>
    public static class LogReader
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, false);

        public static IEnumerable<KeyValuePair<string, long>> ReadLines(string path, long offset)
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16))
            {
                if (offset < 0 || offset > fs.Length) offset = 0;
                fs.Seek(offset, SeekOrigin.Begin);
                var buffer = new byte[1 << 20];
                var pending = new MemoryStream();
                long position = offset;
                bool first = offset == 0;
                int read;
                while ((read = fs.Read(buffer, 0, buffer.Length)) > 0)
                {
                    int start = 0;
                    if (first)
                    {
                        first = false;
                        if (read >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF) start = 3;
                    }
                    for (int i = start; i < read; i++)
                    {
                        if (buffer[i] != (byte)'\n') continue;
                        string text;
                        if (pending.Length > 0)
                        {
                            pending.Write(buffer, start, i - start);
                            text = Decode(pending.GetBuffer(), 0, (int)pending.Length);
                            pending.SetLength(0);
                        }
                        else text = Decode(buffer, start, i - start);
                        yield return new KeyValuePair<string, long>(text, position + i + 1);
                        start = i + 1;
                    }
                    if (start < read) pending.Write(buffer, start, read - start);
                    position += read;
                }
            }
        }

        static string Decode(byte[] bytes, int start, int length)
        {
            if (length > 0 && bytes[start + length - 1] == (byte)'\r') length--;
            return length <= 0 ? string.Empty : Utf8.GetString(bytes, start, length);
        }
    }

    /// <summary>
    /// Column names of a log file, read from its "#Fields:" header. HttpProxy, SMTP and message
    /// tracking logs separate fields with commas, IIS (W3C) logs with spaces.
    /// </summary>
    public sealed class FieldMap
    {
        readonly Dictionary<string, int> _map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public char Separator = ',';
        public string Raw;
        public bool Loaded { get { return _map.Count > 0; } }

        public bool Load(string fieldsLine)
        {
            _map.Clear();
            Raw = null;
            if (string.IsNullOrEmpty(fieldsLine)) return false;
            Raw = fieldsLine;
            string value = fieldsLine.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase) ? fieldsLine.Substring(8).Trim() : fieldsLine.Trim();
            Separator = value.IndexOf(',') >= 0 ? ',' : ' ';
            var parts = value.Split(Separator);
            for (int i = 0; i < parts.Length; i++)
            {
                string key = parts[i].Trim();
                if (key.Length > 0 && !_map.ContainsKey(key)) _map[key] = i;
            }
            return _map.Count > 0;
        }

        /// <summary>Index of the first column found among the names, -1 when none exists.</summary>
        public int Index(params string[] names)
        {
            foreach (var name in names) { int i; if (_map.TryGetValue(name, out i)) return i; }
            return -1;
        }
    }

    /// <summary>
    /// Splits one line into fields without allocating a string per field: only the fields read
    /// with Get are materialised (HttpProxy lines have more than 70 columns, the engine uses ~25).
    /// Comma lines follow the CSV rules of Exchange (quotes, doubled quotes).
    /// </summary>
    public sealed class FieldSplitter
    {
        string _line = string.Empty;
        int[] _start = new int[128], _end = new int[128];
        bool[] _doubled = new bool[128];
        public int Count;

        void Ensure(int n)
        {
            if (n <= _start.Length) return;
            Array.Resize(ref _start, n * 2); Array.Resize(ref _end, n * 2); Array.Resize(ref _doubled, n * 2);
        }

        public void Split(string line, char separator)
        {
            _line = line ?? string.Empty;
            Count = 0;
            int n = _line.Length, i = 0;
            if (separator != ',')
            {
                while (true)
                {
                    Ensure(Count + 1);
                    int s = i;
                    while (i < n && _line[i] != separator) i++;
                    _start[Count] = s; _end[Count] = i; _doubled[Count] = false; Count++;
                    if (i >= n) return;
                    i++;
                }
            }
            while (true)
            {
                Ensure(Count + 1);
                if (i < n && _line[i] == '"')
                {
                    int s = i + 1, j = s; bool doubled = false;
                    while (j < n)
                    {
                        if (_line[j] == '"')
                        {
                            if (j + 1 < n && _line[j + 1] == '"') { doubled = true; j += 2; continue; }
                            break;
                        }
                        j++;
                    }
                    _start[Count] = s; _end[Count] = Math.Min(j, n); _doubled[Count] = doubled; Count++;
                    i = j + 1;
                    while (i < n && _line[i] != ',') i++;
                }
                else
                {
                    int s = i;
                    while (i < n && _line[i] != ',') i++;
                    _start[Count] = s; _end[Count] = i; _doubled[Count] = false; Count++;
                }
                if (i >= n) return;
                i++;
                if (i == n) { Ensure(Count + 1); _start[Count] = n; _end[Count] = n; _doubled[Count] = false; Count++; return; }
            }
        }

        /// <summary>Field value; null when the column is absent, empty or "-" (W3C empty value).</summary>
        public string Get(int index)
        {
            if (index < 0 || index >= Count) return null;
            int s = _start[index], e = _end[index];
            if (e <= s) return null;
            if (e - s == 1 && _line[s] == '-') return null;
            string v = _line.Substring(s, e - s);
            return _doubled[index] ? v.Replace("\"\"", "\"") : v;
        }

        /// <summary>Field value as written (keeps "-", the SMTP disconnect event); null when absent or empty.</summary>
        public string GetRaw(int index)
        {
            if (index < 0 || index >= Count) return null;
            int s = _start[index], e = _end[index];
            return e <= s ? null : _line.Substring(s, e - s);
        }

        public int GetInt(int index, int fallback)
        {
            string v = Get(index); int r;
            return v != null && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out r) ? r : fallback;
        }

        public long GetLong(int index, long fallback)
        {
            string v = Get(index); long r;
            return v != null && long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out r) ? r : fallback;
        }
    }

    /// <summary>Time conversions. Parsing is done by hand: it runs once per log line.</summary>
    public static class TimeUtil
    {
        static int Digits(string s, int start, int count)
        {
            int v = 0;
            for (int i = start; i < start + count; i++)
            {
                char c = s[i];
                if (c < '0' || c > '9') return -1;
                v = v * 10 + (c - '0');
            }
            return v;
        }

        /// <summary>"2026-10-01T08:03:55.018Z" or "2026-10-01 08:03:42" (UTC) to Unix ms.</summary>
        public static bool TryParseUtc(string s, out long ms)
        {
            ms = 0;
            if (s == null || s.Length < 19) return false;
            int y = Digits(s, 0, 4), mo = Digits(s, 5, 2), d = Digits(s, 8, 2), h = Digits(s, 11, 2), mi = Digits(s, 14, 2), se = Digits(s, 17, 2);
            if (y < 1900 || mo < 1 || mo > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 60) return false;
            int frac = 0, p = 19, digits = 0;
            if (p < s.Length && s[p] == '.')
            {
                p++;
                while (p < s.Length && s[p] >= '0' && s[p] <= '9') { if (digits < 3) { frac = frac * 10 + (s[p] - '0'); digits++; } p++; }
                while (digits < 3) { frac *= 10; digits++; }
            }
            try { ms = new DateTimeOffset(y, mo, d, h, mi, Math.Min(se, 59), frac, TimeSpan.Zero).ToUnixTimeMilliseconds(); return true; }
            catch (ArgumentOutOfRangeException) { return false; }
        }

        /// <summary>Wall-clock time of the zone to Unix ms (gaps of summer time are moved forward one hour).</summary>
        public static long LocalToUnixMs(DateTime local, TimeZoneInfo zone)
        {
            local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
            if (zone.IsInvalidTime(local)) local = local.AddHours(1);
            return new DateTimeOffset(local, zone.GetUtcOffset(local)).ToUnixTimeMilliseconds();
        }

        public static DateTime ToLocal(long utcMs, TimeZoneInfo zone)
        {
            return TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(utcMs), zone).DateTime;
        }

        /// <summary>Local wall-clock time as seconds since 1970 "as if UTC": the HTML report displays it with getUTC*.</summary>
        public static long ToLocalSeconds(long utcMs, TimeZoneInfo zone)
        {
            var offset = zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(utcMs));
            return (utcMs + (long)offset.TotalMilliseconds) / 1000;
        }

        public static string Format(long utcMs, TimeZoneInfo zone, string format)
        {
            return ToLocal(utcMs, zone).ToString(format, CultureInfo.InvariantCulture);
        }

        public static string Day(long utcMs, TimeZoneInfo zone) { return Format(utcMs, zone, "yyyy-MM-dd"); }

        public static string Duration(double seconds)
        {
            if (seconds < 0) seconds = 0;
            var t = TimeSpan.FromSeconds(seconds);
            if (t.TotalDays >= 1) return string.Format(CultureInfo.InvariantCulture, "{0} d {1:00} h", (int)t.TotalDays, t.Hours);
            if (t.TotalHours >= 1) return string.Format(CultureInfo.InvariantCulture, "{0} h {1:00} min", (int)t.TotalHours, t.Minutes);
            if (t.TotalMinutes >= 1) return string.Format(CultureInfo.InvariantCulture, "{0} min {1:00} s", t.Minutes, t.Seconds);
            return string.Format(CultureInfo.InvariantCulture, "{0:0.#} s", t.TotalSeconds);
        }
    }

    /// <summary>Local day of a time; cached per quarter of an hour (time zone offsets change on these boundaries).</summary>
    public sealed class DayCache
    {
        readonly TimeZoneInfo _zone;
        long _bucket = long.MinValue;
        string _day;
        public DayCache(TimeZoneInfo zone) { _zone = zone; }
        public string Day(long utcMs)
        {
            long b = utcMs / 900000;
            if (b != _bucket) { _bucket = b; _day = TimeUtil.Day(utcMs, _zone); }
            return _day;
        }
    }

    /// <summary>Identities and client types.</summary>
    public static class Identity
    {
        /// <summary>Authenticated user, lower case ("domain\sam", UPN or SID); null when anonymous.</summary>
        public static string User(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw) || raw == "-") return null;
            string s = raw.Trim().Trim('"');
            // "DOMAIN\" without account name: a client that sent an empty user name.
            if (s.Length == 0 || s[s.Length - 1] == '\\') return null;
            return s.ToLowerInvariant();
        }

        /// <summary>SMTP address of an HttpProxy anchor mailbox ("SMTP:user@contoso.com", "Smtp~..."), else null.</summary>
        public static string Mailbox(string anchor)
        {
            if (string.IsNullOrWhiteSpace(anchor)) return null;
            string s = anchor.Trim();
            if (s.Length > 5 && s.StartsWith("smtp", StringComparison.OrdinalIgnoreCase) && (s[4] == ':' || s[4] == '~')) s = s.Substring(5);
            else if (s.IndexOf('~') >= 0 || s.IndexOf(':') >= 0) return null;
            return s.IndexOf('@') > 0 ? s.ToLowerInvariant() : null;
        }

        /// <summary>Account name without domain: "contoso\healthmailboxb4" and "healthmailboxb4@contoso.com" give "healthmailboxb4".</summary>
        public static string Bare(string identity)
        {
            if (string.IsNullOrEmpty(identity)) return identity;
            string s = identity;
            int b = s.LastIndexOf('\\'); if (b >= 0) s = s.Substring(b + 1);
            int a = s.IndexOf('@'); if (a > 0) s = s.Substring(0, a);
            return s;
        }

        /// <summary>Address between angle brackets of an SMTP command ("MAIL FROM:&lt;a@b&gt; SIZE=1").</summary>
        public static string SmtpAddress(string value)
        {
            if (value == null) return null;
            int lt = value.IndexOf('<'), gt = lt >= 0 ? value.IndexOf('>', lt + 1) : -1;
            string s = lt >= 0 && gt > lt ? value.Substring(lt + 1, gt - lt - 1) : value.Trim().Split(' ')[0];
            return s.Trim().ToLowerInvariant();
        }

        public static string Protocol(string urlStem)
        {
            if (string.IsNullOrEmpty(urlStem)) return "Other";
            string s = urlStem.ToLowerInvariant();
            if (s.StartsWith("/owa")) return "Owa";
            if (s.StartsWith("/ecp")) return "Ecp";
            if (s.StartsWith("/ews")) return "Ews";
            if (s.StartsWith("/mapi")) return "Mapi";
            if (s.StartsWith("/rpc")) return "RpcHttp";
            if (s.StartsWith("/microsoft-server-activesync")) return "Eas";
            if (s.StartsWith("/autodiscover")) return "Autodiscover";
            if (s.StartsWith("/oab")) return "Oab";
            if (s.StartsWith("/powershell")) return "PowerShell";
            if (s.StartsWith("/api")) return "Rest";
            return "Other";
        }

        /// <summary>Client family of a user agent, for the usage views.</summary>
        public static string Client(string userAgent)
        {
            if (string.IsNullOrWhiteSpace(userAgent)) return "Unknown";
            string u = userAgent.ToLowerInvariant();
            if (u.Contains("macoutlook") || u.Contains("outlook-mac")) return "Outlook for Mac";
            if (u.Contains("outlook-ios") || u.Contains("outlook-android") || u.Contains("outlookmobile")) return "Outlook mobile";
            if (u.Contains("microsoft office") || u.Contains("microsoft outlook") || u.Contains("outlook/")) return "Outlook (Windows)";
            if (u.Contains("msrpc")) return "Outlook (RPC/HTTP)";
            if (u.Contains("winrm")) return "PowerShell (WinRM)";
            if (u.Contains("activesync") || u.StartsWith("apple-") || u.Contains("iphone") || u.Contains("ipad") || u.Contains("android")) return "Mobile (ActiveSync)";
            if (u.Contains("teams") || u.Contains("skype")) return "Teams / Skype";
            if (u.Contains("exchangeservicesclient") || u.Contains("ews")) return "EWS application";
            if (u.Contains("mozilla")) return "Browser";
            if (u == "imap4" || u == "pop3") return u.ToUpperInvariant() + " client";
            string first = userAgent.Split('/', ' ')[0];
            return first.Length > 30 ? first.Substring(0, 30) : first;
        }

        public static string Cap(string value, int max)
        {
            return value == null || value.Length <= max ? value : value.Substring(0, max) + "...";
        }

        /// <summary>Value of one parameter of a URL query ("?Cmd=Sync&amp;User=x"), null when absent or empty.</summary>
        public static string QueryValue(string query, string name)
        {
            if (string.IsNullOrEmpty(query)) return null;
            int i = 0;
            while (i < query.Length)
            {
                int start = i;
                if (query[start] == '?' || query[start] == '&') start++;
                int end = query.IndexOf('&', start);
                if (end < 0) end = query.Length;
                int eq = query.IndexOf('=', start);
                if (eq > start && eq < end && eq - start == name.Length && string.Compare(query, start, name, 0, name.Length, StringComparison.OrdinalIgnoreCase) == 0)
                {
                    string v = query.Substring(eq + 1, end - eq - 1);
                    int semi = v.IndexOf(';');
                    if (semi >= 0) v = v.Substring(0, semi);
                    try { v = Uri.UnescapeDataString(v.Replace('+', ' ')); } catch (UriFormatException) { }
                    return v.Length == 0 ? null : v;
                }
                i = end + 1;
            }
            return null;
        }

        /// <summary>Mailbox GUID of "MailboxGuid~&lt;guid&gt;" (HttpProxy anchor) or "&lt;guid&gt;@domain" (MAPI MailboxId), lower case.</summary>
        public static string MailboxGuid(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            string s = value.Trim();
            int tilde = s.IndexOf('~');
            if (tilde >= 0) s = s.Substring(tilde + 1);
            int at = s.IndexOf('@');
            if (at > 0) s = s.Substring(0, at);
            Guid g;
            return Guid.TryParse(s, out g) ? g.ToString("D") : null;
        }

        /// <summary>Part of a ";"-separated "KEY:value" list ("R:{..}:1;RT:Connect;CI:{..}:1"), null when absent.</summary>
        public static string Token(string list, string key)
        {
            if (string.IsNullOrEmpty(list)) return null;
            foreach (var part in list.Split(';'))
            {
                if (part.Length > key.Length && part[key.Length] == ':' && part.StartsWith(key, StringComparison.OrdinalIgnoreCase))
                {
                    string v = part.Substring(key.Length + 1).Trim();
                    return v.Length == 0 || v == "<null>" ? null : v;
                }
            }
            return null;
        }

        /// <summary>MAPI client instance ("{5B43EE0C-...}:1" or "5b43ee0c-...:1") as a lower-case GUID.</summary>
        public static string ClientInstance(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            string s = value.Trim().TrimStart('{');
            int end = s.IndexOfAny(new[] { '}', ':' });
            if (end > 0) s = s.Substring(0, end);
            Guid g;
            return Guid.TryParse(s, out g) ? g.ToString("D") : null;
        }

        /// <summary>Short upper-case server name: "exch01.contoso.com" gives "EXCH01".</summary>
        public static string ServerName(string fqdn)
        {
            if (string.IsNullOrWhiteSpace(fqdn)) return null;
            string s = fqdn.Trim();
            int dot = s.IndexOf('.');
            if (dot > 0) s = s.Substring(0, dot);
            return s.ToUpperInvariant();
        }

        /// <summary>Address without port: "192.168.1.11:28717" gives "192.168.1.11", "[::1]:25" gives "::1".</summary>
        public static string Host(string endpoint)
        {
            if (string.IsNullOrEmpty(endpoint)) return endpoint;
            string s = endpoint.Trim();
            if (s.StartsWith("[")) { int close = s.IndexOf(']'); return close > 0 ? s.Substring(1, close - 1) : s; }
            int colon = s.LastIndexOf(':');
            return colon > 0 && s.IndexOf(':') == colon ? s.Substring(0, colon) : s;
        }
    }
}
