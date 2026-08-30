import CryptoKit
import Darwin
import Foundation
import SQLite3

enum SessionSyncPhase: String, Codable, CaseIterable {
    case preflight = "核对会话状态"
    case backup = "建立统一恢复点"
    case prepared = "恢复点已就绪"
    case rolloutWrite = "同步会话文件"
    case sqliteWrite = "同步会话索引"
    case ledgerWrite = "保存原始来源"
    case verify = "核对完整性"
    case readyToCommit = "等待提交"
    case committed = "已完成"
    case rollingBack = "正在恢复"
    case rolledBack = "已恢复"
    case manualRecovery = "需要人工恢复"

    var terminal: Bool {
        self == .committed || self == .rolledBack
            || self == .manualRecovery
    }
}

enum SessionSyncError: LocalizedError, Equatable {
    case unsafePath(String)
    case symbolicLink(String)
    case tooManyFiles
    case noMetadata(String)
    case conflictingMetadataThreadIDs(String)
    case rolloutChanged(String)
    case malformedRollout(String)
    case unknownDatabaseSchema(String)
    case databaseLocked(String)
    case databaseOpen(String)
    case databaseFailure(String)
    case databaseIntegrity(String)
    case rolloutMissingFromDatabase(Int)
    case planBlocked([String])
    case transactionMissing
    case invalidTransactionPhase(SessionSyncPhase)
    case recoveryPointMissing
    case recoveryVerificationFailed(String)
    case injectedFailure(SessionSyncPhase)

    var errorDescription: String? {
        switch self {
        case let .unsafePath(path):
            return "会话路径不在允许范围：\(path)"
        case let .symbolicLink(path):
            return "会话事务发现符号链接，已阻止：\(path)"
        case .tooManyFiles:
            return "会话或数据库文件数量超过安全上限"
        case let .noMetadata(path):
            return "会话文件缺少session_meta：\(path)"
        case let .conflictingMetadataThreadIDs(path):
            return "同一会话文件含无法证明关系的不同Thread ID，已阻止：\(path)"
        case let .rolloutChanged(path):
            return "会话文件在提交前发生变化：\(path)"
        case let .malformedRollout(path):
            return "会话文件无法安全改签：\(path)"
        case let .unknownDatabaseSchema(path):
            return "会话数据库结构不受支持：\(path)"
        case let .databaseLocked(path):
            return "会话数据库仍被写入占用：\(path)"
        case let .databaseOpen(message):
            return "无法打开会话数据库：\(message)"
        case let .databaseFailure(message):
            return "会话数据库操作失败：\(message)"
        case let .databaseIntegrity(path):
            return "会话数据库完整性检查未通过：\(path)"
        case let .rolloutMissingFromDatabase(count):
            return "有\(count)个会话文件没有对应数据库记录，已阻止冒充修复成功"
        case let .planBlocked(reasons):
            return reasons.joined(separator: "；")
        case .transactionMissing:
            return "找不到会话同步事务"
        case let .invalidTransactionPhase(phase):
            return "会话事务当前处于“\(phase.rawValue)”，不能执行此操作"
        case .recoveryPointMissing:
            return "会话事务恢复点缺失"
        case let .recoveryVerificationFailed(path):
            return "恢复后校验失败：\(path)"
        case let .injectedFailure(phase):
            return "会话事务在“\(phase.rawValue)”注入失败"
        }
    }
}

struct SessionRolloutPlan: Codable, Equatable {
    let url: URL
    let threadID: String
    var relatedThreadIDs: [String]? = nil
    let currentProvider: String?
    let expectedHash: String
    let permissions: Int
    let modificationDate: Date?
    let archived: Bool
    let hasUserEvent: Bool
    let workingDirectory: String?
    let title: String?
    let model: String?
    let createdAt: Date?
    let updatedAt: Date?
    let containsEncryptedContent: Bool?

    var allThreadIDs: [String] {
        var seen = Set<String>()
        return ([threadID] + (relatedThreadIDs ?? []))
            .filter { seen.insert($0).inserted }
    }
}

struct SessionDatabasePlan: Codable, Equatable {
    let url: URL
    let columns: [String]
    let threadIDs: [String]
    let providerByThreadID: [String: String]
    let permissions: Int
    let modificationDate: Date?
}

enum SessionRecoveryTargetKind: String, Codable {
    case rollout
    case database
    case additionalFile
    case originLedger
}

struct SessionRecoveryTarget: Codable, Equatable {
    let url: URL
    let snapshotRelativePath: String?
    let kind: SessionRecoveryTargetKind
    let existed: Bool
    let permissions: Int?
    let modificationDate: Date?
    let expectedSnapshotHash: String?
}

struct SessionAdditionalRecoveryFile: Codable, Equatable {
    let url: URL
    let label: String
}

struct SessionSyncPlan: Codable, Equatable {
    let id: String
    let codexHomeURL: URL
    let targetProvider: String
    let targetProfileID: String
    let sourceProfileID: String?
    let trustSourceOrigin: Bool
    let rollouts: [SessionRolloutPlan]
    let databases: [SessionDatabasePlan]
    let additionalRecoveryFiles: [SessionAdditionalRecoveryFile]
}

struct SessionSyncListItem: Identifiable, Equatable {
    var id: String { threadID }
    let threadID: String
    let title: String?
    let originProfileID: String?
    let originLabel: String
    let observedProvider: String?
    let model: String?
    let workingDirectory: String?
    let createdAt: Date?
    let updatedAt: Date?
    let updatedAtIsFileTime: Bool
    let archived: Bool
    let rolloutPath: String
    let containsEncryptedContent: Bool
}

struct SessionDatabaseDisplayMetadata: Equatable {
    let title: String?
    let createdAt: Date?
    let updatedAt: Date?
}

struct SessionDatabaseInspection {
    let plan: SessionDatabasePlan
    let displayMetadataByThreadID:
        [String: SessionDatabaseDisplayMetadata]
}

struct SessionSyncPreview: Equatable {
    let plan: SessionSyncPlan
    let sessions: [SessionSyncListItem]
    let activeRolloutCount: Int
    let archivedRolloutCount: Int
    let uniqueThreadCount: Int
    let databaseCount: Int
    let indexedThreadCount: Int
    let currentlyVisibleThreadCount: Int
    let rolloutChangeCount: Int
    let databaseChangeCount: Int
    let missingDatabaseThreadCount: Int
    let blockers: [String]

    var canApply: Bool { blockers.isEmpty }
    var needsRepair: Bool {
        rolloutChangeCount > 0 || databaseChangeCount > 0
    }
}

enum SessionOpenSafetyGate {
    static func blockReason(
        sessionProvider: String?,
        currentProvider: String,
        definedProviderIDs: Set<String>,
        runtimeProvider: String?,
        runtimeVerified: Bool
    ) -> String? {
        guard runtimeVerified else {
            return "当前模式尚未可靠核对，请先重新核对后再打开会话"
        }
        guard let sessionProvider,
              !sessionProvider.isEmpty else {
            return "这个会话没有可验证的当前标签，请先点“修复到当前模式”"
        }
        let normalizedRuntime =
            runtimeProvider ?? "openai"
        guard normalizedRuntime == currentProvider else {
            return "Codex真实运行模式与助手记录不一致，请先重新核对当前模式"
        }
        guard sessionProvider == currentProvider else {
            return "这个会话仍标记为“\(sessionProvider)”，当前模式是“\(currentProvider)”；请先点“修复到当前模式”，否则Codex可能提示Provider不存在"
        }
        if currentProvider != "openai",
           !definedProviderIDs.contains(
               currentProvider
           ) {
            return "当前config.toml没有定义Provider“\(currentProvider)”；已阻止打开，请先修复当前模式"
        }
        return nil
    }
}

struct SessionSyncTransaction: Identifiable, Codable, Equatable {
    let id: String
    let plan: SessionSyncPlan
    var phase: SessionSyncPhase
    let startedAt: Date
    var completedAt: Date?
    var message: String
    var recoveryManifest: SnapshotManifest?
    var recoveryTargets: [SessionRecoveryTarget]
    var changedRolloutCount: Int
    var changedDatabaseCount: Int
}

struct SessionOriginLedgerEntry: Codable, Equatable {
    let threadID: String
    var originProfileID: String?
    var originLabel: String
    let firstSeenAt: Date
    var lastSeenAt: Date
    var lastVisibleProvider: String
}

struct SessionOriginLedger: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var entries: [SessionOriginLedgerEntry]

    static let empty = SessionOriginLedger(
        schemaVersion: currentSchemaVersion,
        entries: []
    )
}

