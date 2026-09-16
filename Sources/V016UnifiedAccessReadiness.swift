// SPDX-License-Identifier: AGPL-3.0-only

enum V016AccessReadinessState:
    String, Codable, Equatable, Sendable {
    case ready
    case checking
    case needsAction
    case blocked
}

enum V016AccessReadinessCode:
    String, Codable, Equatable, Sendable {
    case codexNotInstalled = "codex_not_installed"
    case recoveryPending = "recovery_pending"
    case configurationBlocked = "configuration_blocked"
    case readingCurrentState = "reading_current_state"
    case checkingBasicConnection = "checking_basic_connection"
    case checkingRealTask = "checking_real_task"
    case realTaskReady = "real_task_ready"
    case compatibilityFailed = "compatibility_failed"
    case basicConnectionFailed = "basic_connection_failed"
    case realTaskFailed = "real_task_failed"
    case doctorActionRequired = "doctor_action_required"
    case routeUnknown = "route_unknown"
    case runtimeChanged = "runtime_changed"
    case currentStateReadRequired = "current_state_read_required"
    case realTaskRequired = "real_task_required"
    case basicConnectionRequired = "basic_connection_required"
}

enum V016AccessReadinessEvidenceSource:
    String, Codable, Equatable, Sendable {
    case none
    case installation
    case recovery
    case configuration
    case doctor
    case basicConnection
    case realTask

    var title: String {
        switch self {
        case .none: return "尚无验证证据"
        case .installation: return "安装状态"
        case .recovery: return "恢复状态"
        case .configuration: return "配置状态"
        case .doctor: return "Codex官方诊断"
        case .basicConnection: return "基础连接证据"
        case .realTask: return "真实任务证据"
        }
    }
}

enum V016AccessReadinessPrimaryAction: Equatable, Sendable {
    case installCodex
    case previewRecovery
    case keepCurrentConfiguration
    case openDiagnostics
    case resolveFailure(V013FailurePrimaryAction)
    case performDoctorAction(CodexDoctorPrimaryAction)
    case refreshState
    case checkBasicConnection
    case verifyRealTask
    case openCodex

    var title: String {
        switch self {
        case .installCodex: return "安装 Codex"
        case .previewRecovery: return "查看恢复预览"
        case .keepCurrentConfiguration: return "保留当前设置并结束上次操作"
        case .openDiagnostics: return "查看诊断"
        case let .resolveFailure(action): return action.title
        case let .performDoctorAction(action): return action.title
        case .refreshState: return "读取当前接入"
        case .checkBasicConnection: return "确认基础连接"
        case .verifyRealTask: return "验证真实任务"
        case .openCodex: return "打开 Codex 开始工作"
        }
    }
}

struct V016AccessReadinessInput: Equatable, Sendable {
    let codexInstalled: Bool
    let isReadingCurrentState: Bool
    let hasPendingRecovery: Bool
    let canPreviewRecovery: Bool
    let hasConfigurationError: Bool
    let runtimeChangeInvalidatedRealTaskEvidence: Bool
    let journey: V015UserJourneyDecision
    let activeFailure: V013FailurePresentation?
    let doctorGuidance: CodexDoctorActionableGuidance?
    var needsCurrentStateRead: Bool = false
    var needsRecoveryStateRead: Bool = false
    var canKeepCurrentConfiguration: Bool = false
    var isRecoveryActionRunning: Bool = false
}

struct V016AccessReadinessDecision: Equatable, Sendable {
    let route: V015UserJourneyRoute
    let code: V016AccessReadinessCode
    let state: V016AccessReadinessState
    let conclusion: String
    let explanation: String
    let primaryAction: V016AccessReadinessPrimaryAction?
    let evidenceSource: V016AccessReadinessEvidenceSource
    let evidence: [String]
}

