import Foundation

struct V011RecoveryActionStart: Sendable {
    let status: String
    let protectsNewSessions: Bool
    let resetsAgentLoop: Bool
}

@MainActor
protocol V011RecoveryControllerDelegate: AnyObject {
    var allowsRecoveryActionStart: Bool { get }
    var hasPendingRecovery: Bool { get }
    var errorMessage: String? { get }
    var recoveryDisposition: V011RecoveryDisposition { get }
    var recoveryControllerUsesOfficialAccess: Bool { get }
    var canRunDeterministicRepair: Bool { get }
    var deterministicRepairPreviewSummary: String { get }
    var canKeepCurrentConfigurationAndEndPendingSwitch: Bool { get }
    var configurationOnlyRecoveryActionTitle: String { get }
    var canAcceptCurrentRelayAndEndPendingSwitch: Bool { get }

    func recoveryActionDidReject(
        status: String?,
        errorMessage: String
    )
    func recoveryActionDidFinishFailedRepair(
        status: String, errorMessage: String, scope: V011AgentLoopFailureState.Scope?
    )
    func recoveryActionDidProgress(_ message: String)
    func recoveryActionDidBegin(_ start: V011RecoveryActionStart)
    func recoveryActionDidReceiveOfficial(
        _ outcome: V011OfficialRecoveryActionOutcome
    )
    func recoveryActionDidReceivePending(
        _ outcome: V011PendingRecoveryActionOutcome
    )
    func recoveryActionDidReceiveDeterministicRepair(
        _ outcome: V011DeterministicRepairActionOutcome
    )
    func recoveryActionDidReceiveKeepCurrent(
        _ outcome: V011KeepCurrentRecoveryActionOutcome
    )
    func recoveryActionDidReceiveAcceptCurrentRelay(
        _ outcome: V011AcceptCurrentRelayRecoveryActionOutcome
    )
    func recoveryActionDidBecomeIdle()
    func recoveryActionRequestsRefresh(completion: (() -> Void)?)
}

/// Owns recovery eligibility, task launch, progress, completion ordering, and
/// refresh branching. Recovery services retain transaction semantics.
@MainActor
final class V011RecoveryController {
    private let dependencies: V011AccessDependencies
    private weak var delegate:
        (any V011RecoveryControllerDelegate)?