struct SessionOriginLedgerStore {
    let fileURL: URL
    let keyProvider: () throws -> Data

    func load() throws -> SessionOriginLedger {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let plaintext = try ProfileVaultCrypto.open(
            Data(contentsOf: fileURL),
            keyData: keyProvider()
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(
            SessionOriginLedger.self,
            from: plaintext
        )
        guard ledger.schemaVersion <= SessionOriginLedger
            .currentSchemaVersion else {
            throw SessionSyncError.recoveryVerificationFailed(
                fileURL.path
            )
        }
        return ledger
    }

    func save(_ ledger: SessionOriginLedger) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try ProfileVaultCrypto.seal(
            encoder.encode(ledger),
            keyData: keyProvider()
        )
        try SessionSyncAtomicFile.write(
            encrypted,
            to: fileURL,
            expectedHash: SessionSyncFileSafety.hashIfPresent(fileURL),
            permissions: 0o600,
            modificationDate: nil
        )
    }
}

struct SessionSyncJournalStore {
    let rootURL: URL

    func save(_ transaction: SessionSyncTransaction) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = journalURL(transaction.id)
        try SessionSyncAtomicFile.write(
            encoder.encode(transaction),
            to: url,
            expectedHash: SessionSyncFileSafety.hashIfPresent(url),
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func load(_ id: String) throws -> SessionSyncTransaction {
        let url = journalURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionSyncError.transactionMissing
        }
        try SessionSyncFileSafety.requireRegularFile(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SessionSyncTransaction.self,
            from: Data(contentsOf: url)
        )
    }

    func pending() throws -> [SessionSyncTransaction] {
        try all().filter { !$0.phase.terminal }
    }

    func latestCommitted() throws -> SessionSyncTransaction? {
        try all()
            .filter { $0.phase == .committed }
            .sorted { $0.completedAt ?? $0.startedAt >
                $1.completedAt ?? $1.startedAt }
            .first
    }

    func committedBeyondRetention(
        retaining count: Int
    ) throws -> [SessionSyncTransaction] {
        let committed = try all()
            .filter { $0.phase == .committed }
            .sorted {
                ($0.completedAt ?? $0.startedAt)
                    > ($1.completedAt ?? $1.startedAt)
            }
        return Array(committed.dropFirst(max(0, count)))
    }

    func remove(_ transaction: SessionSyncTransaction) throws {
        let url = journalURL(transaction.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try SessionSyncFileSafety.requireRegularFile(url)
        try FileManager.default.removeItem(at: url)
    }

    private func all() throws -> [SessionSyncTransaction] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }
        let values = try rootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw SessionSyncError.unsafePath(rootURL.path)
        }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { url in
            try SessionSyncFileSafety.requireRegularFile(url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                SessionSyncTransaction.self,
                from: Data(contentsOf: url)
            )
        }
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func journalURL(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }
}

struct SessionSyncEngine {
    let codexHomeURL: URL
    let controlRootURL: URL
    let vault: SecureProfileVault
    let ledgerStore: SessionOriginLedgerStore
    let journalStore: SessionSyncJournalStore
    let maximumRolloutFiles: Int
    let maximumDatabaseFiles: Int
    let faultInjector: ((SessionSyncPhase) throws -> Void)?
    let progressObserver:
        ((SessionSyncPhase, String) -> Void)?

    init(
        codexHomeURL: URL,
        controlRootURL: URL,
        keyProvider: @escaping () throws -> Data,
        maximumRolloutFiles: Int = 20_000,
        maximumDatabaseFiles: Int = 50,
        faultInjector: ((SessionSyncPhase) throws -> Void)? = nil,
        progressObserver:
            ((SessionSyncPhase, String) -> Void)? = nil
    ) {
        self.codexHomeURL = codexHomeURL.standardizedFileURL
        self.controlRootURL = controlRootURL.standardizedFileURL
        self.vault = SecureProfileVault(
            rootURL: controlRootURL
                .appendingPathComponent(
                    "SessionSyncVault",
                    isDirectory: true
                ),
            keyProvider: keyProvider
        )
        self.ledgerStore = SessionOriginLedgerStore(
            fileURL: controlRootURL
                .appendingPathComponent(
                    "SessionOriginLedger.vault"
                ),
            keyProvider: keyProvider
        )
        self.journalStore = SessionSyncJournalStore(
            rootURL: controlRootURL
                .appendingPathComponent(
                    "SessionTransactions",
                    isDirectory: true
                )
        )
        self.maximumRolloutFiles = maximumRolloutFiles
        self.maximumDatabaseFiles = maximumDatabaseFiles
        self.faultInjector = faultInjector
        self.progressObserver = progressObserver
    }

    func preview(
        targetProvider: String,
        targetProfileID: String,
        sourceProfileID: String?,
        trustSourceOrigin: Bool,
        additionalRecoveryFiles: [SessionAdditionalRecoveryFile] = []
    ) throws -> SessionSyncPreview {
        try validateRoots()
        let target = targetProvider.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !target.isEmpty else {
            throw SessionSyncError.planBlocked(["目标Provider为空"])
        }
        let rolloutScan = try scanRollouts()
        let databaseScan = try scanDatabases()
        var blockers = rolloutScan.blockers + databaseScan.blockers
        let ledger: SessionOriginLedger
        do {
            ledger = try ledgerStore.load()
            let duplicateOrigins = Dictionary(
                grouping: ledger.entries,
                by: \.threadID
            ).filter { $0.value.count > 1 }
            if !duplicateOrigins.isEmpty {
                blockers.append(
                    "会话原始来源账本含重复记录，需先恢复上次事务"
                )
            }
        } catch {
            ledger = .empty
            blockers.append(
                "会话原始来源账本无法安全读取："
                    + error.localizedDescription
            )
        }
        let rolloutThreads = Set(
            rolloutScan.plans.flatMap(
                \.allThreadIDs
            )
        )
        let databaseThreads = Set(
            databaseScan.plans.flatMap(\.threadIDs)
        )
        let missing = rolloutThreads.subtracting(databaseThreads).count
        if missing > 0 {
            blockers.append(
                SessionSyncError.rolloutMissingFromDatabase(
                    missing
                ).localizedDescription
            )
        }
        if !rolloutThreads.isEmpty && databaseScan.plans.isEmpty {
            blockers.append("没有找到可验证的Codex会话数据库")
        }
        let unsafeExtras = additionalRecoveryFiles.compactMap {
            allowed($0.url) ? nil : $0.url.path
        }
        if !unsafeExtras.isEmpty {
            blockers.append(
                "恢复文件不在白名单："
                    + unsafeExtras.joined(separator: "、")
            )
        }
        let indexedProviders = databaseScan.plans.flatMap {
            $0.providerByThreadID.map { ($0.key, $0.value) }
        }
        let indexedThreadIDs = Set(indexedProviders.map(\.0))
        let visibleThreadIDs = Set(
            indexedProviders
                .filter { $0.1 == target }
                .map(\.0)
        )
        let rolloutChanges = rolloutScan.plans.filter {
            $0.currentProvider != target
        }.count
        let databaseChanges = databaseScan.plans.reduce(0) {
            $0 + $1.providerByThreadID.values.filter {
                $0 != target
            }.count
        }
        let plan = SessionSyncPlan(
            id: UUID().uuidString,
            codexHomeURL: codexHomeURL,
            targetProvider: target,
            targetProfileID: targetProfileID,
            sourceProfileID: sourceProfileID,
            trustSourceOrigin: trustSourceOrigin,
            rollouts: rolloutScan.plans,
            databases: databaseScan.plans,
            additionalRecoveryFiles: additionalRecoveryFiles
        )
        return SessionSyncPreview(
            plan: plan,
            sessions: sessionListItems(
                from: rolloutScan.plans,
                databaseMetadata:
                    databaseScan.displayMetadataByThreadID,
                ledger: ledger
            ),
            activeRolloutCount: rolloutScan.plans.filter {
                !$0.archived
            }.count,
            archivedRolloutCount: rolloutScan.plans.filter {
                $0.archived
            }.count,
            uniqueThreadCount: rolloutThreads.count,
            databaseCount: databaseScan.plans.count,
            indexedThreadCount: indexedThreadIDs.count,
            currentlyVisibleThreadCount: visibleThreadIDs.count,
            rolloutChangeCount: rolloutChanges,
            databaseChangeCount: databaseChanges,
            missingDatabaseThreadCount: missing,
            blockers: blockers
        )
    }

