using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AIAccessAssistant.Core;

public static class WindowsContinuityContract
{
    public const int SourceBuild = 146;
    public const int SchemaVersion = 1;
    public const int MaximumManifestBytes = 1024 * 1024;
    public const int MaximumAccessProfiles = 1000;
    public const int MaximumWorkspaceLabels = 20;
    public const int MaximumHistoryFiles = 10000;
    public const int MaximumDirectoryEntries = 12000;
    public const int PlanLifetimeSeconds = 600;
    public const string ContinuityMutexName =
        "Local\\io.github.liewlf.aiaccessassistant.continuity.v1";
    public const string RuntimeState = "unverified";
}

public enum WindowsPortableAccessKind
{
    Official,
    Relay,
}

public enum WindowsPortableSourcePlatform
{
    MacOS,
    Windows,
}

public enum WindowsPortableStartDestination
{
    Start,
    Access,
    History,
}

public enum WindowsPortableHistoryGrouping
{
    Recent,
    Workspace,
    Recovery,
}

public sealed record WindowsPortableAccessProfile(
    Guid Id,
    WindowsPortableAccessKind Kind,
    string DisplayName,
    string? BaseUrl,
    string? DefaultModel);

public sealed record WindowsPortableWorkspaceLabel(Guid Id, string Label);

public sealed record WindowsPortablePreferences(
    WindowsPortableStartDestination? StartDestination,
    WindowsPortableHistoryGrouping? HistoryGrouping);

public sealed record WindowsPortableManifest(
    string SourceVersion,
    string SourceBuild,
    WindowsPortableSourcePlatform Platform,
    IReadOnlyList<WindowsPortableAccessProfile> AccessProfiles,
    IReadOnlyList<WindowsPortableWorkspaceLabel> WorkspaceLabels,
    WindowsPortablePreferences Preferences,
    string Sha256);

public sealed record WindowsContinuityTargetProfile(
    string LocalProfileId,
    string DisplayName,
    string BaseUrl,
    string DefaultModel,
    string CredentialTarget,
    bool Verified);

public sealed record WindowsContinuityTargetState(
    IReadOnlyList<WindowsContinuityTargetProfile> RelayProfiles,
    IReadOnlyList<string> FavoriteWorkspacePaths,
    IReadOnlyDictionary<string, string> WorkspaceLabels,
    WindowsPortableStartDestination StartDestination,
    WindowsPortableHistoryGrouping HistoryGrouping,
    string? Sha256)
{
    public static WindowsContinuityTargetState Empty { get; } = new(
        [],
        [],
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
        WindowsPortableStartDestination.Start,
        WindowsPortableHistoryGrouping.Workspace,
        null);
}

public enum WindowsContinuityDisposition
{
    NoChange,
    Add,
    Conflict,
    NeedsMapping,
    ApplyPreference,
}

public enum WindowsContinuityScope
{
    Official,
    Relay,
    Workspace,
    Preference,
}

public sealed record WindowsContinuityPreviewChange(
    string Id,
    WindowsContinuityScope Scope,
    string Title,
    string Field,
    WindowsContinuityDisposition Disposition,
    string Detail);

public sealed record WindowsContinuityPreview(
    string SourceVersion,
    string SourceBuild,
    WindowsPortableSourcePlatform SourcePlatform,
    IReadOnlyList<WindowsContinuityPreviewChange> Changes,
    IReadOnlyList<string> Warnings,
    bool CanApply,
    string Sha256);

public sealed record WindowsContinuityImportDocument(
    string SourcePath,
    WindowsPortableManifest Manifest);

public sealed record WindowsContinuityImportSession(
    string SourcePath,
    string SourceSha256,
    string? TargetStateSha256,
    string PreviewSha256,
    WindowsPortableManifest Manifest,
    WindowsContinuityPreview Preview,
    DateTimeOffset PreparedAtUtc,
    DateTimeOffset ExpiresAtUtc);

public sealed class WindowsContinuityManifestException(string message)
    : IOException(message);

public sealed class WindowsContinuityPlanExpiredException()
    : InvalidOperationException(
        "Continuity import preview expired; prepare a fresh preview.");

