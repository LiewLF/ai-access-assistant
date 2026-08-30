// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

enum V011AgentLoopOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

enum V011AgentLoopFailureStage:
    String, Codable, Equatable, Sendable {
    case preparation
    case initialResponse
    case toolCall
    case toolExecution
    case continuation
    case finalResponse
    case configurationChanged
    case cleanup

    var userTitle: String {
        switch self {
        case .preparation:
            return "隔离验证环境未建立"
        case .initialResponse:
            return "Codex没有开始真实任务"
        case .toolCall:
            return "模型没有发起本机工具调用"
        case .toolExecution:
            return "本机工具没有完成"
        case .continuation:
            return "工具完成后模型没有继续"
        case .finalResponse:
            return "任务结束语与验证合同不一致"
        case .configurationChanged:
            return "验证期间Codex设置发生变化"
        case .cleanup:
            return "临时验证目录未能立即清理"
        }
    }

    var userAction: String {
        switch self {
        case .preparation:
            return "重新读取当前状态；仍失败时检查Codex安装与配置文件权限。"
        case .initialResponse:
            return "验证命令在模型请求前退出；这不代表余额不足。请更新Codex或助手后再验证。"
        case .toolCall:
            return "当前模型或中转可能只支持普通回复，不能证明可完成Codex任务。"
        case .toolExecution:
            return "检查Codex工具权限与沙箱；助手不会扩大权限或绕过审批。"
        case .continuation:
            return "当前中转可能不能正确回传工具结果；请核对Responses兼容性。"
        case .finalResponse:
            return "当前链路返回不完整；请核对模型与Responses兼容性。"
        case .configurationChanged:
            return "停止其他配置工具，重新读取后再验证。"
        case .cleanup:
            return "退出助手后重开；过期临时目录会由助手清理。"
        }
    }
}

struct V011AgentLoopReceipt:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentProbeVersion = 1

    let schemaVersion: Int
    let probeVersion: Int
    let observedAt: Date
    let expiresAt: Date
    let durationMilliseconds: Double
    let providerID: String
    let endpointHost: String?
    let modelID: String
    let configHash: String
    let codexAppVersion: String
    let codexAppBuild: String
    let codexCLIVersion: String
    let codexCLISHA256: String
    let outcome: V011AgentLoopOutcome
    let failureStage: V011AgentLoopFailureStage?
    let eventStructureSHA256: String
    let toolCallCount: Int
    let requestCount: Int

    init(
        observedAt: Date,
        expiresAt: Date,
        durationMilliseconds: Double,
        providerID: String,
        endpointHost: String?,
        modelID: String,
        configHash: String,
        codexAppVersion: String,
        codexAppBuild: String,
        codexCLIVersion: String,
        codexCLISHA256: String,
        outcome: V011AgentLoopOutcome,
        failureStage: V011AgentLoopFailureStage?,
        eventStructureSHA256: String,
        toolCallCount: Int,
        requestCount: Int = 1
    ) {
        schemaVersion = Self.currentSchemaVersion
        probeVersion = Self.currentProbeVersion
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.durationMilliseconds = durationMilliseconds
        self.providerID = providerID
        self.endpointHost = endpointHost
        self.modelID = modelID
        self.configHash = configHash
        self.codexAppVersion = codexAppVersion
        self.codexAppBuild = codexAppBuild
        self.codexCLIVersion = codexCLIVersion
        self.codexCLISHA256 = codexCLISHA256
        self.outcome = outcome
        self.failureStage = failureStage
        self.eventStructureSHA256 = eventStructureSHA256
        self.toolCallCount = toolCallCount
        self.requestCount = requestCount
    }

    var evidenceKey: String {
        let canonical = [
            "provider=\(providerID)",
            "endpoint=\(endpointHost ?? "official")",
            "model=\(modelID)",
            "config=\(configHash)",
            "app=\(codexAppVersion)",
            "build=\(codexAppBuild)",
            "cli=\(codexCLIVersion)",
            "cli_sha256=\(codexCLISHA256)",
            "probe=\(probeVersion)",
        ].joined(separator: "\n")
        return Self.sha256(Data(canonical.utf8))
    }

    var isStructurallyValid: Bool {
        let outcomeIsValid = outcome == .passed
            ? failureStage == nil
            : failureStage != nil
        return schemaVersion == Self.currentSchemaVersion
            && probeVersion == Self.currentProbeVersion
            && observedAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt > observedAt
            && durationMilliseconds.isFinite
            && durationMilliseconds >= 0
            && Self.safeIdentifier(providerID, maximum: 256)
            && endpointHost.map(Self.safeHost) != false
            && Self.safeIdentifier(modelID, maximum: 512)
            && Self.isSHA256(configHash)
            && Self.safeIdentifier(codexAppVersion, maximum: 128)
            && Self.safeIdentifier(codexAppBuild, maximum: 128)
            && Self.safeIdentifier(codexCLIVersion, maximum: 128)
            && Self.isSHA256(codexCLISHA256)
            && Self.isSHA256(eventStructureSHA256)
            && toolCallCount >= 0
            && toolCallCount <= 32
            && requestCount == 1
            && outcomeIsValid
    }

    static func providerID(_ live: LiveCodexState) -> String {
        switch live.mode {
        case .official:
            return "openai"
        case let .relay(providerID):
            return providerID
        }
    }

    static func endpointHost(_ live: LiveCodexState) -> String? {
        guard case .relay = live.mode,
              let baseURL = live.provider?.baseURL,
              let components = URLComponents(string: baseURL),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return components.port.map {
            "\(host.lowercased()):\($0)"
        } ?? host.lowercased()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func safeIdentifier(
        _ value: String,
        maximum: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func safeHost(_ value: String) -> Bool {
        safeIdentifier(value, maximum: 512)
            && !value.contains(where: {
                $0.isWhitespace || "/@?#\\".contains($0)
            })
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }
}

struct V011AgentLoopProbeResult: Equatable, Sendable {
    let receipt: V011AgentLoopReceipt

    var safeMessage: String {
        guard let stage = receipt.failureStage else {
            return "真实任务闭环已通过：模型调用了本机工具、接收工具结果并完成续答。"
        }
        return "\(stage.userTitle)。\(stage.userAction)"
    }
}

enum V011AgentLoopVerificationError:
    LocalizedError, Equatable {
    case authorizationRequired
    case unsupportedVersion
    case unsafeConfiguration
    case configurationChanged
    case probeFailed(V011AgentLoopFailureStage)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "需要先确认本次联网和可能产生的一次API费用"
        case .unsupportedVersion:
            return "当前Codex版本尚未通过真实任务验证合同"
        case .unsafeConfiguration:
            return "当前Codex配置无法安全复制到隔离验证环境"
        case .configurationChanged:
            return "验证期间Codex设置发生变化，本次结果已作废"
        case let .probeFailed(stage):
            return "\(stage.userTitle)。\(stage.userAction)"
        }
    }
}

