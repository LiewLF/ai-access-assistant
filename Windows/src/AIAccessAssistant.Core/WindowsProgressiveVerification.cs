using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AIAccessAssistant.Core;

public static class WindowsProgressiveVerificationContract
{
    public const int SourceBuild = 145;
    public const int MaximumCapturedBytesPerStream = 512 * 1024;
    public const int MaximumConfigurationBytes = 2 * 1024 * 1024;
    public const int MaximumRequestsPerStep = 1;
    public const int BasicTimeoutSeconds = 60;
    public const int RealTaskTimeoutSeconds = 90;
    public static readonly TimeSpan ConsentLifetime = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan ReceiptLifetime = TimeSpan.FromHours(24);
    public const string EvidenceLevel = "source_verified";
    public const string RuntimeState = "unverified";
}

public enum WindowsVerificationStep
{
    BasicConnection,
    RealTask,
}

public enum WindowsVerificationStage
{
    NeedsBasic,
    CheckingBasic,
    BasicFailed,
    NeedsRealTask,
    VerifyingRealTask,
    RealTaskFailed,
    Ready,
    Blocked,
}

public enum WindowsVerificationFailureStage
{
    Preparation,
    Login,
    Quota,
    Connection,
    InitialResponse,
    ToolCall,
    ToolExecution,
    Continuation,
    FinalResponse,
    ConfigurationChanged,
    Cleanup,
    Timeout,
    Unknown,
}

public enum WindowsVerificationFailureCategory
{
    Authentication,
    Permission,
    QuotaExhausted,
    RateLimited,
    EndpointOrModel,
    Dns,
    Tls,
    Timeout,
    NetworkUnavailable,
    InvalidResponse,
    ConfigurationDrift,
    ExecutableDrift,
    CredentialUnavailable,
    ToolPermission,
    ResponsesCompatibility,
    Cleanup,
    Unknown,
}

public enum WindowsVerificationPrimaryAction
{
    OpenCodexLogin,
    ReviewRelayProfile,
    ReviewQuota,
    RetryLater,
    ReviewOwnedCodexProcess,
    ReviewDnsAndAddress,
    ReviewTlsAndProxy,
    CheckNetwork,
    RefreshState,
    UpdateAssistant,
    ReviewToolPermission,
    ReviewResponsesCompatibility,
    StopOtherConfigurationTools,
    RestartAssistant,
    OpenAdvancedDiagnostics,
}

public sealed record WindowsVerificationFailurePresentation(
    string Conclusion,
    string Explanation,
    WindowsVerificationPrimaryAction PrimaryAction,
    IReadOnlyList<string> Evidence);

public sealed record WindowsVerificationConsentPlan(
    string PlanId,
    WindowsVerificationStep Step,
    WindowsCodexAccessKind AccessKind,
    string ConfigurationPath,
    string ConfigurationSha256,
    string ExecutablePath,
    string ExecutableSha256,
    string ProviderSha256,
    string? CredentialTarget,
    string? CredentialEnvironmentName,
    DateTimeOffset PreparedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    string ConfirmationTitle,
    string ConfirmationMessage,
    bool MayCostMoney);

public sealed record WindowsVerificationReceipt(
    int SchemaVersion,
    WindowsVerificationStep Step,
    bool Passed,
    DateTimeOffset ObservedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    long DurationMilliseconds,
    string ProviderSha256,
    string ConfigurationSha256,
    string ExecutableSha256,
    string EventStructureSha256,
    int ToolCallCount,
    int RequestCount,
    WindowsVerificationFailureStage? FailureStage,
    WindowsVerificationFailureCategory? FailureCategory,
    int? SafeHttpStatus)
{
    public bool IsStructurallyValid =>
        SchemaVersion == 1 &&
        RequestCount == 1 &&
        ToolCallCount is >= 0 and <= 32 &&
        ExpiresAtUtc > ObservedAtUtc &&
        DurationMilliseconds >= 0 &&
        IsSha256(ProviderSha256) &&
        IsSha256(ConfigurationSha256) &&
        IsSha256(ExecutableSha256) &&
        IsSha256(EventStructureSha256) &&
        SafeHttpStatus is null or >= 100 and <= 599 &&
        (Passed
            ? FailureStage is null && FailureCategory is null
            : FailureStage is not null && FailureCategory is not null);

    private static bool IsSha256(string value) =>
        value.Length == 64 && value.All(character =>
            char.IsAsciiHexDigit(character) &&
            character is not (>= 'A' and <= 'F'));
}

public sealed record WindowsVerificationOutcome(
    WindowsVerificationStage Stage,
    string Conclusion,
    string PrimaryAction,
    WindowsVerificationReceipt? Receipt,
    WindowsVerificationFailurePresentation? Failure);

public sealed record WindowsVerificationRunRequest(
    WindowsVerificationStep Step,
    string ExecutablePath,
    string CandidateKind,
    string WorkspacePath,
    string Marker,
    string? CredentialEnvironmentName,
    byte[]? CredentialUtf8,
    TimeSpan Timeout,
    int MaximumCapturedBytesPerStream);

public sealed record WindowsVerificationTraceAnalysis(
    bool Passed,
    WindowsVerificationFailureStage? FailureStage,
    string EventStructureSha256,
    int ToolCallCount);

public sealed record WindowsVerificationRunResult(
    WindowsVerificationTraceAnalysis Trace,
    long DurationMilliseconds,
    WindowsVerificationFailureCategory? FailureCategory,
    int? SafeHttpStatus);

