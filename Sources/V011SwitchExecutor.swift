// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011SwitchExecutor: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let versionDiscovery: any FableCodexVersionDiscovering
    let defaultHistoryPolicy: V011HistoryPolicy
    let progress: @Sendable (String) -> Void
    let preExecutionPreparation:
        @Sendable () throws -> Void
    let prePlanHook: @Sendable () throws -> Void
    let faultInjector:
        @Sendable (V011SwitchFaultPoint) throws -> Void
    let managedStateStore: V011ManagedStateStore
    let originLedgerStore: V011SessionOriginLedgerStore
    let managedStateBaselineService:
        V011ManagedStateBaselineService
    let capabilityProfileService:
        V011CapabilityProfileService
    let sessionTransactionCoordinator:
        V011SessionTransactionCoordinator
    let recoveryDecisionService:
        V011RecoveryDecisionService
    let recoverySnapshotService:
        V011RecoverySnapshotService
    let journalWriter: V011SwitchJournalWriter
    let coreFactory:
        (Set<String>, CodexVersionContract.Entry?) -> FableSwitchCore

    func execute(
        destination: FableSwitchDestination,
        capabilityUpdate: V011CapabilityProfileUpdate? = nil,
        historyPolicy: V011HistoryPolicy? = nil
    ) async throws -> V011SwitchResult {
        // A managed-profile update keeps the same Provider identity. It may
        // change live Codex defaults, but it never needs to relabel history.
        // Keep the protected config transaction and controlled relaunch while
        // avoiding the expensive SessionCore scan/write path used by a real
        // route switch.
        let relabelsSessions = capabilityUpdate == nil
        let effectiveHistoryPolicy = capabilityUpdate == nil
            ? (historyPolicy ?? defaultHistoryPolicy)
            : .configOnly
        let journalStore = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        // Reconcile only committed ConfigTxn records. Receipt conflicts are a
        // separate session-domain outcome and never block a later cutover.
        _ = sessionTransactionCoordinator.reconcileCommittedSessionTransactions()
        guard try journalStore.pendingConfigCutover().isEmpty else {
            throw V011SwitchError.pendingRecovery
        }
        progress("正在核对Codex版本和当前模式")
        let installation = try versionDiscovery.discover()
        guard let resolvedContractEntry =
                installation.contractEntry,
              resolvedContractEntry.matches(
                  installation.identity
              ),
              case let .verified(discoveredSchemaID) =
                installation.support,
              discoveredSchemaID
                == resolvedContractEntry.schemaID else {
            throw FableSwitchError.unsupportedVersion
        }
        let versionContractID = resolvedContractEntry.schemaID
        var managedState = try managedStateStore.load()
        let initialTarget = try validatedSwitchTarget(
            destination: destination,
            managedState: managedState,
            capabilityUpdate: capabilityUpdate,
            expectedCodexContractID:
                versionContractID
        )
        if let relayProfile = initialTarget.relayProfile {
            progress(
                "正在写入前验证模型目录、认证和最小Responses请求"
            )
            try await capabilityProfileService.verifyRelayPreflight(relayProfile)
        }
        try preExecutionPreparation()
        try sessionTransactionCoordinator.throwIfSessionCancellationRequested(
            phase: "beforeConfigurationWrite"
        )
        let managedStateBaseline = try
            managedStateBaselineService.capture()
        managedState = managedStateBaseline.state
        let preparedTarget = try validatedSwitchTarget(
            destination: destination,
            managedState: managedState,
            capabilityUpdate: capabilityUpdate,
            expectedCodexContractID:
                versionContractID
        )
        guard preparedTarget == initialTarget else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let targetProfileID = preparedTarget.profileID
        let effectiveManagedProviderIDs =
            managedProviderIDs.union(
                managedState.managedProviderIDSet
            )
        let core = makeCore(
            managedProviderIDs:
                effectiveManagedProviderIDs,
            resolvedContractEntry:
                resolvedContractEntry
        )
        let sourceState = try core.inspect(
            version: installation.identity
        )
        if let capabilityUpdate {
            guard V011RelaySemanticMatcher.matches(
                    live: sourceState,
                    profile: capabilityUpdate.sourceProfile
                  ) else {
                throw V011SwitchError.currentRelayChanged
            }
        } else if case let .relay(providerID) = sourceState.mode,
           effectiveManagedProviderIDs.contains(providerID) {
            guard let profile = managedState.relayProfiles
                    .first(where: {
                        $0.v011ProviderID == providerID
                    }),
                  V011RelaySemanticMatcher.matches(
                    live: sourceState,
                    profile: profile
                  ) else {
                throw V011SwitchError.currentRelayChanged
            }
        }
        var trustedOfficialRootOverlay =
            managedState.officialRootOverlay?
                .trustedOverlay(
                    forAny: CodexVersionContract
                        .compatibleSchemaIDs(
                            for: versionContractID
                        )
                )
        if case .official = sourceState.mode {
            let captured = try core
                .captureOfficialRootOverlay(
                    version: installation.identity,
                    expectedConfigHash:
                        sourceState.configHash
                )
            managedState.officialRootOverlay =
                V011OfficialRootOverlayRecord(
                    overlay: captured,
                    capturedFromConfigHash:
                        sourceState.configHash,
                    capturedAt: Date(),
                    versionContractSchemaID:
                        versionContractID
                )
            trustedOfficialRootOverlay = captured
        }
        try prePlanHook()
        let plan = try core.makePlan(
            destination: destination,
            version: installation.identity,
            officialRootOverlay:
                trustedOfficialRootOverlay
        )
        guard plan.sourceHash == sourceState.configHash else {
            throw V011SwitchError.currentRelayChanged
        }
        let prepared = try core.prepareConfiguration(
            plan,
            version: installation.identity
        )
        let cutoverCandidate = try V011CutoverCandidateBuilder.make(
            prepared: prepared,
            target: preparedTarget,
            destination: destination,
            versionContractID: versionContractID,
            changesRoute: relabelsSessions
        )
        try FableCutoverSafetyPolicy.requireReady(
            cutoverCandidate
        )
        let permissions = prepared.originalData == nil
            ? 0o600 : recoverySnapshotService.filePermissions(prepared.configURL)
        let originLedgerExisted =
            FileManager.default.fileExists(
                atPath: originLedgerStore.fileURL.path
            )
        var snapshotInputs = prepared.originalData.map {
            [
                SnapshotInput(
                    relativePath: "config.toml",
                    data: $0,
                    permissions: permissions
                ),
            ]
        } ?? []
        snapshotInputs.append(
            SnapshotInput(
                relativePath:
                    "assistant/v011-target-config.toml",
                data: prepared.proposedData,
                permissions: 0o600
            )
        )
        if let stateData = managedStateBaseline.data {
            snapshotInputs.append(
                SnapshotInput(
                    relativePath:
                        "assistant/v011-state.json",
                    data: stateData,
                    permissions: recoverySnapshotService.filePermissions(
                        managedStateStore.fileURL
                    )
                )
            )
        }
        try recoverySnapshotService.appendSnapshotInputIfPresent(
            url: originLedgerStore.fileURL,
            relativePath:
                "assistant/session-origin-ledger.vault",
            inputs: &snapshotInputs
        )
        try managedStateBaselineService.requireCurrent(
            managedStateBaseline
        )
        let key = try journalWriter.validatedKey()
        let vault = SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchConfigVault",
                isDirectory: true
            ),
            keyProvider: { key }
        )
        let snapshot = try vault.saveSnapshot(
            profileID: "switch-\(UUID().uuidString)",
            adapterVersion: versionContractID,
            inputs: snapshotInputs
        )
        let targetProvider = V011CutoverCandidateBuilder.providerID(for: destination)
        let configTransactionID = UUID().uuidString
        var journal = V011SwitchJournal(
            version: 1,
            id: configTransactionID,
            codexHomePath: codexHome.path,
            sourceConfigHash: prepared.originalHash,
            sourceConfigExisted: prepared.originalExisted,
            targetConfigHash: prepared.proposedHash,
            targetProvider: targetProvider,
            targetProfileID: targetProfileID,
            configSnapshot: snapshot,
            stateExisted: managedStateBaseline.existed,
            originLedgerExisted:
                originLedgerExisted,
            startedAt: Date(),
            updatedAt: Date(),
            phase: .prepared,
            sessionJournalPath: nil,
            message: "已建立加密恢复点",
            stateCASManaged: true,
            sourceManagedStateHash: managedStateBaseline.hash,
            targetManagedStateHash: nil,
            configTransactionID: configTransactionID,
            configTransactionPhase: .prepared,
            historyPolicy: effectiveHistoryPolicy
        )
        try V011SwitchStateEvidenceAuthenticator.seal(
            &journal,
            key: key
        )
        try journalStore.save(journal)

        do {
            try sessionTransactionCoordinator.bindSessionReservationBeforeConfigurationWrite(
                journal: &journal,
                journalStore: journalStore,
                key: key
            )
        } catch {
            if let cancellation = error
                as? V011SessionTransactionCancelled,
               journal.configTransactionPhase == .prepared {
                // Cancel-before-write has no live configuration side effect;
                // close only the candidate journal/reservation and preserve
                // the existing config untouched.
                try? journalWriter.update(
                    &journal,
                    phase: .rolledBack,
                    message: "用户在配置写入前取消；当前设置未改变",
                    store: journalStore
                )
                try? sessionTransactionCoordinator
                    .discardUnmaterializedReservationIfNeeded(journal)
                throw cancellation
            }
            if error is V011SimulatedProcessExit {
                throw error
            }
            recoveryDecisionService.applyPrimaryFailureContext(
                error,
                phase: journal.phase,
                to: &journal
            )
            try? journalWriter.update(
                &journal,
                phase: .rolledBack,
                message: "会话事务预留未通过；配置未写入",
                store: journalStore
            )
            try sessionTransactionCoordinator
                .discardUnmaterializedReservationIfNeeded(journal)
            throw error
        }

        var sessionSummary: SessionCoreRepairSummary?
        var committedState: LiveCodexState?
        do {
            try faultInjector(.prepared)
            progress("正在正常关闭Codex和配置工具")
            try processController.stopConfigurationWriters()

            progress("正在提交目标设置")

            try sessionTransactionCoordinator.throwIfSessionCancellationRequested(
                phase: "beforeConfigurationWrite"
            )

            progress("正在切换当前模式")
            _ = try core.applyPreparedConfiguration(prepared)
            journal.configTransactionPhase = .configWritten
            try journalWriter.update(
                &journal,
                phase: .configWritten,
                message: "目标配置已原子写入",
                store: journalStore
            )
            try faultInjector(.configWritten)

            sessionSummary = sessionTransactionCoordinator.emptySessionSummary(
                targetProvider: targetProvider
            )

            progress("正在重新打开Codex")
            try processController.relaunchCodex()
            try journalWriter.update(
                &journal,
                phase: .codexLaunched,
                message: "Codex已重新打开",
                store: journalStore
            )
            try faultInjector(.codexLaunched)

            progress("正在用Codex发送最小验证请求")
            switch destination {
            case .official:
                try runtimeVerifier.verifyOfficial()
            case let .relay(profile):
                try runtimeVerifier.verifyRelay(profile)
            }
            journal.configTransactionPhase = .verified
            try journalWriter.update(
                &journal,
                phase: .verified,
                message: "Codex最小请求已通过",
                store: journalStore
            )
            try faultInjector(.verified)
            let state = try core.inspect(
                version: installation.identity
            )
            var targetManagedState = managedState
            if let capabilityUpdate {
                targetManagedState.upsert(
                    capabilityUpdate.targetProfile
                )
            }
            guard try recoveryDecisionService.targetConfigurationMatches(
                journal: journal,
                live: state,
                managedState: targetManagedState,
                versionContractID: versionContractID
            ) else {
                throw V011SwitchError.currentRelayChanged
            }
            managedState = targetManagedState
            managedState.activeProfileID =
                targetProfileID
            managedState.lastSuccessfulSwitchID =
                journal.id
            managedState.lastVerifiedConfigHash =
                state.configHash
            managedState.lastVerifiedProviderID =
                targetProvider
            managedState.lastVerifiedAt = Date()
            try V011CutoverPromotionRecorder.record(
                state: &managedState,
                providerID: targetProvider,
                profileID: targetProfileID,
                modelID: state.model,
                configHash: state.configHash,
                capabilityContract: versionContractID,
                transactionID: journal.id,
                verifiedAt: managedState.lastVerifiedAt
                    ?? Date()
            )
            if case .official = destination {
                managedState.officialBaseline =
                    V011OfficialBaselineRecord(
                        configHash: state.configHash,
                        verifiedAt:
                            managedState.lastVerifiedAt
                                ?? Date(),
                        switchTransactionID: journal.id,
                        providerID: "openai",
                        versionContractSchemaID:
                            versionContractID
                    )
            }
            let targetManagedStateData = try managedStateStore
                .preparedData(for: managedState)
            journal.targetManagedStateHash =
                TOMLSemanticEngine.sha256(
                    targetManagedStateData
                )
            journal.updatedAt = Date()
            journal.message = "正在提交受管状态"
            try V011SwitchStateEvidenceAuthenticator.seal(
                &journal,
                key: key
            )
            try journalStore.save(journal)
            try managedStateStore.writePrepared(
                targetManagedStateData,
                expectedCurrentHash: managedStateBaseline.hash
            )
            try faultInjector(.beforeCommit)
            journal.configTransactionPhase = .committed
            try journalWriter.update(
                &journal,
                phase: .committed,
                message: relabelsSessions
                    ? "目标设置和连接验证已完成"
                    : "同轨设置和连接验证均已完成",
                store: journalStore
            )
            try journalStore.archiveCommittedKeepingLatest()
            committedState = state
        } catch {
            if error is V011SimulatedProcessExit {
                throw error
            }
            let primary = error
            do {
                recoveryDecisionService.applyPrimaryFailureContext(
                    primary,
                    phase: journal.phase,
                    to: &journal
                )
                journal.protectsPostSwitchSessions = true
                try journalWriter.update(
                    &journal,
                    phase: .rollbackRequired,
                    message: recoveryDecisionService.recoveryPreparationMessage(
                        forwardFailure: primary
                    ),
                    store: journalStore
                )
                try processController.stopConfigurationWriters()
                let recovery = try recoverySnapshotService.prepare(
                    journal: journal,
                    vault: vault
                )
                try recoverySnapshotService.apply(recovery)
                try processController.relaunchCodex()
                try journalWriter.update(
                    &journal,
                    phase: .rolledBack,
                    message: recoveryDecisionService.recoveryCompletedMessage(
                        sessionRollback: nil
                    ),
                    store: journalStore
                )
                try sessionTransactionCoordinator
                    .discardUnmaterializedReservationIfNeeded(journal)
            } catch {
                let rollbackError = error
                recoveryDecisionService.applyRecoveryContext(
                    from: rollbackError,
                    to: &journal
                )
                let detail = recoveryDecisionService.recoveryFailureDetail(
                    primary: primary,
                    recovery: rollbackError
                )
                try? journalWriter.update(
                    &journal,
                    phase: .rollbackFailed,
                    message: detail,
                    store: journalStore
                )
                throw V011SwitchError.rollbackFailed(
                    detail
                )
            }
            throw primary
        }
        guard let state = committedState,
              let initialSummary = sessionSummary else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        try faultInjector(.committedBeforeReceiptMaterialize)
        let sessionResult = try await sessionTransactionCoordinator.performPostCommitSessionTransaction(
            journal: journal,
            managedState: managedState,
            journalKey: key,
            fallbackSummary: initialSummary
        )
        return V011SwitchResult(
            journal: journal,
            state: state,
            sessionSummary: sessionResult.summary,
            sessionReceipt: sessionResult.receipt
        )
    }

    private func validatedSwitchTarget(
        destination: FableSwitchDestination,
        managedState: V011ManagedState,
        capabilityUpdate: V011CapabilityProfileUpdate?,
        expectedCodexContractID: String
    ) throws -> V011ValidatedSwitchTarget {
        if let capabilityUpdate {
            try capabilityProfileService.validateCapabilityUpdate(
                capabilityUpdate,
                destination: destination,
                managedState: managedState,
                requireActiveProfile: true
            )
            try capabilityProfileService.validateManagedModelCatalog(
                capabilityUpdate.targetProfile,
                sourceProfile:
                    capabilityUpdate.sourceProfile,
                expectedCodexContractID:
                    expectedCodexContractID
            )
            return V011ValidatedSwitchTarget(
                profileID:
                    capabilityUpdate.targetProfile.id,
                relayProfile:
                    capabilityUpdate.targetProfile
            )
        }
        switch destination {
        case .official:
            return V011ValidatedSwitchTarget(
                profileID: nil,
                relayProfile: nil
            )
        case let .relay(profile):
            let matches = managedState.relayProfiles.filter {
                $0.id == profile.id
                    && $0.wireProtocol == .responses
                    && $0.models.contains($0.defaultModel)
                    && $0.fableProfile == profile
            }
            guard matches.count == 1,
                  let saved = matches.first else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            try capabilityProfileService.validateManagedModelCatalog(
                saved,
                sourceProfile: nil,
                expectedCodexContractID:
                    expectedCodexContractID
            )
            return V011ValidatedSwitchTarget(
                profileID: saved.id,
                relayProfile: saved
            )
        }
    }

    private func makeCore(
        managedProviderIDs: Set<String>,
        resolvedContractEntry:
            CodexVersionContract.Entry? = nil
    ) -> FableSwitchCore {
        coreFactory(managedProviderIDs, resolvedContractEntry)
    }
}
