import Foundation

enum PlatformEvidenceState: String {
    case verified = "源码已核验"
    case officialBoundary = "官方边界已核验"
    case blocked = "证据不足，已阻止"
}

enum PlatformEvidenceFreshness: String, Equatable {
    case current = "当前有效"
    case expired = "已过期"
    case unverified = "版本未锁定"
}

struct PlatformWriteSurface: Identifiable {
    let id: String
    let surface: String
    let timing: String
    let impact: String
}

struct PlatformAdapterEvidence: Identifiable {
    let recordVersion: Int
    let id: String
    let toolID: String
    let toolName: String
    let manager: AdapterTarget?
    let upstreamVersion: String
    let upstreamRevision: String?
    let state: PlatformEvidenceState
    let acceptedFields: [String]
    let writeSurfaces: [PlatformWriteSurface]
    let protectedSurfaces: [String]
    let restoreMethod: String
    let automationDecision: String
    let evidenceReference: String
    let verifiedAt: String?
    let expiresAt: String?

    func freshness(at now: Date = Date()) -> PlatformEvidenceFreshness {
        guard upstreamRevision != nil,
              verifiedAt.flatMap(PlatformEvidenceDate.parse) != nil,
              let expiry = expiresAt.flatMap(PlatformEvidenceDate.parse),
              let validThrough = Calendar(identifier: .gregorian).date(
                  byAdding: .day,
                  value: 1,
                  to: expiry
              ) else {
            return .unverified
        }
        return now < validThrough ? .current : .expired
    }

    func allowsAdapterUse(at now: Date = Date()) -> Bool {
        state == .verified && freshness(at: now) == .current
    }

    func statusText(at now: Date = Date()) -> String {
        "\(state.rawValue) · \(freshness(at: now).rawValue)"
    }
}

