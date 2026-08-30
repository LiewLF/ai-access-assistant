import Foundation

enum AdapterTarget: String, CaseIterable, Identifiable {
    case codexPlusPlus = "Codex++"
    case ccSwitch = "CC Switch"
    case cherryStudio = "Cherry Studio"
    case manual = "手动配置"

    var id: String { rawValue }

    var statusText: String {
        switch self {
        case .codexPlusPlus: return "可生成待确认导入；激活中转会切换 Codex 运行配置"
        case .ccSwitch: return "Codex 导入仍锁定 high，已阻止"
        case .cherryStudio: return "只对 Cherry Studio 桌面端开放确认型导入"
        case .manual: return "只生成操作清单，不写目标配置"
        }
    }
}

enum ConfigurationTool: String, CaseIterable, Identifiable, Codable {
    case codexPlusPlus = "Codex++"
    case ccSwitch = "CC Switch"

    var id: String { rawValue }

    var adapterTarget: AdapterTarget {
        switch self {
        case .codexPlusPlus: return .codexPlusPlus
        case .ccSwitch: return .ccSwitch
        }
    }
}

enum ConfigurationMethod: String, CaseIterable, Identifiable, Codable {
    case managed = "AI接入助手安全托管"
    case toolImport = "通过配置管理工具导入"
    case builtIn = "目标 Agent 内置配置"
    case guidance = "手动指导"

    var id: String { rawValue }
}

enum DesktopAgent: String, CaseIterable, Identifiable, Codable {
    case codexDesktop = "Codex Desktop"
    case claudeDesktop = "Claude Desktop"
    case cherryStudio = "Cherry Studio 桌面端"

    var id: String { rawValue }

    var userConfirmedDefaults: ModelCapabilityProfile {
        switch self {
        case .codexDesktop:
            return ModelCapabilityProfile(
                contextWindow: 272_000,
                autoCompactTokenLimit: 258_000,
                reasoningEnabled: true,
                reasoningEffort: .automatic,
                supportsTextInput: true,
                supportsImageInput: true
            )
        case .claudeDesktop:
            return ModelCapabilityProfile(
                contextWindow: 1_000_000,
                autoCompactTokenLimit: nil,
                reasoningEnabled: true,
                reasoningEffort: .automatic,
                supportsTextInput: true,
                supportsImageInput: true
            )
        case .cherryStudio:
            return ModelCapabilityProfile(
                contextWindow: nil,
                autoCompactTokenLimit: nil,
                reasoningEnabled: nil,
                reasoningEffort: .automatic,
                supportsTextInput: true,
                supportsImageInput: true
            )
        }
    }
}

enum RelayWireProtocol: String, CaseIterable, Identifiable, Codable {
    case responses = "Responses API"
    case chatCompletions = "Chat Completions"
    case anthropicMessages = "Anthropic Messages"

    var id: String { rawValue }