    private func sessionListItems(
        from plans: [SessionRolloutPlan],
        databaseMetadata:
            [String: SessionDatabaseDisplayMetadata],
        ledger: SessionOriginLedger
    ) -> [SessionSyncListItem] {
        var origins:
            [String: SessionOriginLedgerEntry] = [:]
        for entry in ledger.entries
            where origins[entry.threadID] == nil {
            origins[entry.threadID] = entry
        }
        var byThread: [String: SessionSyncListItem] = [:]
        var selectedFromPrimary:
            [String: Bool] = [:]
        for plan in plans {
            for threadID in plan.allThreadIDs {
                let database =
                    databaseMetadata[threadID]
                let ledgerEntry = origins[threadID]
                let rolloutUpdatedAt = plan.updatedAt
                let selectedUpdatedAt =
                    database?.updatedAt
                        ?? rolloutUpdatedAt
                        ?? plan.modificationDate
                let isPrimary =
                    threadID == plan.threadID
                let origin = SessionSyncListItem(
                    threadID: threadID,
                    title: database?.title
                        ?? (isPrimary ? plan.title : nil),
                    originProfileID:
                        ledgerEntry?.originProfileID,
                    originLabel:
                        ledgerEntry?.originLabel
                            ?? "历史来源未知",
                    observedProvider:
                        plan.currentProvider,
                    model: plan.model,
                    workingDirectory:
                        plan.workingDirectory,
                    createdAt: database?.createdAt
                        ?? plan.createdAt,
                    updatedAt: selectedUpdatedAt,
                    updatedAtIsFileTime:
                        database?.updatedAt == nil
                            && rolloutUpdatedAt == nil
                            && plan.modificationDate
                                != nil,
                    archived: plan.archived,
                    rolloutPath: plan.url.path,
                    containsEncryptedContent:
                        plan.containsEncryptedContent
                            == true
                )
                if let existing = byThread[threadID] {
                    let existingIsPrimary =
                        selectedFromPrimary[
                            threadID
                        ] == true
                    let newDate = origin.updatedAt
                        ?? origin.createdAt
                        ?? .distantPast
                    let oldDate = existing.updatedAt
                        ?? existing.createdAt
                        ?? .distantPast
                    if (
                        isPrimary
                            && !existingIsPrimary
                    ) || (
                        isPrimary
                            == existingIsPrimary
                            && (
                                newDate > oldDate
                                    || (
                                        newDate == oldDate
                                            && plan.url.path
                                                > existing
                                                    .rolloutPath
                                    )
                            )
                    ) {
                        byThread[threadID] = origin
                        selectedFromPrimary[threadID] =
                            isPrimary
                    }
                } else {
                    byThread[threadID] = origin
                    selectedFromPrimary[threadID] =
                        isPrimary
                }
            }
        }
        return byThread.values.sorted {
            let left = $0.updatedAt
                ?? $0.createdAt
                ?? .distantPast
            let right = $1.updatedAt
                ?? $1.createdAt
                ?? .distantPast
            if left != right { return left > right }
            return $0.threadID < $1.threadID
        }
    }

