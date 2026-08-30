// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

enum B64ContractViolation: String, Codable, CaseIterable, Sendable {
    case invalidVersion
    case invalidAttempt
    case invalidCount
    case invalidSize
    case transactionOrder
}

/// Build64 source-safe contracts. These types are deliberately read-model and
/// fixture oriented: they do not open Codex configuration, Keychain, SQLite,
/// session bodies, or install locations.
enum B64EvidenceLayer: String, Codable, CaseIterable, Sendable {
    case sourceGate
    case packageOwnerGate
    case runtimeGate
}

enum B64EvidenceStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case unverified = "UNVERIFIED"
}

struct B64EvidenceClaim: Codable, Equatable, Sendable {
    let layer: B64EvidenceLayer
    let status: B64EvidenceStatus
    let claim: String
    let evidence: String?

    init(
        layer: B64EvidenceLayer,
        status: B64EvidenceStatus,
        claim: String,
        evidence: String? = nil
    ) {
        self.layer = layer
        self.status = status
        self.claim = claim
        self.evidence = evidence
    }
}

struct B64EvidenceBundle: Codable, Equatable, Sendable {
    let claims: [B64EvidenceClaim]

    var sourceGateStatus: B64EvidenceStatus {
        status(for: .sourceGate)
    }

    var packageOwnerStatus: B64EvidenceStatus {
        status(for: .packageOwnerGate)
    }

    var runtimeStatus: B64EvidenceStatus {
        status(for: .runtimeGate)
    }

    /// Source evidence must never be promoted to package/runtime evidence.
    var releaseStatus: B64EvidenceStatus {
        if claims.contains(where: { $0.status == .fail }) { return .fail }
        guard sourceGateStatus == .pass else { return .unverified }
        guard packageOwnerStatus == .pass,
              runtimeStatus == .pass else { return .unverified }
        return .pass
    }

    private func status(for layer: B64EvidenceLayer) -> B64EvidenceStatus {
        let relevant = claims.filter { $0.layer == layer }
        guard !relevant.isEmpty else { return .unverified }
        if relevant.contains(where: { $0.status == .fail }) { return .fail }
        if relevant.contains(where: { $0.status == .unverified }) { return .unverified }
        return .pass
    }
}

enum B64UpgradeFailure: String, Codable, CaseIterable, Sendable {
    case versionMismatch
    case architectureMismatch
    case signatureMismatch
    case bundleHashMismatch
    case sourceManifestMismatch
    case halfInstalled
    case launchFailed
    case rollbackFailed
}

struct B64UpgradeReceipt: Codable, Equatable, Sendable {
    let transactionID: String
    let oldBuild: String
    let newBuild: String
    let backupHash: String
    let action: String
    let result: B64EvidenceStatus
    let failure: B64UpgradeFailure?
    let observedAt: Date

    var isRecoverableFailure: Bool {
        result == .fail && failure != .rollbackFailed
    }
}

enum B64RecoveryAction: String, Codable, CaseIterable, Sendable {
    case retrySession
    case skipHistory
    case keepCurrentConfiguration
    case restoreCandidate
}

struct B64RecoveryCenterSnapshot: Codable, Equatable, Sendable {
    let snapshotID: String
    let version: Int
    let configTransactionID: String?
    let configPhase: String?
    let sessionTransactionID: String?
    let sessionPhase: String?
    let receiptHash: String?
    let journalHash: String?
    let configCommitted: Bool
    let pendingAction: B64RecoveryAction?
    let failureCode: String?
    let failureStage: String?
    let nextAction: B64RecoveryAction?
    let observedAt: Date

    init(
        snapshotID: String = UUID().uuidString,
        version: Int = 1,
        configTransactionID: String? = nil,
        configPhase: String? = nil,
        sessionTransactionID: String? = nil,
        sessionPhase: String? = nil,
        receiptHash: String? = nil,
        journalHash: String? = nil,
        configCommitted: Bool = false,
        pendingAction: B64RecoveryAction? = nil,
        failureCode: String? = nil,
        failureStage: String? = nil,
        nextAction: B64RecoveryAction? = nil,
        observedAt: Date = Date()
    ) {
        self.snapshotID = snapshotID
        self.version = version
        self.configTransactionID = configTransactionID
        self.configPhase = configPhase
        self.sessionTransactionID = sessionTransactionID
        self.sessionPhase = sessionPhase
        self.receiptHash = receiptHash
        self.journalHash = journalHash
        self.configCommitted = configCommitted
        self.pendingAction = pendingAction
        self.failureCode = failureCode
        self.failureStage = failureStage
        self.nextAction = nextAction
        self.observedAt = observedAt
    }