public sealed class WindowsContinuityManifestReader
{
    private static readonly UTF8Encoding StrictUtf8 = new(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true);

    public WindowsContinuityImportDocument Read(string sourcePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        if (!Path.GetExtension(sourcePath).Equals(
                ".json",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsContinuityManifestException(
                "Select one fully qualified local JSON migration file.");
        }

        var fullPath =
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(sourcePath);
        var file = new FileInfo(fullPath);
        RequireSafeSource(file);
        var initialLength = file.Length;
        var initialWrite = file.LastWriteTimeUtc;
        if (initialLength > WindowsContinuityContract.MaximumManifestBytes)
        {
            throw new WindowsContinuityManifestException(
                "Migration file exceeds the 1 MiB limit.");
        }

        byte[] bytes;
        using (var stream = new FileStream(
            fullPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            16 * 1024,
            FileOptions.SequentialScan))
        {
            if (stream.Length != initialLength)
            {
                throw new WindowsContinuityManifestException(
                    "Migration file changed before it was read.");
            }
            bytes = new byte[checked((int)initialLength)];
            var count = 0;
            while (count < bytes.Length)
            {
                var read = stream.Read(bytes, count, bytes.Length - count);
                if (read == 0)
                {
                    break;
                }
                count += read;
            }
            if (count != bytes.Length ||
                stream.ReadByte() != -1)
            {
                CryptographicOperations.ZeroMemory(bytes);
                throw new WindowsContinuityManifestException(
                    "Migration file changed while it was read.");
            }
        }

        file.Refresh();
        RequireSafeSource(file);
        if (file.Length != initialLength || file.LastWriteTimeUtc != initialWrite)
        {
            CryptographicOperations.ZeroMemory(bytes);
            throw new WindowsContinuityManifestException(
                "Migration file changed while it was read.");
        }

        try
        {
            var source = StrictUtf8.GetString(bytes);
            using var document = JsonDocument.Parse(
                source,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32,
                });
            var sha256 = Hash(bytes);
            var manifest = ParseManifest(document.RootElement, sha256);
            return new WindowsContinuityImportDocument(fullPath, manifest);
        }
        catch (WindowsContinuityManifestException)
        {
            throw;
        }
        catch (Exception error) when (
            error is JsonException or
            DecoderFallbackException or
            FormatException or
            InvalidOperationException or
            OverflowException)
        {
            throw new WindowsContinuityManifestException(
                "Migration file is malformed or unsupported.");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    private static WindowsPortableManifest ParseManifest(
        JsonElement root,
        string sha256)
    {
        RequireObject(
            root,
            [
                "schema_version",
                "product",
                "source_version",
                "source_build",
                "platform",
                "boundary",
                "import_policy",
                "selection",
                "access_profiles",
                "workspace_labels",
                "preferences",
            ]);
        if (Integer(root, "schema_version") !=
                WindowsContinuityContract.SchemaVersion ||
            Text(root, "product", 32) != "AI接入助手")
        {
            throw new WindowsContinuityManifestException(
                "Migration product or schema is unsupported.");
        }

        var sourceVersion = Text(root, "source_version", 64);
        var sourceBuild = Text(root, "source_build", 16);
        if (!IsVersion(sourceVersion) ||
            sourceBuild.Any(character => !char.IsAsciiDigit(character)))
        {
            throw new WindowsContinuityManifestException(
                "Migration source identity is invalid.");
        }

        var platform = Text(root, "platform", 16) switch
        {
            "macOS" => WindowsPortableSourcePlatform.MacOS,
            "windows" => WindowsPortableSourcePlatform.Windows,
            _ => throw new WindowsContinuityManifestException(
                "Migration source platform is unsupported."),
        };
        ParseBoundary(Required(root, "boundary"));
        ParseImportPolicy(Required(root, "import_policy"));
        var selection = ParseSelection(Required(root, "selection"));
        var profiles = ParseProfiles(Required(root, "access_profiles"));
        var labels = ParseWorkspaceLabels(Required(root, "workspace_labels"));
        var preferences = ParsePreferences(Required(root, "preferences"));

        if ((!selection.AccessProfiles && profiles.Count != 0) ||
            (!selection.WorkspaceLabels && labels.Count != 0) ||
            (selection.StartDestination !=
                (preferences.StartDestination is not null)) ||
            (selection.HistoryGrouping !=
                (preferences.HistoryGrouping is not null)) ||
            !selection.HasSelectedField)
        {
            throw new WindowsContinuityManifestException(
                "Migration field selection does not match its content.");
        }

        var ids = new HashSet<Guid>();
        if (profiles.Any(profile => !ids.Add(profile.Id)) ||
            labels.Any(label => !ids.Add(label.Id)))
        {
            throw new WindowsContinuityManifestException(
                "Migration identifiers must be globally unique.");
        }
        var officialCount = profiles.Count(profile =>
            profile.Kind == WindowsPortableAccessKind.Official);
        if (selection.AccessProfiles && officialCount != 1)
        {
            throw new WindowsContinuityManifestException(
                "Selected access profiles require one official entry.");
        }

        return new WindowsPortableManifest(
            sourceVersion,
            sourceBuild,
            platform,
            profiles,
            labels,
            preferences,
            sha256);
    }

    private static void ParseBoundary(JsonElement value)
    {
        var names = new[]
        {
            "credentials_included",
            "auth_files_included",
            "session_content_included",
            "workspace_paths_included",
            "configuration_files_included",
            "keychain_references_included",
        };
        RequireObject(value, names);
        if (names.Any(name => Boolean(value, name)))
        {
            throw new WindowsContinuityManifestException(
                "Migration file includes a forbidden sensitive boundary.");
        }
    }

    private static void ParseImportPolicy(JsonElement value)
    {
        RequireObject(
            value,
            [
                "preview_required",
                "field_selection_required",
                "credential_reentry_required",
                "writes_allowed",
            ]);
        if (!Boolean(value, "preview_required") ||
            !Boolean(value, "field_selection_required") ||
            !Boolean(value, "credential_reentry_required") ||
            Boolean(value, "writes_allowed"))
        {
            throw new WindowsContinuityManifestException(
                "Migration file attempts to bypass preview or enable writes.");
        }
    }

    private sealed record Selection(
        bool AccessProfiles,
        bool WorkspaceLabels,
        bool StartDestination,
        bool HistoryGrouping)
    {
        public bool HasSelectedField =>
            AccessProfiles || WorkspaceLabels ||
            StartDestination || HistoryGrouping;
    }

    private static Selection ParseSelection(JsonElement value)
    {
        RequireObject(
            value,
            [
                "access_profiles",
                "workspace_labels",
                "start_destination",
                "history_grouping",
            ]);
        return new Selection(
            Boolean(value, "access_profiles"),
            Boolean(value, "workspace_labels"),
            Boolean(value, "start_destination"),
            Boolean(value, "history_grouping"));
    }

    private static List<WindowsPortableAccessProfile> ParseProfiles(
        JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array ||
            value.GetArrayLength() >
                WindowsContinuityContract.MaximumAccessProfiles)
        {
            throw new WindowsContinuityManifestException(
                "Access profile collection is invalid or too large.");
        }
        var result = new List<WindowsPortableAccessProfile>();
        foreach (var item in value.EnumerateArray())
        {
            RequireObject(
                item,
                ["id", "kind", "display_name", "base_url", "default_model", "api_protocol"],
                ["id", "kind", "display_name"]);
            var id = Guid.Parse(Text(item, "id", 64));
            var displayName = Text(item, "display_name", 80);
            var kind = Text(item, "kind", 16);
            if (kind == "official")
            {
                RequireAbsentOrNull(item, "base_url");
                RequireAbsentOrNull(item, "default_model");
                RequireAbsentOrNull(item, "api_protocol");
                result.Add(new WindowsPortableAccessProfile(
                    id,
                    WindowsPortableAccessKind.Official,
                    displayName,
                    null,
                    null));
                continue;
            }
            if (kind != "relay")
            {
                throw new WindowsContinuityManifestException(
                    "Access kind is unsupported.");
            }
            var baseUrl = Text(item, "base_url", 2048);
            var defaultModel = Text(item, "default_model", 128);
            if (Text(item, "api_protocol", 32) != "responses" ||
                !IsSafeEndpoint(baseUrl))
            {
                throw new WindowsContinuityManifestException(
                    "Relay profile requires a safe HTTPS Responses endpoint.");
            }
            result.Add(new WindowsPortableAccessProfile(
                id,
                WindowsPortableAccessKind.Relay,
                displayName,
                baseUrl,
                defaultModel));
        }
        return result;
    }

    private static List<WindowsPortableWorkspaceLabel> ParseWorkspaceLabels(
        JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array ||
            value.GetArrayLength() >
                WindowsContinuityContract.MaximumWorkspaceLabels)
        {
            throw new WindowsContinuityManifestException(
                "Workspace label collection is invalid or too large.");
        }
        var result = new List<WindowsPortableWorkspaceLabel>();
        foreach (var item in value.EnumerateArray())
        {
            RequireObject(item, ["id", "label"]);
            result.Add(new WindowsPortableWorkspaceLabel(
                Guid.Parse(Text(item, "id", 64)),
                Text(item, "label", 40)));
        }
        return result;
    }

