using System.Security.Cryptography;
using System.Text;

namespace AIAccessAssistant.Core;

public enum WindowsHistoryEntryState
{
    Available,
    EmptyNeedsAttention,
}

public sealed record WindowsHistoryContinuityEntry(
    string OpaqueId,
    DateTimeOffset LastWriteUtc,
    long ByteCount,
    WindowsHistoryEntryState State);

public sealed record WindowsHistoryContinuitySnapshot(
    IReadOnlyList<WindowsHistoryContinuityEntry> Entries,
    DateTimeOffset ScannedAtUtc,
    bool SessionContentRead,
    bool CloudIndexUsed);

public sealed class WindowsHistoryContinuityException(string message)
    : IOException(message);

public sealed class WindowsHistoryContinuityScanner
{
    private static readonly EnumerationOptions LocalLevelOnly = new()
    {
        AttributesToSkip = 0,
        IgnoreInaccessible = false,
        RecurseSubdirectories = false,
        ReturnSpecialDirectories = false,
    };

    private readonly Func<DateTimeOffset> _clock;

    public WindowsHistoryContinuityScanner(
        Func<DateTimeOffset>? clock = null)
    {
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public WindowsHistoryContinuitySnapshot Scan(
        CodexConfigurationPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var codexHome =
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(
                paths.CodexHome);
        var sessionsRoot =
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(
            Path.Combine(codexHome, "sessions"));
        if (!IsDirectSessionsRoot(codexHome, sessionsRoot))
        {
            throw new WindowsHistoryContinuityException(
                "Codex history root escaped the fixed sessions directory.");
        }
        if (!Directory.Exists(sessionsRoot))
        {
            if (File.Exists(sessionsRoot))
            {
                throw new WindowsHistoryContinuityException(
                    "Codex sessions root is not a directory.");
            }
            return EmptySnapshot();
        }

        var root = new DirectoryInfo(sessionsRoot);
        RequireSafeDirectoryChain(root);
        var entries = new List<WindowsHistoryContinuityEntry>();
        foreach (var year in EnumerateDirectories(root, IsYear))
        {
            var yearValue = int.Parse(year.Name);
            foreach (var month in EnumerateDirectories(
                year,
                name => IsMonth(name, out _)))
            {
                _ = int.TryParse(month.Name, out var monthValue);
                foreach (var day in EnumerateDirectories(
                    month,
                    name => IsDay(name, yearValue, monthValue)))
                {
                    CollectDayEntries(root, day, entries);
                }
            }
        }

        return new WindowsHistoryContinuitySnapshot(
            entries
                .OrderByDescending(entry => entry.LastWriteUtc)
                .ThenBy(entry => entry.OpaqueId, StringComparer.Ordinal)
                .ToArray(),
            _clock().ToUniversalTime(),
            SessionContentRead: false,
            CloudIndexUsed: false);
    }

    private WindowsHistoryContinuitySnapshot EmptySnapshot() => new(
        [],
        _clock().ToUniversalTime(),
        SessionContentRead: false,
        CloudIndexUsed: false);

    private static IReadOnlyList<DirectoryInfo> EnumerateDirectories(
        DirectoryInfo parent,
        Func<string, bool> acceptsName)
    {
        var result = new List<DirectoryInfo>();
        foreach (var path in EnumerateBounded(parent))
        {
            var attributes = File.GetAttributes(path);
            RequireSafeAttributes(attributes);
            if ((attributes & FileAttributes.Directory) == 0)
            {
                continue;
            }
            var directory = new DirectoryInfo(path);
            directory.Refresh();
            RequireDirectChild(parent, directory);
            if (acceptsName(directory.Name))
            {
                result.Add(directory);
            }
        }
        return result.OrderBy(directory => directory.Name, StringComparer.Ordinal)
            .ToArray();
    }

    private static void CollectDayEntries(
        DirectoryInfo sessionsRoot,
        DirectoryInfo day,
        ICollection<WindowsHistoryContinuityEntry> output)
    {
        foreach (var path in EnumerateBounded(day))
        {
            var attributes = File.GetAttributes(path);
            RequireSafeAttributes(attributes);
            if ((attributes & FileAttributes.Directory) != 0 ||
                !Path.GetExtension(path).Equals(
                    ".jsonl",
                    StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var file = new FileInfo(path);
            file.Refresh();
            RequireDirectChild(day, file);
            var byteCount = file.Length;
            var lastWrite = file.LastWriteTimeUtc;
            file.Refresh();
            if (!file.Exists ||
                file.Length != byteCount ||
                file.LastWriteTimeUtc != lastWrite)
            {
                throw new WindowsHistoryContinuityException(
                    "A Codex session changed during metadata refresh.");
            }
            output.Add(new WindowsHistoryContinuityEntry(
                OpaqueIdentity(sessionsRoot, file, byteCount, lastWrite),
                new DateTimeOffset(lastWrite, TimeSpan.Zero),
                byteCount,
                byteCount == 0
                    ? WindowsHistoryEntryState.EmptyNeedsAttention
                    : WindowsHistoryEntryState.Available));
            if (output.Count > WindowsContinuityContract.MaximumHistoryFiles)
            {
                throw new WindowsHistoryContinuityException(
                    "Codex history exceeds the 10,000-session metadata limit.");
            }
        }
    }

    private static IReadOnlyList<string> EnumerateBounded(DirectoryInfo parent)
    {
        RequireSafeDirectoryChain(parent);
        var paths = new List<string>();
        foreach (var path in Directory.EnumerateFileSystemEntries(
            parent.FullName,
            "*",
            LocalLevelOnly))
        {
            paths.Add(path);
            if (paths.Count > WindowsContinuityContract.MaximumDirectoryEntries)
            {
                throw new WindowsHistoryContinuityException(
                    "A Codex history directory exceeds the 12,000-entry limit.");
            }
        }
        return paths;
    }

    private static void RequireSafeDirectoryChain(DirectoryInfo start)
    {
        for (DirectoryInfo? directory = start;
            directory is not null;
            directory = directory.Parent)
        {
            directory.Refresh();
            if (!directory.Exists)
            {
                throw new WindowsHistoryContinuityException(
                    "Codex history directory disappeared during metadata refresh.");
            }
            RequireSafeAttributes(directory.Attributes);
        }
        if (OperatingSystem.IsWindows())
        {
            var root = Path.GetPathRoot(start.FullName) ?? string.Empty;
            if (string.IsNullOrEmpty(root) ||
                new DriveInfo(root).DriveType != DriveType.Fixed)
            {
                throw new WindowsHistoryContinuityException(
                    "Codex history must remain on one fixed local drive.");
            }
        }
    }

    private static void RequireSafeAttributes(FileAttributes attributes)
    {
        if ((attributes &
                (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0)
        {
            throw new WindowsHistoryContinuityException(
                "Reparse or offline Codex history entry was blocked.");
        }
    }

    private static void RequireDirectChild(
        DirectoryInfo parent,
        FileSystemInfo child)
    {
        var childParent = child switch
        {
            DirectoryInfo directory => directory.Parent?.FullName,
            FileInfo file => file.Directory?.FullName,
            _ => null,
        };
        if (!string.Equals(
                Path.GetFullPath(parent.FullName),
                childParent is null ? null : Path.GetFullPath(childParent),
                OperatingSystem.IsWindows()
                    ? StringComparison.OrdinalIgnoreCase
                    : StringComparison.Ordinal))
        {
            throw new WindowsHistoryContinuityException(
                "Codex history entry escaped its expected directory.");
        }
    }

    private static string OpaqueIdentity(
        DirectoryInfo sessionsRoot,
        FileInfo file,
        long byteCount,
        DateTime lastWriteUtc)
    {
        var relative = Path.GetRelativePath(
                sessionsRoot.FullName,
                file.FullName)
            .Replace(Path.DirectorySeparatorChar, '/');
        if (relative == ".." || relative.StartsWith("../", StringComparison.Ordinal))
        {
            throw new WindowsHistoryContinuityException(
                "Codex history entry escaped the sessions root.");
        }
        var material = Encoding.UTF8.GetBytes(string.Join(
            "\u001f",
            relative,
            byteCount,
            lastWriteUtc.Ticks));
        try
        {
            return Convert.ToHexString(SHA256.HashData(material))
                .ToLowerInvariant();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(material);
        }
    }

    private static bool IsDirectSessionsRoot(
        string codexHome,
        string sessionsRoot)
    {
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        return string.Equals(
            sessionsRoot,
            Path.GetFullPath(Path.Combine(codexHome, "sessions")),
            comparison);
    }

    private static bool IsYear(string name) =>
        name.Length == 4 &&
        int.TryParse(name, out var value) &&
        value is >= 1 and <= 9999;

    private static bool IsMonth(string name, out int value)
    {
        value = 0;
        return name.Length == 2 &&
               int.TryParse(name, out value) &&
               value is >= 1 and <= 12;
    }

    private static bool IsDay(string name, int year, int month) =>
        name.Length == 2 &&
        int.TryParse(name, out var value) &&
        value >= 1 &&
        value <= DateTime.DaysInMonth(year, month);
}