    var configurationIsHealthy: Bool {
        guard configCommitted else { return false }
        // A committed ConfigTxn remains healthy when only the independent
        // SessionTxn failed or is awaiting retry. Configuration failures do
        // keep this card unhealthy.
        guard let failureStage else { return true }
        return failureStage != "configurationCheck"
            && failureStage != "configurationRestore"
    }

    var validationErrors: [B64ContractViolation] {
        var errors: [B64ContractViolation] = []
        if version < 1 { errors.append(.invalidVersion) }
        if !B64TransactionOrderCheck.from(self).isValid { errors.append(.transactionOrder) }
        return errors
    }
}

struct B64TransactionOrderCheck: Equatable, Sendable {
    let configCommitted: Bool
    let sessionStarted: Bool

    var isValid: Bool {
        !sessionStarted || configCommitted
    }

    static func from(_ snapshot: B64RecoveryCenterSnapshot) -> B64TransactionOrderCheck {
        B64TransactionOrderCheck(
            configCommitted: snapshot.configCommitted,
            sessionStarted: snapshot.sessionPhase != nil
        )
    }
}

enum B64RecoveryDispatchResult: Equatable, Sendable {
    case dispatched
    case idempotent
    case staleSnapshot
    case unavailable
}

protocol B64RecoveryActionDispatching: Sendable {
    func dispatch(
        _ action: B64RecoveryAction,
        snapshot: B64RecoveryCenterSnapshot
    ) throws -> B64RecoveryDispatchResult
}

/// CAS guard for the recovery-center dispatcher. Implementations can wrap the
/// existing coordinator; this contract intentionally has no write operation.
struct B64RecoveryCenterDispatcher: Sendable {
    let dispatchAction: @Sendable (
        B64RecoveryAction,
        B64RecoveryCenterSnapshot
    ) throws -> B64RecoveryDispatchResult

    func dispatch(
        _ action: B64RecoveryAction,
        from snapshot: B64RecoveryCenterSnapshot
    ) throws -> B64RecoveryDispatchResult {
        guard snapshot.nextAction == action || snapshot.pendingAction == action else {
            return .unavailable
        }
        return try dispatchAction(action, snapshot)
    }
}

struct B64HistorySnapshot: Codable, Equatable, Sendable {
    let snapshotID: String
    let indexVersion: Int
    let totalIndexed: Int
    let visibleCount: Int
    let pendingRecoveryCount: Int
    let filter: String?
    let page: Int
    let pageSize: Int
    let observedAt: Date

    init(
        snapshotID: String = UUID().uuidString,
        indexVersion: Int,
        totalIndexed: Int,
        visibleCount: Int,
        pendingRecoveryCount: Int,
        filter: String? = nil,
        page: Int = 0,
        pageSize: Int = 50,
        observedAt: Date = Date()
    ) {
        self.snapshotID = snapshotID
        self.indexVersion = indexVersion
        self.totalIndexed = max(0, totalIndexed)
        self.visibleCount = max(0, min(visibleCount, totalIndexed))
        self.pendingRecoveryCount = max(0, min(pendingRecoveryCount, totalIndexed))
        self.filter = filter
        self.page = max(0, page)
        self.pageSize = max(1, pageSize)
        self.observedAt = observedAt
    }

    var isConsistent: Bool {
        visibleCount <= totalIndexed && pendingRecoveryCount <= totalIndexed
    }

    var validationErrors: [B64ContractViolation] {
        var errors: [B64ContractViolation] = []
        if indexVersion < 1 { errors.append(.invalidVersion) }
        if totalIndexed < 0 || visibleCount < 0 || pendingRecoveryCount < 0
            || visibleCount > totalIndexed || pendingRecoveryCount > totalIndexed
            || page < 0 || pageSize < 1 {
            errors.append(.invalidCount)
        }
        return errors
    }
}

struct B64HistoryIndexPage: Codable, Equatable, Sendable {
    let snapshot: B64HistorySnapshot
    let identifiers: [String]
    let hasMore: Bool

    init(snapshot: B64HistorySnapshot, identifiers: [String], hasMore: Bool) {
        self.snapshot = snapshot
        self.identifiers = Array(identifiers.prefix(snapshot.pageSize))
        self.hasMore = hasMore || identifiers.count > snapshot.pageSize
    }
}

