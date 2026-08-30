import AppKit
import CryptoKit
import Foundation
import Security

enum SupportedOperatingSystem: String, Codable {
    case macOS
    case windows
}

enum SupportedArchitecture: String, Codable {
    case arm64
    case x86_64
}

enum InstallationPackageKind: String, Codable {
    case dmg
    case pkg
    case app
    case msix
    case exe
}

enum PackageSignatureRequirement: String, Codable {
    case developerID
    case authenticode
    case none
}

enum CompatibilityAvailability: String, Codable {
    case available
    case deferred
    case revoked
}

struct PlatformCompatibilityManifest: Identifiable, Codable, Equatable {
    let id: String
    let productName: String
    let productVersion: String
    let operatingSystem: SupportedOperatingSystem
    let minimumVersion: String
    let maximumVerifiedVersion: String?
    let minimumBuild: String?
    let maximumVerifiedBuild: String?
    let architectures: [SupportedArchitecture]
    let packageKind: InstallationPackageKind
    let downloadURL: URL?
    let byteCount: Int64?
    let sha256: String?
    let signatureRequirement: PackageSignatureRequirement
    let publisher: String?
    let teamID: String?
    let bundleIdentifier: String?
    let windowsInstallIdentifier: String?
    let requiredDiskBytes: Int64
    let prerequisites: [SystemPrerequisite]
    let availability: CompatibilityAvailability
    let verifiedAt: Date?
    let evidenceURLs: [URL]
}

struct SystemPrerequisite: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let reason: String
    let officialSource: URL
    let requiredVersion: String?
    let requiresAdministrator: Bool
    let requiresRestart: Bool
    let expectedDiskBytes: Int64?
}

struct HostPlatformFacts: Codable, Equatable {
    let operatingSystem: SupportedOperatingSystem
    let version: String
    let build: String?
    let architecture: SupportedArchitecture
    let availableDiskBytes: Int64?
    let canRequestAdministratorAuthorization: Bool
    let enterprisePolicyBlocked: Bool
    let networkReachable: Bool?
}

enum InstallationAgentKind: String, Codable {
    case codexDesktop
    case claudeDesktop
    case cherryStudio
}

enum InstalledProductState: String, Codable {
    case notInstalled
    case installed
    case updateRequired
    case running
    case unknown
}

enum LoginVerificationState: String, Codable {
    case loggedIn
    case loggedOut
    case unknown
}

struct AgentInstallation: Identifiable, Codable, Equatable {
    let id: String
    let agent: InstallationAgentKind
    let bundleIdentifier: String?
    let windowsInstallIdentifier: String?
    let installPath: String?
    let version: String?
    let embeddedCLIVersion: String?
    let state: InstalledProductState
    let loginState: LoginVerificationState
    let signatureVerified: Bool?
    let publisher: String?
    let supportedAccessRoutes: [String]
    let officialDownloadURL: URL
}

enum InstallationAutomationLevel: String, Codable {
    case fullyAutomatic = "全自动"
    case semiAutomatic = "半自动"
    case guided = "引导安装"
    case blocked = "阻止"
}

enum CompatibilityBlocker: String, Codable {
    case unavailableProduct
    case operatingSystem
    case systemVersion
    case systemBuild
    case architecture
    case diskSpace
    case enterprisePolicy
    case signatureEvidence
    case hashEvidence
    case administratorAuthorization
    case network
}

struct PlatformCompatibilityResult: Codable, Equatable {
    let compatible: Bool
    let automationLevel: InstallationAutomationLevel
    let blockers: [CompatibilityBlocker]
    let missingPrerequisites: [SystemPrerequisite]
    let explanation: String
}