    func prepare(
        _ preview: SessionSyncPreview
    ) throws -> SessionSyncTransaction {
        guard preview.canApply else {
            throw SessionSyncError.planBlocked(preview.blockers)
        }
        try requireNoPendingTransaction()
        try verifyPlanFresh(preview.plan)
        try faultInjector?(.preflight)
        var transaction = SessionSyncTransaction(
            id: preview.plan.id,
            plan: preview.plan,
            phase: .preflight,
            startedAt: Date(),
            completedAt: nil,
            message: "正在建立会话统一恢复点",
            recoveryManifest: nil,
            recoveryTargets: [],
            changedRolloutCount: 0,
            changedDatabaseCount: 0
        )
        progressObserver?(
            transaction.phase,
            transaction.message
        )
        try journalStore.save(transaction)
        do {
            transaction.phase = .backup
            transaction.message =
                "正在备份SQLite、会话文件和助手状态"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.backup)
            let recovery = try buildRecoveryPoint(preview.plan)
            transaction.recoveryManifest = recovery.manifest
            transaction.recoveryTargets = recovery.targets
            transaction.phase = .prepared
            transaction.message = "配置、会话文件、数据库和来源账本恢复点已就绪"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.prepared)
            return transaction
        } catch {
            transaction.phase = .manualRecovery
            transaction.completedAt = Date()
            transaction.message =
                "恢复点建立失败；尚未修改任何会话内容："
                + error.localizedDescription
            try? journalStore.save(transaction)
            throw error
        }
    }

    func apply(
        transactionID: String
    ) throws -> SessionSyncTransaction {
        var transaction = try journalStore.load(transactionID)
        guard transaction.phase == .prepared else {
            throw SessionSyncError.invalidTransactionPhase(
                transaction.phase
            )
        }
        do {
            try verifyPlanFresh(transaction.plan)
            transaction.phase = .rolloutWrite
            transaction.message = "正在同步活跃和归档会话"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.rolloutWrite)
            transaction.changedRolloutCount = try writeRollouts(
                transaction.plan
            )
            try journalStore.save(transaction)

            transaction.phase = .sqliteWrite
            transaction.message = "正在同步Codex原生会话索引"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.sqliteWrite)
            transaction.changedDatabaseCount = try writeDatabases(
                transaction.plan
            )
            try journalStore.save(transaction)

            transaction.phase = .ledgerWrite
            transaction.message = "正在加密保存会话原始来源"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.ledgerWrite)
            try updateLedger(transaction.plan)

            transaction.phase = .verify
            transaction.message = "正在核对会话数量和数据库完整性"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.verify)
            try verifyApplied(transaction.plan)

            transaction.phase = .readyToCommit
            transaction.message =
                "已同步\(transaction.changedRolloutCount)个会话文件、"
                + "\(transaction.changedDatabaseCount)个数据库；等待连接验证"
            progressObserver?(
                transaction.phase,
                transaction.message
            )
            try journalStore.save(transaction)
            try faultInjector?(.readyToCommit)
            return transaction
        } catch {
            do {
                return try rollback(
                    transactionID: transaction.id,
                    reason: error.localizedDescription
                )
            } catch let rollbackError {
                transaction.phase = .manualRecovery
                transaction.completedAt = Date()
                transaction.message =
                    "会话同步失败，自动恢复未完成："
                    + rollbackError.localizedDescription
                try? journalStore.save(transaction)
                throw rollbackError
            }
        }
    }

    func commit(
        transactionID: String,
        message: String
    ) throws -> SessionSyncTransaction {
        var transaction = try journalStore.load(transactionID)
        guard transaction.phase == .readyToCommit else {
            throw SessionSyncError.invalidTransactionPhase(
                transaction.phase
            )
        }
        try verifyApplied(transaction.plan)
        transaction.phase = .committed
        transaction.completedAt = Date()
        transaction.message = message
        progressObserver?(
            transaction.phase,
            transaction.message
        )
        try journalStore.save(transaction)
        try pruneCommittedRecoveryPoints()
        return transaction
    }

    @discardableResult
    func rollback(
        transactionID: String,
        reason: String,
        allowCommitted: Bool = false
    ) throws -> SessionSyncTransaction {
        var transaction = try journalStore.load(transactionID)
        guard transaction.phase != .committed
                || allowCommitted else {
            throw SessionSyncError.invalidTransactionPhase(
                transaction.phase
            )
        }
        guard let manifest = transaction.recoveryManifest else {
            throw SessionSyncError.recoveryPointMissing
        }
        transaction.phase = .rollingBack
        transaction.message = "正在恢复会话事务：\(reason)"
        progressObserver?(
            transaction.phase,
            transaction.message
        )
        try journalStore.save(transaction)
        let snapshots = try vault.loadSnapshot(manifest)
        let byPath = Dictionary(
            uniqueKeysWithValues: snapshots.map {
                ($0.relativePath, $0)
            }
        )
        for target in transaction.recoveryTargets.reversed() {
            if !target.existed {
                if FileManager.default.fileExists(
                    atPath: target.url.path
                ) {
                    try SessionSyncFileSafety
                        .requireRegularFile(target.url)
                    try FileManager.default.removeItem(at: target.url)
                }
                continue
            }
            guard let relative = target.snapshotRelativePath,
                  let snapshot = byPath[relative] else {
                throw SessionSyncError.recoveryPointMissing
            }
            switch target.kind {
            case .database:
                try SQLiteSessionStore.restoreBackup(
                    snapshot.data,
                    to: target.url,
                    permissions: target.permissions ?? 0o600,
                    modificationDate: target.modificationDate
                )
            case .rollout, .additionalFile, .originLedger:
                try SessionSyncAtomicFile.write(
                    snapshot.data,
                    to: target.url,
                    expectedHash:
                        SessionSyncFileSafety.hashIfPresent(
                            target.url
                        ),
                    permissions: target.permissions ?? 0o600,
                    modificationDate: target.modificationDate
                )
            }
        }
        try verifyRecovery(transaction, snapshotsByPath: byPath)
        transaction.phase = .rolledBack
        transaction.completedAt = Date()
        transaction.message = "失败步骤已停止；配置、数据库、会话文件和来源账本已恢复"
        progressObserver?(
            transaction.phase,
            transaction.message
        )
        try journalStore.save(transaction)
        return transaction
    }

    func restoreLatestCommitted() throws
        -> SessionSyncTransaction {
        guard let transaction = try journalStore
            .latestCommitted() else {
            throw SessionSyncError.transactionMissing
        }
        return try rollback(
            transactionID: transaction.id,
            reason: "用户恢复上次历史会话修复",
            allowCommitted: true
        )
    }

    func recoverPendingTransactions() throws -> [SessionSyncTransaction] {
        var recovered: [SessionSyncTransaction] = []
        for transaction in try journalStore.pending() {
            recovered.append(
                try rollback(
                    transactionID: transaction.id,
                    reason: "检测到上次未完成事务"
                )
            )
        }
        return recovered
    }

    func latestCommittedTransaction() throws -> SessionSyncTransaction? {
        try journalStore.latestCommitted()
    }

    private func validateRoots() throws {
        for root in [codexHomeURL, controlRootURL] {
            if FileManager.default.fileExists(atPath: root.path) {
                let values = try root.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    throw SessionSyncError.unsafePath(root.path)
                }
            }
        }
    }

    private func scanRollouts() throws -> (
        plans: [SessionRolloutPlan],
        blockers: [String]
    ) {
        try Task.checkCancellation()
        var plans: [SessionRolloutPlan] = []
        var blockers: [String] = []
        for (name, archived) in [
            ("sessions", false),
            ("archived_sessions", true),
        ] {
            try Task.checkCancellation()
            let root = codexHomeURL.appendingPathComponent(
                name,
                isDirectory: true
            )
            guard FileManager.default.fileExists(
                atPath: root.path
            ) else { continue }
            let files = try SessionSyncFileSafety
                .recursiveJSONLFiles(
                    root: root,
                    maximumFiles: maximumRolloutFiles
                        - plans.count
            )
            for file in files {
                try Task.checkCancellation()
                do {
                    plans.append(
                        try RolloutProviderSynchronizer.inspect(
                            file,
                            archived: archived
                        )
                    )
                } catch {
                    blockers.append(error.localizedDescription)
                }
            }
        }
        guard plans.count <= maximumRolloutFiles else {
            throw SessionSyncError.tooManyFiles
        }
        return (
            plans.sorted { $0.url.path < $1.url.path },
            blockers
        )
    }

    private func scanDatabases() throws -> (
        plans: [SessionDatabasePlan],
        blockers: [String],
        displayMetadataByThreadID:
            [String: SessionDatabaseDisplayMetadata]
    ) {
        try Task.checkCancellation()
        let candidates = try SessionSyncFileSafety
            .databaseCandidates(
                root: codexHomeURL,
                maximumFiles: maximumDatabaseFiles
            )
        var plans: [SessionDatabasePlan] = []
        var blockers: [String] = []
        var displayMetadata:
            [String: SessionDatabaseDisplayMetadata] = [:]
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                if let inspection = try SQLiteSessionStore
                    .inspectWithDisplayMetadata(
                        candidate
                    ) {
                    plans.append(inspection.plan)
                    for (threadID, metadata)
                        in inspection
                            .displayMetadataByThreadID {
                        displayMetadata[threadID] =
                            preferredDisplayMetadata(
                                displayMetadata[
                                    threadID
                                ],
                                metadata
                            )
                    }
                }
            } catch {
                blockers.append(error.localizedDescription)
            }
        }
        return (
            plans.sorted { $0.url.path < $1.url.path },
            blockers,
            displayMetadata
        )
    }

    private func preferredDisplayMetadata(
        _ existing: SessionDatabaseDisplayMetadata?,
        _ candidate: SessionDatabaseDisplayMetadata
    ) -> SessionDatabaseDisplayMetadata {
        guard let existing else { return candidate }
        let existingDate = existing.updatedAt
            ?? existing.createdAt
            ?? .distantPast
        let candidateDate = candidate.updatedAt
            ?? candidate.createdAt
            ?? .distantPast
        if candidateDate > existingDate {
            return candidate
        }
        if candidateDate < existingDate {
            return existing
        }
        return SessionDatabaseDisplayMetadata(
            title: candidate.title
                ?? existing.title,
            createdAt: candidate.createdAt
                ?? existing.createdAt,
            updatedAt: candidate.updatedAt
                ?? existing.updatedAt
        )
    }

    private func verifyPlanFresh(_ plan: SessionSyncPlan) throws {
        for rollout in plan.rollouts {
            guard SessionSyncFileSafety.hashIfPresent(
                rollout.url
            ) == rollout.expectedHash else {
                throw SessionSyncError.rolloutChanged(
                    rollout.url.path
                )
            }
        }
        for database in plan.databases {
            try SQLiteSessionStore.requireWritableAndUnlocked(
                database.url
            )
            guard try SQLiteSessionStore
                .schemaColumns(database.url) == database.columns else {
                throw SessionSyncError.unknownDatabaseSchema(
                    database.url.path
                )
            }
        }
        for item in plan.additionalRecoveryFiles {
            guard allowed(item.url) else {
                throw SessionSyncError.unsafePath(item.url.path)
            }
            if FileManager.default.fileExists(atPath: item.url.path) {
                try SessionSyncFileSafety.requireRegularFile(item.url)
            }
        }
    }

    private func buildRecoveryPoint(
        _ plan: SessionSyncPlan
    ) throws -> (
        manifest: SnapshotManifest,
        targets: [SessionRecoveryTarget]
    ) {
        var inputs: [SnapshotInput] = []
        var targets: [SessionRecoveryTarget] = []
        for (index, rollout) in plan.rollouts.enumerated() {
            let relative = "rollouts/\(index).jsonl"
            let data = try Data(contentsOf: rollout.url)
            inputs.append(
                SnapshotInput(
                    relativePath: relative,
                    data: data,
                    permissions: rollout.permissions
                )
            )
            targets.append(
                SessionRecoveryTarget(
                    url: rollout.url,
                    snapshotRelativePath: relative,
                    kind: .rollout,
                    existed: true,
                    permissions: rollout.permissions,
                    modificationDate: rollout.modificationDate,
                    expectedSnapshotHash:
                        SecureProfileVault.sha256(data)
                )
            )
        }
        for (index, database) in plan.databases.enumerated() {
            let relative = "databases/\(index).sqlite"
            let data = try SQLiteSessionStore.backupData(
                database.url
            )
            inputs.append(
                SnapshotInput(
                    relativePath: relative,
                    data: data,
                    permissions: database.permissions
                )
            )
            targets.append(
                SessionRecoveryTarget(
                    url: database.url,
                    snapshotRelativePath: relative,
                    kind: .database,
                    existed: true,
                    permissions: database.permissions,
                    modificationDate: database.modificationDate,
                    expectedSnapshotHash:
                        SecureProfileVault.sha256(data)
                )
            )
        }
        for (index, item) in plan.additionalRecoveryFiles
            .enumerated() {
            let exists = FileManager.default.fileExists(
                atPath: item.url.path
            )
            let relative = exists
                ? "additional/\(index).bin" : nil
            let metadata = exists
                ? try SessionSyncFileSafety.metadata(item.url) : nil
            var hash: String?
            if let relative {
                let data = try Data(contentsOf: item.url)
                hash = SecureProfileVault.sha256(data)
                inputs.append(
                    SnapshotInput(
                        relativePath: relative,
                        data: data,
                        permissions: metadata?.permissions ?? 0o600
                    )
                )
            }
            targets.append(
                SessionRecoveryTarget(
                    url: item.url,
                    snapshotRelativePath: relative,
                    kind: .additionalFile,
                    existed: exists,
                    permissions: metadata?.permissions,
                    modificationDate: metadata?.modificationDate,
                    expectedSnapshotHash: hash
                )
            )
        }
        let ledgerURL = ledgerStore.fileURL
        let ledgerExists = FileManager.default.fileExists(
            atPath: ledgerURL.path
        )
        let ledgerRelative = ledgerExists
            ? "ledger/origin-ledger.vault" : nil
        let ledgerMetadata = ledgerExists
            ? try SessionSyncFileSafety.metadata(ledgerURL) : nil
        var ledgerHash: String?
        if let ledgerRelative {
            let data = try Data(contentsOf: ledgerURL)
            ledgerHash = SecureProfileVault.sha256(data)
            inputs.append(
                SnapshotInput(
                    relativePath: ledgerRelative,
                    data: data,
                    permissions:
                        ledgerMetadata?.permissions ?? 0o600
                )
            )
        }
        targets.append(
            SessionRecoveryTarget(
                url: ledgerURL,
                snapshotRelativePath: ledgerRelative,
                kind: .originLedger,
                existed: ledgerExists,
                permissions: ledgerMetadata?.permissions,
                modificationDate:
                    ledgerMetadata?.modificationDate,
                expectedSnapshotHash: ledgerHash
            )
        )
        let manifest = try vault.saveSnapshot(
            profileID: plan.targetProfileID,
            adapterVersion: "0.10.3",
            inputs: inputs
        )
        return (manifest, targets)
    }

    private func writeRollouts(
        _ plan: SessionSyncPlan
    ) throws -> Int {
        var changed = 0
        for rollout in plan.rollouts
            where rollout.currentProvider != plan.targetProvider {
            try RolloutProviderSynchronizer.write(
                rollout,
                targetProvider: plan.targetProvider
            )
            changed += 1
        }
        return changed
    }

    private func writeDatabases(
        _ plan: SessionSyncPlan
    ) throws -> Int {
        let evidence = rolloutEvidenceByThreadID(
            plan.rollouts
        )
        var changed = 0
        for database in plan.databases {
            if database.providerByThreadID.values.contains(
                where: { $0 != plan.targetProvider }
            ) {
                try SQLiteSessionStore.synchronize(
                    database.url,
                    targetProvider: plan.targetProvider,
                    rolloutEvidence: evidence
                )
                changed += 1
            } else {
                try SQLiteSessionStore.correctEvidence(
                    database.url,
                    rolloutEvidence: evidence
                )
            }
        }
        return changed
    }

    private func updateLedger(
        _ plan: SessionSyncPlan
    ) throws {
        var ledger = try ledgerStore.load()
        var byThread:
            [String: SessionOriginLedgerEntry] = [:]
        for entry in ledger.entries {
            guard byThread[entry.threadID] == nil else {
                throw SessionSyncError
                    .recoveryVerificationFailed(
                        ledgerStore.fileURL.path
                    )
            }
            byThread[entry.threadID] = entry
        }
        let now = Date()
        for rollout in plan.rollouts {
            for threadID in rollout.allThreadIDs {
                if var existing = byThread[threadID] {
                    existing.lastSeenAt = now
                    existing.lastVisibleProvider =
                        plan.targetProvider
                    byThread[threadID] = existing
                } else {
                    let source = plan.trustSourceOrigin
                        ? plan.sourceProfileID : nil
                    byThread[threadID] =
                        SessionOriginLedgerEntry(
                            threadID: threadID,
                            originProfileID: source,
                            originLabel: source
                                ?? "历史来源未知",
                            firstSeenAt: now,
                            lastSeenAt: now,
                            lastVisibleProvider:
                                plan.targetProvider
                        )
                }
            }
        }
        ledger.entries = byThread.values.sorted {
            $0.threadID < $1.threadID
        }
        try ledgerStore.save(ledger)
    }

    private func verifyApplied(_ plan: SessionSyncPlan) throws {
        let rolloutThreads = Set(
            plan.rollouts.flatMap(\.allThreadIDs)
        )
        for rollout in plan.rollouts {
            let refreshed = try RolloutProviderSynchronizer
                .inspect(
                    rollout.url,
                    archived: rollout.archived
                )
            guard refreshed.threadID == rollout.threadID,
                  Set(refreshed.allThreadIDs)
                    == Set(rollout.allThreadIDs),
                  refreshed.currentProvider
                    == plan.targetProvider else {
                throw SessionSyncError
                    .recoveryVerificationFailed(
                        rollout.url.path
                    )
            }
        }
        var databaseThreads = Set<String>()
        for database in plan.databases {
            try SQLiteSessionStore.requireIntegrity(database.url)
            let refreshed = try SQLiteSessionStore
                .inspect(database.url)
            guard let refreshed else {
                throw SessionSyncError.unknownDatabaseSchema(
                    database.url.path
                )
            }
            databaseThreads.formUnion(refreshed.threadIDs)
            guard refreshed.providerByThreadID.values.allSatisfy({
                $0 == plan.targetProvider
            }) else {
                throw SessionSyncError
                    .recoveryVerificationFailed(
                        database.url.path
                    )
            }
        }
        let missing = rolloutThreads.subtracting(databaseThreads)
        guard missing.isEmpty else {
            throw SessionSyncError.rolloutMissingFromDatabase(
                missing.count
            )
        }
    }

    private func rolloutEvidenceByThreadID(
        _ rollouts: [SessionRolloutPlan]
    ) -> [String: SessionRolloutPlan] {
        var evidence:
            [String: SessionRolloutPlan] = [:]
        var primary:
            [String: Bool] = [:]
        let ordered = rollouts.sorted {
            if $0.archived != $1.archived {
                return !$0.archived
            }
            return $0.url.path < $1.url.path
        }
        for rollout in ordered {
            for threadID in rollout.allThreadIDs {
                let isPrimary =
                    threadID == rollout.threadID
                if evidence[threadID] == nil
                    || (
                        isPrimary
                            && primary[threadID]
                                != true
                    ) {
                    evidence[threadID] = rollout
                    primary[threadID] = isPrimary
                }
            }
        }
        return evidence
    }

    private func verifyRecovery(
        _ transaction: SessionSyncTransaction,
        snapshotsByPath: [String: SnapshotInput]
    ) throws {
        for target in transaction.recoveryTargets {
            guard target.existed else {
                guard !FileManager.default.fileExists(
                    atPath: target.url.path
                ) else {
                    throw SessionSyncError
                        .recoveryVerificationFailed(
                            target.url.path
                        )
                }
                continue
            }
            guard let relative = target.snapshotRelativePath,
                  let snapshot = snapshotsByPath[relative] else {
                throw SessionSyncError.recoveryPointMissing
            }
            if target.kind == .database {
                try SQLiteSessionStore.requireIntegrity(target.url)
                let restored = try SQLiteSessionStore.backupData(
                    target.url
                )
                guard SecureProfileVault.sha256(restored)
                    == SecureProfileVault.sha256(snapshot.data)
                else {
                    throw SessionSyncError
                        .recoveryVerificationFailed(
                            target.url.path
                        )
                }
            } else {
                guard SessionSyncFileSafety.hashIfPresent(
                    target.url
                ) == SecureProfileVault.sha256(snapshot.data)
                else {
                    throw SessionSyncError
                        .recoveryVerificationFailed(
                            target.url.path
                        )
                }
            }
        }
    }

    private func requireNoPendingTransaction() throws {
        if let pending = try journalStore.pending().first {
            throw SessionSyncError.invalidTransactionPhase(
                pending.phase
            )
        }
    }

    private func pruneCommittedRecoveryPoints() throws {
        for transaction in try journalStore
            .committedBeyondRetention(retaining: 5) {
            if let manifest = transaction.recoveryManifest {
                try vault.deleteSnapshot(manifest)
            }
            try journalStore.remove(transaction)
        }
    }

    private func allowed(_ url: URL) -> Bool {
        let value = url.standardizedFileURL.path
        return SessionSyncFileSafety.isDescendant(
            value,
            of: codexHomeURL.path
        ) || SessionSyncFileSafety.isDescendant(
            value,
            of: controlRootURL.path
        )
    }
}

