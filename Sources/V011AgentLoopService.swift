import Foundation

struct V011AgentLoopVerificationResult: @unchecked Sendable {
    let probeResult: V011AgentLoopProbeResult
    let currentState: V011AccessStateSnapshot

    var matchesCurrent: Bool {
        currentState.agentLoopMatches && !currentState.pending
            && currentState.agentLoopReceipt == probeResult.receipt
    }
}

/// Owns real-task verification and durable receipt matching.
struct V011AgentLoopService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let verifier: any V011AgentLoopVerifying
    private let now: @Sendable () -> Date
    let receiptStore: V011AgentLoopReceiptStore

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
        verifier = dependencies.agentLoopVerifier
        now = dependencies.now
        receiptStore = V011AgentLoopReceiptStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("agent-loop-receipt.json")
        )
    }

    func verify(
        live: LiveCodexState
    ) async throws -> V011AgentLoopVerificationResult {
        guard let expectedRouteIdentity =
                V011AgentLoopRouteIdentity(live: live),
              expectedRouteIdentity.modelID != nil else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return try await Task.detached(
            priority: .userInitiated
        ) {
            let result = try verifier.verify(
                userConsented: true,
                expectedRouteIdentity: expectedRouteIdentity
            )
            try receiptStore.commit(result.receipt)
            // The caller can still hold the passive startup version marker.
            // Match the stored result against freshly discovered local state,
            // preserving the same route/runtime/expiry and recovery guards.
            let recovery = try V011AccessStateReader.pendingRecoveryContext(
                dependencies: dependencies
            )
            let currentState = try V011AccessStateReader.readState(
                dependencies: dependencies, pending: recovery.pending
            )
            return V011AgentLoopVerificationResult(
                probeResult: result,
                currentState: currentState
            )
        }.value
    }

    func receiptTargetsCurrentState(
        _ receipt: V011AgentLoopReceipt,
        live: LiveCodexState
    ) -> Bool {
        receipt.isStructurallyValid
            && receipt.expiresAt > now()
            && receipt.targets(live)
    }
}
