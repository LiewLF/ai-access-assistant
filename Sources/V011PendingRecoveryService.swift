import Foundation

enum V011DeterministicRepairOutcome: @unchecked Sendable {
    case completed(
        count: Int,
        verification: V011AgentLoopProbeResult,
        state: V011AccessStateSnapshot
    )
    case previewChanged(V011PendingRecoveryContext)
    case failed(
        verification: V011AgentLoopProbeResult?,
        state: V011AccessStateSnapshot?,
        safeError: String
    )
}

/// Owns pending recovery execution, accepted-current closure, and
/// deterministic repair with real-task proof.
struct V011PendingRecoveryService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let progress: @Sendable (String) -> Void

    init(
        dependencies: V011AccessDependencies,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dependencies = dependencies
        self.progress = progress
    }

    func recoverPending() async throws -> Int {
        let adoptionCount = try adoptionCoordinator.recoverPending()
        let deletionCount = try deletionCoordinator.recoverPending()
        let coordinator = try coordinatorFactory.make()
        let switchCount = try await coordinator.recoverPending()
        return adoptionCount + deletionCount + switchCount
    }

    func keepCurrentConfigurationAndEndPendingRecovery()
        async throws -> Int {
        try await coordinatorFactory.makePendingRecovery()
            .keepCurrentConfigurationAndEndPendingRecovery()
    }

    func acceptCurrentRelayForPendingRecovery()
        async throws -> V011ManagedState {
        _ = try await coordinatorFactory.makePendingRecovery()
            .acceptCurrentRelayForPendingRecovery(
                now: dependencies.now
            )
        return try stateStore.load()
    }

    func runDeterministicRepair(
        expectedPreviewFingerprint: String
    ) async -> V011DeterministicRepairOutcome {
        let verifier = dependencies.agentLoopVerifier
        let receiptStore = V011AgentLoopService(
            dependencies: dependencies
        ).receiptStore
        let recorder = V011AgentLoopRepairRecorder()
        let repairVerifier = V011AgentLoopRepairRuntimeVerifier(
            base: dependencies.runtimeVerifier,
            agentLoopVerifier: verifier,
            receiptStore: receiptStore,
            recorder: recorder
        )
        var refreshedState: V011AccessStateSnapshot?
        do {
            let freshContext = try V011AccessStateReader
                .pendingRecoveryContext(dependencies: dependencies)
            guard freshContext.disposition == .recoverable,
                  freshContext.preview?.fingerprint
                    == expectedPreviewFingerprint else {
                return .previewChanged(freshContext)
            }
            let coordinator = try coordinatorFactory.make(
                runtimeVerifier: repairVerifier
            )
            let adoptionCount = try adoptionCoordinator.recoverPending()
            let deletionCount = try deletionCoordinator.recoverPending()
            let switchCount = try await coordinator.recoverPending()
            if recorder.result == nil {
                let result = try verifier.verify(
                    userConsented: true,
                    expectedRouteIdentity: nil
                )
                recorder.record(result)
                try receiptStore.commit(result.receipt)
                guard result.receipt.outcome == .passed else {
                    throw V011AgentLoopVerificationError.probeFailed(
                        result.receipt.failureStage ?? .finalResponse
                    )
                }
            }
            guard let result = recorder.result else {
                throw V011AgentLoopVerificationError
                    .probeFailed(.finalResponse)
            }
            let refreshed = try V011AccessStateReader.readState(
                dependencies: dependencies,
                pending: false
            )
            refreshedState = refreshed
            guard refreshed.agentLoopMatches else {
                throw V011AgentLoopVerificationError.probeFailed(
                    result.receipt.failureStage
                        ?? .configurationChanged
                )
            }
            return .completed(
                count: adoptionCount + deletionCount + switchCount,
                verification: result,
                state: refreshed
            )
        } catch {
            return .failed(
                verification: recorder.result,
                state: refreshedState,
                safeError: V011RecoveryErrorText.safeDetail(error)
            )
        }
    }

    private var coordinatorFactory: V011SwitchCoordinatorFactory {
        V011SwitchCoordinatorFactory(
            dependencies: dependencies,
            progress: progress
        )
    }

    private var adoptionCoordinator:
        V011AdoptionTransactionCoordinator {
        V011AdoptionTransactionCoordinator(
            codexHome: dependencies.codexHome,
            controlRoot: dependencies.controlRoot,
            credentialStore: dependencies.credentialStore,
            keyProvider: dependencies.keyProvider
        )
    }

    private var deletionCoordinator:
        V011RelayDeletionTransactionCoordinator {
        V011SavedRelayService(dependencies: dependencies)
            .deletionCoordinator
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }
}
