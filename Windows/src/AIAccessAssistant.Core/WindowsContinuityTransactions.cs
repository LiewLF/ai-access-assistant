using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AIAccessAssistant.Core;

public sealed record WindowsContinuityRelayDecision(
    Guid SourceId,
    string LocalProfileId,
    byte[] CredentialUtf8);

public sealed record WindowsContinuityWorkspaceDecision(
    Guid SourceId,
    string TargetPath);

public sealed record WindowsContinuityApplyRequest(
    WindowsContinuityImportSession Session,
    IReadOnlyList<WindowsContinuityRelayDecision> RelayDecisions,
    IReadOnlyList<WindowsContinuityWorkspaceDecision> WorkspaceDecisions,
    bool ApplyStartDestination,
    bool ApplyHistoryGrouping,
    bool UserConfirmed);

public sealed record WindowsContinuityApplyResult(
    string TransactionId,
    int ImportedRelayCount,
    int MappedWorkspaceCount,
    bool PreferencesChanged,
    bool CurrentAccessPreserved,
    bool CredentialsVerified,
    string Continuation);

public enum WindowsContinuityTransactionPhase
{
    Prepared,
    CredentialsWritten,
    StateApplied,
    Committed,
    RollbackRequired,
    RolledBack,
    RollbackFailed,
}

public sealed record WindowsContinuityTransactionJournal(
    int SchemaVersion,
    string TransactionId,
    WindowsContinuityTransactionPhase Phase,
    string SourceSha256,
    string PreviewSha256,
    string SelectionSha256,
    string? BeforeStateSha256,
    string TargetStateSha256,
    bool BeforeStateExisted,
    IReadOnlyList<string> CredentialTargetSuffixes,
    string BackupRelativeName,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset UpdatedAtUtc);

public sealed class WindowsContinuityConfirmationRequiredException()
    : InvalidOperationException(
        "Continuity import requires final explicit confirmation.");

public sealed class WindowsContinuityPendingRecoveryException()
    : InvalidOperationException(
        "A previous continuity import must be recovered first.");

public sealed class WindowsContinuityRecoveryRequiredException(
    string message,
    Exception? innerException = null)
    : IOException(message, innerException);

public sealed class WindowsContinuityStateStore
{
    public const int StateSchemaVersion = 1;
    private const int MaximumStateBytes = 1024 * 1024;
    private const string StateName = "continuity-state.json";
    private const string JournalName = "continuity-journal.json";

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly IWindowsAtomicFileReplacer _fileReplacer;

    public WindowsContinuityStateStore(
        string rootPath,
        IWindowsAtomicFileReplacer? fileReplacer = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        RootPath =
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(rootPath);
        StatePath = Path.Combine(RootPath, StateName);
        JournalPath = Path.Combine(RootPath, JournalName);
        _fileReplacer = fileReplacer ?? new WindowsAtomicFileReplacer();
    }

    public string RootPath { get; }
    public string StatePath { get; }
    public string JournalPath { get; }

