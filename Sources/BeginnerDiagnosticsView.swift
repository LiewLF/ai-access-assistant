import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerDiagnosticsView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    let openSettingsSection: (BeginnerSettingsSection) -> Void
    let openAccessSection: (BeginnerAccessSection) -> Void

    @State private var tool = Tool.health
    @State private var legacyBackupImporterOpen = false
    @State private var verificationOpen = false
    @State private var connectionHistoryExpanded = false
    @State private var codexLaunchError: String?
    @State private var confirmsBasicConnection = false
    @State private var confirmsRealAgentLoop = false
    @State private var supportBundleExportStatus: String?
    @State private var selectedRepairPreview:
        V014RecoveryRepairPreview?

    private enum Tool:
        String, CaseIterable, Identifiable {
        case health = "配置体检"
        case doctor = "Codex诊断"
        case structure = "结构证据"
        case legacyBackups = "旧备份"
        case transactions = "事务详情"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("高级诊断")
                            .font(.title2.bold())
                        Text(
                            "正常使用不需要进入这里。遇到读取、切换或恢复问题时，再按提示使用对应工具。"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导出脱敏求助包") {
                        exportRedactedSupportBundle()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(
                        "保存固定状态代码、版本和证据新鲜度；不含密钥、路径或任务内容"
                    )
                    .accessibilityIdentifier(
                        "build155.support-bundle.export"
                    )
                }
                Text(
                    "求助包由你选择保存位置，只写本机JSON，不联网、不上传。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let supportBundleExportStatus {
                    Text(supportBundleExportStatus)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            supportBundleExportStatus
                        )
                        .accessibilityIdentifier(
                            "build155.support-bundle.status"
                        )
                }
                Picker("诊断工具", selection: $tool) {
                    ForEach(Tool.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(18)

            Divider()

            BeginnerUnifiedReadinessCard(
                decision: unifiedReadinessDecision,
                accessibilityIdentifier:
                    "m32.diagnostics.readiness",
                actionEnabled: unifiedReadinessActionEnabled,
                perform: performUnifiedReadinessAction
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            switch tool {
            case .health:
                BeginnerConnectionHealthToolView(
                    model: model,
                    accessModel: accessModel,
                    verificationOpen: $verificationOpen,
                    connectionHistoryExpanded:
                        $connectionHistoryExpanded,
                    codexLaunchError: $codexLaunchError,
                    confirmsBasicConnection:
                        $confirmsBasicConnection,
                    confirmsRealAgentLoop:
                        $confirmsRealAgentLoop,
                    selectedRepairPreview:
                        $selectedRepairPreview,
                    openSettingsSection: openSettingsSection,
                    openAccessSection: openAccessSection,
                    openTransactions: {
                        tool = .transactions
                    }
                )
            case .doctor:
                codexDoctorView
            case .structure:
                structureEvidenceView
            case .legacyBackups:
                legacyBackupView
            case .transactions:
                transactionDetailView
            }
        }
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fileImporter(
            isPresented: $legacyBackupImporterOpen,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first else {
                return
            }
            let accessed =
                url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            model.scanLegacyBackupDirectory(url)
        }
        .sheet(isPresented: $verificationOpen) {
            BeginnerCapabilityVerificationView(
                model: model,
                accessModel: accessModel
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
                "将调用Codex内置CLI，在临时HOME、CODEX_HOME和空白工作区完成一次shell工具调用与续答。可能消耗账户额度或产生中转费用；不读取真实项目或历史会话，临时认证副本随后删除。"
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
        .onAppear {
            guard tool == .health,
                  !accessModel.isRefreshing else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: tool) { _, selectedTool in
            guard selectedTool == .health,
                  !accessModel.isRefreshing else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.compatibilityEvidence) {
            _, _ in
            guard tool == .health else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.isRefreshing) {
            wasRefreshing, isRefreshing in
            guard tool == .health,
                  wasRefreshing,
                  !isRefreshing else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.isCheckingCurrentConnection) {
            wasChecking, isChecking in
            guard tool == .health,
                  wasChecking,
                  !isChecking else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.providerProbeReceipts) {
            _, _ in
            guard tool == .health else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
    }

    private var codexDoctorView: some View {
        BeginnerCodexDoctorView(model: model)
    }

    private var structureEvidenceView: some View {
        diagnosticScroll {
            diagnosticIntro(
                title: "导出脱敏结构证据",
                detail:
                    "只记录配置有哪些栏目，不记录栏目里的值、密钥或文件路径。可用于排查新版本兼容问题。",
                icon: "doc.badge.gearshape"
            )
            Text(model.governanceFixtureExportStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Toggle(
                "允许读取我接下来手动选择的TOML文件",
                isOn:
                    $model.confirmsGovernanceFixtureExport
            )
            .toggleStyle(.checkbox)
            Button("选择文件并导出结构证据") {
                model.exportGovernanceStructureFixture()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !model.confirmsGovernanceFixtureExport
            )
        }
    }

    private var legacyBackupView: some View {
        diagnosticScroll {
            diagnosticIntro(
                title: "旧明文备份扫描",
                detail:
                    "检查旧切换工具留下的备份是否含中转密钥。只显示数量和风险，不显示密钥或配置正文。",
                icon: "archivebox.fill"
            )
            Button("选择旧备份文件夹") {
                legacyBackupImporterOpen = true
            }
            .buttonStyle(.borderedProminent)

            if let report = model.legacyBackupRiskReport {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "已检查 \(report.scannedFileCount) 个文件"
                    )
                    .font(.headline)
                    Text(
                        "发现风险 \(report.riskFileCount) 个 · 最近修改：\(report.latestModifiedAt?.formatted() ?? "未知")"
                    )
                    .font(.callout)
                    .foregroundStyle(
                        report.plaintextRiskRemains
                            ? Color.orange : Color.secondary
                    )
                }
                .padding(13)
                .background(
                    .orange.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 11)
                )

                if report.plaintextRiskRemains {
                    Toggle(
                        "我确认创建加密归档；原文件不会删除",
                        isOn:
                            $model.confirmsEncryptLegacyBackups
                    )
                    .toggleStyle(.checkbox)
                    Button("创建加密归档") {
                        model.archiveLegacyBackups()
                    }
                    .disabled(
                        !model.confirmsEncryptLegacyBackups
                    )
                }
            }

            Text(model.legacyBackupRiskStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var transactionDetailView: some View {
        diagnosticScroll {
            diagnosticIntro(
                title: "切换与恢复状态",
                detail:
                    "这里显示最近操作进行到哪一步；不显示配置正文或中转密钥。",
                icon: "arrow.triangle.2.circlepath.circle.fill"
            )

            BeginnerUnifiedReadinessCard(
                decision: unifiedReadinessDecision,
                accessibilityIdentifier: "diagnostics.recovery.readiness",
                actionEnabled: unifiedReadinessActionEnabled,
                perform: performUnifiedReadinessAction
            )

            VStack(alignment: .leading, spacing: 7) {
                transactionRow(
                    "当前配置目标",
                    accessModel.currentDisplayName
                )
                transactionRow(
                    "配置目标",
                    accessModel.currentEndpointHost
                        ?? "官方模式未声明中转地址"
                )
                transactionRow(
                    "最小请求验证地址",
                    beginnerEndpointHost(
                        accessModel.verifiedEndpointHost
                    ) ?? "尚未验证"
                )
                transactionRow(
                    "连接检测",
                    accessModel
                        .currentConnectionVerificationSummary
                )
                transactionRow(
                    "真实任务验证",
                    accessModel.agentLoopVerificationSummary
                )
                transactionRow(
                    "确定性安全修复",
                    accessModel.deterministicRepairPreviewSummary
                )
                transactionRow(
                    "任务Provider",
                    accessModel.currentSessionProviderCheckText
                )
                transactionRow(
                    "Codex运行态",
                    accessModel.currentRuntimeFreshnessText
                )
                transactionRow(
                    "当前状态",
                    accessModel.status
                )
                transactionRow(
                    "配置结果",
                    accessModel.configurationOutcome
                )
                transactionRow(
                    "会话结果",
                    accessModel.sessionOutcome
                )
                transactionRow(
                    "运行构建",
                    accessModel.runningBuildDiagnosticSummary
                )
                transactionRow(
                    "旧切换记录",
                    model.realSwitchPhase?.rawValue
                        ?? "没有进行中的旧事务"
                )
                transactionRow(
                    "历史会话同步",
                    model.sessionSyncPhase?.rawValue
                        ?? model.sessionSyncStatus
                )
                if let stage =
                    accessModel.recoveryFailureStageText {
                    transactionRow("未完成步骤", stage)
                }
                if let nextAction =
                    accessModel.recoveryNextAction {
                    transactionRow("建议下一步", nextAction)
                }
            }
            .padding(13)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11)
            )

            if let warning =
                accessModel.currentConnectionWarning {
                Label(
                    warning,
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if let connectionError =
                accessModel.currentConnectionCheckError {
                Label(
                    connectionError,
                    systemImage: "xmark.octagon.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
            }

            if let error = accessModel.errorMessage {
                Label(
                    BeginnerText.friendly(error),
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "错误不会锁死全部入口："
                        + accessModel.cutoverRecoverySummary,
                    systemImage: "lock.open"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("这些都是真窗口；没做出来的功能，不会在这里硬提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("编辑当前候选") {
                    openAccessSection(.switchMode)
                }
                .buttonStyle(.bordered)
                Button("打开扩展能力") {
                    openSettingsSection(.capabilities)
                }
                .buttonStyle(.bordered)
                Button("打开配置体检") {
                    tool = .health
                }
                .buttonStyle(.bordered)
                Button("打开使用说明") {
                    openSettingsSection(.guide)
                }
                .buttonStyle(.bordered)
            }

            if accessModel.hasExecutableRecoveryAction,
               accessModel.recoveryProtectsNewSessions {
                Label(
                    "修复前会保护切换后新增的历史会话，不会用旧索引覆盖新会话。",
                    systemImage: "shield.checkered"
                )
                .font(.callout)
                .foregroundStyle(.blue)
            }

            DisclosureGroup("其他检测与恢复操作") {
                VStack(alignment: .leading, spacing: 10) {
                    Button(
                        accessModel.isCheckingCurrentConnection
                            ? "正在检测连接" : "检测连接"
                    ) {
                        confirmsBasicConnection = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !accessModel.canCheckCurrentConnection
                    )
                    Button("重新读取状态") {
                        accessModel.refresh()
                    }
                    .disabled(
                        accessModel.isWorking
                            || accessModel.isRefreshing
                            || accessModel
                                .isCheckingCurrentConnection
                            || accessModel.isVerifyingAgentLoop
                    )
                    if accessModel.hasCurrentBasicConnectionEvidence,
                       !accessModel.isAgentLoopVerified,
                       !accessModel.hasPendingRecovery {
                        Button("验证真实任务") {
                            confirmsRealAgentLoop = true
                        }
                        .disabled(
                            !accessModel.canVerifyRealAgentLoop
                        )
                    }
                    if accessModel.hasExecutableRecoveryAction {
                        Button("查看修复预览") {
                            selectedRepairPreview =
                                accessModel.recoveryRepairPreview
                        }
                        .disabled(
                            !accessModel.canRunDeterministicRepair
                        )
                    } else if accessModel.recoveryDisposition
                        == .decisionRequired {
                        Button("验证并继续使用当前轨") {
                            accessModel
                                .acceptCurrentRelayAndEndPendingSwitch()
                        }
                        .disabled(
                            !accessModel
                                .canAcceptCurrentRelayAndEndPendingSwitch
                        )
                        Button("保留当前设置并结束上次操作") {
                            accessModel.keepCurrentStateAndEndPendingSwitch()
                        }
                        .disabled(
                            !accessModel
                                .canKeepCurrentStateAndEndPendingSwitch
                        )
                    }
                }
            }
            .accessibilityIdentifier("diagnostics.recovery.other-actions")
            Text(V015PassiveStateReadBoundary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("查看技术详情") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(accessModel.recoveryDiagnosticSummary)
                    Button("复制脱敏摘要") {
                        accessModel.copyRecoveryDiagnosticSummary()
                    }
                    .accessibilityLabel("复制脱敏诊断摘要")
                    .accessibilityHint("复制不含路径、密钥或会话正文的诊断字段")
                    Button("导出当前配置快照") {
                        accessModel.exportManagedConfigurationSnapshot()
                    }
                    Text(
                        "切换记录：\(model.realSwitchStatus)"
                    )
                    Text(
                        "会话记录：\(model.sessionSyncStatus)"
                    )
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 8)
            }
            .accessibilityLabel("查看技术详情")
            .accessibilityHint("展开后可复制脱敏摘要或导出配置快照")
        }
    }

    private var unifiedReadinessDecision:
        V016AccessReadinessDecision {
        V016AccessReadinessRuntimeResolver.resolve(
            accessModel: accessModel,
            doctorGuidance: model.codexDoctorGuidance,
            codexInstalled:
                CodexApplicationLocator.applicationURL() != nil
        )
    }

    private var unifiedReadinessActionEnabled: Bool {
        guard let action =
                unifiedReadinessDecision.primaryAction else {
            return false
        }
        switch action {
        case .previewRecovery:
            return accessModel.canRunDeterministicRepair
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
            openSettingsSection(.software)
        case .previewRecovery:
            selectedRepairPreview =
                accessModel.recoveryRepairPreview
        case .keepCurrentConfiguration:
            accessModel.keepCurrentConfigurationAndEndPendingSwitch()
        case .openDiagnostics:
            if tool == .transactions, let preview = accessModel.recoveryRepairPreview {
                selectedRepairPreview = preview
            } else {
                tool = .transactions
            }
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
            tool = .health
        case .updateCodex:
            openSettingsSection(.software)
        }
    }

    private func performFailurePrimaryAction(
        _ action: V013FailurePrimaryAction
    ) {
        switch action {
        case .reviewRelayProfile, .reviewQuota,
                .reviewDNSAndAddress:
            openAccessSection(.switchMode)
        case .retryLater:
            confirmsBasicConnection = true
        case .refreshState:
            accessModel.refresh()
        case .openCodexLogin:
            codexLaunchError =
                BeginnerCodexLauncher.openInstalled()
        case .updateAssistant, .restartAssistant:
            openSettingsSection(.guide)
        case .reviewTLSAndProxy, .checkNetwork,
                .reviewToolPermission,
                .reviewResponsesCompatibility,
                .openAdvancedDiagnostics:
            tool = .health
        }
    }

    private func exportRedactedSupportBundle() {
        let panel = NSSavePanel()
        panel.title = "保存脱敏求助包"
        panel.nameFieldStringValue =
            "AI接入助手-脱敏求助包-Build\(AppReleaseMetadata.build).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK,
              let destinationURL = panel.url else {
            supportBundleExportStatus =
                "已取消导出；未写入文件。"
            return
        }
        do {
            try accessModel.exportRedactedSupportBundle(
                readiness: unifiedReadinessDecision,
                to: destinationURL,
                userConfirmed: true
            )
            supportBundleExportStatus =
                "已保存脱敏求助包；未联网、未上传。"
        } catch {
            supportBundleExportStatus =
                "导出失败；目标位置未留下半成品。"
        }
    }

    private func diagnosticScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func diagnosticIntro(
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.title3.bold())
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func transactionRow(
        _ title: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 105, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}
