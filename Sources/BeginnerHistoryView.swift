import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
private enum BeginnerHistoryOrganization:
    String, CaseIterable, Identifiable {
    case recent = "最近活动"
    case workspaces = "按工作区"
    case recovery = "恢复状态"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .recent:
            return "按最后更新时间排列本机任务；时间未知的任务放在最后。"
        case .workspaces:
            return "按工作目录汇总任务数量、归档数量和最近活动。"
        case .recovery:
            return "只看未完成操作、恢复点、备份与导入工具。"
        }
    }
}
struct BeginnerHistoryView: View {
    @ObservedObject var model: V011HistoryModel
    @ObservedObject var accessModel: V011AccessModel
    @State private var searchText = ""
    @State private var workspaceSearchPath: String?
    @State private var showAllWorkspaces = false
    @State private var historyOrganization:
        BeginnerHistoryOrganization = .recent
    @State private var workspaceLabelPath: String?
    @State private var workspaceLabelDraft = ""
    @State private var workspaceActionStatus: String?
    @State private var workspaceActionError: String?
    @State private var repairConfirmationOpen = false
    @State private var recoveryConfirmationOpen = false
    @State private var cleanupConfirmationOpen = false
    @State private var repairPlan: B68RecoveryPlanBundle?
    @State private var recoveryPlan: B68RecoveryPlanBundle?
    @State private var cleanupPlan: B68RecoveryPlanBundle?
    @State private var safeModeKeepCurrent = false
    @State private var localError: String?
    @State private var copyTarget: V011SessionRow?
    @StateObject private var continuationCopy = SessionContinuationCopyController()
    @State private var timelineCopyStatus: String?
    @State private var externalImportTask: Task<Void, Never>?
    @State private var externalImportSource: URL?
    @State private var externalImportConfirmationOpen = false
    @State private var expandedTitleIDs: Set<String> = []
    @FocusState private var historySearchFocused: Bool
    private var currentProviderID: String? {
        guard let live = accessModel.liveState else {
            return nil
        }
        switch live.mode {
        case .official:
            return "openai"
        case let .relay(providerID):
            return providerID
        }
    }
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    private var workspaceLabelEditorPresented: Binding<Bool> {
        Binding(
            get: { workspaceLabelPath != nil },
            set: { presented in
                if !presented {
                    closeWorkspaceLabelEditor()
                }
            }
        )
    }
    private func beginWorkspaceLabelEdit(_ path: String) {
        model.clearWorkspacePreferenceError()
        workspaceLabelPath = path
        workspaceLabelDraft = model.workspaceLabel(for: path) ?? ""
    }
    private func closeWorkspaceLabelEditor() {
        workspaceLabelPath = nil
        workspaceLabelDraft = ""
        model.clearWorkspacePreferenceError()
    }
    private func saveWorkspaceLabel() {
        guard let path = workspaceLabelPath else { return }
        if model.setWorkspaceLabel(workspaceLabelDraft, for: path) {
            closeWorkspaceLabelEditor()
        }
    }
    private var displayedSessions: [V011SessionRow] {
        model.searchQuery.isEmpty
            ? model.recentRows : model.searchRows
    }
    private var historyNeedsAttention: Bool {
        accessModel.hasPendingRecovery
            || model.recoveryNeedsAttention
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("历史会话")
                        .font(
                            .system(
                                size: 28,
                                weight: .bold
                            )
                        )
                    Text(
                        "每个顶层对话只显示一条，内部子会话自动收起；最新会话排在前面。"
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        "普通读取只分页查询任务列表，不导入、不复制会话正文；只有切轨或你主动点“让全部会话在当前模式可见”时，才核对并调整可见标记。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        historySummaryCards
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        historySummaryCards
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("历史会话概览")
                Picker(
                    "历史任务组织方式",
                    selection: $historyOrganization
                ) {
                    ForEach(BeginnerHistoryOrganization.allCases) {
                        section in
                        Text(
                            section == .recovery
                                && historyNeedsAttention
                                ? "恢复状态 · 需处理"
                                : section.rawValue
                        )
                        .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .focusable()
                .accessibilityHint(
                    "使用左右方向键切换最近活动、按工作区和恢复状态"
                )
                .accessibilityIdentifier(
                    "build107.history-organization"
                )
                Text(historyOrganization.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if historyOrganization == .recovery
                    || historyNeedsAttention {
                    if historyOrganization == .recovery
                        && !historyNeedsAttention {
                        ContentUnavailableView(
                            "没有待处理的恢复操作",
                            systemImage: "checkmark.shield.fill",
                            description: Text(
                                "当前没有异常；备份和导入工具仍可使用。"
                            )
                        )
                    }
                    if accessModel.hasPendingRecovery {
                    Label(
                        accessModel.recoveryDisposition
                            == .decisionRequired
                            ? "上次切换没有完成，当前设置已保留。请回到“开始”验证并继续使用当前轨；无法验证时可保留当前设置并结束上次操作。"
                            : "上次切换未完成。请先回到“开始”一键恢复。",
                        systemImage:
                            "exclamationmark.octagon.fill"
                    )
                    .foregroundStyle(.red)
                    }
                    let recoverySnapshot = model.recovery
                    switch recoverySnapshot.warningVisibility {
                case .hidden:
                    EmptyView()
                case .informational:
                    Label(
                        model.recoveryInformationalText,
                        systemImage:
                            "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.callout)
                case .actionable:
                    Label(
                        model.recoveryActionableText,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                case .blocking:
                    if safeModeKeepCurrent {
                        Label(
                            "已保留当前状态。恢复记录问题不影响当前会话。",
                            systemImage:
                                "checkmark.shield.fill"
                        )
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    } else {
                        VStack(
                            alignment: .leading,
                            spacing: 8
                        ) {
                            Label(
                                Build65RecoveryControlLabel
                                    .safeModeStatus.rawValue
                                    + "助手已停止自动重试，当前会话保持不变。",
                                systemImage:
                                    "exclamationmark.octagon.fill"
                            )
                            .foregroundStyle(.red)
                            .font(.callout)
                            HStack(spacing: 8) {
                                Button("保留当前状态") {
                                    safeModeKeepCurrent = true
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier(
                                    "build65.safe-mode-keep"
                                )
                                Button("稍后重试") {
                                    model
                                        .refreshRecoveryAvailability()
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier(
                                    "build65.safe-mode-retry"
                                )
                            }
                            if let code =
                                recoverySnapshot.failureCode {
                                Text(
                                    "问题码：\(code)；导出完整诊断请到高级诊断。"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if recoverySnapshot.operationState == .running {
                    Label(
                        Build65RecoveryControlLabel.runningStatus
                            .rawValue,
                        systemImage: "clock.fill"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .accessibilityLabel(
                        Build65RecoveryControlLabel.runningStatus
                            .rawValue
                    )
                }
                HStack {
                    Button(
                        Build65RecoveryControlLabel.repairButton
                            .rawValue
                    ) {
                        prepareRecoveryPlan(.retry) {
                            repairPlan = $0
                            repairConfirmationOpen = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(
                        Build65RecoveryControlLabel.repairButton
                            .rawValue
                    )
                    .accessibilityIdentifier(
                        "build65.repair-button"
                    )
                    .disabled(
                        currentProviderID == nil
                            || model.isWorking
                            || recoverySnapshot.operationState
                                == .recoverable
                            || recoverySnapshot.operationState
                                == .failed
                            || recoverySnapshot.operationState
                                == .safeMode
                            || recoverySnapshot.operationState
                                == .running
                            || accessModel.hasPendingRecovery
                            || accessModel.isWorking
                            || accessModel.isRefreshing
                            || accessModel
                                .isCheckingCurrentConnection
                    )
                    if model.canCleanupRecoveryRecord {
                        Button(
                            Build65RecoveryControlLabel.cleanupButton
                                .rawValue
                        ) {
                            prepareRecoveryPlan(.cleanup) {
                                cleanupPlan = $0
                                cleanupConfirmationOpen = true
                            }
                        }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier(
                            "build65.cleanup-button"
                        )
                    }
                    Button(
                        Build65RecoveryControlLabel.restoreButton
                            .rawValue
                    ) {
                        prepareRecoveryPlan(.restore) {
                            recoveryPlan = $0
                            recoveryConfirmationOpen = true
                        }
                    }
                    .accessibilityIdentifier(
                        "build65.restore-button"
                    )
                    .disabled(
                        model.isWorking
                            || recoverySnapshot.operationState
                                != .recoverable
                            || accessModel.isWorking
                            || accessModel.isRefreshing
                            || accessModel
                                .isCheckingCurrentConnection
                    )
                    Button("重新检查") {
                        accessModel.refresh()
                        model.refreshRecoveryAvailability()
                        model.loadFirstPage(
                            provider: currentProviderID,
                            force: true
                        )
                    }
                    .accessibilityLabel(
                        Build65RecoveryControlLabel.recheckButton
                            .rawValue
                    )
                    .accessibilityIdentifier(
                        "build65.recheck-button"
                    )
                    .disabled(
                        model.isLoading
                            || model.isWorking
                            || accessModel.isWorking
                            || accessModel.isRefreshing
                            || accessModel
                                .isCheckingCurrentConnection
                    )
                    Spacer()
                    if model.isLoading || model.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                HStack(spacing: 10) {
                    Button(
                        model.operation == .sessionVaultExport
                            ? "正在导出…" : "导出会话保险箱"
                    ) {
                        chooseSessionVaultDestination()
                    }
                    .accessibilityIdentifier(
                        "build77.session-vault-export"
                    )
                    .disabled(model.isWorking)
                    Text(
                        "生成可校验的本机备份；不包含登录、配置、密钥或原始任务数据库。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if model.operation == .sessionVaultExport {
                    ProgressView(model.sessionVaultStatus)
                } else if model.sessionVaultStatus
                    != "尚未导出会话保险箱" {
                    Label(
                        model.sessionVaultStatus,
                        systemImage: "externaldrive.badge.checkmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button(
                        model.isInspectingExternalImport
                            ? "正在预检…" : "预检外部会话"
                    ) {
                        chooseExternalImportFolder()
                    }
                    .accessibilityIdentifier(
                        "build74.external-import-preflight"
                    )
                    .disabled(
                        model.isInspectingExternalImport
                            || model.isWorking
                    )
                    Text(
                        "先只读检查外部备份中的会话文件、重复任务和损坏文件；没有阻断时才会开放整批导入。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if model.isInspectingExternalImport {
                    ProgressView(model.externalImportStatus)
                } else if let preview = model.externalImportPreview {
                    externalImportPreviewCard(preview)
                }
                if model.isWorking,
                   model.progressTotal > 0 {
                    ProgressView(
                        value: Double(model.progressCurrent),
                        total: Double(model.progressTotal)
                    )
                }
                Text(BeginnerText.friendly(model.status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    recoveryAuditTimelineCard(recoverySnapshot)
                }
                if continuationCopy.isCopying {
                    Label(
                        "正在读取这一个会话的可见内容…",
                        systemImage: "doc.on.clipboard"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Button("取消续接包读取") { continuationCopy.cancel() }
                        .accessibilityIdentifier("history.cancel-continuation-copy")
                } else if let copyStatus = continuationCopy.status {
                    Label(
                        copyStatus,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                }
                if let error = continuationCopy.errorMessage {
                    Label(BeginnerText.friendly(error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if historyOrganization == .workspaces {
                    workspaceOverviewCard
                } else if historyOrganization == .recent,
                          !model.rows.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            historySearchControls
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            historySearchControls
                        }
                    }
                    Text(
                        "只查询本机任务标题、时间和工作目录；不联网，不读取对话正文。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let workspaceSearchPath,
                       workspaceSearchPath == model.searchQuery {
                        Label(
                            "正在精确查看工作区："
                                + workspaceSearchPath,
                            systemImage:
                                "folder.badge.magnifyingglass"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    if model.isSearching {
                        ProgressView(model.searchStatus)
                    } else if !model.searchQuery.isEmpty {
                        Text(model.searchStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let searchError = model.searchError {
                        Label(
                            BeginnerText.friendly(searchError),
                            systemImage:
                                "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                    }

                    if !model.searchQuery.isEmpty
                        && displayedSessions.isEmpty
                        && !model.isSearching {
                        ContentUnavailableView(
                            "没有匹配的历史会话",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "换一个标题、任务编号、接入方式或工作目录再试。"
                            )
                        )
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(displayedSessions) {
                                sessionCard($0)
                            }
                        }
                    }

                    let showingSearch = !model.searchQuery.isEmpty
                    let hasMore = showingSearch
                        ? model.searchHasMore : model.hasMore
                    let loading = showingSearch
                        ? model.isSearching : model.isLoading
                    if hasMore {
                        Button(
                            loading
                                ? "正在读取…"
                                : "再显示50个"
                        ) {
                            if showingSearch {
                                model.loadMoreSearch()
                            } else {
                                model.loadMore()
                            }
                        }
                        .disabled(loading)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .center
                        )
                    } else {
                        Text(
                            "已显示\(displayedSessions.count)个会话"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .center
                        )
                    }
                } else if historyOrganization == .recent,
                          model.isLoading {
                    ContentUnavailableView(
                        "正在读取历史会话",
                        systemImage:
                            "bubble.left.and.bubble.right"
                    )
                } else if historyOrganization == .recent {
                    ContentUnavailableView(
                        "没有找到历史会话",
                        systemImage:
                            "bubble.left.and.bubble.right",
                        description: Text(
                            "Codex产生会话后，这里会自动显示。"
                        )
                    )
                }

                if let localError {
                    Label(
                        BeginnerText.friendly(localError),
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
                if let error = model.errorMessage {
                    Label(
                        BeginnerText.friendly(error),
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
                if let error = model.externalImportError {
                    Label(
                        BeginnerText.friendly(error),
                        systemImage: "xmark.octagon.fill"
                    )
                    .foregroundStyle(.red)
                }
                if let error = model.sessionVaultError {
                    Label(
                        BeginnerText.friendly(error),
                        systemImage: "xmark.octagon.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            .padding(28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            accessModel.preparePresentation()
            model.refreshRecoveryAvailability()
            model.loadFirstPage(
                provider: currentProviderID
            )
            model.loadWorkspaceOverview()
        }
        .onChange(of: currentProviderID) { _, provider in
            clearMetadataSearch()
            model.loadFirstPage(
                provider: provider,
                force: true
            )
        }
        .onDisappear {
            model.cancelListing()
            model.cancelWorkspaceListing()
            externalImportTask?.cancel()
            externalImportTask = nil
            continuationCopy.cancel()
        }
        .confirmationDialog(
            "导入外部会话？",
            isPresented: $externalImportConfirmationOpen
        ) {
            Button(
                "确认导入 \(model.externalImportPreview?.importableSessionCount ?? 0) 个"
            ) {
                guard let source = externalImportSource else {
                    localError = "外部会话目录已失效，请重新预检"
                    return
                }
                model.importExternalSessions(at: source)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "导入会把通过预检的会话记录写入当前Codex历史；已有任务一律拒绝，不覆盖原会话。任一文件失败时整批回滚。"
            )
        }
        .confirmationDialog(
            "让全部会话在当前模式可见？",
            isPresented: $repairConfirmationOpen
        ) {
            Button("确认并开始") {
                executeRecoveryPlan(repairPlan) {
                    model.repairToCurrentMode(
                        provider: currentProviderID
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(recoveryPlanSummary(repairPlan))
        }
        .confirmationDialog(
            "恢复上次历史会话操作？",
            isPresented: $recoveryConfirmationOpen
        ) {
            Button("确认恢复") {
                executeRecoveryPlan(recoveryPlan) {
                    model.restoreLastOperation()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(recoveryPlanSummary(recoveryPlan))
        }
        .confirmationDialog(
            "整理旧完成记录？",
            isPresented: $cleanupConfirmationOpen
        ) {
            Button("确认整理") {
                executeRecoveryPlan(cleanupPlan) {
                    model.cleanupStaleRecoveryRecord()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(recoveryPlanSummary(cleanupPlan))
        }
        .confirmationDialog(
            "生成这一个会话的精简续接包？",
            isPresented: Binding(
                get: { copyTarget != nil },
                set: { shown in
                    if !shown {
                        copyTarget = nil
                    }
                }
            )
        ) {
            Button("本次允许并复制续接包") {
                guard let target = copyTarget else {
                    return
                }
                copyTarget = nil
                copyVisibleContent(target)
            }
            Button("取消", role: .cancel) {
                copyTarget = nil
            }
        } message: {
            Text(
                "只读取这一个会话中用户和助手可见的文字；保留首条目标和最近上下文，最多12条、单条2000字、正文合计12000字。隐藏思考、私有状态、附件和凭据不会复制。"
            )
        }
    }

    private var historyState: String {
        if model.isWorking {
            return "处理中"
        }
        if model.isLoading && model.rows.isEmpty {
            return "读取中"
        }
        guard let visible = model.visibleTotal else {
            return currentProviderID == nil
                ? "确认中" : "未核对"
        }
        return visible < model.total
            ? "需要找回"
            : "全部可见"
    }

    private func externalImportPreviewCard(
        _ preview: V011ExternalSessionImportPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "外部会话只读预检",
                    systemImage: "tray.and.arrow.down"
                )
                .font(.headline)
                Spacer()
                Text(preview.sourceFolderName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "会话文件 \(preview.jsonlFileCount) 个 · 可导入 \(preview.importableSessionCount) 个 · 已有任务 \(preview.existingThreadConflictCount) 个 · 外部重复 \(preview.duplicateSourceThreadCount) 个 · 损坏文件 \(preview.invalidFileCount) 个"
            )
            .font(.callout)
            if preview.vaultIntegrityVerified {
                Label(
                    "备份完整性校验通过：活跃 \(preview.vaultActiveSessionCount) 个，归档 \(preview.vaultArchivedSessionCount) 个。校验只证明文件未损坏，不证明来源身份。",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
            Label(
                preview.readyForImport
                    ? "预检未发现阻断；可以整批导入，现有任务不会被覆盖。"
                    : "存在阻断或没有候选；不会提供导入动作。",
                systemImage: preview.readyForImport
                    ? "checkmark.shield" : "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(
                preview.readyForImport
                    ? Color.green : Color.orange
            )
            if preview.readyForImport {
                Button(
                    "导入 \(preview.importableSessionCount) 个外部会话"
                ) {
                    externalImportConfirmationOpen = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.isWorking
                        || externalImportSource == nil
                )
                .accessibilityIdentifier(
                    "build73.external-import-confirm"
                )
            }
            ForEach(preview.issues.prefix(5)) { issue in
                Text("• \(issue.relativePath)：\(issue.detail)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if preview.issues.count > 5 {
                Text("另有\(preview.issues.count - 5)项阻断未展开")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func chooseExternalImportFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择外部 Codex 会话备份文件夹"
        panel.message =
            "只会先做只读预检；确认导入前不会写入当前 Codex 历史。"
        panel.prompt = "只读预检"
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK,
              let root = panel.url else {
            return
        }

        localError = nil
        externalImportSource = root
        externalImportTask?.cancel()
        externalImportTask = Task {
            let accessed = root
                .startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    root.stopAccessingSecurityScopedResource()
                }
                externalImportTask = nil
            }
            await model.preflightExternalSessionImport(
                at: root
            )
        }
    }

    private func chooseSessionVaultDestination() {
        let panel = NSSavePanel()
        panel.title = "导出 Codex 会话保险箱"
        panel.message =
            "只复制会话记录并生成完整性清单；登录、配置、密钥和原始任务数据库不会导出。"
        panel.prompt = "导出并校验"
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue =
            "Codex会话备份-\(formatter.string(from: Date())).codexbackup"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(
            filenameExtension: "codexbackup"
        ) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK,
              let destination = panel.url else {
            return
        }
        localError = nil
        model.exportSessionVault(to: destination)
    }

    private func recoveryAuditTimelineCard(
        _ snapshot: V011HistoryRecoverySnapshot
    ) -> some View {
        let timeline = B68RecoveryAuditTimelineFactory.make([
            .init(
                source: .pointer,
                timestamp: snapshot.observedAt,
                stateCode: snapshot.pointerState.rawValue,
                reference: snapshot.pointerHash.map {
                    String($0.prefix(12))
                }
            ),
            .init(
                source: .journal,
                timestamp: snapshot.observedAt,
                stateCode: snapshot.journalState.rawValue,
                reference: snapshot.journalHash.map {
                    String($0.prefix(12))
                }
            ),
            .init(
                source: .receipt,
                timestamp: snapshot.observedAt,
                stateCode: snapshot.operationState.rawValue,
                reference: snapshot.lastSuccessfulOperationID.map {
                    String($0.prefix(12))
                }
            ),
            .init(
                source: .diagnostic,
                timestamp: snapshot.observedAt,
                stateCode: snapshot.failureCode ?? "none",
                reference: snapshot.failureStage
            ),
        ])
        return DisclosureGroup("恢复记录详情") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(timeline.events) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(recoverySourceName(event.source))
                            .font(.caption.bold())
                        Text(event.stateCode)
                            .font(.caption)
                        Spacer()
                        Text(recoveryOrderName(event.order))
                            .font(.caption2)
                            .foregroundStyle(
                                event.order == .conflict
                                    ? .red : .secondary
                            )
                    }
                }
                Text("“顺序待确认”表示无法证明先后；“记录冲突”表示同一来源内容不一致。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("复制脱敏时间线摘要") {
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(
                        timeline.copyText,
                        forType: .string
                    )
                    timelineCopyStatus = copied
                        ? "已复制脱敏摘要"
                        : "复制失败"
                }
                .accessibilityIdentifier(
                    "build68.copy-recovery-timeline"
                )
                if let timelineCopyStatus {
                    Text(timelineCopyStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func prepareRecoveryPlan(
        _ operation: B68RecoveryOperation,
        present: (B68RecoveryPlanBundle) -> Void
    ) {
        do {
            let bundle = try model.makeRecoveryPlan(
                operation: operation
            )
            guard bundle.preflight.isReady else {
                localError = "操作前检查未通过："
                    + bundle.preflight.code.rawValue
                return
            }
            localError = nil
            present(bundle)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func executeRecoveryPlan(
        _ bundle: B68RecoveryPlanBundle?,
        action: () -> Void
    ) {
        guard let plan = bundle?.preflight.plan else {
            localError = "操作预览已失效，请重新检查。"
            return
        }
        let decision = model.validateRecoveryPlan(plan)
        guard decision.permitted else {
            localError = "操作预览已失效："
                + decision.code.rawValue
                + "。请重新检查。"
            return
        }
        localError = nil
        action()
    }

    private func recoveryPlanSummary(
        _ bundle: B68RecoveryPlanBundle?
    ) -> String {
        guard let preview = bundle?.preview else {
            return "操作预览已失效，请重新检查。"
        }
        let writes = preview.plan.managedWriteSet.joined(
            separator: "、"
        )
        let phases = preview.phases.joined(separator: " → ")
        let space = ByteCountFormatter.string(
            fromByteCount: preview.estimatedBytes,
            countStyle: .file
        )
        let recoveryPoint = preview.recoveryPoint == nil
            ? "无" : "有"
        let irreversible = preview.irreversibleItems.isEmpty
            ? "无" : preview.irreversibleItems.joined(separator: "、")
        return "预计修改 \(preview.objectCount) 个对象；写入："
            + "\(writes)；空间：\(space)；阶段：\(phases)；"
            + "恢复点：\(recoveryPoint)；不可逆项：\(irreversible)。"
    }

    @ViewBuilder
    private var historySummaryCards: some View {
        summaryCard(
            "全部会话",
            model.isLoading && model.rows.isEmpty
                ? "…" : String(model.total)
        )
        summaryCard(
            "当前可见",
            model.visibleTotal.map(String.init) ?? "—"
        )
        summaryCard("状态", historyState)
    }

    @ViewBuilder
    private var historySearchControls: some View {
        TextField(
            "搜索标题、任务编号、接入方式或工作目录",
            text: $searchText
        )
        .textFieldStyle(.roundedBorder)
        .focused($historySearchFocused)
        .accessibilityLabel("搜索本机历史会话")
        .accessibilityHint("输入条件后按回车开始搜索")
        .accessibilityIdentifier("build108.history-search")
        .onSubmit {
            searchAllMetadata()
        }
        Button("搜索") {
            searchAllMetadata()
        }
        .disabled(
            trimmedSearchText.isEmpty || model.isSearching
        )
        if !model.searchQuery.isEmpty {
            Button("清除") {
                clearMetadataSearch()
                historySearchFocused = true
            }
        }
    }

    private func recoverySourceName(
        _ source: B68RecoveryAuditSource
    ) -> String {
        switch source {
        case .pointer:
            return "当前恢复记录"
        case .journal:
            return "操作过程记录"
        case .receipt:
            return "最近完成记录"
        case .diagnostic:
            return "问题诊断"
        }
    }

    private func recoveryOrderName(
        _ order: B68RecoveryAuditOrder
    ) -> String {
        switch order {
        case .known:
            return "顺序已确认"
        case .unknown:
            return "顺序待确认"
        case .conflict:
            return "记录冲突"
        }
    }

    private func summaryCard(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
    }

    private var workspaceOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "工作区总览",
                    systemImage: "folder.badge.gearshape"
                )
                .font(.headline)
                Spacer()
                Text(
                    model.isLoadingWorkspaces
                        && model.workspaceRows.isEmpty
                        ? "读取中"
                        : "\(model.workspaceTotal)个"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(
                "按本机任务记录中的工作目录分组；最多收藏20个，重开后直接显示。收藏只保存在AI接入助手本机偏好中；收藏名称最多40字，真实路径始终显示。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.isLoadingWorkspaces
                && model.workspaceRows.isEmpty {
                ProgressView(model.workspaceStatus)
            } else if model.workspaceRows.isEmpty {
                ContentUnavailableView(
                    "没有可分组的工作区",
                    systemImage: "folder",
                    description: Text(
                        model.workspaceStatus
                    )
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(
                        model.orderedWorkspaceRows.prefix(
                            showAllWorkspaces
                                ? model.workspaceRows.count : 6
                        )
                    ) { workspace in
                        workspaceOverviewRow(workspace)
                    }
                }
                if model.workspaceRows.count > 6 {
                    Button(
                        showAllWorkspaces
                            ? "收起工作区" : "显示本页全部工作区"
                    ) {
                        showAllWorkspaces.toggle()
                    }
                }
                if showAllWorkspaces
                    && model.workspaceHasMore {
                    Button(
                        model.isLoadingWorkspaces
                            ? "正在读取…" : "再显示50个工作区"
                    ) {
                        model.loadMoreWorkspaces()
                    }
                    .disabled(model.isLoadingWorkspaces)
                }
            }
            if let workspaceError = model.workspaceError {
                Label(
                    BeginnerText.friendly(workspaceError),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            if let preferenceError =
                model.workspacePreferenceError {
                Label(
                    BeginnerText.friendly(preferenceError),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            if let workspaceActionStatus {
                Label(
                    workspaceActionStatus,
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
            if let workspaceActionError {
                Label(
                    BeginnerText.friendly(workspaceActionError),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityIdentifier(
            "build81.workspace-overview"
        )
        .sheet(isPresented: workspaceLabelEditorPresented) {
            workspaceLabelEditor
        }
    }

    private func workspaceOverviewRow(
        _ workspace: V011WorkspaceRow
    ) -> some View {
        let workspaceLabel = model.workspaceLabel(
            for: workspace.path
        )
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                workspaceOverviewDetails(
                    workspace,
                    workspaceLabel: workspaceLabel
                )
                Spacer()
                HStack(spacing: 8) {
                    workspaceOverviewActions(
                        workspace,
                        workspaceLabel: workspaceLabel
                    )
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                workspaceOverviewDetails(
                    workspace,
                    workspaceLabel: workspaceLabel
                )
                HStack(spacing: 8) {
                    workspaceOverviewActions(
                        workspace,
                        workspaceLabel: workspaceLabel
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            workspaceLabel.map { "工作区：\($0)" }
                ?? "工作区：\(workspace.path)"
        )
    }

    @ViewBuilder
    private func workspaceOverviewDetails(
        _ workspace: V011WorkspaceRow,
        workspaceLabel: String?
    ) -> some View {
        let pathDisplay = V011HistoryDisplayProjection.workspace(
            workspace.path
        )
        VStack(alignment: .leading, spacing: 3) {
                if let workspaceLabel {
                    Text(workspaceLabel)
                        .font(.callout.weight(.semibold))
                    Text(pathDisplay.summary)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                } else {
                    Text(pathDisplay.summary)
                        .font(.callout.monospaced())
                        .lineLimit(2)
                }
                Group {
                    if workspace.isIndexed {
                        Text(
                            "会话 \(workspace.sessionCount) 个 · "
                                + "已归档 \(workspace.archivedCount) 个 · "
                                + "最近 \(dateText(workspace.latestUpdatedAt))"
                        )
                    } else {
                        Text("收藏路径已保留；本地索引暂无详情")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func workspaceOverviewActions(
        _ workspace: V011WorkspaceRow,
        workspaceLabel: String?
    ) -> some View {
            Button(
                model.isWorkspaceFavorite(workspace.path)
                    ? "取消收藏" : "收藏"
            ) {
                model.toggleWorkspaceFavorite(workspace.path)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(
                "build82.workspace-favorite"
            )
            Button("查看会话") {
                searchWorkspace(workspace.path)
            }
            .disabled(model.isSearching)
            .accessibilityIdentifier(
                "build81.workspace-overview-open"
            )
            Menu("更多") {
                if model.isWorkspaceFavorite(workspace.path) {
                    Button(
                        workspaceLabel == nil
                            ? "设置工作区名称"
                            : "修改工作区名称"
                    ) {
                        beginWorkspaceLabelEdit(workspace.path)
                    }
                    .accessibilityIdentifier(
                        "build84.workspace-label"
                    )
                }
                Button("复制工作区路径") {
                    copyWorkspacePath(workspace.path)
                }
                .accessibilityIdentifier(
                    "build85.workspace-copy-path"
                )
                Button("在访达中打开") {
                    openWorkspaceInFinder(workspace.path)
                }
                .accessibilityIdentifier(
                    "build85.workspace-open-finder"
                )
            }
            .accessibilityIdentifier(
                "build85.workspace-actions"
            )
    }

    @ViewBuilder
    private var workspaceLabelEditor: some View {
        if let path = workspaceLabelPath {
            VStack(alignment: .leading, spacing: 14) {
                Text("收藏工作区名称")
                    .font(.title3.bold())
                Text(
                    "名称只保存在AI接入助手本机偏好中，不修改文件夹。真实路径始终保留。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                TextField(
                    "例如：主项目",
                    text: $workspaceLabelDraft
                )
                .accessibilityIdentifier(
                    "build84.workspace-label-field"
                )
                if let error = model.workspacePreferenceError {
                    Text(BeginnerText.friendly(error))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    if model.workspaceLabel(for: path) != nil {
                        Button("清除名称") {
                            if model.setWorkspaceLabel(nil, for: path) {
                                closeWorkspaceLabelEditor()
                            }
                        }
                    }
                    Spacer()
                    Button("取消", role: .cancel) {
                        closeWorkspaceLabelEditor()
                    }
                    Button("保存") {
                        saveWorkspaceLabel()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(
                        "build84.workspace-label-save"
                    )
                }
            }
            .padding(24)
            .frame(minWidth: 320, idealWidth: 440, maxWidth: 560)
        }
    }

    private func sessionCard(
        _ session: V011SessionRow
    ) -> some View {
        let titleDisplay = V011HistoryDisplayProjection.title(
            session.title
        )
        let titleExpanded = expandedTitleIDs.contains(session.id)
        let workspaceDisplay = V011HistoryDisplayProjection.workspace(
            session.workingDirectory
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(
                    titleExpanded
                        ? titleDisplay.source : titleDisplay.summary
                )
                    .font(.headline)
                    .lineLimit(titleExpanded ? nil : 2)
                Spacer()
                if session.archived {
                    Text("已归档")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            if titleDisplay.isTruncated {
                Button(
                    titleExpanded ? "收起完整标题" : "展开完整标题"
                ) {
                    if titleExpanded {
                        expandedTitleIDs.remove(session.id)
                    } else {
                        expandedTitleIDs.insert(session.id)
                    }
                }
                .buttonStyle(.link)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    sessionMetadata(session)
                }
                VStack(alignment: .leading, spacing: 5) {
                    sessionMetadata(session)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "创建：\(dateText(session.createdAt))  ·  "
                    + "更新：\(dateText(session.updatedAt))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if !session.workingDirectory.isEmpty {
                Label(
                    workspaceDisplay.summary,
                    systemImage: "folder"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sessionActions(session)
                }
                VStack(alignment: .leading, spacing: 8) {
                    sessionActions(session)
                }
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("历史会话：\(session.title)")
    }

    @ViewBuilder
    private func sessionMetadata(
        _ session: V011SessionRow
    ) -> some View {
        Label(
            "来源：" + session.originLabel,
            systemImage: "point.3.connected.trianglepath.dotted"
        )
        Label(
            "当前：" + providerName(session.currentProvider),
            systemImage: "scope"
        )
    }

    @ViewBuilder
    private func sessionActions(
        _ session: V011SessionRow
    ) -> some View {
        Button("在Codex中打开") {
            open(session)
        }
        if !session.workingDirectory
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
            Button("查看此工作区会话") {
                searchWorkspace(session.workingDirectory)
            }
            .disabled(model.isSearching)
            .accessibilityIdentifier(
                "build81.workspace-exact-sessions"
            )
        }
        Menu("更多") {
            Button("生成精简续接包") {
                copyTarget = session
            }
            .disabled(continuationCopy.isCopying)
        }
        .accessibilityIdentifier(
            "build89.session-more-actions"
        )
    }

    private func providerName(_ providerID: String) -> String {
        if providerID == "openai" {
            return "官方"
        }
        if let profile = accessModel.savedProfiles.first(
            where: {
                $0.v011ProviderID == providerID
            }
        ) {
            return profile.name
        }
        if case let .relay(currentID)? =
            accessModel.liveState?.mode,
           currentID == providerID {
            return accessModel.currentDisplayName
        }
        return "历史中转"
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else {
            return "时间未知"
        }
        return date.formatted(
            date: .numeric,
            time: .shortened
        )
    }

    private func searchAllMetadata() {
        workspaceSearchPath = nil
        model.searchMetadata(
            searchText,
            provider: currentProviderID
        )
    }

    private func searchWorkspace(_ path: String) {
        let normalizedPath = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedPath.isEmpty else {
            return
        }
        workspaceSearchPath = normalizedPath
        searchText = normalizedPath
        model.searchWorkspace(
            normalizedPath,
            provider: currentProviderID
        )
    }

    private func normalizedWorkspaceActionPath(
        _ path: String
    ) -> String? {
        let normalizedPath = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedPath.hasPrefix("/"),
              normalizedPath.utf8.count <= 4_096,
              !normalizedPath.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              ) else {
            return nil
        }
        return normalizedPath
    }

    private func copyWorkspacePath(_ path: String) {
        workspaceActionStatus = nil
        workspaceActionError = nil
        guard let normalizedPath =
            normalizedWorkspaceActionPath(path) else {
            workspaceActionError = "工作区路径无效"
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(
            normalizedPath,
            forType: .string
        ) else {
            workspaceActionError = "无法复制工作区路径"
            return
        }
        workspaceActionStatus = "工作区路径已复制"
    }

    private func openWorkspaceInFinder(_ path: String) {
        workspaceActionStatus = nil
        workspaceActionError = nil
        guard let normalizedPath =
            normalizedWorkspaceActionPath(path) else {
            workspaceActionError = "工作区路径无效"
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: normalizedPath,
            isDirectory: &isDirectory
        ) else {
            workspaceActionError = "这个工作区文件夹当前不存在"
            return
        }
        guard isDirectory.boolValue else {
            workspaceActionError = "这个工作区路径当前不是文件夹"
            return
        }
        let url = URL(
            fileURLWithPath: normalizedPath,
            isDirectory: true
        )
        guard NSWorkspace.shared.open(url) else {
            workspaceActionError = "访达没有接受这个工作区路径"
            return
        }
        workspaceActionStatus = "已在访达中打开工作区"
    }

    private func clearMetadataSearch() {
        workspaceSearchPath = nil
        searchText = ""
        model.clearSearch()
    }

    private func open(
        _ session: V011SessionRow
    ) {
        guard let provider = currentProviderID else {
            localError = "还在确认当前模式，请稍后再试"
            return
        }
        guard session.currentProvider == provider else {
            localError =
                "这个会话尚未在当前模式可见，请先点“让全部会话在当前模式可见”"
            return
        }
        guard let url =
            CodexDesktopSessionLink.url(
                threadID: session.id
            ),
              NSWorkspace.shared.open(url) else {
            localError = "Codex没有接受这个会话链接"
            return
        }
        localError = nil
    }

    private func copyVisibleContent(
        _ session: V011SessionRow
    ) {
        localError = nil
        continuationCopy.start {
            try await model.continuationPacket(for: session)
        }
    }
}
