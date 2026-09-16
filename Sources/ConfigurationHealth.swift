import CryptoKit
import Foundation

enum ConfigurationHealthCategory: String, Codable, CaseIterable {
    case safety = "安全字段"
    case frequent = "常用字段"
    case cost = "成本参数"
    case structure = "结构完整"
    case runtime = "运行能力"
    case capabilities = "扩展能力"
}

enum ConfigurationHealthState: String, Codable {
    case passed = "通过"
    case warning = "需核对"
    case blocked = "阻止"
    case unverified = "未验证"
    case notEnabled = "未启用"
}

struct ConfigurationHealthItem: Identifiable, Codable, Equatable {
    let id: String
    let category: ConfigurationHealthCategory
    let title: String
    let state: ConfigurationHealthState
    let detail: String
}

struct ConfigurationHealthReport: Codable, Equatable {
    let generatedAt: Date
    let semanticHash: String?
    let catalogContext: Build65CatalogResolutionContext?
    let items: [ConfigurationHealthItem]

    init(
        generatedAt: Date,
        semanticHash: String?,
        catalogContext: Build65CatalogResolutionContext? = nil,
        items: [ConfigurationHealthItem]
    ) {
        self.generatedAt = generatedAt
        self.semanticHash = semanticHash
        self.catalogContext = catalogContext
        self.items = items
    }

    var hasBlocker: Bool { items.contains { $0.state == .blocked } }

    var capabilitySummary: ConfigurationCapabilitySummary {
        ConfigurationCapabilitySummary.make(from: items)
    }
}

enum ConfigurationCapabilityVerdict:
    String, Codable, Equatable, Sendable {
    case consistent = "一致"
    case different = "有差异"
    case unverified = "未验证"
}

struct ConfigurationCapabilitySummary:
    Codable, Equatable, Sendable {
    let verdict: ConfigurationCapabilityVerdict
    let available: [ConfigurationHealthItem]
    let differences: [ConfigurationHealthItem]
    let unverified: [ConfigurationHealthItem]

    private static let parityTitles: Set<String> = [
        "核心接入闸门",
        "受管模型目录",
        "协议",
        "Fast请求",
        "Web Search（Responses）",
        "Web Search（Standalone）",
        "Web Search（MCP）",
        "来源引用",
        "远程在线压缩",
        "图片输入（Provider）",
    ]

    static func make(
        from items: [ConfigurationHealthItem]
    ) -> ConfigurationCapabilitySummary {
        let parityItems = items.filter {
            parityTitles.contains($0.title)
        }
        let available = parityItems.filter {
            $0.state == .passed
        }
        let differences = parityItems.filter {
            $0.state == .warning || $0.state == .blocked
        }
        let unverified = parityItems.filter {
            $0.state == .unverified
        }
        let verdict: ConfigurationCapabilityVerdict
        if !differences.isEmpty {
            verdict = .different
        } else if parityItems.isEmpty || !unverified.isEmpty {
            verdict = .unverified
        } else {
            verdict = .consistent
        }
        return ConfigurationCapabilitySummary(
            verdict: verdict,
            available: available,
            differences: differences,
            unverified: unverified
        )
    }
}

struct ConfigurationCapabilityEvidence: Codable, Equatable {
    let skillManifestPaths: [String]
    let pluginManifestPaths: [String]
    let configuredMCPServerIDs: [String]
    let probeReceipts: [CapabilityProbeReceipt]
    let providerProbeReceipts: [ProviderCapabilityProbeReceipt]

    init(
        skillManifestPaths: [String],
        pluginManifestPaths: [String],
        configuredMCPServerIDs: [String],
        probeReceipts: [CapabilityProbeReceipt],
        providerProbeReceipts:
            [ProviderCapabilityProbeReceipt] = []
    ) {
        self.skillManifestPaths = skillManifestPaths
        self.pluginManifestPaths = pluginManifestPaths
        self.configuredMCPServerIDs = configuredMCPServerIDs
        self.probeReceipts = probeReceipts
        self.providerProbeReceipts = providerProbeReceipts
    }

