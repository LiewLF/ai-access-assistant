import Foundation

struct V011RecoveryActionFailure: Sendable {
    let status: String
    let errorMessage: String
}

enum V011OfficialRecoveryActionOutcome: @unchecked Sendable {
    case success(result: V011OfficialRecoveryResult, status: String)
    case failure(V011RecoveryActionFailure)
}

enum V011PendingRecoveryActionOutcome: Sendable {
    case success(count: Int, status: String)
    case failure(V011RecoveryActionFailure)
}

enum V011DeterministicRepairActionOutcome: @unchecked Sendable {
    case completed(
        count: Int,
        verification: V011AgentLoopProbeResult,
        state: V011AccessStateSnapshot,
        status: String
    )
    case previewChanged(
        context: V011PendingRecoveryContext,
        status: String,
        errorMessage: String
    )
    case failed(
        verification: V011AgentLoopProbeResult?,
        state: V011AccessStateSnapshot?,
        verificationScope: V011AgentLoopFailureState.Scope?,
        status: String,
        errorMessage: String
    )
}

enum V011KeepCurrentRecoveryActionOutcome: Sendable {
    case success(count: Int, status: String)
    case failure(V011RecoveryActionFailure)
}

enum V011AcceptCurrentRelayRecoveryActionOutcome: @unchecked Sendable {
    case success(state: V011ManagedState, status: String)
    case failure(V011RecoveryActionFailure)
}

/// Maps official and pending recovery transactions into deterministic action
/// outcomes. Transaction ordering remains owned by the underlying services;
/// MainActor controller owns lifetime and refresh branching; its façade
/// delegate applies returned state.
struct V011RecoveryActionService: @unchecked Sendable {
    private let officialService: V011OfficialRecoveryService
    private let pendingService: V011PendingRecoveryService

    init(
        dependencies: V011AccessDependencies,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        officialService = V011OfficialRecoveryService(
            dependencies: dependencies
        )
        pendingService = V011PendingRecoveryService(
            dependencies: dependencies,
            progress: progress
        )
    }

    func establishOfficial()
        async -> V011OfficialRecoveryActionOutcome {
        let service = officialService
        let task = Task.detached(
            priority: .userInitiated
        ) { () -> V011OfficialRecoveryActionOutcome in
            do {
                return .success(
                    result: try service.establish(),
                    status:
                        "官方恢复信息已建立；现在可安全切换到中转并返回官方"
                )
            } catch {
                return .failure(
                    V011RecoveryActionFailure(
                        status:
                            "官方恢复信息未建立，Codex当前设置未改变",
                        errorMessage:
                            V011RecoveryErrorText.safeDetail(error)
                    )
                )
            }
        }
        return await task.value
    }

    func recoverPending()
        async -> V011PendingRecoveryActionOutcome {
        let service = pendingService
        let task = Task.detached(
            priority: .userInitiated
        ) { () -> V011PendingRecoveryActionOutcome in
            do {
                let count = try await service.recoverPending()
                return .success(
                    count: count,
                    status: "已恢复\(count)项未完成操作"
                )
            } catch {
                return .failure(
                    V011RecoveryActionFailure(
                        status: "恢复尚未完成",
                        errorMessage:
                            V011RecoveryErrorText.safeDetail(error)
                    )
                )
            }
        }
        return await task.value
    }

    func runDeterministicRepair(
        expectedPreviewFingerprint: String
    ) async -> V011DeterministicRepairActionOutcome {
        let service = pendingService
        let outcome = await Task.detached(
            priority: .userInitiated
        ) {
            await service.runDeterministicRepair(
                expectedPreviewFingerprint:
                    expectedPreviewFingerprint
            )
        }.value
        switch outcome {
        case let .completed(count, verification, state):
            return .completed(
                count: count,
                verification: verification,
                state: state,
                status:
                    "已修复\(count)项未完成操作；真实任务闭环已通过"
            )
        case let .previewChanged(context):
            return .previewChanged(
                context: context,
                status: "修复预览已变化；本次未执行",
                errorMessage: V014RecoveryRepairError
                    .previewChanged.localizedDescription
            )
        case let .failed(verification, state, verificationScope, safeError):
            return .failed(
                verification: verification,
                state: state,
                verificationScope: verificationScope,
                status:
                    "安全修复未完成验证；请查看失败原因",
                errorMessage:
                    verification?.safeMessage ?? safeError
            )
        }
    }

    func keepCurrentConfiguration()
        async -> V011KeepCurrentRecoveryActionOutcome {
        let service = pendingService
        let task = Task.detached(
            priority: .userInitiated
        ) { () -> V011KeepCurrentRecoveryActionOutcome in
            do {
                let count = try await service
                    .keepCurrentConfigurationAndEndPendingRecovery()
                return .success(
                    count: count,
                    status:
                        "已保留当前状态并结束\(count)项旧事务"
                )
            } catch {
                return .failure(
                    V011RecoveryActionFailure(
                        status:
                            "未能结束旧事务，当前状态保持不变",
                        errorMessage:
                            V011RecoveryErrorText.safeDetail(error)
                    )
                )
            }
        }
        return await task.value
    }

    func acceptCurrentRelay()
        async -> V011AcceptCurrentRelayRecoveryActionOutcome {
        let service = pendingService
        let task = Task.detached(
            priority: .userInitiated
        ) { () -> V011AcceptCurrentRelayRecoveryActionOutcome in
            do {
                return .success(
                    state: try await service
                        .acceptCurrentRelayForPendingRecovery(),
                    status:
                        "当前轨已验证；现在可以修改配置或重新切换"
                )
            } catch {
                return .failure(
                    V011RecoveryActionFailure(
                        status:
                            "当前轨验证未完成；配置和旧事务保持原状",
                        errorMessage:
                            V011RecoveryErrorText.safeDetail(error)
                    )
                )
            }
        }
        return await task.value
    }
}