    public static WindowsContinuityStateStore ForCurrentUser(
        Func<string, string?>? environmentReader = null)
    {
        environmentReader ??= Environment.GetEnvironmentVariable;
        var localAppData = environmentReader("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new IOException(
                "LOCALAPPDATA is unavailable; continuity state path is unproven.");
        }
        return new WindowsContinuityStateStore(Path.Combine(
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(localAppData),
            "AI Access Assistant",
            "Continuity"));
    }

    public WindowsContinuityTargetState Load()
    {
        if (!File.Exists(StatePath))
        {
            return WindowsContinuityTargetState.Empty;
        }
        RequireRoot(createIfMissing: false);
        var bytes = ReadBoundedOrdinaryFile(StatePath, MaximumStateBytes);
        try
        {
            var sha256 = WindowsContinuityManifestReader.Hash(bytes);
            using var document = JsonDocument.Parse(
                StrictUtf8.GetString(bytes),
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 24,
                });
            return ParseState(document.RootElement, sha256);
        }
        catch (WindowsContinuityManifestException)
        {
            throw;
        }
        catch (Exception error) when (
            error is JsonException or
            DecoderFallbackException or
            FormatException or
            InvalidOperationException)
        {
            throw new WindowsContinuityManifestException(
                "Local continuity state is malformed; recovery is required.");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public byte[] Serialize(WindowsContinuityTargetState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        ValidateStateForSerialization(state);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(
            stream,
            new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schema_version", StateSchemaVersion);
            writer.WriteStartArray("relay_profiles");
            foreach (var profile in state.RelayProfiles.OrderBy(
                profile => profile.LocalProfileId,
                StringComparer.Ordinal))
            {
                ValidateTargetProfile(profile);
                writer.WriteStartObject();
                writer.WriteString("local_profile_id", profile.LocalProfileId);
                writer.WriteString("display_name", profile.DisplayName);
                writer.WriteString("base_url", profile.BaseUrl);
                writer.WriteString("default_model", profile.DefaultModel);
                writer.WriteString("credential_target", profile.CredentialTarget);
                writer.WriteBoolean("verified", false);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteStartArray("favorite_workspace_paths");
            foreach (var path in state.FavoriteWorkspacePaths.Order(
                StringComparer.OrdinalIgnoreCase))
            {
                writer.WriteStringValue(Path.GetFullPath(path));
            }
            writer.WriteEndArray();
            writer.WriteStartArray("workspace_labels");
            foreach (var pair in state.WorkspaceLabels.OrderBy(
                pair => pair.Key,
                StringComparer.OrdinalIgnoreCase))
            {
                writer.WriteStartObject();
                writer.WriteString("path", Path.GetFullPath(pair.Key));
                writer.WriteString("label", pair.Value);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteString(
                "start_destination",
                EnumText(state.StartDestination));
            writer.WriteString(
                "history_grouping",
                EnumText(state.HistoryGrouping));
            writer.WriteEndObject();
        }
        var result = stream.ToArray();
        if (result.Length > MaximumStateBytes)
        {
            CryptographicOperations.ZeroMemory(result);
            throw new IOException("Continuity state exceeds the 1 MiB limit.");
        }
        return result;
    }

    public WindowsContinuityTransactionJournal? LoadJournal()
    {
        if (!File.Exists(JournalPath))
        {
            return null;
        }
        RequireRoot(createIfMissing: false);
        var bytes = ReadBoundedOrdinaryFile(JournalPath, 64 * 1024);
        try
        {
            using var document = JsonDocument.Parse(StrictUtf8.GetString(bytes));
            return ParseJournal(document.RootElement);
        }
        catch (WindowsContinuityRecoveryRequiredException)
        {
            throw;
        }
        catch (Exception error) when (
            error is JsonException or
            DecoderFallbackException or
            FormatException or
            ArgumentException or
            OverflowException or
            InvalidOperationException)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity recovery journal is malformed.",
                error);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public void SaveJournal(WindowsContinuityTransactionJournal journal)
    {
        ArgumentNullException.ThrowIfNull(journal);
        ValidateJournal(journal);
        RequireRoot(createIfMissing: true);
        var bytes = SerializeJournal(journal);
        try
        {
            WriteThroughReplace(JournalPath, bytes, journal.TransactionId);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public void DeleteJournal(string transactionId)
    {
        var journal = LoadJournal();
        if (journal is null)
        {
            return;
        }
        if (!string.Equals(
                journal.TransactionId,
                transactionId,
                StringComparison.Ordinal))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "A different continuity transaction owns the recovery journal.");
        }
        DeleteVerifiedFile(
            JournalPath,
            WindowsAtomicFileReplacer.HashFile(JournalPath));
    }

    public void ApplyState(
        byte[] targetData,
        string? expectedBeforeSha256,
        string targetSha256,
        string backupRelativeName,
        string transactionId)
    {
        ArgumentNullException.ThrowIfNull(targetData);
        WindowsNativeGuard.RequireWindows("Continuity state apply");
        RequireRoot(createIfMissing: true);
        ValidateRelativeName(backupRelativeName);
        var stage = Path.Combine(
            RootPath,
            $".continuity-stage-{transactionId}.tmp");
        var backup = Path.Combine(RootPath, backupRelativeName);
        ValidateRelativeName(Path.GetFileName(stage));
        if (File.Exists(stage) || File.Exists(backup))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity stage or backup already exists.");
        }
        WriteNewThrough(stage, targetData);
        var preserveStage = false;
        try
        {
            if (File.Exists(StatePath))
            {
                var before = _fileReplacer.Snapshot(StatePath);
                if (!string.Equals(
                        before.Sha256,
                        expectedBeforeSha256,
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new WindowsTransactionBusyException(
                        "Continuity state changed after preview.");
                }
                _ = _fileReplacer.ReplaceFile(
                    StatePath,
                    stage,
                    backup,
                    before.Sha256,
                    before);
            }
            else
            {
                if (expectedBeforeSha256 is not null)
                {
                    throw new WindowsTransactionBusyException(
                        "Continuity state disappeared after preview.");
                }
                File.Move(stage, StatePath);
            }
            if (!string.Equals(
                    WindowsAtomicFileReplacer.HashFile(StatePath),
                    targetSha256,
                    StringComparison.OrdinalIgnoreCase))
            {
                preserveStage = true;
                throw new WindowsContinuityRecoveryRequiredException(
                    "Continuity state write completed with an unexpected identity.");
            }
        }
        catch (WindowsReplaceFileAmbiguousException)
        {
            preserveStage = true;
            throw;
        }
        catch (WindowsTransactionRecoveryRequiredException)
        {
            preserveStage = true;
            throw;
        }
        catch (WindowsContinuityRecoveryRequiredException)
        {
            preserveStage = true;
            throw;
        }
        finally
        {
            if (!preserveStage && File.Exists(stage))
            {
                DeleteVerifiedFile(
                    stage,
                    WindowsAtomicFileReplacer.HashFile(stage));
            }
        }
    }

    public void VerifyBaseline(string? expectedSha256)
    {
        var current = File.Exists(StatePath)
            ? WindowsAtomicFileReplacer.HashFile(StatePath)
            : null;
        if (!string.Equals(
                current,
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity state no longer matches the recovery baseline.");
        }
    }

    public string? CurrentStateSha256() =>
        File.Exists(StatePath)
            ? WindowsAtomicFileReplacer.HashFile(StatePath)
            : null;

    public void VerifyTarget(string expectedSha256)
    {
        if (!string.Equals(
                CurrentStateSha256(),
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Committed continuity state identity changed.");
        }
    }

    public void RestoreState(WindowsContinuityTransactionJournal journal)
    {
        ArgumentNullException.ThrowIfNull(journal);
        WindowsNativeGuard.RequireWindows("Continuity state recovery");
        RequireRoot(createIfMissing: false);
        var current = File.Exists(StatePath)
            ? WindowsAtomicFileReplacer.HashFile(StatePath)
            : null;
        if (!string.Equals(
                current,
                journal.TargetStateSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity target changed before recovery.");
        }

        if (!journal.BeforeStateExisted)
        {
            if (File.Exists(StatePath))
            {
                DeleteVerifiedFile(StatePath, journal.TargetStateSha256);
            }
            return;
        }

        var backup = Path.Combine(RootPath, journal.BackupRelativeName);
        if (!File.Exists(backup) || journal.BeforeStateSha256 is null ||
            !string.Equals(
                WindowsAtomicFileReplacer.HashFile(backup),
                journal.BeforeStateSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity backup is missing or changed.");
        }
        var currentSnapshot = _fileReplacer.Snapshot(StatePath);
        var rollbackEvidence = Path.Combine(
            RootPath,
            $".continuity-rollback-{journal.TransactionId}.tmp");
        if (File.Exists(rollbackEvidence))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity rollback evidence already exists.");
        }
        _ = _fileReplacer.ReplaceFile(
            StatePath,
            backup,
            rollbackEvidence,
            journal.TargetStateSha256,
            currentSnapshot);
        if (!string.Equals(
                WindowsAtomicFileReplacer.HashFile(StatePath),
                journal.BeforeStateSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity rollback did not restore the previous state.");
        }
        DeleteVerifiedFile(
            rollbackEvidence,
            journal.TargetStateSha256);
    }

    public void DeleteCommittedBackup(
        WindowsContinuityTransactionJournal journal)
    {
        ArgumentNullException.ThrowIfNull(journal);
        if (!journal.BeforeStateExisted)
        {
            return;
        }
        var backup = Path.Combine(RootPath, journal.BackupRelativeName);
        if (!File.Exists(backup) || journal.BeforeStateSha256 is null)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity backup is unavailable before commit.");
        }
        DeleteVerifiedFile(backup, journal.BeforeStateSha256);
    }

    public void FinalizeCommitted(
        WindowsContinuityTransactionJournal journal)
    {
        ArgumentNullException.ThrowIfNull(journal);
        if (journal.Phase != WindowsContinuityTransactionPhase.Committed)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Only a committed continuity transaction may be finalized.");
        }
        VerifyTarget(journal.TargetStateSha256);
        if (journal.BeforeStateExisted)
        {
            var backup = Path.Combine(RootPath, journal.BackupRelativeName);
            if (File.Exists(backup))
            {
                if (journal.BeforeStateSha256 is null)
                {
                    throw new WindowsContinuityRecoveryRequiredException(
                        "Committed continuity backup identity is missing.");
                }
                DeleteVerifiedFile(backup, journal.BeforeStateSha256);
            }
        }
        DeleteJournal(journal.TransactionId);
    }

    private static WindowsContinuityTargetState ParseState(
        JsonElement root,
        string sha256)
    {
        RequireExactObject(
            root,
            [
                "schema_version",
                "relay_profiles",
                "favorite_workspace_paths",
                "workspace_labels",
                "start_destination",
                "history_grouping",
            ]);
        if (Int(root, "schema_version") != StateSchemaVersion)
        {
            throw new WindowsContinuityManifestException(
                "Local continuity state schema is unsupported.");
        }

        var profiles = new List<WindowsContinuityTargetProfile>();
        var profileArray = Property(root, "relay_profiles");
        if (profileArray.ValueKind != JsonValueKind.Array ||
            profileArray.GetArrayLength() >
                WindowsContinuityContract.MaximumAccessProfiles)
        {
            throw new WindowsContinuityManifestException(
                "Local relay profile collection is invalid.");
        }
        foreach (var item in profileArray.EnumerateArray())
        {
            RequireExactObject(
                item,
                [
                    "local_profile_id",
                    "display_name",
                    "base_url",
                    "default_model",
                    "credential_target",
                    "verified",
                ]);
            var profile = new WindowsContinuityTargetProfile(
                SafeText(item, "local_profile_id", 128),
                SafeText(item, "display_name", 80),
                SafeEndpoint(item, "base_url"),
                SafeText(item, "default_model", 128),
                SafeText(item, "credential_target", 256),
                Bool(item, "verified"));
            ValidateTargetProfile(profile);
            if (profile.Verified)
            {
                throw new WindowsContinuityManifestException(
                    "Imported continuity state cannot adopt verification.");
            }
            profiles.Add(profile);
        }
        if (profiles.Select(profile => profile.LocalProfileId)
                .Distinct(StringComparer.Ordinal).Count() != profiles.Count ||
            profiles.Select(profile => profile.CredentialTarget)
                .Distinct(StringComparer.Ordinal).Count() != profiles.Count)
        {
            throw new WindowsContinuityManifestException(
                "Local relay profile identifiers are duplicated.");
        }

        var favorites = ParsePathArray(
            Property(root, "favorite_workspace_paths"));
        if (favorites.Count > WindowsContinuityContract.MaximumWorkspaceLabels)
        {
            throw new WindowsContinuityManifestException(
                "Too many local favorite workspaces.");
        }
        var labels = new Dictionary<string, string>(
            StringComparer.OrdinalIgnoreCase);
        var labelsArray = Property(root, "workspace_labels");
        if (labelsArray.ValueKind != JsonValueKind.Array ||
            labelsArray.GetArrayLength() >
                WindowsContinuityContract.MaximumWorkspaceLabels)
        {
            throw new WindowsContinuityManifestException(
                "Local workspace labels are invalid.");
        }
        foreach (var item in labelsArray.EnumerateArray())
        {
            RequireExactObject(item, ["path", "label"]);
            var path = SafePath(item, "path");
            var label = SafeText(item, "label", 40);
            if (!favorites.Contains(path, StringComparer.OrdinalIgnoreCase) ||
                !labels.TryAdd(path, label))
            {
                throw new WindowsContinuityManifestException(
                    "Workspace label is not bound to one local favorite.");
            }
        }
        var start = ParseStart(SafeText(root, "start_destination", 32));
        var grouping = ParseGrouping(SafeText(root, "history_grouping", 32));
        return new WindowsContinuityTargetState(
            profiles,
            favorites,
            labels,
            start,
            grouping,
            sha256);
    }

    private static void ValidateTargetProfile(
        WindowsContinuityTargetProfile profile)
    {
        if (profile.LocalProfileId.Length is < 1 or > 128 ||
            profile.LocalProfileId.Any(character =>
                !char.IsAsciiLetterOrDigit(character) &&
                character is not '.' and not '_' and not '-') ||
            profile.DisplayName.Length is < 1 or > 80 ||
            profile.DisplayName.Any(char.IsControl) ||
            profile.DefaultModel.Length is < 1 or > 128 ||
            profile.DefaultModel.Any(char.IsControl) ||
            !Uri.TryCreate(profile.BaseUrl, UriKind.Absolute, out var uri) ||
            !uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) ||
            profile.Verified)
        {
            throw new WindowsContinuityManifestException(
                "Local relay profile is invalid.");
        }
        WindowsCredentialManager.ValidateTargetName(profile.CredentialTarget);
        var expectedTarget =
            WindowsNativeTransactionContract.CredentialTargetPrefix +
            WindowsContinuityManifestReader.HashText(profile.LocalProfileId)[..32];
        if (!string.Equals(
                profile.CredentialTarget,
                expectedTarget,
                StringComparison.Ordinal))
        {
            throw new WindowsContinuityManifestException(
                "Local relay credential target does not match its profile identifier.");
        }
    }

    private static void ValidateStateForSerialization(
        WindowsContinuityTargetState state)
    {
        if (state.RelayProfiles.Count >
                WindowsContinuityContract.MaximumAccessProfiles ||
            state.RelayProfiles.Select(profile => profile.LocalProfileId)
                .Distinct(StringComparer.Ordinal).Count() !=
                state.RelayProfiles.Count ||
            state.RelayProfiles.Select(profile => profile.CredentialTarget)
                .Distinct(StringComparer.Ordinal).Count() !=
                state.RelayProfiles.Count)
        {
            throw new WindowsContinuityManifestException(
                "Local relay profile collection is invalid.");
        }
        foreach (var profile in state.RelayProfiles)
        {
            ValidateTargetProfile(profile);
        }

        if (state.FavoriteWorkspacePaths.Count >
                WindowsContinuityContract.MaximumWorkspaceLabels ||
            state.FavoriteWorkspacePaths.Any(path =>
                !Path.IsPathFullyQualified(path)) ||
            state.FavoriteWorkspacePaths
                .Select(Path.GetFullPath)
                .Distinct(StringComparer.OrdinalIgnoreCase).Count() !=
                state.FavoriteWorkspacePaths.Count ||
            state.WorkspaceLabels.Count >
                WindowsContinuityContract.MaximumWorkspaceLabels)
        {
            throw new WindowsContinuityManifestException(
                "Local favorite workspace collection is invalid.");
        }
        foreach (var pair in state.WorkspaceLabels)
        {
            if (!Path.IsPathFullyQualified(pair.Key))
            {
                throw new WindowsContinuityManifestException(
                    "Workspace label path is not fully qualified.");
            }
            var path = Path.GetFullPath(pair.Key);
            if (!state.FavoriteWorkspacePaths.Contains(
                    path,
                    StringComparer.OrdinalIgnoreCase) ||
                pair.Value.Length is < 1 or > 40 ||
                pair.Value.Any(char.IsControl))
            {
                throw new WindowsContinuityManifestException(
                    "Workspace label is not bound to one valid local favorite.");
            }
        }
    }

    private static List<string> ParsePathArray(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array)
        {
            throw new WindowsContinuityManifestException(
                "Local favorite workspace collection is invalid.");
        }
        var paths = value.EnumerateArray().Select(item =>
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                throw new WindowsContinuityManifestException(
                    "Local favorite workspace path is invalid.");
            }
            var path = item.GetString() ?? string.Empty;
            if (!Path.IsPathFullyQualified(path))
            {
                throw new WindowsContinuityManifestException(
                    "Local favorite workspace path is not fully qualified.");
            }
            return Path.GetFullPath(path);
        }).ToList();
        if (paths.Distinct(StringComparer.OrdinalIgnoreCase).Count() != paths.Count)
        {
            throw new WindowsContinuityManifestException(
                "Local favorite workspace paths are duplicated.");
        }
        return paths;
    }

    private static WindowsContinuityTransactionJournal ParseJournal(
        JsonElement root)
    {
        RequireExactObject(
            root,
            [
                "schema_version",
                "transaction_id",
                "phase",
                "source_sha256",
                "preview_sha256",
                "selection_sha256",
                "before_state_sha256",
                "target_state_sha256",
                "before_state_existed",
                "credential_target_suffixes",
                "backup_relative_name",
                "started_at_utc",
                "updated_at_utc",
            ]);
        var suffixesElement = Property(root, "credential_target_suffixes");
        if (suffixesElement.ValueKind != JsonValueKind.Array ||
            suffixesElement.GetArrayLength() >
                WindowsContinuityContract.MaximumAccessProfiles)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity journal credential targets are invalid.");
        }
        var suffixes = suffixesElement.EnumerateArray()
            .Select(item => item.ValueKind == JsonValueKind.String
                ? item.GetString() ?? string.Empty
                : string.Empty)
            .ToArray();
        var journal = new WindowsContinuityTransactionJournal(
            Int(root, "schema_version"),
            SafeText(root, "transaction_id", 64),
            ParseTransactionPhase(SafeText(root, "phase", 32)),
            SafeText(root, "source_sha256", 64),
            SafeText(root, "preview_sha256", 64),
            SafeText(root, "selection_sha256", 64),
            NullableText(root, "before_state_sha256", 64),
            SafeText(root, "target_state_sha256", 64),
            Bool(root, "before_state_existed"),
            suffixes,
            SafeText(root, "backup_relative_name", 128),
            Timestamp(root, "started_at_utc"),
            Timestamp(root, "updated_at_utc"));
        ValidateJournal(journal);
        return journal;
    }

    private static byte[] SerializeJournal(
        WindowsContinuityTransactionJournal journal)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(
            stream,
            new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schema_version", journal.SchemaVersion);
            writer.WriteString("transaction_id", journal.TransactionId);
            writer.WriteString("phase", EnumText(journal.Phase));
            writer.WriteString("source_sha256", journal.SourceSha256);
            writer.WriteString("preview_sha256", journal.PreviewSha256);
            writer.WriteString("selection_sha256", journal.SelectionSha256);
            if (journal.BeforeStateSha256 is null)
            {
                writer.WriteNull("before_state_sha256");
            }
            else
            {
                writer.WriteString(
                    "before_state_sha256",
                    journal.BeforeStateSha256);
            }
            writer.WriteString(
                "target_state_sha256",
                journal.TargetStateSha256);
            writer.WriteBoolean(
                "before_state_existed",
                journal.BeforeStateExisted);
            writer.WriteStartArray("credential_target_suffixes");
            foreach (var suffix in journal.CredentialTargetSuffixes.Order(
                StringComparer.Ordinal))
            {
                writer.WriteStringValue(suffix);
            }
            writer.WriteEndArray();
            writer.WriteString(
                "backup_relative_name",
                journal.BackupRelativeName);
            writer.WriteString("started_at_utc", journal.StartedAtUtc);
            writer.WriteString("updated_at_utc", journal.UpdatedAtUtc);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    private static void ValidateJournal(
        WindowsContinuityTransactionJournal journal)
    {
        if (journal.SchemaVersion != 1 ||
            journal.TransactionId.Length != 32 ||
            journal.TransactionId.Any(character =>
                !char.IsAsciiHexDigit(character) || char.IsUpper(character)) ||
            !Enum.IsDefined(journal.Phase) ||
            !IsSha256(journal.SourceSha256) ||
            !IsSha256(journal.PreviewSha256) ||
            !IsSha256(journal.SelectionSha256) ||
            !IsSha256(journal.TargetStateSha256) ||
            (journal.BeforeStateExisted &&
                !IsSha256(journal.BeforeStateSha256)) ||
            (!journal.BeforeStateExisted &&
                journal.BeforeStateSha256 is not null) ||
            journal.CredentialTargetSuffixes.Count >
                WindowsContinuityContract.MaximumAccessProfiles ||
            journal.CredentialTargetSuffixes.Distinct(StringComparer.Ordinal)
                .Count() != journal.CredentialTargetSuffixes.Count ||
            journal.CredentialTargetSuffixes.Any(suffix =>
                suffix.Length != 32 ||
                suffix.Any(character =>
                    !char.IsAsciiHexDigit(character) || char.IsUpper(character))) ||
            !string.Equals(
                journal.BackupRelativeName,
                $"continuity-backup-{journal.TransactionId}.json",
                StringComparison.Ordinal) ||
            journal.StartedAtUtc.Offset != TimeSpan.Zero ||
            journal.UpdatedAtUtc.Offset != TimeSpan.Zero ||
            journal.UpdatedAtUtc < journal.StartedAtUtc)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity recovery journal failed validation.");
        }
        ValidateRelativeName(journal.BackupRelativeName);
    }

    private void RequireRoot(bool createIfMissing)
    {
        if (!Directory.Exists(RootPath))
        {
            if (!createIfMissing)
            {
                throw new WindowsContinuityRecoveryRequiredException(
                    "Continuity root is missing.");
            }
            var parent = NearestExistingParent(RootPath);
            RequireSafeDirectoryChain(parent);
            Directory.CreateDirectory(RootPath);
        }
        var root = new DirectoryInfo(RootPath);
        RequireSafeDirectoryChain(root);
    }

    private static DirectoryInfo NearestExistingParent(string path)
    {
        DirectoryInfo? candidate = new DirectoryInfo(path).Parent;
        while (candidate is not null && !candidate.Exists)
        {
            candidate = candidate.Parent;
        }
        return candidate ?? throw new IOException(
            "Continuity root parent is unavailable.");
    }

    private static void RequireSafeDirectoryChain(DirectoryInfo start)
    {
        for (DirectoryInfo? directory = start;
            directory is not null;
            directory = directory.Parent)
        {
            directory.Refresh();
            if (!directory.Exists ||
                (directory.Attributes &
                    (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0)
            {
                throw new WindowsContinuityRecoveryRequiredException(
                    "Continuity root or parent is unsafe.");
            }
        }
        if (OperatingSystem.IsWindows())
        {
            var driveRoot = Path.GetPathRoot(start.FullName) ?? string.Empty;
            if (string.IsNullOrEmpty(driveRoot) ||
                new DriveInfo(driveRoot).DriveType != DriveType.Fixed)
            {
                throw new WindowsContinuityRecoveryRequiredException(
                    "Continuity root must remain on a fixed local drive.");
            }
        }
    }

    private static byte[] ReadBoundedOrdinaryFile(string path, int maximumBytes)
    {
        var file = new FileInfo(path);
        file.Refresh();
        if (!file.Exists || file.Length > maximumBytes ||
            (file.Attributes &
                (FileAttributes.Directory |
                    FileAttributes.ReparsePoint |
                    FileAttributes.Offline)) != 0)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity file is unsafe or too large.");
        }
        return File.ReadAllBytes(path);
    }

    private void WriteThroughReplace(
        string destination,
        byte[] data,
        string transactionId)
    {
        var stage = Path.Combine(
            RootPath,
            $".{Path.GetFileName(destination)}.{transactionId}.tmp");
        if (File.Exists(stage))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity journal stage already exists.");
        }
        WriteNewThrough(stage, data);
        var completed = false;
        try
        {
            if (File.Exists(destination))
            {
                File.Replace(stage, destination, null, ignoreMetadataErrors: false);
            }
            else
            {
                File.Move(stage, destination);
            }
            completed = true;
        }
        catch (Exception error)
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity journal replacement is unproven; same-directory evidence was preserved.",
                error);
        }
        finally
        {
            if (completed && File.Exists(stage))
            {
                File.Delete(stage);
            }
        }
    }

    private static void WriteNewThrough(string path, byte[] data)
    {
        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            16 * 1024,
            FileOptions.WriteThrough);
        stream.Write(data);
        stream.Flush(flushToDisk: true);
    }

    private static void DeleteVerifiedFile(string path, string expectedSha256)
    {
        if (!File.Exists(path))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Expected continuity recovery file is missing.");
        }
        var file = new FileInfo(path);
        file.Refresh();
        if ((file.Attributes &
                (FileAttributes.Directory |
                    FileAttributes.ReparsePoint |
                    FileAttributes.Offline)) != 0 ||
            !string.Equals(
                WindowsAtomicFileReplacer.HashFile(path),
                expectedSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity recovery file identity changed.");
        }
        File.Delete(path);
    }

    private static void ValidateRelativeName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) ||
            Path.GetFileName(name) != name ||
            name.Length > 128 ||
            name.Any(character =>
                !char.IsAsciiLetterOrDigit(character) &&
                character is not '.' and not '_' and not '-'))
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity recovery filename is invalid.");
        }
    }

    private static void RequireExactObject(
        JsonElement value,
        IReadOnlyCollection<string> names)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new WindowsContinuityManifestException(
                "Continuity JSON object is invalid.");
        }
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!names.Contains(property.Name) ||
                !observed.Add(property.Name))
            {
                throw new WindowsContinuityManifestException(
                    "Continuity JSON contains an unknown or duplicate field.");
            }
        }
        if (names.Any(name => !observed.Contains(name)))
        {
            throw new WindowsContinuityManifestException(
                "Continuity JSON is missing a required field.");
        }
    }

    private static JsonElement Property(JsonElement value, string name) =>
        value.TryGetProperty(name, out var property)
            ? property
            : throw new WindowsContinuityManifestException(
                "Continuity JSON is missing a required field.");

    private static int Int(JsonElement value, string name) =>
        Property(value, name).TryGetInt32(out var result)
            ? result
            : throw new WindowsContinuityManifestException(
                "Continuity integer is invalid.");

    private static bool Bool(JsonElement value, string name) =>
        Property(value, name).ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new WindowsContinuityManifestException(
                "Continuity Boolean is invalid."),
        };

    private static string SafeText(
        JsonElement value,
        string name,
        int maximumLength)
    {
        var property = Property(value, name);
        if (property.ValueKind != JsonValueKind.String)
        {
            throw new WindowsContinuityManifestException(
                "Continuity text is invalid.");
        }
        var text = property.GetString()?.Trim() ?? string.Empty;
        if (text.Length is 0 || text.Length > maximumLength ||
            text.Any(char.IsControl))
        {
            throw new WindowsContinuityManifestException(
                "Continuity text is invalid.");
        }
        return text;
    }

    private static string? NullableText(
        JsonElement value,
        string name,
        int maximumLength)
    {
        var property = Property(value, name);
        return property.ValueKind == JsonValueKind.Null
            ? null
            : SafeText(value, name, maximumLength);
    }

    private static DateTimeOffset Timestamp(JsonElement value, string name)
    {
        var text = SafeText(value, name, 64);
        if (!DateTimeOffset.TryParse(
                text,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var timestamp))
        {
            throw new WindowsContinuityManifestException(
                "Continuity timestamp is invalid.");
        }
        return timestamp.ToUniversalTime();
    }

    private static string SafeEndpoint(JsonElement value, string name)
    {
        var endpoint = SafeText(value, name, 2048);
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) ||
            !uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new WindowsContinuityManifestException(
                "Continuity endpoint is invalid.");
        }
        return endpoint;
    }

    private static string SafePath(JsonElement value, string name)
    {
        var path = SafeText(value, name, 32767);
        if (!Path.IsPathFullyQualified(path))
        {
            throw new WindowsContinuityManifestException(
                "Continuity workspace path is invalid.");
        }
        return Path.GetFullPath(path);
    }

    private static WindowsPortableStartDestination ParseStart(string value) =>
        value switch
        {
            "start" => WindowsPortableStartDestination.Start,
            "access" => WindowsPortableStartDestination.Access,
            "history" => WindowsPortableStartDestination.History,
            _ => throw new WindowsContinuityManifestException(
                "Continuity start destination is invalid."),
        };

    private static WindowsContinuityTransactionPhase ParseTransactionPhase(
        string value) =>
        value switch
        {
            "prepared" => WindowsContinuityTransactionPhase.Prepared,
            "credentials_written" =>
                WindowsContinuityTransactionPhase.CredentialsWritten,
            "state_applied" => WindowsContinuityTransactionPhase.StateApplied,
            "committed" => WindowsContinuityTransactionPhase.Committed,
            "rollback_required" =>
                WindowsContinuityTransactionPhase.RollbackRequired,
            "rolled_back" => WindowsContinuityTransactionPhase.RolledBack,
            "rollback_failed" =>
                WindowsContinuityTransactionPhase.RollbackFailed,
            _ => throw new WindowsContinuityRecoveryRequiredException(
                "Continuity recovery journal phase is invalid."),
        };

    private static WindowsPortableHistoryGrouping ParseGrouping(string value) =>
        value switch
        {
            "recent" => WindowsPortableHistoryGrouping.Recent,
            "workspace" => WindowsPortableHistoryGrouping.Workspace,
            "recovery" => WindowsPortableHistoryGrouping.Recovery,
            _ => throw new WindowsContinuityManifestException(
                "Continuity history grouping is invalid."),
        };

    private static string EnumText<T>(T value) where T : struct, Enum =>
        value.ToString() switch
        {
            "MacOS" => "macOS",
            _ => JsonNamingPolicy.SnakeCaseLower.ConvertName(value.ToString()),
        };

    private static bool IsSha256(string? value) =>
        value is { Length: 64 } &&
        value.All(character =>
            char.IsAsciiHexDigit(character) && !char.IsUpper(character));
}

