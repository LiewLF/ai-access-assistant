import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerStartView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @ObservedObject var historyModel: V011HistoryModel
    @ObservedObject var usageModel: V012UsageTruthModel
    let onAddRelay: () -> Void
    let onSwitchMode: () -> Void
    let onFindSessions: () -> Void
    let onInstallCodex: () -> Void
    let onOpenDiagnostics: () -> Void
    let onOpenGuide: () -> Void

    @State private var codexLaunchError: String?
    @State private var confirmsBasicConnection = false
    @State private var confirmsRealAgentLoop = false
    @State private var selectedRepairPreview:
        V014RecoveryRepairPreview?

    private var codexInstalled: Bool {
        CodexApplicationLocator.applicationURL() != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今天还能用多少")
                        .font(.title.weight(.semibold))
                    Text(
                        "先看官方套餐、本周剩余与满额估算，再决定今天怎么用。"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                V011UnifiedResourceOverviewCard(
                    accessModel: accessModel,
                    historyModel: historyModel,
                    usageModel: usageModel,
                    onFailureAction: performOfficialUsageAction
                )

                if firstUseGuidance.isVisible
                    && !unifiedReadinessOverridesFirstUse {
                    firstUseGuidanceCard
                } else {
                    unifiedReadinessCard
                }

                homeOutcomeActions

                outcomeCards

                if accessModel.errorMessage != nil {
                    configurationProblemCard
                }

                VStack(spacing: 12) {
                    Text("接入与帮助")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if codexInstalled {
                        actionCard(
                            title: "添加中转",
                            detail:
                                "粘贴说明、文字或截图，自动整理需要填写的信息。",
                            icon: "plus.circle.fill",
                            action: onAddRelay
                        )
                        actionCard(
                            title: "切换模式",
                            detail:
                                "在官方和已保存的中转之间切换；失败会自动恢复原轨，只有恢复无法安全完成时才暂停。",
                            icon:
                                "arrow.triangle.2.circlepath",
                            action: onSwitchMode
                        )
                    }
                    actionCard(
                        title: "使用说明",
                        detail:
                            "看每个窗口能做什么，错误去哪里处理。",
                        icon: "book.closed.fill",
                        action: onOpenGuide
                    )
                }

                Text(
                    "助手不会覆盖技能、工具连接、扩展或项目设置，也不会改动官方登录。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            accessModel.preparePresentation()
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.isRefreshing) {
            wasRefreshing, isRefreshing in
            guard wasRefreshing, !isRefreshing else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .confirmationDialog(
            "确认第1步基础连接？",
            isPresented: $confirmsBasicConnection
        ) {
            Button("确认联网并检查基础连接") {
                accessModel.detectCurrentConnection(
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将按当前设置发送一次最小请求，确认地址、登录凭据和基础响应。中转可能扣费；官方是否计入额度以实际账户为准。不会切换接入、读取任务内容或修改配置。"
            )
        }
        .confirmationDialog(
            "确认验证真实任务？",
            isPresented: $confirmsRealAgentLoop
        ) {
            Button("确认联网并验证真实任务") {
                accessModel.verifyRealAgentLoop(
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将使用Codex自带命令，在本机临时隔离环境完成一次工具调用和续答。可能消耗官方额度或产生中转费用；不会读取真实项目或历史会话，临时认证副本随后删除。"
            )
        }
        .sheet(item: $selectedRepairPreview) { preview in
            BeginnerRecoveryRepairPreviewView(
                preview: preview
            ) { fingerprint in
                accessModel.runDeterministicRepair(
                    userConsented: true,
                    expectedPreviewFingerprint: fingerprint
                )
            }
        }
    }

    private var firstUseGuidance: V015FirstUseGuidance {
        firstUseRuntimeProjection.guidance
    }

    private var firstUseRuntimeProjection:
        V015FirstUseRuntimeProjection {
        V015FirstUseRuntimeProjectionResolver.resolve(
            accessModel: accessModel,
            codexInstalled: codexInstalled
        )
    }

    private var unifiedReadinessDecision:
        V016AccessReadinessDecision {
        V016AccessReadinessRuntimeResolver.resolve(
            accessModel: accessModel,
            doctorGuidance: model.codexDoctorGuidance,
            codexInstalled: codexInstalled
        )
    }

    private var unifiedReadinessOverridesFirstUse: Bool {
        guard let action =
                unifiedReadinessDecision.primaryAction else {
            return false
        }
        if case .performDoctorAction = action { return true }
        return false
    }

    private var unifiedReadinessCard: some View {
        BeginnerUnifiedReadinessCard(
            decision: unifiedReadinessDecision,
            accessibilityIdentifier: "build152.home.readiness",
            actionEnabled: unifiedReadinessActionEnabled,
            perform: performUnifiedReadinessAction
        )
    }

    private var unifiedReadinessActionEnabled: Bool {
        guard let action =
                unifiedReadinessDecision.primaryAction else {
            return false
        }
        switch action {
        case .checkBasicConnection:
            return accessModel.canCheckCurrentConnection
        case .verifyRealTask:
            return accessModel.canVerifyRealAgentLoop
        case .refreshState:
            return !accessModel.isWorking
                && !accessModel.isRefreshing
        case .resolveFailure(.retryLater):
            return accessModel.canCheckCurrentConnection
        default:
            return true
        }
    }

    private var firstUseGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("首次使用", systemImage: "figure.wave")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
            Text(firstUseGuidance.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(firstUseGuidance.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let primaryTitle = firstUseGuidance.primaryTitle,
               let primaryAction = firstUseGuidance.primaryAction {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        firstUseButton(
                            primaryTitle,
                            action: primaryAction,
                            prominent: true,
                            identifier:
                                "build118.first-use.primary"
                        )
                        if let secondaryTitle =
                                firstUseGuidance.secondaryTitle,
                           let secondaryAction =
                                firstUseGuidance.secondaryAction {
                            firstUseButton(
                                secondaryTitle,
                                action: secondaryAction,
                                prominent: false,
                                identifier:
                                    "build118.first-use.secondary"
                            )
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        firstUseButton(
                            primaryTitle,
                            action: primaryAction,
                            prominent: true,
                            identifier:
                                "build118.first-use.primary"
                        )
                        if let secondaryTitle =
                                firstUseGuidance.secondaryTitle,
                           let secondaryAction =
                                firstUseGuidance.secondaryAction {
                            firstUseButton(
                                secondaryTitle,
                                action: secondaryAction,
                                prominent: false,
                                identifier:
                                    "build118.first-use.secondary"
                            )
                        }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(firstUseGuidance.title)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.blue.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(firstUseGuidance.title)
        .accessibilityHint(firstUseGuidance.detail)
        .accessibilityIdentifier("build118.first-use")
    }

    @ViewBuilder
    private func firstUseButton(
        _ title: String,
        action: V015FirstUseGuidanceAction,
        prominent: Bool,
        identifier: String
    ) -> some View {
        let button = Button(title) {
            performFirstUseAction(action)
        }
        .accessibilityLabel(title)
        .accessibilityHint(firstUseGuidance.detail)
        .accessibilityIdentifier(identifier)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func performFirstUseAction(
        _ action: V015FirstUseGuidanceAction
    ) {
        switch action {
        case .installCodex:
            onInstallCodex()
        case .refreshState:
            accessModel.refresh()
        case .checkBasic:
            confirmsBasicConnection = true
        case .verifyRealTask:
            confirmsRealAgentLoop = true
        case .addRelay:
            onAddRelay()
        case .switchMode:
            onSwitchMode()
        }
    }

    private func performUnifiedReadinessAction(
        _ action: V016AccessReadinessPrimaryAction
    ) {
        switch action {
        case .installCodex:
            onInstallCodex()
        case .previewRecovery:
            selectedRepairPreview =
                accessModel.recoveryRepairPreview
        case .openDiagnostics:
            onOpenDiagnostics()
        case let .resolveFailure(failureAction):
            performFailurePrimaryAction(failureAction)
        case let .performDoctorAction(doctorAction):
            performDoctorPrimaryAction(doctorAction)
        case .refreshState:
            accessModel.refresh()
        case .checkBasicConnection:
            confirmsBasicConnection = true
        case .verifyRealTask:
            confirmsRealAgentLoop = true
        case .openCodex:
            codexLaunchError =
                BeginnerCodexLauncher.openInstalled()
        }
    }

    private func performDoctorPrimaryAction(
        _ action: CodexDoctorPrimaryAction
    ) {
        switch action {
        case .openCodex, .openCodexLogin:
            codexLaunchError =
                BeginnerCodexLauncher.openInstalled()
        case .refreshState:
            accessModel.refresh()
        case .reviewConfiguration:
            model.openCodexConfiguration()
        case .checkNetwork, .reviewEvidence:
            onOpenDiagnostics()
        case .updateCodex:
            onInstallCodex()
        }
    }

    private var homeOutcomeActions: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    homeSecondaryActionCard(
                        title: "继续上次任务",
                        detail:
                            "打开最近会话，选择一条在Codex中继续；这里只读列表元数据。",
                        icon: "clock.arrow.circlepath",
                        accessibilityIdentifier:
                            "build104.home.continue",
                        action: onFindSessions
                    )
                    homeSecondaryActionCard(
                        title: "找回没显示的历史",
                        detail:
                            "旧会话没显示时，进入历史工具核对可见性或导入备份。",
                        icon: "tray.and.arrow.down.fill",
                        accessibilityIdentifier:
                            "build104.home.find-history",
                        action: onFindSessions
                    )
                }
                VStack(spacing: 12) {
                    homeSecondaryActionCard(
                        title: "继续上次任务",
                        detail:
                            "打开最近会话，选择一条在Codex中继续；这里只读列表元数据。",
                        icon: "clock.arrow.circlepath",
                        accessibilityIdentifier:
                            "build104.home.continue",
                        action: onFindSessions
                    )
                    homeSecondaryActionCard(
                        title: "找回没显示的历史",
                        detail:
                            "旧会话没显示时，进入历史工具核对可见性或导入备份。",
                        icon: "tray.and.arrow.down.fill",
                        accessibilityIdentifier:
                            "build104.home.find-history",
                        action: onFindSessions
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作结果入口")
    }

    private func homeSecondaryActionCard(
        title: String,
        detail: String,
        icon: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .foregroundStyle(.blue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func performOfficialUsageAction(
        _ action: V013FailurePrimaryAction
    ) {
        switch action {
        case .openCodexLogin:
            codexLaunchError =
                BeginnerCodexLauncher.openInstalled()
        case .retryLater:
            accessModel.refreshOfficialUsage()
        case .updateAssistant, .restartAssistant:
            onOpenGuide()
        case .refreshState:
            accessModel.refresh()
        case .reviewRelayProfile,
                .reviewQuota,
                .reviewDNSAndAddress:
            onSwitchMode()
        case .reviewTLSAndProxy,
                .checkNetwork,
                .reviewToolPermission,
                .reviewResponsesCompatibility,
                .stopOtherConfigurationTools,
                .openAdvancedDiagnostics:
            onOpenDiagnostics()
        }
    }

    private func performFailurePrimaryAction(
        _ action: V013FailurePrimaryAction
    ) {
        switch action {
        case .reviewRelayProfile,
                .reviewQuota,
                .reviewDNSAndAddress:
            onSwitchMode()
        case .retryLater:
            confirmsBasicConnection = true
        case .refreshState:
            accessModel.refresh()
        case .openCodexLogin:
            codexLaunchError =
                BeginnerCodexLauncher.openInstalled()
        case .updateAssistant, .restartAssistant:
            onOpenGuide()
        case .reviewTLSAndProxy,
                .checkNetwork,
                .reviewToolPermission,
                .reviewResponsesCompatibility,
                .stopOtherConfigurationTools,
                .openAdvancedDiagnostics:
            onOpenDiagnostics()
        }
    }

    private var outcomeCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                outcomeCard(
                    title: "配置状态",
                    value: accessModel.configurationOutcome,
                    detail: "配置提交独立于历史会话整理",
                    icon: "checkmark.shield",
                    accessibilityIdentifier:
                        V011AccessibilityContract.configurationCardID,
                    accessibilitySortPriority: 2
                )
                outcomeCard(
                    title: "会话状态",
                    value: accessModel.sessionOutcome,
                    detail: "失败可重试，不回滚已提交配置",
                    icon: "bubble.left.and.bubble.right",
                    accessibilityIdentifier:
                        V011AccessibilityContract.sessionCardID,
                    accessibilitySortPriority: 1
                )
            }
            VStack(alignment: .leading, spacing: 12) {
                outcomeCard(
                    title: "配置状态",
                    value: accessModel.configurationOutcome,
                    detail: "配置提交独立于历史会话整理",
                    icon: "checkmark.shield",
                    accessibilityIdentifier:
                        V011AccessibilityContract.configurationCardID,
                    accessibilitySortPriority: 2
                )
                outcomeCard(
                    title: "会话状态",
                    value: accessModel.sessionOutcome,
                    detail: "失败可重试，不回滚已提交配置",
                    icon: "bubble.left.and.bubble.right",
                    accessibilityIdentifier:
                        V011AccessibilityContract.sessionCardID,
                    accessibilitySortPriority: 1
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("配置与会话状态")
    }

    private func outcomeCard(
        title: String,
        value: String,
        detail: String,
        icon: String,
        accessibilityIdentifier: String,
        accessibilitySortPriority: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(value)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
        .accessibilityHint(detail)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilitySortPriority(accessibilitySortPriority)
    }

    private var configurationProblemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                accessModel.recoveryDisposition
                    == .decisionRequired
                    ? "上次切换没有完成，当前设置已保留。"
                    : (
                        accessModel.hasPendingRecovery
                            ? "上次恢复没有完成"
                            : "Codex状态暂时没有读清楚"
                    ),
                systemImage: "wrench.and.screwdriver.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)
            Text(
                BeginnerText.friendly(
                    accessModel.errorMessage
                        ?? "请重新检查；仍未恢复时打开高级诊断。"
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if accessModel.recoveryDisposition
                == .decisionRequired {
                Label(
                    "历史记录暂时无法安全处理。助手不会删除聊天内容，也不会覆盖当前设置。",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                Label(
                    "先结束上次操作，再重新读取当前状态；当前设置和聊天内容保持不变。",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if accessModel.hasPendingRecovery,
               accessModel.recoveryDisposition
                == .recoverable,
               accessModel.recoveryProtectsNewSessions {
                Label(
                    "最小修复会先保护切换后新增的历史会话和内容；只有满足严格条件才恢复本次受影响内容。",
                    systemImage: "shield.checkered"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
            }
            if accessModel.hasPendingRecovery {
                Label(
                    "安全恢复出口："
                        + accessModel.cutoverRecoverySummary,
                    systemImage: "door.left.hand.open"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let stage =
                accessModel.recoveryFailureStageText {
                Text("未完成步骤：\(stage)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let nextAction =
                accessModel.recoveryNextAction {
                Text("下一步：\(nextAction)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if accessModel.hasExecutableRecoveryAction {
                    Button("查看修复预览") {
                        selectedRepairPreview =
                            accessModel.recoveryRepairPreview
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !accessModel.canRunDeterministicRepair
                    )
                } else if accessModel.recoveryDisposition
                    == .decisionRequired {
                    Button("验证并继续使用当前轨") {
                        accessModel
                            .acceptCurrentRelayAndEndPendingSwitch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !accessModel
                            .canAcceptCurrentRelayAndEndPendingSwitch
                    )
                    Button("保留当前设置并结束上次操作") {
                        accessModel.keepCurrentStateAndEndPendingSwitch()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !accessModel
                            .canKeepCurrentStateAndEndPendingSwitch
                    )
                } else {
                    Button("重新检查") {
                        accessModel.refresh()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        accessModel.isWorking
                            || accessModel.isRefreshing
                            || accessModel
                                .isCheckingCurrentConnection
                    )
                }
                Button("打开修复工具") {
                    onOpenDiagnostics()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private var capabilityVerdict:
        ConfigurationCapabilityVerdict {
        model.configurationHealth?
            .capabilitySummary.verdict ?? .unverified
    }

    private var capabilityVerdictColor: Color {
        switch capabilityVerdict {
        case .consistent: return .green
        case .different: return .orange
        case .unverified: return .secondary
        }
    }

    private func actionCard(
        title: String,
        detail: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(17)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }
}