public interface IWindowsVerificationRunner
{
    Task<WindowsVerificationRunResult> RunAsync(
        WindowsVerificationRunRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class WindowsVerificationConsentRequiredException()
    : InvalidOperationException(
        "User confirmation is required before a network request that may cost money.");

public sealed class WindowsVerificationPlanExpiredException()
    : InvalidOperationException(
        "Verification confirmation expired; prepare a fresh confirmation.");

public sealed class WindowsVerificationBusyException()
    : InvalidOperationException(
        "Another verification is already running; no second request was started.");

internal sealed record WindowsVerificationConfiguration(
    string Path,
    string Sha256,
    WindowsCodexAccessKind AccessKind,
    string ProviderId,
    string ProviderSha256,
    string? CredentialTarget,
    string? CredentialEnvironmentName);

internal static class WindowsVerificationConfigurationReader
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static WindowsVerificationConfiguration Read(
        string path,
        bool allowMissingOfficial = false)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
        {
            throw new IOException("Configuration path is not a fully qualified local path.");
        }
        var fullPath = Path.GetFullPath(path);
        if (Directory.Exists(fullPath))
        {
            throw new IOException("Configuration path points to a directory.");
        }
        var file = new FileInfo(fullPath);
        file.Refresh();
        if (!file.Exists && allowMissingOfficial)
        {
            return new WindowsVerificationConfiguration(
                fullPath,
                HashBytes(ReadOnlySpan<byte>.Empty),
                WindowsCodexAccessKind.Official,
                "openai",
                HashUtf8("openai"),
                null,
                null);
        }
        if (!file.Exists ||
            (file.Attributes & (FileAttributes.Directory |
                                FileAttributes.ReparsePoint |
                                FileAttributes.Offline)) != 0 ||
            file.Length < 0 ||
            file.Length > WindowsProgressiveVerificationContract.MaximumConfigurationBytes)
        {
            throw new IOException("Configuration is missing, unsafe, or exceeds the byte limit.");
        }
        var bytes = File.ReadAllBytes(fullPath);
        if (bytes.Length > WindowsProgressiveVerificationContract.MaximumConfigurationBytes)
        {
            throw new IOException("Configuration grew beyond the byte limit.");
        }
        var source = StrictUtf8.GetString(bytes).TrimStart('\uFEFF');
        if (WindowsConfigurationTransactionService.ContainsSensitiveAssignment(source))
        {
            throw new IOException(
                "Configuration embeds a sensitive value; verification is blocked until it uses env_key.");
        }

        var parser = new MinimalVerificationToml(source);
        var providerId = parser.RootValue("model_provider") ?? "openai";
        ValidateIdentifier(providerId, "model_provider");
        var accessKind = providerId.Equals(
            "openai",
            StringComparison.OrdinalIgnoreCase)
            ? WindowsCodexAccessKind.Official
            : WindowsCodexAccessKind.Relay;
        var providerSha256 = HashUtf8(providerId);
        string? environmentName = null;
        string? credentialTarget = null;
        if (accessKind == WindowsCodexAccessKind.Relay)
        {
            environmentName = parser.ProviderValue(providerId, "env_key") ??
                throw new IOException(
                    "Relay configuration does not contain one safe env_key reference.");
            WindowsCodexProcessController.ValidateEnvironmentName(environmentName);
            credentialTarget =
                WindowsNativeTransactionContract.CredentialTargetPrefix +
                providerSha256[..32];
            WindowsCredentialManager.ValidateTargetName(credentialTarget);
        }
        return new WindowsVerificationConfiguration(
            fullPath,
            HashBytes(bytes),
            accessKind,
            providerId,
            providerSha256,
            credentialTarget,
            environmentName);
    }

    public static string HashFile(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 64 * 1024,
            options: FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    public static string HashUtf8(string value) =>
        HashBytes(StrictUtf8.GetBytes(value));

    public static string HashBytes(ReadOnlySpan<byte> value) =>
        Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

    private static void ValidateIdentifier(string value, string field)
    {
        if (value.Length is < 1 or > 128 ||
            !value.All(character =>
                char.IsAsciiLetterOrDigit(character) ||
                character is '.' or '_' or '-'))
        {
            throw new IOException($"{field} is unsafe or ambiguous.");
        }
    }

    private sealed class MinimalVerificationToml
    {
        private readonly Dictionary<string, string> _root =
            new(StringComparer.Ordinal);
        private readonly Dictionary<string, Dictionary<string, string>> _providers =
            new(StringComparer.Ordinal);

        public MinimalVerificationToml(string source)
        {
            var inRoot = true;
            string? providerSection = null;
            foreach (var rawLine in source
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
                    inRoot = false;
                    providerSection = ParseProviderSection(line);
                    continue;
                }
                var equals = IndexOfEqualsOutsideQuotes(line);
                if (equals <= 0)
                {
                    continue;
                }
                var key = ParseBareOrQuoted(line[..equals]);
                var value = ParseQuoted(line[(equals + 1)..]);
                if (key is null || value is null)
                {
                    continue;
                }
                Dictionary<string, string> target;
                if (inRoot)
                {
                    target = _root;
                }
                else if (providerSection is not null)
                {
                    target = Provider(providerSection);
                }
                else
                {
                    continue;
                }
                if (!target.TryAdd(key, value))
                {
                    throw new IOException("Configuration contains a duplicate verification field.");
                }
            }
        }

        public string? RootValue(string key) =>
            _root.GetValueOrDefault(key);

        public string? ProviderValue(string provider, string key) =>
            _providers.TryGetValue(provider, out var values)
                ? values.GetValueOrDefault(key)
                : null;

        private Dictionary<string, string> Provider(string provider) =>
            _providers.TryGetValue(provider, out var existing)
                ? existing
                : _providers[provider] = new Dictionary<string, string>(
                    StringComparer.Ordinal);

        private static string? ParseProviderSection(string line)
        {
            if (!line.EndsWith(']'))
            {
                return null;
            }
            var inner = line[1..^1].Trim();
            const string prefix = "model_providers.";
            if (!inner.StartsWith(prefix, StringComparison.Ordinal))
            {
                return null;
            }
            return ParseBareOrQuoted(inner[prefix.Length..]);
        }

        private static string? ParseBareOrQuoted(string raw)
        {
            var value = raw.Trim();
            if (value.Length >= 2 &&
                ((value[0] == '"' && value[^1] == '"') ||
                 (value[0] == '\'' && value[^1] == '\'')))
            {
                value = value[1..^1];
            }
            return value.Length is > 0 and <= 128 &&
                value.All(character =>
                    char.IsAsciiLetterOrDigit(character) ||
                    character is '.' or '_' or '-')
                ? value
                : null;
        }

        private static string? ParseQuoted(string raw)
        {
            var value = raw.Trim();
            if (value.Length < 2 ||
                !((value[0] == '"' && value[^1] == '"') ||
                  (value[0] == '\'' && value[^1] == '\'')))
            {
                return null;
            }
            var result = value[1..^1];
            return result.Contains('\0') ? null : result;
        }

        private static string StripComment(string source)
        {
            char quote = '\0';
            var escaped = false;
            for (var index = 0; index < source.Length; index++)
            {
                var character = source[index];
                if (quote != '\0')
                {
                    if (quote == '"' && character == '\\' && !escaped)
                    {
                        escaped = true;
                        continue;
                    }
                    if (character == quote && !escaped)
                    {
                        quote = '\0';
                    }
                    escaped = false;
                    continue;
                }
                if (character is '"' or '\'')
                {
                    quote = character;
                }
                else if (character == '#')
                {
                    return source[..index];
                }
            }
            return source;
        }

        private static int IndexOfEqualsOutsideQuotes(string source)
        {
            char quote = '\0';
            var escaped = false;
            for (var index = 0; index < source.Length; index++)
            {
                var character = source[index];
                if (quote != '\0')
                {
                    if (quote == '"' && character == '\\' && !escaped)
                    {
                        escaped = true;
                        continue;
                    }
                    if (character == quote && !escaped)
                    {
                        quote = '\0';
                    }
                    escaped = false;
                    continue;
                }
                if (character is '"' or '\'')
                {
                    quote = character;
                }
                else if (character == '=')
                {
                    return index;
                }
            }
            return -1;
        }
    }
}

