// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

struct V011PendingRecoveryCoordinator: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let processController: any FableProcessController
    let sessionCore: any V011SessionCoreOperating
    let progress: @Sendable (String) -> Void
    let acceptedCurrentFaultInjector:
        @Sendable (V011AcceptedCurrentFaultPoint) throws -> Void
    let acceptedCurrentDirectorySynchronizer:
        @Sendable (Int32) -> Int32
    let sessionTransactionCoordinator:
        V011SessionTransactionCoordinator
    let currentConnectionVerifier:
        V011CurrentConnectionVerifier
    let recoveryDecisionService:
        V011RecoveryDecisionService
    let forwardCompletionService:
        V011ForwardCompletionService
    let recoverySnapshotService:
        V011RecoverySnapshotService
    let managedStateStore: V011ManagedStateStore
    let journalWriter: V011SwitchJournalWriter

    func recoverPending() async throws -> Int {
        let store = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        // Startup always reconciles already-committed ConfigTxn records before
        // entering the legacy pending-journal recovery domain.
        _ = sessionTransactionCoordinator.reconcileCommittedSessionTransactions()
        let pending = try store.pending()
        guard !pending.isEmpty else { return 0 }
        guard pending.count == 1,
              var journal = pending.first else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        do {
            let disposition = try recoveryDecisionService.disposition(pending: pending)
            guard disposition != .decisionRequired else {
                throw V011SwitchError.recoveryDecisionRequired
            }
        } catch {
            throw error
        }
        // Preflight session history before any configuration restore. The
        // session core enforces current runtime journal size, path, and
        // readability limits. Any failure stays on decision/archive path;
        // no live surface has been touched yet.
        let isSplitConfigTransaction = journal.configTransactionID != nil
        if !isSplitConfigTransaction {
            do {
                try recoveryDecisionService.preflightSessionJournal(journal)
                if let interrupted = try await sessionCore.interruptedJournal(
                    codexHome: codexHome,
                    recoveryRoot: sessionRecoveryRoot
                ) {
                    _ = try recoveryDecisionService.boundInterruptedSessionJournal(
                        interrupted,
                        to: journal
                    )
                }
            } catch {
                throw V011SwitchError.recoveryDecisionRequired
            }
        }
        let key = try journalWriter.validatedKey()
        let vault = SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchConfigVault",
                isDirectory: true
            ),
            keyProvider: { key }
        )
        try processController.stopConfigurationWriters()
        var forwardFailure: Error?
        var forwardPreparation:
            V011ForwardCompletionPreparation?
        do {
            if journal.failureStage != .configurationRestore {
                forwardPreparation = try await
                    forwardCompletionService.prepareIfSafe(
                    journal: &journal,
                    store: store,
                    journalKey: key
                )
            }
        } catch {
            forwardFailure = error
            recoveryDecisionService.applyRecoveryContext(
                from: error,
                to: &journal
            )
            try store.save(journal)
        }
        if let forward = forwardPreparation {
            do {
                if let data = forward.managedStateData {
                    try managedStateStore.writePrepared(
                        data,
                        expectedCurrentHash:
                            forward.expectedManagedStateHash
                    )
                }
                guard SessionSyncFileSafety.hashIfPresent(
                        managedStateStore.fileURL
                      ) == forward.resultingManagedStateHash else {
                    throw V011SwitchError
                        .concurrentConfigurationChange
                }
                progress("正在重新打开Codex")
                do {
                    try processController.relaunchCodex()
                } catch {
                    throw V011ForwardCompletionError(
                        stage: .connectionCheck,
                        reason: V011RecoveryErrorText
                            .safeDetail(error),
                        nextAction:
                            "再次恢复，重新打开Codex并完成目标模式切换"
                    )
                }
                if journal.configTransactionID != nil {
                    journal.configTransactionPhase = .committed
                }
                try journalWriter.update(
                    &journal,
                    phase: .committed,
                    message:
                        "目标模式、历史会话和连接均已核对，已完成切换",
                    store: store
                )
                try store.archiveCommittedKeepingLatest()
                _ = sessionTransactionCoordinator.reconcileCommittedSessionTransactions()
                return 1
            } catch {
                recoveryDecisionService.applyRecoveryContext(
                    from: error,
                    to: &journal
                )
                let detail = recoveryDecisionService.recoveryFailureDetail(
                    primary: nil,
                    recovery: error
                )
                try? journalWriter.update(
                    &journal,
                    phase: .rollbackFailed,
                    message: detail,
                    store: store
                )
                throw V011SwitchError.rollbackFailed(detail)
            }
        }
        do {
            var stalePrewriteTransactionID: String?
            journal.phase = .rollbackRequired
            journal.updatedAt = Date()
            journal.protectsPostSwitchSessions = true
            journal.message = recoveryDecisionService.recoveryPreparationMessage(
                forwardFailure: forwardFailure
            )
            try store.save(journal)
            if !isSplitConfigTransaction {
                if let interrupted = try await sessionCore
                    .interruptedJournal(
                        codexHome: codexHome,
                        recoveryRoot: sessionRecoveryRoot
                    ) {
                    let boundPath = try recoveryDecisionService.boundInterruptedSessionJournal(
                        interrupted,
                        to: journal
                    )
                    if interrupted.prewrite {
                        stalePrewriteTransactionID =
                            interrupted.transactionID
                        journal.sessionJournalPath = nil
                    } else {
                        journal.sessionJournalPath =
                            boundPath
                    }
                    try store.save(journal)
                }
            } else {
                journal.sessionJournalPath = nil
            }
            var sessionRollback: SessionCoreRollbackSummary?
            if let path = journal.sessionJournalPath,
               try recoveryDecisionService
                .sessionJournalIsMaterialized(path) {
                do {
                    sessionRollback = try await sessionCore
                        .rollback(
                            codexHome: codexHome,
                            recoveryRoot: sessionRecoveryRoot,
                            journal: URL(fileURLWithPath: path),
                        journalKey: key
                        )
                } catch {
                    throw V011ForwardCompletionError(
                        stage: .sessionRestore,
                        reason: V011RecoveryErrorText
                            .safeDetail(error),
                        nextAction:
                            "完全退出Codex后再次恢复；仍失败时打开修复工具"
                    )
                }
            } else if stalePrewriteTransactionID == nil {
                journal.sessionJournalPath = nil
                try store.save(journal)
            }
            do {
                let recovery = try recoverySnapshotService.prepare(
                    journal: journal,
                    vault: vault
                )
                try recoverySnapshotService.apply(recovery)
            } catch {
                throw V011ForwardCompletionError(
                    stage: .configurationRestore,
                    reason: V011RecoveryErrorText.safeDetail(error),
                    nextAction:
                        "不要继续切换，打开修复工具核对当前模式"
                )
            }
            if let transactionID = stalePrewriteTransactionID {
                _ = try await sessionCore
                    .clearStalePrewriteLock(
                        codexHome: codexHome,
                        recoveryRoot: sessionRecoveryRoot,
                        transactionID: transactionID
                    )
            }
            progress("正在重新打开Codex")
            try processController.relaunchCodex()
            try journalWriter.update(
                &journal,
                phase: .rolledBack,
                message: recoveryDecisionService.recoveryCompletedMessage(
                    sessionRollback: sessionRollback
                ),
                store: store
            )
            try sessionTransactionCoordinator
                .discardUnmaterializedReservationIfNeeded(journal)
            return 1
        } catch {
            recoveryDecisionService.applyRecoveryContext(
                from: error,
                to: &journal
            )
            let detail = recoveryDecisionService.recoveryFailureDetail(
                primary: forwardFailure,
                recovery: error
            )
            try? journalWriter.update(
                &journal,
                phase: .rollbackFailed,
                message: detail,
                store: store
            )
            throw V011SwitchError.rollbackFailed(detail)
        }
    }

    func recoveryDisposition(
        onPreview: ((String, FablePreparedRecoveryConfiguration) -> Void)? = nil
    ) throws -> V011RecoveryDisposition {
        let store = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        return try recoveryDecisionService.disposition(
            pending: store.pending(), onPreview: onPreview
        )
    }

    func keepCurrentStateAndEndPendingRecovery()
        async throws -> Int {
        let store = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        let pending = try store.pending()
        guard !pending.isEmpty else { return 0 }
        guard pending.count == 1,
              let journal = pending.first else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let expectedHash = try store.journalHash(journal.id)
        _ = try store.archivePendingKeepingCurrent(
            journal,
            expectedJournalHash: expectedHash
        )
        return 1
    }

    /// Safe configuration-only recovery action. It archives exactly the
    /// pending outer switch journal via CAS and deliberately does not call
    /// SessionCore, touch Codex configuration, or modify session history.
    func keepCurrentConfigurationAndEndPendingRecovery()
        async throws -> Int {
        try await keepCurrentStateAndEndPendingRecovery()
    }

    func acceptCurrentRelayForPendingRecovery(
        now: @Sendable () -> Date = { Date() }
    ) async throws -> V011SwitchJournal {
        let store = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            ),
            faultInjector: acceptedCurrentFaultInjector,
            directorySynchronizer:
                acceptedCurrentDirectorySynchronizer
        )
        let initialPending = try store.pending()
        let initialInterrupted = try await sessionCore
            .interruptedJournal(
                codexHome: codexHome,
                recoveryRoot: sessionRecoveryRoot
            )
        guard initialPending.count == 1,
              let originalJournal = initialPending.first,
              try recoveryDecisionService.disposition(
                  pending: initialPending
              ) == .decisionRequired,
              try recoveryDecisionService.sessionJournalAllowsAcceptance(
                  originalJournal
              ),
              initialInterrupted == nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }

        let verification = try await currentConnectionVerifier.verify(
            now: now,
            requireSavedRelayProfile: true
        )
        guard case .relay = verification.state.mode,
              let profileID = verification.savedProfileID,
              verification.sessionProviderCheck
                == .synchronized else {
            throw V011SwitchError.currentRelayChanged
        }
        try currentConnectionVerifier.validate(
            verification,
            requireSavedRelayProfile: true
        )
        guard try await recoveryDecisionService.sessionsMatchTarget(
            providerID: verification.providerID
        ) else {
            throw V011SwitchError.currentRelayChanged
        }
        try currentConnectionVerifier.validate(
            verification,
            requireSavedRelayProfile: true
        )

        let finalPending = try store.pending()
        let finalInterrupted = try await sessionCore
            .interruptedJournal(
                codexHome: codexHome,
                recoveryRoot: sessionRecoveryRoot
            )
        guard finalPending.count == 1,
              var journal = finalPending.first,
              journal == originalJournal,
              try recoveryDecisionService.disposition(
                  pending: finalPending
              ) == .decisionRequired,
              try recoveryDecisionService.sessionJournalAllowsAcceptance(journal),
              finalInterrupted == nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }

        let stateURL = managedStateStore.fileURL
        let originalStateData: Data?
        if FileManager.default.fileExists(
            atPath: stateURL.path
        ) {
            try SessionSyncFileSafety.requireRegularFile(
                stateURL
            )
            originalStateData = try Data(
                contentsOf: stateURL,
                options: .mappedIfSafe
            )
        } else {
            originalStateData = nil
        }
        let stateHash = SessionSyncFileSafety.hashIfPresent(
            stateURL
        )
        guard originalStateData.map({
                  TOMLSemanticEngine.sha256($0)
              }) == stateHash else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
        let journalHash = try store.journalHash(
            journal.id
        )
        var managedState = try managedStateStore.load()
        guard stateHash == SessionSyncFileSafety.hashIfPresent(
                  stateURL
              ),
              managedState.relayProfiles.filter({
                  $0.id == profileID
                      && $0.v011ProviderID
                        == verification.providerID
                      && V011RelaySemanticMatcher.matches(
                          live: verification.state,
                          profile: $0
                      )
                      && verification.state.provider?
                        .displayName == $0.name
              }).count == 1 else {
            throw V011CurrentConnectionVerificationError
                .savedProfileMismatch
        }
        try currentConnectionVerifier.validate(
            verification,
            requireSavedRelayProfile: true
        )
        guard stateHash == SessionSyncFileSafety.hashIfPresent(
                  stateURL
              ),
              (
                  try recoverySnapshotService.configurationRestorePreflight(
                      journal: journal
                  ).isConflict
              ),
              try store.load(journal.id) == journal else {
            throw V011SwitchError.concurrentConfigurationChange
        }

        managedState.activeProfileID = profileID
        managedState.lastVerifiedConfigHash =
            verification.configHash
        managedState.lastVerifiedProviderID =
            verification.providerID
        managedState.lastVerifiedAt = verification.verifiedAt
        guard case let .verified(contractID) =
                verification.state.versionSupport else {
            throw FableSwitchError.unsupportedVersion
        }
        try V011CutoverPromotionRecorder.record(
            state: &managedState,
            providerID: verification.providerID,
            profileID: profileID,
            modelID: verification.state.model,
            configHash: verification.configHash,
            capabilityContract: contractID,
            transactionID: journal.id,
            verifiedAt: verification.verifiedAt
        )
        let intendedStateData = try managedStateStore
            .preparedData(for: managedState)
        let intendedStateHash = TOMLSemanticEngine.sha256(
            intendedStateData
        )
        do {
            try managedStateStore.writePrepared(
                intendedStateData,
                expectedCurrentHash: stateHash
            )
            try acceptedCurrentFaultInjector(
                .afterAcceptedStateWrite
            )
        } catch {
            let primary = error
            switch classifyAtomicWrite(
                at: stateURL,
                originalHash: stateHash,
                intendedHash: intendedStateHash
            ) {
            case .original, .intended:
                do {
                    try store
                        .withOriginalJournalAndNoAcceptedArchive(
                            journalID: journal.id,
                            expectedJournalHash: journalHash
                        ) {
                            try managedStateStore
                                .restoreOriginal(
                                    originalStateData,
                                    originalHash: stateHash,
                                    intendedHash:
                                        intendedStateHash
                                )
                        }
                } catch {
                    throw V011SwitchError.rollbackFailed(
                        "验证状态写入失败，原状态补偿也未完成"
                    )
                }
                throw primary
            case .foreign:
                throw V011SwitchError.rollbackFailed(
                    "验证状态写入期间出现并发修改，已禁止自动覆盖"
                )
            }
        }

        do {
            try currentConnectionVerifier.validate(
                verification,
                requireSavedRelayProfile: true
            )
            journal.acceptedCurrent =
                V011AcceptedCurrentRecord(
                    providerID: verification.providerID,
                    profileID: profileID,
                    configHash: verification.configHash,
                    verifiedAt: verification.verifiedAt
                )
            journal.phase = .acceptedCurrent
            journal.updatedAt = Date()
            journal.message =
                "已验证并保留当前中转，旧恢复事务已结束"
            return try store.commitAcceptedCurrent(
                journal,
                expectedJournalHash: journalHash
            )
        } catch let error as
            V011AcceptedJournalCommitIndeterminate {
            throw V011SwitchError.rollbackFailed(
                error.detail
            )
        } catch {
            let primary = error
            do {
                try store
                    .withOriginalJournalAndNoAcceptedArchive(
                        journalID: journal.id,
                        expectedJournalHash: journalHash
                    ) {
                        try managedStateStore.restoreOriginal(
                            originalStateData,
                            originalHash: stateHash,
                            intendedHash: intendedStateHash
                        )
                    }
            } catch {
                throw V011SwitchError.rollbackFailed(
                    "旧恢复事务未提交，验证状态补偿也未完成"
                )
            }
            throw primary
        }
    }

    private var sessionRecoveryRoot: URL {
        controlRoot.appendingPathComponent(
            "SessionCoreRecovery",
            isDirectory: true
        )
    }

}
