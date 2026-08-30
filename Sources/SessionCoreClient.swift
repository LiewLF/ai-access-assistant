// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

enum SessionCoreCommand: String, Codable, Sendable {
    case list
    case search
    case workspaces
    case workspaceDetails = "workspace-details"
    case workspaceSessions = "workspace-sessions"
    case pending
    case clearPrewriteLock = "clear-prewrite-lock"
    case inspect
    case repair
    case rollback
    case `import`
}

enum SessionCoreProgressPhase: String, Codable, Sendable {
    case inspect
    case rollouts
    case sqlite
    case commit
}

enum SessionCoreProcessKind: Equatable, Sendable {
    case readOnly
    case transaction
}

struct SessionCoreProgress: Codable, Equatable, Sendable {
    let phase: SessionCoreProgressPhase
    let current: Int
    let total: Int
}

enum SessionCoreJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SessionCoreJSONValue])
    case array([SessionCoreJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: SessionCoreJSONValue].self
        ) {
            self = .object(value)
        } else if let value = try? container.decode(
            [SessionCoreJSONValue].self
        ) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct SessionCoreSession: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let currentProvider: String
    let archived: Bool
    let createdAt: SessionCoreJSONValue
    let updatedAt: SessionCoreJSONValue
    let rolloutPath: String
}

struct SessionCoreSessionPage: Codable, Equatable, Sendable {
    let databasePath: String
    let total: Int
    let visibleTotal: Int?
    let limit: Int
    let offset: Int
    let hasMore: Bool
    let sessions: [SessionCoreSession]
}

struct SessionCoreWorkspace: Codable, Equatable, Sendable {
    let cwd: String
    let sessionCount: Int
    let archivedCount: Int
    let latestUpdatedAt: SessionCoreJSONValue
}

struct SessionCoreWorkspacePage: Codable, Equatable, Sendable {
    let databasePath: String
    let total: Int
    let limit: Int
    let offset: Int
    let hasMore: Bool
    let workspaces: [SessionCoreWorkspace]
}

struct SessionCorePendingJournal: Codable, Equatable, Sendable {
    let transactionID: String
    let journalPath: String?
    let prewrite: Bool

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transactionId"
        case journalPath
        case prewrite
    }
}

struct SessionCoreClearedPrewriteLock: Codable, Equatable, Sendable {
    let transactionID: String
    let cleared: Bool

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transactionId"
        case cleared
    }
}

private struct SessionCorePendingJournalResult: Decodable, Sendable {
    let journal: SessionCorePendingJournal?
}

struct SessionCoreInspection: Codable, Equatable, Sendable {
    let codexHome: String
    let databasePath: String
    let targetProvider: String
    let rolloutFiles: Int
    let sessionMetaRecords: Int
    let rolloutFilesNeedingRepair: Int
    let encryptedContentFiles: Int
    let sqliteThreads: Int
    let sqliteProviderMismatches: Int
    let sqliteUserEventMismatches: Int
    let sqliteCwdMismatches: Int
    let needsRepair: Bool
    let estimatedJournalBytes: UInt64?
    let journalLimitBytes: UInt64?
    let rolloutPatchCount: Int?
    let capacitySafe: Bool?

    init(
        codexHome: String,
        databasePath: String,
        targetProvider: String,
        rolloutFiles: Int,
        sessionMetaRecords: Int,
        rolloutFilesNeedingRepair: Int,
        encryptedContentFiles: Int,
        sqliteThreads: Int,
        sqliteProviderMismatches: Int,
        sqliteUserEventMismatches: Int,
        sqliteCwdMismatches: Int,
        needsRepair: Bool,
        estimatedJournalBytes: UInt64? = nil,
        journalLimitBytes: UInt64? = nil,
        rolloutPatchCount: Int? = nil,
        capacitySafe: Bool? = nil
    ) {
        self.codexHome = codexHome
        self.databasePath = databasePath
        self.targetProvider = targetProvider
        self.rolloutFiles = rolloutFiles
        self.sessionMetaRecords = sessionMetaRecords
        self.rolloutFilesNeedingRepair = rolloutFilesNeedingRepair
        self.encryptedContentFiles = encryptedContentFiles
        self.sqliteThreads = sqliteThreads
        self.sqliteProviderMismatches = sqliteProviderMismatches
        self.sqliteUserEventMismatches = sqliteUserEventMismatches
        self.sqliteCwdMismatches = sqliteCwdMismatches
        self.needsRepair = needsRepair
        self.estimatedJournalBytes = estimatedJournalBytes
        self.journalLimitBytes = journalLimitBytes
        self.rolloutPatchCount = rolloutPatchCount
        self.capacitySafe = capacitySafe
    }
}

struct SessionCoreRepairSummary: Codable, Equatable, Sendable {
    let transactionID: String?
    let journalPath: String?
    let targetProvider: String
    let changedRolloutFiles: Int
    let changedSessionMetaRecords: Int
    let sqliteProviderRowsUpdated: Int
    let sqliteUserEventRowsUpdated: Int
    let sqliteCwdRowsUpdated: Int
    let noChanges: Bool

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transactionId"
        case journalPath
        case targetProvider
        case changedRolloutFiles
        case changedSessionMetaRecords
        case sqliteProviderRowsUpdated
        case sqliteUserEventRowsUpdated
        case sqliteCwdRowsUpdated
        case noChanges
    }
}

