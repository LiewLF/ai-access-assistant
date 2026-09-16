import Foundation

struct V011ConnectionFailureScope: Sendable {
    let hasFailure: Bool
    let configHash: String?
    let providerID: String?
}

struct V011AccessRefreshPresentation: Sendable {
    let agentLoopErrorMessage: String?
    let shouldClearConnectionFailure: Bool
    let isCurrentConnectionVerified: Bool
    let verifiedEndpointHost: String?
    let currentSessionProviderCheck: V011SessionProviderCheck?
    let status: String
    let errorMessage: String?
}

struct V011AccessRefreshLoaded: @unchecked Sendable {
    let state: V011AccessStateSnapshot
    let recovery: V011PendingRecoveryContext
    let presentation: V011AccessRefreshPresentation
}

struct V011AccessRefreshFailed: @unchecked Sendable {
    let recovery: V011PendingRecoveryContext?
    let status: String
    let errorMessage: String
}

enum V011AccessRefreshOutcome: @unchecked Sendable {
    case loaded(V011AccessRefreshLoaded)
    case failed(V011AccessRefreshFailed)
}

/// Owns refresh I/O sequencing, cancellation boundaries, and pure status
/// projection while MainActor retains Published-state assignment.
struct V011AccessRefreshService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let recoveryProgress:
        @MainActor @Sendable (V011PendingRecoveryContext) -> Void

    init(
        dependencies: V011AccessDependencies,
        recoveryProgress: @escaping @MainActor @Sendable
            (V011PendingRecoveryContext) -> Void = { _ in }
    ) {
        self.dependencies = dependencies
        self.recoveryProgress = recoveryProgress
    }

    func load(
        connectionFailureScope: V011ConnectionFailureScope
    ) async throws -> V011AccessRefreshOutcome {
        var recovery: V011PendingRecoveryContext?
        do {
            let currentRecovery = try await Task.detached(
                priority: .userInitiated
            ) {
                try V011AccessStateReader.pendingRecoveryContext(
                    dependencies: dependencies
                )
            }.value
            try Task.checkCancellation()
            recovery = currentRecovery
            await recoveryProgress(currentRecovery)
            try Task.checkCancellation()
            let state = try await Task.detached(
                priority: .userInitiated
            ) {
                try V011AccessStateReader.readState(
                    dependencies: dependencies,
                    pending: currentRecovery.pending
                )
            }.value
            try Task.checkCancellation()
            return .loaded(
                V011AccessRefreshLoaded(
                    state: state,
                    recovery: currentRecovery,
                    presentation: Self.presentation(
                        state: state,
                        recovery: currentRecovery,
                        connectionFailureScope:
                            connectionFailureScope
                    )
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(
                Self.failure(
                    recovery: recovery,
                    error: error
                )
            )
        }
    }

    private static func presentation(
        state: V011AccessStateSnapshot,
        recovery: V011PendingRecoveryContext,
        connectionFailureScope: V011ConnectionFailureScope
    ) -> V011AccessRefreshPresentation {
        let agentLoopErrorMessage: String?
        if state.agentLoopMatches {
            agentLoopErrorMessage = nil
        } else if let receipt = state.agentLoopReceipt,
                  receipt.targets(state.live),
                  let stage = receipt.failureStage {
            let failure = V013FailurePresentation.agentLoop(stage, reason: receipt.failureReason)
            agentLoopErrorMessage =
                "\(failure.conclusion)。\(failure.explanation)"
        } else {
            agentLoopErrorMessage = nil
        }
        let failureIsUnscoped = connectionFailureScope.hasFailure
            && connectionFailureScope.configHash == nil
        let failureMatchesCurrentConfiguration =
            connectionFailureScope.configHash == state.live.configHash
            && connectionFailureScope.providerID
                == V011ConnectionHealthService.providerID(state.live)
        let failedCurrentConfiguration = failureIsUnscoped
            || failureMatchesCurrentConfiguration
        let endpointHost: String?
        let sessionProviderCheck: V011SessionProviderCheck?
        if state.receiptMatches {
            endpointHost = V011ConnectionHealthService
                .normalizedEndpointHost(
                    state.connectionReceipt?.endpointHost
                )
            sessionProviderCheck = state.connectionReceipt?
                .sessionProviderCheck
        } else {
            endpointHost = nil
            sessionProviderCheck = nil
        }
        return V011AccessRefreshPresentation(
            agentLoopErrorMessage: agentLoopErrorMessage,
            shouldClearConnectionFailure:
                connectionFailureScope.hasFailure
                    && !failedCurrentConfiguration,
            isCurrentConnectionVerified:
                state.verified && !failedCurrentConfiguration,
            verifiedEndpointHost: endpointHost,
            currentSessionProviderCheck: sessionProviderCheck,
            status: statusText(
                live: state.live,
                managed: state.managed,
                pending: state.pending,
                recoveryDisposition: recovery.disposition,
                verified: state.verified
                    && !failedCurrentConfiguration,
                receiptMatches: state.receiptMatches,
                runtimeFreshness: state.runtimeFreshness
            ),
            errorMessage: state.pending ? recovery.detail : nil
        )
    }

    private static func failure(
        recovery: V011PendingRecoveryContext?,
        error: Error
    ) -> V011AccessRefreshFailed {
        guard let recovery, recovery.pending else {
            return V011AccessRefreshFailed(
                recovery: recovery,
                status: "暂时无法读取Codex状态",
                errorMessage: error.localizedDescription
            )
        }
        let status = recovery.disposition == .decisionRequired
            ? "上次切换没有完成，当前设置已保留"
            : "已找到未完成的操作，可继续最小修复"
        return V011AccessRefreshFailed(
            recovery: recovery,
            status: status,
            errorMessage: [
                recovery.detail,
                "其他状态暂时无法读取：\(V011RecoveryErrorText.safeDetail(error))",
            ]
            .compactMap { $0 }
            .joined(separator: "；")
        )
    }

    static func statusText(
        live: LiveCodexState,
        managed: V011ManagedState,
        pending: Bool,
        recoveryDisposition: V011RecoveryDisposition,
        verified: Bool,
        receiptMatches: Bool,
        runtimeFreshness: V011RuntimeFreshness
    ) -> String {
        if pending, recoveryDisposition == .decisionRequired {
            return verified
                ? "当前连接检测已通过；上次切换没有完成，当前设置已保留"
                : "上次切换没有完成，当前设置已保留"
        }
        if receiptMatches, runtimeFreshness == .stale {
            return pending
                ? "连接已通过；当前任务保持旧设置，且上次操作仍未完成"
                : "连接已通过；当前已打开任务可能保持旧设置"
        }
        if receiptMatches,
           runtimeFreshness == .unknown,
           verified {
            return pending
                ? "连接已通过；当前任务生效状态未确认，且上次操作仍未完成"
                : "连接已通过；当前任务生效状态未确认"
        }
        if pending {
            return verified
                ? "当前连接检测已通过；上次操作仍未完成"
                : "上次操作未完成，可继续最小修复"
        }
        guard live.versionSupport.allowsWrites else {
            return "当前Codex版本尚未通过兼容验证，只允许查看"
        }
        switch live.mode {
        case .official:
            return verified
                ? "Codex官方最近一次连接检测已通过"
                : "已识别为Codex官方，尚未完成连接检测"
        case let .relay(providerID):
            if let profile = managed.relayProfiles.first(where: {
                $0.v011ProviderID == providerID
            }) {
                return verified
                    ? "\(profile.name)最近一次连接检测已通过"
                    : "已识别为\(profile.name)，尚未完成连接检测"
            }
            return "检测到一个现有中转，可接管并保持现状"
        }
    }
}
