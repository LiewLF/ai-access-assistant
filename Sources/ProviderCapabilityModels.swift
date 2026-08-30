import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode([String: JSONValue].self)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum ProviderCapabilityStatus: String, Codable, CaseIterable, Sendable {
    case verified
    case requested
    case unsupported
    case unknown
    case degraded

    var isVerified: Bool { self == .verified }
}

enum ProviderCapabilitySourceType: String, Codable, Sendable {
    case userStated = "user_stated"
    case userConfirmed = "user_confirmed"
    case assistantSuggested = "assistant_suggested"
    case assistantInferred = "assistant_inferred"
    case toolVerified = "tool_verified"
    case externalSource = "external_source"
}

enum ProviderEvidenceFreshness: String, Codable, Sendable {
    case current
    case dated
    case unknown
}

struct ProviderCapabilityEvidence: Codable, Equatable, Sendable {
    let id: String
    let sourceType: ProviderCapabilitySourceType
    let locator: String
    let observedAt: Date?
    let freshness: ProviderEvidenceFreshness
    let confidence: Double?
    let summaryHash: String?
}

enum ProviderServiceTierKind:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case inherit
    case followCodex
    case standard
    case fast
    case flex
    case providerSpecific

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inherit: return "保持原设置"
        case .followCodex: return "跟随 Codex Fast 开关"
        case .standard: return "Standard"
        case .fast: return "Fast"
        case .flex: return "Flex"
        case .providerSpecific: return "自定义档位"
        }
    }
}

enum ProviderOptionalBooleanSetting:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve
    case enabled
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserve: return "保持原设置"
        case .enabled: return "开启"
        case .disabled: return "关闭"
        }
    }

    var value: Bool? {
        switch self {
        case .preserve: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    init(value: Bool?) {
        switch value {
        case .some(true): self = .enabled
        case .some(false): self = .disabled
        case .none: self = .preserve
        }
    }
}

enum ProviderWebSearchSetting:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve
    case disabled
    case cached
    case live

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserve: return "保持原设置"
        case .disabled: return "Disabled"
        case .cached: return "Cached"
        case .live: return "Live"
        }
    }

    var configuredValue: String? {
        self == .preserve ? nil : rawValue
    }

    init(configuredValue: String?) {
        self = configuredValue
            .flatMap(Self.init(rawValue:)) ?? .preserve
    }
}

enum ProviderModelVerbositySetting:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserve: return "保持原设置"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var configuredValue: String? {
        self == .preserve ? nil : rawValue
    }

    init(configuredValue: String?) {
        self = configuredValue
            .flatMap(Self.init(rawValue:)) ?? .preserve
    }
}

struct ProviderServiceTierIntent: Codable, Equatable, Sendable {
    let kind: ProviderServiceTierKind
    let providerValue: String?

    static let inherit = ProviderServiceTierIntent(
        kind: .inherit,
        providerValue: nil
    )

    static let fast = ProviderServiceTierIntent(
        kind: .fast,
        providerValue: nil
    )

    var configuredValue: String? {
        switch kind {
        case .inherit, .followCodex:
            return nil
        case .standard:
            return "standard"
        case .fast:
            return "fast"
        case .flex:
            return "flex"
        case .providerSpecific:
            return providerValue
        }
    }
}

struct ProviderServiceTierCapability: Codable, Equatable, Sendable {
    let requested: ProviderServiceTierIntent
    let emittedValue: String?
    let accepted: ProviderCapabilityStatus
    let actual: String?
    let fallback: String?
    let evidenceID: String?
}

enum RemoteCompactionActivation: String, Codable, Sendable {
    case providerName
    case providerField
    case endpoint
    case native
    case unknown
}

struct ProviderRemoteCompactionCapability:
    Codable, Equatable, Sendable {
    let status: ProviderCapabilityStatus
    let activation: RemoteCompactionActivation
    let requiredUpstreamName: String?
    let evidenceID: String?
}

