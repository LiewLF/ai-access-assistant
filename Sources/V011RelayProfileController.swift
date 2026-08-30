import Foundation

@MainActor
protocol V011RelayProfileControllerDelegate: AnyObject {
    var allowsRelayProfileActionStart: Bool { get }
    var hasPendingRecovery: Bool { get }
    var currentProviderID: String? { get }

    func relayProfilePendingRecoveryBlockMessage(
        action: String
    ) -> String
    func relayProfileActionDidReject(_ message: String)
    func relayProfileActionDidProgress(_ message: String)
    func relayProfileUpdateDidBegin(status: String)
    func relayProfileUpdateDidReceive(
        _ outcome: V011RelayUpdateActionOutcome
    )
    func relayProfileAdoptionDidBegin()
    func relayProfileAdoptionDidReceive(
        _ outcome: V011RelayAdoptionActionOutcome
    )
    func relayProfileActionDidBecomeIdle()
    func relayProfileActionRequestsRefresh()
}

/// Owns relay capability/profile/adoption gates, task launch, progress, and
/// completion ordering. Existing services retain transactions and recovery.
@MainActor
final class V011RelayProfileController {
    private let dependencies: V011AccessDependencies
    private weak var delegate:
        (any V011RelayProfileControllerDelegate)?

    private lazy var updateActionService =
        V011RelayUpdateActionService(
            service: V011RelayUpdateService(
                dependencies: dependencies,
                coordinatorFactory: V011SwitchCoordinatorFactory(
                    dependencies: dependencies,
                    progress: { [weak self] message in
                        Task { @MainActor in
                            self?.delegate?
                                .relayProfileActionDidProgress(message)
                        }
                    }
                ),
                savedRelayService: V011SavedRelayService(
                    dependencies: dependencies
                )
            )
        )
    private lazy var adoptionActionService =
        V011RelayAdoptionActionService(
            dependencies: dependencies
        )

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011RelayProfileControllerDelegate
    ) {
        self.dependencies = dependencies
        self.delegate = delegate
    }

    func updateCapabilities(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile
    ) {
        guard let delegate,
              prepareUpdate(
                  delegate: delegate,
                  pendingAction: "配置中转能力",
                  status: delegate.currentProviderID
                    == sourceProfile.v011ProviderID
                        ? "正在应用当前轨能力；同轨更新不整理历史会话"
                        : "正在保存中转能力档"
              ) else {
            return
        }
        let service = updateActionService
        Task {
            let outcome = await service.updateCapabilities(
                sourceProfile: sourceProfile,
                targetProfile: targetProfile
            )
            finishUpdate(outcome, delegate: delegate)
        }
    }

    func updateProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        replacementAPIKey: String?
    ) {
        guard let delegate,
              delegate.allowsRelayProfileActionStart else {
            return
        }
        guard !delegate.hasPendingRecovery else {
            rejectPending(
                action: "修改中转资料",
                delegate: delegate
            )
            return
        }
        let replacement = replacementAPIKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newSecret = replacement?.isEmpty == false
            ? replacement : nil
        let sourceIsCurrent = delegate.currentProviderID
            == sourceProfile.v011ProviderID
        guard !(sourceIsCurrent && newSecret != nil) else {
            delegate.relayProfileActionDidReject(
                "当前轨密钥不能直接替换。先切到官方或另一条中转，再在此窗口安全更新。"
            )
            return
        }
        delegate.relayProfileUpdateDidBegin(
            status: sourceIsCurrent
                ? "正在修改当前中转；同轨更新不整理历史会话"
                : "正在验证并保存中转资料"
        )
        let service = updateActionService
        Task {
            let outcome = await service.updateProfile(
                sourceProfile: sourceProfile,
                targetProfile: targetProfile,
                replacementSecret: newSecret,
                sourceIsCurrent: sourceIsCurrent
            )
            finishUpdate(outcome, delegate: delegate)
        }
    }

    func adoptCurrentRelay(
        displayName: String,
        replacementAPIKey: String
    ) {
        guard let delegate,
              delegate.allowsRelayProfileActionStart else {
            return
        }
        guard !delegate.hasPendingRecovery else {
            rejectPending(
                action: "接管当前中转",
                delegate: delegate
            )
            return
        }
        _ = replacementAPIKey
        delegate.relayProfileAdoptionDidBegin()
        let service = adoptionActionService
        Task {
            let outcome = await service.adoptCurrentRelay(
                displayName: displayName
            )
            delegate.relayProfileAdoptionDidReceive(outcome)
            delegate.relayProfileActionDidBecomeIdle()
        }
    }

    private func prepareUpdate(
        delegate: any V011RelayProfileControllerDelegate,
        pendingAction: String,
        status: String
    ) -> Bool {
        guard delegate.allowsRelayProfileActionStart else {
            return false
        }
        guard !delegate.hasPendingRecovery else {
            rejectPending(action: pendingAction, delegate: delegate)
            return false
        }
        delegate.relayProfileUpdateDidBegin(status: status)
        return true
    }

    private func rejectPending(
        action: String,
        delegate: any V011RelayProfileControllerDelegate
    ) {
        delegate.relayProfileActionDidReject(
            delegate.relayProfilePendingRecoveryBlockMessage(
                action: action
            )
        )
    }

    private func finishUpdate(
        _ outcome: V011RelayUpdateActionOutcome,
        delegate: any V011RelayProfileControllerDelegate
    ) {
        delegate.relayProfileUpdateDidReceive(outcome)
        delegate.relayProfileActionDidBecomeIdle()
        switch outcome {
        case .success:
            delegate.relayProfileActionRequestsRefresh()
        case let .failure(_, _, shouldRefresh):
            if shouldRefresh {
                delegate.relayProfileActionRequestsRefresh()
            }
        }
    }
}
