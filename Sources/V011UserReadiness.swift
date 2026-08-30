import Foundation

enum V011OfficialUsageError: LocalizedError {
    case testingBlocked
    case unsupportedVersion
    case appServerUnavailable
    case protocolMismatch
    case chatGPTLoginRequired
    case rateLimitsUnavailable
    case unsafeEvidence

    var errorDescription: String? {
        switch self {
        case .testingBlocked:
            return "测试环境禁止读取真实官方额度"
        case .unsupportedVersion:
            return "当前Codex版本暂不支持安全读取官方额度"
        case .appServerUnavailable:
            return "Codex官方额度服务暂时不可用"
        case .protocolMismatch:
            return "Codex官方额度接口已变化，请升级助手后再试"
        case .chatGPTLoginRequired:
            return "请先在Codex中登录ChatGPT账号"
        case .rateLimitsUnavailable:
            return "官方暂未返回可显示的额度窗口"
        case .unsafeEvidence:
            return "官方额度证据不完整，未采用本次结果"
        }
    }
}

struct V011OfficialUsageWindow: Codable, Equatable, Identifiable {
    let durationMinutes: Int?
    let usedPercent: Int
    let resetsAt: Date?

    var id: String {
        "\(durationMinutes ?? -1)|\(resetsAt?.timeIntervalSince1970 ?? -1)"
    }

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var displayName: String {
        switch durationMinutes {
        case 300:
            return "5小时"
        case 10_080:
            return "每周"
        case let minutes? where minutes > 0
            && minutes.isMultiple(of: 1_440):
            return "\(minutes / 1_440)天"
        case let minutes? where minutes > 0
            && minutes.isMultiple(of: 60):
            return "\(minutes / 60)小时"
        case let minutes? where minutes > 0:
            return "\(minutes)分钟"
        default:
            return "额度窗口"
        }
    }

    var isStructurallyValid: Bool {
        (0...100).contains(usedPercent)
            && durationMinutes.map { $0 > 0 } != false
            && resetsAt.map {
                $0.timeIntervalSince1970.isFinite
                    && $0.timeIntervalSince1970 > 0
            } != false
    }
}

struct V011OfficialUsageSnapshot: Codable, Equatable {
    static let schemaVersion = 2
    static let freshnessLifetime: TimeInterval = 30 * 60

    let version: Int
    let observedAt: Date
    let freshUntil: Date
    let accountType: String
    let planType: String
    let accountScopeSHA256: String
    let codexAppVersion: String
    let codexAppBuild: String
    let codexCLIVersion: String
    let codexCLISHA256: String
    let windows: [V011OfficialUsageWindow]
    let credits: V011OfficialCreditsSnapshot?
    let individualLimit: V011OfficialSpendControlSnapshot?
    let spendControlReached: Bool?
    let rateLimitReachedType: String?
    let tokenUsage: V011OfficialTokenUsageSnapshot?

    init(
        version: Int,
        observedAt: Date,
        freshUntil: Date,
        accountType: String,
        planType: String,
        accountScopeSHA256: String,
        codexAppVersion: String,
        codexAppBuild: String,
        codexCLIVersion: String,
        codexCLISHA256: String,
        windows: [V011OfficialUsageWindow],
        credits: V011OfficialCreditsSnapshot? = nil,
        individualLimit: V011OfficialSpendControlSnapshot? = nil,
        spendControlReached: Bool? = nil,
        rateLimitReachedType: String? = nil,
        tokenUsage: V011OfficialTokenUsageSnapshot? = nil
    ) {
        self.version = version
        self.observedAt = observedAt
        self.freshUntil = freshUntil
        self.accountType = accountType
        self.planType = planType
        self.accountScopeSHA256 = accountScopeSHA256
        self.codexAppVersion = codexAppVersion
        self.codexAppBuild = codexAppBuild
        self.codexCLIVersion = codexCLIVersion
        self.codexCLISHA256 = codexCLISHA256
        self.windows = windows
        self.credits = credits
        self.individualLimit = individualLimit
        self.spendControlReached = spendControlReached
        self.rateLimitReachedType = rateLimitReachedType
        self.tokenUsage = tokenUsage
    }

    func isFresh(at date: Date) -> Bool {
        isStructurallyValid && freshUntil > date
    }