enum B64SnapshotSource: String, Codable, CaseIterable, Sendable {
    case current
    case lastKnownGood = "lkg"
    case candidate
}

enum B64SnapshotApplyFailure: String, Codable, CaseIterable, Sendable {
    case staleExpectedHash
    case thirdValueConflict
    case futureSchema
    case unknownDangerousField
    case writerUnavailable
}

enum B64SnapshotCASWriterError: Error, Equatable, Sendable {
    case thirdValueConflict
    case unavailable
}

struct B64SnapshotApplyRequest: Codable, Equatable, Sendable {
    let source: B64SnapshotSource
    let expectedConfigHash: String
    let snapshotHash: String
    let schemaVersion: Int
    let supportedSchemaVersion: Int
    let unknownFields: [String]
    let dangerousUnknownFields: [String]
}

enum B64SnapshotApplyResult: Codable, Equatable, Sendable {
    case applied(newConfigHash: String)
    case rejected(B64SnapshotApplyFailure)
}

protocol B64SnapshotCASWriting: Sendable {
    func applySnapshot(
        _ request: B64SnapshotApplyRequest,
        expectedCurrentHash: String
    ) throws -> String
}

struct B64SnapshotApplyCoordinator: Sendable {
    let writer: any B64SnapshotCASWriting

    func apply(
        _ request: B64SnapshotApplyRequest,
        currentConfigHash: String
    ) throws -> B64SnapshotApplyResult {
        guard request.expectedConfigHash == currentConfigHash else {
            return .rejected(.staleExpectedHash)
        }
        guard request.schemaVersion <= request.supportedSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard request.dangerousUnknownFields.isEmpty else {
            return .rejected(.unknownDangerousField)
        }
        do {
            return .applied(newConfigHash: try writer.applySnapshot(
                request,
                expectedCurrentHash: currentConfigHash
            ))
        } catch B64SnapshotCASWriterError.thirdValueConflict {
            return .rejected(.thirdValueConflict)
        } catch B64SnapshotCASWriterError.unavailable {
            return .rejected(.writerUnavailable)
        } catch {
            return .rejected(.writerUnavailable)
        }
    }
}

struct B64BatchRepairReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, CaseIterable, Sendable {
        case pending
        case running
        case paused
        case cancelled
        case completed
        case skipped
        case failed
    }

    let batchID: String
    let transactionID: String
    let attempt: Int
    let completedCount: Int
    let totalCount: Int
    let estimatedBytes: Int64
    let state: State
    let failureCode: String?
    let updatedAt: Date

    var isResumable: Bool {
        [.pending, .running, .paused, .cancelled, .failed].contains(state)
    }

    var validationErrors: [B64ContractViolation] {
        var errors: [B64ContractViolation] = []
        if attempt < 1 { errors.append(.invalidAttempt) }
        if completedCount < 0 || totalCount < 0 || completedCount > totalCount {
            errors.append(.invalidCount)
        }
        if estimatedBytes < 0 { errors.append(.invalidSize) }
        return errors
    }
}

enum B64JournalV2Gate {
    static func evaluate(
        v1Readable: Bool,
        rollbackPassed: Bool,
        boundedMemoryPassed: Bool,
        capacityPassed: Bool
    ) -> B64EvidenceStatus {
        v1Readable && rollbackPassed && boundedMemoryPassed && capacityPassed
            ? .pass
            : .unverified
    }
}

enum B64FeatureGate: String, Codable, Sendable {
    case enabled
    case featureOff
    case unverified

    static func journalV2(
        v1Readable: Bool,
        rollbackPassed: Bool,
        boundedMemoryPassed: Bool,
        capacityPassed: Bool
    ) -> B64FeatureGate {
        B64JournalV2Gate.evaluate(
            v1Readable: v1Readable,
            rollbackPassed: rollbackPassed,
            boundedMemoryPassed: boundedMemoryPassed,
            capacityPassed: capacityPassed
        ) == .pass ? .enabled : .featureOff
    }
}

enum B64RouteFailureCode: String, Codable, CaseIterable, Sendable {
    case dns
    case tls
    case http
    case authentication
    case timeout
    case unknown
}

struct B64RouteHealth: Codable, Equatable, Sendable {
    let host: String
    let routeKind: String
    let expiresAt: Date?
    let observedAt: Date?
    let failureCode: B64RouteFailureCode?
    let isFresh: Bool

