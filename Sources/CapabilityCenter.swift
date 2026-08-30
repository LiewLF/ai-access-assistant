import CryptoKit
import Foundation

enum CapabilityPackageType: String, Codable, CaseIterable {
    case skill
    case plugin
    case mcp
    case hook
    case routingRule
    case bundle
}

enum CapabilitySourceTier: Int, Codable, CaseIterable {
    case openAIOfficial = 0
    case agentOfficial = 1
    case trustedOrganization = 2
    case verifiedMarketplace = 3
    case github = 4
    case localImport = 5
}

enum CapabilityRiskLevel: String, Codable {
    case low
    case medium
    case high
    case unknown
}

struct CapabilityPermissionSurface: Codable, Equatable {
    let fileReadPatterns: [String]
    let fileWritePatterns: [String]
    let networkDomains: [String]
    let executesCommands: Bool
    let systemPermissions: [String]
    let oauthScopes: [String]
    let requiresAPIKey: Bool
    let canSendExternally: Bool
    let canDelete: Bool
    let canPayOrAdminister: Bool

    var weightedSize: Int {
        fileReadPatterns.count
            + fileWritePatterns.count * 2
            + networkDomains.count
            + systemPermissions.count * 3
            + oauthScopes.count * 2
            + (executesCommands ? 3 : 0)
            + (requiresAPIKey ? 2 : 0)
            + (canSendExternally ? 4 : 0)
            + (canDelete ? 5 : 0)
            + (canPayOrAdminister ? 8 : 0)
    }
}

struct CapabilityPackage: Identifiable, Codable, Equatable {
    let id: String
    let type: CapabilityPackageType
    let sourceTier: CapabilitySourceTier
    let displayName: String
    let summary: String
    let repositoryURL: URL?
    let marketplaceURL: URL?
    let version: String
    let commitSHA: String?
    let license: String?
    let maintainer: String
    let supportedAgents: [String]
    let supportedOperatingSystems: [String]
    let minimumAgentVersion: String?
    let providerProtocols: [String]
    let requiredModelCapabilities: [String]
    let runtimes: [String]
    let permissions: CapabilityPermissionSurface
    let installFiles: [String]
    let installCommands: [String]
    let uninstallFiles: [String]
    let latestReleaseAt: Date?
    let latestCommitAt: Date?
    let archived: Bool
    let stars: Int?
    let knownVulnerabilities: [String]
    let riskLevel: CapabilityRiskLevel
    let verifiedAt: Date?
    let verificationMethod: String?
    let conflicts: [String]
    let alternatives: [String]
}

struct CapabilityRequirement: Identifiable, Codable, Equatable {
    let id: String
    let description: String
    let requiredPackageTypes: [CapabilityPackageType]
    let modelCapabilities: [String]
    let dataSources: [String]
    let externalActions: [String]
}

struct CapabilityGoalAnalysis: Codable, Equatable {
    let originalGoal: String
    let requirements: [CapabilityRequirement]
    let privacyKeywordsSentToSearch: [String]
}

enum CapabilityGoalAnalyzer {
    static func analyze(_ goal: String) -> CapabilityGoalAnalysis {
        let normalized = goal.lowercased()
        var requirements: [CapabilityRequirement] = []
        func add(
            _ id: String,
            _ description: String,
            _ types: [CapabilityPackageType],
            _ modelCapabilities: [String] = [],
            _ dataSources: [String] = [],
            _ actions: [String] = []
        ) {
            requirements.append(CapabilityRequirement(
                id: id,
                description: description,
                requiredPackageTypes: types,
                modelCapabilities: modelCapabilities,
                dataSources: dataSources,
                externalActions: actions
            ))
        }
        if normalized.contains("excel") || normalized.contains("表格") || normalized.contains("图表") {
            add("structured-data", "读取结构化表格并生成图表", [.skill, .plugin], [], ["本地文件"], [])
        }
        if normalized.contains("notion") {
            add("notion", "读取用户授权的Notion内容", [.plugin, .mcp], [], ["Notion"], ["OAuth读取"])
        }
        if normalized.contains("浏览器") || normalized.contains("网站") {
            add("browser", "控制浏览器完成网站测试", [.skill, .mcp], [], [], ["浏览器控制"])
        }
        if normalized.contains("图片") || normalized.contains("视觉") {
            add("vision", "处理图片输入", [.skill, .plugin], ["image_input"])
        }
        if normalized.contains("路由") || normalized.contains("工作流") {
            add("routing", "按任务选择工作流", [.routingRule, .hook, .skill])
        }
        if requirements.isEmpty {
            add("general", "匹配用户描述的通用能力", CapabilityPackageType.allCases)
        }
        let keywords = requirements.flatMap { requirement in
            [requirement.id, requirement.description] + requirement.dataSources
        }
        return CapabilityGoalAnalysis(
            originalGoal: goal,
            requirements: requirements,
            privacyKeywordsSentToSearch: Array(Set(keywords)).sorted()
        )
    }
}

struct CapabilityRuntimeContext: Codable, Equatable {
    let agent: String
    let operatingSystem: String
    let agentVersion: String?
    let providerProtocol: String?
    let modelCapabilities: [String]
    let accountCapabilities: [String]
    let installedPackageIDs: [String]
}

enum CapabilityCandidateState: String, Codable {
    case recommended
    case compatible
    case alreadyInstalled
    case incompatible
    case blockedByRisk
}

struct CapabilityRecommendationCandidate: Identifiable, Codable, Equatable {
    var id: String { package.id }
    let package: CapabilityPackage
    let state: CapabilityCandidateState
    let score: Int
    let reasons: [String]
    let limitations: [String]
}

struct CapabilityRecommendation: Codable, Equatable {
    let originalGoal: String
    let requirements: [CapabilityRequirement]
    let candidates: [CapabilityRecommendationCandidate]
    let generatedAt: Date
}