struct SessionCoreImportSummary: Codable, Equatable, Sendable {
    let transactionID: String
    let journalPath: String
    let importedSessions: Int
    let importedRolloutFiles: Int
    let conflictPolicy: String

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transactionId"
        case journalPath
        case importedSessions
        case importedRolloutFiles
        case conflictPolicy
    }
}

struct SessionCoreRollbackSummary: Codable, Equatable, Sendable {
    let transactionID: String
    let journalPath: String
    let restoredRolloutFiles: Int
    let databaseRestored: Bool
    let alreadyRolledBack: Bool

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transactionId"
        case journalPath
        case restoredRolloutFiles
        case databaseRestored
        case alreadyRolledBack
    }
}

enum SessionCoreClientError: Error, Equatable, LocalizedError {
    case executableUnavailable
    case unsafeExecutable
    case invalidCodexHome
    case invalidSourceRoot
    case invalidJournalRoot
    case invalidJournal
    case recoveryPointerChanged
    case journalCodexHomeMismatch
    case invalidJournalKey
    case invalidTransactionID
    case invalidProvider
    case invalidPagination
    case invalidSearchQuery
    case invalidWorkspacePath
    case invalidWorkspaceSelection
    case launchFailed
    case timedOut
    case outputTooLarge
    case inputWriteFailed
    case malformedProtocol
    case protocolVersionUnsupported(Int)
    case commandMismatch
    case missingResult
    case processFailed(status: Int32, stderrSummary: String?)
    case commandFailed(
        command: SessionCoreCommand,
        code: String,
        message: String
    )

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "历史会话组件尚未安装完整。"
        case .unsafeExecutable:
            return "历史会话组件未通过本机安全检查。"
        case .invalidCodexHome:
            return "Codex数据目录无效，操作已停止。"
        case .invalidSourceRoot:
            return "外部会话目录无效，或与当前Codex数据目录重叠。"
        case .invalidJournalRoot:
            return "恢复记录目录无效，操作已停止。"
        case .invalidJournal:
            return "恢复记录无效，操作已停止。"
        case .recoveryPointerChanged:
            return "恢复记录已变化，请重新检查后再操作。"
        case .journalCodexHomeMismatch:
            return "恢复记录不属于当前Codex数据目录，操作已停止。"
        case .invalidJournalKey:
            return "恢复密钥无效，操作已停止。"
        case .invalidTransactionID:
            return "恢复记录编号无效，操作已停止。"
        case .invalidProvider:
            return "当前模式标识无效，操作已停止。"
        case .invalidPagination:
            return "历史会话分页参数无效。"
        case .invalidSearchQuery:
            return "搜索词需为1到200个可见字符。"
        case .invalidWorkspacePath:
            return "工作目录需为1到4096个可见字符。"
        case .invalidWorkspaceSelection:
            return "一次只能读取1到20个工作区收藏。"
        case .launchFailed:
            return "历史会话组件无法启动。"
        case .timedOut:
            return "历史会话操作等待超时，未继续执行。"
        case .outputTooLarge:
            return "历史会话组件返回内容异常过大，操作已停止。"
        case .inputWriteFailed:
            return "恢复密钥未能安全交给历史会话组件，操作已停止。"
        case .malformedProtocol:
            return "历史会话组件返回了无法识别的结果。"
        case .protocolVersionUnsupported:
            return "历史会话组件版本与当前软件不兼容。"
        case .commandMismatch:
            return "历史会话组件返回了不匹配的操作结果。"
        case .missingResult:
            return "历史会话组件没有返回最终结果。"
        case .processFailed(_, let stderrSummary):
            return stderrSummary
                ?? "历史会话组件执行失败，错误输出已隐藏。"
        case .commandFailed(_, _, let message):
            return message
        }
    }
}

struct SessionCoreProcessResult: Sendable {
    let terminationStatus: Int32
    let standardError: Data
}

protocol SessionCoreProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        kind: SessionCoreProcessKind,
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int,
        standardOutputLine: @escaping @Sendable (Data) throws -> Void
    ) async throws -> SessionCoreProcessResult
}

struct SessionCoreClient: Sendable {
    static let protocolVersion = 1
    static let productionAcceptsExplicitExecutable = false
    static let maximumRecoveryJournalBytes = 64 * 1_024 * 1_024

    struct Limits: Equatable, Sendable {
        let timeout: TimeInterval
        let maximumStandardOutputBytes: Int
        let maximumStandardErrorBytes: Int

        static let `default` = Limits(
            timeout: 120,
            maximumStandardOutputBytes: 8 * 1024 * 1024,
            maximumStandardErrorBytes: 64 * 1024
        )
    }

    private let executableURL: URL
    private let bundleURL: URL?
    private let trustedRecoveryRoot: URL
    private let runner: any SessionCoreProcessRunning
    private let limits: Limits

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        runner: any SessionCoreProcessRunning =
            SessionCoreSystemProcessRunner(),
        limits: Limits = .default
    ) {
        self.executableURL =
            SessionCoreExecutableLocator.executableURL(
                bundleURL: bundleURL
            )
        self.bundleURL = bundleURL
        self.trustedRecoveryRoot =
            SessionCoreRecoveryRootLocator.rootURL()
        self.runner = runner
        self.limits = limits
    }