enum PlatformCompatibilityEvaluator {
    static func evaluate(
        manifest: PlatformCompatibilityManifest,
        host: HostPlatformFacts,
        installedPrerequisiteIDs: Set<String>,
        supportsSilentInstall: Bool
    ) -> PlatformCompatibilityResult {
        var blockers: [CompatibilityBlocker] = []
        if manifest.availability != .available { blockers.append(.unavailableProduct) }
        if manifest.operatingSystem != host.operatingSystem { blockers.append(.operatingSystem) }
        if compareVersions(host.version, manifest.minimumVersion) == .orderedAscending {
            blockers.append(.systemVersion)
        }
        if let maximum = manifest.maximumVerifiedVersion,
           compareVersions(host.version, maximum) == .orderedDescending {
            blockers.append(.systemVersion)
        }
        if let minimumBuild = manifest.minimumBuild,
           let build = host.build,
           compareVersions(build, minimumBuild) == .orderedAscending {
            blockers.append(.systemBuild)
        }
        if let maximumBuild = manifest.maximumVerifiedBuild,
           let build = host.build,
           compareVersions(build, maximumBuild) == .orderedDescending {
            blockers.append(.systemBuild)
        }
        if !manifest.architectures.contains(host.architecture) { blockers.append(.architecture) }
        if let available = host.availableDiskBytes, available < manifest.requiredDiskBytes {
            blockers.append(.diskSpace)
        }
        if host.enterprisePolicyBlocked { blockers.append(.enterprisePolicy) }
        if host.networkReachable == false { blockers.append(.network) }
        if manifest.signatureRequirement != .none,
           manifest.publisher == nil,
           manifest.teamID == nil {
            blockers.append(.signatureEvidence)
        }
        if manifest.downloadURL != nil, manifest.sha256 == nil {
            blockers.append(.hashEvidence)
        }
        let missing = manifest.prerequisites.filter { !installedPrerequisiteIDs.contains($0.id) }
        if missing.contains(where: \.requiresAdministrator),
           !host.canRequestAdministratorAuthorization {
            blockers.append(.administratorAuthorization)
        }
        let uniqueBlockers = Array(Set(blockers)).sorted { $0.rawValue < $1.rawValue }
        if !uniqueBlockers.isEmpty {
            return PlatformCompatibilityResult(
                compatible: false,
                automationLevel: .blocked,
                blockers: uniqueBlockers,
                missingPrerequisites: missing,
                explanation: blockerExplanation(uniqueBlockers)
            )
        }
        let level: InstallationAutomationLevel
        if supportsSilentInstall, missing.isEmpty {
            level = .fullyAutomatic
        } else if manifest.downloadURL != nil {
            level = .semiAutomatic
        } else {
            level = .guided
        }
        return PlatformCompatibilityResult(
            compatible: true,
            automationLevel: level,
            blockers: [],
            missingPrerequisites: missing,
            explanation: missing.isEmpty
                ? "当前系统组合有明确兼容证据。"
                : "先逐项安装目标组件明确需要的前置项；每项单独确认。"
        )
    }

    static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        let leftParts = left.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let rightParts = right.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let lhs = index < leftParts.count ? leftParts[index] : 0
            let rhs = index < rightParts.count ? rightParts[index] : 0
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func blockerExplanation(_ blockers: [CompatibilityBlocker]) -> String {
        let labels: [CompatibilityBlocker: String] = [
            .unavailableProduct: "该平台安装包尚未开放或已撤销",
            .operatingSystem: "安装包与操作系统不匹配",
            .systemVersion: "系统版本不在已验证范围",
            .systemBuild: "系统Build不在已验证范围",
            .architecture: "CPU架构不匹配",
            .diskSpace: "可用磁盘空间不足",
            .enterprisePolicy: "企业策略阻止安装",
            .signatureEvidence: "缺少签名发布者证据",
            .hashEvidence: "缺少安装包SHA-256",
            .administratorAuthorization: "无法请求必要的系统管理员授权",
            .network: "官方下载地址当前不可达",
        ]
        return blockers.compactMap { labels[$0] }.joined(separator: "；")
    }
}

enum InstallationTransactionState: String, Codable {
    case planned
    case awaitingUserConfirmation
    case downloading
    case verifying
    case installingPrerequisite
    case openingInstaller
    case awaitingLogin
    case verifyingInstallation
    case committed
    case rolledBack
    case manualRecoveryRequired
}

struct AgentInstallationTransaction: Identifiable, Codable, Equatable {
    let id: String
    let manifestID: String
    var state: InstallationTransactionState
    let startedAt: Date
    var updatedAt: Date
    var temporaryDownloadPaths: [String]
    var installedPrerequisiteIDs: [String]
    var sanitizedMessage: String
}

struct AgentInstallationJournalStore {
    let fileURL: URL

    func load() throws -> [AgentInstallationTransaction] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [AgentInstallationTransaction].self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ transactions: [AgentInstallationTransaction]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transactions).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func upsert(_ transaction: AgentInstallationTransaction) throws {
        var values = try load()
        values.removeAll { $0.id == transaction.id || $0.manifestID == transaction.manifestID }
        values.append(transaction)
        try save(values)
    }
}