enum RolloutProviderSynchronizer {
    private struct MetadataRecord {
        let line: Data
        let range: Range<Data.Index>
        let object: [String: Any]
        let payload: [String: Any]
        let threadID: String
    }

    static func inspect(
        _ url: URL,
        archived: Bool
    ) throws -> SessionRolloutPlan {
        try SessionSyncFileSafety.requireRegularFile(url)
        let data = try Data(contentsOf: url)
        let metadata = try metadataRecords(
            in: data,
            path: url.path
        )
        guard let first = metadata.first else {
            throw SessionSyncError.noMetadata(url.path)
        }
        let threadID = first.threadID
        let allThreadIDs = uniqueThreadIDs(
            in: metadata
        )
        let providers = metadata.map {
            $0.payload["model_provider"] as? String
        }
        let firstProvider = providers.first ?? nil
        let providerIsUniform = providers.allSatisfy {
            $0 == firstProvider
        }
        let createdDates = metadata.compactMap {
            metadataDate(
                $0.payload,
                keys: ["created_at"]
            ) ?? metadataDate(
                $0.object,
                keys: ["timestamp", "created_at"]
            )
        }
        let updatedDates = metadata.compactMap {
            metadataDate(
                $0.payload,
                keys: [
                    "updated_at",
                    "last_active_at",
                ]
            ) ?? metadataDate(
                $0.object,
                keys: ["updated_at"]
            )
        }
        let fileMetadata = try SessionSyncFileSafety.metadata(url)
        return SessionRolloutPlan(
            url: url.standardizedFileURL,
            threadID: threadID,
            relatedThreadIDs:
                Array(allThreadIDs.dropFirst()),
            currentProvider: providerIsUniform
                ? firstProvider : nil,
            expectedHash: SecureProfileVault.sha256(data),
            permissions: fileMetadata.permissions,
            modificationDate: fileMetadata.modificationDate,
            archived: archived,
            hasUserEvent: hasUserEvent(in: data),
            workingDirectory: latestMetadataString(
                metadata,
                keys: [
                    "cwd",
                    "working_directory",
                ]
            ),
            title: latestMetadataString(
                metadata,
                keys: ["title", "name"]
            ),
            model: latestMetadataString(
                metadata,
                keys: ["model", "model_name"]
            ),
            createdAt: createdDates.min(),
            updatedAt: (
                updatedDates
                    + createdDates
            ).max(),
            containsEncryptedContent:
                data.range(
                    of: Data(
                        "\"encrypted_content\"".utf8
                    )
                ) != nil
        )
    }