#if SESSION_CORE_CLIENT_STANDALONE_TEST
    init(
        testingExecutableURL: URL,
        testingRecoveryRoot: URL,
        runner: any SessionCoreProcessRunning =
            SessionCoreSystemProcessRunner(),
        limits: Limits = .default
    ) {
        self.executableURL = testingExecutableURL
        self.bundleURL = nil
        self.trustedRecoveryRoot = testingRecoveryRoot
        self.runner = runner
        self.limits = limits
    }
#endif

    func list(
        codexHome: URL,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> SessionCoreSessionPage {
        try await list(
            codexHome: codexHome,
            limit: limit,
            offset: offset,
            provider: nil
        )
    }

    func list(
        codexHome: URL,
        limit: Int = 50,
        offset: Int = 0,
        provider: String?
    ) async throws -> SessionCoreSessionPage {
        try await listPage(
            codexHome: codexHome,
            limit: limit,
            offset: offset,
            provider: provider,
            topLevelOnly: true
        )
    }

    func listAll(
        codexHome: URL,
        limit: Int = 50,
        offset: Int = 0,
        provider: String? = nil
    ) async throws -> SessionCoreSessionPage {
        try await listPage(
            codexHome: codexHome,
            limit: limit,
            offset: offset,
            provider: provider,
            topLevelOnly: false
        )
    }

    private func listPage(
        codexHome: URL,
        limit: Int,
        offset: Int,
        provider: String?,
        topLevelOnly: Bool
    ) async throws -> SessionCoreSessionPage {
        let home = try validateCodexHome(codexHome)
        guard (1...50).contains(limit), offset >= 0 else {
            throw SessionCoreClientError.invalidPagination
        }
        let validatedProvider = try provider.map(validateProvider)
        var arguments = [
            "list",
            "--codex-home", home.path,
            "--limit", String(limit),
            "--offset", String(offset),
        ]
        if topLevelOnly {
            arguments.append(contentsOf: [
                "--top-level-only", "true",
            ])
        }
        if let validatedProvider {
            arguments.append(contentsOf: [
                "--provider", validatedProvider,
            ])
        }
        return try await execute(
            command: .list,
            arguments: arguments,
            resultType: SessionCoreSessionPage.self
        )
    }

    func search(
        codexHome: URL,
        query: String,
        limit: Int = 50,
        offset: Int = 0,
        provider: String? = nil
    ) async throws -> SessionCoreSessionPage {
        let home = try validateCodexHome(codexHome)
        guard (1...50).contains(limit), offset >= 0 else {
            throw SessionCoreClientError.invalidPagination
        }
        let query = try validateSearchQuery(query)
        let validatedProvider = try provider.map(validateProvider)
        var arguments = [
            "search",
            "--codex-home", home.path,
            "--query", query,
            "--limit", String(limit),
            "--offset", String(offset),
            "--top-level-only", "true",
        ]
        if let validatedProvider {
            arguments.append(contentsOf: [
                "--provider", validatedProvider,
            ])
        }
        return try await execute(
            command: .search,
            arguments: arguments,
            resultType: SessionCoreSessionPage.self
        )
    }

    func listWorkspaces(
        codexHome: URL,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> SessionCoreWorkspacePage {
        let home = try validateCodexHome(codexHome)
        guard (1...50).contains(limit), offset >= 0 else {
            throw SessionCoreClientError.invalidPagination
        }
        return try await execute(
            command: .workspaces,
            arguments: [
                "workspaces",
                "--codex-home", home.path,
                "--limit", String(limit),
                "--offset", String(offset),
                "--top-level-only", "true",
            ],
            resultType: SessionCoreWorkspacePage.self
        )
    }

    func lookupWorkspaces(
        codexHome: URL,
        paths: [String]
    ) async throws -> SessionCoreWorkspacePage {
        let home = try validateCodexHome(codexHome)
        guard (1...20).contains(paths.count) else {
            throw SessionCoreClientError.invalidWorkspaceSelection
        }
        var normalized: [String] = []
        normalized.reserveCapacity(paths.count)
        for path in paths {
            let path = try validateWorkspacePath(path)
            if !normalized.contains(path) {
                normalized.append(path)
            }
        }
        let encoded = try JSONEncoder().encode(normalized)
        guard let payload = String(data: encoded, encoding: .utf8) else {
            throw SessionCoreClientError.malformedProtocol
        }
        return try await execute(
            command: .workspaceDetails,
            arguments: [
                "workspace-details",
                "--codex-home", home.path,
                "--top-level-only", "true",
                "--cwds-json", payload,
            ],
            resultType: SessionCoreWorkspacePage.self
        )
    }

    func listWorkspaceSessions(
        codexHome: URL,
        cwd: String,
        limit: Int = 50,
        offset: Int = 0,
        provider: String? = nil
    ) async throws -> SessionCoreSessionPage {
        let home = try validateCodexHome(codexHome)
        guard (1...50).contains(limit), offset >= 0 else {
            throw SessionCoreClientError.invalidPagination
        }
        let cwd = try validateWorkspacePath(cwd)
        let validatedProvider = try provider.map(validateProvider)
        var arguments = [
            "workspace-sessions",
            "--codex-home", home.path,
            "--cwd", cwd,
            "--limit", String(limit),
            "--offset", String(offset),
            "--top-level-only", "true",
        ]
        if let validatedProvider {
            arguments.append(contentsOf: [
                "--provider", validatedProvider,
            ])
        }
        return try await execute(
            command: .workspaceSessions,
            arguments: arguments,
            resultType: SessionCoreSessionPage.self
        )
    }

    func inspect(
        codexHome: URL,
        provider: String
    ) async throws -> SessionCoreInspection {
        let home = try validateCodexHome(codexHome)
        let provider = try validateProvider(provider)
        return try await execute(
            command: .inspect,
            arguments: [
                "inspect",
                "--codex-home", home.path,
                "--provider", provider,
            ],
            resultType: SessionCoreInspection.self
        )
    }

    func interruptedJournal(
        codexHome: URL,
        recoveryRoot: URL
    ) async throws -> SessionCorePendingJournal? {
        let home = try validateCodexHome(codexHome)
        let recoveryRoot = try validateRecoveryRoot(
            recoveryRoot,
            allowMissing: true
        )
        let result = try await execute(
            command: .pending,
            arguments: [
                "pending",
                "--codex-home", home.path,
                "--recovery-root", recoveryRoot.path,
            ],
            resultType: SessionCorePendingJournalResult.self
        )
        return result.journal
    }

    func clearStalePrewriteLock(
        codexHome: URL,
        recoveryRoot: URL,
        transactionID: String
    ) async throws -> SessionCoreClearedPrewriteLock {
        let home = try validateCodexHome(codexHome)
        let recoveryRoot = try validateRecoveryRoot(recoveryRoot)
        let transactionID = try validateTransactionID(
            transactionID
        )
        return try await execute(
            command: .clearPrewriteLock,
            arguments: [
                "clear-prewrite-lock",
                "--codex-home", home.path,
                "--recovery-root", recoveryRoot.path,
                "--transaction-id", transactionID,
            ],
            resultType: SessionCoreClearedPrewriteLock.self
        )
    }

    func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void =
            { _ in }
    ) async throws -> SessionCoreRepairSummary {
        try await repair(
            codexHome: codexHome,
            provider: provider,
            recoveryRoot: recoveryRoot,
            transactionID: nil,
            journalKey: journalKey,
            progress: progress
        )
    }

    func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        transactionID: String,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void =
            { _ in }
    ) async throws -> SessionCoreRepairSummary {
        try await repair(
            codexHome: codexHome,
            provider: provider,
            recoveryRoot: recoveryRoot,
            transactionID: Optional(transactionID),
            journalKey: journalKey,
            progress: progress
        )
    }

    private func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        transactionID: String?,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void
    ) async throws -> SessionCoreRepairSummary {
        let home = try validateCodexHome(codexHome)
        let provider = try validateProvider(provider)
        let recoveryRoot = try validateRecoveryRoot(recoveryRoot)
        let encodedJournalKey = try encodeJournalKey(journalKey)
        var arguments = [
            "repair",
            "--codex-home", home.path,
            "--provider", provider,
            "--journal-root", recoveryRoot.path,
        ]
        if let transactionID {
            arguments.append(contentsOf: [
                "--transaction-id",
                try validateTransactionID(transactionID),
            ])
        }
        arguments.append("--journal-key-stdin")
        return try await execute(
            command: .repair,
            arguments: arguments,
            standardInput: encodedJournalKey,
            resultType: SessionCoreRepairSummary.self,
            progress: progress
        )
    }

    func rollback(
        codexHome: URL,
        recoveryRoot: URL,
        journal: URL,
        journalKey: Data
    ) async throws -> SessionCoreRollbackSummary {
        let home = try validateCodexHome(codexHome)
        let recoveryRoot = try validateRecoveryRoot(recoveryRoot)
        let journal = try validateJournal(
            journal,
            belongsTo: home,
            inside: recoveryRoot
        )
        let encodedJournalKey = try encodeJournalKey(journalKey)
        return try await execute(
            command: .rollback,
            arguments: [
                "rollback",
                "--journal", journal.path,
                "--journal-key-stdin",
            ],
            standardInput: encodedJournalKey,
            resultType: SessionCoreRollbackSummary.self
        )
    }

    func importSessions(
        codexHome: URL,
        sourceRoot: URL,
        recoveryRoot: URL,
        transactionID: String,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void =
            { _ in }
    ) async throws -> SessionCoreImportSummary {
        let home = try validateCodexHome(codexHome)
        let source = try validateRealDirectory(
            sourceRoot,
            error: .invalidSourceRoot
        )
        guard !source.isWithinOrEqual(to: home),
              !home.isWithinOrEqual(to: source) else {
            throw SessionCoreClientError.invalidSourceRoot
        }
        let recoveryRoot = try validateRecoveryRoot(recoveryRoot)
        let transactionID = try validateTransactionID(
            transactionID
        )
        let encodedJournalKey = try encodeJournalKey(journalKey)
        return try await execute(
            command: .import,
            arguments: [
                "import",
                "--codex-home", home.path,
                "--source-root", source.path,
                "--journal-root", recoveryRoot.path,
                "--transaction-id", transactionID,
                "--journal-key-stdin",
            ],
            standardInput: encodedJournalKey,
            resultType: SessionCoreImportSummary.self,
            progress: progress
        )
    }

    private func execute<Result: Decodable & Sendable>(
        command: SessionCoreCommand,
        arguments: [String],
        standardInput: Data? = nil,
        resultType: Result.Type,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void =
            { _ in }
    ) async throws -> Result {
        try validateExecutable()
        let accumulator = SessionCoreEventAccumulator(
            expectedCommand: command,
            progress: progress
        )
        let processResult: SessionCoreProcessResult
        do {
            processResult = try await runner.run(
                executableURL: executableURL,
                arguments: arguments,
                standardInput: standardInput,
                kind: command.processKind,
                timeout: limits.timeout,
                maximumStandardOutputBytes:
                    limits.maximumStandardOutputBytes,
                maximumStandardErrorBytes:
                    limits.maximumStandardErrorBytes,
                standardOutputLine: { line in
                    try accumulator.consume(line)
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SessionCoreProcessRunnerError {
            switch error {
            case .unsafeExecutable:
                throw SessionCoreClientError.unsafeExecutable
            case .launchFailed:
                throw SessionCoreClientError.launchFailed
            case .timedOut:
                throw SessionCoreClientError.timedOut
            case .outputTooLarge:
                throw SessionCoreClientError.outputTooLarge
            case .inputWriteFailed:
                throw SessionCoreClientError.inputWriteFailed
            case .lineHandlerFailed(let underlying):
                if let clientError =
                    underlying as? SessionCoreClientError {
                    throw clientError
                }
                throw SessionCoreClientError.malformedProtocol
            }
        }

        let outcome = try accumulator.finish()
        if let failure = outcome.failure {
            guard processResult.terminationStatus != 0 else {
                throw SessionCoreClientError.malformedProtocol
            }
            throw SessionCoreClientError.commandFailed(
                command: command,
                code: failure.code,
                message: SessionCoreMessageRedactor.redact(
                    failure.message,
                    sensitiveValues: standardInput.flatMap {
                        String(data: $0, encoding: .utf8)
                    }.map { [$0] } ?? []
                )
            )
        }
        guard processResult.terminationStatus == 0 else {
            throw SessionCoreClientError.processFailed(
                status: processResult.terminationStatus,
                stderrSummary: SessionCoreMessageRedactor.stderrSummary(
                    processResult.standardError
                )
            )
        }
        guard let data = outcome.resultData else {
            throw SessionCoreClientError.missingResult
        }
        do {
            return try JSONDecoder().decode(resultType, from: data)
        } catch {
            throw SessionCoreClientError.malformedProtocol
        }
    }

    private func validateExecutable() throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/") else {
            throw SessionCoreClientError.executableUnavailable
        }
        guard let values = try? executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            throw SessionCoreClientError.executableUnavailable
        }
        if let bundleURL {
            guard verifiesCodeSignature(executableURL),
                  verifiesCodeSignature(bundleURL) else {
                throw SessionCoreClientError.unsafeExecutable
            }
        }
    }

    private func validateCodexHome(_ url: URL) throws -> URL {
        let normalized = try validateExplicitAbsoluteURL(
            url,
            error: .invalidCodexHome
        )
        guard let values = try? normalized.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            throw SessionCoreClientError.invalidCodexHome
        }
        return normalized.resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func validateProvider(_ provider: String) throws -> String {
        guard !provider.isEmpty,
              provider.unicodeScalars.allSatisfy({
                  guard $0.isASCII else { return false }
                  return (48...57).contains($0.value)
                      || (65...90).contains($0.value)
                      || (97...122).contains($0.value)
                      || "._-".unicodeScalars.contains($0)
              }) else {
            throw SessionCoreClientError.invalidProvider
        }
        return provider
    }

    private func validateSearchQuery(_ query: String) throws -> String {
        let trimmed = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard (1...200).contains(trimmed.count),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SessionCoreClientError.invalidSearchQuery
        }
        return trimmed
    }

    private func validateWorkspacePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard (1...4096).contains(trimmed.count),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SessionCoreClientError.invalidWorkspacePath
        }
        return trimmed
    }

    private func validateTransactionID(
        _ transactionID: String
    ) throws -> String {
        guard let parsed = UUID(uuidString: transactionID),
              parsed.uuidString.lowercased()
                == transactionID.lowercased() else {
            throw SessionCoreClientError.invalidTransactionID
        }
        return transactionID.lowercased()
    }

    private func encodeJournalKey(_ journalKey: Data) throws -> Data {
        guard journalKey.count == 32 else {
            throw SessionCoreClientError.invalidJournalKey
        }
        return journalKey.base64EncodedData()
    }

    private func verifiesCodeSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &code
        ) == errSecSuccess,
        let code else {
            return false
        }
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

    private func validateExplicitAbsoluteURL(
        _ url: URL,
        error: SessionCoreClientError
    ) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw error
        }
        return url.standardizedFileURL
    }

    private func validateJournal(
        _ url: URL,
        belongsTo codexHome: URL,
        inside recoveryRoot: URL
    ) throws -> URL {
        let explicit = try validateExplicitAbsoluteURL(
            url,
            error: .invalidJournal
        )
        guard let originalValues = try? explicit.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        ),
        originalValues.isSymbolicLink != true else {
            throw SessionCoreClientError.invalidJournal
        }
        let manifest: URL
        if originalValues.isDirectory == true {
            manifest = explicit.appendingPathComponent("journal.json")
        } else if originalValues.isRegularFile == true {
            manifest = explicit
        } else {
            throw SessionCoreClientError.invalidJournal
        }
        guard let manifestValues = try? manifest.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        manifestValues.isRegularFile == true,
        manifestValues.isSymbolicLink != true,
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: manifest.path
        ),
        let size = attributes[.size] as? NSNumber,
        size.uint64Value <= UInt64(Self.maximumRecoveryJournalBytes),
        let data = try? readBoundedJournalData(manifest),
        let binding = try? JSONDecoder().decode(
            SessionCoreJournalBinding.self,
            from: data
        ),
        binding.version == 1 else {
            throw SessionCoreClientError.invalidJournal
        }
        let boundHome = try validateCodexHome(
            URL(fileURLWithPath: binding.codexHome)
        )
        guard boundHome.path == codexHome.path else {
            throw SessionCoreClientError.journalCodexHomeMismatch
        }
        let canonicalJournal = explicit.resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonicalJournal.isWithinOrEqual(
            to: recoveryRoot
        ) else {
            throw SessionCoreClientError.invalidJournal
        }
        return canonicalJournal
    }

    private func readBoundedJournalData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(
            min(Self.maximumRecoveryJournalBytes, 1_024 * 1_024)
        )
        while true {
            let remaining = Self.maximumRecoveryJournalBytes - data.count
            let readSize = min(64 * 1_024, remaining + 1)
            guard let chunk = try handle.read(upToCount: readSize),
                  !chunk.isEmpty else {
                return data
            }
            guard chunk.count <= remaining else {
                throw SessionCoreClientError.invalidJournal
            }
            data.append(chunk)
        }
    }

    private func validateRecoveryRoot(
        _ url: URL,
        allowMissing: Bool = false
    ) throws -> URL {
        let trusted = try validateRealDirectory(
            trustedRecoveryRoot,
            error: .invalidJournalRoot
        )
        let explicit = try validateExplicitAbsoluteURL(
            url,
            error: .invalidJournalRoot
        )
        let candidate: URL
        if allowMissing,
           !FileManager.default.fileExists(atPath: explicit.path) {
            candidate = explicit
        } else {
            candidate = try validateRealDirectory(
                explicit,
                error: .invalidJournalRoot
            )
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedCandidate.isWithinOrEqual(to: trusted) else {
            throw SessionCoreClientError.invalidJournalRoot
        }
        return resolvedCandidate
    }

    private func validateRealDirectory(
        _ url: URL,
        error: SessionCoreClientError
    ) throws -> URL {
        let explicit = try validateExplicitAbsoluteURL(
            url,
            error: error
        )
        guard let values = try? explicit.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            throw error
        }
        return explicit.resolvingSymlinksInPath()
            .standardizedFileURL
    }
}

