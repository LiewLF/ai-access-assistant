// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Build 65 recovery contract: one immutable snapshot drives every visible
/// recovery state. Counts, pointer state, journal state, operation state,
/// warning visibility, next action and failure code all come from the same
/// generation; the UI never combines async flags to infer "unfinished".
///
/// This file is read-model and action-contract only. Durable writes continue
/// to go through the existing pointer/journal files and the SessionCore
/// coordinator (rollback / clear-stale-lock); restore archiving is CAS on the
/// exact pointer.

enum Build65RecoveryPointerState: String, Codable, CaseIterable, Sendable {
    case absent
    case prepared
    case committed
    case invalid
}

enum Build65RecoveryJournalState: String, Codable, CaseIterable, Sendable {
    case absent
    case prewrite
    case materialized
    /// Journal directory exists but the manifest never materialized and no
    /// SessionCore lock proves an active transaction. This is a prewrite
    /// leftover from a crash before commit: nothing to roll back.
    case staleEmpty
    case corrupt
}

enum Build65RecoveryOperationState: String, Codable, CaseIterable, Sendable {
    case idle
    case running
    case recoverable
    case completed
    case failed
    case safeMode
}

enum Build65WarningVisibility: String, Codable, CaseIterable, Sendable {
    case hidden
    case informational
    case actionable
    case blocking
}

enum Build65RecoveryNextAction: String, Codable, CaseIterable, Sendable {
    case none
    case restore
    case clearStaleLock
    case archiveStaleRecord
    case exportDiagnostic
    case keepCurrent
    case retryLater
}

enum Build65HistoryRecoveryFailureCode:
    String, Codable, CaseIterable, Sendable {
    case pointerUnreadable = "pointer_unreadable"
    case journalMismatch = "journal_mismatch"
    case journalCorrupt = "journal_corrupt"
    case restoreFailed = "restore_failed"
    case sessionCoreUnavailable = "session_core_unavailable"
}

extension V011HistoryRecoverySnapshot {
    func overridingFailure(
        _ code: Build65HistoryRecoveryFailureCode,
        stage: String
    ) -> V011HistoryRecoverySnapshot {
        V011HistoryRecoverySnapshot(
            generation: generation,
            observedAt: observedAt,
            totalCount: totalCount,
            visibleCount: visibleCount,
            pointerState: pointerState,
            journalState: journalState,
            operationState: .safeMode,
            warningVisibility: .blocking,
            nextAction: .exportDiagnostic,
            failureCode: code.rawValue,
            failureStage: stage,
            attempt: attempt,
            transactionID: transactionID,
            pointerHash: pointerHash,
            journalHash: journalHash,
            lastSuccessfulOperationID:
                lastSuccessfulOperationID,
            operationKey: operationKey,
            progressCurrent: progressCurrent,
            progressTotal: progressTotal
        )
    }

    /// Derived copy for the restore-failure override: a single restore
    /// failure is a retryable `.failed`; a second consecutive failure enters
    /// one-shot read-only safe mode.
    func overridingRestoreFailure(
        safeMode: Bool,
        attempt: Int
    ) -> V011HistoryRecoverySnapshot {
        V011HistoryRecoverySnapshot(
            generation: generation,
            observedAt: observedAt,
            totalCount: totalCount,
            visibleCount: visibleCount,
            pointerState: pointerState,
            journalState: journalState,
            operationState: safeMode ? .safeMode : .failed,
            warningVisibility: .blocking,
            nextAction: safeMode
                ? .keepCurrent : .retryLater,
            failureCode:
                Build65HistoryRecoveryFailureCode
                    .restoreFailed.rawValue,
            failureStage: "restore",
            attempt: attempt,
            transactionID: transactionID,
            pointerHash: pointerHash,
            journalHash: journalHash,
            lastSuccessfulOperationID:
                lastSuccessfulOperationID,
            operationKey: operationKey
        )
    }
}

struct V011HistoryRecoverySnapshot: Codable, Equatable, Sendable {
    let generation: Int
    let observedAt: Date
    let totalCount: Int
    let visibleCount: Int
    let pendingCount: Int
    let indexVersion: Int
    let pointerState: Build65RecoveryPointerState
    let journalState: Build65RecoveryJournalState
    let operationState: Build65RecoveryOperationState
    let warningVisibility: Build65WarningVisibility
    let nextAction: Build65RecoveryNextAction?
    let failureCode: String?
    let failureStage: String?
    let attempt: Int
    let transactionID: String?
    let pointerHash: String?
    let journalHash: String?
    let lastSuccessfulOperationID: String?
    let operationKey: String?
    let progressCurrent: Int
    let progressTotal: Int

