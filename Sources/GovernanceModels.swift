import CryptoKit
import Foundation

enum V011RunningBundleClass: String, Codable, Equatable, Sendable {
    case installed
    case candidate
    case other
    case unverified
}

/// Runtime provenance is deliberately derived from the running bundle's
/// metadata.  It never records the bundle URL or any filesystem path.
struct V011RunningBuildEvidence: Codable, Equatable, Sendable {
    let version: String
    let build: String
    let bundleClass: V011RunningBundleClass
    let bundleHash: String?
    let observedAt: Date

    static func current(
        bundle: Bundle = .main,
        now: Date = Date()
    ) -> V011RunningBuildEvidence {
        let version = (bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? AppReleaseMetadata.version
        let build = (bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? AppReleaseMetadata.build
        let declaredClass = (bundle.object(
            forInfoDictionaryKey: "B63BundleClass"
        ) as? String)?.lowercased()
        let bundleClass = V011RunningBundleClass(
            rawValue: declaredClass ?? ""
        ) ?? .unverified
        let identity = [
            bundle.bundleIdentifier ?? "unknown",
            version,
            build,
            bundleClass.rawValue,
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(identity.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return V011RunningBuildEvidence(
            version: version,
            build: build,
            bundleClass: bundleClass,
            bundleHash: digest,
            observedAt: now
        )
    }
}

/// Aggregated connection evidence for portable diagnostics. Deliberately
/// excludes observation IDs, provider IDs, config hashes, endpoints, and
/// raw error text.
struct V011ConnectionHealthDiagnosticSummary:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sampleCount: Int
    let passedCount: Int
    let degradedCount: Int
    let failedCount: Int
    let passRate: Double
    let medianDurationMilliseconds: Double?
    let consecutiveIssueCount: Int
    let latestOutcome: V011ConnectionHealthOutcome
    let latestFailureCode: V011ConnectionHealthFailureCode?
    let latestRuntimeState: V011ConnectionHealthRuntimeState
    let latestSessionProviderCheck: V011SessionProviderCheck?
    let advice: V011ConnectionHealthAdvice

    static func make(
        from observations: [V011ConnectionHealthObservation]
    ) -> V011ConnectionHealthDiagnosticSummary? {
        guard let latest = observations.first,
              let digest = V011ConnectionHealthAnalyzer.digest(
                  observations
              ) else {
            return nil
        }
        return V011ConnectionHealthDiagnosticSummary(
            schemaVersion: currentSchemaVersion,
            sampleCount: digest.sampleCount,
            passedCount: digest.passedCount,
            degradedCount: digest.degradedCount,
            failedCount: digest.failedCount,
            passRate: digest.passRate,
            medianDurationMilliseconds:
                digest.medianDurationMilliseconds,
            consecutiveIssueCount:
                digest.consecutiveIssueCount,
            latestOutcome: latest.outcome,
            latestFailureCode: latest.failureCode,
            latestRuntimeState: latest.runtimeState,
            latestSessionProviderCheck:
                latest.sessionProviderCheck,
            advice: V011ConnectionHealthAnalyzer.advice(
                for: latest
            )
        )
    }
}

enum V013DiagnosticRoute: String, Codable, Equatable, Sendable {
    case official
    case relay
    case unknown
}

enum V013DiagnosticRuntimeAdoption:
    String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case notRunning
    case unknown
}

enum V013DiagnosticFailureDomain:
    String, Codable, Equatable, Sendable {
    case connection
    case agentLoop
    case compatibility
    case officialUsage
    case recovery
}

/// Coarse evidence states only. Initializers reject arbitrary strings so
/// provider text, prompts, responses, and tool output cannot enter this
/// portable support schema through a freshness field.
struct V013DiagnosticEvidenceFreshness:
    Codable, Equatable, Sendable {
    let connection: String
    let agentLoop: String
    let compatibility: String
    let officialUsage: String

    init(
        connection: String,
        agentLoop: String,
        compatibility: String,
        officialUsage: String
    ) {
        self.connection = Self.normalized(
            connection,
            allowed: [
                "untested", "fresh", "aging", "stale",
                "clockSkewed",
            ]
        )
        self.agentLoop = Self.normalized(
            agentLoop,
            allowed: ["untested", "fresh", "stale", "mismatched"]
        )
        self.compatibility = Self.normalized(
            compatibility,
            allowed: [
                "untested", "fresh", "cached", "bundled", "blocked",
            ]
        )
        self.officialUsage = Self.normalized(
            officialUsage,
            allowed: ["untested", "fresh", "stale"]
        )
    }

    static let unknown = Self(
        connection: "untested",
        agentLoop: "untested",
        compatibility: "untested",
        officialUsage: "untested"
    )

    private static func normalized(
        _ value: String,
        allowed: Set<String>
    ) -> String {
        allowed.contains(value) ? value : "untested"
    }
}

struct V011DiagnosticBundle: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let transactionID: String?
    let phase: String?
    let failureCode: String?
    let journalSizeBytes: Int64?
    let recoveryPath: String?
    let configHash: String?
    let networkRoute: String?
    let appVersion: String
    let configTransactionID: String?
    let sessionTransactionID: String?
    let configPhase: String?
    let sessionPhase: String?
    let sessionAttempt: Int?
    let estimatedJournalBytes: UInt64?
    let journalLimitBytes: UInt64?
    let actualJournalBytes: UInt64?
    let recoveryID: String?
    let targetProvider: String?
    let targetProfileID: String?
    let failureStage: String?
    let nextAction: String?
    let runningVersion: String?
    let runningBuild: String?
    let bundleClass: V011RunningBundleClass?
    let bundleHash: String?
    let runningBuildObservedAt: Date?
    let currentRoute: V013DiagnosticRoute
    let runtimeAdoption: V013DiagnosticRuntimeAdoption
    let failureDomain: V013DiagnosticFailureDomain?
    let evidenceFreshness: V013DiagnosticEvidenceFreshness
    let connectionHealth:
        V011ConnectionHealthDiagnosticSummary?

    init(
        schemaVersion: Int,
        transactionID: String?,
        phase: String?,
        failureCode: String?,
        journalSizeBytes: Int64?,
        recoveryPath: String?,
        configHash: String?,
        networkRoute: String?,
        appVersion: String,
        configTransactionID: String? = nil,
        sessionTransactionID: String? = nil,
        configPhase: String? = nil,
        sessionPhase: String? = nil,
        sessionAttempt: Int? = nil,
        estimatedJournalBytes: UInt64? = nil,
        journalLimitBytes: UInt64? = nil,
        actualJournalBytes: UInt64? = nil,
        recoveryID: String? = nil,
        targetProvider: String? = nil,
        targetProfileID: String? = nil,
        failureStage: String? = nil,
        nextAction: String? = nil,
        runningVersion: String? = nil,
        runningBuild: String? = nil,
        bundleClass: V011RunningBundleClass? = nil,
        bundleHash: String? = nil,
        runningBuildObservedAt: Date? = nil,
        currentRoute: V013DiagnosticRoute = .unknown,
        runtimeAdoption: V013DiagnosticRuntimeAdoption = .unknown,
        failureDomain: V013DiagnosticFailureDomain? = nil,
        evidenceFreshness:
            V013DiagnosticEvidenceFreshness = .unknown,
        connectionHealth:
            V011ConnectionHealthDiagnosticSummary? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.phase = phase
        self.failureCode = failureCode
        self.journalSizeBytes = journalSizeBytes
        // A diagnostic receipt must remain portable. Filesystem paths can
        // disclose user names, workspace structure, or session locations, so
        // they are deliberately discarded before Codable export.
        _ = recoveryPath
        self.recoveryPath = nil
        self.configHash = configHash
        // Raw route and saved-profile identifiers can disclose a custom
        // service name. Schema v2 reports only currentRoute's coarse kind.
        _ = networkRoute
        self.networkRoute = nil
        self.appVersion = appVersion
        self.configTransactionID = configTransactionID
        self.sessionTransactionID = sessionTransactionID
        self.configPhase = configPhase
        self.sessionPhase = sessionPhase
        self.sessionAttempt = sessionAttempt
        self.estimatedJournalBytes = estimatedJournalBytes
        self.journalLimitBytes = journalLimitBytes
        self.actualJournalBytes = actualJournalBytes
        self.recoveryID = recoveryID
        _ = targetProvider
        _ = targetProfileID
        self.targetProvider = nil
        self.targetProfileID = nil
        self.failureStage = failureStage
        self.nextAction = nextAction
        self.runningVersion = runningVersion
        self.runningBuild = runningBuild
        self.bundleClass = bundleClass
        self.bundleHash = bundleHash
        self.runningBuildObservedAt = runningBuildObservedAt
        self.currentRoute = currentRoute
        self.runtimeAdoption = runtimeAdoption
        self.failureDomain = failureDomain
        self.evidenceFreshness = evidenceFreshness
        self.connectionHealth = connectionHealth
    }

    var redactedSummary: String {
        [
            "schema=v013-diagnostic-2",
            "transaction_id=\(transactionID ?? "unavailable")",
            "phase=\(phase ?? "unavailable")",
            "failure_code=\(failureCode ?? "unavailable")",
            "journal_size_bytes=\(journalSizeBytes.map(String.init) ?? "unavailable")",
            // Full filesystem paths are deliberately excluded from the
            // copyable diagnostic text; recoveryID remains the stable join
            // key for durable receipts.
            "recovery_path=unavailable",
            "config_hash=\(configHash ?? "unavailable")",
            "network_route=\(networkRoute ?? "unavailable")",
            "app_version=\(appVersion)",
            "config_transaction_id=\(configTransactionID ?? "unavailable")",
            "session_transaction_id=\(sessionTransactionID ?? "unavailable")",
            "config_phase=\(configPhase ?? "unavailable")",
            "session_phase=\(sessionPhase ?? "unavailable")",
            "session_attempt=\(sessionAttempt.map(String.init) ?? "unavailable")",
            "estimated_journal_bytes=\(estimatedJournalBytes.map(String.init) ?? "unavailable")",
            "journal_limit_bytes=\(journalLimitBytes.map(String.init) ?? "unavailable")",
            "actual_journal_bytes=\(actualJournalBytes.map(String.init) ?? "unavailable")",
            "recovery_id=\(recoveryID ?? "unavailable")",
            "target_provider=\(targetProvider ?? "unavailable")",
            "target_profile_id=\(targetProfileID ?? "unavailable")",
            "failure_stage=\(failureStage ?? "unavailable")",
            "next_action=\(nextAction ?? "unavailable")",
            "running_version=\(runningVersion ?? "unavailable")",
            "running_build=\(runningBuild ?? "unavailable")",
            "bundle_class=\(bundleClass?.rawValue ?? "unverified")",
            "bundle_hash=\(bundleHash ?? "unavailable")",
            "current_route=\(currentRoute.rawValue)",
            "runtime_adoption=\(runtimeAdoption.rawValue)",
            "failure_domain=\(failureDomain?.rawValue ?? "unavailable")",
            "connection_evidence=\(evidenceFreshness.connection)",
            "agent_loop_evidence=\(evidenceFreshness.agentLoop)",
            "compatibility_evidence=\(evidenceFreshness.compatibility)",
            "official_usage_evidence=\(evidenceFreshness.officialUsage)",
            "connection_health_sample_count=\(connectionHealth.map { String($0.sampleCount) } ?? "unavailable")",
            "connection_health_passed_count=\(connectionHealth.map { String($0.passedCount) } ?? "unavailable")",
            "connection_health_degraded_count=\(connectionHealth.map { String($0.degradedCount) } ?? "unavailable")",
            "connection_health_failed_count=\(connectionHealth.map { String($0.failedCount) } ?? "unavailable")",
            "connection_health_latest_outcome=\(connectionHealth?.latestOutcome.rawValue ?? "unavailable")",
            "connection_health_latest_failure_code=\(connectionHealth?.latestFailureCode?.rawValue ?? "unavailable")",
            "connection_health_latest_runtime=\(connectionHealth?.latestRuntimeState.rawValue ?? "unavailable")",
            "connection_health_latest_session=\(connectionHealth?.latestSessionProviderCheck?.rawValue ?? "unavailable")",
            "connection_health_advice=\(connectionHealth?.advice.rawValue ?? "unavailable")",
        ].joined(separator: "\n")
    }
}

struct V011ManagedConfigurationSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let configHash: String
    let redactedConfig: String