    private enum CodingKeys: String, CodingKey {
        case skillManifestPaths
        case pluginManifestPaths
        case configuredMCPServerIDs
        case probeReceipts
        case providerProbeReceipts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        skillManifestPaths = try container.decode(
            [String].self,
            forKey: .skillManifestPaths
        )
        pluginManifestPaths = try container.decode(
            [String].self,
            forKey: .pluginManifestPaths
        )
        configuredMCPServerIDs = try container.decode(
            [String].self,
            forKey: .configuredMCPServerIDs
        )
        probeReceipts = try container.decode(
            [CapabilityProbeReceipt].self,
            forKey: .probeReceipts
        )
        providerProbeReceipts = try container.decodeIfPresent(
            [ProviderCapabilityProbeReceipt].self,
            forKey: .providerProbeReceipts
        ) ?? []
    }
}

enum CapabilityProbeKind: String, Codable, CaseIterable {
    case mcpConnection
    case toolEnumeration
    case imageInput
    case protocolRequest
}

enum CapabilityProbeStatus: String, Codable {
    case passed
    case failed
}

enum CapabilityProbeSource: String, Codable {
    case agentPublicRuntime
    case providerMinimalRequest
}

struct CapabilityProbeReceipt: Codable, Equatable {
    let id: String
    let kind: CapabilityProbeKind
    let status: CapabilityProbeStatus
    let source: CapabilityProbeSource
    let agentBundleIdentifier: String
    let agentVersion: String
    let processIdentifier: Int32?
    let transactionID: String?
    let observedAt: Date
    let evidenceSHA256: String
}

enum CapabilityProbeReceiptError: LocalizedError {
    case invalidAgentIdentity
    case missingRuntimeProcess
    case missingProviderTransaction
    case invalidEvidence

    var errorDescription: String? {
        switch self {
        case .invalidAgentIdentity:
            return "能力探针缺少Agent标识或版本"
        case .missingRuntimeProcess:
            return "Agent运行时探针缺少进程证据"
        case .missingProviderTransaction:
            return "Provider请求探针缺少事务证据"
        case .invalidEvidence:
            return "能力探针没有可哈希的结果摘要"
        }
    }
}

