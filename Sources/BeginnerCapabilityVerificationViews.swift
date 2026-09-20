import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerManagedModelCatalogImportHelpView: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    let profile: CodexRelayProfile
    let chooseFile: () -> Void
    let scanFolder: () -> Void
    let scanDefaultCodexHome: () -> Void
    let cancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var sampleJSON: String {
        """
        {
          "models": [
            {
              "id": "\(profile.defaultModel)",
              "context_window": 272000,
              "service_tiers": ["fast", "standard"],
              "reasoning_efforts": ["high", "xhigh"],
              "input_modalities": ["text"]
            }
          ]
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("要导入什么")
                            .font(.title2.bold())
                        Text(
                            "选一个模型目录 JSON。它通常来自当前中转或供应商导出的模型列表，也可以是你之前保存过的目录副本。"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        "如果你只知道文件夹，不知道文件名，先点自动扫描；如果相关文件在隐藏的 .codex 里，先扫默认目录。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    GroupBox("硬要求") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• 顶层要有 models 或 data 数组")
                            Text("• 每个模型至少要有 id / slug / model / name 其中一个")
                            Text("• 可选字段：context_window、service_tiers、reasoning_efforts、input_modalities")
                            Text("• 不要选截图、config.toml、说明文档或随便的文本文件")
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("样例") {
                        Text(sampleJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(
                        "如果你没有这类 JSON，就先别导入；先找供应商给你的模型目录文件，或找当前轨默认模型 \(profile.defaultModel) 所在的目录副本。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)],
                alignment: .leading, spacing: 10
            ) {
                Button("自动扫描文件夹") {
                    dismiss()
                    scanFolder()
                }
                .buttonStyle(.borderedProminent)
                Button("扫描默认 .codex 目录") {
                    dismiss()
                    scanDefaultCodexHome()
                }
                .buttonStyle(.borderedProminent)
                Button("继续选择 JSON") {
                    dismiss()
                    chooseFile()
                }
                .buttonStyle(.borderedProminent)
                Button("取消") {
                    dismiss()
                    cancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 720, maxWidth: 900,
               minHeight: 440, idealHeight: 560, maxHeight: 760)
    }
}

struct BeginnerManagedModelCatalogCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let modelIDs: [String]
    let matchesDefaultModel: Bool
}

struct BeginnerManagedModelCatalogImportReview: Identifiable {
    let id = UUID()
    let profile: CodexRelayProfile
    let sourceLabel: String
    let candidates: [BeginnerManagedModelCatalogCandidate]
}

struct BeginnerManagedModelCatalogImportReviewView: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    let review: BeginnerManagedModelCatalogImportReview
    let chooseCandidate: (BeginnerManagedModelCatalogCandidate) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("找到候选")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "\(review.sourceLabel) 里找到了 \(review.candidates.count) 个可导入的模型目录 JSON。"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(review.candidates) { candidate in
                        Button {
                            chooseCandidate(candidate)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.url.lastPathComponent)
                                        .font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(
                                        "模型 \(candidate.modelIDs.count) 个"
                                            + (candidate.matchesDefaultModel
                                                ? " · 命中默认模型 \(review.profile.defaultModel)"
                                                : "")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    Text(
                                        candidate.modelIDs.prefix(3)
                                            .joined(separator: " · ")
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if candidate.matchesDefaultModel {
                                    Text("优先")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Color.green.opacity(0.14),
                                            in: Capsule()
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
            HStack {
                Button("取消") {
                    cancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 760, maxWidth: 900,
               minHeight: 440, idealHeight: 560, maxHeight: 760)
    }
}

struct BeginnerCapabilityVerificationView: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsCoreProbe = false
    @State private var confirmsFastProbe = false
    @State private var confirmsWebSearchProbe = false
    @State private var confirmsImageInputProbe = false
    @State private var localError: String?

    var body: some View {
        panel(displayTextSize: displayTextSize)
        .safeAreaInset(edge: .bottom) { BeginnerCurrentConnectionCheckBanner(accessModel: accessModel) }
        .confirmationDialog(
            "确认验证基础能力？",
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
                BeginnerCurrentConnectionCheckCopy.consent
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
                "将向当前中转发送一次真实Fast请求。会联网，并可能产生额外API费用；不会修改配置。"
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
                "将发送一次真实Web Search请求，并在同一响应验证来源引用。会联网，并可能产生额外API及搜索费用；不会修改配置。"
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
                "将发送一次小型合成图片请求。会联网，并可能产生额外API费用；不会读取用户图片或修改配置。"
            )
        }
        .onAppear { refreshHealth() }
        .onChange(of: accessModel.isCheckingCurrentConnection) {
            wasChecking, isChecking in
            guard wasChecking, !isChecking else { return }
            refreshHealth()
        }
        .onChange(of: accessModel.providerProbeReceipts) {
            _, _ in refreshHealth()
        }
        .onChange(of: accessModel.isWorking) {
            wasWorking, isWorking in
            guard wasWorking, !isWorking else { return }
            refreshHealth()
        }
        .onChange(of: accessModel.isRefreshing) {
            wasRefreshing, isRefreshing in
            guard wasRefreshing, !isRefreshing else { return }
            refreshHealth()
        }
    }

    func panel(displayTextSize: AppDisplayTextSize) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("扩展能力验证")
                        .font(.title2.bold())
                    Text(
                        "打开窗口时自动刷新本地状态；联网探针必须主动确认。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("基础能力") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                "核心闸门缺少当前轨的配置语法、认证、Responses文本和CAS回执时，会阻止自动写入。"
                            )
                            .font(.callout)
                            Text(
                                accessModel
                                    .currentConnectionVerificationSummary
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Button(
                                accessModel.isCheckingCurrentConnection
                                    ? "正在验证基础能力"
                                    : "验证基础能力"
                            ) {
                                confirmsCoreProbe = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(networkProbeDisabled)
                            Text(
                                BeginnerCurrentConnectionCheckCopy.consent
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Provider可选探针") {
                        VStack(alignment: .leading, spacing: 10) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)],
                                alignment: .leading, spacing: 10
                            ) {
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
                            .disabled(networkProbeDisabled)
                            Text(
                                "Fast、Web Search和图片探针直接请求当前中转以核对原始响应字段，不复用当前会话。每项独立确认、独立请求、独立回执；取消时零调用。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("本地扩展与真实缺口") {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("刷新本地扩展状态") {
                                refreshHealth()
                            }
                            HStack {
                                Button("打开Codex Plugins") {
                                    openCodexDeepLink(
                                        "codex://plugins/",
                                        actionName: "Codex Plugins"
                                    )
                                }
                                Button("打开Codex MCP设置") {
                                    openCodexDeepLink(
                                        "codex://settings",
                                        actionName: "Codex MCP设置"
                                    )
                                }
                            }
                            Text(
                                "MCP配置已识别不等于进程已连接。打开Codex后在任务中输入 /mcp 核对已连接服务器和工具；本窗口不伪造连接回执。"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            Text(
                                "Plugins清单可自动读取；套餐、OAuth和工作区权限仍由Codex确认。受管模型目录请在扩展能力卡导入后再刷新。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(
                                "远程在线压缩只有真实压缩事件回执后才算已验证；当前没有安全通用立即探针。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("当前验证结果") {
                        VStack(alignment: .leading, spacing: 9) {
                            if verificationItems.isEmpty {
                                Text("尚未读取验证结果。")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(verificationItems) { item in
                                    VStack(
                                        alignment: .leading,
                                        spacing: 2
                                    ) {
                                        Text(
                                            "\(item.title)：\(item.state.rawValue)"
                                        )
                                        .font(.callout.weight(.semibold))
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !inactiveVerificationItems.isEmpty {
                                    DisclosureGroup(
                                        "未启用（\(inactiveVerificationItems.count)）"
                                    ) {
                                        ForEach(
                                            inactiveVerificationItems
                                        ) { item in
                                            VStack(
                                                alignment: .leading,
                                                spacing: 2
                                            ) {
                                                Text(item.title)
                                                    .font(
                                                        .caption
                                                            .weight(
                                                                .semibold
                                                            )
                                                    )
                                                Text(item.detail)
                                                    .font(.caption)
                                                    .foregroundStyle(
                                                        .secondary
                                                    )
                                            }
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Label(
                        accessModel.status,
                        systemImage: accessModel.isWorking
                            || accessModel
                                .isCheckingCurrentConnection
                            ? "hourglass"
                            : "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    if let message = accessModel
                        .capabilityEvidenceErrorMessage {
                        Label(
                            message,
                            systemImage:
                                "exclamationmark.triangle.fill"
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
                }
                .padding(20)
            }
        }
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 780, maxWidth: 960,
               minHeight: 440, idealHeight: 680, maxHeight: 820)
    }

    private var networkProbeDisabled: Bool {
        accessModel.isWorking
            || accessModel.isRefreshing
            || accessModel.isCheckingCurrentConnection
    }

    private var verificationItems: [ConfigurationHealthItem] {
        model.configurationHealth?.items.filter {
            $0.state != .notEnabled
        } ?? []
    }

    private var inactiveVerificationItems:
        [ConfigurationHealthItem] {
        model.configurationHealth?.items.filter {
            $0.state == .notEnabled
        } ?? []
    }

    private func refreshHealth() {
        model.refreshConfigurationHealth(
            using: accessModel
        )
    }

    private func openCodexDeepLink(
        _ rawURL: String,
        actionName: String
    ) {
        guard let url = URL(string: rawURL),
              NSWorkspace.shared.open(url) else {
            localError =
                "无法打开\(actionName)。请确认已安装Codex后重试。"
            return
        }
        localError = nil
    }
}