enum SessionCoreExecutableLocator {
    static func executableURL(bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ai-access-session-core")
    }
}

private extension SessionCoreCommand {
    var processKind: SessionCoreProcessKind {
        switch self {
        case .list, .search, .workspaces, .workspaceDetails,
             .workspaceSessions,
             .pending, .inspect:
            return .readOnly
        case .clearPrewriteLock, .repair, .rollback, .import:
            return .transaction
        }
    }
}

enum SessionCoreRecoveryRootLocator {
    static func rootURL(
        applicationSupportURL: URL? = nil
    ) -> URL {
        let support = applicationSupportURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? URL(
                fileURLWithPath:
                    "/Library/Application Support",
                isDirectory: true
            )
        return support
            .appendingPathComponent(
                "AI接入助手",
                isDirectory: true
            )
            .appendingPathComponent(
                "ControlPlane",
                isDirectory: true
            )
            .appendingPathComponent(
                "SessionCoreRecovery",
                isDirectory: true
            )
    }
}

private struct SessionCoreJournalBinding: Decodable {
    let version: Int
    let codexHome: String
}

private struct SessionCoreWireEvent: Decodable {
    let schemaVersion: Int
    let event: String
    let command: String
    let ok: Bool
    let code: String?
    let message: String?
    let data: SessionCoreJSONValue?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case command
        case ok
        case code
        case message
        case data
    }
}

