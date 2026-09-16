// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

enum V011SwitchPhase: String, Codable, CaseIterable {
    case prepared
    case configWritten
    case sessionsWritten
    case codexLaunched
    case verified
    case committed
    case rollbackRequired
    case rolledBack
    case rollbackFailed
    case acceptedCurrent

    var isPending: Bool {
        ![.committed, .rolledBack, .acceptedCurrent]
            .contains(self)
    }
}

enum V011HistoryPolicy: String, Codable, CaseIterable, Sendable {
    case configOnly
    case deferred
    case runAfterCommit
}

enum V011ConfigTransactionPhase: String, Codable, CaseIterable, Sendable {
    case prepared
    case configWritten
    case verified
    case committed
}

enum V011SessionTransactionPhase: String, Codable, CaseIterable, Sendable {
    case reserved
    case notStarted
    case prepared
    case running
    case retryableFailure
    case committed
    // Read compatibility for receipts written before Build63. New successful
    // writes use `committed` and do not reinterpret the legacy value.
    case succeeded
    case skipped
    case superseded
    case cancelled
    case terminalFailure
}

enum V011AnchoredIOCheckpoint: Sendable {
    case receiptLockAcquired
}

/// Test-only process-exit marker. Unlike an ordinary injected error, this
/// deliberately bypasses in-process compensation so restart fixtures can
/// exercise the exact persisted crash boundary.
struct V011SimulatedProcessExit: Error, Equatable, Sendable {
    let point: V011SwitchFaultPoint
}

struct V011SessionTransactionCancelled: Error, Equatable, Sendable {
    let stage: String
}

enum V011SessionFailureCode: String, Codable, Equatable, Sendable {
    case journalCapacityExceeded
    case pendingSessionRecovery
    case sessionRepairFailed
    case sessionCancelled
    case receiptConflict
}

/// Durable control errors are intentionally distinct from configuration
/// rollback errors. Session cancellation/resume must never enter ConfigTxn's
/// recovery path.
enum V011SessionTransactionControlError: Error, Equatable, Sendable {
    case staleReceipt
    case staleConfiguration
    case providerDrift
    case profileDrift
    case notResumable
}

/// Cooperative cancellation shared by the coordinator and an isolated test
/// fixture. It is an in-memory request only; the durable receipt is written
/// through V011SessionTransactionReceiptStore with an expected hash (CAS).
final class V011SessionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func cancel() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        requested = false
        lock.unlock()
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

struct V011SessionResumeRequest: Equatable, Sendable {
    let receiptID: String
    let expectedReceiptHash: String
    let currentConfigHash: String
    let currentProvider: String
    let currentProfileID: String?
    let currentProfileHash: String?
}

enum V011SwitchFaultPoint: String, CaseIterable, Sendable {
    case prepared
    case reservationWritten
    case reservationBound
    case configWritten
    case sessionsWritten
    case codexLaunched
    case verified
    case beforeCommit
    case committedBeforeReceiptMaterialize
    case receiptMaterialized
}

enum V011RecoveryFailureStage: String, Codable, Equatable {
    case compatibilityCheck
    case configurationCheck
    case sessionCheck
    case connectionCheck
    case sessionRestore
    case configurationRestore

    var displayName: String {
        switch self {
        case .compatibilityCheck:
            return "Codex版本核对"
        case .configurationCheck:
            return "目标设置核对"
        case .sessionCheck:
            return "历史会话核对"
        case .connectionCheck:
            return "中转连接检测"
        case .sessionRestore:
            return "历史会话恢复"
        case .configurationRestore:
            return "Codex设置恢复"
        }
    }
}

enum V011RecoveryDisposition: Equatable {
    case unread
    case none
    case recoverable
    case decisionRequired
}

struct V011AcceptedCurrentRecord: Codable, Equatable {
    let providerID: String
    let profileID: String
    let configHash: String
    let verifiedAt: Date
}

struct V011SessionSupersedeIntent: Codable, Equatable, Sendable {
    let receiptID: String
    let expectedReceiptHash: String
    let supersededBy: String

    var isStructurallyValid: Bool {
        UUID(uuidString: receiptID) != nil
            && UUID(uuidString: supersededBy) != nil
            && Self.isLowercaseSHA256(expectedReceiptHash)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }
}

enum V011SessionTxnReservationState: String, Codable, Sendable {
    case reserved
    case committed
}