private enum PlatformEvidenceDate {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

enum PlatformEvidenceCatalog {
    static let records: [PlatformAdapterEvidence] = [
        PlatformAdapterEvidence(
            recordVersion: 1,
            id: "codexplusplus-285f40e",
            toolID: "codexplusplus",
            toolName: "Codex++",
            manager: .codexPlusPlus,
            upstreamVersion: "Codex++ 285f40e4d19b",
            upstreamRevision: "285f40e4d19b",
            state: .verified,
            acceptedFields: ["供应商名称", "Base URL", "API Key", "wireApi", "relayMode"],
            writeSurfaces: [
                PlatformWriteSurface(
                    id: "codexpp-import",
                    surface: "Codex++ 自己的供应商资料",
                    timing: "用户在 Codex++ 二次确认导入后",
                    impact: "新增供应商并设为当前供应商；仅打开导入文件不会写入"
                ),
                PlatformWriteSurface(
                    id: "codexpp-activate",
                    surface: "~/.codex/config.toml 与 ~/.codex/auth.json",
                    timing: "用户随后在 Codex++ 激活纯 API 供应商时",
                    impact: "会切换 Codex 运行配置；不是零影响操作"
                ),
            ],
            protectedSurfaces: ["ChatGPT 官方登录", "Keychain", "用户未确认的 Codex 配置"],
            restoreMethod: "在 Codex++ 切回原官方供应商，并按导出的清单验证官方会话；不要删除官方登录。",
            automationDecision: "只生成待确认导入文件和三段验证清单；不自动激活、不自动切回。",
            evidenceReference: "Codex++ provider_import.rs、relay_config.rs、relay_switch.rs；OpenAI Codex 配置参考",
            verifiedAt: "2026-07-18",
            expiresAt: "2026-08-17"
        ),
        PlatformAdapterEvidence(
            recordVersion: 1,
            id: "ccswitch-997be22",
            toolID: "cc-switch",
            toolName: "CC Switch",
            manager: .ccSwitch,
            upstreamVersion: "CC Switch 997be22bfa5d",
            upstreamRevision: "997be22bfa5d",
            state: .blocked,
            acceptedFields: ["app", "name", "endpoint", "apiKey", "model", "enabled"],
            writeSurfaces: [
                PlatformWriteSurface(
                    id: "ccswitch-import",
                    surface: "CC Switch 供应商数据库",
                    timing: "用户确认导入后",
                    impact: "新增供应商；enabled=true 还会立即切换"
                ),
            ],
            protectedSurfaces: ["~/.codex/config.toml", "~/.codex/auth.json", "用户思考强度"],
            restoreMethod: "未开放导出，因此无需恢复。",
            automationDecision: "阻止。当前 Codex 深链接生成器仍固定 model_reasoning_effort = high。",
            evidenceReference: "CC Switch deeplink/provider.rs 与 codexProviderPresets.ts",
            verifiedAt: "2026-07-18",
            expiresAt: "2026-08-17"
        ),
        PlatformAdapterEvidence(
            recordVersion: 1,
            id: "claude-code-router-unpinned-20260830",
            toolID: "claude-code-router",
            toolName: "Claude Code Router (CCR)",
            manager: nil,
            upstreamVersion: "版本未锁定",
            upstreamRevision: nil,
            state: .blocked,
            acceptedFields: [],
            writeSurfaces: [],
            protectedSurfaces: [
                "Codex与Claude配置",
                "OAuth与API凭据",
                "用户现有本地代理",
            ],
            restoreMethod: "未开放适配，因此无需恢复。",
            automationDecision: "只读显示外部网关边界；不在助手内建立代理、路由、fallback或OAuth生命周期。",
            evidenceReference: "2026-08-30项目级只读调研；尚未锁定可用于适配的tag或commit",
            verifiedAt: "2026-08-30",
            expiresAt: nil
        ),
        PlatformAdapterEvidence(
            recordVersion: 1,
            id: "cherrystudio-65e55c5",
            toolID: "cherry-studio",
            toolName: "Cherry Studio",
            manager: .cherryStudio,
            upstreamVersion: "Cherry Studio 65e55c5333eb",
            upstreamRevision: "65e55c5333eb",
            state: .verified,
            acceptedFields: ["id", "name", "baseUrl", "apiKey", "type"],
            writeSurfaces: [
                PlatformWriteSurface(
                    id: "cherry-prefill",
                    surface: "Cherry Studio 新增供应商设置页",
                    timing: "打开导入文件时",
                    impact: "只打开并预填表单，不直接保存"
                ),
            ],
            protectedSurfaces: ["Codex Desktop 配置", "Claude Desktop 登录", "Keychain"],
            restoreMethod: "未确认保存时直接关闭表单；保存后只在 Cherry Studio 内停用或移除该新增供应商。",
            automationDecision: "仅对 Cherry Studio 桌面端开放确认型导入；Codex Desktop、Claude Desktop 组合继续阻止。",
            evidenceReference: "Cherry Studio providersImport.ts 与 providersImport.test.ts",
            verifiedAt: "2026-07-18",
            expiresAt: "2026-08-17"
        ),
        PlatformAdapterEvidence(
            recordVersion: 1,
            id: "claude-desktop-official-20260718",
            toolID: "claude-desktop",
            toolName: "Claude Desktop",
            manager: .manual,
            upstreamVersion: "Claude Desktop 官方帮助中心 2026-07-18",
            upstreamRevision: "official-docs-20260718",
            state: .officialBoundary,
            acceptedFields: ["官方订阅登录", "MCP / Desktop Extensions"],
            writeSurfaces: [],
            protectedSurfaces: ["Claude Pro 登录", "Claude Desktop 数据目录", "Keychain"],
            restoreMethod: "未开放任意中转配置，因此无需恢复。",
            automationDecision: "阻止把 MCP 配置误当模型中转配置；没有官方证据时不生成 Base URL 或 API Key 配置。",
            evidenceReference: "support.claude.com：Installing Claude Desktop；Getting started with local MCP servers",
            verifiedAt: "2026-07-18",
            expiresAt: "2026-08-17"
        ),
    ]