    init(
        generation: Int,
        observedAt: Date = Date(),
        totalCount: Int,
        visibleCount: Int,
        indexVersion: Int = 1,
        pointerState: Build65RecoveryPointerState,
        journalState: Build65RecoveryJournalState,
        operationState: Build65RecoveryOperationState,
        warningVisibility: Build65WarningVisibility,
        nextAction: Build65RecoveryNextAction?,
        failureCode: String? = nil,
        failureStage: String? = nil,
        attempt: Int = 0,
        transactionID: String? = nil,
        pointerHash: String? = nil,
        journalHash: String? = nil,
        lastSuccessfulOperationID: String? = nil,
        operationKey: String? = nil,
        progressCurrent: Int = 0,
        progressTotal: Int = 0
    ) {
        self.generation = generation
        self.observedAt = observedAt
        self.totalCount = totalCount
        self.visibleCount = visibleCount
        self.pendingCount = max(0, totalCount - visibleCount)
        self.indexVersion = indexVersion
        self.pointerState = pointerState
        self.journalState = journalState
        self.operationState = operationState
        self.warningVisibility = warningVisibility
        self.nextAction = nextAction
        self.failureCode = failureCode
        self.failureStage = failureStage
        self.attempt = attempt
        self.transactionID = transactionID
        self.pointerHash = pointerHash
        self.journalHash = journalHash
        self.lastSuccessfulOperationID = lastSuccessfulOperationID
        self.operationKey = operationKey
        self.progressCurrent = max(0, progressCurrent)
        self.progressTotal = max(0, progressTotal)
    }

    /// Short, copyable problem code: failure code + stage + generation.
    /// Contains no hashes, paths, tokens or session content.
    var problemCode: String {
        let stage = failureStage ?? "unknown"
        return "H65-\(failureCode ?? "ok")-\(stage)-g\(generation)"
    }

    /// All sessions visible (or counts not loaded yet).
    var allVisible: Bool { visibleCount >= totalCount }

    /// Counts are loaded; decisions that depend on counts are only stable
    /// after this is true.
    var countsAvailable: Bool { visibleCount >= 0 && totalCount >= 0 }

    var validationErrors: [String] {
        var errors: [String] = []
        if totalCount < 0 || visibleCount < 0 { errors.append("negative_count") }
        if visibleCount > totalCount && totalCount > 0 { errors.append("visible_exceeds_total") }
        if generation < 1 { errors.append("invalid_generation") }
        return errors
    }
}

/// Pure decision: pointer + journal + counts + operation context -> snapshot.
/// No I/O; unit-testable against every row of the Build 65 matrix.
enum Build65HistoryRecoveryDecision {
    struct Inputs: Equatable, Sendable {
        var pointerState: Build65RecoveryPointerState = .absent
        var journalState: Build65RecoveryJournalState = .absent
        var journalIdentityMatches: Bool = true
        var totalCount: Int = 0
        var visibleCount: Int = 0
        var countsAvailable: Bool = false
        var indexVersion: Int = 1
        var pointerTransactionID: String?
        var pointerHash: String?
        var journalHash: String?
        var generation: Int = 1
        var attempt: Int = 0
        var operationKey: String?
        var lastSuccessfulOperationID: String?
        var failureStage: String?
    }

    static func decide(_ input: Inputs) -> V011HistoryRecoverySnapshot {
        let pointer = input.pointerState
        let journal = input.journalState
        let identity = input.journalIdentityMatches
        let allVisible = input.countsAvailable
            && input.visibleCount >= input.totalCount

        // Corrupt or identity-mismatched records never auto-retry.
        if journal == .corrupt || !identity {
            return snapshot(
                input,
                operation: .safeMode,
                warning: .blocking,
                next: .exportDiagnostic,
                failure: !identity
                    ? .journalMismatch : .journalCorrupt,
                stage: input.failureStage ?? "reconcile"
            )
        }

        switch (pointer, journal) {
        case (.absent, .corrupt),
             (.prepared, .corrupt),
             (.committed, .corrupt),
             (.invalid, _):
            return snapshot(
                input,
                operation: .safeMode,
                warning: .blocking,
                next: .exportDiagnostic,
                failure: .pointerUnreadable,
                stage: input.failureStage ?? "reconcile"
            )

        case (.absent, .staleEmpty):
            // Nothing was ever committed and no pointer references it.
            return snapshot(
                input,
                operation: .idle,
                warning: .hidden,
                next: Build65RecoveryNextAction.none,
                stage: "reconcile"
            )

        case (.prepared, .staleEmpty),
             (.committed, .staleEmpty):
            // Prewrite leftover: the pointer was written, the journal never
            // materialized and no lock exists. Nothing to roll back; the
            // record is stale and safe to archive.
            return snapshot(
                input,
                operation: .completed,
                warning: .informational,
                next: .archiveStaleRecord,
                stage: "reconcile"
            )

        case (.absent, .absent):
            return snapshot(
                input,
                operation: .idle,
                warning: .hidden,
                next: Build65RecoveryNextAction.none
            )

        case (.absent, .prewrite),
             (.absent, .materialized):
            // SessionCore can prove the journal identity; recoverable.
            return snapshot(
                input,
                operation: .recoverable,
                warning: .actionable,
                next: journal == .prewrite
                    ? .clearStaleLock : .restore,
                stage: "reconcile"
            )

        case (.prepared, .absent),
             (.committed, .absent):
            // Nothing to roll back; pointer is a stale completion record.
            return snapshot(
                input,
                operation: .completed,
                warning: .informational,
                next: .archiveStaleRecord,
                stage: "reconcile"
            )

        case (.prepared, .prewrite),
             (.committed, .prewrite):
            return snapshot(
                input,
                operation: .recoverable,
                warning: .actionable,
                next: .clearStaleLock,
                stage: "reconcile"
            )

        case (.prepared, .materialized):
            return snapshot(
                input,
                operation: .recoverable,
                warning: .actionable,
                next: .restore,
                stage: "reconcile"
            )

        case (.committed, .materialized):
            if allVisible {
                // Repair durably completed; journal is a leftover record.
                // Rolling back would undo a finished, visible repair.
                return snapshot(
                    input,
                    operation: .completed,
                    warning: .informational,
                    next: .archiveStaleRecord,
                    stage: "reconcile"
                )
            }
            return snapshot(
                input,
                operation: .recoverable,
                warning: .actionable,
                next: .restore,
                stage: "reconcile"
            )
        }
    }

