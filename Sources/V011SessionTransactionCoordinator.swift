// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011SessionTransactionCoordinator {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let versionDiscovery: any FableCodexVersionDiscovering
    let processController: any FableProcessController
    let sessionCore: any V011SessionCoreOperating
    let sessionRecoveryRoot: URL
    let sessionTransactionRoot: URL
    let managedStateStore: V011ManagedStateStore
    let sessionCancellationToken: V011SessionCancellationToken
    let faultInjector:
        @Sendable (V011SwitchFaultPoint) throws -> Void
    let progress: @Sendable (String) -> Void
    let coreFactory:
        (Set<String>, CodexVersionContract.Entry?) -> FableSwitchCore
    let captureOrigins: (V011ManagedState) async throws -> Void
    let prepareRecoveryRoot: () throws -> Void
    let markOriginsVisible: (String) throws -> Void

    private func makeCore(
        managedProviderIDs: Set<String>,
        resolvedContractEntry: CodexVersionContract.Entry?
    ) -> FableSwitchCore {
        coreFactory(managedProviderIDs, resolvedContractEntry)
    }

    private func captureSessionOrigins(
        managedState: V011ManagedState
    ) async throws {
        try await captureOrigins(managedState)
    }

    private func prepareSessionRecoveryRoot() throws {
        try prepareRecoveryRoot()
    }

    private func markSessionOriginsVisible(
        providerID: String
    ) throws {
        try markOriginsVisible(providerID)
    }

    func emptySessionSummary(
        targetProvider: String
    ) -> SessionCoreRepairSummary {
        SessionCoreRepairSummary(
            transactionID: nil,
            journalPath: nil,
            targetProvider: targetProvider,
            changedRolloutFiles: 0,
            changedSessionMetaRecords: 0,
            sqliteProviderRowsUpdated: 0,
            sqliteUserEventRowsUpdated: 0,
            sqliteCwdRowsUpdated: 0,
            noChanges: true
        )
    }

    func throwIfSessionCancellationRequested(
        phase: String
    ) throws {
        guard !sessionCancellationToken.isCancellationRequested else {
            throw V011SessionTransactionCancelled(stage: phase)
        }
    }

    func bindSessionReservationBeforeConfigurationWrite(
        journal: inout V011SwitchJournal,
        journalStore: V011SwitchJournalStore,
        key: Data
    ) throws {
        guard let configTransactionID = journal.configTransactionID,
              let historyPolicy = journal.historyPolicy else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let store = V011SessionTransactionReceiptStore(
            rootURL: sessionTransactionRoot
        )
        let intents = try store.openSupersedeIntents(
            supersededBy: configTransactionID
        )
        var reservationHash: String?
        var reservationID: String?
        if historyPolicy != .configOnly {
            let reservation = V011SessionTxnReservation(
                configTxnID: configTransactionID,
                targetProvider: journal.targetProvider,
                targetProfileID: journal.targetProfileID,
                targetConfigHash: journal.targetConfigHash,
                expectedSourceHash: journal.sourceConfigHash,
                historyPolicy: historyPolicy,
                createdAt: journal.startedAt
            )
            reservationHash = try store.saveReservation(
                reservation,
                expectedHash: nil
            )
            reservationID = reservation.id
            try faultInjector(.reservationWritten)
            let persistedReservation = try store.loadReservation(
                reservation.id
            )
            guard persistedReservation.schemaVersion
                    == reservation.schemaVersion,
                  persistedReservation.id == reservation.id,
                  persistedReservation.sessionTxnID
                    == reservation.sessionTxnID,
                  persistedReservation.configTxnID
                    == reservation.configTxnID,
                  persistedReservation.targetProvider
                    == reservation.targetProvider,
                  persistedReservation.targetProfileID
                    == reservation.targetProfileID,
                  persistedReservation.targetConfigHash
                    == reservation.targetConfigHash,
                  persistedReservation.expectedSourceHash
                    == reservation.expectedSourceHash,
                  persistedReservation.historyPolicy
                    == reservation.historyPolicy,
                  persistedReservation.state == reservation.state,
                  persistedReservation.expectedReservationHash
                    == reservation.expectedReservationHash,
                  try store.reservationHash(reservation.id)
                    == reservationHash else {
                throw V011SwitchError.concurrentConfigurationChange
            }
        }
        guard reservationID != nil || !intents.isEmpty else {
            return
        }
        journal.reservationID = reservationID
        journal.reservationHash = reservationHash
        journal.supersedeIntents = intents
        journal.updatedAt = Date()
        journal.message = "已绑定会话事务预留和旧回执意图"
        try V011SwitchStateEvidenceAuthenticator.seal(
            &journal,
            key: key
        )
        try journalStore.save(journal)
        _ = try journalStore.journalHash(journal.id)
        let bound = try journalStore.load(journal.id)
        guard bound.reservationID == reservationID,
              bound.reservationHash == reservationHash,
              bound.supersedeIntents == intents else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        try faultInjector(.reservationBound)
        if let reservationID, let reservationHash {
            guard try store.reservationHash(reservationID)
                    == reservationHash else {
                throw V011SwitchError.concurrentConfigurationChange
            }
        }
        for intent in intents {
            guard try store.hash(intent.receiptID)
                    == intent.expectedReceiptHash else {
                throw V011SwitchError.concurrentConfigurationChange
            }
        }
    }

    func discardUnmaterializedReservationIfNeeded(
        _ journal: V011SwitchJournal
    ) throws {
        guard journal.historyPolicy != nil,
              journal.historyPolicy != .configOnly,
              journal.configTransactionPhase != .committed,
              let configTransactionID = journal.configTransactionID else {
            return
        }
        let reservationID = journal.reservationID
            ?? V011SessionTxnReservation.sessionTransactionID(
                forConfigTransactionID: configTransactionID
            )
        try V011SessionTransactionReceiptStore(
            rootURL: sessionTransactionRoot
        ).discardUnmaterializedReservation(
            reservationID,
            configTransactionID: configTransactionID
        )
    }

    @discardableResult
    func reconcileCommittedSessionTransactions()
        -> V011SessionReconciliationSummary {
        let journalStore = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        let store = V011SessionTransactionReceiptStore(
            rootURL: sessionTransactionRoot
        )
        var summary = V011SessionReconciliationSummary()
        do {
            summary.receiptConflictIDs.append(
                contentsOf: try store.scan().conflictIDs
            )
        } catch {
            return summary
        }
        guard let journals = try? journalStore
                .committedSessionTransactions() else {
            return summary
        }
        for journal in journals {
            let result = reconcileCommittedSessionTransaction(
                journal,
                store: store,
                at: Date()
            )
            if result.materialized,
               let receipt = result.receipt {
                summary.materializedReceiptIDs.append(receipt.id)
            }
            summary.receiptConflictIDs.append(
                contentsOf: result.conflictIDs
            )
        }
        summary.materializedReceiptIDs = Array(
            Set(summary.materializedReceiptIDs)
        ).sorted()
        summary.receiptConflictIDs = Array(
            Set(summary.receiptConflictIDs)
        ).sorted()
        return summary
    }

    /// Request cancellation for the currently materialized SessionTxn. The
    /// token stops the next safe boundary in this coordinator while the CAS
    /// receipt makes the request restart-safe for a fresh coordinator.
    @discardableResult
    func cancelSessionTransaction(
        receiptID: String,
        expectedReceiptHash: String,
        reason: String = "userRequested"
    ) throws -> V011SessionTransactionReceipt {
        sessionCancellationToken.cancel()
        let store = V011SessionTransactionReceiptStore(
            rootURL: sessionTransactionRoot
        )
        return try store.cancel(
            receiptID,
            expectedHash: expectedReceiptHash,
            reason: reason
        )
    }

    /// Re-open a retryable receipt after checking the live config/provider/
    /// profile identity. The returned receipt is the sole durable authority;
    /// a subsequent coordinator may use its monotonically incremented attempt
    /// to execute the existing SessionCore repair path.
    @discardableResult
    func resumeSessionTransaction(
        _ request: V011SessionResumeRequest
    ) throws -> V011SessionTransactionReceipt {
        let store = V011SessionTransactionReceiptStore(
            rootURL: sessionTransactionRoot
        )
        let current = try currentSessionResumeRequest(
            request,
            store: store
        )
        let receipt = try store.resume(current)
        sessionCancellationToken.reset()
        return receipt
    }

    /// Re-read the live configuration and managed profile immediately before
    /// a resume. Caller-supplied hashes are evidence cross-checks only; they
    /// never substitute for this writer-owned observation.
    private func currentSessionResumeRequest(
        _ request: V011SessionResumeRequest,
        store: V011SessionTransactionReceiptStore
    ) throws -> V011SessionResumeRequest {
        let receipt = try store.load(request.receiptID)
        let installation = try versionDiscovery.discover()
        guard let contract = installation.contractEntry,
              contract.matches(installation.identity),
              case let .verified(schemaID) = installation.support,
              schemaID == contract.schemaID else {
            throw V011SessionTransactionControlError.staleConfiguration
        }
        let managed = try managedStateStore.load()
        let core = makeCore(
            managedProviderIDs: managedProviderIDs.union(
                managed.managedProviderIDSet
            ),
            resolvedContractEntry: contract
        )
        let live = try core.inspect(version: installation.identity)
        let liveProvider: String
        switch live.mode {
        case .official:
            liveProvider = "openai"
        case let .relay(providerID):
            liveProvider = providerID
        }
        guard liveProvider == receipt.targetProvider,
              liveProvider == request.currentProvider else {
            throw V011SessionTransactionControlError.providerDrift
        }
        guard live.configHash == receipt.configHash,
              live.configHash == request.currentConfigHash else {
            throw V011SessionTransactionControlError.staleConfiguration
        }
        let liveProfileID: String?
        if let profileID = receipt.targetProfileID {
            guard let profile = managed.relayProfiles.first(where: {
                $0.id == profileID
                    && $0.v011ProviderID == liveProvider
            }),
            V011RelaySemanticMatcher.matches(
                live: live,
                profile: profile
            ),
            live.provider?.displayName
                == profile.fableProfile.providerConfigurationName else {
                throw V011SessionTransactionControlError.profileDrift
            }
            liveProfileID = profileID
        } else {
            guard liveProvider == "openai" else {
                throw V011SessionTransactionControlError.profileDrift
            }
            liveProfileID = nil
        }
        let profileHash = V011SessionTransactionReceiptStore.profileHash(
            provider: liveProvider,
            profileID: liveProfileID
        )
        guard liveProfileID == request.currentProfileID,
              profileHash == request.currentProfileHash else {
            throw V011SessionTransactionControlError.profileDrift
        }
        return V011SessionResumeRequest(
            receiptID: request.receiptID,
            expectedReceiptHash: request.expectedReceiptHash,
            currentConfigHash: live.configHash,
            currentProvider: liveProvider,
            currentProfileID: liveProfileID,
            currentProfileHash: profileHash
        )
    }

    private func reconcileCommittedSessionTransaction(
        _ journal: V011SwitchJournal,
        store: V011SessionTransactionReceiptStore,
        at date: Date
    ) -> (
        receipt: V011SessionTransactionReceipt?,
        materialized: Bool,
        conflictIDs: [String]
    ) {
        guard journal.phase == .committed,
              journal.configTransactionPhase == .committed else {
            return (nil, false, [])
        }
        var materialized = false
        var receipt: V011SessionTransactionReceipt?
        var conflicts: [String] = []
        if let reservationID = journal.reservationID,
           let reservationHash = journal.reservationHash {
            do {
                var reservation = try store.loadReservation(
                    reservationID
                )
                guard reservation.configTxnID
                        == journal.configTransactionID,
                      reservation.targetProvider
                        == journal.targetProvider,
                      reservation.targetProfileID
                        == journal.targetProfileID,
                      reservation.targetConfigHash
                        == journal.targetConfigHash,
                      reservation.expectedSourceHash
                        == journal.sourceConfigHash,
                      reservation.historyPolicy
                        == journal.historyPolicy else {
                    throw V011SwitchError.invalidRecoveryJournal
                }
                switch reservation.state {
                case .reserved:
                    guard try store.reservationHash(reservationID)
                            == reservationHash else {
                        throw V011SwitchError
                            .concurrentConfigurationChange
                    }
                    reservation.state = .committed
                    reservation.expectedReservationHash =
                        reservationHash
                    reservation.updatedAt = date
                    _ = try store.saveReservation(
                        reservation,
                        expectedHash: reservationHash
                    )
                case .committed:
                    guard reservation.expectedReservationHash
                            == reservationHash else {
                        throw V011SwitchError
                            .concurrentConfigurationChange
                    }
                }
                let committedReservation = try store
                    .loadReservation(reservationID)
                guard committedReservation.state == .committed,
                      committedReservation.expectedReservationHash
                        == reservationHash else {
                    throw V011SwitchError.invalidRecoveryJournal
                }
                if let existingHash = try store.hashIfPresent(
                    reservationID
                ) {
                    var existing = try store.load(reservationID)
                    guard existing.id
                            == committedReservation.sessionTxnID,
                          existing.configTransactionID
                            == committedReservation.configTxnID,
                          existing.configHash
                            == committedReservation.targetConfigHash,
                          existing.targetProvider
                            == committedReservation.targetProvider,
                          existing.targetProfileID
                            == committedReservation.targetProfileID,
                          existing.historyPolicy
                            == committedReservation.historyPolicy else {
                        throw V011SwitchError.invalidRecoveryJournal
                    }
                    if existing.expectedReceiptHash == nil {
                        guard existing.phase == .notStarted,
                              existing.attempt == 0,
                              existing.createdAt
                                == committedReservation.createdAt,
                              existing.failureCode == nil,
                              existing.failureStage == nil,
                              existing.nextAction == nil,
                              existing.supersededBy == nil,
                              existing.estimatedJournalBytes == nil,
                              existing.actualJournalBytes == nil,
                              existing.journalLimitBytes == nil,
                              existing.rolloutFileCount == nil,
                              existing.patchCount == nil,
                              existing.estimateVersion == nil,
                              existing.recoveryID
                                == committedReservation.sessionTxnID
                                    .lowercased() else {
                            throw V011SwitchError.invalidRecoveryJournal
                        }
                        existing.expectedReceiptHash = reservationHash
                        existing.updatedAt = date
                        let healedHash = try store.saveLegacyAnchorHeal(
                            existing,
                            expectedHash: existingHash
                        )
                        let healed = try store.load(existing.id)
                        guard try store.hash(existing.id) == healedHash,
                              healed.expectedReceiptHash
                                == reservationHash else {
                            throw V011SwitchError.invalidRecoveryJournal
                        }
                        receipt = healed
                        materialized = true
                    } else {
                        receipt = existing
                    }
                } else {
                    let candidate = V011SessionTransactionReceipt(
                        id: committedReservation.sessionTxnID,
                        configTransactionID:
                            committedReservation.configTxnID,
                        configHash:
                            committedReservation.targetConfigHash,
                        targetProvider:
                            committedReservation.targetProvider,
                        targetProfileID:
                            committedReservation.targetProfileID,
                        historyPolicy:
                            committedReservation.historyPolicy,
                        phase: .notStarted,
                        attempt: 0,
                        createdAt: committedReservation.createdAt,
                        updatedAt: date,
                        expectedReceiptHash: reservationHash,
                        recoveryID:
                            committedReservation.sessionTxnID
                                .lowercased()
                    )
                    let candidateHash = try store.save(
                        candidate,
                        expectedHash: nil
                    )
                    let persisted = try store.load(candidate.id)
                    guard try store.hash(candidate.id) == candidateHash,
                          persisted.id
                            == committedReservation.sessionTxnID,
                          persisted.configTransactionID
                            == committedReservation.configTxnID,
                          persisted.configHash
                            == committedReservation.targetConfigHash,
                          persisted.targetProvider
                            == committedReservation.targetProvider,
                          persisted.targetProfileID
                            == committedReservation.targetProfileID,
                          persisted.historyPolicy
                            == committedReservation.historyPolicy,
                          persisted.phase == .notStarted,
                          persisted.attempt == 0,
                          persisted.createdAt
                            == committedReservation.createdAt,
                          persisted.expectedReceiptHash
                            == reservationHash,
                          persisted.failureCode == nil,
                          persisted.failureStage == nil,
                          persisted.nextAction == nil,
                          persisted.supersededBy == nil,
                          persisted.recoveryID
                            == committedReservation.sessionTxnID
                                .lowercased() else {
                        throw V011SwitchError.invalidRecoveryJournal
                    }
                    receipt = persisted
                    materialized = true
                }
            } catch {
                conflicts.append(reservationID)
            }
        }
        for intent in journal.supersedeIntents ?? [] {
            do {
                var old = try store.load(intent.receiptID)
                if old.phase == .superseded,
                   old.supersededBy != nil {
                    continue
                }
                guard try store.hash(intent.receiptID)
                        == intent.expectedReceiptHash,
                      old.isOpen else {
                    conflicts.append(intent.receiptID)
                    continue
                }
                old.phase = .superseded
                old.supersededBy = intent.supersededBy
                old.failureCode = nil
                old.failureStage = nil
                old.nextAction = nil
                old.expectedReceiptHash = intent.expectedReceiptHash
                old.updatedAt = date
                let savedHash = try store.saveSuperseded(
                    old,
                    expectedHash: intent.expectedReceiptHash,
                    intent: intent
                )
                guard try store.hash(old.id) == savedHash else {
                    throw V011SwitchError.invalidRecoveryJournal
                }
            } catch {
                conflicts.append(intent.receiptID)
            }
        }
        // receiptConflict is a presentation-only overlay. Neither the newly
        // materialized receipt nor the conflicting predecessor is rewritten.
        return (receipt, materialized, Array(Set(conflicts)).sorted())
    }

    func performPostCommitSessionTransaction(
        journal: V011SwitchJournal,
        managedState: V011ManagedState,
        journalKey: Data,
        fallbackSummary: SessionCoreRepairSummary
    ) async throws -> V011PostCommitSessionResult {
        let store = V011SessionTransactionReceiptStore(
            rootURL: sessionTransactionRoot
        )
        let reconciliation = reconcileCommittedSessionTransaction(
            journal,
            store: store,
            at: Date()
        )
        guard journal.historyPolicy != .configOnly else {
            return V011PostCommitSessionResult(
                summary: fallbackSummary,
                receipt: nil
            )
        }
        guard var receipt = reconciliation.receipt else {
            let now = Date()
            let id = journal.reservationID
                ?? V011SessionTxnReservation.sessionTransactionID(
                    forConfigTransactionID: journal.id
                )
            return V011PostCommitSessionResult(
                summary: fallbackSummary,
                receipt: V011SessionTransactionReceipt(
                    id: id,
                    configTransactionID: journal.id,
                    configHash: journal.targetConfigHash,
                    targetProvider: journal.targetProvider,
                    targetProfileID: journal.targetProfileID,
                    historyPolicy: journal.historyPolicy ?? .deferred,
                    phase: .retryableFailure,
                    attempt: 0,
                    createdAt: journal.startedAt,
                    updatedAt: now,
                    failureCode: .receiptConflict,
                    failureStage: "reservationMaterialize",
                    nextAction: "reviewReceiptConflict",
                    recoveryID: id.lowercased()
                )
            )
        }
        guard receipt.expectedReceiptHash != nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        try faultInjector(.receiptMaterialized)
        guard journal.historyPolicy == .runAfterCommit else {
            return V011PostCommitSessionResult(
                summary: fallbackSummary,
                receipt: receipt
            )
        }
        let sessionTransactionID = receipt.id
        let targetProvider = journal.targetProvider
        do {
            var receiptHash = try store.hash(receipt.id)
            if sessionCancellationToken.isCancellationRequested {
                let cancelled = try store.cancel(
                    receipt.id,
                    expectedHash: receiptHash,
                    reason: "beforeSessionWrite"
                )
                return V011PostCommitSessionResult(
                    summary: fallbackSummary,
                    receipt: cancelled
                )
            }
            receipt.phase = .prepared
            receipt.failureCode = nil
            receipt.failureStage = nil
            receipt.nextAction = nil
            receipt.expectedReceiptHash = receiptHash
            receipt.updatedAt = Date()
            receiptHash = try store.save(
                receipt,
                expectedHash: receiptHash
            )
            let inspection = try await sessionCore.inspect(
                codexHome: codexHome,
                provider: targetProvider
            )
            receipt.estimatedJournalBytes =
                inspection.estimatedJournalBytes
            receipt.journalLimitBytes =
                inspection.journalLimitBytes
            receipt.rolloutFileCount = inspection.rolloutFiles
            receipt.patchCount = inspection.rolloutPatchCount
            receipt.estimateVersion = 1
            receipt.expectedReceiptHash = receiptHash
            receipt.updatedAt = Date()

            guard let estimatedBytes =
                    inspection.estimatedJournalBytes,
                  let limitBytes = inspection.journalLimitBytes,
                  inspection.capacitySafe == true,
                  estimatedBytes <= limitBytes else {
                receipt.phase = .retryableFailure
                receipt.failureCode = .journalCapacityExceeded
                receipt.failureStage = "capacityPreflight"
                receipt.nextAction = "retryOrSkip"
                receiptHash = try store.save(
                    receipt,
                    expectedHash: receiptHash
                )
                return V011PostCommitSessionResult(
                    summary: fallbackSummary,
                    receipt: receipt
                )
            }

            if sessionCancellationToken.isCancellationRequested {
                let cancelled = try store.cancel(
                    receipt.id,
                    expectedHash: receiptHash,
                    reason: "afterCapacityPreflight"
                )
                return V011PostCommitSessionResult(
                    summary: fallbackSummary,
                    receipt: cancelled
                )
            }

            if !inspection.needsRepair {
                receipt.phase = .committed
                receipt.failureCode = nil
                receipt.failureStage = nil
                receipt.nextAction = nil
                receipt.expectedReceiptHash = receiptHash
                receiptHash = try store.save(
                    receipt,
                    expectedHash: receiptHash
                )
                return V011PostCommitSessionResult(
                    summary: fallbackSummary,
                    receipt: receipt
                )
            }

            if let interrupted = try await sessionCore
                .interruptedJournal(
                    codexHome: codexHome,
                    recoveryRoot: sessionRecoveryRoot
                ) {
                _ = interrupted
                receipt.phase = .retryableFailure
                receipt.failureCode = .pendingSessionRecovery
                receipt.failureStage = "sessionPreflight"
                receipt.nextAction = "retry"
                receipt.expectedReceiptHash = receiptHash
                receiptHash = try store.save(
                    receipt,
                    expectedHash: receiptHash
                )
                return V011PostCommitSessionResult(
                    summary: fallbackSummary,
                    receipt: receipt
                )
            }

            receipt.phase = .running
            receipt.attempt = 1
            receipt.failureCode = nil
            receipt.failureStage = nil
            receipt.nextAction = nil
            receipt.expectedReceiptHash = receiptHash
            receipt.updatedAt = Date()
            receiptHash = try store.save(
                receipt,
                expectedHash: receiptHash
            )

            if sessionCancellationToken.isCancellationRequested {
                let cancelled = try store.cancel(
                    receipt.id,
                    expectedHash: receiptHash,
                    reason: "beforeSessionRepair"
                )
                return V011PostCommitSessionResult(
                    summary: fallbackSummary,
                    receipt: cancelled
                )
            }

            progress("设置已提交，正在独立整理历史会话")
            try processController.stopConfigurationWriters()
            try await captureSessionOrigins(
                managedState: managedState
            )
            try prepareSessionRecoveryRoot()
            let expectedJournal = sessionRecoveryRoot
                .appendingPathComponent(
                    sessionTransactionID.lowercased(),
                    isDirectory: true
                )
                .standardizedFileURL
            let summary = try await sessionCore.repair(
                codexHome: codexHome,
                provider: targetProvider,
                recoveryRoot: sessionRecoveryRoot,
                transactionID: sessionTransactionID.lowercased(),
                journalKey: journalKey,
                progress: { event in
                    progress(
                        "正在整理历史会话 \(event.current)/\(event.total)"
                    )
                }
            )
            if sessionCancellationToken.isCancellationRequested {
                let cancelled = try store.cancel(
                    receipt.id,
                    expectedHash: receiptHash,
                    reason: "afterSessionRepairBoundary"
                )
                return V011PostCommitSessionResult(
                    summary: summary,
                    receipt: cancelled
                )
            }
            if summary.noChanges {
                guard summary.transactionID == nil,
                      summary.journalPath == nil else {
                    throw V011SwitchError.invalidRecoveryJournal
                }
                receipt.recoveryID = nil
            } else {
                guard summary.transactionID
                        == sessionTransactionID.lowercased(),
                      let journalPath = summary.journalPath,
                      URL(fileURLWithPath: journalPath)
                        .standardizedFileURL == expectedJournal else {
                    throw V011SwitchError.invalidRecoveryJournal
                }
                receipt.actualJournalBytes =
                    sessionJournalSize(expectedJournal)
            }
            // Persist progress/size before the next cancellation boundary so
            // an archive or restart retains diagnostic evidence.
            receipt.expectedReceiptHash = receiptHash
            receipt.updatedAt = Date()
            receiptHash = try store.save(
                receipt,
                expectedHash: receiptHash
            )
            try markSessionOriginsVisible(
                providerID: targetProvider
            )
            try faultInjector(.sessionsWritten)
            if sessionCancellationToken.isCancellationRequested {
                let cancelled = try store.cancel(
                    receipt.id,
                    expectedHash: receiptHash,
                    reason: "midPlanCancellation"
                )
                return V011PostCommitSessionResult(
                    summary: summary,
                    receipt: cancelled
                )
            }
            try processController.relaunchCodex()
            receipt.phase = .committed
            receipt.failureCode = nil
            receipt.failureStage = nil
            receipt.nextAction = nil
            receipt.expectedReceiptHash = receiptHash
            receipt.updatedAt = Date()
            _ = try store.save(
                receipt,
                expectedHash: receiptHash
            )
            return V011PostCommitSessionResult(
                summary: summary,
                receipt: receipt
            )
        } catch {
            try? processController.relaunchCodex()
            if error is V011SessionTransactionCancelled {
                do {
                    let currentHash = try store.hash(receipt.id)
                    let cancelled = try store.cancel(
                        receipt.id,
                        expectedHash: currentHash,
                        reason: "cooperativeCancellation"
                    )
                    return V011PostCommitSessionResult(
                        summary: fallbackSummary,
                        receipt: cancelled
                    )
                } catch {
                    // Preserve the original durable receipt if cancellation
                    // races with another writer; never enter config rollback.
                    receipt.failureCode = .receiptConflict
                }
            }
            receipt.phase = .retryableFailure
            receipt.failureCode = sessionFailureCode(error)
            receipt.failureStage = "sessionRepair"
            receipt.nextAction = "retry"
            receipt.updatedAt = Date()
            do {
                let currentHash = try store.hash(receipt.id)
                receipt.expectedReceiptHash = currentHash
                _ = try store.save(
                    receipt,
                    expectedHash: currentHash
                )
            } catch {
                receipt.failureCode = .receiptConflict
            }
            return V011PostCommitSessionResult(
                summary: fallbackSummary,
                receipt: receipt
            )
        }
    }

    private func sessionJournalSize(_ directory: URL) -> UInt64? {
        let manifest = directory.appendingPathComponent("journal.json")
        guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: manifest.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    private func sessionFailureCode(
        _ error: Error
    ) -> V011SessionFailureCode {
        if let clientError = error as? SessionCoreClientError,
           case let .commandFailed(_, code, _) = clientError,
           code == "journal_too_large" {
            return .journalCapacityExceeded
        }
        return .sessionRepairFailed
    }
}
