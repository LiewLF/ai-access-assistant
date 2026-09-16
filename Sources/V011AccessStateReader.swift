import Foundation

struct V011AccessStateSnapshot: @unchecked Sendable {
    let managed: V011ManagedState
    let live: LiveCodexState
    let pending: Bool
    let verified: Bool
    let connectionReceipt: V011ConnectionReceipt?
    let receiptMatches: Bool
    let agentLoopReceipt: V011AgentLoopReceipt?
    let agentLoopMatches: Bool
    let savedRelayReadinessReceipts:
        [String: V011SavedRelayReadinessReceipt]
    let savedRelayReadinessMatches: [String: Bool]
    let recoveryDiagnosticSummary: String
    let runtimeFreshness: V011RuntimeFreshness
    let compatibilityEvidence: CodexCompatibilityEvidence
}

struct V011PendingRecoveryContext: @unchecked Sendable {
    let pending: Bool
    let detail: String?
    let stage: String?
    let nextAction: String?
    let protectsNewSessions: Bool
    let disposition: V011RecoveryDisposition
    let preview: V014RecoveryRepairPreview?
}

/// Read-only boundary for refresh snapshots and pending-recovery diagnosis.
enum V011AccessStateReader {
    static func readState(
        dependencies: V011AccessDependencies,
        pending: Bool
    ) throws -> V011AccessStateSnapshot {
        let stateStore = V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
        let state = try stateStore.load()
        let receiptStore = V011ConnectionReceiptStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("connection-receipt.json")
        )
        // Malformed detached receipts fail closed without hiding live config
        // or blocking recovery controls.
        let connectionReceipt: V011ConnectionReceipt? =
            try? receiptStore.load()
        let agentLoopStore = V011AgentLoopReceiptStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("agent-loop-receipt.json")
        )
        let agentLoopReceipt: V011AgentLoopReceipt? =
            try? agentLoopStore.load()
        let savedRelayReadinessStore = V011SavedRelayReadinessStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent(
                    "UserReadiness",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "saved-relay-readiness.json",
                    isDirectory: false
                )
        )
        let savedRelayReadinessReceipts =
            (try? savedRelayReadinessStore.load()) ?? [:]
        let installation = try dependencies
            .versionDiscovery.discover()
        let core = FableSwitchCore(
            codexHome: dependencies.codexHome,
            resolvedContractEntry: installation.contractEntry,
            credentialStore: dependencies.credentialStore,
            processController: dependencies.processController,
            runtimeVerifier: dependencies.runtimeVerifier,
            managedProviderIDs: state.managedProviderIDSet
        )
        let live = try core.inspect(
            version: installation.identity
        )
        let receiptMatches = connectionReceipt.map {
            V011ConnectionHealthService.receiptMatches(
                $0,
                live: live,
                at: dependencies.now()
            )
        } ?? false
        let agentLoopMatches = agentLoopReceipt.map {
            dependencies.agentLoopVerifier.receiptMatchesCurrent(
                $0,
                live: live,
                now: dependencies.now()
            )
        } ?? false
        let readinessVerifier =
            dependencies.savedRelayReadinessVerifier
        let currentTime = dependencies.now()
        let savedRelayReadinessMatches: [String: Bool] = Dictionary(
            uniqueKeysWithValues: state.relayProfiles.compactMap {
                profile in
                guard let receipt =
                        savedRelayReadinessReceipts[profile.id]
                else { return nil }
                return (
                    profile.id,
                    readinessVerifier.receiptMatchesCurrent(
                        receipt,
                        profile: profile,
                        now: currentTime
                    )
                )
            }
        )
        let runtimeFreshness = V011ConnectionHealthService
            .runtimeFreshness(
                live: live,
                runtimeObservation:
                    dependencies.codexRuntimeObservation()
            )
        return V011AccessStateSnapshot(
            managed: state,
            live: live,
            pending: pending,
            verified: receiptMatches,
            connectionReceipt: connectionReceipt,
            receiptMatches: receiptMatches,
            agentLoopReceipt: agentLoopReceipt,
            agentLoopMatches: agentLoopMatches,
            savedRelayReadinessReceipts:
                savedRelayReadinessReceipts,
            savedRelayReadinessMatches:
                savedRelayReadinessMatches,
            recoveryDiagnosticSummary:
                loadRecoveryDiagnosticSummary(
                    controlRoot: dependencies.controlRoot,
                    liveConfigHash: live.configHash
                ),
            runtimeFreshness: runtimeFreshness,
            compatibilityEvidence:
                installation.compatibilityEvidence
        )
    }

    static func pendingRecoveryContext(
        dependencies: V011AccessDependencies,
        passive: Bool = false
    ) throws -> V011PendingRecoveryContext {
        let switchStore = V011SwitchJournalStore(
            rootURL: dependencies.controlRoot
                .appendingPathComponent(
                    "SwitchTransactions",
                    isDirectory: true
                )
        )
        let switchPending = try (passive ? switchStore.pendingReadOnly() : switchStore.pending())
        let adoptionStore = V011AdoptionJournalStore(
            rootURL: dependencies.controlRoot
                .appendingPathComponent(
                    "AdoptionTransactions",
                    isDirectory: true
                )
        )
        let adoptionPending = try (passive ? adoptionStore.pendingReadOnly() : adoptionStore.pending())
        let deletionStore = V011RelayDeletionJournalStore(
            rootURL: dependencies.controlRoot
                .appendingPathComponent(
                    "RelayDeletionTransactions",
                    isDirectory: true
                )
        )
        let deletionPending = try (passive ? deletionStore.pendingReadOnly() : deletionStore.pending())
        let failure = switchPending
            .filter { $0.phase == .rollbackFailed }
            .max { $0.updatedAt < $1.updatedAt }
        var detail = failure.map {
            V011RecoveryErrorText.safeDetail($0.message)
        }
        if detail == nil,
           let deletionFailure = deletionPending
            .filter({ $0.phase == .rollbackFailed })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            detail = V011RecoveryErrorText.safeDetail(
                deletionFailure.message
            )
        }
        let latestSwitch = switchPending.max {
            $0.updatedAt < $1.updatedAt
        }
        var switchDisposition: V011RecoveryDisposition = .none
        var configurationPreviews: [String: V014RecoveryFieldPreview] = [:]
        var configurationPreviewBindings: [String] = []
        // Startup reads journal facts only. Recoverability requires the later
        // explicit read, which may inspect the encrypted snapshot and version.
        if !switchPending.isEmpty && !passive {
            let coordinator = V011UnifiedSwitchCoordinator(
                codexHome: dependencies.codexHome,
                controlRoot: dependencies.controlRoot,
                managedProviderIDs: [],
                credentialStore: dependencies.credentialStore,
                processController: dependencies.processController,
                runtimeVerifier: dependencies.runtimeVerifier,
                versionDiscovery: dependencies.versionDiscovery,
                relayPreflightVerifier: { profile, secret in
                    _ = try await dependencies.verifyDraft(
                        profile,
                        secret
                    )
                },
                sessionCore: dependencies.sessionCore,
                keyProvider: dependencies.keyProvider
            )
            do {
                switchDisposition = try coordinator
                    .recoveryDisposition { id, prepared in
                        configurationPreviews[id] = V014RecoveryConfigurationPreview.read(prepared)
                        configurationPreviewBindings.append(
                            "configuration:\(id):\(prepared.expectedCurrentHash ?? "absent")")
                    }
            } catch {
                switchDisposition = .decisionRequired
                detail = [
                    detail,
                    "恢复状态暂时无法确认：\(V011RecoveryErrorText.safeDetail(error))",
                ]
                .compactMap { $0 }
                .joined(separator: "；")
            }
        }
        let hasPending = !switchPending.isEmpty
            || !adoptionPending.isEmpty
            || !deletionPending.isEmpty
        let disposition: V011RecoveryDisposition =
            passive && hasPending ? .unread
                : switchDisposition == .decisionRequired
                ? .decisionRequired
                : (hasPending ? .recoverable : .none)
        let fingerprintParts = switchPending.map {
            "switch:\($0.id):\($0.phase.rawValue):\($0.updatedAt.timeIntervalSinceReferenceDate)"
        } + adoptionPending.map {
            "adoption:\($0.id):\($0.phase.rawValue):\($0.updatedAt.timeIntervalSinceReferenceDate)"
        } + deletionPending.map {
            "deletion:\($0.id):\($0.phase.rawValue):\($0.updatedAt.timeIntervalSinceReferenceDate)"
        }
        let boundFingerprintParts = fingerprintParts + configurationPreviewBindings
        let preview = hasPending
            ? V014RecoveryRepairPreview(
                fingerprint: TOMLSemanticEngine.sha256(
                    Data(
                        boundFingerprintParts
                            .sorted()
                            .joined(separator: "\n")
                            .utf8
                    )
                ),
                switchCount: switchPending.count,
                adoptionCount: adoptionPending.count,
                deletionCount: deletionPending.count,
                protectsNewSessions:
                    latestSwitch?.protectsPostSwitchSessions == true,
                operationImpacts: V014RecoveryImpactPreview.operations(
                    switches: switchPending, adoptions: adoptionPending,
                    deletions: deletionPending, configurationPreviews: configurationPreviews)
            )
            : nil
        return V011PendingRecoveryContext(
            pending: hasPending,
            detail: detail,
            stage: failure?.failureStage?.displayName,
            nextAction: failure?.nextAction,
            protectsNewSessions: latestSwitch != nil,
            disposition: disposition,
            preview: preview
        )
    }

    private static func loadRecoveryDiagnosticSummary(
        controlRoot: URL,
        liveConfigHash: String?
    ) -> String {
        let receiptRoot = controlRoot.appendingPathComponent(
            "SessionTransactions",
            isDirectory: true
        )
        let sessionReceipt: V011SessionTransactionReceipt? =
            (try? V011SessionTransactionReceiptStore(
                rootURL: receiptRoot
            ).all())?
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        let pending: V011SwitchJournal? =
            (try? V011SwitchJournalStore(
                rootURL: controlRoot.appendingPathComponent(
                    "SwitchTransactions",
                    isDirectory: true
                )
            ).pending())?.first
        let transactionID = sessionReceipt?.id
            ?? pending?.id
            ?? "unavailable"
        let phase = sessionReceipt?.phase.rawValue
            ?? pending?.failureStage?.displayName
            ?? "unavailable"
        let failureCode = sessionReceipt?.failureCode?.rawValue
            ?? "unavailable"
        let size = sessionReceipt?.actualJournalBytes.map(String.init)
            ?? sessionReceipt?.estimatedJournalBytes.map(String.init)
            ?? "unavailable"
        let configHash = sessionReceipt?.configHash
            ?? liveConfigHash
            ?? "unavailable"
        let attempt = sessionReceipt.map { String($0.attempt) }
            ?? "unavailable"
        return [
            "transaction_id=\(transactionID)",
            "phase=\(phase)",
            "failure_code=\(failureCode)",
            "journal_size_bytes=\(size)",
            "config_hash=\(configHash)",
            "session_attempt=\(attempt)",
        ].joined(separator: "\n")
    }
}