enum ProviderRemoteCompactionSetting:
    String, Codable, CaseIterable, Identifiable, Sendable {
    case preserve
    case enabled
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserve: return "保持原设置"
        case .enabled: return "开启并自动配置"
        case .disabled: return "不启用"
        }
    }

    init(capability: ProviderRemoteCompactionCapability) {
        switch capability.status {
        case .verified, .requested:
            self = .enabled
        case .unsupported:
            self = .disabled
        case .unknown, .degraded:
            self = .preserve
        }
    }

    fileprivate func capability(
        preserving existing: ProviderRemoteCompactionCapability? = nil
    ) -> ProviderRemoteCompactionCapability {
        switch self {
        case .preserve:
            return existing
                ?? ProviderRemoteCompactionCapability(
                    status: .unknown,
                    activation: .unknown,
                    requiredUpstreamName: nil,
                    evidenceID: nil
                )
        case .enabled:
            if let existing,
               existing.status == .verified,
               existing.activation == .providerName,
               existing.requiredUpstreamName == "OpenAI" {
                return existing
            }
            return ProviderRemoteCompactionCapability(
                status: .requested,
                activation: .providerName,
                requiredUpstreamName: "OpenAI",
                evidenceID: nil
            )
        case .disabled:
            return ProviderRemoteCompactionCapability(
                status: .unsupported,
                activation: .providerName,
                requiredUpstreamName: "OpenAI",
                evidenceID: nil
            )
        }
    }
}

enum ProviderWebSearchMode: String, Codable, Sendable {
    case codexLive
    case providerNative
    case passthrough
    case mcp
    case unknown
}

struct ProviderWebSearchCapability: Codable, Equatable, Sendable {
    let status: ProviderCapabilityStatus
    let mode: ProviderWebSearchMode
    let citations: ProviderCapabilityStatus
    let configuredValue: String?
    let evidenceID: String?

    init(
        status: ProviderCapabilityStatus,
        mode: ProviderWebSearchMode,
        citations: ProviderCapabilityStatus,
        configuredValue: String? = nil,
        evidenceID: String?
    ) {
        self.status = status
        self.mode = mode
        self.citations = citations
        self.configuredValue = configuredValue
        self.evidenceID = evidenceID
    }
}

struct ProviderModelCapability: Codable, Equatable, Sendable {
    let modelID: String
    let contextWindow: Int?
    let localAutoCompactLimit: Int?
    let serviceTiers: [String]
    let defaultServiceTier: String?
    let reasoningEfforts: [String]
    let inputModalities: [String]
}

