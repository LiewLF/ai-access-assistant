import Foundation

@MainActor
protocol V011SwitchControllerDelegate: AnyObject {
    var allowsSwitchEntry: Bool { get }
    var allowsSwitchExecution: Bool { get }
    var switchControllerUsesRelayAccess: Bool { get }
    var hasTrustedOfficialRootOverlay: Bool { get }
    var hasPendingRecovery: Bool { get }
    var errorMessage: String? { get }
    var needsCurrentRelayAdoption: Bool { get }

    func switchControllerPendingRecoveryBlockMessage(
        action: String
    ) -> String
    func switchControllerDidReject(
        status: String?,
        errorMessage: String
    )
    func switchControllerDidProgress(_ message: String)
    func switchControllerDidBegin()
    func switchControllerDidReceive(
        _ outcome: V011SwitchActionOutcome
    )
    func switchControllerDidBecomeIdle()
    func switchControllerRequestsRefresh(completion: (() -> Void)?)
}

/// Owns switch entry guards, transaction task launch, progress, completion
/// ordering, and refresh branching. SwitchActionService retains transaction.
@MainActor
final class V011SwitchController {
    private let dependencies: V011AccessDependencies
    private weak var delegate:
        (any V011SwitchControllerDelegate)?

    private lazy var actionService = V011SwitchActionService(
        dependencies: dependencies,
        progress: { [weak self] message in
            Task { @MainActor in
                self?.delegate?.switchControllerDidProgress(message)
            }
        }
    )

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011SwitchControllerDelegate
    ) {
        self.dependencies = dependencies
        self.delegate = delegate
    }

    func switchToOfficial() {
        guard let delegate, delegate.allowsSwitchEntry else {
            return
        }
        guard !delegate.switchControllerUsesRelayAccess
                || delegate.hasTrustedOfficialRootOverlay else {
            delegate.switchControllerDidReject(
                status:
                    "本次切换未执行，官方设置尚未建立安全恢复信息",
                errorMessage: FableSwitchError
                    .officialRootOverlayUnavailable
                    .localizedDescription
            )
            return
        }
        perform(destination: .official, delegate: delegate)
    }

    func switchToRelay(_ profile: CodexRelayProfile) {
        guard let delegate, delegate.allowsSwitchEntry else {
            return
        }
        perform(
            destination: .relay(profile.fableProfile),
            delegate: delegate
        )
    }

    private func perform(
        destination: FableSwitchDestination,
        delegate: any V011SwitchControllerDelegate
    ) {
        guard delegate.allowsSwitchExecution else { return }
        guard !delegate.hasPendingRecovery else {
            delegate.switchControllerDidReject(
                status: nil,
                errorMessage: delegate
                    .switchControllerPendingRecoveryBlockMessage(
                        action: "切换模式"
                    )
            )
            return
        }
        guard !delegate.needsCurrentRelayAdoption else {
            delegate.switchControllerDidReject(
                status: nil,
                errorMessage: "请先接管当前中转并保持现状，再切换模式"
            )
            return
        }
        delegate.switchControllerDidBegin()
        let service = actionService
        Task {
            let outcome = await service.execute(
                destination: destination
            )
            delegate.switchControllerDidReceive(outcome)
            delegate.switchControllerDidBecomeIdle()
            switch outcome {
            case .completed:
                delegate.switchControllerRequestsRefresh(completion: nil)
            case let .failed(failure):
                if failure.shouldRefresh {
                    delegate.switchControllerRequestsRefresh { [weak delegate] in
                        guard let delegate, !delegate.hasPendingRecovery,
                              delegate.errorMessage == nil else { return }
                        // Refresh current data first; a successful read does not
                        // turn the failed cutover into a successful operation.
                        delegate.switchControllerDidReceive(.failed(failure))
                    }
                }
            }
        }
    }
}