    static func capture(
        data: Data,
        now: Date = Date()
    ) -> V011ManagedConfigurationSnapshot {
        let text = String(decoding: data, as: UTF8.self)
        return V011ManagedConfigurationSnapshot(
            id: UUID(),
            createdAt: now,
            configHash: TOMLSemanticEngine.sha256(data),
            redactedConfig: SensitiveTextRedactor.redact(text)
        )
    }

    func semanticDiff(to data: Data) throws -> [String] {
        let before = try TOMLSemanticEngine.parse(redactedConfig)
        let after = try TOMLSemanticEngine.parse(
            SensitiveTextRedactor.redact(
                String(decoding: data, as: UTF8.self)
            )
        )
        return TOMLSemanticEngine.diff(before: before, after: after)
            .map(\.path)
    }

    func dryRunImport(to data: Data) throws
        -> V011SnapshotImportDryRun {
        let currentHash = TOMLSemanticEngine.sha256(data)
        let changedFields = try semanticDiff(to: data)
        return V011SnapshotImportDryRun(
            snapshotID: id.uuidString,
            sourceHash: configHash,
            currentHash: currentHash,
            changedFields: changedFields,
            decision: changedFields.isEmpty ? .noChanges : .reviewRequired,
            blockedReasons: [],
            configWriteCount: 0,
            sessionWriteCount: 0,
            processWriteCount: 0,
            receiptWriteCount: 0
        )
    }
}

