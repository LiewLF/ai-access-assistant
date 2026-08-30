// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import SwiftUI

struct InstallationCenterView: View {
    @State private var host = HostPlatformInspector.inspectMac()
    @State private var codex = MacAgentInstallationInspector.inspect(
        agent: .codexDesktop,
        bundleIdentifier: "com.openai.codex",
        officialDownloadURL: OfficialAgentCatalog.codexDownload,
        supportedAccessRoutes: ["官方登录", "AI接入助手托管中转"]
    )
    @State private var claude = MacAgentInstallationInspector.inspect(
        agent: .claudeDesktop,
        bundleIdentifier: "com.anthropic.claudefordesktop",
        officialDownloadURL: OfficialAgentCatalog.claudeDownload,
        supportedAccessRoutes: ["官方登录指导"]
    )
    @State private var cherry = MacAgentInstallationInspector.inspect(
        agent: .cherryStudio,
        bundleIdentifier: "com.cherryai.cherrystudio",
        officialDownloadURL: OfficialAgentCatalog.cherryDownload,
        supportedAccessRoutes: ["官方使用指导；独立配置适配器后续开放"]
    )
    @State private var transactions: [String: AgentInstallationTransaction] = [:]
    @State private var transactionError: String?
    @State private var diagnosticReport: InstallationDiagnosticReport?
    @State private var isDiagnosing = false

