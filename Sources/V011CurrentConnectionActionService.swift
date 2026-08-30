import Foundation

struct V011CurrentConnectionActionContext: @unchecked Sendable {
    let managedState: V011ManagedState
    let hasPendingRecovery: Bool
    let recoveryDisposition: V011RecoveryDisposition
    let currentProviderID: String?
    let currentLiveState: LiveCodexState?
}

struct V011CurrentConnectionCapabilityUpdate: @unchecked Sendable {
    let receipts: [ProviderCapabilityProbeReceipt]?
    let errorMessage: String?
}

struct V011CurrentConnectionHistoryUpdate: @unchecked Sendable {
    let history: [V011ConnectionHealthObservation]?
    let errorMessage: String?
}

enum V011CurrentConnectionActionOutcome: @unchecked Sendable {
    case verified(
        check: V011CurrentConnectionCheckResult,
        status: String,
        capability: V011CurrentConnectionCapabilityUpdate,
        history: V011CurrentConnectionHistoryUpdate
    )
    case probeFailed(
        failure: V011CurrentConnectionProbeFailure,
        runtimeFreshness: V011RuntimeFreshness,
        status: String,
        history: V011CurrentConnectionHistoryUpdate
    )
    case failed(
        safeError: String,
        history: V011CurrentConnectionHistoryUpdate
    )
}

