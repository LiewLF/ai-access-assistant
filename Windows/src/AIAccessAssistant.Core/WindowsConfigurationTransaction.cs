using System.Security.Cryptography;
using System.Text;

namespace AIAccessAssistant.Core;

public enum WindowsConfigurationTransactionState
{
    NoChange,
    Applied,
}

public sealed class WindowsConfigurationTransactionPlan
{
    private readonly byte[] _proposedUtf8;

    internal WindowsConfigurationTransactionPlan(
        string transactionId,
        string configurationPath,
        WindowsFileSecuritySnapshot? originalSnapshot,
        string originalPreview,
        byte[] proposedUtf8,
        string proposedSha256,
        string proposedPreview,
        DateTimeOffset preparedAtUtc,
        DateTimeOffset expiresAtUtc)
    {
        TransactionId = transactionId;
        ConfigurationPath = configurationPath;
        OriginalSnapshot = originalSnapshot;
        OriginalPreview = originalPreview;
        _proposedUtf8 = proposedUtf8.ToArray();
        ProposedSha256 = proposedSha256;
        ProposedPreview = proposedPreview;
        PreparedAtUtc = preparedAtUtc;
        ExpiresAtUtc = expiresAtUtc;
    }

    public string TransactionId { get; }
    public string ConfigurationPath { get; }
    public WindowsFileSecuritySnapshot? OriginalSnapshot { get; }
    public bool ConfigurationExisted => OriginalSnapshot is not null;
    public string OriginalPreview { get; }
    public string ProposedSha256 { get; }
    public string ProposedPreview { get; }
    public int ProposedByteCount => _proposedUtf8.Length;
    public DateTimeOffset PreparedAtUtc { get; }
    public DateTimeOffset ExpiresAtUtc { get; }
    public bool ChangesRequired =>
        OriginalSnapshot is null ||
        !string.Equals(
            OriginalSnapshot.Sha256,
            ProposedSha256,
            StringComparison.OrdinalIgnoreCase);

    internal byte[] CopyProposedUtf8() => _proposedUtf8.ToArray();
}

public sealed record WindowsConfigurationTransactionResult(
    string TransactionId,
    WindowsConfigurationTransactionState State,
    string ConfigurationSha256,
    bool BackupRemoved,
    bool UserConfirmed);

public sealed class WindowsUserConfirmationRequiredException()
    : InvalidOperationException(
        "Configuration transaction requires explicit user confirmation.");

public sealed class WindowsConfigurationTransactionExpiredException()
    : InvalidOperationException(
        "Configuration preview expired; prepare a fresh preview before applying.");

