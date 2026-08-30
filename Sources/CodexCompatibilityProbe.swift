import CryptoKit
import Foundation
import Security

enum CodexAgentLoopExecutionProtocol:
    String, Codable, Equatable, Sendable {
    case approveForMeV1 = "approve-for-me-v1"
    case workspaceWriteSandboxV1 = "workspace-write-sandbox-v1"

    var commandArguments: [String] {
        switch self {
        case .approveForMeV1:
            return ["--approve-for-me"]
        case .workspaceWriteSandboxV1:
            return ["--sandbox", "workspace-write"]
        }
    }

    static func select(fromExecHelp data: Data) -> Self? {
        let help = String(decoding: data, as: UTF8.self)
        if help.contains("--approve-for-me") {
            return .approveForMeV1
        }
        if help.contains("--sandbox")
            && help.contains("workspace-write") {
            return .workspaceWriteSandboxV1
        }
        return nil
    }
}

enum CodexCompatibilityEvidenceSource: String, Equatable {
    case bundledContract
    case cachedProbe
    case freshProbe
    case blocked
}

struct CodexCompatibilityEvidence: Equatable {
    let source: CodexCompatibilityEvidenceSource
    let summary: String
    let failureCheck: String?
    let cacheKey: String?
    let observedAt: Date?

    init(
        source: CodexCompatibilityEvidenceSource,
        summary: String,
        failureCheck: String?,
        cacheKey: String?,
        observedAt: Date? = nil
    ) {
        self.source = source
        self.summary = summary
        self.failureCheck = failureCheck
        self.cacheKey = cacheKey
        self.observedAt = observedAt
    }

    static func bundled(_ identity: CodexVersionIdentity) -> Self {
        CodexCompatibilityEvidence(
            source: .bundledContract,
            summary:
                "Codex \(identity.appVersion) (\(identity.appBuild)) 已有内置兼容证据",
            failureCheck: nil,
            cacheKey: nil
        )
    }

    static let unverified = CodexCompatibilityEvidence(
        source: .blocked,
        summary: "当前Codex版本尚未完成隔离兼容验证",
        failureCheck: "compatibility_not_verified",
        cacheKey: nil
    )
}

struct CodexCompatibilityProbeOutcome: Equatable {
    let contractEntry: CodexVersionContract.Entry?
    let agentLoopExecutionProtocol:
        CodexAgentLoopExecutionProtocol?
    let evidence: CodexCompatibilityEvidence

    var support: FableVersionSupport {
        guard let contractEntry,
              agentLoopExecutionProtocol != nil else {
            return .readOnly
        }
        return .verified(schemaID: contractEntry.schemaID)
    }
}

struct CodexCompatibilityCacheKey: Codable, Equatable {
    let appVersion: String
    let appBuild: String
    let cliVersion: String
    let cliSHA256: String
    let probeVersion: Int
    let bundleIdentifier: String
    let teamIdentifier: String

    var canonical: String {
        [
            "app=\(appVersion)",
            "build=\(appBuild)",
            "cli=\(cliVersion)",
            "sha256=\(cliSHA256)",
            "probe=\(probeVersion)",
            "bundle=\(bundleIdentifier)",
            "team=\(teamIdentifier)",
        ].joined(separator: "\n")
    }

    var digest: String {
        TOMLSemanticEngine.sha256(Data(canonical.utf8))
    }
}

struct CodexCompatibilityProbeReceipt: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let key: CodexCompatibilityCacheKey
    let managedSchemaID: String
    let probeMethod: String
    let agentLoopExecutionProtocol:
        CodexAgentLoopExecutionProtocol
    let checks: [String]
    let verifiedAt: Date

    func isValid(for expected: CodexCompatibilityCacheKey) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && key == expected
            && managedSchemaID
                == CodexVersionContract.dynamicManagedSchemaID
            && !probeMethod.isEmpty
            && Set(checks).isSuperset(of: [
                "openai-signature",
                "embedded-cli-sha256",
                "strict-config",
                "responses-provider",
                "isolated-codex-home",
                "session-core-protocol",
                "agent-loop-exec-protocol",
            ])
    }
}

struct CodexCompatibilityProbeFailure: LocalizedError, Equatable {
    let code: String
    let check: String
    let userMessage: String

    var errorDescription: String? { userMessage }
}

enum CodexCompatibilityEvidenceStoreError: Error {
    case unsafePath
    case invalidReceipt
}