enum InstallerDownloadError: LocalizedError {
    case missingDownloadEvidence
    case insecureURL
    case invalidHTTPStatus(Int)
    case responseNotHTTP
    case sourceNotRegularFile
    case unsafeDownloadDirectory
    case fileTooLarge(Int64)
    case byteCountMismatch(expected: Int64, actual: Int64)
    case sha256Mismatch
    case signatureVerificationFailed
    case signatureTeamMismatch

    var errorDescription: String? {
        switch self {
        case .missingDownloadEvidence:
            return "安装清单缺少直接下载地址或SHA-256，不能自动下载"
        case .insecureURL:
            return "安装包地址或最终重定向地址不是无凭据HTTPS，已阻止"
        case let .invalidHTTPStatus(status):
            return "安装包下载返回HTTP \(status)，未保存文件"
        case .responseNotHTTP:
            return "安装包下载没有返回可核对的HTTPS响应"
        case .sourceNotRegularFile:
            return "下载结果不是普通文件，已清理"
        case .unsafeDownloadDirectory:
            return "安装包临时目录不是助手自己的普通目录，已阻止"
        case let .fileTooLarge(size):
            return "安装包超过安全大小上限（\(size)字节），已清理"
        case let .byteCountMismatch(expected, actual):
            return "安装包大小与清单不一致（预期\(expected)，实际\(actual)），已清理"
        case .sha256Mismatch:
            return "安装包SHA-256与清单不一致，已清理"
        case .signatureVerificationFailed:
            return "安装包签名未通过，已清理"
        case .signatureTeamMismatch:
            return "安装包签名团队与清单不一致，已清理"
        }
    }
}

struct InstallerSignatureEvidence: Codable, Equatable {
    let verified: Bool
    let teamID: String?
}

struct InstallerPackageSignatureVerifier {
    let verify:
        @Sendable (
            URL,
            PlatformCompatibilityManifest
        ) throws -> InstallerSignatureEvidence

    static let live = InstallerPackageSignatureVerifier {
        url,
        manifest in
        if manifest.signatureRequirement == .none {
            return InstallerSignatureEvidence(
                verified: true,
                teamID: nil
            )
        }
        guard manifest.signatureRequirement == .developerID else {
            throw InstallerDownloadError
                .signatureVerificationFailed
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        ) == errSecSuccess,
        let code,
        SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            throw InstallerDownloadError
                .signatureVerificationFailed
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [String: Any] else {
            throw InstallerDownloadError
                .signatureVerificationFailed
        }
        let teamID = dictionary[
            kSecCodeInfoTeamIdentifier as String
        ] as? String
        if let expectedTeam = manifest.teamID,
           teamID != expectedTeam {
            throw InstallerDownloadError
                .signatureTeamMismatch
        }
        return InstallerSignatureEvidence(
            verified: true,
            teamID: teamID
        )
    }
}

struct VerifiedInstallerArtifact: Codable, Equatable {
    let manifestID: String
    let filePath: String
    let byteCount: Int64
    let sha256: String
    let finalURL: URL
    let signature: InstallerSignatureEvidence
}

struct InstallerDownloadTransport {
    let perform:
        @Sendable (URLRequest, Int64) async throws
            -> (URL, URLResponse)

    static let live = InstallerDownloadTransport { request, maximumBytes in
        try await RelaySecureHTTPClient.download(
            for: request,
            source: .catalog,
            maximumBytes: maximumBytes
        )
    }
}

struct VerifiedInstallerDownloadService {
    static let maximumPackageBytes: Int64 = 2_147_483_648

    let rootURL: URL
    let transport: InstallerDownloadTransport
    let signatureVerifier: InstallerPackageSignatureVerifier
    let maximumBytes: Int64

    init(
        rootURL: URL,
        transport: InstallerDownloadTransport = .live,
        signatureVerifier:
            InstallerPackageSignatureVerifier = .live,
        maximumBytes: Int64 = maximumPackageBytes
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.transport = transport
        self.signatureVerifier = signatureVerifier
        self.maximumBytes = maximumBytes
    }

