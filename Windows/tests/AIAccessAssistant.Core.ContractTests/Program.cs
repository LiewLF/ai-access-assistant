using AIAccessAssistant.Core;
using System.Security;
using System.Security.Cryptography;
using System.Text;

namespace AIAccessAssistant.Core.ContractTests;

internal static class Program
{
    private static async Task<int> Main()
    {
        try
        {
            TestFrozenProductContract();
            TestBuild143ReadinessContract();
            TestBuild144NativeTransactionContract();
            TestBuild145ProgressiveVerificationContract();
            TestBuild146ContinuityContract();
            TestBuild147InclusiveReliabilityContract();
            TestBuild148NativeSourceGateContract();
            TestInclusiveFailureProjection();
            TestLongPathNormalizationFixture();
            TestContinuityManifestPreflightAndState();
            TestHistoryContinuityMetadataOnly();
            TestProcessQuiescenceRechecksBeforeApply();
            TestPathDiscovery();
            await TestMissingConfigurationAsync();
            await TestRedactedPreviewAsync();
            await TestOversizedConfigurationBlockedAsync();
            TestAccessRecognitionFixtures();
            await TestNpmShimReadinessAsync();
            await TestNotFoundOutcomeAsync();
            await TestProgressiveVerificationConsentAndJourneyAsync();
            await TestRelayCredentialConsentBoundaryAsync();
            await TestCleanupFailureInvalidatesSuccessAsync();
            TestProgressiveVerificationIgnoresNestedProvider();
            TestDeferredCapabilitiesFailClosed();
            TestNativeInputBoundaries();
            if (OperatingSystem.IsWindows())
            {
                TestCredentialManagerRoundTrip();
                TestNamedMutexExclusivityAndAbandonment();
                TestExistingConfigurationTransaction();
                TestMissingConfigurationTransaction();
                TestAmbiguousReplacementPreservesEvidence();
                TestContinuityApplyAndRecovery();
            }
            Console.WriteLine(
                "WINDOWS_CORE_CONTRACT=PASS discovery=bounded install-version=read-only access=redacted credential=credman transaction=replacefile-cas-confirmed continuity=preview-confirm-recover history=metadata-only mutex=fail-closed runtime=windows-only");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"WINDOWS_CORE_CONTRACT=FAIL {error}");
            return 1;
        }
    }

    private static void TestBuild143ReadinessContract()
    {
        Require(
            WindowsCodexReadinessContract.SourceBuild == 143,
            "Build143 readiness source build drifted");
        Require(
            WindowsCodexReadinessContract.MaximumPathDirectories == 128,
            "PATH candidate budget drifted");
        Require(
            WindowsCodexReadinessContract.EvidenceLevel == "source_verified",
            "Windows source evidence level drifted");
        Require(
            WindowsCodexReadinessContract.RuntimeState == "unverified",
            "source-only readiness claimed Windows runtime support");
    }

    private static void TestBuild144NativeTransactionContract()
    {
        Require(
            WindowsNativeTransactionContract.SourceBuild == 144,
            "Build144 native transaction source build drifted");
        Require(
            WindowsNativeTransactionContract.MaximumCredentialBytes == 5 * 512,
            "Credential Manager blob budget drifted");
        Require(
            WindowsNativeTransactionContract.MaximumConfigurationBytes ==
                2 * 1024 * 1024,
            "configuration transaction byte budget drifted");
        Require(
            WindowsNativeTransactionContract.RuntimeState == "unverified",
            "source-only Build144 claimed Windows runtime support");
    }

    private static void TestBuild145ProgressiveVerificationContract()
    {
        Require(
            WindowsProgressiveVerificationContract.SourceBuild == 145,
            "Build145 progressive verification source build drifted");
        Require(
            WindowsProgressiveVerificationContract.MaximumRequestsPerStep == 1 &&
            WindowsProgressiveVerificationContract.BasicTimeoutSeconds == 60 &&
            WindowsProgressiveVerificationContract.RealTaskTimeoutSeconds == 90,
            "Build145 request or timeout budget drifted");
        Require(
            WindowsProgressiveVerificationContract.RuntimeState == "unverified",
            "source-only Build145 claimed Windows runtime support");

        var quota = WindowsVerificationFailureProjector.Project(
            WindowsVerificationStep.BasicConnection,
            WindowsVerificationFailureStage.Quota,
            WindowsVerificationFailureCategory.QuotaExhausted,
            429);
        Require(
            quota.PrimaryAction == WindowsVerificationPrimaryAction.ReviewQuota &&
            quota.Evidence.Count == 4,
            "explicit quota evidence did not produce one quota action");
        var permission = WindowsVerificationFailureProjector.Project(
            WindowsVerificationStep.BasicConnection,
            WindowsVerificationFailureStage.Connection,
            WindowsVerificationFailureCategory.Permission,
            403);
        Require(
            permission.PrimaryAction ==
                WindowsVerificationPrimaryAction.OpenAdvancedDiagnostics &&
            permission.Explanation.Contains("不能据此断定", StringComparison.Ordinal),
            "HTTP 403 was misclassified as an API-key or login error");
        var relayAuthentication = WindowsVerificationFailureProjector.Project(
            WindowsVerificationStep.BasicConnection,
            WindowsVerificationFailureStage.Login,
            WindowsVerificationFailureCategory.Authentication,
            401,
            WindowsCodexAccessKind.Relay);
        Require(
            relayAuthentication.PrimaryAction ==
                WindowsVerificationPrimaryAction.ReviewRelayProfile,
            "relay authentication failure incorrectly opened official Codex login");
        var timeout = WindowsVerificationFailureProjector.Project(
            WindowsVerificationStep.RealTask,
            WindowsVerificationFailureStage.Timeout,
            WindowsVerificationFailureCategory.Timeout);
        Require(
            timeout.PrimaryAction ==
                WindowsVerificationPrimaryAction.ReviewOwnedCodexProcess,
            "timeout failure encouraged retry before checking the owned Codex process");
    }

    private static void TestProcessQuiescenceRechecksBeforeApply()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var path = Path.Combine(root, "config.toml");
            const string original = "model_provider = \"openai\"\n";
            const string proposed = "model_provider = \"fixture\"\n";
            File.WriteAllText(path, original, new UTF8Encoding(false));
            var controller = new FixtureProcessController();
            var service = new WindowsQuiescentConfigurationTransactionService(
                new WindowsProcessQuiescenceService(controller));
            var plan = service.Prepare(path, proposed);
            controller.Writers = [42];

            RequireThrows<WindowsProcessQuiescenceRequiredException>(
                () => service.Apply(plan, userConfirmed: true),
                "pre-apply process quiescence did not block a newly observed writer");
            Require(
                File.ReadAllText(path) == original &&
                controller.GracefulExitRequests == 0,
                "process quiescence changed configuration or closed Codex automatically");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestBuild146ContinuityContract()
    {
        Require(
            WindowsContinuityContract.SourceBuild == 146 &&
            WindowsContinuityContract.SchemaVersion == 1,
            "Build146 continuity identity drifted");
        Require(
            WindowsContinuityContract.MaximumManifestBytes == 1024 * 1024 &&
            WindowsContinuityContract.MaximumHistoryFiles == 10000 &&
            WindowsContinuityContract.MaximumDirectoryEntries == 12000 &&
            WindowsContinuityContract.PlanLifetimeSeconds == 600,
            "Build146 continuity bounds drifted");
        Require(
            WindowsContinuityContract.RuntimeState == "unverified",
            "source-only Build146 claimed Windows runtime support");
    }

    private static void TestBuild147InclusiveReliabilityContract()
    {
        Require(
            WindowsInclusiveReliabilityContract.SourceBuild == 147 &&
            WindowsInclusiveReliabilityContract.NarrowEffectiveWidth == 820 &&
            WindowsInclusiveReliabilityContract.MaximumNormalizedPathCharacters ==
                32760,
            "Build147 inclusive reliability identity or bounds drifted");
        Require(
            WindowsInclusiveReliabilityContract.EvidenceLevel ==
                "source_verified" &&
            WindowsInclusiveReliabilityContract.RuntimeState == "unverified",
            "Build147 source checks claimed Windows accessibility runtime support");
    }

    private static void TestBuild148NativeSourceGateContract()
    {
        Require(
            WindowsNativeSourceGateContract.SourceBuild == 148 &&
            WindowsNativeSourceGateContract.ProductVersion == "0.12.0" &&
            WindowsNativeSourceGateContract.FileVersion == "0.12.0.148" &&
            WindowsNativeSourceGateContract.InformationalVersion ==
                "0.12.0+build.148" &&
            WindowsNativeSourceGateContract.TargetFramework ==
                "net10.0-windows10.0.26100.0" &&
            WindowsNativeSourceGateContract.RuntimeIdentifier == "win-x64" &&
            WindowsNativeSourceGateContract.RunnerImage ==
                "windows-2025-vs2026",
            "Build148 native source identity or runner contract drifted");
        Require(
            WindowsNativeSourceGateContract.NativeBuildState ==
                "defined_not_run" &&
            WindowsNativeSourceGateContract.WindowsRuntimeState ==
                "unverified" &&
            !WindowsNativeSourceGateContract.PackageGenerationAllowed &&
            !WindowsNativeSourceGateContract.InstallerGenerationAllowed &&
            !WindowsNativeSourceGateContract.ArtifactUploadAllowed &&
            !WindowsNativeSourceGateContract.PublicReleaseAllowed,
            "Build148 source gate claimed native execution, packaging, upload, or release");
    }

    private static void TestInclusiveFailureProjection()
    {
        const string sensitivePath = @"C:\PrivateFixture\secret.json";
        var permission = WindowsInclusiveFailureProjector.Project(
            new UnauthorizedAccessException(sensitivePath),
            WindowsInclusiveOperation.HistoryRefresh);
        Require(
            permission.Code == WindowsInclusiveFailureCode.PermissionDenied &&
            permission.PrimaryAction.Contains("sessions", StringComparison.Ordinal) &&
            !permission.AutomaticRetry &&
            !permission.AutomaticElevation &&
            !permission.RawExceptionTextVisible &&
            !permission.RawPathVisible &&
            permission.CurrentWorkPreserved &&
            !string.Join(
                    "\n",
                    permission.Conclusion,
                    permission.PrimaryAction,
                    permission.Continuation)
                .Contains(sensitivePath, StringComparison.Ordinal),
            "permission failure leaked a path or lost its one safe action");

        var security = WindowsInclusiveFailureProjector.Project(
            new AggregateException(new SecurityException(sensitivePath)),
            WindowsInclusiveOperation.ContinuityImport);
        Require(
            security.Code == WindowsInclusiveFailureCode.PermissionDenied &&
            security.PrimaryAction.Contains("迁移 JSON", StringComparison.Ordinal),
            "nested security exception did not preserve operation-specific guidance");

        var tooLong = WindowsInclusiveFailureProjector.Project(
            new PathTooLongException(sensitivePath),
            WindowsInclusiveOperation.ConfigurationTransaction);
        Require(
            tooLong.Code == WindowsInclusiveFailureCode.PathTooLong &&
            tooLong.PrimaryAction.Contains("层级更短", StringComparison.Ordinal) &&
            !tooLong.PrimaryAction.Contains(sensitivePath, StringComparison.Ordinal),
            "long-path failure leaked its path or lacked one recovery action");

        var missing = WindowsInclusiveFailureProjector.Project(
            new DirectoryNotFoundException(sensitivePath),
            WindowsInclusiveOperation.ContinuityRecovery);
        Require(
            missing.Code == WindowsInclusiveFailureCode.PathUnavailable &&
            missing.PrimaryAction.Contains("不要新建", StringComparison.Ordinal),
            "missing recovery directory encouraged fabricated recovery evidence");
    }

    private static void TestLongPathNormalizationFixture()
    {
        var longPath = Path.Combine(
            Path.GetFullPath(Path.GetTempPath()),
            new string('a', 90),
            new string('b', 90),
            new string('c', 90),
            "continuity.json");
        var normalized =
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(longPath);
        Require(
            WindowsInclusivePathPolicy.IsLongPath(normalized) &&
            normalized.Length > 260 &&
            normalized.EndsWith("continuity.json", StringComparison.Ordinal) &&
            normalized == Path.GetFullPath(longPath),
            "ordinary local long path was rejected, truncated, or rewritten");
        RequireThrows<IOException>(
            () => WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(
                @"\\server\share\continuity.json"),
            "UNC path was accepted by long-path policy");
        RequireThrows<IOException>(
            () => WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(
                @"\\?\C:\fixture\continuity.json"),
            "device-prefixed path was accepted by long-path policy");
        RequireThrows<IOException>(
            () => WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(
                "relative-continuity.json"),
            "relative path was accepted by long-path policy");
    }

    private static void TestContinuityManifestPreflightAndState()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var favorite = Path.Combine(root, "favorite");
            Directory.CreateDirectory(favorite);
            var source = Path.Combine(root, "continuity.json");
            var valid = ValidContinuityManifest();
            File.WriteAllText(source, valid, new UTF8Encoding(false));

            var target = new WindowsContinuityTargetState(
                [],
                [favorite],
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
                WindowsPortableStartDestination.Start,
                WindowsPortableHistoryGrouping.Workspace,
                null);
            var session = new WindowsContinuityPreflightService().Prepare(
                source,
                target);
            Require(
                session.Manifest.AccessProfiles.Count == 2 &&
                session.Preview.Changes.Any(change =>
                    change.Scope == WindowsContinuityScope.Relay &&
                    change.Disposition == WindowsContinuityDisposition.Add) &&
                session.Preview.Changes.Any(change =>
                    change.Scope == WindowsContinuityScope.Workspace &&
                    change.Disposition ==
                        WindowsContinuityDisposition.NeedsMapping) &&
                session.Preview.CanApply,
                "valid non-sensitive continuity preview was not actionable");
            Require(
                Directory.EnumerateFiles(root).Count() == 1,
                "continuity preflight wrote target state or recovery evidence");

            var unknown = Path.Combine(root, "unknown.json");
            File.WriteAllText(
                unknown,
                valid.Replace(
                    "\"product\": \"AI接入助手\",",
                    "\"product\": \"AI接入助手\",\n  \"unexpected\": true,"),
                new UTF8Encoding(false));
            RequireThrows<WindowsContinuityManifestException>(
                () => new WindowsContinuityManifestReader().Read(unknown),
                "unknown continuity field was not blocked");

            var sensitive = Path.Combine(root, "sensitive.json");
            File.WriteAllText(
                sensitive,
                valid.Replace(
                    "\"credentials_included\": false",
                    "\"credentials_included\": true"),
                new UTF8Encoding(false));
            RequireThrows<WindowsContinuityManifestException>(
                () => new WindowsContinuityManifestReader().Read(sensitive),
                "sensitive continuity boundary was not blocked");

            var unsafeEndpoint = Path.Combine(root, "unsafe-endpoint.json");
            File.WriteAllText(
                unsafeEndpoint,
                valid.Replace(
                    "https://relay.example.com/v1",
                    "http://relay.example.com/v1?token=leak"),
                new UTF8Encoding(false));
            RequireThrows<WindowsContinuityManifestException>(
                () => new WindowsContinuityManifestReader().Read(unsafeEndpoint),
                "unsafe relay endpoint was not blocked");

            const string localProfileId = "relay-local";
            var credentialTargetSuffix = Convert.ToHexString(SHA256.HashData(
                    Encoding.UTF8.GetBytes(localProfileId)))
                .ToLowerInvariant()[..32];
            var profile = new WindowsContinuityTargetProfile(
                localProfileId,
                "迁移中转",
                "https://relay.example.com/v1",
                "gpt-fixture",
                WindowsNativeTransactionContract.CredentialTargetPrefix +
                    credentialTargetSuffix,
                Verified: false);
            var store = new WindowsContinuityStateStore(
                Path.Combine(root, "state"));
            var bytes = store.Serialize(new WindowsContinuityTargetState(
                [profile],
                [favorite],
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    [favorite] = "本机收藏",
                },
                WindowsPortableStartDestination.History,
                WindowsPortableHistoryGrouping.Recent,
                null));
            try
            {
                var text = Encoding.UTF8.GetString(bytes);
                Require(
                    text.Contains("\"verified\": false", StringComparison.Ordinal) &&
                    !text.Contains("api-key", StringComparison.OrdinalIgnoreCase),
                    "continuity state adopted verification or serialized a secret");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
            RequireThrows<WindowsContinuityManifestException>(
                () => store.Serialize(new WindowsContinuityTargetState(
                    [profile with { Verified = true }],
                    [favorite],
                    new Dictionary<string, string>(),
                    WindowsPortableStartDestination.Start,
                    WindowsPortableHistoryGrouping.Workspace,
                    null)),
                "imported continuity state adopted verification");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestHistoryContinuityMetadataOnly()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var paths = PathsFor(root);
            var day = Path.Combine(
                paths.CodexHome,
                "sessions",
                "2026",
                "08",
                "20");
            Directory.CreateDirectory(day);
            var older = Path.Combine(day, "older.jsonl");
            var newer = Path.Combine(day, "newer.jsonl");
            var empty = Path.Combine(day, "empty.jsonl");
            File.WriteAllText(
                older,
                "prompt=must-never-be-read",
                new UTF8Encoding(false));
            File.WriteAllText(
                newer,
                "response=must-never-be-read",
                new UTF8Encoding(false));
            File.WriteAllBytes(empty, []);
            File.SetLastWriteTimeUtc(older, new DateTime(2026, 8, 20, 1, 0, 0, DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(newer, new DateTime(2026, 8, 20, 2, 0, 0, DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(empty, new DateTime(2026, 8, 20, 0, 0, 0, DateTimeKind.Utc));

            using var locked = new FileStream(
                newer,
                FileMode.Open,
                FileAccess.ReadWrite,
                FileShare.None);
            var snapshot = new WindowsHistoryContinuityScanner(
                () => new DateTimeOffset(2026, 8, 20, 3, 0, 0, TimeSpan.Zero))
                .Scan(paths);
            Require(
                snapshot.Entries.Count == 3 &&
                snapshot.Entries[0].LastWriteUtc >
                    snapshot.Entries[1].LastWriteUtc &&
                snapshot.Entries.All(entry =>
                    entry.OpaqueId.Length == 64 &&
                    entry.OpaqueId.All(character =>
                        char.IsAsciiHexDigit(character) &&
                        !char.IsUpper(character))) &&
                snapshot.Entries.Any(entry =>
                    entry.State == WindowsHistoryEntryState.EmptyNeedsAttention) &&
                !snapshot.SessionContentRead &&
                !snapshot.CloudIndexUsed,
                "history metadata scan read content, leaked identity, or sorted incorrectly");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestFrozenProductContract()
    {
        Require(WindowsProductContract.SourceBuild == 142, "source build drifted");
        Require(
            WindowsProductContract.MinimumWindowsBuild == 22000,
            "minimum Windows build drifted");
        Require(
            WindowsProductContract.RuntimeIdentifier == "win-x64",
            "runtime identifier drifted");
        Require(
            WindowsProductContract.RuntimeState == "unverified",
            "source-only candidate claimed Windows runtime support");
    }

    private static void TestPathDiscovery()
    {
        var paths = CodexConfigurationPaths.Discover(name => name switch
        {
            "USERPROFILE" => @"C:\Users\ExampleUser",
            "CODEX_HOME" => null,
            _ => null,
        });

        Require(
            paths.ConfigurationFile.EndsWith(
                @"\.codex\config.toml",
                StringComparison.OrdinalIgnoreCase),
            "standard config path not discovered");
        Require(
            !paths.ConfigurationFile.Contains("/Users/", StringComparison.Ordinal),
            "macOS path leaked into Windows discovery");

        var overridePaths = CodexConfigurationPaths.Discover(name => name switch
        {
            "USERPROFILE" => @"C:\Users\ExampleUser",
            "CODEX_HOME" => @"D:\CodexHome",
            _ => null,
        });
        Require(
            overridePaths.ConfigurationFile.Equals(
                @"D:\CodexHome\config.toml",
                StringComparison.OrdinalIgnoreCase),
            "CODEX_HOME override not honored");
    }

    private static async Task TestMissingConfigurationAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var paths = PathsFor(root);
            var result = await new ReadOnlyConfigurationPreviewService().ReadAsync(paths);
            Require(!result.Exists, "missing config reported as present");
            Require(result.Content.Length == 0, "missing config returned content");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task TestRedactedPreviewAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var paths = PathsFor(root);
            Directory.CreateDirectory(paths.CodexHome);
            const string secret = "fixture-sensitive-value";
            var source = $"model = \"gpt-test\"\r\n\"api_key\" = \"{secret}\"\r\nservice_tier = \"standard\"\r\n";
            await File.WriteAllTextAsync(paths.ConfigurationFile, source, new UTF8Encoding(false));

            var result = await new ReadOnlyConfigurationPreviewService().ReadAsync(paths);
            Require(result.Exists, "existing config reported missing");
            Require(result.Redacted, "sensitive assignment was not marked redacted");
            Require(!result.Content.Contains(secret, StringComparison.Ordinal), "secret leaked into preview");
            Require(result.Content.Contains("\"api_key\" = \"<redacted>\"", StringComparison.Ordinal), "redaction marker missing");
            Require(result.Content.Contains("model = \"gpt-test\"", StringComparison.Ordinal), "safe field removed");
            Require(await File.ReadAllTextAsync(paths.ConfigurationFile) == source, "preview modified config file");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task TestOversizedConfigurationBlockedAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var paths = PathsFor(root);
            Directory.CreateDirectory(paths.CodexHome);
            await using (var stream = File.Create(paths.ConfigurationFile))
            {
                stream.SetLength(ReadOnlyConfigurationPreviewService.MaximumConfigurationBytes + 1L);
            }

            await RequireThrowsAsync<ConfigurationPreviewException>(
                () => new ReadOnlyConfigurationPreviewService().ReadAsync(paths),
                "oversized config was not blocked");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestAccessRecognitionFixtures()
    {
        var defaultOfficial = WindowsCodexAccessRecognizer.Recognize(
            PreviewFor(string.Empty, exists: false));
        Require(
            defaultOfficial.Kind == WindowsCodexAccessKind.Official &&
            !defaultOfficial.ExplicitProvider,
            "missing root provider was not recognized as official default");

        var explicitOfficial = WindowsCodexAccessRecognizer.Recognize(
            PreviewFor("model_provider = \"openai\" # explicit\r\n"));
        Require(
            explicitOfficial.Kind == WindowsCodexAccessKind.Official &&
            explicitOfficial.ExplicitProvider,
            "explicit openai provider was not recognized as official");

        const string relayIdentifier = "fixture-private-relay-id";
        var relay = WindowsCodexAccessRecognizer.Recognize(
            PreviewFor($"model_provider = \"{relayIdentifier}\"\n"));
        Require(
            relay.Kind == WindowsCodexAccessKind.Relay,
            "relay provider was not recognized");
        Require(
            !relay.Summary.Contains(relayIdentifier, StringComparison.Ordinal),
            "relay identifier leaked into user summary");

        var nestedProvider = WindowsCodexAccessRecognizer.Recognize(
            PreviewFor(
                "[model_providers.fixture]\n" +
                "model_provider = \"nested-value\"\n"));
        Require(
            nestedProvider.Kind == WindowsCodexAccessKind.Official &&
            !nestedProvider.ExplicitProvider,
            "nested provider field was mistaken for root current access");

        var duplicate = WindowsCodexAccessRecognizer.Recognize(
            PreviewFor(
                "model_provider = \"openai\"\n" +
                "model_provider = \"fixture\"\n"));
        Require(
            duplicate.Kind == WindowsCodexAccessKind.Blocked,
            "duplicate root provider did not fail closed");

        var invalid = WindowsCodexAccessRecognizer.Recognize(
            PreviewFor("model_provider = unquoted\n"));
        Require(
            invalid.Kind == WindowsCodexAccessKind.Blocked,
            "invalid root provider did not fail closed");
    }

    private static async Task TestNpmShimReadinessAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var userProfile = Path.Combine(root, "user");
            var codexHome = Path.Combine(root, "codex-home");
            var localAppData = Path.Combine(root, "local-app-data");
            var npmDirectory = Path.Combine(root, "npm");
            Directory.CreateDirectory(userProfile);
            Directory.CreateDirectory(codexHome);
            Directory.CreateDirectory(localAppData);
            Directory.CreateDirectory(npmDirectory);

            var shimPath = Path.Combine(npmDirectory, "codex.cmd");
            const string shim =
                "@echo off\r\nnode \"%~dp0\\node_modules\\@openai\\codex\\bin\\codex.js\" %*\r\n";
            await File.WriteAllTextAsync(
                shimPath,
                shim,
                new UTF8Encoding(false));
            var packageDirectory = Path.Combine(
                npmDirectory,
                "node_modules",
                "@openai",
                "codex");
            Directory.CreateDirectory(packageDirectory);
            await File.WriteAllTextAsync(
                Path.Combine(packageDirectory, "package.json"),
                "{\"version\":\"9.8.7\"}\n",
                new UTF8Encoding(false));

            const string relayIdentifier = "fixture-relay-must-not-leak";
            var configurationPath = Path.Combine(codexHome, "config.toml");
            var configuration =
                $"model_provider = \"{relayIdentifier}\"\r\n";
            await File.WriteAllTextAsync(
                configurationPath,
                configuration,
                new UTF8Encoding(false));
            var shimBefore = await File.ReadAllBytesAsync(shimPath);
            var configurationBefore = await File.ReadAllBytesAsync(
                configurationPath);

            var service = new ReadOnlyWindowsCodexReadinessService(
                name => name switch
                {
                    "USERPROFILE" => userProfile,
                    "CODEX_HOME" => codexHome,
                    "LOCALAPPDATA" => localAppData,
                    "PATH" => npmDirectory,
                    _ => null,
                });
            var snapshot = await service.InspectAsync();

            Require(
                snapshot.Installation.State ==
                    WindowsCodexInstallationState.Found,
                "valid npm Codex shim was not recognized");
            Require(
                snapshot.Installation.CandidateKind == "codex.cmd" &&
                snapshot.Installation.VersionState ==
                    WindowsCodexVersionState.Known &&
                snapshot.Installation.Version == "9.8.7",
                "npm Codex version was not recognized");
            Require(
                snapshot.Access.Kind == WindowsCodexAccessKind.Relay,
                "current relay access was not recognized");
            Require(
                snapshot.Outcome.State == WindowsCanWorkState.Unverified &&
                snapshot.Outcome.Conclusion.Contains(
                    "尚未验证",
                    StringComparison.Ordinal),
                "installation and config existence incorrectly claimed task readiness");
            Require(
                !snapshot.Access.Summary.Contains(
                    relayIdentifier,
                    StringComparison.Ordinal) &&
                !snapshot.Outcome.Conclusion.Contains(
                    relayIdentifier,
                    StringComparison.Ordinal),
                "relay identifier leaked into readiness summary");
            Require(
                (await File.ReadAllBytesAsync(shimPath))
                    .SequenceEqual(shimBefore),
                "readiness inspection modified Codex shim");
            Require(
                (await File.ReadAllBytesAsync(configurationPath))
                    .SequenceEqual(configurationBefore),
                "readiness inspection modified config.toml");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task TestNotFoundOutcomeAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var userProfile = Path.Combine(root, "user");
            var localAppData = Path.Combine(root, "local-app-data");
            Directory.CreateDirectory(userProfile);
            Directory.CreateDirectory(localAppData);

            var service = new ReadOnlyWindowsCodexReadinessService(
                name => name switch
                {
                    "USERPROFILE" => userProfile,
                    "CODEX_HOME" => Path.Combine(root, "codex-home"),
                    "LOCALAPPDATA" => localAppData,
                    "PATH" => null,
                    _ => null,
                });
            var snapshot = await service.InspectAsync();
            Require(
                snapshot.Installation.State ==
                    WindowsCodexInstallationState.NotFound,
                "bounded missing installation was not reported as not found");
            Require(
                snapshot.Outcome.State == WindowsCanWorkState.NotReady &&
                snapshot.Outcome.PrimaryAction.Contains(
                    "PATH",
                    StringComparison.Ordinal),
                "missing installation did not produce one safe next action");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task TestProgressiveVerificationConsentAndJourneyAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var executable = Path.Combine(root, "codex.exe");
            await File.WriteAllBytesAsync(executable, [(byte)'M', (byte)'Z', 1, 2]);
            var configurationPath = Path.Combine(root, "config.toml");
            const string configuration =
                "model_provider = \"openai\"\nmodel = \"gpt-fixture\"\n";
            await File.WriteAllTextAsync(
                configurationPath,
                configuration,
                new UTF8Encoding(false));
            var preview = new ConfigurationPreview(
                configurationPath,
                configuration,
                Encoding.UTF8.GetByteCount(configuration),
                true,
                false,
                "fixture");
            var snapshot = VerificationSnapshot(
                executable,
                preview,
                WindowsCodexAccessKind.Official);
            var runner = new FixtureVerificationRunner();
            var credentials = new FixtureCredentialManager();
            var service = new WindowsProgressiveVerificationService(
                runner,
                credentials,
                () => DateTimeOffset.Parse("2026-08-20T10:00:00Z"));

            var basicPlan = service.Prepare(
                snapshot,
                WindowsVerificationStep.BasicConnection);
            await RequireThrowsAsync<WindowsVerificationConsentRequiredException>(
                () => service.ExecuteAsync(basicPlan, userConfirmed: false),
                "cancelled basic verification started a request");
            Require(
                runner.CallCount == 0 && credentials.ReadCount == 0,
                "cancelled basic verification used process, network, or credential data");

            var basic = await service.ExecuteAsync(
                basicPlan,
                userConfirmed: true);
            Require(
                basic.Stage == WindowsVerificationStage.NeedsRealTask &&
                basic.Receipt?.Passed == true &&
                basic.Receipt.RequestCount == 1 &&
                runner.CallCount == 1,
                "basic verification did not stop at step one");

            var realPlan = service.Prepare(
                snapshot,
                WindowsVerificationStep.RealTask);
            Require(
                realPlan.PlanId != basicPlan.PlanId,
                "real task reused the basic consent plan");
            var ready = await service.ExecuteAsync(
                realPlan,
                userConfirmed: true);
            Require(
                ready.Stage == WindowsVerificationStage.Ready &&
                ready.Receipt?.Passed == true &&
                ready.Receipt.ToolCallCount == 1 &&
                runner.CallCount == 2,
                "real-task verification did not require a second successful request");

            var stalePlan = service.Prepare(
                snapshot,
                WindowsVerificationStep.BasicConnection);
            await File.AppendAllTextAsync(
                configurationPath,
                "# drift\n",
                new UTF8Encoding(false));
            var drift = await service.ExecuteAsync(
                stalePlan,
                userConfirmed: true);
            Require(
                drift.Stage == WindowsVerificationStage.BasicFailed &&
                drift.Failure?.PrimaryAction ==
                    WindowsVerificationPrimaryAction.StopOtherConfigurationTools &&
                runner.CallCount == 2,
                "configuration drift did not block the request at zero additional calls");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task TestRelayCredentialConsentBoundaryAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var executable = Path.Combine(root, "codex.exe");
            await File.WriteAllBytesAsync(executable, [(byte)'M', (byte)'Z', 3, 4]);
            var configurationPath = Path.Combine(root, "config.toml");
            const string configuration =
                "model_provider = \"fixture_relay\"\n" +
                "model = \"gpt-fixture\"\n" +
                "[model_providers.fixture_relay]\n" +
                "env_key = \"AI_ACCESS_RELAY_KEY\"\n";
            await File.WriteAllTextAsync(
                configurationPath,
                configuration,
                new UTF8Encoding(false));
            var preview = new ConfigurationPreview(
                configurationPath,
                configuration,
                Encoding.UTF8.GetByteCount(configuration),
                true,
                true,
                "fixture");
            var snapshot = VerificationSnapshot(
                executable,
                preview,
                WindowsCodexAccessKind.Relay);
            var runner = new FixtureVerificationRunner();
            var credentials = new FixtureCredentialManager(
                Encoding.UTF8.GetBytes("fixture-relay-secret"));
            var service = new WindowsProgressiveVerificationService(
                runner,
                credentials,
                () => DateTimeOffset.Parse("2026-08-20T10:00:00Z"));
            var plan = service.Prepare(
                snapshot,
                WindowsVerificationStep.BasicConnection);

            await RequireThrowsAsync<WindowsVerificationConsentRequiredException>(
                () => service.ExecuteAsync(plan, userConfirmed: false),
                "cancelled relay verification read a credential");
            Require(credentials.ReadCount == 0, "relay credential was read before consent");

            var outcome = await service.ExecuteAsync(plan, userConfirmed: true);
            Require(
                outcome.Stage == WindowsVerificationStage.NeedsRealTask &&
                credentials.ReadCount == 1 &&
                runner.ObservedCredential &&
                credentials.LastReturned is not null &&
                credentials.LastReturned.All(value => value == 0),
                "relay credential was not consent-bound or zeroed after process use");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task TestCleanupFailureInvalidatesSuccessAsync()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var executable = Path.Combine(root, "codex.exe");
            await File.WriteAllBytesAsync(executable, [(byte)'M', (byte)'Z', 5, 6]);
            var configurationPath = Path.Combine(root, "config.toml");
            const string configuration = "model_provider = \"openai\"\n";
            await File.WriteAllTextAsync(
                configurationPath,
                configuration,
                new UTF8Encoding(false));
            var preview = new ConfigurationPreview(
                configurationPath,
                configuration,
                Encoding.UTF8.GetByteCount(configuration),
                true,
                false,
                "fixture");
            var snapshot = VerificationSnapshot(
                executable,
                preview,
                WindowsCodexAccessKind.Official);
            var sandbox = Path.Combine(root, "cleanup-fixture");
            var runner = new FixtureVerificationRunner();
            var service = new WindowsProgressiveVerificationService(
                runner,
                new FixtureCredentialManager(),
                () => DateTimeOffset.Parse("2026-08-20T10:00:00Z"),
                () =>
                {
                    Directory.CreateDirectory(sandbox);
                    return sandbox;
                },
                _ => false);

            var plan = service.Prepare(
                snapshot,
                WindowsVerificationStep.BasicConnection);
            var outcome = await service.ExecuteAsync(plan, userConfirmed: true);
            Require(
                outcome.Stage == WindowsVerificationStage.BasicFailed &&
                outcome.Receipt?.Passed == false &&
                outcome.Failure?.PrimaryAction ==
                    WindowsVerificationPrimaryAction.RestartAssistant &&
                runner.CallCount == 1,
                "cleanup failure incorrectly adopted a successful verification result");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestProgressiveVerificationIgnoresNestedProvider()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var executable = Path.Combine(root, "codex.exe");
            File.WriteAllBytes(executable, [(byte)'M', (byte)'Z', 7, 8]);
            var configurationPath = Path.Combine(root, "config.toml");
            const string configuration =
                "[profiles.fixture]\n" +
                "model_provider = \"must-not-be-root\"\n";
            File.WriteAllText(
                configurationPath,
                configuration,
                new UTF8Encoding(false));
            var preview = new ConfigurationPreview(
                configurationPath,
                configuration,
                Encoding.UTF8.GetByteCount(configuration),
                true,
                false,
                "fixture");
            var service = new WindowsProgressiveVerificationService(
                new FixtureVerificationRunner(),
                new FixtureCredentialManager(),
                () => DateTimeOffset.Parse("2026-08-20T10:00:00Z"));

            var plan = service.Prepare(
                VerificationSnapshot(
                    executable,
                    preview,
                    WindowsCodexAccessKind.Official),
                WindowsVerificationStep.BasicConnection);
            Require(
                plan.AccessKind == WindowsCodexAccessKind.Official &&
                plan.CredentialTarget is null,
                "nested model_provider was incorrectly treated as the current root access");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static WindowsCodexReadinessSnapshot VerificationSnapshot(
        string executable,
        ConfigurationPreview preview,
        WindowsCodexAccessKind accessKind)
    {
        return new WindowsCodexReadinessSnapshot(
            new WindowsCodexInstallationEvidence(
                WindowsCodexInstallationState.Found,
                WindowsCodexVersionState.Known,
                "fixture",
                "codex.exe",
                "fixture",
                "fixture",
                executable),
            new WindowsCodexAccessEvidence(
                accessKind,
                true,
                "fixture redacted summary"),
            new WindowsUserOutcome(
                WindowsCanWorkState.Unverified,
                "unverified",
                "verify",
                "unchanged"),
            preview,
            "fixture",
            "source_verified",
            "unverified");
    }

    private static void TestDeferredCapabilitiesFailClosed()
    {
        RequireThrows<PlatformCapabilityUnavailableException>(
            () => new DeferredCredentialManager().ReadGenericCredential("fixture"),
            "Credential Manager read did not fail closed");
        RequireThrows<PlatformCapabilityUnavailableException>(
            () => new DeferredAtomicFileReplacer().Snapshot("fixture"),
            "ReplaceFile/ACL snapshot did not fail closed");
        RequireThrows<PlatformCapabilityUnavailableException>(
            () => new DeferredTransactionMutex().Acquire("Local\\fixture", TimeSpan.Zero),
            "Named Mutex did not fail closed");
        RequireThrows<PlatformCapabilityUnavailableException>(
            () => new DeferredProcessController().FindConfigurationWriters(),
            "process discovery did not fail closed");
    }

    private static void TestNativeInputBoundaries()
    {
        RequireThrows<ArgumentException>(
            () => WindowsCredentialManager.ValidateTargetName("foreign/relay/fixture"),
            "foreign credential namespace was accepted");
        RequireThrows<ArgumentException>(
            () => WindowsCredentialManager.ValidateTargetName(
                WindowsNativeTransactionContract.CredentialTargetPrefix +
                "contains/slash"),
            "unsafe credential target suffix was accepted");
        WindowsCredentialManager.ValidateTargetName(
            WindowsNativeTransactionContract.CredentialTargetPrefix +
            "fixture-safe_1");

        RequireThrows<ArgumentException>(
            () => NamedWindowsTransactionMutex.ValidateName("Global\\foreign"),
            "foreign mutex namespace was accepted");
        NamedWindowsTransactionMutex.ValidateName(
            WindowsNativeTransactionContract.ConfigurationMutexName);

        Require(
            WindowsConfigurationTransactionService.ContainsSensitiveAssignment(
                "api_key = \"fixture-secret\"\n"),
            "embedded api_key assignment was accepted");
        Require(
            !WindowsConfigurationTransactionService.ContainsSensitiveAssignment(
                "env_key = \"AI_ACCESS_RELAY_KEY\"\n"),
            "safe env_key reference was rejected");
        Require(
            WindowsConfigurationTransactionService.ContainsSensitiveAssignment(
                "env_key = \"unsafe-value\"\n"),
            "invalid env_key reference was accepted");
        Require(
            WindowsConfigurationTransactionService.ContainsSensitiveAssignment(
                "http_headers = { \"Authorization\" = \"Bearer fixture-secret\" }\n"),
            "inline authorization header was accepted");
    }

    private static void TestCredentialManagerRoundTrip()
    {
        var target =
            WindowsNativeTransactionContract.CredentialTargetPrefix +
            $"contract-{Guid.NewGuid():N}";
        var secret = Encoding.UTF8.GetBytes("fixture-credential-value");
        var manager = new WindowsCredentialManager();
        try
        {
            manager.DeleteGenericCredential(target);
            manager.WriteGenericCredential(target, secret);
            var observed = manager.ReadGenericCredential(target);
            Require(observed is not null, "Credential Manager read returned missing");
            try
            {
                Require(
                    observed!.SequenceEqual(secret),
                    "Credential Manager round trip changed secret bytes");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(observed!);
            }
            manager.DeleteGenericCredential(target);
            Require(
                manager.ReadGenericCredential(target) is null,
                "Credential Manager delete did not remove fixture credential");
            manager.DeleteGenericCredential(target);
        }
        finally
        {
            manager.DeleteGenericCredential(target);
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    private static void TestNamedMutexExclusivityAndAbandonment()
    {
        var name =
            $"Local\\io.github.liewlf.aiaccessassistant.contract-{Guid.NewGuid():N}";
        var manager = new NamedWindowsTransactionMutex();
        using (manager.Acquire(name, TimeSpan.FromSeconds(1)))
        {
            Exception? workerError = null;
            var worker = new Thread(() =>
            {
                try
                {
                    using var unexpected = manager.Acquire(name, TimeSpan.Zero);
                }
                catch (Exception error)
                {
                    workerError = error;
                }
            });
            worker.Start();
            worker.Join();
            Require(
                workerError is WindowsTransactionBusyException,
                "second thread was not blocked by named mutex");
        }

        var abandonedName =
            $"Local\\io.github.liewlf.aiaccessassistant.abandoned-{Guid.NewGuid():N}";
        using var rawMutex = new Mutex(false, abandonedName);
        var owner = new Thread(() => _ = rawMutex.WaitOne());
        owner.Start();
        owner.Join();
        RequireThrows<WindowsTransactionRecoveryRequiredException>(
            () => manager.Acquire(abandonedName, TimeSpan.FromSeconds(1)),
            "abandoned mutex did not fail closed");
    }

    private static void TestExistingConfigurationTransaction()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var path = Path.Combine(root, "config.toml");
            const string original =
                "model_provider = \"openai\"\r\nmodel = \"gpt-fixture\"\r\n";
            const string proposed =
                "model_provider = \"fixture-relay\"\r\nenv_key = \"AI_ACCESS_RELAY_KEY\"\r\n";
            File.WriteAllText(path, original, new UTF8Encoding(false));
            var replacer = new WindowsAtomicFileReplacer();
            var before = replacer.Snapshot(path);
            var service = new WindowsConfigurationTransactionService(
                replacer,
                new NamedWindowsTransactionMutex());
            var plan = service.Prepare(path, proposed);
            Require(plan.ChangesRequired, "changed config produced no-change plan");
            Require(
                plan.OriginalPreview == original &&
                plan.ProposedPreview.Contains(
                    "model_provider = \"fixture-relay\"",
                    StringComparison.Ordinal) &&
                plan.ProposedPreview.Contains(
                    "env_key = \"<redacted>\"",
                    StringComparison.Ordinal) &&
                !plan.ProposedPreview.Contains(
                    "AI_ACCESS_RELAY_KEY",
                    StringComparison.Ordinal),
                "transaction preview did not preserve safe fields or redact credential references");

            RequireThrows<WindowsUserConfirmationRequiredException>(
                () => service.Apply(plan, userConfirmed: false),
                "configuration write did not require explicit confirmation");
            Require(
                File.ReadAllText(path) == original,
                "unconfirmed transaction modified configuration");

            File.AppendAllText(path, "# concurrent drift\r\n", new UTF8Encoding(false));
            RequireThrows<WindowsTransactionBusyException>(
                () => service.Apply(plan, userConfirmed: true),
                "pre-write identity drift was not blocked");
            File.WriteAllText(path, original, new UTF8Encoding(false));

            plan = service.Prepare(path, proposed);
            var result = service.Apply(plan, userConfirmed: true);
            var after = replacer.Snapshot(path);
            Require(
                result.State == WindowsConfigurationTransactionState.Applied &&
                result.BackupRemoved &&
                result.UserConfirmed,
                "confirmed transaction result was incomplete");
            Require(
                File.ReadAllText(path) == proposed,
                "confirmed transaction did not write proposed configuration");
            Require(
                before.DaclSddl == after.DaclSddl &&
                before.Attributes == after.Attributes &&
                before.CreationTimeUtc == after.CreationTimeUtc,
                "ReplaceFileW did not preserve original metadata: DACL, attributes, or creation time");
            Require(
                !Directory.EnumerateFiles(root).Any(file =>
                    Path.GetFileName(file).Contains(
                        ".ai-access-",
                        StringComparison.Ordinal)),
                "successful transaction left stage or backup files");

            var noChangePlan = service.Prepare(path, proposed);
            var noChangeBefore = File.GetLastWriteTimeUtc(path);
            var noChange = service.Apply(
                noChangePlan,
                userConfirmed: true);
            Require(
                noChange.State == WindowsConfigurationTransactionState.NoChange &&
                File.GetLastWriteTimeUtc(path) == noChangeBefore,
                "no-change transaction rewrote configuration");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestMissingConfigurationTransaction()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var path = Path.Combine(root, "config.toml");
            const string proposed =
                "model_provider = \"fixture-relay\"\nenv_key = \"AI_ACCESS_RELAY_KEY\"\n";
            var service = new WindowsConfigurationTransactionService();
            var plan = service.Prepare(path, proposed);
            Require(!plan.ConfigurationExisted, "missing config preview claimed existing file");
            RequireThrows<WindowsUserConfirmationRequiredException>(
                () => service.Apply(plan, userConfirmed: false),
                "missing config creation did not require confirmation");
            Require(!File.Exists(path), "unconfirmed transaction created config");

            var result = service.Apply(plan, userConfirmed: true);
            Require(
                result.State == WindowsConfigurationTransactionState.Applied &&
                File.ReadAllText(path) == proposed,
                "confirmed missing-config transaction did not create exact content");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestAmbiguousReplacementPreservesEvidence()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var path = Path.Combine(root, "config.toml");
            const string original = "model_provider = \"openai\"\n";
            const string proposed = "model_provider = \"fixture-relay\"\n";
            File.WriteAllText(path, original, new UTF8Encoding(false));
            var service = new WindowsConfigurationTransactionService(
                new AmbiguousFileReplacer(),
                new NamedWindowsTransactionMutex());
            var plan = service.Prepare(path, proposed);

            RequireThrows<WindowsReplaceFileAmbiguousException>(
                () => service.Apply(plan, userConfirmed: true),
                "ambiguous ReplaceFileW result was not preserved");
            Require(
                File.ReadAllText(path) == original,
                "ambiguous replacement changed fixture destination");
            Require(
                Directory.EnumerateFiles(root).Any(file =>
                    Path.GetFileName(file).Contains(
                        ".ai-access-stage-",
                        StringComparison.Ordinal)),
                "ambiguous replacement deleted recovery stage evidence");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void TestContinuityApplyAndRecovery()
    {
        var root = NewTemporaryDirectory();
        try
        {
            var source = Path.Combine(root, "continuity.json");
            File.WriteAllText(
                source,
                ValidContinuityManifest(),
                new UTF8Encoding(false));
            var config = Path.Combine(root, "config.toml");
            const string configBefore = "model_provider = \"openai\"\n";
            File.WriteAllText(config, configBefore, new UTF8Encoding(false));
            var store = new WindowsContinuityStateStore(
                Path.Combine(root, "continuity-state"));
            var credentials = new MutableCredentialManager();
            var coordinator = new WindowsContinuityImportCoordinator(
                store,
                credentials,
                new FixtureTransactionMutex(),
                clock: () => new DateTimeOffset(
                    2026,
                    8,
                    20,
                    4,
                    0,
                    0,
                    TimeSpan.Zero));
            var session = coordinator.Prepare(source);
            var cancelledSecret = Encoding.UTF8.GetBytes("cancelled-secret");
            var cancelled = new WindowsContinuityApplyRequest(
                session,
                [new WindowsContinuityRelayDecision(
                    Guid.Parse("22222222-2222-2222-2222-222222222222"),
                    "relay-cancelled",
                    cancelledSecret)],
                [],
                ApplyStartDestination: false,
                ApplyHistoryGrouping: false,
                UserConfirmed: false);
            RequireThrows<WindowsContinuityConfirmationRequiredException>(
                () => coordinator.Apply(cancelled),
                "unconfirmed continuity import was not blocked");
            Require(
                cancelledSecret.All(value => value == 0) &&
                credentials.Count == 0 &&
                !File.Exists(store.StatePath) &&
                !File.Exists(store.JournalPath),
                "cancelled continuity import retained secret data or wrote state");

            session = coordinator.Prepare(source);
            var appliedSecret = Encoding.UTF8.GetBytes("fixture-secret");
            var applied = coordinator.Apply(new WindowsContinuityApplyRequest(
                session,
                [new WindowsContinuityRelayDecision(
                    Guid.Parse("22222222-2222-2222-2222-222222222222"),
                    "relay-imported",
                    appliedSecret)],
                [],
                ApplyStartDestination: true,
                ApplyHistoryGrouping: true,
                UserConfirmed: true));
            var state = store.Load();
            Require(
                applied.ImportedRelayCount == 1 &&
                applied.CurrentAccessPreserved &&
                !applied.CredentialsVerified &&
                appliedSecret.All(value => value == 0) &&
                state.RelayProfiles.Count == 1 &&
                !state.RelayProfiles[0].Verified &&
                state.StartDestination == WindowsPortableStartDestination.History &&
                state.HistoryGrouping == WindowsPortableHistoryGrouping.Recent &&
                credentials.Count == 1 &&
                !File.Exists(store.JournalPath) &&
                File.ReadAllText(config) == configBefore,
                "confirmed continuity import changed current config or adopted verification");

            var rollbackRoot = Path.Combine(root, "rollback");
            var rollbackStore = new WindowsContinuityStateStore(rollbackRoot);
            var rollbackCredentials = new MutableCredentialManager();
            var suffix = new string('c', 32);
            rollbackCredentials.WriteGenericCredential(
                WindowsNativeTransactionContract.CredentialTargetPrefix + suffix,
                Encoding.UTF8.GetBytes("rollback-secret"));
            var now = new DateTimeOffset(
                2026,
                8,
                20,
                5,
                0,
                0,
                TimeSpan.Zero);
            rollbackStore.SaveJournal(new WindowsContinuityTransactionJournal(
                1,
                new string('1', 32),
                WindowsContinuityTransactionPhase.CredentialsWritten,
                new string('a', 64),
                new string('b', 64),
                new string('c', 64),
                null,
                new string('d', 64),
                BeforeStateExisted: false,
                [suffix],
                "continuity-backup-11111111111111111111111111111111.json",
                now,
                now));
            var rollbackCoordinator = new WindowsContinuityImportCoordinator(
                rollbackStore,
                rollbackCredentials,
                new FixtureTransactionMutex(),
                clock: () => now);
            RequireThrows<WindowsContinuityConfirmationRequiredException>(
                () => rollbackCoordinator.RecoverPending(userConfirmed: false),
                "continuity recovery did not require explicit confirmation");
            Require(
                rollbackCoordinator.RecoverPending(userConfirmed: true) == 1 &&
                rollbackCredentials.Count == 0 &&
                !File.Exists(rollbackStore.JournalPath),
                "incomplete continuity import did not roll back credentials and journal");

            var committedRoot = Path.Combine(root, "committed");
            var committedStore = new WindowsContinuityStateStore(committedRoot);
            Directory.CreateDirectory(committedRoot);
            File.WriteAllText(
                committedStore.StatePath,
                "{}",
                new UTF8Encoding(false));
            committedStore.SaveJournal(new WindowsContinuityTransactionJournal(
                1,
                new string('2', 32),
                WindowsContinuityTransactionPhase.Committed,
                new string('a', 64),
                new string('b', 64),
                new string('c', 64),
                null,
                new string('e', 64),
                BeforeStateExisted: false,
                [],
                "continuity-backup-22222222222222222222222222222222.json",
                now,
                now));
            var committedCoordinator = new WindowsContinuityImportCoordinator(
                committedStore,
                new MutableCredentialManager(),
                new FixtureTransactionMutex(),
                clock: () => now);
            RequireThrows<WindowsContinuityRecoveryRequiredException>(
                () => committedCoordinator.RecoverPending(userConfirmed: true),
                "committed cleanup accepted a changed target state");
            Require(
                committedStore.LoadJournal()?.Phase ==
                    WindowsContinuityTransactionPhase.Committed,
                "committed cleanup failure was incorrectly rewritten as rollback failure");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class FixtureTransactionMutex : IWindowsTransactionMutex
    {
        public IDisposable Acquire(string name, TimeSpan timeout)
        {
            Require(
                name == WindowsContinuityContract.ContinuityMutexName,
                "continuity transaction used an unexpected Mutex namespace");
            return new FixtureLease();
        }

        private sealed class FixtureLease : IDisposable
        {
            public void Dispose()
            {
            }
        }
    }

    private sealed class MutableCredentialManager : IWindowsCredentialManager
    {
        private readonly Dictionary<string, byte[]> _values =
            new(StringComparer.Ordinal);

        public int Count => _values.Count;

        public byte[]? ReadGenericCredential(string targetName) =>
            _values.TryGetValue(targetName, out var value)
                ? value.ToArray()
                : null;

        public void WriteGenericCredential(
            string targetName,
            ReadOnlySpan<byte> secret)
        {
            if (_values.ContainsKey(targetName))
            {
                throw new InvalidOperationException(
                    "fixture credential overwrite blocked");
            }
            _values[targetName] = secret.ToArray();
        }

        public void DeleteGenericCredential(string targetName)
        {
            if (_values.Remove(targetName, out var value))
            {
                CryptographicOperations.ZeroMemory(value);
            }
        }
    }

    private sealed class AmbiguousFileReplacer : IWindowsAtomicFileReplacer
    {
        private readonly WindowsAtomicFileReplacer _native = new();

        public WindowsFileSecuritySnapshot Snapshot(string path) =>
            _native.Snapshot(path);

        public WindowsFileReplacementReceipt ReplaceFile(
            string destination,
            string replacement,
            string backup,
            string expectedSha256,
            WindowsFileSecuritySnapshot expectedMetadata) =>
            throw new WindowsReplaceFileAmbiguousException(1176);
    }

    private sealed class FixtureVerificationRunner : IWindowsVerificationRunner
    {
        public int CallCount { get; private set; }
        public bool ObservedCredential { get; private set; }

        public Task<WindowsVerificationRunResult> RunAsync(
            WindowsVerificationRunRequest request,
            CancellationToken cancellationToken = default)
        {
            CallCount += 1;
            ObservedCredential = request.CredentialUtf8?.Length > 0;
            var toolCalls = request.Step == WindowsVerificationStep.RealTask
                ? 1
                : 0;
            return Task.FromResult(new WindowsVerificationRunResult(
                new WindowsVerificationTraceAnalysis(
                    true,
                    null,
                    Convert.ToHexString(SHA256.HashData(
                        Encoding.UTF8.GetBytes(request.Step.ToString())))
                        .ToLowerInvariant(),
                    toolCalls),
                10,
                null,
                null));
        }
    }

    private sealed class FixtureProcessController : IWindowsProcessController
    {
        public IReadOnlyList<int> Writers { get; set; } = [];
        public int GracefulExitRequests { get; private set; }

        public IReadOnlyList<int> FindConfigurationWriters() => Writers;

        public void RequestGracefulExit(int processId)
        {
            GracefulExitRequests += 1;
        }

        public int LaunchCodex(IReadOnlyDictionary<string, string> environment) =>
            throw new InvalidOperationException("fixture launch not allowed");

        public bool WaitForExit(int processId, TimeSpan timeout) =>
            throw new InvalidOperationException("fixture wait not allowed");
    }

    private sealed class FixtureCredentialManager : IWindowsCredentialManager
    {
        private readonly byte[]? _secret;

        public FixtureCredentialManager(byte[]? secret = null)
        {
            _secret = secret;
        }

        public int ReadCount { get; private set; }
        public byte[]? LastReturned { get; private set; }

        public byte[]? ReadGenericCredential(string targetName)
        {
            ReadCount += 1;
            LastReturned = _secret?.ToArray();
            return LastReturned;
        }

        public void WriteGenericCredential(
            string targetName,
            ReadOnlySpan<byte> secret) =>
            throw new InvalidOperationException("fixture write not allowed");

        public void DeleteGenericCredential(string targetName) =>
            throw new InvalidOperationException("fixture delete not allowed");
    }

    private static CodexConfigurationPaths PathsFor(string root) =>
        new(root, Path.Combine(root, ".codex"), Path.Combine(root, ".codex", "config.toml"));

    private static ConfigurationPreview PreviewFor(
        string content,
        bool exists = true) =>
        new(
            "fixture-config.toml",
            content,
            Encoding.UTF8.GetByteCount(content),
            exists,
            false,
            "fixture");

    private static string ValidContinuityManifest() =>
        @"{
          ""schema_version"": 1,
          ""product"": ""AI接入助手"",
          ""source_version"": ""0.12.0"",
          ""source_build"": ""145"",
          ""platform"": ""macOS"",
          ""boundary"": {
            ""credentials_included"": false,
            ""auth_files_included"": false,
            ""session_content_included"": false,
            ""workspace_paths_included"": false,
            ""configuration_files_included"": false,
            ""keychain_references_included"": false
          },
          ""import_policy"": {
            ""preview_required"": true,
            ""field_selection_required"": true,
            ""credential_reentry_required"": true,
            ""writes_allowed"": false
          },
          ""selection"": {
            ""access_profiles"": true,
            ""workspace_labels"": true,
            ""start_destination"": true,
            ""history_grouping"": true
          },
          ""access_profiles"": [
            {
              ""id"": ""11111111-1111-1111-1111-111111111111"",
              ""kind"": ""official"",
              ""display_name"": ""Codex 官方""
            },
            {
              ""id"": ""22222222-2222-2222-2222-222222222222"",
              ""kind"": ""relay"",
              ""display_name"": ""迁移中转"",
              ""base_url"": ""https://relay.example.com/v1"",
              ""default_model"": ""gpt-fixture"",
              ""api_protocol"": ""responses""
            }
          ],
          ""workspace_labels"": [
            {
              ""id"": ""33333333-3333-3333-3333-333333333333"",
              ""label"": ""项目工作区""
            }
          ],
          ""preferences"": {
            ""start_destination"": ""history"",
            ""history_grouping"": ""recent""
          }
        }";

    private static string NewTemporaryDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"ai-access-windows-contract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void RequireThrows<TException>(Action action, string message)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException(message);
    }

    private static async Task RequireThrowsAsync<TException>(Func<Task> action, string message)
        where TException : Exception
    {
        try
        {
            await action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException(message);
    }
}