enum V016AccessReadinessResolver {
    static func resolve(
        _ input: V016AccessReadinessInput
    ) -> V016AccessReadinessDecision {
        guard input.codexInstalled else {
            return decision(
                input,
                code: .codexNotInstalled,
                state: .blocked,
                conclusion: "还不能开始工作",
                explanation: "先完成 Codex 官方安装和登录。",
                action: .installCodex,
                source: .installation
            )
        }
        if input.hasPendingRecovery {
            let busy = input.isReadingCurrentState || input.isRecoveryActionRunning
            let action: V016AccessReadinessPrimaryAction = input.needsRecoveryStateRead
                ? .refreshState : input.canKeepCurrentConfiguration
                    ? .keepCurrentConfiguration : input.canPreviewRecovery
                        ? .previewRecovery : .openDiagnostics
            let explanation = input.needsRecoveryStateRead
                ? "已找到未完成记录；先离线读取恢复状态，再选择适用的处理方式。"
                : input.canKeepCurrentConfiguration
                    ? "可保留当前设置和聊天内容，仅归档上次未完成的操作记录。"
                    : "当前设置和历史保持保护；先处理已有恢复点。"
            return decision(
                input,
                code: .recoveryPending,
                state: busy ? .checking : .blocked,
                conclusion: busy ? "正在核对和处理恢复状态" : "上次操作尚未安全结束",
                explanation: explanation,
                action: busy ? nil : action,
                source: .recovery
            )
        }
        if input.hasConfigurationError {
            return decision(
                input,
                code: .configurationBlocked,
                state: .blocked,
                conclusion: "当前设置需要处理",
                explanation:
                    "助手没有采用不完整配置；先查看诊断再继续。",
                action: .openDiagnostics,
                source: .configuration
            )
        }
        if input.isReadingCurrentState {
            return decision(
                input,
                code: .readingCurrentState,
                state: .checking,
                conclusion: "正在读取当前接入",
                explanation: V015PassiveStateReadBoundary.detail,
                action: nil,
                source: .none
            )
        }
        switch input.journey.verificationStage {
        case .checkingBasic:
            return decision(
                input,
                code: .checkingBasicConnection,
                state: .checking,
                conclusion: "正在确认基础连接",
                explanation:
                    "当前接入保持不变；等待本次最小请求结果。",
                action: nil,
                source: .basicConnection
            )
        case .verifyingRealTask:
            return decision(
                input,
                code: .checkingRealTask,
                state: .checking,
                conclusion: "正在验证真实任务",
                explanation:
                    "隔离任务不会读取真实项目或历史会话。",
                action: nil,
                source: .realTask
            )
        case .ready:
            return decision(
                input,
                code: .realTaskReady,
                state: .ready,
                conclusion: "当前接入可以完成真实任务",
                explanation:
                    "真实任务证据与当前设置匹配，可以继续工作。",
                action: .openCodex,
                source: .realTask
            )
        case .recoveryRequired, .needsBasic, .basicFailed,
                .needsRealTask, .realTaskFailed:
            break
        }
        if let failure = input.activeFailure {
            return decision(
                input,
                code: failureCode(
                    input.journey.failureSource
                ),
                state: .blocked,
                conclusion: failure.conclusion,
                explanation: failure.explanation,
                action: .resolveFailure(failure.primaryAction),
                source: failureSource(input.journey.failureSource),
                evidence: failure.evidence
            )
        }
        switch input.journey.verificationStage {
        case .recoveryRequired:
            return decision(
                input,
                code: .recoveryPending,
                state: .blocked,
                conclusion: "当前接入需要恢复",
                explanation:
                    "没有可直接采用的恢复结论；先查看诊断。",
                action: .openDiagnostics,
                source: .recovery
            )
        case .basicFailed:
            return genericFailure(
                input,
                code: .basicConnectionFailed,
                conclusion: "基础连接未通过",
                source: .basicConnection
            )
        case .realTaskFailed:
            return genericFailure(
                input,
                code: .realTaskFailed,
                conclusion: "真实任务未通过",
                source: .realTask
            )
        case .checkingBasic, .verifyingRealTask, .ready:
            preconditionFailure("handled above")
        case .needsBasic, .needsRealTask:
            break
        }
        if let doctor = input.doctorGuidance,
           doctorNeedsAction(doctor) {
            return decision(
                input,
                code: .doctorActionRequired,
                state: doctor.state == .blocked
                    ? .blocked : .needsAction,
                conclusion: doctor.conclusion,
                explanation: doctor.explanation,
                action: .performDoctorAction(
                    doctor.primaryAction
                ),
                source: .doctor,
                evidence: doctor.evidence
            )
        }
        if input.journey.route == .unknown {
            return decision(
                input,
                code: .routeUnknown,
                state: .needsAction,
                conclusion: "尚未读取当前接入",
                explanation: V015PassiveStateReadBoundary.detail,
                action: .refreshState,
                source: .none
            )
        }
        if input.needsCurrentStateRead {
            return decision(
                input, code: .currentStateReadRequired, state: .needsAction,
                conclusion: "已识别当前接入，先核对状态",
                explanation: "先离线核对版本、恢复状态和已有验证记录；不会重新发送模型请求。",
                action: .refreshState, source: .none
            )
        }
        if input.runtimeChangeInvalidatedRealTaskEvidence {
            switch input.journey.verificationStage {
            case .needsBasic:
                return decision(
                    input,
                    code: .runtimeChanged,
                    state: .needsAction,
                    conclusion: "Codex 已更新，需要重新验证",
                    explanation:
                        "旧验证证据不再适用于当前 Codex；先确认基础连接。",
                    action: .checkBasicConnection,
                    source: .realTask
                )
            case .needsRealTask:
                return decision(
                    input,
                    code: .runtimeChanged,
                    state: .needsAction,
                    conclusion: "Codex 已更新，需要重新验证",
                    explanation:
                        "旧真实任务证据不再适用于当前 Codex；重新验证后再继续工作。",
                    action: .verifyRealTask,
                    source: .realTask
                )
            case .checkingBasic, .verifyingRealTask, .ready,
                    .recoveryRequired, .basicFailed, .realTaskFailed:
                break
            }
        }
        if input.journey.verificationStage == .needsRealTask {
            return decision(
                input,
                code: .realTaskRequired,
                state: .needsAction,
                conclusion: "基础连接已通过，还需验证真实任务",
                explanation:
                    "普通响应不能证明工具调用和续答可以完成。",
                action: .verifyRealTask,
                source: .basicConnection
            )
        }
        let doctorPassed = input.doctorGuidance?.state == .ready
        return decision(
            input,
            code: .basicConnectionRequired,
            state: .needsAction,
            conclusion: doctorPassed
                ? "基础诊断通过，还需确认当前接入"
                : "当前接入尚未验证",
            explanation: doctorPassed
                ? "Doctor 未发现基础阻断，但不能代替当前接入的连接证据。"
                : "先确认基础连接；不会自动切换接入。",
            action: .checkBasicConnection,
            source: doctorPassed ? .doctor : .none,
            evidence: doctorPassed
                ? input.doctorGuidance?.evidence ?? [] : []
        )
    }

