import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerRelayDraftView: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @Binding var section: BeginnerAccessSection
    @Binding var localStatus: String?
    let onChooseScreenshots: () -> Void
    let protocolIsSupported: Bool
    let protocolCompatibilityMessage: String
    let addRelayDisabled: Bool
    let synchronizeFastModeWithServiceTier:
        (ProviderServiceTierKind) -> Void
    let checkRelayDraft: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                officialContinuationCard
                sourceSection
                fieldsSection

                Button {
                    checkRelayDraft()
                } label: {
                    Label(
                        "检测并添加",
                        systemImage:
                            "checkmark.shield.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(addRelayDisabled)

                BeginnerAccessStatusView(
                    model: model,
                    accessModel: accessModel,
                    localStatus: localStatus
                )
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var officialContinuationCard: some View {
        if case .official? = accessModel.liveState?.mode {
            HStack(spacing: 12) {
                Label(
                    "中转是可选项；没有中转也可以继续使用 Codex 官方。",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.callout)
                Spacer()
                Button("暂不添加，继续使用官方") {
                    section = .switchMode
                    localStatus =
                        "未添加中转；当前官方设置保持不变。"
                }
                .buttonStyle(.bordered)
            }
            .padding(13)
            .background(
                .green.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
    }

    private var sourceSection: some View {
        beginnerSection(
            title: "1. 添加中转说明",
            subtitle:
                "任选一种。可以粘贴网址、文字，也可以导入多张截图。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField(
                        "中转配置文档网址",
                        text: $model.documentURL
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(
                        model.isRefreshingDocument
                            ? "正在整理"
                            : "读取网址"
                    ) {
                        model.refreshDocument()
                    }
                    .disabled(
                        model.isRefreshingDocument
                            || model.documentURL
                                .trimmingCharacters(
                                    in:
                                        .whitespacesAndNewlines
                                ).isEmpty
                    )
                }
                TextEditor(
                    text:
                        $model.pastedConfigurationText
                )
                .frame(minHeight: 80)
                .padding(8)
                .background(
                    Color(
                        nsColor: .textBackgroundColor
                    ),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(alignment: .topLeading) {
                    if model.pastedConfigurationText
                        .isEmpty {
                        Text("或粘贴QQ群公告、配置说明")
                            .foregroundStyle(.tertiary)
                            .padding(13)
                            .allowsHitTesting(false)
                    }
                }
                HStack {
                    Button("整理粘贴文字") {
                        model.addPastedSource()
                    }
                    Button {
                        onChooseScreenshots()
                    } label: {
                        Label(
                            "导入截图",
                            systemImage:
                                "photo.on.rectangle"
                        )
                    }
                    Spacer()
                    Text(
                        model.configurationSources.isEmpty
                            ? "尚未添加资料"
                            : "已添加\(model.configurationSources.count)份资料"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if model.isReadingScreenshots {
                    ProgressView(model.screenshotStatus)
                }
            }
        }
    }

    private var fieldsSection: some View {
        beginnerSection(
            title: "2. 核对信息",
            subtitle:
                "没识别到的内容可直接补上；出现冲突时先选择正确来源。密钥只在安全输入框填写。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                conflictResolutionSection
                labeledField("中转名称") {
                    TextField(
                        "例如：我的中转",
                        text: $model.providerName
                    )
                    .textFieldStyle(.roundedBorder)
                }
                labeledField("中转接口地址（Base URL）") {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField(
                            "https://…/v1",
                            text: $model.baseURL
                        )
                        .textFieldStyle(.roundedBorder)
                        Text(
                            "这是中转网站提供的服务地址，通常以 /v1 结尾。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                labeledField("接入协议（中转与Codex的沟通方式）") {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker(
                            "接入协议",
                            selection: $model.wireProtocol
                        ) {
                            ForEach(
                                RelayWireProtocol.allCases
                            ) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        HStack(alignment: .top, spacing: 7) {
                            Image(
                                systemName:
                                    protocolIsSupported
                                        ? "checkmark.circle.fill"
                                        : "xmark.octagon.fill"
                            )
                            Text(protocolCompatibilityMessage)
                                .font(.caption)
                            Spacer()
                        }
                        .foregroundStyle(
                            protocolIsSupported
                                ? Color.green : Color.orange
                        )
                    }
                }
                labeledField("中转密钥（API Key）") {
                    VStack(alignment: .leading, spacing: 5) {
                        SecureField(
                            "只在这里输入",
                            text: $model.apiKey
                        )
                        .textFieldStyle(.roundedBorder)
                        Text(
                            "启用中转时，密钥会写入本机Codex设置，并限制为只有当前用户可读；切回官方时自动移除。它不是“零落盘”。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                modelFields
                advancedFields
            }
        }
    }

    private var modelFields: some View {
        labeledField("模型（决定实际使用哪种AI）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(
                        "输入模型名称",
                        text: $model.newModelName
                    )
                    .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        model.addModel()
                    }
                    Button(
                        model.isFetchingModels
                            ? "正在读取"
                            : "读取模型"
                    ) {
                        model.fetchModels()
                    }
                    .disabled(
                        model.isFetchingModels
                            || model.baseURL.isEmpty
                            || model.apiKey.isEmpty
                    )
                }
                if !model.modelNames.isEmpty {
                    Picker(
                        "默认模型",
                        selection: $model.modelName
                    ) {
                        ForEach(
                            model.modelNames,
                            id: \.self
                        ) {
                            Text($0).tag($0)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已添加模型（\(model.modelNames.count)）")
                            .font(.caption.weight(.semibold))
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(
                                    model.modelNames,
                                    id: \.self
                                ) { modelName in
                                    Button {
                                        model.selectDefaultModel(modelName)
                                    } label: {
                                        Label(
                                            modelName,
                                            systemImage:
                                                modelName == model.modelName
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        Text("点击模型可设为默认模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.modelFetchStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var conflictResolutionSection: some View {
        if !model.unresolvedConflicts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "不同资料给出了不同答案",
                    systemImage:
                        "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.red)
                Text(
                    "助手不会替你猜。请逐项选择可信的那一条，全部选完后才能添加。"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                ForEach(model.unresolvedConflicts) {
                    conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(conflict.field)
                            .font(.callout.weight(.semibold))
                        ForEach(conflict.candidates) {
                            candidate in
                            Button {
                                model.resolveConflict(
                                    field: conflict.field,
                                    value: candidate.value
                                )
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(
                                        alignment: .leading,
                                        spacing: 3
                                    ) {
                                        Text(candidate.value)
                                            .foregroundStyle(
                                                .primary
                                            )
                                        Text(
                                            "来自：\(candidate.sourceTitle)"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(
                                            .secondary
                                        )
                                    }
                                    Spacer()
                                    Text("选择")
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(11)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
            .padding(13)
            .background(
                .red.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
    }

    private var advancedFields: some View {
        DisclosureGroup("扩展能力（切换时自动应用）") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(
                        "资料明确写出的值已自动带入；没写明的字段保持原设置。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("按资料重新自动设置") {
                        model.applyExtractedConfiguration()
                    }
                    .buttonStyle(.bordered)
                }
                labeledField("上下文长度") {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField(
                            "可留空",
                            text: $model.contextWindow
                        )
                        .textFieldStyle(.roundedBorder)
                        Text(
                            "模型可用上下文上限。只填模型或Provider明确给出的值；填大不会扩容，反而可能使请求失败。留空沿用默认值。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                labeledField("本地自动压缩阈值") {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField(
                            "可留空",
                            text:
                                $model.autoCompactTokenLimit
                        )
                        .textFieldStyle(.roundedBorder)
                        Text(
                            "Codex本机达到此阈值后压缩历史；必须小于上下文长度。它不等于在线压缩。留空沿用默认值。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                labeledField("在线上下文压缩") {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker(
                            "在线上下文压缩",
                            selection:
                                $model.remoteCompactionSetting
                        ) {
                            ForEach(
                                ProviderRemoteCompactionSetting
                                    .allCases
                            ) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(
                            of: model.remoteCompactionSetting
                        ) { _, value in
                            switch value {
                            case .enabled:
                                model.providerCompatibilityName =
                                    "OpenAI"
                            case .disabled:
                                if model.providerCompatibilityName
                                    .caseInsensitiveCompare("OpenAI")
                                    == .orderedSame {
                                    model.providerCompatibilityName = ""
                                }
                            case .preserve:
                                break
                            }
                        }
                        Text(
                            CapabilityOptionHelp.remoteCompaction(
                                model.remoteCompactionSetting
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                labeledField("思考强度") {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker(
                            "思考强度",
                            selection:
                                $model.reasoningEffort
                        ) {
                            ForEach(
                                ReasoningEffort.allCases
                            ) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        Text(
                            CapabilityOptionHelp.reasoning(
                                model.reasoningEffort
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(
                        "支持图片输入",
                        isOn: $model.supportsImageInput
                    )
                    Text(
                        CapabilityOptionHelp.imageInput(
                            model.supportsImageInput
                                ? .enabled : .disabled
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                labeledField("速度档（Service Tier）") {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker(
                            "速度档",
                            selection: $model.serviceTierKind
                        ) {
                            ForEach(
                                ProviderServiceTierKind.allCases
                            ) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: model.serviceTierKind) {
                            _, value in
                            synchronizeFastModeWithServiceTier(
                                value
                            )
                        }
                        if model.serviceTierKind
                            == .providerSpecific {
                            TextField(
                                "填写中转明确提供的档位",
                                text:
                                    $model.serviceTierCustomValue
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        Text(
                            CapabilityOptionHelp.serviceTier(
                                model.serviceTierKind
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(
                            "选择具体档位会自动同步Codex Fast功能开关；保持原设置和自定义档位不会写入该开关。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                labeledField("Web Search") {
                    Picker(
                        "Web Search",
                        selection: $model.webSearchSetting
                    ) {
                        ForEach(
                            ProviderWebSearchSetting.allCases
                        ) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Text(
                        CapabilityOptionHelp.webSearch(
                            model.webSearchSetting
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                labeledField("回答详略（verbosity）") {
                    Picker(
                        "回答详略",
                        selection:
                            $model.modelVerbositySetting
                    ) {
                        ForEach(
                            ProviderModelVerbositySetting
                                .allCases
                        ) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Text(
                        CapabilityOptionHelp.verbosity(
                            model.modelVerbositySetting
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                labeledField("Provider响应留存") {
                    Picker(
                        "Provider响应留存",
                        selection:
                            $model
                                .responseStorageDisabledSetting
                    ) {
                        ForEach(
                            ProviderOptionalBooleanSetting
                                .allCases
                        ) { value in
                            Text(
                                CapabilityOptionHelp
                                    .responseStorageDisplayName(
                                        value
                                    )
                            )
                            .tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Text(
                        CapabilityOptionHelp.responseStorage(
                            model.responseStorageDisabledSetting
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                labeledField("Provider兼容名称") {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField(
                            "例如文档明确写出的 OpenAI",
                            text:
                                $model.providerCompatibilityName
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(
                            model.remoteCompactionSetting == .enabled
                        )
                        Text(
                            "写入 model_providers.<id>.name，不改变界面显示名。开启在线压缩时自动设为OpenAI；其他情况只采用资料明确值。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("将自动写入")
                        .font(.callout.weight(.semibold))
                    ForEach(
                        model.capabilityConfigurationSummary,
                        id: \.self
                    ) { value in
                        Label(value, systemImage: "arrow.right.circle")
                            .font(.caption)
                    }
                    Text(
                        "已配置或已请求不等于已验证；真实支持仍以切换后的分层探针结果为准。"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .blue.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }
            .padding(.top, 10)
        }
    }

    private func beginnerSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(17)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
