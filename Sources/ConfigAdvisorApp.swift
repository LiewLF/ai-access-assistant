import SwiftUI
import UniformTypeIdentifiers
#if !AI_ACCESS_ASSISTANT_TESTING
@main
#endif
struct ConfigAdvisorApp: App {
    init() {
        _ = SensitiveTemporaryArtifactJanitor.cleanupExpired()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 860, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
    }
}
private extension AppVaultKeyMigrationDependencies {
    static let live = Self(
        refreshState: {
            let need = try await Task.detached(
                priority: .utility
            ) {
                try AppVaultKeyStore.migrationNeed()
            }.value
            switch need {
            case .none:
                return .ready
            case .migrationRequired:
                return .migrationRequired
            case .cleanupRequired:
                return .cleanupRequired
            }
        },
        migrateState: {
            let result = try await Task.detached(
                priority: .userInitiated
            ) {
                try AppVaultKeyStore.migrateLegacyKey()
            }.value
            return .migrated(
                legacyRemoved: result.legacyRemoved
            )
        }
    )
}
private struct AppVaultKeyMigrationBanner: View {
    @ObservedObject var model: AppVaultKeyMigrationModel
    @State private var confirmationOpen = false
    var body: some View {
        if model.showsBanner {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.bold())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Color.orange.opacity(0.08)
            )
            .accessibilityIdentifier(
                "build87.vault-key-migration-banner"
            )
            .confirmationDialog(
                "迁移旧保险箱权限？",
                isPresented: $confirmationOpen
            ) {
                Button("允许macOS询问一次并迁移") {
                    model.migrate()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    "macOS可能显示一次登录钥匙串密码框。密码只交给系统，AI接入助手不会读取或代填你的密码。应用会先复制旧加密密钥、验证新条目可无交互读取，再删除旧条目；任何失败都保留旧条目。"
                )
            }
        }
    }
    @ViewBuilder
    private var action: some View {
        switch model.state {
        case .migrationRequired, .cleanupRequired:
            Button("迁移旧保险箱权限") {
                confirmationOpen = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(
                "build87.vault-key-migration-action"
            )
        case .migrating:
            ProgressView()
                .controlSize(.small)
        case let .migrated(legacyRemoved):
            if legacyRemoved {
                Button("知道了") {
                    model.dismissCompletedState()
                }
            } else {
                Button("重试清理旧条目") {
                    confirmationOpen = true
                }
            }
        case .failed:
            Button("重新检查") {
                model.refresh()
            }
        case .checking, .ready:
            EmptyView()
        }
    }
    private var title: String {
        switch model.state {
        case .migrationRequired:
            return "旧保险箱权限需要迁移"
        case .cleanupRequired:
            return "新权限已可用，旧条目待清理"
        case .migrating:
            return "正在由macOS迁移保险箱权限"
        case let .migrated(legacyRemoved):
            return legacyRemoved
                ? "保险箱权限迁移完成"
                : "新权限已生效，旧条目暂未删除"
        case .failed:
            return "保险箱权限检查未完成"
        case .checking:
            return "正在检查保险箱权限"
        case .ready:
            return "保险箱权限可用"
        }
    }
    private var detail: String {
        switch model.state {
        case .migrationRequired:
            return "启动不会再主动弹密码框；只有点击迁移后，macOS可能询问一次。"
        case .cleanupRequired:
            return "应用优先使用已验证的新条目；可显式清理旧ACL条目。"
        case .migrating:
            return "请在系统窗口中决定是否授权；应用看不到你输入的密码。"
        case let .migrated(legacyRemoved):
            return legacyRemoved
                ? "新条目已完成无交互回读，旧条目已删除。"
                : "启动将使用新条目；旧条目保留，可稍后重试清理。"
        case let .failed(message):
            return message
        case .checking:
            return "只做不允许交互的Keychain状态查询。"
        case .ready:
            return "无需迁移。"
        }
    }
    private var icon: String {
        switch model.state {
        case .migrated:
            return "checkmark.shield.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "key.fill"
        }
    }
    private var iconColor: Color {
        if case .migrated = model.state {
            return .green
        }
        return .orange
    }
}
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var configModel = ConfigWorkspaceModel()
    @StateObject private var v011AccessModel =
        V011AccessModel()
    @StateObject private var v011HistoryModel =
        V011HistoryModel()
    @StateObject private var v012UsageModel =
        V012UsageTruthModel()
    @StateObject private var vaultMigrationModel =
        AppVaultKeyMigrationModel(dependencies: .live)
    @StateObject private var shellState = AppShellState()
    @AppStorage(AppDisplayTextSize.storageKey)
    private var displayTextSize =
        AppDisplayTextSize.defaultValue
    @State private var importerOpen = false
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                AppVaultKeyMigrationBanner(
                    model: vaultMigrationModel
                )
                Divider()
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    detail
                }
            }
        }
        .dynamicTypeSize(displayTextSize.dynamicTypeSize)
        .fileImporter(
            isPresented: $importerOpen,
            allowedContentTypes: [.png, .jpeg, .tiff, .heic],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                configModel.addScreenshots(urls)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { shellState.settingsOpen },
                set: shellState.setSettingsPresented
            )
        ) {
            BeginnerSettingsView(
                model: configModel,
                accessModel: v011AccessModel,
                historyModel: v011HistoryModel,
                initialSection:
                    shellState.settingsInitialSection,
                onUseRelayEntry: { entry in
                    configModel.importDirectoryEntry(entry)
                    shellState.openAccess(.addRelay)
                    shellState.setSettingsPresented(false)
                },
                onConfigureCustomRelay: {
                    configModel.selectRelay(
                        RelayCatalog.customID
                    )
                    shellState.openAccess(.addRelay)
                    shellState.setSettingsPresented(false)
                },
                openAccessSection: { section in
                    shellState.openAccess(section)
                    shellState.setSettingsPresented(false)
                }
            )
            .frame(
                minWidth: 840,
                idealWidth: 920,
                maxWidth: 1_080,
                minHeight: 620,
                idealHeight: 700,
                maxHeight: 820
            )
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { notification in
            requestRefreshForCodexLifecycle(notification)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { notification in
            requestRefreshForCodexLifecycle(notification)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            v011AccessModel.requestRefresh(reason: .sceneActive)
        }
        .task {
            vaultMigrationModel.refresh()
        }
        .onChange(of: vaultMigrationModel.state) { _, state in
            if case .migrated = state {
                v011AccessModel.refresh()
            }
        }
        .onChange(of: shellState.mode) { _, mode in
            if mode != .home {
                v012UsageModel.cancelRefresh()
            }
        }
        .onDisappear {
            v012UsageModel.cancelRefresh()
        }
    }

    private func requestRefreshForCodexLifecycle(
        _ notification: Notification
    ) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication,
            V011AccessModel.isRelevantCodexApplication(
                bundleIdentifier: application.bundleIdentifier
            ) else {
            return
        }
        v011AccessModel.requestRefresh(
            reason: .codexApplicationLifecycle
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch shellState.mode {
        case .home:
            BeginnerStartView(
                model: configModel,
                accessModel: v011AccessModel,
                historyModel: v011HistoryModel,
                usageModel: v012UsageModel,
                onAddRelay: {
                    shellState.openAccess(.addRelay)
                },
                onSwitchMode: {
                    shellState.openAccess(.switchMode)
                },
                onFindSessions: {
                    shellState.selectMainMode(.sessions)
                },
                onInstallCodex: {
                    shellState.openSettings(.software)
                },
                onOpenDiagnostics: {
                    shellState.openSettings(.diagnostics)
                },
                onOpenGuide: {
                    shellState.openSettings(.guide)
                }
            )
        case .access:
            BeginnerAccessView(
                model: configModel,
                accessModel: v011AccessModel,
                section: Binding(
                    get: { shellState.accessSection },
                    set: shellState.selectAccessSection
                ),
                onChooseScreenshots: { importerOpen = true },
                onInstallCodex: { shellState.openSettings(.software) },
                onOpenDiagnostics: { shellState.openSettings(.diagnostics) },
                onOpenGuide: {
                    shellState.openSettings(.guide)
                }
            )
        case .sessions:
            BeginnerHistoryView(
                model: v011HistoryModel,
                accessModel: v011AccessModel
            )
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(availableMainModes) { item in
                Button {
                    shellState.selectMainMode(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .frame(width: 20)
                        Text(item.rawValue)
                        Spacer()
                    }
                    .font(
                        .body.weight(
                            shellState.mode == item ? .semibold : .regular
                        )
                    )
                    .foregroundStyle(
                        shellState.mode == item
                            ? Color.accentColor : Color.primary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        shellState.mode == item
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Label(
                "切换失败会恢复原状态",
                systemImage: "checkmark.shield"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .padding(12)
        .frame(width: 190)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var availableMainModes: [MainMode] {
        guard CodexApplicationLocator.applicationURL() == nil else {
            return MainMode.allCases
        }
        return MainMode.allCases.filter {
            $0 != .access && $0 != .sessions
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "scope")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI接入助手")
                    .font(.system(size: 22, weight: .bold))
                Text("安装、接入、切换与恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            displayTextSizeMenu
            Button {
                shellState.openSettings(.software)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("设置与诊断")
            .accessibilityLabel("设置与诊断")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private var displayTextSizeMenu: some View {
        Menu {
            Picker(
                "显示字号",
                selection: $displayTextSize
            ) {
                ForEach(AppDisplayTextSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .help("显示字号")
        .accessibilityLabel("显示字号")
        .accessibilityIdentifier(
            "build174.display-text-size"
        )
    }

    private var appVersion: String {
        "\(AppReleaseMetadata.version) (\(AppReleaseMetadata.build))"
    }

}

struct ConfigurationWorkspaceView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    let onChooseScreenshots: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("配置向导")
                            .font(.system(size: 28, weight: .bold))
                        Text("读取文档 → 自动整理 → 手动补齐 → 安全检查 → 确认导出。未识别字段可直接填写。")
                            .foregroundStyle(.secondary)
                    }

                    wizardHeader

                    Group {
                        switch model.wizardStep {
                        case .sources: sourcesStep
                        case .fields: fieldsStep
                        case .agent: agentStep
                        case .method: methodStep
                        case .safety: safetyStep
                        }
                    }
                    .padding(20)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(28)
                .frame(maxWidth: 1_100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()
            navigationBar
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }

    private var wizardHeader: some View {
        HStack(spacing: 8) {
            ForEach(ConfigurationWizardStep.allCases) { step in
                Button {
                    model.wizardStep = step
                } label: {
                    HStack(spacing: 6) {
                        Text(String(step.rawValue))
                            .font(.caption.bold())
                            .frame(width: 22, height: 22)
                            .background(
                                step.rawValue <= model.wizardStep.rawValue ? Color.blue : Color.secondary.opacity(0.2),
                                in: Circle()
                            )
                            .foregroundStyle(step.rawValue <= model.wizardStep.rawValue ? Color.white : Color.secondary)
                        Text(step.title).font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelTitle("1. 添加配置资料", subtitle: "网址、粘贴文字、单张或多张 QQ 截图进入同一识别流程")

            Picker("中转站", selection: $model.selectedRelayID) {
                Text("我自己的中转站／其他服务").tag(RelayCatalog.customID)
                ForEach(RelayCatalog.providers) { relay in
                    Text("已核验目录 · \(relay.name)").tag(relay.id)
                }
            }
            .onChange(of: model.selectedRelayID) { _, value in model.selectRelay(value) }

            if let relay = model.selectedRelay {
                VStack(alignment: .leading, spacing: 5) {
                    Text(relay.notes).font(.callout)
                    Text("来源：\(relay.documentationURL)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("最近核验：\(relay.lastVerified)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            labeledField("配置文档网址") {
                TextField("HTTPS 文档网址", text: $model.documentURL)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                model.refreshDocument()
            } label: {
                HStack {
                    if model.isRefreshingDocument { ProgressView().controlSize(.small) }
                    Label(model.isRefreshingDocument ? "正在读取全文并整理" : "读取文档并自动整理", systemImage: "wand.and.stars")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isRefreshingDocument)

            Label(model.documentStatus, systemImage: model.documentText.isEmpty ? "circle.dotted" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(model.documentText.isEmpty ? Color.secondary : Color.green)

            Divider()

            panelTitle("粘贴配置文字", subtitle: "适合 QQ 公告、群文件说明或没有公开网址的中转站")
            TextEditor(text: $model.pastedConfigurationText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 100)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Button("整理粘贴文字") { model.addPastedSource() }
                .buttonStyle(.bordered)

            Divider()

            panelTitle("导入配置截图", subtitle: "支持多选、自动排序和去重；OCR 只在本机运行")
            Button {
                onChooseScreenshots()
            } label: {
                HStack {
                    if model.isReadingScreenshots { ProgressView().controlSize(.small) }
                    Label("选择单张或多张截图", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isReadingScreenshots)
            Text(model.screenshotStatus).font(.caption).foregroundStyle(.secondary)

            if !model.configurationSources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已加入资料（\(model.configurationSources.count)）").font(.headline)
                    ForEach(model.configurationSources) { source in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title).font(.callout.weight(.semibold))
                                Text("\(source.kind.rawValue) · \(source.location)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let kind = source.screenshotKind {
                                    Picker("截图类型", selection: Binding(
                                        get: { kind },
                                        set: { model.setScreenshotKind(sourceID: source.id, kind: $0) }
                                    )) {
                                        Text(ScreenshotConfigurationKind.relayInstructions.rawValue).tag(ScreenshotConfigurationKind.relayInstructions)
                                        Text(ScreenshotConfigurationKind.currentSettings.rawValue).tag(ScreenshotConfigurationKind.currentSettings)
                                        Text(ScreenshotConfigurationKind.unknown.rawValue).tag(ScreenshotConfigurationKind.unknown)
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                                if source.containsSensitiveText {
                                    Label("疑似 Key/Token 已遮挡，不会带入", systemImage: "eye.slash.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) { model.removeSource(source.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }

            if !model.extractedSummary.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("已识别并带入").font(.headline)
                    ForEach(model.extractedSummary, id: \.self) { value in
                        Label(value, systemImage: "checkmark")
                            .font(.callout)
                    }
                    Button("重新应用识别结果") { model.applyExtractedConfiguration() }
                        .buttonStyle(.link)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }

            ForEach(model.extracted.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle("3. 选择桌面 Agent", subtitle: "这是最终发送消息和使用模型的软件")
            labeledField("桌面 Agent") {
                Picker("桌面 Agent", selection: $model.agent) {
                    ForEach([DesktopAgent.codexDesktop]) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.agent) { _, _ in model.applyAgentDefaults() }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("分类说明").font(.headline)
                Text("当前只显示已进入真实闭环验收的 Codex Desktop。")
                Text("Codex++、CC Switch是接入路径，不是桌面 Agent。Claude与Cherry Studio验收后再开放。")
            }
            .font(.callout)
            .padding(12)
            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle("4. 选择可完成的接入路径", subtitle: "只显示当前电脑具备入口、能进入保护与验证闭环的路径")

            ForEach(model.availableAccessRoutes) { route in
                Button {
                    model.selectAccessRoute(route)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: model.selectedAccessRoute == route ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(model.selectedAccessRoute == route ? Color.blue : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(route.rawValue).font(.headline)
                                if route == .managed {
                                    Text("推荐").font(.caption.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 2).background(.blue, in: Capsule())
                                }
                            }
                            Text(route.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.selectedAccessRoute == route ? Color.blue : Color.secondary).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Label("风险决定保护措施，不再决定什么都不做。每条可选路径都进入配置、验证、切回官方闭环。", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout).foregroundStyle(.blue)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var fieldsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelTitle("2. 核对识别字段", subtitle: "文档和截图共用提取器；冲突不自动覆盖")

            if let result = model.unifiedResult {
                HStack {
                    Label("候选字段 \(result.candidates.count) 条", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    Text("冲突 \(result.conflicts.count) 项")
                        .foregroundStyle(result.conflicts.isEmpty ? Color.green : Color.red)
                }
                .font(.callout.weight(.semibold))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(Array(model.recognizedFieldRows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(row.1.hasPrefix("未填写") ? Color.orange : Color.primary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }
            }

            ForEach(model.unresolvedConflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(conflict.field) 存在冲突", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.red)
                    ForEach(conflict.candidates) { candidate in
                        Button {
                            model.resolveConflict(field: conflict.field, value: candidate.value)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(candidate.value)
                                    Text("\(candidate.sourceTitle) · 置信度 \(candidate.confidence)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("选择此值")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            Label(
                "橙色未填写项可直接在下方补充。供应商、Base URL、API Key 和默认模型为必填；上下文、压缩阈值及文本/图片能力为选填，不会阻止下一步。",
                systemImage: "pencil.and.list.clipboard"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    labeledField("供应商名称（必填，可手动填写）") {
                        TextField("未识别时在这里手动填写", text: $model.providerName).textFieldStyle(.roundedBorder)
                    }
                    labeledField("Base URL（必填，可手动填写）") {
                        TextField("例如 https://example.com/v1", text: $model.baseURL).textFieldStyle(.roundedBorder)
                    }
                    if model.isLocalGateway {
                        Toggle(
                            "这是我手动填写的本机网关，只对当前配置档放行",
                            isOn: $model.confirmsLocalGateway
                        )
                        .toggleStyle(.checkbox)
                        Text("本机HTTP是明文连接；不会加入公共目录，也不会自动套用到其他配置档。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    labeledField("API Key（唯一必须手填）") {
                        SecureField("只在内存和确认导出文件中使用", text: $model.apiKey).textFieldStyle(.roundedBorder)
                    }
                    labeledField("协议") {
                        Picker("协议", selection: $model.wireProtocol) {
                            ForEach(RelayWireProtocol.allCases) { item in Text(item.rawValue).tag(item) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    labeledField("上下文窗口") {
                        TextField("例如 272000", text: $model.contextWindow).textFieldStyle(.roundedBorder)
                    }
                    labeledField("自动压缩阈值") {
                        TextField("例如 258000；不适用可留空", text: $model.autoCompactTokenLimit).textFieldStyle(.roundedBorder)
                    }
                    Toggle("启用推理", isOn: $model.reasoningEnabled)
                    labeledField("思考强度") {
                        Picker("思考强度", selection: $model.reasoningEffort) {
                            ForEach(ReasoningEffort.allCases) { item in Text(item.rawValue).tag(item) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("文本输入", isOn: $model.supportsTextInput)
                    Toggle("图片输入", isOn: $model.supportsImageInput)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.providerName) { _, value in
                model.recordManualField("供应商", value: value)
                model.invalidatePreview()
            }
            .onChange(of: model.baseURL) { _, value in
                model.recordManualField("Base URL", value: value)
                model.invalidatePreview()
            }
            .onChange(of: model.apiKey) { _, _ in model.invalidatePreview() }
            .onChange(of: model.wireProtocol) { _, value in
                model.recordManualField("协议", value: value.rawValue)
                model.invalidatePreview()
            }
            .onChange(of: model.contextWindow) { _, value in
                model.recordManualField("上下文", value: value)
                model.invalidatePreview()
            }
            .onChange(of: model.autoCompactTokenLimit) { _, value in
                model.recordManualField("自动压缩阈值", value: value)
                model.invalidatePreview()
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("模型列表（至少一个）").font(.headline)
                        Text("可以手动添加多个模型，也可以从中转的 /models 接口在线拉取。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isFetchingModels { ProgressView().controlSize(.small) }
                }

                HStack(spacing: 9) {
                    TextField("输入模型名称，例如 gpt-5.5", text: $model.newModelName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addModel() }
                    Button("添加模型") { model.addModel() }
                        .disabled(model.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        model.fetchModels()
                    } label: {
                        Label("在线拉取模型", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isFetchingModels)
                }

                Text(model.modelFetchStatus)
                    .font(.caption)
                    .foregroundStyle(model.modelFetchStatus.contains("失败") ? Color.red : Color.secondary)

                if model.modelNames.isEmpty {
                    Label("尚无模型，请手动添加或在线拉取", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(model.modelNames, id: \.self) { modelName in
                        HStack {
                            Button { model.selectDefaultModel(modelName) } label: {
                                Image(systemName: model.modelName == modelName ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.modelName == modelName ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            Text(modelName).textSelection(.enabled)
                            Spacer()
                            if model.modelName == modelName {
                                Text("默认模型").font(.caption.weight(.semibold)).foregroundStyle(.green)
                            } else {
                                Button("设为默认") { model.selectDefaultModel(modelName) }
                                    .buttonStyle(.link)
                            }
                            Button(role: .destructive) { model.removeModel(modelName) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(9)
                        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Text("如果中转没有开放模型接口，拉取失败不会影响手动添加。API Key 不会写入网址、日志或字段来源。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup("查看字段来源（\(model.evidence.count) 条）") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.evidence.enumerated()), id: \.offset) { _, item in
                        Text("• \(item.field)：\(item.value)｜\(item.status.rawValue)｜\(item.source)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            }

            if !model.missingFields.isEmpty {
                Label("仍缺：\(model.missingFields.joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var safetyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelTitle("5. 执行与验证", subtitle: "建立官方恢复点后，完成配置、启动、真实请求和恢复")

            HStack {
                Label("当前模式：\(model.codexRuntimeMode.rawValue)", systemImage: model.codexRuntimeMode == .official ? "person.crop.circle.badge.checkmark" : "network")
                    .font(.headline)
                Spacer()
                Text(model.selectedAccessRoute.rawValue).font(.callout).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .top) {
                Label(
                    model.allowsManagedWrite ? "真实状态核对通过" : "真实状态核对未通过",
                    systemImage: model.allowsManagedWrite ? "checkmark.shield.fill" : "exclamationmark.octagon.fill"
                )
                .font(.headline)
                .foregroundStyle(model.allowsManagedWrite ? Color.green : Color.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.runtimeTruthStatus)
                        .font(.callout)
                        .textSelection(.enabled)
                    Text("状态不一致时，配置生成和切换按钮会被禁用；恢复官方入口仍保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新核对") { model.refreshRuntimeTruth() }
            }
            .padding(14)
            .background(
                (model.allowsManagedWrite ? Color.green : Color.red).opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("白名单与保护").font(.headline)
                Text("受控写入：\(model.codexHomeURL.appendingPathComponent("config.toml").path)")
                Text("加密备份/必要恢复：auth.json")
                Text("受控会话同步：首次授权后，仅在加密恢复点和完整回滚保护下同步Codex会话标签")
                Text("永不访问：Codex、Claude或ChatGPT的Keychain项、其他应用配置")
                Text("中转Key：只存认证Helper自己的Keychain项；config.toml使用Codex命令认证")
            }
            .font(.callout)
            .padding(14)
            .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            if model.officialBaseline == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("第一步：建立官方基线").font(.headline)
                    Toggle("我已确认当前Codex是可正常使用的官方模式", isOn: $model.confirmsOfficialMode).toggleStyle(.checkbox)
                    Toggle("我授权助手读取白名单文件并建立本机加密快照", isOn: $model.confirmsRealWrite).toggleStyle(.checkbox)
                    Button("建立官方加密基线") { model.establishOfficialBaseline() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !model.confirmsOfficialMode
                                || !model.confirmsRealWrite
                                || model.runtimeTruth?.runtimeMode != .official
                                || model.runtimeTruth?.allowsManagedWrite != true
                        )
                }
                .padding(14)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Label("官方候选基线已建立（待真实请求验证）", systemImage: "checkmark.shield.fill")
                    .font(.headline).foregroundStyle(.orange)

                if !model.savedRelayProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已保存中转配置档").font(.headline)
                        ForEach(model.savedRelayProfiles, id: \.id) { profile in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(
                                        model.unverifiedLegacyRelayProfileIDs
                                            .contains(profile.id)
                                            ? "\(profile.name)（未验证旧档）"
                                            : profile.name
                                    )
                                    .fontWeight(.semibold)
                                    Text("默认模型：\(profile.defaultModel) · \(profile.wireProtocol.rawValue)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("选择并准备切换") { model.selectSavedRelayProfile(profile) }
                                    .disabled(
                                        model.unverifiedLegacyRelayProfileIDs
                                            .contains(profile.id)
                                    )
                            }
                        }
                    }
                    .padding(12)
                    .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }

                Button("生成当前值 → 中转目标值差异") { model.prepareCodexExecution() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.allowsManagedWrite)

                if let plan = model.codexPlan {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("即将管理的字段").font(.headline)
                        ForEach(Array(plan.managedChanges.enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .top) {
                                Text(change.0).font(.system(.caption, design: .monospaced)).frame(width: 210, alignment: .leading)
                                Text(change.1).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                Text(change.2).fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                    .padding(14)
                    .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                    if model.selectedAccessRoute == .manual {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("手动操作步骤").font(.headline)
                            Text("1. 打开 config.toml。\n2. 按上方差异修改托管字段，并加入下方供应商段。\n3. 保存文件。\n4. 回助手点击“检查并启动验证”。")
                            Text(plan.manualBlock)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).padding(10)
                                .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            HStack {
                                Button("打开配置文件") { model.openCodexConfiguration() }
                                Button("复制配置块") { model.copyManualConfiguration() }
                            }
                        }
                        .padding(14)
                        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if model.selectedAccessRoute.requiresExternalTool {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("外部配置工具闭环").font(.headline)
                            Text("助手已先准备恢复点。目标工具由你最终确认；回来后助手检查并标准化结果。")
                            if model.selectedAccessRoute == .codexPlusPlus {
                                Text("导入后核对：供应商 \(model.providerName)；Base URL \(model.baseURL)；协议 \(model.wireProtocol.rawValue)。导入协议不带模型，请在供应商模型页加入：\(model.modelNames.joined(separator: "、"))。不要删除原官方供应商。")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("在CC Switch选择 Codex → 新增供应商，填写名称 \(model.providerName)、地址 \(model.baseURL)、模型 \(model.modelName)。保存后不要继续反复切换；助手会检查 auth.json，并把固定 high 修正为 \(model.reasoningEffort.rawValue)。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("打开 \(model.selectedAccessRoute == .codexPlusPlus ? "Codex++ 导入" : "CC Switch")") { model.openExternalTool() }
                                    .buttonStyle(.borderedProminent)
                                Button("我已在工具中完成，检查改动") { model.inspectExternalChange() }
                            }
                            if model.externalChangeDetected {
                                Label(model.externalChangeSummary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                HStack {
                                    ForEach(ExternalDriftChoice.allCases) { choice in
                                        Button(choice.rawValue) { model.handleExternalDrift(choice) }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }

                    Toggle(
                        "我已保存当前工作，并允许助手正常关闭Codex、执行受保护切换、验证后重新打开；失败自动恢复",
                        isOn: Binding(
                            get: {
                                model.confirmsCodexRestart
                                    && model.confirmsWorkSaved
                                    && model.confirmsRealWrite
                            },
                            set: { confirmed in
                                model.confirmsCodexRestart =
                                    confirmed
                                model.confirmsWorkSaved =
                                    confirmed
                                model.confirmsRealWrite =
                                    confirmed
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    if !model.selectedAccessRoute.requiresExternalTool {
                        Button {
                            model.executeRealRelaySwitch()
                        } label: {
                            Label(model.selectedAccessRoute == .manual ? "检查并启动真实验证" : "切到 \(model.providerName) 并真实验证", systemImage: "play.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(
                            !model.confirmsCodexRestart
                                || !model.confirmsWorkSaved
                                || !model.confirmsRealWrite
                                || model.isRealSwitchWorking
                                || !model.allowsManagedWrite
                        )
                    }
                }

                Button(role: .destructive) { model.restoreOfficialMode() } label: {
                    Label("切回官方并重开Codex", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(
                    !model.confirmsCodexRestart
                        || !model.confirmsWorkSaved
                        || model.isRealSwitchWorking
                )
            }

            HStack {
                if model.isRealSwitchWorking { ProgressView().controlSize(.small) }
                if let phase = model.realSwitchPhase { Text(phase.rawValue).fontWeight(.semibold) }
                Text(model.realSwitchStatus).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            if model.codexRuntimeMode == .relay {
                Label(
                    model.credentialBridgeState == .ready
                        ? "持久凭据桥已就绪；Codex可从Dock、Codex++或其他正常入口启动"
                        : "持久凭据桥未就绪；为避免Key缺失，当前中转模式已阻止无感启动",
                    systemImage:
                        model.credentialBridgeState == .ready
                            ? "key.horizontal.fill"
                            : "exclamationmark.octagon.fill"
                )
                .font(.callout)
                .foregroundStyle(
                    model.credentialBridgeState == .ready
                        ? Color.green : Color.red
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (
                        model.credentialBridgeState == .ready
                            ? Color.green : Color.red
                    ).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            Button("上一步") { model.goBack() }
                .disabled(model.wizardStep == .sources)
            Spacer()
            Text("第 \(model.wizardStep.rawValue) / 5 步")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.wizardStep != .safety {
                if model.wizardStep == .fields, !model.canContinueFromFields {
                    Text(model.unresolvedConflicts.isEmpty
                         ? "还需填写：\(model.missingFields.joined(separator: "、"))"
                         : "请先处理字段冲突")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("下一步") { model.goNext() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        (model.wizardStep == .sources && !model.canContinueFromSources)
                            || (model.wizardStep == .fields && !model.canContinueFromFields)
                    )
            }
        }
        .controlSize(.large)
    }

    private func panelTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
struct AdviceCard: View {
    let item: AdviceItem

    private var color: Color {
        switch item.level {
        case .recommended: return .green
        case .caution: return .orange
        case .blocked: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.level.symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title).font(.headline)
                    Text(item.level.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.1), in: Capsule())
                }
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.82))
                Text("依据：\(item.source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.16)))
    }
}
