// =============================================================================
//  Exchange Log Report - route of a message: order, distribution lists, hops, readable details, submissions
//  Author: Nicolas Fabert
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace ExchangeLogReport
{
    public static partial class ReportBuilder
    {
        /// <summary>
        /// The route of one message: its tracking events and its SMTP conversations as steps in the order the message travelled. A step is
        /// [0] time (as the caller's local), [1] server, [2] "Tracking" or "SMTP Receive|Send (role)", [3] label, [4] detail,
        /// [5] submission number (1..n), [6] UTC milliseconds.
        /// What the logs record in a different order than the mail moved is put back in order (a front end logs its conversation when it ends),
        /// the events that describe one fact are one step (a distribution list and its expansion, a hop and its delivery, a deferral storm),
        /// and the steps are numbered by the submission they belong to (a message can enter the organization several times).
        /// </summary>
        internal static class RouteBuilder
        {
            sealed class Step
            {
                public int Seq, Pos;
                public long Ms;
                public bool Tracking, Receive;                 // SMTP: Receive (front-end side of a conversation) or Send
                public object[] Row;
                public string Server, Event = "", Source, InternalId, Related, Connector, Status, Client, Peer, Role, Response;
                public string Sender, ClientIp, Helo, RemoteIp;  // tracking: sender and client address; SMTP: MAIL FROM, HELO and remote address
                public string[] Rcpts = new string[0];
                HashSet<string> set;
                public HashSet<string> RcptSet { get { return set ?? (set = new HashSet<string>(Rcpts, StringComparer.OrdinalIgnoreCase)); } }
                Dictionary<string, int> positions;
                /// <summary>Index of the first occurrence of a recipient (case-insensitive), -1 when absent; a lookup instead of a scan so a list of thousands of members stays linear.</summary>
                public int RcptIndex(string rcpt)
                {
                    if (positions == null)
                    {
                        positions = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                        for (int i = 0; i < Rcpts.Length; i++) if (!positions.ContainsKey(Rcpts[i])) positions[Rcpts[i]] = i;
                    }
                    int at;
                    return positions.TryGetValue(rcpt, out at) ? at : -1;
                }
                public double K1, K2, K3;                      // order: time, rank, sequence
                public Step Partner, Recv, Fed;                // Send: its Receive, the tracking RECEIVE it fed; RECEIVE: the Send that fed it
                public Step Entry;                             // Receive entering the organization: the tracking RECEIVE it queued on its server, and back
                public int Sub;                                // 0: not resolved yet, -1: being resolved
                public bool Dead, Folded, RootOwn;
                public HashSet<string> Left;                   // DELIVER: recipients not folded into a hop
                public List<string> Expanded;                  // DROP: lists expanded on another server
                public List<int> Kept;                         // DROP: indexes of the recipients that were really dropped
                public bool EmptyList;                         // EXPAND: the list has no member
                public Out Hop, Rest;                          // SEND: the step that stands for the group, the part nobody delivered
            }

            sealed class Out
            {
                public long Ms;
                public string Server, Kind, Label, Detail, Fold;
                public int Sub;
            }

            static readonly Dictionary<string, double> Ranks = new Dictionary<string, double>(StringComparer.Ordinal) {
                { "RECEIVE", 0 }, { "SUBMIT", 1 }, { "INITMESSAGECREATED", 1 }, { "RESUBMIT", 1.5 }, { "RESOLVE", 2 }, { "REDIRECT", 2 }, { "EXPAND", 2 },
                { "DUPLICATEEXPAND", 2 }, { "DUPLICATEREDIRECT", 2 }, { "AGENTINFO", 3 }, { "TRANSFER", 4 }, { "DROP", 5 }, { "FAIL", 5 }, { "DEFER", 5 },
                { "POISONMESSAGE", 5 }, { "DELIVERFAIL", 5.5 }, { "SEND", 6 }, { "SENDEXTERNAL", 6 }, { "DELIVER", 7 }, { "DUPLICATEDELIVER", 7 },
                { "PROCESSMEETINGMESSAGE", 7.5 }, { "DSN", 8 }, { "BADMAIL", 8 }, { "MODERATIONEXPIRE", 8 } };
            // An event the table does not know sits with the failures: after the routing, before the hand-over.
            const double UnknownRank = 5;
            const int ListCap = 3;

            static readonly Regex HostnameRx = new Regex(@"Hostname=([^\],\s]+)", RegexOptions.Compiled);
            // A DELIVER status of a recent Exchange: one "<item id>;<delivery time>;ClientSubmitTime:<time>" triple per recipient
            // delivered to the Inbox, a folder display name when a rule moved the item, DefaultFolderType:<name> for a default folder.
            static readonly Regex ItemIdRx = new Regex(@"^[0-9A-F]{8,}$", RegexOptions.Compiled);
            static readonly Regex IsoTimeRx = new Regex(@"^\d{4}-\d\d-\d\dT\d", RegexOptions.Compiled);
            // A status text of the transport rather than a folder: an SMTP enhanced status code or a resolver, queue or store driver code.
            static readonly Regex TransportStatusRx = new Regex(@"^\d{3}[ -]\d\.\d+\.\d+|RESOLVER\.|QUEUE\.|StoreDriver\.", RegexOptions.Compiled);
            static readonly Regex RetryRx = new Regex(@"retryinterval=([\d:.]+)", RegexOptions.Compiled | RegexOptions.IgnoreCase);

            // First match wins. The codes are those of the Exchange transport agents and resolver as they appear in recipient-status texts.
            static readonly KeyValuePair<Regex, string>[] Reasons = new[] {
                R(@"RESOLVER\.GRP\.Expanded", "distribution list expanded"),
                R(@"RESOLVER\.OOF\.IntToExt", "out-of-office reply not sent outside the organization"),
                R(@"RESOLVER\.OOF\.ExtToInt", "external out-of-office reply handled, not delivered"),
                R(@"RESOLVER\.MSGTYPE\.AF", "auto-forward to an external recipient blocked"),
                R(@"RESOLVER\.MSGTYPE\.AR", "auto-reply to an external recipient blocked"),
                R(@"RESOLVER\.GRP\.BlockedMessage", "message blocked by the group"),
                R(@"RESOLVER\.GRP\.NotRedirected", "group message not redirected"),
                R(@"RESOLVER\.MER\.Suppressed", "recipient suppressed"),
                R(@"RESOLVER\.ADR\.RecipientNotFound", "recipient not found (SMTP address lookup)"),
                R(@"RESOLVER\.ADR\.ExRecipNotFound", "recipient not found (legacy Exchange address)"),
                R(@"RESOLVER\.RST\.SenderNotAuthenticatedForGroup", "sender not authenticated for the group"),
                R(@"QUEUE\.TransportAgent", "deleted by a transport agent"),
                R(@"StoreDriver\.Rules", "deleted by a mailbox rule"),
                R(@"SharedMailboxSentItemsAgent", "sent item copied to the shared mailbox"),
                R(@"mailbox full|QuotaExceeded", "mailbox full (quota exceeded)", true),
                R(@"dynamic mailbox database throttling", "mailbox database throttling limit exceeded"),
                R(@"recipient thread limit exceeded", "recipient thread limit exceeded") };
            static KeyValuePair<Regex, string> R(string pattern, string label, bool ignoreCase = false)
            {
                return new KeyValuePair<Regex, string>(new Regex(pattern, (ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None) | RegexOptions.Compiled), label);
            }

            internal static string Short(string host)
            {
                if (string.IsNullOrEmpty(host)) return "";
                int dot = host.IndexOf('.');
                return (dot < 0 ? host : host.Substring(0, dot)).ToLowerInvariant();
            }

            static string JoinList(IList<string> list, long total = -1)
            {
                if (total < 0) total = list.Count;
                string text = string.Join("; ", list.Take(ListCap));
                return total > ListCap ? text + " (+" + (total - ListCap).ToString(CultureInfo.InvariantCulture) + ")" : text;
            }

            static string Plural(long n, string noun) { return n.ToString(CultureInfo.InvariantCulture) + " " + noun + (n == 1 ? "" : "s"); }

            /// <summary>The text of one recipient-status entry for a reader: a known code in words, the raw text otherwise.</summary>
            static string Readable(string entry)
            {
                if (string.IsNullOrWhiteSpace(entry)) return "";
                var led = Regex.Match(entry, @"\{LED=([^}]*)\}");
                string text = led.Success ? led.Groups[1].Value : entry;
                if (string.IsNullOrWhiteSpace(text)) return "";
                foreach (var reason in Reasons)
                    if (reason.Key.IsMatch(text))
                    {
                        var retry = RetryRx.Match(text);
                        return reason.Value + (retry.Success ? " (retry " + Regex.Replace(retry.Groups[1].Value, @"\.\d+$", "") + ")" : "");
                    }
                return text.Trim();
            }

            /// <summary>All the entries of a status text in words, once each. The 250-character cap of the stored text can cut the last entry of a list: it is ignored when others are whole.</summary>
            static string ReasonOf(string status)
            {
                var raw = JourneySummary.SplitEntries(status);
                var whole = raw.Where(e => !e.StartsWith("[{LED=", StringComparison.Ordinal) || e.EndsWith("}]", StringComparison.Ordinal)).ToList();
                if (whole.Count > 0) raw = whole;
                return string.Join("; ", raw.Select(Readable).Where(x => x.Length > 0).Distinct(StringComparer.Ordinal));
            }

            /// <summary>The entries of a DELIVER status, one per recipient: an item id with its delivery and client submit times is one
            /// Inbox entry (empty text); the empty entries a trailing ';' leaves beyond n recipients are dropped.</summary>
            static List<string> DeliveryEntries(string status, int n)
            {
                var raw = JourneySummary.SplitEntries(status);
                var list = new List<string>(raw.Count);
                for (int i = 0; i < raw.Count; i++)
                {
                    string e = raw[i].Trim();
                    if (ItemIdRx.IsMatch(e))
                    {
                        if (i + 1 < raw.Count && IsoTimeRx.IsMatch(raw[i + 1].Trim())) i++;
                        if (i + 1 < raw.Count && raw[i + 1].TrimStart().StartsWith("ClientSubmitTime:", StringComparison.Ordinal)) i++;
                        list.Add("");
                    }
                    // A time or a client submit time alone is never a folder name.
                    else if (IsoTimeRx.IsMatch(e)) list.Add("");
                    else list.Add(e.StartsWith("ClientSubmitTime:", StringComparison.Ordinal) ? "" : e);
                }
                while (list.Count > Math.Max(1, n) && list[list.Count - 1].Length == 0) list.RemoveAt(list.Count - 1);
                return list;
            }

            /// <summary>Folder of the k-th of n delivered recipients, read from its own entry: nothing recorded or an item id is the Inbox,
            /// DefaultFolderType:X a default folder, a transport status (SMTP code, resolver, queue or store driver text) is shown as it is,
            /// any other text is the folder an Inbox rule moved the item to.</summary>
            static string FolderAt(string status, int k, int n)
            {
                if (string.IsNullOrEmpty(status)) return "Inbox";
                var entries = DeliveryEntries(status, n);
                string e;
                if (entries.Count == n && k < n) e = entries[k];
                else if (entries.Count == 1) e = entries[0];
                // A lone recipient owns the whole text, whatever ';' a folder name holds.
                else if (n == 1) e = status.Replace("'", "").Trim().TrimEnd(';').Trim();
                else e = entries.FirstOrDefault();
                if (string.IsNullOrWhiteSpace(e) || ItemIdRx.IsMatch(e.Trim())) return "Inbox";
                e = e.Trim();
                if (TransportStatusRx.IsMatch(e)) return e;
                var m = Regex.Match(e, @"^DefaultFolderType:(\w+)");
                if (!m.Success) return "folder «" + e + "»";
                string name = m.Groups[1].Value;
                switch (name)
                {
                    case "Inbox": return "Inbox";
                    case "DeletedItems": name = "Deleted Items"; break;
                    case "JunkEmail": name = "Junk Email"; break;
                    case "SentItems": name = "Sent Items"; break;
                    default: name = Regex.Replace(name, "([a-z])([A-Z])", "$1 $2"); break;
                }
                return "folder «" + name + "»";
            }

            static bool Shares(HashSet<string> a, HashSet<string> b)
            {
                if (a.Count > b.Count) { var t = a; a = b; b = t; }
                foreach (var x in a) if (b.Contains(x)) return true;
                return false;
            }

            internal static List<object[]> Build(Journey j, List<object[]> sessions, HashSet<string> collected, Func<long, object> local, Func<long, string> clock)
            {
                var all = new List<Step>();
                foreach (var e in j.Events)
                {
                    var t = new Step {
                        Tracking = true, Row = e, Seq = all.Count, Ms = L(e[1]), Server = S(e[2]), Event = S(e[3]) ?? "", Source = S(e[4]), InternalId = S(e[5]),
                        Status = S(e[8]), Client = S(e[13]) ?? S(e[12]), Peer = S(e[14]), Connector = S(e[15]), Related = S(e[18]),
                        Sender = S(e[6]), ClientIp = S(e[12]),
                        Rcpts = (S(e[7]) ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries) };
                    all.Add(t);
                }
                if (sessions != null)
                    foreach (var s in sessions)
                        all.Add(new Step {
                            Row = s, Seq = all.Count, Ms = L(s[1]), Server = S(s[3]), Receive = S(s[4]) == "Receive", Role = S(s[5]), Status = S(s[14]),
                            Response = S(s[15]), InternalId = s.Length > 23 ? S(s[23]) : null, Sender = S(s[12]), Helo = S(s[9]), RemoteIp = AddressOf(S(s[7])),
                            Rcpts = (s.Length > 24 ? S(s[24]) ?? "" : "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries) });
                var T = all.Where(x => x.Tracking).ToList();

                // ---- C1 order: (time, rank, sequence); the conversations of a front end are placed around the RECEIVE they caused.
                foreach (var x in all)
                {
                    double rank;
                    x.K1 = x.Ms; x.K3 = x.Seq;
                    x.K2 = !x.Tracking ? -1 : Ranks.TryGetValue(x.Event, out rank) ? rank : UnknownRank;
                }
                var receives = T.Where(x => x.Event == "RECEIVE").ToList();
                var fronts = all.Where(x => !x.Tracking && x.Receive).ToList();
                foreach (var s in all.Where(x => !x.Tracking && !x.Receive))
                {
                    var host = s.Response == null ? null : HostnameRx.Match(s.Response);
                    string hostShort = host != null && host.Success ? Short(host.Groups[1].Value) : null;
                    Step best = null;
                    if (s.InternalId != null)
                        best = receives.FirstOrDefault(r => r.Fed == null && r.InternalId == s.InternalId && (hostShort == null || Short(r.Server) == hostShort));
                    if (best == null)
                    {
                        double distance = 120000;
                        foreach (var r in receives)
                        {
                            if (r.Fed != null || (hostShort != null && Short(r.Server) != hostShort) || Short(r.Client) != Short(s.Server)) continue;
                            double d = Math.Abs(r.Ms - s.Ms);
                            if (d <= distance) { distance = d; best = r; }
                        }
                    }
                    if (best != null) { s.Recv = best; best.Fed = s; }
                    if (s.InternalId != null)
                    {
                        s.Partner = fronts.FirstOrDefault(f => f.Fed == null && f.Partner == null && f.InternalId == s.InternalId && Short(f.Server) == Short(s.Server));
                        if (s.Partner != null) s.Partner.Partner = s;
                    }
                }
                foreach (var s in all.Where(x => !x.Tracking && !x.Receive))
                {
                    if (s.Recv != null)
                    {
                        s.K1 = s.Recv.K1; s.K2 = s.Recv.K2; s.K3 = s.Recv.K3 + 0.5;
                        if (s.Partner != null) { s.Partner.K1 = s.Recv.K1; s.Partner.K2 = s.Recv.K2; s.Partner.K3 = s.Recv.K3 - 0.5; }
                    }
                    else if (s.Partner != null) { s.K3 = s.Partner.Seq + 0.5; }
                }
                // A conversation that entered the organization is placed just before the tracking RECEIVE it queued.
                PairEntries(all, receives, collected);
                foreach (var c in fronts)
                    if (c.Entry != null && c.Partner == null) { c.K1 = c.Entry.K1; c.K2 = c.Entry.K2; c.K3 = c.Entry.K3 - 0.5; }
                var O = all.OrderBy(x => x.K1).ThenBy(x => x.K2).ThenBy(x => x.K3).ThenBy(x => x.Seq).ToList();
                for (int i = 0; i < O.Count; i++) O[i].Pos = i;

                Submissions(O, T, receives, collected);

                // ---- C2 distribution lists
                var givers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var confirmed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var x in T)
                {
                    if (x.Related != null && x.Rcpts.Length > 0 && (x.Event == "EXPAND" || x.Event == "REDIRECT" || x.Event == "RESOLVE")) givers.Add(x.Related);
                    if (x.Event != "DROP") continue;
                    var entries = JourneySummary.SplitEntries(x.Status);
                    for (int k = 0; k < x.Rcpts.Length; k++)
                        if (JourneySummary.IsExpansion(JourneySummary.EntryOf(x.Status, entries, k, x.Rcpts.Length))) confirmed.Add(x.Rcpts[k]);
                }
                var expands = T.Where(x => x.Event == "EXPAND" && x.Related != null).ToList();
                foreach (var x in expands) x.EmptyList = x.Rcpts.Length == 0 && !givers.Contains(x.Related) && confirmed.Contains(x.Related);
                var expandsOf = new Dictionary<string, List<Step>>(StringComparer.OrdinalIgnoreCase);
                foreach (var x in expands)
                {
                    List<Step> same;
                    if (!expandsOf.TryGetValue(x.Related, out same)) expandsOf[x.Related] = same = new List<Step>();
                    same.Add(x);
                }
                foreach (var d in T.Where(x => x.Event == "DROP" && x.Rcpts.Length > 0))
                {
                    var entries = JourneySummary.SplitEntries(d.Status);
                    var kept = new List<int>();
                    bool any = false;
                    for (int k = 0; k < d.Rcpts.Length; k++)
                    {
                        if (!JourneySummary.IsExpansion(JourneySummary.EntryOf(d.Status, entries, k, d.Rcpts.Length))) { kept.Add(k); continue; }
                        any = true;
                        List<Step> named;
                        bool shown = expandsOf.TryGetValue(d.Rcpts[k], out named) && named.Any(e => e.Server == d.Server && Math.Abs(e.Ms - d.Ms) <= 5000);
                        if (!shown) (d.Expanded ?? (d.Expanded = new List<string>())).Add(d.Rcpts[k]);
                    }
                    if (any) d.Kept = kept;
                }

                // ---- C3 hops
                // DELIVERs by server, then by recipient, in route order: a hop finds the delivery of each of its recipients without scanning them all.
                var delivers = new Dictionary<string, Dictionary<string, List<Step>>>(StringComparer.Ordinal);
                foreach (var x in T.Where(y => y.Event == "DELIVER"))
                {
                    x.Left = new HashSet<string>(x.Rcpts, StringComparer.OrdinalIgnoreCase);
                    Dictionary<string, List<Step>> byRcpt;
                    if (!delivers.TryGetValue(Short(x.Server), out byRcpt)) delivers[Short(x.Server)] = byRcpt = new Dictionary<string, List<Step>>(StringComparer.OrdinalIgnoreCase);
                    foreach (var member in x.Left)
                    {
                        List<Step> list;
                        if (!byRcpt.TryGetValue(member, out list)) byRcpt[member] = list = new List<Step>();
                        list.Add(x);
                    }
                }
                var receivedBy = new Dictionary<string, List<Step>>(StringComparer.Ordinal);
                foreach (var rx in receives)
                {
                    string pair = Short(rx.Server) + "|" + Short(rx.Client);
                    List<Step> list;
                    if (!receivedBy.TryGetValue(pair, out list)) receivedBy[pair] = list = new List<Step>();
                    list.Add(rx);
                }
                var groups = new Dictionary<string, List<Step>>(StringComparer.Ordinal);
                foreach (var x in O)
                {
                    if (!x.Tracking || (x.Event != "SEND" && x.Event != "SENDEXTERNAL")) continue;
                    string key = string.Join("|", x.Server, Short(x.Peer), x.Connector, x.Ms / 1000, x.Event);
                    List<Step> g;
                    if (!groups.TryGetValue(key, out g)) groups[key] = g = new List<Step>();
                    g.Add(x);
                }
                foreach (var g in groups.Values) Hop(g, delivers, receivedBy, collected, clock);

                // ---- C4 details, in order
                var outs = new List<Out>();
                foreach (var o in O)
                {
                    if (!o.Tracking) { outs.Add(SmtpStep(o)); continue; }
                    if (o.Hop != null) { outs.Add(o.Hop); if (o.Rest != null) outs.Add(o.Rest); continue; }
                    if (o.Dead) continue;
                    TrackingStep(o, outs);
                }

                // ---- consecutive identical deferrals and drops (a storm) are one step; an identical one after another step starts a new group
                var folded = new List<Out>();
                for (int i = 0; i < outs.Count; )
                {
                    var first = outs[i];
                    int end = i + 1;
                    if (first.Fold != null)
                        while (end < outs.Count && outs[end].Fold == first.Fold && outs[end].Sub == first.Sub) end++;
                    if (end - i > 1)
                        first.Label += " ×" + (end - i).ToString(CultureInfo.InvariantCulture) + " (" + clock(first.Ms) + "–" + clock(outs[end - 1].Ms) + ")";
                    folded.Add(first);
                    i = end;
                }

                var result = new List<object[]>(folded.Count);
                foreach (var f in folded)
                    result.Add(new object[] { local(f.Ms), f.Server, f.Kind, f.Label, f.Detail, (long)f.Sub, f.Ms });
                return result;
            }

            /// <summary>Address part of an endpoint ("203.0.113.5:25", "[2001:db8::1]:25").</summary>
            static string AddressOf(string endpoint)
            {
                if (string.IsNullOrEmpty(endpoint)) return null;
                if (endpoint.StartsWith("[", StringComparison.Ordinal)) { int end = endpoint.IndexOf(']'); return end > 1 ? endpoint.Substring(1, end - 1) : endpoint; }
                int colon = endpoint.LastIndexOf(':');
                return colon > 0 && endpoint.IndexOf(':') == colon ? endpoint.Substring(0, colon) : endpoint;
            }

            /// <summary>A Receive conversation that starts a submission: from a front end, an Edge or a host that is not a collected server.</summary>
            static bool EntersHere(Step c, HashSet<string> collected)
            {
                string from = Short(c.Helo);
                return c.Role == "FrontEnd" || c.Role == "Edge" || from.Length == 0 || !collected.Contains(from);
            }

            // ------------------------------------------------------------------ C1 entry conversations
            // The conversation that queued the message on a server and the tracking RECEIVE of that server are one entry into the organization:
            // the internal id of the reply when both carry the same, else the RECEIVE of the same server within a minute that agrees with the
            // conversation on the most of a recipient, the sender and the client (HELO name or address), the closest in time among equals. At
            // least one must agree; each RECEIVE answers one conversation, and the pair is known to both sides.
            static void PairEntries(List<Step> all, List<Step> receives, HashSet<string> collected)
            {
                var conversations = all.Where(x => !x.Tracking && x.Receive && x.Partner == null && EntersHere(x, collected)).OrderBy(x => x.Ms).ThenBy(x => x.Seq).ToList();
                if (conversations.Count == 0) return;
                var open = receives.Where(r => r.Source == "SMTP" && r.Fed == null).ToList();
                foreach (var c in conversations)
                {
                    if (c.InternalId == null) continue;
                    var r = open.FirstOrDefault(x => x.Entry == null && x.InternalId == c.InternalId && Short(x.Server) == Short(c.Server));
                    if (r != null) { c.Entry = r; r.Entry = c; }
                }
                // Without an internal id only a conversation that queued the message (status Accepted) can be the entry: a deferred
                // or rejected attempt of the same client shortly before shares its sender, recipients and HELO but queued nothing.
                foreach (var c in conversations)
                {
                    if (c.Entry != null || c.Status != "Accepted") continue;
                    Step best = null; double score = double.MaxValue;
                    foreach (var r in open)
                    {
                        if (r.Entry != null || Short(r.Server) != Short(c.Server)) continue;
                        double d = Math.Abs(r.Ms - c.Ms) / 1000.0;
                        if (d > 60) continue;
                        double agree = 0;
                        if (c.Rcpts.Length > 0 && r.Rcpts.Length > 0 && Shares(c.RcptSet, r.RcptSet)) agree += 1000;
                        if (!string.IsNullOrEmpty(c.Sender) && string.Equals(c.Sender, r.Sender, StringComparison.OrdinalIgnoreCase)) agree += 1000;
                        if ((!string.IsNullOrEmpty(c.Helo) && Short(c.Helo) == Short(r.Client))
                            || (!string.IsNullOrEmpty(c.RemoteIp) && string.Equals(c.RemoteIp, r.ClientIp, StringComparison.OrdinalIgnoreCase))) agree += 1000;
                        if (agree == 0) continue;
                        d -= agree;
                        if (d < score) { score = d; best = r; }
                    }
                    if (best != null) { c.Entry = best; best.Entry = c; }
                }
            }

            // ------------------------------------------------------------------ C5 submissions

            static void Submissions(List<Step> O, List<Step> T, List<Step> receives, HashSet<string> collected)
            {
                var receivesBy = new Dictionary<string, List<Step>>(StringComparer.Ordinal);
                var sendsTo = new Dictionary<string, List<Step>>(StringComparer.Ordinal);
                var sendsFrom = new Dictionary<string, List<Step>>(StringComparer.Ordinal);
                var startsBy = new Dictionary<string, List<Step>>(StringComparer.Ordinal);     // where a mailbox server's own mail begins: SUBMIT, or a RECEIVE that is not SMTP
                var legOf = new Dictionary<string, Step>(StringComparer.Ordinal);               // the RECEIVE of a leg: server and internal id
                var conversationOf = new Dictionary<string, Step>(StringComparer.Ordinal);      // the conversation received on a server for an internal id
                Action<Dictionary<string, List<Step>>, string, Step> add = (map, key, step) =>
                {
                    List<Step> list;
                    if (!map.TryGetValue(key, out list)) map[key] = list = new List<Step>();
                    list.Add(step);
                };
                foreach (var x in O)
                {
                    if (!x.Tracking) continue;
                    if (x.Event == "RECEIVE") add(receivesBy, Short(x.Server), x);
                    if (x.Event == "SEND" || x.Event == "SENDEXTERNAL") { add(sendsTo, Short(x.Peer), x); add(sendsFrom, Short(x.Server), x); }
                }
                foreach (var x in T)
                    if (x.Event == "SUBMIT" || (x.Event == "RECEIVE" && x.Source != "SMTP")) add(startsBy, Short(x.Server), x);
                foreach (var x in O)
                    if (!x.Tracking && x.Receive && x.InternalId != null && !conversationOf.ContainsKey(Short(x.Server) + "\u0000" + x.InternalId)) conversationOf[Short(x.Server) + "\u0000" + x.InternalId] = x;
                foreach (var x in receives)
                    if (x.InternalId != null && !legOf.ContainsKey(x.Server + "\u0000" + x.InternalId)) legOf[x.Server + "\u0000" + x.InternalId] = x;
                int roots = 0;
                const int None = -2, Busy = -1;
                // The tracking SEND that carried a RECEIVE: from the host that connected, to this server, within a minute, preferably for the same recipients.
                Func<Step, string, Step> sendFor = (r, fromHost) =>
                {
                    List<Step> candidates;
                    if (!sendsTo.TryGetValue(Short(r.Server), out candidates)) return null;
                    Step best = null; double score = double.MaxValue;
                    foreach (var s in candidates)
                    {
                        if (Short(s.Server) != fromHost) continue;
                        double d = Math.Abs(s.Ms - r.Ms) / 1000.0;
                        if (d > 60) continue;
                        d -= Shares(s.RcptSet, r.RcptSet) ? 1000 : 0;
                        if (d < score) { score = d; best = s; }
                    }
                    return best;
                };
                Func<Step, string, Step> mailboxStart = (r, host) =>
                {
                    Step best = null; double score = double.MaxValue;
                    List<Step> starts;
                    if (!startsBy.TryGetValue(host, out starts)) return null;
                    foreach (var x in starts)
                    {
                        if (x == r) continue;
                        double d = Math.Abs(x.Ms - r.Ms) / 1000.0;
                        if (d > 120) continue;
                        d += (Shares(x.RcptSet, r.RcptSet) ? -1000 : 0) + (x.Event == "SUBMIT" ? 100000 : 0);   // the SUBMIT only when no RECEIVE is there
                        if (d < score) { score = d; best = x; }
                    }
                    return best;
                };
                Func<Step, int> subOf = null;
                subOf = o =>
                {
                    if (o.Sub != 0) return o.Sub == Busy ? None : o.Sub;
                    o.Sub = Busy;
                    int r = None;
                    if (!o.Tracking && o.Receive)
                    {
                        // A conversation received from another collected server of the organization is a leg of a submission that began elsewhere;
                        // only mail entering from a front end, an Edge or an unknown host starts one.
                        string from = Short(S(o.Row[9]));
                        if (o.Role == "FrontEnd" || o.Role == "Edge" || from.Length == 0 || !collected.Contains(from)) r = ++roots;
                        else { var sent = sendFor(o, from); r = sent != null ? subOf(sent) : None; }
                    }
                    else if (!o.Tracking)
                    {
                        if (o.Partner != null) r = subOf(o.Partner);
                        else if (o.Recv != null) r = subOf(o.Recv);
                        else
                        {
                            // A conversation with no tracking RECEIVE behind it belongs to the SEND that made it: same server, next host named in the answer, within a minute.
                            var host = o.Response == null ? null : HostnameRx.Match(o.Response);
                            string peer = host != null && host.Success ? Short(host.Groups[1].Value) : null;
                            List<Step> mine; Step best = null; double score = double.MaxValue;
                            if (sendsFrom.TryGetValue(Short(o.Server), out mine))
                                foreach (var s in mine)
                                {
                                    double d = Math.Abs(s.Ms - o.Ms) / 1000.0;
                                    if (d > 60) continue;
                                    d -= peer != null && Short(s.Peer) == peer ? 100000 : 0;
                                    if (d < score) { score = d; best = s; }
                                }
                            r = best != null ? subOf(best) : None;
                        }
                    }
                    else if (o.Event == "RECEIVE")
                    {
                        // The conversation that queued this message on the same server (an Edge, or a server that logs both) is the same entry into the organization.
                        Step conversation = null; int own = None;
                        if (o.Entry != null) own = subOf(o.Entry);
                        else if (o.Fed == null && o.Source == "SMTP" && o.InternalId != null && conversationOf.TryGetValue(Short(o.Server) + "\u0000" + o.InternalId, out conversation)) own = subOf(conversation);
                        if (o.Fed != null) { int x = o.Fed.Partner != null ? subOf(o.Fed.Partner) : None; r = x > 0 ? x : ++roots; }
                        else if (own > 0) r = own;
                        else if (o.Source != "SMTP") r = ++roots;
                        else if (!string.IsNullOrEmpty(o.Client) && collected.Contains(Short(o.Client)))
                        {
                            var sent = sendFor(o, Short(o.Client));
                            int x = sent != null ? subOf(sent) : None;
                            if (!(x > 0)) { var m = mailboxStart(o, Short(o.Client)); x = m != null ? subOf(m) : None; }
                            r = x > 0 ? x : ++roots;
                        }
                        else r = ++roots;
                    }
                    else
                    {
                        // A step follows the RECEIVE of its leg (same server and internal id); else the latest earlier RECEIVE of the server sharing a recipient,
                        // else the latest earlier, else the first later; else the SEND that targets the server.
                        Step leg = null;
                        if (o.InternalId != null) legOf.TryGetValue(o.Server + "\u0000" + o.InternalId, out leg);
                        List<Step> candidates;
                        if (leg == null && receivesBy.TryGetValue(Short(o.Server), out candidates))
                        {
                            Step before = null, share = null;
                            foreach (var x in candidates)
                            {
                                if (x.Pos < o.Pos) { before = x; if (Shares(o.RcptSet, x.RcptSet)) share = x; }
                                else { if (before == null) before = x; break; }
                            }
                            leg = share ?? before;
                        }
                        if (leg != null) r = subOf(leg);
                        else
                        {
                            List<Step> sends; Step best = null; double score = double.MaxValue;
                            if (sendsTo.TryGetValue(Short(o.Server), out sends))
                                foreach (var s in sends)
                                {
                                    if (s == o) continue;
                                    double d = Math.Abs(s.Ms - o.Ms) / 1000.0;
                                    if (d > 60) continue;
                                    d -= Shares(s.RcptSet, o.RcptSet) ? 1000 : 0;
                                    if (d < score) { score = d; best = s; }
                                }
                            if (best != null) r = subOf(best);
                        }
                    }
                    o.Sub = r == None ? 0 : r;   // a cycle must not be remembered as the answer
                    return r;
                };
                foreach (var o in O) subOf(o);
                int last = 0;
                foreach (var o in O) { if (o.Sub > 0) last = o.Sub; else o.Sub = last; }
                var first = O.FirstOrDefault(x => x.Sub > 0);
                int fill = first != null ? first.Sub : ++roots;
                foreach (var o in O) if (o.Sub <= 0) o.Sub = fill;
                var number = new Dictionary<int, int>();
                foreach (var o in O) if (!number.ContainsKey(o.Sub)) number[o.Sub] = number.Count + 1;
                foreach (var o in O) o.Sub = number[o.Sub];
            }

            // ------------------------------------------------------------------ C3 one group of SEND events (same server, next host, connector, second)

            static void Hop(List<Step> g, Dictionary<string, Dictionary<string, List<Step>>> delivers, Dictionary<string, List<Step>> receivedBy, HashSet<string> collected, Func<long, string> clock)
            {
                var f = g[0];
                var rcpts = new List<string>();
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var tails = new List<string>();
                foreach (var m in g)
                {
                    foreach (var r in m.Rcpts) if (seen.Add(r)) rcpts.Add(r);
                    foreach (var t in (m.Status ?? "").Split(';')) { string x = t.Trim(); if (x.Length > 0 && !tails.Contains(x)) tails.Add(x); }
                }
                string next = Short(f.Peer), status = string.Join("; ", tails);
                bool inside = next.Length > 0 && collected.Contains(next);
                string source = f.Source ?? "";
                string toText = string.IsNullOrEmpty(f.Peer) ? null : f.Peer + (inside ? "" : " (not collected)");
                var matched = new List<KeyValuePair<string, Step>>();
                Step delivered = null, received = null;
                if (inside)
                {
                    Dictionary<string, List<Step>> byRcpt;
                    if (delivers.TryGetValue(next, out byRcpt))
                        foreach (var r in rcpts)
                        {
                            List<Step> candidates;
                            if (!byRcpt.TryGetValue(r, out candidates)) continue;
                            var d = candidates.FirstOrDefault(x => x.Left.Contains(r) && Math.Abs(x.Ms - f.Ms) <= 30000);
                            if (d == null) continue;
                            d.Left.Remove(r);
                            matched.Add(new KeyValuePair<string, Step>(r, d));
                            if (delivered == null || d.Ms < delivered.Ms) delivered = d;
                        }
                    if (matched.Count == 0)
                    {
                        List<Step> pool;
                        var candidatesIn = (receivedBy.TryGetValue(next + "|" + Short(f.Server), out pool) ? pool : new List<Step>())
                            .Where(r => !r.Folded && Math.Abs(r.Ms - f.Ms) <= 30000).ToList();
                        received = candidatesIn.FirstOrDefault(r => Shares(r.RcptSet, seen)) ?? candidatesIn.FirstOrDefault();
                        if (received != null) { received.Folded = true; received.Dead = true; }
                    }
                }
                var hop = new Out { Server = f.Server, Kind = "Tracking", Ms = f.Ms, Sub = f.Sub };
                string tail = status.Length > 0 ? " | " + status : "";
                if (delivered != null)
                {
                    var matchedKeys = new HashSet<string>(matched.Select(m => m.Key), StringComparer.OrdinalIgnoreCase);
                    var unmatched = rcpts.Where(r => !matchedKeys.Contains(r)).ToList();
                    var items = matched.Select(m => m.Key + " (" + FolderAt(m.Value.Status, Math.Max(0, m.Value.RcptIndex(m.Key)), m.Value.Rcpts.Length) + ")").ToList();
                    hop.Label = f.Event + " > DELIVER";
                    hop.Ms = Math.Min(f.Ms, delivered.Ms);
                    hop.Detail = "to " + f.Peer + " | " + Plural(matched.Count, "recipient") + ": " + JoinList(items) + " | delivered " + clock(delivered.Ms) + tail;
                    if (unmatched.Count > 0)
                        f.Rest = new Out { Server = f.Server, Kind = "Tracking", Ms = f.Ms, Sub = f.Sub, Label = f.Event,
                            Detail = source + " | to " + toText + (f.Connector != null ? " | connector " + f.Connector : "") + " | " + JoinList(unmatched) + tail };
                }
                else if (received != null)
                {
                    hop.Label = f.Event + " > RECEIVE";
                    hop.Ms = Math.Min(f.Ms, received.Ms);
                    hop.Detail = "to " + f.Peer + " | " + Plural(rcpts.Count, "recipient") + ": " + JoinList(rcpts) + " | received " + clock(received.Ms) + tail;
                }
                else
                {
                    hop.Label = f.Event;
                    hop.Detail = source + (toText != null ? " | to " + toText : "") + (f.Connector != null ? " | connector " + f.Connector : "") + " | " + JoinList(rcpts) + tail;
                }
                f.Hop = hop;
                for (int i = 1; i < g.Count; i++) g[i].Dead = true;
            }

            // ------------------------------------------------------------------ C4 steps

            static Out SmtpStep(Step o)
            {
                var s = o.Row;
                var parts = new List<string>();
                if (S(s[7]) != null) parts.Add("remote " + S(s[7]));
                if (S(s[6]) != null) parts.Add(S(s[6]));
                if (S(s[9]) != null) parts.Add("HELO " + S(s[9]));
                if (S(s[10]) != null) parts.Add(S(s[10]));
                if (S(s[11]) != null) parts.Add("auth " + S(s[11]));
                if (o.Receive) AddAuthentication(parts, SmtpAuthView.Fields(s, 18), S(s[12]));
                if (o.Response != null) parts.Add(o.Response);
                return new Out { Ms = o.Ms, Server = o.Server, Kind = "SMTP " + S(s[4]) + (o.Role != null ? " (" + o.Role + ")" : ""), Label = o.Status, Detail = string.Join(" | ", parts), Sub = o.Sub };
            }

            static void TrackingStep(Step o, List<Out> outs)
            {
                var e = o.Row;
                Func<string, string, string, Out> step = (label, detail, fold) => new Out { Ms = o.Ms, Server = o.Server, Kind = "Tracking", Label = label, Detail = detail, Sub = o.Sub, Fold = fold };
                string source = o.Source ?? "";
                string evt = o.Event;
                switch (evt)
                {
                    case "EXPAND":
                        if (o.Related != null && (string.IsNullOrEmpty(o.Status) || JourneySummary.IsExpansion(o.Status)))
                        {
                            if (o.Rcpts.Length > 0)
                                outs.Add(step("EXPAND", source + " | distribution list " + o.Related + " expanded to " + Plural(o.Rcpts.Length, "recipient") + ": " + JoinList(o.Rcpts), null));
                            else if (o.EmptyList)
                                outs.Add(step("DROP", source + " | " + o.Related + " | distribution list is empty: nobody receives the message", "DROP|" + o.Server + "|" + source + " | " + o.Related));
                            else
                                outs.Add(step("EXPAND", source + " | distribution list " + o.Related + " expanded (members not listed in this step)", null));
                            return;
                        }
                        break;
                    case "DELIVER": case "DUPLICATEDELIVER":
                    {
                        var left = o.Left == null ? o.Rcpts.ToList() : o.Rcpts.Where(r => o.Left.Contains(r)).ToList();
                        if (left.Count == 0 && o.Rcpts.Length > 0) return;   // everything is in a SEND > DELIVER step
                        string label = evt == "DELIVER" ? "DELIVER" : "DELIVER (duplicate suppressed)";
                        var firstAt = new Dictionary<string, int>(StringComparer.Ordinal);
                        for (int i = 0; i < o.Rcpts.Length; i++) if (!firstAt.ContainsKey(o.Rcpts[i])) firstAt[o.Rcpts[i]] = i;
                        var folders = left.Select(r => FolderAt(o.Status, firstAt[r], o.Rcpts.Length)).ToList();
                        string detail = folders.Count == 0 || folders.All(x => x == folders[0])
                            ? source + " | " + JoinList(left) + " | " + (folders.Count > 0 ? folders[0] : FolderAt(o.Status, 0, 1))
                            : source + " | " + JoinList(left.Select((r, i) => r + " (" + folders[i] + ")").ToList());
                        outs.Add(step(label, detail, null));
                        return;
                    }
                    case "DEFER":
                        outs.Add(step("DEFER", source + (o.Connector != null ? " | connector " + o.Connector : "") + " | " + JoinList(o.Rcpts) + " | " + OrNone(ReasonOf(o.Status)), null));
                        outs[outs.Count - 1].Fold = "DEFER|" + o.Server + "|" + outs[outs.Count - 1].Detail;
                        return;
                    case "FAIL":
                        outs.Add(step("FAIL", source + " | " + JoinList(o.Rcpts) + " | " + OrNone(ReasonOf(o.Status)), null));
                        return;
                    case "DROP":
                    {
                        if (o.Kept == null)
                        {
                            string detail = source + " | " + JoinList(o.Rcpts) + " | " + OrNone(ReasonOf(o.Status));
                            outs.Add(step("DROP", detail, "DROP|" + o.Server + "|" + detail));
                            return;
                        }
                        // Part of the recipients are lists that were expanded: the EXPAND step shows that; only the others were dropped.
                        if (o.Expanded != null)
                            outs.Add(step("EXPAND (expanded on another server)", source + " | distribution list " + string.Join("; ", o.Expanded) + " expanded on another server", null));
                        if (o.Kept.Count > 0)
                        {
                            var entries = JourneySummary.SplitEntries(o.Status);
                            var reasons = o.Kept.Select(k => Readable(JourneySummary.EntryOf(o.Status, entries, k, o.Rcpts.Length))).Where(x => x.Length > 0).Distinct(StringComparer.Ordinal).ToList();
                            string detail = source + " | " + string.Join("; ", o.Kept.Select(k => o.Rcpts[k])) + " | " + (reasons.Count > 0 ? string.Join("; ", reasons) : "no reason given");
                            outs.Add(step("DROP", detail, "DROP|" + o.Server + "|" + detail));
                        }
                        return;
                    }
                    case "TRANSFER":
                        if (!string.IsNullOrEmpty(o.Status) && o.Status.All(c => c == ';'))
                        {
                            outs.Add(step("TRANSFER", source + " | " + JoinList(o.Rcpts) + " | " + Plural(o.Status.Length + 1, "recipient") + " (bifurcation)", null));
                            return;
                        }
                        break;
                    case "SUBMIT":
                        if (o.Status != null && o.Status.StartsWith("MDB:", StringComparison.Ordinal))
                        {
                            outs.Add(step("SUBMIT", source + " | " + JoinList(o.Rcpts) + " | from mailbox", null));
                            return;
                        }
                        break;
                }
                outs.Add(step(evt, StepDetail(e, o.Rcpts), null));
            }

            static string OrNone(string reason) { return reason.Length > 0 ? reason : "no reason given"; }
        }
    }
}
