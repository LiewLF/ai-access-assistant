// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011ExternalSessionImportEvent: Sendable {
    case importing
    case progress(current: Int, total: Int)
    case relaunching
}

struct V011ExternalSessionImportFailure: Sendable {
    let primaryMessage: String
    let recoveryMessage: String?
}

enum V011ExternalSessionImportOutcome: Sendable {
    case success(SessionCoreImportSummary)
    case failure(V011ExternalSessionImportFailure)
}

/// Owns one external-session import transaction from prepared pointer through
/// materialized-journal validation, committed pointer, relaunch, and failure
/// recovery. UI state remains outside this service.
struct V011ExternalSessionImportService: Sendable {
    let dependencies: V011HistoryDependencies

    func execute(
        sourceRoot: URL,
        normalizedSource: URL,
        expectedSessionCount: Int,
        event: @escaping @MainActor @Sendable (
            V011ExternalSessionImportEvent
        ) -> Void
    ) async -> V011ExternalSessionImportOutcome {
        let recoveryRoot = dependencies.controlRoot
            .appendingPathComponent(
                "SessionCoreRecovery",
                isDirectory: true
            )
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
            kind: .externalImport
        )
        let accessed = sourceRoot
            .startAccessingSecurityScopedResource()
        var journalKey: Data?
        var pointerPrepared = false
        defer {
            if accessed {
                sourceRoot.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await Task.detached {
                try dependencies.stopConfigurationWriters()
                try V011HistoryRecoveryStore
                    .prepareRecoveryRoot(recoveryRoot)
            }.value
            let key = try await Task.detached {
                try dependencies.keyProvider()
            }.value
            journalKey = key
            try await Task.detached {
                try V011HistoryRecoveryStore
                    .saveRecoveryJournalPointer(
                    preparedPointer,
                    at: pointerURL,
                    recoveryRoot: recoveryRoot
                )
            }.value
            pointerPrepared = true
            await event(.importing)
            let summary = try await dependencies
                .sessionCore.importSessions(
                    codexHome: dependencies.codexHome,
                    sourceRoot: normalizedSource,
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
            let pending = try await dependencies
                .sessionCore.interruptedJournal(
                    codexHome: dependencies.codexHome,
                    recoveryRoot: recoveryRoot
                )
            guard pending == nil,
                  summary.transactionID == transactionID,
                  URL(fileURLWithPath: summary.journalPath)
                    .standardizedFileURL.path
                    == expectedJournal.path,
                  summary.importedSessions
                    == expectedSessionCount,
                  summary.importedRolloutFiles
                    == expectedSessionCount,
                  summary.conflictPolicy
                    == "reject_existing_thread_id",
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
                kind: .externalImport
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
                V011ExternalSessionImportFailure(
                    primaryMessage: primaryMessage,
                    recoveryMessage: recoveryMessage
                )
            )
        }
    }
}