    func download(
        manifest: PlatformCompatibilityManifest
    ) async throws -> VerifiedInstallerArtifact {
        guard let downloadURL = manifest.downloadURL,
              let expectedHash = normalizedSHA256(manifest.sha256) else {
            throw InstallerDownloadError.missingDownloadEvidence
        }
        guard secureHTTPS(downloadURL) else {
            throw InstallerDownloadError.insecureURL
        }
        if let expectedBytes = manifest.byteCount,
           expectedBytes > maximumBytes {
            throw InstallerDownloadError.fileTooLarge(expectedBytes)
        }
        var request = URLRequest(url: downloadURL, timeoutInterval: 300)
        request.httpMethod = "GET"
        request.setValue(
            AppReleaseMetadata.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        let (temporaryURL, response) = try await transport.perform(
            request,
            maximumBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw InstallerDownloadError.responseNotHTTP
        }
        guard http.statusCode == 200 else {
            throw InstallerDownloadError.invalidHTTPStatus(http.statusCode)
        }
        guard let finalURL = http.url, secureHTTPS(finalURL) else {
            throw InstallerDownloadError.insecureURL
        }

        try prepareRoot()
        let artifactURL = rootURL.appendingPathComponent(
            "installer-\(UUID().uuidString).\(manifest.packageKind.rawValue)",
            isDirectory: false
        )
        do {
            let sourceValues = try temporaryURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true else {
                throw InstallerDownloadError.sourceNotRegularFile
            }
            if let sourceSize = sourceValues.fileSize,
               Int64(sourceSize) > maximumBytes {
                throw InstallerDownloadError.fileTooLarge(
                    Int64(sourceSize)
                )
            }
            try FileManager.default.copyItem(
                at: temporaryURL,
                to: artifactURL
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: artifactURL.path
            )
            let byteCount = try regularFileSize(artifactURL)
            guard byteCount <= maximumBytes else {
                throw InstallerDownloadError.fileTooLarge(byteCount)
            }
            if let expectedBytes = manifest.byteCount,
               byteCount != expectedBytes {
                throw InstallerDownloadError.byteCountMismatch(
                    expected: expectedBytes,
                    actual: byteCount
                )
            }
            let actualHash = try fileSHA256(artifactURL)
            guard actualHash == expectedHash else {
                throw InstallerDownloadError.sha256Mismatch
            }
            let signature = try signatureVerifier.verify(
                artifactURL,
                manifest
            )
            guard signature.verified else {
                throw InstallerDownloadError
                    .signatureVerificationFailed
            }
            return VerifiedInstallerArtifact(
                manifestID: manifest.id,
                filePath: artifactURL.path,
                byteCount: byteCount,
                sha256: actualHash,
                finalURL: finalURL,
                signature: signature
            )
        } catch {
            try? FileManager.default.removeItem(at: artifactURL)
            throw error
        }
    }

    func remove(_ artifact: VerifiedInstallerArtifact) throws {
        let candidate = URL(
            fileURLWithPath: artifact.filePath
        ).standardizedFileURL
        guard candidate.deletingLastPathComponent() == rootURL else {
            throw InstallerDownloadError.sourceNotRegularFile
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let allowedBases = [
            FileManager.default.temporaryDirectory,
            FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first,
        ].compactMap { $0?.resolvingSymlinksInPath() }
        guard allowedBases.contains(where: {
            resolvedRoot.path.hasPrefix(
                $0.path.hasSuffix("/")
                    ? $0.path
                    : $0.path + "/"
            )
        }) else {
            throw InstallerDownloadError
                .unsafeDownloadDirectory
        }
        let values = try rootURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw InstallerDownloadError
                .unsafeDownloadDirectory
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func regularFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize else {
            throw InstallerDownloadError.sourceNotRegularFile
        }
        return Int64(size)
    }

    private func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    private func secureHTTPS(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
    }
}

enum GuidedAgentInstallationWorkflow {
    static func begin(manifestID: String) -> AgentInstallationTransaction {
        AgentInstallationTransaction(
            id: UUID().uuidString,
            manifestID: manifestID,
            state: .awaitingUserConfirmation,
            startedAt: Date(),
            updatedAt: Date(),
            temporaryDownloadPaths: [],
            installedPrerequisiteIDs: [],
            sanitizedMessage: "等待用户确认打开官方安装入口；尚未下载或安装"
        )
    }

    static func openedOfficialInstaller(
        _ transaction: AgentInstallationTransaction
    ) -> AgentInstallationTransaction {
        transition(
            transaction,
            to: .openingInstaller,
            message: "已打开官方入口；请完成系统授权、协议和安装向导"
        )
    }

    static func downloadStarted(
        _ transaction: AgentInstallationTransaction
    ) -> AgentInstallationTransaction {
        transition(
            transaction,
            to: .downloading,
            message: "正在从清单固定的HTTPS地址下载；不发送账号、Key或Cookie"
        )
    }

    static func downloadVerified(
        _ transaction: AgentInstallationTransaction,
        artifact: VerifiedInstallerArtifact
    ) -> AgentInstallationTransaction {
        var copy = transition(
            transaction,
            to: .openingInstaller,
            message: "安装包大小和SHA-256已通过；等待用户确认打开官方安装器"
        )
        copy.temporaryDownloadPaths = [artifact.filePath]
        return copy
    }

    static func downloadFailed(
        _ transaction: AgentInstallationTransaction,
        error: Error
    ) -> AgentInstallationTransaction {
        let safeReason: String
        if let known = error as? InstallerDownloadError {
            safeReason = known.localizedDescription
        } else if let network = error as? RelaySecureNetworkError {
            safeReason = network.localizedDescription
        } else {
            safeReason = "系统文件或网络错误；详细路径和响应未写入事务记录"
        }
        var copy = transition(
            transaction,
            to: .rolledBack,
            message: "安装包下载或校验失败，临时文件已清理：\(safeReason)"
        )
        copy.temporaryDownloadPaths = []
        return copy
    }

    static func rechecked(
        _ transaction: AgentInstallationTransaction,
        installation: AgentInstallation
    ) -> AgentInstallationTransaction {
        if installation.state == .notInstalled {
            return transition(
                transaction,
                to: .openingInstaller,
                message: "尚未检测到安装；不会擅自覆盖、降级或卸载现有版本"
            )
        }
        guard installation.signatureVerified == true else {
            return transition(
                transaction,
                to: .manualRecoveryRequired,
                message: "已发现应用，但代码签名未通过；停止登录和请求验证"
            )
        }
        return transition(
            transaction,
            to: .awaitingLogin,
            message: "安装与签名已通过；请在Agent内自行完成协议、账号、密码和验证码"
        )
    }

    static func loginCompleted(
        _ transaction: AgentInstallationTransaction
    ) -> AgentInstallationTransaction {
        transition(
            transaction,
            to: .verifyingInstallation,
            message: "等待最小官方请求；成功只证明登录通路可用，不证明套餐或余额"
        )
    }

    static func completedProbe(
        _ transaction: AgentInstallationTransaction,
        result: OfficialAccountProbeResult
    ) -> AgentInstallationTransaction {
        guard result.category == .availableUnknownPlan else {
            return transition(
                transaction,
                to: .manualRecoveryRequired,
                message: result.message
            )
        }
        return transition(
            transaction,
            to: .committed,
            message: result.message
        )
    }

    private static func transition(
        _ transaction: AgentInstallationTransaction,
        to state: InstallationTransactionState,
        message: String
    ) -> AgentInstallationTransaction {
        var copy = transaction
        copy.state = state
        copy.updatedAt = Date()
        copy.sanitizedMessage = message
        return copy
    }
}

enum OfficialAccountProbeCategory: String, Codable {
    case availableUnknownPlan
    case loginExpired
    case modelNotAllowed
    case regionalOrWorkspaceRestriction
    case quotaOrRateLimit
    case network
    case serviceIncident
    case unknown
}

struct OfficialAccountProbeResult: Codable, Equatable {
    let category: OfficialAccountProbeCategory
    let message: String
    let provesSubscription: Bool
    let provesRemainingQuota: Bool
}

enum OfficialAccountProbeClassifier {
    static func classify(
        httpStatus: Int?,
        errorCode: String?,
        networkFailure: Bool,
        serviceIncidentConfirmed: Bool,
        explicitQuotaEvidence: Bool
    ) -> OfficialAccountProbeResult {
        let code = errorCode?.lowercased() ?? ""
        let category: OfficialAccountProbeCategory
        let message: String
        if networkFailure {
            category = .network
            message = "网络、DNS、TLS或代理连接失败，请进入网络诊断。"
        } else if serviceIncidentConfirmed {
            category = .serviceIncident
            message = "官方服务当前异常；保留官方模式，不自动切换中转。"
        } else if httpStatus == 401 || code.contains("login") || code.contains("unauthorized") {
            category = .loginExpired
            message = "官方登录已失效，请在Agent中重新登录。"
        } else if httpStatus == 403 || code.contains("model_not_allowed") {
            category = .modelNotAllowed
            message = "当前账号、工作区或地区没有该模型权限；不能据此判断额度。"
        } else if httpStatus == 429, explicitQuotaEvidence {
            category = .quotaOrRateLimit
            message = "证据表明当前请求受额度或速率限制，可添加中转配置。"
        } else if httpStatus == 200 {
            category = .availableUnknownPlan
            message = "官方登录通路当前可用；套餐和剩余额度未知。"
        } else {
            category = .unknown
            message = "暂时无法分类；保留脱敏错误，不猜测原因。"
        }
        return OfficialAccountProbeResult(
            category: category,
            message: message,
            provesSubscription: false,
            provesRemainingQuota: false
        )
    }
}

enum CapabilityHealthState: String, Codable {
    case passed = "通过"
    case unverified = "未验证"
    case unsupported = "不支持"
    case separateAccountRequired = "需要单独账号"
    case planOrRegionRestricted = "受套餐或地区限制"
}

struct CapabilityHealthItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let state: CapabilityHealthState
    let evidence: String?
}

enum HostPlatformInspector {
    static func inspectMac() -> HostPlatformFacts {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionText = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
        let architecture: SupportedArchitecture = .arm64
        #else
        let architecture: SupportedArchitecture = .x86_64
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        let capacity = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let systemVersion = NSDictionary(
            contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist"
        )
        return HostPlatformFacts(
            operatingSystem: .macOS,
            version: versionText,
            build: systemVersion?["ProductBuildVersion"] as? String,
            architecture: architecture,
            availableDiskBytes: capacity,
            canRequestAdministratorAuthorization: true,
            enterprisePolicyBlocked: false,
            networkReachable: nil
        )
    }
}

enum MacAgentInstallationInspector {
    static func inspect(
        agent: InstallationAgentKind,
        bundleIdentifier: String,
        officialDownloadURL: URL,
        supportedAccessRoutes: [String]
    ) -> AgentInstallation {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return AgentInstallation(
                id: bundleIdentifier,
                agent: agent,
                bundleIdentifier: bundleIdentifier,
                windowsInstallIdentifier: nil,
                installPath: nil,
                version: nil,
                embeddedCLIVersion: nil,
                state: .notInstalled,
                loginState: .unknown,
                signatureVerified: nil,
                publisher: nil,
                supportedAccessRoutes: supportedAccessRoutes,
                officialDownloadURL: officialDownloadURL
            )
        }
        let bundle = Bundle(url: url)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
        return AgentInstallation(
            id: bundleIdentifier,
            agent: agent,
            bundleIdentifier: bundleIdentifier,
            windowsInstallIdentifier: nil,
            installPath: url.path,
            version: version,
            embeddedCLIVersion: nil,
            state: running ? .running : .installed,
            loginState: .unknown,
            signatureVerified: verifyCodeSignature(url),
            publisher: signingTeamIdentifier(url),
            supportedAccessRoutes: supportedAccessRoutes,
            officialDownloadURL: officialDownloadURL
        )
    }

