using System.Diagnostics;
using System.Security;

namespace AIAccessAssistant.Core;

public enum WindowsProcessQuiescenceState
{
    Quiet,
    Busy,
    Blocked,
}

public sealed record WindowsProcessQuiescenceReport(
    WindowsProcessQuiescenceState State,
    int PossibleWriterCount,
    string Conclusion,
    string PrimaryAction)
{
    public bool AllowsConfigurationApply =>
        State == WindowsProcessQuiescenceState.Quiet;
}

public sealed class WindowsProcessQuiescenceRequiredException(
    WindowsProcessQuiescenceReport report)
    : InvalidOperationException(report.Conclusion)
{
    public WindowsProcessQuiescenceReport Report { get; } = report;
}

public sealed class WindowsCodexProcessController : IWindowsProcessController
{
    private static readonly HashSet<string> CandidateProcessNames =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "codex",
            "codex-cli",
        };

    private const int MaximumProcessCandidates = 128;
    private readonly string? _expectedExecutablePath;

    public WindowsCodexProcessController(string? expectedExecutablePath = null)
    {
        if (!string.IsNullOrWhiteSpace(expectedExecutablePath))
        {
            var fullPath = Path.GetFullPath(expectedExecutablePath);
            if (!Path.IsPathFullyQualified(fullPath) ||
                !fullPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "Process quiescence requires an exact native codex.exe path.",
                    nameof(expectedExecutablePath));
            }
            _expectedExecutablePath = fullPath;
        }
    }

    public IReadOnlyList<int> FindConfigurationWriters()
    {
        WindowsNativeGuard.RequireWindows("Codex process discovery");
        if (_expectedExecutablePath is null)
        {
            throw new InvalidOperationException(
                "Exact codex.exe identity is required before process quiescence can be proven.");
        }

        var possibleWriters = new SortedSet<int>();
        var matchedCandidates = 0;
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                if (process.Id == Environment.ProcessId)
                {
                    continue;
                }

                string processName;
                try
                {
                    processName = process.ProcessName;
                }
                catch (Exception error) when (
                    error is InvalidOperationException or
                    NotSupportedException or
                    System.ComponentModel.Win32Exception)
                {
                    continue;
                }
                if (!CandidateProcessNames.Contains(processName))
                {
                    continue;
                }

                matchedCandidates += 1;
                if (matchedCandidates > MaximumProcessCandidates)
                {
                    throw new InvalidOperationException(
                        "Codex process candidate limit exceeded; quiescence is unproven.");
                }

                try
                {
                    var observedPath = process.MainModule?.FileName;
                    if (string.IsNullOrWhiteSpace(observedPath))
                    {
                        possibleWriters.Add(process.Id);
                        continue;
                    }
                    var fullPath = Path.GetFullPath(observedPath);
                    // Any codex/codex-cli process can share the same CODEX_HOME.
                    // Exact path identity binds the supported executable, but a
                    // different same-name executable must still block writes.
                    _ = string.Equals(
                        fullPath,
                        _expectedExecutablePath,
                        StringComparison.OrdinalIgnoreCase);
                    possibleWriters.Add(process.Id);
                }
                catch (Exception error) when (
                    error is InvalidOperationException or
                    NotSupportedException or
                    SecurityException or
                    UnauthorizedAccessException or
                    System.ComponentModel.Win32Exception)
                {
                    // A matching process name that cannot be inspected remains a
                    // possible writer. Never turn access denial into "quiet".
                    possibleWriters.Add(process.Id);
                }
            }
        }
        return possibleWriters.ToArray();
    }

    public void RequestGracefulExit(int processId)
    {
        WindowsNativeGuard.RequireWindows("Codex graceful exit request");
        if (processId <= 0 || processId == Environment.ProcessId)
        {
            throw new ArgumentOutOfRangeException(nameof(processId));
        }
        using var process = Process.GetProcessById(processId);
        if (!process.CloseMainWindow())
        {
            throw new InvalidOperationException(
                "Codex did not expose a closeable main window; ask the user to close it manually.");
        }
    }

    public int LaunchCodex(IReadOnlyDictionary<string, string> environment)
    {
        WindowsNativeGuard.RequireWindows("Codex launch");
        if (_expectedExecutablePath is null)
        {
            throw new InvalidOperationException(
                "Exact codex.exe identity is required before launch.");
        }
        ArgumentNullException.ThrowIfNull(environment);

        var startInfo = new ProcessStartInfo
        {
            FileName = _expectedExecutablePath,
            UseShellExecute = false,
        };
        foreach (var (name, value) in environment)
        {
            ValidateEnvironmentName(name);
            startInfo.Environment[name] = value;
        }
        var process = Process.Start(startInfo) ??
            throw new InvalidOperationException("Codex process did not start.");
        var processId = process.Id;
        process.Dispose();
        return processId;
    }

    public bool WaitForExit(int processId, TimeSpan timeout)
    {
        WindowsNativeGuard.RequireWindows("Codex process wait");
        if (processId <= 0 || processId == Environment.ProcessId)
        {
            throw new ArgumentOutOfRangeException(nameof(processId));
        }
        if (timeout < TimeSpan.Zero || timeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }
        try
        {
            using var process = Process.GetProcessById(processId);
            return process.WaitForExit((int)Math.Ceiling(timeout.TotalMilliseconds));
        }
        catch (ArgumentException)
        {
            return true;
        }
    }

    internal static void ValidateEnvironmentName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) ||
            name.Length > 128 ||
            name.Contains('=') ||
            name.Contains('\0') ||
            !(char.IsAsciiLetter(name[0]) || name[0] == '_') ||
            !name.All(character =>
                char.IsAsciiLetterOrDigit(character) || character == '_'))
        {
            throw new ArgumentException(
                "Environment variable name is unsafe.",
                nameof(name));
        }
    }
}

