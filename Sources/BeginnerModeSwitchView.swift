import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerModeSwitchView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @Binding var section: BeginnerAccessSection
    @Binding var localStatus: String?
    @Binding var pendingTarget: BeginnerPendingSwitchTarget?
    @Binding var capabilityEditorProfile: CodexRelayProfile?
    @Binding var savedRelayEditorProfile: CodexRelayProfile?
    @Binding var readinessProfile: CodexRelayProfile?
    @Binding var confirmsSavedRelayReadiness: Bool
    let readinessDecision: V016AccessReadinessDecision
    let readinessActionEnabled: Bool
    let performReadinessAction:
        (V016AccessReadinessPrimaryAction) -> Void
    let onOpenGuide: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BeginnerUnifiedReadinessCard(
                    decision: readinessDecision,
                    accessibilityIdentifier:
                        "build152.access.readiness",
                    actionEnabled: readinessActionEnabled,
                    perform: performReadinessAction
                )
                compatibilityBanner
                BeginnerThirdPartyEvidenceView()
                currentRelayAdoption

                if let message =
                    accessModel.switchingBlockMessage {
                    Label(
                        message,
                        systemImage:
                            "exclamationmark.shield.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(13)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        .orange.opacity(0.08),
                        in: RoundedRectangle(
                            cornerRadius: 11
                        )
                    )
                }

                modeCard(
                    name: "Codex官方",
                    detail: "使用ChatGPT登录和官方额度。",
                    active:
                        accessModel.liveState?.mode
                            == .official,
                    enabled:
                        accessModel.canSwitchToOfficial
                ) {
                    pendingTarget = .official
                }

                if !accessModel
                        .hasTrustedOfficialRootOverlay {
                    if accessModel.liveState?.mode
                        == .official {
                        VStack(
                            alignment: .leading,
                            spacing: 9
                        ) {
                            Text("先建立官方恢复信息")
                                .font(.headline)
                            Text(
                                "当前已是官方。验证官方连接后，只保存安全返回官方所需的恢复信息，不改动Codex配置、会话或凭据。"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Button("建立官方恢复信息") {
                                accessModel.establishOfficialRecoveryInfo()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                !accessModel
                                    .canEstablishOfficialRecoveryInfo
                            )
                        }
                        .padding(14)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .background(
                            .blue.opacity(0.07),
                            in: RoundedRectangle(
                                cornerRadius: 11
                            )
                        )
                    } else if accessModel
                        .currentProviderID != nil {
                        Label(
                            "尚未建立官方恢复信息，助手不会猜测官方模型设置，因此暂不能切到官方。请先用原来的工具切回官方并刷新；中转之间仍可切换。",
                            systemImage: "info.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(13)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .background(
                            .secondary.opacity(0.06),
                            in: RoundedRectangle(
                                cornerRadius: 11
                            )
                        )
                    }
                }

                ForEach(
                    V015AccessListProjector.project(
                        accessModel.savedProfiles,
                        currentProviderID:
                            accessModel.currentProviderID
                    ),
                    id: \.id
                ) { row in
                    let profile = row.profile
                    modeCard(
                        name: profile.name,
                        detail: row.detail,
                        active: row.active,
                        enabled:
                            accessModel.allowsSwitching,
                        preflightTitle:
                            savedRelayReadinessButtonTitle(
                                for: profile
                            ),
                        preflightEnabled:
                            accessModel
                                .canVerifySavedRelayReadiness(
                                    profile
                                ),
                        preflightAction: {
                            readinessProfile = profile
                            confirmsSavedRelayReadiness = true
                        },
                        preflightStatus:
                            accessModel.savedRelayReadinessStatus(
                                for: profile
                            ),
                        preflightStatusColor:
                            savedRelayReadinessStatusColor(
                                for: profile
                            ),
                        secondaryTitle: "扩展能力",
                        secondaryEnabled:
                            accessModel.allowsSwitching,
                        secondaryAction: {
                            capabilityEditorProfile = profile
                        },
                        tertiaryTitle: "修改中转",
                        tertiaryEnabled:
                            accessModel.allowsSwitching,
                        tertiaryAction: {
                            savedRelayEditorProfile = profile
                        }
                    ) {
                        pendingTarget = .relay(profile)
                    }
                }

                if accessModel.savedProfiles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("还没有保存的中转")
                            .font(.headline)
                        Button("去添加中转") {
                            section = .addRelay
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(35)
                    .background(
                        .secondary.opacity(0.05),
                        in: RoundedRectangle(
                            cornerRadius: 14
                        )
                    )
                }

                BeginnerAccessStatusView(
                    model: model,
                    accessModel: accessModel,
                    localStatus: localStatus
                )
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var compatibilityBanner: some View {
        if accessModel.isRefreshing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在验证当前Codex版本")
                        .font(.callout.weight(.semibold))
                    Text("升级后的检查只使用临时目录，不读取或修改你的真实设置和历史会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .blue.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        } else if let evidence =
                    accessModel.compatibilityEvidence,
                  evidence.source == .freshProbe
                    || evidence.source == .cachedProbe {
            Label(
                evidence.summary,
                systemImage: "checkmark.shield.fill"
            )
            .font(.callout)
            .foregroundStyle(.green)
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .green.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        } else if let failure =
                    accessModel.compatibilityFailurePresentation {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.conclusion)
                        .font(.callout.weight(.semibold))
                    Text(failure.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BeginnerFailureEvidenceDisclosure(
                        presentation: failure
                    )
                }
                Spacer()
                Button(failure.primaryAction.title) {
                    if failure.primaryAction == .updateAssistant {
                        onOpenGuide()
                    } else {
                        accessModel.refresh()
                    }
                }
                .disabled(
                    accessModel.isWorking
                        || accessModel.isRefreshing
                        || accessModel
                            .isCheckingCurrentConnection
                )
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
    }

    @ViewBuilder
    private var currentRelayAdoption: some View {
        if accessModel.needsCurrentRelayAdoption {
            VStack(alignment: .leading, spacing: 9) {
                Label(
                    "检测到正在使用一个中转",
                    systemImage:
                        "arrow.down.circle.fill"
                )
                .font(.headline)
                Text(
                    "把当前中转保存到助手；不会改动现有Codex设置。"
                )
                .foregroundStyle(.secondary)
                TextField(
                    "给它起个名字，可留空",
                    text:
                        $model
                            .existingProviderDisplayName
                )
                .textFieldStyle(.roundedBorder)
                Button("接管并保持现状") {
                    accessModel.adoptCurrentRelay(
                        displayName:
                            model
                                .existingProviderDisplayName,
                        replacementAPIKey:
                            model.apiKey
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    accessModel.isWorking
                        || accessModel.isRefreshing
                        || accessModel
                            .isCheckingCurrentConnection
                        || accessModel.hasPendingRecovery
                )
            }
            .padding(15)
            .background(
                .orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 13)
            )
        }
    }

    private func savedRelayReadinessButtonTitle(
        for profile: CodexRelayProfile
    ) -> String {
        switch accessModel.savedRelayReadinessState(
            for: profile
        ) {
        case .verifying:
            return "正在验证"
        case .usable, .expired, .failed:
            return "重新验证"
        case .unverified:
            return "验证真实任务"
        }
    }

    private func savedRelayReadinessStatusColor(
        for profile: CodexRelayProfile
    ) -> Color {
        switch accessModel.savedRelayReadinessState(
            for: profile
        ) {
        case .verifying:
            return .blue
        case .usable:
            return .green
        case .failed:
            return .orange
        case .expired:
            return .yellow
        case .unverified:
            return .secondary
        }
    }

    private func modeCard(
        name: String,
        detail: String,
        active: Bool,
        enabled: Bool,
        preflightTitle: String? = nil,
        preflightEnabled: Bool = true,
        preflightAction: (() -> Void)? = nil,
        preflightStatus: String? = nil,
        preflightStatusColor: Color = .secondary,
        secondaryTitle: String? = nil,
        secondaryEnabled: Bool = true,
        secondaryAction: (() -> Void)? = nil,
        tertiaryTitle: String? = nil,
        tertiaryEnabled: Bool = true,
        tertiaryAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(
                systemName:
                    active
                        ? "checkmark.circle.fill"
                        : "circle"
            )
            .font(.title2)
            .foregroundStyle(
                active ? Color.green : Color.secondary
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let preflightStatus {
                    Text(preflightStatus)
                        .font(
                            .caption.weight(.medium)
                        )
                        .foregroundStyle(
                            preflightStatusColor
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
            }
            Spacer()
            if let preflightTitle,
               let preflightAction {
                Button(preflightTitle) {
                    preflightAction()
                }
                .buttonStyle(.bordered)
                .disabled(!preflightEnabled)
            }
            if let secondaryTitle,
               let secondaryAction {
                Button(secondaryTitle) {
                    secondaryAction()
                }
                .buttonStyle(.bordered)
                .disabled(!secondaryEnabled)
            }
            if let tertiaryTitle,
               let tertiaryAction {
                Button(tertiaryTitle) {
                    tertiaryAction()
                }
                .buttonStyle(.bordered)
                .disabled(!tertiaryEnabled)
            }
            if active {
                Text("当前")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            } else {
                Button("切换") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }
}