    var importValue: String {
        switch self {
        case .responses: return "responses"
        case .chatCompletions: return "chat"
        case .anthropicMessages: return "anthropic"
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable, Codable {
    case automatic = "自动"
    case low = "低"
    case medium = "中"
    case high = "高"
    case xhigh = "超高"
    case max = "最大"
    case ultra = "极限"

    var id: String { rawValue }
}

struct ModelCapabilityProfile: Equatable, Codable {
    var contextWindow: Int?
    var autoCompactTokenLimit: Int?
    var reasoningEnabled: Bool?
    var reasoningEffort: ReasoningEffort?
    var supportsTextInput: Bool?
    var supportsImageInput: Bool?
    var serviceTier: String? = nil
    var fastMode: Bool? = nil
    var webSearch: String? = nil
    var modelVerbosity: String? = nil
    var disableResponseStorage: Bool? = nil
    var upstreamName: String? = nil
}

enum EvidenceStatus: String, Codable {
    case verified = "已核验"
    case userConfirmed = "用户确认"
    case extracted = "文档识别"
    case unknown = "未写明"
}

struct FieldEvidence: Equatable, Codable {
    let field: String
    let value: String
    let source: String
    let status: EvidenceStatus
}

struct RelayProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let homepageURL: String
    let documentationURL: String
    let defaultBaseURL: String?
    let verifiedProtocols: [RelayWireProtocol]
    let region: String
    let lastVerified: String
    let notes: String
}

enum AutomationLevel: String {
    case guidance = "仅指导"
    case export = "可安全导出"
    case simulation = "切换模拟"
    case blocked = "已阻止"
}

struct CompatibilityRecord: Identifiable {
    let id: String
    let relayID: String
    let manager: AdapterTarget
    let method: ConfigurationMethod
    let tool: ConfigurationTool?
    let agent: DesktopAgent
    let protocols: [RelayWireProtocol]
    let level: AutomationLevel
    let configurationMethod: String
    let officialModeImpact: String
    let recoveryMethod: String
    let evidence: String
    let verifiedAt: String
}

struct ExtractedRelayConfiguration: Equatable {
    var providerName: String?
    var baseURL: String?
    var protocols: [RelayWireProtocol]
    var models: [String]
    var capabilities: ModelCapabilityProfile
    var evidence: [FieldEvidence]
    var warnings: [String]

    static let empty = ExtractedRelayConfiguration(
        providerName: nil,
        baseURL: nil,
        protocols: [],
        models: [],
        capabilities: ModelCapabilityProfile(
            contextWindow: nil,
            autoCompactTokenLimit: nil,
            reasoningEnabled: nil,
            reasoningEffort: nil,
            supportsTextInput: nil,
            supportsImageInput: nil
        ),
        evidence: [],
        warnings: []
    )
}

struct ConfigDraft: Equatable {
    var manager: AdapterTarget
    var method: ConfigurationMethod
    var tool: ConfigurationTool?
    var agent: DesktopAgent
    var relayID: String
    var providerName: String
    var baseURL: String
    var apiKey: String
    var model: String
    var models: [String]
    var wireProtocol: RelayWireProtocol
    var capabilities: ModelCapabilityProfile
    var evidence: [FieldEvidence]
}

struct GeneratedArtifact: Identifiable {
    let id = UUID()
    let fileName: String
    let data: Data
    let redactedPreview: String
    let containsSecret: Bool
}

struct GeneratedConfiguration {
    let manager: AdapterTarget
    let artifacts: [GeneratedArtifact]
    let instructions: String
    let safetySummary: String
}

enum ConfigurationGenerationError: LocalizedError {
    case missingProviderName
    case invalidBaseURL
    case missingAPIKey
    case missingModel
    case incompatibleCombination(String)
    case safetyBlocked(String)
    case invalidImportURL
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingProviderName: return "供应商名称未识别"
        case .invalidBaseURL: return "Base URL 必须是 HTTPS；仅本机地址允许 HTTP"
        case .missingAPIKey: return "还差 API Key"
        case .missingModel: return "文档没有可核验模型名，请选择或填写模型"
        case let .incompatibleCombination(reason): return reason
        case let .safetyBlocked(reason): return "安全检查阻止：\(reason)"
        case .invalidImportURL: return "无法生成 Codex++ 导入链接"
        case .encodingFailed: return "配置文件编码失败"
        }
    }
}

protocol ConfigurationAdapter {
    var manager: AdapterTarget { get }
    func generate(from draft: ConfigDraft, compatibility: CompatibilityRecord) throws -> GeneratedConfiguration
}

enum ConfigurationAdapters {
    static func adapter(for manager: AdapterTarget) -> any ConfigurationAdapter {
        switch manager {
        case .codexPlusPlus: return CodexPlusPlusAdapter()
        case .cherryStudio: return CherryStudioAdapter()
        case .ccSwitch, .manual: return GuidanceOnlyAdapter(manager: manager)
        }
    }
}

struct CodexPlusPlusAdapter: ConfigurationAdapter {
    let manager = AdapterTarget.codexPlusPlus

