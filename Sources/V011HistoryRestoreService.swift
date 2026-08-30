// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011HistoryRestoreEvent: Sendable {
    case restoring
    case completedStateObserved(
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?
    )
    case failed(String)
}

enum V011HistoryRestoreOutcome: Sendable {
    case completedWithoutRollback
    case restored
    case failed
}

/// Owns authoritative restore re-read, pointer CAS, journal actionability,
/// SessionCore rollback/clear, pointer archive, and relaunch. UI retry state
/// and recovery snapshot projection stay in HistoryModel.
struct V011HistoryRestoreService: Sendable {
    let dependencies: V011HistoryDependencies
    let recoveryRoot: URL

    func execute(
        expectedPointerHash: String?,
        visibleTotal: Int?,
        total: Int,
        event: @escaping @MainActor @Sendable (
            V011HistoryRestoreEvent
        ) -> Void
    ) async -> V011HistoryRestoreOutcome {
        let pointerURL = recoveryRoot.appendingPathComponent(
            "last-repair.json"
        )
        var relaunched = false
        do {
            let pointer = try await Task.detached {
                try V011HistoryRecoveryStore
                    .readRecoveryJournalPointer(
                    at: pointerURL,
                    recoveryRoot: recoveryRoot
                )
            }.value
            let observedPointerHash: String?
            if pointer != nil {
                observedPointerHash = try await Task.detached {
                    try V011HistoryRecoveryStore
                        .pointerContentHash(at: pointerURL)
                }.value
            } else {
                observedPointerHash = nil
            }
            guard observedPointerHash == expectedPointerHash else {
                throw SessionCoreClientError.recoveryPointerChanged
            }
            let pending = try await dependencies.sessionCore
                .interruptedJournal(
                    codexHome: dependencies.codexHome,
                    recoveryRoot: recoveryRoot
                )
            guard !journalIsCorrupt(
                pointer: pointer,
                pending: pending
            ) else {
                throw SessionCoreClientError.invalidJournal
            }
            guard isActionable(
                pointer: pointer,
                pending: pending,
                visibleTotal: visibleTotal,
                total: total
            ) else {
                await event(
                    .completedStateObserved(
                        pointer: pointer,
                        pending: pending
                    )
                )
                try await archivePointer(
                    pointer,
                    pointerURL: pointerURL,
                    expectedHash: observedPointerHash
                )
                return .completedWithoutRollback
            }

            try await Task.detached {
                try dependencies.stopConfigurationWriters()
            }.value
            await event(.restoring)
            let key = try await Task.detached {
                try dependencies.keyProvider()
            }.value
            try await V011HistoryRepairRecoveryService
                .restoreRepair(
                dependencies: dependencies,
                recoveryRoot: recoveryRoot,
                pointer: pointer,
                pending: pending,
                journalKey: key
            )
            try await Task.detached {
                if let pointer,
                   let observedPointerHash {
                    try V011HistoryRecoveryStore
                        .archiveRecoveryPointer(
                        at: pointerURL,
                        expectedTransactionID:
                            pointer.transactionID,
                        expectedHash: observedPointerHash
                    )
                }
                try dependencies.relaunchCodex()
            }.value
            relaunched = true
            return .restored
        } catch {
            await event(.failed(error.localizedDescription))
            if !relaunched {
                try? await Task.detached {
                    try dependencies.relaunchCodex()
                }.value
                relaunched = true
            }
            return .failed
        }
    }

    private func archivePointer(
        _ pointer: V011HistoryRecoveryPointer?,
        pointerURL: URL,
        expectedHash: String?
    ) async throws {
        guard let pointer else { return }
        guard let expectedHash else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
        try await Task.detached {
            try V011HistoryRecoveryStore.archiveRecoveryPointer(
                at: pointerURL,
                expectedTransactionID: pointer.transactionID,
                expectedHash: expectedHash
            )
        }.value
    }

    private func isActionable(
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?,
        visibleTotal: Int?,
        total: Int
    ) -> Bool {
        if let pending {
            guard !pending.prewrite else { return true }
            if let pointer,
               pending.transactionID.lowercased()
                != pointer.transactionID.lowercased() {
                return false
            }
            guard let path = pending.journalPath,
                  let state = try? V011HistoryRecoveryStore
                    .recoveryJournalState(
                    URL(fileURLWithPath: path),
                    recoveryRoot: recoveryRoot,
                    transactionID: pending.transactionID
                  ),
                  state == .materialized else {
                return false
            }
            if pointer?.kind == .externalImport,
               pointer?.phase == .committed {
                return true
            }
            if pointer?.phase == .committed,
               let visibleTotal,
               visibleTotal >= total {
                return false
            }
            return true
        }
        guard let pointer else { return false }
        guard let state = try? V011HistoryRecoveryStore
            .recoveryJournalState(
            URL(fileURLWithPath: pointer.journalPath),
            recoveryRoot: recoveryRoot,
            transactionID: pointer.transactionID
        ), state == .materialized else {
            return false
        }
        if pointer.kind == .externalImport,
           pointer.phase == .committed {
            return true
        }
        switch pointer.phase {
        case .prepared:
            return true
        case .committed:
            if let visibleTotal,
               visibleTotal >= total {
                return false
            }
            return true
        }
    }

    private func journalIsCorrupt(
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?
    ) -> Bool {
        guard let pending else { return false }
        guard !pending.prewrite else { return false }
        guard let path = pending.journalPath else { return true }
        guard let state = try? V011HistoryRecoveryStore
            .recoveryJournalState(
            URL(fileURLWithPath: path),
            recoveryRoot: recoveryRoot,
            transactionID: pending.transactionID
        ) else {
            return true
        }
        if let pointer,
           URL(fileURLWithPath: pending.journalPath ?? "")
            .standardizedFileURL.path
            != URL(fileURLWithPath: pointer.journalPath)
                .standardizedFileURL.path {
            return true
        }
        return state != .materialized
    }
}
