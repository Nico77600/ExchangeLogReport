// Storage maintenance command line (Database-Storage.ps1): option parsing, failure reporting and the entry point.
// Author  : Nicolas Fabert
// Version : 3.0.0
#nullable enable
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport.Storage;

internal enum StorageMode { None, Audit, Copy }

/// <summary>A failure whose message is safe to show as is.</summary>
internal sealed class ApiError(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

internal sealed record StorageOptions(string Database, StorageMode StorageMode)
{
    public string? Destination { get; init; }
    public string? Output { get; init; }
    public string SqliteTool { get; init; } = "";
    public bool Migrate { get; init; }
    public bool Repack { get; init; }
    public bool Vacuum { get; init; }

    public static StorageOptions Parse(string[] args, string defaultSqliteTool)
    {
        string database = "";
        StorageMode mode = StorageMode.None;
        string? destination = null, output = null;
        string sqliteTool = defaultSqliteTool;
        bool confirm = false, migrate = false, repack = false, vacuum = false;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (int i = 0; i < args.Length; i++)
        {
            string key = args[i];
            if (!seen.Add(key)) throw new ArgumentException("Duplicate command-line option.");
            string Value()
            {
                if (++i >= args.Length || args[i].StartsWith("--", StringComparison.Ordinal))
                    throw new ArgumentException("Missing command-line option value.");
                return args[i];
            }
            switch (key)
            {
                case "--database": database = Absolute(Value()); break;
                case "--sqlite-tool": sqliteTool = Absolute(Value()); break;
                case "--output": output = Absolute(Value()); break;
                case "--destination": destination = Absolute(Value()); break;
                case "--confirm-copy": confirm = true; break;
                case "--migrate": migrate = true; break;
                case "--repack": repack = true; break;
                case "--vacuum": vacuum = true; break;
                case "--storage-audit":
                case "--storage-copy":
                    if (mode != StorageMode.None) throw new ArgumentException("Choose one storage operation.");
                    mode = key == "--storage-audit" ? StorageMode.Audit : StorageMode.Copy;
                    break;
                default: throw new ArgumentException("Unknown command-line option.");
            }
        }
        if (mode == StorageMode.None) throw new ArgumentException("Choose --storage-audit or --storage-copy.");
        if (!seen.Contains("--database"))
            throw new ArgumentException("Storage operations require an explicit absolute --database.");
        if (mode == StorageMode.Copy && (destination is null || !confirm))
            throw new ArgumentException("--storage-copy requires --destination and --confirm-copy.");
        if (mode == StorageMode.Copy) output ??= destination + ".maintenance.json";
        if (mode != StorageMode.Copy && (destination is not null || confirm || migrate || repack || vacuum))
            throw new ArgumentException("Destination, confirmation and maintenance switches require --storage-copy.");
        return new(database, mode) {
            Destination = destination, Output = output, SqliteTool = sqliteTool,
            Migrate = migrate, Repack = repack, Vacuum = vacuum
        };
    }

    private static string Absolute(string value)
    {
        if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("Paths must be fully qualified.");
        return Path.GetFullPath(value);
    }
}

public static class StorageCli
{
    internal static string Version { get; private set; } = "3.0.0";

    private const string Usage =
        "Read-only audit:\n" +
        "  Database-Storage.cmd --storage-audit --database \"D:\\Copy\\ExchangeLogReport.sqlite\"\n" +
        "New compacted copy, without schema change:\n" +
        "  Database-Storage.cmd --storage-copy --database \"D:\\Copy\\ExchangeLogReport.sqlite\" --destination \"D:\\Copy\\Compacted.sqlite\" --output \"D:\\Copy\\Compacted.audit.json\" --confirm-copy --vacuum\n" +
        "New optimized copy for this version:\n" +
        "  Database-Storage.cmd --storage-copy --database \"D:\\Copy\\ExchangeLogReport.sqlite\" --destination \"D:\\Copy\\Optimized.sqlite\" --output \"D:\\Copy\\Optimized.audit.json\" --confirm-copy --migrate --repack --vacuum\n" +
        "Read the \"Database maintenance\" chapter of the user guide (docs\\ExchangeLogReport-UserGuide.html) before running maintenance. Original files are never replaced.";

    /// <summary>Runs one storage operation. Exit codes: 0 done, 2 refused or failed; the JSON report goes to stdout.</summary>
    public static int Run(string[] args, string toolVersion, string defaultSqliteTool)
    {
        Version = toolVersion;
        if (args.Length == 0)
        {
            Console.WriteLine(Usage);
            return 0;
        }
        StorageOptions options;
        try { options = StorageOptions.Parse(args, defaultSqliteTool); }
        catch (ArgumentException e) { Console.Error.WriteLine(e.Message); return 2; }
        return StorageMaintenance.RunCliAsync(options).GetAwaiter().GetResult();
    }

    internal static string Describe(Exception error)
    {
        Exception cause = error.GetBaseException();
        // Never print arbitrary exception messages: SQLite errors can include private values.
        string reason = cause switch {
            ApiError problem => problem.Message,
            DllNotFoundException => "A native dependency is missing. Re-extract the complete win-x64 package and check lib\\sqlite\\runtimes\\win-x64\\e_sqlite3.dll.",
            BadImageFormatException => "A binary is corrupt or has the wrong architecture. Use the complete win-x64 package on 64-bit Windows.",
            FileNotFoundException file => "Required file or assembly is missing" + Dependency(file.FileName) + ". Re-extract the complete package.",
            FileLoadException file => "A required assembly could not be loaded" + Dependency(file.FileName) + ". Check package integrity and Windows file blocking.",
            DirectoryNotFoundException => "A required directory is missing. Check the database, destination and output paths.",
            UnauthorizedAccessException => "Access denied. Check read permission for the source and write permission for the destination and output folders.",
            Win32Exception native => "Windows operation failed (" + native.NativeErrorCode + "): " + new Win32Exception(native.NativeErrorCode).Message + ".",
            SqliteException sqlite => SqliteReason(sqlite),
            IOException io => "Local file operation failed (Windows " + (io.HResult & 0xffff) + "): " + new Win32Exception(io.HResult & 0xffff).Message + ". Check paths, free disk space and files held by another process.",
            InvalidDataException => "A database or package data file is incomplete or unsupported. Verify the package and the source database.",
            _ => "Unexpected local operation failure. Verify the complete package, chosen paths and free disk space."
        };
        return reason + " [" + cause.GetType().Name + "; HRESULT 0x" + cause.HResult.ToString("X8") + "]";
    }

    private static string Dependency(string? path)
    {
        if (path is null) return "";
        string name = Path.GetFileName(path);
        return name.Length <= 180 && Regex.IsMatch(name, @"^[A-Za-z0-9_.-]+\.(?:dll|exe)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
            ? " (" + name + ")" : "";
    }

    private static string SqliteReason(SqliteException error)
    {
        string reason = error.SqliteErrorCode switch {
            1 => "The SQLite schema or query is unavailable. Verify the delivered schema-" + ExchangeLogReport.Store.SchemaVersion + " source.",
            3 or 23 => "SQLite access was denied. Check local file permissions.",
            5 or 6 => "SQLite is busy or locked. Close other writers and retry.",
            8 => "SQLite rejected a write on a read-only connection. Source migration is not allowed.",
            11 or 26 => "The selected file is corrupt or is not a SQLite database.",
            13 => "SQLite storage is full. Free space in the destination directory.",
            14 => "SQLite could not open the configured file. Check its existence, path and read permissions.",
            _ => "SQLite could not complete the operation. Check source integrity and local storage."
        };
        return reason + " SQLite codes " + error.SqliteErrorCode + "/" + error.SqliteExtendedErrorCode + ".";
    }
}