struct ProviderCapabilityProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let providerID: String
    let displayName: String
    let upstreamName: String?
    let baseURL: String
    let wireAPI: String
    let models: [ProviderModelCapability]
    let defaultModel: String
    let modelCatalogPath: String?
    let serviceTier: ProviderServiceTierCapability
    let fastModeEnabled: Bool?
    let remoteCompaction: ProviderRemoteCompactionCapability
    let webSearch: ProviderWebSearchCapability
    let textInput: ProviderCapabilityStatus
    let imageInput: ProviderCapabilityStatus
    let reasoning: ProviderCapabilityStatus
    let audioInput: ProviderCapabilityStatus
    let requiresOpenAIAuth: Bool?
    let responseStorageDisabled: Bool?
    let modelVerbosity: String?
    let supportsWebSockets: Bool?
    let supportsStandaloneWebSearch: Bool?
    let evidence: [ProviderCapabilityEvidence]
    let extensions: [String: JSONValue]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        providerID: String,
        displayName: String,
        upstreamName: String?,
        baseURL: String,
        wireAPI: String = "responses",
        models: [ProviderModelCapability],
        defaultModel: String,
        modelCatalogPath: String? = nil,
        serviceTier: ProviderServiceTierCapability,
        fastModeEnabled: Bool? = nil,
        remoteCompaction: ProviderRemoteCompactionCapability,
        webSearch: ProviderWebSearchCapability,
        textInput: ProviderCapabilityStatus,
        imageInput: ProviderCapabilityStatus,
        reasoning: ProviderCapabilityStatus,
        audioInput: ProviderCapabilityStatus = .unknown,
        requiresOpenAIAuth: Bool?,
        responseStorageDisabled: Bool?,
        modelVerbosity: String?,
        supportsWebSockets: Bool? = nil,
        supportsStandaloneWebSearch: Bool? = nil,
        evidence: [ProviderCapabilityEvidence] = [],
        extensions: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.displayName = displayName
        self.upstreamName = upstreamName
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.models = models
        self.defaultModel = defaultModel
        self.modelCatalogPath = modelCatalogPath
        self.serviceTier = serviceTier
        self.fastModeEnabled = fastModeEnabled
        self.remoteCompaction = remoteCompaction
        self.webSearch = webSearch
        self.textInput = textInput
        self.imageInput = imageInput
        self.reasoning = reasoning
        self.audioInput = audioInput
        self.requiresOpenAIAuth = requiresOpenAIAuth
        self.responseStorageDisabled = responseStorageDisabled
        self.modelVerbosity = modelVerbosity
        self.supportsWebSockets = supportsWebSockets
        self.supportsStandaloneWebSearch =
            supportsStandaloneWebSearch
        self.evidence = evidence
        self.extensions = extensions
    }

    func validationIssues() -> [String] {
        var issues: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            issues.append("unsupported capability schema")
        }
        if providerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            issues.append("provider ID is empty")
        }
        if displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            issues.append("display name is empty")
        }
        if wireAPI.lowercased() != "responses" {
            issues.append("wire API is not responses")
        }
        let modelIDs = models.map(\.modelID)
        if Set(modelIDs).count != modelIDs.count {
            issues.append("duplicate model ID")
        }
        if !modelIDs.contains(defaultModel) {
            issues.append("default model is absent")
        }
        if let modelCatalogPath {
            if !modelCatalogPath.hasPrefix("/")
                || modelCatalogPath.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                }) {
                issues.append("model catalog path is unsafe")
            }
        }
        for model in models {
            if let context = model.contextWindow, context <= 0 {
                issues.append("invalid context window for \(model.modelID)")
            }
            if let compact = model.localAutoCompactLimit {
                guard let context = model.contextWindow,
                      compact > 0,
                      compact < context else {
                    issues.append(
                        "invalid auto compact limit for \(model.modelID)"
                    )
                    continue
                }
            }
        }
        if serviceTier.requested.kind == .providerSpecific,
           serviceTier.requested.providerValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false {
            issues.append("provider-specific service tier is empty")
        }
        return issues
    }

    static func legacy(
        providerID: String,
        displayName: String,
        baseURL: String,
        models: [String],
        defaultModel: String,
        contextWindow: Int?,
        localAutoCompactLimit: Int?,
        reasoningEffort: String?,
        requiresOpenAIAuth: Bool? = true
    ) -> ProviderCapabilityProfile {
        let uniqueModels = Array(Set(models + [defaultModel])).sorted()
        let modelProfiles = uniqueModels.map { model in
            ProviderModelCapability(
                modelID: model,
                contextWindow:
                    model == defaultModel ? contextWindow : nil,
                localAutoCompactLimit:
                    model == defaultModel
                        ? localAutoCompactLimit : nil,
                serviceTiers: [],
                defaultServiceTier: nil,
                reasoningEfforts:
                    model == defaultModel
                        ? reasoningEffort.map { [$0] } ?? []
                        : [],
                inputModalities: []
            )
        }
        return ProviderCapabilityProfile(
            providerID: providerID,
            displayName: displayName,
            upstreamName: nil,
            baseURL: baseURL,
            models: modelProfiles,
            defaultModel: defaultModel,
            modelCatalogPath: nil,
            serviceTier: ProviderServiceTierCapability(
                requested: .inherit,
                emittedValue: nil,
                accepted: .unknown,
                actual: nil,
                fallback: nil,
                evidenceID: nil
            ),
            fastModeEnabled: nil,
            remoteCompaction:
                ProviderRemoteCompactionCapability(
                    status: .unknown,
                    activation: .unknown,
                    requiredUpstreamName: nil,
                    evidenceID: nil
                ),
            webSearch: ProviderWebSearchCapability(
                status: .unknown,
                mode: .unknown,
                citations: .unknown,
                evidenceID: nil
            ),
            textInput: .requested,
            imageInput: .unknown,
            reasoning: .requested,
            requiresOpenAIAuth: requiresOpenAIAuth,
            responseStorageDisabled: nil,
            modelVerbosity: nil
        )
    }

    func withManagedModelCatalog(
        path: String,
        models replacementModels: [ProviderModelCapability]? = nil
    ) -> ProviderCapabilityProfile {
        ProviderCapabilityProfile(
            schemaVersion: schemaVersion,
            providerID: providerID,
            displayName: displayName,
            upstreamName: upstreamName,
            baseURL: baseURL,
            wireAPI: wireAPI,
            models: replacementModels ?? models,
            defaultModel: defaultModel,
            modelCatalogPath: path,
            serviceTier: serviceTier,
            fastModeEnabled: fastModeEnabled,
            remoteCompaction: remoteCompaction,
            webSearch: webSearch,
            textInput: textInput,
            imageInput: imageInput,
            reasoning: reasoning,
            audioInput: audioInput,
            requiresOpenAIAuth: requiresOpenAIAuth,
            responseStorageDisabled: responseStorageDisabled,
            modelVerbosity: modelVerbosity,
            supportsWebSockets: supportsWebSockets,
            supportsStandaloneWebSearch:
                supportsStandaloneWebSearch,
            evidence: evidence,
            extensions: extensions
        )
    }

    func rebased(
        providerID: String,
        displayName: String,
        baseURL: String
    ) -> ProviderCapabilityProfile {
        ProviderCapabilityProfile(
            schemaVersion: schemaVersion,
            providerID: providerID,
            displayName: displayName,
            upstreamName: upstreamName,
            baseURL: baseURL,
            wireAPI: wireAPI,
            models: models,
            defaultModel: defaultModel,
            modelCatalogPath: modelCatalogPath,
            serviceTier: serviceTier,
            fastModeEnabled: fastModeEnabled,
            remoteCompaction: remoteCompaction,
            webSearch: webSearch,
            textInput: textInput,
            imageInput: imageInput,
            reasoning: reasoning,
            audioInput: audioInput,
            requiresOpenAIAuth: requiresOpenAIAuth,
            responseStorageDisabled: responseStorageDisabled,
            modelVerbosity: modelVerbosity,
            supportsWebSockets: supportsWebSockets,
            supportsStandaloneWebSearch:
                supportsStandaloneWebSearch,
            evidence: evidence,
            extensions: extensions
        )
    }

    func updatingRelaySettings(
        displayName: String,
        baseURL: String,
        models relayModels: [String],
        defaultModel relayDefaultModel: String
    ) -> ProviderCapabilityProfile {
        let uniqueModels = relayModels.reduce(into: [String]()) {
            result, modelID in
            guard !result.contains(modelID) else { return }
            result.append(modelID)
        }
        let modelProfiles = uniqueModels.map { modelID in
            models.first(where: { $0.modelID == modelID })
                ?? ProviderModelCapability(
                    modelID: modelID,
                    contextWindow: nil,
                    localAutoCompactLimit: nil,
                    serviceTiers: [],
                    defaultServiceTier: nil,
                    reasoningEfforts: [],
                    inputModalities: []
                )
        }
        return ProviderCapabilityProfile(
            schemaVersion: schemaVersion,
            providerID: providerID,
            displayName: displayName,
            upstreamName: upstreamName,
            baseURL: baseURL,
            wireAPI: wireAPI,
            models: modelProfiles,
            defaultModel: relayDefaultModel,
            modelCatalogPath: modelCatalogPath,
            serviceTier: serviceTier,
            fastModeEnabled: fastModeEnabled,
            remoteCompaction: remoteCompaction,
            webSearch: webSearch,
            textInput: textInput,
            imageInput: imageInput,
            reasoning: reasoning,
            audioInput: audioInput,
            requiresOpenAIAuth: requiresOpenAIAuth,
            responseStorageDisabled: responseStorageDisabled,
            modelVerbosity: modelVerbosity,
            supportsWebSockets: supportsWebSockets,
            supportsStandaloneWebSearch:
                supportsStandaloneWebSearch,
            evidence: evidence,
            extensions: extensions
        )
    }

    func applyingConfiguration(
        _ draft: ProviderCapabilityConfigurationDraft,
        contextWindow: Int?,
        localAutoCompactLimit: Int?,
        reasoningEffort: String?
    ) -> ProviderCapabilityProfile {
        let requestedTier = draft.serviceTierIntent
        let tierChanged = requestedTier != serviceTier.requested
        let configuredSearch = draft.webSearch.configuredValue
        let searchChanged =
            configuredSearch != webSearch.configuredValue
        let updatedModels = models.map { model in
            guard model.modelID == defaultModel else {
                return model
            }
            var efforts = model.reasoningEfforts
            if let reasoningEffort,
               !efforts.contains(reasoningEffort) {
                efforts.append(reasoningEffort)
            }
            var inputModalities = model.inputModalities
            if let supportsImage = draft.imageInput.value {
                if supportsImage {
                    if !inputModalities.contains("image") {
                        inputModalities.append("image")
                    }
                } else {
                    inputModalities.removeAll { $0 == "image" }
                }
            }
            return ProviderModelCapability(
                modelID: model.modelID,
                contextWindow: contextWindow,
                localAutoCompactLimit:
                    localAutoCompactLimit,
                serviceTiers: model.serviceTiers,
                defaultServiceTier:
                    model.defaultServiceTier,
                reasoningEfforts: efforts,
                inputModalities: inputModalities
            )
        }
        return ProviderCapabilityProfile(
            schemaVersion: schemaVersion,
            providerID: providerID,
            displayName: displayName,
            upstreamName: draft.effectiveUpstreamName,
            baseURL: baseURL,
            wireAPI: wireAPI,
            models: updatedModels,
            defaultModel: defaultModel,
            modelCatalogPath: modelCatalogPath,
            serviceTier: tierChanged
                ? ProviderServiceTierCapability(
                    requested: requestedTier,
                    emittedValue: requestedTier.configuredValue,
                    accepted:
                        requestedTier.configuredValue == nil
                            ? .unknown : .requested,
                    actual: nil,
                    fallback: nil,
                    evidenceID: nil
                )
                : serviceTier,
            fastModeEnabled: draft.fastMode.value,
            remoteCompaction: draft.remoteCompaction.capability(
                preserving: remoteCompaction
            ),
            webSearch: searchChanged
                ? ProviderWebSearchCapability(
                    status:
                        configuredSearch == nil
                            ? .unknown : .requested,
                    mode:
                        configuredSearch == nil
                            ? .unknown : .codexLive,
                    citations: webSearch.citations,
                    configuredValue: configuredSearch,
                    evidenceID: nil
                )
                : webSearch,
            textInput: textInput,
            imageInput: {
                switch draft.imageInput {
                case .preserve: return imageInput
                case .enabled: return .requested
                case .disabled: return .unsupported
                }
            }(),
            reasoning: reasoning,
            audioInput: audioInput,
            requiresOpenAIAuth: requiresOpenAIAuth,
            responseStorageDisabled:
                draft.responseStorageDisabled.value,
            modelVerbosity:
                draft.modelVerbosity.configuredValue,
            supportsWebSockets: supportsWebSockets,
            supportsStandaloneWebSearch:
                supportsStandaloneWebSearch,
            evidence: evidence,
            extensions: extensions
        )
    }

    var configurationSummary: [String] {
        var values: [String] = []
        values.append("模型：\(defaultModel)")
        if let model = models.first(where: {
            $0.modelID == defaultModel
        }) {
            if let contextWindow = model.contextWindow {
                values.append("上下文：\(contextWindow)")
            }
            if let localAutoCompactLimit =
                model.localAutoCompactLimit {
                values.append("自动压缩阈值：\(localAutoCompactLimit)")
            }
            if let reasoningEffort =
                model.reasoningEfforts.first {
                values.append("思考强度：\(reasoningEffort)")
            }
        }
        if serviceTier.requested.kind == .followCodex {
            values.append("速度档：followCodex")
        } else if let configured = serviceTier.requested.configuredValue {
            values.append("速度档：\(configured)")
        }
        if let fastModeEnabled {
            values.append(
                "Fast开关：\(fastModeEnabled ? "开启" : "关闭")"
            )
        } else if serviceTier.requested.kind == .fast {
            values.append("Fast开关：开启")
        } else if serviceTier.requested.kind == .standard
                    || serviceTier.requested.kind == .flex {
            values.append("Fast开关：关闭")
        } else if serviceTier.requested.kind == .followCodex {
            values.append("Fast开关：跟随Codex")
        }
        if let configured = webSearch.configuredValue {
            values.append("Web Search：\(configured)")
        }
        if let modelVerbosity {
            values.append("回答详略：\(modelVerbosity)")
        }
        if let responseStorageDisabled {
            values.append(
                "响应存储：\(responseStorageDisabled ? "禁用" : "允许")"
            )
        }
        switch remoteCompaction.status {
        case .verified:
            values.append("在线压缩：已验证")
        case .requested:
            values.append("在线压缩：已请求，待真实事件验证")
        case .unsupported:
            values.append("在线压缩：不启用")
        case .degraded:
            values.append("在线压缩：有差异")
        case .unknown:
            break
        }
        if let upstreamName {
            values.append("Provider兼容名称：\(upstreamName)")
        }
        switch imageInput {
        case .verified:
            values.append("图片输入：已验证")
        case .requested:
            values.append("图片输入：声明支持")
        case .unsupported:
            values.append("图片输入：声明不支持")
        case .degraded:
            values.append("图片输入：有差异")
        case .unknown:
            break
        }
        if let modelCatalogPath {
            values.append("受管模型目录：\(modelCatalogPath)")
        }
        return values
    }
}