    init(
        endpoint: String,
        routeKind: String,
        expiresAt: Date? = nil,
        observedAt: Date? = nil,
        failureCode: B64RouteFailureCode? = nil,
        now: Date = Date()
    ) {
        self.host = B64RouteHealth.hostOnly(endpoint)
        self.routeKind = routeKind
        self.expiresAt = expiresAt
        self.observedAt = observedAt
        self.failureCode = failureCode
        let observationFresh = observedAt.map {
            now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 3600
        } ?? false
        let notExpired = expiresAt.map { $0 > now } ?? true
        self.isFresh = observationFresh && notExpired
    }

    private static func hostOnly(_ endpoint: String) -> String {
        if let components = URLComponents(string: endpoint), let host = components.host {
            return host
        }
        return endpoint
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
    }
}

struct B64RecoveryProgress: Codable, Equatable, Sendable {
    let operationID: String
    let attempt: Int
    let completed: Int
    let total: Int
    let currentBatch: String?
    let lastError: String?
    let updatedAt: Date

    var isComplete: Bool { total > 0 && completed >= total }
    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    var validationErrors: [B64ContractViolation] {
        var errors: [B64ContractViolation] = []
        if attempt < 1 { errors.append(.invalidAttempt) }
        if completed < 0 || total < 0 || completed > total { errors.append(.invalidCount) }
        return errors
    }
}

enum B64ProgressStoreError: Error, Equatable, Sendable {
    case staleHash
    case unsafePath
    case invalidData
}

/// A bounded receipt-only store for isolated fixtures. It never writes config,
/// credentials, SQLite, or session data. Production integration must continue
/// to use the existing coordinator/receipt writer and its CAS policy.
struct B64ProgressReceiptStore {
    let url: URL
    private let fileManager: FileManager
    private static let processLock = NSLock()

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url.standardizedFileURL
        self.fileManager = fileManager
    }

    func read() throws -> (progress: B64RecoveryProgress, hash: String)? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw B64ProgressStoreError.unsafePath
        }
        let data = try Data(contentsOf: url)
        guard let progress = try? JSONDecoder().decode(B64RecoveryProgress.self, from: data) else {
            throw B64ProgressStoreError.invalidData
        }
        return (progress, Self.hash(data))
    }

    @discardableResult
    func write(
        _ progress: B64RecoveryProgress,
        expectedHash: String?
    ) throws -> String {
        // Serialize all fixture-store writers in this process so the
        // read/compare/replace sequence is one CAS critical section.
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let existing = try read()
        if let expectedHash {
            guard existing?.hash == expectedHash else {
                throw B64ProgressStoreError.staleHash
            }
        } else if existing != nil {
            // A nil expected hash means create-only; never overwrite an
            // existing receipt without an explicit CAS value.
            throw B64ProgressStoreError.staleHash
        }
        let data = try JSONEncoder().encode(progress)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".build64-progress-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return Self.hash(data)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct B64SafeModeState: Codable, Equatable, Sendable {
    let enabled: Bool
    let consecutiveFailures: Int
    let reason: String?

    static func evaluate(
        consecutiveFailures: Int,
        receiptCorrupt: Bool,
        threshold: Int = 3
    ) -> B64SafeModeState {
        let enabled = receiptCorrupt || consecutiveFailures >= threshold
        return B64SafeModeState(
            enabled: enabled,
            consecutiveFailures: max(0, consecutiveFailures),
            reason: receiptCorrupt ? "receiptCorrupt" : (enabled ? "repeatedRecoveryFailure" : nil)
        )
    }
}

struct B64TimelineEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let build: String
    let transactionID: String
    let phase: String
    let attempt: Int
    let result: String
    let nextAction: String?
}

struct B64DerivedTimeline: Codable, Equatable, Sendable {
    let events: [B64TimelineEvent]

    init(events: [B64TimelineEvent]) {
        self.events = events.sorted { $0.timestamp < $1.timestamp }
    }
}

struct B64FailurePresentation: Codable, Equatable, Sendable {
    let code: String
    let stage: String
    let message: String
    let retryable: Bool
    let nextAction: B64RecoveryAction?

