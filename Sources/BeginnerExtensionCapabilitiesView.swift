import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerExtensionCapabilitiesView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @StateObject private var localTrustModel =
        LocalTrustCenterModel()

    @State private var editingProfile: CodexRelayProfile?
    @State private var editingSavedProfile: CodexRelayProfile?
    @State private var catalogProfile: CodexRelayProfile?
    @State private var catalogImportHelpProfile: CodexRelayProfile?
    @State private var catalogImportReview:
        BeginnerManagedModelCatalogImportReview?
    @State private var catalogImporterOpen = false
    @State private var discoveryOpen = false
    @State private var verificationOpen = false
    @State private var localTrustCenterOpen = false
    @State private var localError: String?
    @State private var confirmsCoreProbe = false
    @State private var confirmsFastProbe = false
    @State private var confirmsWebSearchProbe = false
    @State private var confirmsImageInputProbe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("扩展能力")
                            .font(.system(size: 28, weight: .bold))
                        Spacer()
                        Button("验证扩展能力") {
                            verificationOpen = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text(
                        "直接设置中转能力、自动应用到当前轨，并用分层证据验证。配置、请求和真实支持分开显示。"
                    )
                    .foregroundStyle(.secondary)
                }

                if accessModel.savedProfiles.isEmpty {
                    ContentUnavailableView(
                        "还没有已保存中转",
                        systemImage: "slider.horizontal.3",
                        description: Text(
                            "先在“接入与切换”添加中转；保存后可在这里配置全部受管能力。"
                        )
                    )
                } else {
                    ForEach(accessModel.savedProfiles) { profile in
                        relayCard(profile)
                    }
                }

                localExtensionCard

                if let message = accessModel
                    .capabilityEvidenceErrorMessage {
                    Label(
                        message,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                if let localError {
                    Label(
                        localError,
                        systemImage: "xmark.octagon.fill"
                    )
                    .foregroundStyle(.red)
                }
                Text(accessModel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editingProfile) { profile in
            BeginnerRelayCapabilityEditor(
                sourceProfile: profile,
                isCurrent:
                    accessModel.currentProviderID
                        == profile.v011ProviderID,
                save: { target in
                    editingProfile = nil
                    accessModel.updateRelayCapabilities(
                        sourceProfile: profile,
                        targetProfile: target
                    )
                },
                cancel: {
                    editingProfile = nil
                }
            )
        }
        .sheet(item: $editingSavedProfile) { profile in
            BeginnerSavedRelayEditor(
                sourceProfile: profile,
                isCurrent:
                    accessModel.currentProviderID
                        == profile.v011ProviderID,
                save: { target, replacementAPIKey in
                    editingSavedProfile = nil
                    accessModel.updateRelayProfile(
                        sourceProfile: profile,
                        targetProfile: target,
                        replacementAPIKey:
                            replacementAPIKey
                    )
                },
                delete: {
                    editingSavedProfile = nil
                    accessModel.deleteSavedRelay(profile)
                },
                cancel: {
                    editingSavedProfile = nil
                }
            )
        }
        .sheet(isPresented: $discoveryOpen) {
            CapabilityDiscoveryView()
                .frame(minWidth: 900, minHeight: 680)
        }
        .sheet(isPresented: $verificationOpen) {
            BeginnerCapabilityVerificationView(
                model: model,
                accessModel: accessModel
            )
            .frame(minWidth: 780, minHeight: 680)
        }
        .sheet(isPresented: $localTrustCenterOpen) {
            LocalTrustCenterView(
                model: localTrustModel,
                performPrimaryAction:
                    performCapabilityCompatibilityAction
            )
            .onChange(of: accessModel.compatibilityEvidence) {
                _, _ in
                guard localTrustCenterOpen else { return }
                localTrustModel.refresh(
                    codexEvidence: localCodexCompatibilityEvidence
                )
            }
        }
        .sheet(item: $catalogImportHelpProfile) { profile in
            BeginnerManagedModelCatalogImportHelpView(
                profile: profile,
                chooseFile: {
                    catalogImportHelpProfile = nil
                    catalogProfile = profile
                    DispatchQueue.main.async {
                        catalogImporterOpen = true
                    }
                },
                scanFolder: {
                    catalogImportHelpProfile = nil
                    startManagedModelCatalogScan(for: profile)
                },
                scanDefaultCodexHome: {
                    catalogImportHelpProfile = nil
                    startManagedModelCatalogScan(
                        for: profile,
                        rootURL: accessModel.codexHomeURL
                    )
                },
                cancel: {
                    catalogImportHelpProfile = nil
                }
            )
            .frame(minWidth: 720, minHeight: 560)
        }
        .sheet(item: $catalogImportReview) { review in
            BeginnerManagedModelCatalogImportReviewView(
                review: review,
                chooseCandidate: { candidate in
                    catalogImportReview = nil
                    importCatalog(
                        from: candidate.url,
                        profile: review.profile
                    )
                },
                cancel: {
                    catalogImportReview = nil
                }
            )
            .frame(minWidth: 760, minHeight: 560)
        }
        .fileImporter(
            isPresented: $catalogImporterOpen,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importCatalog(result)
        }
        .confirmationDialog(
            "确认验证当前轨核心能力？",
            isPresented: $confirmsCoreProbe
        ) {
            Button("确认联网并验证基础能力") {
                accessModel.detectCurrentConnection(
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将按当前实时设置发送一次Responses最小请求。可能产生一次API费用；不会切换接入、启动MCP或修改配置。"
            )
        }
        .confirmationDialog(
            "确认验证 Fast？",
            isPresented: $confirmsFastProbe
        ) {
            Button("确认联网并验证 Fast") {
                accessModel.runOptionalProviderCapabilityProbe(
                    .serviceTier,
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将向当前中转发送一次真实 Fast 请求。会联网，并可能产生额外 API 费用；不会修改配置。"
            )
        }
        .confirmationDialog(
            "确认验证 Web Search 与来源引用？",
            isPresented: $confirmsWebSearchProbe
        ) {
            Button("确认联网并验证 Web Search 与来源引用") {
                accessModel.runOptionalProviderCapabilityProbe(
                    .webSearchResponses,
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将向当前中转发送一次真实 Web Search（Responses）请求，并在同一响应中验证来源引用。会联网，并可能产生额外 API 及搜索费用；不会修改配置。"
            )
        }
        .confirmationDialog(
            "确认验证图片输入？",
            isPresented: $confirmsImageInputProbe
        ) {
            Button("确认联网并验证图片输入") {
                accessModel.runOptionalProviderCapabilityProbe(
                    .imageInput,
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "将向当前中转发送一次小型合成图片请求。会联网，并可能产生额外 API 费用；不会读取用户图片或修改配置。"
            )
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
        .onChange(of: accessModel.isCheckingCurrentConnection) {
            wasChecking, isChecking in
            guard wasChecking, !isChecking else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.providerProbeReceipts) {
            _, _ in
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
        .onChange(of: accessModel.isWorking) {
            wasWorking, isWorking in
            guard wasWorking, !isWorking else { return }
            model.refreshConfigurationHealth(
                using: accessModel
            )
        }
    }

    private func relayCard(
        _ profile: CodexRelayProfile
    ) -> some View {
        let isCurrent = accessModel.currentProviderID
            == profile.v011ProviderID
        let capability = profile.effectiveCapabilityProfile
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.headline)
                        if isCurrent {
                            Text("当前轨")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Color.green.opacity(0.13),
                                    in: Capsule()
                                )
                        }
                    }
                    Text(
                        profile.defaultModel
                            + " · Responses · "
                            + profile.v011ProviderID
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                capabilityEvidenceLabel(
                    profile,
                    isCurrent: isCurrent
                )
            }

            let configurationSummary = CapabilityOptionHelp
                .configurationSummary(
                    capability.configurationSummary
                )
            if configurationSummary.isEmpty {
                Text("尚未保存可显示的扩展能力。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 210), spacing: 8),
                    ],
                    alignment: .leading,
                    spacing: 7
                ) {
                ForEach(
                    configurationSummary,
                        id: \.self
                    ) { value in
                        Label(
                            value,
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.caption)
                    }
                }
            }

            HStack {
                Button("修改中转资料") {
                    editingSavedProfile = profile
                }
                .disabled(accessModel.isWorking)

                Button("设置并自动应用") {
                    editingProfile = profile
                }
                .buttonStyle(.borderedProminent)
                .disabled(accessModel.isWorking)

                Button("导入受管模型目录") {
                    catalogImportHelpProfile = profile
                }
                .disabled(accessModel.isWorking)

                if isCurrent {
                    Button("验证当前轨核心能力") {
                        confirmsCoreProbe = true
                    }
                    .disabled(
                        accessModel.isWorking
                            || accessModel
                                .isCheckingCurrentConnection
                    )
                }
            }

            optionalProbeControls(isCurrent: isCurrent)

            Text(
                isCurrent
                    ? "同轨保存走预写探针、快照、CAS、运行时验证和失败恢复；配置变化时只快速重开Codex，不扫描或改写历史会话。"
                    : "保存只更新受管档案；下次切换到该中转时自动应用。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "导入时只选包含 models 或 data 数组的 JSON；通常来自供应商导出的模型目录，不是截图、config.toml 或普通说明文档。"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    @ViewBuilder
    private func optionalProbeControls(
        isCurrent: Bool
    ) -> some View {
        if isCurrent {
            VStack(alignment: .leading, spacing: 8) {
                Text("真实可选探针")
                    .font(.callout.weight(.semibold))
                HStack {
                    Button("验证 Fast") {
                        confirmsFastProbe = true
                    }
                    Button("验证 Web Search 与来源引用") {
                        confirmsWebSearchProbe = true
                    }
                    Button("验证图片输入") {
                        confirmsImageInputProbe = true
                    }
                }
                .disabled(optionalProbeControlsDisabled)
                Text(
                    "每项都会先单独确认联网和可能产生的额外费用；只有确认后才发送一次真实请求。未配置的能力会保持阻止并说明原因。"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var optionalProbeControlsDisabled: Bool {
        accessModel.isWorking
            || accessModel.isRefreshing
            || accessModel.isCheckingCurrentConnection
    }

    private var localExtensionCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("本地扩展")
                .font(.headline)
            Text(
                "Skills、Plugins和MCP属于本机或账户扩展，不写进中转能力档。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("管理Codex Skills") {
                        openCodexDeepLink(
                            "codex://skills",
                            actionName: "Codex Skills管理"
                        )
                    }
                    Button("安装/授权Codex Plugins") {
                        openCodexDeepLink(
                            "codex://plugins/install/?marketplace=openai-curated",
                            actionName: "Codex Plugins安装与授权"
                        )
                    }
                    Button("在Codex设置管理MCP") {
                        openCodexDeepLink(
                            "codex://settings",
                            actionName: "Codex MCP设置"
                        )
                    }
                }
                HStack {
                    Button("只读核对兼容性") {
                        localTrustCenterOpen = true
                        localTrustModel.refresh(
                            codexEvidence:
                                localCodexCompatibilityEvidence
                        )
                    }
                    .accessibilityIdentifier(
                        "build134.capability-compatibility"
                    )
                    Button("查找并审查扩展") {
                        discoveryOpen = true
                    }
                    Button("刷新安装状态") {
                        model.refreshConfigurationHealth(
                            using: accessModel
                        )
                    }
                }
            }
            if localExtensionHealthItems.isEmpty {
                Text("尚未读取本地扩展状态。点击“刷新安装状态”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(localExtensionHealthItems) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.title)：\(item.state.rawValue)")
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(
                "只读核对统一显示Codex、Skills、Plugins、MCP与Hooks的证据来源和新鲜度；路径、权限与内容指纹收进技术详情。已配置不等于已连接或可执行。这些能力仍由Codex管理。"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        .padding(16)
        .background(
            Color.blue.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private var localExtensionHealthItems:
        [ConfigurationHealthItem] {
        let names: Set<String> = ["Skills", "Plugins", "MCP"]
        return model.configurationHealth?.items.filter {
            names.contains($0.title)
        } ?? []
    }

    private var localCodexCompatibilityEvidence:
        CapabilityCompatibilityCodexEvidence {
        guard let evidence = accessModel.compatibilityEvidence else {
            return .unverified
        }
        switch evidence.source {
        case .freshProbe:
            return CapabilityCompatibilityCodexEvidence(
                verdict: .compatible,
                source: .freshProbe,
                observedAt: evidence.observedAt,
                summary: evidence.summary
            )
        case .cachedProbe:
            return CapabilityCompatibilityCodexEvidence(
                verdict: .compatible,
                source: .cachedProbe,
                observedAt: evidence.observedAt,
                summary: evidence.summary
            )
        case .bundledContract:
            return CapabilityCompatibilityCodexEvidence(
                verdict: .compatible,
                source: .bundledContract,
                observedAt: nil,
                summary: evidence.summary
            )
        case .blocked:
            return CapabilityCompatibilityCodexEvidence(
                verdict: .blocked,
                source: .failedCheck,
                observedAt: evidence.observedAt,
                summary: evidence.summary
            )
        }
    }

    private func openCodexDeepLink(
        _ rawURL: String,
        actionName: String
    ) {
        guard let url = URL(string: rawURL) else {
            localError = "无法创建\(actionName)链接。"
            return
        }
        guard NSWorkspace.shared.open(url) else {
            localError =
                "Codex没有接受\(actionName)链接。请确认已安装Codex后重试。"
            return
        }
        localError = nil
    }

    private func performCapabilityCompatibilityAction(
        _ action: CapabilityCompatibilityPrimaryAction
    ) {
        switch action {
        case .refreshCodexCompatibility:
            accessModel.refresh()
        case .refreshLocalSnapshot:
            localTrustModel.refresh(
                codexEvidence: localCodexCompatibilityEvidence
            )
        case .openSkills:
            openCodexDeepLink(
                "codex://skills",
                actionName: "Codex Skills管理"
            )
        case .openPlugins:
            openCodexDeepLink(
                "codex://plugins/",
                actionName: "Codex Plugins"
            )
        case .openCodexSettings:
            openCodexDeepLink(
                "codex://settings",
                actionName: "Codex设置"
            )
        }
    }

    @ViewBuilder
    private func capabilityEvidenceLabel(
        _ profile: CodexRelayProfile,
        isCurrent: Bool
    ) -> some View {
        if !isCurrent {
            Label("保存后待切换验证", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let contractID =
                    accessModel.currentCodexContractID,
                  let profileHash = try?
                    ProviderCapabilityProfileIdentity.sha256(
                        profile.effectiveCapabilityProfile
                    ) {
            let receipts = ProviderCapabilityProbeEvidenceGate
                .currentReceipts(
                    accessModel.providerProbeReceipts,
                    expectedProviderID: profile.v011ProviderID,
                    expectedCodexContractID: contractID,
                    expectedProfileID: profile.id,
                    expectedCapabilityProfileSHA256:
                        profileHash
                )
            let result = ProviderProbeSuiteResult.evaluate(receipts)
            Label(
                result.decision == .blockBeforeWrite
                    ? "核心能力待验证"
                    : (result.optionalDifferences.isEmpty
                        ? "核心能力已验证"
                        : "已验证，有能力差异"),
                systemImage:
                    result.decision == .blockBeforeWrite
                        ? "questionmark.circle"
                        : "checkmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(
                result.decision == .blockBeforeWrite
                    ? Color.orange : Color.green
            )
        } else {
            Label("当前合同未绑定", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func importCatalog(
        _ result: Result<[URL], Error>
    ) {
        defer { catalogProfile = nil }
        do {
            let urls = try result.get()
            guard let url = urls.first,
                  let profile = catalogProfile else {
                return
            }
            let accessed =
                url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let payload = try Data(
                contentsOf: url,
                options: .mappedIfSafe
            )
            accessModel.importManagedModelCatalog(
                payload: payload,
                sourceName: url.lastPathComponent,
                sourceProfile: profile
            )
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func importCatalog(
        from url: URL,
        profile: CodexRelayProfile
    ) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let payload = try Data(
                contentsOf: url,
                options: .mappedIfSafe
            )
            accessModel.importManagedModelCatalog(
                payload: payload,
                sourceName: url.lastPathComponent,
                sourceProfile: profile
            )
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func startManagedModelCatalogScan(
        for profile: CodexRelayProfile,
        rootURL: URL? = nil
    ) {
        if let rootURL {
            guard FileManager.default.fileExists(
                atPath: rootURL.path
            ) else {
                localError =
                    "默认 .codex 目录不存在：\(rootURL.path)"
                return
            }
            scanManagedModelCatalogLocation(
                rootURL,
                profile: profile,
                sourceLabel: rootURL.lastPathComponent
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择文件夹或 JSON"
        panel.message =
            "选文件夹时，软件会先找可导入的模型目录 JSON；也可以直接选 JSON 文件。隐藏文件已显示。"
        panel.directoryURL = accessModel.codexHomeURL
            .deletingLastPathComponent()
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }
        scanManagedModelCatalogLocation(
            url,
            profile: profile,
            sourceLabel: url.lastPathComponent
        )
    }

    private func scanManagedModelCatalogLocation(
        _ url: URL,
        profile: CodexRelayProfile,
        sourceLabel: String
    ) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if url.hasDirectoryPath {
            let candidates =
                managedModelCatalogCandidates(
                    in: url,
                    profile: profile
                )
            if candidates.isEmpty {
                localError =
                    "这个文件夹里没找到可导入的模型目录 JSON。"
                return
            }
            if candidates.count == 1 {
                importCatalog(
                    from: candidates[0].url,
                    profile: profile
                )
                return
            }
            catalogImportReview =
                BeginnerManagedModelCatalogImportReview(
                    profile: profile,
                    sourceLabel: sourceLabel,
                    candidates: candidates
                )
            return
        }
        guard let candidate = managedModelCatalogCandidate(
            from: url,
            profile: profile
        ) else {
            localError =
                "这个 JSON 不是受管模型目录。请换另一个文件。"
            return
        }
        importCatalog(from: candidate.url, profile: profile)
    }

    private func managedModelCatalogCandidates(
        in folderURL: URL,
        profile: CodexRelayProfile
    ) -> [BeginnerManagedModelCatalogCandidate] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var candidates: [BeginnerManagedModelCatalogCandidate] = []
        let store = ManagedModelCatalogStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "json" else {
                continue
            }
            if let candidate = managedModelCatalogCandidate(
                from: url,
                profile: profile,
                store: store
            ) {
                candidates.append(candidate)
            }
        }
        candidates.sort {
            if $0.matchesDefaultModel != $1.matchesDefaultModel {
                return $0.matchesDefaultModel && !$1.matchesDefaultModel
            }
            if $0.modelIDs.count != $1.modelIDs.count {
                return $0.modelIDs.count > $1.modelIDs.count
            }
            return $0.url.lastPathComponent.localizedStandardCompare(
                $1.url.lastPathComponent
            ) == .orderedAscending
        }
        return candidates
    }

    private func managedModelCatalogCandidate(
        from url: URL,
        profile: CodexRelayProfile,
        store: ManagedModelCatalogStore? = nil
    ) -> BeginnerManagedModelCatalogCandidate? {
        guard url.pathExtension.lowercased() == "json" else {
            return nil
        }
        let store = store ?? ManagedModelCatalogStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        guard let payload = try? Data(
            contentsOf: url,
            options: .mappedIfSafe
        ) else {
            return nil
        }
        guard let models = try? store.parseModels(payload),
              !models.isEmpty else {
            return nil
        }
        return BeginnerManagedModelCatalogCandidate(
            url: url,
            modelIDs: models.map(\.modelID),
            matchesDefaultModel: models.contains {
                $0.modelID == profile.defaultModel
            }
        )
    }
}