struct V011SessionTxnReservation: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let sessionTxnID: String
    let configTxnID: String
    let targetProvider: String
    let targetProfileID: String?
    let targetConfigHash: String
    let expectedSourceHash: String
    let historyPolicy: V011HistoryPolicy
    let createdAt: Date
    var updatedAt: Date
    var state: V011SessionTxnReservationState
    var expectedReservationHash: String?
    var latestReceiptHash: String?
    var pendingReceiptHash: String?
    var pendingReceiptPreviousHash: String?

    init(
        configTxnID: String,
        targetProvider: String,
        targetProfileID: String?,
        targetConfigHash: String,
        expectedSourceHash: String,
        historyPolicy: V011HistoryPolicy,
        createdAt: Date
    ) {
        let sessionTxnID = Self.sessionTransactionID(
            forConfigTransactionID: configTxnID
        )
        schemaVersion = Self.currentSchemaVersion
        id = sessionTxnID
        self.sessionTxnID = sessionTxnID
        self.configTxnID = configTxnID
        self.targetProvider = targetProvider
        self.targetProfileID = targetProfileID
        self.targetConfigHash = targetConfigHash
        self.expectedSourceHash = expectedSourceHash
        self.historyPolicy = historyPolicy
        self.createdAt = createdAt
        updatedAt = createdAt
        state = .reserved
        expectedReservationHash = nil
        latestReceiptHash = nil
        pendingReceiptHash = nil
        pendingReceiptPreviousHash = nil
    }

    static func sessionTransactionID(
        forConfigTransactionID configTransactionID: String
    ) -> String {
        let domain = Data(
            "ai-access-assistant.build63.session-txn\u{0}\(configTransactionID.lowercased())"
                .utf8
        )
        var bytes = Array(SHA256.hash(data: domain).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && id == sessionTxnID
            && UUID(uuidString: sessionTxnID) != nil
            && UUID(uuidString: configTxnID) != nil
            && !targetProvider.isEmpty
            && Self.isLowercaseSHA256(targetConfigHash)
            && Self.isLowercaseSHA256(expectedSourceHash)
            && historyPolicy != .configOnly
            && expectedReservationHash.map(Self.isLowercaseSHA256) != false
            && latestReceiptHash.map(Self.isLowercaseSHA256) != false
            && pendingReceiptHash.map(Self.isLowercaseSHA256) != false
            && pendingReceiptPreviousHash.map(Self.isLowercaseSHA256) != false
            && (pendingReceiptHash == nil)
                == (pendingReceiptPreviousHash == nil)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }
}

struct V011SwitchJournal: Identifiable, Codable, Equatable {
    let version: Int
    let id: String
    let codexHomePath: String
    let sourceConfigHash: String
    let sourceConfigExisted: Bool
    let targetConfigHash: String
    let targetProvider: String
    let targetProfileID: String?
    let configSnapshot: SnapshotManifest
    let stateExisted: Bool
    let originLedgerExisted: Bool
    let startedAt: Date
    var updatedAt: Date
    var phase: V011SwitchPhase
    var sessionJournalPath: String?
    var message: String
    var failureStage: V011RecoveryFailureStage? = nil
    var nextAction: String? = nil
    var protectsPostSwitchSessions: Bool? = nil
    var acceptedCurrent: V011AcceptedCurrentRecord? = nil
    var stateCASManaged: Bool? = nil
    var sourceManagedStateHash: String? = nil
    var targetManagedStateHash: String? = nil
    var forwardManagedStateHash: String? = nil
    var targetOriginLedgerHash: String? = nil
    var stateEvidenceVersion: Int? = nil
    var stateEvidenceMAC: String? = nil
    var configTransactionID: String? = nil
    var configTransactionPhase: V011ConfigTransactionPhase? = nil
    var historyPolicy: V011HistoryPolicy? = nil
    var reservationID: String? = nil
    var reservationHash: String? = nil
    var supersedeIntents: [V011SessionSupersedeIntent]? = nil
}