private struct SessionCoreFailure: Sendable {
    let code: String
    let message: String
}

private struct SessionCoreEventOutcome: Sendable {
    let resultData: Data?
    let failure: SessionCoreFailure?
}

private final class SessionCoreEventAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedCommand: SessionCoreCommand
    private let progress: @Sendable (SessionCoreProgress) -> Void
    private var started = false
    private var finished = false
    private var resultData: Data?
    private var failure: SessionCoreFailure?

    init(
        expectedCommand: SessionCoreCommand,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void
    ) {
        self.expectedCommand = expectedCommand
        self.progress = progress
    }

    func consume(_ line: Data) throws {
        let event: SessionCoreWireEvent
        do {
            event = try JSONDecoder().decode(
                SessionCoreWireEvent.self,
                from: line
            )
        } catch {
            throw SessionCoreClientError.malformedProtocol
        }
        guard event.schemaVersion == SessionCoreClient.protocolVersion else {
            throw SessionCoreClientError.protocolVersionUnsupported(
                event.schemaVersion
            )
        }
        guard event.command == expectedCommand.rawValue else {
            throw SessionCoreClientError.commandMismatch
        }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            throw SessionCoreClientError.malformedProtocol
        }
        switch event.event {
        case "start":
            guard !started, event.ok, event.data == nil,
                  event.code == nil, event.message == nil else {
                throw SessionCoreClientError.malformedProtocol
            }
            started = true
        case "progress":
            guard started,
                  expectedCommand == .repair
                    || expectedCommand == .import,
                  event.ok,
                  event.code == nil, event.message == nil,
                  let data = event.data else {
                throw SessionCoreClientError.malformedProtocol
            }
            let decoded = try decode(
                SessionCoreProgress.self,
                from: data
            )
            guard decoded.current >= 0,
                  decoded.total >= 0,
                  decoded.current <= decoded.total else {
                throw SessionCoreClientError.malformedProtocol
            }
            progress(decoded)
        case "result":
            guard started else {
                throw SessionCoreClientError.malformedProtocol
            }
            finished = true
            if event.ok {
                guard event.code == nil, event.message == nil,
                      let data = event.data else {
                    throw SessionCoreClientError.malformedProtocol
                }
                resultData = try JSONEncoder().encode(data)
            } else {
                guard event.data == nil,
                      let code = event.code, !code.isEmpty,
                      let message = event.message else {
                    throw SessionCoreClientError.malformedProtocol
                }
                failure = SessionCoreFailure(
                    code: code,
                    message: message
                )
            }
        default:
            throw SessionCoreClientError.malformedProtocol
        }
    }

    func finish() throws -> SessionCoreEventOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard started, finished else {
            throw SessionCoreClientError.missingResult
        }
        return SessionCoreEventOutcome(
            resultData: resultData,
            failure: failure
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from value: SessionCoreJSONValue
    ) throws -> T {
        do {
            return try JSONDecoder().decode(
                type,
                from: JSONEncoder().encode(value)
            )
        } catch {
            throw SessionCoreClientError.malformedProtocol
        }
    }
}