enum V011SnapshotImportDecision: String, Codable, Equatable, Sendable {
    case noChanges
    case reviewRequired
    case blocked
}

struct V011SnapshotImportDryRun: Codable, Equatable, Sendable {
    let snapshotID: String
    let sourceHash: String
    let currentHash: String
    let changedFields: [String]
    let decision: V011SnapshotImportDecision
    let blockedReasons: [String]
    let configWriteCount: Int
    let sessionWriteCount: Int
    let processWriteCount: Int
    let receiptWriteCount: Int

    var isZeroWrite: Bool {
        configWriteCount == 0
            && sessionWriteCount == 0
            && processWriteCount == 0
            && receiptWriteCount == 0
    }
}

struct V011ReadOnlyAuditReport: Codable, Equatable, Sendable {
    let generatedAt: Date
    let configurationHash: String?
    let configurationOutcome: String
    let sessionOutcome: String
    let pendingConfigurationTransactionIDs: [String]
    let sessionReceiptIDs: [String]
    let protectedSurfaceChanges: [String]
    let configWriteCount: Int
    let sessionWriteCount: Int
    let processWriteCount: Int
    let receiptWriteCount: Int

    var isZeroWrite: Bool {
        configWriteCount == 0
            && sessionWriteCount == 0
            && processWriteCount == 0
            && receiptWriteCount == 0
    }
}

enum ConfigurationTruthState: String, Codable {
    case verified
    case candidate
    case unknown
    case drifted
}

enum CodexSchemaCompatibilityState: String, Codable {
    case verified
    case unverified
    case unsupported
}

enum CodexProviderFieldAutomation: String, Codable {
    case automatic
    case explicitConfirmation
    case dedicatedAdapter
    case migrationRemovalOnly
}

struct CodexProviderSchemaContract: Equatable {
    let schemaID: String
    let appVersion: String
    let appBuild: String
    let fieldPolicies: [String: CodexProviderFieldAutomation]

    var automaticFields: Set<String> {
        Set(fieldPolicies.compactMap { key, value in
            value == .automatic ? key : nil
        })
    }
}

enum CodexProviderSchemaCatalog {
    private static let verifiedFieldPolicies:
        [String: CodexProviderFieldAutomation] = [
            "name": .automatic,
            "base_url": .automatic,
            "wire_api": .automatic,
            "env_key": .automatic,
            "query_params": .explicitConfirmation,
            "http_headers": .explicitConfirmation,
            "env_http_headers": .explicitConfirmation,
            "request_max_retries": .explicitConfirmation,
            "stream_max_retries": .explicitConfirmation,
            "stream_idle_timeout_ms": .explicitConfirmation,
            "requires_openai_auth": .dedicatedAdapter,
            "auth": .dedicatedAdapter,
            "experimental_bearer_token": .migrationRemovalOnly,
        ]

    static let current = CodexProviderSchemaContract(
        schemaID: "codex-provider-26.715.52143-5591-v1",
        appVersion: "26.715.52143",
        appBuild: "5591",
        fieldPolicies: verifiedFieldPolicies
    )

    static let previous = CodexProviderSchemaContract(
        schemaID: "codex-provider-26.715.31925-5551-v1",
        appVersion: "26.715.31925",
        appBuild: "5551",
        fieldPolicies: verifiedFieldPolicies
    )