public sealed class WindowsContinuityImportCoordinator
{
    private readonly WindowsContinuityStateStore _stateStore;
    private readonly IWindowsCredentialManager _credentialManager;
    private readonly IWindowsTransactionMutex _transactionMutex;
    private readonly WindowsContinuityPreflightService _preflight;
    private readonly Func<DateTimeOffset> _clock;

    public WindowsContinuityImportCoordinator(
        WindowsContinuityStateStore? stateStore = null,
        IWindowsCredentialManager? credentialManager = null,
        IWindowsTransactionMutex? transactionMutex = null,
        WindowsContinuityPreflightService? preflight = null,
        Func<DateTimeOffset>? clock = null)
    {
        _stateStore = stateStore ??
            WindowsContinuityStateStore.ForCurrentUser();
        _credentialManager = credentialManager ??
            new WindowsCredentialManager();
        _transactionMutex = transactionMutex ??
            new NamedWindowsTransactionMutex();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _preflight = preflight ??
            new WindowsContinuityPreflightService(clock: _clock);
    }

    public WindowsContinuityTargetState LoadTargetState() =>
        _stateStore.Load();

    public WindowsContinuityTransactionPhase? PendingRecoveryPhase() =>
        _stateStore.LoadJournal()?.Phase;

    public WindowsContinuityImportSession Prepare(string sourcePath)
    {
        RequireNoPendingRecovery();
        return _preflight.Prepare(sourcePath, _stateStore.Load());
    }