protocol V011AgentLoopVerifying {
    func verify(
        userConsented: Bool,
        expectedProviderID: String?,
        expectedConfigHash: String?
    ) throws -> V011AgentLoopProbeResult

    func receiptMatchesCurrent(
        _ receipt: V011AgentLoopReceipt,
        live: LiveCodexState,
        now: Date
    ) -> Bool
}

struct V011AgentLoopTraceAnalysis: Equatable, Sendable {
    let outcome: V011AgentLoopOutcome
    let failureStage: V011AgentLoopFailureStage?
    let eventStructureSHA256: String
    let toolCallCount: Int
}

enum V011AgentLoopTraceAnalyzer {
    static func analyze(
        _ data: Data,
        marker: String,
        terminationStatus: Int32
    ) -> V011AgentLoopTraceAnalysis {
        let text = String(decoding: data, as: UTF8.self)
        var turnStarted = false
        var toolStarted = false
        var toolCompleted = false
        var toolOutputObserved = false
        var continuationObserved = false
        var finalResponseObserved = false
        var turnCompleted = false
        var toolCallCount = 0
        var structure: [String] = []

        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                    with: lineData
                  ) as? [String: Any] else {
                structure.append("invalid-json")
                continue
            }
            let eventType = object["type"] as? String ?? "unknown"
            let item = object["item"] as? [String: Any]
            let itemType = item?["type"] as? String ?? "none"
            let status = item?["status"] as? String ?? "none"
            let exitClass: String
            if let exitCode = item?["exit_code"] as? Int {
                exitClass = exitCode == 0 ? "zero" : "nonzero"
            } else {
                exitClass = "none"
            }
            structure.append(
                "\(eventType)|\(itemType)|\(status)|\(exitClass)"
            )

