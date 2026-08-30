using System.Text;

namespace AIAccessAssistant.Core;

public sealed record CodexConfigurationPaths(
    string UserProfile,
    string CodexHome,
    string ConfigurationFile)
{
    public static CodexConfigurationPaths Discover(
        Func<string, string?>? environmentReader = null)
    {
        environmentReader ??= Environment.GetEnvironmentVariable;

        var userProfile = environmentReader("USERPROFILE");
        if (string.IsNullOrWhiteSpace(userProfile))
        {
            throw new ConfigurationDiscoveryException(
                "USERPROFILE is unavailable; Codex configuration path cannot be proven.");
        }

        var codexHomeOverride = environmentReader("CODEX_HOME");
        var codexHome = string.IsNullOrWhiteSpace(codexHomeOverride)
            ? Path.Combine(userProfile, ".codex")
            : codexHomeOverride;

        return new CodexConfigurationPaths(
            Path.GetFullPath(userProfile),
            Path.GetFullPath(codexHome),
            Path.GetFullPath(Path.Combine(codexHome, "config.toml")));
    }
}

public sealed record ConfigurationPreview(
    string Path,
    string Content,
    long ByteCount,
    bool Exists,
    bool Redacted,
    string Status);

public sealed class ReadOnlyConfigurationPreviewService
{
    public const int MaximumConfigurationBytes = 2 * 1024 * 1024;

    private static readonly string[] SensitiveKeyFragments =
        ["key", "token", "secret", "password", "credential"];

    public async Task<ConfigurationPreview> ReadAsync(
        CodexConfigurationPaths paths,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(paths);

        var file = new FileInfo(paths.ConfigurationFile);
        if (!file.Exists)
        {
            return new ConfigurationPreview(
                paths.ConfigurationFile,
                string.Empty,
                0,
                false,
                false,
                "未找到 config.toml；未执行写入。");
        }

        file.Refresh();
        if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new ConfigurationPreviewException(
                "config.toml is a reparse point; preview blocked fail-closed.");
        }

        if (file.Length > MaximumConfigurationBytes)
        {
            throw new ConfigurationPreviewException(
                $"config.toml exceeds {MaximumConfigurationBytes} bytes; preview blocked.");
        }

        await using var stream = new FileStream(
            file.FullName,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            bufferSize: 16 * 1024,
            options: FileOptions.Asynchronous | FileOptions.SequentialScan);

        if (stream.Length > MaximumConfigurationBytes)
        {
            throw new ConfigurationPreviewException(
                $"config.toml exceeds {MaximumConfigurationBytes} bytes; preview blocked.");
        }

        var buffer = new byte[MaximumConfigurationBytes + 1];
        var byteCount = 0;
        while (byteCount < buffer.Length)
        {
            var count = await stream.ReadAsync(
                buffer.AsMemory(byteCount, buffer.Length - byteCount),
                cancellationToken);
            if (count == 0)
            {
                break;
            }
            byteCount += count;
        }
        if (byteCount > MaximumConfigurationBytes)
        {
            throw new ConfigurationPreviewException(
                $"config.toml grew beyond {MaximumConfigurationBytes} bytes; preview blocked.");
        }

        var source = new UTF8Encoding(
            encoderShouldEmitUTF8Identifier: false,
            throwOnInvalidBytes: true).GetString(buffer, 0, byteCount);
        source = source.TrimStart('\uFEFF');
        var redacted = Redact(source);
        return new ConfigurationPreview(
            file.FullName,
            redacted,
            byteCount,
            true,
            !string.Equals(source, redacted, StringComparison.Ordinal),
            "只读预览；敏感字段已脱敏，未执行写入。");
    }

    internal static string Redact(string source)
    {
        var newline = source.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var endsWithNewline = source.EndsWith("\n", StringComparison.Ordinal);
        var lines = source.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');

        for (var index = 0; index < lines.Length; index++)
        {
            var equalsIndex = lines[index].IndexOf('=');
            if (equalsIndex <= 0)
            {
                continue;
            }

            var leftHandSide = lines[index][..equalsIndex].TrimEnd();
            var normalizedKey = leftHandSide
                .Trim()
                .Trim('"', '\'')
                .ToLowerInvariant();
            if (normalizedKey.StartsWith('#') ||
                !SensitiveKeyFragments.Any(fragment => normalizedKey.Contains(fragment, StringComparison.Ordinal)))
            {
                continue;
            }

            lines[index] = $"{leftHandSide} = \"<redacted>\"";
        }

        var result = string.Join(newline, lines);
        if (!endsWithNewline && result.EndsWith(newline, StringComparison.Ordinal))
        {
            result = result[..^newline.Length];
        }

        return result;
    }
}

public sealed class ConfigurationDiscoveryException(string message) : Exception(message);

public sealed class ConfigurationPreviewException(string message) : Exception(message);
