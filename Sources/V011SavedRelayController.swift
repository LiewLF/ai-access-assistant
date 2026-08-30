import Foundation

@MainActor
protocol V011SavedRelayControllerDelegate: AnyObject {
    var allowsSavedRelayMutationStart: Bool { get }
    var hasPendingRecovery: Bool { get }
    var managedState: V011ManagedState { get }
    var currentProviderID: String? { get }

    func canPreflightSavedRelay(
        _ profile: CodexRelayProfile
    ) -> Bool
    func savedRelayPendingRecoveryBlockMessage(
        action: String
    ) -> String
    func savedRelayActionDidReject(_ message: String)
    func savedRelayPreflightDidBegin(
        profile: CodexRelayProfile
    )
    func savedRelayPreflightDidReceive(
        profileID: String,
        outcome: V011SavedRelayPreflightActionOutcome
    )
    func savedRelayPreflightDidBecomeIdle(
        profileID: String
    )
    func savedRelayDeleteDidBegin(profile: CodexRelayProfile)
    func savedRelayDeleteDidReceive(
        profileID: String,
        outcome: V011SavedRelayDeleteOutcome
    )
    func savedRelayAddDidBegin()
    func savedRelayAddDidReceive(
        _ outcome: V011SavedRelayAddOutcome
    )
    func savedRelayMutationDidBecomeIdle()
    func savedRelayActionRequestsRefresh()
}

/// Owns saved-relay action gates, task launch, and completion ordering.
/// Transaction and compensation remain in V011SavedRelayService.
@MainActor
final class V011SavedRelayController {
    private weak var delegate:
        (any V011SavedRelayControllerDelegate)?
    private let actionService: V011SavedRelayActionService

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011SavedRelayControllerDelegate
    ) {
        actionService = V011SavedRelayActionService(
            dependencies: dependencies
        )
        self.delegate = delegate
    }

    func preflight(_ profile: CodexRelayProfile) {
        guard let delegate,
              delegate.canPreflightSavedRelay(profile) else {
            return
        }
        let profileID = profile.id
        delegate.savedRelayPreflightDidBegin(profile: profile)
        let service = actionService
        Task {
            let outcome = await service.preflight(profile)
            delegate.savedRelayPreflightDidReceive(
                profileID: profileID,
                outcome: outcome
            )
            delegate.savedRelayPreflightDidBecomeIdle(
                profileID: profileID
            )
        }
    }

    func delete(_ profile: CodexRelayProfile) {
        guard let delegate,
              delegate.allowsSavedRelayMutationStart else {
            return
        }
        guard !delegate.hasPendingRecovery else {
            delegate.savedRelayActionDidReject(
                delegate.savedRelayPendingRecoveryBlockMessage(
                    action: "删除中转"
                )
            )
            return
        }
        guard delegate.managedState.relayProfiles
                .contains(profile) else {
            delegate.savedRelayActionDidReject(
                V011RelayDeletionTransactionError
                    .profileChanged.localizedDescription
            )
            return
        }
        guard delegate.currentProviderID
                != profile.v011ProviderID else {
            delegate.savedRelayActionDidReject(
                V011RelayDeletionTransactionError
                    .activeRelay.localizedDescription
            )
            return
        }
        delegate.savedRelayDeleteDidBegin(profile: profile)
        let service = actionService
        Task {
            let outcome = await service.delete(profile)
            delegate.savedRelayDeleteDidReceive(
                profileID: profile.id,
                outcome: outcome
            )
            delegate.savedRelayMutationDidBecomeIdle()
            if case let .failure(_, shouldRefresh, _, _) = outcome,
               shouldRefresh {
                delegate.savedRelayActionRequestsRefresh()
            }
        }
    }

    func add(
        draft: CodexRelayProfile,
        apiKey: String
    ) {
        guard let delegate else { return }
        let key = apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !key.isEmpty else {
            delegate.savedRelayActionDidReject(
                V011AccessError.apiKeyRequired.localizedDescription
            )
            return
        }
        guard draft.wireProtocol == .responses else {
            delegate.savedRelayActionDidReject(
                V011AccessError.responsesRequired.localizedDescription
            )
            return
        }
        guard !delegate.hasPendingRecovery else {
            delegate.savedRelayActionDidReject(
                delegate.savedRelayPendingRecoveryBlockMessage(
                    action: "添加中转"
                )
            )
            return
        }
        guard delegate.allowsSavedRelayMutationStart else { return }
        delegate.savedRelayAddDidBegin()
        let service = actionService
        Task {
            let outcome = await service.add(
                draft: draft,
                apiKey: key
            )
            delegate.savedRelayAddDidReceive(outcome)
            delegate.savedRelayMutationDidBecomeIdle()
        }
    }
}
