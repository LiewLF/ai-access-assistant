import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BeginnerPendingSwitchTarget: Identifiable {
    case official
    case relay(CodexRelayProfile)

    var id: String {
        switch self {
        case .official:
            return "official"
        case let .relay(profile):
            return profile.id
        }
    }

    var displayName: String {
        switch self {
        case .official:
            return "Codex官方"
        case let .relay(profile):
            return profile.name
        }
    }

    var configurationWrites: [String] {
        switch self {
        case .official:
            return ["按已验证官方恢复信息精确恢复受管能力字段"]
        case let .relay(profile):
            return CapabilityOptionHelp.configurationSummary(
                profile.effectiveCapabilityProfile
                    .configurationSummary
            )
        }
    }
}

struct BeginnerAccessView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @Binding var section: BeginnerAccessSection
    let onChooseScreenshots: () -> Void
    let onInstallCodex: () -> Void
    let onOpenDiagnostics: () -> Void
    let onOpenGuide: () -> Void

    @State private var localStatus: String?
    @State private var pendingTarget: BeginnerPendingSwitchTarget?
    @State private var capabilityEditorProfile:
        CodexRelayProfile?
    @State private var savedRelayEditorProfile:
        CodexRelayProfile?
    @State private var readinessProfile:
        CodexRelayProfile?
    @State private var confirmsSavedRelayReadiness = false
    @State private var confirmsBasicConnection = false
    @State private var confirmsRealAgentLoop = false
    @State private var selectedRepairPreview:
        V014RecoveryRepairPreview?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("接入与切换")
                        .font(
                            .system(
                                size: 28,
                                weight: .bold
                            )
                        )
                    Text("添加一次，以后直接选择想用的模式。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modeBadge
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)

            Picker(
                "接入与切换",
                selection: $section
            ) {
                ForEach(
                    BeginnerAccessSection.allCases
                ) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            Divider()

            Group {
                switch section {
                case .addRelay:
                    BeginnerRelayDraftView(
                        model: model,
                        accessModel: accessModel,
                        section: $section,
                        localStatus: $localStatus,
                        onChooseScreenshots: onChooseScreenshots,
                        protocolIsSupported: protocolIsSupported,
                        protocolCompatibilityMessage:
                            protocolCompatibilityMessage,
                        primaryActionTitle: relayDraftPrimaryActionTitle,
                        addRelayDisabled: addRelayDisabled,
                        synchronizeFastModeWithServiceTier:
                            synchronizeFastModeWithServiceTier,
                        checkRelayDraft: checkRelayDraft,
                        readRelayDraftModels: readRelayDraftModels
                    )
                case .switchMode:
                    BeginnerModeSwitchView(
                        model: model,
                        accessModel: accessModel,
                        section: $section,
                        localStatus: $localStatus,
                        pendingTarget: $pendingTarget,
                        capabilityEditorProfile:
                            $capabilityEditorProfile,
                        savedRelayEditorProfile:
                            $savedRelayEditorProfile,
                        readinessProfile: $readinessProfile,
                        confirmsSavedRelayReadiness:
                            $confirmsSavedRelayReadiness,
                        readinessDecision:
                            unifiedReadinessDecision,
                        readinessActionEnabled:
                            unifiedReadinessActionEnabled,
                        performReadinessAction:
                            performUnifiedReadinessAction,
                        onOpenGuide: onOpenGuide
                    )
                }
            }
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
        .onChange(of: model.isFetchingModels) {
            wasFetching,
            isFetching in
            guard wasFetching, !isFetching else {
                return
            }
            performRelayDraftAction(.modelReadFinished)
        }
        .sheet(item: $pendingTarget) { target in
            BeginnerSwitchConfirmationCard(
                currentMode: accessModel.currentDisplayName,
                targetMode: target.displayName,
                targetConfigurationWrites:
                    target.configurationWrites,
                confirm: {
                    performConfirmedSwitch(target)
                },
                cancel: {
                    pendingTarget = nil
                }
            )
        }
        .sheet(item: $capabilityEditorProfile) { profile in
            BeginnerRelayCapabilityEditor(
                sourceProfile: profile,
                isCurrent:
                    accessModel.currentProviderID
                        == profile.v011ProviderID,
                save: { targetProfile in
                    accessModel.updateRelayCapabilities(
                        sourceProfile: profile,
                        targetProfile: targetProfile
                    )
                    capabilityEditorProfile = nil
                },
                cancel: {
                    capabilityEditorProfile = nil
                }
            )
        }
        .sheet(item: $savedRelayEditorProfile) { profile in
            BeginnerSavedRelayEditor(
                sourceProfile: profile,
                isCurrent:
                    accessModel.currentProviderID
                        == profile.v011ProviderID,
                save: { targetProfile, replacementAPIKey in
                    accessModel.updateRelayProfile(
                        sourceProfile: profile,
                        targetProfile: targetProfile,
                        replacementAPIKey:
                            replacementAPIKey
                    )
                    savedRelayEditorProfile = nil
                },
                delete: {
                    accessModel.deleteSavedRelay(profile)
                    savedRelayEditorProfile = nil
                },
                cancel: {
                    savedRelayEditorProfile = nil
                }
            )
        }
        .confirmationDialog(
            "确认验证这个中转的真实任务？",
            isPresented: $confirmsSavedRelayReadiness
        ) {
            if let profile = readinessProfile {
                Button("确认联网并验证真实任务") {
                    accessModel.verifySavedRelayReadiness(
                        profile,
                        userConsented: true
                    )
                    readinessProfile = nil
                }
            }
            Button("取消", role: .cancel) {
                readinessProfile = nil
            }
        } message: {
            Text(
                "助手会在隔离临时配置中使用这个已保存中转，完成一次shell工具调用与续答。可能消耗账户额度或产生中转费用；不会切换当前接入，不读取真实项目，凭据副本随后删除。"
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
                BeginnerCurrentConnectionCheckCopy.consent
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
                "将在隔离环境完成一次工具调用和续答。可能消耗官方额度或产生中转费用；不会读取真实项目或历史会话。"
            )
        }
        .sheet(item: $selectedRepairPreview) { preview in
            BeginnerRecoveryRepairPreviewView(
                preview: preview,
                canConfirm: accessModel.canRunDeterministicRepair
            ) { fingerprint in
                accessModel.runDeterministicRepair(
                    userConsented: true,
                    expectedPreviewFingerprint: fingerprint
                )
            }
        }
    }

    private var codexInstalled: Bool {
        CodexApplicationLocator.applicationURL() != nil
    }

    private var unifiedReadinessDecision:
        V016AccessReadinessDecision {
        V016AccessReadinessRuntimeResolver.resolve(
            accessModel: accessModel,
            doctorGuidance: model.codexDoctorGuidance,
            codexInstalled: codexInstalled
        )
    }

    private var unifiedReadinessActionEnabled: Bool {
        guard let action =
                unifiedReadinessDecision.primaryAction else {
            return false
        }
        switch action {
        case .keepCurrentConfiguration:
            return accessModel.canKeepCurrentConfigurationAndEndPendingSwitch
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

    private func performUnifiedReadinessAction(
        _ action: V016AccessReadinessPrimaryAction
    ) {
        switch action {
        case .installCodex:
            onInstallCodex()
        case .previewRecovery:
            selectedRepairPreview =
                accessModel.recoveryRepairPreview
        case .keepCurrentConfiguration:
            accessModel.keepCurrentConfigurationAndEndPendingSwitch()
        case .openDiagnostics:
            onOpenDiagnostics()
        case let .resolveFailure(failureAction):
            performReadinessFailureAction(failureAction)
        case let .performDoctorAction(doctorAction):
            performReadinessDoctorAction(doctorAction)
        case .refreshState:
            accessModel.refresh()
        case .checkBasicConnection:
            confirmsBasicConnection = true
        case .verifyRealTask:
            confirmsRealAgentLoop = true
        case .openCodex:
            localStatus = BeginnerCodexLauncher.openInstalled()
        }
    }

    private func performReadinessFailureAction(
        _ action: V013FailurePrimaryAction
    ) {
        switch action {
        case .reviewRelayProfile, .reviewQuota,
                .reviewDNSAndAddress:
            section = .switchMode
        case .retryLater:
            confirmsBasicConnection = true
        case .refreshState:
            accessModel.refresh()
        case .openCodexLogin:
            localStatus = BeginnerCodexLauncher.openInstalled()
        case .updateAssistant, .restartAssistant:
            onOpenGuide()
        case .reviewTLSAndProxy, .checkNetwork,
                .reviewToolPermission,
                .reviewResponsesCompatibility,
                .openAdvancedDiagnostics:
            onOpenDiagnostics()
        }
    }

    private func performReadinessDoctorAction(
        _ action: CodexDoctorPrimaryAction
    ) {
        switch action {
        case .openCodex, .openCodexLogin:
            localStatus = BeginnerCodexLauncher.openInstalled()
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

    private var modeBadge: some View {
        Label(
            compactModeName,
            systemImage: modeBadgeIcon
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(modeBadgeColor)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            modeBadgeColor.opacity(0.1),
            in: Capsule()
        )
    }

    private var modeBadgeIcon: String {
        switch unifiedReadinessDecision.state {
        case .ready:
            return "checkmark.seal.fill"
        case .checking:
            return "hourglass.circle.fill"
        case .needsAction:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }

    private var modeBadgeColor: Color {
        switch unifiedReadinessDecision.state {
        case .ready: return .green
        case .checking: return .blue
        case .needsAction: return .orange
        case .blocked: return .red
        }
    }

    private var compactModeName: String {
        switch accessModel.liveState?.mode {
        case .official:
            return "当前：官方"
        case let .relay(providerID):
            return "当前："
                + (
                    accessModel.savedProfiles.first {
                        $0.v011ProviderID == providerID
                    }?.name
                    ?? "中转"
                )
        case nil:
            return "正在检查"
        }
    }

    private func checkRelayDraft() {
        guard protocolIsSupported else {
            localStatus = protocolCompatibilityMessage
            return
        }
        guard model.unresolvedConflicts.isEmpty else {
            localStatus =
                "请先处理上方所有资料冲突，再继续添加。"
            return
        }
        guard relayDraftAddressIsValid() else { return }
        let missing = model.missingFields
        let missingWithoutModel = missing.filter {
            $0 != "模型"
        }
        guard missingWithoutModel.isEmpty else {
            localStatus =
                "还需填写："
                + missingWithoutModel.joined(
                    separator: "、"
                )
            return
        }
        performRelayDraftAction(.primaryButton)
    }

    private func relayDraftAddressIsValid() -> Bool {
        guard let issue = V011RelayEndpointPolicy.draftIssue(model.baseURL,
            localGatewayConfirmed: model.confirmsLocalGateway) else { return true }
        localStatus = issue
        return false
    }

    private func readRelayDraftModels() {
        guard !addRelayDisabled, relayDraftAddressIsValid() else { return }
        model.fetchModels()
    }

    private func performRelayDraftAction(_ event: BeginnerRelayDraftEvent) {
        switch BeginnerRelayDraftActionPolicy.action(
            for: event,
            isDraftVisible: section == .addRelay,
            isBusy: addRelayDisabled,
            isFetchingModels: model.isFetchingModels,
            hasSelectedModel: !model.missingFields.contains("模型")
        ) {
        case .none:
            return
        case .readModels:
            localStatus =
                "正在读取可用模型。选定后，请点击“检测并添加”完成验证和保存。"
            readRelayDraftModels()
        case .submit:
            submitRelayDraft()
        case let .feedback(message):
            localStatus = message
        }
    }

    private var relayDraftPrimaryActionTitle: String {
        BeginnerRelayDraftActionPolicy.buttonTitle(
            isFetchingModels: model.isFetchingModels,
            hasSelectedModel: !model.missingFields.contains("模型")
        )
    }

    private func submitRelayDraft() {
        guard protocolIsSupported,
              model.unresolvedConflicts.isEmpty,
              model.missingFields.isEmpty else {
            return
        }
        synchronizeFastModeWithServiceTier(
            model.serviceTierKind
        )
        localStatus = nil
        accessModel.addRelay(
            draft: model.codexRelayProfile,
            apiKey: model.apiKey
        )
    }

    private func synchronizeFastModeWithServiceTier(
        _ serviceTier: ProviderServiceTierKind
    ) {
        switch serviceTier {
        case .fast:
            model.fastModeSetting = .enabled
        case .standard, .flex:
            model.fastModeSetting = .disabled
        case .followCodex:
            model.fastModeSetting = .preserve
        case .inherit, .providerSpecific:
            model.fastModeSetting = .preserve
        }
    }

    private var protocolIsSupported: Bool {
        model.wireProtocol == .responses
    }

    private var protocolCompatibilityMessage: String {
        switch model.wireProtocol {
        case .responses:
            return "Responses：当前Codex版本已经验证可用。"
        case .chatCompletions:
            return "Chat Completions：当前Codex版本不能直接使用，因此不会添加。请向中转站确认是否同时提供Responses。"
        case .anthropicMessages:
            return "Anthropic Messages：它用于Claude类接口，当前Codex版本不能直接使用，因此不会添加。"
        }
    }

    private var addRelayDisabled: Bool {
        accessModel.isWorking
            || accessModel.isRefreshing
            || accessModel.isCheckingCurrentConnection
            || model.isFetchingModels
            || accessModel.hasPendingRecovery
            || !protocolIsSupported
            || !model.unresolvedConflicts.isEmpty
    }

    private func performConfirmedSwitch(
        _ target: BeginnerPendingSwitchTarget
    ) {
        switch target {
        case .official:
            accessModel.switchToOfficial()
        case let .relay(profile):
            accessModel.switchToRelay(profile)
        }
        localStatus = nil
        pendingTarget = nil
    }
}