    var isStructurallyValid: Bool {
        (version == 1 || version == Self.schemaVersion)
            && observedAt <= freshUntil
            && freshUntil.timeIntervalSince(observedAt)
                <= Self.freshnessLifetime + 1
            && accountType == "chatgpt"
            && !planType.isEmpty
            && planType.utf8.count <= 80
            && Self.isSHA256(accountScopeSHA256)
            && !codexAppVersion.isEmpty
            && !codexAppBuild.isEmpty
            && !codexCLIVersion.isEmpty
            && Self.isSHA256(codexCLISHA256)
            && !windows.isEmpty
            && windows.count <= 4
            && windows.allSatisfy(\.isStructurallyValid)
            && credits.map(\.isStructurallyValid) != false
            && individualLimit.map(\.isStructurallyValid) != false
            && rateLimitReachedType.map {
                !$0.isEmpty && $0.utf8.count <= 80
            } != false
            && tokenUsage.map(\.isStructurallyValid) != false
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        }
    }
}

protocol V011OfficialUsageReading: Sendable {
    func read() throws -> V011OfficialUsageSnapshot
    func read(threadID: String) throws -> V011OfficialUsageSnapshot
}

private final class V011AppServerOutputRecorder:
    @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceededLimit = false
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        guard data.count + value.count <= maximumBytes else {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
            return
        }
        data.append(value)
    }

    var snapshot: (data: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, exceededLimit)
    }
}

struct V011CodexAppServerExchange: @unchecked Sendable {
    static let maximumCapturedBytes = 512 * 1024

    let environment: @Sendable () -> [String: String]

    init(
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.environment = environment
    }

