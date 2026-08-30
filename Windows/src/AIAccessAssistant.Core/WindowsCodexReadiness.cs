using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using System.Text;
using System.Text.Json;

namespace AIAccessAssistant.Core;

public static class WindowsCodexReadinessContract
{
    public const int SourceBuild = 143;
    public const int MaximumPathDirectories = 128;
    public const int MaximumPathDepth = 64;
    public const int MaximumShimBytes = 64 * 1024;
    public const int MaximumPackageMetadataBytes = 256 * 1024;
    public const string EvidenceLevel = "source_verified";
    public const string RuntimeState = "unverified";
}

public enum WindowsCodexInstallationState
{
    Found,
    NotFound,
    Blocked,
}

public enum WindowsCodexVersionState
{
    Known,
    Unknown,
}

public enum WindowsCodexAccessKind
{
    Official,
    Relay,
    Blocked,
}

public enum WindowsCanWorkState
{
    NotReady,
    NeedsAttention,
    Unverified,
}

public sealed record WindowsCodexInstallationEvidence(
    WindowsCodexInstallationState State,
    WindowsCodexVersionState VersionState,
    string? Version,
    string? CandidateKind,
    string? SourceLabel,
    string Summary,
    string? ExecutablePath = null);

public sealed record WindowsCodexAccessEvidence(
    WindowsCodexAccessKind Kind,
    bool ExplicitProvider,
    string Summary);

public sealed record WindowsUserOutcome(
    WindowsCanWorkState State,
    string Conclusion,
    string PrimaryAction,
    string Continuation);

public sealed record WindowsCodexReadinessSnapshot(
    WindowsCodexInstallationEvidence Installation,
    WindowsCodexAccessEvidence Access,
    WindowsUserOutcome Outcome,
    ConfigurationPreview ConfigurationPreview,
    string TechnicalStatus,
    string EvidenceLevel,
    string RuntimeState);

public sealed class ReadOnlyWindowsCodexReadinessService
{
    private readonly Func<string, string?> _environmentReader;
    private readonly ReadOnlyConfigurationPreviewService _previewService;

    public ReadOnlyWindowsCodexReadinessService(
        Func<string, string?>? environmentReader = null,
        ReadOnlyConfigurationPreviewService? previewService = null)
    {
        _environmentReader = environmentReader
            ?? Environment.GetEnvironmentVariable;
        _previewService = previewService
            ?? new ReadOnlyConfigurationPreviewService();
    }

    public async Task<WindowsCodexReadinessSnapshot> InspectAsync(
        CancellationToken cancellationToken = default)
    {
        var installation = await InspectInstallationAsync(cancellationToken);
        var (preview, access, technicalStatus) =
            await InspectCurrentAccessAsync(cancellationToken);
        var outcome = ProjectOutcome(installation, access);

        return new WindowsCodexReadinessSnapshot(
            installation,
            access,
            outcome,
            preview,
            technicalStatus,
            WindowsCodexReadinessContract.EvidenceLevel,
            WindowsCodexReadinessContract.RuntimeState);
    }

