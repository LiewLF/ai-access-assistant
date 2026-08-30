import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerSettingsView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @ObservedObject var historyModel: V011HistoryModel
    let initialSection: BeginnerSettingsSection
    let onUseRelayEntry:
        (ProviderCatalogEntryV2) -> Void
    let onConfigureCustomRelay: () -> Void
    let openAccessSection: (BeginnerAccessSection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var section =
        BeginnerSettingsSection.software
    @State private var publicDistributionExportStatus: String?
    @State private var continuityImportWorking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置与诊断")
                    .font(.title2.bold())
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .disabled(continuityImportWorking)
            }
            .padding(18)
            Divider()
            HStack(spacing: 0) {
                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {
                    ForEach(
                        BeginnerSettingsSection.allCases
                    ) { item in
                        Button {
                            section = item
                        } label: {
                            Label(
                                item.rawValue,
                                systemImage: item.icon
                            )
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .foregroundStyle(
                                section == item
                                    ? Color.accentColor
                                    : Color.primary
                            )
                            .background(
                                section == item
                                    ? Color.accentColor
                                        .opacity(0.1)
                                    : Color.clear,
                                in: RoundedRectangle(
                                    cornerRadius: 8
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            continuityImportWorking
                                && section != item
                        )
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 170)
                .background(
                    Color(
                        nsColor:
                            .controlBackgroundColor
                    ).opacity(0.55)
                )
                Divider()
                Group {
                    switch section {
                    case .software:
                        BeginnerCodexInstallationView(
                            accessModel: accessModel
                        )
                    case .capabilities:
                        BeginnerExtensionCapabilitiesView(
                            model: model,
                            accessModel: accessModel
                        )
                    case .relayDirectory:
                        RelayDirectoryView(
                            onUseEntry:
                                onUseRelayEntry,
                            configureCustom:
                                onConfigureCustomRelay
                        )
                    case .continuity:
                        BeginnerContinuityExportView(
                            accessModel: accessModel,
                            historyModel: historyModel,
                            isImportWorking:
                                $continuityImportWorking
                        )
                    case .diagnostics:
                        BeginnerDiagnosticsView(
                            model: model,
                            accessModel: accessModel,
                            openSettingsSection: { section = $0 },
                            openAccessSection: openAccessSection
                        )
                    case .guide:
                        BeginnerGuideView(
                            openSettingsSection: { section = $0 },
                            openAccessSection: openAccessSection
                        )
                    case .about:
                        aboutView
                    }
                }
            }
        }
        .onAppear {
            section = initialSection
        }
        .interactiveDismissDisabled(continuityImportWorking)
    }

    private var aboutView: some View {
        let updateTrustState =
            TrustedUpdateTrustStore.productionState()
        let updateTrustDiagnostic =
            TrustedUpdateTrustDiagnosticResolver.resolve(
                updateTrustState
            )
        let publicDistributionReadiness =
            PublicDistributionReadinessResolver.sourceBaseline(
                updateTrustState: updateTrustState
            )
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "scope")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("AI接入助手")
                    .font(.title.bold())
                Text("版本 " + appVersion)
                Text("许可证：AGPL-3.0-only")
                    .fontWeight(.semibold)
                Text(
                    "本软件按现状提供，不附带任何担保。你可以按照GNU Affero GPL v3的条款复制、修改和再发布。"
                )
                .foregroundStyle(.secondary)
                Text(
                    "本机优先：不设应用内遥测；联网、真实任务和诊断导出只由用户明确触发。"
                )
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        updateTrustDiagnostic.title,
                        systemImage: updateTrustDiagnostic.symbolName
                    )
                    .font(.headline)
                    Text(updateTrustDiagnostic.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor)
                        .opacity(0.7)
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 10,
                        style: .continuous
                    )
                )
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        publicDistributionReadiness.title,
                        systemImage:
                            publicDistributionReadiness.symbolName
                    )
                    .font(.headline)
                    Text(publicDistributionReadiness.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(publicDistributionReadiness.gates) { gate in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(
                                    gate.title,
                                    systemImage: gate.status.symbolName
                                )
                                .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(gate.status.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(gate.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("下一步：\(gate.primaryAction)")
                                .font(.caption)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    Button("导出公开发布缺口") {
                        exportPublicDistributionReadiness(
                            publicDistributionReadiness
                        )
                    }
                    .accessibilityHint(
                        "导出四项状态和固定说明；不含证书、公证账户、公钥内容、路径或用户数据"
                    )
                    if let publicDistributionExportStatus {
                        Text(publicDistributionExportStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor)
                        .opacity(0.7)
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 10,
                        style: .continuous
                    )
                )
                LocalBetaAcceptanceCenterView(
                    detectedFailureStage:
                        localBetaDetectedFailureStage
                )
                Button("查看隐私说明") {
                    openResource(
                        name: "PRIVACY",
                        extension: "md"
                    )
                }
                HStack {
                    Button("查看完整许可证") {
                        openResource(
                            name: "LICENSE",
                            extension: nil
                        )
                    }
                    Button("查看对应源码说明") {
                        openResource(
                            name: "SOURCE-CODE",
                            extension: "md"
                        )
                    }
                    Button("查看第三方声明") {
                        openResource(
                            name: "THIRD_PARTY_NOTICES",
                            extension: "md"
                        )
                    }
                }
                Link(
                    "Codex++ 上游项目",
                    destination: URL(
                        string:
                            "https://github.com/BigPizzaV3/CodexPlusPlus"
                    )!
                )
                Text(
                    "公开发布时，安装包与对应可构建源码同步提供。"
                )
                .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: 650, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var appVersion: String {
        "\(AppReleaseMetadata.version) (\(AppReleaseMetadata.build))"
    }

    private var localBetaDetectedFailureStage:
        LocalBetaFailureStage {
        if accessModel.hasPendingRecovery
            || accessModel.hasPendingPortableContinuityImport {
            return .recovery
        }
        if accessModel.agentLoopFailurePresentation != nil {
            return .realTask
        }
        if accessModel.currentConnectionFailurePresentation != nil {
            return .connection
        }
        if accessModel.officialUsageFailurePresentation != nil {
            return .officialUsage
        }
        if accessModel.compatibilityFailurePresentation != nil {
            return .capabilityCompatibility
        }
        return .none
    }

    private func exportPublicDistributionReadiness(
        _ report: PublicDistributionReadinessReport
    ) {
        let panel = NSSavePanel()
        panel.title = "保存公开发布缺口"
        panel.nameFieldStringValue =
            "AI接入助手-公开发布缺口-Build\(AppReleaseMetadata.build).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK,
              let destinationURL = panel.url else {
            publicDistributionExportStatus =
                "已取消导出；未写入文件。"
            return
        }
        do {
            try report.redactedJSONData().write(
                to: destinationURL,
                options: .atomic
            )
            publicDistributionExportStatus =
                "已导出脱敏发布缺口；未执行联网、签名或公证。"
        } catch {
            publicDistributionExportStatus =
                "导出失败；未写入完整文件。"
        }
    }

    private func openResource(
        name: String,
        extension fileExtension: String?
    ) {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
