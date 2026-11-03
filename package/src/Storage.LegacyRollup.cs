#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Globalization;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport.Storage;

/// <summary>
/// The tracking rollup row of a schema 8 to 11 database, computed with the recipient rules those databases were written with
/// (Relayed, Delivered and relayed, "(Sent)", members of an expanded list marked Expanded, every DROP an event). The SMTP-only
/// rows are read through the engine, with the status those schemas give a sent transaction ('Not completed (SMTP)').
/// </summary>
internal static class StorageLegacyRollup
{
    /// <summary>
    /// Same 18-slot row as ReportBuilder.ReadServeRollupBounds, with the schema 8 to 11 recipient rules; null when the identity has no row.
    /// smtpFirstMs/smtpLastMs: MIN/MAX(time_ms) of the SMTP rows counted in the row (null when none), from the statement that counts them.
    /// </summary>
    /// <param name="reuse">The commands come from a caller-owned cache (prepared once, bound again per identity) and are not disposed here.</param>
    internal static object?[]? Read(Func<string, SqliteCommand> command, string kind, string identity, bool reuse, out long eventCount, out long? smtpFirstMs, out long? smtpLastMs)
    {
        if (kind != "message") return ReportBuilder.ReadServeRollupBounds(command, kind, identity, reuse, out eventCount, out smtpFirstMs, out smtpLastMs, sentStatus: false);
        eventCount = 0; smtpFirstMs = null; smtpLastMs = null;
        ReportBuilder.Journey? journey = null;
        var summary = new LegacyJourneySummary(compact: true);
        foreach (var row in ReportBuilder.ServeRows(command, "SELECT time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality FROM message_event WHERE msg_hash=@h AND message_id=@m COLLATE BINARY ORDER BY time_ms,id;", !reuse))
        {
            if (journey == null) journey = new ReportBuilder.Journey { MessageId = identity, First = L(row[0]) };
            journey.Last = L(row[0]); eventCount++;
            if (journey.Sender == null) journey.Sender = S(row[3]);
            if (journey.Subject == null) journey.Subject = S(row[7]);
            if (journey.Direction == null) journey.Direction = S(row[8]);
            journey.Size = Math.Max(journey.Size, L(row[6]));
            journey.MaxCount = Math.Max(journey.MaxCount, L(row[5]));
            summary.Add(S(row[1]), S(row[2]), S(row[4]));
        }
        // A message identity with SMTP rows only: the SMTP row path, identical in both rule sets. The engine runs the event query
        // once more and finds no row (one indexed lookup per SMTP-only identity); that keeps a single implementation of the
        // SMTP-only row instead of a second copy here.
        if (journey == null) return ReportBuilder.ReadServeRollupBounds(command, kind, identity, reuse, out eventCount, out smtpFirstMs, out smtpLastMs, sentStatus: false);
        long count;
        var counter = command("SELECT COUNT(*),MIN(time_ms),MAX(time_ms) FROM smtp_transaction WHERE msg_hash=@h AND message_id=@m COLLATE BINARY;");
        try
        {
            using var reader = counter.ExecuteReader();
            reader.Read();
            count = reader.GetInt64(0);
            if (!reader.IsDBNull(1)) { smtpFirstMs = reader.GetInt64(1); smtpLastMs = reader.GetInt64(2); }
        }
        finally { if (!reuse) counter.Dispose(); }
        return summary.Row(journey, count, t => t, new List<object[]>(), new List<object[]>());
    }

    /// <summary>
    /// The schema 8-11 rules as the rules plug of the engine's merge-scan verification: the same journey values as Read (first sender, subject and
    /// direction, bounds, size, recipient count) and the frozen LegacyJourneySummary, fed with the event rows of one identity in time_ms,id order.
    /// </summary>
    internal sealed class LegacyRules : ReportBuilder.RollupRules
    {
        internal LegacyRules() { SentSmtpStatus = false; }
        private ReportBuilder.Journey? journey;
        private LegacyJourneySummary summary = new(compact: true);
        private string identity = "";
        internal override void Begin(string identity) { this.identity = identity; journey = null; summary = new LegacyJourneySummary(compact: true); }
        internal override void Event(SqliteDataReader row)
        {
            long time = L(Value(row, 2));
            if (journey == null) journey = new ReportBuilder.Journey { MessageId = identity, First = time };
            journey.Last = time;
            if (journey.Sender == null) journey.Sender = S(Value(row, 5));
            if (journey.Subject == null) journey.Subject = S(Value(row, 9));
            if (journey.Direction == null) journey.Direction = S(Value(row, 10));
            journey.Size = Math.Max(journey.Size, L(Value(row, 8)));
            journey.MaxCount = Math.Max(journey.MaxCount, L(Value(row, 7)));
            summary.Add(S(Value(row, 3)), S(Value(row, 4)), S(Value(row, 6)));
        }
        internal override object[] Row(long smtpCount) => summary.Row(journey!, smtpCount, t => t, new List<object[]>(), new List<object[]>())!;
    }