public static class WindowsVerificationTraceAnalyzer
{
    public static WindowsVerificationTraceAnalysis Analyze(
        string standardOutput,
        string marker,
        int exitCode,
        WindowsVerificationStep step)
    {
        var turnStarted = false;
        var toolStarted = false;
        var toolCompleted = false;
        var toolOutputObserved = false;
        var continuationObserved = false;
        var finalResponseObserved = false;
        var turnCompleted = false;
        var toolCallCount = 0;
        var structure = new List<string>();

        foreach (var rawLine in standardOutput.Split(
                     ['\r', '\n'],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                using var document = JsonDocument.Parse(rawLine);
                var root = document.RootElement;
                var eventType = StringValue(root, "type") ?? "unknown";
                var item = root.TryGetProperty("item", out var observedItem) &&
                           observedItem.ValueKind == JsonValueKind.Object
                    ? observedItem
                    : default;
                var itemType = item.ValueKind == JsonValueKind.Object
                    ? StringValue(item, "type") ?? "none"
                    : "none";
                var status = item.ValueKind == JsonValueKind.Object
                    ? StringValue(item, "status") ?? "none"
                    : "none";
                var itemExit = item.ValueKind == JsonValueKind.Object &&
                               item.TryGetProperty("exit_code", out var exitElement) &&
                               exitElement.TryGetInt32(out var parsedExit)
                    ? parsedExit
                    : (int?)null;
                structure.Add(
                    $"{eventType}|{itemType}|{status}|" +
                    (itemExit is null ? "none" : itemExit == 0 ? "zero" : "nonzero"));

                if (eventType == "turn.started")
                {
                    turnStarted = true;
                }
                if (itemType == "command_execution")
                {
                    if (eventType == "item.started" && turnStarted)
                    {
                        toolStarted = true;
                        toolCallCount += 1;
                    }
                    if (eventType == "item.completed" &&
                        toolStarted && itemExit == 0)
                    {
                        toolCompleted = true;
                        toolOutputObserved = ContainsMarker(item, marker);
                    }
                }
                if (eventType == "item.completed" &&
                    itemType == "agent_message" &&
                    item.ValueKind == JsonValueKind.Object &&
                    StringValue(item, "text") is { } response)
                {
                    if (step == WindowsVerificationStep.BasicConnection)
                    {
                        finalResponseObserved =
                            response.Trim().Equals(marker, StringComparison.Ordinal);
                    }
                    else if (toolCompleted && toolOutputObserved)
                    {
                        continuationObserved = true;
                        finalResponseObserved =
                            response.Trim().Equals(marker, StringComparison.Ordinal);
                    }
                }
                if (eventType == "turn.completed" && finalResponseObserved)
                {
                    turnCompleted = true;
                }
            }
            catch (JsonException)
            {
                structure.Add("invalid-json");
            }
        }

        WindowsVerificationFailureStage? failure;
        if (exitCode != 0 || !turnStarted)
        {
            failure = WindowsVerificationFailureStage.InitialResponse;
        }
        else if (step == WindowsVerificationStep.RealTask && !toolStarted)
        {
            failure = WindowsVerificationFailureStage.ToolCall;
        }
        else if (step == WindowsVerificationStep.RealTask &&
                 (!toolCompleted || !toolOutputObserved))
        {
            failure = WindowsVerificationFailureStage.ToolExecution;
        }
        else if (step == WindowsVerificationStep.RealTask && !continuationObserved)
        {
            failure = WindowsVerificationFailureStage.Continuation;
        }
        else if (!finalResponseObserved || !turnCompleted)
        {
            failure = WindowsVerificationFailureStage.FinalResponse;
        }
        else
        {
            failure = null;
        }
        return new WindowsVerificationTraceAnalysis(
            failure is null,
            failure,
            WindowsVerificationConfigurationReader.HashUtf8(
                string.Join('\n', structure)),
            toolCallCount);
    }

