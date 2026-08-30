import Foundation

struct V011SupportEvidenceService {
    private let codexHome: URL
    private let controlRoot: URL
    private let now: @Sendable () -> Date

    init(
        codexHome: URL,
        controlRoot: URL,
        now: @escaping @Sendable () -> Date
    ) {
        self.codexHome = codexHome
        self.controlRoot = controlRoot
        self.now = now
    }

    func diagnosticEvidenceFreshness(
        connectionObservation: V011ConnectionHealthObservation?,
        agentLoopReceipt: V011AgentLoopReceipt?,
        agentLoopTargetsCurrentState: Bool,
        compatibilityEvidence: CodexCompatibilityEvidence?,
        officialUsageSnapshot: V011OfficialUsageSnapshot?,
        at timestamp: Date
    ) -> V013DiagnosticEvidenceFreshness {
        let connection = V011ConnectionHealthAnalyzer
            .evidenceFreshness(
                for: connectionObservation,
                at: timestamp
            ).rawValue
        let agentLoop: String
        if let receipt = agentLoopReceipt {
            if !receipt.isStructurallyValid {
                agentLoop = "mismatched"
            } else if receipt.expiresAt <= timestamp {
                agentLoop = "stale"
            } else if agentLoopTargetsCurrentState {
                agentLoop = "fresh"
            } else {
                agentLoop = "mismatched"
            }
        } else {
            agentLoop = "untested"
        }
        let compatibility: String
        switch compatibilityEvidence?.source {
        case .freshProbe:
            compatibility = "fresh"
        case .cachedProbe:
            compatibility = "cached"
        case .bundledContract:
            compatibility = "bundled"
        case .blocked:
            compatibility = "blocked"
        case nil:
            compatibility = "untested"
        }
        let officialUsage: String
        if let snapshot = officialUsageSnapshot {
            officialUsage = snapshot.isFresh(at: timestamp)
                ? "fresh" : "stale"
        } else {
            officialUsage = "untested"
        }
        return V013DiagnosticEvidenceFreshness(
            connection: connection,
            agentLoop: agentLoop,
            compatibility: compatibility,
            officialUsage: officialUsage
        )
    }

    func exportRedactedSupportBundle(
        readiness: V016AccessReadinessDecision,
        freshness: V013DiagnosticEvidenceFreshness,
        to destinationURL: URL,
        userConfirmed: Bool,
        exportedAt: Date
    ) throws -> URL {
        let document = try V016RedactedSupportBundleBuilder.make(
            decision: readiness,
            product: V011RunningBuildEvidence.current(now: exportedAt),
            freshness: freshness,
            exportedAt: exportedAt
        )
        try V016RedactedSupportBundleExporter.write(
            document,
            to: destinationURL,
            userConfirmed: userConfirmed
        )
        return destinationURL.standardizedFileURL
    }

    func exportManagedConfigurationSnapshot() throws -> URL {
        let data = try Data(
            contentsOf: codexHome.appendingPathComponent("config.toml")
        )
        let snapshot = V011ManagedConfigurationSnapshot.capture(
            data: data,
            now: now()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(snapshot)
        let folder = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let url = folder
            .appendingPathComponent("AI接入助手-配置快照-\(snapshot.id)")
            .appendingPathExtension("json")
        try encoded.write(to: url, options: .atomic)
        return url
    }

    func previewConfigurationImport(
        snapshot: V011ManagedConfigurationSnapshot,
        currentData: Data
    ) -> V011SnapshotImportDryRun {
        do {
            return try snapshot.dryRunImport(to: currentData)
        } catch {
            return V011SnapshotImportDryRun(
                snapshotID: snapshot.id.uuidString,
                sourceHash: snapshot.configHash,
                currentHash: TOMLSemanticEngine.sha256(currentData),
                changedFields: [],
                decision: .blocked,
                blockedReasons: ["snapshot_parse_failed"],
                configWriteCount: 0,
                sessionWriteCount: 0,
                processWriteCount: 0,
                receiptWriteCount: 0
            )
        }
    }

    func readOnlyAuditReport(
        configurationHash: String?,
        configurationOutcome: String,
        sessionOutcome: String
    ) -> V011ReadOnlyAuditReport {
        let journalRoot = controlRoot.appendingPathComponent(
            "SwitchTransactions",
            isDirectory: true
        )
        let receiptRoot = controlRoot.appendingPathComponent(
            "SessionTransactions",
            isDirectory: true
        )
        let pendingIDs = (try? V011SwitchJournalStore(
            rootURL: journalRoot
        ).pending().map(\.id)) ?? []
        let receiptIDs = (try? V011SessionTransactionReceiptStore(
            rootURL: receiptRoot
        ).all().map(\.id)) ?? []
        return V011ReadOnlyAuditReport(
            generatedAt: now(),
            configurationHash: configurationHash,
            configurationOutcome: configurationOutcome,
            sessionOutcome: sessionOutcome,
            pendingConfigurationTransactionIDs: pendingIDs,
            sessionReceiptIDs: receiptIDs,
            protectedSurfaceChanges: [],
            configWriteCount: 0,
            sessionWriteCount: 0,
            processWriteCount: 0,
            receiptWriteCount: 0
        )
    }
}