    private static func latestMetadataString(
        _ records: [MetadataRecord],
        keys: [String]
    ) -> String? {
        for record in records.reversed() {
            if let value = metadataString(
                record.payload,
                keys: keys
            ) {
                return value
            }
        }
        return nil
    }

    private static func metadataRecords(
        in data: Data,
        path: String
    ) throws -> [MetadataRecord] {
        let lines = try metadataLines(
            in: data,
            path: path
        )
        var records: [MetadataRecord] = []
        for metadata in lines {
            guard let object = try JSONSerialization
                .jsonObject(
                    with: metadata.line
                ) as? [String: Any],
                  let payload =
                    object["payload"] as? [String: Any],
                  let threadID = (
                    payload["id"] as? String
                        ?? payload["thread_id"]
                            as? String
                        ?? payload["conversation_id"]
                            as? String
                  ),
                  !threadID.isEmpty else {
                throw SessionSyncError.noMetadata(path)
            }
            records.append(
                MetadataRecord(
                    line: metadata.line,
                    range: metadata.range,
                    object: object,
                    payload: payload,
                    threadID: threadID
                )
            )
        }
        try requireConnectedThreadRelationship(
            records,
            path: path
        )
        return records
    }

    private static func uniqueThreadIDs(
        in records: [MetadataRecord]
    ) -> [String] {
        var seen = Set<String>()
        return records.map(\.threadID).filter {
            seen.insert($0).inserted
        }
    }

    private static func requireConnectedThreadRelationship(
        _ records: [MetadataRecord],
        path: String
    ) throws {
        let orderedIDs = uniqueThreadIDs(in: records)
        guard orderedIDs.count > 1 else { return }
        let allIDs = Set(orderedIDs)
        var graph = Dictionary(
            uniqueKeysWithValues: orderedIDs.map {
                ($0, Set<String>())
            }
        )
        for record in records {
            for relatedID in relationshipThreadIDs(
                in: record.payload
            ) where allIDs.contains(relatedID)
                && relatedID != record.threadID {
                graph[record.threadID, default: []]
                    .insert(relatedID)
                graph[relatedID, default: []]
                    .insert(record.threadID)
            }
        }
        var pending = [orderedIDs[0]]
        var visited = Set<String>()
        while let current = pending.popLast() {
            guard visited.insert(current).inserted
            else { continue }
            pending.append(
                contentsOf: graph[current] ?? []
            )
        }
        guard visited == allIDs else {
            throw SessionSyncError
                .conflictingMetadataThreadIDs(path)
        }
    }

    private static func relationshipThreadIDs(
        in payload: [String: Any]
    ) -> Set<String> {
        var values = Set<String>()
        for key in [
            "parent_thread_id",
            "forked_from_id",
            "session_id",
        ] {
            if let value = payload[key] as? String,
               !value.isEmpty {
                values.insert(value)
            }
        }
        if let source =
            payload["source"] as? [String: Any],
           let subagent =
            source["subagent"] as? [String: Any],
           let spawn =
            subagent["thread_spawn"] as? [String: Any],
           let parent =
            spawn["parent_thread_id"] as? String,
           !parent.isEmpty {
            values.insert(parent)
        }
        return values
    }

    static func write(
        _ plan: SessionRolloutPlan,
        targetProvider: String
    ) throws {
        let original = try Data(contentsOf: plan.url)
        guard SecureProfileVault.sha256(original)
            == plan.expectedHash else {
            throw SessionSyncError.rolloutChanged(plan.url.path)
        }
        let updated = try replacingProvider(
            in: original,
            targetProvider: targetProvider,
            path: plan.url.path
        )
        try SessionSyncAtomicFile.write(
            updated,
            to: plan.url,
            expectedHash: plan.expectedHash,
            permissions: plan.permissions,
            modificationDate: plan.modificationDate
        )
    }

    static func replacingProvider(
        in data: Data,
        targetProvider: String,
        path: String = "rollout"
    ) throws -> Data {
        let metadata = try metadataRecords(
            in: data,
            path: path
        )
        var output = data
        for record in metadata.reversed() {
            let updatedLine = try replacingProvider(
                inMetadataLine: record.line,
                targetProvider: targetProvider,
                path: path
            )
            output.replaceSubrange(
                record.range,
                with: updatedLine
            )
        }
        return output
    }

    private static func replacingProvider(
        inMetadataLine data: Data,
        targetProvider: String,
        path: String
    ) throws -> Data {
        let lineString = String(
            decoding: data,
            as: UTF8.self
        )
        let providerLiteral = try JSONSerialization.data(
            withJSONObject: targetProvider,
            options: [.fragmentsAllowed]
        )
        let literal = String(
            decoding: providerLiteral,
            as: UTF8.self
        )
        let regex = try NSRegularExpression(
            pattern:
                #"("model_provider"\s*:\s*)("(?:\\.|[^"\\])*")"#
        )
        let fullRange = NSRange(
            lineString.startIndex...,
            in: lineString
        )
        let matches = regex.matches(
            in: lineString,
            range: fullRange
        )
        guard matches.count <= 1 else {
            throw SessionSyncError.malformedRollout(path)
        }
        let updatedLine: String
        if let match = matches.first,
           let valueRange = Range(
               match.range(at: 2),
               in: lineString
           ) {
            updatedLine = lineString.replacingCharacters(
                in: valueRange,
                with: literal
            )
        } else {
            updatedLine = try insertingProvider(
                into: lineString,
                literal: literal,
                path: path
            )
        }
        try verifyOnlyProviderChanged(
            old: lineString,
            new: updatedLine,
            targetProvider: targetProvider,
            path: path
        )
        return Data(updatedLine.utf8)
    }

    private static func metadataLines(
        in data: Data,
        path: String
    ) throws -> [
        (line: Data, range: Range<Data.Index>)
    ] {
        var start = data.startIndex
        var found: [
            (line: Data, range: Range<Data.Index>)
        ] = []
        while start < data.endIndex {
            let newline = data[start...]
                .firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            var bodyEnd = end
            if bodyEnd > start,
               data[data.index(before: bodyEnd)] == 0x0D {
                bodyEnd = data.index(before: bodyEnd)
            }
            let range = start..<bodyEnd
            let line = data.subdata(in: range)
            if let object = try? JSONSerialization
               .jsonObject(with: line) as? [String: Any],
               object["type"] as? String == "session_meta" {
                found.append((line, range))
            }
            guard let newline else { break }
            start = data.index(after: newline)
        }
        guard !found.isEmpty else {
            throw SessionSyncError.noMetadata(path)
        }
        return found
    }

