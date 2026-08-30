import Foundation

/// Immutable read model for recovery eligibility, switch availability,
/// cutover actions, and blocking guidance.
struct V011AccessRecoveryPresentation: @unchecked Sendable {
    let managedState: V011ManagedState
    let liveState: LiveCodexState?
    let compatibilityEvidence: CodexCompatibilityEvidence?
    let hasPendingRecovery: Bool
    let recoveryDisposition: V011RecoveryDisposition
    let recoveryRepairPreview: V014RecoveryRepairPreview?
    let currentProviderID: String?
    let currentRelayProfileID: String?
    let needsCurrentRelayAdoption: Bool
    let isWorking: Bool
    let isRefreshing: Bool
    let isCheckingCurrentConnection: Bool
    let isVerifyingAgentLoop: Bool
    let isRefreshingOfficialUsage: Bool
    let verifyingSavedRelayReadinessID: String?

    var canRunDeterministicRepair: Bool {
        hasExecutableRecoveryAction
            && recoveryRepairPreview?.totalCount ?? 0 > 0
            && !interactionBusy
    }

    var deterministicRepairPreviewSummary: String {
        switch recoveryDisposition {
        case .recoverable:
            guard let recoveryRepairPreview else {
                return "正在读取已有恢复点；没有可核对的预览前不会执行修复。"
            }
            return "发现\(recoveryRepairPreview.totalCount)个已有恢复点：\(recoveryRepairPreview.operationSummary)。只处理这些未完成操作；首个失败即停止，并保留仍需恢复的记录。"
        case .decisionRequired:
            return "当前证据存在冲突，不能确定性自动修复；请保留当前设置或验证后接管。"
        case .none:
            return "当前没有可确定性自动修复的未完成操作。网络、认证、额度或中转兼容问题不会被猜测修改。"
        }
    }

    var hasExecutableRecoveryAction: Bool {
        hasPendingRecovery && recoveryDisposition == .recoverable
    }

    var canRecoverPendingSwitch: Bool {
        hasExecutableRecoveryAction && !interactionBusy
    }

    var canKeepCurrentStateAndEndPendingSwitch: Bool {
        hasPendingRecovery
            && recoveryDisposition == .decisionRequired
            && !interactionBusy
    }

    var canAcceptCurrentRelayAndEndPendingSwitch: Bool {
        hasPendingRecovery
            && recoveryDisposition == .decisionRequired
            && currentProviderID != nil
            && currentRelayProfileID != nil
            && !needsCurrentRelayAdoption
            && liveState?.versionSupport.allowsWrites == true
            && !interactionBusy
    }

    var allowsSwitching: Bool {
        liveState?.versionSupport.allowsWrites == true
            && !needsCurrentRelayAdoption
            && !hasPendingRecovery
            && !interactionBusy
    }

    var canSwitchToOfficial: Bool {
        guard allowsSwitching else { return false }
        if case .relay? = liveState?.mode {
            return hasTrustedOfficialRootOverlay
        }
        return true
    }

    var hasTrustedOfficialRootOverlay: Bool {
        guard case let .verified(schemaID)? =
                liveState?.versionSupport else {
            return false
        }
        return managedState.officialRootOverlay?.trustedOverlay(
            forAny: CodexVersionContract.compatibleSchemaIDs(
                for: schemaID
            )
        ) != nil
    }

    var canEstablishOfficialRecoveryInfo: Bool {
        guard case .official? = liveState?.mode else {
            return false
        }
        return allowsSwitching && !hasTrustedOfficialRootOverlay
    }

    var cutoverRecoveryPlan: FableCutoverRecoveryPlan {
        FableCutoverRecoveryPolicy.plan(
            for: FableCutoverFailureContext(
                pendingTransaction: hasPendingRecovery,
                evidenceConflict:
                    recoveryDisposition == .decisionRequired,
                candidateEditable: true,
                savedRelayCount: managedState.relayProfiles.filter {
                    $0.id != currentRelayProfileID
                }.count,
                officialExitAvailable:
                    hasTrustedOfficialRootOverlay
                        || liveState?.mode == .official,
                preSwitchSnapshotAvailable: hasPendingRecovery,
                lastKnownGoodAvailable:
                    managedState.lastKnownGoodCutoverConfiguration
                        != nil,
                minimalForwardRepairSafe:
                    hasExecutableRecoveryAction,
                diagnosticExportAvailable: true
            )
        )
    }

    var cutoverRecoverySummary: String {
        let names = cutoverRecoveryPlan.availableActions
            .prefix(5)
            .map(\.displayName)
        return names.isEmpty
            ? "安全恢复入口尚未建立"
            : names.joined(separator: " · ")
    }

    var switchingBlockMessage: String? {
        if hasPendingRecovery {
            return pendingRecoveryBlockMessage(action: "切换模式")
        }
        if needsCurrentRelayAdoption {
            return "请先接管当前中转并保持现状，再切换模式"
        }
        if isRefreshing {
            return "正在验证当前Codex版本；升级后的验证只在隔离临时目录中进行"
        }
        guard let liveState else {
            return "还在确认Codex当前状态，请稍后再试"
        }
        guard liveState.versionSupport.allowsWrites else {
            return compatibilityEvidence?.summary
                ?? "当前Codex版本尚未通过兼容验证。现在只读取状态，不会修改设置或历史会话。"
        }
        return nil
    }

    func pendingRecoveryBlockMessage(action: String) -> String {
        if recoveryDisposition == .decisionRequired {
            return canAcceptCurrentRelayAndEndPendingSwitch
                ? "上次切换没有完成，当前设置已保留。可先验证当前状态，或只处理设置、不处理历史会话，再\(action)"
                : "上次切换没有完成，当前设置已保留。只处理设置、不处理历史会话，再\(action)"
        }
        return "请先处理上次未完成的操作，再\(action)"
    }

    private var interactionBusy: Bool {
        isWorking
            || isRefreshing
            || isCheckingCurrentConnection
            || isVerifyingAgentLoop
            || isRefreshingOfficialUsage
            || verifyingSavedRelayReadinessID != nil
    }
}
