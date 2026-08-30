// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

protocol V011HistorySessionCoreOperating: Sendable {
    func list(
        codexHome: URL,
        limit: Int,
        offset: Int,
        provider: String?
    ) async throws -> SessionCoreSessionPage

    func listAll(
        codexHome: URL,
        limit: Int,
        offset: Int,
        provider: String?
    ) async throws -> SessionCoreSessionPage

    func search(
        codexHome: URL,
        query: String,
        limit: Int,
        offset: Int,
        provider: String?
    ) async throws -> SessionCoreSessionPage

    func listWorkspaces(
        codexHome: URL,
        limit: Int,
        offset: Int
    ) async throws -> SessionCoreWorkspacePage

    func lookupWorkspaces(
        codexHome: URL,
        paths: [String]
    ) async throws -> SessionCoreWorkspacePage

    func listWorkspaceSessions(
        codexHome: URL,
        cwd: String,
        limit: Int,
        offset: Int,
        provider: String?
    ) async throws -> SessionCoreSessionPage

    func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        transactionID: String,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void
    ) async throws -> SessionCoreRepairSummary

    func interruptedJournal(
        codexHome: URL,
        recoveryRoot: URL
    ) async throws -> SessionCorePendingJournal?

    func clearStalePrewriteLock(
        codexHome: URL,
        recoveryRoot: URL,
        transactionID: String
    ) async throws -> SessionCoreClearedPrewriteLock

    func rollback(
        codexHome: URL,
        recoveryRoot: URL,
        journal: URL,
        journalKey: Data
    ) async throws -> SessionCoreRollbackSummary

    func importSessions(
        codexHome: URL,
        sourceRoot: URL,
        recoveryRoot: URL,
        transactionID: String,
        journalKey: Data,
        progress: @escaping @Sendable (
            SessionCoreProgress
        ) -> Void
    ) async throws -> SessionCoreImportSummary
}

extension V011HistorySessionCoreOperating {
    func listAll(
        codexHome: URL,
        limit: Int,
        offset: Int,
        provider: String?
    ) async throws -> SessionCoreSessionPage {
        try await list(
            codexHome: codexHome,
            limit: limit,
            offset: offset,
            provider: provider
        )
    }

    func lookupWorkspaces(
        codexHome: URL,
        paths: [String]
    ) async throws -> SessionCoreWorkspacePage {
        let page = try await listWorkspaces(
            codexHome: codexHome,
            limit: 50,
            offset: 0
        )
        let requested = Set(paths)
        let matches = page.workspaces.filter {
            requested.contains($0.cwd)
        }
        return SessionCoreWorkspacePage(
            databasePath: page.databasePath,
            total: matches.count,
            limit: paths.count,
            offset: 0,
            hasMore: false,
            workspaces: matches
        )
    }
}

extension SessionCoreClient: V011HistorySessionCoreOperating {}
