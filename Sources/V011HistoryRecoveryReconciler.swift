// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011HistoryJournalReconciliation {
    let pending: SessionCorePendingJournal?
    let identityMismatch: Bool
    let corruptOnDisk: Bool
    let state: Build65RecoveryJournalState
    let url: URL?
    let hash: String?
}

struct V011HistoryRecoveryProjectionInput {
    let currentGeneration: Int
    let totalCount: Int
    let visibleCount: Int?
    let indexVersion: Int
    let pointerRecord: V011HistoryRecoveryPointer?
    let pointerReadFailed: Bool
    let pending: SessionCorePendingJournal?
    let journalIdentityMismatch: Bool
    let journalCorruptOnDisk: Bool
    let journalState: Build65RecoveryJournalState
    let journalHash: String?
    let restoreAttempt: Int
    let consecutiveRestoreFailures: Int
    let restoreFailedOnce: Bool
    let lastSuccessfulOperationID: String?
    let observationFailure: Build65HistoryRecoveryFailureCode?
}

struct V011HistoryRecoveryProjection {
    let generation: Int
    let pointerHash: String?
    let snapshot: V011HistoryRecoverySnapshot
    let hasInterruptedOperation: Bool
    let hasLastRecoveryPoint: Bool
}

enum V011HistoryRecoveryReconciler {
    static func reconcileJournal(
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?,
        recoveryRoot: URL,
        currentJournalURL: URL?
    ) -> V011HistoryJournalReconciliation {
        var identityMismatch = false
        var corruptOnDisk = false
        var state = Build65RecoveryJournalState.absent
        var journalURL = currentJournalURL
        var journalHash: String?

        if let pending {
            if let pointer,
               pending.transactionID.lowercased()
                != pointer.transactionID.lowercased() {
                identityMismatch = true
                state = .corrupt
                return V011HistoryJournalReconciliation(
                    pending: pending,
                    identityMismatch: identityMismatch,
                    corruptOnDisk: corruptOnDisk,
                    state: state,
                    url: journalURL,
                    hash: nil
                )
            }
            if pending.prewrite {
                if pending.journalPath != nil {
                    corruptOnDisk = true
                    state = .corrupt
                } else {
                    state = .prewrite
                }
                return V011HistoryJournalReconciliation(
                    pending: pending,
                    identityMismatch: identityMismatch,
                    corruptOnDisk: corruptOnDisk,
                    state: state,
                    url: journalURL,
                    hash: nil
                )
            }
            guard let path = pending.journalPath else {
                corruptOnDisk = true
                state = .corrupt
                return V011HistoryJournalReconciliation(
                    pending: pending,
                    identityMismatch: identityMismatch,
                    corruptOnDisk: corruptOnDisk,
                    state: state,
                    url: journalURL,
                    hash: nil
                )
            }
            let journal = URL(fileURLWithPath: path)
                .standardizedFileURL
            if let pointer,
               journal.path
                != URL(fileURLWithPath: pointer.journalPath)
                    .standardizedFileURL.path {
                identityMismatch = true
                state = .corrupt
                return V011HistoryJournalReconciliation(
                    pending: pending,
                    identityMismatch: identityMismatch,
                    corruptOnDisk: corruptOnDisk,
                    state: state,
                    url: journalURL,
                    hash: nil
                )
            }
            let observedState = try? V011HistoryRecoveryStore
                .recoveryJournalState(
                    journal,
                    recoveryRoot: recoveryRoot,
                    transactionID: pending.transactionID
                )
            if observedState == .some(.materialized) {
                state = .materialized
                journalURL = journal
                journalHash = V011HistoryRecoveryStore
                    .journalContentHash(
                        journal,
                        recoveryRoot: recoveryRoot,
                        transactionID: pending.transactionID
                    )
            } else {
                corruptOnDisk = true
                state = .corrupt
                journalURL = nil
            }
            return V011HistoryJournalReconciliation(
                pending: pending,
                identityMismatch: identityMismatch,
                corruptOnDisk: corruptOnDisk,
                state: state,
                url: journalURL,
                hash: journalHash
            )
        }

        if let pointer {
            let journal = URL(
                fileURLWithPath: pointer.journalPath
            ).standardizedFileURL
            let observedState = try? V011HistoryRecoveryStore
                .recoveryJournalState(
                    journal,
                    recoveryRoot: recoveryRoot,
                    transactionID: pointer.transactionID
                )
            switch observedState {
            case .some(.materialized):
                state = .materialized
                journalURL = journal
                journalHash = V011HistoryRecoveryStore
                    .journalContentHash(
                        journal,
                        recoveryRoot: recoveryRoot,
                        transactionID: pointer.transactionID
                    )
            case .some(.staleEmpty):
                state = .staleEmpty
                journalURL = journal
            case .some(.absent):
                state = .absent
                journalURL = nil
            case .none:
                corruptOnDisk = true
                state = .corrupt
                journalURL = journal
            }
        } else {
            journalURL = nil
        }
        return V011HistoryJournalReconciliation(
            pending: nil,
            identityMismatch: identityMismatch,
            corruptOnDisk: corruptOnDisk,
            state: state,
            url: journalURL,
            hash: journalHash
        )
    }

