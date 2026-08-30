// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011HistoryRecoveryCleanupRequest: Sendable {
    let pointerURL: URL
    let pointer: V011HistoryRecoveryPointer
    let expectedPointerHash: String
    let journal: URL?
    let expectedJournalHash: String?
}

private enum V011HistoryRecoveryCleanupOutcome: Sendable {
    case archived
    case failed(String)
}

@MainActor
protocol V011HistoryRecoveryCleanupControllerDelegate: AnyObject {
    func historyRecoveryCleanupDidArchive()
    func historyRecoveryCleanupDidFail(_ message: String)
}

/// Owns cleanup single-flight, task lifetime, and detached CAS archival.
/// HistoryModel remains the weak delegate for recovery-state projection.
@MainActor
final class V011HistoryRecoveryCleanupController {
    private weak var delegate:
        (any V011HistoryRecoveryCleanupControllerDelegate)?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    init(
        delegate: any V011HistoryRecoveryCleanupControllerDelegate
    ) {
        self.delegate = delegate
    }

    func cleanup(
        _ request: V011HistoryRecoveryCleanupRequest
    ) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    try V011HistoryRecoveryStore
                        .archiveRecoveryRecord(
                        at: request.pointerURL,
                        expectedTransactionID:
                            request.pointer.transactionID,
                        expectedHash:
                            request.expectedPointerHash,
                        journal: request.journal,
                        expectedJournalHash:
                            request.expectedJournalHash
                    )
                    return V011HistoryRecoveryCleanupOutcome
                        .archived
                } catch {
                    return V011HistoryRecoveryCleanupOutcome
                        .failed(error.localizedDescription)
                }
            }.value
            switch outcome {
            case .archived:
                delegate?.historyRecoveryCleanupDidArchive()
            case let .failed(message):
                delegate?.historyRecoveryCleanupDidFail(message)
            }
            task = nil
        }
    }
}
