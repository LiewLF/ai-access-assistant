using System.Security;

namespace AIAccessAssistant.Core;

public static class WindowsInclusiveReliabilityContract
{
    public const int SourceBuild = 147;
    public const int NarrowEffectiveWidth = 820;
    public const int MaximumNormalizedPathCharacters = 32760;
    public const string EvidenceLevel = "source_verified";
    public const string RuntimeState = "unverified";
}

public enum WindowsInclusiveOperation
{
    ReadinessRefresh,
    BasicVerification,
    RealTaskVerification,
    ContinuityImport,
    ContinuityRecovery,
    HistoryRefresh,
    ConfigurationTransaction,
}

public enum WindowsInclusiveFailureCode
{
    PermissionDenied,
    PathTooLong,
    PathUnavailable,
    OperationUnavailable,
}

public sealed record WindowsInclusiveFailurePresentation(
    WindowsInclusiveFailureCode Code,
    string Conclusion,
    string PrimaryAction,
    string Continuation,
    bool AutomaticRetry,
    bool AutomaticElevation,
    bool RawExceptionTextVisible,
    bool RawPathVisible,
    bool CurrentWorkPreserved);

public static class WindowsInclusiveFailureProjector
{
    public static WindowsInclusiveFailurePresentation Project(
        Exception error,
        WindowsInclusiveOperation operation)
    {
        ArgumentNullException.ThrowIfNull(error);
        var cause = Innermost(error);
        if (cause is UnauthorizedAccessException or SecurityException)
        {
            return Presentation(
                WindowsInclusiveFailureCode.PermissionDenied,
                "当前账号权限不足，操作已停止",
                PermissionAction(operation));
        }
        if (cause is PathTooLongException)
        {
            return Presentation(
                WindowsInclusiveFailureCode.PathTooLong,
                "该路径超出 Windows 可用范围，操作已停止",
                "把目标保留在本机固定磁盘；若仍失败，请移到层级更短的目录后重新执行原操作。");
        }
        if (cause is FileNotFoundException or DirectoryNotFoundException)
        {
            return Presentation(
                WindowsInclusiveFailureCode.PathUnavailable,
                "所需本机文件或目录已移动，操作已停止",
                MissingPathAction(operation));
        }
        return Presentation(
            WindowsInclusiveFailureCode.OperationUnavailable,
            "本次操作未完成",
            "保持当前接入不变，重新读取当前状态后再执行原操作。");
    }

    public static bool IsPathOrPermissionFailure(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var cause = Innermost(error);
        return cause is UnauthorizedAccessException or
            SecurityException or
            PathTooLongException or
            FileNotFoundException or
            DirectoryNotFoundException;
    }

    private static Exception Innermost(Exception error)
    {
        var current = error;
        var depth = 0;
        while (current.InnerException is not null && depth < 8)
        {
            current = current.InnerException;
            depth += 1;
        }
        return current;
    }

    private static WindowsInclusiveFailurePresentation Presentation(
        WindowsInclusiveFailureCode code,
        string conclusion,
        string primaryAction) => new(
            code,
            conclusion,
            primaryAction,
            "当前接入、Codex 配置、凭据和已有任务保持不变；助手不会自动重试或申请管理员权限。",
            AutomaticRetry: false,
            AutomaticElevation: false,
            RawExceptionTextVisible: false,
            RawPathVisible: false,
            CurrentWorkPreserved: true);

    private static string PermissionAction(
        WindowsInclusiveOperation operation) => operation switch
    {
        WindowsInclusiveOperation.ReadinessRefresh =>
            "确认当前 Windows 账号可读取 Codex 安装目录和 config.toml，然后重新刷新只读识别。",
        WindowsInclusiveOperation.BasicVerification or
        WindowsInclusiveOperation.RealTaskVerification =>
            "确认当前账号可运行 Codex 并访问本机临时目录，然后重新点击原验证步骤。",
        WindowsInclusiveOperation.ContinuityImport =>
            "确认当前账号可读取所选迁移 JSON，然后重新选择该文件。",
        WindowsInclusiveOperation.ContinuityRecovery =>
            "确认当前账号可读写 AI接入助手本机数据目录，然后重新点击恢复。",
        WindowsInclusiveOperation.HistoryRefresh =>
            "确认当前账号可读取 Codex sessions 目录，然后重新刷新历史元数据。",
        _ =>
            "确认当前账号可读写目标本机文件，然后重新执行原操作。",
    };

    private static string MissingPathAction(
        WindowsInclusiveOperation operation) => operation switch
    {
        WindowsInclusiveOperation.ReadinessRefresh =>
            "确认 Codex 仍安装在受支持的本机位置，然后重新刷新只读识别。",
        WindowsInclusiveOperation.ContinuityImport =>
            "重新选择仍存在的本机迁移 JSON。",
        WindowsInclusiveOperation.ContinuityRecovery =>
            "不要新建或猜测恢复文件；保留当前状态并重新打开助手核对恢复入口。",
        WindowsInclusiveOperation.HistoryRefresh =>
            "确认 CODEX_HOME 和 sessions 目录仍存在，然后重新刷新历史元数据。",
        _ =>
            "重新读取当前状态，确认所需本机文件仍存在后再执行原操作。",
    };
}

public static class WindowsInclusivePathPolicy
{
    public static string NormalizeOrdinaryLocalPath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (path.Contains('\0') ||
            path.StartsWith(@"\\", StringComparison.Ordinal) ||
            path.StartsWith("//", StringComparison.Ordinal) ||
            path.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            path.StartsWith(@"\\.\", StringComparison.Ordinal) ||
            !Path.IsPathFullyQualified(path))
        {
            throw new IOException(
                "Network, device, relative, or invalid paths are blocked.");
        }

        var normalized = Path.GetFullPath(path);
        if (normalized.Length >
            WindowsInclusiveReliabilityContract.MaximumNormalizedPathCharacters)
        {
            throw new PathTooLongException(
                "Path exceeds the bounded Windows long-path contract.");
        }
        return normalized;
    }

    public static bool IsLongPath(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        return path.Length > 260;
    }
}
