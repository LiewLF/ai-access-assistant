// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

struct V011SwitchResult {
    let journal: V011SwitchJournal
    let state: LiveCodexState
    let sessionSummary: SessionCoreRepairSummary
    let sessionReceipt: V011SessionTransactionReceipt?

    var configurationCommitted: Bool {
        journal.configTransactionPhase == .committed
            || journal.phase == .committed
    }

    var sessionPhase: V011SessionTransactionPhase {
        sessionReceipt?.phase ?? .skipped
    }
}

struct V011PostCommitSessionResult {
    let summary: SessionCoreRepairSummary
    let receipt: V011SessionTransactionReceipt?
}

struct V011SessionReconciliationSummary: Equatable, Sendable {
    var materializedReceiptIDs: [String] = []
    var receiptConflictIDs: [String] = []
}


struct V011RelayPreflightFailure: LocalizedError, Equatable {
    let detail: String

    var errorDescription: String? { detail }
}

struct V011CapabilityProfileUpdate: Equatable {
    let sourceProfile: CodexRelayProfile
    let targetProfile: CodexRelayProfile
    let allowsRelaySettings: Bool

    init(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        allowsRelaySettings: Bool = false
    ) {
        self.sourceProfile = sourceProfile
        self.targetProfile = targetProfile
        self.allowsRelaySettings = allowsRelaySettings
    }
}

struct V011CapabilityProfileUpdateResult {
    let liveState: LiveCodexState
    let managedState: V011ManagedState
    let appliedToLiveConfiguration: Bool
    let switchTransactionID: String?
}