enum CapabilityProbeReceiptFactory {
    static func issue(
        kind: CapabilityProbeKind,
        status: CapabilityProbeStatus,
        source: CapabilityProbeSource,
        agentBundleIdentifier: String,
        agentVersion: String,
        processIdentifier: Int32?,
        transactionID: String?,
        observedAt: Date,
        evidenceComponents: [String]
    ) throws -> CapabilityProbeReceipt {
        let bundle = agentBundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let version = agentVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !bundle.isEmpty, !version.isEmpty else {
            throw CapabilityProbeReceiptError
                .invalidAgentIdentity
        }
        switch source {
        case .agentPublicRuntime:
            guard let processIdentifier,
                  processIdentifier > 0 else {
                throw CapabilityProbeReceiptError
                    .missingRuntimeProcess
            }
        case .providerMinimalRequest:
            guard transactionID?.isEmpty == false else {
                throw CapabilityProbeReceiptError
                    .missingProviderTransaction
            }
        }
        let components = evidenceComponents.filter {
            !$0.isEmpty
        }
        guard !components.isEmpty else {
            throw CapabilityProbeReceiptError.invalidEvidence
        }
        let canonical = (
            [
                kind.rawValue,
                status.rawValue,
                source.rawValue,
                bundle,
                version,
                processIdentifier.map(String.init) ?? "",
                transactionID ?? "",
                ISO8601DateFormatter().string(from: observedAt),
            ] + components
        ).joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(canonical.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return CapabilityProbeReceipt(
            id: UUID().uuidString,
            kind: kind,
            status: status,
            source: source,
            agentBundleIdentifier: bundle,
            agentVersion: version,
            processIdentifier: processIdentifier,
            transactionID: transactionID,
            observedAt: observedAt,
            evidenceSHA256: digest
        )
    }
}

enum CapabilityProbeEvidenceGate {
    static func result(
        kind: CapabilityProbeKind,
        receipts: [CapabilityProbeReceipt],
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400,
        expectedAgentBundleIdentifier: String? = nil,
        expectedAgentVersion: String? = nil
    ) -> Bool? {
        let valid = receipts.filter { receipt in
            guard receipt.kind == kind,
                  receipt.observedAt <= now,
                  now.timeIntervalSince(receipt.observedAt)
                    <= maximumAge,
                  validSHA256(receipt.evidenceSHA256),
                  !receipt.agentBundleIdentifier.isEmpty,
                  !receipt.agentVersion.isEmpty else {
                return false
            }
            if let expectedAgentBundleIdentifier,
               receipt.agentBundleIdentifier
                != expectedAgentBundleIdentifier {
                return false
            }
            if let expectedAgentVersion,
               receipt.agentVersion != expectedAgentVersion {
                return false
            }
            switch receipt.source {
            case .agentPublicRuntime:
                return receipt.processIdentifier.map {
                    $0 > 0
                } == true
            case .providerMinimalRequest:
                return receipt.transactionID?.isEmpty == false
            }
        }
        guard let latest = valid.max(by: {
            $0.observedAt < $1.observedAt
        }) else {
            return nil
        }
        return latest.status == .passed
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum ConfigurationCapabilityInspector {
    static func inspect(
        codexHome: URL,
        configText: String,
        skillsRoot: URL? = nil,
        probeReceipts: [CapabilityProbeReceipt] = [],
        providerProbeReceipts:
            [ProviderCapabilityProbeReceipt] = [],
        maximumEntries: Int = 2_000
    ) -> ConfigurationCapabilityEvidence {
        let document = try? TOMLSemanticEngine.parse(
            TOMLSensitiveValueRedactor.redact(configText)
        )
        let mcpIDs = Set(document?.leaves.keys.compactMap { path -> String? in
            let components = TOMLSemanticEngine.decodePath(path)
            guard components.count >= 2, components[0] == "mcp_servers" else { return nil }
            guard components[1] != "<empty-table>",
                  components[1] != "<empty-array>" else {
                return nil
            }
            return components[1]
        } ?? []).sorted()
        let resolvedSkillsRoot = skillsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".agents",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "skills",
                    isDirectory: true
                )
        let skills = boundedManifestPaths(
            root: resolvedSkillsRoot,
            acceptedNames: ["SKILL.md"],
            maximumEntries: maximumEntries
        )
        let plugins = boundedManifestPaths(
            root: codexHome.appendingPathComponent("plugins", isDirectory: true),
            acceptedNames: ["plugin.json"],
            maximumEntries: maximumEntries,
            includeHiddenEntries: true
        )
        return ConfigurationCapabilityEvidence(
            skillManifestPaths: skills,
            pluginManifestPaths: plugins,
            configuredMCPServerIDs: mcpIDs,
            probeReceipts: probeReceipts,
            providerProbeReceipts:
                providerProbeReceipts
        )
    }

    private static func boundedManifestPaths(
        root: URL,
        acceptedNames: Set<String>,
        maximumEntries: Int,
        includeHiddenEntries: Bool = false
    ) -> [String] {
        guard maximumEntries > 0 else { return [] }
        let canonicalRoot = root
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalPrefix = canonicalRoot.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: includeHiddenEntries
                ? [] : [.skipsHiddenFiles]
        ) else { return [] }
        var result: [String] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maximumEntries { break }
            guard let values = try? url.resourceValues(
                     forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard acceptedNames.contains(url.lastPathComponent),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let canonicalURL = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard canonicalURL.path.hasPrefix(canonicalPrefix) else {
                continue
            }
            result.append(
                String(canonicalURL.path.dropFirst(canonicalPrefix.count))
            )
        }
        return result.sorted()
    }
}

enum ConfigurationHealthEvaluator {
    static func evaluate(
        configText: String,
        runtimeTruth: RuntimeTruth?,
        lastTransaction: RealSwitchTransaction?,
        capabilityEvidence: ConfigurationCapabilityEvidence? = nil,
        expectedAgentBundleIdentifier: String? = nil,
        expectedAgentVersion: String? = nil,
        expectedProviderID: String? = nil,
        expectedCodexContractID: String? = nil,
        expectedProfileID: String? = nil,
        expectedCapabilityProfileSHA256: String? = nil,
        catalogInspection: Build65CatalogInspection? = nil,
        now: Date = Date()
    ) -> ConfigurationHealthReport {
        let redacted = TOMLSensitiveValueRedactor.redact(configText)
        let document: TOMLSemanticDocument
        do {
            document = try TOMLSemanticEngine.parse(redacted)
        } catch {
            return ConfigurationHealthReport(
                generatedAt: Date(),
                semanticHash: nil,
                items: [
                    item(
                        .safety,
                        "TOML语法",
                        .blocked,
                        "无法安全解析：\(error.localizedDescription)"
                    ),
                    item(
                        .runtime,
                        "真实探针",
                        .blocked,
                        "配置语法未通过，禁止启动真实探针。"
                    ),
                ]
            )
        }

        var items: [ConfigurationHealthItem] = []
        let provider = document.rootString("model_provider")
        let model = document.rootString("model")
        let effort = document.rootString("model_reasoning_effort")
        let context = document.rootInteger("model_context_window")
        let compact = document.rootInteger("model_auto_compact_token_limit")
        let hasLegacyBearer = document.leaves.keys.contains {
            $0.contains("experimental_bearer_token")
        }
        let wireProtocol = provider.flatMap {
            document.string(at: ["model_providers", $0, "wire_api"])
        }
        let modelCatalogPath = document.rootString(
            "model_catalog_json"
        )

        items.append(item(
            .safety,
            "TOML语法",
            .passed,
            "完整语义解析通过；共\(document.leaves.count)个动态叶子。"
        ))
        items.append(item(
            .safety,
            "中转认证字段",
            .passed,
            hasLegacyBearer
                ? "已识别当前受管中转合同使用的认证字段；助手不读取或显示正文。"
                : "未检测到experimental_bearer_token。"
        ))
        if let truth = runtimeTruth {
            items.append(item(
                .safety,
                "真实状态一致性",
                truth.allowsManagedWrite ? .passed : .blocked,
                truth.allowsManagedWrite
                    ? "持久配置、有效配置层和已知运行上下文无阻断。"
                    : (truth.blockingReasons.isEmpty ? "真实状态证据不足。" : truth.blockingReasons.joined(separator: "；"))
            ))
        } else {
            items.append(item(
                .safety,
                "真实状态一致性",
                .unverified,
                "尚未取得可验证的RuntimeTruth。"
            ))
        }

        let providerIsOfficial = provider == nil || provider == "openai"
        let providerExists = providerIsOfficial || provider.map(document.providerIDs.contains) == true
        items.append(item(
            .frequent,
            "Provider",
            providerExists ? .passed : .blocked,
            providerIsOfficial
                ? "官方Provider。"
                : (providerExists ? "Provider \(provider!)存在对应配置表。" : "Provider \(provider ?? "未知")缺少对应配置表。")
        ))
        items.append(item(
            .frequent,
            "模型",
            model?.isEmpty == false ? .passed : .warning,
            model?.isEmpty == false ? "已设置模型：\(model!)" : "未设置固定模型，将由Agent或Provider默认值决定。"
        ))
        let allowedEfforts: Set<String> = [
            "none", "minimal", "low", "medium", "high", "xhigh",
            "max", "ultra",
        ]
        items.append(item(
            .frequent,
            "思考强度",
            effort == nil || allowedEfforts.contains(effort!) ? .passed : .blocked,
            effort.map { allowedEfforts.contains($0) ? "合法值：\($0)" : "未知值：\($0)" }
                ?? "未固定思考强度。"
        ))

        items.append(item(
            .cost,
            "上下文窗口",
            context == nil ? .unverified : (context! > 0 ? .passed : .blocked),
            context.map { $0 > 0 ? "\($0) tokens" : "必须大于0。" }
                ?? "中转资料未提供；需按模型证据填写或保持未验证。"
        ))
        let compactState: ConfigurationHealthState
        let compactDetail: String
        if let compact {
            if compact <= 0 {
                compactState = .blocked
                compactDetail = "自动压缩阈值必须大于0。"
            } else if let context, compact > context {
                compactState = .blocked
                compactDetail = "自动压缩阈值\(compact)超过上下文\(context)。"
            } else {
                compactState = .passed
                compactDetail = "\(compact) tokens"
            }
        } else {
            compactState = .unverified
            compactDetail = "未设置自动压缩阈值。"
        }
        items.append(item(.cost, "自动压缩阈值", compactState, compactDetail))

        items.append(item(
            .structure,
            "非Provider结构",
            document.leaves.isEmpty ? .blocked : .passed,
            "结构基于动态语义叶子保护；未使用固定117、15、10、9作为断言。"
        ))
        items.append(item(
            .structure,
            "配置漂移",
            runtimeTruth?.state == .drifted ? .blocked : (runtimeTruth == nil ? .unverified : .passed),
            runtimeTruth?.state == .drifted
                ? "运行轨与持久配置不一致。"
                : "未发现已知运行轨漂移；未知配置层仍按RuntimeTruth阻止。"
        ))

        let currentProviderReceipts:
            [ProviderCapabilityProbeReceipt]
        if let expectedProviderID,
           !expectedProviderID.isEmpty,
           let expectedCodexContractID,
           !expectedCodexContractID.isEmpty {
            currentProviderReceipts =
                ProviderCapabilityProbeEvidenceGate
                    .currentReceipts(
                        capabilityEvidence?
                            .providerProbeReceipts ?? [],
                        expectedProviderID: expectedProviderID,
                        expectedCodexContractID:
                            expectedCodexContractID,
                        expectedProfileID:
                            expectedProfileID,
                        expectedCapabilityProfileSHA256:
                            expectedCapabilityProfileSHA256,
                        now: now
                    )
            let suite = ProviderProbeSuiteResult.evaluate(
                currentProviderReceipts
            )
            let blocked = suite.decision == .blockBeforeWrite
            items.append(item(
                .runtime,
                "核心接入闸门",
                blocked ? .blocked : .passed,
                blocked
                    ? "核心探针缺失或失败：\(suite.missingOrFailedCore.map(\.rawValue).joined(separator: "、"))；真实写入保持阻止。"
                    : "TOML、认证、Responses最小文本请求和CAS均有当前合同证据。"
            ))
        } else {
            currentProviderReceipts = []
            items.append(item(
                .runtime,
                "核心接入闸门",
                .unverified,
                "尚未绑定当前Provider和Codex版本合同。"
            ))
        }
        items.append(contentsOf: ConfigurationHealthRuntimeEvidence.items(
            lastTransaction: lastTransaction,
            receipt: latestProviderReceipt(.responsesText, in: currentProviderReceipts),
            providerID: provider, modelID: model,
            runtimeDrifted: runtimeTruth?.state == .drifted
        ))
        let catalogReceipt = latestProviderReceipt(
            .modelCatalog,
            in: currentProviderReceipts
        )
        let catalogState: ConfigurationHealthState
        let catalogDetail: String
        if modelCatalogPath == nil {
            catalogState = .notEnabled
            catalogDetail = catalogReceipt?.status == .verified
                ? "已有受管目录完整性回执，但当前配置尚未采用该路径；不等同Provider /models接口在线。"
                : "未设置受管模型目录；不会覆盖用户已有外部路径。"
        } else if let catalogInspection {
            let catalogAction = Build65HealthActionResolver.resolveCatalog(
                itemState: .warning,
                inspection: catalogInspection,
                connectionHealthy: true
            )
            let liveCatalogHealthy = catalogInspection.failureCode == nil
                && catalogInspection.externalSourceUnchanged
            catalogState = liveCatalogHealthy
                ? .passed
                : (catalogAction.severity == .blocking ? .blocked : .warning)
            if let failure = catalogInspection.failureCode {
                catalogDetail =
                    "实时目录核对失败："
                    + Build65CatalogFailurePresentation.from(failure).message
            } else {
                catalogDetail =
                    "实时目录已读取并通过当前字段、hash和模型核对；此证据不代表Provider /models接口在线。"
            }
        } else if catalogReceipt?.status == .verified {
            catalogState = .passed
            catalogDetail = "已设置model_catalog_json；受管副本的Provider绑定、版本合同、hash和模型字段已验证。此证据不代表Provider /models接口在线。"
        } else {
            catalogState = .warning
            catalogDetail = "已设置model_catalog_json，但目录来源、hash或模型字段尚未完成当前合同验证。"
        }
        items.append(item(
            .capabilities,
            "受管模型目录",
            catalogState,
            catalogDetail
        ))
        let skillCount = capabilityEvidence?.skillManifestPaths.count ?? 0
        items.append(item(
            .capabilities,
            "Skills",
            skillCount > 0 ? .passed : .unverified,
            skillCount > 0
                ? "发现\(skillCount)个普通SKILL.md清单；只证明文件可识别，不证明触发和任务结果。"
                : "未在当前个人~/.agents/skills目录发现普通SKILL.md；尚未检查Agent官方内置能力。"
        ))
        let pluginCount = capabilityEvidence?.pluginManifestPaths.count ?? 0
        items.append(item(
            .capabilities,
            "Plugins",
            pluginCount > 0 ? .passed : .unverified,
            pluginCount > 0
                ? "发现\(pluginCount)个plugin.json清单；连接器授权、套餐和运行状态仍需单独验证。"
                : "未在当前CODEX_HOME发现可识别Plugin清单。"
        ))
        let mcpIDs = capabilityEvidence?.configuredMCPServerIDs ?? []
        let receipts: [CapabilityProbeReceipt]
        if expectedAgentBundleIdentifier?.isEmpty == false,
           expectedAgentVersion?.isEmpty == false {
            receipts = capabilityEvidence?.probeReceipts ?? []
        } else {
            receipts = []
        }
        let mcpVerified = CapabilityProbeEvidenceGate.result(
            kind: .mcpConnection,
            receipts: receipts,
            now: now,
            expectedAgentBundleIdentifier:
                expectedAgentBundleIdentifier,
            expectedAgentVersion: expectedAgentVersion
        )
        items.append(item(
            .capabilities,
            "MCP",
            mcpVerified == true
                ? .passed
                : (mcpIDs.isEmpty ? .notEnabled : .unverified),
            mcpVerified == true
                ? "已验证MCP连接：\(mcpIDs.joined(separator: "、"))"
                : (mcpIDs.isEmpty
                    ? "没有发现MCP配置；未执行工具枚举。"
                    : "已配置\(mcpIDs.count)个MCP：\(mcpIDs.joined(separator: "、"))；配置存在不等于进程已连接。")
        ))
        capabilityItem(
            title: "工具调用",
            evidence: CapabilityProbeEvidenceGate.result(
                kind: .toolEnumeration,
                receipts: receipts,
                now: now,
                expectedAgentBundleIdentifier:
                    expectedAgentBundleIdentifier,
                expectedAgentVersion: expectedAgentVersion
            ),
            passed: "已完成工具枚举和只读调用验证。",
            unknown: "尚未完成工具枚举；不能从模型名称或配置推断支持。",
            into: &items
        )
        capabilityItem(
            title: "图片输入",
            evidence: CapabilityProbeEvidenceGate.result(
                kind: .imageInput,
                receipts: receipts,
                now: now,
                expectedAgentBundleIdentifier:
                    expectedAgentBundleIdentifier,
                expectedAgentVersion: expectedAgentVersion
            ),
            passed: "已完成脱敏图片夹具请求验证。",
            unknown: "尚未执行图片夹具；配置或目录声明不等于模型实际支持。",
            into: &items
        )
        let protocolVerified = CapabilityProbeEvidenceGate.result(
            kind: .protocolRequest,
            receipts: receipts,
            now: now,
            expectedAgentBundleIdentifier:
                expectedAgentBundleIdentifier,
            expectedAgentVersion: expectedAgentVersion
        ) == true
        items.append(item(
            .capabilities,
            "协议",
            protocolVerified ? .passed : (wireProtocol == nil ? .unverified : .warning),
            protocolVerified
                ? "有效协议请求回执已通过；历史切换记录不参与此判断。"
                : (wireProtocol.map { "配置声明\($0)，但尚无真实请求证据。" }
                    ?? "未识别活动Provider协议，尚未验证。")
        ))
        let configuredServiceTier = document
            .rootString("service_tier")?
            .lowercased()
        let fastApplicable = configuredServiceTier.map {
            ["fast", "priority"].contains($0)
        } == true
            || latestProviderReceipt(
                .serviceTier,
                in: currentProviderReceipts
            ) != nil
        let configuredWebSearch = document
            .rootString("web_search")?
            .lowercased()
        let responsesSearchApplicable = configuredWebSearch.map {
            ["live", "cached"].contains($0)
        } == true
            || latestProviderReceipt(
                .webSearchResponses,
                in: currentProviderReceipts
            ) != nil
        let standaloneSearchApplicable = provider.flatMap {
            document.boolean(at: [
                "model_providers",
                $0,
                "supports_standalone_web_search",
            ])
        } == true || latestProviderReceipt(
            .webSearchStandalone,
            in: currentProviderReceipts
        ) != nil
        let mcpSearchApplicable = latestProviderReceipt(
            .webSearchMCP,
            in: currentProviderReceipts
        ) != nil
        let citationsApplicable = responsesSearchApplicable
            || latestProviderReceipt(
                .webSearchCitations,
                in: currentProviderReceipts
            ) != nil
        let providerCompatibilityName = provider.flatMap {
            document.string(at: [
                "model_providers", $0, "name",
            ])
        }
        let remoteCompactionApplicable =
            providerCompatibilityName?
                .caseInsensitiveCompare("OpenAI") == .orderedSame
            || latestProviderReceipt(
                .remoteCompaction,
                in: currentProviderReceipts
            ) != nil
        providerProbeItem(
            title: "Fast请求",
            kind: .serviceTier,
            receipts: currentProviderReceipts,
            applicable: fastApplicable,
            verified: "已观察配置意图、规范化请求和目标档位证据。",
            unknown: "尚未观察Fast请求；按钮或配置字段不算实际档位证明。",
            into: &items
        )
        providerProbeItem(
            title: "Web Search（Responses）",
            kind: .webSearchResponses,
            receipts: currentProviderReceipts,
            applicable: responsesSearchApplicable,
            verified: "已观察Responses搜索工具调用和真实结果。",
            unknown: "普通Responses 200不算搜索证据。",
            into: &items
        )
        providerProbeItem(
            title: "Web Search（Standalone）",
            kind: .webSearchStandalone,
            receipts: currentProviderReceipts,
            applicable: standaloneSearchApplicable,
            verified: "已观察Provider Standalone搜索结果。",
            unknown: "Provider字段声明不等于Standalone搜索真实可用。",
            into: &items
        )
        providerProbeItem(
            title: "Web Search（MCP）",
            kind: .webSearchMCP,
            receipts: currentProviderReceipts,
            applicable: mcpSearchApplicable,
            verified: "已观察MCP搜索工具和结果；不冒充Responses搜索。",
            unknown: "尚无MCP搜索回执。",
            into: &items
        )
        providerProbeItem(
            title: "来源引用",
            kind: .webSearchCitations,
            receipts: currentProviderReceipts,
            applicable: citationsApplicable,
            verified: "搜索结果包含可核对来源引用结构。",
            unknown: "搜索能返回结果不代表包含标准引用。",
            into: &items
        )
        providerProbeItem(
            title: "远程在线压缩",
            kind: .remoteCompaction,
            receipts: currentProviderReceipts,
            applicable: remoteCompactionApplicable,
            verified: "已观察远程压缩事件或等价响应合同。",
            unknown: "本地自动压缩阈值不算远程在线压缩证据。",
            into: &items
        )
        providerProbeItem(
            title: "图片输入（Provider）",
            kind: .imageInput,
            receipts: currentProviderReceipts,
            verified: "已用小型合成图片完成当前Provider请求。",
            unknown: "尚未执行需确认的合成图片探针；音频未纳入首批。",
            into: &items
        )
        return ConfigurationHealthReport(
            generatedAt: Date(),
            semanticHash: document.semanticHash,
            catalogContext: Build65CatalogResolutionContext(
                profileID: expectedProfileID,
                catalogPath: modelCatalogPath,
                providerID: expectedProviderID ?? provider,
                codexContractID: expectedCodexContractID,
                selectedModelID: model
            ),
            items: items
        )
    }