    private static func verifyCodeSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        ) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: 0),
            nil
        ) == errSecSuccess
    }

    private static func signingTeamIdentifier(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        ) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

enum OfficialAgentCatalog {
    static let codexDownload = URL(string: "https://chatgpt.com/download/")!
    static let claudeDownload = URL(string: "https://claude.ai/download")!
    static let cherryDownload = URL(string: "https://cherry-ai.com")!
}

enum CodexInstallationCenterState: String, Codable {
    case incompatible
    case permissionBlocked
    case networkBlocked
    case notInstalled
    case installedNeedsLogin
    case officialReady
    case unverifiedInstallation
}

struct CodexInstallationGuidance: Codable, Equatable {
    let state: CodexInstallationCenterState
    let title: String
    let detail: String
    let steps: [String]
    let nextAction: String
    let officialSource: URL

    var canOpenOfficialSource: Bool {
        state == .notInstalled
    }

    var canOpenInstalledCodex: Bool {
        state == .installedNeedsLogin || state == .officialReady
    }
}

enum CodexInstallationGuidanceEvaluator {
    static let minimumMacOSVersion = "15.0"

    static func evaluate(
        host: HostPlatformFacts,
        installation: AgentInstallation,
        endpointState: InstallationDiagnosticState? = nil,
        officialConnectionVerified: Bool = false
    ) -> CodexInstallationGuidance {
        let source = installation.officialDownloadURL
        let installSteps = [
            "确认地址属于官方来源，再由你打开下载页面。",
            "按官方页面完成下载和安装；系统要求授权时由你决定。",
            "打开 Codex，自行完成账号、密码和验证码登录。",
            "回到助手重新检测安装，再执行一次官方连接检查。",
        ]

        guard host.operatingSystem == .macOS,
              host.architecture == .arm64,
              PlatformCompatibilityEvaluator.compareVersions(
                host.version,
                minimumMacOSVersion
              ) != .orderedAscending else {
            return CodexInstallationGuidance(
                state: .incompatible,
                title: "当前电脑不在已验证范围",
                detail: "本阶段只验证 macOS 15 或更高版本的 Apple 芯片 Mac；不会提供不匹配安装包。",
                steps: [],
                nextAction: "升级到受支持的 macOS Apple 芯片电脑后重新检测。Intel 和其他平台需等待独立适配。",
                officialSource: source
            )
        }

        if installation.state == .notInstalled,
           !host.canRequestAdministratorAuthorization {
            return CodexInstallationGuidance(
                state: .permissionBlocked,
                title: "当前账户可能无权完成安装",
                detail: "助手不会绕过 macOS 管理员授权或企业策略。",
                steps: installSteps,
                nextAction: "在系统设置确认安装权限，或联系设备管理员；获得权限后重新检测。",
                officialSource: source
            )
        }

        if installation.state == .notInstalled,
           host.enterprisePolicyBlocked {
            return CodexInstallationGuidance(
                state: .permissionBlocked,
                title: "设备策略阻止安装",
                detail: "检测到明确的设备管理阻止证据，助手已停止打开安装来源。",
                steps: installSteps,
                nextAction: "联系设备管理员解除对应策略后重新检测；不要尝试绕过策略。",
                officialSource: source
            )
        }

        if installation.state == .notInstalled,
           host.networkReachable == false || endpointState == .failed {
            return CodexInstallationGuidance(
                state: .networkBlocked,
                title: "官方安装来源当前不可达",
                detail: "网络、DNS、TLS或代理检查失败；未下载任何文件。",
                steps: installSteps,
                nextAction: "检查网络、系统时间、代理或证书后重新检查；不要改用非官方镜像。",
                officialSource: source
            )
        }

        if installation.state == .notInstalled {
            return CodexInstallationGuidance(
                state: .notInstalled,
                title: "尚未安装 Codex",
                detail: "可以继续使用官方 Codex，不需要先配置中转。助手只会在你再次确认后打开官方来源。",
                steps: installSteps,
                nextAction: "先检查官方来源是否可达，再确认打开官方安装页面。",
                officialSource: source
            )
        }

        guard installation.signatureVerified != false else {
            return CodexInstallationGuidance(
                state: .unverifiedInstallation,
                title: "已找到 Codex，但签名验证失败",
                detail: "助手不会继续登录检查或把该应用视为可信官方安装。",
                steps: [],
                nextAction: "从 Finder 查看应用来源；移除可疑副本后，仅从官方来源重新安装。",
                officialSource: source
            )
        }

        if officialConnectionVerified {
            return CodexInstallationGuidance(
                state: .officialReady,
                title: "Codex 官方连接可用",
                detail: "已安装且最近一次官方连接检查通过。没有中转也可以直接继续使用官方 Codex。",
                steps: [],
                nextAction: "直接打开 Codex 继续使用；只有确实需要时再添加中转。",
                officialSource: source
            )
        }

        return CodexInstallationGuidance(
            state: .installedNeedsLogin,
            title: "已安装 Codex，等待登录后验证",
            detail: "安装已检测到。助手不会读取密码、验证码，也不会把安装成功当作登录成功。",
            steps: [
                "打开 Codex，自行完成官方登录。",
                "回到助手，确认执行一次官方连接检查。",
                "检查通过后即可继续官方；中转不是必需项。",
            ],
            nextAction: "完成登录后点击“检测官方连接”。",
            officialSource: source
        )
    }
}

