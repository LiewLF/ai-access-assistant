import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerSavedRelayEditor: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    let sourceProfile: CodexRelayProfile
    let isCurrent: Bool
    let save: (CodexRelayProfile, String?) -> Void
    let delete: () -> Void
    let cancel: () -> Void

    @State private var displayName: String
    @State private var baseURL: String
    @State private var defaultModel: String
    @State private var replacementAPIKey = ""
    @State private var deletionConfirmationOpen = false

    init(
        sourceProfile: CodexRelayProfile,
        isCurrent: Bool,
        save: @escaping (CodexRelayProfile, String?) -> Void,
        delete: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.sourceProfile = sourceProfile
        self.isCurrent = isCurrent
        self.save = save
        self.delete = delete
        self.cancel = cancel
        _displayName = State(initialValue: sourceProfile.name)
        _baseURL = State(initialValue: sourceProfile.baseURL)
        _defaultModel = State(
            initialValue: sourceProfile.defaultModel
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("修改已保存中转")
                    .font(.title2.bold())
                Text(
                    "修改名称、地址、默认模型；Provider ID、Responses协议和认证策略保持不变。"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Label(
                        isCurrent
                            ? "当前轨：只处理配置并快速重开Codex，不扫描或改写历史会话；失败恢复原配置。"
                            : "非当前轨：先验证目标，资料未被其他操作修改时才保存；当前Codex不变。",
                        systemImage: isCurrent
                            ? "arrow.triangle.2.circlepath"
                            : "checkmark.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(
                        isCurrent ? Color.orange : Color.blue
                    )

                    editorField("中转名称") {
                        TextField(
                            "例如：我的中转",
                            text: $displayName
                        )
                        .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("中转名称")
                    }

                    editorField("中转接口地址（Base URL）") {
                        VStack(alignment: .leading, spacing: 5) {
                            TextField(
                                "https://…/v1",
                                text: $baseURL
                            )
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("中转接口地址")
                            Text(
                                "填写基础接口地址，不含完整请求路径、查询参数或账号信息。本机HTTP仅接受已确认网关的127.0.0.1:1024–65535。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    editorField("默认模型") {
                        VStack(alignment: .leading, spacing: 7) {
                            if !sourceProfile.models.isEmpty {
                                Picker(
                                    "已保存模型",
                                    selection: $defaultModel
                                ) {
                                    ForEach(
                                        sourceProfile.models,
                                        id: \.self
                                    ) {
                                        Text($0).tag($0)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            TextField(
                                "也可填写中转明确提供的新模型ID",
                                text: $defaultModel
                            )
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("默认模型")
                            Text(
                                "新模型只记为待验证；填写名称不会证明中转真实支持。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    editorField("更新中转密钥（可留空）") {
                        VStack(alignment: .leading, spacing: 5) {
                            SecureField(
                                "留空则保持已保存密钥",
                                text: $replacementAPIKey
                            )
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("更新中转密钥，可留空")
                            .disabled(isCurrent)
                            Text(
                                isCurrent
                                    ? "当前轨不直接替换密钥，避免认证和恢复现场半更新。先切到官方或另一条中转后再改。"
                                    : "新密钥先用于目标验证；失败恢复原密钥，不进入界面、日志或受管档案。"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                isCurrent ? Color.orange : Color.secondary
                            )
                        }
                    }

                    HStack {
                        editorField("Provider ID（固定）") {
                            Text(sourceProfile.v011ProviderID)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        editorField("协议（固定）") {
                            Text("Responses")
                                .font(.callout.weight(.semibold))
                        }
                    }

                    if let validationMessage {
                        Label(
                            validationMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 7) {
                        Text("删除中转")
                            .font(.headline)
                        Text(
                            isCurrent
                                ? "当前正在使用这条中转。先切到官方或另一条中转，再删除。"
                                : "删除已保存档案、本机钥匙串密钥和本次切换前检测结果；当前Codex模式不会改变。"
                        )
                        .font(.callout)
                        .foregroundStyle(
                            isCurrent ? Color.orange : Color.secondary
                        )
                        Button(role: .destructive) {
                            deletionConfirmationOpen = true
                        } label: {
                            Label(
                                "删除已保存中转",
                                systemImage: "trash"
                            )
                        }
                        .disabled(isCurrent)
                    }
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
                .padding(22)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("验证并保存") {
                    guard let targetProfile else { return }
                    save(
                        targetProfile,
                        replacementAPIKey.isEmpty
                            ? nil : replacementAPIKey
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetProfile == nil)
            }
            .padding(18)
        }
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 800,
               minHeight: 440, idealHeight: 620, maxHeight: 820)
        .accessibilityIdentifier("relay.saved-editor")
        .alert(
            "删除“\(sourceProfile.name)”？",
            isPresented: $deletionConfirmationOpen
        ) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                delete()
            }
        } message: {
            Text(
                "本机会删除已保存中转、本机钥匙串密钥和本次切换前检测结果。不会删除历史会话、官方登录、Skills、Plugins、MCP、项目或其他中转。重新添加时需要再次输入密钥。目标：\(sourceProfile.name)（\(beginnerEndpointHost(sourceProfile.baseURL) ?? "地址不可显示")）"
            )
        }
    }

    private var targetProfile: CodexRelayProfile? {
        let name = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let endpoint = baseURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let model = defaultModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty,
              V011RelayEndpointPolicy.draftIssue(endpoint,
                localGatewayConfirmed: sourceProfile.localGatewayConfirmed == true) == nil,
              !model.isEmpty else {
            return nil
        }
        return sourceProfile.updatingRelaySettings(
            name: name,
            baseURL: endpoint,
            defaultModel: model
        )
    }

    private var validationMessage: String? {
        if displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            return "中转名称不能为空。"
        }
        if let issue = V011RelayEndpointPolicy.draftIssue(baseURL,
            localGatewayConfirmed: sourceProfile.localGatewayConfirmed == true) {
            return issue
        }
        if defaultModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            return "默认模型不能为空。"
        }
        return nil
    }

    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