struct V011SessionTransactionReceipt: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let configTransactionID: String
    let configHash: String
    let targetProvider: String
    let targetProfileID: String?
    let historyPolicy: V011HistoryPolicy
    var phase: V011SessionTransactionPhase
    var attempt: Int
    let createdAt: Date
    var updatedAt: Date
    var failureCode: V011SessionFailureCode?
    var failureStage: String?
    var nextAction: String?
    var supersededBy: String?
    var expectedReceiptHash: String?
    var estimatedJournalBytes: UInt64?
    var actualJournalBytes: UInt64?
    var journalLimitBytes: UInt64?
    var rolloutFileCount: Int?
    var patchCount: Int?
    var estimateVersion: Int?
    var recoveryID: String?

    var rolloutCount: Int? {
        get { rolloutFileCount }
        set { rolloutFileCount = newValue }
    }

    init(
        id: String,
        configTransactionID: String,
        configHash: String,
        targetProvider: String,
        targetProfileID: String? = nil,
        historyPolicy: V011HistoryPolicy,
        phase: V011SessionTransactionPhase,
        attempt: Int,
        createdAt: Date,
        updatedAt: Date,
        failureCode: V011SessionFailureCode? = nil,
        failureStage: String? = nil,
        nextAction: String? = nil,
        supersededBy: String? = nil,
        expectedReceiptHash: String? = nil,
        estimatedJournalBytes: UInt64? = nil,
        actualJournalBytes: UInt64? = nil,
        journalLimitBytes: UInt64? = nil,
        rolloutFileCount: Int? = nil,
        patchCount: Int? = nil,
        estimateVersion: Int? = nil,
        recoveryID: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.configTransactionID = configTransactionID
        self.configHash = configHash
        self.targetProvider = targetProvider
        self.targetProfileID = targetProfileID
        self.historyPolicy = historyPolicy
        self.phase = phase
        self.attempt = attempt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.failureCode = failureCode
        self.failureStage = failureStage
        self.nextAction = nextAction
        self.supersededBy = supersededBy
        self.expectedReceiptHash = expectedReceiptHash
        self.estimatedJournalBytes = estimatedJournalBytes
        self.actualJournalBytes = actualJournalBytes
        self.journalLimitBytes = journalLimitBytes
        self.rolloutFileCount = rolloutFileCount
        self.patchCount = patchCount
        self.estimateVersion = estimateVersion
        self.recoveryID = recoveryID
    }

    var isOpen: Bool {
        [.notStarted, .prepared, .running, .retryableFailure]
            .contains(phase)
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && UUID(uuidString: id) != nil
            && UUID(uuidString: configTransactionID) != nil
            && configHash.count == 64
            && configHash.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && !targetProvider.isEmpty
            && attempt >= 0
            && supersededBy.map { UUID(uuidString: $0) != nil } != false
            && expectedReceiptHash.map(Self.isLowercaseSHA256) != false
            && rolloutFileCount.map { $0 >= 0 } != false
            && patchCount.map { $0 >= 0 } != false
            && estimateVersion.map { $0 > 0 } != false
            && (recoveryID == nil || recoveryID == id.lowercased())
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, configTransactionID, configHash
        case targetProvider, targetProfileID, historyPolicy, phase
        case attempt, createdAt, updatedAt, failureCode, failureStage
        case nextAction, supersededBy, expectedReceiptHash
        case estimatedJournalBytes, actualJournalBytes, journalLimitBytes
        case rolloutFileCount, rolloutCount, patchCount, estimateVersion
        case recoveryID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        configTransactionID = try container.decode(
            String.self,
            forKey: .configTransactionID
        )
        configHash = try container.decode(String.self, forKey: .configHash)
        targetProvider = try container.decode(
            String.self,
            forKey: .targetProvider
        )
        targetProfileID = try container.decodeIfPresent(
            String.self,
            forKey: .targetProfileID
        )
        historyPolicy = try container.decode(
            V011HistoryPolicy.self,
            forKey: .historyPolicy
        )
        phase = try container.decode(
            V011SessionTransactionPhase.self,
            forKey: .phase
        )
        attempt = try container.decode(Int.self, forKey: .attempt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        failureCode = try container.decodeIfPresent(
            V011SessionFailureCode.self,
            forKey: .failureCode
        )
        failureStage = try container.decodeIfPresent(
            String.self,
            forKey: .failureStage
        )
        nextAction = try container.decodeIfPresent(
            String.self,
            forKey: .nextAction
        )
        supersededBy = try container.decodeIfPresent(
            String.self,
            forKey: .supersededBy
        )
        expectedReceiptHash = try container.decodeIfPresent(
            String.self,
            forKey: .expectedReceiptHash
        )
        estimatedJournalBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .estimatedJournalBytes
        )
        actualJournalBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .actualJournalBytes
        )
        journalLimitBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .journalLimitBytes
        )
        if let currentCount = try container.decodeIfPresent(
            Int.self,
            forKey: .rolloutFileCount
        ) {
            rolloutFileCount = currentCount
        } else {
            rolloutFileCount = try container.decodeIfPresent(
                Int.self,
                forKey: .rolloutCount
            )
        }
        patchCount = try container.decodeIfPresent(
            Int.self,
            forKey: .patchCount
        )
        estimateVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .estimateVersion
        )
        recoveryID = try container.decodeIfPresent(
            String.self,
            forKey: .recoveryID
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(configTransactionID, forKey: .configTransactionID)
        try container.encode(configHash, forKey: .configHash)
        try container.encode(targetProvider, forKey: .targetProvider)
        try container.encodeIfPresent(targetProfileID, forKey: .targetProfileID)
        try container.encode(historyPolicy, forKey: .historyPolicy)
        try container.encode(phase, forKey: .phase)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(failureCode, forKey: .failureCode)
        try container.encodeIfPresent(failureStage, forKey: .failureStage)
        try container.encodeIfPresent(nextAction, forKey: .nextAction)
        try container.encodeIfPresent(supersededBy, forKey: .supersededBy)
        try container.encodeIfPresent(
            expectedReceiptHash,
            forKey: .expectedReceiptHash
        )
        try container.encodeIfPresent(
            estimatedJournalBytes,
            forKey: .estimatedJournalBytes
        )
        try container.encodeIfPresent(
            actualJournalBytes,
            forKey: .actualJournalBytes
        )
        try container.encodeIfPresent(
            journalLimitBytes,
            forKey: .journalLimitBytes
        )
        try container.encodeIfPresent(
            rolloutFileCount,
            forKey: .rolloutFileCount
        )
        try container.encodeIfPresent(patchCount, forKey: .patchCount)
        try container.encodeIfPresent(estimateVersion, forKey: .estimateVersion)
        try container.encodeIfPresent(recoveryID, forKey: .recoveryID)
    }
}
