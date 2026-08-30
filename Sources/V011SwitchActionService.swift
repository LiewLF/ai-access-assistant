import Foundation

struct V011SwitchResultPresentation: Sendable {
    let configurationOutcome: String
    let sessionOutcome: String
    let status: String

    init(result: V011SwitchResult) {
        configurationOutcome = result.configurationCommitted
            ? "配置已提交"
            : "配置提交状态待确认"
        switch result.sessionPhase {
        case .committed, .succeeded:
            sessionOutcome = "历史会话已整理"
            status = "设置已切换，历史会话已整理"
        case .retryableFailure:
            let capacityExceeded = result.sessionReceipt?.failureCode
                == .journalCapacityExceeded
            sessionOutcome = capacityExceeded
                ? "历史会话容量不足，可重试"
                : "历史会话未整理，可重试"
            status = capacityExceeded
                ? "设置已切换；历史会话容量不足，可稍后重试"
                : "设置已切换；历史会话未整理，可稍后重试"
        case .notStarted, .cancelled:
            sessionOutcome = "历史会话整理已延期"
            status = "设置已切换；历史会话整理已延期"
        case .skipped:
            sessionOutcome = "历史会话未整理"
            status = "设置已切换；历史会话未整理"
        case .reserved, .prepared, .running:
            sessionOutcome = "历史会话状态待确认"
            status = "设置已切换；历史会话状态待确认"
        case .terminalFailure:
            sessionOutcome = "历史会话整理失败，可查看诊断"
            status = "设置已切换；历史会话整理失败，请打开修复工具"
        case .superseded:
            sessionOutcome = "历史会话已由新事务替代"
            status = "设置已切换；历史会话已由新事务替代"
        }
    }
}

enum V011SwitchActionOutcome: @unchecked Sendable {
    case completed(
        switchResult: V011SwitchResult,
        managedState: V011ManagedState,
        presentation: V011SwitchResultPresentation
    )
    case failed(V011SwitchFailurePresentation)
}

struct V011SwitchFailurePresentation: Sendable {
    let status: String
    let configurationOutcome: String
    let sessionOutcome: String
    let errorMessage: String
    let shouldRefresh: Bool
}

/// Executes one normal switch and keeps coordinator creation, transaction
/// execution, managed-state reload, and failure classification together.
struct V011SwitchActionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let progress: @Sendable (String) -> Void

    init(
        dependencies: V011AccessDependencies,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dependencies = dependencies
        self.progress = progress
    }

    func execute(
        destination: FableSwitchDestination
    ) async -> V011SwitchActionOutcome {
        let service = self
        return await Task.detached(priority: .userInitiated) {
            await service.executeTransaction(
                destination: destination
            )
        }.value
    }

    private func executeTransaction(
        destination: FableSwitchDestination
    ) async -> V011SwitchActionOutcome {
        let coordinator: V011UnifiedSwitchCoordinator
        do {
            coordinator = try coordinatorFactory.make()
        } catch let failure as V011RelayPreflightFailure {
            return .failed(
                preflightFailure(failure.localizedDescription)
            )
        } catch {
            return .failed(
                executionFailure(error, shouldRefresh: false)
            )
        }
        do {
            let result = try await coordinator.execute(
                destination: destination
            )
            return .completed(
                switchResult: result,
                managedState: try stateStore.load(),
                presentation: V011SwitchResultPresentation(
                    result: result
                )
            )
        } catch let failure as V011RelayPreflightFailure {
            return .failed(
                preflightFailure(failure.localizedDescription)
            )
        } catch {
            return .failed(
                executionFailure(error, shouldRefresh: true)
            )
        }
    }

    private func preflightFailure(
        _ message: String
    ) -> V011SwitchFailurePresentation {
        V011SwitchFailurePresentation(
            status: "写入前验证未通过；Codex设置未改变",
            configurationOutcome: "配置未提交",
            sessionOutcome: "未启动历史会话整理",
            errorMessage: message,
            shouldRefresh: false
        )
    }

    private func executionFailure(
        _ error: Error,
        shouldRefresh: Bool
    ) -> V011SwitchFailurePresentation {
        V011SwitchFailurePresentation(
            status: "切换未完成；请按当前状态提示处理",
            configurationOutcome: "配置提交状态待确认",
            sessionOutcome: "历史会话状态待确认",
            errorMessage: V011RecoveryErrorText.safeDetail(error),
            shouldRefresh: shouldRefresh
        )
    }

    private var coordinatorFactory: V011SwitchCoordinatorFactory {
        V011SwitchCoordinatorFactory(
            dependencies: dependencies,
            progress: progress
        )
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }
}