    static func snapshot(
        _ input: Inputs,
        operation: Build65RecoveryOperationState,
        warning: Build65WarningVisibility,
        next: Build65RecoveryNextAction?,
        failure: Build65HistoryRecoveryFailureCode? = nil,
        stage: String? = nil
    ) -> V011HistoryRecoverySnapshot {
        V011HistoryRecoverySnapshot(
            generation: input.generation,
            totalCount: input.countsAvailable
                ? input.totalCount : 0,
            visibleCount: input.countsAvailable
                ? input.visibleCount : 0,
            indexVersion: input.indexVersion,
            pointerState: input.pointerState,
            journalState: input.journalState,
            operationState: operation,
            warningVisibility: warning,
            nextAction: next,
            failureCode: failure?.rawValue,
            failureStage: stage,
            attempt: input.attempt,
            transactionID: input.pointerTransactionID,
            pointerHash: input.pointerHash,
            journalHash: input.journalHash,
            lastSuccessfulOperationID:
                input.lastSuccessfulOperationID,
            operationKey: input.operationKey
        )
    }
}

/// Redacted, copyable recovery diagnostic. No token, cookie, full path or
/// session content; the evidence hash stays available in advanced detail.
struct Build65RecoveryDiagnosticSummary: Codable, Equatable, Sendable {
    let build: Int
    let problemCode: String
    let operationState: String
    let pointerState: String
    let journalState: String
    let nextAction: String?
    let failureStage: String?
    let attempt: Int
    let totalCount: Int
    let visibleCount: Int

    init(
        build: Int,
        snapshot: V011HistoryRecoverySnapshot
    ) {
        self.build = build
        self.problemCode = snapshot.problemCode
        self.operationState = snapshot.operationState.rawValue
        self.pointerState = snapshot.pointerState.rawValue
        self.journalState = snapshot.journalState.rawValue
        self.nextAction = snapshot.nextAction?.rawValue
        self.failureStage = snapshot.failureStage
        self.attempt = snapshot.attempt
        self.totalCount = snapshot.totalCount
        self.visibleCount = snapshot.visibleCount
    }

    var copyText: String {
        [
            "Build \(build)",
            "问题码 \(problemCode)",
            "状态 \(operationState)",
            "指针 \(pointerState)",
            "恢复记录 \(journalState)",
            "建议 \(nextAction ?? "无")",
        ].joined(separator: " / ")
    }
}

/// Stable accessibility labels for the history recovery controls. The UI
/// must use these exact strings so VoiceOver and automation never drift.
enum Build65RecoveryControlLabel: String, CaseIterable, Sendable {
    case restoreButton = "恢复上次操作"
    case repairButton = "让全部会话在当前模式可见"
    case recheckButton = "重新检查历史会话"
    case cleanupButton = "整理旧记录"
    case runningStatus = "正在核对恢复记录"
    case completedStatus = "上次历史会话操作已完成"
    case safeModeStatus = "恢复记录无法安全核对"
}

/// Stable labels for the catalog resolution dialog.
enum Build65CatalogControlLabel: String, CaseIterable, Sendable {
    case dialogTitle = "处理受管模型目录"
    case recheck = "重新核对目录"
    case copyAsManaged = "复制为受管目录"
    case keepCurrent = "继续使用当前配置"
    case technicalDetail = "查看技术详情"
    case cancel = "取消"
}

/// Operation key: transactionID + pointerHash + journalHash. The same key
/// running twice is a single-flight no-op.
enum Build65RecoveryOperationKey {
    static func make(
        transactionID: String?,
        pointerHash: String?,
        journalHash: String?
    ) -> String {
        let canonical = [
            transactionID ?? "",
            pointerHash ?? "",
            journalHash ?? "",
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
