import Foundation

struct V011CurrentConnectionCheckResult: @unchecked Sendable {
    let verification: V011CurrentConnectionVerification
    let receipt: V011ConnectionReceipt
    let endpointHost: String?
    let runtimeFreshness: V011RuntimeFreshness
    let receiptMatches: Bool
    var isVerified: Bool {
        // The probe verifies this connection. A provider index covering old
        // tasks cannot establish the route of the currently running task.
        receiptMatches
    }
}

/// Owns live connection verification through durable receipt commit.
/// MainActor façade only projects result into user-visible state and history.
struct V011CurrentConnectionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let coordinatorFactory: V011SwitchCoordinatorFactory
    private let connectionHealthService: V011ConnectionHealthService

    init(
        dependencies: V011AccessDependencies,
        coordinatorFactory: V011SwitchCoordinatorFactory,
        connectionHealthService: V011ConnectionHealthService
    ) {
        self.dependencies = dependencies
        self.coordinatorFactory = coordinatorFactory
        self.connectionHealthService = connectionHealthService
    }

    func verify() async throws -> V011CurrentConnectionCheckResult {
        let coordinator = try coordinatorFactory.make(
            runtimeVerifier:
                dependencies.currentConnectionRuntimeVerifier
        )
        let now = dependencies.now
        let result = try await Task.detached(
            priority: .userInitiated
        ) {
            try await coordinator.verifyCurrentConnection(
                now: now,
                relayVerifier: { profile, secret in
                    let requestProfile = CodexRelayProfile(
                        id: profile.id,
                        providerID: profile.providerID,
                        name: profile.displayName,
                        baseURL: profile.baseURL,
                        wireProtocol: .responses,
                        models: [profile.model],
                        defaultModel: profile.model,
                        contextWindow: profile.contextWindow,
                        autoCompactTokenLimit:
                            profile.autoCompactTokenLimit,
                        reasoningEffort: .automatic
                    )
                    _ = try await dependencies.verifyCurrentRelay(
                        requestProfile,
                        secret
                    )
                }
            )
        }.value
        try dependencies.beforeConnectionReceiptSave()
        try coordinator.validateCurrentConnection(result)
        let endpointHost = V011ConnectionHealthService
            .normalizedEndpointHost(result.endpointHost)
        if case .relay = result.state.mode,
           endpointHost == nil {
            throw V011CurrentConnectionVerificationError
                .endpointHostUnavailable
        }
        let receipt = V011ConnectionReceipt(
            configHash: result.configHash,
            providerID: result.providerID,
            endpointHost: endpointHost,
            verifiedAt: result.verifiedAt,
            sessionProviderCheck: result.sessionProviderCheck,
            expiresAt: result.verifiedAt.addingTimeInterval(
                V011ConnectionReceipt.validityDuration
            )
        )
        try connectionHealthService.receiptStore.commit(receipt) {
            try dependencies.afterConnectionReceiptSave()
            try coordinator.validateCurrentConnection(result)
        }
        let freshness = V011ConnectionHealthService.runtimeFreshness(
            live: result.state,
            runtimeObservation: dependencies.codexRuntimeObservation()
        )
        let receiptMatches = V011ConnectionHealthService.receiptMatches(
            receipt,
            live: result.state,
            at: dependencies.now()
        )
        return V011CurrentConnectionCheckResult(
            verification: result,
            receipt: receipt,
            endpointHost: endpointHost,
            runtimeFreshness: freshness,
            receiptMatches: receiptMatches
        )
    }
}
