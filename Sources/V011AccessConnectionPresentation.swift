import Foundation

/// Immutable read model for current-route identity, connection evidence,
/// action availability, and user-facing connection guidance.
struct V011AccessConnectionPresentation: @unchecked Sendable {
    let managedState: V011ManagedState
    let liveState: LiveCodexState?
    let connectionHealthHistory: [V011ConnectionHealthObservation]
    let hasPendingRecovery: Bool
    let isWorking: Bool
    let isRefreshing: Bool
    let isCheckingCurrentConnection: Bool
    let isVerifyingAgentLoop: Bool
    let isRefreshingOfficialUsage: Bool
    let verifyingSavedRelayReadinessID: String?
    let isAgentLoopVerified: Bool
    let agentLoopReceipt: V011AgentLoopReceipt?
    let agentLoopReceiptTargetsCurrentState: Bool
    let agentLoopTransientError: String?
    let currentConnectionCheckError: String?
    let isCurrentConnectionVerified: Bool
    let currentConnectionReceipt: V011ConnectionReceipt?
    let currentRuntimeFreshness: V011RuntimeFreshness
    let currentSessionProviderCheck: V011SessionProviderCheck?
    let now: Date

    var currentProviderID: String? {
        switch liveState?.mode {
        case .official, nil:
            return nil
        case let .relay(providerID):
            return providerID
        }
    }

    var connectionHealthProviderSummaries:
        [V011ConnectionHealthProviderSummary] {
        var descriptors = [
            V011ConnectionHealthProviderDescriptor(
                providerID: "openai",
                displayName: "ChatGPT官方",
                savedModelCount: nil,
                defaultModelPresent: nil,
                isCurrent: currentProviderID == nil
            )
        ]
        descriptors.append(
            contentsOf: managedState.relayProfiles.map { profile in
                let modelIDs = Set(
                    profile.models.compactMap { value in
                        let normalized = value.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        return normalized.isEmpty ? nil : normalized
                    }
                )
                let defaultModel = profile.defaultModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return V011ConnectionHealthProviderDescriptor(
                    providerID: profile.v011ProviderID,
                    displayName: profile.name,
                    savedModelCount: modelIDs.count,
                    defaultModelPresent: !defaultModel.isEmpty
                        && modelIDs.contains(defaultModel),
                    isCurrent: currentProviderID
                        == profile.v011ProviderID
                )
            }
        )
        if let unsavedCurrentProviderDescriptor {
            descriptors.append(unsavedCurrentProviderDescriptor)
        }
        return V011ConnectionHealthAnalyzer.providerSummaries(
            connectionHealthHistory,
            descriptors: descriptors
        )
    }