    func generate(from draft: ConfigDraft, compatibility: CompatibilityRecord) throws -> GeneratedConfiguration {
        try validate(draft, compatibility: compatibility)
        let realURL = try importURL(from: draft, apiKey: draft.apiKey)
        let previewURL = try importURL(from: draft, apiKey: "<API_KEY 已遮盖>")
        let importArtifact = try AdapterArtifactFactory.webLocation(
            name: "Codex++-供应商导入.webloc",
            url: realURL,
            redactedURL: previewURL
        )
        let capabilityText = Self.capabilityDescription(draft.capabilities)
        let evidenceText = draft.evidence.isEmpty
            ? "- 未取得字段来源"
            : draft.evidence.map { "- \($0.field)：\($0.value)｜\($0.status.rawValue)｜\($0.source)" }.joined(separator: "\n")
        let guide = """
        # AI接入助手导出说明

        配置工具：\(draft.manager.rawValue)
        桌面 Agent：\(draft.agent.rawValue)
        供应商：\(draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines))
        协议：\(draft.wireProtocol.rawValue)
        Base URL：\(Self.cleanBaseURL(draft.baseURL))
        模型：\(draft.model.trimmingCharacters(in: .whitespacesAndNewlines))
        可用模型：\(draft.models.joined(separator: "、"))
        \(capabilityText)

        ## 字段来源

        \(evidenceText)

        ## 使用

        1. 双击 `Codex++-供应商导入.webloc`。
        2. Codex++ 显示待导入供应商后，再次核对并确认。
        3. 上游导入协议不携带模型和能力字段；按本说明在供应商模型页核对。
        4. 仅导出文件不会修改 Codex++ 或 `~/.codex`；你在 Codex++ 确认导入后，会新增供应商资料。
        5. 后续激活“纯 API”供应商时，Codex++ 会切换 `~/.codex/config.toml` 和 `auth.json`；它不是零影响操作。
        6. 激活前、使用中转、切回官方后，分别按另外三份检查单操作。
        """
        guard let guideData = guide.data(using: .utf8) else {
            throw ConfigurationGenerationError.encodingFailed
        }

        let before = try AdapterArtifactFactory.markdown(name: "1-切换前检查.md", text: Self.preSwitchChecklist)
        let relayCheck = try AdapterArtifactFactory.markdown(name: "2-中转模式验证.md", text: Self.relayChecklist)
        let officialCheck = try AdapterArtifactFactory.markdown(name: "3-切回官方验证.md", text: Self.officialChecklist)

        return GeneratedConfiguration(
            manager: manager,
            artifacts: [
                importArtifact,
                GeneratedArtifact(
                    fileName: "配置说明.md",
                    data: guideData,
                    redactedPreview: guide,
                    containsSecret: false
                ),
                before,
                relayCheck,
                officialCheck,
            ],
            instructions: "导出本身不改配置；Codex++ 二次确认只导入供应商，真正激活会切换 Codex 运行文件。",
            safetySummary: "本软件只写桌面副本；不自动激活、不读取或修改 `~/.codex`、数据库、认证与 Keychain。"
        )
    }

    private func validate(_ draft: ConfigDraft, compatibility: CompatibilityRecord) throws {
        guard compatibility.level == .export else {
            throw ConfigurationGenerationError.incompatibleCombination(
                "该组合只有指导证据，暂不生成自动导入"
            )
        }
        guard !draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationGenerationError.missingProviderName
        }
        guard Self.isAllowedBaseURL(draft.baseURL) else {
            throw ConfigurationGenerationError.invalidBaseURL
        }
        guard !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationGenerationError.missingAPIKey
        }
        guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationGenerationError.missingModel
        }
        guard compatibility.protocols.contains(draft.wireProtocol) else {
            throw ConfigurationGenerationError.incompatibleCombination("当前组合没有该协议证据")
        }
        let audit = SafetyPolicies.policy(manager: draft.manager, agent: draft.agent)
            .evaluate(proposedWrites: ["~/Desktop/AI接入助手导出"])
        guard audit.allowed else {
            throw ConfigurationGenerationError.safetyBlocked(audit.reasons.joined(separator: "；"))
        }
    }

    static func isAllowedBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let host = components.host?.lowercased() else { return false }
        if components.scheme?.lowercased() == "https" { return true }
        return components.scheme?.lowercased() == "http"
            && ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    static func cleanBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func importURL(from draft: ConfigDraft, apiKey: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "codexplusplus"
        components.host = "v1"
        components.path = "/import/provider"
        components.queryItems = [
            URLQueryItem(name: "resource", value: "provider"),
            URLQueryItem(name: "name", value: draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "baseUrl", value: Self.cleanBaseURL(draft.baseURL)),
            URLQueryItem(name: "apiKey", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "wireApi", value: draft.wireProtocol.importValue),
            URLQueryItem(name: "relayMode", value: "pureApi"),
        ]
        guard let url = components.url else { throw ConfigurationGenerationError.invalidImportURL }
        return url
    }

    private static func capabilityDescription(_ profile: ModelCapabilityProfile) -> String {
        let context = profile.contextWindow.map(String.init) ?? "文档未写明"
        let compact = profile.autoCompactTokenLimit.map(String.init) ?? "不适用或未写明"
        let reasoning = profile.reasoningEnabled.map { $0 ? "开启" : "关闭" } ?? "未写明"
        let effort = profile.reasoningEffort?.rawValue ?? "未写明"
        let text = profile.supportsTextInput.map { $0 ? "支持" : "不支持" } ?? "未写明"
        let image = profile.supportsImageInput.map { $0 ? "支持" : "不支持" } ?? "未写明"
        return """
        上下文窗口：\(context)
        自动压缩阈值：\(compact)
        推理开关：\(reasoning)
        思考强度：\(effort)
        文本输入：\(text)
        图片输入：\(image)
        """
    }

    private static let preSwitchChecklist = """
    # 切换前检查

    - [ ] Codex Desktop 当前官方模式可以正常新建一次对话。
    - [ ] Codex++ 中原官方供应商仍存在，名称已记住。
    - [ ] 不删除 ChatGPT 官方登录，不清理 Keychain，不手改 `auth.json`。
    - [ ] 先只导入新供应商，不立即激活；核对名称、Base URL 和协议无误。
    - [ ] 明白激活纯 API 供应商会切换 Codex 的运行配置。
    """

    private static let relayChecklist = """
    # 中转模式验证

    - [ ] 在 Codex++ 中手动激活刚导入的中转供应商。
    - [ ] 使用供应商测试或 Provider Doctor 检查连接。
    - [ ] 在 Codex Desktop 新建临时对话，发送一条短文本。
    - [ ] 如需图片，再发送一张不含隐私的测试图。
    - [ ] 核对实际模型、上下文和思考强度，没有被工具写成其他值。
    - [ ] 任一步失败，停止继续修改，切回原官方供应商。
    """

    private static let officialChecklist = """
    # 切回官方验证

    - [ ] 在 Codex++ 选择切换前记下的原官方供应商。
    - [ ] 不删除、不重新粘贴官方登录信息。
    - [ ] 完全退出并重新打开 Codex Desktop。
    - [ ] 新建对话，确认官方账号仍为已登录状态。
    - [ ] 发送一条短文本并确认回复正常。
    - [ ] 若官方模式异常，不再反复切换，保留现场并查看 Codex++ 的切换备份记录。
    """
}