    static func from(code: String, stage: String) -> B64FailurePresentation {
        let normalized = code.lowercased()
        if normalized.contains("dns") {
            return .init(code: code, stage: stage, message: "域名解析失败", retryable: true, nextAction: .retrySession)
        }
        if normalized.contains("tls") || normalized.contains("certificate") {
            return .init(code: code, stage: stage, message: "TLS证书或握手失败", retryable: true, nextAction: .retrySession)
        }
        if normalized.contains("http") {
            return .init(code: code, stage: stage, message: "中转返回HTTP错误", retryable: true, nextAction: .retrySession)
        }
        if normalized.contains("timeout") {
            return .init(code: code, stage: stage, message: "连接超时", retryable: true, nextAction: .retrySession)
        }
        if normalized.contains("capacity") {
            return .init(code: code, stage: stage, message: "历史整理容量超限", retryable: true, nextAction: .retrySession)
        }
        if normalized.contains("cas") || normalized.contains("conflict") {
            return .init(code: code, stage: stage, message: "状态已变化，请重新读取后再试", retryable: true, nextAction: .retrySession)
        }
        if normalized.contains("auth") {
            return .init(code: code, stage: stage, message: "认证失败，请检查连接配置", retryable: false, nextAction: .keepCurrentConfiguration)
        }
        if normalized.contains("permission") || normalized.contains("access denied") {
            return .init(code: code, stage: stage, message: "文件权限不足", retryable: false, nextAction: .keepCurrentConfiguration)
        }
        if normalized.contains("recovery") {
            return .init(code: code, stage: stage, message: "恢复记录无法安全读取", retryable: true, nextAction: .keepCurrentConfiguration)
        }
        return .init(code: code, stage: stage, message: "操作未完成，请查看诊断", retryable: true, nextAction: .retrySession)
    }
}

struct B64RetentionItem: Codable, Equatable, Sendable {
    let identifier: String
    let bytes: Int64
    let active: Bool
    let pendingRecovery: Bool
    let referencedByDiagnostic: Bool

    var isCleanable: Bool {
        !active && !pendingRecovery && !referencedByDiagnostic
    }
}

struct B64RetentionInspection: Codable, Equatable, Sendable {
    let items: [B64RetentionItem]
    let totalBytes: Int64

    init(items: [B64RetentionItem]) {
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + max(0, $1.bytes) }
    }

    var cleanableItems: [B64RetentionItem] { items.filter(\.isCleanable) }
    var cleanableBytes: Int64 { cleanableItems.reduce(0) { $0 + max(0, $1.bytes) } }
}

struct B64PerformanceSample: Codable, Equatable, Sendable {
    let operation: String
    let milliseconds: Double
    let environmentHash: String
    let build: String
}

struct B64PerformanceTrend: Codable, Equatable, Sendable {
    let operation: String
    let environmentHash: String
    let build: String
    let warmupCount: Int
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let baselineP95Milliseconds: Double?

    init(
        samples: [B64PerformanceSample],
        warmupCount: Int = 0,
        baselineP95Milliseconds: Double? = nil
    ) {
        let first = samples.first
        let operation = first?.operation ?? ""
        let environmentHash = first?.environmentHash ?? ""
        let build = first?.build ?? ""
        let grouped = samples.filter {
            $0.operation == operation
                && $0.environmentHash == environmentHash
                && $0.build == build
                && $0.milliseconds >= 0
        }
        let boundedWarmup = min(max(0, warmupCount), grouped.count)
        let durations = Array(grouped.dropFirst(boundedWarmup))
            .map(\.milliseconds)
            .sorted()
        self.operation = operation
        self.environmentHash = environmentHash
        self.build = build
        self.warmupCount = boundedWarmup
        self.sampleCount = durations.count
        self.p50Milliseconds = Self.percentile(durations, 0.50)
        self.p95Milliseconds = Self.percentile(durations, 0.95)
        self.baselineP95Milliseconds = baselineP95Milliseconds
    }

    var exceedsTwentyPercentBaseline: Bool {
        guard meetsSampleFloor,
              let baselineP95Milliseconds,
              baselineP95Milliseconds > 0 else { return false }
        return p95Milliseconds > baselineP95Milliseconds * 1.20
    }

    var meetsSampleFloor: Bool { sampleCount >= 30 }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, Int(ceil(Double(values.count) * fraction)) - 1)
        return values[max(0, index)]
    }
}

enum B64DiagnosticRedactor {
    static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)((?:https?|wss?|file)://)[^\s/]+(?:/[^\s\"}]*)?"#,
            #"(?i)\"?(token|cookie|api[_-]?key|password)\"?\s*[:=]\s*\"?[^\s,;\"}]+\"?"#,
            #"/(?:Users|var|private|tmp|Volumes|Applications)/[^\s,;\"}]+"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
            }
        }
        return result
    }
}