    private static WindowsPortablePreferences ParsePreferences(JsonElement value)
    {
        RequireObject(
            value,
            ["start_destination", "history_grouping"],
            []);
        WindowsPortableStartDestination? start = null;
        if (TryText(value, "start_destination", 32) is { } startValue)
        {
            start = startValue switch
            {
                "start" => WindowsPortableStartDestination.Start,
                "access" => WindowsPortableStartDestination.Access,
                "history" => WindowsPortableStartDestination.History,
                _ => throw new WindowsContinuityManifestException(
                    "Start destination is unsupported."),
            };
        }
        WindowsPortableHistoryGrouping? grouping = null;
        if (TryText(value, "history_grouping", 32) is { } groupingValue)
        {
            grouping = groupingValue switch
            {
                "recent" => WindowsPortableHistoryGrouping.Recent,
                "workspace" => WindowsPortableHistoryGrouping.Workspace,
                "recovery" => WindowsPortableHistoryGrouping.Recovery,
                _ => throw new WindowsContinuityManifestException(
                    "History grouping is unsupported."),
            };
        }
        return new WindowsPortablePreferences(start, grouping);
    }

    private static void RequireSafeSource(FileInfo file)
    {
        file.Refresh();
        if (!file.Exists ||
            (file.Attributes & (FileAttributes.Directory |
                FileAttributes.ReparsePoint |
                FileAttributes.Offline)) != 0 ||
            file.Directory is null)
        {
            throw new WindowsContinuityManifestException(
                "Migration source must be a local ordinary file.");
        }
        for (DirectoryInfo? directory = file.Directory;
            directory is not null;
            directory = directory.Parent)
        {
            directory.Refresh();
            if ((directory.Attributes &
                    (FileAttributes.ReparsePoint | FileAttributes.Offline)) != 0)
            {
                throw new WindowsContinuityManifestException(
                    "Migration source parent is unsafe.");
            }
        }
        if (OperatingSystem.IsWindows())
        {
            var root = Path.GetPathRoot(file.FullName) ?? string.Empty;
            if (string.IsNullOrEmpty(root) ||
                new DriveInfo(root).DriveType != DriveType.Fixed)
            {
                throw new WindowsContinuityManifestException(
                    "Migration source must be on a fixed local drive.");
            }
        }
    }

