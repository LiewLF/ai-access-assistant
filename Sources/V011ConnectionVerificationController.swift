import Foundation

@MainActor
protocol V011ConnectionVerificationControllerDelegate: AnyObject {
    var canCheckCurrentConnection: Bool { get }
    var canVerifyRealAgentLoop: Bool { get }
    var connectionVerificationLiveState: LiveCodexState? { get }

    func connectionVerificationCurrentContext()
        -> V011CurrentConnectionActionContext
    func connectionVerificationDidRejectCurrentCheck(
        _ message: String
    )
    func connectionVerificationCurrentCheckDidBegin()
    func connectionVerificationCurrentCheckDidReceive(
        _ outcome: V011CurrentConnectionActionOutcome
    )
    func connectionVerificationCurrentCheckDidBecomeIdle()
    func connectionVerificationDidRejectAgentLoop(
        _ message: String
    )
    func connectionVerificationAgentLoopDidBegin()
    func connectionVerificationAgentLoopDidVerify(
        _ result: V011AgentLoopVerificationResult
    )
    func connectionVerificationAgentLoopDidFail(
        _ message: String
    )
    func connectionVerificationAgentLoopDidBecomeIdle()
}

/// Owns authorization gates, task launch, and completion ordering for current
/// connection and real Agent Loop verification.
@MainActor
final class V011ConnectionVerificationController {
    private weak var delegate:
        (any V011ConnectionVerificationControllerDelegate)?
    private let currentConnectionService:
        V011CurrentConnectionActionService
    private var currentConnectionTask: Task<Void, Never>?
    private let agentLoopService: V011AgentLoopService

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011ConnectionVerificationControllerDelegate
    ) {
        currentConnectionService =
            V011CurrentConnectionActionService(
                dependencies: dependencies
            )
        agentLoopService = V011AgentLoopService(
            dependencies: dependencies
        )
        self.delegate = delegate
    }

    func detectCurrentConnection(userConsented: Bool) {
        guard let delegate else { return }
        guard userConsented else {
            delegate.connectionVerificationDidRejectCurrentCheck(
                "需要确认联网及可能产生的额度或费用"
            )
            return
        }
        guard currentConnectionTask == nil, delegate.canCheckCurrentConnection else { return }
        let startedNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        delegate.connectionVerificationCurrentCheckDidBegin()
        let service = currentConnectionService
        currentConnectionTask = Task {
            _ = await service.run(
                startedNanoseconds: startedNanoseconds,
                currentContext: {
                    delegate.connectionVerificationCurrentContext()
                },
                completed: { outcome in
                    currentConnectionTask = nil
                    delegate.connectionVerificationCurrentCheckDidReceive(outcome)
                    delegate.connectionVerificationCurrentCheckDidBecomeIdle()
                }
            )
        }
    }

    func cancelCurrentConnection() {
        currentConnectionTask?.cancel()
    }

    func verifyRealAgentLoop(userConsented: Bool) {
        guard let delegate else { return }
        guard userConsented else {
            delegate.connectionVerificationDidRejectAgentLoop(
                V011AgentLoopVerificationError
                    .authorizationRequired.localizedDescription
            )
            return
        }
        guard delegate.canVerifyRealAgentLoop,
              let live = delegate.connectionVerificationLiveState else {
            delegate.connectionVerificationDidRejectAgentLoop(
                "先完成基础连接检测；有未完成切换时先使用安全修复。"
            )
            return
        }
        delegate.connectionVerificationAgentLoopDidBegin()
        let service = agentLoopService
        Task {
            do {
                let result = try await service.verify(live: live)
                delegate.connectionVerificationAgentLoopDidVerify(
                    result
                )
            } catch {
                delegate.connectionVerificationAgentLoopDidFail(
                    V011RecoveryErrorText.safeDetail(error)
                )
            }
            delegate.connectionVerificationAgentLoopDidBecomeIdle()
        }
    }

    func agentLoopReceiptTargetsCurrentState(
        _ receipt: V011AgentLoopReceipt,
        live: LiveCodexState
    ) -> Bool {
        agentLoopService.receiptTargetsCurrentState(
            receipt,
            live: live
        )
    }
}
