// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

struct CapabilityDiscoveryView: View {
    @State private var goal = ""
    @State private var analysis: CapabilityGoalAnalysis?
    @State private var isSearching = false
    @State private var repositories: [DiscoveredCapabilityRepository] = []
    @State private var searchError: String?
    @State private var localPackageImporterOpen = false
    @State private var selectedRepository: DiscoveredCapabilityRepository?
    @State private var inspection: CapabilityLocalInspectionResult?
    @State private var installationPlan: CapabilityInstallationPlan?
    @State private var confirmsInstallationPlan = false
    @State private var confirmsRealSkillInstallation = false
    @State private var confirmsManagedSkillUninstall = false
    @State private var pendingManagedSkillUninstall:
        CapabilityInstalledManifest?
    @State private var unpersistedSkillManifest:
        CapabilityInstalledManifest?
    @State private var managedSkillManifests:
        [CapabilityInstalledManifest] = []
    @State private var managedSkillStatus: String?
    @State private var sandboxReceipt: CapabilitySandboxReceipt?
    @State private var sandboxStatus: String?
    @State private var trustedCatalog: CapabilityCatalogReceipt?
    @State private var aggregation: CapabilitySourceAggregation?
    @State private var capabilityCatalogPackageData: Data?
    @State private var capabilityCatalogKeyData: Data?
    @State private var capabilityCatalogPackageImporterOpen = false
    @State private var capabilityCatalogKeyImporterOpen = false
    @State private var confirmsCapabilityCatalogKey = false
    @State private var capabilityCatalogStatus = "尚未导入可信能力目录"
    @State private var githubLocks: [Int: GitHubCapabilityLock] = [:]
    @State private var lockingRepositoryIDs = Set<Int>()