enum CapabilityRecommendationEngine {
    static func recommend(
        analysis: CapabilityGoalAnalysis,
        packages: [CapabilityPackage],
        context: CapabilityRuntimeContext,
        now: Date = Date()
    ) -> CapabilityRecommendation {
        let requiredTypes = Set(analysis.requirements.flatMap(\.requiredPackageTypes))
        let requiredModelCapabilities = Set(analysis.requirements.flatMap(\.modelCapabilities))
        let candidates = packages.map { package -> CapabilityRecommendationCandidate in
            var reasons: [String] = []
            var limitations: [String] = []
            var score = 1_000 - package.sourceTier.rawValue * 100
            var state: CapabilityCandidateState = .compatible
            if context.installedPackageIDs.contains(package.id) {
                state = .alreadyInstalled
                limitations.append("已经安装，不重复安装。")
                score -= 500
            }
            if !requiredTypes.contains(package.type), package.type != .bundle {
                state = .incompatible
                limitations.append("组件类型不匹配当前目标。")
            }
            if !package.supportedAgents.contains(context.agent)
                || !package.supportedOperatingSystems.contains(context.operatingSystem) {
                state = .incompatible
                limitations.append("不兼容当前Agent或操作系统。")
            }
            let requiredByPackage = Set(package.requiredModelCapabilities)
            let availableCapabilities = Set(context.modelCapabilities)
            if !requiredByPackage.isSubset(of: availableCapabilities)
                || !requiredModelCapabilities.isSubset(of: availableCapabilities) {
                state = .incompatible
                limitations.append("当前Provider或模型缺少必要能力。")
            }
            if package.archived || !package.knownVulnerabilities.isEmpty {
                state = .blockedByRisk
                limitations.append(package.archived ? "仓库已归档。" : "存在已知漏洞。")
            }
            if package.riskLevel == .high || package.riskLevel == .unknown {
                state = .blockedByRisk
                limitations.append("风险过高或无法解释，不开放一键安装。")
            }
            score -= package.permissions.weightedSize * 5
            score -= package.runtimes.count * 8
            if let verifiedAt = package.verifiedAt,
               now.timeIntervalSince(verifiedAt) < 90 * 24 * 60 * 60 {
                score += 30
                reasons.append("近期有可核验记录。")
            }
            if package.sourceTier == .openAIOfficial || package.sourceTier == .agentOfficial {
                reasons.append("官方维护来源优先。")
            }
            if package.permissions.weightedSize == 0 {
                reasons.append("权限面较小。")
            }
            if state == .compatible { state = .recommended }
            return CapabilityRecommendationCandidate(
                package: package,
                state: state,
                score: score,
                reasons: reasons,
                limitations: limitations
            )
        }.sorted {
            if statePriority($0.state) != statePriority($1.state) {
                return statePriority($0.state) < statePriority($1.state)
            }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.package.id < $1.package.id
        }
        return CapabilityRecommendation(
            originalGoal: analysis.originalGoal,
            requirements: analysis.requirements,
            candidates: candidates,
            generatedAt: now
        )
    }

    private static func statePriority(_ state: CapabilityCandidateState) -> Int {
        switch state {
        case .recommended: return 0
        case .compatible: return 1
        case .alreadyInstalled: return 2
        case .incompatible: return 3
        case .blockedByRisk: return 4
        }
    }
}

enum CapabilitySecurityFindingKind: String, Codable {
    case unsignedBinary
    case obfuscatedCode
    case remoteDownloader
    case installScript
    case broadFileWrite
    case sensitiveSystemPermission
    case broadOAuth
    case credentialAccess
    case destructiveTool
    case paymentOrAdminTool
    case promptInjection
    case unpinnedDependency
    case unknownExecutable
}

struct CapabilitySecurityFinding: Identifiable, Codable, Equatable {
    var id: String { "\(kind.rawValue):\(evidence)" }
    let kind: CapabilitySecurityFindingKind
    let severity: CapabilityRiskLevel
    let evidence: String
    let explanation: String
}

struct CapabilityStaticReviewInput: Codable, Equatable {
    let filePaths: [String]
    let textFiles: [String: String]
    let binaryPaths: [String]
    let installCommands: [String]
    let dependencyVersions: [String: String]
    let permissions: CapabilityPermissionSurface
}

struct CapabilitySecurityReview: Codable, Equatable {
    let riskLevel: CapabilityRiskLevel
    let oneClickAllowed: Bool
    let findings: [CapabilitySecurityFinding]
}

enum CapabilitySecurityAuditor {
    static func review(_ input: CapabilityStaticReviewInput) -> CapabilitySecurityReview {
        var findings: [CapabilitySecurityFinding] = []
        func add(
            _ kind: CapabilitySecurityFindingKind,
            _ severity: CapabilityRiskLevel,
            _ evidence: String,
            _ explanation: String
        ) {
            findings.append(CapabilitySecurityFinding(
                kind: kind,
                severity: severity,
                evidence: evidence,
                explanation: explanation
            ))
        }
        for path in input.binaryPaths {
            add(.unsignedBinary, .high, path, "二进制签名和来源尚未验证。")
        }
        for command in input.installCommands {
            let lower = command.lowercased()
            if lower.contains("curl ") || lower.contains("wget ") {
                add(.remoteDownloader, .high, command, "安装命令会继续下载远程内容。")
            }
            if lower.contains("| sh") || lower.contains("| bash") || lower.contains("invoke-expression") {
                add(.installScript, .high, command, "远程内容直接进入Shell执行。")
            }
            if lower.contains("sudo ") || lower.contains("rm -rf") {
                add(.unknownExecutable, .high, command, "命令包含管理员或破坏性动作。")
            }
        }
        for (path, text) in input.textFiles {
            let lower = text.lowercased()
            if lower.contains("ignore previous instructions")
                || lower.contains("bypass approval")
                || lower.contains("steal credential") {
                add(.promptInjection, .high, path, "发现绕过审批或凭据窃取指令。")
            }
            if lower.contains("eval(") && lower.contains("base64") {
                add(.obfuscatedCode, .high, path, "发现可疑动态执行和编码组合。")
            }
        }
        for (name, version) in input.dependencyVersions where version == "latest" || version == "*" {
            add(.unpinnedDependency, .medium, "\(name)=\(version)", "依赖版本未锁定。")
        }
        if input.permissions.fileWritePatterns.contains(where: { $0 == "/" || $0 == "~" || $0.contains("**") }) {
            add(.broadFileWrite, .high, input.permissions.fileWritePatterns.joined(separator: ","), "文件写入范围过宽。")
        }
        if !input.permissions.systemPermissions.isEmpty {
            add(.sensitiveSystemPermission, .medium, input.permissions.systemPermissions.joined(separator: ","), "需要额外系统权限。")
        }
        if input.permissions.oauthScopes.contains(where: { $0.contains("admin") || $0.contains("write") }) {
            add(.broadOAuth, .high, input.permissions.oauthScopes.joined(separator: ","), "OAuth包含写入或管理员范围。")
        }
        if input.permissions.requiresAPIKey {
            add(.credentialAccess, .medium, "API Key", "组件需要读取独立凭据。")
        }
        if input.permissions.canDelete {
            add(.destructiveTool, .high, "delete", "组件包含删除动作。")
        }
        if input.permissions.canPayOrAdminister {
            add(.paymentOrAdminTool, .high, "payment/admin", "组件包含付款或管理员动作。")
        }
        let risk: CapabilityRiskLevel
        if findings.contains(where: { $0.severity == .high }) {
            risk = .high
        } else if findings.contains(where: { $0.severity == .medium }) {
            risk = .medium
        } else {
            risk = .low
        }
        return CapabilitySecurityReview(
            riskLevel: risk,
            oneClickAllowed: risk != .high && input.binaryPaths.isEmpty,
            findings: findings
        )
    }
}

