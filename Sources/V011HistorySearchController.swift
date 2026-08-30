// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
protocol V011HistorySearchControllerDelegate: AnyObject {
    func historySearchDidBegin(
        offset: Int,
        replacing: Bool
    )
    func historySearchDidLoad(
        rows: [V011SessionRow],
        total: Int,
        hasMore: Bool,
        workspaceScoped: Bool
    )
    func historySearchDidFail(_ error: Error)
    func historySearchDidBecomeIdle()
    func historySearchDidClear()
}

/// Owns local-history search context, page task lifetime, generation
/// invalidation, and result assembly. HistoryModel remains the weak delegate
/// for Published-state projection and user-facing status text.
@MainActor
final class V011HistorySearchController {
    private let dependencies: V011HistoryDependencies
    private weak var delegate:
        (any V011HistorySearchControllerDelegate)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var query = ""
    private var provider: String?
    private var workspacePath: String?

    init(
        dependencies: V011HistoryDependencies,
        delegate: any V011HistorySearchControllerDelegate
    ) {
        self.dependencies = dependencies
        self.delegate = delegate
    }

    func searchMetadata(
        query: String,
        provider: String?,
        recentRows: [V011SessionRow]
    ) {
        self.query = query
        self.provider = provider
        workspacePath = nil
        start(
            offset: 0,
            replacing: true,
            existingRows: [],
            recentRows: recentRows
        )
    }

    func searchWorkspace(
        path: String,
        provider: String?,
        recentRows: [V011SessionRow]
    ) {
        query = path
        self.provider = provider
        workspacePath = path
        start(
            offset: 0,
            replacing: true,
            existingRows: [],
            recentRows: recentRows
        )
    }

    func loadMore(
        offset: Int,
        existingRows: [V011SessionRow],
        recentRows: [V011SessionRow]
    ) {
        guard !query.isEmpty else { return }
        start(
            offset: offset,
            replacing: false,
            existingRows: existingRows,
            recentRows: recentRows
        )
    }

    func clear() {
        generation = UUID()
        task?.cancel()
        task = nil
        query = ""
        provider = nil
        workspacePath = nil
        delegate?.historySearchDidClear()
    }

    private func start(
        offset: Int,
        replacing: Bool,
        existingRows: [V011SessionRow],
        recentRows: [V011SessionRow]
    ) {
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        delegate?.historySearchDidBegin(
            offset: offset,
            replacing: replacing
        )

        let dependencies = dependencies
        let query = query
        let provider = provider
        let workspacePath = workspacePath
        let knownRows = Dictionary(
            uniqueKeysWithValues: recentRows.map { ($0.id, $0) }
        )
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let page: SessionCoreSessionPage
                if let workspacePath {
                    page = try await dependencies.sessionCore
                        .listWorkspaceSessions(
                            codexHome: dependencies.codexHome,
                            cwd: workspacePath,
                            limit: 50,
                            offset: offset,
                            provider: provider
                        )
                } else {
                    page = try await dependencies.sessionCore.search(
                        codexHome: dependencies.codexHome,
                        query: query,
                        limit: 50,
                        offset: offset,
                        provider: provider
                    )
                }
                try Task.checkCancellation()
                guard generation == self.generation else {
                    return
                }
                let newRows = page.sessions.map {
                    knownRows[$0.id]
                        ?? V011SessionRow(
                            session: $0,
                            origin: nil
                        )
                }
                let resultRows: [V011SessionRow]
                if replacing {
                    resultRows = newRows
                } else {
                    let existing = Set(existingRows.map(\.id))
                    resultRows = existingRows
                        + newRows.filter {
                            !existing.contains($0.id)
                        }
                }
                delegate?.historySearchDidLoad(
                    rows: resultRows,
                    total: page.total,
                    hasMore: page.hasMore,
                    workspaceScoped: workspacePath != nil
                )
            } catch is CancellationError {
            } catch {
                guard generation == self.generation else {
                    return
                }
                delegate?.historySearchDidFail(error)
            }
            guard generation == self.generation else {
                return
            }
            delegate?.historySearchDidBecomeIdle()
            self.task = nil
        }
        self.task = task
    }
}