enum SessionCoreProcessRunnerError: Error {
    case unsafeExecutable
    case launchFailed
    case timedOut
    case outputTooLarge
    case inputWriteFailed
    case lineHandlerFailed(Error)
}

struct SessionCoreSystemProcessRunner: SessionCoreProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        kind: SessionCoreProcessKind,
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int,
        standardOutputLine: @escaping @Sendable (Data) throws -> Void
    ) async throws -> SessionCoreProcessResult {
        let controller = SessionCoreProcessController(kind: kind)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Repairing a large history is disk/CPU intensive. Use a
                // utility queue; progress remains delivered asynchronously.
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(
                            returning: try runBlocking(
                                executableURL: executableURL,
                                arguments: arguments,
                                standardInput: standardInput,
                                kind: kind,
                                timeout: timeout,
                                maximumStandardOutputBytes:
                                    maximumStandardOutputBytes,
                                maximumStandardErrorBytes:
                                    maximumStandardErrorBytes,
                                standardOutputLine:
                                    standardOutputLine,
                                controller: controller
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            controller.cancel()
        }
    }

    private func runBlocking(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        kind: SessionCoreProcessKind,
        timeout: TimeInterval,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int,
        standardOutputLine: @escaping @Sendable (Data) throws -> Void,
        controller: SessionCoreProcessController
    ) throws -> SessionCoreProcessResult {
        guard timeout > 0,
              maximumStandardOutputBytes > 0,
              maximumStandardErrorBytes > 0 else {
            throw SessionCoreProcessRunnerError.outputTooLarge
        }
        guard let values = try? executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            throw SessionCoreProcessRunnerError.unsafeExecutable
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.qualityOfService = .utility
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = standardInput == nil ? nil : Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin?.fileHandleForReading
            ?? FileHandle.nullDevice
        guard controller.install(process) else {
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            throw SessionCoreProcessRunnerError.launchFailed
        }

        let group = DispatchGroup()
        let stderrBox = SessionCoreDataBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            do {
                try SessionCorePipeReader.readLines(
                    from: stdout.fileHandleForReading,
                    maximumBytes: maximumStandardOutputBytes,
                    drainAfterFailure: kind == .transaction,
                    lineHandler: standardOutputLine
                )
            } catch let error as SessionCoreProcessRunnerError {
                controller.fail(error)
            } catch {
                controller.fail(
                    SessionCoreProcessRunnerError.lineHandlerFailed(
                        error
                    )
                )
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            do {
                let data = try SessionCorePipeReader.readData(
                    from: stderr.fileHandleForReading,
                    maximumBytes: maximumStandardErrorBytes,
                    drainAfterLimit: kind == .transaction
                )
                stderrBox.set(data)
            } catch {
                controller.fail(
                    SessionCoreProcessRunnerError.outputTooLarge
                )
            }
        }

        if let standardInput, let stdin {
            do {
                try stdin.fileHandleForWriting.write(
                    contentsOf: standardInput
                )
                try stdin.fileHandleForWriting.close()
            } catch {
                try? stdin.fileHandleForWriting.close()
                controller.fail(
                    SessionCoreProcessRunnerError.inputWriteFailed,
                    forceTerminate: true
                )
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var deadlineWasReached = false
        while process.isRunning {
            if controller.shouldTerminateForCancellation {
                process.terminate()
            } else if !deadlineWasReached, Date() >= deadline {
                deadlineWasReached = true
                if kind == .transaction {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                controller.fail(
                    SessionCoreProcessRunnerError.timedOut
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        guard group.wait(timeout: .now() + 2) == .success else {
            controller.fail(
                SessionCoreProcessRunnerError.timedOut
            )
            throw SessionCoreProcessRunnerError.timedOut
        }
        if controller.shouldThrowCancellation {
            throw CancellationError()
        }
        if let failure = controller.failure {
            throw failure
        }
        return SessionCoreProcessResult(
            terminationStatus: process.terminationStatus,
            standardError: stderrBox.value
        )
    }
}

private final class SessionCoreProcessController:
    @unchecked Sendable {
    private let lock = NSLock()
    private let kind: SessionCoreProcessKind
    private var process: Process?
    private var cancellationRequested = false
    private var storedFailure: SessionCoreProcessRunnerError?

    init(kind: SessionCoreProcessKind) {
        self.kind = kind
    }

    var shouldTerminateForCancellation: Bool {
        lock.withLock {
            cancellationRequested && kind == .readOnly
        }
    }

    var shouldThrowCancellation: Bool {
        lock.withLock {
            cancellationRequested && kind == .readOnly
        }
    }

    var failure: SessionCoreProcessRunnerError? {
        lock.withLock { storedFailure }
    }

    func install(_ process: Process) -> Bool {
        lock.withLock {
            guard !(cancellationRequested && kind == .readOnly) else {
                return false
            }
            self.process = process
            return true
        }
    }

    func cancel() {
        let process: Process? = lock.withLock {
            cancellationRequested = true
            guard kind == .readOnly else { return nil }
            return self.process
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func fail(
        _ error: SessionCoreProcessRunnerError,
        forceTerminate: Bool = false
    ) {
        let process: Process? = lock.withLock {
            if storedFailure == nil {
                storedFailure = error
            }
            guard forceTerminate || kind == .readOnly else {
                return nil
            }
            return self.process
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class SessionCoreDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func set(_ data: Data) {
        lock.withLock {
            self.data = data
        }
    }
}

private enum SessionCorePipeReader {
    static func readData(
        from handle: FileHandle,
        maximumBytes: Int,
        drainAfterLimit: Bool
    ) throws -> Data {
        var result = Data()
        var exceededLimit = false
        while true {
            let chunk = try handle.read(upToCount: 16 * 1024) ?? Data()
            if chunk.isEmpty { break }
            if exceededLimit {
                continue
            }
            guard result.count <= maximumBytes - chunk.count else {
                if !drainAfterLimit {
                    throw SessionCoreProcessRunnerError.outputTooLarge
                }
                exceededLimit = true
                result.removeAll(keepingCapacity: false)
                continue
            }
            result.append(chunk)
        }
        if exceededLimit {
            throw SessionCoreProcessRunnerError.outputTooLarge
        }
        return result
    }

    static func readLines(
        from handle: FileHandle,
        maximumBytes: Int,
        drainAfterFailure: Bool,
        lineHandler: @escaping @Sendable (Data) throws -> Void
    ) throws {
        var total = 0
        var pending = Data()
        var storedFailure: Error?
        while true {
            let chunk = try handle.read(upToCount: 16 * 1024) ?? Data()
            if chunk.isEmpty { break }
            if storedFailure != nil {
                continue
            }
            guard total <= maximumBytes - chunk.count else {
                if !drainAfterFailure {
                    throw SessionCoreProcessRunnerError.outputTooLarge
                }
                storedFailure =
                    SessionCoreProcessRunnerError.outputTooLarge
                pending.removeAll(keepingCapacity: false)
                continue
            }
            total += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.last == 0x0D {
                    line.removeLast()
                }
                if !line.isEmpty {
                    do {
                        try lineHandler(line)
                    } catch {
                        if !drainAfterFailure { throw error }
                        storedFailure = error
                        pending.removeAll(keepingCapacity: false)
                        break
                    }
                }
            }
        }
        if storedFailure == nil, !pending.isEmpty {
            if pending.last == 0x0D {
                pending.removeLast()
            }
            if !pending.isEmpty {
                try lineHandler(pending)
            }
        }
        if let storedFailure {
            throw storedFailure
        }
    }
}

private enum SessionCoreMessageRedactor {
    static func stderrSummary(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return "历史会话组件执行失败，错误输出已隐藏。"
    }

    static func redact(
        _ message: String,
        sensitiveValues: [String] = []
    ) -> String {
        var result = String(message.prefix(512))
        for value in sensitiveValues where !value.isEmpty {
            result = result.replacingOccurrences(
                of: value,
                with: "[已隐藏]"
            )
        }
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/\-=]+"#,
            #"(?i)(api[_ -]?key|token|experimental_bearer_token)\s*[:=]\s*[^\s,;]+"#,
            #"\bsk-[A-Za-z0-9_-]{8,}\b"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ) else { continue }
            let range = NSRange(
                result.startIndex..<result.endIndex,
                in: result
            )
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[已隐藏]"
            )
        }
        return result
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

private extension URL {
    func isWithinOrEqual(to root: URL) -> Bool {
        let candidatePath = standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(
                rootPath.hasSuffix("/")
                    ? rootPath
                    : rootPath + "/"
            )
    }
}
