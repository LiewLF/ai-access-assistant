// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

private enum SessionCopyPreviewOutcome {
    case value(SessionCopyPreview)
    case failed(String)
    case cancelled
}

struct SessionCenterView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @State private var searchText = ""
    @State private var selectedSession: SessionOrigin?
    @State private var bodyAuthorization = false
    @State private var copyPreview: SessionCopyPreview?
    @State private var isGeneratingCopyPreview = false
    @State private var copyPreviewTask:
        Task<Void, Never>?
    @State private var localError: String?
    @State private var technicalDetailsOpen = false

    private var sessions: [SessionSyncListItem] {
        model.sessionSyncPreview?.sessions ?? []
    }

    private var visibleSessions: [SessionSyncListItem] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            [
                $0.title,
                $0.threadID,
                $0.model,
                $0.workingDirectory,
                $0.originLabel,
                $0.observedProvider,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("历史会话")
                        .font(.system(size: 28, weight: .bold))
                    Text(
                        "自动扫描全部活跃与归档会话。切轨时同步当前可见标签，原始来源另行加密保存。"
                    )
                    .foregroundStyle(.secondary)
                }

                if model.hasPendingSessionRecovery {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "发现未完成的切换事务",
                            systemImage:
                                "exclamationmark.octagon.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.red)
                        Text(
                            "恢复前不能继续切换。不会自动猜测或跳过失败步骤。"
                        )
                        Toggle(
                            "我确认当前工作已保存",
                            isOn: $model.confirmsWorkSaved
                        )
                        .toggleStyle(.checkbox)
                        Button("一键恢复") {
                            model
                                .recoverPendingSessionTransaction()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.confirmsWorkSaved)
                    }
                    .padding(16)
                    .background(
                        .red.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                } else {
                    summaryCards
                    Toggle(
                        "切换时自动保持全部历史会话可见",
                        isOn: Binding(
                            get: {
                                model.sessionSyncAuthorized
                            },
                            set: {
                                model
                                    .setSessionSyncAuthorization(
                                        $0
                                    )
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    Text(
                        "首次需要明确授权。每次修复都会先备份SQLite、rollout和助手状态；失败整笔恢复。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "我确认当前Codex工作已保存，可以正常关闭并重开",
                        isOn: $model.confirmsWorkSaved
                    )
                    .toggleStyle(.checkbox)
                    HStack {
                        Button("修复到当前模式") {
                            model
                                .repairSessionsToCurrentMode()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isSessionSyncWorking
                                || model.isSessionSyncScanning
                        )
                        Button("恢复上次修复") {
                            model.restoreLastSessionRepair()
                        }
                        .disabled(
                            !model.confirmsWorkSaved
                                || model.isSessionSyncWorking
                        )
                        Button("在Codex中打开") {
                            openCodex()
                        }
                    }
                    if !model.sessionSyncAuthorized {
                        Label(
                            "开始前请先勾选上方的历史会话保护授权",
                            systemImage:
                                "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else if !model.confirmsWorkSaved {
                        Label(
                            "开始前请勾选“当前Codex工作已保存”；也可以直接点修复按钮查看提示",
                            systemImage:
                                "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 10) {
                    if model.isSessionSyncScanning
                        || model.isSessionSyncWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(
                        model.sessionSyncStatus,
                        systemImage:
                            model.isSessionSyncScanning
                                || model.isSessionSyncWorking
                                ? "arrow.triangle.2.circlepath"
                                : (
                                    model.sessionSyncPreview == nil
                                        ? "clock"
                                        : (
                                            model.sessionSyncPreview?
                                                .canApply == false
                                                ? "exclamationmark.triangle.fill"
                                                : "checkmark.shield"
                                        )
                                )
                    )
                    .font(.callout)
                    .foregroundStyle(
                        model.isSessionSyncScanning
                            || model.isSessionSyncWorking
                            ? Color.secondary
                            : (
                                model.sessionSyncPreview == nil
                                    ? Color.secondary
                                    : (
                                        model.sessionSyncPreview?
                                            .canApply == false
                                            ? Color.orange
                                            : Color.green
                                    )
                            )
                    )
                    Spacer()
                    Button("重新扫描") {
                        model.refreshSessionSyncPreview(
                            force: true
                        )
                    }
                    .disabled(
                        model.isSessionSyncScanning
                            || model.isSessionSyncWorking
                    )
                }
                if let blockers =
                    model.sessionSyncPreview?
                        .blockers,
                   !blockers.isEmpty {
                    VStack(
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(
                            Array(blockers.prefix(3)),
                            id: \.self
                        ) { blocker in
                            Label(
                                blocker,
                                systemImage:
                                    "exclamationmark.triangle.fill"
                            )
                            Text(
                                blockerGuidance(blocker)
                            )
                            .padding(.leading, 24)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .background(
                        .orange.opacity(0.07),
                        in: RoundedRectangle(
                            cornerRadius: 10
                        )
                    )
                }

                if !sessions.isEmpty {
                    TextField(
                        "搜索标题、模型或工作目录",
                        text: $searchText
                    )
                    .textFieldStyle(.roundedBorder)
                    LazyVStack(spacing: 10) {
                        ForEach(visibleSessions) {
                            session in
                            sessionCard(session)
                        }
                    }
                } else if model.isSessionSyncScanning {
                    Label(
                        "正在后台整理会话；可先切换到其他页面",
                        systemImage: "clock"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "暂无可显示的历史会话",
                        systemImage: "bubble.left"
                    )
                    .foregroundStyle(.secondary)
                }

                if let selectedSession {
                    Divider()
                    Text("无法跨服务续聊时")
                        .font(.headline)
                    Text(
                        "不会删除或篡改加密内容。你可以只复制用户可见文字到新会话。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Toggle(
                        "授权本次读取可见正文并生成脱敏副本",
                        isOn: $bodyAuthorization
                    )
                    .toggleStyle(.checkbox)
                    Button(
                        isGeneratingCopyPreview
                            ? "正在生成…"
                            : "生成可复制内容"
                    ) {
                        generatePreview(selectedSession)
                    }
                    .disabled(
                        !bodyAuthorization
                            || isGeneratingCopyPreview
                    )
                    if let copyPreview {
                        Text(copyPreview.pasteDocument)
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced
                                )
                            )
                            .textSelection(.enabled)
                            .padding(12)
                            .background(
                                .secondary.opacity(0.05),
                                in: RoundedRectangle(
                                    cornerRadius: 10
                                )
                            )
                        Button("复制内容") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                copyPreview.pasteDocument,
                                forType: .string
                            )
                        }
                    }
                }

                DisclosureGroup(
                    "查看技术详情",
                    isExpanded: $technicalDetailsOpen
                ) {
                    if let preview =
                        model.sessionSyncPreview {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                "Provider："
                                    + preview.plan
                                        .targetProvider
                            )
                            Text(
                                "活跃：\(preview.activeRolloutCount) · 归档：\(preview.archivedRolloutCount) · 数据库：\(preview.databaseCount)"
                            )
                            Text(
                                "待改签rollout：\(preview.rolloutChangeCount) · 待更新索引：\(preview.databaseChangeCount)"
                            )
                            ForEach(
                                preview.plan.databases,
                                id: \.url
                            ) {
                                Text($0.url.path)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(
                            .system(
                                .caption,
                                design: .monospaced
                            )
                        )
                    }
                }

                if let localError {
                    Label(
                        localError,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
                if let error = model.errorMessage {
                    Label(
                        error,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            model.refreshRuntimeTruth()
            model.refreshSessionSyncPreview()
        }
        .onDisappear {
            model.cancelSessionSyncPreviewScan()
            copyPreviewTask?.cancel()
            copyPreviewTask = nil
            isGeneratingCopyPreview = false
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                "全部",
                model.sessionSyncPreview
                    .map {
                        String($0.uniqueThreadCount)
                    } ?? "—"
            )
            summaryCard(
                "当前可见",
                model.sessionSyncPreview
                    .map {
                        String(
                            $0.currentlyVisibleThreadCount
                        )
                    } ?? "—"
            )
            summaryCard(
                "状态",
                model.isSessionSyncScanning
                    ? "扫描中"
                    : (
                        model.sessionSyncPreview == nil
                            ? "未扫描"
                            : (
                                model.sessionSyncPreview?
                                    .needsRepair == true
                                    ? "需修复"
                                    : "已一致"
                            )
                    )
            )
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func sessionCard(
        _ session: SessionSyncListItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(session.title ?? "未命名会话")
                    .font(.headline)
                Spacer()
                if session.archived
                    || session.rolloutPath
                        .contains("archived_sessions") {
                    Text("已归档")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                "原始轨道："
                    + originDisplayName(session)
            )
            .font(.callout)
            Text(
                "当前可见标签："
                    + providerDisplayName(
                        session.observedProvider
                    )
            )
            .font(.callout)
            HStack(spacing: 14) {
                Label(
                    "创建："
                        + sessionDateText(
                            session.createdAt
                        ),
                    systemImage: "calendar"
                )
                Label(
                    "最近："
                        + sessionDateText(
                            session.updatedAt
                        )
                        + (
                            session.updatedAtIsFileTime
                                ? "（文件时间）"
                                : ""
                        ),
                    systemImage: "clock"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                session.workingDirectory
                    ?? "工作目录未知"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if session.containsEncryptedContent {
                Label(
                    "含Provider私有加密状态；若无法续聊，可复制可见内容到新会话",
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            HStack {
                Button("在Codex中打开") {
                    openSession(session)
                }
                Button("复制可见内容") {
                    selectedSession =
                        sessionOrigin(session)
                    bodyAuthorization = false
                    copyPreview = nil
                }
                Button("复制Thread ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        session.threadID,
                        forType: .string
                    )
                }
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func generatePreview(
        _ session: SessionOrigin
    ) {
        guard bodyAuthorization,
              let path = session.rolloutPath else {
            return
        }
        copyPreviewTask?.cancel()
        copyPreview = nil
        localError = nil
        isGeneratingCopyPreview = true
        let threadID = session.threadID
        let url = URL(fileURLWithPath: path)
        copyPreviewTask = Task {
            let worker = Task.detached(
                priority: .userInitiated
            ) {
                () -> SessionCopyPreviewOutcome in
                do {
                    let preview =
                        try RolloutVisibleTranscriptExtractor()
                            .preview(
                                at: url,
                                threadID: threadID,
                                authorization:
                                    SessionReadAuthorization(
                                        metadataAllowed: true,
                                        visibleBodyAllowed:
                                            true
                                    )
                            )
                    return .value(preview)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(
                        error.localizedDescription
                    )
                }
            }
            let outcome =
                await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
            guard !Task.isCancelled else { return }
            copyPreviewTask = nil
            isGeneratingCopyPreview = false
            switch outcome {
            case let .value(preview):
                copyPreview = preview
                localError = nil
            case let .failed(message):
                localError = message
            case .cancelled:
                break
            }
        }
    }

    private func sessionOrigin(
        _ item: SessionSyncListItem
    ) -> SessionOrigin {
        let evidence = SessionOriginEvidence(
            kind: .rollout,
            source: item.rolloutPath,
            value: item.observedProvider
                ?? "provider未记录",
            observedAt: item.createdAt
        )
        return SessionOrigin(
            threadID: item.threadID,
            title: item.title,
            observedProvider:
                item.observedProvider,
            inferredOrigin:
                item.originLabel
                    == "历史来源未知"
                    ? nil
                    : originDisplayName(item),
            confidence:
                item.originLabel
                    == "历史来源未知"
                    ? .unknown
                    : .verified,
            evidence: [evidence],
            model: item.model,
            workingDirectory:
                item.workingDirectory,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            archived: item.archived,
            sqliteStatus: .unknown,
            rolloutStatus: .available,
            rolloutPath: item.rolloutPath,
            containsEncryptedContent:
                item.containsEncryptedContent,
            actions: [
                .continueOnOrigin,
                .copyVisibleText,
                .readOnly,
                .locate,
            ]
        )
    }

    private func openSession(
        _ session: SessionSyncListItem
    ) {
        if let reason = model
            .sessionOpenBlockReason(session) {
            localError = reason
            return
        }
        guard let url = CodexDesktopSessionLink.url(
                  threadID: session.threadID
              ),
              NSWorkspace.shared.open(url) else {
            localError =
                "当前模式尚未可靠核对，或Codex没有接受会话链接"
            return
        }
        localError = nil
    }

    private func originDisplayName(
        _ session: SessionSyncListItem
    ) -> String {
        if session.originProfileID == "official"
            || session.originLabel == "official"
            || session.originLabel == "官方" {
            return "官方"
        }
        if let profileID = session.originProfileID,
           let profile = model.savedRelayProfiles
            .first(where: {
                $0.id == profileID
            }) {
            return profile.name
        }
        return session.originLabel
    }

    private func providerDisplayName(
        _ providerID: String?
    ) -> String {
        guard let providerID,
              !providerID.isEmpty else {
            return "未记录"
        }
        if providerID == "openai" {
            return "官方（openai）"
        }
        if let profile = model.savedRelayProfiles
            .first(where: {
                $0.providerID == providerID
            }) {
            return "\(profile.name)（\(providerID)）"
        }
        return providerID
    }

    private func sessionDateText(
        _ date: Date?
    ) -> String {
        guard let date else { return "未知" }
        return date.formatted(
            date: .numeric,
            time: .shortened
        )
    }

    private func blockerGuidance(
        _ blocker: String
    ) -> String {
        if blocker.contains("不同Thread ID") {
            return "这些Thread没有可证明的父子或派生关系，助手不会猜；在技术详情确认文件后再处理。"
        }
        if blocker.contains("占用") {
            return "退出Codex和其他配置工具，再点“重新扫描”。"
        }
        if blocker.contains("没有对应数据库记录") {
            return "正常打开并退出一次Codex，让原生会话索引完成落盘后再修复。"
        }
        if blocker.contains("来源账本") {
            return "先使用“一键恢复”恢复未完成事务。"
        }
        return "助手已停止写入；根据红字定位原因后重新扫描。"
    }

    private func openCodex() {
        guard let url =
            CodexApplicationLocator.applicationURL(),
              NSWorkspace.shared.open(url) else {
            localError = "未找到Codex Desktop"
            return
        }
        localError = nil
    }
}