    static let supported = [current, previous]

    static func contract(
        appVersion: String?,
        appBuild: String?
    ) -> CodexProviderSchemaContract? {
        supported.first {
            $0.appVersion == appVersion
                && $0.appBuild == appBuild
        }
    }
}

struct CodexSchemaCompatibility: Codable, Equatable {
    let state: CodexSchemaCompatibilityState
    let appVersion: String?
    let appBuild: String?
    let adapterVersion: String
    let evidence: String
}

struct SharedConfigurationBaseline: Codable, Equatable {
    let sourcePath: String
    let fileHash: String?
    let semanticHash: String?
    let unmanagedLeaves: [String: String]
    let permissions: Int?
    let codexVersion: String?
    let adapterVersion: String
    let createdAt: Date
}

struct OfficialOverlay: Codable, Equatable {
    let id: String
    var state: ConfigurationTruthState
    var rootValues: [String: String]
    var managedProviderIDs: [String]
    var source: String
    var lastVerifiedAt: Date?
    var lastVerificationMethod: String? = nil
    var lastVerifiedProcessIdentifier: Int32? = nil
    var codexVersion: String?
    var adapterVersion: String
}

enum OfficialValidationMethod: String, Codable {
    case userConfirmedInteractiveRequest
}

struct OfficialValidationEvidence: Codable, Equatable {
    let method: OfficialValidationMethod
    let observedAt: Date
    let codexProcessIdentifier: Int32?
    let responseSucceeded: Bool
}

struct OfficialOverlayCandidate: Identifiable, Equatable {
    let id: String
    let displayName: String
    let source: String
    let overlay: OfficialOverlay
    let state: ConfigurationTruthState
    let observedProviderID: String?
    let sourceNonProviderSemanticHash: String
    let nonProviderDifferencePaths: [String]
    let warnings: [String]
}

enum OfficialOverlayCandidateFactory {
    static func currentWithoutProvider(
        currentText: String
    ) throws -> OfficialOverlayCandidate {
        let current = try TOMLSemanticEngine.parse(currentText)
        let overlay = OfficialOverlay(
            id: "official-current-without-provider",
            state: .candidate,
            rootValues: [:],
            managedProviderIDs: current.providerIDs,
            source: "当前配置移除Provider覆盖",
            lastVerifiedAt: nil,
            codexVersion: nil,
            adapterVersion: AppReleaseMetadata.version
        )
        return OfficialOverlayCandidate(
            id: overlay.id,
            displayName: "当前配置移除Provider",
            source: overlay.source,
            overlay: overlay,
            state: .candidate,
            observedProviderID: current.rootString("model_provider"),
            sourceNonProviderSemanticHash: nonProviderSemanticHash(current),
            nonProviderDifferencePaths: [],
            warnings: ["只生成候选；未发送官方真实请求，不能标记为官方可用。"]
        )
    }

    static func assistantOverlay(
        _ overlay: OfficialOverlay,
        currentText: String
    ) throws -> OfficialOverlayCandidate {
        let current = try TOMLSemanticEngine.parse(currentText)
        var candidate = overlay
        candidate.state = candidate.lastVerifiedAt == nil ? .candidate : candidate.state
        return OfficialOverlayCandidate(
            id: "assistant-\(overlay.id)",
            displayName: "AI接入助手官方覆盖层",
            source: overlay.source,
            overlay: candidate,
            state: candidate.lastVerifiedAt == nil ? .candidate : candidate.state,
            observedProviderID: candidate.rootValues["model_provider"],
            sourceNonProviderSemanticHash: nonProviderSemanticHash(current),
            nonProviderDifferencePaths: [],
            warnings: candidate.lastVerifiedAt == nil
                ? ["覆盖层尚无官方真实请求证据。"]
                : []
        )
    }

    static func backup(
        text: String,
        filename: String,
        currentText: String
    ) throws -> OfficialOverlayCandidate {
        let backup = try TOMLSemanticEngine.parse(text)
        let current = try TOMLSemanticEngine.parse(currentText)
        let provider = backup.rootString("model_provider")
        var overlay = try PreservingTOMLEditor.officialOverlay(from: text)
        overlay = OfficialOverlay(
            id: "backup-\(TOMLSemanticEngine.sha256(Data(filename.utf8)).prefix(16))",
            state: .candidate,
            rootValues: overlay.rootValues,
            managedProviderIDs: current.providerIDs,
            source: "用户选择备份：\(filename)",
            lastVerifiedAt: nil,
            codexVersion: nil,
            adapterVersion: AppReleaseMetadata.version
        )
        let differencePaths = nonProviderDifferencePaths(before: current, after: backup)
        var warnings = ["备份只提供Provider根值候选；不会整份覆盖当前MCP、项目或权限设置。"]
        if provider != nil, provider != "openai" {
            warnings.append("备份中的model_provider不是openai或空值，必须人工核对。")
        }
        if !differencePaths.isEmpty {
            warnings.append("备份与当前配置有\(differencePaths.count)项非Provider语义差异；这些差异不会自动恢复。")
        }
        return OfficialOverlayCandidate(
            id: overlay.id,
            displayName: filename,
            source: overlay.source,
            overlay: overlay,
            state: provider == nil || provider == "openai" ? .candidate : .unknown,
            observedProviderID: provider,
            sourceNonProviderSemanticHash: nonProviderSemanticHash(backup),
            nonProviderDifferencePaths: differencePaths,
            warnings: warnings
        )
    }

    static func nonProviderLeaves(
        _ document: TOMLSemanticDocument
    ) -> [String: String] {
        document.leaves.filter { path, _ in
            let components = TOMLSemanticEngine.decodePath(path)
            guard let first = components.first else { return false }
            return first != "model_providers"
                && !TOMLChangePolicy.providerRootKeys.contains(first)
        }
    }

