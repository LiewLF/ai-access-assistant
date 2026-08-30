// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011HistoryRepairRecoveryService {
    static func recoverPreparedRepair(
        dependencies: V011HistoryDependencies,
        recoveryRoot: URL,
        pointer: V011HistoryRecoveryPointer,
        journalKey: Data
    ) async throws {
        let pending = try await dependencies.sessionCore
            .interruptedJournal(
                codexHome: dependencies.codexHome,
                recoveryRoot: recoveryRoot
            )
        try await restoreRepair(
            dependencies: dependencies,
            recoveryRoot: recoveryRoot,
            pointer: pointer,
            pending: pending,
            journalKey: journalKey
        )
    }

    static func restoreRepair(
        dependencies: V011HistoryDependencies,
        recoveryRoot: URL,
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?,
        journalKey: Data
    ) async throws {
        guard pointer != nil || pending != nil else {
            throw SessionCoreClientError.invalidJournal
        }

        let transactionID: String
        let journal: URL
        if let pointer {
            transactionID = try V011HistoryRecoveryStore
                .validatedTransactionID(pointer.transactionID)
            journal = try V011HistoryRecoveryStore
                .validatedRecoveryJournal(
                    URL(fileURLWithPath: pointer.journalPath),
                    recoveryRoot: recoveryRoot,
                    transactionID: transactionID
                )
        } else if let pending {
            transactionID = try V011HistoryRecoveryStore
                .validatedTransactionID(pending.transactionID)
            journal = recoveryRoot.appendingPathComponent(
                transactionID,
                isDirectory: true
            ).standardizedFileURL
        } else {
            throw SessionCoreClientError.invalidJournal
        }

        if let pending {
            guard try V011HistoryRecoveryStore
                .validatedTransactionID(pending.transactionID)
                == transactionID else {
                throw SessionCoreClientError.invalidJournal
            }
            if pending.prewrite {
                guard pending.journalPath == nil,
                      try V011HistoryRecoveryStore
                        .recoveryJournalState(
                            journal,
                            recoveryRoot: recoveryRoot,
                            transactionID: transactionID
                        ) == .absent else {
                    throw SessionCoreClientError.invalidJournal
                }
                let cleared = try await dependencies.sessionCore
                    .clearStalePrewriteLock(
                        codexHome: dependencies.codexHome,
                        recoveryRoot: recoveryRoot,
                        transactionID: transactionID
                    )
                guard cleared.transactionID == transactionID,
                      cleared.cleared else {
                    throw SessionCoreClientError.invalidJournal
                }
                return
            }

            guard let pendingPath = pending.journalPath,
                  try V011HistoryRecoveryStore
                    .validatedRecoveryJournal(
                        URL(fileURLWithPath: pendingPath),
                        recoveryRoot: recoveryRoot,
                        transactionID: transactionID
                    ).path == journal.path,
                  try V011HistoryRecoveryStore
                    .recoveryJournalState(
                        journal,
                        recoveryRoot: recoveryRoot,
                        transactionID: transactionID
                    ) == .materialized else {
                throw SessionCoreClientError.invalidJournal
            }
            try await rollbackRepair(
                dependencies: dependencies,
                recoveryRoot: recoveryRoot,
                journal: journal,
                transactionID: transactionID,
                journalKey: journalKey
            )
            return
        }

        switch try V011HistoryRecoveryStore.recoveryJournalState(
            journal,
            recoveryRoot: recoveryRoot,
            transactionID: transactionID
        ) {
        case .materialized:
            try await rollbackRepair(
                dependencies: dependencies,
                recoveryRoot: recoveryRoot,
                journal: journal,
                transactionID: transactionID,
                journalKey: journalKey
            )
        case .absent, .staleEmpty:
            guard pointer?.phase == .prepared else {
                throw SessionCoreClientError.invalidJournal
            }
        }
    }

    private static func rollbackRepair(
        dependencies: V011HistoryDependencies,
        recoveryRoot: URL,
        journal: URL,
        transactionID: String,
        journalKey: Data
    ) async throws {
        let summary = try await dependencies.sessionCore.rollback(
            codexHome: dependencies.codexHome,
            recoveryRoot: recoveryRoot,
            journal: journal,
            journalKey: journalKey
        )
        guard summary.transactionID == transactionID,
              URL(fileURLWithPath: summary.journalPath)
                .standardizedFileURL.path == journal.path else {
            throw SessionCoreClientError.invalidJournal
        }
    }
}