struct CapabilityInstallationPlan: Identifiable, Codable, Equatable {
    let id: String
    let packageID: String
    let sourceURL: URL?
    let pinnedVersion: String
    let pinnedCommitSHA: String?
    let expectedFiles: [String]
    let commands: [String]
    let permissions: CapabilityPermissionSurface
    let restorePointPaths: [String]
    let uninstallPaths: [String]
    let requiresUserConfirmation: Bool
}

enum CapabilityInstallationState: String, Codable {
    case planned
    case awaitingConfirmation
    case restorePointCreated
    case downloaded
    case verified
    case installed
    case agentRefreshed
    case capabilityVerified
    case committed
    case rolledBack
    case manualRecoveryRequired
}

struct CapabilityInstallationTransaction: Identifiable, Codable, Equatable {
    let id: String
    let planID: String
    var state: CapabilityInstallationState
    let startedAt: Date
    var updatedAt: Date
    var createdFiles: [String]
    var modifiedFiles: [String]
    var sanitizedMessage: String
}

struct CapabilityExecutionStatus: Codable, Equatable {
    let installed: Bool
    let enabled: Bool
    let connected: Bool
    let currentModelCanExecute: Bool
    let currentAccountAuthorized: Bool
    let realTaskVerified: Bool
}

struct DiscoveredCapabilityRepository: Identifiable, Codable, Equatable {
    let id: Int
    let fullName: String
    let repositoryURL: URL
    let summary: String?
    let stars: Int
    let forks: Int
    let archived: Bool
    let defaultBranch: String
    let updatedAt: Date?
    let license: String?

    var initialRiskLabel: String {
        archived ? "仓库已归档，阻止安装" : "未经安全审查，不能一键安装"
    }
}

struct OfficialCapabilityReference: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let summary: String
    let packageTypes: [CapabilityPackageType]
    let documentationURL: URL
    let limitation: String
}

enum OfficialCapabilityReferenceCatalog {
    static func references(
        for analysis: CapabilityGoalAnalysis
    ) -> [OfficialCapabilityReference] {
        let requested = Set(analysis.requirements.flatMap(\.requiredPackageTypes))
        var values: [OfficialCapabilityReference] = []
        if !requested.isDisjoint(with: [.skill, .plugin]) {
            values.append(OfficialCapabilityReference(
                id: "openai-skills-plugins",
                title: "OpenAI Skills与Plugins",
                summary: "先核对Codex官方机制和当前账号可见入口，避免重复安装第三方组件。",
                packageTypes: [.skill, .plugin],
                documentationURL: URL(
                    string: "https://learn.chatgpt.com/docs/skills-and-plugins"
                )!,
                limitation: "官方文档存在不证明当前套餐、工作区或地区已开放具体能力。"
            ))
        }
        if requested.contains(.skill) {
            values.append(OfficialCapabilityReference(
                id: "openai-build-skills",
                title: "OpenAI构建Skills",
                summary: "核对Skill目录、清单和官方工作流要求。",
                packageTypes: [.skill],
                documentationURL: URL(
                    string: "https://learn.chatgpt.com/docs/build-skills"
                )!,
                limitation: "这是机制文档，不是自动安装包。"
            ))
        }
        if requested.contains(.plugin) {
            values.append(OfficialCapabilityReference(
                id: "openai-plugins",
                title: "OpenAI Plugins",
                summary: "优先从Codex官方Plugin入口安装和授权。",
                packageTypes: [.plugin],
                documentationURL: URL(
                    string: "https://learn.chatgpt.com/docs/plugins"
                )!,
                limitation: "连接器授权和工作区批准必须由用户完成。"
            ))
        }
        return values
    }
}

struct SignedCapabilityCatalogPayload: Codable, Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let generatedAt: Date
    let packages: [CapabilityPackage]
    let revokedPackageIDs: [String]
}

struct SignedCapabilityCatalogPackage: Codable, Equatable {
    let payload: SignedCapabilityCatalogPayload
    let keyID: String
    let signature: Data
}

struct CapabilityCatalogPublicKeyDocument: Codable, Equatable {
    let schemaVersion: Int
    let keyID: String
    let displayName: String
    let publicKeyBase64: String
    let sourceURL: URL?
}

struct CapabilityCatalogReceipt: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let catalogVersion: String
    let keyID: String
    let publisherName: String
    let publicKeyFingerprint: String
    let generatedAt: Date
    let importedAt: Date
    let packages: [CapabilityPackage]
    let revokedPackageIDs: [String]
}

enum CapabilityCatalogError: LocalizedError, Equatable {
    case malformedPackage
    case malformedPublicKey
    case unsupportedSchema(Int)
    case keyIdentifierMismatch
    case invalidSignature
    case revokedPackage(String)
    case untrustedSourceTier(String)
    case missingVerification(String)

    var errorDescription: String? {
        switch self {
        case .malformedPackage: return "能力目录文件格式无法识别"
        case .malformedPublicKey: return "能力目录发布者公钥无法识别"
        case let .unsupportedSchema(version): return "能力目录Schema \(version)不受支持"
        case .keyIdentifierMismatch: return "能力目录Key ID与发布者公钥不一致"
        case .invalidSignature: return "能力目录签名无效"
        case let .revokedPackage(id): return "能力包已撤销：\(id)"
        case let .untrustedSourceTier(id): return "签名目录不能把未经核验GitHub包冒充可信来源：\(id)"
        case let .missingVerification(id): return "能力包缺少版本、维护者或核验记录：\(id)"
        }
    }
}