    private static string? StringValue(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static bool ContainsMarker(JsonElement item, string marker)
    {
        foreach (var name in new[] { "aggregated_output", "output", "stdout" })
        {
            if (item.TryGetProperty(name, out var value) &&
                JsonContains(value, marker))
            {
                return true;
            }
        }
        return false;
    }

    private static bool JsonContains(JsonElement value, string marker)
    {
        return value.ValueKind switch
        {
            JsonValueKind.String =>
                value.GetString()?.Contains(marker, StringComparison.Ordinal) == true,
            JsonValueKind.Array =>
                value.EnumerateArray().Any(item => JsonContains(item, marker)),
            JsonValueKind.Object =>
                value.EnumerateObject().Any(property =>
                    JsonContains(property.Value, marker)),
            _ => false,
        };
    }
}

public static class WindowsVerificationFailureProjector
{
    public static WindowsVerificationFailurePresentation Project(
        WindowsVerificationStep step,
        WindowsVerificationFailureStage stage,
        WindowsVerificationFailureCategory category,
        int? safeHttpStatus = null,
        WindowsCodexAccessKind accessKind = WindowsCodexAccessKind.Official)
    {
        var status = safeHttpStatus is >= 100 and <= 599
            ? $"（HTTP {safeHttpStatus}）"
            : string.Empty;
        var (conclusion, explanation, action) = category switch
        {
            WindowsVerificationFailureCategory.Authentication =>
                (step == WindowsVerificationStep.BasicConnection
                    ? "当前认证未通过"
                    : "真实任务认证未通过",
                 "认证未通过" + status + "。官方接入先完成 Codex 登录；中转接入核对已保存凭据。",
                 accessKind == WindowsCodexAccessKind.Official
                    ? WindowsVerificationPrimaryAction.OpenCodexLogin
                    : WindowsVerificationPrimaryAction.ReviewRelayProfile),
            WindowsVerificationFailureCategory.Permission =>
                ("当前访问受限",
                 "服务拒绝请求" + status + "。可能是账号、模型或地区权限，不能据此断定 API Key 错误。",
                 accessKind == WindowsCodexAccessKind.Relay
                    ? WindowsVerificationPrimaryAction.ReviewRelayProfile
                    : WindowsVerificationPrimaryAction.OpenAdvancedDiagnostics),
            WindowsVerificationFailureCategory.QuotaExhausted =>
                ("当前额度不足",
                 "发现明确余额或额度不足信号" + status + "；无需反复验证。",
                 WindowsVerificationPrimaryAction.ReviewQuota),
            WindowsVerificationFailureCategory.RateLimited =>
                ("请求暂时受限",
                 "请求频率受限" + status + "；助手不会自动重试或切换接入。",
                 WindowsVerificationPrimaryAction.RetryLater),
            WindowsVerificationFailureCategory.EndpointOrModel =>
                ("地址或模型不可用",
                 "当前地址、协议路径或模型没有形成可用结果" + status + "。",
                 accessKind == WindowsCodexAccessKind.Relay
                    ? WindowsVerificationPrimaryAction.ReviewRelayProfile
                    : WindowsVerificationPrimaryAction.OpenAdvancedDiagnostics),
            WindowsVerificationFailureCategory.Dns =>
                ("域名无法解析",
                 "先核对中转地址；地址无误时检查 DNS 或网络。",
                 WindowsVerificationPrimaryAction.ReviewDnsAndAddress),
            WindowsVerificationFailureCategory.Tls =>
                ("安全连接未通过",
                 "TLS 或证书验证未通过；助手不会绕过证书验证。",
                 WindowsVerificationPrimaryAction.ReviewTlsAndProxy),
            WindowsVerificationFailureCategory.Timeout =>
                ("验证超时",
                 "验证未在时限内完成；已请求停止本次受控子进程，结果不采用且不会自动重试。",
                 WindowsVerificationPrimaryAction.ReviewOwnedCodexProcess),
            WindowsVerificationFailureCategory.NetworkUnavailable =>
                ("网络未连通",
                 "网络或代理连接未完成。核对连接后再验证。",
                 WindowsVerificationPrimaryAction.CheckNetwork),
            WindowsVerificationFailureCategory.ConfigurationDrift =>
                ("验证期间配置发生变化",
                 "本次结果已作废，旧证据不会被采用。",
                 WindowsVerificationPrimaryAction.StopOtherConfigurationTools),
            WindowsVerificationFailureCategory.ExecutableDrift =>
                ("Codex 程序发生变化",
                 "启动前后程序身份不一致；本次结果已作废。",
                 WindowsVerificationPrimaryAction.RefreshState),
            WindowsVerificationFailureCategory.CredentialUnavailable =>
                ("中转凭据不可用",
                 "没有读取到与当前中转匹配的 Windows 凭据。",
                 WindowsVerificationPrimaryAction.ReviewRelayProfile),
            WindowsVerificationFailureCategory.ToolPermission =>
                ("本机工具没有完成",
                 "检查 Codex 工具权限；助手不会扩大权限或绕过审批。",
                 WindowsVerificationPrimaryAction.ReviewToolPermission),
            WindowsVerificationFailureCategory.ResponsesCompatibility =>
                ("真实任务闭环不完整",
                 "工具调用、工具结果续接或最终回复没有全部完成。",
                 WindowsVerificationPrimaryAction.ReviewResponsesCompatibility),
            WindowsVerificationFailureCategory.Cleanup =>
                ("临时验证目录未能清理",
                 "验证结果不采用；关闭助手后再重开。",
                 WindowsVerificationPrimaryAction.RestartAssistant),
            WindowsVerificationFailureCategory.InvalidResponse =>
                ("响应格式不可用",
                 "服务已响应，但没有形成受支持的结构化结果。",
                 WindowsVerificationPrimaryAction.ReviewResponsesCompatibility),
            _ =>
                ("验证没有完成",
                 "失败原因未能安全分类；当前设置保持不变。",
                 WindowsVerificationPrimaryAction.OpenAdvancedDiagnostics),
        };
        var evidence = new List<string>
        {
            "步骤：" + (step == WindowsVerificationStep.BasicConnection
                ? "基础连接"
                : "真实任务"),
            "阶段：" + ToToken(stage),
            "类别：" + ToToken(category),
        };
        if (safeHttpStatus is >= 100 and <= 599)
        {
            evidence.Add($"HTTP：{safeHttpStatus}");
        }
        return new WindowsVerificationFailurePresentation(
            conclusion,
            explanation,
            action,
            evidence);
    }

