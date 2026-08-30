import Foundation

struct V011AgentLoopVerificationResult: @unchecked Sendable {
    let probeResult: V011AgentLoopProbeResult
    let matchesCurrent: Bool
}

/// Owns real-task verification and durable receipt matching.
struct V011AgentLoopService: @unchecked Sendable {
    private let verifier: any V011AgentLoopVerifying
    private let now: @Sendable () -> Date
    let receiptStore: V011AgentLoopReceiptStore

    init(dependencies: V011AccessDependencies) {
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
        let expectedProviderID =
            V011ConnectionHealthService.providerID(live)
        let expectedConfigHash = live.configHash
        return try await Task.detached(
            priority: .userInitiated
        ) {
            let result = try verifier.verify(
                userConsented: true,
                expectedProviderID: expectedProviderID,
                expectedConfigHash: expectedConfigHash
            )
            try receiptStore.commit(result.receipt)
            return V011AgentLoopVerificationResult(
                probeResult: result,
                matchesCurrent: verifier.receiptMatchesCurrent(
                    result.receipt,
                    live: live,
                    now: now()
                )
            )
        }.value
    }

    func receiptTargetsCurrentState(
        _ receipt: V011AgentLoopReceipt,
        live: LiveCodexState
    ) -> Bool {
        receipt.isStructurallyValid
            && receipt.expiresAt > now()
            && receipt.configHash == live.configHash
            && receipt.providerID
                == V011ConnectionHealthService.providerID(live)
            && receipt.endpointHost
                == V011AgentLoopReceipt.endpointHost(live)
            && receipt.modelID == live.model
            && receipt.codexAppVersion == live.version.appVersion
            && receipt.codexAppBuild == live.version.appBuild
            && receipt.codexCLIVersion == live.version.cliVersion
    }
}