enum SignedCapabilityCatalogVerifier {
    static func sign(
        payload: SignedCapabilityCatalogPayload,
        keyID: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedCapabilityCatalogPackage {
        SignedCapabilityCatalogPackage(
            payload: payload,
            keyID: keyID,
            signature: try privateKey.signature(for: canonicalData(payload))
        )
    }

    static func verify(
        package: SignedCapabilityCatalogPackage,
        key: Curve25519.Signing.PublicKey
    ) throws -> [CapabilityPackage] {
        guard package.payload.schemaVersion == 1 else {
            throw CapabilityCatalogError.unsupportedSchema(package.payload.schemaVersion)
        }
        guard key.isValidSignature(
            package.signature,
            for: try canonicalData(package.payload)
        ) else {
            throw CapabilityCatalogError.invalidSignature
        }
        for value in package.payload.packages {
            guard !package.payload.revokedPackageIDs.contains(value.id) else {
                throw CapabilityCatalogError.revokedPackage(value.id)
            }
            guard value.sourceTier == .trustedOrganization
                    || value.sourceTier == .verifiedMarketplace
                    || value.sourceTier == .openAIOfficial
                    || value.sourceTier == .agentOfficial else {
                throw CapabilityCatalogError.untrustedSourceTier(value.id)
            }
            guard value.version != "latest",
                  !value.version.isEmpty,
                  !value.maintainer.isEmpty,
                  value.verifiedAt != nil,
                  value.verificationMethod?.isEmpty == false else {
                throw CapabilityCatalogError.missingVerification(value.id)
            }
        }
        return package.payload.packages
    }

    static func importPackage(
        packageData: Data,
        publicKeyData: Data,
        now: Date = Date()
    ) throws -> CapabilityCatalogReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let package = try? decoder.decode(
            SignedCapabilityCatalogPackage.self,
            from: packageData
        ) else {
            throw CapabilityCatalogError.malformedPackage
        }
        guard let keyDocument = try? decoder.decode(
            CapabilityCatalogPublicKeyDocument.self,
            from: publicKeyData
        ),
        keyDocument.schemaVersion == 1,
        let raw = Data(base64Encoded: keyDocument.publicKeyBase64),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw CapabilityCatalogError.malformedPublicKey
        }
        guard package.keyID == keyDocument.keyID else {
            throw CapabilityCatalogError.keyIdentifierMismatch
        }
        let packages = try verify(package: package, key: key)
        return CapabilityCatalogReceipt(
            schemaVersion: CapabilityCatalogReceipt.currentSchemaVersion,
            catalogVersion: package.payload.catalogVersion,
            keyID: package.keyID,
            publisherName: keyDocument.displayName,
            publicKeyFingerprint: SHA256.hash(data: raw)
                .map { String(format: "%02x", $0) }.joined(),
            generatedAt: package.payload.generatedAt,
            importedAt: now,
            packages: packages,
            revokedPackageIDs: package.payload.revokedPackageIDs
        )
    }

    private static func canonicalData(
        _ payload: SignedCapabilityCatalogPayload
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

struct CapabilityCatalogStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI接入助手/CapabilityCatalog", isDirectory: true)
    }

    var receiptURL: URL { directory.appendingPathComponent("verified-catalog.json") }

    func save(_ receipt: CapabilityCatalogReceipt) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }

    func load() throws -> CapabilityCatalogReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            CapabilityCatalogReceipt.self,
            from: Data(contentsOf: receiptURL, options: .mappedIfSafe)
        )
        guard receipt.schemaVersion <= CapabilityCatalogReceipt.currentSchemaVersion else {
            throw CapabilityCatalogError.unsupportedSchema(receipt.schemaVersion)
        }
        return receipt
    }
}

struct GitHubCapabilityLock: Codable, Equatable {
    let repositoryFullName: String
    let defaultBranch: String
    let commitSHA: String
    let releaseTag: String?
    let releaseURL: URL?
    let retrievedAt: Date
}

enum GitHubCapabilityLockError: LocalizedError {
    case invalidRepository
    case responseTooLarge
    case badResponse(Int)
    case unexpectedHost
    case malformedResponse
    case commitNotPinned

    var errorDescription: String? {
        switch self {
        case .invalidRepository: return "GitHub仓库标识无效"
        case .responseTooLarge: return "GitHub锁定响应超过1 MB"
        case let .badResponse(status): return "GitHub锁定请求失败 HTTP \(status)"
        case .unexpectedHost: return "GitHub锁定请求被重定向到非api.github.com"
        case .malformedResponse: return "GitHub Commit或Release响应无法识别"
        case .commitNotPinned: return "未取得40位Commit SHA，禁止生成安装计划"
        }
    }
}

enum GitHubCapabilityLockService {
    static func lock(
        repository: DiscoveredCapabilityRepository,
        session: URLSession? = nil,
        now: Date = Date()
    ) async throws -> GitHubCapabilityLock {
        let parts = repository.fullName.split(separator: "/")
        guard parts.count == 2,
              parts.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy {
                      $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
                  }
              }) else {
            throw GitHubCapabilityLockError.invalidRepository
        }
        let base = "https://api.github.com/repos/\(parts[0])/\(parts[1])"
        let commitObject = try await requestJSON(
            URL(string: "\(base)/commits/\(repository.defaultBranch)")!,
            session: session
        )
        guard let sha = commitObject["sha"] as? String,
              sha.count == 40,
              sha.allSatisfy(\.isHexDigit) else {
            throw GitHubCapabilityLockError.commitNotPinned
        }
        var releaseTag: String?
        var releaseURL: URL?
        do {
            let release = try await requestJSON(
                URL(string: "\(base)/releases/latest")!,
                session: session
            )
            releaseTag = release["tag_name"] as? String
            if let html = release["html_url"] as? String,
               let url = URL(string: html),
               url.scheme == "https",
               url.host == "github.com" {
                releaseURL = url
            }
        } catch GitHubCapabilityLockError.badResponse(404) {
            releaseTag = nil
            releaseURL = nil
        }
        return GitHubCapabilityLock(
            repositoryFullName: repository.fullName,
            defaultBranch: repository.defaultBranch,
            commitSHA: sha.lowercased(),
            releaseTag: releaseTag,
            releaseURL: releaseURL,
            retrievedAt: now
        )
    }

    private static func requestJSON(
        _ url: URL,
        session: URLSession?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            AppReleaseMetadata.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let client: URLSession
        if let session {
            client = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            client = URLSession(configuration: configuration)
        }
        let (data, response) = try await client.data(for: request)
        guard data.count <= 1_048_576 else {
            throw GitHubCapabilityLockError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubCapabilityLockError.malformedResponse
        }
        guard http.url?.scheme == "https", http.url?.host == "api.github.com" else {
            throw GitHubCapabilityLockError.unexpectedHost
        }
        guard http.statusCode == 200 else {
            throw GitHubCapabilityLockError.badResponse(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubCapabilityLockError.malformedResponse
        }
        return object
    }
}

struct CapabilitySourceAggregation: Codable, Equatable {
    let officialReferences: [OfficialCapabilityReference]
    let trustedPackages: [CapabilityPackage]
    let githubRepositories: [DiscoveredCapabilityRepository]
}