struct CodexCompatibilityEvidenceStore {
    static let maximumReceiptBytes = 128 * 1024

    let rootURL: URL
    private let fileManager: FileManager
    private let writer: FableAtomicConfigWriter

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        writer: FableAtomicConfigWriter = FableAtomicConfigWriter()
    ) {
        self.rootURL = URL(
            fileURLWithPath: rootURL.standardizedFileURL.path,
            isDirectory: true
        ).standardizedFileURL
        self.fileManager = fileManager
        self.writer = writer
    }

    func load(
        for key: CodexCompatibilityCacheKey
    ) throws -> CodexCompatibilityProbeReceipt? {
        try prepareRoot()
        let url = receiptURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        try requireRegularFile(url)
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumReceiptBytes else {
            throw CodexCompatibilityEvidenceStoreError.invalidReceipt
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(
            CodexCompatibilityProbeReceipt.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        guard receipt.isValid(for: key) else {
            throw CodexCompatibilityEvidenceStoreError.invalidReceipt
        }
        return receipt
    }

    func save(_ receipt: CodexCompatibilityProbeReceipt) throws {
        guard receipt.isValid(for: receipt.key) else {
            throw CodexCompatibilityEvidenceStoreError.invalidReceipt
        }
        try prepareRoot()
        let url = receiptURL(for: receipt.key)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        guard !data.isEmpty,
              data.count <= Self.maximumReceiptBytes else {
            throw CodexCompatibilityEvidenceStoreError.invalidReceipt
        }
        let expectedHash: String?
        if fileManager.fileExists(atPath: url.path) {
            try requireRegularFile(url)
            expectedHash = TOMLSemanticEngine.sha256(
                try Data(contentsOf: url, options: .mappedIfSafe)
            )
        } else {
            expectedHash = nil
        }
        try writer.write(
            data,
            to: url,
            expectedCurrentHash: expectedHash
        )
    }

    private func receiptURL(
        for key: CodexCompatibilityCacheKey
    ) -> URL {
        rootURL.appendingPathComponent(
            "\(key.digest).json",
            isDirectory: false
        )
    }

    private func prepareRoot() throws {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard let values = try? rootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            throw CodexCompatibilityEvidenceStoreError.unsafePath
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func requireRegularFile(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL
                == rootURL,
              let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw CodexCompatibilityEvidenceStoreError.unsafePath
        }
    }
}

protocol CodexBinaryHashing {
    func sha256(of url: URL) throws -> String
}

struct CodexBinarySHA256Hasher: CodexBinaryHashing {
    func sha256(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              attributes[.size] as? NSNumber != nil else {
            throw CodexCompatibilityEvidenceStoreError.unsafePath
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return digest
    }
}

protocol CodexSessionCoreValidating {
    func validate(_ url: URL) -> Bool
}

struct CodexBundledSessionCoreValidator:
    CodexSessionCoreValidating {
    let bundleURL: URL

    init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL.standardizedFileURL
    }

    func validate(_ url: URL) -> Bool {
        let expected = bundleURL.appendingPathComponent(
            "Contents/Helpers/ai-access-session-core",
            isDirectory: false
        ).standardizedFileURL
        guard url.standardizedFileURL == expected,
              let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return false }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &code
        ) == errSecSuccess,
        let code else { return false }
        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(
                rawValue:
                    kSecCSStrictValidate
                    | kSecCSCheckAllArchitectures
            ),
            nil
        ) == errSecSuccess
    }
}

protocol CodexDynamicCompatibilityResolving {
    func resolve(
        applicationURL: URL,
        cliURL: URL,
        identity: CodexVersionIdentity,
        cliSHA256: String
    ) -> CodexCompatibilityProbeOutcome
}

