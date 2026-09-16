// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreFoundation

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
            return "真实任务验证未完成"
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
            return "现有记录未保留具体原因，不能确认请求是否发出或是否消耗额度。请查看高级诊断。"
        case .toolCall:
            return "当前模型或中转可能只支持普通回复，不能证明可完成Codex任务。"
        case .toolExecution:
            return "检查Codex工具权限与沙箱；助手不会扩大权限或绕过审批。"
        case .continuation:
            return "当前中转可能不能正确回传工具结果；请核对Responses兼容性。"
        case .finalResponse:
            return "当前链路返回不完整；请核对模型与Responses兼容性。"
        case .configurationChanged:
            return "本次证据已作废。重新读取当前状态；若再次变化，仅说明证据仍未稳定，不会停止进程、修改配置或自动重试。"
        case .cleanup:
            return "退出助手后重开；过期临时目录会由助手清理。"
        }
    }
}

struct V011AgentLoopProbeResult: Equatable, Sendable {
    let receipt: V011AgentLoopReceipt
    let completedUsage: V012CompletedTurnUsage?

    init(
        receipt: V011AgentLoopReceipt,
        completedUsage: V012CompletedTurnUsage? = nil
    ) {
        self.receipt = receipt
        self.completedUsage = completedUsage
    }

    var safeMessage: String {
        if let reason = receipt.failureReason {
            return "\(reason.userTitle)。\(reason.userAction)"
        }
        guard let stage = receipt.failureStage else {
            return "真实任务闭环已通过：模型调用了本机工具、接收工具结果并完成续答。"
        }
        return "\(stage.userTitle)。\(stage.userAction)"
    }
}

struct V011AgentLoopExecUsage: Equatable, Sendable {
    let threadID: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64

    var isStructurallyValid: Bool {
        !threadID.isEmpty
            && threadID.utf8.count <= 256
            && !threadID.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
            && [
                inputTokens,
                cachedInputTokens,
                outputTokens,
                reasoningOutputTokens,
            ].allSatisfy { $0 >= 0 }
            && cachedInputTokens <= inputTokens
            && cacheWriteInputTokens.map {
                $0 >= 0 && cachedInputTokens + $0 <= inputTokens
            } != false
            && reasoningOutputTokens <= outputTokens
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
        expectedRouteIdentity: V011AgentLoopRouteIdentity?
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
    let toolCallCount: Int
    let execUsage: V011AgentLoopExecUsage?
    var failureReason: V011AgentLoopFailureReason? = nil
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
        var threadID: String?
        var execUsage: V011AgentLoopExecUsage?
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                    with: lineData
                  ) as? [String: Any] else {
                continue
            }
            let eventType = object["type"] as? String ?? "unknown"
            let item = object["item"] as? [String: Any]
            let itemType = item?["type"] as? String ?? "none"

