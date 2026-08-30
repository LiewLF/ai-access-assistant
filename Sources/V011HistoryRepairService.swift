// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011HistoryRepairEvent: Sendable {
    case reconciling
    case capturingOrigins
    case progress(current: Int, total: Int)
    case relaunching
}

struct V011HistoryRepairFailure: Sendable {
    let primaryMessage: String
    let recoveryMessage: String?
}

enum V011HistoryRepairOutcome: Sendable {
    case success(SessionCoreRepairSummary)
    case failure(V011HistoryRepairFailure)
}

/// Owns one normal repair transaction from prepared pointer through origin
/// capture, SessionCore repair, journal validation, commit/no-change cleanup,
/// relaunch, and failure compensation.
struct V011HistoryRepairService: Sendable {
    let dependencies: V011HistoryDependencies
    let recoveryRoot: URL
    let ledgerRoot: URL

    func execute(
        provider: String,
        event: @escaping @MainActor @Sendable (
            V011HistoryRepairEvent
        ) -> Void
    ) async -> V011HistoryRepairOutcome {
        let pointerURL = recoveryRoot.appendingPathComponent(
            "last-repair.json"
        )
        let transactionID = UUID().uuidString.lowercased()
        let expectedJournal = recoveryRoot
            .appendingPathComponent(
                transactionID,
                isDirectory: true
            )
            .standardizedFileURL
        let preparedPointer = V011HistoryRecoveryPointer(
            version: 1,
            transactionID: transactionID,
            journalPath: expectedJournal.path,
            phase: .prepared,
            kind: .repair
        )
        var journalKey: Data?
        var pointerPrepared = false

        do {
            try await Task.detached {
                try dependencies.stopConfigurationWriters()
                try V011HistoryRecoveryStore
                    .prepareRecoveryRoot(recoveryRoot)
            }.value
            await event(.reconciling)
            let key = try await Task.detached {
                try dependencies.keyProvider()
            }.value
            journalKey = key
            await event(.capturingOrigins)
            try await V011HistorySessionOriginService(
                dependencies: dependencies,
                ledgerRoot: ledgerRoot
            ).captureBeforeRepair()
            await event(.reconciling)
            try await Task.detached {
                try V011HistoryRecoveryStore
                    .saveRecoveryJournalPointer(
                    preparedPointer,
                    at: pointerURL,
                    recoveryRoot: recoveryRoot
                )
            }.value
            pointerPrepared = true
            let summary = try await dependencies.sessionCore.repair(
                codexHome: dependencies.codexHome,
                provider: provider,
                recoveryRoot: recoveryRoot,
                transactionID: transactionID,
                journalKey: key,
                progress: { progress in
                    Task { @MainActor in
                        event(
                            .progress(
                                current: progress.current,
                                total: progress.total
                            )
                        )
                    }
                }
            )
            let pending = try await dependencies.sessionCore
                .interruptedJournal(
                    codexHome: dependencies.codexHome,
                    recoveryRoot: recoveryRoot
                )
            guard pending == nil else {
                throw SessionCoreClientError.invalidJournal
            }
            if summary.noChanges {
                guard summary.transactionID == nil,
                      summary.journalPath == nil,
                      try V011HistoryRecoveryStore
                        .recoveryJournalState(
                        expectedJournal,
                        recoveryRoot: recoveryRoot,
                        transactionID: transactionID
                      ) == .absent else {
                    throw SessionCoreClientError.invalidJournal
                }
                try await Task.detached {
                    let pointerHash = try V011HistoryRecoveryStore
                        .pointerContentHash(at: pointerURL)
                    try V011HistoryRecoveryStore
                        .archiveRecoveryPointer(
                        at: pointerURL,
                        expectedTransactionID: transactionID,
                        expectedHash: pointerHash
                    )
                }.value
                pointerPrepared = false
            } else {
                guard summary.transactionID == transactionID,
                      let returnedPath = summary.journalPath,
                      URL(fileURLWithPath: returnedPath)
                        .standardizedFileURL.path
                        == expectedJournal.path,
                      try V011HistoryRecoveryStore
                        .recoveryJournalState(
                        expectedJournal,
                        recoveryRoot: recoveryRoot,
                        transactionID: transactionID
                      ) == .materialized else {
                    throw SessionCoreClientError.invalidJournal
                }
                let committedPointer = V011HistoryRecoveryPointer(
                    version: 1,
                    transactionID: transactionID,
                    journalPath: expectedJournal.path,
                    phase: .committed,
                    kind: .repair
                )
                try await Task.detached {
                    try V011HistoryRecoveryStore
                        .saveRecoveryJournalPointer(
                        committedPointer,
                        at: pointerURL,
                        recoveryRoot: recoveryRoot
                    )
                }.value
                pointerPrepared = false
            }
            await event(.relaunching)
            try await Task.detached {
                try dependencies.relaunchCodex()
            }.value
            return .success(summary)
        } catch {
            let primaryMessage = error.localizedDescription
            var recoveryMessage: String?
            if pointerPrepared,
               let journalKey {
                do {
                    let expectedPointerHash =
                        try await Task.detached {
                            try V011HistoryRecoveryStore
                                .pointerContentHash(
                                at: pointerURL
                            )
                        }.value
                    try await V011HistoryRepairRecoveryService
                        .recoverPreparedRepair(
                        dependencies: dependencies,
                        recoveryRoot: recoveryRoot,
                        pointer: preparedPointer,
                        journalKey: journalKey
                    )
                    try await Task.detached {
                        try V011HistoryRecoveryStore
                            .archiveRecoveryPointer(
                            at: pointerURL,
                            expectedTransactionID:
                                preparedPointer.transactionID,
                            expectedHash: expectedPointerHash
                        )
                    }.value
                } catch {
                    recoveryMessage = error.localizedDescription
                }
            }
            do {
                try await Task.detached {
                    try dependencies.relaunchCodex()
                }.value
            } catch {
                if recoveryMessage == nil {
                    recoveryMessage = error.localizedDescription
                }
            }
            return .failure(
                V011HistoryRepairFailure(
                    primaryMessage: primaryMessage,
                    recoveryMessage: recoveryMessage
                )
            )
        }
    }
}
