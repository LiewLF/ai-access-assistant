import Foundation

enum CodexInstallationReadinessGuidance {
    @MainActor
    static func reverificationDecision(
        accessModel: V011AccessModel,
        baseline: CodexInstallationGuidance
    ) -> V016AccessReadinessDecision? {
        selectReverificationDecision(
            V016AccessReadinessRuntimeResolver.resolve(
                accessModel: accessModel, doctorGuidance: nil, codexInstalled: true
            ),
            baseline: baseline,
            runtimeChanged: V016RuntimeEvidenceDrift.detected(
                receipt: accessModel.agentLoopReceipt, live: accessModel.liveState
            )
        )
    }

    static func selectReverificationDecision(
        _ current: V016AccessReadinessDecision,
        baseline: CodexInstallationGuidance,
        runtimeChanged: Bool
    ) -> V016AccessReadinessDecision? {
        guard baseline.canOpenInstalledCodex, runtimeChanged,
              current.route == .official else { return nil }
        switch current.code {
        case .runtimeChanged, .checkingBasicConnection, .checkingRealTask:
            return current
        default:
            return nil
        }
    }

    @MainActor
    static func resolve(
        accessModel: V011AccessModel,
        host: HostPlatformFacts,
        installation: AgentInstallation,
        endpointState: InstallationDiagnosticState? = nil
    ) -> CodexInstallationGuidance {
        let baseline = CodexInstallationGuidanceEvaluator.evaluate(
            host: host,
            installation: installation,
            endpointState: endpointState,
            officialConnectionVerified: accessModel.liveState != nil
                && accessModel.currentProviderID == nil
                && accessModel.isCurrentConnectionVerified
        )
        guard baseline.canOpenInstalledCodex else { return baseline }
        let current = V016AccessReadinessRuntimeResolver.resolve(
            accessModel: accessModel, doctorGuidance: nil, codexInstalled: true
        )
        return applying(current, to: baseline)
    }

    static func applying(
        _ current: V016AccessReadinessDecision,
        to baseline: CodexInstallationGuidance
    ) -> CodexInstallationGuidance {
        guard baseline.canOpenInstalledCodex,
              current.route == .official,
              current.code == .realTaskReady else { return baseline }
        return CodexInstallationGuidance(
            state: .officialReady,
            title: "Codex 官方真实任务可用",
            detail: "当前官方接入已有与当前设置和 Codex 版本匹配的真实任务证据，可以继续使用。",
            steps: [],
            nextAction: "直接打开 Codex 继续工作，无需重复登录或再次执行基础连接检查。",
            officialSource: baseline.officialSource
        )
    }
}