    private static func doctorNeedsAction(
        _ guidance: CodexDoctorActionableGuidance
    ) -> Bool {
        if guidance.state == .blocked { return true }
        guard guidance.state == .limited else { return false }
        return guidance.primaryAction != .reviewEvidence
            && guidance.primaryAction != .openCodex
    }

    private static func failureSource(
        _ source: V015UserJourneyFailureSource?
    ) -> V016AccessReadinessEvidenceSource {
        switch source {
        case .compatibility: return .configuration
        case .connection: return .basicConnection
        case .agentLoop: return .realTask
        case nil: return .none
        }
    }

    private static func failureCode(
        _ source: V015UserJourneyFailureSource?
    ) -> V016AccessReadinessCode {
        switch source {
        case .compatibility: return .compatibilityFailed
        case .connection: return .basicConnectionFailed
        case .agentLoop: return .realTaskFailed
        case nil: return .basicConnectionFailed
        }
    }

    private static func genericFailure(
        _ input: V016AccessReadinessInput,
        code: V016AccessReadinessCode,
        conclusion: String,
        source: V016AccessReadinessEvidenceSource
    ) -> V016AccessReadinessDecision {
        decision(
            input,
            code: code,
            state: .blocked,
            conclusion: conclusion,
            explanation:
                "没有可安全采用的失败分类；当前设置保持不变。",
            action: .openDiagnostics,
            source: source
        )
    }

    private static func decision(
        _ input: V016AccessReadinessInput,
        code: V016AccessReadinessCode,
        state: V016AccessReadinessState,
        conclusion: String,
        explanation: String,
        action: V016AccessReadinessPrimaryAction?,
        source: V016AccessReadinessEvidenceSource,
        evidence: [String] = []
    ) -> V016AccessReadinessDecision {
        V016AccessReadinessDecision(
            route: input.journey.route,
            code: code,
            state: state,
            conclusion: conclusion,
            explanation: explanation,
            primaryAction: action,
            evidenceSource: source,
            evidence: Array(evidence.prefix(8))
        )
    }
}

@MainActor
enum V016AccessReadinessRuntimeResolver {
    static func resolve(
        accessModel: V011AccessModel,
        doctorGuidance: CodexDoctorActionableGuidance?,
        codexInstalled: Bool
    ) -> V016AccessReadinessDecision {
        let projection =
            V015FirstUseRuntimeProjectionResolver.resolve(
                accessModel: accessModel,
                codexInstalled: codexInstalled
            )
        let failure: V013FailurePresentation?
        switch projection.journey.failureSource {
        case .compatibility:
            failure = accessModel.compatibilityFailurePresentation
        case .connection:
            failure = accessModel.currentConnectionFailurePresentation
        case .agentLoop:
            failure = accessModel.agentLoopFailurePresentation
        case nil:
            failure = nil
        }
        return V016AccessReadinessResolver.resolve(
            V016AccessReadinessInput(
                codexInstalled: codexInstalled,
                isReadingCurrentState: accessModel.isRefreshing,
                hasPendingRecovery: accessModel.hasPendingRecovery,
                canPreviewRecovery:
                    accessModel.hasExecutableRecoveryAction
                    && accessModel.canRunDeterministicRepair,
                hasConfigurationError: accessModel.errorMessage != nil,
                runtimeChangeInvalidatedRealTaskEvidence:
                    V016RuntimeEvidenceDrift.detected(
                        receipt: accessModel.agentLoopReceipt,
                        live: accessModel.liveState
                    ),
                journey: projection.journey,
                activeFailure: failure,
                doctorGuidance: doctorGuidance,
                needsCurrentStateRead: accessModel.needsCurrentStateRead,
                needsRecoveryStateRead: accessModel.recoveryDisposition == .unread,
                canKeepCurrentConfiguration: accessModel.canKeepCurrentConfigurationAndEndPendingSwitch,
                isRecoveryActionRunning: accessModel.isWorking
            )
        )
    }
}
