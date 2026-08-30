import Foundation

enum V011OfficialUsageRefreshOutcome: @unchecked Sendable {
    case success(V011OfficialUsageSnapshot)
    case failure(V013FailurePresentation)
    case cancelled
}

struct V011SavedRelayReadinessVerification: @unchecked Sendable {
    let receipt: V011SavedRelayReadinessReceipt
    let matches: Bool
}

enum V011SavedRelayReadinessVerificationOutcome:
    @unchecked Sendable {
    case success(V011SavedRelayReadinessVerification)
    case failure(String)
    case cancelled
}

enum V011SavedRelayReadinessCommitOutcome: @unchecked Sendable {
    case success(
        receipts: [String: V011SavedRelayReadinessReceipt],
        matches: Bool
    )
    case failure(String)
}

/// Owns user-readiness background work and synchronous evidence finalization.
/// MainActor controller retains cancellation and completion ordering; its weak
/// façade delegate owns Published-state assignment.
struct V011UserReadinessActionService: @unchecked Sendable {
    private let coordinator: V011UserReadinessCoordinator

    init(dependencies: V011AccessDependencies) {
        coordinator = V011UserReadinessCoordinator(
            dependencies: dependencies
        )
    }

    func loadEvidence() -> V011UserReadinessEvidenceSnapshot {
        coordinator.loadEvidence()
    }

    func refreshOfficialUsage(
        threadID: String?
    ) async -> V011OfficialUsageRefreshOutcome {
        let coordinator = coordinator
        let result: Result<V011OfficialUsageSnapshot, Error> =
            await Task.detached(priority: .userInitiated) {
                Result {
                    try coordinator.refreshOfficialUsage(
                        threadID: threadID
                    )
                }
            }.value
        guard !Task.isCancelled else { return .cancelled }
        switch result {
        case let .success(snapshot):
            return .success(snapshot)
        case let .failure(error):
            return .failure(
                V013FailurePresentation.officialUsage(error)
            )
        }
    }

    func verifySavedRelayReadiness(
        _ profile: CodexRelayProfile
    ) async -> V011SavedRelayReadinessVerificationOutcome {
        let coordinator = coordinator
        let result: Result<
            V011SavedRelayReadinessVerification,
            Error
        > = await Task.detached(priority: .userInitiated) {
            Result {
                let verified = try coordinator
                    .verifySavedRelayReadiness(profile)
                return V011SavedRelayReadinessVerification(
                    receipt: verified.receipt,
                    matches: verified.matches
                )
            }
        }.value
        guard !Task.isCancelled else { return .cancelled }
        switch result {
        case let .success(verified):
            return .success(verified)
        case let .failure(error):
            return .failure(
                V011UserReadinessCoordinator.safeError(error)
            )
        }
    }

    func commitSavedRelayReadiness(
        _ verified: V011SavedRelayReadinessVerification,
        profile: CodexRelayProfile,
        profileIsCurrent: Bool,
        existingReceipts:
            [String: V011SavedRelayReadinessReceipt]
    ) -> V011SavedRelayReadinessCommitOutcome {
        guard profileIsCurrent else {
            return .failure(
                "验证期间中转资料已变化，本次结果已作废"
            )
        }
        var receipts = existingReceipts
        receipts[profile.id] = verified.receipt
        do {
            try coordinator.commitSavedRelayReadiness(receipts)
            return .success(
                receipts: receipts,
                matches: verified.matches
            )
        } catch {
            return .failure("验证完成，但证据未能安全保存")
        }
    }
}