    private static bool IsSafeEndpoint(string value)
    {
        return Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
            uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
            !string.IsNullOrWhiteSpace(uri.Host) &&
            string.IsNullOrEmpty(uri.UserInfo) &&
            string.IsNullOrEmpty(uri.Query) &&
            string.IsNullOrEmpty(uri.Fragment);
    }

    private static bool IsVersion(string value)
    {
        var core = value.Split(['-', '+'], 2)[0];
        var parts = core.Split('.');
        return parts.Length is >= 2 and <= 4 &&
            parts.All(part => part.Length > 0 &&
                part.All(char.IsAsciiDigit));
    }

    private static void RequireObject(
        JsonElement value,
        IReadOnlyCollection<string> allowed,
        IReadOnlyCollection<string>? required = null)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new WindowsContinuityManifestException(
                "Migration JSON shape is invalid.");
        }
        required ??= allowed;
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!allowed.Contains(property.Name) ||
                !observed.Add(property.Name))
            {
                throw new WindowsContinuityManifestException(
                    "Migration JSON contains an unknown or duplicate field.");
            }
        }
        if (required.Any(name => !observed.Contains(name)))
        {
            throw new WindowsContinuityManifestException(
                "Migration JSON is missing a required field.");
        }
    }

    private static JsonElement Required(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var result))
        {
            throw new WindowsContinuityManifestException(
                "Migration JSON is missing a required field.");
        }
        return result;
    }

    private static string Text(JsonElement value, string name, int maximumLength)
    {
        var result = Required(value, name);
        if (result.ValueKind != JsonValueKind.String)
        {
            throw new WindowsContinuityManifestException(
                "Migration text field is invalid.");
        }
        var text = result.GetString()?.Trim() ?? string.Empty;
        if (text.Length is 0 || text.Length > maximumLength ||
            text.Any(char.IsControl))
        {
            throw new WindowsContinuityManifestException(
                "Migration text field is invalid.");
        }
        return text;
    }

    private static string? TryText(
        JsonElement value,
        string name,
        int maximumLength)
    {
        if (!value.TryGetProperty(name, out var result) ||
            result.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return Text(value, name, maximumLength);
    }

    private static int Integer(JsonElement value, string name)
    {
        var result = Required(value, name);
        if (!result.TryGetInt32(out var integer))
        {
            throw new WindowsContinuityManifestException(
                "Migration integer field is invalid.");
        }
        return integer;
    }

    private static bool Boolean(JsonElement value, string name)
    {
        var result = Required(value, name);
        return result.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new WindowsContinuityManifestException(
                "Migration Boolean field is invalid."),
        };
    }

    private static void RequireAbsentOrNull(JsonElement value, string name)
    {
        if (value.TryGetProperty(name, out var result) &&
            result.ValueKind != JsonValueKind.Null)
        {
            throw new WindowsContinuityManifestException(
                "Official access contains relay-only fields.");
        }
    }

    internal static string Hash(ReadOnlySpan<byte> bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    internal static string HashText(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        try
        {
            return Hash(bytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}

public sealed class WindowsContinuityPreflightService
{
    private readonly WindowsContinuityManifestReader _reader;
    private readonly Func<DateTimeOffset> _clock;

    public WindowsContinuityPreflightService(
        WindowsContinuityManifestReader? reader = null,
        Func<DateTimeOffset>? clock = null)
    {
        _reader = reader ?? new WindowsContinuityManifestReader();
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public WindowsContinuityImportSession Prepare(
        string sourcePath,
        WindowsContinuityTargetState target)
    {
        ArgumentNullException.ThrowIfNull(target);
        var document = _reader.Read(sourcePath);
        var preview = Inspect(document.Manifest, target);
        var preparedAt = _clock();
        return new WindowsContinuityImportSession(
            document.SourcePath,
            document.Manifest.Sha256,
            target.Sha256,
            preview.Sha256,
            document.Manifest,
            preview,
            preparedAt,
            preparedAt.AddSeconds(
                WindowsContinuityContract.PlanLifetimeSeconds));
    }

    public static WindowsContinuityPreview Inspect(
        WindowsPortableManifest manifest,
        WindowsContinuityTargetState target)
    {
        var changes = new List<WindowsContinuityPreviewChange>();
        var warnings = new List<string>
        {
            "凭据、认证文件、会话正文、源工作区路径和配置文件不会导入。",
            "导入后当前接入保持不变；新中转仍需手动选择并验证。",
        };

        foreach (var profile in manifest.AccessProfiles)
        {
            if (profile.Kind == WindowsPortableAccessKind.Official)
            {
                changes.Add(new WindowsContinuityPreviewChange(
                    profile.Id.ToString("D"),
                    WindowsContinuityScope.Official,
                    profile.DisplayName,
                    "official_access",
                    WindowsContinuityDisposition.NoChange,
                    "Windows Codex official login remains local and is not imported."));
                continue;
            }
            var exact = target.RelayProfiles.FirstOrDefault(existing =>
                Equal(existing.DisplayName, profile.DisplayName) &&
                EqualEndpoint(existing.BaseUrl, profile.BaseUrl!) &&
                Equal(existing.DefaultModel, profile.DefaultModel!));
            var conflict = target.RelayProfiles.Any(existing =>
                Equal(existing.DisplayName, profile.DisplayName) ||
                EqualEndpoint(existing.BaseUrl, profile.BaseUrl!));
            changes.Add(new WindowsContinuityPreviewChange(
                profile.Id.ToString("D"),
                WindowsContinuityScope.Relay,
                profile.DisplayName,
                "relay_profile",
                exact is not null
                    ? WindowsContinuityDisposition.NoChange
                    : conflict
                        ? WindowsContinuityDisposition.Conflict
                        : WindowsContinuityDisposition.Add,
                exact is not null
                    ? "Matching non-sensitive relay metadata already exists."
                    : conflict
                        ? "Name or endpoint conflicts with an existing relay; overwrite is blocked."
                        : "May add metadata after credential reentry and final confirmation."));
        }

        foreach (var label in manifest.WorkspaceLabels)
        {
            var existing = target.WorkspaceLabels.Values.Any(value =>
                Equal(value, label.Label));
            changes.Add(new WindowsContinuityPreviewChange(
                label.Id.ToString("D"),
                WindowsContinuityScope.Workspace,
                label.Label,
                "workspace_label",
                existing
                    ? WindowsContinuityDisposition.NoChange
                    : WindowsContinuityDisposition.NeedsMapping,
                existing
                    ? "Matching local workspace label already exists."
                    : "Map this label to one existing local favorite; no source path is available."));
        }

        if (manifest.Preferences.StartDestination is { } start)
        {
            changes.Add(PreferenceChange(
                "start_destination",
                start.ToString(),
                start == target.StartDestination));
        }
        if (manifest.Preferences.HistoryGrouping is { } grouping)
        {
            changes.Add(PreferenceChange(
                "history_grouping",
                grouping.ToString(),
                grouping == target.HistoryGrouping));
        }

        var canApply = changes.All(change =>
            change.Disposition != WindowsContinuityDisposition.Conflict) &&
            changes.Any(change => change.Disposition is
                WindowsContinuityDisposition.Add or
                WindowsContinuityDisposition.NeedsMapping or
                WindowsContinuityDisposition.ApplyPreference);
        var fingerprint = string.Join(
            '\u001e',
            changes.OrderBy(change => change.Id, StringComparer.Ordinal)
                .ThenBy(change => change.Field, StringComparer.Ordinal)
                .Select(change => string.Join(
                    '\u001f',
                    change.Id,
                    change.Scope,
                    change.Title,
                    change.Field,
                    change.Disposition,
                    change.Detail))
                .Concat(warnings.Order(StringComparer.Ordinal)));
        return new WindowsContinuityPreview(
            manifest.SourceVersion,
            manifest.SourceBuild,
            manifest.Platform,
            changes,
            warnings,
            canApply,
            WindowsContinuityManifestReader.HashText(fingerprint));
    }

    public void RequireFresh(WindowsContinuityImportSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (_clock() > session.ExpiresAtUtc)
        {
            throw new WindowsContinuityPlanExpiredException();
        }
        var fresh = _reader.Read(session.SourcePath);
        if (!string.Equals(
                fresh.Manifest.Sha256,
                session.SourceSha256,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new WindowsTransactionBusyException(
                "Migration source changed after preview.");
        }
    }

    private static WindowsContinuityPreviewChange PreferenceChange(
        string field,
        string incoming,
        bool same) => new(
            field,
            WindowsContinuityScope.Preference,
            incoming,
            field,
            same
                ? WindowsContinuityDisposition.NoChange
                : WindowsContinuityDisposition.ApplyPreference,
            same
                ? "Preference already matches."
                : "May apply after final confirmation; current access remains unchanged.");

    private static bool Equal(string left, string right) =>
        string.Equals(
            left.Trim(),
            right.Trim(),
            StringComparison.OrdinalIgnoreCase);

    private static bool EqualEndpoint(string left, string right) =>
        string.Equals(
            left.TrimEnd('/'),
            right.TrimEnd('/'),
            StringComparison.OrdinalIgnoreCase);
}