    static var thirdPartyRecords: [PlatformAdapterEvidence] {
        records.filter { $0.toolID != "claude-desktop" }
    }

    static func record(for manager: AdapterTarget, agent: DesktopAgent? = nil) -> PlatformAdapterEvidence? {
        if manager == .manual, agent == .claudeDesktop {
            return records.first(where: { $0.toolID == "claude-desktop" })
        }
        if manager == .manual { return nil }
        return records.first(where: { $0.manager == manager })
    }
}

enum AdapterArtifactFactory {
    static func markdown(name: String, text: String) throws -> GeneratedArtifact {
        guard let data = text.data(using: .utf8) else {
            throw ConfigurationGenerationError.encodingFailed
        }
        return GeneratedArtifact(fileName: name, data: data, redactedPreview: text, containsSecret: false)
    }

    static func webLocation(name: String, url: URL, redactedURL: URL) throws -> GeneratedArtifact {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>URL</key><string>\(escaped)</string></dict></plist>
        """
        guard let data = contents.data(using: .utf8) else {
            throw ConfigurationGenerationError.encodingFailed
        }
        return GeneratedArtifact(
            fileName: name,
            data: data,
            redactedPreview: redactedURL.absoluteString,
            containsSecret: true
        )
    }
}

struct CherryStudioAdapter: ConfigurationAdapter {
    let manager = AdapterTarget.cherryStudio

    func generate(from draft: ConfigDraft, compatibility: CompatibilityRecord) throws -> GeneratedConfiguration {
        guard compatibility.level == .export, draft.agent == .cherryStudio else {
            throw ConfigurationGenerationError.incompatibleCombination(
                "Cherry Studio 导入只配置 Cherry Studio 自己，不能用来配置 Codex Desktop 或 Claude Desktop"
            )
        }
        guard !draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationGenerationError.missingProviderName
        }
        guard CodexPlusPlusAdapter.isAllowedBaseURL(draft.baseURL) else {
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

        let realURL = try importURL(from: draft, apiKey: draft.apiKey)
        let previewURL = try importURL(from: draft, apiKey: "<API_KEY 已遮盖>")
        let importFile = try AdapterArtifactFactory.webLocation(
            name: "Cherry-Studio-供应商导入.webloc",
            url: realURL,
            redactedURL: previewURL
        )
        let guide = try AdapterArtifactFactory.markdown(name: "Cherry-Studio-配置说明.md", text: """
        # Cherry Studio 配置说明

        1. 双击 `Cherry-Studio-供应商导入.webloc`。
        2. Cherry Studio 只会打开“新增供应商”页面并预填字段；请核对后再保存。
        3. 导入协议不包含模型、上下文和思考强度，请在保存后添加模型：\(draft.models.joined(separator: "、"))。
        4. 这不会配置 Codex Desktop 或 Claude Desktop，也不会修改它们的官方登录。
        5. 不想继续时直接关闭新增表单即可。
        """)
        return GeneratedConfiguration(
            manager: manager,
            artifacts: [importFile, guide],
            instructions: "导出后由 Cherry Studio 打开新增供应商表单；仍需你核对并保存。",
            safetySummary: "只生成桌面导入副本；不写 Codex、Claude、Keychain 或 Cherry Studio 数据库。"
        )
    }

    private func importURL(from draft: ConfigDraft, apiKey: String) throws -> URL {
        let type = draft.wireProtocol == .anthropicMessages ? "anthropic" : "openai"
        let identifier = "ai-access-" + draft.providerName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let payload: [String: String] = [
            "id": identifier,
            "name": draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            "baseUrl": CodexPlusPlusAdapter.cleanBaseURL(draft.baseURL),
            "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "type": type,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        var components = URLComponents()
        components.scheme = "cherrystudio"
        components.host = "providers"
        components.path = "/api-keys"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "data", value: encoded),
        ]
        guard let url = components.url else { throw ConfigurationGenerationError.invalidImportURL }
        return url
    }
}