struct ProviderCapabilityConfigurationDraft: Equatable, Sendable {
    var serviceTierKind: ProviderServiceTierKind = .inherit
    var serviceTierProviderValue = ""
    var fastMode: ProviderOptionalBooleanSetting = .preserve
    var webSearch: ProviderWebSearchSetting = .preserve
    var modelVerbosity: ProviderModelVerbositySetting = .preserve
    var responseStorageDisabled:
        ProviderOptionalBooleanSetting = .preserve
    var imageInput: ProviderOptionalBooleanSetting = .preserve
    var remoteCompaction:
        ProviderRemoteCompactionSetting = .preserve
    var upstreamName = ""

    func makeProfile(
        providerID: String,
        displayName: String,
        baseURL: String,
        models: [String],
        defaultModel: String,
        contextWindow: Int?,
        localAutoCompactLimit: Int?,
        reasoningEffort: String?,
        supportsTextInput: Bool,
        supportsImageInput: Bool
    ) -> ProviderCapabilityProfile {
        let configuredTier = serviceTierIntent
        let configuredImageInput =
            imageInput.value ?? supportsImageInput
        let uniqueModels = uniqueStrings(
            models + [defaultModel]
        )
        let modelCapabilities = uniqueModels.map { modelID in
            ProviderModelCapability(
                modelID: modelID,
                contextWindow:
                    modelID == defaultModel
                        ? contextWindow : nil,
                localAutoCompactLimit:
                    modelID == defaultModel
                        ? localAutoCompactLimit : nil,
                serviceTiers:
                    modelID == defaultModel
                        ? configuredTier.configuredValue
                            .map { [$0] } ?? []
                        : [],
                defaultServiceTier:
                    modelID == defaultModel
                        ? configuredTier.configuredValue : nil,
                reasoningEfforts:
                    modelID == defaultModel
                        ? reasoningEffort.map { [$0] } ?? []
                        : [],
                inputModalities:
                    modelID == defaultModel
                        ? inputModalities(
                            text: supportsTextInput,
                            image: configuredImageInput
                        ) : []
            )
        }
        let configuredSearch = webSearch.configuredValue
        return ProviderCapabilityProfile(
            providerID: providerID,
            displayName: displayName,
            upstreamName: effectiveUpstreamName,
            baseURL: baseURL,
            models: modelCapabilities,
            defaultModel: defaultModel,
            serviceTier: ProviderServiceTierCapability(
                requested: configuredTier,
                emittedValue: configuredTier.configuredValue,
                accepted:
                    configuredTier.configuredValue == nil
                        ? .unknown : .requested,
                actual: nil,
                fallback: nil,
                evidenceID: nil
            ),
            fastModeEnabled: fastMode.value,
            remoteCompaction: remoteCompaction.capability(),
            webSearch: ProviderWebSearchCapability(
                status:
                    configuredSearch == nil
                        ? .unknown : .requested,
                mode:
                    configuredSearch == nil
                        ? .unknown : .codexLive,
                citations: .unknown,
                configuredValue: configuredSearch,
                evidenceID: nil
            ),
            textInput:
                supportsTextInput ? .requested : .unsupported,
            imageInput:
                configuredImageInput ? .requested : .unsupported,
            reasoning: .requested,
            requiresOpenAIAuth: true,
            responseStorageDisabled:
                responseStorageDisabled.value,
            modelVerbosity: modelVerbosity.configuredValue
        )
    }