    private static long L(object? v) => v == null ? 0 : Convert.ToInt64(v, CultureInfo.InvariantCulture);
    private static string? S(object? v) => v is byte[] ? Packed.Text(v) : v == null ? null : Convert.ToString(v, CultureInfo.InvariantCulture);

    /// <summary>
    /// Frozen copy of the schema 8-11 JourneySummary (pre-12). Never updated: it describes what those databases contain.
    /// </summary>
    internal sealed class LegacyJourneySummary
    {
        private static readonly HashSet<string> Final = new(StringComparer.Ordinal) { "Delivered", "Failed", "Dropped", "Poison" };
        private readonly Dictionary<string, string> status = new(StringComparer.OrdinalIgnoreCase);
        private readonly List<string> order = new(), servers = new(), events = new();
        private readonly HashSet<string>? compactEvents;
        private bool dropped;
        internal LegacyJourneySummary(bool compact = false) { if (compact) compactEvents = new HashSet<string>(StringComparer.Ordinal); }
        private void Set(string rcpt, string value)
        {
            if (string.IsNullOrEmpty(rcpt)) return;
            if (!status.TryGetValue(rcpt, out string? current)) order.Add(rcpt);
            else if (current == "Delivered" && value != "Failed") return;
            status[rcpt] = value;
        }
        internal void Add(string? server, string? evt, string? recipients)
        {
            evt ??= "";
            var rcpts = (recipients ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
            if (!servers.Contains(server!, StringComparer.OrdinalIgnoreCase)) servers.Add(server!);
            if (compactEvents != null) { if (compactEvents.Add(evt)) events.Add(evt); }
            else if (events.Count == 0 || events[events.Count - 1] != evt) events.Add(evt);
            switch (evt)
            {
                case "DELIVER": foreach (var x in rcpts) Set(x, "Delivered"); break;
                // SENDEXTERNAL: handed over by SMTP outside the transport services of the organization: same meaning as SEND.
                case "SEND": case "SENDEXTERNAL": foreach (var x in rcpts) { if (!status.TryGetValue(x, out string? cur) || !Final.Contains(cur)) Set(x, "Sent"); } break;
                case "FAIL": foreach (var x in rcpts) Set(x, "Failed"); break;
                case "DEFER": foreach (var x in rcpts) { if (!status.TryGetValue(x, out string? cur) || !Final.Contains(cur)) Set(x, "Deferred"); } break;
                case "DROP": dropped = true; foreach (var x in rcpts) Set(x, "Dropped"); break;
                case "POISONMESSAGE": foreach (var x in rcpts) Set(x, "Poison"); break;
                case "EXPAND": foreach (var x in rcpts) Set(x, "Expanded"); break;
                default: foreach (var x in rcpts) if (!status.ContainsKey(x)) Set(x, "In transit"); break;
            }
        }
        internal object?[] Row(ReportBuilder.Journey j, long smtpCount, Func<long, object> local, List<object[]> steps, List<object[]> transcripts)
        {
            var finals = order.Where(r => status[r] != "Expanded").ToList();
            int total = finals.Count;
            int delivered = 0, failed = 0, sent = 0, deferred = 0, drop = 0;
            foreach (var r in finals)
                switch (status[r])
                {
                    case "Delivered": delivered++; break;
                    case "Failed": case "Poison": failed++; break;
                    case "Sent": sent++; break;
                    case "Deferred": deferred++; break;
                    case "Dropped": drop++; break;
                }
            string overall;
            if (total == 0) overall = dropped ? "Dropped" : "In transit";
            else if (failed == total) overall = "Failed";
            else if (failed > 0) overall = "Partially failed";
            else if (drop > 0) overall = drop == total ? "Dropped" : "Partially dropped";
            else if (delivered == total) overall = "Delivered";
            else if (delivered + sent == total) overall = delivered > 0 ? "Delivered and relayed" : "Relayed";
            else if (deferred > 0) overall = "Deferred";
            else overall = "In transit";
            // The Duration slot (2) is not stored by the rollup and stays null.
            return new object?[] {
                local(j.First), local(j.Last), null, overall, j.Sender,
                finals.Select(r => status[r] == "Delivered" ? r : r + " (" + status[r] + ")").ToArray(),
                Math.Max(j.MaxCount, (long)total), (long)delivered, (long)failed, j.Subject, j.Size > 0 ? (object)(long)Math.Ceiling(j.Size / 1024.0) : null,
                j.Direction, string.Join(" > ", servers), string.Join(" > ", events), smtpCount, j.MessageId, steps, transcripts };
        }
    }
}