    private static func metadataString(
        _ payload: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func metadataDate(
        _ payload: [String: Any],
        keys: [String]
    ) -> Date? {
        guard let raw = metadataString(
            payload,
            keys: keys
        ) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.date(from: raw)
            ?? ISO8601DateFormatter()
                .date(from: raw)
    }

    private static func insertingProvider(
        into line: String,
        literal: String,
        path: String
    ) throws -> String {
        let payloadRegex = try NSRegularExpression(
            pattern: #""payload"\s*:\s*\{"#
        )
        let fullRange = NSRange(line.startIndex..., in: line)
        guard let match = payloadRegex.firstMatch(
            in: line,
            range: fullRange
        ),
        let matchRange = Range(match.range, in: line),
        let open = line[matchRange].lastIndex(of: "{"),
        let close = matchingObjectClose(
            in: line,
            opening: open
        ) else {
            throw SessionSyncError.malformedRollout(path)
        }
        let content = line[
            line.index(after: open)..<close
        ]
        let separator = content.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? "" : ","
        var output = line
        output.insert(
            contentsOf:
                "\(separator)\"model_provider\":\(literal)",
            at: close
        )
        return output
    }

    private static func matchingObjectClose(
        in text: String,
        opening: String.Index
    ) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = opening
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func verifyOnlyProviderChanged(
        old: String,
        new: String,
        targetProvider: String,
        path: String
    ) throws {
        guard var oldObject = try JSONSerialization
            .jsonObject(with: Data(old.utf8)) as? [String: Any],
              var newObject = try JSONSerialization
                .jsonObject(with: Data(new.utf8)) as? [String: Any],
              var oldPayload =
                oldObject["payload"] as? [String: Any],
              var newPayload =
                newObject["payload"] as? [String: Any],
              newPayload["model_provider"] as? String
                == targetProvider else {
            throw SessionSyncError.malformedRollout(path)
        }
        oldPayload.removeValue(forKey: "model_provider")
        newPayload.removeValue(forKey: "model_provider")
        oldObject["payload"] = oldPayload
        newObject["payload"] = newPayload
        guard NSDictionary(dictionary: oldObject)
            .isEqual(to: newObject) else {
            throw SessionSyncError.malformedRollout(path)
        }
    }

    private static func hasUserEvent(in data: Data) -> Bool {
        let needle = Data("\"role\":\"user\"".utf8)
        if data.range(of: needle) != nil { return true }
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.range(
            of: #""role"\s*:\s*"user""#,
            options: .regularExpression
        ) != nil
    }
}

enum SQLiteSessionStore {
    static func inspect(
        _ url: URL
    ) throws -> SessionDatabasePlan? {
        try inspectWithDisplayMetadata(url)?.plan
    }

    static func inspectWithDisplayMetadata(
        _ url: URL
    ) throws -> SessionDatabaseInspection? {
        try SessionSyncFileSafety.requireRegularFile(url)
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { connection.close() }
        let tables = try connection.textValues(
            "SELECT name FROM sqlite_master "
                + "WHERE type='table'"
        )
        guard tables.contains("threads") else {
            if url.lastPathComponent.lowercased()
                .hasPrefix("state") {
                throw SessionSyncError
                    .unknownDatabaseSchema(url.path)
            }
            return nil
        }
        let columns = try connection.tableColumns("threads")
        guard columns.contains("id"),
              columns.contains("model_provider") else {
            throw SessionSyncError
                .unknownDatabaseSchema(url.path)
        }
        try connection.requireIntegrity(path: url.path)
        try connection.requireWritableAndUnlocked(path: url.path)
        let displayColumns = [
            "title",
            "created_at",
            "updated_at",
        ].filter(columns.contains)
        let selectedColumns =
            ["id", "model_provider"]
                + displayColumns
        let rows = try connection.rows(
            "SELECT "
                + selectedColumns
                    .joined(separator: ", ")
                + " FROM threads"
        )
        var providers: [String: String] = [:]
        var displayMetadata:
            [String: SessionDatabaseDisplayMetadata] = [:]
        for row in rows {
            guard let id = row[safe: 0] ?? nil,
                  !id.isEmpty else { continue }
            providers[id] = row[safe: 1] ?? nil
                ?? ""
            var values: [String: String?] = [:]
            for (
                offset,
                column
            ) in displayColumns.enumerated() {
                values[column] =
                    row[safe: offset + 2] ?? nil
            }
            displayMetadata[id] =
                SessionDatabaseDisplayMetadata(
                    title: nonempty(
                        values["title"] ?? nil
                    ),
                    createdAt: parseDate(
                        values["created_at"] ?? nil
                    ),
                    updatedAt: parseDate(
                        values["updated_at"] ?? nil
                    )
                )
        }
        let metadata = try SessionSyncFileSafety.metadata(url)
        return SessionDatabaseInspection(
            plan: SessionDatabasePlan(
                url: url.standardizedFileURL,
                columns: columns.sorted(),
                threadIDs: providers.keys.sorted(),
                providerByThreadID: providers,
                permissions: metadata.permissions,
                modificationDate: metadata.modificationDate
            ),
            displayMetadataByThreadID:
                displayMetadata
        )
    }

    private static func nonempty(
        _ value: String?
    ) -> String? {
        let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(
        _ value: String?
    ) -> Date? {
        guard let raw = nonempty(value) else {
            return nil
        }
        if let number = Double(raw),
           number.isFinite {
            let seconds: Double
            if abs(number) >= 1_000_000_000_000_000 {
                seconds = number / 1_000_000_000
            } else if abs(number)
                >= 1_000_000_000_000 {
                seconds = number / 1_000
            } else {
                seconds = number
            }
            return Date(
                timeIntervalSince1970: seconds
            )
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(
            identifier: "en_US_POSIX"
        )
        formatter.timeZone = TimeZone(
            secondsFromGMT: 0
        )
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    static func schemaColumns(_ url: URL) throws -> [String] {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { connection.close() }
        return try connection.tableColumns("threads").sorted()
    }

    static func requireWritableAndUnlocked(
        _ url: URL
    ) throws {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { connection.close() }
        try connection.requireWritableAndUnlocked(path: url.path)
    }

    static func requireIntegrity(_ url: URL) throws {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READONLY
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { connection.close() }
        try connection.requireIntegrity(path: url.path)
    }

    static func backupData(_ url: URL) throws -> Data {
        try SessionSyncFileSafety.requireRegularFile(url)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ai-access-session-backup-\(UUID().uuidString).sqlite"
            )
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(
                atPath: temporary.path + "-wal"
            )
            try? FileManager.default.removeItem(
                atPath: temporary.path + "-shm"
            )
        }
        let source = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READONLY
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { source.close() }
        try source.requireIntegrity(path: url.path)
        let destination = try SQLiteConnection(
            url: temporary,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_CREATE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { destination.close() }
        try SQLiteConnection.backup(
            source: source,
            destination: destination
        )
        try destination.requireIntegrity(path: temporary.path)
        destination.close()
        return try Data(contentsOf: temporary)
    }

    static func restoreBackup(
        _ data: Data,
        to target: URL,
        permissions: Int,
        modificationDate: Date?
    ) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ai-access-session-restore-\(UUID().uuidString).sqlite"
            )
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(
                atPath: temporary.path + "-wal"
            )
            try? FileManager.default.removeItem(
                atPath: temporary.path + "-shm"
            )
        }
        try data.write(to: temporary, options: [.atomic])
        let source = try SQLiteConnection(
            url: temporary,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { source.close() }
        try source.requireIntegrity(path: temporary.path)
        let destination = try SQLiteConnection(
            url: target,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { destination.close() }
        try destination.requireWritableAndUnlocked(
            path: target.path
        )
        try SQLiteConnection.backup(
            source: source,
            destination: destination
        )
        try destination.requireIntegrity(path: target.path)
        destination.close()
        try FileManager.default.setAttributes(
            [
                .posixPermissions: permissions,
                .modificationDate:
                    modificationDate ?? Date(),
            ],
            ofItemAtPath: target.path
        )
    }

    static func synchronize(
        _ url: URL,
        targetProvider: String,
        rolloutEvidence: [String: SessionRolloutPlan]
    ) throws {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { connection.close() }
        try connection.requireWritableAndUnlocked(path: url.path)
        let columns = try connection.tableColumns("threads")
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try connection.execute(
                "UPDATE threads SET model_provider = ?",
                bindings: [.text(targetProvider)]
            )
            try correctEvidence(
                connection,
                columns: columns,
                rolloutEvidence: rolloutEvidence
            )
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    static func correctEvidence(
        _ url: URL,
        rolloutEvidence: [String: SessionRolloutPlan]
    ) throws {
        let connection = try SQLiteConnection(
            url: url,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
        )
        defer { connection.close() }
        try connection.requireWritableAndUnlocked(path: url.path)
        let columns = try connection.tableColumns("threads")
        do {
            try connection.execute("BEGIN IMMEDIATE")
            try correctEvidence(
                connection,
                columns: columns,
                rolloutEvidence: rolloutEvidence
            )
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func correctEvidence(
        _ connection: SQLiteConnection,
        columns: [String],
        rolloutEvidence: [String: SessionRolloutPlan]
    ) throws {
        let hasUserEvent = columns.contains("has_user_event")
        let hasCWD = columns.contains("cwd")
        guard hasUserEvent || hasCWD else { return }
        for (threadID, evidence) in rolloutEvidence {
            var assignments: [String] = []
            var bindings: [SQLiteBinding] = []
            if hasUserEvent {
                assignments.append("has_user_event = ?")
                bindings.append(
                    .integer(evidence.hasUserEvent ? 1 : 0)
                )
            }
            if hasCWD, let cwd = evidence.workingDirectory {
                assignments.append("cwd = ?")
                bindings.append(.text(cwd))
            }
            guard !assignments.isEmpty else { continue }
            bindings.append(.text(threadID))
            try connection.execute(
                "UPDATE threads SET "
                    + assignments.joined(separator: ", ")
                    + " WHERE id = ?",
                bindings: bindings
            )
        }
    }
}

private enum SQLiteBinding {
    case text(String)
    case integer(Int64)
    case null
}

private final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(url: URL, flags: Int32) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            flags,
            nil
        )
        guard result == SQLITE_OK, database != nil else {
            let message = database.flatMap {
                sqlite3_errmsg($0).map(String.init(cString:))
            } ?? "未知错误"
            if let database { sqlite3_close(database) }
            throw SessionSyncError.databaseOpen(
                "\(url.path)：\(message)"
            )
        }
        handle = database
        sqlite3_busy_timeout(database, 0)
    }

    func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    func execute(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws {
        guard let handle else {
            throw SessionSyncError.databaseFailure(
                "数据库已关闭"
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw failure(handle)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                throw SessionSyncError.databaseLocked(
                    sqlite3_db_filename(handle, "main")
                        .map(String.init(cString:))
                        ?? "SQLite"
                )
            }
            throw failure(handle)
        }
    }

    func rows(_ sql: String) throws -> [[String?]] {
        guard let handle else {
            throw SessionSyncError.databaseFailure(
                "数据库已关闭"
            )
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw failure(handle)
        }
        defer { sqlite3_finalize(statement) }
        var output: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else {
                if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    throw SessionSyncError.databaseLocked(
                        sqlite3_db_filename(handle, "main")
                            .map(String.init(cString:))
                            ?? "SQLite"
                    )
                }
                throw failure(handle)
            }
            output.append(
                (0..<sqlite3_column_count(statement)).map {
                    guard sqlite3_column_type(statement, $0)
                        != SQLITE_NULL,
                          let text =
                            sqlite3_column_text(statement, $0)
                    else { return nil }
                    return String(cString: text)
                }
            )
        }
    }

