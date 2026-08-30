// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011HistoryRecoveryObservation: Sendable {
    let pointerRecord: V011HistoryRecoveryPointer?
    let pointerReadFailed: Bool
    let pointerErrorMessage: String?
    let pending: SessionCorePendingJournal?
}

struct V011HistoryRecoveryRefreshToken: Equatable, Sendable {
    fileprivate let id: UUID
}

struct V011HistoryRecoveryObservationService: Sendable {
    let dependencies: V011HistoryDependencies
    let recoveryRoot: URL

    func read() async throws -> V011HistoryRecoveryObservation {
        let pointer = recoveryRoot.appendingPathComponent(
            "last-repair.json"
        )
        let pointerResult = await Task.detached {
            Result {
                try V011HistoryRecoveryStore
                    .readRecoveryJournalPointer(
                    at: pointer,
                    recoveryRoot: recoveryRoot
                )
            }
        }.value
        // SessionCore owns lock/root semantics. Query even when root is
        // absent: only proven prewrite absence is safe.
        let pending = try await dependencies.sessionCore
            .interruptedJournal(
                codexHome: dependencies.codexHome,
                recoveryRoot: recoveryRoot
            )
        try Task.checkCancellation()
        switch pointerResult {
        case let .success(pointerRecord):
            return V011HistoryRecoveryObservation(
                pointerRecord: pointerRecord,
                pointerReadFailed: false,
                pointerErrorMessage: nil,
                pending: pending
            )
        case let .failure(error):
            return V011HistoryRecoveryObservation(
                pointerRecord: nil,
                pointerReadFailed: true,
                pointerErrorMessage: error.localizedDescription,
                pending: pending
            )
        }
    }
}

@MainActor
protocol V011HistoryRecoveryRefreshControllerDelegate: AnyObject {
    func historyRecoveryRefreshDidLoad(
        _ observation: V011HistoryRecoveryObservation
    )
    func historyRecoveryRefreshDidFail(_ error: Error)
}

/// Owns read-only recovery refresh cancellation and generation invalidation.
/// HistoryModel remains the weak delegate for durable-state reconciliation
/// and snapshot publication.
@MainActor
final class V011HistoryRecoveryRefreshController {
    private let service: V011HistoryRecoveryObservationService
    private weak var delegate:
        (any V011HistoryRecoveryRefreshControllerDelegate)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(
        dependencies: V011HistoryDependencies,
        recoveryRoot: URL,
        delegate: any V011HistoryRecoveryRefreshControllerDelegate
    ) {
        self.service = V011HistoryRecoveryObservationService(
            dependencies: dependencies,
            recoveryRoot: recoveryRoot
        )
        self.delegate = delegate
    }

    func refresh() {
        let token = beginExclusiveRefresh()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let observation = try await read(
                    for: token
                ) else {
                    return
                }
                delegate?.historyRecoveryRefreshDidLoad(
                    observation
                )
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(token) else {
                    return
                }
                delegate?.historyRecoveryRefreshDidFail(error)
            }
            guard isCurrent(token) else {
                return
            }
            self.task = nil
        }
        self.task = task
    }

    func beginExclusiveRefresh()
        -> V011HistoryRecoveryRefreshToken {
        task?.cancel()
        task = nil
        let token = V011HistoryRecoveryRefreshToken(
            id: UUID()
        )
        generation = token.id
        return token
    }

    func read(
        for token: V011HistoryRecoveryRefreshToken
    ) async throws -> V011HistoryRecoveryObservation? {
        let observation = try await service.read()
        try Task.checkCancellation()
        guard isCurrent(token) else { return nil }
        return observation
    }

    func isCurrent(
        _ token: V011HistoryRecoveryRefreshToken
    ) -> Bool {
        generation == token.id
    }
}