    /// The live route can point at a relay that no saved profile covers, for
    /// example a hand-edited configuration. History for that provider still
    /// belongs to the current route, so it needs a current descriptor; without
    /// one the failure would be filed as a historical provider that is not
    /// the route the user is on.
    private var unsavedCurrentProviderDescriptor:
        V011ConnectionHealthProviderDescriptor? {
        guard let liveState,
              case let .relay(providerID) = liveState.mode,
              !managedState.relayProfiles.contains(where: {
                  $0.v011ProviderID == providerID
              }) else { return nil }
        let actualName = (liveState.provider?.displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return V011ConnectionHealthProviderDescriptor(
            providerID: providerID,
            displayName: actualName.isEmpty
                ? "当前中转（未保存）" : "\(actualName)（未保存）",
            savedModelCount: nil,
            defaultModelPresent: nil,
            isCurrent: true
        )
    }

    var currentConnectionHealthObservation:
        V011ConnectionHealthObservation? {
        connectionHealthProviderSummaries.first(where: {
            $0.isCurrent
        })?.latestObservation
    }

    private var currentConnectionEvidenceObservation:
        V011ConnectionHealthObservation? {
        guard let liveState,
              let observation = currentConnectionHealthObservation,
              V011ConnectionHealthService.observationMatches(
                  observation,
                  live: liveState,
                  receipt: currentConnectionReceipt,
                  at: now
              ) else { return nil }
        return observation
    }

    var currentConnectionFailurePresentation: V013FailurePresentation? {
        guard let observation = currentConnectionEvidenceObservation else {
            return nil
        }
        // Older builds saved a successful probe as degraded when unrelated
        // historical tasks had other provider labels. Preserve that record,
        // but do not project it as a current connection failure.
        if observation.outcome == .degraded,
           observation.failureCode == .sessionProviderDrift {
            return nil
        }
        return V013FailurePresentation.connection(observation)
    }

    var currentConnectionRescueAdvice: V011ConnectionHealthAdvice {
        V011ConnectionHealthAnalyzer.rescueAdvice(
            hasPendingRecovery: hasPendingRecovery,
            needsRelayAdoption: needsCurrentRelayAdoption,
            latestObservation: currentConnectionEvidenceObservation
        )
    }

    var currentCodexContractID: String? {
        guard case let .verified(schemaID)? =
                liveState?.versionSupport else {
            return nil
        }
        return schemaID
    }

    var currentRelayProfile: CodexRelayProfile? {
        guard let currentProviderID else { return nil }
        return managedState.relayProfiles.first {
            $0.v011ProviderID == currentProviderID
        }
    }

    var currentRelayProfileID: String? {
        currentRelayProfile?.id
    }

    var currentCapabilityProfileSHA256: String? {
        guard let currentRelayProfile else { return nil }
        return try? ProviderCapabilityProfileIdentity.sha256(
            currentRelayProfile.effectiveCapabilityProfile
        )
    }

    var currentDisplayName: String {
        guard let liveState else {
            return "正在检查"
        }
        switch liveState.mode {
        case .official:
            return "Codex官方"
        case let .relay(providerID):
            if let profile = managedState.relayProfiles.first(
                where: { $0.v011ProviderID == providerID }
            ), V011RelaySemanticMatcher.matches(
                live: liveState,
                profile: profile
            ) {
                return profile.name
            }
            let actualName = liveState.provider?.displayName
                ?? "当前中转"
            return "\(actualName)（设置已变化）"
        }
    }

    var currentEndpointHost: String? {
        V011ConnectionHealthService.endpointHost(
            liveState?.provider?.baseURL
        )
    }

    var canCheckCurrentConnection: Bool {
        liveState != nil && !interactionBusy
    }

    var canVerifyRealAgentLoop: Bool {
        liveState != nil
            && hasFreshConnectionReceipt
            && !hasPendingRecovery
            && !interactionBusy
    }

    var hasCurrentBasicConnectionEvidence: Bool {
        hasFreshConnectionReceipt
    }

    var agentLoopVerificationSummary: String {
        if isVerifyingAgentLoop {
            return "正在隔离环境验证真实工具调用和续答"
        }
        if isAgentLoopVerified {
            return "真实任务闭环已通过"
        }
        if let failure = agentLoopFailurePresentation {
            return "\(failure.conclusion)：\(failure.explanation) 下一步：\(failure.primaryAction.title)。"
        }
        if hasFreshConnectionReceipt {
            return "基础连接已通过；真实任务闭环尚未验证"
        }
        return "先通过基础连接检测，再验证真实任务闭环"
    }

    var agentLoopFailurePresentation: V013FailurePresentation? {
        if let agentLoopTransientError {
            return V011AgentLoopFailureState.presentation(agentLoopTransientError)
        }
        guard let agentLoopReceipt, agentLoopReceiptTargetsCurrentState,
              let stage = agentLoopReceipt.failureStage else { return nil }
        return V013FailurePresentation.agentLoop(stage, reason: agentLoopReceipt.failureReason)
    }

    var currentConnectionVerificationSummary: String {
        if isCheckingCurrentConnection {
            return "正在发送最小真实请求"
        }
        if let currentConnectionCheckError {
            return "检测失败：\(currentConnectionCheckError)"
        }
        if hasFreshConnectionReceipt,
           currentSessionProviderCheck != .synchronized {
            return currentSessionProviderCheck == .drifted
                ? "最小请求已通过 · 历史任务保留其他接入标签"
                : "最小请求已通过 · 历史任务标签尚未核对"
        }
        if isCurrentConnectionVerified,
           let checkedAt = currentConnectionReceipt?.verifiedAt {
            if currentRuntimeFreshness == .stale {
                return "已通过 · 已打开任务是否采用新设置未验证"
            }
            if currentRuntimeFreshness == .unknown {
                return "已通过 · 当前任务生效状态未确认"
            }
            return "已通过 · \(checkedAt.formatted(date: .numeric, time: .shortened))"
        }
        if currentConnectionReceipt != nil {
            return "上次检测结果已过期"
        }
        return "尚未检测"
    }

    var currentRuntimeFreshnessText: String {
        switch currentRuntimeFreshness {
        case .fresh:
            return "运行实例晚于当前配置"
        case .stale:
            return "运行实例早于当前配置"
        case .notRunning:
            return "未检测到运行中的Codex"
        case .unknown:
            return "尚未核对"
        }
    }

    var currentSessionProviderCheckText: String {
        switch currentSessionProviderCheck {
        case .synchronized:
            return "历史任务标签与当前接入一致"
        case .drifted:
            return "历史任务保留其他接入标签"
        case .unavailable:
            return "历史任务标签暂时无法核对"
        case nil:
            return "尚未核对"
        }
    }

    var currentConnectionWarning: String? {
        if hasFreshConnectionReceipt,
           currentRuntimeFreshness == .stale {
            return "基础连接已通过；Codex运行实例早于当前配置，已打开任务是否采用新设置尚未验证。历史任务标签不能证明实际请求路由。"
        }
        if hasFreshConnectionReceipt,
           currentRuntimeFreshness == .unknown {
            return "连接检测已通过；当前已打开任务是否载入最新设置无法确认。此状态不锁死切轨，切轨时仍执行完整安全保护。"
        }
        if needsCurrentRelayAdoption {
            return "保存名称与当前实际地址、模型或认证不一致；名称不能作为路由依据。"
        }
        switch currentSessionProviderCheck {
        case .drifted:
            return "历史任务保留其他接入标签，这是历史记录差异，不表示当前请求使用旧线路；无需为此改写历史或重启Codex。"
        case .unavailable:
            return "历史任务标签暂时无法核对；这不改变基础连接结果，当前任务能力仍需独立验证。"
        case .synchronized, nil:
            break
        }
        guard let liveState else { return nil }
        let providerID = V011ConnectionHealthService
            .providerID(liveState)
        if let receipt = currentConnectionReceipt,
           receipt.configHash != liveState.configHash
            || receipt.providerID != providerID {
            return "助手上次验证记录与实时配置不同；请重新检测连接。"
        }
        if let receipt = currentConnectionReceipt,
           receipt.configHash == liveState.configHash,
           receipt.providerID == providerID,
           V011ConnectionHealthService.normalizedEndpointHost(
               receipt.endpointHost
           ) != currentEndpointHost {
            return "最小请求验证地址与当前配置目标不同；请重新检测连接。"
        }
        return nil
    }

    var hasFreshConnectionReceipt: Bool {
        guard let liveState,
              let currentConnectionReceipt else {
            return false
        }
        return V011ConnectionHealthService.receiptMatches(
            currentConnectionReceipt,
            live: liveState,
            at: now
        )
    }

    var needsCurrentRelayAdoption: Bool {
        guard case let .relay(providerID)? = liveState?.mode else {
            return false
        }
        guard let liveState,
              let profile = managedState.relayProfiles.first(where: {
                  $0.v011ProviderID == providerID
              }) else {
            return true
        }
        return !V011RelaySemanticMatcher.matches(
            live: liveState,
            profile: profile
        )
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