    func exchange(
        executable: URL,
        requestLines: Data,
        expectedResponseIDs: Set<Int>,
        timeout: TimeInterval = 12
    ) throws -> Data {
        let currentEnvironment = environment()
        guard currentEnvironment[
            "AI_ACCESS_ASSISTANT_TESTING"
        ] != "1" else {
            throw V011OfficialUsageError.testingBlocked
        }
        guard let values = try? executable.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        FileManager.default.isExecutableFile(
            atPath: executable.path
        ) else {
            throw V011OfficialUsageError.unsupportedVersion
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = FableCommandEnvironmentPolicy.sanitized(
            base: currentEnvironment,
            overrides: [:]
        )
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let output = V011AppServerOutputRecorder(
            maximumBytes: Self.maximumCapturedBytes
        )
        let errors = V011AppServerOutputRecorder(
            maximumBytes: 64 * 1024
        )
        stdout.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }

        do {
            try process.run()
            try stdin.fileHandleForWriting.write(
                contentsOf: requestLines
            )
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            throw V011OfficialUsageError.appServerUnavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        var complete = false
        while Date() < deadline {
            let captured = output.snapshot
            if captured.exceededLimit {
                break
            }
            if Self.responseIDs(in: captured.data)
                .isSuperset(of: expectedResponseIDs) {
                complete = true
                break
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < stopDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { process.interrupt() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let captured = output.snapshot
        _ = errors.snapshot
        guard complete,
              !captured.exceededLimit else {
            throw V011OfficialUsageError.appServerUnavailable
        }
        return captured.data
    }

    private static func responseIDs(in data: Data) -> Set<Int> {
        Set(jsonObjects(in: data).compactMap { object in
            return object["id"] as? Int
        })
    }

    fileprivate static func jsonObjects(
        in data: Data
    ) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            guard let value = try? JSONSerialization.jsonObject(
                with: Data(line),
                options: []
            ) else { return nil }
            return value as? [String: Any]
        }
    }
}

struct V011LiveOfficialUsageReader:
    V011OfficialUsageReading, @unchecked Sendable {
    let versionDiscovery: any FableCodexVersionDiscovering
    let exchange: V011CodexAppServerExchange
    let binaryHasher: any CodexBinaryHashing
    let now: @Sendable () -> Date

    init(
        versionDiscovery: any FableCodexVersionDiscovering,
        exchange: V011CodexAppServerExchange =
            V011CodexAppServerExchange(),
        binaryHasher: any CodexBinaryHashing =
            CodexBinarySHA256Hasher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.versionDiscovery = versionDiscovery
        self.exchange = exchange
        self.binaryHasher = binaryHasher
        self.now = now
    }

    func read() throws -> V011OfficialUsageSnapshot {
        try read(threadID: nil)
    }

    func read(threadID: String) throws -> V011OfficialUsageSnapshot {
        guard !threadID.isEmpty,
              threadID.utf8.count <= 512,
              !threadID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return try read(threadID: Optional(threadID))
    }

    private func read(
        threadID: String?
    ) throws -> V011OfficialUsageSnapshot {
        let installation = try versionDiscovery.discover()
        guard installation.support.allowsWrites,
              let entry = installation.contractEntry,
              entry.matches(installation.identity) else {
            throw V011OfficialUsageError.unsupportedVersion
        }
        var messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "ai-access-assistant",
                        "version": AppReleaseMetadata.version,
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:],
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/read",
                "params": ["refreshToken": false],
            ],
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "account/rateLimits/read",
                "params": NSNull(),
            ],
            [
                "jsonrpc": "2.0",
                "id": 4,
                "method": "account/usage/read",
                "params": NSNull(),
            ],
        ]
        if let threadID {
            messages.append([
                "jsonrpc": "2.0",
                "id": 5,
                "method": "account/usage/read",
                "params": ["threadId": threadID],
            ])
        }
        var requestLines = Data()
        for message in messages {
            requestLines.append(
                try JSONSerialization.data(
                    withJSONObject: message,
                    options: [.sortedKeys]
                )
            )
            requestLines.append(0x0A)
        }
        let responseData = try exchange.exchange(
            executable: installation.cliURL,
            requestLines: requestLines,
            expectedResponseIDs: threadID == nil
                ? [1, 2, 3, 4] : [1, 2, 3, 4, 5]
        )
        let snapshot = try Self.parse(
            responseData,
            installation: installation,
            cliSHA256: try binaryHasher.sha256(
                of: installation.cliURL
            ),
            observedAt: now(),
            requestedThreadID: threadID
        )
        guard snapshot.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return snapshot
    }

    static func parse(
        _ responseData: Data,
        installation: FableCodexInstallation,
        cliSHA256: String,
        observedAt: Date,
        requestedThreadID: String? = nil
    ) throws -> V011OfficialUsageSnapshot {
        let responses = Dictionary(
            uniqueKeysWithValues:
                V011CodexAppServerExchange
                    .jsonObjects(in: responseData)
                    .compactMap { object -> (Int, [String: Any])? in
                        guard let id = object["id"] as? Int else {
                            return nil
                        }
                        return (id, object)
                    }
        )
        guard responses[1]?["error"] == nil,
              responses[2]?["error"] == nil,
              responses[3]?["error"] == nil,
              let accountResult = responses[2]?["result"]
                as? [String: Any],
              let account = accountResult["account"]
                as? [String: Any],
              let accountType = account["type"] as? String,
              accountType == "chatgpt" else {
            throw V011OfficialUsageError.chatGPTLoginRequired
        }
        let email = (account["email"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let planType = (account["planType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "unknown"
        guard let rateResult = responses[3]?["result"]
                as? [String: Any] else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let bucket: [String: Any]?
        if let buckets = rateResult["rateLimitsByLimitId"]
                as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            bucket = codex
        } else {
            bucket = rateResult["rateLimits"]
                as? [String: Any]
        }
        guard let bucket else {
            throw V011OfficialUsageError.rateLimitsUnavailable
        }
        var windows: [V011OfficialUsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let raw = bucket[key] as? [String: Any],
                  let used = raw["usedPercent"] as? Int else {
                continue
            }
            let duration = raw["windowDurationMins"] as? Int
            let resetSeconds = raw["resetsAt"] as? Int
            windows.append(
                V011OfficialUsageWindow(
                    durationMinutes: duration,
                    usedPercent: used,
                    resetsAt: resetSeconds.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    }
                )
            )
        }
        windows = Array(
            Dictionary(
                grouping: windows,
                by: { $0.durationMinutes ?? -1 }
            ).values.compactMap(\.first)
        ).sorted {
            ($0.durationMinutes ?? Int.max)
                < ($1.durationMinutes ?? Int.max)
        }
        guard !windows.isEmpty else {
            throw V011OfficialUsageError.rateLimitsUnavailable
        }
        let credits = try V011OfficialCreditsSnapshot.parse(
            bucket["credits"]
        )
        let individualLimit = try V011OfficialSpendControlSnapshot
            .parse(bucket["individualLimit"])
        let tokenUsage: V011OfficialTokenUsageSnapshot?
        if responses[4]?["error"] == nil,
           let usageResult = responses[4]?["result"]
                as? [String: Any] {
            let threadResult: [String: Any]?
            if requestedThreadID != nil,
               responses[5]?["error"] == nil {
                threadResult = responses[5]?["result"]
                    as? [String: Any]
            } else {
                threadResult = nil
            }
            tokenUsage = try V011OfficialTokenUsageSnapshot.parse(
                accountResult: usageResult,
                threadResult: threadResult,
                requestedThreadID: requestedThreadID
            )
        } else {
            tokenUsage = nil
        }
        let scope = [accountType, email, planType]
            .joined(separator: "|")
        return V011OfficialUsageSnapshot(
            version: V011OfficialUsageSnapshot.schemaVersion,
            observedAt: observedAt,
            freshUntil: observedAt.addingTimeInterval(
                V011OfficialUsageSnapshot.freshnessLifetime
            ),
            accountType: accountType,
            planType: planType,
            accountScopeSHA256: V011AgentLoopReceipt.sha256(
                Data(scope.utf8)
            ),
            codexAppVersion: installation.identity.appVersion,
            codexAppBuild: installation.identity.appBuild,
            codexCLIVersion: installation.identity.cliVersion,
            codexCLISHA256: cliSHA256,
            windows: windows,
            credits: credits,
            individualLimit: individualLimit,
            spendControlReached:
                bucket["spendControlReached"] as? Bool,
            rateLimitReachedType:
                bucket["rateLimitReachedType"] as? String,
            tokenUsage: tokenUsage
        )
    }
}

struct V011OfficialUsageSnapshotStore {
    static let maximumBytes = 64 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: FableAtomicConfigWriter

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        writer: FableAtomicConfigWriter = FableAtomicConfigWriter()
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.writer = writer
    }

    func load() throws -> V011OfficialUsageSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumBytes else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        let value = try JSONDecoder().decode(
            V011OfficialUsageSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        guard value.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return value
    }

    func commit(_ value: V011OfficialUsageSnapshot) throws {
        guard value.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        try writer.write(
            data,
            to: fileURL,
            expectedCurrentHash:
                SessionSyncFileSafety.hashIfPresent(fileURL)
        )
    }
}

