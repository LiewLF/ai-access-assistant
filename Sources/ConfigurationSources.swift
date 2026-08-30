import Foundation

enum ConfigurationSourceKind: String, CaseIterable, Identifiable, Codable {
    case remoteDocument = "远程文档"
    case pastedText = "粘贴文字"
    case relayScreenshot = "中转资料截图"
    case currentSettingsScreenshot = "当前设置截图"
    case verifiedPreset = "已核验预设"
    case userConfirmed = "用户确认"

    var id: String { rawValue }

    var priority: Int {
        switch self {
        case .userConfirmed: return 100
        case .verifiedPreset: return 90
        case .remoteDocument: return 85
        case .pastedText: return 80
        case .relayScreenshot, .currentSettingsScreenshot: return 75
        }
    }
}

enum ScreenshotConfigurationKind: String, Codable {
    case relayInstructions = "中转配置资料"
    case currentSettings = "配置工具当前设置"
    case unknown = "无法判断"
}

struct ConfigurationSourceRecord: Identifiable, Equatable {
    let id: UUID
    var kind: ConfigurationSourceKind
    var title: String
    var sanitizedText: String
    var location: String
    var screenshotKind: ScreenshotConfigurationKind?
    var containsSensitiveText: Bool

    init(
        id: UUID = UUID(),
        kind: ConfigurationSourceKind,
        title: String,
        sanitizedText: String,
        location: String,
        screenshotKind: ScreenshotConfigurationKind? = nil,
        containsSensitiveText: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sanitizedText = sanitizedText
        self.location = location
        self.screenshotKind = screenshotKind
        self.containsSensitiveText = containsSensitiveText
    }
}

struct ConfigurationFieldCandidate: Identifiable, Equatable {
    let id: String
    let field: String
    let value: String
    let sourceID: UUID
    let sourceTitle: String
    let sourceKind: ConfigurationSourceKind
    let confidence: Int
    let evidenceLocation: String
}

struct ConfigurationFieldConflict: Identifiable, Equatable {
    var id: String { field }
    let field: String
    let candidates: [ConfigurationFieldCandidate]
}

struct UnifiedConfigurationResult: Equatable {
    let extracted: ExtractedRelayConfiguration
    let candidates: [ConfigurationFieldCandidate]
    let conflicts: [ConfigurationFieldConflict]
    let warnings: [String]

    var blocksConfiguration: Bool { !conflicts.isEmpty }
}

enum ConfigurationSourceEngine {
    static let scalarFields: Set<String> = [
        "供应商", "Base URL", "上下文", "自动压缩阈值", "推理开关", "思考强度", "文本输入", "图片输入",
        "速度档", "Fast开关", "Web Search", "回答详略", "禁用响应存储", "Provider兼容名称",
    ]

    static func classifyScreenshot(text: String) -> ScreenshotConfigurationKind {
        let value = text.lowercased()
        let relayScore = [
            "base url", "接口地址", "请求地址", "api key", "responses api", "chat completions",
            "模型名称", "上下文", "model_context_window", "model_reasoning_effort",
            "service_tier", "fast_mode", "web_search", "model_verbosity", "disable_response_storage",
        ].reduce(0) { $0 + (value.contains($1.lowercased()) ? 1 : 0) }
        let settingsScore = [
            "供应商配置", "codex++", "cc switch", "启用", "保存", "设置", "当前供应商", "模型列表",
        ].reduce(0) { $0 + (value.contains($1.lowercased()) ? 1 : 0) }
        if relayScore >= 2, relayScore > settingsScore { return .relayInstructions }
        if settingsScore >= 2 { return .currentSettings }
        return .unknown
    }

    static func sanitizedSource(
        kind: ConfigurationSourceKind,
        title: String,
        text: String,
        location: String
    ) -> ConfigurationSourceRecord {
        let containsSensitive = containsSensitiveValue(text)
        let sanitized = SensitiveTextRedactor.redact(text)
        let screenshotKind: ScreenshotConfigurationKind? = switch kind {
        case .relayScreenshot, .currentSettingsScreenshot: classifyScreenshot(text: sanitized)
        default: nil
        }
        return ConfigurationSourceRecord(
            kind: kind,
            title: title,
            sanitizedText: sanitized,
            location: location,
            screenshotKind: screenshotKind,
            containsSensitiveText: containsSensitive
        )
    }