            if eventType == "thread.started",
               let value = object["thread_id"] as? String {
                threadID = value
            }
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
                execUsage = parseExecUsage(
                    object["usage"],
                    threadID: threadID
                )
            }
        }

        let failureStage: V011AgentLoopFailureStage?
        if !turnStarted {
            failureStage = .initialResponse
        } else if !toolStarted {
            failureStage = .toolCall
        } else if !toolCompleted || !toolOutputObserved {
            failureStage = .toolExecution
        } else if !continuationObserved {
            failureStage = .continuation
        } else if !finalResponseObserved || !turnCompleted || terminationStatus != 0 {
            failureStage = .finalResponse
        } else {
            failureStage = nil
        }
        return V011AgentLoopTraceAnalysis(
            outcome: failureStage == nil ? .passed : .failed,
            failureStage: failureStage,
            toolCallCount: toolCallCount,
            execUsage: failureStage == nil ? execUsage : nil,
            failureReason: terminationStatus != 0 ? .processExit : nil
        )
    }

    static func parseExecUsage(
        _ value: Any?,
        threadID: String?
    ) -> V011AgentLoopExecUsage? {
        guard let threadID,
              let usage = value as? [String: Any],
              let input = nonnegativeInteger(usage["input_tokens"]),
              let cached = nonnegativeInteger(
                usage["cached_input_tokens"]
              ),
              let output = nonnegativeInteger(usage["output_tokens"])
        else { return nil }
        let result = V011AgentLoopExecUsage(
            threadID: threadID,
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: nonnegativeInteger(
                usage["cache_write_input_tokens"]
            ) ?? (usage["cache_write_input_tokens"] == nil ? 0 : nil),
            outputTokens: output,
            reasoningOutputTokens: nonnegativeInteger(
                usage["reasoning_output_tokens"]
            ) ?? 0
        )
        return result.isStructurallyValid ? result : nil
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double <= Double(Int64.max),
              double.rounded() == double else { return nil }
        return Int64(double)
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
    let fileManager: FileManager
    let now: @Sendable () -> Date
    let temporaryRoot: URL

    init(
        codexHome: URL,
        versionDiscovery: any FableCodexVersionDiscovering,
        commandRunner: any FableCommandRunning = FableSystemCommandRunner(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.versionDiscovery = versionDiscovery
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.now = now
        self.temporaryRoot = temporaryRoot.standardizedFileURL
    }

    func verify(
        userConsented: Bool,
        expectedRouteIdentity: V011AgentLoopRouteIdentity?
    ) throws -> V011AgentLoopProbeResult {
        guard userConsented else {
            throw V011AgentLoopVerificationError
                .authorizationRequired
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let observedAt = now()
        let installation = try versionDiscovery.discover()
        guard installation.support.allowsWrites,
              let runtimeIdentity =
                V011AgentLoopRuntimeIdentity(
                    installation: installation
                ) else {
            throw V011AgentLoopVerificationError
                .unsupportedVersion
        }
        let executionProtocol = runtimeIdentity.executionProtocol
        let configURL = codexHome.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
        let configData = try boundedRegularFile(
            configURL,
            maximumBytes: Self.maximumConfigurationBytes,
            required: true
        ) ?? Data()
        let routeIdentity = try V011AgentLoopRouteIdentity(
            configurationData: configData
        )
        guard routeIdentity.modelID != nil else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        guard expectedRouteIdentity.map({
            $0 == routeIdentity
        }) != false else {
            throw V011AgentLoopVerificationError
                .configurationChanged
        }
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
            toolCallCount: 0,
            execUsage: nil
        )
        var completedUsage: V012CompletedTurnUsage?
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
                    // Persist only inside the disposable CODEX_HOME so the
                    // verified usage reader can retain non-sensitive call facts.
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
                let completedAt = now()
                if let usage = analysis.execUsage,
                   let model = routeIdentity.modelID {
                    completedUsage = V012CompletedTurnUsage(
                        id: V011AgentLoopReceipt.sha256(
                            Data(usage.threadID.utf8)
                        ),
                        startedAt: observedAt,
                        completedAt: completedAt,
                        durationMilliseconds: Int64(
                            max(
                                0,
                                completedAt.timeIntervalSince(observedAt)
                                    * 1_000
                            )
                        ),
                        timeToFirstTokenMilliseconds: nil,
                        model: model,
                        providerID: routeIdentity.providerID,
                        serviceTier: "unknown",
                        calls: [
                            V012UpstreamTokenUsage(
                                observedAt: completedAt,
                                inputTokens: usage.inputTokens,
                                cachedInputTokens:
                                    usage.cachedInputTokens,
                                cacheWriteInputTokens:
                                    usage.cacheWriteInputTokens,
                                outputTokens: usage.outputTokens,
                                reasoningOutputTokens:
                                    usage.reasoningOutputTokens,
                                activeContextTokens: nil,
                                rateLimit: nil,
                                creditBalance: nil
                            ),
                        ]
                    )
                    completedUsage?.containsOnlyTurnTotals = true
                    if let total = completedUsage {
                        completedUsage = V012VerifiedExecUsage.read(
                            codexHome: tempCodexHome,
                            expected: total
                        ) ?? total
                        completedUsage?.sourceThreadID = usage.threadID
                        completedUsage?.sourceThreadIDHash = V011AgentLoopReceipt.sha256(
                            Data(usage.threadID.utf8))
                    }
                }
            } catch {
                analysis = V011AgentLoopTraceAnalysis(
                    outcome: .failed,
                    failureStage: .initialResponse,
                    toolCallCount: 0,
                    execUsage: nil,
                    failureReason: V011AgentLoopFailureReason(commandError: error)
                )
            }
            let currentData = try boundedRegularFile(
                configURL,
                maximumBytes: Self.maximumConfigurationBytes,
                required: true
            ) ?? Data()
            configurationChanged = (
                try? V011AgentLoopRouteIdentity(
                    configurationData: currentData
                )
            ) != routeIdentity
        } catch {
            analysis = V011AgentLoopTraceAnalysis(
                outcome: .failed,
                failureStage: .preparation,
                toolCallCount: 0,
                execUsage: nil
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
            routeIdentity: routeIdentity,
            runtimeIdentity: runtimeIdentity,
            outcome: failureStage == nil ? .passed : .failed,
            failureStage: failureStage,
            toolCallCount: analysis.toolCallCount,
            failureReason: failureStage == analysis.failureStage ? analysis.failureReason : nil
        )
        guard receipt.isStructurallyValid else {
            throw V011AgentLoopVerificationError
                .unsafeConfiguration
        }
        return V011AgentLoopProbeResult(
            receipt: receipt,
            completedUsage: failureStage == nil ? completedUsage : nil
        )
    }

    func receiptMatchesCurrent(
        _ receipt: V011AgentLoopReceipt,
        live: LiveCodexState,
        now: Date
    ) -> Bool {
        guard receipt.isStructurallyValid,
              receipt.outcome == .passed,
              receipt.expiresAt > now,
              receipt.targets(live),
              let installation = try? versionDiscovery.discover(),
              installation.identity == live.version,
              let runtimeIdentity =
                V011AgentLoopRuntimeIdentity(
                    installation: installation
                ),
              runtimeIdentity == receipt.runtimeIdentity else {
            return false
        }
        return true
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
            expectedRouteIdentity: nil
        )
        guard result.receipt.providerID == providerID else {
            throw V011AgentLoopVerificationError
                .configurationChanged
        }
        recorder.record(result)
        try receiptStore.commit(result.receipt)
        guard result.receipt.outcome == .passed else {
            throw V011AgentLoopVerificationError.probeFailed(
                result.receipt.failureStage ?? .finalResponse
            )
        }
    }
}
