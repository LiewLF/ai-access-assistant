import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeginnerRelayCapabilityEditor: View {
    @Environment(\.appDisplayTextSize) private var displayTextSize
    let sourceProfile: CodexRelayProfile
    let isCurrent: Bool
    let save: (CodexRelayProfile) -> Void
    let cancel: () -> Void

    @State private var contextWindowText: String
    @State private var autoCompactLimitText: String
    @State private var reasoningEffort: ReasoningEffort
    @State private var serviceTierKind:
        ProviderServiceTierKind
    @State private var serviceTierCustomValue: String
    @State private var fastModeSetting:
        ProviderOptionalBooleanSetting
    @State private var webSearchSetting:
        ProviderWebSearchSetting
    @State private var modelVerbositySetting:
        ProviderModelVerbositySetting
    @State private var responseStorageDisabledSetting:
        ProviderOptionalBooleanSetting
    @State private var imageInputSetting:
        ProviderOptionalBooleanSetting
    @State private var remoteCompactionSetting:
        ProviderRemoteCompactionSetting
    @State private var providerCompatibilityName: String

    init(
        sourceProfile: CodexRelayProfile,
        isCurrent: Bool,
        save: @escaping (CodexRelayProfile) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.sourceProfile = sourceProfile
        self.isCurrent = isCurrent
        self.save = save
        self.cancel = cancel
        let capability =
            sourceProfile.effectiveCapabilityProfile
        let modelCapability = capability.models.first {
            $0.modelID == capability.defaultModel
        }
        let contextWindow = sourceProfile.contextWindow
            ?? modelCapability?.contextWindow
        let autoCompactLimit =
            sourceProfile.autoCompactTokenLimit
                ?? modelCapability?.localAutoCompactLimit
        _contextWindowText = State(
            initialValue: contextWindow.map(String.init) ?? ""
        )
        _autoCompactLimitText = State(
            initialValue:
                autoCompactLimit.map(String.init) ?? ""
        )
        _reasoningEffort = State(
            initialValue: sourceProfile.reasoningEffort
        )
        _serviceTierKind = State(
            initialValue: capability.serviceTier.requested.kind
        )
        _serviceTierCustomValue = State(
            initialValue:
                capability.serviceTier.requested
                    .providerValue ?? ""
        )
        let initialFastMode: ProviderOptionalBooleanSetting
        if let explicit = capability.fastModeEnabled {
            initialFastMode = ProviderOptionalBooleanSetting(
                value: explicit
            )
        } else {
            switch capability.serviceTier.requested.kind {
            case .fast:
                initialFastMode = .enabled
            case .standard, .flex:
                initialFastMode = .disabled
            case .inherit, .followCodex,
                 .providerSpecific:
                initialFastMode = .preserve
            }
        }
        _fastModeSetting = State(
            initialValue: initialFastMode
        )
        _webSearchSetting = State(
            initialValue: ProviderWebSearchSetting(
                configuredValue:
                    capability.webSearch.configuredValue
            )
        )
        _modelVerbositySetting = State(
            initialValue: ProviderModelVerbositySetting(
                configuredValue: capability.modelVerbosity
            )
        )
        _responseStorageDisabledSetting = State(
            initialValue: ProviderOptionalBooleanSetting(
                value:
                    capability.responseStorageDisabled
            )
        )
        let imageSetting: ProviderOptionalBooleanSetting
        switch capability.imageInput {
        case .verified, .requested:
            imageSetting = .enabled
        case .unsupported:
            imageSetting = .disabled
        case .unknown, .degraded:
            imageSetting = .preserve
        }
        _imageInputSetting = State(initialValue: imageSetting)
        _remoteCompactionSetting = State(
            initialValue: ProviderRemoteCompactionSetting(
                capability: capability.remoteCompaction
            )
        )
        _providerCompatibilityName = State(
            initialValue: capability.upstreamName ?? ""
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("“\(sourceProfile.name)”的扩展能力")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "只修改能力字段；地址、模型、Provider ID和认证策略保持不变。"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        isCurrent
                            ? "当前轨：保存后执行预写探针、快照、CAS和运行时验证；会快速重开Codex，但不整理历史会话。"
                            : "非当前轨：只更新受管档案；当前Codex不变，下次切换时自动应用。",
                        systemImage:
                            isCurrent
                                ? "arrow.triangle.2.circlepath"
                                : "tray.and.arrow.down"
                    )
                    .font(.callout)
                    .foregroundStyle(
                        isCurrent ? Color.orange : Color.blue
                    )
                    .padding(12)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        (isCurrent
                            ? Color.orange : Color.blue)
                            .opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 12) {
                        editorField("上下文长度") {
                            VStack(alignment: .leading, spacing: 5) {
                                TextField(
                                    "可留空",
                                    text: $contextWindowText
                                )
                                .textFieldStyle(.roundedBorder)
                                Text(
                                    "模型可用上限；只填明确值。填大不会扩容，可能导致请求失败。"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        editorField("本地自动压缩阈值") {
                            VStack(alignment: .leading, spacing: 5) {
                                TextField(
                                    "可留空",
                                    text: $autoCompactLimitText
                                )
                                .textFieldStyle(.roundedBorder)
                                Text(
                                    "Codex本机压缩历史的触发阈值；必须小于上下文长度，不等于在线压缩。"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    editorField("在线上下文压缩") {
                        VStack(alignment: .leading, spacing: 5) {
                            Picker(
                                "在线上下文压缩",
                                selection: $remoteCompactionSetting
                            ) {
                                ForEach(
                                    ProviderRemoteCompactionSetting
                                        .allCases
                                ) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .onChange(
                                of: remoteCompactionSetting
                            ) { _, value in
                                switch value {
                                case .enabled:
                                    providerCompatibilityName =
                                        "OpenAI"
                                case .disabled:
                                    if providerCompatibilityName
                                        .caseInsensitiveCompare("OpenAI")
                                        == .orderedSame {
                                        providerCompatibilityName = ""
                                    }
                                case .preserve:
                                    break
                                }
                            }
                            Text(
                                CapabilityOptionHelp.remoteCompaction(
                                    remoteCompactionSetting
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    editorField("思考强度") {
                        VStack(alignment: .leading, spacing: 5) {
                            Picker(
                                "思考强度",
                                selection: $reasoningEffort
                            ) {
                                ForEach(ReasoningEffort.allCases) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            Text(
                                CapabilityOptionHelp.reasoning(
                                    reasoningEffort
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    editorField("图片输入（Provider声明）") {
                        VStack(alignment: .leading, spacing: 5) {
                            Picker(
                                "图片输入",
                                selection: $imageInputSetting
                            ) {
                                ForEach(
                                    ProviderOptionalBooleanSetting
                                        .allCases
                                ) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            Text(
                                CapabilityOptionHelp.imageInput(
                                    imageInputSetting
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 12) {
                        editorField("协议") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Responses")
                                    .font(.callout.weight(.semibold))
                                Text("当前已验证版本固定使用Responses；协议变更需重新走核心接入。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        editorField("速度档（Service Tier）") {
                            VStack(alignment: .leading, spacing: 7) {
                                Picker(
                                    "速度档",
                                    selection: $serviceTierKind
                                ) {
                                    ForEach(
                                        ProviderServiceTierKind
                                            .allCases
                                    ) {
                                        Text($0.displayName).tag($0)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .onChange(
                                    of: serviceTierKind
                                ) { _, value in
                                    switch value {
                                    case .fast:
                                        fastModeSetting = .enabled
                                    case .standard, .flex:
                                        fastModeSetting = .disabled
                                    case .followCodex:
                                        fastModeSetting = .preserve
                                    case .inherit,
                                         .providerSpecific:
                                        break
                                    }
                                }
                                if serviceTierKind
                                    == .providerSpecific {
                                    TextField(
                                        "中转明确提供的档位",
                                        text:
                                            $serviceTierCustomValue
                                    )
                                    .textFieldStyle(.roundedBorder)
                                }
                                Text(
                                    CapabilityOptionHelp.serviceTier(
                                        serviceTierKind
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
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 12) {
                        editorField("Web Search（Responses）") {
                            Picker(
                                "Web Search",
                                selection: $webSearchSetting
                            ) {
                                ForEach(
                                    ProviderWebSearchSetting
                                        .allCases
                                ) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            Text(
                                CapabilityOptionHelp.webSearch(
                                    webSearchSetting
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        editorField("回答详略（verbosity）") {
                            Picker(
                                "回答详略",
                                selection:
                                    $modelVerbositySetting
                            ) {
                                ForEach(
                                    ProviderModelVerbositySetting
                                        .allCases
                                ) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            Text(
                                CapabilityOptionHelp.verbosity(
                                    modelVerbositySetting
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    editorField("Provider响应留存") {
                        Picker(
                            "Provider响应留存",
                            selection:
                                $responseStorageDisabledSetting
                        ) {
                            ForEach(
                                    ProviderOptionalBooleanSetting
                                        .allCases
                                ) {
                                Text(
                                    CapabilityOptionHelp
                                        .responseStorageDisplayName(
                                            $0
                                        )
                                )
                                .tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Text(
                            CapabilityOptionHelp.responseStorage(
                                responseStorageDisabledSetting
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    editorField("Provider兼容名称") {
                        VStack(alignment: .leading, spacing: 5) {
                            TextField(
                                "例如中转文档明确给出的 OpenAI",
                                text: $providerCompatibilityName
                            )
                            .textFieldStyle(.roundedBorder)
                            .disabled(
                                remoteCompactionSetting == .enabled
                            )
                            Text(
                                "写入 model_providers.<id>.name，不改变界面显示名。开启在线压缩时自动设为OpenAI；其他情况只采用明确值。"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("保存后配置")
                            .font(.callout.weight(.semibold))
                        ForEach(
                            targetProfile.map {
                                CapabilityOptionHelp
                                    .configurationSummary(
                                        $0
                                            .effectiveCapabilityProfile
                                            .configurationSummary
                                    )
                            } ?? [],
                            id: \.self
                        ) { value in
                            Label(
                                value,
                                systemImage:
                                    "slider.horizontal.3"
                            )
                            .font(.caption)
                        }
                        Text(
                            "已配置或已请求不等于已验证；真实支持仍以分层探针证据为准。"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        .blue.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                    if let validationMessage {
                        Label(
                            validationMessage,
                            systemImage:
                                "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
                    }
                }
                .padding(22)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack { cancelButton; Spacer(); saveButton }
                VStack(alignment: .trailing, spacing: 10) { saveButton; cancelButton }
            }
            .padding(18)
        }
        .appDisplayScale(displayTextSize)
        .frame(minWidth: 520, idealWidth: 650, minHeight: 440, idealHeight: 720)
    }

    private var cancelButton: some View {
        Button("取消", action: cancel)
            .keyboardShortcut(.cancelAction)
    }

    private var saveButton: some View {
        Button(isCurrent ? "保存并快速应用" : "保存扩展能力") {
            guard let targetProfile else { return }
            save(targetProfile)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(targetProfile == nil)
    }

    private var targetProfile: CodexRelayProfile? {
        guard basicValidationMessage == nil else {
            return nil
        }
        var draft = ProviderCapabilityConfigurationDraft()
        draft.serviceTierKind = serviceTierKind
        draft.serviceTierProviderValue =
            serviceTierCustomValue
        draft.fastMode = effectiveFastModeSetting
        draft.webSearch = webSearchSetting
        draft.modelVerbosity = modelVerbositySetting
        draft.responseStorageDisabled =
            responseStorageDisabledSetting
        draft.imageInput = imageInputSetting
        draft.remoteCompaction = remoteCompactionSetting
        draft.upstreamName = providerCompatibilityName
        let capability = sourceProfile
            .effectiveCapabilityProfile
            .applyingConfiguration(
                draft,
                contextWindow:
                    optionalPositiveInt(contextWindowText),
                localAutoCompactLimit:
                    optionalPositiveInt(autoCompactLimitText),
                reasoningEffort:
                    reasoningConfigurationValue
            )
        guard capability.validationIssues().isEmpty else {
            return nil
        }
        return sourceProfile.updatingCapabilities(
            capability,
            contextWindow:
                optionalPositiveInt(contextWindowText),
            autoCompactTokenLimit:
                optionalPositiveInt(autoCompactLimitText),
            reasoningEffort: reasoningEffort
        )
    }

    private var validationMessage: String? {
        if let basicValidationMessage {
            return basicValidationMessage
        }
        guard targetProfile != nil else {
            return "扩展能力配置不符合当前Schema"
        }
        return nil
    }

    private var effectiveFastModeSetting:
        ProviderOptionalBooleanSetting {
        switch serviceTierKind {
        case .fast:
            return .enabled
        case .standard, .flex:
            return .disabled
        case .followCodex:
            return .preserve
        case .inherit, .providerSpecific:
            return fastModeSetting
        }
    }

    private var basicValidationMessage: String? {
        let contextText = contextWindowText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compactText = autoCompactLimitText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !contextText.isEmpty,
           optionalPositiveInt(contextText) == nil {
            return "上下文长度必须是正整数"
        }
        if !compactText.isEmpty,
           optionalPositiveInt(compactText) == nil {
            return "自动压缩阈值必须是正整数"
        }
        if !compactText.isEmpty,
           contextText.isEmpty {
            return "设置自动压缩阈值前必须填写上下文长度"
        }
        if let context = optionalPositiveInt(contextText),
           let compact = optionalPositiveInt(compactText),
           compact >= context {
            return "自动压缩阈值必须小于上下文长度"
        }
        if serviceTierKind == .providerSpecific,
           serviceTierCustomValue.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            return "自定义速度档不能为空"
        }
        return nil
    }

    private var reasoningConfigurationValue: String? {
        switch reasoningEffort {
        case .automatic:
            return nil
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            return "xhigh"
        case .max:
            return "max"
        case .ultra:
            return "ultra"
        }
    }

    private func optionalPositiveInt(
        _ value: String
    ) -> Int? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              let parsed = Int(trimmed),
              parsed > 0 else {
            return nil
        }
        return parsed
    }

    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