    func textValues(_ sql: String) throws -> [String] {
        try rows(sql).compactMap { $0.first ?? nil }
    }

    func tableColumns(_ table: String) throws -> [String] {
        try rows("PRAGMA table_info(\(table))")
            .compactMap { row in
                guard row.indices.contains(1) else { return nil }
                return row[1]
            }
    }

    func requireIntegrity(path: String) throws {
        let values = try textValues("PRAGMA integrity_check")
        guard values == ["ok"] else {
            throw SessionSyncError.databaseIntegrity(path)
        }
    }

    func requireWritableAndUnlocked(path: String) throws {
        do {
            try execute("BEGIN IMMEDIATE")
            try execute("ROLLBACK")
        } catch SessionSyncError.databaseLocked {
            throw SessionSyncError.databaseLocked(path)
        }
    }

    static func backup(
        source: SQLiteConnection,
        destination: SQLiteConnection
    ) throws {
        guard let sourceHandle = source.handle,
              let destinationHandle = destination.handle,
              let backup = sqlite3_backup_init(
                  destinationHandle,
                  "main",
                  sourceHandle,
                  "main"
              ) else {
            throw SessionSyncError.databaseFailure(
                "无法初始化SQLite官方备份"
            )
        }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw SessionSyncError.databaseFailure(
                "SQLite官方备份失败：\(result)/\(finish)"
            )
        }
    }

    private func bind(
        _ bindings: [SQLiteBinding],
        to statement: OpaquePointer
    ) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                result = sqlite3_bind_text(
                    statement,
                    index,
                    text,
                    -1,
                    unsafeBitCast(
                        -1,
                        to: sqlite3_destructor_type.self
                    )
                )
            case let .integer(integer):
                result = sqlite3_bind_int64(
                    statement,
                    index,
                    integer
                )
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw SessionSyncError.databaseFailure(
                    "SQLite参数绑定失败：\(result)"
                )
            }
        }
    }

    private func failure(
        _ handle: OpaquePointer
    ) -> SessionSyncError {
        let path = sqlite3_db_filename(handle, "main")
            .map(String.init(cString:)) ?? "SQLite"
        return SessionSyncError.databaseFailure(
            "\(path)："
                + (
                    sqlite3_errmsg(handle)
                        .map(String.init(cString:))
                        ?? "SQLite未知错误"
                )
        )
    }
}

struct SessionFileMetadata {
    let permissions: Int
    let modificationDate: Date?
}

enum SessionSyncFileSafety {
    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true else {
            throw SessionSyncError.unsafePath(url.path)
        }
        guard values.isSymbolicLink != true else {
            throw SessionSyncError.symbolicLink(url.path)
        }
    }

    static func metadata(
        _ url: URL
    ) throws -> SessionFileMetadata {
        try requireRegularFile(url)
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path)
        return SessionFileMetadata(
            permissions:
                (attributes[.posixPermissions] as? NSNumber)?
                    .intValue ?? 0o600,
            modificationDate:
                attributes[.modificationDate] as? Date
        )
    }

    static func hashIfPresent(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return SecureProfileVault.sha256(data)
    }

    static func recursiveJSONLFiles(
        root: URL,
        maximumFiles: Int
    ) throws -> [URL] {
        guard maximumFiles >= 0 else {
            throw SessionSyncError.tooManyFiles
        }
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw SessionSyncError.unsafePath(root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var output: [URL] = []
        for case let item as URL in enumerator {
            let itemValues = try item.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            if itemValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw SessionSyncError.symbolicLink(item.path)
            }
            guard itemValues.isRegularFile == true,
                  item.pathExtension.lowercased() == "jsonl"
            else { continue }
            guard output.count < maximumFiles else {
                throw SessionSyncError.tooManyFiles
            }
            output.append(item.standardizedFileURL)
        }
        return output.sorted { $0.path < $1.path }
    }

    static func databaseCandidates(
        root: URL,
        maximumFiles: Int
    ) throws -> [URL] {
        let roots = [
            root,
            root.appendingPathComponent(
                "sqlite",
                isDirectory: true
            ),
        ]
        var output = Set<URL>()
        for directory in roots
            where FileManager.default.fileExists(
                atPath: directory.path
            ) {
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw SessionSyncError.unsafePath(
                    directory.path
                )
            }
            for item in try FileManager.default
                .contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ],
                    options: [.skipsHiddenFiles]
                )
                where item.pathExtension.lowercased()
                    == "sqlite" {
                try requireRegularFile(item)
                output.insert(item.standardizedFileURL)
                guard output.count <= maximumFiles else {
                    throw SessionSyncError.tooManyFiles
                }
            }
        }
        return output.sorted { $0.path < $1.path }
    }

    static func isDescendant(
        _ path: String,
        of root: String
    ) -> Bool {
        path == root || path.hasPrefix(
            root.hasSuffix("/") ? root : root + "/"
        )
    }
}

enum SessionSyncAtomicFile {
    static func write(
        _ data: Data,
        to url: URL,
        expectedHash: String?,
        permissions: Int,
        modificationDate: Date?
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if manager.fileExists(atPath: url.path) {
            try SessionSyncFileSafety.requireRegularFile(url)
        }
        guard SessionSyncFileSafety.hashIfPresent(url)
            == expectedHash else {
            throw SessionSyncError.rolloutChanged(url.path)
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".ai-access-session-\(UUID().uuidString).tmp"
            )
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [])
        try manager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: temporary.path
        )
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(
                url,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: permissions,
        ]
        if let modificationDate {
            attributes[.modificationDate] = modificationDate
        }
        try manager.setAttributes(
            attributes,
            ofItemAtPath: url.path
        )
        let directoryDescriptor = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            throw SessionSyncError
                .recoveryVerificationFailed(url.path)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0,
              SessionSyncFileSafety.hashIfPresent(url)
                == SecureProfileVault.sha256(data) else {
            throw SessionSyncError
                .recoveryVerificationFailed(url.path)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