    private lazy var actionService = V011RecoveryActionService(
        dependencies: dependencies,
        progress: { [weak self] message in
            Task { @MainActor in
                self?.delegate?.recoveryActionDidProgress(message)
            }
        }
    )

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011RecoveryControllerDelegate
    ) {
        self.dependencies = dependencies
        self.delegate = delegate
    }

    func establishOfficialRecoveryInfo() {
        guard let delegate,
              delegate.allowsRecoveryActionStart else {
            return
        }
        guard !delegate.hasPendingRecovery else {
            reject(
                V011SwitchError.pendingRecovery.localizedDescription,
                delegate: delegate
            )
            return
        }
        guard delegate.recoveryControllerUsesOfficialAccess else {
            reject(
                FableSwitchError.officialRootOverlayUnavailable
                    .localizedDescription,
                status: "本次建立未执行；当前实时配置不是Codex官方",
                delegate: delegate
            )
            return
        }
        begin(
            "正在验证Codex官方并建立安全恢复信息",
            delegate: delegate
        )
        let service = actionService
        Task {
            let outcome = await service.establishOfficial()
            delegate.recoveryActionDidReceiveOfficial(outcome)
            delegate.recoveryActionDidBecomeIdle()
        }
    }

    func recoverPendingSwitch() {
        guard let delegate,
              delegate.allowsRecoveryActionStart else {
            return
        }
        guard delegate.recoveryDisposition == .recoverable else {
            if delegate.recoveryDisposition == .decisionRequired {
                reject(
                    V011SwitchError.recoveryDecisionRequired
                        .localizedDescription,
                    status: "上次切换没有完成，当前设置已保留",
                    delegate: delegate
                )
            }
            return
        }
        begin(
            "正在先核对能否前向完成；必要时只恢复本次受影响内容",
            protectsNewSessions: true,
            delegate: delegate
        )
        let service = actionService
        Task {
            let outcome = await service.recoverPending()
            delegate.recoveryActionDidReceivePending(outcome)
            delegate.recoveryActionDidBecomeIdle()
            delegate.recoveryActionRequestsRefresh(completion: nil)
        }
    }

    func runDeterministicRepair(
        userConsented: Bool,
        expectedPreviewFingerprint: String
    ) {
        guard let delegate else { return }
        guard userConsented else {
            reject(
                V011AgentLoopVerificationError
                    .authorizationRequired.localizedDescription,
                delegate: delegate
            )
            return
        }
        guard delegate.canRunDeterministicRepair else {
            reject(
                delegate.deterministicRepairPreviewSummary,
                delegate: delegate
            )
            return
        }
        begin(
            "正在使用恢复点修复，并在提交前验证真实任务",
            protectsNewSessions: true,
            resetsAgentLoop: true,
            delegate: delegate
        )
        let service = actionService
        Task {
            let outcome = await service.runDeterministicRepair(
                expectedPreviewFingerprint:
                    expectedPreviewFingerprint
            )
            delegate
                .recoveryActionDidReceiveDeterministicRepair(outcome)
            delegate.recoveryActionDidBecomeIdle()
            switch outcome {
            case .previewChanged:
                return
            case .completed:
                delegate.recoveryActionRequestsRefresh(completion: nil)
            case let .failed(_, _, verificationScope, status, errorMessage):
                delegate.recoveryActionRequestsRefresh { [weak delegate] in
                    guard let delegate, !delegate.hasPendingRecovery,
                          delegate.errorMessage == nil else { return }
                    // Keep freshly read state; a successful read cannot erase
                    // the failure of this repair attempt.
                    delegate.recoveryActionDidFinishFailedRepair(
                        status: status, errorMessage: errorMessage, scope: verificationScope
                    )
                }
            }
        }
    }

    func keepCurrentConfigurationAndEndPendingSwitch() {
        guard let delegate,
              delegate.allowsRecoveryActionStart,
              delegate.canKeepCurrentConfigurationAndEndPendingSwitch else {
            return
        }
        begin(
            delegate.configurationOnlyRecoveryActionTitle,
            delegate: delegate
        )
        let service = actionService
        Task {
            let outcome = await service.keepCurrentConfiguration()
            delegate.recoveryActionDidReceiveKeepCurrent(outcome)
            delegate.recoveryActionDidBecomeIdle()
            if case .success = outcome {
                delegate.recoveryActionRequestsRefresh(completion: nil)
            }
        }
    }

    func acceptCurrentRelayAndEndPendingSwitch() {
        guard let delegate else { return }
        guard delegate.canAcceptCurrentRelayAndEndPendingSwitch else {
            if delegate.recoveryDisposition == .decisionRequired {
                reject(
                    "当前配置必须匹配一个已保存中转；否则请只处理设置、不处理历史会话，再重新接管",
                    status: "当前轨尚不能安全接管",
                    delegate: delegate
                )
            }
            return
        }
        begin(
            "正在验证当前轨、历史会话和旧事务状态",
            delegate: delegate
        )
        let service = actionService
        Task {
            let outcome = await service.acceptCurrentRelay()
            delegate
                .recoveryActionDidReceiveAcceptCurrentRelay(outcome)
            delegate.recoveryActionDidBecomeIdle()
            delegate.recoveryActionRequestsRefresh(completion: nil)
        }
    }

    private func begin(
        _ status: String,
        protectsNewSessions: Bool = false,
        resetsAgentLoop: Bool = false,
        delegate: any V011RecoveryControllerDelegate
    ) {
        delegate.recoveryActionDidBegin(
            V011RecoveryActionStart(
                status: status,
                protectsNewSessions: protectsNewSessions,
                resetsAgentLoop: resetsAgentLoop
            )
        )
    }

    private func reject(
        _ errorMessage: String,
        status: String? = nil,
        delegate: any V011RecoveryControllerDelegate
    ) {
        delegate.recoveryActionDidReject(
            status: status,
            errorMessage: errorMessage
        )
    }
}
