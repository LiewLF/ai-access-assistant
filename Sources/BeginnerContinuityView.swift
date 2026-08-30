import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let portableContinuityTargetChoiceRequired =
    "__portable_continuity_target_choice_required__"

private struct PortableContinuityRelayImportForm:
    Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let baseURL: String
    let defaultModel: String
    var isSelected: Bool
    var targetProfileID: String
    var useIncomingDisplayName: Bool
    var useIncomingBaseURL: Bool
    var useIncomingDefaultModel: Bool
    var credential: String
}

private struct PortableContinuityWorkspaceImportForm:
    Identifiable, Equatable {
    let id: UUID
    let label: String
    var isSelected: Bool
    var targetPath: String
}

struct BeginnerContinuityExportView: View {
    @ObservedObject var accessModel: V011AccessModel
    @ObservedObject var historyModel: V011HistoryModel
    @Binding var isImportWorking: Bool

    @State private var snapshot:
        PortableContinuityExportSnapshot?
    @State private var selection = PortableContinuitySelection(
        accessProfiles: true,
        workspaceLabels: true,
        startDestination: false,
        historyGrouping: false
    )
    @State private var previewStatus = "正在生成本机预览…"
    @State private var exportStatus: String?
    @State private var importPreview:
        PortableContinuityImportPreview?
    @State private var importSession:
        PortableContinuityImportSession?
    @State private var relayImportForms:
        [PortableContinuityRelayImportForm] = []
    @State private var workspaceImportForms:
        [PortableContinuityWorkspaceImportForm] = []
    @State private var importConfirmed = false
    @State private var importStatus =
        "尚未选择迁移设置文件。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("迁移设置")
                        .font(.system(size: 28, weight: .bold))
                    Text(
                        "先看清内容，再选择字段并导出。导出的JSON只保存可重新建立接入所需的非敏感资料。"
                    )
                    .foregroundStyle(.secondary)
                }

                boundaryCard
                selectionCard
                previewCard

                HStack(spacing: 12) {
                    Button("重新读取预览") {
                        refreshPreview()
                    }
                    .buttonStyle(.bordered)
                    Button("导出所选内容") {
                        exportSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        snapshot == nil
                            || !selection.hasSelectedField
                    )
                    .accessibilityIdentifier(
                        "build130.continuity-export"
                    )
                    .accessibilityHint(
                        "打开保存位置；取消不会写入文件"
                    )
                }
                if let exportStatus {
                    Text(exportStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.vertical, 4)
                importPreflightCard
            }
            .padding(30)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if snapshot == nil {
                refreshPreview()
            }
            accessModel.refreshPortableContinuityRecoveryState()
        }
        .onChange(of: relayImportForms) { _, _ in
            importConfirmed = false
        }
        .onChange(of: workspaceImportForms) { _, _ in
            importConfirmed = false
        }
    }

    private var boundaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "固定排除敏感和本机专属内容",
                systemImage: "lock.shield.fill"
            )
            .font(.headline)
            Text(
                "不会导出 API Key、Token、认证文件、Keychain 引用、会话正文、配置文件、真实工作区路径或原中转内部ID。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(
                "中转凭据需要在新设备重新录入；导出过程不联网、不读取钥匙串。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.green.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择导出字段")
                .font(.headline)
            Toggle("接入资料：名称、HTTPS地址、默认模型、Responses协议", isOn: $selection.accessProfiles)
            Toggle("工作区标签：只保留标签文字，使用新匿名ID", isOn: $selection.workspaceLabels)
            Toggle("启动页默认值：开始", isOn: $selection.startDestination)
            Toggle("历史分组默认值：工作区", isOn: $selection.historyGrouping)
            Text(
                "后两项目前是产品默认值，不是单独保存的个人选择，因此默认不勾选。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if !selection.hasSelectedField {
                Label(
                    "至少选择一项才能导出",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.7),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("导出预览")
                    .font(.headline)
                Spacer()
                Text("Build\(AppReleaseMetadata.build)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let snapshot {
                Text("接入资料 \(snapshot.accessProfiles.count) 项")
                    .font(.subheadline.weight(.semibold))
                ForEach(snapshot.accessProfiles, id: \.id) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.callout.weight(.semibold))
                        if let baseURL = profile.baseURL,
                            let defaultModel = profile.defaultModel
                        {
                            Text("\(defaultModel) · \(baseURL)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("官方登录；不包含认证资料")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider()
                Text("工作区标签 \(snapshot.workspaceLabels.count) 项")
                    .font(.subheadline.weight(.semibold))
                if snapshot.workspaceLabels.isEmpty {
                    Text("当前没有已命名的工作区标签。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.workspaceLabels, id: \.id) { item in
                        Label(item.label, systemImage: "tag")
                            .font(.callout)
                    }
                }
                if snapshot.skippedRelayCount > 0
                    || snapshot.skippedWorkspaceLabelCount > 0
                {
                    Text(
                        "已跳过不可移植内容：中转 \(snapshot.skippedRelayCount) 项，标签 \(snapshot.skippedWorkspaceLabelCount) 项。"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(previewStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.7),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func refreshPreview() {
        exportStatus = nil
        let relaySources = accessModel.savedProfiles.map { profile in
            PortableContinuityRelaySource(
                sourceIdentifier: profile.id,
                displayName: profile.name,
                baseURL: profile.baseURL,
                defaultModel: profile.defaultModel,
                usesResponsesAPI:
                    profile.wireProtocol == .responses
            )
        }
        let workspaceSources = historyModel.workspaceLabels
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value < rhs.value
            }
            .map { path, label in
                PortableContinuityWorkspaceSource(
                    localPath: path,
                    label: label
                )
            }
        do {
            snapshot = try PortableContinuityExportPlanner.snapshot(
                sourceVersion: AppReleaseMetadata.version,
                sourceBuild: AppReleaseMetadata.build,
                relaySources: relaySources,
                workspaceSources: workspaceSources
            )
            previewStatus =
                "预览来自当前内存状态；未读取凭据、未联网、未写文件。"
        } catch {
            snapshot = nil
            previewStatus = "无法生成安全预览；未写入文件。"
        }
    }

    private func exportSelection() {
        guard let snapshot,
            selection.hasSelectedField
        else {
            exportStatus = "至少选择一项；未写入文件。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存迁移设置"
        panel.nameFieldStringValue =
            "AI接入助手-迁移设置-Build\(AppReleaseMetadata.build).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK,
            let destinationURL = panel.url
        else {
            exportStatus = "已取消导出；未写入文件。"
            return
        }
        do {
            let manifest = try snapshot.manifest(
                selection: selection
            )
            try PortableContinuityAtomicExporter.write(
                manifest,
                to: destinationURL
            )
            exportStatus =
                "已原子导出所选非敏感设置；未联网、未读取凭据。"
        } catch {
            exportStatus = "导出失败；目标位置未留下半成品。"
        }
    }

    @ViewBuilder
    private var importPreflightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "预检、选择，再确认导入",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.headline)
            Text(
                "先只读预检迁移文件，再让你逐条选择中转字段、重新输入目标凭据，并把标签绑定到本机已收藏工作区。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(
                "文件或当前设置变化后必须重新预检。导入过程不联网、不启动Codex、不验证中转，也不产生中转任务费用。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if accessModel.hasPendingPortableContinuityImport {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "发现未完成的迁移导入",
                        systemImage: "arrow.counterclockwise.circle.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    Text(
                        accessModel.portableContinuityRecoveryError
                            ?? "先恢复写入前状态或完成安全清理，才能再次预检和导入。"
                    )
                    .font(.caption)
                    Button("恢复未完成导入") {
                        recoverPendingImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImportWorking || accessModel.isWorking)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }

            Button("选择JSON并只读预检") {
                inspectImportFile()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isImportWorking
                    || accessModel.isWorking
                    || accessModel.hasPendingPortableContinuityImport
            )
            .accessibilityIdentifier(
                "build131.continuity-import-preflight"
            )
            .accessibilityHint(
                "只读取所选普通JSON文件；取消时不读取文件也不写入设置"
            )
            Text(importStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "build133.continuity-import-result"
                )

            if let importPreview {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        "来源 \(importPreview.sourceVersion) (\(importPreview.sourceBuild)) · \(importPreview.sourcePlatform.rawValue)"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("预检已绑定")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Text(importSummary(importPreview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(importPreview.warnings, id: \.self) { warning in
                    Label(
                        warning,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(importPreview.changes) { change in
                        importChangeRow(change)
                    }
                }

                if !relayImportForms.isEmpty {
                    Divider()
                    Text("选择中转字段并重新输入凭据")
                        .font(.subheadline.weight(.semibold))
                    ForEach($relayImportForms) { $form in
                        relayImportEditor($form)
                    }
                }

                if !workspaceImportForms.isEmpty {
                    Divider()
                    Text("把标签绑定到本机工作区")
                        .font(.subheadline.weight(.semibold))
                    if historyModel.favoriteWorkspacePaths.isEmpty {
                        Text("当前没有已收藏工作区；先到历史工具收藏，再重新预检。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach($workspaceImportForms) { $form in
                        workspaceImportEditor($form)
                    }
                }

                if importPreview.selection.startDestination
                    || importPreview.selection.historyGrouping
                {
                    Label(
                        "启动页和历史分组偏好当前不写入；本次只导入你明确选择的中转和工作区标签。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()
                Toggle(
                    "我已核对上述来源、字段、目标工作区和凭据，确认执行本次导入",
                    isOn: $importConfirmed
                )
                .disabled(
                    isImportWorking
                        || accessModel.hasPendingPortableContinuityImport
                )
                Button("确认并导入所选内容") {
                    applyConfirmedImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApplyImport)
                .accessibilityIdentifier(
                    "build132.continuity-import-confirm"
                )
                .accessibilityHint(
                    "只写入明确选择的字段和本机工作区映射；不联网验证"
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.blue.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func relayImportEditor(
        _ form: Binding<PortableContinuityRelayImportForm>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: form.isSelected) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(form.wrappedValue.displayName)
                        .font(.callout.weight(.semibold))
                    Text(
                        "\(form.wrappedValue.defaultModel) · \(form.wrappedValue.baseURL)"
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            if form.wrappedValue.isSelected {
                Picker("写入目标", selection: form.targetProfileID) {
                    if form.wrappedValue.targetProfileID
                        == portableContinuityTargetChoiceRequired
                    {
                        Text("请选择具体目标")
                            .tag(portableContinuityTargetChoiceRequired)
                    }
                    Text("新增为一条中转").tag("")
                    ForEach(accessModel.savedProfiles) { profile in
                        Text("更新：\(profile.name)")
                            .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                if form.wrappedValue.targetProfileID
                    == portableContinuityTargetChoiceRequired
                {
                    Text("文件名称和地址命中了不同中转；请选择具体目标。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if form.wrappedValue.targetProfileID.isEmpty {
                    Text("新增中转会写入文件中的名称、HTTPS地址和默认模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(
                        "名称使用文件值",
                        isOn: form.useIncomingDisplayName
                    )
                    Toggle(
                        "接口地址使用文件值",
                        isOn: form.useIncomingBaseURL
                    )
                    Toggle(
                        "默认模型使用文件值",
                        isOn: form.useIncomingDefaultModel
                    )
                }
                SecureField(
                    "在目标设备重新输入这条中转的 API Key",
                    text: form.credential
                )
                .textFieldStyle(.roundedBorder)
                Text("凭据只写入本机Keychain；不会保存到迁移文件或恢复记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.65),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func workspaceImportEditor(
        _ form: Binding<PortableContinuityWorkspaceImportForm>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "导入标签：\(form.wrappedValue.label)",
                isOn: form.isSelected
            )
            if form.wrappedValue.isSelected {
                Picker("绑定到", selection: form.targetPath) {
                    Text("请选择本机已收藏工作区").tag("")
                    ForEach(
                        historyModel.favoriteWorkspacePaths.sorted(),
                        id: \.self
                    ) { path in
                        Text(workspaceTargetTitle(path)).tag(path)
                    }
                }
                .pickerStyle(.menu)
                if !form.wrappedValue.targetPath.isEmpty {
                    Text(form.wrappedValue.targetPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.65),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private var canApplyImport: Bool {
        guard importSession != nil,
            importConfirmed,
            !isImportWorking,
            !accessModel.isWorking,
            !accessModel.hasPendingPortableContinuityImport
        else { return false }
        let relays = relayImportForms.filter(\.isSelected)
        let workspaces = workspaceImportForms.filter(\.isSelected)
        guard !relays.isEmpty || !workspaces.isEmpty else {
            return false
        }
        guard relays.allSatisfy({ form in
            !form.credential.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                && (form.targetProfileID.isEmpty
                    || accessModel.savedProfiles.contains(where: {
                        $0.id == form.targetProfileID
                    }))
        }) else {
            return false
        }
        let existingTargetIDs = relays.compactMap {
            $0.targetProfileID.isEmpty ? nil : $0.targetProfileID
        }
        guard Set(existingTargetIDs).count == existingTargetIDs.count else {
            return false
        }
        guard workspaces.allSatisfy({
            historyModel.favoriteWorkspacePaths.contains($0.targetPath)
        }) else {
            return false
        }
        let targetPaths = workspaces.map(\.targetPath)
        return Set(targetPaths).count == targetPaths.count
    }

    private func workspaceTargetTitle(_ path: String) -> String {
        if let label = historyModel.workspaceLabels[path] {
            return label
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func importChangeRow(
        _ change: PortableContinuityImportChange
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "\(change.scope.displayName) · \(change.recordTitle) · \(change.field.displayName)"
                )
                .font(.callout.weight(.semibold))
                Spacer()
                Text(change.disposition.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(
                        importDispositionColor(
                            change.disposition
                        )
                    )
            }
            Text("文件：\(change.incomingValue)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let currentValue = change.currentValue {
                Text("当前：\(currentValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(change.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.65),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func importSummary(
        _ preview: PortableContinuityImportPreview
    ) -> String {
        "无需变化 \(preview.count(for: .unchanged)) · 可新增 \(preview.count(for: .willAdd)) · 需选择 \(preview.count(for: .conflict)) · 需绑定 \(preview.count(for: .requiresTargetMapping)) · 当前不支持 \(preview.count(for: .unsupported))"
    }

    private func importDispositionColor(
        _ disposition: PortableContinuityImportDisposition
    ) -> Color {
        switch disposition {
        case .unchanged:
            return .secondary
        case .willAdd:
            return .green
        case .conflict, .requiresTargetMapping:
            return .orange
        case .unsupported:
            return .red
        }
    }

    private func inspectImportFile() {
        let panel = NSOpenPanel()
        panel.title = "选择迁移设置"
        panel.prompt = "只读预检"
        panel.message =
            "先只读一个普通JSON文件；预检完成后仍需逐项选择并明确确认。"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK,
            let sourceURL = panel.url
        else {
            resetImportDraft()
            importStatus =
                "已取消导入预检；未读取文件、未写入设置。"
            return
        }
        resetImportDraft()
        isImportWorking = true
        importStatus = "正在只读预检所选文件和当前设置…"
        Task {
            defer { isImportWorking = false }
            do {
                let session = try await accessModel
                    .preparePortableContinuityImport(from: sourceURL)
                importSession = session
                importPreview = session.preview
                configureImportForms(session)
                importStatus =
                    "只读预检完成；当前设置与所选文件均未改变。请完成选择后确认。"
            } catch {
                resetImportDraft()
                importStatus =
                    "预检失败：\(error.localizedDescription)；未写入设置。"
            }
        }
    }

    private func configureImportForms(
        _ session: PortableContinuityImportSession
    ) {
        relayImportForms = session.manifest.accessProfiles.compactMap {
            source in
            guard source.kind == .relay,
                let baseURL = source.baseURL,
                let defaultModel = source.defaultModel
            else { return nil }
            let candidates = accessModel.savedProfiles.filter {
                canonicalPortableEndpoint($0.baseURL)
                        == canonicalPortableEndpoint(baseURL)
                    || normalizedPortableName($0.name)
                        == normalizedPortableName(source.displayName)
            }
            let exact = candidates.first {
                canonicalPortableEndpoint($0.baseURL)
                        == canonicalPortableEndpoint(baseURL)
                    && normalizedPortableName($0.name)
                        == normalizedPortableName(source.displayName)
                    && $0.defaultModel == defaultModel
                    && $0.wireProtocol == .responses
            }
            let targetProfileID: String
            if let exact {
                targetProfileID = exact.id
            } else if candidates.count == 1 {
                targetProfileID = candidates[0].id
            } else if candidates.count > 1 {
                targetProfileID =
                    portableContinuityTargetChoiceRequired
            } else {
                targetProfileID = ""
            }
            return PortableContinuityRelayImportForm(
                id: source.id,
                displayName: source.displayName,
                baseURL: baseURL,
                defaultModel: defaultModel,
                isSelected: candidates.isEmpty,
                targetProfileID: targetProfileID,
                useIncomingDisplayName: true,
                useIncomingBaseURL: true,
                useIncomingDefaultModel: true,
                credential: ""
            )
        }
        workspaceImportForms = session.manifest.workspaceLabels.map {
            source in
            let matchingPaths = historyModel.workspaceLabels.compactMap {
                path, label in
                normalizedPortableName(label)
                    == normalizedPortableName(source.label)
                    ? path : nil
            }.sorted()
            return PortableContinuityWorkspaceImportForm(
                id: source.id,
                label: source.label,
                isSelected: false,
                targetPath:
                    matchingPaths.count == 1 ? matchingPaths[0] : ""
            )
        }
        importConfirmed = false
    }

    private func applyConfirmedImport() {
        guard canApplyImport,
            let importSession
        else {
            importStatus = "请完成选择、凭据和确认；尚未写入设置。"
            return
        }
        let relayDecisions = relayImportForms
            .filter(\.isSelected)
            .map { form in
                let isNew = form.targetProfileID.isEmpty
                return PortableContinuityRelayDecision(
                    sourceID: form.id,
                    targetProfileID:
                        isNew ? nil : form.targetProfileID,
                    useIncomingDisplayName:
                        isNew || form.useIncomingDisplayName,
                    useIncomingBaseURL:
                        isNew || form.useIncomingBaseURL,
                    useIncomingDefaultModel:
                        isNew || form.useIncomingDefaultModel,
                    credential: form.credential
                )
            }
        let workspaceDecisions = workspaceImportForms
            .filter(\.isSelected)
            .map {
                PortableContinuityWorkspaceDecision(
                    sourceID: $0.id,
                    targetPath: $0.targetPath
                )
            }
        let request = PortableContinuityApplyRequest(
            session: importSession,
            relayDecisions: relayDecisions,
            workspaceDecisions: workspaceDecisions,
            userConfirmed: true
        )
        isImportWorking = true
        importStatus = "正在建立恢复点并导入所选内容…"
        Task {
            defer { isImportWorking = false }
            do {
                let result = try await accessModel
                    .applyPortableContinuityImport(request)
                historyModel.reloadWorkspacePreferences()
                resetImportDraft()
                refreshPreview()
                importStatus =
                    "已导入中转 \(result.importedRelayCount) 条、工作区标签 \(result.mappedWorkspaceCount) 个。\(result.continuation.userMessage)"
            } catch {
                importConfirmed = false
                accessModel.refreshPortableContinuityRecoveryState()
                importStatus =
                    "导入未完成：\(error.localizedDescription)"
            }
        }
    }

    private func recoverPendingImport() {
        isImportWorking = true
        importConfirmed = false
        importStatus = "正在恢复未完成的迁移导入…"
        Task {
            defer { isImportWorking = false }
            do {
                let count = try await accessModel
                    .recoverPortableContinuityImport()
                historyModel.reloadWorkspacePreferences()
                resetImportDraft()
                refreshPreview()
                importStatus =
                    "已安全处理 \(count) 条未完成导入记录；可以重新预检。"
            } catch {
                importStatus =
                    "恢复仍未完成：\(error.localizedDescription)"
            }
        }
    }

    private func resetImportDraft() {
        importSession = nil
        importPreview = nil
        relayImportForms = []
        workspaceImportForms = []
        importConfirmed = false
    }

    private func canonicalPortableEndpoint(_ value: String) -> String {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme,
            let host = components.host
        else {
            return value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
    }

    private func normalizedPortableName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