    private let capabilityCatalogStore = CapabilityCatalogStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("能力中心")
                        .font(.system(size: 28, weight: .bold))
                    Text("先告诉我你想完成什么，不需要先知道Skill、Plugin、MCP或Hook名称。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("例如：我想分析Excel并生成图表", text: $goal)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { analyze() }
                    Button("拆解需求") { analyze() }
                        .buttonStyle(.borderedProminent)
                        .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let analysis {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("需求拆解").font(.headline)
                        ForEach(analysis.requirements) { requirement in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(requirement.description).fontWeight(.semibold)
                                Text("候选类型：\(requirement.requiredPackageTypes.map(\.rawValue).joined(separator: "、"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("对外搜索只发送这些必要关键词：\(analysis.privacyKeywordsSentToSearch.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button {
                                search(analysis)
                            } label: {
                                if isSearching {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("联网检索GitHub公开仓库", systemImage: "magnifyingglass")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSearching)
                            Button("查看官方Skills与Plugins") {
                                NSWorkspace.shared.open(
                                    URL(string: "https://learn.chatgpt.com/docs/skills-and-plugins")!
                                )
                            }
                        }
                    }
                    .padding(14)
                    .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("候选顺序").font(.headline)
                    Text("1. 当前Agent原生能力\n2. OpenAI或Agent官方能力\n3. 已信任组织和已核验目录\n4. GitHub公开仓库\n5. 用户本地导入")
                    Text("星标和搜索排名只作参考。候选必须再检查权限、脚本、二进制、OAuth、网络、依赖和卸载清单。")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                if let aggregation {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("官方来源").font(.headline)
                        ForEach(aggregation.officialReferences) { reference in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(reference.title).fontWeight(.semibold)
                                    Text(reference.summary).font(.callout)
                                    Text(reference.limitation)
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                Spacer()
                                Link("打开官方文档", destination: reference.documentationURL)
                            }
                            .padding(10)
                            .background(.blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("可信签名目录").font(.headline)
                        Spacer()
                        Button("选择目录JSON") {
                            capabilityCatalogPackageImporterOpen = true
                        }
                        Button("选择发布者公钥") {
                            capabilityCatalogKeyImporterOpen = true
                        }
                    }
                    Text("目录和公钥必须来自独立渠道。目录只能提供官方或已核验来源，不能把普通GitHub仓库自称可信。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(
                        "我已从发布者独立渠道核对Key ID和公钥指纹来源",
                        isOn: $confirmsCapabilityCatalogKey
                    )
                    .toggleStyle(.checkbox)
                    Button("验签并导入能力目录") { importCapabilityCatalog() }
                        .disabled(
                            capabilityCatalogPackageData == nil
                                || capabilityCatalogKeyData == nil
                                || !confirmsCapabilityCatalogKey
                        )
                    Text(capabilityCatalogStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    if let aggregation {
                        ForEach(aggregation.trustedPackages) { package in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(package.displayName).fontWeight(.semibold)
                                    Text(package.summary).font(.callout)
                                    Text("\(package.type.rawValue) · \(package.version) · \(package.maintainer)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("核验：\(package.verificationMethod ?? "未知")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let url = package.marketplaceURL ?? package.repositoryURL {
                                    Link("查看来源", destination: url)
                                }
                            }
                            .padding(10)
                            .background(.green.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                ForEach(repositories) { repository in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repository.fullName).font(.headline)
                            Text(repository.summary ?? "没有简介")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("Stars \(repository.stars) · Forks \(repository.forks) · License \(repository.license ?? "未知")")
                                .font(.caption).foregroundStyle(.secondary)
                            Label(repository.initialRiskLabel, systemImage: "shield.lefthalf.filled")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("查看证据") {
                                NSWorkspace.shared.open(repository.repositoryURL)
                            }
                            Button {
                                lockGitHubRepository(repository)
                            } label: {
                                if lockingRepositoryIDs.contains(repository.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(githubLocks[repository.id] == nil
                                        ? "锁定Commit/Release" : "已锁定Commit")
                                }
                            }
                            .disabled(
                                lockingRepositoryIDs.contains(repository.id)
                                    || githubLocks[repository.id] != nil
                            )
                            Button("审查本地下载包") {
                                selectedRepository = repository
                                localPackageImporterOpen = true
                            }
                            if let lock = githubLocks[repository.id] {
                                Text(String(lock.commitSHA.prefix(12)))
                                    .font(.system(.caption, design: .monospaced))
                                Text(lock.releaseTag ?? "无Release，按Commit锁定")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }

                if let inspection, let installationPlan {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("静态审查与试装计划").font(.headline)
                        Text("来源：\(selectedRepository?.fullName ?? "用户本地导入")")
                        Text("文件 \(inspection.relativeFiles.count) 个 · \(inspection.totalBytes) bytes")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("内容指纹：\(inspection.treeSHA256)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Label(
                            inspection.review.riskLevel.localizedName,
                            systemImage: inspection.review.riskLevel == .high
                                ? "xmark.octagon.fill" : "checkmark.shield"
                        )
                        .foregroundStyle(inspection.review.riskLevel == .high ? Color.red : Color.orange)
                        if inspection.review.findings.isEmpty {
                            Text("未发现当前规则可识别的高风险项；这不等于第三方代码绝对安全。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(inspection.review.findings) { finding in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(finding.severity.localizedName)：\(finding.explanation)")
                                        .font(.callout.weight(.semibold))
                                    Text(finding.evidence)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        Text("锁定版本：\(installationPlan.pinnedVersion)")
                            .font(.caption)
                        Text("试装只复制到AI接入助手临时目录，不写Skills、MCP、Plugins、Hooks或Agent配置。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle(
                            "我已核对来源、文件、风险和卸载清单，同意仅在临时目录试装",
                            isOn: $confirmsInstallationPlan
                        )
                        .toggleStyle(.checkbox)
                        HStack {
                            Button("在临时目录试装") {
                                stageInSandbox(installationPlan, inspection)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                !confirmsInstallationPlan
                                    || inspection.review.riskLevel == .high
                                    || sandboxReceipt != nil
                                    || (selectedRepository != nil
                                        && installationPlan.pinnedCommitSHA == nil)
                            )
                            if let sandboxReceipt {
                                Button("撤销临时试装") { rollbackSandbox(sandboxReceipt) }
                            }
                        }
                        if let sandboxStatus {
                            Text(sandboxStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("安装到Codex Skills")
                            .font(.callout.weight(.semibold))
                        Text(
                            "目标：\(managedSkillTargetText(for: installationPlan))"
                        )
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        Text(
                            "真实安装会再次显示精确目标和文件数；同名目录不覆盖。卸载只删除本次创建且hash未变化的文件，保留用户后来新增或修改的内容。"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Button("安装到Codex Skills") {
                            confirmsRealSkillInstallation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !installationPlan.expectedFiles.contains(
                                "SKILL.md"
                            )
                                || inspection.review.riskLevel == .high
                                || inspection.review.riskLevel == .unknown
                                || (selectedRepository != nil
                                    && installationPlan.pinnedCommitSHA == nil)
                        )
                        if let managedSkillStatus {
                            Text(managedSkillStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }

                if !managedSkillManifests.isEmpty
                    || unpersistedSkillManifest != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI接入助手管理的Skills")
                            .font(.headline)
                        ForEach(
                            managedSkillManifests,
                            id: \.transactionID
                        ) { manifest in
                            managedSkillRow(manifest)
                        }
                        if let unpersistedSkillManifest {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    unpersistedSkillManifest.packageID
                                )
                                .fontWeight(.semibold)
                                Text(
                                    "文件已安装，但持久回执失败；未自动回滚。仅本页保留恢复清单。"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                                Button(
                                    "撤销未入账安装",
                                    role: .destructive
                                ) {
                                    uninstallUnpersistedSkill(
                                        unpersistedSkillManifest
                                    )
                                }
                            }
                            .padding(10)
                            .background(
                                Color.red.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                    }
                    .padding(14)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }

                Label(
                    "真实安装必须再次由用户确认。当前页面不会静默安装Skill、MCP、Plugin、Hook或路由。",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(.orange)
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $localPackageImporterOpen,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            inspectLocalPackage(result)
        }
        .fileImporter(
            isPresented: $capabilityCatalogPackageImporterOpen,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            capabilityCatalogPackageData = readImportedData(result)
            confirmsCapabilityCatalogKey = false
        }
        .fileImporter(
            isPresented: $capabilityCatalogKeyImporterOpen,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            capabilityCatalogKeyData = readImportedData(result)
            confirmsCapabilityCatalogKey = false
        }
        .confirmationDialog(
            "确认真实安装Skill？",
            isPresented: $confirmsRealSkillInstallation,
            titleVisibility: .visible
        ) {
            if let plan = installationPlan,
               let inspection {
                Button("确认安装到Codex Skills") {
                    installManagedSkill(
                        plan,
                        inspection
                    )
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            if let plan = installationPlan {
                Text(
                    "将写入\(managedSkillTargetText(for: plan))，共\(plan.expectedFiles.count)个已审查文件。同名目录不覆盖；不会执行包内命令。"
                )
            }
        }
        .confirmationDialog(
            "确认卸载此Skill？",
            isPresented: $confirmsManagedSkillUninstall,
            titleVisibility: .visible
        ) {
            if let manifest = pendingManagedSkillUninstall {
                Button("确认按回执卸载", role: .destructive) {
                    uninstallManagedSkill(manifest)
                }
            }
            Button("取消", role: .cancel) {
                pendingManagedSkillUninstall = nil
            }
        } message: {
            if let manifest = pendingManagedSkillUninstall {
                Text(
                    "只删除事务\(manifest.transactionID)创建且hash未变化的\(manifest.createdPaths.count)个文件；用户新增或修改内容会保留并停止。"
                )
            }
        }
        .onAppear {
            loadCapabilityCatalog()
            loadManagedSkills()
        }
    }

    private func analyze() {
        let value = CapabilityGoalAnalyzer.analyze(goal)
        analysis = value
        repositories = []
        aggregation = CapabilitySourceAggregator.aggregate(
            analysis: value,
            trustedCatalog: trustedCatalog,
            githubRepositories: []
        )
        searchError = nil
    }

    private func search(_ analysis: CapabilityGoalAnalysis) {
        isSearching = true
        searchError = nil
        Task {
            do {
                repositories = try await CapabilityDiscoveryService.searchGitHub(
                    keywords: analysis.privacyKeywordsSentToSearch
                )
                if repositories.isEmpty {
                    searchError = "没有找到可识别候选；可调整目标描述。"
                }
                aggregation = CapabilitySourceAggregator.aggregate(
                    analysis: analysis,
                    trustedCatalog: trustedCatalog,
                    githubRepositories: repositories
                )
            } catch {
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func inspectLocalPackage(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                throw CapabilityLocalInspectionError.notDirectory
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let result = try CapabilityLocalPackageInspector.inspect(root: url)
            inspection = result
            let plan: CapabilityInstallationPlan
            if let repository = selectedRepository,
               let lock = githubLocks[repository.id] {
                plan = try CapabilityPlanFactory.makeReviewedGitHubPlan(
                    repository: repository,
                    lock: lock,
                    inspection: result
                )
            } else {
                plan = CapabilityPlanFactory.makeLocalReviewPlan(
                    packageID: selectedRepository?.fullName ?? url.lastPathComponent,
                    sourceURL: selectedRepository?.repositoryURL,
                    inspection: result
                )
            }
            try CapabilityPlanLockStore().save(CapabilityPlanLockDocument(
                plan: plan,
                sourceTreeSHA256: result.treeSHA256,
                reviewRiskLevel: result.review.riskLevel,
                createdAt: Date()
            ))
            installationPlan = plan
            confirmsInstallationPlan = false
            sandboxReceipt = nil
            sandboxStatus = selectedRepository != nil && plan.pinnedCommitSHA == nil
                ? "静态审查完成；GitHub来源尚未锁定Commit，已阻止试装。"
                : "静态审查完成；0600锁定清单已保存。请核对后决定是否进行临时试装。"
            searchError = nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func stageInSandbox(
        _ plan: CapabilityInstallationPlan,
        _ inspection: CapabilityLocalInspectionResult
    ) {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ai-access-capability-\(plan.id)", isDirectory: true)
            let receipt = try CapabilitySandboxInstaller.stage(
                plan: plan,
                inspection: inspection,
                sandboxRoot: root,
                userConfirmed: confirmsInstallationPlan
            )
            sandboxReceipt = receipt
            sandboxStatus = "临时试装完成：\(receipt.stagedFiles.count)个文件；尚未安装到任何Agent。"
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func rollbackSandbox(_ receipt: CapabilitySandboxReceipt) {
        do {
            let root = URL(fileURLWithPath: receipt.sandboxRoot, isDirectory: true)
            try CapabilitySandboxInstaller.rollback(sandboxRoot: root, receipt: receipt)
            sandboxReceipt = nil
            sandboxStatus = "临时试装已撤销；真实Agent和用户配置未改变。"
        } catch {
            searchError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func managedSkillRow(
        _ manifest: CapabilityInstalledManifest
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(manifest.packageID)
                    .fontWeight(.semibold)
                Text(
                    managedSkillTargetText(
                        forPackageID: manifest.packageID
                    )
                )
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                Text(
                    "受管文件\(manifest.createdPaths.count)个 · 事务\(manifest.transactionID)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("卸载", role: .destructive) {
                pendingManagedSkillUninstall = manifest
                confirmsManagedSkillUninstall = true
            }
        }
        .padding(10)
        .background(
            Color.blue.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private var localSkillsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".agents",
                isDirectory: true
            )
            .appendingPathComponent(
                "skills",
                isDirectory: true
            )
    }

    private var localSkillManifestStoreURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        return support
            .appendingPathComponent(
                "AI接入助手/ControlPlane/LocalExtensions",
                isDirectory: true
            )
            .appendingPathComponent("skills.json")
    }

    private func localSkillService()
        throws -> LocalSkillManagementService {
        try LocalSkillManagementService(
            skillsRoot: localSkillsRoot,
            manifestStoreURL: localSkillManifestStoreURL
        )
    }

    private func managedSkillTargetText(
        for plan: CapabilityInstallationPlan
    ) -> String {
        managedSkillTargetText(forPackageID: plan.packageID)
    }

    private func managedSkillTargetText(
        forPackageID packageID: String
    ) -> String {
        do {
            return try localSkillService()
                .targetDirectory(for: packageID).path
        } catch {
            return "目标路径无效：\(error.localizedDescription)"
        }
    }

    private func installManagedSkill(
        _ plan: CapabilityInstallationPlan,
        _ inspection: CapabilityLocalInspectionResult
    ) {
        let accessed = inspection.rootURL
            .startAccessingSecurityScopedResource()
        defer {
            if accessed {
                inspection.rootURL
                    .stopAccessingSecurityScopedResource()
            }
        }
        do {
            let transaction = try localSkillService().install(
                plan: plan,
                inspection: inspection,
                userConfirmed: true
            )
            guard let manifest = transaction.manifest else {
                throw LocalSkillManagementError
                    .committedManifestMissing
            }
            managedSkillStatus =
                "已安装\(manifest.createdPaths.count)个文件；hash和持久回执已验证。Codex通常会自动发现，未显示时重启Codex。"
            unpersistedSkillManifest = nil
            searchError = nil
            loadManagedSkills()
        } catch let error as LocalSkillManagementError {
            if case let .manifestPersistenceFailed(
                manifest,
                _
            ) = error {
                unpersistedSkillManifest = manifest
            }
            searchError = error.localizedDescription
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func loadManagedSkills() {
        do {
            managedSkillManifests = try localSkillService()
                .installedManifests()
        } catch {
            managedSkillManifests = []
            searchError = error.localizedDescription
        }
    }

    private func uninstallManagedSkill(
        _ manifest: CapabilityInstalledManifest
    ) {
        defer {
            pendingManagedSkillUninstall = nil
        }
        do {
            try localSkillService().uninstall(
                transactionID: manifest.transactionID
            )
            managedSkillStatus =
                "已按回执卸载\(manifest.packageID)；用户新增内容保持不变。"
            searchError = nil
            loadManagedSkills()
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func uninstallUnpersistedSkill(
        _ manifest: CapabilityInstalledManifest
    ) {
        do {
            try FilesystemSkillComponentAdapter.uninstall(
                manifest: manifest,
                skillsRoot: localSkillsRoot
            )
            unpersistedSkillManifest = nil
            managedSkillStatus = "未入账安装已按内存回执撤销。"
            searchError = nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func lockGitHubRepository(_ repository: DiscoveredCapabilityRepository) {
        lockingRepositoryIDs.insert(repository.id)
        searchError = nil
        Task {
            do {
                githubLocks[repository.id] = try await GitHubCapabilityLockService.lock(
                    repository: repository
                )
            } catch {
                searchError = error.localizedDescription
            }
            lockingRepositoryIDs.remove(repository.id)
        }
    }

    private func loadCapabilityCatalog() {
        do {
            trustedCatalog = try capabilityCatalogStore.load()
            if let trustedCatalog {
                capabilityCatalogStatus = "已载入\(trustedCatalog.publisherName)目录 \(trustedCatalog.catalogVersion)。"
            }
            if let analysis {
                aggregation = CapabilitySourceAggregator.aggregate(
                    analysis: analysis,
                    trustedCatalog: trustedCatalog,
                    githubRepositories: repositories
                )
            }
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func importCapabilityCatalog() {
        guard let capabilityCatalogPackageData,
              let capabilityCatalogKeyData else { return }
        do {
            let receipt = try SignedCapabilityCatalogVerifier.importPackage(
                packageData: capabilityCatalogPackageData,
                publicKeyData: capabilityCatalogKeyData
            )
            try capabilityCatalogStore.save(receipt)
            trustedCatalog = receipt
            capabilityCatalogStatus = "签名有效：\(receipt.publisherName) · \(receipt.catalogVersion) · \(receipt.packages.count)项。"
            if let analysis {
                aggregation = CapabilitySourceAggregator.aggregate(
                    analysis: analysis,
                    trustedCatalog: receipt,
                    githubRepositories: repositories
                )
            }
            searchError = nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func readImportedData(
        _ result: Result<[URL], Error>
    ) -> Data? {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return nil }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            searchError = error.localizedDescription
            return nil
        }
    }
}

private extension CapabilityRiskLevel {
    var localizedName: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中风险，需要核对"
        case .high: return "高风险，已阻止"
        case .unknown: return "风险未知，已阻止"
        }
    }
}