            if eventType == "turn.started" {
                turnStarted = true
            }
            if itemType == "command_execution" {
                if eventType == "item.started", turnStarted {
                    toolStarted = true
                    toolCallCount += 1
                }
                if eventType == "item.completed",
                   toolStarted,
                   (item?["exit_code"] as? Int) == 0 {
                    toolCompleted = true
                    toolOutputObserved = containsOutput(
                        marker,
                        in: item ?? [:]
                    )
                }
            }
            if eventType == "item.completed",
               itemType == "agent_message",
               toolCompleted,
               toolOutputObserved,
               let response = item?["text"] as? String {
                continuationObserved = true
                if response.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) == marker {
                    finalResponseObserved = true
                }
            }
            if eventType == "turn.completed",
               finalResponseObserved {
                turnCompleted = true
            }
        }

        let failureStage: V011AgentLoopFailureStage?
        if terminationStatus != 0 || !turnStarted {
            failureStage = .initialResponse
        } else if !toolStarted {
            failureStage = .toolCall
        } else if !toolCompleted || !toolOutputObserved {
            failureStage = .toolExecution
        } else if !continuationObserved {
            failureStage = .continuation
        } else if !finalResponseObserved || !turnCompleted {
            failureStage = .finalResponse
        } else {
            failureStage = nil
        }
        return V011AgentLoopTraceAnalysis(
            outcome: failureStage == nil ? .passed : .failed,
            failureStage: failureStage,
            eventStructureSHA256: V011AgentLoopReceipt.sha256(
                Data(structure.joined(separator: "\n").utf8)
            ),
            toolCallCount: toolCallCount
        )
    }

    private static func containsOutput(
        _ marker: String,
        in item: [String: Any]
    ) -> Bool {
        for key in ["aggregated_output", "output", "stdout"] {
            if let value = item[key], contains(marker, in: value) {
                return true
            }
        }
        return false
    }

    private static func contains(
        _ marker: String,
        in value: Any
    ) -> Bool {
        if let text = value as? String {
            return text.contains(marker)
        }
        if let values = value as? [Any] {
            return values.contains { contains(marker, in: $0) }
        }
        if let object = value as? [String: Any] {
            return object.values.contains {
                contains(marker, in: $0)
            }
        }
        return false
    }
}