public sealed class WindowsConfigurationTransactionService
{
    public static readonly TimeSpan DefaultPlanLifetime = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan DefaultMutexTimeout = TimeSpan.FromSeconds(5);

    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);
    private static readonly string[] SensitiveKeyFragments =
        [
            "key",
            "token",
            "secret",
            "password",
            "credential",
            "authorization",
            "cookie",
            "bearer",
        ];
    private static readonly HashSet<string> AllowedSensitiveLookingKeys =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "env_key",
        };

    private readonly IWindowsAtomicFileReplacer _fileReplacer;
    private readonly IWindowsTransactionMutex _transactionMutex;
    private readonly Func<DateTimeOffset> _clock;

    public WindowsConfigurationTransactionService(
        IWindowsAtomicFileReplacer? fileReplacer = null,
        IWindowsTransactionMutex? transactionMutex = null,
        Func<DateTimeOffset>? clock = null)
    {
        _fileReplacer = fileReplacer ?? new WindowsAtomicFileReplacer();
        _transactionMutex = transactionMutex ??
            new NamedWindowsTransactionMutex();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public WindowsConfigurationTransactionPlan Prepare(
        string configurationPath,
        string proposedConfiguration)
    {
        ArgumentNullException.ThrowIfNull(proposedConfiguration);
        WindowsNativeGuard.RequireWindows("Configuration transaction preview");

        if (!Path.IsPathFullyQualified(configurationPath))
        {
            throw new IOException(
                "Configuration path must be fully qualified and local.");
        }

        var fullPath = Path.GetFullPath(configurationPath);
        WindowsFileSecuritySnapshot? originalSnapshot = null;
        var originalText = string.Empty;
        if (File.Exists(fullPath))
        {
            originalSnapshot = _fileReplacer.Snapshot(fullPath);
            var originalBytes = ReadBoundedFile(fullPath);
            var observedHash = HashBytes(originalBytes);
            if (!string.Equals(
                    observedHash,
                    originalSnapshot.Sha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new WindowsTransactionBusyException(
                    "Configuration changed while preparing preview.");
            }
            originalText = DecodeStrictUtf8(originalBytes);
        }
        else
        {
            _ = WindowsLocalPathPolicy.ValidateNewFilePath(fullPath);
        }

        if (proposedConfiguration.Contains('\0'))
        {
            throw new ArgumentException(
                "Proposed configuration contains a null character.",
                nameof(proposedConfiguration));
        }
        if (ContainsSensitiveAssignment(proposedConfiguration))
        {
            throw new ArgumentException(
                "Proposed configuration embeds a credential; store it in Windows Credential Manager and reference env_key instead.",
                nameof(proposedConfiguration));
        }

        var proposedUtf8 = StrictUtf8.GetBytes(proposedConfiguration);
        if (proposedUtf8.Length >
            WindowsNativeTransactionContract.MaximumConfigurationBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(proposedConfiguration),
                $"Configuration exceeds {WindowsNativeTransactionContract.MaximumConfigurationBytes} bytes.");
        }

        var preparedAt = _clock();
        return new WindowsConfigurationTransactionPlan(
            Guid.NewGuid().ToString("N"),
            fullPath,
            originalSnapshot,
            ReadOnlyConfigurationPreviewService.Redact(originalText),
            proposedUtf8,
            HashBytes(proposedUtf8),
            ReadOnlyConfigurationPreviewService.Redact(proposedConfiguration),
            preparedAt,
            preparedAt + DefaultPlanLifetime);
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
        WindowsNativeGuard.RequireWindows("Configuration transaction apply");
        if (_clock() > plan.ExpiresAtUtc)
        {
            throw new WindowsConfigurationTransactionExpiredException();
        }

        using var lease = _transactionMutex.Acquire(
            WindowsNativeTransactionContract.ConfigurationMutexName,
            DefaultMutexTimeout);

        var proposedUtf8 = plan.CopyProposedUtf8();
        try
        {
            var proposedHash = HashBytes(proposedUtf8);
            if (!string.Equals(
                    proposedHash,
                    plan.ProposedSha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Prepared configuration content identity changed.");
            }
            VerifyCurrentState(plan);
            if (!plan.ChangesRequired)
            {
                return new WindowsConfigurationTransactionResult(
                    plan.TransactionId,
                    WindowsConfigurationTransactionState.NoChange,
                    plan.ProposedSha256,
                    BackupRemoved: true,
                    UserConfirmed: true);
            }

            var directory = Path.GetDirectoryName(plan.ConfigurationPath) ??
                throw new IOException("Configuration directory is unavailable.");
            WindowsLocalPathPolicy.ValidateExistingDirectory(directory);
            var stage = Path.Combine(
                directory,
                $".{Path.GetFileName(plan.ConfigurationPath)}.ai-access-stage-{plan.TransactionId}.tmp");
            var backup = Path.Combine(
                directory,
                $".{Path.GetFileName(plan.ConfigurationPath)}.ai-access-backup-{plan.TransactionId}.tmp");
            WindowsLocalPathPolicy.ValidateNewFilePath(stage);
            WindowsLocalPathPolicy.ValidateNewFilePath(backup);

            var preserveStageForRecovery = false;
            try
            {
                WriteStage(stage, proposedUtf8);
                if (plan.OriginalSnapshot is not null)
                {
                    _ = _fileReplacer.ReplaceFile(
                        plan.ConfigurationPath,
                        stage,
                        backup,
                        plan.OriginalSnapshot.Sha256,
                        plan.OriginalSnapshot);
                    VerifyApplied(plan.ConfigurationPath, plan.ProposedSha256);
                    DeleteVerifiedTemporaryFile(
                        backup,
                        plan.OriginalSnapshot.Sha256);
                }
                else
                {
                    if (File.Exists(plan.ConfigurationPath))
                    {
                        throw new WindowsTransactionBusyException(
                            "Configuration appeared after preview; transaction was not applied.");
                    }
                    File.Move(stage, plan.ConfigurationPath);
                    try
                    {
                        VerifyApplied(
                            plan.ConfigurationPath,
                            plan.ProposedSha256);
                    }
                    catch
                    {
                        RollBackNewFileIfUnchanged(
                            plan.ConfigurationPath,
                            plan.ProposedSha256);
                        throw;
                    }
                }
            }
            catch (WindowsReplaceFileAmbiguousException)
            {
                preserveStageForRecovery = true;
                throw;
            }
            finally
            {
                if (!preserveStageForRecovery)
                {
                    DeleteStageIfOwned(stage, plan.ProposedSha256);
                }
            }

            return new WindowsConfigurationTransactionResult(
                plan.TransactionId,
                WindowsConfigurationTransactionState.Applied,
                plan.ProposedSha256,
                BackupRemoved: !File.Exists(backup),
                UserConfirmed: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(proposedUtf8);
        }
    }

    public static bool ContainsSensitiveAssignment(string source)
    {
        foreach (var line in source.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var equalsIndex = line.IndexOf('=');
            if (equalsIndex <= 0)
            {
                continue;
            }
            var normalizedKey = line[..equalsIndex]
                .Trim()
                .Trim('"', '\'')
                .ToLowerInvariant();
            if (normalizedKey.StartsWith('#'))
            {
                continue;
            }
            if (AllowedSensitiveLookingKeys.Contains(normalizedKey))
            {
                if (!IsSafeEnvironmentReference(line[(equalsIndex + 1)..]))
                {
                    return true;
                }
                continue;
            }
            var loweredLine = line.ToLowerInvariant();
            if (SensitiveKeyFragments.Any(fragment =>
                    loweredLine.Contains(fragment, StringComparison.Ordinal)))
            {
                return true;
            }
        }
        return false;
    }

    private static bool IsSafeEnvironmentReference(string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length < 3 ||
            trimmed[0] != '"' ||
            trimmed[^1] != '"')
        {
            return false;
        }
        var name = trimmed[1..^1];
        return name.Length is > 0 and <= 128 &&
            (char.IsAsciiLetter(name[0]) || name[0] == '_') &&
            name.All(character =>
                char.IsAsciiLetterOrDigit(character) || character == '_');
    }

    private void VerifyCurrentState(WindowsConfigurationTransactionPlan plan)
    {
        if (plan.OriginalSnapshot is null)
        {
            if (File.Exists(plan.ConfigurationPath) ||
                Directory.Exists(plan.ConfigurationPath))
            {
                throw new WindowsTransactionBusyException(
                    "Configuration appeared after preview; transaction was not applied.");
            }
            _ = WindowsLocalPathPolicy.ValidateNewFilePath(
                plan.ConfigurationPath);
            return;
        }

        var current = _fileReplacer.Snapshot(plan.ConfigurationPath);
        if (current != plan.OriginalSnapshot)
        {
            throw new WindowsTransactionBusyException(
                "Configuration changed after preview; transaction was not applied.");
        }
    }

    private void VerifyApplied(string path, string expectedSha256)
    {
        var observed = _fileReplacer.Snapshot(path);
        if (!string.Equals(
                observed.Sha256,
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "Configuration write completed but content verification failed.");
        }
    }

    private void DeleteVerifiedTemporaryFile(
        string path,
        string expectedSha256)
    {
        var observed = _fileReplacer.Snapshot(path);
        if (!string.Equals(
                observed.Sha256,
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "Transaction backup identity changed; automatic cleanup was blocked.");
        }
        File.Delete(path);
        if (File.Exists(path) || Directory.Exists(path))
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "Transaction backup could not be removed after verification.");
        }
    }

    private void RollBackNewFileIfUnchanged(
        string path,
        string expectedSha256)
    {
        if (!File.Exists(path))
        {
            return;
        }
        var observed = _fileReplacer.Snapshot(path);
        if (!string.Equals(
                observed.Sha256,
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "New configuration changed before rollback; file was preserved.");
        }
        File.Delete(path);
        if (File.Exists(path))
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "New configuration rollback failed.");
        }
    }

    private void DeleteStageIfOwned(string stage, string expectedSha256)
    {
        if (!File.Exists(stage))
        {
            return;
        }
        var observed = _fileReplacer.Snapshot(stage);
        if (!string.Equals(
                observed.Sha256,
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "Transaction stage identity changed; automatic cleanup was blocked.");
        }
        File.Delete(stage);
    }

    private static void WriteStage(string path, ReadOnlySpan<byte> content)
    {
        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 16 * 1024,
            options: FileOptions.WriteThrough);
        stream.Write(content);
        stream.Flush(flushToDisk: true);
    }

    private static byte[] ReadBoundedFile(string path)
    {
        var info = new FileInfo(path);
        info.Refresh();
        if (info.Length > WindowsNativeTransactionContract.MaximumConfigurationBytes)
        {
            throw new IOException(
                $"Configuration exceeds {WindowsNativeTransactionContract.MaximumConfigurationBytes} bytes.");
        }
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length > WindowsNativeTransactionContract.MaximumConfigurationBytes)
        {
            throw new IOException(
                "Configuration grew beyond the supported size while reading.");
        }
        return bytes;
    }

    private static string DecodeStrictUtf8(byte[] bytes)
    {
        var text = StrictUtf8.GetString(bytes);
        return text.TrimStart('\uFEFF');
    }

    private static string HashBytes(ReadOnlySpan<byte> bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