    static func nonProviderSemanticHash(_ document: TOMLSemanticDocument) -> String {
        let leaves = nonProviderLeaves(document)
        let canonical = leaves.keys.sorted()
            .map { "\($0)=\(leaves[$0]!)" }
            .joined(separator: "\n")
        return TOMLSemanticEngine.sha256(Data(canonical.utf8))
    }

    static func nonProviderDifferencePaths(
        before: TOMLSemanticDocument,
        after: TOMLSemanticDocument
    ) -> [String] {
        let lhs = nonProviderLeaves(before)
        let rhs = nonProviderLeaves(after)
        return Set(lhs.keys).union(rhs.keys).filter { lhs[$0] != rhs[$0] }.sorted()
    }
}

struct SharedCapabilityFileEvidence: Identifiable, Codable, Equatable {
    var id: String { "\(kind):\(relativePath)" }
    let kind: String
    let relativePath: String
    let sha256: String
}

struct SharedCapabilityInventory: Codable, Equatable {
    let files: [SharedCapabilityFileEvidence]
    let nonProviderSemanticHash: String
}

struct CrossRailCapabilityContinuityReport: Codable, Equatable {
    let preserved: Bool
    let changedFileIDs: [String]
    let changedConfigurationPaths: [String]
    let explanation: String
}

enum SharedCapabilityInventoryInspector {
    static func inspect(
        codexHome: URL,
        configText: String,
        additionalAgentFiles: [URL] = [],
        maximumEntries: Int = 4_000
    ) throws -> SharedCapabilityInventory {
        let document = try TOMLSemanticEngine.parse(
            TOMLSensitiveValueRedactor.redact(configText)
        )
        var evidence: [SharedCapabilityFileEvidence] = []
        try collect(
            root: codexHome.appendingPathComponent("skills", isDirectory: true),
            acceptedNames: ["SKILL.md"],
            kind: "skill",
            maximumEntries: maximumEntries,
            into: &evidence
        )
        try collect(
            root: codexHome.appendingPathComponent("plugins", isDirectory: true),
            acceptedNames: ["plugin.json"],
            kind: "plugin",
            maximumEntries: maximumEntries,
            into: &evidence
        )
        for url in additionalAgentFiles where FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            evidence.append(SharedCapabilityFileEvidence(
                kind: "agent-rules",
                relativePath: url.lastPathComponent,
                sha256: TOMLSemanticEngine.sha256(try Data(contentsOf: url, options: .mappedIfSafe))
            ))
        }
        return SharedCapabilityInventory(
            files: evidence.sorted { $0.id < $1.id },
            nonProviderSemanticHash: OfficialOverlayCandidateFactory
                .nonProviderSemanticHash(document)
        )
    }

    static func compare(
        before: SharedCapabilityInventory,
        after: SharedCapabilityInventory,
        beforeConfigText: String,
        afterConfigText: String
    ) throws -> CrossRailCapabilityContinuityReport {
        let lhs = Dictionary(uniqueKeysWithValues: before.files.map { ($0.id, $0.sha256) })
        let rhs = Dictionary(uniqueKeysWithValues: after.files.map { ($0.id, $0.sha256) })
        let changedFiles = Set(lhs.keys).union(rhs.keys).filter { lhs[$0] != rhs[$0] }.sorted()
        let configChanges = OfficialOverlayCandidateFactory.nonProviderDifferencePaths(
            before: try TOMLSemanticEngine.parse(
                TOMLSensitiveValueRedactor.redact(beforeConfigText)
            ),
            after: try TOMLSemanticEngine.parse(
                TOMLSensitiveValueRedactor.redact(afterConfigText)
            )
        )
        let preserved = changedFiles.isEmpty
            && configChanges.isEmpty
            && before.nonProviderSemanticHash == after.nonProviderSemanticHash
        return CrossRailCapabilityContinuityReport(
            preserved: preserved,
            changedFileIDs: changedFiles,
            changedConfigurationPaths: configChanges,
            explanation: preserved
                ? "Skills、Plugins、AGENTS.md以及TOML中的MCP、Hooks、Projects等非Provider语义保持不变。"
                : "检测到共享能力层变化，禁止把本次切轨标记为无损。"
        )
    }

    private static func collect(
        root: URL,
        acceptedNames: Set<String>,
        kind: String,
        maximumEntries: Int,
        into evidence: inout [SharedCapabilityFileEvidence]
    ) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maximumEntries { break }
            guard acceptedNames.contains(url.lastPathComponent) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let rootPath = root.standardizedFileURL.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let filePath = url.standardizedFileURL.path
            let prefix = "/" + rootPath + "/"
            guard filePath.hasPrefix(prefix) else { continue }
            evidence.append(SharedCapabilityFileEvidence(
                kind: kind,
                relativePath: String(filePath.dropFirst(prefix.count)),
                sha256: TOMLSemanticEngine.sha256(try Data(contentsOf: url, options: .mappedIfSafe))
            ))
        }
    }
}

enum ProviderAuthenticationMode: String, Codable {
    case command
    case environment
    case openAI
    case legacyBearer
    case none
    case unknown
}

struct ProviderOverlay: Identifiable, Codable, Equatable {
    let id: String
    var providerID: String
    var displayName: String
    var baseURL: String
    var wireProtocol: RelayWireProtocol
    var models: [String]
    var defaultModel: String
    var contextWindow: Int?
    var autoCompactTokenLimit: Int?
    var reasoningEffort: ReasoningEffort
    var supportsTextInput: Bool?
    var supportsImageInput: Bool?
    var supportsToolCalls: Bool?
    var authenticationMode: ProviderAuthenticationMode
    var keychainAccount: String?
    var source: String
    var lastVerifiedAt: Date?
    var schemaVersion: Int
    var opaqueFields: [String: String]