    static func recognizeScreenshots(urls: [URL]) async throws -> [ConfigurationSourceRecord] {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var seenTexts = Set<String>()
        var output: [ConfigurationSourceRecord] = []
        for url in sorted {
            let text = try await Task.detached(priority: .userInitiated) {
                try ScreenshotOCR.recognize(url: url)
            }.value
            let sanitized = SensitiveTextRedactor.redact(text)
            let fingerprint = normalizedFingerprint(sanitized)
            guard !fingerprint.isEmpty, seenTexts.insert(fingerprint).inserted else { continue }
            let detected = classifyScreenshot(text: sanitized)
            let kind: ConfigurationSourceKind = detected == .currentSettings
                ? .currentSettingsScreenshot
                : .relayScreenshot
            output.append(sanitizedSource(
                kind: kind,
                title: url.lastPathComponent,
                text: text,
                location: "截图 \(output.count + 1) · \(url.lastPathComponent)"
            ))
        }
        return output
    }

    static func merge(
        _ sources: [ConfigurationSourceRecord],
        resolutions: [String: String] = [:]
    ) -> UnifiedConfigurationResult {
        var candidates: [ConfigurationFieldCandidate] = []
        var warnings: [String] = []
        var sourceExtractions: [(ConfigurationSourceRecord, ExtractedRelayConfiguration)] = []

        for source in sources {
            let url = sourceURL(for: source)
            let extraction = DocumentConfigExtractor.extract(
                sourceURL: url,
                text: source.sanitizedText,
                summaryOnly: false
            )
            sourceExtractions.append((source, extraction))
            for evidence in extraction.evidence {
                candidates.append(ConfigurationFieldCandidate(
                    id: "\(source.id.uuidString)-\(evidence.field)-\(evidence.value)",
                    field: evidence.field,
                    value: evidence.value,
                    sourceID: source.id,
                    sourceTitle: source.title,
                    sourceKind: source.kind,
                    confidence: source.kind.priority,
                    evidenceLocation: source.location
                ))
            }
            if source.containsSensitiveText {
                warnings.append("\(source.title) 检测到疑似 API Key 或 Token；已遮挡，不会自动带入")
            }
            if source.screenshotKind == .unknown {
                warnings.append("\(source.title) 无法判断截图类型，请人工确认")
            }
        }

        candidates = deduplicateCandidates(candidates)
        for (field, value) in resolutions {
            candidates.append(ConfigurationFieldCandidate(
                id: "user-confirmed-\(field)-\(value)",
                field: field,
                value: value,
                sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                sourceTitle: "用户确认",
                sourceKind: .userConfirmed,
                confidence: 100,
                evidenceLocation: "冲突选择"
            ))
        }
        let grouped = Dictionary(grouping: candidates, by: \.field)
        let conflicts = scalarFields.compactMap { field -> ConfigurationFieldConflict? in
            if resolutions[field] != nil { return nil }
            let values = grouped[field] ?? []
            let uniqueValues = Set(values.map { normalizedValue($0.value) })
            return uniqueValues.count > 1
                ? ConfigurationFieldConflict(field: field, candidates: values.sorted { $0.confidence > $1.confidence })
                : nil
        }.sorted { $0.field < $1.field }

        var result = ExtractedRelayConfiguration.empty
        result.providerName = resolutions["供应商"] ?? unconflictedValue("供应商", grouped: grouped, conflicts: conflicts)
        result.baseURL = resolutions["Base URL"] ?? unconflictedValue("Base URL", grouped: grouped, conflicts: conflicts)
        result.protocols = unique(sourceExtractions.flatMap { $0.1.protocols })
        result.models = unique(sourceExtractions.flatMap { $0.1.models })
        result.capabilities.contextWindow = integerField("上下文", grouped: grouped, conflicts: conflicts)
        result.capabilities.autoCompactTokenLimit = integerField("自动压缩阈值", grouped: grouped, conflicts: conflicts)
        result.capabilities.reasoningEnabled = booleanField("推理开关", grouped: grouped, conflicts: conflicts, trueValue: "开启")
        result.capabilities.reasoningEffort = effortField(grouped: grouped, conflicts: conflicts)
        result.capabilities.supportsTextInput = booleanField("文本输入", grouped: grouped, conflicts: conflicts, trueValue: "支持")
        result.capabilities.supportsImageInput = booleanField("图片输入", grouped: grouped, conflicts: conflicts, trueValue: "支持")
        result.capabilities.serviceTier = unconflictedValue("速度档", grouped: grouped, conflicts: conflicts)
        result.capabilities.fastMode = booleanField("Fast开关", grouped: grouped, conflicts: conflicts, trueValue: "开启")
        result.capabilities.webSearch = unconflictedValue("Web Search", grouped: grouped, conflicts: conflicts)
        result.capabilities.modelVerbosity = unconflictedValue("回答详略", grouped: grouped, conflicts: conflicts)
        result.capabilities.disableResponseStorage = booleanField("禁用响应存储", grouped: grouped, conflicts: conflicts, trueValue: "开启")
        result.capabilities.upstreamName = unconflictedValue("Provider兼容名称", grouped: grouped, conflicts: conflicts)
        result.evidence = candidates.map {
            FieldEvidence(field: $0.field, value: $0.value, source: "\($0.sourceTitle) · \($0.evidenceLocation)", status: .extracted)
        }
        if result.baseURL == nil { warnings.append("未识别 Base URL") }
        if result.protocols.isEmpty { warnings.append("未识别协议") }
        if result.models.isEmpty { warnings.append("未识别模型") }
        if !conflicts.isEmpty { warnings.append("存在字段冲突；选择正确值后才能继续") }
        result.warnings = unique(warnings)
        return UnifiedConfigurationResult(
            extracted: result,
            candidates: candidates,
            conflicts: conflicts,
            warnings: unique(warnings)
        )
    }