struct V011SavedRelayReadinessReceipt:
    Codable, Equatable, Identifiable {
    static let schemaVersion = 1

    let version: Int
    let profileID: String
    let profileFingerprint: String
    let agentLoop: V011AgentLoopReceipt

    var id: String { profileID }
    var observedAt: Date { agentLoop.observedAt }
    var expiresAt: Date { agentLoop.expiresAt }

    var isStructurallyValid: Bool {
        version == Self.schemaVersion
            && !profileID.isEmpty
            && profileID.utf8.count <= 512
            && profileFingerprint.count == 64
            && profileFingerprint.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && agentLoop.isStructurallyValid
    }

    static func fingerprint(
        _ profile: CodexRelayProfile
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(profile)) ?? Data()
        return V011AgentLoopReceipt.sha256(data)
    }
}

enum V011SavedRelayReadinessState: Equatable {
    case verifying
    case usable
    case expired
    case failed
    case unverified
}

protocol V011SavedRelayReadinessVerifying: Sendable {
    func verify(
        profile: CodexRelayProfile,
        secret: String,
        userConsented: Bool
    ) throws -> V011SavedRelayReadinessReceipt

    func receiptMatchesCurrent(
        _ receipt: V011SavedRelayReadinessReceipt,
        profile: CodexRelayProfile,
        now: Date
    ) -> Bool
}