struct GuidanceOnlyAdapter: ConfigurationAdapter {
    let manager: AdapterTarget

    func generate(from draft: ConfigDraft, compatibility: CompatibilityRecord) throws -> GeneratedConfiguration {
        guard draft.agent == .codexDesktop else {
            throw ConfigurationGenerationError.incompatibleCombination(
                "\(AppReleaseMetadata.version) 首批只开放 Codex Desktop 指导闭环"
            )
        }
        let profile = CodexRelayProfile(
            id: draft.relayID,
            name: draft.providerName,
            baseURL: draft.baseURL,
            wireProtocol: draft.wireProtocol,
            models: draft.models,
            defaultModel: draft.model,
            contextWindow: draft.capabilities.contextWindow,
            autoCompactTokenLimit: draft.capabilities.autoCompactTokenLimit,
            reasoningEffort: draft.capabilities.reasoningEffort ?? .automatic
        )
        let plan = try PreservingTOMLEditor.plan(original: "", profile: profile)
        let text = """
        # Codex Desktop 手动配置指导

        配置位置：`$CODEX_HOME/config.toml`（默认 `~/.codex/config.toml`）

        ## 目标配置

        ```toml
        \(plan.manualBlock)
        ```

        ## 完成顺序

        1. 先在AI接入助手建立官方加密基线。
        2. 只修改助手列出的托管字段，保留MCP、权限、项目和其他设置。
        3. API Key不要写进TOML；由助手Keychain保存并在启动Codex时注入。
        4. 保存后回助手检查文件并执行模型接口和最小真实请求。
        5. 失败或需要官方额度时，点击“切回官方并重开Codex”。
        """
        let artifact = try AdapterArtifactFactory.markdown(name: "Codex-手动配置指导.md", text: text)
        return GeneratedConfiguration(
            manager: manager,
            artifacts: [artifact],
            instructions: "按页面逐步配置；助手检查、验证并提供恢复，不再只报风险。",
            safetySummary: "Key不写入配置；官方基线建立后才继续。"
        )
    }
}

enum SensitiveTextRedactor {
    static func redact(_ text: String) -> String {
        var output = text
        let fieldPattern = #"(?i)([\"']?(?:api[ _-]?key|token|authorization|secret|密钥|令牌|中转密钥)[\"']?\s*[:=：]\s*[\"']?)([^\s\"',，。;}\]]{6,})"#
        let tokenPattern = #"(?i)\b(?:sk[-_]|nb_|rk[-_]|pk[-_])[A-Za-z0-9_-]{6,}"#
        output = replace(fieldPattern, in: output, template: "$1<已遮盖>")
        output = replace(tokenPattern, in: output, template: "<已遮盖>")
        return output
    }

    private static func replace(_ pattern: String, in text: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