    private static func sourceURL(for source: ConfigurationSourceRecord) -> URL {
        if source.kind == .remoteDocument, let url = URL(string: source.location) { return url }
        return URL(string: "https://local.ai-access.invalid/source/\(source.id.uuidString)")!
    }

    private static func unconflictedValue(
        _ field: String,
        grouped: [String: [ConfigurationFieldCandidate]],
        conflicts: [ConfigurationFieldConflict]
    ) -> String? {
        guard !conflicts.contains(where: { $0.field == field }) else { return nil }
        return grouped[field]?.max(by: { $0.confidence < $1.confidence })?.value
    }

    private static func integerField(
        _ field: String,
        grouped: [String: [ConfigurationFieldCandidate]],
        conflicts: [ConfigurationFieldConflict]
    ) -> Int? {
        unconflictedValue(field, grouped: grouped, conflicts: conflicts)
            .flatMap { Int($0.replacingOccurrences(of: "_", with: "")) }
    }

    private static func booleanField(
        _ field: String,
        grouped: [String: [ConfigurationFieldCandidate]],
        conflicts: [ConfigurationFieldConflict],
        trueValue: String
    ) -> Bool? {
        unconflictedValue(field, grouped: grouped, conflicts: conflicts).map { $0 == trueValue }
    }

    private static func effortField(
        grouped: [String: [ConfigurationFieldCandidate]],
        conflicts: [ConfigurationFieldConflict]
    ) -> ReasoningEffort? {
        guard let value = unconflictedValue("思考强度", grouped: grouped, conflicts: conflicts) else { return nil }
        return ReasoningEffort.allCases.first(where: { $0.rawValue == value })
    }

    private static func containsSensitiveValue(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:sk[-_]|rk[-_]|pk[-_])[A-Za-z0-9_-]{6,}"#,
            #"(?i)(?:api[_ -]?key|token|authorization|密钥|令牌)\s*[:=：]\s*\S{6,}"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func normalizedFingerprint(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func normalizedValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func deduplicateCandidates(_ values: [ConfigurationFieldCandidate]) -> [ConfigurationFieldCandidate] {
        var seen = Set<String>()
        return values.filter {
            seen.insert("\($0.field)|\(normalizedValue($0.value))|\($0.sourceID.uuidString)").inserted
        }
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
