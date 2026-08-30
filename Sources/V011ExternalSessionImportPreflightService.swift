// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011ExternalSessionImportPreflightResult: Sendable {
    let preview: V011ExternalSessionImportPreview
    let normalizedSourcePath: String
}

/// Owns bounded current-thread enumeration and detached external-folder
/// inspection. This service is read-only and never mutates either source.
struct V011ExternalSessionImportPreflightService: Sendable {
    let dependencies: V011HistoryDependencies

    func inspect(
        sourceRoot: URL
    ) async throws -> V011ExternalSessionImportPreflightResult {
        let existingThreadIDs = try await allCurrentThreadIDs()
        try Task.checkCancellation()
        let codexHome = dependencies.codexHome
        let worker = Task.detached(priority: .userInitiated) {
            try V011ExternalSessionImportPreflightScanner.inspect(
                sourceRoot: sourceRoot,
                currentCodexHome: codexHome,
                existingThreadIDs: existingThreadIDs
            )
        }
        let preview = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return V011ExternalSessionImportPreflightResult(
            preview: preview,
            normalizedSourcePath: sourceRoot
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
        )
    }

    private func allCurrentThreadIDs()
        async throws -> Set<String> {
        let maximumSessions = 20_000
        var threadIDs = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await dependencies.sessionCore.listAll(
                codexHome: dependencies.codexHome,
                limit: 50,
                offset: offset,
                provider: nil
            )
            for session in page.sessions {
                threadIDs.insert(session.id.lowercased())
            }
            guard threadIDs.count <= maximumSessions,
                  offset + page.sessions.count <= maximumSessions else {
                throw V011ExternalSessionImportPreflightError
                    .tooManyCurrentSessions
            }
            guard page.hasMore else { return threadIDs }
            guard !page.sessions.isEmpty else {
                throw V011ExternalSessionImportPreflightError
                    .stalledCurrentSessionListing
            }
            offset += page.sessions.count
        }
    }
}