    fileprivate var serviceTierIntent: ProviderServiceTierIntent {
        ProviderServiceTierIntent(
            kind: serviceTierKind,
            providerValue:
                serviceTierKind == .providerSpecific
                    ? normalized(serviceTierProviderValue)
                    : nil
        )
    }

    var effectiveUpstreamName: String? {
        let configured = normalized(upstreamName)
        switch remoteCompaction {
        case .preserve:
            return configured
        case .enabled:
            return "OpenAI"
        case .disabled:
            guard configured?.caseInsensitiveCompare("OpenAI")
                    == .orderedSame else {
                return configured
            }
            return nil
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty,
                  seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
    }

    private func inputModalities(
        text: Bool,
        image: Bool
    ) -> [String] {
        var values: [String] = []
        if text { values.append("text") }
        if image { values.append("image") }
        return values
    }
}

struct LocalCapabilityInvariantRecord: Codable, Equatable, Sendable {
    let name: String
    let path: String?
    let count: Int?
    let hash: String?
}

struct LocalCapabilityInvariantSnapshot:
    Codable, Equatable, Sendable {
    let records: [LocalCapabilityInvariantRecord]
    let beforeHash: String
    let afterHash: String?
    let semanticDiff: [String]

    var isPreserved: Bool? {
        guard let afterHash else { return nil }
        return beforeHash == afterHash && semanticDiff.isEmpty
    }
}

struct AccountEntitlementObservation: Codable, Equatable, Sendable {
    let chatGPTLogin: ProviderCapabilityStatus
    let apps: ProviderCapabilityStatus
    let connectors: ProviderCapabilityStatus
    let pluginMarketplace: ProviderCapabilityStatus
    let accountPlan: String?
    let observedAt: Date?
}

struct CapabilityParityStage: Codable, Equatable, Sendable {
    let status: ProviderCapabilityStatus
    let configured: String?
    let emitted: String?
    let accepted: String?
    let actual: String?
    let fallback: String?
    let evidenceID: String?
}

enum CapabilityParityVerdict: String, Codable, Sendable {
    case consistent
    case different
    case unverified
}

struct CapabilityParityContract: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let providerID: String
    let model: CapabilityParityStage
    let modelCatalog: CapabilityParityStage
    let reasoning: CapabilityParityStage
    let speedTier: CapabilityParityStage
    let contextWindow: CapabilityParityStage
    let localAutoCompact: CapabilityParityStage
    let remoteCompaction: CapabilityParityStage
    let webSearch: CapabilityParityStage
    let citations: CapabilityParityStage
    let textInput: CapabilityParityStage
    let imageInput: CapabilityParityStage
    let protocolCapability: CapabilityParityStage
    let authentication: CapabilityParityStage
    let responseStorage: CapabilityParityStage
    let localInvariants: LocalCapabilityInvariantSnapshot?
    let entitlements: AccountEntitlementObservation?
    let codexVersion: String
    let observedAt: Date
    let evidenceHash: String

    var verdict: CapabilityParityVerdict {
        let core = [
            model.status,
            reasoning.status,
            speedTier.status,
            contextWindow.status,
            localAutoCompact.status,
            remoteCompaction.status,
            webSearch.status,
            citations.status,
            textInput.status,
            imageInput.status,
            protocolCapability.status,
            authentication.status,
            responseStorage.status,
        ]
        if core.contains(.degraded)
            || core.contains(.unsupported)
            || localInvariants?.isPreserved == false {
            return .different
        }
        if core.allSatisfy(\.isVerified)
            && localInvariants?.isPreserved == true {
            return .consistent
        }
        return .unverified
    }
}
