// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
protocol V011HistoryWorkspaceControllerDelegate: AnyObject {
    func historyWorkspaceDidBegin(
        offset: Int,
        replacing: Bool
    )
    func historyWorkspaceDidLoad(
        rows: [V011WorkspaceRow],
        total: Int,
        hasMore: Bool,
        favoriteLookupError: Error?
    )
    func historyWorkspaceDidFail(_ error: Error)
    func historyWorkspaceDidBecomeIdle()
    func historyWorkspaceDidCancel()
}

/// Owns workspace-page task lifetime, favorite detail lookup, page assembly,
/// and SessionCore offset. HistoryModel remains the weak delegate for
/// Published-state projection and workspace preference ownership.
@MainActor
final class V011HistoryWorkspaceController {
    private let dependencies: V011HistoryDependencies
    private weak var delegate:
        (any V011HistoryWorkspaceControllerDelegate)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var listOffset = 0

    init(
        dependencies: V011HistoryDependencies,
        delegate: any V011HistoryWorkspaceControllerDelegate
    ) {
        self.dependencies = dependencies
        self.delegate = delegate
    }

    func loadFirstPage(
        force: Bool,
        isLoading: Bool,
        favoritePaths: Set<String>
    ) {
        if isLoading && !force {
            return
        }
        start(
            offset: 0,
            replacing: true,
            existingRows: [],
            favoritePaths: favoritePaths.sorted()
        )
    }

    func loadMore(existingRows: [V011WorkspaceRow]) {
        start(
            offset: listOffset,
            replacing: false,
            existingRows: existingRows,
            favoritePaths: []
        )
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        delegate?.historyWorkspaceDidCancel()
    }

    private func start(
        offset: Int,
        replacing: Bool,
        existingRows: [V011WorkspaceRow],
        favoritePaths: [String]
    ) {
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        if replacing {
            listOffset = 0
        }
        delegate?.historyWorkspaceDidBegin(
            offset: offset,
            replacing: replacing
        )

        let dependencies = dependencies
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await dependencies.sessionCore
                    .listWorkspaces(
                        codexHome: dependencies.codexHome,
                        limit: 50,
                        offset: offset
                    )
                var favoriteRows: [V011WorkspaceRow] = []
                var favoriteLookupError: Error?
                if !favoritePaths.isEmpty {
                    do {
                        let details = try await dependencies.sessionCore
                            .lookupWorkspaces(
                                codexHome: dependencies.codexHome,
                                paths: favoritePaths
                            )
                        let indexed = Dictionary(
                            uniqueKeysWithValues: details.workspaces.map {
                                ($0.cwd, V011WorkspaceRow(workspace: $0))
                            }
                        )
                        favoriteRows = favoritePaths.map {
                            indexed[$0]
                                ?? V011WorkspaceRow(
                                    missingFavoritePath: $0
                                )
                        }
                        favoriteRows.sort { lhs, rhs in
                            if lhs.isIndexed != rhs.isIndexed {
                                return lhs.isIndexed
                            }
                            if lhs.latestUpdatedAt
                                != rhs.latestUpdatedAt {
                                return (lhs.latestUpdatedAt
                                    ?? .distantPast)
                                    > (rhs.latestUpdatedAt
                                        ?? .distantPast)
                            }
                            return lhs.path
                                .localizedCaseInsensitiveCompare(
                                    rhs.path
                                ) == .orderedAscending
                        }
                    } catch {
                        favoriteRows = favoritePaths.map {
                            V011WorkspaceRow(
                                missingFavoritePath: $0
                            )
                        }
                        favoriteLookupError = error
                    }
                }
                try Task.checkCancellation()
                guard generation == self.generation else {
                    return
                }
                let newRows = page.workspaces.map(
                    V011WorkspaceRow.init(workspace:)
                )
                let resultRows: [V011WorkspaceRow]
                if replacing {
                    let favorites = Set(favoriteRows.map(\.path))
                    resultRows = favoriteRows
                        + newRows.filter {
                            !favorites.contains($0.path)
                        }
                } else {
                    let existing = Set(existingRows.map(\.path))
                    resultRows = existingRows
                        + newRows.filter {
                            !existing.contains($0.path)
                        }
                }
                listOffset = offset + page.workspaces.count
                delegate?.historyWorkspaceDidLoad(
                    rows: resultRows,
                    total: page.total,
                    hasMore: page.hasMore,
                    favoriteLookupError: favoriteLookupError
                )
            } catch is CancellationError {
            } catch {
                guard generation == self.generation else {
                    return
                }
                delegate?.historyWorkspaceDidFail(error)
            }
            guard generation == self.generation else {
                return
            }
            delegate?.historyWorkspaceDidBecomeIdle()
            self.task = nil
        }
        self.task = task
    }
}