    private var journalStore: AgentInstallationJournalStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return AgentInstallationJournalStore(
            fileURL: base.appendingPathComponent(
                "AI接入助手/Installation/transactions.json"
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("安装中心")
                        .font(.system(size: 28, weight: .bold))
                    Text("先识别系统和CPU，再给出匹配安装方式。不会绕过Gatekeeper、协议、登录或管理员确认。")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    factCard("系统", "macOS \(host.version)")
                    factCard("CPU", host.architecture == .arm64 ? "Apple芯片" : "Intel")
                    factCard("AI接入助手", "开发构建 · ad-hoc签名")
                }
                HStack {
                    Button("重新检测系统与Agent") { refreshInstallations() }
                        .buttonStyle(.borderedProminent)
                    Button {
                        runInstallationDiagnostics()
                    } label: {
                        if isDiagnosing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("检查网络、TLS、代理和策略", systemImage: "network.badge.shield.half.filled")
                        }
                    }
                    .disabled(isDiagnosing)
                }
                Label(
                    "当前0.11测试包仅支持Apple芯片，最低macOS 15。Universal 2尚未生成；Intel真机、Developer ID签名和公证仍是后续发布门。",
                    systemImage: "hammer.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(14)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                if let report = diagnosticReport {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("安装环境诊断").font(.headline)
                        ForEach(report.endpoints) { endpoint in
                            HStack(alignment: .top) {
                                Image(systemName: endpoint.state == .passed
                                    ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(endpoint.state == .passed ? Color.green : Color.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(endpoint.requestedURL.host ?? endpoint.requestedURL.absoluteString)
                                        .fontWeight(.semibold)
                                    Text(endpoint.detail).font(.caption).foregroundStyle(.secondary)
                                    if let final = endpoint.finalURL {
                                        Text("最终地址：\(final.absoluteString)")
                                            .font(.caption).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        Text(
                            report.environment.proxyConfigured
                                ? "检测到代理来源：\(report.environment.proxySourceLabels.joined(separator: "、"))。不读取或显示代理地址、账号和密码。"
                                : "未从当前进程和系统会话发现显式代理证据。"
                        )
                        .font(.caption)
                        .foregroundStyle(report.environment.proxyConfigured ? Color.orange : Color.secondary)
                        Text(
                            report.environment.managedPreferencesDirectoryPresent
                                ? "发现系统托管偏好目录；这不等于安装被企业策略阻止，仍需以具体系统提示为证据。"
                                : "未发现可解释的企业策略目录证据；不据此保证管理员允许安装。"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }

                Label(
                    "当前macOS桌面Agent安装包未发现需要AI接入助手代装的独立运行时。若未来Manifest声明前置项，将逐项显示官方来源、版本、磁盘、管理员权限、重启和卸载方式。",
                    systemImage: "shippingbox"
                )
                .font(.callout)
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                installRow(
                    "Codex Desktop",
                    "支持安装检测、ChatGPT登录指导、官方通路验证和Codex配置。",
                    OfficialAgentCatalog.codexDownload,
                    codex
                )
                installRow(
                    "Claude Desktop",
                    "只做官方安装和登录指导；不承诺任意Base URL中转。",
                    OfficialAgentCatalog.claudeDownload,
                    claude
                )
                installRow(
                    "Cherry Studio",
                    "0.9.x只做安装检测和官方使用指导；不触碰Codex或Claude配置。",
                    OfficialAgentCatalog.cherryDownload,
                    cherry
                )
                if let transactionError {
                    Label(transactionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("公开安装包矩阵").font(.headline)
                    matrixLine("macOS Apple芯片", "功能构建可用；正式分发待Developer ID和公证", .orange)
                    matrixLine("macOS Intel / Universal 2", "0.11未生成；需先完成Intel真机适配与验收", .orange)
                    matrixLine("Windows x64 / arm64", "1.1.0前不提供macOS包，也不改后缀冒充", .red)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if let saved = try? journalStore.load() {
                transactions = Dictionary(
                    uniqueKeysWithValues: saved.map { ($0.manifestID, $0) }
                )
            }
        }
    }

    private func factCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func installRow(
        _ name: String,
        _ detail: String,
        _ url: URL,
        _ installation: AgentInstallation
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                Text(
                    installation.state == .notInstalled
                        ? "未安装"
                        : "\(installation.state.rawValue) · 版本 \(installation.version ?? "未知") · 签名 \(installation.signatureVerified == true ? "通过" : "未验证")"
                )
                .font(.caption)
                .foregroundStyle(installation.signatureVerified == false ? Color.red : Color.secondary)
                if let path = installation.installPath {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(url.absoluteString).font(.caption).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                if installation.state == .notInstalled {
                    Button("开始引导安装") {
                        beginGuidedInstall(installation, url: url)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("打开Agent") {
                        if let path = installation.installPath {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                    Button("我已完成登录") {
                        markLoginCompleted(installation)
                    }
                }
                if let transaction = transactions[installation.id] {
                    Text(transaction.state.rawValue)
                        .font(.caption.bold())
                    Text(transaction.sanitizedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func beginGuidedInstall(
        _ installation: AgentInstallation,
        url: URL
    ) {
        do {
            var transaction = GuidedAgentInstallationWorkflow.begin(
                manifestID: installation.id
            )
            transaction = GuidedAgentInstallationWorkflow.openedOfficialInstaller(
                transaction
            )
            try journalStore.upsert(transaction)
            transactions[installation.id] = transaction
            NSWorkspace.shared.open(url)
            transactionError = nil
        } catch {
            transactionError = "安装引导状态保存失败：\(error.localizedDescription)"
        }
    }

    private func markLoginCompleted(_ installation: AgentInstallation) {
        do {
            let current = transactions[installation.id]
                ?? GuidedAgentInstallationWorkflow.begin(
                    manifestID: installation.id
                )
            let transaction = GuidedAgentInstallationWorkflow.loginCompleted(
                current
            )
            try journalStore.upsert(transaction)
            transactions[installation.id] = transaction
            transactionError = nil
        } catch {
            transactionError = "登录验证状态保存失败：\(error.localizedDescription)"
        }
    }

    private func refreshInstallations() {
        host = HostPlatformInspector.inspectMac()
        codex = MacAgentInstallationInspector.inspect(
            agent: .codexDesktop,
            bundleIdentifier: "com.openai.codex",
            officialDownloadURL: OfficialAgentCatalog.codexDownload,
            supportedAccessRoutes: ["官方登录", "AI接入助手托管中转"]
        )
        claude = MacAgentInstallationInspector.inspect(
            agent: .claudeDesktop,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            officialDownloadURL: OfficialAgentCatalog.claudeDownload,
            supportedAccessRoutes: ["官方登录指导"]
        )
        cherry = MacAgentInstallationInspector.inspect(
            agent: .cherryStudio,
            bundleIdentifier: "com.cherryai.cherrystudio",
            officialDownloadURL: OfficialAgentCatalog.cherryDownload,
            supportedAccessRoutes: ["官方使用指导；独立配置适配器后续开放"]
        )
        for installation in [codex, claude, cherry] {
            if let current = transactions[installation.id] {
                let updated = GuidedAgentInstallationWorkflow.rechecked(
                    current,
                    installation: installation
                )
                try? journalStore.upsert(updated)
                transactions[installation.id] = updated
            }
        }
    }

    private func runInstallationDiagnostics() {
        isDiagnosing = true
        transactionError = nil
        Task {
            diagnosticReport = await InstallationNetworkDiagnostics.run(
                endpoints: [
                    OfficialAgentCatalog.codexDownload,
                    OfficialAgentCatalog.claudeDownload,
                    OfficialAgentCatalog.cherryDownload,
                ]
            )
            isDiagnosing = false
        }
    }

    private func matrixLine(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(name).frame(width: 190, alignment: .leading)
            Text(value).foregroundStyle(color)
        }
        .font(.callout)
    }
}