enum CapabilitySourceAggregator {
    static func aggregate(
        analysis: CapabilityGoalAnalysis,
        trustedCatalog: CapabilityCatalogReceipt?,
        githubRepositories: [DiscoveredCapabilityRepository]
    ) -> CapabilitySourceAggregation {
        let requiredTypes = Set(analysis.requirements.flatMap(\.requiredPackageTypes))
        let trusted = trustedCatalog?.packages.filter {
            requiredTypes.contains($0.type) || $0.type == .bundle
        } ?? []
        var seenRepositoryURLs = Set<String>()
        let github = githubRepositories.filter {
            seenRepositoryURLs.insert($0.repositoryURL.absoluteString.lowercased()).inserted
        }
        return CapabilitySourceAggregation(
            officialReferences: OfficialCapabilityReferenceCatalog.references(for: analysis),
            trustedPackages: trusted.sorted {
                if $0.sourceTier.rawValue != $1.sourceTier.rawValue {
                    return $0.sourceTier.rawValue < $1.sourceTier.rawValue
                }
                return $0.displayName < $1.displayName
            },
            githubRepositories: github
        )
    }
}

enum CapabilityDiscoveryError: LocalizedError {
    case emptyQuery
    case invalidEndpoint
    case responseTooLarge
    case badResponse(Int)
    case unexpectedHost
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .emptyQuery: return "请输入具体目标"
        case .invalidEndpoint: return "无法构造安全搜索请求"
        case .responseTooLarge: return "GitHub响应超过1 MB，已停止读取"
        case let .badResponse(code): return "GitHub搜索失败，HTTP \(code)"
        case .unexpectedHost: return "搜索请求被重定向到非GitHub域名，已阻止"
        case .malformedResponse: return "GitHub返回格式无法识别"
        }
    }
}

enum CapabilityDiscoveryService {
    static func searchGitHub(
        keywords: [String],
        session: URLSession? = nil
    ) async throws -> [DiscoveredCapabilityRepository] {
        let query = sanitizedQuery(keywords)
        guard !query.isEmpty else { throw CapabilityDiscoveryError.emptyQuery }
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "\(query) codex"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "10"),
        ]
        guard let url = components?.url else { throw CapabilityDiscoveryError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            AppReleaseMetadata.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let client: URLSession
        if let session {
            client = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            client = URLSession(configuration: configuration)
        }
        let (data, response) = try await client.data(for: request)
        guard data.count <= 1_048_576 else { throw CapabilityDiscoveryError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else {
            throw CapabilityDiscoveryError.malformedResponse
        }
        guard http.url?.scheme == "https", http.url?.host == "api.github.com" else {
            throw CapabilityDiscoveryError.unexpectedHost
        }
        guard http.statusCode == 200 else {
            throw CapabilityDiscoveryError.badResponse(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else {
            throw CapabilityDiscoveryError.malformedResponse
        }
        return items.prefix(10).compactMap { item in
            guard let id = item["id"] as? Int,
                  let fullName = item["full_name"] as? String,
                  let htmlURL = item["html_url"] as? String,
                  let repositoryURL = URL(string: htmlURL),
                  repositoryURL.scheme == "https",
                  repositoryURL.host == "github.com" else { return nil }
            let license = (item["license"] as? [String: Any])?["spdx_id"] as? String
            let updatedAt = (item["updated_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            return DiscoveredCapabilityRepository(
                id: id,
                fullName: fullName,
                repositoryURL: repositoryURL,
                summary: item["description"] as? String,
                stars: item["stargazers_count"] as? Int ?? 0,
                forks: item["forks_count"] as? Int ?? 0,
                archived: item["archived"] as? Bool ?? false,
                defaultBranch: item["default_branch"] as? String ?? "unknown",
                updatedAt: updatedAt,
                license: license
            )
        }
    }

    static func sanitizedQuery(_ keywords: [String]) -> String {
        let raw = keywords.joined(separator: " ")
        let safe = raw.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || scalar == "-"
        }
        return String(String.UnicodeScalarView(safe))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(80)
            .description
    }
}

struct CapabilityLocalInspectionResult {
    let rootURL: URL
    let relativeFiles: [String]
    let totalBytes: Int
    let treeSHA256: String
    let review: CapabilitySecurityReview
}

enum CapabilityLocalInspectionError: LocalizedError {
    case notDirectory
    case symbolicLink(String)
    case tooManyFiles
    case packageTooLarge
    case unsafeRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory: return "请选择一个本地组件文件夹"
        case let .symbolicLink(path): return "组件包含符号链接，已阻止：\(path)"
        case .tooManyFiles: return "组件文件超过2000个，已停止审查"
        case .packageTooLarge: return "静态审查内容超过5 MB，已停止读取"
        case let .unsafeRelativePath(path): return "组件路径越界，已阻止：\(path)"
        }
    }
}

enum CapabilityLocalPackageInspector {
    static func inspect(
        root: URL,
        maximumFiles: Int = 2_000,
        maximumBytes: Int = 5 * 1_024 * 1_024
    ) throws -> CapabilityLocalInspectionResult {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CapabilityLocalInspectionError.notDirectory
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CapabilityLocalInspectionError.notDirectory
        }
        var relativeFiles: [String] = []
        var textFiles: [String: String] = [:]
        var binaryPaths: [String] = []
        var installCommands: [String] = []
        var dependencies: [String: String] = [:]
        var totalBytes = 0
        var hashParts: [(String, Data)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = try safeRelativePath(url: url, root: root)
            if values.isSymbolicLink == true {
                throw CapabilityLocalInspectionError.symbolicLink(relative)
            }
            guard values.isRegularFile == true else { continue }
            relativeFiles.append(relative)
            guard relativeFiles.count <= maximumFiles else {
                throw CapabilityLocalInspectionError.tooManyFiles
            }
            let size = values.fileSize ?? 0
            totalBytes += size
            guard totalBytes <= maximumBytes else {
                throw CapabilityLocalInspectionError.packageTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            hashParts.append((relative, data))
            let ext = url.pathExtension.lowercased()
            if executableExtensions.contains(ext) || isMachO(data) {
                binaryPaths.append(relative)
            }
            if textExtensions.contains(ext) || documentationNames.contains(url.lastPathComponent.lowercased()) {
                if let text = String(data: data.prefix(256 * 1_024), encoding: .utf8) {
                    textFiles[relative] = text
                    installCommands.append(contentsOf: suspiciousCommandLines(in: text))
                    if url.lastPathComponent == "package.json" {
                        dependencies.merge(parseNodeDependencies(data)) { current, _ in current }
                    }
                }
            }
        }
        relativeFiles.sort()
        let permissions = inferPermissions(from: textFiles)
        let review = CapabilitySecurityAuditor.review(CapabilityStaticReviewInput(
            filePaths: relativeFiles,
            textFiles: textFiles,
            binaryPaths: binaryPaths,
            installCommands: Array(Set(installCommands)).sorted(),
            dependencyVersions: dependencies,
            permissions: permissions
        ))
        var digest = SHA256()
        for (path, data) in hashParts.sorted(by: { $0.0 < $1.0 }) {
            digest.update(data: Data(path.utf8))
            digest.update(data: Data([0]))
            digest.update(data: data)
            digest.update(data: Data([0]))
        }
        return CapabilityLocalInspectionResult(
            rootURL: root,
            relativeFiles: relativeFiles,
            totalBytes: totalBytes,
            treeSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            review: review
        )
    }