struct V011LiveSavedRelayReadinessVerifier:
    V011SavedRelayReadinessVerifying, @unchecked Sendable {
    let codexHome: URL
    let versionDiscovery: any FableCodexVersionDiscovering
    let commandRunner: any FableCommandRunning
    let binaryHasher: any CodexBinaryHashing
    let fileManager: FileManager
    let now: @Sendable () -> Date
    let temporaryRoot: URL

    init(
        codexHome: URL,
        versionDiscovery: any FableCodexVersionDiscovering,
        commandRunner: any FableCommandRunning =
            FableSystemCommandRunner(),
        binaryHasher: any CodexBinaryHashing =
            CodexBinarySHA256Hasher(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.versionDiscovery = versionDiscovery
        self.commandRunner = commandRunner
        self.binaryHasher = binaryHasher
        self.fileManager = fileManager
        self.now = now
        self.temporaryRoot = temporaryRoot.standardizedFileURL
    }

    func verify(
        profile: CodexRelayProfile,
        secret: String,
        userConsented: Bool
    ) throws -> V011SavedRelayReadinessReceipt {
        guard userConsented else {
            throw V011AgentLoopVerificationError.authorizationRequired
        }
        let liveConfigURL = codexHome.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
        let liveConfigData = try boundedConfig(liveConfigURL)
        let liveConfigHash = V011AgentLoopReceipt.sha256(
            liveConfigData
        )
        let original = String(
            decoding: liveConfigData,
            as: UTF8.self
        )
        let proposed = try FableIsolatedRelayConfigurationBuilder.build(
            original: original,
            profile: profile.fableProfile,
            secret: secret
        )
        let proposedData = Data(proposed.utf8)
        let sandboxRoot = temporaryRoot.appendingPathComponent(
            "ai-access-saved-relay-\(UUID().uuidString)",
            isDirectory: true
        ).standardizedFileURL
        guard sandboxRoot.deletingLastPathComponent()
                == temporaryRoot else {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
        let isolatedCodexHome = sandboxRoot.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        var probeResult: V011AgentLoopProbeResult?
        var probeError: Error?
        do {
            try fileManager.createDirectory(
                at: sandboxRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: isolatedCodexHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let isolatedConfig = isolatedCodexHome
                .appendingPathComponent("config.toml")
            try proposedData.write(
                to: isolatedConfig,
                options: Data.WritingOptions.atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: isolatedConfig.path
            )
            probeResult = try V011LiveAgentLoopVerifier(
                codexHome: isolatedCodexHome,
                versionDiscovery: versionDiscovery,
                commandRunner: commandRunner,
                binaryHasher: binaryHasher,
                fileManager: fileManager,
                now: now,
                temporaryRoot: sandboxRoot
            ).verify(
                userConsented: true,
                expectedProviderID: profile.v011ProviderID,
                expectedConfigHash:
                    V011AgentLoopReceipt.sha256(proposedData)
            )
        } catch {
            probeError = error
        }
        let currentConfig = try boundedConfig(liveConfigURL)
        let configurationChanged =
            V011AgentLoopReceipt.sha256(currentConfig)
                != liveConfigHash
        do {
            if fileManager.fileExists(atPath: sandboxRoot.path) {
                try fileManager.removeItem(at: sandboxRoot)
            }
        } catch {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
        if configurationChanged {
            throw V011AgentLoopVerificationError.configurationChanged
        }
        if let probeError { throw probeError }
        guard let probeResult else {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
        let receipt = V011SavedRelayReadinessReceipt(
            version: V011SavedRelayReadinessReceipt.schemaVersion,
            profileID: profile.id,
            profileFingerprint:
                V011SavedRelayReadinessReceipt.fingerprint(profile),
            agentLoop: probeResult.receipt
        )
        guard receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
        return receipt
    }

    func receiptMatchesCurrent(
        _ receipt: V011SavedRelayReadinessReceipt,
        profile: CodexRelayProfile,
        now: Date
    ) -> Bool {
        guard receipt.isStructurallyValid,
              receipt.profileID == profile.id,
              receipt.profileFingerprint
                == V011SavedRelayReadinessReceipt
                    .fingerprint(profile),
              receipt.agentLoop.outcome == .passed,
              receipt.expiresAt > now,
              receipt.agentLoop.providerID
                == profile.v011ProviderID,
              receipt.agentLoop.modelID
                == profile.defaultModel,
              let installation = try? versionDiscovery.discover(),
              receipt.agentLoop.codexAppVersion
                == installation.identity.appVersion,
              receipt.agentLoop.codexAppBuild
                == installation.identity.appBuild,
              receipt.agentLoop.codexCLIVersion
                == installation.identity.cliVersion,
              let hash = try? binaryHasher.sha256(
                of: installation.cliURL
              ) else {
            return false
        }
        return hash == receipt.agentLoop.codexCLISHA256
    }

    private func boundedConfig(_ url: URL) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            return Data()
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= V011LiveAgentLoopVerifier
                .maximumConfigurationBytes else {
            throw V011AgentLoopVerificationError.unsafeConfiguration
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

private struct V011SavedRelayReadinessPayload: Codable {
    let version: Int
    let receipts: [String: V011SavedRelayReadinessReceipt]
}

struct V011SavedRelayReadinessStore {
    static let maximumBytes = 512 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: FableAtomicConfigWriter

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        writer: FableAtomicConfigWriter = FableAtomicConfigWriter()
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.writer = writer
    }

    func load() throws -> [String: V011SavedRelayReadinessReceipt] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumBytes else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        let payload = try JSONDecoder().decode(
            V011SavedRelayReadinessPayload.self,
            from: Data(contentsOf: fileURL)
        )
        guard payload.version == 1,
              payload.receipts.count <= 256,
              payload.receipts.allSatisfy({ key, receipt in
                  key == receipt.profileID
                      && receipt.isStructurallyValid
              }) else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return payload.receipts
    }

    func commit(
        _ receipts: [String: V011SavedRelayReadinessReceipt]
    ) throws {
        guard receipts.count <= 256,
              receipts.allSatisfy({ key, receipt in
                  key == receipt.profileID
                      && receipt.isStructurallyValid
              }) else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            V011SavedRelayReadinessPayload(
                version: 1,
                receipts: receipts
            )
        )
        guard data.count <= Self.maximumBytes else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        try writer.write(
            data,
            to: fileURL,
            expectedCurrentHash:
                SessionSyncFileSafety.hashIfPresent(fileURL)
        )
    }
}