    var isAssistantManaged: Bool {
        providerID.hasPrefix("ai_access_") || source == "AI接入助手"
    }
}

struct PersistentUserConfig: Codable, Equatable {
    let codexHome: String
    let configPath: String
    let exists: Bool
    let fileHash: String?
    let semanticHash: String?
    let selectedProviderID: String?
    let selectedModel: String?
    let reasoningEffort: String?
    let managedProviderIDs: [String]
}

struct EffectiveConfiguration: Codable, Equatable {
    let layers: [String]
    let selectedProfile: String?
    let projectConfigPaths: [String]
    let selectedProviderID: String?
    let selectedModel: String?
    let state: ConfigurationTruthState
    let explanation: String
}

struct ProcessLaunchContext: Codable, Equatable {
    let processIdentifier: Int32?
    let codexHome: String?
    let codexHomeEvidence: String?
    let workingDirectory: String?
    let profile: String?
    let arguments: [String]
    let selectedProviderID: String?
    let selectedModel: String?
    let authenticationMode: ProviderAuthenticationMode
    let state: ConfigurationTruthState
}

struct RuntimeTruth: Codable, Equatable {
    let persistent: PersistentUserConfig
    let effective: EffectiveConfiguration
    let process: ProcessLaunchContext
    let runtimeMode: CodexRuntimeMode
    let activeProviderID: String?
    let semanticHash: String?
    let state: ConfigurationTruthState
    let blockingReasons: [String]

    var allowsManagedWrite: Bool {
        state == .verified && blockingReasons.isEmpty
    }
}

struct RuntimeTruthObservation: Equatable {
    let fileHash: String?
    let semanticHash: String?
    let selectedProfile: String?
    let projectConfigPaths: [String]
    let effectiveProviderID: String?
    let effectiveModel: String?
    let processIdentifier: Int32?
    let processProviderID: String?
    let processModel: String?
    let runtimeMode: CodexRuntimeMode

    init(_ truth: RuntimeTruth) {
        fileHash = truth.persistent.fileHash
        semanticHash = truth.semanticHash
        selectedProfile = truth.effective.selectedProfile
        projectConfigPaths = truth.effective.projectConfigPaths
        effectiveProviderID = truth.effective.selectedProviderID
        effectiveModel = truth.effective.selectedModel
        processIdentifier = truth.process.processIdentifier
        processProviderID = truth.process.selectedProviderID
        processModel = truth.process.selectedModel
        runtimeMode = truth.runtimeMode
    }
}

struct RuntimeDriftReport: Equatable {
    let changes: [String]
    let configurationChanged: Bool
    let processChanged: Bool

    var summary: String {
        changes.joined(separator: "；")
    }
}

enum RuntimeDriftDetector {
    static func compare(
        previous: RuntimeTruthObservation,
        current: RuntimeTruthObservation
    ) -> RuntimeDriftReport? {
        var changes: [String] = []
        var configurationChanged = false
        var processChanged = false

        if previous.semanticHash != current.semanticHash {
            changes.append("config.toml语义已改变")
            configurationChanged = true
        } else if previous.fileHash != current.fileHash {
            changes.append("config.toml字节已改变（语义不变）")
            configurationChanged = true
        }
        if previous.selectedProfile != current.selectedProfile {
            changes.append("活动Profile已改变")
            configurationChanged = true
        }
        if previous.projectConfigPaths != current.projectConfigPaths {
            changes.append("项目配置层已改变")
            configurationChanged = true
        }
        if previous.effectiveProviderID != current.effectiveProviderID {
            changes.append("有效Provider已改变")
            configurationChanged = true
        }
        if previous.effectiveModel != current.effectiveModel {
            changes.append("有效模型已改变")
            configurationChanged = true
        }
        if previous.runtimeMode != current.runtimeMode {
            changes.append("真实运行轨已改变")
            configurationChanged = true
        }
        if previous.processIdentifier != current.processIdentifier {
            changes.append("Codex进程已启动、退出或重启")
            processChanged = true
        } else if previous.processProviderID != current.processProviderID
                    || previous.processModel != current.processModel {
            changes.append("Codex进程启动配置已改变")
            processChanged = true
        }

        guard !changes.isEmpty else { return nil }
        return RuntimeDriftReport(
            changes: changes,
            configurationChanged: configurationChanged,
            processChanged: processChanged
        )
    }
}

enum DriftKind: String, Codable {
    case missing
    case added
    case changed
    case runtimeMismatch
}

struct ConfigurationDrift: Identifiable, Codable, Equatable {
    let id: String
    let path: String
    let expectedValue: String?
    let actualValue: String?
    let kind: DriftKind
    let managed: Bool
    let recommendation: String

    init(
        path: String,
        expectedValue: String?,
        actualValue: String?,
        kind: DriftKind,
        managed: Bool,
        recommendation: String
    ) {
        self.id = "\(kind.rawValue):\(path)"
        self.path = path
        self.expectedValue = expectedValue
        self.actualValue = actualValue
        self.kind = kind
        self.managed = managed
        self.recommendation = recommendation
    }
}

enum ManagedSwitchState: String, Codable {
    case prepared = "PREPARED"
    case secretStored = "SECRET_STORED"
    case configCommitted = "CONFIG_COMMITTED"
    case runtimeStarted = "RUNTIME_STARTED"
    case runtimeVerified = "RUNTIME_VERIFIED"
    case committed = "COMMITTED"
    case rollbackRequired = "ROLLBACK_REQUIRED"
    case rolledBack = "ROLLED_BACK"
    case manualRecoveryRequired = "MANUAL_RECOVERY_REQUIRED"
}