    private static let textExtensions: Set<String> = [
        "md", "txt", "json", "toml", "yaml", "yml", "xml",
        "swift", "py", "js", "mjs", "cjs", "ts", "sh", "zsh", "bash", "ps1",
    ]
    private static let executableExtensions: Set<String> = [
        "dylib", "so", "dll", "exe", "pkg", "dmg", "app", "bin",
    ]
    private static let documentationNames: Set<String> = [
        "skill.md", "readme", "readme.md", "license", "agents.md", "plugin.json",
    ]

    private static func safeRelativePath(url: URL, root: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw CapabilityLocalInspectionError.unsafeRelativePath(path)
        }
        let relative = String(path.dropFirst(rootPath.count))
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw CapabilityLocalInspectionError.unsafeRelativePath(relative)
        }
        return relative
    }

    private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = Array(data.prefix(4))
        return [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe],
        ].contains(magic)
    }

    private static func suspiciousCommandLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard ["curl ", "wget ", "| sh", "| bash", "sudo ", "rm -rf", "npm install", "pip install"]
                .contains(where: lower.contains) else { return nil }
            return String(line.prefix(400))
        }
    }

    private static func parseNodeDependencies(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for key in ["dependencies", "devDependencies"] {
            guard let values = object[key] as? [String: String] else { continue }
            result.merge(values) { current, _ in current }
        }
        return result
    }

    private static func inferPermissions(from files: [String: String]) -> CapabilityPermissionSurface {
        let joined = files.values.joined(separator: "\n").lowercased()
        let executes = joined.contains("child_process")
            || joined.contains("subprocess")
            || joined.contains("process(")
        let requiresKey = joined.contains("api_key")
            || joined.contains("api key")
            || joined.contains("token")
        let canDelete = joined.contains("delete(")
            || joined.contains("unlink(")
            || joined.contains("rm -")
        let canPay = joined.contains("payment")
            || joined.contains("billing")
            || joined.contains("admin")
        var systemPermissions: [String] = []
        if joined.contains("camera") { systemPermissions.append("camera") }
        if joined.contains("microphone") { systemPermissions.append("microphone") }
        if joined.contains("accessibility") { systemPermissions.append("accessibility") }
        if joined.contains("screen recording") { systemPermissions.append("screen-recording") }
        return CapabilityPermissionSurface(
            fileReadPatterns: joined.contains("readfile") ? ["需按代码继续核对"] : [],
            fileWritePatterns: joined.contains("writefile") ? ["需按代码继续核对"] : [],
            networkDomains: joined.contains("http://") || joined.contains("https://")
                ? ["代码包含网络地址，需逐项核对"] : [],
            executesCommands: executes,
            systemPermissions: systemPermissions,
            oauthScopes: joined.contains("oauth") ? ["需按服务商说明核对"] : [],
            requiresAPIKey: requiresKey,
            canSendExternally: joined.contains("fetch(") || joined.contains("urlsession"),
            canDelete: canDelete,
            canPayOrAdminister: canPay
        )
    }
}

enum CapabilityPlanFactory {
    static func makeLocalReviewPlan(
        packageID: String,
        sourceURL: URL?,
        inspection: CapabilityLocalInspectionResult
    ) -> CapabilityInstallationPlan {
        CapabilityInstallationPlan(
            id: UUID().uuidString,
            packageID: packageID,
            sourceURL: sourceURL,
            pinnedVersion: "tree-sha256:\(inspection.treeSHA256)",
            pinnedCommitSHA: nil,
            expectedFiles: inspection.relativeFiles,
            commands: [],
            permissions: inferPlanPermissions(inspection.review),
            restorePointPaths: [],
            uninstallPaths: inspection.relativeFiles,
            requiresUserConfirmation: true
        )
    }

    static func makeReviewedGitHubPlan(
        repository: DiscoveredCapabilityRepository,
        lock: GitHubCapabilityLock,
        inspection: CapabilityLocalInspectionResult
    ) throws -> CapabilityInstallationPlan {
        guard lock.repositoryFullName == repository.fullName,
              lock.commitSHA.count == 40,
              lock.commitSHA.allSatisfy(\.isHexDigit) else {
            throw GitHubCapabilityLockError.commitNotPinned
        }
        return CapabilityInstallationPlan(
            id: UUID().uuidString,
            packageID: repository.fullName,
            sourceURL: repository.repositoryURL,
            pinnedVersion: lock.releaseTag ?? "commit:\(lock.commitSHA)",
            pinnedCommitSHA: lock.commitSHA,
            expectedFiles: inspection.relativeFiles,
            commands: [],
            permissions: inferPlanPermissions(inspection.review),
            restorePointPaths: [],
            uninstallPaths: inspection.relativeFiles,
            requiresUserConfirmation: true
        )
    }

    private static func inferPlanPermissions(
        _ review: CapabilitySecurityReview
    ) -> CapabilityPermissionSurface {
        CapabilityPermissionSurface(
            fileReadPatterns: [],
            fileWritePatterns: [],
            networkDomains: [],
            executesCommands: review.findings.contains { $0.kind == .unknownExecutable },
            systemPermissions: [],
            oauthScopes: [],
            requiresAPIKey: review.findings.contains { $0.kind == .credentialAccess },
            canSendExternally: false,
            canDelete: review.findings.contains { $0.kind == .destructiveTool },
            canPayOrAdminister: review.findings.contains { $0.kind == .paymentOrAdminTool }
        )
    }
}

struct CapabilitySandboxReceipt: Codable, Equatable {
    let schemaVersion: Int
    let planID: String
    let packageID: String
    let sourceTreeSHA256: String
    let stagedFiles: [String]
    let stagedAt: Date
    let sandboxRoot: String
}

struct CapabilityPlanLockDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let plan: CapabilityInstallationPlan
    let sourceTreeSHA256: String
    let reviewRiskLevel: CapabilityRiskLevel
    let createdAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        plan: CapabilityInstallationPlan,
        sourceTreeSHA256: String,
        reviewRiskLevel: CapabilityRiskLevel,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.plan = plan
        self.sourceTreeSHA256 = sourceTreeSHA256
        self.reviewRiskLevel = reviewRiskLevel
        self.createdAt = createdAt
    }
}

enum CapabilityPlanLockError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "能力安装锁定清单Schema \(version)高于当前支持版本，已进入只读保护"
        }
    }
}