struct V011UnifiedSwitchCoordinator: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let knownProfilesByProvider:
        [String: (id: String, name: String)]
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let versionDiscovery: any FableCodexVersionDiscovering
    let relayPreflightVerifier: @Sendable
        (CodexRelayProfile, String) async throws -> Void
    let preExecutionPreparation:
        @Sendable () throws -> Void
    let sessionCore: any V011SessionCoreOperating
    let defaultHistoryPolicy: V011HistoryPolicy
    let keyProvider: () throws -> Data
    let versionContract: CodexVersionContract
    let progress: @Sendable (String) -> Void
    let prePlanHook: @Sendable () throws -> Void
    let faultInjector:
        @Sendable (V011SwitchFaultPoint) throws -> Void
    let acceptedCurrentFaultInjector:
        @Sendable (V011AcceptedCurrentFaultPoint) throws -> Void
    let acceptedCurrentDirectorySynchronizer:
        @Sendable (Int32) -> Int32
    let sessionCancellationToken: V011SessionCancellationToken

    init(
        codexHome: URL,
        controlRoot: URL,
        managedProviderIDs: Set<String>,
        knownProfilesByProvider:
            [String: (id: String, name: String)] = [:],
        credentialStore: any FableCredentialStore,
        processController: any FableProcessController,
        runtimeVerifier: any FableRuntimeVerifier,
        versionDiscovery: any FableCodexVersionDiscovering,
        relayPreflightVerifier: @escaping @Sendable
            (CodexRelayProfile, String) async throws -> Void,
        preExecutionPreparation: @escaping @Sendable
            () throws -> Void = {},
        sessionCore: any V011SessionCoreOperating = SessionCoreClient(),
        defaultHistoryPolicy: V011HistoryPolicy = .configOnly,
        keyProvider: @escaping () throws -> Data,
        versionContract: CodexVersionContract = .verified,
        progress: @escaping @Sendable (String) -> Void = { _ in },
        prePlanHook: @escaping @Sendable () throws -> Void = {},
        faultInjector: @escaping @Sendable
            (V011SwitchFaultPoint) throws -> Void = { _ in },
        acceptedCurrentFaultInjector: @escaping @Sendable
            (V011AcceptedCurrentFaultPoint) throws -> Void = { _ in },
        acceptedCurrentDirectorySynchronizer: @escaping @Sendable
            (Int32) -> Int32 = { Darwin.fsync($0) },
        sessionCancellationToken:
            V011SessionCancellationToken = V011SessionCancellationToken()
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.controlRoot = controlRoot.standardizedFileURL
        self.managedProviderIDs = managedProviderIDs
        self.knownProfilesByProvider =
            knownProfilesByProvider
        self.credentialStore = credentialStore
        self.processController = processController
        self.runtimeVerifier = runtimeVerifier
        self.versionDiscovery = versionDiscovery
        self.relayPreflightVerifier =
            relayPreflightVerifier
        self.preExecutionPreparation =
            preExecutionPreparation
        self.sessionCore = sessionCore
        self.defaultHistoryPolicy = defaultHistoryPolicy
        self.keyProvider = keyProvider
        self.versionContract = versionContract
        self.progress = progress
        self.prePlanHook = prePlanHook
        self.faultInjector = faultInjector
        self.acceptedCurrentFaultInjector =
            acceptedCurrentFaultInjector
        self.acceptedCurrentDirectorySynchronizer =
            acceptedCurrentDirectorySynchronizer
        self.sessionCancellationToken = sessionCancellationToken
    }

    private var currentConnectionVerifier:
        V011CurrentConnectionVerifier {
        V011CurrentConnectionVerifier(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            versionDiscovery: versionDiscovery,
            sessionCore: sessionCore,
            versionContract: versionContract
        )
    }

    func verifyCurrentConnection(
        now: @Sendable () -> Date = { Date() },
        requireSavedRelayProfile: Bool = false,
        relayVerifier: (@Sendable (
            RelayProfile,
            String
        ) async throws -> Void)? = nil
    ) async throws -> V011CurrentConnectionVerification {
        try await currentConnectionVerifier.verify(
            now: now,
            requireSavedRelayProfile:
                requireSavedRelayProfile,
            relayVerifier: relayVerifier
        )
    }

    /// Re-checks the exact route immediately before/after committing a
    /// detached verification receipt. This method is intentionally
    /// read-only and never trusts the previously loaded managed-state cache.
    func validateCurrentConnection(
        _ verification: V011CurrentConnectionVerification,
        requireSavedRelayProfile: Bool = false
    ) throws {
        try currentConnectionVerifier.validate(
            verification,
            requireSavedRelayProfile:
                requireSavedRelayProfile
        )
    }

    private var switchExecutor: V011SwitchExecutor {
        V011SwitchExecutor(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            versionDiscovery: versionDiscovery,
            defaultHistoryPolicy: defaultHistoryPolicy,
            progress: progress,
            preExecutionPreparation:
                preExecutionPreparation,
            prePlanHook: prePlanHook,
            faultInjector: faultInjector,
            managedStateStore: managedStateStore,
            originLedgerStore: originLedgerStore,
            managedStateBaselineService:
                managedStateBaselineService,
            capabilityProfileService:
                capabilityProfileService,
            sessionTransactionCoordinator:
                sessionTransactionCoordinator,
            recoveryDecisionService:
                recoveryDecisionService,
            recoverySnapshotService:
                recoverySnapshotService,
            journalWriter: journalWriter,
            coreFactory: { providerIDs, contractEntry in
                makeCore(
                    managedProviderIDs: providerIDs,
                    resolvedContractEntry: contractEntry
                )
            }
        )
    }

    func execute(
        destination: FableSwitchDestination,
        capabilityUpdate: V011CapabilityProfileUpdate? = nil,
        historyPolicy: V011HistoryPolicy? = nil
    ) async throws -> V011SwitchResult {
        try await switchExecutor.execute(
            destination: destination,
            capabilityUpdate: capabilityUpdate,
            historyPolicy: historyPolicy
        )
    }

    private var sessionTransactionCoordinator:
        V011SessionTransactionCoordinator {
        V011SessionTransactionCoordinator(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            versionDiscovery: versionDiscovery,
            processController: processController,
            sessionCore: sessionCore,
            sessionRecoveryRoot: sessionRecoveryRoot,
            sessionTransactionRoot: sessionTransactionRoot,
            managedStateStore: managedStateStore,
            sessionCancellationToken: sessionCancellationToken,
            faultInjector: faultInjector,
            progress: progress,
            coreFactory: { providerIDs, contractEntry in
                makeCore(
                    managedProviderIDs: providerIDs,
                    resolvedContractEntry: contractEntry
                )
            },
            captureOrigins: { state in
                try await sessionPreparationService.captureOrigins(
                    managedState: state
                )
            },
            prepareRecoveryRoot: {
                try sessionPreparationService.prepareRecoveryRoot()
            },
            markOriginsVisible: { providerID in
                try sessionPreparationService.markOriginsVisible(
                    providerID: providerID
                )
            }
        )
    }

    @discardableResult
    func reconcileCommittedSessionTransactions()
        -> V011SessionReconciliationSummary {
        sessionTransactionCoordinator
            .reconcileCommittedSessionTransactions()
    }

    @discardableResult
    func cancelSessionTransaction(
        receiptID: String,
        expectedReceiptHash: String,
        reason: String = "userRequested"
    ) throws -> V011SessionTransactionReceipt {
        try sessionTransactionCoordinator.cancelSessionTransaction(
            receiptID: receiptID,
            expectedReceiptHash: expectedReceiptHash,
            reason: reason
        )
    }

    @discardableResult
    func resumeSessionTransaction(
        _ request: V011SessionResumeRequest
    ) throws -> V011SessionTransactionReceipt {
        try sessionTransactionCoordinator
            .resumeSessionTransaction(request)
    }

    private var capabilityProfileService:
        V011CapabilityProfileService {
        V011CapabilityProfileService(
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            versionDiscovery: versionDiscovery,
            relayPreflightVerifier: relayPreflightVerifier,
            prePlanHook: prePlanHook,
            managedStateStore: managedStateStore,
            coreFactory: { providerIDs, contractEntry in
                makeCore(
                    managedProviderIDs: providerIDs,
                    resolvedContractEntry: contractEntry
                )
            },
            captureBaseline: {
                try managedStateBaselineService.capture()
            },
            requireBaselineCurrent: { baseline in
                try managedStateBaselineService.requireCurrent(baseline)
            },
            executeSwitch: { destination, update in
                try await execute(
                    destination: destination,
                    capabilityUpdate: update
                )
            }
        )
    }

    func updateCapabilityProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile
    ) async throws -> V011CapabilityProfileUpdateResult {
        try await capabilityProfileService.updateCapabilityProfile(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile
        )
    }

    func updateRelayProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        requireInactiveSource: Bool = false
    ) async throws -> V011CapabilityProfileUpdateResult {
        try await capabilityProfileService.updateRelayProfile(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile,
            requireInactiveSource: requireInactiveSource
        )
    }

    private var recoveryDecisionService:
        V011RecoveryDecisionService {
        V011RecoveryDecisionService(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            sessionCore: sessionCore,
            versionContract: versionContract,
            keyProvider: keyProvider
        )
    }

    private var forwardCompletionService:
        V011ForwardCompletionService {
        V011ForwardCompletionService(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            versionDiscovery: versionDiscovery,
            sessionCore: sessionCore,
            versionContract: versionContract,
            keyProvider: keyProvider
        )
    }

    private var pendingRecoveryCoordinator:
        V011PendingRecoveryCoordinator {
        V011PendingRecoveryCoordinator(
            codexHome: codexHome,
            controlRoot: controlRoot,
            processController: processController,
            sessionCore: sessionCore,
            progress: progress,
            acceptedCurrentFaultInjector:
                acceptedCurrentFaultInjector,
            acceptedCurrentDirectorySynchronizer:
                acceptedCurrentDirectorySynchronizer,
            sessionTransactionCoordinator:
                sessionTransactionCoordinator,
            currentConnectionVerifier:
                currentConnectionVerifier,
            recoveryDecisionService:
                recoveryDecisionService,
            forwardCompletionService:
                forwardCompletionService,
            recoverySnapshotService:
                recoverySnapshotService,
            managedStateStore: managedStateStore,
            journalWriter: journalWriter
        )
    }

    func recoverPending() async throws -> Int {
        try await pendingRecoveryCoordinator.recoverPending()
    }

    func recoveryDisposition(
        onPreview: ((String, FablePreparedRecoveryConfiguration) -> Void)? = nil
    ) throws -> V011RecoveryDisposition {
        try pendingRecoveryCoordinator.recoveryDisposition(onPreview: onPreview)
    }

    func keepCurrentStateAndEndPendingRecovery()
        async throws -> Int {
        try await pendingRecoveryCoordinator
            .keepCurrentStateAndEndPendingRecovery()
    }

    func keepCurrentConfigurationAndEndPendingRecovery()
        async throws -> Int {
        try await pendingRecoveryCoordinator
            .keepCurrentConfigurationAndEndPendingRecovery()
    }

    func acceptCurrentRelayForPendingRecovery(
        now: @Sendable () -> Date = { Date() }
    ) async throws -> V011SwitchJournal {
        try await pendingRecoveryCoordinator
            .acceptCurrentRelayForPendingRecovery(now: now)
    }

    func restoreLatestCommitted() async throws {
        let store = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        guard var journal = try store.latestCommitted() else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let key = try journalWriter.validatedKey()
        guard try V011SwitchStateEvidenceAuthenticator
                .allowsAutomaticRecovery(
                    journal,
                    key: key
                ) else {
            throw V011SwitchError.recoveryDecisionRequired
        }
        let vault = SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchConfigVault",
                isDirectory: true
            ),
            keyProvider: { key }
        )
        try processController.stopConfigurationWriters()
        let recovery = try recoverySnapshotService.prepare(
            journal: journal,
            vault: vault
        )
        try recoverySnapshotService.apply(recovery)
        if let path = journal.sessionJournalPath {
            _ = try await sessionCore.rollback(
                codexHome: codexHome,
                recoveryRoot: sessionRecoveryRoot,
                journal: URL(fileURLWithPath: path),
                journalKey: key
            )
        }
        try processController.relaunchCodex()
        try journalWriter.update(
            &journal,
            phase: .rolledBack,
            message: "已恢复上次切换",
            store: store
        )
    }

    private var sessionRecoveryRoot: URL {
        controlRoot.appendingPathComponent(
            "SessionCoreRecovery",
            isDirectory: true
        )
    }

    private var sessionTransactionRoot: URL {
        controlRoot.appendingPathComponent(
            "SessionTransactions",
            isDirectory: true
        )
    }

    private var managedStateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent("state.json")
        )
    }

    private var managedStateBaselineService:
        V011ManagedStateBaselineService {
        V011ManagedStateBaselineService(
            managedStateStore: managedStateStore
        )
    }

    private var originLedgerStore:
        V011SessionOriginLedgerStore {
        V011SessionOriginLedgerStore(
            rootURL: controlRoot.appendingPathComponent(
                "SessionOriginLedger",
                isDirectory: true
            ),
            keyProvider: keyProvider
        )
    }

    private var sessionPreparationService:
        V011SessionPreparationService {
        V011SessionPreparationService(
            codexHome: codexHome,
            sessionRecoveryRoot: sessionRecoveryRoot,
            sessionCore: sessionCore,
            originLedgerStore: originLedgerStore,
            knownProfilesByProvider:
                knownProfilesByProvider
        )
    }

    private func makeCore(
        managedProviderIDs: Set<String>,
        resolvedContractEntry:
            CodexVersionContract.Entry? = nil
    ) -> FableSwitchCore {
        FableSwitchCore(
            codexHome: codexHome,
            versionContract: versionContract,
            resolvedContractEntry:
                resolvedContractEntry,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            managedProviderIDs: managedProviderIDs
        )
    }

    private var recoverySnapshotService:
        V011RecoverySnapshotService {
        V011RecoverySnapshotService(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            versionContract: versionContract,
            keyProvider: keyProvider
        )
    }

    private var journalWriter: V011SwitchJournalWriter {
        V011SwitchJournalWriter(keyProvider: keyProvider)
    }
}