enum InstallationDiagnosticState: String, Codable {
    case passed = "通过"
    case warning = "需核对"
    case failed = "失败"
    case unverified = "未验证"
}

struct InstallationEndpointDiagnostic: Identifiable, Codable, Equatable {
    var id: String { requestedURL.absoluteString }
    let requestedURL: URL
    let finalURL: URL?
    let state: InstallationDiagnosticState
    let httpStatus: Int?
    let detail: String
}

struct InstallationEnvironmentEvidence: Codable, Equatable {
    let proxyConfigured: Bool
    let proxySourceLabels: [String]
    let managedPreferencesDirectoryPresent: Bool
    let canRequestAdministratorAuthorization: Bool
}

struct InstallationDiagnosticReport: Codable, Equatable {
    let generatedAt: Date
    let endpoints: [InstallationEndpointDiagnostic]
    let environment: InstallationEnvironmentEvidence
}

enum InstallationEnvironmentInspector {
    static func inspect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        proxyDictionary: [AnyHashable: Any]? = URLSessionConfiguration.default.connectionProxyDictionary
    ) -> InstallationEnvironmentEvidence {
        let proxyEnvironmentKeys = [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy",
        ]
        let environmentSources = proxyEnvironmentKeys.filter {
            environment[$0]?.isEmpty == false
        }.map { "环境变量\($0)" }
        let systemProxy = proxyDictionary?.isEmpty == false
            ? ["系统网络代理（值不显示）"] : []
        return InstallationEnvironmentEvidence(
            proxyConfigured: !environmentSources.isEmpty || !systemProxy.isEmpty,
            proxySourceLabels: environmentSources + systemProxy,
            managedPreferencesDirectoryPresent: FileManager.default.fileExists(
                atPath: "/Library/Managed Preferences"
            ),
            canRequestAdministratorAuthorization: true
        )
    }
}