struct CapabilityPlanLockStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI接入助手/CapabilityPlans", isDirectory: true)
    }

    func fileURL(planID: String) -> URL {
        let safeID = planID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("\(safeID).json")
    }

    func save(_ document: CapabilityPlanLockDocument) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let url = fileURL(planID: document.plan.id)
        try encoder.encode(document).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(planID: String) throws -> CapabilityPlanLockDocument? {
        let url = fileURL(planID: planID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            CapabilityPlanLockDocument.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        guard document.schemaVersion <= CapabilityPlanLockDocument.currentSchemaVersion else {
            throw CapabilityPlanLockError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }
}

enum CapabilitySandboxError: LocalizedError {
    case userConfirmationRequired
    case riskBlocked
    case sourceChanged
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .userConfirmationRequired: return "必须先确认安装计划"
        case .riskBlocked: return "静态审查为高风险，已阻止试装"
        case .sourceChanged: return "本地组件在审查后发生变化，请重新审查"
        case let .unsafePath(path): return "试装路径越界，已阻止：\(path)"
        }
    }
}

enum CapabilitySandboxInstaller {
    static func stage(
        plan: CapabilityInstallationPlan,
        inspection: CapabilityLocalInspectionResult,
        sandboxRoot: URL,
        userConfirmed: Bool,
        now: Date = Date()
    ) throws -> CapabilitySandboxReceipt {
        guard userConfirmed else { throw CapabilitySandboxError.userConfirmationRequired }
        guard inspection.review.riskLevel != .high else { throw CapabilitySandboxError.riskBlocked }
        guard plan.pinnedVersion == "tree-sha256:\(inspection.treeSHA256)" else {
            throw CapabilitySandboxError.sourceChanged
        }
        let currentInspection = try CapabilityLocalPackageInspector.inspect(root: inspection.rootURL)
        guard currentInspection.treeSHA256 == inspection.treeSHA256 else {
            throw CapabilitySandboxError.sourceChanged
        }
        let target = sandboxRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var staged: [String] = []
        do {
            for relative in plan.expectedFiles {
                guard !relative.hasPrefix("/"),
                      !relative.split(separator: "/").contains("..") else {
                    throw CapabilitySandboxError.unsafePath(relative)
                }
                let source = inspection.rootURL.appendingPathComponent(relative).standardizedFileURL
                let destination = target.appendingPathComponent(relative).standardizedFileURL
                guard destination.path.hasPrefix(target.path + "/") else {
                    throw CapabilitySandboxError.unsafePath(relative)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.copyItem(at: source, to: destination)
                staged.append(relative)
            }
            let receipt = CapabilitySandboxReceipt(
                schemaVersion: 1,
                planID: plan.id,
                packageID: plan.packageID,
                sourceTreeSHA256: inspection.treeSHA256,
                stagedFiles: staged.sorted(),
                stagedAt: now,
                sandboxRoot: target.path
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let receiptURL = target.appendingPathComponent(".ai-access-install-receipt.json")
            try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: receiptURL.path
            )
            return receipt
        } catch {
            try? rollback(sandboxRoot: target, receipt: CapabilitySandboxReceipt(
                schemaVersion: 1,
                planID: plan.id,
                packageID: plan.packageID,
                sourceTreeSHA256: inspection.treeSHA256,
                stagedFiles: staged,
                stagedAt: now,
                sandboxRoot: target.path
            ))
            throw error
        }
    }

    static func rollback(
        sandboxRoot: URL,
        receipt: CapabilitySandboxReceipt
    ) throws {
        let root = sandboxRoot.standardizedFileURL
        guard receipt.sandboxRoot == root.path else {
            throw CapabilitySandboxError.unsafePath(receipt.sandboxRoot)
        }
        for relative in receipt.stagedFiles.reversed() {
            let target = root.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw CapabilitySandboxError.unsafePath(relative)
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
        let receiptURL = root.appendingPathComponent(".ai-access-install-receipt.json")
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try FileManager.default.removeItem(at: receiptURL)
        }
    }
}

enum CapabilityExecutionMode: String, Codable {
    case filesystemCopy
    case officialConfirmationFlow
    case configurationAdapter
    case incrementalTextPatch
    case compositeTransaction
}

struct CapabilityInstallTarget: Codable, Equatable {
    let packageType: CapabilityPackageType
    let executionMode: CapabilityExecutionMode
    let targetDescription: String
    let protectedSurfaces: [String]
    let requiredEvidence: [String]
}

enum CapabilityInstallTargetResolver {
    static func target(
        type: CapabilityPackageType,
        scope: String = "个人"
    ) -> CapabilityInstallTarget {
        switch type {
        case .skill:
            return CapabilityInstallTarget(
                packageType: type,
                executionMode: .filesystemCopy,
                targetDescription: "\(scope)范围Skills目录中的独立新目录",
                protectedSurfaces: ["不覆盖同名Skill", "不修改其他Skill", "不写Provider配置"],
                requiredEvidence: ["SKILL.md", "锁定版本或Commit", "文件清单", "触发夹具"]
            )
        case .plugin:
            return CapabilityInstallTarget(
                packageType: type,
                executionMode: .officialConfirmationFlow,
                targetDescription: "Codex官方Plugin详情和安装流程",
                protectedSurfaces: ["不模拟绕过官方确认", "不代授连接器权限", "不冒充套餐可用"],
                requiredEvidence: ["官方详情页", "当前Agent可见入口", "用户确认", "启用和授权状态"]
            )
        case .mcp:
            return CapabilityInstallTarget(
                packageType: type,
                executionMode: .configurationAdapter,
                targetDescription: "目标Agent受支持的MCP配置段",
                protectedSurfaces: ["保留其他MCP", "Key不进预览日志", "不覆盖Provider和项目配置"],
                requiredEvidence: ["服务器命令和版本", "运行时", "环境变量", "工具枚举", "只读调用"]
            )
        case .hook, .routingRule:
            return CapabilityInstallTarget(
                packageType: type,
                executionMode: .incrementalTextPatch,
                targetDescription: "\(scope)范围Hook、AGENTS.md或项目路由的最小增量",
                protectedSurfaces: ["先备份", "不覆盖已有规则", "不扩大作用域"],
                requiredEvidence: ["差异", "作用域", "优先级", "允许样本", "阻断样本"]
            )
        case .bundle:
            return CapabilityInstallTarget(
                packageType: type,
                executionMode: .compositeTransaction,
                targetDescription: "按子组件拆分后的复合事务",
                protectedSurfaces: ["任一子项失败整体回滚", "不得绕过各子组件审批"],
                requiredEvidence: ["子组件清单", "逐项权限", "统一恢复点", "逐项验证"]
            )
        }
    }
}

struct CapabilityInstallAuthorization: Codable, Equatable {
    let planID: String
    let packageID: String
    let approvedTarget: CapabilityInstallTarget
    let approvedFiles: [String]
    let approvedCommands: [String]
    let approvedAt: Date
    let userConfirmed: Bool
}

enum CapabilityComponentTransactionState: String, Codable {
    case awaitingConfirmation
    case restorePointCreated
    case installed
    case agentRefreshed
    case capabilityVerified
    case committed
    case rolledBack
    case manualRecoveryRequired
}

struct CapabilityInstalledManifest: Codable, Equatable {
    let schemaVersion: Int
    let transactionID: String
    let planID: String
    let packageID: String
    let packageType: CapabilityPackageType
    let createdPaths: [String]
    let modifiedPaths: [String]
    let preservedUserDataPaths: [String]
    let installedAt: Date
    let verifiedAt: Date?
    let createdFileSHA256: [String: String]?