struct CodexDynamicCompatibilityResolver:
    CodexDynamicCompatibilityResolving {
    static let currentProbeVersion = 2
    private static let probeLock = NSLock()

    private let commandRunner: any FableCommandRunning
    private let evidenceStore: CodexCompatibilityEvidenceStore
    private let sessionCoreURL: URL
    private let sessionCoreValidator:
        any CodexSessionCoreValidating
    private let temporaryRoot: URL
    private let fileManager: FileManager

    init(
        commandRunner: any FableCommandRunning =
            FableSystemCommandRunner(),
        evidenceStore: CodexCompatibilityEvidenceStore,
        sessionCoreURL: URL,
        sessionCoreValidator: any CodexSessionCoreValidating,
        temporaryRoot: URL = FileManager.default
            .temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.evidenceStore = evidenceStore
        self.sessionCoreURL = sessionCoreURL
            .standardizedFileURL
        self.sessionCoreValidator = sessionCoreValidator
        self.temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    static func live() -> CodexDynamicCompatibilityResolver {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        let bundle = Bundle.main.bundleURL
        return CodexDynamicCompatibilityResolver(
            evidenceStore: CodexCompatibilityEvidenceStore(
                rootURL: support
                    .appendingPathComponent(
                        "AI接入助手",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        "CompatibilityEvidence",
                        isDirectory: true
                    )
            ),
            sessionCoreURL: bundle.appendingPathComponent(
                "Contents/Helpers/ai-access-session-core",
                isDirectory: false
            ),
            sessionCoreValidator:
                CodexBundledSessionCoreValidator(
                    bundleURL: bundle
                )
        )
    }

    func resolve(
        applicationURL: URL,
        cliURL: URL,
        identity: CodexVersionIdentity,
        cliSHA256: String
    ) -> CodexCompatibilityProbeOutcome {
        let key = CodexCompatibilityCacheKey(
            appVersion: identity.appVersion,
            appBuild: identity.appBuild,
            cliVersion: identity.cliVersion,
            cliSHA256: cliSHA256,
            probeVersion: Self.currentProbeVersion,
            bundleIdentifier:
                FableMacOSProcessController.codexBundleIdentifier,
            teamIdentifier:
                FableOpenAICodeSignatureValidator.teamIdentifier
        )
        Self.probeLock.lock()
        defer { Self.probeLock.unlock() }

        guard sessionCoreValidator.validate(sessionCoreURL) else {
            return blockedOutcome(
                CodexCompatibilityProbeFailure(
                    code: "session_core_invalid",
                    check: "session-core-protocol",
                    userMessage:
                        "AI接入助手的历史会话组件不完整，请重新安装当前版本后再验证"
                ),
                key: key
            )
        }

        if let receipt = try? evidenceStore.load(for: key) {
            return passedOutcome(
                key: key,
                identity: identity,
                receipt: receipt,
                source: .cachedProbe
            )
        }

        do {
            let receipt = try probe(
                applicationURL: applicationURL,
                cliURL: cliURL,
                identity: identity,
                key: key
            )
            try evidenceStore.save(receipt)
            return passedOutcome(
                key: key,
                identity: identity,
                receipt: receipt,
                source: .freshProbe
            )
        } catch let failure as CodexCompatibilityProbeFailure {
            return blockedOutcome(failure, key: key)
        } catch {
            return blockedOutcome(
                CodexCompatibilityProbeFailure(
                    code: "probe_internal_error",
                    check: "compatibility-probe",
                    userMessage:
                        "新版Codex隔离验证没有完成；本次保持只读，可点“重新检查”再试"
                ),
                key: key
            )
        }
    }

    private func passedOutcome(
        key: CodexCompatibilityCacheKey,
        identity: CodexVersionIdentity,
        receipt: CodexCompatibilityProbeReceipt,
        source: CodexCompatibilityEvidenceSource
    ) -> CodexCompatibilityProbeOutcome {
        let entry = CodexVersionContract.Entry(
            schemaID: receipt.managedSchemaID,
            appVersion: identity.appVersion,
            appBuild: identity.appBuild,
            cliVersion: identity.cliVersion
        )
        let wording = source == .cachedProbe
            ? "已使用本机隔离验证证据"
            : "已在本机隔离环境完成验证"
        return CodexCompatibilityProbeOutcome(
            contractEntry: entry,
            agentLoopExecutionProtocol:
                receipt.agentLoopExecutionProtocol,
            evidence: CodexCompatibilityEvidence(
                source: source,
                summary:
                    "新版Codex \(identity.appVersion) (\(identity.appBuild)) \(wording)，配置和真实任务启动方式均已确认",
                failureCheck: nil,
                cacheKey: key.digest,
                observedAt: receipt.verifiedAt
            )
        )
    }

    private func blockedOutcome(
        _ failure: CodexCompatibilityProbeFailure,
        key: CodexCompatibilityCacheKey
    ) -> CodexCompatibilityProbeOutcome {
        CodexCompatibilityProbeOutcome(
            contractEntry: nil,
            agentLoopExecutionProtocol: nil,
            evidence: CodexCompatibilityEvidence(
                source: .blocked,
                summary: failure.userMessage,
                failureCheck: failure.check,
                cacheKey: key.digest,
                observedAt: Date()
            )
        )
    }

    private func probe(
        applicationURL: URL,
        cliURL: URL,
        identity: CodexVersionIdentity,
        key: CodexCompatibilityCacheKey
    ) throws -> CodexCompatibilityProbeReceipt {
        guard applicationURL.path.hasSuffix(".app"),
              cliURL.standardizedFileURL.path.hasPrefix(
                  applicationURL.standardizedFileURL.path + "/Contents/"
              ) else {
            throw CodexCompatibilityProbeFailure(
                code: "cli_not_embedded",
                check: "embedded-cli",
                userMessage:
                    "没有找到Codex安装包内自带的验证程序；不会使用PATH中的其他codex"
            )
        }
        let sandbox = temporaryRoot.appendingPathComponent(
            "ai-access-codex-compat-\(UUID().uuidString)",
            isDirectory: true
        ).standardizedFileURL
        guard sandbox.path.hasPrefix(temporaryRoot.path + "/")
        else {
            throw CodexCompatibilityProbeFailure(
                code: "unsafe_probe_root",
                check: "isolated-codex-home",
                userMessage: "无法建立隔离验证目录；本次没有读取真实Codex设置"
            )
        }
        defer { try? fileManager.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent(
            "home",
            isDirectory: true
        )
        let codexHome = sandbox.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        let temporary = sandbox.appendingPathComponent(
            "tmp",
            isDirectory: true
        )
        let workspace = sandbox.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        for directory in [sandbox, home, codexHome, temporary, workspace] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        let fixtureSecret =
            "fixture-compatibility-\(UUID().uuidString.lowercased())"
        let providerID = "ai_access_compat_probe"
        let endpoint = "http://127.0.0.1:9/v1"
        let config = """
        model = "probe-model"
        model_provider = "\(providerID)"
        model_reasoning_effort = "medium"
        model_context_window = 272000
        model_auto_compact_token_limit = 258000

        [model_providers.\(providerID)]
        name = "AI Access Compatibility Probe"
        base_url = "\(endpoint)"
        wire_api = "responses"
        requires_openai_auth = false
        experimental_bearer_token = "\(fixtureSecret)"
        """
        let configURL = codexHome.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )

        let environment = isolatedEnvironment(
            home: home,
            codexHome: codexHome,
            temporary: temporary
        )
        let sessionResult: FableCommandResult
        do {
            sessionResult = try commandRunner.run(
                executable: sessionCoreURL,
                arguments: ["--version"],
                environmentOverrides: environment,
                timeout: 5,
                maximumCapturedBytes: 64 * 1024
            )
        } catch {
            throw CodexCompatibilityProbeFailure(
                code: "session_core_unavailable",
                check: "session-core-protocol",
                userMessage:
                    "历史会话组件没有通过本机自检；切换保持只读，避免升级后损坏会话"
            )
        }
        guard sessionResult.terminationStatus == 0,
              sessionCoreProtocolIsValid(sessionResult.standardOutput)
        else {
            throw CodexCompatibilityProbeFailure(
                code: "session_core_protocol_mismatch",
                check: "session-core-protocol",
                userMessage:
                    "历史会话组件与当前助手版本不匹配，请重新安装AI接入助手"
            )
        }

        let doctorResult: FableCommandResult
        do {
            doctorResult = try commandRunner.run(
                executable: cliURL,
                arguments: [
                    "--strict-config",
                    "-C", workspace.path,
                    "doctor", "--json",
                ],
                environmentOverrides: environment,
                timeout: 15,
                maximumCapturedBytes: 1024 * 1024
            )
        } catch let error as FableLiveAdapterError {
            let message: String
            if error == .commandTimedOut {
                message = "新版Codex隔离验证超时；没有修改真实设置，可点“重新检查”再试"
            } else {
                message = "新版Codex的隔离诊断无法启动；本次保持只读"
            }
            throw CodexCompatibilityProbeFailure(
                code: "doctor_unavailable",
                check: "strict-config",
                userMessage: message
            )
        }
        let combined =
            doctorResult.standardOutput + doctorResult.standardError
        guard combined.range(of: Data(fixtureSecret.utf8)) == nil else {
            throw CodexCompatibilityProbeFailure(
                code: "probe_secret_exposed",
                check: "secret-redaction",
                userMessage:
                    "新版Codex诊断输出包含了不应显示的认证内容；已停止并清理临时验证目录"
            )
        }

        let method: String
        var checks = [
            "openai-signature",
            "embedded-cli-sha256",
            "session-core-protocol",
        ]
        guard let doctorReport = doctorReport(
            doctorResult.standardOutput
        ) else {
            throw CodexCompatibilityProbeFailure(
                code: "doctor_invalid_json",
                check: "strict-config",
                userMessage:
                    "新版Codex返回了无法核对的诊断结果；本次保持只读，可点“重新检查”再试"
            )
        }
        if doctorReportIsCompatible(
            doctorReport,
            identity: identity,
            cliURL: cliURL,
            codexHome: codexHome,
            providerID: providerID,
            endpoint: endpoint
        ) {
            method = "strict-config-doctor-v1"
            checks.append(contentsOf: [
                "strict-config",
                "responses-provider",
                "isolated-codex-home",
                "experimental-bearer-token-redacted",
            ])
        } else {
            guard doctorReport["schemaVersion"] as? Int != 1 else {
                throw CodexCompatibilityProbeFailure(
                    code: "doctor_contract_mismatch",
                    check: "strict-config",
                    userMessage:
                        "新版Codex的配置诊断与助手管理字段不一致；已保持只读，避免错误切换"
                )
            }
            let fallback: FableCommandResult
            do {
                fallback = try commandRunner.run(
                    executable: cliURL,
                    arguments: ["features", "list"],
                    environmentOverrides: environment,
                    timeout: 10,
                    maximumCapturedBytes: 512 * 1024
                )
            } catch {
                throw CodexCompatibilityProbeFailure(
                    code: "strict_config_rejected",
                    check: "strict-config",
                    userMessage:
                        "新版Codex不再接受助手当前使用的配置字段；已保持只读，并列为真实兼容失败"
                )
            }
            let fallbackCombined =
                fallback.standardOutput + fallback.standardError
            guard fallback.terminationStatus == 0,
                  !fallback.standardOutput.isEmpty,
                  fallbackCombined.range(
                      of: Data(fixtureSecret.utf8)
                  ) == nil else {
                throw CodexCompatibilityProbeFailure(
                    code: "strict_config_rejected",
                    check: "strict-config",
                    userMessage:
                        "新版Codex不再接受助手当前使用的配置字段；已保持只读，并列为真实兼容失败"
                )
            }
            method = "strict-config-doctor-plus-features-v2"
            checks.append(contentsOf: [
                "strict-config",
                "features-list",
                "responses-provider",
                "isolated-codex-home",
                "experimental-bearer-token-redacted",
            ])
        }

        let agentLoopExecutionProtocol = try agentLoopProtocol(
            cliURL: cliURL,
            environment: environment,
            fixtureSecret: fixtureSecret
        )
        checks.append("agent-loop-exec-protocol")

        let receipt = CodexCompatibilityProbeReceipt(
            schemaVersion:
                CodexCompatibilityProbeReceipt.currentSchemaVersion,
            key: key,
            managedSchemaID:
                CodexVersionContract.dynamicManagedSchemaID,
            probeMethod: method,
            agentLoopExecutionProtocol:
                agentLoopExecutionProtocol,
            checks: Array(Set(checks)).sorted(),
            verifiedAt: Date()
        )
        guard receipt.isValid(for: key) else {
            throw CodexCompatibilityProbeFailure(
                code: "incomplete_evidence",
                check: "compatibility-evidence",
                userMessage:
                    "新版Codex验证证据不完整；本次保持只读"
            )
        }
        return receipt
    }

    private func agentLoopProtocol(
        cliURL: URL,
        environment: [String: String],
        fixtureSecret: String
    ) throws -> CodexAgentLoopExecutionProtocol {
        let result: FableCommandResult
        do {
            result = try commandRunner.run(
                executable: cliURL,
                arguments: ["exec", "--help"],
                environmentOverrides: environment,
                timeout: 5,
                maximumCapturedBytes: 256 * 1024
            )
        } catch {
            throw CodexCompatibilityProbeFailure(
                code: "agent_loop_help_unavailable",
                check: "agent-loop-exec-protocol",
                userMessage:
                    "当前Codex的真实任务启动方式无法确认；请更新AI接入助手"
            )
        }
        let combined = result.standardOutput + result.standardError
        guard result.terminationStatus == 0,
              combined.range(of: Data(fixtureSecret.utf8)) == nil,
              let selected =
                CodexAgentLoopExecutionProtocol.select(
                    fromExecHelp: combined
                ) else {
            throw CodexCompatibilityProbeFailure(
                code: "agent_loop_protocol_unsupported",
                check: "agent-loop-exec-protocol",
                userMessage:
                    "当前Codex的真实任务启动方式尚未兼容；请更新AI接入助手"
            )
        }
        return selected
    }

    private func isolatedEnvironment(
        home: URL,
        codexHome: URL,
        temporary: URL
    ) -> [String: String] {
        [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "TMPDIR": temporary.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": "ai-access-probe",
            "LOGNAME": "ai-access-probe",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1",
            "http_proxy": "http://127.0.0.1:1",
            "https_proxy": "http://127.0.0.1:1",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
            "SSL_CERT_FILE": "",
            "SSL_CERT_DIR": "",
        ]
    }

    private func sessionCoreProtocolIsValid(_ data: Data) -> Bool {
        for rawLine in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(rawLine)
            ) as? [String: Any],
            object["schema_version"] as? Int == 1,
            object["event"] as? String == "result",
            object["ok"] as? Bool == true,
            let payload = object["data"] as? [String: Any],
            payload["protocolVersion"] as? Int == 1 else {
                continue
            }
            return true
        }
        return false
    }

    private func doctorReport(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    }

    private func doctorReportIsCompatible(
        _ object: [String: Any],
        identity: CodexVersionIdentity,
        cliURL: URL,
        codexHome: URL,
        providerID: String,
        endpoint: String
    ) -> Bool {
        guard object["schemaVersion"] as? Int == 1,
        object["codexVersion"] as? String
            == identity.cliVersion,
        let checks = object["checks"] as? [String: Any],
        let config = check(checks, id: "config.load"),
        status(config) == "ok",
        pathsAreEquivalent(
            detail(config, "CODEX_HOME"),
            codexHome
        ),
        detail(config, "model") == "probe-model",
        detail(config, "model provider") == providerID,
        pathsAreEquivalent(
            detail(config, "sqlite home"),
            codexHome
        ),
        let auth = check(checks, id: "auth.credentials"),
        status(auth) == "ok",
        (auth["summary"] as? String)?
            .localizedCaseInsensitiveContains("not required")
                == true,
        let installation = check(checks, id: "installation"),
        status(installation) == "ok",
        pathsAreEquivalent(
            detail(installation, "current executable"),
            cliURL
        ),
        let websocket = check(
            checks,
            id: "network.websocket_reachability"
        ),
        status(websocket) == "ok",
        detail(websocket, "model provider") == providerID,
        detail(websocket, "wire API") == "responses",
        let reachability = check(
            checks,
            id: "network.provider_reachability"
        ),
        detailsText(reachability).contains(endpoint),
        let paths = check(checks, id: "state.paths"),
        status(paths) == "ok",
        detailsContainPath(paths, codexHome),
        let parity = check(
            checks,
            id: "state.rollout_db_parity"
        ),
        status(parity) == "ok",
        detail(parity, "default model provider") == providerID
        else { return false }
        return true
    }

    private func pathsAreEquivalent(
        _ reported: String?,
        _ expected: URL
    ) -> Bool {
        guard let reported else { return false }
        return URL(fileURLWithPath: reported)
            .resolvingSymlinksInPath().standardizedFileURL.path
            == expected.resolvingSymlinksInPath()
                .standardizedFileURL.path
    }

    private func detailsContainPath(
        _ check: [String: Any],
        _ expected: URL
    ) -> Bool {
        let text = detailsText(check)
        return text.contains(expected.standardizedFileURL.path)
            || text.contains(
                expected.resolvingSymlinksInPath()
                    .standardizedFileURL.path
            )
    }

    private func check(
        _ checks: [String: Any],
        id: String
    ) -> [String: Any]? {
        checks[id] as? [String: Any]
    }

    private func status(_ check: [String: Any]) -> String? {
        check["status"] as? String
    }

    private func detail(
        _ check: [String: Any],
        _ key: String
    ) -> String? {
        (check["details"] as? [String: Any])?[key]
            as? String
    }

    private func detailsText(_ check: [String: Any]) -> String {
        guard let details = check["details"]
            as? [String: Any] else { return "" }
        return details.keys.sorted().map {
            "\($0)=\(String(describing: details[$0]!))"
        }.joined(separator: "\n")
    }
}
