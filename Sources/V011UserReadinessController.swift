import Foundation

@MainActor
protocol V011UserReadinessControllerDelegate: AnyObject {
    var canRefreshOfficialUsage: Bool { get }
    var userReadinessUsesOfficialAccess: Bool { get }
    var userReadinessSavedRelayReceiptsForCommit:
        [String: V011SavedRelayReadinessReceipt] { get }

    func canVerifySavedRelayReadiness(
        _ profile: CodexRelayProfile
    ) -> Bool
    func userReadinessSavedRelayProfileIsCurrent(
        _ profile: CodexRelayProfile
    ) -> Bool
    func userReadinessOfficialUsageDidReject(
        _ message: String
    )
    func userReadinessOfficialUsageDidBegin()
    func userReadinessOfficialUsageDidBecomeIdle()
    func userReadinessOfficialUsageDidReceive(
        _ outcome: V011OfficialUsageRefreshOutcome
    )
    func userReadinessSavedRelayDidReject(
        profileID: String,
        message: String
    )
    func userReadinessSavedRelayDidBegin(
        profileID: String
    )
    func userReadinessSavedRelayDidBecomeIdle()
    func userReadinessSavedRelayDidReceive(
        profileID: String,
        outcome: V011SavedRelayReadinessCommitOutcome
    )
}

/// Owns user-readiness task cancellation and completion ordering.
/// AccessModel remains weak delegate for gates and Published-state projection.
@MainActor
final class V011UserReadinessController {
    private weak var delegate:
        (any V011UserReadinessControllerDelegate)?
    private let actionService: V011UserReadinessActionService
    private var officialUsageTask: Task<Void, Never>?
    private var savedRelayReadinessTask: Task<Void, Never>?

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011UserReadinessControllerDelegate
    ) {
        actionService = V011UserReadinessActionService(
            dependencies: dependencies
        )
        self.delegate = delegate
    }

    func loadEvidence() -> V011UserReadinessEvidenceSnapshot {
        actionService.loadEvidence()
    }

    func refreshOfficialUsage(
        threadID: String?
    ) {
        guard let delegate else { return }
        guard delegate.canRefreshOfficialUsage else {
            if !delegate.userReadinessUsesOfficialAccess {
                delegate.userReadinessOfficialUsageDidReject(
                    "仅当前使用Codex官方时读取官方额度"
                )
            }
            return
        }
        delegate.userReadinessOfficialUsageDidBegin()
        let service = actionService
        officialUsageTask?.cancel()
        officialUsageTask = Task { [weak self] in
            let outcome = await service.refreshOfficialUsage(
                threadID: threadID
            )
            guard let self,
                  !Task.isCancelled,
                  let delegate = self.delegate else {
                return
            }
            delegate.userReadinessOfficialUsageDidBecomeIdle()
            switch outcome {
            case .success:
                guard delegate.userReadinessUsesOfficialAccess else {
                    delegate.userReadinessOfficialUsageDidReject(
                        "读取期间接入已变化，本次额度未显示"
                    )
                    return
                }
                delegate.userReadinessOfficialUsageDidReceive(outcome)
            case .failure:
                delegate.userReadinessOfficialUsageDidReceive(outcome)
            case .cancelled:
                return
            }
        }
    }

    func verifySavedRelayReadiness(
        _ profile: CodexRelayProfile,
        userConsented: Bool
    ) {
        guard let delegate else { return }
        guard userConsented else {
            delegate.userReadinessSavedRelayDidReject(
                profileID: profile.id,
                message: "需要确认联网和可能产生的一次API费用"
            )
            return
        }
        guard delegate.canVerifySavedRelayReadiness(profile) else {
            return
        }
        delegate.userReadinessSavedRelayDidBegin(
            profileID: profile.id
        )
        let service = actionService
        savedRelayReadinessTask?.cancel()
        savedRelayReadinessTask = Task { [weak self] in
            let outcome = await service
                .verifySavedRelayReadiness(profile)
            guard let self,
                  !Task.isCancelled,
                  let delegate = self.delegate else {
                return
            }
            delegate.userReadinessSavedRelayDidBecomeIdle()
            switch outcome {
            case let .success(verified):
                let committed = service.commitSavedRelayReadiness(
                    verified,
                    profile: profile,
                    profileIsCurrent: delegate
                        .userReadinessSavedRelayProfileIsCurrent(profile),
                    existingReceipts: delegate
                        .userReadinessSavedRelayReceiptsForCommit
                )
                delegate.userReadinessSavedRelayDidReceive(
                    profileID: profile.id,
                    outcome: committed
                )
            case let .failure(message):
                delegate.userReadinessSavedRelayDidReceive(
                    profileID: profile.id,
                    outcome: .failure(message)
                )
            case .cancelled:
                return
            }
        }
    }
}