enum InstallationNetworkDiagnostics {
    static func run(
        endpoints: [URL],
        session: URLSession? = nil,
        environment: InstallationEnvironmentEvidence = InstallationEnvironmentInspector.inspect()
    ) async -> InstallationDiagnosticReport {
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
        var results: [InstallationEndpointDiagnostic] = []
        for endpoint in endpoints {
            guard endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil else {
                results.append(InstallationEndpointDiagnostic(
                    requestedURL: endpoint,
                    finalURL: nil,
                    state: .failed,
                    httpStatus: nil,
                    detail: "安装入口不是无凭据HTTPS，已阻止。"
                ))
                continue
            }
            var request = URLRequest(url: endpoint, timeoutInterval: 12)
            request.httpMethod = "HEAD"
            request.setValue(
                AppReleaseMetadata.userAgent,
                forHTTPHeaderField: "User-Agent"
            )
            do {
                let (_, response) = try await client.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    results.append(InstallationEndpointDiagnostic(
                        requestedURL: endpoint,
                        finalURL: response.url,
                        state: .failed,
                        httpStatus: nil,
                        detail: "没有收到可识别的HTTPS响应。"
                    ))
                    continue
                }
                let secureFinal = http.url?.scheme == "https"
                let reachable = (200...399).contains(http.statusCode)
                let browserChallenge = secureFinal
                    && [401, 403, 405].contains(http.statusCode)
                let state: InstallationDiagnosticState = reachable
                    ? .passed : (browserChallenge ? .warning : .failed)
                let detail: String
                if reachable {
                    detail = "DNS、TLS和HTTP入口当前可达；不代表账号或下载内容已验证。"
                } else if browserChallenge {
                    detail = "DNS和TLS已连通，但官方页面要求浏览器验证；请核对地址后由你确认打开。"
                } else {
                    detail = "最终入口不是可用HTTPS响应。"
                }
                results.append(InstallationEndpointDiagnostic(
                    requestedURL: endpoint,
                    finalURL: http.url,
                    state: state,
                    httpStatus: http.statusCode,
                    detail: detail
                ))
            } catch {
                let nsError = error as NSError
                let label: String
                switch nsError.code {
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                    label = "DNS解析失败"
                case NSURLErrorSecureConnectionFailed,
                     NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasBadDate:
                    label = "TLS或证书验证失败"
                case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
                    label = "网络连接失败或超时"
                default:
                    label = "网络诊断失败"
                }
                results.append(InstallationEndpointDiagnostic(
                    requestedURL: endpoint,
                    finalURL: nil,
                    state: .failed,
                    httpStatus: nil,
                    detail: "\(label)：\(nsError.localizedDescription)"
                ))
            }
        }
        return InstallationDiagnosticReport(
            generatedAt: Date(),
            endpoints: results,
            environment: environment
        )
    }
}

enum AgentPrerequisiteCatalog {
    static func macOSPrerequisites(for agent: InstallationAgentKind) -> [SystemPrerequisite] {
        switch agent {
        case .codexDesktop, .claudeDesktop, .cherryStudio:
            return []
        }
    }
}
