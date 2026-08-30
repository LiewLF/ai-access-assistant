import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerConnectionHealthToolView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @Binding var verificationOpen: Bool
    @Binding var connectionHistoryExpanded: Bool
    @Binding var codexLaunchError: String?
    @Binding var confirmsBasicConnection: Bool
    @Binding var confirmsRealAgentLoop: Bool
    @Binding var selectedRepairPreview: V014RecoveryRepairPreview?
    let openSettingsSection: (BeginnerSettingsSection) -> Void
    let openAccessSection: (BeginnerAccessSection) -> Void
    let openTransactions: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("排障入口")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("验证扩展能力") {
                        verificationOpen = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 8) {
                    Button("打开切换模式") {
                        openAccessSection(.switchMode)
                    }
                    Button("打开扩展能力") {
                        openSettingsSection(.capabilities)
                    }
                    Button("打开事务详情") {
                        openTransactions()
                    }
                    Button("打开使用说明") {
                        openSettingsSection(.guide)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                connectionHealthHistoryView
            }
            .frame(minHeight: 220, idealHeight: 300, maxHeight: 340)

            Divider()

            ConfigurationHealthView(
                model: model,
                refreshAction: {
                    model.refreshConfigurationHealth(
                        using: accessModel
                    )
                },
                onOpenExtensions: {
                    openSettingsSection(.capabilities)
                },
                onCopyAsManaged: { request in
                    accessModel.copyExternalModelCatalogAsManaged(request)
                    openSettingsSection(.capabilities)
                },
                onOpenGuide: {
                    openSettingsSection(.guide)
                },
                onOpenRecovery: {
                    openTransactions()
                }
            )
        }
    }

    private var connectionHealthHistoryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "接入救援",
                    systemImage: "cross.case.fill"
                )
                .font(.headline)
                Spacer()
                Text(
                    accessModel.currentDisplayName
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(
                "遇到不能使用时，主动检查一次。助手只给一个主要结论和对应入口，不会后台探测、自动切换或保存请求响应。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            let providerSummaries =
                accessModel.connectionHealthProviderSummaries
            if let currentSummary = providerSummaries.first(
                where: { $0.isCurrent }
            ) {
                currentConnectionRescueCard(currentSummary)
            }

            DisclosureGroup(
                isExpanded: $connectionHistoryExpanded
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    let otherSummaries = providerSummaries.filter {
                        !$0.isCurrent
                    }
                    if !otherSummaries.isEmpty {
                        Text("其他中转")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(
                                        minimum: 260,
                                        maximum: 420
                                    ),
                                    spacing: 10
                                )
                            ],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(otherSummaries) { summary in
                                connectionHealthProviderCard(summary)
                            }
                        }
                    }
                    if accessModel.connectionHealthHistory.isEmpty {
                        Text("尚无主动检测记录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("最近检测记录")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(
                            Array(
                                accessModel.connectionHealthHistory
                                    .prefix(5)
                            )
                        ) { observation in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(
                                        connectionHealthOutcomeText(
                                            observation.outcome
                                        ),
                                        systemImage:
                                            connectionHealthOutcomeIcon(
                                                observation.outcome
                                            )
                                    )
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(
                                        connectionHealthOutcomeColor(
                                            observation.outcome
                                        )
                                    )
                                    Spacer()
                                    Text(
                                        String(
                                            format: "%.0f ms",
                                            observation
                                                .durationMilliseconds
                                        )
                                    )
                                    .font(
                                        .system(
                                            .caption,
                                            design: .monospaced
                                        )
                                    )
                                    .foregroundStyle(.secondary)
                                }
                                Text(
                                    "\(connectionHealthProviderText(observation.providerID)) · \(observation.observedAt.formatted(date: .abbreviated, time: .shortened))"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(
                                    connectionHealthDetailText(
                                        observation
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            if observation.id
                                != accessModel.connectionHealthHistory
                                    .prefix(5).last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Label(
                        "检测记录与其他中转",
                        systemImage: "clock.arrow.circlepath"
                    )
                    Spacer()
                    Text(
                        "\(accessModel.connectionHealthHistory.count) 条"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.medium))

            if let historyError =
                accessModel.connectionHealthHistoryError {
                Label(
                    historyError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func currentConnectionRescueCard(
        _ summary: V011ConnectionHealthProviderSummary
    ) -> some View {
        let advice = accessModel.currentConnectionRescueAdvice
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(summary.displayName)
                    .font(.callout.weight(.semibold))
                Spacer()
                if accessModel.isCheckingCurrentConnection {
                    ProgressView()
                        .controlSize(.small)
                } else if let latest = summary.latestObservation {
                    Label(
                        connectionHealthOutcomeText(latest.outcome),
                        systemImage:
                            connectionHealthOutcomeIcon(latest.outcome)
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        connectionHealthOutcomeColor(latest.outcome)
                    )
                } else {
                    Text("尚未检查")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                codexLaunchError
                    ?? connectionHealthAdviceText(
                        advice,
                        observation: summary.latestObservation
                    )
            )
                .font(.caption)
                .foregroundStyle(
                    codexLaunchError == nil
                        ? Color.secondary : Color.red
                )
            if let failure = V013FailurePresentation.connection(
                summary.latestObservation
            ) {
                BeginnerFailureEvidenceDisclosure(
                    presentation: failure
                )
            }
            Label(
                accessModel.agentLoopVerificationSummary,
                systemImage: accessModel.isAgentLoopVerified
                    ? "checkmark.seal.fill"
                    : "hammer"
            )
            .font(.caption)
            .foregroundStyle(
                accessModel.isAgentLoopVerified
                    ? Color.green
                    : (
                        accessModel.agentLoopErrorMessage == nil
                            ? Color.secondary : Color.red
                    )
            )
            if advice == .recoverPendingSwitch {
                Button("查看修复预览") {
                    if accessModel.canRunDeterministicRepair {
                        selectedRepairPreview =
                            accessModel.recoveryRepairPreview
                    } else {
                        openTransactions()
                    }
                }
                .buttonStyle(.bordered)
            } else if accessModel.hasCurrentBasicConnectionEvidence,
                      !accessModel.isAgentLoopVerified {
                Button(
                    accessModel.isVerifyingAgentLoop
                        ? "正在验证真实任务"
                        : "验证真实任务"
                ) {
                    confirmsRealAgentLoop = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accessModel.canVerifyRealAgentLoop)
            } else {
                connectionHealthAdviceAction(
                    advice,
                    observation: summary.latestObservation
                )
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityIdentifier("build89.connection-rescue")
    }

    private func connectionHealthProviderCard(
        _ summary: V011ConnectionHealthProviderSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.displayName)
                        .font(.body.weight(.semibold))
                    Text(summary.providerID)
                        .font(
                            .system(
                                .caption,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if summary.isCurrent {
                    Text("当前")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: Capsule()
                        )
                }
            }

            if let digest = summary.digest,
               let latest = summary.latestObservation {
                HStack {
                    Label(
                        connectionHealthOutcomeText(latest.outcome),
                        systemImage:
                            connectionHealthOutcomeIcon(
                                latest.outcome
                            )
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        connectionHealthOutcomeColor(
                            latest.outcome
                        )
                    )
                    Spacer()
                    Text("最近 \(digest.sampleCount) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let passRate = Int(
                    (digest.passRate * 100).rounded()
                )
                let median = digest
                    .medianDurationMilliseconds.map {
                        String(format: "%.0f ms", $0)
                    } ?? "无有效耗时"
                Text(
                    "通过率 \(passRate)% · 中位耗时 \(median)"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(
                    "上次检测：\(latest.observedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if digest.consecutiveIssueCount > 0 {
                    Label(
                        "连续 \(digest.consecutiveIssueCount) 次需要处理",
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                Label(
                    "尚未主动检测",
                    systemImage: "questionmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Text(connectionHealthSavedModelText(summary))
                .font(.caption)
                .foregroundStyle(
                    summary.defaultModelPresent == false
                        ? .orange : .secondary
                )
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    summary.isCurrent
                        ? Color.accentColor.opacity(0.08)
                        : Color(nsColor: .windowBackgroundColor)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            summary.isCurrent
                                ? Color.accentColor.opacity(0.2)
                                : Color(
                                    nsColor: .separatorColor
                                ).opacity(0.55),
                            lineWidth: 1
                        )
                }
        }
    }

    private func connectionHealthAdviceText(
        _ advice: V011ConnectionHealthAdvice,
        observation: V011ConnectionHealthObservation?
    ) -> String {
        if let detail = BeginnerConnectionHealthCopy.detail(
            for: observation
        ) {
            return detail
        }
        switch advice {
        case .none:
            return "当前没有需要处理的连接问题。"
        case .retryConnectionCheck:
            return "确认当前网络、登录或中转资料没有变化后，再主动检测一次。"
        case .reviewRelayProfile:
            return "核对当前中转地址、模型和认证资料；保存名称不能证明实际路由。"
        case .refreshCurrentState:
            return "先重新读取当前状态。确认设置没有继续变化后，再主动检测。"
        case .openCodex:
            return "最小请求已通过。打开Codex并新建任务，才是实际使用确认。"
        case .reopenCodex:
            return "新建任务或重开Codex后再主动检测；助手不会自动重开。"
        case .recoverPendingSwitch:
            return "先处理上次未完成的切换；当前设置和历史会话保持保护。"
        }
    }

    @ViewBuilder
    private func connectionHealthAdviceAction(
        _ advice: V011ConnectionHealthAdvice,
        observation: V011ConnectionHealthObservation?
    ) -> some View {
        switch advice {
        case .retryConnectionCheck:
            Button(
                accessModel.isCheckingCurrentConnection
                    ? "正在检测"
                    : (
                        BeginnerConnectionHealthCopy
                            .actionTitle(for: observation)
                            ?? "再次检测"
                    )
            ) {
                confirmsBasicConnection = true
            }
            .buttonStyle(.bordered)
            .disabled(!accessModel.canCheckCurrentConnection)
        case .reviewRelayProfile:
            Button(
                BeginnerConnectionHealthCopy.actionTitle(
                    for: observation
                ) ?? "检查中转资料"
            ) {
                openAccessSection(.switchMode)
            }
            .buttonStyle(.bordered)
        case .refreshCurrentState:
            Button("重新读取当前状态") {
                accessModel.refresh()
            }
            .buttonStyle(.bordered)
            .disabled(
                accessModel.isWorking
                    || accessModel.isRefreshing
                    || accessModel.isCheckingCurrentConnection
            )
        case .openCodex:
            Button("打开Codex") {
                codexLaunchError =
                    BeginnerCodexLauncher.openInstalled()
            }
            .buttonStyle(.bordered)
        case .reopenCodex:
            Button("查看处理方法") {
                openSettingsSection(.guide)
            }
            .buttonStyle(.bordered)
        case .recoverPendingSwitch:
            Button("处理上次切换") {
                if accessModel.canRecoverPendingSwitch {
                    accessModel.recoverPendingSwitch()
                } else {
                    openTransactions()
                }
            }
            .buttonStyle(.bordered)
        case .none:
            Button("现在不能用，帮我检查") {
                confirmsBasicConnection = true
            }
            .buttonStyle(.bordered)
            .disabled(!accessModel.canCheckCurrentConnection)
        }
    }

    private func connectionHealthOutcomeText(
        _ outcome: V011ConnectionHealthOutcome
    ) -> String {
        switch outcome {
        case .passed:
            return "检测通过"
        case .degraded:
            return "连接可用，状态待确认"
        case .failed:
            return "检测失败"
        }
    }

    private func connectionHealthOutcomeIcon(
        _ outcome: V011ConnectionHealthOutcome
    ) -> String {
        switch outcome {
        case .passed:
            return "checkmark.circle.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private func connectionHealthOutcomeColor(
        _ outcome: V011ConnectionHealthOutcome
    ) -> Color {
        switch outcome {
        case .passed:
            return .green
        case .degraded:
            return .orange
        case .failed:
            return .red
        }
    }

    private func connectionHealthProviderText(
        _ providerID: String?
    ) -> String {
        guard let providerID else { return "未知轨道" }
        return providerID == "openai"
            ? "ChatGPT官方" : providerID
    }

    private func connectionHealthSavedModelText(
        _ summary: V011ConnectionHealthProviderSummary
    ) -> String {
        guard let modelCount = summary.savedModelCount else {
            return "保存模型：无当前资料 · 非在线 /models 结果"
        }
        let defaultState: String
        switch summary.defaultModelPresent {
        case .some(true):
            defaultState = "默认模型已保存"
        case .some(false):
            defaultState = "默认模型缺失，请核对"
        case .none:
            defaultState = "默认模型状态未知"
        }
        return "保存模型：\(modelCount) 个 · \(defaultState) · 非在线 /models 结果"
    }

    private func connectionHealthDetailText(
        _ observation: V011ConnectionHealthObservation
    ) -> String {
        let runtime: String
        switch observation.runtimeState {
        case .fresh:
            runtime = "运行态已载入当前配置"
        case .stale:
            runtime = "已打开任务可能保持旧设置"
        case .notRunning:
            runtime = "未检测到运行中的Codex"
        case .unknown:
            runtime = "运行态未确认"
        }
        let session: String
        switch observation.sessionProviderCheck {
        case .synchronized:
            session = "任务路由已同步"
        case .drifted:
            session = "任务路由有旧标签"
        case .unavailable:
            session = "任务路由未核对"
        case nil:
            session = "任务路由无结果"
        }
        guard let failureCode = observation.failureCode else {
            return "\(runtime) · \(session)"
        }
        let failure = V013FailurePresentation
            .connection(observation)?.conclusion
            ?? "连接检测失败：\(failureCode.rawValue)"
        return [failure, runtime, session]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