    private static func capabilityItem(
        title: String,
        evidence: Bool?,
        passed: String,
        unknown: String,
        into items: inout [ConfigurationHealthItem]
    ) {
        items.append(item(
            .capabilities,
            title,
            evidence == true ? .passed : (evidence == false ? .warning : .unverified),
            evidence == true ? passed : (evidence == false ? "最近验证失败；请检查Provider、模型、账号和权限。" : unknown)
        ))
    }

    private static func latestProviderReceipt(
        _ kind: ProviderCapabilityProbeKind,
        in receipts: [ProviderCapabilityProbeReceipt]
    ) -> ProviderCapabilityProbeReceipt? {
        receipts.filter { $0.kind == kind }.max(by: {
            $0.observedAt < $1.observedAt
        })
    }

    private static func providerProbeItem(
        title: String,
        kind: ProviderCapabilityProbeKind,
        receipts: [ProviderCapabilityProbeReceipt],
        applicable: Bool = true,
        verified: String,
        unknown: String,
        into items: inout [ConfigurationHealthItem]
    ) {
        guard applicable else {
            items.append(item(
                .capabilities,
                title,
                .notEnabled,
                "当前轨未启用此能力；无需验证，也不计入能力差异。"
            ))
            return
        }
        let receipt = latestProviderReceipt(kind, in: receipts)
        let state: ConfigurationHealthState
        switch receipt?.status {
        case .verified:
            state = .passed
        case .requested, .unsupported, .degraded:
            state = .warning
        case .unknown, nil:
            state = .unverified
        }
        let detail: String
        if receipt?.status == .verified {
            detail = verified
        } else if let receipt {
            let configured = receipt.stage.configured ?? "unknown"
            let emitted = receipt.stage.emitted ?? "unknown"
            let actual = receipt.stage.actual ?? "unknown"
            detail = "\(unknown) configured=\(configured)，emitted=\(emitted)，actual=\(actual)，status=\(receipt.status.rawValue)。可选能力失败不触发rollback。"
        } else {
            detail = unknown
        }
        items.append(item(
            .capabilities,
            title,
            state,
            detail
        ))
    }

    private static func item(
        _ category: ConfigurationHealthCategory,
        _ title: String,
        _ state: ConfigurationHealthState,
        _ detail: String
    ) -> ConfigurationHealthItem {
        ConfigurationHealthItem(
            id: "\(category.rawValue):\(title)",
            category: category,
            title: title,
            state: state,
            detail: detail
        )
    }
}