    public WindowsContinuityApplyResult Apply(
        WindowsContinuityApplyRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            return ApplyCore(request);
        }
        finally
        {
            foreach (var credential in request.RelayDecisions)
            {
                CryptographicOperations.ZeroMemory(credential.CredentialUtf8);
            }
        }
    }

    private WindowsContinuityApplyResult ApplyCore(
        WindowsContinuityApplyRequest request)
    {
        if (!request.UserConfirmed)
        {
            throw new WindowsContinuityConfirmationRequiredException();
        }
        WindowsNativeGuard.RequireWindows("Continuity import apply");
        if (_clock() > request.Session.ExpiresAtUtc)
        {
            throw new WindowsContinuityPlanExpiredException();
        }
        ValidateDecisions(request);

        using var lease = _transactionMutex.Acquire(
            WindowsContinuityContract.ContinuityMutexName,
            TimeSpan.FromSeconds(5));
        RequireNoPendingRecovery();
        _preflight.RequireFresh(request.Session);
        var current = _stateStore.Load();
        if (!string.Equals(
                current.Sha256,
                request.Session.TargetStateSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsTransactionBusyException(
                "Continuity target changed after preview.");
        }
        var freshPreview = WindowsContinuityPreflightService.Inspect(
            request.Session.Manifest,
            current);
        if (!string.Equals(
                freshPreview.Sha256,
                request.Session.PreviewSha256,
                StringComparison.OrdinalIgnoreCase) ||
            !freshPreview.CanApply)
        {
            throw new WindowsTransactionBusyException(
                "Continuity preview changed or contains a conflict.");
        }

        PreparedTarget? prepared = null;
        byte[]? stateBytes = null;
        try
        {
            prepared = PrepareTarget(request, current);
            stateBytes = _stateStore.Serialize(prepared.TargetState);
            var targetSha256 = WindowsContinuityManifestReader.Hash(stateBytes);
            var transactionId = Guid.NewGuid().ToString("N");
            var selectionSha256 = SelectionFingerprint(request);
            var backupName = $"continuity-backup-{transactionId}.json";
            var now = _clock();
            var journal = new WindowsContinuityTransactionJournal(
                1,
                transactionId,
                WindowsContinuityTransactionPhase.Prepared,
                request.Session.SourceSha256,
                request.Session.PreviewSha256,
                selectionSha256,
                current.Sha256,
                targetSha256,
                current.Sha256 is not null,
                prepared.Credentials.Select(item => item.TargetSuffix).ToArray(),
                backupName,
                now,
                now);
            _stateStore.SaveJournal(journal);

            try
            {
                WriteNewCredentials(prepared.Credentials);
                journal = Update(
                    journal,
                    WindowsContinuityTransactionPhase.CredentialsWritten);
                _stateStore.ApplyState(
                    stateBytes,
                    current.Sha256,
                    targetSha256,
                    backupName,
                    transactionId);
                journal = Update(
                    journal,
                    WindowsContinuityTransactionPhase.StateApplied);
            }
            catch (Exception error)
            {
                try
                {
                    journal = Update(
                        journal,
                        WindowsContinuityTransactionPhase.RollbackRequired);
                    Rollback(journal);
                    journal = Update(
                        journal,
                        WindowsContinuityTransactionPhase.RolledBack);
                    _stateStore.DeleteJournal(transactionId);
                }
                catch (Exception rollbackError)
                {
                    try
                    {
                        _ = Update(
                            journal,
                            WindowsContinuityTransactionPhase.RollbackFailed);
                    }
                    catch
                    {
                        // Preserve the last durable journal and original exception.
                    }
                    throw new WindowsContinuityRecoveryRequiredException(
                        "Continuity import and automatic rollback did not complete; recovery evidence was preserved.",
                        new AggregateException(error, rollbackError));
                }
                throw;
            }

            try
            {
                journal = Update(
                    journal,
                    WindowsContinuityTransactionPhase.Committed);
                _stateStore.FinalizeCommitted(journal);
            }
            catch (Exception error)
            {
                throw new WindowsContinuityRecoveryRequiredException(
                    "Continuity import was committed but cleanup still requires recovery.",
                    error);
            }
            return new WindowsContinuityApplyResult(
                transactionId,
                prepared.Credentials.Count,
                request.WorkspaceDecisions.Count,
                prepared.PreferencesChanged,
                true,
                false,
                prepared.Credentials.Count == 0
                    ? "迁移设置已保存，当前接入未切换；可继续当前工作。"
                    : "迁移设置已保存，当前接入未切换；新中转需手动选择并验证。");
        }
        finally
        {
            if (stateBytes is not null)
            {
                CryptographicOperations.ZeroMemory(stateBytes);
            }
            if (prepared is not null)
            {
                foreach (var credential in prepared.Credentials)
                {
                    CryptographicOperations.ZeroMemory(credential.Secret);
                }
            }
        }
    }

    public int RecoverPending(bool userConfirmed)
    {
        if (!userConfirmed)
        {
            throw new WindowsContinuityConfirmationRequiredException();
        }
        WindowsNativeGuard.RequireWindows("Continuity import recovery");
        using var lease = _transactionMutex.Acquire(
            WindowsContinuityContract.ContinuityMutexName,
            TimeSpan.FromSeconds(5));
        var journal = _stateStore.LoadJournal();
        if (journal is null)
        {
            return 0;
        }
        if (journal.Phase == WindowsContinuityTransactionPhase.Committed)
        {
            try
            {
                _stateStore.FinalizeCommitted(journal);
                return 1;
            }
            catch (Exception error)
            {
                throw new WindowsContinuityRecoveryRequiredException(
                    "Committed continuity cleanup remains incomplete.",
                    error);
            }
        }
        try
        {
            Rollback(journal);
            journal = Update(
                journal,
                WindowsContinuityTransactionPhase.RolledBack);
            _stateStore.DeleteJournal(journal.TransactionId);
            return 1;
        }
        catch (Exception error)
        {
            try
            {
                _ = Update(
                    journal,
                    WindowsContinuityTransactionPhase.RollbackFailed);
            }
            catch
            {
                // Keep prior durable recovery evidence.
            }
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity recovery remains incomplete.",
                error);
        }
    }

    private sealed record PreparedCredential(
        string TargetSuffix,
        string TargetName,
        byte[] Secret);

    private sealed record PreparedTarget(
        WindowsContinuityTargetState TargetState,
        IReadOnlyList<PreparedCredential> Credentials,
        bool PreferencesChanged);

    private PreparedTarget PrepareTarget(
        WindowsContinuityApplyRequest request,
        WindowsContinuityTargetState current)
    {
        var profiles = current.RelayProfiles.ToList();
        var credentials = new List<PreparedCredential>();
        try
        {
            foreach (var decision in request.RelayDecisions)
            {
                var source = request.Session.Manifest.AccessProfiles.Single(profile =>
                    profile.Id == decision.SourceId &&
                    profile.Kind == WindowsPortableAccessKind.Relay);
                if (profiles.Any(profile =>
                        profile.LocalProfileId == decision.LocalProfileId ||
                        profile.DisplayName.Equals(
                            source.DisplayName,
                            StringComparison.OrdinalIgnoreCase) ||
                        profile.BaseUrl.TrimEnd('/').Equals(
                            source.BaseUrl!.TrimEnd('/'),
                            StringComparison.OrdinalIgnoreCase)))
                {
                    throw new WindowsContinuityManifestException(
                        "Selected relay conflicts with an existing local profile.");
                }
                var suffix = WindowsContinuityManifestReader.HashText(
                    decision.LocalProfileId)[..32];
                var targetName =
                    WindowsNativeTransactionContract.CredentialTargetPrefix + suffix;
                WindowsCredentialManager.ValidateTargetName(targetName);
                profiles.Add(new WindowsContinuityTargetProfile(
                    decision.LocalProfileId,
                    source.DisplayName,
                    source.BaseUrl!,
                    source.DefaultModel!,
                    targetName,
                    false));
                credentials.Add(new PreparedCredential(
                    suffix,
                    targetName,
                    decision.CredentialUtf8.ToArray()));
            }

            var labels = new Dictionary<string, string>(
                current.WorkspaceLabels,
                StringComparer.OrdinalIgnoreCase);
            foreach (var decision in request.WorkspaceDecisions)
            {
                var source = request.Session.Manifest.WorkspaceLabels.Single(label =>
                    label.Id == decision.SourceId);
                var targetPath = Path.GetFullPath(decision.TargetPath);
                if (!current.FavoriteWorkspacePaths.Contains(
                        targetPath,
                        StringComparer.OrdinalIgnoreCase) ||
                    labels.ContainsKey(targetPath))
                {
                    throw new WindowsContinuityManifestException(
                        "Workspace label must map to one unused local favorite.");
                }
                RequireExistingFavoriteDirectory(targetPath);
                labels[targetPath] = source.Label;
            }

            var start = request.ApplyStartDestination &&
                    request.Session.Manifest.Preferences.StartDestination is { } incomingStart
                ? incomingStart
                : current.StartDestination;
            var grouping = request.ApplyHistoryGrouping &&
                    request.Session.Manifest.Preferences.HistoryGrouping is { } incomingGrouping
                ? incomingGrouping
                : current.HistoryGrouping;
            return new PreparedTarget(
                new WindowsContinuityTargetState(
                    profiles,
                    current.FavoriteWorkspacePaths,
                    labels,
                    start,
                    grouping,
                    null),
                credentials,
                start != current.StartDestination ||
                    grouping != current.HistoryGrouping);
        }
        catch
        {
            foreach (var credential in credentials)
            {
                CryptographicOperations.ZeroMemory(credential.Secret);
            }
            throw;
        }
    }

    private static void RequireExistingFavoriteDirectory(string path)
    {
        var directory = new DirectoryInfo(path);
        directory.Refresh();
        if (!directory.Exists ||
            (directory.Attributes &
                (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0)
        {
            throw new WindowsContinuityManifestException(
                "Workspace target must remain one local ordinary favorite directory.");
        }
        if (OperatingSystem.IsWindows())
        {
            var root = Path.GetPathRoot(directory.FullName) ?? string.Empty;
            if (string.IsNullOrEmpty(root) ||
                new DriveInfo(root).DriveType != DriveType.Fixed)
            {
                throw new WindowsContinuityManifestException(
                    "Workspace target must remain on a fixed local drive.");
            }
        }
    }

    private void WriteNewCredentials(
        IReadOnlyList<PreparedCredential> credentials)
    {
        var written = new List<string>();
        try
        {
            foreach (var item in credentials)
            {
                var existing = _credentialManager.ReadGenericCredential(
                    item.TargetName);
                try
                {
                    if (existing is not null)
                    {
                        throw new WindowsContinuityManifestException(
                            "Imported credential target already exists; overwrite is blocked.");
                    }
                }
                finally
                {
                    if (existing is not null)
                    {
                        CryptographicOperations.ZeroMemory(existing);
                    }
                }
                _credentialManager.WriteGenericCredential(
                    item.TargetName,
                    item.Secret);
                written.Add(item.TargetSuffix);
            }
        }
        catch
        {
            DeleteNewCredentials(written);
            throw;
        }
        finally
        {
            foreach (var item in credentials)
            {
                CryptographicOperations.ZeroMemory(item.Secret);
            }
        }
    }

    private void Rollback(WindowsContinuityTransactionJournal journal)
    {
        var current = _stateStore.CurrentStateSha256();
        if (string.Equals(
                current,
                journal.TargetStateSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            _stateStore.RestoreState(journal);
        }
        else if (string.Equals(
            current,
            journal.BeforeStateSha256,
            StringComparison.OrdinalIgnoreCase))
        {
            _stateStore.VerifyBaseline(journal.BeforeStateSha256);
        }
        else
        {
            throw new WindowsContinuityRecoveryRequiredException(
                "Continuity state matches neither baseline nor prepared target.");
        }
        DeleteNewCredentials(journal.CredentialTargetSuffixes);
    }

    private void DeleteNewCredentials(IEnumerable<string> suffixes)
    {
        foreach (var suffix in suffixes)
        {
            var target =
                WindowsNativeTransactionContract.CredentialTargetPrefix + suffix;
            _credentialManager.DeleteGenericCredential(target);
            var remaining = _credentialManager.ReadGenericCredential(target);
            try
            {
                if (remaining is not null)
                {
                    throw new WindowsContinuityRecoveryRequiredException(
                        "Imported credential cleanup did not complete.");
                }
            }
            finally
            {
                if (remaining is not null)
                {
                    CryptographicOperations.ZeroMemory(remaining);
                }
            }
        }
    }

    private WindowsContinuityTransactionJournal Update(
        WindowsContinuityTransactionJournal journal,
        WindowsContinuityTransactionPhase phase)
    {
        var updated = journal with
        {
            Phase = phase,
            UpdatedAtUtc = _clock(),
        };
        _stateStore.SaveJournal(updated);
        return updated;
    }

    private void RequireNoPendingRecovery()
    {
        if (_stateStore.LoadJournal() is not null)
        {
            throw new WindowsContinuityPendingRecoveryException();
        }
    }

    private static void ValidateDecisions(
        WindowsContinuityApplyRequest request)
    {
        if (request.RelayDecisions.Count == 0 &&
            request.WorkspaceDecisions.Count == 0 &&
            !request.ApplyStartDestination &&
            !request.ApplyHistoryGrouping)
        {
            throw new WindowsContinuityManifestException(
                "Select at least one migration field.");
        }
        if ((request.ApplyStartDestination &&
                request.Session.Manifest.Preferences.StartDestination is null) ||
            (request.ApplyHistoryGrouping &&
                request.Session.Manifest.Preferences.HistoryGrouping is null))
        {
            throw new WindowsContinuityManifestException(
                "Selected migration preference is unavailable in the source.");
        }
        if (request.RelayDecisions.Select(item => item.SourceId).Distinct().Count()
                != request.RelayDecisions.Count ||
            request.RelayDecisions.Select(item => item.LocalProfileId)
                .Distinct(StringComparer.Ordinal).Count()
                != request.RelayDecisions.Count ||
            request.WorkspaceDecisions.Select(item => item.SourceId).Distinct().Count()
                != request.WorkspaceDecisions.Count ||
            request.WorkspaceDecisions.Select(item => item.TargetPath)
                .Distinct(StringComparer.OrdinalIgnoreCase).Count()
                != request.WorkspaceDecisions.Count)
        {
            throw new WindowsContinuityManifestException(
                "Migration selections contain duplicate identifiers.");
        }
        foreach (var decision in request.RelayDecisions)
        {
            if (decision.LocalProfileId.Length is < 1 or > 128 ||
                decision.LocalProfileId.Any(character =>
                    !char.IsAsciiLetterOrDigit(character) &&
                    character is not '.' and not '_' and not '-') ||
                decision.CredentialUtf8.Length is < 1 or >
                    WindowsNativeTransactionContract.MaximumCredentialBytes)
            {
                throw new WindowsContinuityManifestException(
                    "Relay selection or credential is invalid.");
            }
            _ = request.Session.Manifest.AccessProfiles.Single(profile =>
                profile.Id == decision.SourceId &&
                profile.Kind == WindowsPortableAccessKind.Relay);
        }
        foreach (var decision in request.WorkspaceDecisions)
        {
            if (!Path.IsPathFullyQualified(decision.TargetPath))
            {
                throw new WindowsContinuityManifestException(
                    "Workspace target must be a fully qualified local favorite.");
            }
            _ = request.Session.Manifest.WorkspaceLabels.Single(label =>
                label.Id == decision.SourceId);
        }
    }

    private static string SelectionFingerprint(
        WindowsContinuityApplyRequest request)
    {
        var rows = request.RelayDecisions.Select(decision =>
                $"relay\u001f{decision.SourceId:D}\u001f{decision.LocalProfileId}")
            .Concat(request.WorkspaceDecisions.Select(decision =>
                $"workspace\u001f{decision.SourceId:D}\u001f" +
                WindowsContinuityManifestReader.HashText(
                    Path.GetFullPath(decision.TargetPath))))
            .Append($"start\u001f{request.ApplyStartDestination}")
            .Append($"history\u001f{request.ApplyHistoryGrouping}")
            .Order(StringComparer.Ordinal);
        return WindowsContinuityManifestReader.HashText(
            string.Join("\u001e", rows));
    }
}
