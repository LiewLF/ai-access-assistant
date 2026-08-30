import AppKit
import Foundation

struct RefreshedDocument {
    let sourceURL: URL
    let title: String
    let text: String
    let fetchedAt: Date
    let updatedAt: String?
    let wordCount: Int?
    let isSummaryOnly: Bool
    let extracted: ExtractedRelayConfiguration
}

enum DocumentRefreshError: LocalizedError {
    case invalidURL
    case insecureURL
    case badStatus(Int)
    case tooLarge
    case emptyContent
    case malformedPublicDocument

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "文档网址无效"
        case .insecureURL: return "只允许 HTTPS 文档网址"
        case let .badStatus(code): return "文档服务器返回 HTTP \(code)"
        case .tooLarge: return "文档超过 2 MB，已停止"
        case .emptyContent: return "未读取到可用文档内容"
        case .malformedPublicDocument: return "公开文档结构无法识别"
        }
    }
}

enum DocumentRefreshService {
    static func fetch(urlString: String) async throws -> RefreshedDocument {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DocumentRefreshError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw DocumentRefreshError.insecureURL
        }

        let (data, http) = try await request(url: url, accept: "text/html,text/plain,application/json")
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        var title = url.host ?? "中转文档"
        var updatedAt: String?
        var wordCount: Int?
        var text: String
        var summaryOnly = false

        if isYuqueURL(url), contentType.contains("text/html") {
            if let full = try await fetchYuquePublicContent(pageURL: url, pageData: data) {
                title = full.title
                updatedAt = full.updatedAt
                wordCount = full.wordCount
                text = full.text
            } else if let summary = extractYuqueMetadata(html: String(data: data, encoding: .utf8) ?? "") {
                title = summary.title
                updatedAt = summary.updatedAt
                wordCount = summary.wordCount
                text = summary.text
                summaryOnly = true
            } else {
                throw DocumentRefreshError.malformedPublicDocument
            }
        } else if contentType.contains("text/html") {
            text = htmlToText(String(data: data, encoding: .utf8) ?? "")
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }

        let redacted = SensitiveTextRedactor.redact(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { throw DocumentRefreshError.emptyContent }
        let extracted = DocumentConfigExtractor.extract(
            sourceURL: url,
            text: redacted,
            summaryOnly: summaryOnly
        )
        return RefreshedDocument(
            sourceURL: url,
            title: title,
            text: String(redacted.prefix(300_000)),
            fetchedAt: Date(),
            updatedAt: updatedAt,
            wordCount: wordCount,
            isSummaryOnly: summaryOnly,
            extracted: extracted
        )
    }

    private static func request(url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("AIConnectionAssistant/0.6", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await RelaySecureHTTPClient.data(
            for: request,
            source: .remoteDocument
        )
        guard let http = response as? HTTPURLResponse else { throw DocumentRefreshError.badStatus(0) }
        guard (200...299).contains(http.statusCode) else {
            throw DocumentRefreshError.badStatus(http.statusCode)
        }
        guard data.count <= 2_000_000 else { throw DocumentRefreshError.tooLarge }
        return (data, http)
    }

    private static func isYuqueURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "yuque.com" || host.hasSuffix(".yuque.com")
    }

    private struct YuqueContent {
        let title: String
        let updatedAt: String?
        let wordCount: Int?
        let text: String
    }

    private static func fetchYuquePublicContent(pageURL: URL, pageData: Data) async throws -> YuqueContent? {
        let html = String(data: pageData, encoding: .utf8) ?? ""
        guard let root = yuqueAppData(html: html),
              let book = root["book"] as? [String: Any],
              let doc = root["doc"] as? [String: Any],
              let bookID = (book["id"] as? NSNumber)?.intValue,
              let slug = doc["slug"] as? String else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = pageURL.host ?? "www.yuque.com"
        components.path = "/api/docs/\(slug)"
        components.queryItems = [URLQueryItem(name: "book_id", value: String(bookID))]
        guard let apiURL = components.url else { return nil }
        let (apiData, _) = try await request(url: apiURL, accept: "application/json")
        guard let json = try? JSONSerialization.jsonObject(with: apiData) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let content = data["content"] as? String else { return nil }
        let text = extractLakeText(content)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return YuqueContent(
            title: data["title"] as? String ?? doc["title"] as? String ?? "语雀文档",
            updatedAt: data["content_updated_at"] as? String ?? doc["content_updated_at"] as? String,
            wordCount: (data["word_count"] as? NSNumber)?.intValue ?? (doc["word_count"] as? NSNumber)?.intValue,
            text: text
        )
    }