struct ManagedSwitchJournal: Identifiable, Codable, Equatable {
    let id: String
    let fromOverlayID: String?
    let toOverlayID: String
    var state: ManagedSwitchState
    let startedAt: Date
    var updatedAt: Date
    let beforeFileHash: String?
    let beforeSemanticHash: String?
    var afterFileHash: String?
    var afterSemanticHash: String?
    var sanitizedMessage: String
}

struct RuntimeTruthInspector {
    let codexHome: URL
    let controlRoot: URL
    let selectedProfile: String?
    let profileConfigPath: URL?
    let processWorkingDirectory: URL?
    let projectConfigPaths: [URL]
    let projectContextKnown: Bool
    let processIdentifier: Int32?
    let processCodexHome: URL?
    let processCodexHomeEvidence: CodexHomeEnvironmentEvidence?
    let processArguments: [String]
    let processProviderID: String?
    let processModel: String?
    let processConfigurationOverrides: [String: String]
    let hasUnsupportedProcessOverrides: Bool
    let schemaCompatibility: CodexSchemaCompatibility?
    let configurationOccupied: Bool?

    init(
        codexHome: URL,
        controlRoot: URL? = nil,
        selectedProfile: String? = nil,
        profileConfigPath: URL? = nil,
        processWorkingDirectory: URL? = nil,
        projectConfigPaths: [URL] = [],
        projectContextKnown: Bool = true,
        processIdentifier: Int32? = nil,
        processCodexHome: URL? = nil,
        processCodexHomeEvidence:
            CodexHomeEnvironmentEvidence? = nil,
        processArguments: [String] = [],
        processProviderID: String? = nil,
        processModel: String? = nil,
        processConfigurationOverrides: [String: String] = [:],
        hasUnsupportedProcessOverrides: Bool = false,
        schemaCompatibility: CodexSchemaCompatibility? = nil,
        configurationOccupied: Bool? = nil
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.controlRoot =
            (controlRoot ?? Self.defaultControlRoot())
            .standardizedFileURL
        self.selectedProfile = selectedProfile
        self.profileConfigPath = profileConfigPath?.standardizedFileURL
        self.processWorkingDirectory =
            processWorkingDirectory?.standardizedFileURL
        self.projectConfigPaths = projectConfigPaths.map(\.standardizedFileURL)
        self.projectContextKnown = projectContextKnown
        self.processIdentifier = processIdentifier
        self.processCodexHome =
            processCodexHome?.standardizedFileURL
        self.processCodexHomeEvidence =
            processCodexHomeEvidence
        self.processArguments = processArguments
        self.processProviderID = processProviderID
        self.processModel = processModel
        self.processConfigurationOverrides = processConfigurationOverrides
        self.hasUnsupportedProcessOverrides = hasUnsupportedProcessOverrides
        self.schemaCompatibility = schemaCompatibility
        self.configurationOccupied = configurationOccupied
    }