    private async Task<WindowsCodexInstallationEvidence>
        InspectInstallationAsync(CancellationToken cancellationToken)
    {
        var blockedCandidateObserved = false;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var directory in SupportedCandidateDirectories())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!TryNormalizeLocalPath(directory.Path, out var normalized))
            {
                blockedCandidateObserved = true;
                continue;
            }
            if (!seen.Add(normalized))
            {
                continue;
            }

            foreach (var candidateName in new[]
                     {
                         "codex.exe",
                         "codex.cmd",
                         "codex.ps1",
                     })
            {
                var candidate = Path.Combine(normalized, candidateName);
                var inspection = await InspectCandidateAsync(
                    candidate,
                    directory.Label,
                    cancellationToken);
                if (inspection.State == WindowsCodexInstallationState.Found)
                {
                    return inspection;
                }
                if (inspection.State == WindowsCodexInstallationState.Blocked)
                {
                    blockedCandidateObserved = true;
                }
            }
        }

        if (blockedCandidateObserved)
        {
            return new WindowsCodexInstallationEvidence(
                WindowsCodexInstallationState.Blocked,
                WindowsCodexVersionState.Unknown,
                null,
                null,
                null,
                "Codex 安装识别遇到不安全或不可读取的候选；未继续扩大扫描范围。");
        }

        return new WindowsCodexInstallationEvidence(
            WindowsCodexInstallationState.NotFound,
            WindowsCodexVersionState.Unknown,
            null,
            null,
            null,
            "在受支持的有限位置未识别到 Codex；这不代表电脑其他位置一定没有安装。");
    }

    private IEnumerable<(string Path, string Label)>
        SupportedCandidateDirectories()
    {
        var pathValue = _environmentReader("PATH");
        if (!string.IsNullOrWhiteSpace(pathValue))
        {
            var count = 0;
            foreach (var part in pathValue.Split(
                         Path.PathSeparator,
                         StringSplitOptions.RemoveEmptyEntries |
                         StringSplitOptions.TrimEntries))
            {
                if (count >= WindowsCodexReadinessContract.MaximumPathDirectories)
                {
                    break;
                }
                count += 1;
                yield return (part.Trim('"'), "PATH");
            }
        }

        var userProfile = _environmentReader("USERPROFILE");
        if (!string.IsNullOrWhiteSpace(userProfile))
        {
            yield return (
                Path.Combine(userProfile, ".codex", "bin"),
                "用户 Codex 目录");
        }

        var localAppData = _environmentReader("LOCALAPPDATA");
        if (!string.IsNullOrWhiteSpace(localAppData))
        {
            yield return (
                Path.Combine(localAppData, "Programs", "Codex"),
                "本机 Codex 程序目录");
        }
    }

    private static async Task<WindowsCodexInstallationEvidence>
        InspectCandidateAsync(
            string candidatePath,
            string sourceLabel,
            CancellationToken cancellationToken)
    {
        try
        {
            var file = new FileInfo(candidatePath);
            if (file.Directory is null || !file.Directory.Exists)
            {
                return NotFoundCandidate();
            }
            if (ContainsReparsePointInParents(file.Directory))
            {
                return BlockedCandidate();
            }
            file.Refresh();
            if (!file.Exists)
            {
                return NotFoundCandidate();
            }
            if ((file.Attributes & FileAttributes.Directory) != 0 ||
                (file.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                return BlockedCandidate();
            }

            if (file.Extension.Equals(".exe", StringComparison.OrdinalIgnoreCase))
            {
                if (!await HasPortableExecutableMagicAsync(
                        file,
                        cancellationToken))
                {
                    return BlockedCandidate();
                }

                var version = SafeVersion(
                    FileVersionInfo.GetVersionInfo(file.FullName)
                        .ProductVersion)
                    ?? SafeVersion(
                        FileVersionInfo.GetVersionInfo(file.FullName)
                            .FileVersion);
                return FoundCandidate(
                    "codex.exe",
                    sourceLabel,
                    version,
                    file.FullName);
            }

            if (file.Length > WindowsCodexReadinessContract.MaximumShimBytes)
            {
                return BlockedCandidate();
            }
            var shim = await ReadBoundedUtf8Async(
                file,
                WindowsCodexReadinessContract.MaximumShimBytes,
                cancellationToken);
            var normalizedShim = shim.Replace('\\', '/');
            if (!normalizedShim.Contains(
                    "@openai/codex",
                    StringComparison.OrdinalIgnoreCase) &&
                !normalizedShim.Contains(
                    "codex.js",
                    StringComparison.OrdinalIgnoreCase))
            {
                return BlockedCandidate();
            }

            var npmVersion = await ReadAdjacentNpmVersionAsync(
                file.DirectoryName,
                cancellationToken);
            return FoundCandidate(
                file.Extension.Equals(
                    ".cmd",
                    StringComparison.OrdinalIgnoreCase)
                    ? "codex.cmd"
                    : "codex.ps1",
                sourceLabel,
                npmVersion,
                file.FullName);
        }
        catch (Exception error) when (
            error is IOException or
            UnauthorizedAccessException or
            SecurityException or
            Win32Exception or
            DecoderFallbackException or
            JsonException or
            ArgumentException or
            NotSupportedException)
        {
            return BlockedCandidate();
        }
    }

    private async Task<(ConfigurationPreview Preview,
        WindowsCodexAccessEvidence Access, string TechnicalStatus)>
        InspectCurrentAccessAsync(CancellationToken cancellationToken)
    {
        CodexConfigurationPaths paths;
        try
        {
            paths = CodexConfigurationPaths.Discover(_environmentReader);
        }
        catch (Exception error) when (
            error is ConfigurationDiscoveryException or
            ArgumentException or
            SecurityException or
            NotSupportedException)
        {
            return BlockedAccessResult(
                string.Empty,
                "无法在受支持的本机路径中确认 Codex 配置位置。");
        }

        if (!TryNormalizeLocalPath(
                paths.ConfigurationFile,
                out var localConfigurationPath))
        {
            return BlockedAccessResult(
                string.Empty,
                "配置位于不受支持的设备或网络路径；只读识别已阻止。");
        }

        try
        {
            if (ContainsReparsePointInParents(
                    new FileInfo(localConfigurationPath).Directory))
            {
                return BlockedAccessResult(
                    localConfigurationPath,
                    "配置路径包含重解析点；只读识别已阻止。");
            }
            var localPaths = paths with
            {
                ConfigurationFile = localConfigurationPath,
            };
            var preview = await _previewService.ReadAsync(
                localPaths,
                cancellationToken);
            return (
                preview,
                WindowsCodexAccessRecognizer.Recognize(preview),
                preview.Status);
        }
        catch (Exception error) when (
            error is ConfigurationPreviewException or
            DecoderFallbackException or
            IOException or
            UnauthorizedAccessException or
            SecurityException or
            ArgumentException or
            NotSupportedException)
        {
            return BlockedAccessResult(
                localConfigurationPath,
                "config.toml 只读读取失败；未执行写入。");
        }
    }

    private static (
        ConfigurationPreview Preview,
        WindowsCodexAccessEvidence Access,
        string TechnicalStatus) BlockedAccessResult(
            string configurationPath,
            string status)
    {
        var preview = new ConfigurationPreview(
            configurationPath,
            string.Empty,
            0,
            false,
            false,
            status);
        var access = new WindowsCodexAccessEvidence(
            WindowsCodexAccessKind.Blocked,
            false,
            "当前接入无法安全识别；未读取认证文件，也未修改配置。");
        return (preview, access, status);
    }

    private static WindowsUserOutcome ProjectOutcome(
        WindowsCodexInstallationEvidence installation,
        WindowsCodexAccessEvidence access)
    {
        const string continuation =
            "本次只读检查未修改配置、凭据或任务，可以按提示处理后继续。";

        if (installation.State == WindowsCodexInstallationState.NotFound)
        {
            return new WindowsUserOutcome(
                WindowsCanWorkState.NotReady,
                "当前不能确认可以工作",
                "确认 Codex 已安装并加入 PATH，然后刷新只读识别。",
                continuation);
        }

        if (installation.State == WindowsCodexInstallationState.Blocked ||
            access.Kind == WindowsCodexAccessKind.Blocked)
        {
            return new WindowsUserOutcome(
                WindowsCanWorkState.NeedsAttention,
                "当前识别不完整，不能确认可以工作",
                "先检查普通本机安装路径和 config.toml，再刷新只读识别。",
                continuation);
        }

        return new WindowsUserOutcome(
            WindowsCanWorkState.Unverified,
            "已识别 Codex，但尚未验证能完成任务",
            "在 Windows 11 x64 上核对登录或额度；真实任务验证仍需用户另行确认。",
            continuation);
    }

    private static bool TryNormalizeLocalPath(
        string path,
        out string normalized)
    {
        normalized = string.Empty;
        try
        {
            normalized =
                WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(path);
            return true;
        }
        catch (Exception error) when (
            error is ArgumentException or
            IOException or
            SecurityException or
            NotSupportedException)
        {
            return false;
        }
    }

    private static bool ContainsReparsePointInParents(DirectoryInfo? directory)
    {
        var depth = 0;
        while (directory is not null &&
               depth < WindowsCodexReadinessContract.MaximumPathDepth)
        {
            if (directory.Exists)
            {
                directory.Refresh();
                if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    return true;
                }
            }
            directory = directory.Parent;
            depth += 1;
        }
        return directory is not null;
    }

    private static async Task<bool> HasPortableExecutableMagicAsync(
        FileInfo file,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            file.FullName,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            bufferSize: 2,
            options: FileOptions.Asynchronous | FileOptions.SequentialScan);
        var magic = new byte[2];
        var count = await stream.ReadAsync(magic, cancellationToken);
        return count == 2 && magic[0] == (byte)'M' && magic[1] == (byte)'Z';
    }

    private static async Task<string> ReadBoundedUtf8Async(
        FileInfo file,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        file.Refresh();
        if (file.Length > maximumBytes)
        {
            throw new IOException("bounded read exceeded");
        }

        await using var stream = new FileStream(
            file.FullName,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            bufferSize: 16 * 1024,
            options: FileOptions.Asynchronous | FileOptions.SequentialScan);
        if (stream.Length > maximumBytes)
        {
            throw new IOException("bounded read exceeded");
        }

        var buffer = new byte[maximumBytes + 1];
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
        if (byteCount > maximumBytes)
        {
            throw new IOException("bounded read exceeded");
        }

        return new UTF8Encoding(false, true).GetString(
            buffer,
            0,
            byteCount).TrimStart('\uFEFF');
    }

    private static async Task<string?> ReadAdjacentNpmVersionAsync(
        string? shimDirectory,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(shimDirectory))
        {
            return null;
        }

        try
        {
            var packagePath = Path.Combine(
                shimDirectory,
                "node_modules",
                "@openai",
                "codex",
                "package.json");
            if (!TryNormalizeLocalPath(packagePath, out var normalized))
            {
                return null;
            }
            var file = new FileInfo(normalized);
            if (ContainsReparsePointInParents(file.Directory))
            {
                return null;
            }
            file.Refresh();
            if (!file.Exists ||
                (file.Attributes & FileAttributes.ReparsePoint) != 0 ||
                file.Length >
                    WindowsCodexReadinessContract.MaximumPackageMetadataBytes)
            {
                return null;
            }

            var source = await ReadBoundedUtf8Async(
                file,
                WindowsCodexReadinessContract.MaximumPackageMetadataBytes,
                cancellationToken);
            using var document = JsonDocument.Parse(source);
            if (!document.RootElement.TryGetProperty(
                    "version",
                    out var versionProperty) ||
                versionProperty.ValueKind != JsonValueKind.String)
            {
                return null;
            }
            return SafeVersion(versionProperty.GetString());
        }
        catch (Exception error) when (
            error is IOException or
            UnauthorizedAccessException or
            SecurityException or
            DecoderFallbackException or
            JsonException or
            ArgumentException or
            NotSupportedException)
        {
            return null;
        }
    }

    private static string? SafeVersion(string? source)
    {
        var value = source?.Trim();
        if (string.IsNullOrEmpty(value) || value.Length > 64)
        {
            return null;
        }
        return value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '.' or '-' or '_' or '+')
            ? value
            : null;
    }

    private static WindowsCodexInstallationEvidence FoundCandidate(
        string candidateKind,
        string sourceLabel,
        string? version,
        string executablePath)
    {
        var versionState = string.IsNullOrEmpty(version)
            ? WindowsCodexVersionState.Unknown
            : WindowsCodexVersionState.Known;
        var versionText = versionState == WindowsCodexVersionState.Known
            ? $"版本 {version}"
            : "版本尚未确认";
        return new WindowsCodexInstallationEvidence(
            WindowsCodexInstallationState.Found,
            versionState,
            version,
            candidateKind,
            sourceLabel,
            $"已在{sourceLabel}识别到 {candidateKind}；{versionText}。",
            executablePath);
    }

    private static WindowsCodexInstallationEvidence NotFoundCandidate() =>
        new(
            WindowsCodexInstallationState.NotFound,
            WindowsCodexVersionState.Unknown,
            null,
            null,
            null,
            string.Empty);

    private static WindowsCodexInstallationEvidence BlockedCandidate() =>
        new(
            WindowsCodexInstallationState.Blocked,
            WindowsCodexVersionState.Unknown,
            null,
            null,
            null,
            string.Empty);
}