    private static func yuqueAppData(html: String) -> [String: Any]? {
        let pattern = #"window\.appData\s*=\s*JSON\.parse\(decodeURIComponent\(\"([^\"]+)\"\)\)"#
        guard let encoded = firstCapture(pattern, in: html),
              let decoded = encoded.removingPercentEncoding,
              let data = decoded.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func extractYuqueMetadata(html: String) -> YuqueContent? {
        guard let root = yuqueAppData(html: html), let doc = root["doc"] as? [String: Any] else { return nil }
        let title = doc["title"] as? String ?? "语雀文档"
        let description = doc["description"] as? String ?? ""
        let updated = doc["content_updated_at"] as? String
        let words = (doc["word_count"] as? NSNumber)?.intValue
        return YuqueContent(
            title: title,
            updatedAt: updated,
            wordCount: words,
            text: "标题：\(title)\n摘要：\(description)\n说明：公开正文接口不可用，仅取得摘要。"
        )
    }

    private static func extractLakeText(_ lakeHTML: String) -> String {
        var codeBlocks: [String] = []
        let pattern = #"<card[^>]+name=\"codeblock\"[^>]+value=\"data:([^\"]+)\"[^>]*></card>"#
        if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(lakeHTML.startIndex..<lakeHTML.endIndex, in: lakeHTML)
            for match in expression.matches(in: lakeHTML, range: nsRange) {
                guard let range = Range(match.range(at: 1), in: lakeHTML) else { continue }
                let encoded = decodeHTMLEntities(String(lakeHTML[range]))
                guard let decoded = encoded.removingPercentEncoding,
                      let data = decoded.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let code = object["code"] as? String,
                      !code.isEmpty else { continue }
                codeBlocks.append(code)
            }
        }
        let prose = htmlToText(lakeHTML)
        return ([prose] + codeBlocks.map { "配置代码：\n\($0)" }).joined(separator: "\n\n")
    }