    private static string ToToken<T>(T value) where T : struct, Enum =>
        Regex.Replace(value.ToString(), "([a-z0-9])([A-Z])", "$1-$2")
            .ToLowerInvariant();
}

public sealed class WindowsCodexCliVerificationRunner : IWindowsVerificationRunner
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public async Task<WindowsVerificationRunResult> RunAsync(
        WindowsVerificationRunRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        WindowsNativeGuard.RequireWindows("Windows Codex verification");
        ValidateRequest(request);
        var startInfo = BuildStartInfo(request);
        string? credentialString = null;
        if (request.CredentialUtf8 is not null)
        {
            credentialString = StrictUtf8.GetString(request.CredentialUtf8);
            startInfo.Environment[request.CredentialEnvironmentName!] =
                credentialString;
        }

        using var process = new Process { StartInfo = startInfo };
        var standardOutput = new StringBuilder();
        var standardError = new StringBuilder();
        var outputBytes = 0;
        var errorBytes = 0;
        var outputExceeded = false;
        var errorExceeded = false;
        var outputGate = new object();
        var errorGate = new object();
        process.OutputDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null)
            {
                return;
            }
            lock (outputGate)
            {
                outputBytes += Encoding.UTF8.GetByteCount(eventArgs.Data) + 1;
                if (outputBytes > request.MaximumCapturedBytesPerStream)
                {
                    outputExceeded = true;
                    TryKillOwnedTree(process);
                    return;
                }
                standardOutput.AppendLine(eventArgs.Data);
            }
        };
        process.ErrorDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null)
            {
                return;
            }
            lock (errorGate)
            {
                errorBytes += Encoding.UTF8.GetByteCount(eventArgs.Data) + 1;
                if (errorBytes > request.MaximumCapturedBytesPerStream)
                {
                    errorExceeded = true;
                    TryKillOwnedTree(process);
                    return;
                }
                standardError.AppendLine(eventArgs.Data);
            }
        };

        var stopwatch = Stopwatch.StartNew();
        try
        {
            if (!process.Start())
            {
                return FailedWithoutTrace(
                    stopwatch,
                    WindowsVerificationFailureStage.Preparation,
                    WindowsVerificationFailureCategory.Unknown,
                    "process-start-false");
            }
            if (request.CredentialUtf8 is not null)
            {
                CryptographicOperations.ZeroMemory(request.CredentialUtf8);
            }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
            timeout.CancelAfter(request.Timeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token);
                process.WaitForExit();
            }
            catch (OperationCanceledException) when (
                !cancellationToken.IsCancellationRequested)
            {
                var terminated = TryKillOwnedTree(process);
                if (terminated)
                {
                    process.WaitForExit();
                }
                return FailedWithoutTrace(
                    stopwatch,
                    WindowsVerificationFailureStage.Timeout,
                    WindowsVerificationFailureCategory.Timeout,
                    terminated
                        ? "timeout-terminated"
                        : "timeout-termination-unverified");
            }
            catch (OperationCanceledException)
            {
                if (TryKillOwnedTree(process))
                {
                    process.WaitForExit();
                }
                throw;
            }

            string output;
            string error;
            bool outputLimit;
            bool errorLimit;
            lock (outputGate)
            {
                output = standardOutput.ToString();
                outputLimit = outputExceeded;
            }
            lock (errorGate)
            {
                error = standardError.ToString();
                errorLimit = errorExceeded;
            }
            if (outputLimit || errorLimit)
            {
                return FailedWithoutTrace(
                    stopwatch,
                    WindowsVerificationFailureStage.InitialResponse,
                    WindowsVerificationFailureCategory.InvalidResponse,
                    "output-limit");
            }
            var trace = WindowsVerificationTraceAnalyzer.Analyze(
                output,
                request.Marker,
                process.ExitCode,
                request.Step);
            (WindowsVerificationFailureCategory? category, int? httpStatus) =
                trace.Passed
                ? (null, null)
                : ClassifyFailure(output, error, trace.FailureStage);
            return new WindowsVerificationRunResult(
                trace,
                stopwatch.ElapsedMilliseconds,
                category,
                httpStatus);
        }
        catch (Exception error) when (
            error is System.ComponentModel.Win32Exception or
            InvalidOperationException or
            IOException or
            UnauthorizedAccessException or
            DecoderFallbackException)
        {
            TryKillOwnedTree(process);
            return FailedWithoutTrace(
                stopwatch,
                WindowsVerificationFailureStage.Preparation,
                WindowsVerificationFailureCategory.Unknown,
                "process-error");
        }
        finally
        {
            if (request.CredentialUtf8 is not null)
            {
                CryptographicOperations.ZeroMemory(request.CredentialUtf8);
            }
            if (request.CredentialEnvironmentName is not null)
            {
                startInfo.Environment.Remove(request.CredentialEnvironmentName);
            }
            credentialString = null;
        }
    }

    private static ProcessStartInfo BuildStartInfo(
        WindowsVerificationRunRequest request)
    {
        var arguments = VerificationArguments(request);
        var extension = Path.GetExtension(request.ExecutablePath);
        ProcessStartInfo startInfo;
        if (extension.Equals(".exe", StringComparison.OrdinalIgnoreCase))
        {
            startInfo = BaseStartInfo(request.ExecutablePath, request.WorkspacePath);
            foreach (var argument in arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
        }
        else if (extension.Equals(".ps1", StringComparison.OrdinalIgnoreCase))
        {
            var powershell = Path.Combine(
                Environment.SystemDirectory,
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            startInfo = BaseStartInfo(powershell, request.WorkspacePath);
            foreach (var argument in new[]
                     {
                         "-NoLogo",
                         "-NoProfile",
                         "-NonInteractive",
                         "-ExecutionPolicy",
                         "Bypass",
                         "-File",
                         request.ExecutablePath,
                     }.Concat(arguments))
            {
                startInfo.ArgumentList.Add(argument);
            }
        }
        else
        {
            var commandInterpreter = Environment.GetEnvironmentVariable("ComSpec") ??
                Path.Combine(Environment.SystemDirectory, "cmd.exe");
            startInfo = BaseStartInfo(commandInterpreter, request.WorkspacePath);
            startInfo.ArgumentList.Add("/d");
            startInfo.ArgumentList.Add("/s");
            startInfo.ArgumentList.Add("/c");
            startInfo.ArgumentList.Add(BuildCmdCommand(
                request.ExecutablePath,
                arguments));
        }
        return startInfo;
    }

    private static ProcessStartInfo BaseStartInfo(
        string executable,
        string workspace)
    {
        return new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workspace,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
    }

    private static IReadOnlyList<string> VerificationArguments(
        WindowsVerificationRunRequest request)
    {
        var prompt = request.Step == WindowsVerificationStep.BasicConnection
            ? $"Reply exactly {request.Marker}. Do not call tools."
            : $"Use the shell tool to write {request.Marker} to .ai-access-agent-loop, then use the shell tool to read that file. Only after the tool output is returned, reply exactly {request.Marker}. Do not inspect any other path.";
        return new[]
        {
            "exec",
            "-c",
            "mcp_servers={}",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "workspace-write",
            "--color",
            "never",
            "--json",
            "-C",
            request.WorkspacePath,
            prompt,
        };
    }

    private static string BuildCmdCommand(
        string executable,
        IReadOnlyList<string> arguments)
    {
        static void RequireCmdSafe(string value)
        {
            if (value.Any(character => "\r\n\0&|<>^%!".Contains(character)))
            {
                throw new InvalidOperationException(
                    "cmd shim path or argument contains an unsafe shell character.");
            }
        }
        static string Quote(string value)
        {
            RequireCmdSafe(value);
            return "\"" + value.Replace("\"", "\"\"") + "\"";
        }

        return string.Join(' ',
            new[] { Quote(executable) }.Concat(arguments.Select(Quote)));
    }

    private static void ValidateRequest(WindowsVerificationRunRequest request)
    {
        if (request.Timeout <= TimeSpan.Zero ||
            request.Timeout > TimeSpan.FromMinutes(2) ||
            request.MaximumCapturedBytesPerStream is < 1024 or >
                WindowsProgressiveVerificationContract.MaximumCapturedBytesPerStream ||
            request.Marker.Length is < 16 or > 96 ||
            !request.Marker.All(character =>
                char.IsAsciiLetterOrDigit(character) || character == '_'))
        {
            throw new ArgumentException("Verification request boundary is invalid.");
        }
        var executable = new FileInfo(Path.GetFullPath(request.ExecutablePath));
        executable.Refresh();
        if (!executable.Exists ||
            (executable.Attributes & (FileAttributes.Directory |
                                      FileAttributes.ReparsePoint |
                                      FileAttributes.Offline)) != 0 ||
            !new[] { ".exe", ".cmd", ".ps1" }.Contains(
                executable.Extension,
                StringComparer.OrdinalIgnoreCase))
        {
            throw new IOException("Codex executable path is unsafe or unsupported.");
        }
        var workspace = new DirectoryInfo(Path.GetFullPath(request.WorkspacePath));
        workspace.Refresh();
        if (!workspace.Exists ||
            (workspace.Attributes & (FileAttributes.ReparsePoint |
                                     FileAttributes.Offline)) != 0)
        {
            throw new IOException("Verification workspace is unsafe.");
        }
        if ((request.CredentialUtf8 is null) !=
            (request.CredentialEnvironmentName is null))
        {
            throw new ArgumentException(
                "Relay credential and environment name must be supplied together.");
        }
        if (request.CredentialEnvironmentName is not null)
        {
            WindowsCodexProcessController.ValidateEnvironmentName(
                request.CredentialEnvironmentName);
        }
    }

    private static (WindowsVerificationFailureCategory?, int?) ClassifyFailure(
        string output,
        string error,
        WindowsVerificationFailureStage? stage)
    {
        var combined = (output + "\n" + error).ToLowerInvariant();
        var httpStatus = SafeHttpStatus(combined);
        if (combined.Contains("insufficient_quota", StringComparison.Ordinal) ||
            combined.Contains("quota exceeded", StringComparison.Ordinal) ||
            combined.Contains("credit balance", StringComparison.Ordinal) ||
            combined.Contains("余额不足", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.QuotaExhausted, httpStatus);
        }
        if (httpStatus == 429 ||
            combined.Contains("rate limit", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.RateLimited, httpStatus);
        }
        if (httpStatus == 401 ||
            combined.Contains("login required", StringComparison.Ordinal) ||
            combined.Contains("not logged in", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.Authentication, httpStatus);
        }
        if (httpStatus == 403)
        {
            return (WindowsVerificationFailureCategory.Permission, httpStatus);
        }
        if (combined.Contains("name or service not known", StringComparison.Ordinal) ||
            combined.Contains("no such host", StringComparison.Ordinal) ||
            combined.Contains("dns", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.Dns, httpStatus);
        }
        if (combined.Contains("certificate", StringComparison.Ordinal) ||
            combined.Contains("tls", StringComparison.Ordinal) ||
            combined.Contains("ssl", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.Tls, httpStatus);
        }
        if (combined.Contains("timed out", StringComparison.Ordinal) ||
            combined.Contains("timeout", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.Timeout, httpStatus);
        }
        if (httpStatus is 404 or 405 ||
            combined.Contains("model not found", StringComparison.Ordinal))
        {
            return (WindowsVerificationFailureCategory.EndpointOrModel, httpStatus);
        }
        return stage switch
        {
            WindowsVerificationFailureStage.ToolExecution =>
                (WindowsVerificationFailureCategory.ToolPermission, httpStatus),
            WindowsVerificationFailureStage.ToolCall or
            WindowsVerificationFailureStage.Continuation or
            WindowsVerificationFailureStage.FinalResponse =>
                (WindowsVerificationFailureCategory.ResponsesCompatibility, httpStatus),
            _ => (WindowsVerificationFailureCategory.InvalidResponse, httpStatus),
        };
    }

    private static int? SafeHttpStatus(string source)
    {
        var match = Regex.Match(
            source,
            @"(?:http(?:/\d(?:\.\d)?)?\s*|status(?:\s+code)?\s*[:=]?\s*)([1-5]\d{2})",
            RegexOptions.CultureInvariant);
        return match.Success && int.TryParse(match.Groups[1].Value, out var status)
            ? status
            : null;
    }

    private static WindowsVerificationRunResult FailedWithoutTrace(
        Stopwatch stopwatch,
        WindowsVerificationFailureStage stage,
        WindowsVerificationFailureCategory category,
        string structure)
    {
        return new WindowsVerificationRunResult(
            new WindowsVerificationTraceAnalysis(
                false,
                stage,
                WindowsVerificationConfigurationReader.HashUtf8(structure),
                0),
            stopwatch.ElapsedMilliseconds,
            category,
            null);
    }

    private static bool TryKillOwnedTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
            return process.HasExited || process.WaitForExit(5_000);
        }
        catch (Exception error) when (
            error is InvalidOperationException or
            NotSupportedException or
            System.ComponentModel.Win32Exception)
        {
            // Failure remains unverified; never kill unrelated processes.
            return false;
        }
    }
}