public sealed class WindowsProcessQuiescenceService
{
    private readonly IWindowsProcessController _controller;

    public WindowsProcessQuiescenceService(IWindowsProcessController controller)
    {
        _controller = controller ?? throw new ArgumentNullException(nameof(controller));
    }

    public WindowsProcessQuiescenceReport Inspect()
    {
        try
        {
            var writers = _controller.FindConfigurationWriters();
            if (writers.Count == 0)
            {
                return new WindowsProcessQuiescenceReport(
                    WindowsProcessQuiescenceState.Quiet,
                    0,
                    "未发现与已识别 codex.exe 匹配的配置写入进程。",
                    "可以继续核对配置预览；应用前仍会再次检查。");
            }
            return new WindowsProcessQuiescenceReport(
                WindowsProcessQuiescenceState.Busy,
                writers.Count,
                "Codex 仍在运行，当前不会应用配置。",
                "先保存工作并手动关闭 Codex，然后重新检查。");
        }
        catch (Exception error) when (
            error is InvalidOperationException or
            NotSupportedException or
            SecurityException or
            UnauthorizedAccessException or
            System.ComponentModel.Win32Exception)
        {
            return new WindowsProcessQuiescenceReport(
                WindowsProcessQuiescenceState.Blocked,
                0,
                "无法证明 Codex 进程已静默，当前不会应用配置。",
                "保留当前设置，关闭 Codex 后再重新检查。");
        }
    }

    public void RequireQuiet()
    {
        var report = Inspect();
        if (!report.AllowsConfigurationApply)
        {
            throw new WindowsProcessQuiescenceRequiredException(report);
        }
    }
}

public sealed class WindowsQuiescentConfigurationTransactionService
{
    private readonly WindowsProcessQuiescenceService _quiescence;
    private readonly WindowsConfigurationTransactionService _transactions;

    public WindowsQuiescentConfigurationTransactionService(
        WindowsProcessQuiescenceService quiescence,
        WindowsConfigurationTransactionService? transactions = null)
    {
        _quiescence = quiescence ??
            throw new ArgumentNullException(nameof(quiescence));
        _transactions = transactions ??
            new WindowsConfigurationTransactionService();
    }

    public WindowsConfigurationTransactionPlan Prepare(
        string configurationPath,
        string proposedConfiguration)
    {
        _quiescence.RequireQuiet();
        return _transactions.Prepare(configurationPath, proposedConfiguration);
    }

    public WindowsConfigurationTransactionResult Apply(
        WindowsConfigurationTransactionPlan plan,
        bool userConfirmed)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (!userConfirmed)
        {
            throw new WindowsUserConfirmationRequiredException();
        }
        _quiescence.RequireQuiet();
        return _transactions.Apply(plan, userConfirmed: true);
    }
}