    init(
        schemaVersion: Int,
        transactionID: String,
        planID: String,
        packageID: String,
        packageType: CapabilityPackageType,
        createdPaths: [String],
        modifiedPaths: [String],
        preservedUserDataPaths: [String],
        installedAt: Date,
        verifiedAt: Date?,
        createdFileSHA256: [String: String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.planID = planID
        self.packageID = packageID
        self.packageType = packageType
        self.createdPaths = createdPaths
        self.modifiedPaths = modifiedPaths
        self.preservedUserDataPaths = preservedUserDataPaths
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
        self.createdFileSHA256 = createdFileSHA256
    }
}

struct CapabilityComponentTransaction: Identifiable, Codable, Equatable {
    let id: String
    let planID: String
    let packageID: String
    let packageType: CapabilityPackageType
    var state: CapabilityComponentTransactionState
    let startedAt: Date
    var updatedAt: Date
    var sanitizedMessage: String
    var manifest: CapabilityInstalledManifest?
}

enum CapabilityComponentPhase: String, CaseIterable {
    case restorePoint
    case install
    case refresh
    case verify
    case commit
}

enum CapabilityComponentTransactionError: LocalizedError {
    case authorizationMissing
    case authorizationMismatch
    case highRiskBlocked
    case adapterFailed(CapabilityComponentPhase)

    var errorDescription: String? {
        switch self {
        case .authorizationMissing: return "能力安装尚未取得用户确认"
        case .authorizationMismatch: return "安装计划、组件或写入面与用户确认不一致"
        case .highRiskBlocked: return "高风险能力包禁止自动安装"
        case let .adapterFailed(phase): return "能力安装在\(phase.rawValue)阶段失败，已请求回滚"
        }
    }
}

protocol CapabilityComponentAdapter {
    func createRestorePoint(
        transactionID: String,
        plan: CapabilityInstallationPlan,
        target: CapabilityInstallTarget
    ) throws
    func install(
        transactionID: String,
        plan: CapabilityInstallationPlan,
        packageType: CapabilityPackageType,
        target: CapabilityInstallTarget
    ) throws -> CapabilityInstalledManifest
    func refreshAgent(packageType: CapabilityPackageType) throws
    func verifyCapability(
        packageType: CapabilityPackageType,
        manifest: CapabilityInstalledManifest
    ) throws
    func rollback(
        transactionID: String,
        manifest: CapabilityInstalledManifest?
    ) throws
    func uninstall(manifest: CapabilityInstalledManifest) throws
}

enum CapabilityComponentTransactionEngine {
    static func execute(
        plan: CapabilityInstallationPlan,
        packageType: CapabilityPackageType,
        review: CapabilitySecurityReview,
        authorization: CapabilityInstallAuthorization,
        adapter: CapabilityComponentAdapter,
        transactionID: String = UUID().uuidString,
        now: Date = Date(),
        fault: CapabilityComponentPhase? = nil
    ) throws -> CapabilityComponentTransaction {
        guard authorization.userConfirmed else {
            throw CapabilityComponentTransactionError.authorizationMissing
        }
        let target = CapabilityInstallTargetResolver.target(type: packageType)
        guard authorization.planID == plan.id,
              authorization.packageID == plan.packageID,
              authorization.approvedTarget == target,
              authorization.approvedFiles == plan.expectedFiles,
              authorization.approvedCommands == plan.commands else {
            throw CapabilityComponentTransactionError.authorizationMismatch
        }
        guard review.riskLevel != .high, review.riskLevel != .unknown else {
            throw CapabilityComponentTransactionError.highRiskBlocked
        }
        var transaction = CapabilityComponentTransaction(
            id: transactionID,
            planID: plan.id,
            packageID: plan.packageID,
            packageType: packageType,
            state: .awaitingConfirmation,
            startedAt: now,
            updatedAt: now,
            sanitizedMessage: "用户已确认精确写入面；尚未写入",
            manifest: nil
        )
        do {
            try inject(.restorePoint, fault)
            try adapter.createRestorePoint(
                transactionID: transactionID,
                plan: plan,
                target: target
            )
            transition(
                &transaction,
                to: .restorePointCreated,
                "恢复点已建立"
            )
            try inject(.install, fault)
            let manifest = try adapter.install(
                transactionID: transactionID,
                plan: plan,
                packageType: packageType,
                target: target
            )
            transaction.manifest = manifest
            transition(&transaction, to: .installed, "目标组件已写入，等待Agent刷新")
            try inject(.refresh, fault)
            try adapter.refreshAgent(packageType: packageType)
            transition(&transaction, to: .agentRefreshed, "Agent已刷新，等待能力夹具")
            try inject(.verify, fault)
            try adapter.verifyCapability(
                packageType: packageType,
                manifest: manifest
            )
            transition(&transaction, to: .capabilityVerified, "能力夹具已通过")
            try inject(.commit, fault)
            transition(&transaction, to: .committed, "安装事务已提交")
            return transaction
        } catch {
            do {
                try adapter.rollback(
                    transactionID: transactionID,
                    manifest: transaction.manifest
                )
                transition(&transaction, to: .rolledBack, "安装失败；已恢复安装前状态")
            } catch {
                transition(
                    &transaction,
                    to: .manualRecoveryRequired,
                    "自动回滚失败；必须按恢复点人工处理"
                )
            }
            throw error
        }
    }

    static func uninstall(
        manifest: CapabilityInstalledManifest,
        adapter: CapabilityComponentAdapter
    ) throws {
        try adapter.uninstall(manifest: manifest)
    }

    private static func inject(
        _ phase: CapabilityComponentPhase,
        _ fault: CapabilityComponentPhase?
    ) throws {
        if fault == phase {
            throw CapabilityComponentTransactionError.adapterFailed(phase)
        }
    }

    private static func transition(
        _ transaction: inout CapabilityComponentTransaction,
        to state: CapabilityComponentTransactionState,
        _ message: String
    ) {
        transaction.state = state
        transaction.updatedAt = Date()
        transaction.sanitizedMessage = message
    }
}