    private static func htmlToText(_ html: String) -> String {
        let withBreaks = html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</(?:p|h[1-6]|li|blockquote|div)>"#, with: "\n", options: .regularExpression)
        guard let data = withBreaks.data(using: .utf8) else { return "" }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        let text = (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string ?? ""
        return text
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum DocumentConfigExtractor {
    static func extract(
        sourceURL: URL,
        text: String,
        summaryOnly: Bool
    ) -> ExtractedRelayConfiguration {
        var result = ExtractedRelayConfiguration.empty
        let source = sourceURL.absoluteString
        if let preset = RelayCatalog.providers.first(where: { $0.documentationURL == source }) {
            result.providerName = preset.name
            result.evidence.append(FieldEvidence(field: "供应商", value: preset.name, source: source, status: .verified))
        } else if let provider = firstCapture(
            #"(?im)^\s*(?:供应商|中转站|provider(?: name)?)\s*[:=：]\s*[\"']?([^\n\"']{2,80})"#,
            in: text
        ) {
            let cleaned = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            result.providerName = cleaned
            result.evidence.append(FieldEvidence(field: "供应商", value: cleaned, source: source, status: .extracted))
        }

        if let base = firstCapture(
            #"(?i)(?:base[_ ]?url|接口地址|请求地址|url)\s*[:=：]\s*[\"']?(https://[^\s\"'<>]+)"#,
            in: text
        ) ?? firstCapture(#"(?i)(https://[a-z0-9.-]+(?::\d+)?/(?:api/)?v\d+)"#, in: text) {
            let cleaned = base.trimmingCharacters(in: CharacterSet(charactersIn: ".,，。;；)`]"))
            result.baseURL = cleaned
            result.evidence.append(FieldEvidence(field: "Base URL", value: cleaned, source: source, status: .extracted))
        }

        if text.range(of: #"(?i)wire_api\s*=\s*[\"']responses[\"']|responses\s*api|/responses\b"#, options: .regularExpression) != nil {
            result.protocols.append(.responses)
        }
        if text.range(of: #"(?i)wire_api\s*=\s*[\"']chat[\"']|chat\s*completions|/chat/completions\b"#, options: .regularExpression) != nil {
            result.protocols.append(.chatCompletions)
        }
        if text.range(of: #"(?i)anthropic\s*messages|/v1/messages\b"#, options: .regularExpression) != nil {
            result.protocols.append(.anthropicMessages)
        }
        result.protocols = unique(result.protocols)
        for item in result.protocols {
            result.evidence.append(FieldEvidence(field: "协议", value: item.rawValue, source: source, status: .extracted))
        }

        result.models = extractModels(text)
        for model in result.models {
            result.evidence.append(FieldEvidence(field: "模型", value: model, source: source, status: .extracted))
        }

        result.capabilities.contextWindow = integerValue(
            patterns: [
                #"(?i)model_context_window\s*=\s*([0-9_]+)"#,
                #"(?i)(?:context window|上下文(?:窗口)?)\s*[:=：]?\s*([0-9_]+)"#,
            ],
            text: text
        )
        result.capabilities.autoCompactTokenLimit = integerValue(
            patterns: [
                #"(?i)model_auto_compact_token_limit\s*=\s*([0-9_]+)"#,
                #"(?i)(?:自动压缩(?:阈值)?|auto compact(?: token limit)?)\s*[:=：]?\s*([0-9_]+)"#,
            ],
            text: text
        )
        if let effort = firstCapture(
            #"(?i)(?:model_reasoning_effort|思考强度|推理强度)\s*[:=：]\s*[\"']?(low|medium|high|xhigh|max|ultra|低|中|高|超高|最大|极限)[\"']?"#,
            in: text
        ) {
            result.capabilities.reasoningEffort = reasoningEffort(effort)
            result.capabilities.reasoningEnabled = true
        }
        if text.range(of: #"(?i)(?:reasoning|推理)(?:_enabled|开关)?\s*[:=：]\s*(?:true|on|开启|打开)"#, options: .regularExpression) != nil {
            result.capabilities.reasoningEnabled = true
        } else if text.range(of: #"(?i)(?:reasoning|推理)(?:_enabled|开关)?\s*[:=：]\s*(?:false|off|关闭)"#, options: .regularExpression) != nil {
            result.capabilities.reasoningEnabled = false
        }
        let explicitCapabilities = explicitCapabilityFields(in: text)
        result.capabilities.serviceTier = explicitCapabilities.serviceTiers.onlyValue
        result.capabilities.fastMode = explicitCapabilities.fastModes.onlyValue
        result.capabilities.webSearch = explicitCapabilities.webSearchValues.onlyValue
        result.capabilities.modelVerbosity = explicitCapabilities.modelVerbosityValues.onlyValue
        result.capabilities.disableResponseStorage =
            explicitCapabilities.responseStorageDisabledValues.onlyValue
        result.capabilities.upstreamName = explicitCapabilities.upstreamNames.onlyValue
        result.capabilities.supportsTextInput = explicitSupport(
            positive: #"(?i)(?:支持|support(?:s|ed)?)\s*(?:文本|text)(?:输入| input)?"#,
            negative: #"(?i)(?:不支持|does not support)\s*(?:文本|text)"#,
            text: text
        )
        result.capabilities.supportsImageInput = explicitSupport(
            positive: #"(?i)(?:支持|support(?:s|ed)?)\s*(?:图片|图像|image|vision)(?:输入| input)?"#,
            negative: #"(?i)(?:不支持|does not support)\s*(?:图片|图像|image|vision)"#,
            text: text
        )

        addCapabilityEvidence(&result, source: source)
        addExplicitCapabilityEvidence(
            &result,
            extraction: explicitCapabilities,
            source: source
        )
        result.warnings.append(contentsOf: explicitCapabilities.conflictWarnings)
        if summaryOnly { result.warnings.append("当前只取得摘要，不能自动带入摘要未写明的字段") }
        if result.baseURL == nil { result.warnings.append("未识别 Base URL") }
        if result.protocols.isEmpty { result.warnings.append("未识别协议") }
        if result.models.isEmpty { result.warnings.append("文档正文未识别到模型名；若模型只在图片中，需要手动选择") }
        return result
    }

    private static func extractModels(_ text: String) -> [String] {
        let patterns = [
            #"(?im)^\s*(?:model|模型(?:名称)?)\s*[:=：]\s*[\"']?([A-Za-z0-9][A-Za-z0-9._:/-]{2,80})"#,
            #"(?i)(?:支持模型|models?)\s*[:=：]\s*[\"']?((?:gpt|claude|gemini|deepseek)[A-Za-z0-9._:/-]{2,80})"#,
        ]
        var output: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,，。;；"))
                if !output.contains(value) { output.append(value) }
            }
        }
        if let list = firstCapture(#"(?im)^\s*(?:模型列表|支持模型)\s*[:=：]\s*(.+)$"#, in: text) {
            for value in list.split(whereSeparator: { ",，、;； \t".contains($0) }) {
                let candidate = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]()"))
                if candidate.count >= 3, candidate.range(of: #"(?i)^(gpt|claude|gemini|deepseek|o[0-9])"#, options: .regularExpression) != nil,
                   !output.contains(candidate) {
                    output.append(candidate)
                }
            }
        }
        return Array(output.prefix(50))
    }

    private static func integerValue(patterns: [String], text: String) -> Int? {
        for pattern in patterns {
            if let value = firstCapture(pattern, in: text),
               let number = Int(value.replacingOccurrences(of: "_", with: "")) { return number }
        }
        return nil
    }

    private static func explicitSupport(positive: String, negative: String, text: String) -> Bool? {
        if text.range(of: negative, options: .regularExpression) != nil { return false }
        if text.range(of: positive, options: .regularExpression) != nil { return true }
        return nil
    }

    private static func reasoningEffort(_ value: String) -> ReasoningEffort? {
        switch value.lowercased() {
        case "low", "低": return .low
        case "medium", "中": return .medium
        case "high", "高": return .high
        case "xhigh", "超高": return .xhigh
        case "max", "最大": return .max
        case "ultra", "极限": return .ultra
        default: return nil
        }
    }

    private static func addCapabilityEvidence(_ result: inout ExtractedRelayConfiguration, source: String) {
        if let value = result.capabilities.contextWindow {
            result.evidence.append(FieldEvidence(field: "上下文", value: String(value), source: source, status: .extracted))
        }
        if let value = result.capabilities.autoCompactTokenLimit {
            result.evidence.append(FieldEvidence(field: "自动压缩阈值", value: String(value), source: source, status: .extracted))
        }
        if let value = result.capabilities.reasoningEnabled {
            result.evidence.append(FieldEvidence(field: "推理开关", value: value ? "开启" : "关闭", source: source, status: .extracted))
        }
        if let value = result.capabilities.reasoningEffort {
            result.evidence.append(FieldEvidence(field: "思考强度", value: value.rawValue, source: source, status: .extracted))
        }
        if let value = result.capabilities.supportsTextInput {
            result.evidence.append(FieldEvidence(field: "文本输入", value: value ? "支持" : "不支持", source: source, status: .extracted))
        }
        if let value = result.capabilities.supportsImageInput {
            result.evidence.append(FieldEvidence(field: "图片输入", value: value ? "支持" : "不支持", source: source, status: .extracted))
        }
    }

    private struct ExplicitCapabilityExtraction {
        var serviceTiers: [String] = []
        var fastModes: [Bool] = []
        var webSearchValues: [String] = []
        var modelVerbosityValues: [String] = []
        var responseStorageDisabledValues: [Bool] = []
        var upstreamNames: [String] = []

        var conflictWarnings: [String] {
            [
                serviceTiers.count > 1 ? "资料内存在多个速度档值" : nil,
                fastModes.count > 1 ? "资料内存在多个 Fast 开关值" : nil,
                webSearchValues.count > 1 ? "资料内存在多个 Web Search 值" : nil,
                modelVerbosityValues.count > 1 ? "资料内存在多个回答详略值" : nil,
                responseStorageDisabledValues.count > 1
                    ? "资料内存在多个禁用响应存储值" : nil,
                upstreamNames.count > 1 ? "资料内存在多个 Provider 兼容名称" : nil,
            ].compactMap { $0 }
        }
    }

    private enum CapabilityTOMLTable {
        case root
        case features
        case provider
        case other
    }

    private struct CapabilityTOMLAssignment {
        let key: String
        let value: String
    }

    private static func explicitCapabilityFields(
        in text: String
    ) -> ExplicitCapabilityExtraction {
        var output = ExplicitCapabilityExtraction()
        var table: CapabilityTOMLTable = .root
        let headerExpression = try? NSRegularExpression(
            pattern: #"^\s*\[([^\[\]]+)\]\s*(?:#.*)?$"#
        )
        let assignmentExpression = try? NSRegularExpression(
            pattern: #"^\s*([A-Za-z0-9_.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s#]+))\s*(?:#.*)?$"#
        )

        for rawLine in text.components(separatedBy: .newlines) {
            if let header = capture(
                expression: headerExpression,
                group: 1,
                in: rawLine
            ) {
                table = capabilityTable(header: header)
                continue
            }
            guard let assignment = capabilityAssignment(
                line: rawLine,
                expression: assignmentExpression
            ) else { continue }
            let key = assignment.key.lowercased()
            switch (table, key) {
            case (.root, "service_tier"):
                if let value = normalizedServiceTier(assignment.value) {
                    appendUnique(value, to: &output.serviceTiers)
                }
            case (.root, "web_search"):
                if let value = normalizedWhitelistValue(
                    assignment.value,
                    allowed: ["disabled", "cached", "live"]
                ) {
                    appendUnique(value, to: &output.webSearchValues)
                }
            case (.root, "model_verbosity"):
                if let value = normalizedWhitelistValue(
                    assignment.value,
                    allowed: ["low", "medium", "high"]
                ) {
                    appendUnique(value, to: &output.modelVerbosityValues)
                }
            case (.root, "disable_response_storage"):
                if let value = normalizedBoolean(assignment.value) {
                    appendUnique(
                        value,
                        to: &output.responseStorageDisabledValues
                    )
                }
            case (.root, "features.fast_mode"),
                 (.features, "fast_mode"):
                if let value = normalizedBoolean(assignment.value) {
                    appendUnique(value, to: &output.fastModes)
                }
            case (.provider, "name"):
                if let value = normalizedProviderName(assignment.value) {
                    appendUnique(value, to: &output.upstreamNames)
                }
            default:
                break
            }
        }

        if output.serviceTiers.isEmpty,
           let value = firstCapture(
            #"(?im)^\s*(?:service\s*tier|速度档)\s*[:=：]\s*[\"']?([A-Za-z0-9._-]+)"#,
            in: text
           ).flatMap(normalizedServiceTier) {
            output.serviceTiers = [value]
        }
        if output.fastModes.isEmpty,
           let value = firstCapture(
            #"(?im)^\s*(?:fast\s*(?:mode|开关)|Fast开关)\s*[:=：]\s*[\"']?([^\s\"'#，。;；]+)"#,
            in: text
           ).flatMap(normalizedBoolean) {
            output.fastModes = [value]
        }
        if output.webSearchValues.isEmpty,
           let value = firstCapture(
            #"(?im)^\s*web\s*search\s*[:=：]\s*[\"']?([A-Za-z0-9_-]+)"#,
            in: text
           ).flatMap({
               normalizedWhitelistValue(
                   $0,
                   allowed: ["disabled", "cached", "live"]
               )
           }) {
            output.webSearchValues = [value]
        }
        if output.modelVerbosityValues.isEmpty,
           let value = firstCapture(
            #"(?im)^\s*(?:回答详略|model\s*verbosity)\s*[:=：]\s*[\"']?([A-Za-z0-9_-]+)"#,
            in: text
           ).flatMap({
               normalizedWhitelistValue(
                   $0,
                   allowed: ["low", "medium", "high"]
               )
           }) {
            output.modelVerbosityValues = [value]
        }
        if output.responseStorageDisabledValues.isEmpty,
           let value = firstCapture(
            #"(?im)^\s*(?:禁用响应存储|disable\s*response\s*storage)\s*[:=：]\s*[\"']?([^\s\"'#，。;；]+)"#,
            in: text
           ).flatMap(normalizedBoolean) {
            output.responseStorageDisabledValues = [value]
        }
        return output
    }

    private static func capabilityTable(
        header: String
    ) -> CapabilityTOMLTable {
        let normalized = header.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        if normalized == "features" { return .features }
        if normalized.range(
            of: #"^model_providers\.(?:\"[^\"]+\"|'[^']+'|[a-z0-9_-]+)$"#,
            options: .regularExpression
        ) != nil {
            return .provider
        }
        return .other
    }

    private static func capabilityAssignment(
        line: String,
        expression: NSRegularExpression?
    ) -> CapabilityTOMLAssignment? {
        guard let expression,
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let keyRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            guard let valueRange = Range(match.range(at: group), in: line) else {
                continue
            }
            return CapabilityTOMLAssignment(
                key: String(line[keyRange]),
                value: String(line[valueRange])
            )
        }
        return nil
    }

