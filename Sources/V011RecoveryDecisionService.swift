// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011RecoveryDecisionService {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let sessionCore: any V011SessionCoreOperating
    let versionContract: CodexVersionContract
    let keyProvider: () throws -> Data

    func disposition(
        pending: [V011SwitchJournal],
        onPreview: ((String, FablePreparedRecoveryConfiguration) -> Void)? = nil
    ) throws -> V011RecoveryDisposition {
        guard !pending.isEmpty else { return .none }
        guard pending.count == 1 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let key = try validatedJournalKey()
        let vault = SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchConfigVault",
                isDirectory: true
            ),
            keyProvider: { key }
        )
        for journal in pending {
            do {
                try preflightSessionJournal(journal)
            } catch {
                return .decisionRequired
            }
            guard try V011SwitchStateEvidenceAuthenticator
                    .allowsAutomaticRecovery(
                        journal,
                        key: key
                    ) else {
                return .decisionRequired
            }
            do {
                let recovery = try recoverySnapshotService.prepare(
                    journal: journal,
                    vault: vault
                )
                onPreview?(journal.id, recovery.configuration.prepared)
            } catch FableSwitchError.managedRecoveryConflict {
                return .decisionRequired
            } catch V011SwitchError
                .concurrentConfigurationChange {
                return .decisionRequired
            }
        }
        return .recoverable
    }

    func preflightSessionJournal(
        _ journal: V011SwitchJournal
    ) throws {
        guard let path = journal.sessionJournalPath else { return }
        let directory = URL(fileURLWithPath: path)
            .standardizedFileURL
        let expectedRoot = sessionRecoveryRoot.standardizedFileURL
        let expectedName = journal.id.lowercased()
        guard directory.deletingLastPathComponent() == expectedRoot,
              directory.lastPathComponent.lowercased() == expectedName else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let directoryExists = FileManager.default.fileExists(
            atPath: directory.path
        )
        let manifest = directory.appendingPathComponent("journal.json")
        let manifestExists = FileManager.default.fileExists(
            atPath: manifest.path
        )
        // An outer switch journal that points at an inner journal is never
        // safe to recover when that inner path disappeared. Treat both a
        // missing directory and a missing manifest as a decision-required
        // case before stopping writers or restoring configuration.
        guard directoryExists, manifestExists else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        guard try sessionInspector
                .sessionJournalIsMaterialized(path) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: manifest.path
        )
        if let size = attributes[.size] as? NSNumber,
           size.uint64Value > UInt64(
                SessionCoreClient.maximumRecoveryJournalBytes
           ) {
            throw V011SwitchError.invalidRecoveryJournal
        }
        _ = try sessionInspector.boundedRegularFileData(
            manifest,
            maximumBytes: SessionCoreClient
                .maximumRecoveryJournalBytes
        )
    }

    /// Resolve a SessionCore interrupted journal only after binding its
    /// transaction ID and path to the outer switch journal. A mismatched
    /// lock/path must not be allowed to become a session rollback target.
    func boundInterruptedSessionJournal(
        _ interrupted: SessionCorePendingJournal,
        to journal: V011SwitchJournal
    ) throws -> String? {
        let outerID = journal.id.lowercased()
        guard interrupted.transactionID.lowercased() == outerID else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        if interrupted.prewrite {
            guard interrupted.journalPath == nil else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            return nil
        }
        guard let interruptedPath = interrupted.journalPath,
              let outerPath = journal.sessionJournalPath else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let expectedRoot = sessionRecoveryRoot.standardizedFileURL
        let interruptedURL = URL(fileURLWithPath: interruptedPath)
            .standardizedFileURL
        let outerURL = URL(fileURLWithPath: outerPath)
            .standardizedFileURL
        guard interruptedURL.deletingLastPathComponent() == expectedRoot,
              outerURL.deletingLastPathComponent() == expectedRoot,
              interruptedURL.lastPathComponent.lowercased() == outerID,
              outerURL.lastPathComponent.lowercased() == outerID else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return outerURL.path
    }

    func targetConfigurationMatches(
        journal: V011SwitchJournal,
        live: LiveCodexState,
        managedState: V011ManagedState,
        versionContractID: String
    ) throws -> Bool {
        try targetConfigurationMatcher.matches(
            journal: journal,
            live: live,
            managedState: managedState,
            versionContractID: versionContractID
        )
    }

    func sessionsMatchTarget(
        providerID: String
    ) async throws -> Bool {
        try await sessionInspector.sessionsMatchTarget(
            providerID: providerID
        )
    }

    func sessionJournalAllowsAcceptance(
        _ journal: V011SwitchJournal
    ) throws -> Bool {
        try sessionInspector.sessionJournalAllowsAcceptance(
            journal
        )
    }

    func sessionJournalAllowsForwardCompletion(
        _ journal: V011SwitchJournal
    ) throws -> Bool {
        try sessionInspector.sessionJournalAllowsForwardCompletion(
            journal
        )
    }

    func sessionJournalIsMaterialized(
        _ path: String
    ) throws -> Bool {
        try sessionInspector.sessionJournalIsMaterialized(path)
    }

    func recoveryFailureDetail(
        primary: Error?,
        recovery: Error
    ) -> String {
        let recoveryText = V011RecoveryErrorText
            .safeDetail(recovery)
        guard let primary else {
            return "恢复未完成：\(recoveryText)"
        }
        return "目标状态复核未通过：\(V011RecoveryErrorText.safeDetail(primary))；恢复也未完成：\(recoveryText)"
    }

    func applyRecoveryContext(
        from error: Error,
        to journal: inout V011SwitchJournal
    ) {
        if let context = error as? V011ForwardCompletionError {
            journal.failureStage = context.stage
            journal.nextAction = context.nextAction
            return
        }
        if let clientError = error as? SessionCoreClientError {
            _ = clientError
            journal.failureStage = .sessionRestore
            journal.nextAction =
                "完全退出Codex后再次恢复；仍失败时打开修复工具"
            return
        }
        journal.failureStage = journal.failureStage
            ?? .configurationRestore
        journal.nextAction = journal.nextAction
            ?? "不要继续切换，打开修复工具核对当前模式"
    }

    func applyPrimaryFailureContext(
        _ error: Error,
        phase: V011SwitchPhase,
        to journal: inout V011SwitchJournal
    ) {
        if error is SessionCoreClientError {
            journal.failureStage = .sessionCheck
            journal.nextAction =
                "完全退出Codex后再次恢复；恢复完成后重新切换"
            return
        }
        switch phase {
        case .sessionsWritten, .codexLaunched:
            journal.failureStage = .connectionCheck
            journal.nextAction =
                "恢复完成后检查网络、中转地址、模型和密钥，再重新切换"
        case .verified:
            journal.failureStage = .configurationCheck
            journal.nextAction =
                "恢复完成后退出其他配置工具，再重新切换"
        default:
            journal.failureStage = .configurationCheck
            journal.nextAction =
                "恢复完成后重新核对中转信息，再重新切换"
        }
    }

    func recoveryPreparationMessage(
        forwardFailure: Error?
    ) -> String {
        let protection =
            "正在保护切换后新增的历史会话，再恢复到操作前"
        guard let forwardFailure else { return protection }
        return "\(V011RecoveryErrorText.safeDetail(forwardFailure))；\(protection)"
    }

    func recoveryCompletedMessage(
        sessionRollback: SessionCoreRollbackSummary?
    ) -> String {
        guard let sessionRollback else {
            return "未完成切换已恢复；没有需要回退的会话标签"
        }
        if sessionRollback.alreadyRolledBack {
            return "未完成切换已恢复；历史会话此前已恢复，新增会话保持不变"
        }
        return "未完成切换已恢复；切换后新增的历史会话和内容已保留"
    }

    private var sessionRecoveryRoot: URL {
        controlRoot.appendingPathComponent(
            "SessionCoreRecovery",
            isDirectory: true
        )
    }

    private var targetConfigurationMatcher:
        V011TargetConfigurationMatcher {
        V011TargetConfigurationMatcher(
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore
        )
    }

    private var sessionInspector: V011SessionRecoveryInspector {
        V011SessionRecoveryInspector(
            codexHome: codexHome,
            sessionRecoveryRoot: sessionRecoveryRoot,
            sessionCore: sessionCore
        )
    }

    private var recoverySnapshotService:
        V011RecoverySnapshotService {
        V011RecoverySnapshotService(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            versionContract: versionContract,
            keyProvider: keyProvider
        )
    }

    private func validatedJournalKey() throws -> Data {
        let key = try keyProvider()
        guard key.count == 32 else {
            throw SecureProfileVaultError.encodingFailed
        }
        return key
    }
}