public static class WindowsCodexAccessRecognizer
{
    public static WindowsCodexAccessEvidence Recognize(
        ConfigurationPreview preview)
    {
        ArgumentNullException.ThrowIfNull(preview);

        var providerValues = new List<string>();
        var rootScope = true;
        foreach (var rawLine in preview.Content
                     .Replace("\r\n", "\n", StringComparison.Ordinal)
                     .Split('\n'))
        {
            var line = StripComment(rawLine).Trim();
            if (line.Length == 0)
            {
                continue;
            }
            if (line.StartsWith("[", StringComparison.Ordinal))
            {
                rootScope = false;
                continue;
            }
            if (!rootScope)
            {
                continue;
            }

            var equalsIndex = IndexOfEqualsOutsideQuotes(line);
            if (equalsIndex < 0)
            {
                if (LooksLikeModelProvider(line))
                {
                    return Blocked();
                }
                continue;
            }

            var rawKey = line[..equalsIndex];
            var key = NormalizeKey(rawKey);
            if (key is null && LooksLikeModelProvider(rawKey))
            {
                return Blocked();
            }
            if (!string.Equals(
                    key,
                    "model_provider",
                    StringComparison.Ordinal))
            {
                continue;
            }

            var value = ParseQuotedValue(line[(equalsIndex + 1)..]);
            if (value is null || value.Length == 0)
            {
                return Blocked();
            }
            providerValues.Add(value);
            if (providerValues.Count > 1)
            {
                return Blocked();
            }
        }

        if (providerValues.Count == 0)
        {
            return new WindowsCodexAccessEvidence(
                WindowsCodexAccessKind.Official,
                false,
                "未指定 model_provider，按 Codex 官方默认接入识别；登录、额度和真实任务尚未验证。");
        }

        if (providerValues[0].Equals(
                "openai",
                StringComparison.OrdinalIgnoreCase))
        {
            return new WindowsCodexAccessEvidence(
                WindowsCodexAccessKind.Official,
                true,
                "当前配置选择 Codex 官方；登录、额度和真实任务尚未验证。");
        }

        return new WindowsCodexAccessEvidence(
            WindowsCodexAccessKind.Relay,
            true,
            "当前配置选择一个中转接入；名称、地址和凭据不在摘要中显示，真实任务尚未验证。");
    }