    private static func capture(
        expression: NSRegularExpression?,
        group: Int,
        in text: String
    ) -> String? {
        guard let expression,
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func normalizedServiceTier(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast", "priority": return "fast"
        case "standard": return "standard"
        case "flex": return "flex"
        case "default": return "default"
        case "auto": return "auto"
        default: return nil
        }
    }

    private static func normalizedWhitelistValue(
        _ value: String,
        allowed: Set<String>
    ) -> String? {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return allowed.contains(normalized) ? normalized : nil
    }

    private static func normalizedBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "on", "enabled", "yes", "1", "开启", "打开":
            return true
        case "false", "off", "disabled", "no", "0", "关闭":
            return false
        default:
            return nil
        }
    }

    private static func normalizedProviderName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 128,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return normalized
    }

    private static func addExplicitCapabilityEvidence(
        _ result: inout ExtractedRelayConfiguration,
        extraction: ExplicitCapabilityExtraction,
        source: String
    ) {
        for value in extraction.serviceTiers {
            result.evidence.append(FieldEvidence(
                field: "速度档", value: value, source: source,
                status: .extracted
            ))
        }
        for value in extraction.fastModes {
            result.evidence.append(FieldEvidence(
                field: "Fast开关", value: value ? "开启" : "关闭",
                source: source, status: .extracted
            ))
        }
        for value in extraction.webSearchValues {
            result.evidence.append(FieldEvidence(
                field: "Web Search", value: value, source: source,
                status: .extracted
            ))
        }
        for value in extraction.modelVerbosityValues {
            result.evidence.append(FieldEvidence(
                field: "回答详略", value: value, source: source,
                status: .extracted
            ))
        }
        for value in extraction.responseStorageDisabledValues {
            result.evidence.append(FieldEvidence(
                field: "禁用响应存储", value: value ? "开启" : "关闭",
                source: source, status: .extracted
            ))
        }
        for value in extraction.upstreamNames {
            result.evidence.append(FieldEvidence(
                field: "Provider兼容名称", value: value, source: source,
                status: .extracted
            ))
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func appendUnique<T: Equatable>(
        _ value: T,
        to values: inout [T]
    ) {
        if !values.contains(value) { values.append(value) }
    }
}

private extension Array where Element: Equatable {
    var onlyValue: Element? {
        count == 1 ? first : nil
    }
}