struct V011LiveAgentLoopVerifier:
    V011AgentLoopVerifying, @unchecked Sendable {
    static let maximumConfigurationBytes = 2 * 1024 * 1024
    static let maximumAuthenticationBytes = 2 * 1024 * 1024
    static let maximumCapturedBytes = 512 * 1024
    static let evidenceLifetime: TimeInterval = 24 * 60 * 60

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
        commandRunner: any FableCommandRunning = FableSystemCommandRunner(),
        binaryHasher: any CodexBinaryHashing = CodexBinarySHA256Hasher(),
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
        userConsented: Bool,
        expectedProviderID: String?,
        expectedConfigHash: String?
    ) throws -> V011AgentLoopProbeResult {
        guard userConsented else {
            throw V011AgentLoopVerificationError
                .authorizationRequired
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let observedAt = now()
        let installation = try versionDiscovery.discover()
        guard installation.support.allowsWrites,
              let entry = installation.contractEntry,
              entry.matches(installation.identity),
              let executionProtocol =
                installation.agentLoopExecutionProtocol else {
            throw V011AgentLoopVerificationError
                .unsupportedVersion
        }
        let configURL = codexHome.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
        let configData = try boundedRegularFile(
            configURL,
            maximumBytes: Self.maximumConfigurationBytes,
            required: true
        ) ?? Data()
        let configHash = V011AgentLoopReceipt.sha256(configData)
        guard expectedConfigHash.map({ $0 == configHash }) != false,
              let configuration = try? TOMLSemanticEngine.parse(
                String(decoding: configData, as: UTF8.self)
              ),
              let model = configuration.rootString("model")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        let providerID = configuration.rootString(
            "model_provider"
        ) ?? "openai"
        guard expectedProviderID.map({ $0 == providerID }) != false else {
            throw V011AgentLoopVerificationError
                .configurationChanged
        }
        let endpointHost = try endpointHost(
            configuration: configuration,
            providerID: providerID
        )
        let cliSHA256 = try binaryHasher.sha256(
            of: installation.cliURL
        )
        let marker = "AI_ACCESS_AGENT_LOOP_OK_"
            + UUID().uuidString.replacingOccurrences(
                of: "-",
                with: ""
            )
        let sandboxRoot = temporaryRoot.appendingPathComponent(
            "ai-access-agent-loop-\(UUID().uuidString)",
            isDirectory: true
        ).standardizedFileURL
        guard sandboxRoot.deletingLastPathComponent()
                == temporaryRoot else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }

        var analysis = V011AgentLoopTraceAnalysis(
            outcome: .failed,
            failureStage: .preparation,
            eventStructureSHA256:
                V011AgentLoopReceipt.sha256(
                    Data("preparation".utf8)
                ),
            toolCallCount: 0
        )
        var configurationChanged = false
        do {
            try prepareSandbox(
                sandboxRoot,
                configData: configData
            )
            let tempHome = sandboxRoot.appendingPathComponent(
                "home",
                isDirectory: true
            )
            let tempCodexHome = sandboxRoot.appendingPathComponent(
                "codex-home",
                isDirectory: true
            )
            let workspace = sandboxRoot.appendingPathComponent(
                "workspace",
                isDirectory: true
            )
            let prompt = """
            This is a deterministic local verification. Use the shell tool to write \(marker) to .ai-access-agent-loop, then use the shell tool to read that file. Only after the tool output is returned, reply exactly \(marker). Do not inspect any other path and do not use the network except for the configured model request.
            """
            do {
                let arguments = [
                    "exec",
                    "-c", "mcp_servers={}",
                    "--ephemeral",
                    "--ignore-rules",
                    "--skip-git-repo-check",
                ] + executionProtocol.commandArguments + [
                    "--color", "never",
                    "--json",
                    "-C", workspace.path,
                    prompt,
                ]
                let result = try commandRunner.run(
                    executable: installation.cliURL,
                    arguments: arguments,
                    environmentOverrides: [
                        "HOME": tempHome.path,
                        "CODEX_HOME": tempCodexHome.path,
                        "TMPDIR": sandboxRoot.path,
                    ],
                    timeout: 90,
                    maximumCapturedBytes:
                        Self.maximumCapturedBytes
                )
                analysis = V011AgentLoopTraceAnalyzer.analyze(
                    result.standardOutput,
                    marker: marker,
                    terminationStatus: result.terminationStatus
                )
            } catch {
                analysis = V011AgentLoopTraceAnalysis(
                    outcome: .failed,
                    failureStage: .initialResponse,
                    eventStructureSHA256:
                        V011AgentLoopReceipt.sha256(
                            Data("command-error".utf8)
                        ),
                    toolCallCount: 0
                )
            }
            let currentData = try boundedRegularFile(
                configURL,
                maximumBytes: Self.maximumConfigurationBytes,
                required: true
            ) ?? Data()
            configurationChanged =
                V011AgentLoopReceipt.sha256(currentData)
                    != configHash
        } catch {
            analysis = V011AgentLoopTraceAnalysis(
                outcome: .failed,
                failureStage: .preparation,
                eventStructureSHA256:
                    V011AgentLoopReceipt.sha256(
                        Data("preparation-error".utf8)
                    ),
                toolCallCount: 0
            )
        }

        let cleanupFailed: Bool
        do {
            if fileManager.fileExists(atPath: sandboxRoot.path) {
                try fileManager.removeItem(at: sandboxRoot)
            }
            cleanupFailed = false
        } catch {
            cleanupFailed = true
        }
        let failureStage: V011AgentLoopFailureStage?
        if cleanupFailed {
            failureStage = .cleanup
        } else if configurationChanged {
            failureStage = .configurationChanged
        } else {
            failureStage = analysis.failureStage
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let receipt = V011AgentLoopReceipt(
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(
                Self.evidenceLifetime
            ),
            durationMilliseconds: Double(elapsed) / 1_000_000,
            providerID: providerID,
            endpointHost: endpointHost,
            modelID: model,
            configHash: configHash,
            codexAppVersion: installation.identity.appVersion,
            codexAppBuild: installation.identity.appBuild,
            codexCLIVersion: installation.identity.cliVersion,
            codexCLISHA256: cliSHA256,
            outcome: failureStage == nil ? .passed : .failed,
            failureStage: failureStage,
            eventStructureSHA256:
                analysis.eventStructureSHA256,
            toolCallCount: analysis.toolCallCount
        )
        guard receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return V011AgentLoopProbeResult(receipt: receipt)
    }

    func receiptMatchesCurrent(
        _ receipt: V011AgentLoopReceipt,
        live: LiveCodexState,
        now: Date
    ) -> Bool {
        guard receipt.isStructurallyValid,
              receipt.outcome == .passed,
              receipt.expiresAt > now,
              receipt.configHash == live.configHash,
              receipt.providerID
                == V011AgentLoopReceipt.providerID(live),
              receipt.endpointHost
                == V011AgentLoopReceipt.endpointHost(live),
              receipt.modelID == live.model,
              receipt.codexAppVersion == live.version.appVersion,
              receipt.codexAppBuild == live.version.appBuild,
              receipt.codexCLIVersion == live.version.cliVersion,
              let installation = try? versionDiscovery.discover(),
              installation.identity == live.version,
              let currentHash = try? binaryHasher.sha256(
                of: installation.cliURL
              ) else {
            return false
        }
        return currentHash == receipt.codexCLISHA256
    }

    private func prepareSandbox(
        _ root: URL,
        configData: Data
    ) throws {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for name in ["home", "codex-home", "workspace"] {
            let directory = root.appendingPathComponent(
                name,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let tempCodexHome = root.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        try configData.write(
            to: tempCodexHome.appendingPathComponent("config.toml"),
            options: [.atomic]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempCodexHome
                .appendingPathComponent("config.toml").path
        )
        let authURL = codexHome.appendingPathComponent(
            "auth.json",
            isDirectory: false
        )
        if let authData = try boundedRegularFile(
            authURL,
            maximumBytes: Self.maximumAuthenticationBytes,
            required: false
        ) {
            let target = tempCodexHome.appendingPathComponent(
                "auth.json",
                isDirectory: false
            )
            try authData.write(to: target, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: target.path
            )
        }
    }

    private func boundedRegularFile(
        _ url: URL,
        maximumBytes: Int,
        required: Bool
    ) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            if required {
                throw V011AgentLoopVerificationError
                    .unsafeConfiguration
            }
            return nil
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
              size <= maximumBytes else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func endpointHost(
        configuration: TOMLSemanticDocument,
        providerID: String
    ) throws -> String? {
        guard providerID != "openai" else { return nil }
        guard let baseURL = configuration.string(at: [
            "model_providers", providerID, "base_url",
        ]),
        let components = URLComponents(string: baseURL),
        components.scheme?.lowercased() == "https",
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        let host = components.host,
        !host.isEmpty else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return components.port.map {
            "\(host.lowercased()):\($0)"
        } ?? host.lowercased()
    }
}

struct V011AgentLoopReceiptStore {
    static let maximumBytes = 128 * 1024

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

    func load() throws -> V011AgentLoopReceipt? {
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
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        let receipt = try JSONDecoder().decode(
            V011AgentLoopReceipt.self,
            from: Data(contentsOf: fileURL)
        )
        guard receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return receipt
    }

    func commit(_ receipt: V011AgentLoopReceipt) throws {
        guard receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
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
        let data = try encoder.encode(receipt)
        guard data.count <= Self.maximumBytes else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        try writer.write(
            data,
            to: fileURL,
            expectedCurrentHash:
                SessionSyncFileSafety.hashIfPresent(fileURL)
        )
    }
}

final class V011AgentLoopRepairRecorder:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: V011AgentLoopProbeResult?

    func record(_ result: V011AgentLoopProbeResult) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    var result: V011AgentLoopProbeResult? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}

struct V011AgentLoopRepairRuntimeVerifier:
    FableRuntimeVerifier, @unchecked Sendable {
    let base: any FableRuntimeVerifier
    let agentLoopVerifier: any V011AgentLoopVerifying
    let receiptStore: V011AgentLoopReceiptStore
    let recorder: V011AgentLoopRepairRecorder

    func verifyOfficial() throws {
        try base.verifyOfficial()
        try verifyAgentLoop(providerID: "openai")
    }

    func verifyRelay(_ profile: RelayProfile) throws {
        try base.verifyRelay(profile)
        try verifyAgentLoop(providerID: profile.providerID)
    }

    private func verifyAgentLoop(providerID: String) throws {
        let result = try agentLoopVerifier.verify(
            userConsented: true,
            expectedProviderID: providerID,
            expectedConfigHash: nil
        )
        recorder.record(result)
        try receiptStore.commit(result.receipt)
        guard result.receipt.outcome == .passed else {
            throw V011AgentLoopVerificationError.probeFailed(
                result.receipt.failureStage ?? .finalResponse
            )
        }
    }
}
