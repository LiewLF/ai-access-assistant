// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationProfilesView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    let openExecution: () -> Void
    @State private var backupImporterOpen = false
    @State private var legacyBackupImporterOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("配置档与真实状态")
                        .font(.system(size: 28, weight: .bold))
                    Text("真实文件、助手记录和运行轨必须一致，写入按钮才会启用。")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            model.allowsManagedWrite ? "状态一致" : "状态未通过",
                            systemImage: model.allowsManagedWrite ? "checkmark.shield.fill" : "exclamationmark.octagon.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(model.allowsManagedWrite ? Color.green : Color.red)
                        Text(model.runtimeTruthStatus)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("重新核对") { model.refreshRuntimeTruth() }
                }
                .padding(16)
                .background(
                    (model.allowsManagedWrite ? Color.green : Color.red).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("Codex官方诊断").font(.headline)
                    Text(model.codexDoctorStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Toggle(
                        "允许本次只读配置并执行网络连通性检查",
                        isOn: $model.confirmsCodexDoctorDiagnostic
                    )
                    Button(
                        model.isRunningCodexDoctorDiagnostic
                            ? "诊断中…" : "运行Codex官方脱敏诊断"
                    ) {
                        model.runCodexDoctorDiagnostic()
                    }
                    .disabled(
                        !model.confirmsCodexDoctorDiagnostic
                            || model.isRunningCodexDoctorDiagnostic
                    )
                }
                .padding(14)
                .background(
                    Color.blue.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                HStack(alignment: .top) {
                    Label(
                        model.bundledRecoveryAllowsManagedRelay
                            ? "恢复链完整" : "恢复链不完整",
                        systemImage: model.bundledRecoveryAllowsManagedRelay
                            ? "lifepreserver.fill"
                            : "exclamationmark.octagon.fill"
                    )
                    .foregroundStyle(
                        model.bundledRecoveryAllowsManagedRelay
                            ? Color.green : Color.red
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.bundledRecoveryStatus)
                            .font(.caption)
                            .textSelection(.enabled)
                        Button("重新检查恢复链") {
                            model.refreshBundledRecoveryHealth()
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    (
                        model.bundledRecoveryAllowsManagedRelay
                            ? Color.green : Color.red
                    ).opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("导出脱敏配置结构").font(.headline)
                    Text(model.governanceFixtureExportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        "允许本次只读我选择的TOML；输出不含配置值、路径名或Key",
                        isOn:
                            $model.confirmsGovernanceFixtureExport
                    )
                    Button("选择TOML并导出结构证据") {
                        model.exportGovernanceStructureFixture()
                    }
                    .disabled(
                        !model.confirmsGovernanceFixtureExport
                    )
                }
                .padding(14)
                .background(
                    Color.purple.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12)
                )

                if model.runtimeDriftDetected {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("发现外部变化，托管写入已暂停", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(model.runtimeDriftSummary)
                            .font(.callout)
                            .textSelection(.enabled)
                        HStack {
                            Button("进入执行页核对") { openExecution() }
                                .buttonStyle(.borderedProminent)
                            Button("暂不处理") { model.dismissRuntimeDrift() }
                        }
                    }
                    .padding(14)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                if model.runtimeTruth?.runtimeMode == .relay,
                   (
                    model.codexRuntimeMode != .relay
                        || model.activeRelayIsUnverified
                   ) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("真实中转与助手记录不一致")
                            .font(.headline)
                        Text(
                            "真实配置正在使用 \(model.runtimeTruth?.activeProviderID ?? "现有中转")，但助手仍记录为\(model.codexRuntimeMode.rawValue)。先只读接管；不改config.toml、不读取Key正文，custom保持原ID。"
                        )
                            .font(.callout).foregroundStyle(.secondary)
                        TextField(
                            "显示名称，可留空使用现有名称",
                            text: $model.existingProviderDisplayName
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("只读接管当前Provider") {
                            model.importExistingProviderReadOnly()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if let report = model.existingProviderImportReport {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            report.targetConfigurationUnchanged
                                ? "目标配置零写入"
                                : "目标配置发生变化",
                            systemImage: report.targetConfigurationUnchanged
                                ? "checkmark.shield.fill"
                                : "xmark.octagon.fill"
                        )
                        .foregroundStyle(report.targetConfigurationUnchanged ? Color.green : Color.red)
                        Text("Provider：\(report.providerID) · 字节数：\(report.byteCount)")
                            .font(.caption)
                        Text("写前哈希：\(report.configHashBefore)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        ForEach(report.warnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(14)
                    .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }

                profileCard(
                    name: "官方模式",
                    detail: model.officialBaseline == nil
                        ? "尚未建立。必须先确认官方请求可用。"
                        : "官方候选覆盖层已建立；真实官方请求成功后才能标记已验证。日常切换不会整份覆盖MCP、Hooks、Projects或认证。",
                    active: model.codexRuntimeMode == .official
                )
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("官方覆盖层候选").font(.headline)
                            Text("并排比较候选；只提取Provider根值，不整份恢复旧MCP、项目或权限配置。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重新生成") { model.refreshOfficialCandidates() }
                        Button("选择config.toml备份") { backupImporterOpen = true }
                    }
                    Text(model.officialCandidateStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.officialCandidates) { candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(candidate.displayName).fontWeight(.semibold)
                                Spacer()
                                Text(candidate.state == .verified ? "已验证" : (candidate.state == .candidate ? "候选" : "证据不足"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(candidate.state == .verified ? Color.green : Color.orange)
                            }
                            Text("来源：\(candidate.source)")
                                .font(.caption)
                            Text("观察到的Provider：\(candidate.observedProviderID ?? "空值")")
                                .font(.caption)
                            Text("非Provider语义哈希：\(candidate.sourceNonProviderSemanticHash)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            if !candidate.nonProviderDifferencePaths.isEmpty {
                                Text("与当前配置不同，但不会自动恢复：")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                ForEach(candidate.nonProviderDifferencePaths.prefix(12), id: \.self) { path in
                                    Text("• \(path)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            ForEach(candidate.warnings, id: \.self) { warning in
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                            Button(
                                model.selectedOfficialCandidateID == candidate.id
                                    ? "当前已选候选" : "选为官方候选"
                            ) {
                                model.selectOfficialCandidate(candidate)
                            }
                            .disabled(
                                model.selectedOfficialCandidateID == candidate.id
                                    || candidate.state == .unknown
                            )
                        }
                        .padding(12)
                        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Label(
                        "只有由助手启动官方轨并完成真实最小请求后，候选才可升级为已验证；当前选择不会写config.toml。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.orange)
                    Toggle(
                        "我已在当前官方Codex发送真实请求并收到正常回复",
                        isOn: $model.confirmsOfficialRecoveryTest
                    )
                    .toggleStyle(.checkbox)
                    Button("记录官方验证证据") {
                        model.confirmOfficialRequestSuccess()
                    }
                    .disabled(
                        !model.confirmsOfficialRecoveryTest
                            || model.codexRuntimeMode != .official
                            || model.runtimeTruth?.runtimeMode != .official
                            || model.runtimeTruth?.process.processIdentifier == nil
                    )
                }
                .padding(14)
                .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                ForEach(model.savedRelayProfiles, id: \.id) { profile in
                    profileCard(
                        name:
                            model.unverifiedLegacyRelayProfileIDs
                                .contains(profile.id)
                                ? "\(profile.name)（未验证旧档）"
                                : profile.name,
                        detail:
                            (
                                model.unverifiedLegacyRelayProfileIDs
                                    .contains(profile.id)
                                    ? "不会参与切换 · "
                                    : ""
                            )
                            + "\(profile.wireProtocol.rawValue) · \(profile.defaultModel) · \(profile.baseURL)",
                        active: model.codexRuntimeMode == .relay && model.selectedRelayID == profile.id
                    )
                }
                if model.savedRelayProfiles.isEmpty {
                    Label("尚无中转配置档。Krill、AIHUB、PoloAI不会固定出现；只有用户导入后才显示。", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("进入执行与验证") { openExecution() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                VStack(alignment: .leading, spacing: 9) {
                    Text("旧明文备份风险").font(.headline)
                    Text("仅在你选择provider-switch-backups目录后扫描；只显示数量、时间和风险，不显示Key或配置正文。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择旧备份目录并扫描") {
                        legacyBackupImporterOpen = true
                    }
                    if let report = model.legacyBackupRiskReport {
                        Text(
                            "文件：\(report.scannedFileCount) · 风险：\(report.riskFileCount) · "
                                + "最近修改：\(report.latestModifiedAt?.formatted() ?? "未知")"
                        )
                        .font(.caption)
                        if report.plaintextRiskRemains {
                            Toggle(
                                "我确认创建加密归档；原文件不会删除",
                                isOn: $model.confirmsEncryptLegacyBackups
                            )
                            .toggleStyle(.checkbox)
                            Button("创建加密归档") {
                                model.archiveLegacyBackups()
                            }
                            .disabled(!model.confirmsEncryptLegacyBackups)
                        }
                    }
                    Text(model.legacyBackupRiskStatus)
                        .font(.caption)
                        .foregroundStyle(
                            model.legacyBackupRiskReport?.plaintextRiskRemains
                                == true ? Color.orange : Color.secondary
                        )
                }
                .padding(14)
                .background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 9) {
                    Text("退出托管").font(.headline)
                    Text("必须先恢复官方轨。助手不会在中转配置仍生效时删除自己保存的密钥和恢复点。")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle(
                        "我已在当前官方轨发送真实请求并确认可用",
                        isOn: $model.confirmsOfficialRecoveryTest
                    )
                    .toggleStyle(.checkbox)
                    Button(role: .destructive) {
                        model.exitManagement()
                    } label: {
                        Text("删除助手托管数据并退出")
                    }
                    .disabled(
                        model.codexRuntimeMode != .official
                            || model.runtimeTruth?.runtimeMode != .official
                            || !model.confirmsOfficialRecoveryTest
                    )
                    Text(model.exitManagementStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(28)
            .frame(maxWidth: 950, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $backupImporterOpen,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            model.importOfficialBackupCandidate(url)
        }
        .fileImporter(
            isPresented: $legacyBackupImporterOpen,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            model.scanLegacyBackupDirectory(url)
        }
    }

    private func profileCard(name: String, detail: String, active: Bool) -> some View {
        HStack {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if active {
                Text("当前轨").font(.caption.bold()).foregroundStyle(.green)
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
