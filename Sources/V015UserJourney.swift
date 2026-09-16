// SPDX-License-Identifier: AGPL-3.0-only

enum V014HomePrimaryOutcome: String, Equatable, Sendable {
    case installCodex
    case recoverAccess
    case resolveAccessFailure
    case startWork
}

enum V014HomeOutcomeResolver {
    static func resolve(
        codexInstalled: Bool,
        hasPendingRecovery: Bool,
        hasConfigurationError: Bool,
        hasAccessFailure: Bool
    ) -> V014HomePrimaryOutcome {
        guard codexInstalled else { return .installCodex }
        if hasPendingRecovery || hasConfigurationError {
            return .recoverAccess
        }
        if hasAccessFailure {
            return .resolveAccessFailure
        }
        return .startWork
    }
}

enum V014VerificationJourneyStage: String, Equatable, Sendable {
    case recoveryRequired
    case needsBasic
    case checkingBasic
    case basicFailed
    case needsRealTask
    case verifyingRealTask
    case realTaskFailed
    case ready
}

enum V014VerificationJourneyResolver {
    static func resolve(
        hasPendingRecovery: Bool,
        isCheckingBasic: Bool,
        hasBasicEvidence: Bool,
        hasBasicFailure: Bool,
        isVerifyingRealTask: Bool,
        isRealTaskVerified: Bool,
        hasRealTaskFailure: Bool
    ) -> V014VerificationJourneyStage {
        if hasPendingRecovery { return .recoveryRequired }
        if isCheckingBasic { return .checkingBasic }
        if isVerifyingRealTask { return .verifyingRealTask }
        if isRealTaskVerified && !hasBasicFailure && !hasRealTaskFailure {
            return .ready
        }
        guard hasBasicEvidence else {
            return hasBasicFailure ? .basicFailed : .needsBasic
        }
        if hasRealTaskFailure { return .realTaskFailed }
        return .needsRealTask
    }
}

enum V015UserJourneyRoute: String, Equatable, Sendable {
    case official
    case relay
    case unknown
}

enum V015UserJourneyFailureSource: String, Equatable, Sendable {
    case compatibility
    case connection
    case agentLoop
}

enum V015UserJourneyRecoveryAction: String, Equatable, Sendable {
    case none
    case previewExisting
    case openDiagnostics
}

struct V015UserJourneyInput: Equatable, Sendable {
    let route: V015UserJourneyRoute
    let codexInstalled: Bool
    let hasPendingRecovery: Bool
    let canRunDeterministicRecovery: Bool
    let hasConfigurationError: Bool
    let hasCompatibilityFailure: Bool
    let hasConnectionFailure: Bool
    let hasBasicEvidence: Bool
    let isCheckingBasic: Bool
    let isVerifyingRealTask: Bool
    let isRealTaskVerified: Bool
    let hasAgentLoopFailure: Bool
}

struct V015UserJourneyDecision: Equatable, Sendable {
    let route: V015UserJourneyRoute
    let homeOutcome: V014HomePrimaryOutcome
    let verificationStage: V014VerificationJourneyStage
    let failureSource: V015UserJourneyFailureSource?
    let recoveryAction: V015UserJourneyRecoveryAction
}

enum V015UserJourneyResolver {
    static func resolve(
        _ input: V015UserJourneyInput
    ) -> V015UserJourneyDecision {
        let failureSource: V015UserJourneyFailureSource?
        if input.hasCompatibilityFailure {
            failureSource = .compatibility
        } else if input.hasBasicEvidence,
                  input.hasAgentLoopFailure {
            failureSource = .agentLoop
        } else if input.hasConnectionFailure {
            failureSource = .connection
        } else if input.hasAgentLoopFailure {
            failureSource = .agentLoop
        } else {
            failureSource = nil
        }

        let basicEvidenceUsable = input.hasBasicEvidence
            && !input.hasCompatibilityFailure
            && !input.hasConnectionFailure
        let recoveryAction: V015UserJourneyRecoveryAction
        if input.hasPendingRecovery {
            recoveryAction = input.canRunDeterministicRecovery
                ? .previewExisting : .openDiagnostics
        } else if input.hasConfigurationError {
            recoveryAction = .openDiagnostics
        } else {
            recoveryAction = .none
        }

        return V015UserJourneyDecision(
            route: input.route,
            homeOutcome: V014HomeOutcomeResolver.resolve(
                codexInstalled: input.codexInstalled,
                hasPendingRecovery: input.hasPendingRecovery,
                hasConfigurationError:
                    input.hasConfigurationError,
                hasAccessFailure: failureSource != nil
            ),
            verificationStage:
                V014VerificationJourneyResolver.resolve(
                    hasPendingRecovery:
                        input.hasPendingRecovery,
                    isCheckingBasic: input.isCheckingBasic,
                    hasBasicEvidence: basicEvidenceUsable,
                    hasBasicFailure:
                        input.hasCompatibilityFailure
                        || input.hasConnectionFailure,
                    isVerifyingRealTask:
                        input.isVerifyingRealTask,
                    isRealTaskVerified:
                        input.isRealTaskVerified,
                    hasRealTaskFailure:
                        input.hasAgentLoopFailure
                ),
            failureSource: failureSource,
            recoveryAction: recoveryAction
        )
    }
}
