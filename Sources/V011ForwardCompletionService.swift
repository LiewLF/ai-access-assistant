// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011ForwardCompletionPreparation {
    let managedStateData: Data?
    let expectedManagedStateHash: String?
    let resultingManagedStateHash: String
}

struct V011ForwardCompletionService: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let versionDiscovery: any FableCodexVersionDiscovering
    let sessionCore: any V011SessionCoreOperating
    let versionContract: CodexVersionContract
    let keyProvider: () throws -> Data

    func prepareIfSafe(
        journal: inout V011SwitchJournal,
        store: V011SwitchJournalStore,
        journalKey: Data
    ) async throws -> V011ForwardCompletionPreparation? {
        let isSplitConfigTransaction = journal.configTransactionID != nil
        let sessionJournalCommitted: Bool
        if isSplitConfigTransaction {
            sessionJournalCommitted =
                journal.configTransactionPhase == .verified
                    || journal.configTransactionPhase == .committed
        } else {
            do {
                sessionJournalCommitted = try
                    recoveryDecisionService.sessionJournalAllowsForwardCompletion(journal)
            } catch {
                throw V011ForwardCompletionError(
                    stage: .sessionCheck,
                    reason: V011RecoveryErrorText.safeDetail(error),
                    nextAction:
                        "让助手保护新增会话并恢复到操作前"
                )
            }
        }
        guard sessionJournalCommitted else {
            return nil
        }
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
            throw V011ForwardCompletionError(
                stage: .compatibilityCheck,
                reason: "当前Codex版本尚未通过写入验证",
                nextAction:
                    "让助手恢复原模式，再到修复工具查看版本支持状态"
            )
        }
        let schemaID = resolvedContractEntry.schemaID
        var managedState: V011ManagedState
        do {
            managedState = try managedStateStore.load()
        } catch {
            throw V011ForwardCompletionError(
                stage: .configurationCheck,
                reason: V011RecoveryErrorText.safeDetail(error),
                nextAction:
                    "让助手恢复原模式，再重新核对中转信息"
            )
        }
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
        let initialLive: LiveCodexState
        do {
            initialLive = try core.inspect(
                version: installation.identity
            )
            guard try recoveryDecisionService.targetConfigurationMatches(
                journal: journal,
                live: initialLive,
                managedState: managedState,
                versionContractID: schemaID
            ) else {
                throw V011ForwardCompletionError(
                    stage: .configurationCheck,
                    reason: "当前Codex设置与本次目标模式不一致",
                    nextAction:
                        "让助手恢复原模式，再重新核对中转地址、模型和密钥"
                )
            }
        } catch let error as V011ForwardCompletionError {
            throw error
        } catch {
            throw V011ForwardCompletionError(
                stage: .configurationCheck,
                reason: V011RecoveryErrorText.safeDetail(error),
                nextAction:
                    "让助手恢复原模式，再重新核对中转信息"
            )
        }
        if !isSplitConfigTransaction {
            do {
                guard try await recoveryDecisionService.sessionsMatchTarget(
                    providerID: journal.targetProvider
                ) else {
                    throw V011ForwardCompletionError(
                        stage: .sessionCheck,
                        reason: "部分历史会话还没有切换到目标模式",
                        nextAction:
                            "让助手先保护新增会话，再恢复到操作前"
                    )
                }
                guard try await sessionCore.interruptedJournal(
                    codexHome: codexHome,
                    recoveryRoot: sessionRecoveryRoot
                ) == nil else {
                    throw V011ForwardCompletionError(
                        stage: .sessionCheck,
                        reason: "仍有一项历史会话操作没有结束",
                        nextAction:
                            "让助手先保护新增会话，再恢复到操作前"
                    )
                }
            } catch let error as V011ForwardCompletionError {
                throw error
            } catch {
                throw V011ForwardCompletionError(
                    stage: .sessionCheck,
                    reason: V011RecoveryErrorText.safeDetail(error),
                    nextAction:
                        "完全退出Codex后再次恢复"
                )
            }
        }

        switch journal.targetProfileID {
        case .none:
            guard journal.targetProvider == "openai" else {
                throw V011ForwardCompletionError(
                    stage: .configurationCheck,
                    reason: "目标模式记录不完整",
                    nextAction:
                        "让助手恢复原模式，再重新选择目标模式"
                )
            }
            do {
                try runtimeVerifier.verifyOfficial()
            } catch {
                throw V011ForwardCompletionError(
                    stage: .connectionCheck,
                    reason: V011RecoveryErrorText
                        .safeDetail(error),
                    nextAction:
                        "检查网络和官方登录后重新切换"
                )
            }
        case let .some(profileID):
            guard let profile = managedState.relayProfiles
                .first(where: {
                    $0.id == profileID
                        && $0.v011ProviderID
                            == journal.targetProvider
                }) else {
                throw V011ForwardCompletionError(
                    stage: .configurationCheck,
                    reason: "找不到本次切换使用的中转资料",
                    nextAction:
                        "让助手恢复原模式，再重新添加或核对中转"
                )
            }
            do {
                try runtimeVerifier.verifyRelay(
                    profile.fableProfile
                )
            } catch {
                throw V011ForwardCompletionError(
                    stage: .connectionCheck,
                    reason: V011RecoveryErrorText
                        .safeDetail(error),
                    nextAction:
                        "检查网络、中转地址、模型和密钥后重新检测"
                )
            }
        }

        let verifiedLive: LiveCodexState
        do {
            verifiedLive = try core.inspect(
                version: installation.identity
            )
            guard try recoveryDecisionService.targetConfigurationMatches(
                journal: journal,
                live: verifiedLive,
                managedState: managedState,
                versionContractID: schemaID
            ) else {
                throw V011ForwardCompletionError(
                    stage: .configurationCheck,
                    reason: "连接检测后Codex设置又发生变化",
                    nextAction:
                        "退出其他配置工具，让助手恢复原模式后重试"
                )
            }
        } catch let error as V011ForwardCompletionError {
            throw error
        } catch {
            throw V011ForwardCompletionError(
                stage: .configurationCheck,
                reason: V011RecoveryErrorText.safeDetail(error),
                nextAction:
                    "退出其他配置工具，让助手恢复原模式后重试"
            )
        }
        if !isSplitConfigTransaction {
            do {
                guard try await recoveryDecisionService.sessionsMatchTarget(
                    providerID: journal.targetProvider
                ) else {
                    throw V011ForwardCompletionError(
                        stage: .sessionCheck,
                        reason: "连接检测后历史会话状态又发生变化",
                        nextAction:
                            "完全退出Codex后再次恢复"
                    )
                }
            } catch let error as V011ForwardCompletionError {
                throw error
            } catch {
                throw V011ForwardCompletionError(
                    stage: .sessionCheck,
                    reason: V011RecoveryErrorText.safeDetail(error),
                    nextAction:
                        "完全退出Codex后再次恢复"
                )
            }
        }

        let managedStateURL = managedStateStore.fileURL
        let currentManagedStateHash =
            SessionSyncFileSafety.hashIfPresent(managedStateURL)
        let managedStateExists = FileManager.default.fileExists(
            atPath: managedStateURL.path
        )
        guard managedStateExists
                == (currentManagedStateHash != nil) else {
            throw V011ForwardCompletionError(
                stage: .configurationCheck,
                reason: "受管状态文件无法安全读取",
                nextAction:
                    "不要继续切换，打开修复工具核对当前模式"
            )
        }
        if journal.stateCASManaged == true,
           let forwardHash = journal.forwardManagedStateHash,
           currentManagedStateHash == forwardHash {
            return V011ForwardCompletionPreparation(
                managedStateData: nil,
                expectedManagedStateHash:
                    currentManagedStateHash,
                resultingManagedStateHash: forwardHash
            )
        }
        if journal.stateCASManaged == true {
            let safeBaseHashes: Set<String?> = [
                journal.sourceManagedStateHash,
                journal.targetManagedStateHash,
            ]
            guard safeBaseHashes.contains(
                    currentManagedStateHash
                  ) else {
                throw V011ForwardCompletionError(
                    stage: .configurationCheck,
                    reason: "受管状态已被其他操作改变",
                    nextAction:
                        "不要继续切换，打开修复工具核对当前模式"
                )
            }
        }

        managedState.activeProfileID =
            journal.targetProfileID
        managedState.lastSessionJournalPath =
            journal.sessionJournalPath
        managedState.lastSuccessfulSwitchID = journal.id
        managedState.lastVerifiedConfigHash =
            verifiedLive.configHash
        managedState.lastVerifiedProviderID =
            journal.targetProvider
        managedState.lastVerifiedAt = Date()
        try V011CutoverPromotionRecorder.record(
            state: &managedState,
            providerID: journal.targetProvider,
            profileID: journal.targetProfileID,
            modelID: verifiedLive.model,
            configHash: verifiedLive.configHash,
            capabilityContract: schemaID,
            transactionID: journal.id,
            verifiedAt: managedState.lastVerifiedAt
                ?? Date()
        )
        if journal.targetProvider == "openai" {
            managedState.officialBaseline =
                V011OfficialBaselineRecord(
                    configHash: verifiedLive.configHash,
                    verifiedAt:
                        managedState.lastVerifiedAt ?? Date(),
                    switchTransactionID: journal.id,
                    providerID: "openai",
                    versionContractSchemaID: schemaID
                )
        }
        let managedStateData = try managedStateStore
            .preparedData(for: managedState)
        let managedStateHash = TOMLSemanticEngine.sha256(
            managedStateData
        )
        if journal.stateCASManaged == true,
           journal.forwardManagedStateHash
            != managedStateHash {
            journal.forwardManagedStateHash = managedStateHash
            journal.updatedAt = Date()
            journal.message = "目标模式已核对，正在提交受管状态"
            try V011SwitchStateEvidenceAuthenticator.seal(
                &journal,
                key: journalKey
            )
            try store.save(journal)
        }
        return V011ForwardCompletionPreparation(
            managedStateData:
                managedStateHash == currentManagedStateHash
                    ? nil : managedStateData,
            expectedManagedStateHash:
                currentManagedStateHash,
            resultingManagedStateHash: managedStateHash
        )
    }

    private var sessionRecoveryRoot: URL {
        controlRoot.appendingPathComponent(
            "SessionCoreRecovery",
            isDirectory: true
        )
    }

    private var managedStateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent("state.json")
        )
    }

    private var recoveryDecisionService:
        V011RecoveryDecisionService {
        V011RecoveryDecisionService(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs: managedProviderIDs,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            sessionCore: sessionCore,
            versionContract: versionContract,
            keyProvider: keyProvider
        )
    }

    private func makeCore(
        managedProviderIDs: Set<String>,
        resolvedContractEntry:
            CodexVersionContract.Entry? = nil
    ) -> FableSwitchCore {
        FableSwitchCore(
            codexHome: codexHome,
            versionContract: versionContract,
            resolvedContractEntry:
                resolvedContractEntry,
            credentialStore: credentialStore,
            processController: processController,
            runtimeVerifier: runtimeVerifier,
            managedProviderIDs: managedProviderIDs
        )
    }
}