    static func project(
        _ input: V011HistoryRecoveryProjectionInput,
        pointerURL: URL
    ) -> V011HistoryRecoveryProjection {
        let generation = input.currentGeneration + 1
        let pointerState: Build65RecoveryPointerState
        if input.pointerReadFailed {
            pointerState = .invalid
        } else {
            switch input.pointerRecord?.phase {
            case .none:
                pointerState = .absent
            case .some(.prepared):
                pointerState = .prepared
            case .some(.committed):
                pointerState = .committed
            }
        }
        let journalState: Build65RecoveryJournalState
        if input.journalCorruptOnDisk
            || input.journalIdentityMismatch {
            journalState = .corrupt
        } else {
            journalState = input.journalState
        }
        let pointerHash = input.pointerRecord == nil
            ? nil
            : try? V011HistoryRecoveryStore
                .pointerContentHash(at: pointerURL)
        let operationKey = Build65RecoveryOperationKey.make(
            transactionID: input.pointerRecord?.transactionID
                ?? input.pending?.transactionID,
            pointerHash: pointerHash,
            journalHash: input.journalHash
        )
        var decisionInput = Build65HistoryRecoveryDecision.Inputs()
        decisionInput.pointerState = pointerState
        decisionInput.journalState = journalState
        decisionInput.journalIdentityMatches =
            !input.journalIdentityMismatch
        decisionInput.totalCount = input.totalCount
        decisionInput.visibleCount = input.visibleCount ?? 0
        decisionInput.countsAvailable = input.visibleCount != nil
        decisionInput.pointerTransactionID =
            input.pointerRecord?.transactionID
        decisionInput.pointerHash = pointerHash
        decisionInput.journalHash = input.journalHash
        decisionInput.generation = generation
        decisionInput.attempt = input.restoreAttempt
        decisionInput.operationKey = operationKey
        decisionInput.lastSuccessfulOperationID =
            input.lastSuccessfulOperationID
        decisionInput.indexVersion = input.indexVersion
        var snapshot = Build65HistoryRecoveryDecision
            .decide(decisionInput)
        if input.pointerRecord?.kind == .externalImport,
           input.pointerRecord?.phase == .committed,
           pointerState == .committed,
           journalState == .materialized {
            snapshot = V011HistoryRecoverySnapshot(
                generation: snapshot.generation,
                observedAt: snapshot.observedAt,
                totalCount: snapshot.totalCount,
                visibleCount: snapshot.visibleCount,
                indexVersion: snapshot.indexVersion,
                pointerState: snapshot.pointerState,
                journalState: snapshot.journalState,
                operationState: .recoverable,
                warningVisibility: .actionable,
                nextAction: .restore,
                transactionID: snapshot.transactionID,
                pointerHash: snapshot.pointerHash,
                journalHash: snapshot.journalHash,
                lastSuccessfulOperationID:
                    snapshot.lastSuccessfulOperationID,
                operationKey: snapshot.operationKey
            )
        }
        if input.restoreFailedOnce {
            snapshot = snapshot.overridingRestoreFailure(
                safeMode: input.consecutiveRestoreFailures >= 2,
                attempt: input.restoreAttempt
            )
        }
        if let failure = input.observationFailure {
            snapshot = snapshot.overridingFailure(
                failure,
                stage: "observation"
            )
        }
        let interrupted = snapshot.operationState == .recoverable
            || snapshot.operationState == .failed
            || snapshot.operationState == .safeMode
        let hasRecoveryPoint = interrupted
            || snapshot.operationState == .completed
        return V011HistoryRecoveryProjection(
            generation: generation,
            pointerHash: pointerHash,
            snapshot: snapshot,
            hasInterruptedOperation: interrupted,
            hasLastRecoveryPoint: hasRecoveryPoint
        )
    }
}