public sealed class WindowsProgressiveVerificationService
{
    private readonly IWindowsVerificationRunner _runner;
    private readonly IWindowsCredentialManager _credentialManager;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Func<string> _sandboxFactory;
    private readonly Func<string, bool> _sandboxCleanup;
    private readonly SemaphoreSlim _operation = new(1, 1);
    private WindowsVerificationReceipt? _basicReceipt;

    public WindowsProgressiveVerificationService(
        IWindowsVerificationRunner? runner = null,
        IWindowsCredentialManager? credentialManager = null,
        Func<DateTimeOffset>? clock = null,
        Func<string>? sandboxFactory = null,
        Func<string, bool>? sandboxCleanup = null)
    {
        _runner = runner ?? new WindowsCodexCliVerificationRunner();
        _credentialManager = credentialManager ?? new WindowsCredentialManager();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _sandboxFactory = sandboxFactory ?? CreateSandbox;
        _sandboxCleanup = sandboxCleanup ?? TryDeleteSandbox;
    }

    public WindowsVerificationConsentPlan Prepare(
        WindowsCodexReadinessSnapshot snapshot,
        WindowsVerificationStep step)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (snapshot.Installation.State != WindowsCodexInstallationState.Found ||
            snapshot.Access.Kind == WindowsCodexAccessKind.Blocked ||
            string.IsNullOrWhiteSpace(snapshot.Installation.ExecutablePath) ||
            (snapshot.Access.Kind == WindowsCodexAccessKind.Relay &&
             !snapshot.ConfigurationPreview.Exists))
        {
            throw new InvalidOperationException(
                "Complete read-only Codex and configuration recognition before verification.");
        }
        var configuration = WindowsVerificationConfigurationReader.Read(
            snapshot.ConfigurationPreview.Path,
            allowMissingOfficial:
                snapshot.Access.Kind == WindowsCodexAccessKind.Official);
        if (configuration.AccessKind != snapshot.Access.Kind)
        {
            throw new InvalidOperationException(
                "Current access changed after read-only recognition.");
        }
        var executablePath = Path.GetFullPath(
            snapshot.Installation.ExecutablePath);
        var executableSha256 = WindowsVerificationConfigurationReader.HashFile(
            executablePath);
        if (step == WindowsVerificationStep.RealTask &&
            !BasicReceiptMatches(
                configuration,
                executableSha256,
                _clock()))
        {
            throw new InvalidOperationException(
                "Complete a matching basic connection check before real-task verification.");
        }
        var now = _clock();
        return new WindowsVerificationConsentPlan(
            Guid.NewGuid().ToString("N"),
            step,
            configuration.AccessKind,
            configuration.Path,
            configuration.Sha256,
            executablePath,
            executableSha256,
            configuration.ProviderSha256,
            configuration.CredentialTarget,
            configuration.CredentialEnvironmentName,
            now,
            now + WindowsProgressiveVerificationContract.ConsentLifetime,
            step == WindowsVerificationStep.BasicConnection
                ? "确认检测基础连接？"
                : "确认验证真实任务？",
            step == WindowsVerificationStep.BasicConnection
                ? "将启动一次最小 Codex 请求，可能产生一次 API 费用；不会自动重试或切换接入。"
                : "将运行一次隔离工具任务，可能产生一次 API 费用；会检查工具调用、结果续接和最终回复。",
            MayCostMoney: true);
    }

    public async Task<WindowsVerificationOutcome> ExecuteAsync(
        WindowsVerificationConsentPlan plan,
        bool userConfirmed,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (!userConfirmed)
        {
            throw new WindowsVerificationConsentRequiredException();
        }
        if (_clock() > plan.ExpiresAtUtc)
        {
            throw new WindowsVerificationPlanExpiredException();
        }
        if (!await _operation.WaitAsync(0, cancellationToken))
        {
            throw new WindowsVerificationBusyException();
        }

        byte[]? credential = null;
        string? sandbox = null;
        try
        {
            var configuration = WindowsVerificationConfigurationReader.Read(
                plan.ConfigurationPath,
                allowMissingOfficial:
                    plan.AccessKind == WindowsCodexAccessKind.Official);
            var executableSha256 = WindowsVerificationConfigurationReader.HashFile(
                plan.ExecutablePath);
            if (!MatchesPlan(plan, configuration, executableSha256))
            {
                return FailureWithoutRequest(
                    plan.Step,
                    WindowsVerificationFailureStage.ConfigurationChanged,
                    configuration.Sha256 == plan.ConfigurationSha256
                        ? WindowsVerificationFailureCategory.ExecutableDrift
                        : WindowsVerificationFailureCategory.ConfigurationDrift);
            }
            if (plan.Step == WindowsVerificationStep.RealTask &&
                !BasicReceiptMatches(configuration, executableSha256, _clock()))
            {
                return FailureWithoutRequest(
                    plan.Step,
                    WindowsVerificationFailureStage.Preparation,
                    WindowsVerificationFailureCategory.ConfigurationDrift);
            }

            if (configuration.AccessKind == WindowsCodexAccessKind.Relay)
            {
                credential = _credentialManager.ReadGenericCredential(
                    configuration.CredentialTarget!);
                if (credential is null || credential.Length == 0)
                {
                    return FailureWithoutRequest(
                        plan.Step,
                        WindowsVerificationFailureStage.Login,
                        WindowsVerificationFailureCategory.CredentialUnavailable);
                }
            }

            sandbox = _sandboxFactory();
            var marker = "AI_ACCESS_WINDOWS_OK_" +
                Guid.NewGuid().ToString("N").ToUpperInvariant();
            var result = await _runner.RunAsync(
                new WindowsVerificationRunRequest(
                    plan.Step,
                    plan.ExecutablePath,
                    Path.GetFileName(plan.ExecutablePath),
                    sandbox,
                    marker,
                    configuration.CredentialEnvironmentName,
                    credential,
                    TimeSpan.FromSeconds(
                        plan.Step == WindowsVerificationStep.BasicConnection
                            ? WindowsProgressiveVerificationContract.BasicTimeoutSeconds
                            : WindowsProgressiveVerificationContract.RealTaskTimeoutSeconds),
                    WindowsProgressiveVerificationContract.MaximumCapturedBytesPerStream),
                cancellationToken);

            var currentConfiguration = WindowsVerificationConfigurationReader.Read(
                plan.ConfigurationPath,
                allowMissingOfficial:
                    plan.AccessKind == WindowsCodexAccessKind.Official);
            var currentExecutableSha256 =
                WindowsVerificationConfigurationReader.HashFile(plan.ExecutablePath);
            WindowsVerificationFailureStage? failureStage = result.Trace.FailureStage;
            WindowsVerificationFailureCategory? failureCategory =
                result.FailureCategory;
            if (currentConfiguration.Sha256 != plan.ConfigurationSha256)
            {
                failureStage = WindowsVerificationFailureStage.ConfigurationChanged;
                failureCategory = WindowsVerificationFailureCategory.ConfigurationDrift;
            }
            else if (currentExecutableSha256 != plan.ExecutableSha256)
            {
                failureStage = WindowsVerificationFailureStage.ConfigurationChanged;
                failureCategory = WindowsVerificationFailureCategory.ExecutableDrift;
            }

            if (_sandboxCleanup(sandbox))
            {
                sandbox = null;
            }
            else if (failureStage is null)
            {
                failureStage = WindowsVerificationFailureStage.Cleanup;
                failureCategory = WindowsVerificationFailureCategory.Cleanup;
            }

            var passed = result.Trace.Passed && failureStage is null;
            var observedAt = _clock();
            var receipt = new WindowsVerificationReceipt(
                1,
                plan.Step,
                passed,
                observedAt,
                observedAt + WindowsProgressiveVerificationContract.ReceiptLifetime,
                result.DurationMilliseconds,
                plan.ProviderSha256,
                plan.ConfigurationSha256,
                plan.ExecutableSha256,
                result.Trace.EventStructureSha256,
                result.Trace.ToolCallCount,
                1,
                failureStage,
                passed
                    ? null
                    : failureCategory ?? WindowsVerificationFailureCategory.Unknown,
                result.SafeHttpStatus);
            if (!receipt.IsStructurallyValid)
            {
                return FailureWithoutRequest(
                    plan.Step,
                    WindowsVerificationFailureStage.Unknown,
                    WindowsVerificationFailureCategory.Unknown);
            }
            if (passed)
            {
                if (plan.Step == WindowsVerificationStep.BasicConnection)
                {
                    _basicReceipt = receipt;
                    return new WindowsVerificationOutcome(
                        WindowsVerificationStage.NeedsRealTask,
                        "第1步已通过，尚未证明能完成真实任务",
                        "单独确认后验证真实任务",
                        receipt,
                        null);
                }
                return new WindowsVerificationOutcome(
                    WindowsVerificationStage.Ready,
                    "2/2 已完成：当前接入可完成真实工具任务",
                    "可以开始工作",
                    receipt,
                    null);
            }
            var failure = WindowsVerificationFailureProjector.Project(
                plan.Step,
                receipt.FailureStage!.Value,
                receipt.FailureCategory!.Value,
                receipt.SafeHttpStatus,
                plan.AccessKind);
            return new WindowsVerificationOutcome(
                plan.Step == WindowsVerificationStep.BasicConnection
                    ? WindowsVerificationStage.BasicFailed
                    : WindowsVerificationStage.RealTaskFailed,
                failure.Conclusion,
                PrimaryActionTitle(failure.PrimaryAction),
                receipt,
                failure);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (
            error is IOException or
            UnauthorizedAccessException or
            DecoderFallbackException or
            CryptographicException or
            InvalidOperationException or
            ArgumentException)
        {
            return FailureWithoutRequest(
                plan.Step,
                WindowsVerificationFailureStage.Preparation,
                WindowsVerificationFailureCategory.Unknown);
        }
        finally
        {
            if (credential is not null)
            {
                CryptographicOperations.ZeroMemory(credential);
            }
            if (sandbox is not null)
            {
                _sandboxCleanup(sandbox);
            }
            _operation.Release();
        }
    }

    private bool BasicReceiptMatches(
        WindowsVerificationConfiguration configuration,
        string executableSha256,
        DateTimeOffset now)
    {
        var receipt = _basicReceipt;
        return receipt is not null &&
            receipt.IsStructurallyValid &&
            receipt.Passed &&
            receipt.Step == WindowsVerificationStep.BasicConnection &&
            receipt.ExpiresAtUtc > now &&
            receipt.ProviderSha256 == configuration.ProviderSha256 &&
            receipt.ConfigurationSha256 == configuration.Sha256 &&
            receipt.ExecutableSha256 == executableSha256;
    }

    private static bool MatchesPlan(
        WindowsVerificationConsentPlan plan,
        WindowsVerificationConfiguration configuration,
        string executableSha256)
    {
        return plan.ConfigurationPath == configuration.Path &&
            plan.ConfigurationSha256 == configuration.Sha256 &&
            plan.AccessKind == configuration.AccessKind &&
            plan.ProviderSha256 == configuration.ProviderSha256 &&
            plan.CredentialTarget == configuration.CredentialTarget &&
            plan.CredentialEnvironmentName == configuration.CredentialEnvironmentName &&
            plan.ExecutableSha256 == executableSha256;
    }

    private static string CreateSandbox()
    {
        var root = Path.GetFullPath(Path.GetTempPath());
        var path = Path.Combine(
            root,
            "ai-access-windows-verification-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static bool TryDeleteSandbox(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
            return !Directory.Exists(path);
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static WindowsVerificationOutcome FailureWithoutRequest(
        WindowsVerificationStep step,
        WindowsVerificationFailureStage stage,
        WindowsVerificationFailureCategory category)
    {
        var failure = WindowsVerificationFailureProjector.Project(
            step,
            stage,
            category);
        return new WindowsVerificationOutcome(
            step == WindowsVerificationStep.BasicConnection
                ? WindowsVerificationStage.BasicFailed
                : WindowsVerificationStage.RealTaskFailed,
            failure.Conclusion,
            PrimaryActionTitle(failure.PrimaryAction),
            null,
            failure);
    }

    public static string PrimaryActionTitle(
        WindowsVerificationPrimaryAction action) => action switch
    {
        WindowsVerificationPrimaryAction.OpenCodexLogin => "打开 Codex 登录",
        WindowsVerificationPrimaryAction.ReviewRelayProfile => "检查中转资料",
        WindowsVerificationPrimaryAction.ReviewQuota => "检查余额或套餐",
        WindowsVerificationPrimaryAction.RetryLater => "稍后再验证",
        WindowsVerificationPrimaryAction.ReviewOwnedCodexProcess =>
            "检查并关闭本次 Codex 进程",
        WindowsVerificationPrimaryAction.ReviewDnsAndAddress => "检查地址与 DNS",
        WindowsVerificationPrimaryAction.ReviewTlsAndProxy => "检查 TLS 与代理",
        WindowsVerificationPrimaryAction.CheckNetwork => "检查网络或代理",
        WindowsVerificationPrimaryAction.RefreshState => "重新读取当前状态",
        WindowsVerificationPrimaryAction.UpdateAssistant => "更新助手后重试",
        WindowsVerificationPrimaryAction.ReviewToolPermission => "检查 Codex 工具权限",
        WindowsVerificationPrimaryAction.ReviewResponsesCompatibility => "检查 Responses 兼容性",
        WindowsVerificationPrimaryAction.StopOtherConfigurationTools => "停止其他配置工具",
        WindowsVerificationPrimaryAction.RestartAssistant => "重开助手",
        _ => "查看高级诊断",
    };
}
