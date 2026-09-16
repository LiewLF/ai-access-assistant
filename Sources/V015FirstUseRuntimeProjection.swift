// SPDX-License-Identifier: AGPL-3.0-only

struct V015FirstUseRuntimeProjection: Equatable, Sendable {
    let journey: V015UserJourneyDecision
    let guidance: V015FirstUseGuidance
}

@MainActor
enum V015FirstUseRuntimeProjectionResolver {
    static func resolve(
        accessModel: V011AccessModel,
        codexInstalled: Bool
    ) -> V015FirstUseRuntimeProjection {
        let route: V015UserJourneyRoute
        switch accessModel.liveState?.mode {
        case .official:
            route = .official
        case .relay:
            route = .relay
        case nil:
            route = .unknown
        }

        let journey = V015UserJourneyResolver.resolve(
            V015UserJourneyInput(
                route: route,
                codexInstalled: codexInstalled,
                hasPendingRecovery:
                    accessModel.hasPendingRecovery,
                canRunDeterministicRecovery:
                    accessModel.hasExecutableRecoveryAction
                    && accessModel.canRunDeterministicRepair,
                hasConfigurationError:
                    accessModel.errorMessage != nil,
                hasCompatibilityFailure:
                    accessModel.compatibilityFailurePresentation
                    != nil,
                hasConnectionFailure:
                    accessModel.currentConnectionFailurePresentation
                    != nil,
                hasBasicEvidence:
                    accessModel.hasCurrentBasicConnectionEvidence,
                isCheckingBasic:
                    accessModel.isCheckingCurrentConnection,
                isVerifyingRealTask:
                    accessModel.isVerifyingAgentLoop,
                isRealTaskVerified:
                    accessModel.isAgentLoopVerified,
                hasAgentLoopFailure:
                    accessModel.agentLoopFailurePresentation != nil
            )
        )
        let homeOutcome = journey.homeOutcome
        let guidance = V015FirstUseGuidanceResolver.resolve(
            V015FirstUseGuidanceInput(
                route: accessModel.needsCurrentStateRead ? .unknown : journey.route,
                codexInstalled: codexInstalled,
                savedRelayCount: accessModel.savedProfiles.count,
                verificationStage: journey.verificationStage,
                hasBlockingIssue:
                    homeOutcome == .recoverAccess
                    || homeOutcome == .resolveAccessFailure
                    || V016RuntimeEvidenceDrift.detected(
                        receipt: accessModel.agentLoopReceipt,
                        live: accessModel.liveState
                    ),
                isReadingCurrentState: accessModel.isRefreshing
            )
        )
        return V015FirstUseRuntimeProjection(
            journey: journey,
            guidance: guidance
        )
    }
}