/// Owns current-connection action orchestration and durable evidence writes.
/// MainActor controller starts the action; its façade delegate applies typed
/// outcomes.
struct V011CurrentConnectionActionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func run(
        startedNanoseconds: UInt64,
        currentContext: @escaping @MainActor @Sendable
            () -> V011CurrentConnectionActionContext
    ) async -> V011CurrentConnectionActionOutcome {
        do {
            let check = try await verificationService.verify()
            let context = await currentContext()
            let result = check.verification
            let capability = persistCoreReceipts(
                for: result,
                managedState: context.managedState
            )
            let status = Self.status(
                check: check,
                managedState: context.managedState,
                hasPendingRecovery: context.hasPendingRecovery,
                recoveryDisposition: context.recoveryDisposition
            )
            let history = recordObservation(
                startedNanoseconds: startedNanoseconds,
                providerID: result.providerID,
                configHash: result.configHash,
                outcome: check.isVerified ? .passed : .degraded,
                failureCode: check.isVerified
                    ? nil
                    : (
                        check.sessionIsCurrent
                            ? .receiptMismatch
                            : .sessionProviderDrift
                    ),
                sessionProviderCheck: result.sessionProviderCheck,
                runtimeFreshness: check.runtimeFreshness
            )
            return .verified(
                check: check,
                status: status,
                capability: capability,
                history: history
            )
        } catch let failure as V011CurrentConnectionProbeFailure {
            let context = await currentContext()
            let freshness = V011ConnectionHealthService
                .runtimeFreshness(
                    live: failure.state,
                    runtimeObservation:
                        dependencies.codexRuntimeObservation()
                )
            let status = context.hasPendingRecovery
                ? "最小请求失败；已重新读取当前配置，且上次操作仍未完成"
                : "最小请求失败；已重新读取当前配置"
            return .probeFailed(
                failure: failure,
                runtimeFreshness: freshness,
                status: status,
                history: recordObservation(
                    startedNanoseconds: startedNanoseconds,
                    providerID: failure.providerID,
                    configHash: failure.configHash,
                    outcome: .failed,
                    failureCode: .probeFailed,
                    failureCategory: failure.failureCategory,
                    httpStatus: failure.httpStatus,
                    sessionProviderCheck:
                        failure.sessionProviderCheck,
                    runtimeFreshness: freshness
                )
            )
        } catch {
            let context = await currentContext()
            return .failed(
                safeError: V011RecoveryErrorText.safeDetail(error),
                history: recordObservation(
                    startedNanoseconds: startedNanoseconds,
                    providerID: context.currentProviderID
                        ?? (context.currentLiveState == nil
                            ? nil : "openai"),
                    configHash: context.currentLiveState?.configHash,
                    outcome: .failed,
                    failureCode: V011ConnectionHealthService
                        .failureCode(for: error),
                    sessionProviderCheck: nil,
                    runtimeFreshness: .unknown
                )
            )
        }
    }

    private static func status(
        check: V011CurrentConnectionCheckResult,
        managedState: V011ManagedState,
        hasPendingRecovery: Bool,
        recoveryDisposition: V011RecoveryDisposition
    ) -> String {
        if check.isVerified {
            return V011AccessRefreshService.statusText(
                live: check.verification.state,
                managed: managedState,
                pending: hasPendingRecovery,
                recoveryDisposition: recoveryDisposition,
                verified: true,
                receiptMatches: true,
                runtimeFreshness: check.runtimeFreshness
            )
        }
        if check.runtimeFreshness == .stale {
            return hasPendingRecovery
                ? "连接已通过；当前任务保持旧设置，且上次操作仍未完成"
                : "连接已通过；当前已打开任务可能保持旧设置"
        }
        if !check.sessionIsCurrent {
            return hasPendingRecovery
                ? "最小请求已通过；任务路由未确认，且上次操作仍未完成"
                : "最小请求已通过；任务路由尚未确认"
        }
        if check.runtimeFreshness == .unknown {
            return hasPendingRecovery
                ? "最小请求已通过；运行态未确认，且上次操作仍未完成"
                : "最小请求已通过；运行态尚未确认"
        }
        return hasPendingRecovery
            ? "最小请求地址与配置不一致，且上次操作仍未完成"
            : "最小请求地址与配置不一致，请重新检测"
    }

    private func persistCoreReceipts(
        for result: V011CurrentConnectionVerification,
        managedState: V011ManagedState
    ) -> V011CurrentConnectionCapabilityUpdate {
        do {
            return V011CurrentConnectionCapabilityUpdate(
                receipts: try capabilityEvidenceService
                    .persistCoreReceipts(
                        for: result,
                        managedState: managedState
                    ),
                errorMessage: nil
            )
        } catch {
            return V011CurrentConnectionCapabilityUpdate(
                receipts: nil,
                errorMessage:
                    "连接已通过，但扩展能力回执未保存："
                        + error.localizedDescription
            )
        }
    }

    private func recordObservation(
        startedNanoseconds: UInt64,
        providerID: String?,
        configHash: String?,
        outcome: V011ConnectionHealthOutcome,
        failureCode: V011ConnectionHealthFailureCode?,
        failureCategory:
            V011ConnectionHealthFailureCategory? = nil,
        httpStatus: Int? = nil,
        sessionProviderCheck: V011SessionProviderCheck?,
        runtimeFreshness: V011RuntimeFreshness
    ) -> V011CurrentConnectionHistoryUpdate {
        do {
            return V011CurrentConnectionHistoryUpdate(
                history: try connectionHealthService
                    .appendObservation(
                        startedNanoseconds: startedNanoseconds,
                        providerID: providerID,
                        configHash: configHash,
                        outcome: outcome,
                        failureCode: failureCode,
                        failureCategory: failureCategory,
                        httpStatus: httpStatus,
                        sessionProviderCheck: sessionProviderCheck,
                        runtimeFreshness: runtimeFreshness
                    ),
                errorMessage: nil
            )
        } catch {
            return V011CurrentConnectionHistoryUpdate(
                history: nil,
                errorMessage:
                    "连接检测历史无法保存；本次检测结果仍有效"
            )
        }
    }

    private var verificationService: V011CurrentConnectionService {
        V011CurrentConnectionService(
            dependencies: dependencies,
            coordinatorFactory: V011SwitchCoordinatorFactory(
                dependencies: dependencies
            ),
            connectionHealthService: connectionHealthService
        )
    }

    private var connectionHealthService: V011ConnectionHealthService {
        V011ConnectionHealthService(
            controlRoot: dependencies.controlRoot,
            now: dependencies.now
        )
    }

    private var capabilityEvidenceService:
        V011ProviderCapabilityEvidenceService {
        V011ProviderCapabilityEvidenceService(
            controlRoot: dependencies.controlRoot,
            keyProvider: dependencies.keyProvider
        )
    }
}
