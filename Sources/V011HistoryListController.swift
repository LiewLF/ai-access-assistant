// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
protocol V011HistoryListControllerDelegate: AnyObject {
    func historyListWillLoad(
        offset: Int,
        replacing: Bool
    )
    func historyListDidLoad(
        page: SessionCoreSessionPage,
        ledger: V011SessionOriginLedgerPayload,
        ledgerWarning: String?,
        replacing: Bool,
        publishRecoveryAtEnd: Bool
    )
    func historyListDidCancel()
    func historyListDidFail(_ error: Error)
    func historyListDidBecomeIdle()
}

/// Owns recent-session provider selection, task lifetime, generation
/// invalidation, and last-error state. HistoryModel remains the weak delegate
/// for Published-state projection and recovery snapshot publication.
@MainActor
final class V011HistoryListController {
    private let dependencies: V011HistoryDependencies
    private let originService: V011HistorySessionOriginService
    private weak var delegate:
        (any V011HistoryListControllerDelegate)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    private(set) var currentProvider: String?
    private(set) var lastError: Error?

    init(
        dependencies: V011HistoryDependencies,
        ledgerRoot: URL,
        delegate: any V011HistoryListControllerDelegate
    ) {
        self.dependencies = dependencies
        self.originService = V011HistorySessionOriginService(
            dependencies: dependencies,
            ledgerRoot: ledgerRoot
        )
        self.delegate = delegate
    }

    func loadFirstPage(
        provider: String?,
        force: Bool,
        isLoading: Bool
    ) {
        if isLoading,
           provider == currentProvider,
           !force {
            return
        }
        currentProvider = provider
        _ = start(
            offset: 0,
            provider: provider,
            replacing: true
        )
    }

    func loadMore(offset: Int) {
        _ = start(
            offset: offset,
            provider: currentProvider,
            replacing: false
        )
    }

    func recount(provider: String?) -> Task<Void, Never> {
        start(
            offset: 0,
            provider: provider,
            replacing: true,
            publishRecoveryAtEnd: false
        )
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private func start(
        offset: Int,
        provider: String?,
        replacing: Bool,
        publishRecoveryAtEnd: Bool = true
    ) -> Task<Void, Never> {
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        lastError = nil
        delegate?.historyListWillLoad(
            offset: offset,
            replacing: replacing
        )

        let dependencies = dependencies
        let originService = originService
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await dependencies.sessionCore
                    .list(
                        codexHome: dependencies.codexHome,
                        limit: 50,
                        offset: offset,
                        provider: provider
                    )
                try Task.checkCancellation()
                let ledgerResult = await Task.detached {
                    () -> Result<
                        V011SessionOriginLedgerPayload,
                        Error
                    > in
                    do {
                        return .success(
                            try originService.loadAndMerge(
                                sessions: page.sessions
                            )
                        )
                    } catch {
                        return .failure(error)
                    }
                }.value
                try Task.checkCancellation()
                guard generation == self.generation else {
                    return
                }
                let ledger: V011SessionOriginLedgerPayload
                let ledgerWarning: String?
                switch ledgerResult {
                case let .success(value):
                    ledger = value
                    ledgerWarning = nil
                case let .failure(error):
                    ledger = .empty
                    ledgerWarning =
                        "历史来源暂时无法读取："
                        + error.localizedDescription
                }
                delegate?.historyListDidLoad(
                    page: page,
                    ledger: ledger,
                    ledgerWarning: ledgerWarning,
                    replacing: replacing,
                    publishRecoveryAtEnd:
                        publishRecoveryAtEnd
                )
            } catch is CancellationError {
                guard generation == self.generation else {
                    return
                }
                delegate?.historyListDidCancel()
            } catch {
                guard generation == self.generation else {
                    return
                }
                lastError = error
                delegate?.historyListDidFail(error)
            }
            guard generation == self.generation else {
                return
            }
            delegate?.historyListDidBecomeIdle()
            self.task = nil
        }
        self.task = task
        return task
    }
}
