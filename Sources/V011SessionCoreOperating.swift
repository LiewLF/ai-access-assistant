// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

protocol V011SessionCoreOperating: Sendable {
    func list(
        codexHome: URL,
        limit: Int,
        offset: Int,
        provider: String?
    ) async throws -> SessionCoreSessionPage

    func interruptedJournal(
        codexHome: URL,
        recoveryRoot: URL
    ) async throws -> SessionCorePendingJournal?

    func inspect(
        codexHome: URL,
        provider: String
    ) async throws -> SessionCoreInspection

    func clearStalePrewriteLock(
        codexHome: URL,
        recoveryRoot: URL,
        transactionID: String
    ) async throws -> SessionCoreClearedPrewriteLock

    func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void
    ) async throws -> SessionCoreRepairSummary

    func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        transactionID: String,
        journalKey: Data,
        progress: @escaping @Sendable (SessionCoreProgress) -> Void
    ) async throws -> SessionCoreRepairSummary

    func rollback(
        codexHome: URL,
        recoveryRoot: URL,
        journal: URL,
        journalKey: Data
    ) async throws -> SessionCoreRollbackSummary
}

extension V011SessionCoreOperating {
    func inspect(
        codexHome: URL,
        provider: String
    ) async throws -> SessionCoreInspection {
        _ = codexHome
        _ = provider
        throw V011SwitchError.invalidRecoveryJournal
    }

    func repair(
        codexHome: URL,
        provider: String,
        recoveryRoot: URL,
        transactionID: String,
        journalKey: Data,
        progress: @escaping @Sendable
            (SessionCoreProgress) -> Void
    ) async throws -> SessionCoreRepairSummary {
        _ = transactionID
        return try await repair(
            codexHome: codexHome,
            provider: provider,
            recoveryRoot: recoveryRoot,
            journalKey: journalKey,
            progress: progress
        )
    }
}

extension SessionCoreClient: V011SessionCoreOperating {}
