// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

struct RelayDirectoryView: View {
    let onUseEntry: (ProviderCatalogEntryV2) -> Void
    let configureCustom: () -> Void

    @State private var receipt: RelayCatalogImportReceipt?
    @State private var pendingPackageData: Data?
    @State private var pendingPackage: SignedRelayCatalogPackage?
    @State private var pendingPublicKeyData: Data?
    @State private var pendingKeyDocument: RelayCatalogPublicKeyDocument?
    @State private var pendingFingerprint = ""
    @State private var confirmsPublisherKey = false
    @State private var packageImporterOpen = false
    @State private var keyImporterOpen = false
    @State private var showsClearConfirmation = false
    @State private var status = "尚未导入签名目录。你仍可使用自定义Provider，不依赖预设品牌。"
    @State private var probeScheduleStatus =
        "导入目录后会建立本地复核计划；不会静默发送Key或模型请求"
    @State private var probeSchedule: RelayProbeScheduleState?
    @State private var confirmsPublicProbe = false
    @State private var isRunningPublicProbe = false
    @State private var errorMessage: String?

    private let cache = RelayDirectoryCacheStore()
    private let probeScheduleStore = RelayProbeScheduleStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("中转目录")
                        .font(.system(size: 28, weight: .bold))
                    Text("目录只帮助发现和核对服务，不绑定Krill、AIHUB、PoloAI或任何固定品牌。")
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    directoryActionCard(
                        title: "我还没有中转",
                        text: "可以先使用Agent官方通路；需要中转时再导入服务商资料。",
                        button: "去安装或登录Agent",
                        icon: "person.crop.circle.badge.questionmark"
                    ) {
                        configureCustom()
                    }
                    directoryActionCard(
                        title: "我有自己的中转",
                        text: "网址、QQ群截图或文字资料都可进入配置助手，不要求服务在目录里。",
                        button: "添加自定义Provider",
                        icon: "plus.circle"
                    ) {
                        configureCustom()
                    }
                }

                GroupBox("导入签名目录") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("目录包和发布者公钥必须分别取得。先核对公钥来源与指纹，再由软件验证签名；目录文件不能自带一个未经信任的公钥给自己作证。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("选择目录JSON") { packageImporterOpen = true }
                            Button("选择发布者公钥JSON") { keyImporterOpen = true }
                        }
                        if let package = pendingPackage {
                            Text("待导入：版本 \(package.payload.catalogVersion) · Key ID \(package.keyID) · \(package.payload.entries.count) 条记录")
                                .font(.callout)
                        }
                        if let key = pendingKeyDocument {
                            Text("发布者：\(key.displayName) · Key ID \(key.keyID)")
                                .font(.callout)
                            Text("SHA-256：\(pendingFingerprint)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Toggle("我已从发布者的独立可信渠道核对这个Key ID和指纹", isOn: $confirmsPublisherKey)
                                .toggleStyle(.checkbox)
                        }
                        Button("验证签名并导入") { importPendingDirectory() }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                pendingPackageData == nil
                                    || pendingPublicKeyData == nil
                                    || !confirmsPublisherKey
                            )
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Text(probeScheduleStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                    .padding(.top, 6)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                if let receipt {
                    importedDirectory(receipt)
                } else {
                    Label(
                        "没有目录也能正常使用：自定义Provider入口始终保留，缺失字段会要求用户核对，不会猜。",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.green)
                }
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { loadCache() }
        .fileImporter(
            isPresented: $packageImporterOpen,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importPackageFile(result)
        }
        .fileImporter(
            isPresented: $keyImporterOpen,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importKeyFile(result)
        }
        .confirmationDialog(
            "清除已导入目录？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("只清除AI接入助手的目录缓存", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("不会删除配置档、Key或目标Agent设置。")
        }
    }

    @ViewBuilder
    private func importedDirectory(_ receipt: RelayCatalogImportReceipt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已验证目录 \(receipt.catalogVersion)").font(.headline)
                    Text("发布者：\(receipt.publisherName) · 导入：\(receipt.importedAt.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清除目录缓存") { showsClearConfirmation = true }
            }
            Text("公钥指纹：\(receipt.publicKeyFingerprint)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Toggle(
                    "允许本次联系到期记录的公开文档地址，只检查文档与TLS",
                    isOn: $confirmsPublicProbe
                )
                Button(
                    isRunningPublicProbe
                        ? "探针运行中…" : "运行到期公开探针"
                ) {
                    runDuePublicProbes(receipt)
                }
                .disabled(
                    !confirmsPublicProbe
                        || isRunningPublicProbe
                        || RelayProbeScheduler.dueTasks(
                            probeSchedule
                                ?? RelayProbeScheduleState(
                                    schemaVersion:
                                        RelayProbeScheduleState
                                            .currentSchemaVersion,
                                    generatedAt: Date(),
                                    tasks: []
                                ),
                            now: Date()
                        ).isEmpty
                )
            }
            .font(.caption)
            if !receipt.revokedEntryIDs.isEmpty {
                Label(
                    "撤销清单：\(receipt.revokedEntryIDs.joined(separator: "、"))",
                    systemImage: "xmark.octagon.fill"
                )
                .foregroundStyle(.red)
            }
            ForEach(receipt.entries) { entry in
                relayEntryCard(entry)
            }
        }
    }

    private func relayEntryCard(_ entry: ProviderCatalogEntryV2) -> some View {
        let localProbe = probeSchedule?.tasks.first {
            $0.entryID == entry.id
        }
        let effectiveState = RelayCatalogGovernance.effectiveState(
            entry: entry,
            localProbe: localProbe,
            now: Date()
        )
        let oneClick = RelayCatalogGovernance.allowsOneClick(
            entry,
            localProbe: localProbe,
            now: Date()
        )
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.serviceName).font(.headline)
                    Text(entry.serviceType.localizedName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(effectiveState.localizedName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(effectiveState.displayColor)
            }
            Text(entry.baseURLPattern ?? "Base URL需要用户按账号或区域填写")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Text("协议：\(entry.protocols.isEmpty ? "未提供" : entry.protocols.joined(separator: "、"))")
                .font(.callout)
            Text("模型：\(entry.models.isEmpty ? "未提供，需在线拉取或手填" : entry.models.joined(separator: "、"))")
                .font(.callout)
            VStack(alignment: .leading, spacing: 3) {
                Text("兼容矩阵").font(.caption.weight(.semibold))
                compatibilityLine("Codex Desktop", entry.supportedAgents.contains("codexDesktop"))
                compatibilityLine("Claude Desktop", entry.supportedAgents.contains("claudeDesktop"))
                compatibilityLine("Cherry Studio", entry.supportedAgents.contains("cherryStudio"))
            }
            Text("核验：\(entry.verification.verifiedAt.formatted()) · \(entry.verification.verifierID)")
                .font(.caption).foregroundStyle(.secondary)
            if localProbe?.requiresAuthenticatedVerification == true {
                Label(
                    "公开文档/TLS已单独核对；模型列表和最小请求仍需中转Key及单独授权。",
                    systemImage: "key.horizontal"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            ForEach(entry.verification.evidenceURLs, id: \.absoluteString) { url in
                Link(url.absoluteString, destination: url)
                    .font(.caption)
            }
            if !entry.knownIssues.isEmpty {
                Label(entry.knownIssues.joined(separator: "；"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("带入配置助手继续核对") { onUseEntry(entry) }
                    .buttonStyle(.borderedProminent)
                    .disabled(effectiveState == .anomalous || effectiveState == .revoked)
                Text(oneClick ? "证据完整，可进入一键接入前核对" : "仅可预填；真实一键接入证据不足")
                    .font(.caption)
                    .foregroundStyle(oneClick ? Color.green : Color.orange)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func compatibilityLine(_ agent: String, _ declared: Bool) -> some View {
        HStack {
            Text(agent).frame(width: 150, alignment: .leading)
            Text(declared ? "目录声明支持，仍按本机适配器复核" : "未声明支持")
                .foregroundStyle(declared ? Color.green : Color.secondary)
        }
        .font(.caption)
    }

    private func directoryActionCard(
        title: String,
        text: String,
        button: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(button, action: action)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 135, alignment: .leading)
        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func loadCache() {
        do {
            receipt = try cache.load()
            if let receipt {
                status = "已载入签名目录 \(receipt.catalogVersion)。"
                try reconcileProbeSchedule(receipt)
            }
        } catch {
            errorMessage = "目录缓存无法读取：\(error.localizedDescription)"
        }
    }

    private func importPackageFile(_ result: Result<[URL], Error>) {
        do {
            let data = try readFirstFile(result)
            let package = try RelayCatalogPackageImporter.decodePackage(data)
            pendingPackageData = data
            pendingPackage = package
            confirmsPublisherKey = false
            errorMessage = nil
            status = "目录包已读取；请另行选择发布者公钥并核对指纹。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importKeyFile(_ result: Result<[URL], Error>) {
        do {
            let data = try readFirstFile(result)
            let decoded = try RelayCatalogPackageImporter.decodePublicKey(data)
            pendingPublicKeyData = data
            pendingKeyDocument = decoded.document
            pendingFingerprint = RelayCatalogPackageImporter.fingerprint(decoded.key.rawRepresentation)
            confirmsPublisherKey = false
            errorMessage = nil
            status = "公钥已读取；请通过发布者的独立渠道核对Key ID和指纹。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPendingDirectory() {
        guard let pendingPackageData, let pendingPublicKeyData else { return }
        do {
            let imported = try RelayCatalogPackageImporter.importPackage(
                packageData: pendingPackageData,
                publicKeyData: pendingPublicKeyData
            )
            try cache.save(imported)
            receipt = imported
            try reconcileProbeSchedule(imported)
            status = "签名有效；目录已导入。"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCache() {
        do {
            try cache.clear()
            try probeScheduleStore.clear()
            receipt = nil
            probeSchedule = nil
            status = "目录缓存已清除；自定义Provider入口仍可使用。"
            probeScheduleStatus =
                "目录复核计划已清除；不影响配置档或目标Agent"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileProbeSchedule(
        _ receipt: RelayCatalogImportReceipt
    ) throws {
        let now = Date()
        let schedule = RelayProbeScheduler.reconcile(
            entries: receipt.entries,
            previous: try probeScheduleStore.load(),
            now: now
        )
        try probeScheduleStore.save(schedule)
        probeSchedule = schedule
        let due = RelayProbeScheduler.dueTasks(schedule, now: now)
        if due.isEmpty {
            let next = schedule.tasks.first?.nextDueAt.formatted()
                ?? "无待核验记录"
            probeScheduleStatus =
                "本地定时复核计划已建立；下次：\(next)。网络探针不会在未授权时静默运行。"
        } else {
            probeScheduleStatus =
                "有\(due.count)条目录记录到期待复核；已取消其自动可信推断，等待用户运行网络验证。"
        }
    }

    private func runDuePublicProbes(
        _ receipt: RelayCatalogImportReceipt
    ) {
        guard confirmsPublicProbe,
              let schedule = probeSchedule else {
            errorMessage = "先确认本次公开文档和TLS探针"
            return
        }
        let due = RelayProbeScheduler.dueTasks(
            schedule,
            now: Date()
        )
        guard !due.isEmpty else {
            probeScheduleStatus = "当前没有到期目录记录"
            return
        }
        isRunningPublicProbe = true
        Task {
            var updated = schedule
            var passed = 0
            var failed = 0
            do {
                for task in due {
                    guard let entry = receipt.entries.first(
                        where: { $0.id == task.entryID }
                    ) else { continue }
                    let result = try await
                        RelayDirectoryPublicProbeRunner.run(
                            entry: entry,
                            task: task,
                            userAuthorized: true
                        )
                    updated = RelayProbeScheduler.recording(
                        result,
                        in: updated
                    )
                    if result.hasFailure {
                        failed += 1
                    } else {
                        passed += 1
                    }
                }
                try probeScheduleStore.save(updated)
                probeSchedule = updated
                probeScheduleStatus =
                    "公开文档/TLS探针完成：\(passed)条通过，\(failed)条失败。模型列表与最小请求未使用Key，仍保持待核验。"
                errorMessage = nil
            } catch {
                errorMessage =
                    "公开目录探针停止：\(error.localizedDescription)"
            }
            confirmsPublicProbe = false
            isRunningPublicProbe = false
        }
    }

    private func readFirstFile(_ result: Result<[URL], Error>) throws -> Data {
        let urls = try result.get()
        guard let url = urls.first else { throw RelayCatalogSecurityError.malformedPackage }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

private extension RelayServiceType {
    var localizedName: String {
        switch self {
        case .officialAPI: return "官方API"
        case .compatibleService: return "兼容服务"
        case .thirdPartyRelay: return "第三方中转"
        }
    }
}

private extension RelayCatalogRecordState {
    var localizedName: String {
        switch self {
        case .verified: return "已核验"
        case .reviewRequired: return "待复核"
        case .anomalous: return "异常"
        case .revoked: return "已撤销"
        }
    }

    var displayColor: Color {
        switch self {
        case .verified: return .green
        case .reviewRequired: return .orange
        case .anomalous, .revoked: return .red
        }
    }
}
