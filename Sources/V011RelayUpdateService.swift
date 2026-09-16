import Foundation

struct V011RelayUpdateFailure: LocalizedError, @unchecked Sendable {
    let primaryDescription: String
    let primarySafeDescription: String
    let recoverySafeDescription: String?
    let isPreflight: Bool
    let shouldRefresh: Bool

    var errorDescription: String? {
        [
            primarySafeDescription,
            recoverySafeDescription.map {
                "凭据恢复未完成：\($0)"
            },
        ].compactMap { $0 }.joined(separator: "；")
    }
}

/// Owns capability/profile update execution and replacement-credential
/// compensation. MainActor controller decides eligibility; its façade delegate
/// projects returned state.
struct V011RelayUpdateService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let coordinatorFactory: V011SwitchCoordinatorFactory
    private let savedRelayService: V011SavedRelayService

    init(
        dependencies: V011AccessDependencies,
        coordinatorFactory: V011SwitchCoordinatorFactory,
        savedRelayService: V011SavedRelayService
    ) {
        self.dependencies = dependencies
        self.coordinatorFactory = coordinatorFactory
        self.savedRelayService = savedRelayService
    }

    func updateCapabilities(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile
    ) async throws -> V011CapabilityProfileUpdateResult {
        var shouldRefresh = false
        do {
            let coordinator = try coordinatorFactory.make()
            shouldRefresh = true
            return try await coordinator.updateCapabilityProfile(
                sourceProfile: sourceProfile,
                targetProfile: targetProfile
            )
        } catch {
            throw failure(
                error,
                recoverySafeDescription: nil,
                shouldRefresh: shouldRefresh
            )
        }
    }

    func updateProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        replacementSecret: String?
    ) async throws -> V011CapabilityProfileUpdateResult {
        var previousSecret: String?
        var storedReplacement = false
        var shouldRefresh = false
        do {
            if let issue = V011RelayEndpointPolicy.draftIssue(
                targetProfile.baseURL,
                localGatewayConfirmed: targetProfile.localGatewayConfirmed == true
            ) {
                throw V011RelayPreflightFailure(detail: issue)
            }
            if let replacementSecret {
                previousSecret = try dependencies.credentialStore.secret(
                    reference: sourceProfile.v011CredentialReference
                )
                try dependencies.credentialStore.store(
                    replacementSecret,
                    reference: sourceProfile.v011CredentialReference
                )
                storedReplacement = true
            }
            let coordinator = try coordinatorFactory.make()
            shouldRefresh = true
            return try await coordinator.updateRelayProfile(
                sourceProfile: sourceProfile,
                targetProfile: targetProfile,
                requireInactiveSource: storedReplacement
            )
        } catch {
            let primary = error
            var recoverySafeDescription: String?
            if storedReplacement {
                do {
                    try savedRelayService.restoreCredential(
                        previousSecret,
                        reference: sourceProfile
                            .v011CredentialReference
                    )
                } catch {
                    recoverySafeDescription =
                        V011RecoveryErrorText.safeDetail(error)
                }
            }
            throw failure(
                primary,
                recoverySafeDescription: recoverySafeDescription,
                shouldRefresh: shouldRefresh
            )
        }
    }

    private func failure(
        _ error: Error,
        recoverySafeDescription: String?,
        shouldRefresh: Bool
    ) -> V011RelayUpdateFailure {
        let isPreflight = error is V011RelayPreflightFailure
        return V011RelayUpdateFailure(
            primaryDescription: error.localizedDescription,
            primarySafeDescription:
                V011RecoveryErrorText.safeDetail(error),
            recoverySafeDescription: recoverySafeDescription,
            isPreflight: isPreflight,
            shouldRefresh: isPreflight ? false : shouldRefresh
        )
    }
}