    private static WindowsCodexAccessEvidence Blocked() =>
        new(
            WindowsCodexAccessKind.Blocked,
            false,
            "model_provider 重复、为空或格式不受支持；当前接入识别已阻止。");

    private static bool LooksLikeModelProvider(string line)
    {
        var normalized = line.TrimStart();
        return normalized.StartsWith(
                   "model_provider",
                   StringComparison.Ordinal) ||
               normalized.StartsWith(
                   "\"model_provider\"",
                   StringComparison.Ordinal) ||
               normalized.StartsWith(
                   "'model_provider'",
                   StringComparison.Ordinal);
    }

    private static string? NormalizeKey(string source)
    {
        var value = source.Trim();
        if (value.Length >= 2 &&
            ((value[0] == '"' && value[^1] == '"') ||
             (value[0] == '\'' && value[^1] == '\'')))
        {
            value = value[1..^1];
        }
        if (value.Length == 0 ||
            value.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) ||
                  character is '_' or '-')))
        {
            return null;
        }
        return value;
    }

    private static string? ParseQuotedValue(string source)
    {
        var value = source.Trim();
        if (value.Length < 2)
        {
            return null;
        }
        if (value[0] == '"' && value[^1] == '"')
        {
            try
            {
                return JsonSerializer.Deserialize<string>(value)?.Trim();
            }
            catch (JsonException)
            {
                return null;
            }
        }
        if (value[0] == '\'' && value[^1] == '\'' &&
            !value[1..^1].Contains('\''))
        {
            return value[1..^1].Trim();
        }
        return null;
    }

    private static string StripComment(string source)
    {
        var quote = '\0';
        var escaped = false;
        for (var index = 0; index < source.Length; index++)
        {
            var character = source[index];
            if (quote == '"' && escaped)
            {
                escaped = false;
                continue;
            }
            if (quote == '"' && character == '\\')
            {
                escaped = true;
                continue;
            }
            if (quote != '\0')
            {
                if (character == quote)
                {
                    quote = '\0';
                }
                continue;
            }
            if (character is '"' or '\'')
            {
                quote = character;
                continue;
            }
            if (character == '#')
            {
                return source[..index];
            }
        }
        return source;
    }

    private static int IndexOfEqualsOutsideQuotes(string source)
    {
        var quote = '\0';
        var escaped = false;
        for (var index = 0; index < source.Length; index++)
        {
            var character = source[index];
            if (quote == '"' && escaped)
            {
                escaped = false;
                continue;
            }
            if (quote == '"' && character == '\\')
            {
                escaped = true;
                continue;
            }
            if (quote != '\0')
            {
                if (character == quote)
                {
                    quote = '\0';
                }
                continue;
            }
            if (character is '"' or '\'')
            {
                quote = character;
                continue;
            }
            if (character == '=')
            {
                return index;
            }
        }
        return -1;
    }
}