    func inspect() throws -> RuntimeTruth {
        let configURL = codexHome.appendingPathComponent("config.toml")
        let exists = FileManager.default.fileExists(atPath: configURL.path)
        let data = exists ? try Data(contentsOf: configURL) : Data()
        let text = TOMLSensitiveValueRedactor.redact(
            String(decoding: data, as: UTF8.self)
        )
        let document = try TOMLSemanticEngine.parse(text)
        let provider = document.rootString("model_provider")
        let model = document.rootString("model")
        let effort = document.rootString("model_reasoning_effort")
        let managedProviders = document.providerIDs.filter {
            $0.hasPrefix("ai_access_")
        }
        let persistent = PersistentUserConfig(
            codexHome: codexHome.path,
            configPath: configURL.path,
            exists: exists,
            fileHash: exists ? TOMLSemanticEngine.sha256(data) : nil,
            semanticHash: document.semanticHash,
            selectedProviderID: provider,
            selectedModel: model,
            reasoningEffort: effort,
            managedProviderIDs: managedProviders
        )

        var layers = [configURL.path]
        var blockers: [String] = []
        var effectiveProvider = provider
        var effectiveModel = model
        if let selectedProfile {
            if let profileConfigPath,
               FileManager.default.fileExists(atPath: profileConfigPath.path) {
                let profileLayer = try TOMLSemanticEngine.parse(
                    String(
                        decoding: Data(contentsOf: profileConfigPath),
                        as: UTF8.self
                    )
                )
                layers.append(profileConfigPath.path)
                effectiveProvider =
                    profileLayer.rootString("model_provider")
                    ?? effectiveProvider
                effectiveModel =
                    profileLayer.rootString("model")
                    ?? effectiveModel
            } else {
                blockers.append("活动Profile“\(selectedProfile)”对应配置文件不存在或无法定位")
            }
            blockers.append("存在Profile覆盖；当前适配器只读核对但不写Profile文件")
        }
        if !projectConfigPaths.isEmpty {
            let projectRoot = processWorkingDirectory.map {
                CodexProjectConfigurationDiscovery.projectRoot(from: $0)
            }
            let trustLevel = projectRoot.flatMap {
                document.string(
                    at: ["projects", $0.path, "trust_level"]
                )
            }
            if trustLevel == "trusted" {
                for path in projectConfigPaths {
                    guard FileManager.default.fileExists(atPath: path.path)
                    else { continue }
                    let layer = try TOMLSemanticEngine.parse(
                        String(
                            decoding: Data(contentsOf: path),
                            as: UTF8.self
                        )
                    )
                    layers.append(path.path)
                    effectiveModel =
                        layer.rootString("model") ?? effectiveModel
                }
                blockers.append("存在已信任项目配置层；当前适配器只读核对但不写项目文件")
            } else {
                blockers.append("发现项目配置，但无法证明当前项目已受信任；未把项目层冒充有效配置")
            }
        }
        if processIdentifier != nil, !projectContextKnown {
            blockers.append("无法确定Codex进程工作目录和项目配置链")
        }
        if processIdentifier != nil,
           let processCodexHomeEvidence {
            switch processCodexHomeEvidence {
            case .explicit, .defaulted:
                if processCodexHome != codexHome {
                    blockers.append(
                        "运行进程CODEX_HOME与助手目标目录不一致"
                    )
                }
            case .unreadable:
                blockers.append(
                    "无法读取运行进程的CODEX_HOME证据"
                )
            case .unsafe:
                blockers.append(
                    "运行进程CODEX_HOME不在当前用户目录或格式不安全"
                )
            case .notRunning:
                blockers.append(
                    "进程状态与CODEX_HOME证据不一致"
                )
            }
        }
        if let overrideProvider = processConfigurationOverrides[
            "model_provider"
        ] {
            effectiveProvider = overrideProvider
            blockers.append("启动参数覆盖了model_provider")
        }
        if let overrideModel = processConfigurationOverrides["model"] {
            effectiveModel = overrideModel
            blockers.append("启动参数覆盖了model")
        }
        if processConfigurationOverrides.keys.contains(
            "model_reasoning_effort"
        ) {
            blockers.append("启动参数覆盖了model_reasoning_effort")
        }
        if hasUnsupportedProcessOverrides {
            blockers.append("存在未识别或高风险启动配置覆盖")
        }
        if document.rootString("openai_base_url") != nil {
            blockers.append("存在openai_base_url覆盖；适配器尚未证明其与目标Provider的优先级")
        }
        if let modelCatalogJSON =
            document.rootString("model_catalog_json"),
           let reason =
            modelCatalogBlockingReason(
                path: modelCatalogJSON
            ) {
            blockers.append(reason)
        }
        if let schemaCompatibility {
            switch schemaCompatibility.state {
            case .verified:
                break
            case .unverified:
                blockers.append("当前Codex版本尚无配置Schema验证证据")
            case .unsupported:
                blockers.append("当前Codex版本不在适配器支持范围")
            }
        }
        if configurationOccupied == true {
            blockers.append("config.toml存在其他进程持有的排他锁")
        }

        let processState: ConfigurationTruthState
        if processIdentifier == nil {
            processState = .unknown
        } else if let processProviderID, processProviderID != effectiveProvider {
            processState = .drifted
            blockers.append("运行进程Provider与有效配置不一致")
        } else {
            processState = .verified
        }
        let process = ProcessLaunchContext(
            processIdentifier: processIdentifier,
            codexHome: processIdentifier == nil
                ? nil
                : processCodexHome?.path,
            codexHomeEvidence:
                processCodexHomeEvidence?.rawValue,
            workingDirectory: processWorkingDirectory?.path,
            profile: selectedProfile,
            arguments: processArguments,
            selectedProviderID: processProviderID,
            selectedModel: processModel,
            authenticationMode: .unknown,
            state: processState
        )
        let effectiveState: ConfigurationTruthState = blockers.isEmpty ? .verified : .unknown
        let effective = EffectiveConfiguration(
            layers: layers,
            selectedProfile: selectedProfile,
            projectConfigPaths: projectConfigPaths.map(\.path),
            selectedProviderID: effectiveProvider,
            selectedModel: effectiveModel,
            state: effectiveState,
            explanation: blockers.isEmpty ? "用户配置是当前唯一已知持久层" : blockers.joined(separator: "；")
        )
        let runtimeMode: CodexRuntimeMode
        if effectiveProvider == nil || effectiveProvider == "openai" {
            runtimeMode = .official
        } else if effectiveProvider?.hasPrefix("ai_access_") == true || effectiveProvider == "custom" {
            runtimeMode = .relay
        } else {
            runtimeMode = .external
        }
        let truthState: ConfigurationTruthState = blockers.isEmpty ? .verified : .unknown
        return RuntimeTruth(
            persistent: persistent,
            effective: effective,
            process: process,
            runtimeMode: runtimeMode,
            activeProviderID: effectiveProvider,
            semanticHash: document.semanticHash,
            state: truthState,
            blockingReasons: blockers
        )
    }

    private func modelCatalogBlockingReason(
        path: String
    ) -> String? {
        let store = ManagedModelCatalogStore(
            rootURL: controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "ManagedModelCatalogs",
                    isDirectory: true
                )
        )
        switch store.existingPathState(path) {
        case .managed:
            return nil
        case .managedInvalid:
            return "受管模型目录校验失败；请重新导入"
        case .externalExisting:
            return "存在model_catalog_json外部模型目录覆盖；必须先导入为受管副本或核对有效模型来源"
        case .externalMissing:
            return "model_catalog_json指向不存在文件；请重新导入受管模型目录或切回默认"
        case let .unsafe(reason):
            return "model_catalog_json路径不安全：\(reason)"
        case .absent:
            return "model_catalog_json为空或无法识别"
        }
    }

    private static func defaultControlRoot() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        return support
            .appendingPathComponent(
                "AI接入助手",
                isDirectory: true
            )
            .appendingPathComponent(
                "ControlPlane",
                isDirectory: true
            )
    }
}

enum TOMLSensitiveValueRedactor {
    private static let sensitiveKeys = [
        "experimental_bearer_token",
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "authorization",
        "secret",
    ]

    static func redact(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { return line }
            let key = line[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            guard sensitiveKeys.contains(where: { key == $0 || key.hasSuffix(".\($0)") }) else {
                return line
            }
            return "\(line[..<equals])= \"<敏感值已跳过>\""
        }.joined(separator: "\n")
    }
}
