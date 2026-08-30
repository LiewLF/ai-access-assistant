import AppKit
import SwiftUI

struct BeginnerCodexInstallationView: View {
    @ObservedObject var accessModel: V011AccessModel

    @State private var host = HostPlatformInspector.inspectMac()
    @State private var installation = MacAgentInstallationInspector.inspect(
        agent: .codexDesktop,
        bundleIdentifier: "com.openai.codex",
        officialDownloadURL: OfficialAgentCatalog.codexDownload,
        supportedAccessRoutes: ["官方登录", "可选兼容中转"]
    )
    @State private var diagnosticReport: InstallationDiagnosticReport?
    @State private var isDiagnosing = false
    @State private var actionError: String?
    @State private var confirmsOpeningOfficialSource = false
    @State private var confirmsOpeningCodex = false
    @State private var confirmsOfficialConnectionCheck = false

    private var officialConnectionVerified: Bool {
        accessModel.liveState != nil
            && accessModel.currentProviderID == nil
            && accessModel.isCurrentConnectionVerified
    }

    private var guidance: CodexInstallationGuidance {
        CodexInstallationGuidanceEvaluator.evaluate(
            host: host,
            installation: installation,
            endpointState: diagnosticReport?.endpoints.first?.state,
            officialConnectionVerified: officialConnectionVerified
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codex 安装与登录")
                        .font(.system(size: 28, weight: .bold))
                    Text("只处理 macOS 上的 Codex。先检测，再由你确认是否打开官方来源或执行连接检查。")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    installationFact("系统", "macOS \(host.version)")
                    installationFact(
                        "CPU",
                        host.architecture == .arm64
                            ? "Apple 芯片" : "Intel"
                    )
                    installationFact(
                        "Codex",
                        installation.state == .notInstalled
                            ? "未安装"
                            : "已安装 \(installation.version ?? "版本未知")"
                    )
                }

                HStack {
                    Button("重新检测") {
                        refreshInstallation()
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        diagnoseOfficialSource()
                    } label: {
                        if isDiagnosing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                "检查官方来源网络",
                                systemImage: "network"
                            )
                        }
                    }
                    .disabled(isDiagnosing)
                }

                installationStatusCard

                VStack(alignment: .leading, spacing: 7) {
                    Text("官方来源")
                        .font(.headline)
                    Text(guidance.officialSource.absoluteString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Text("助手不会静默下载、安装、绕过系统权限，也不会读取登录密码或验证码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )

                if !guidance.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("安装与登录步骤")
                            .font(.headline)
                        ForEach(
                            Array(guidance.steps.enumerated()),
                            id: \.offset
                        ) { index, step in
                            Text("\(index + 1). \(step)")
                                .font(.callout)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }

                actionButtons

                if let endpoint = diagnosticReport?.endpoints.first {
                    Label(
                        endpoint.detail,
                        systemImage: endpoint.state == .passed
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(diagnosticColor(endpoint.state))
                }

                if let actionError {
                    Label(
                        actionError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "确认打开 Codex 官方安装来源？",
            isPresented: $confirmsOpeningOfficialSource
        ) {
            Button("确认打开官方来源") {
                openOfficialSource()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将打开 \(guidance.officialSource.host ?? "官方网页")；不会自动下载或安装。")
        }
        .confirmationDialog(
            "确认打开已安装的 Codex？",
            isPresented: $confirmsOpeningCodex
        ) {
            Button("确认打开 Codex") {
                openInstalledCodex()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("登录由 Codex 官方界面完成，助手不会读取账号、密码或验证码。")
        }
        .confirmationDialog(
            "确认检测官方连接？",
            isPresented: $confirmsOfficialConnectionCheck
        ) {
            Button("确认执行连接检查") {
                accessModel.detectCurrentConnection(
                    userConsented: true
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会按当前实时 Codex 设置发送一次最小请求，可能产生一次API费用；不会切换模式或修改配置。")
        }
    }

    private var installationStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                guidance.title,
                systemImage: guidance.state == .officialReady
                    ? "checkmark.circle.fill"
                    : (
                        guidance.state == .notInstalled
                            || guidance.state == .installedNeedsLogin
                            ? "info.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
            )
            .font(.headline)
            Text(guidance.detail)
                .font(.callout)
            Text("下一步：\(guidance.nextAction)")
                .font(.callout.weight(.medium))
            if let checkError = accessModel.currentConnectionCheckError,
               installation.state != .notInstalled {
                Text("连接检查：\(BeginnerText.friendly(checkError))")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            statusColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            switch guidance.state {
            case .notInstalled:
                Button("打开官方安装来源") {
                    confirmsOpeningOfficialSource = true
                }
                .buttonStyle(.borderedProminent)
            case .installedNeedsLogin:
                Button("打开 Codex 登录") {
                    confirmsOpeningCodex = true
                }
                .buttonStyle(.borderedProminent)
                Button(
                    accessModel.isCheckingCurrentConnection
                        ? "正在检测" : "登录后检测官方连接"
                ) {
                    confirmsOfficialConnectionCheck = true
                }
                .disabled(accessModel.isCheckingCurrentConnection)
            case .officialReady:
                Button("打开 Codex 继续官方") {
                    confirmsOpeningCodex = true
                }
                .buttonStyle(.borderedProminent)
                Text("无需添加中转")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            case .networkBlocked:
                Button("修复后重新检查网络") {
                    diagnoseOfficialSource()
                }
                .disabled(isDiagnosing)
            case .permissionBlocked,
                 .incompatible,
                 .unverifiedInstallation:
                EmptyView()
            }
        }
    }

    private var statusColor: Color {
        switch guidance.state {
        case .officialReady:
            return .green
        case .notInstalled, .installedNeedsLogin:
            return .blue
        case .incompatible, .permissionBlocked,
             .networkBlocked, .unverifiedInstallation:
            return .orange
        }
    }

    private func diagnosticColor(
        _ state: InstallationDiagnosticState
    ) -> Color {
        switch state {
        case .passed:
            return .green
        case .warning, .unverified:
            return .orange
        case .failed:
            return .red
        }
    }

    private func installationFact(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func refreshInstallation() {
        host = HostPlatformInspector.inspectMac()
        installation = MacAgentInstallationInspector.inspect(
            agent: .codexDesktop,
            bundleIdentifier: "com.openai.codex",
            officialDownloadURL: OfficialAgentCatalog.codexDownload,
            supportedAccessRoutes: ["官方登录", "可选兼容中转"]
        )
        diagnosticReport = nil
        actionError = nil
        accessModel.refresh()
    }

    private func diagnoseOfficialSource() {
        isDiagnosing = true
        actionError = nil
        Task {
            diagnosticReport = await InstallationNetworkDiagnostics.run(
                endpoints: [OfficialAgentCatalog.codexDownload]
            )
            isDiagnosing = false
        }
    }

    private func openOfficialSource() {
        guard NSWorkspace.shared.open(guidance.officialSource) else {
            actionError = "无法打开官方来源。请检查默认浏览器和系统权限，或复制上方官方地址到浏览器后重试。"
            return
        }
        actionError = nil
    }

    private func openInstalledCodex() {
        guard let path = installation.installPath,
              NSWorkspace.shared.open(
                URL(fileURLWithPath: path)
              ) else {
            actionError = "无法打开 Codex。请在“应用程序”中手动打开；若仍失败，从官方来源重新安装后再检测。"
            return
        }
        actionError = nil
    }
}
