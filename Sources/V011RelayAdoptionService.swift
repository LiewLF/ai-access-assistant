import Foundation

struct V011RelayAdoptionResult: @unchecked Sendable {
    let managedState: V011ManagedState
    let liveState: LiveCodexState
    let profileName: String
}

enum V011RelayAdoptionFailureDisposition: @unchecked Sendable {
    case unchanged
    case rolledBack(V011ManagedState)
    case recoveryPending
}

struct V011RelayAdoptionFailure: LocalizedError, @unchecked Sendable {
    let primaryDescription: String
    let recoveryDescription: String?
    let disposition: V011RelayAdoptionFailureDisposition

    var errorDescription: String? {
        guard let recoveryDescription else {
            return primaryDescription
        }
        return "\(primaryDescription)；\(recoveryDescription)"
    }
}

/// Owns current-relay adoption as one compensating transaction.
/// Journal phase order, credential/state writes, and rollback boundaries stay
/// together so UI code cannot partially reproduce transaction semantics.
struct V011RelayAdoptionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func adoptCurrentRelay(
        displayName: String
    ) async throws -> V011RelayAdoptionResult {
        var adoptionJournal: V011AdoptionJournal?
        do {
            _ = try migrationCoordinator.prepareIfNeeded()
            let installation = try dependencies
                .versionDiscovery.discover()
            let core = FableSwitchCore(
                codexHome: dependencies.codexHome,
                resolvedContractEntry: installation.contractEntry,
                credentialStore: dependencies.credentialStore,
                processController: dependencies.processController,
                runtimeVerifier: dependencies.runtimeVerifier,
                atomicWriter: dependencies.atomicWriter,
                managedProviderIDs: []
            )
            let live = try core.inspect(
                version: installation.identity
            )
            guard case let .relay(providerID) = live.mode else {
                throw V011AccessError.currentRelayMissing
            }
            let document = try currentConfigurationDocument()
            guard let baseURL = live.provider?.baseURL,
                  !baseURL.isEmpty,
                  let model = live.model,
                  !model.isEmpty,
                  live.provider?.wireAPI == "responses" else {
                throw V011AccessError.currentRelayIncomplete
            }
            let configuredSecret = document.string(
                at: [
                    "model_providers",
                    providerID,
                    "experimental_bearer_token",
                ]
            )
            guard let secret = configuredSecret?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                  !secret.isEmpty,
                  live.provider?.hasBearerToken == true,
                  live.provider?.hasEnvKey == false,
                  live.provider?.hasCommandAuth == false,
                  live.provider?.requiresOpenAIAuth == true else {
                throw V011AccessError
                    .currentRelayUsesLegacyAuthentication
            }
            let name = displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let profileName = name.isEmpty
                ? (live.provider?.displayName ?? "当前中转")
                : name
            let existingState = try stateStore.load()
            let matchingProfiles = existingState.relayProfiles.filter {
                $0.v011ProviderID == providerID
            }
            let completedMigration = try migrationCoordinator
                .loadManifest()?.adoptedProfileID
            let profileID: String
            if matchingProfiles.count == 1,
               let existing = matchingProfiles.first,
               completedMigration == existing.id {
                profileID = existing.id
            } else {
                profileID =
                    "adopted-"
                    + String(
                        TOMLSemanticEngine.sha256(
                            Data("\(providerID)|\(baseURL)".utf8)
                        ).prefix(12)
                    )
            }
            let profile = CodexRelayProfile(
                id: profileID,
                providerID: providerID,
                name: profileName,
                baseURL: baseURL,
                wireProtocol: .responses,
                models: [model],
                defaultModel: model,
                contextWindow: live.contextWindow,
                autoCompactTokenLimit: live.autoCompactTokenLimit,
                reasoningEffort:
                    V011RelayAdoptionProfileMapper.reasoningEffort(
                        live.reasoningEffort
                    ),
                capabilityProfile:
                    V011RelayAdoptionProfileMapper
                        .adoptedCapabilityProfile(
                            live: live,
                            providerID: providerID,
                            profileName: profileName,
                            baseURL: baseURL,
                            model: model
                        )
            )
            guard V011RelaySemanticMatcher.matches(
                live: live,
                profile: profile
            ) else {
                throw V011AccessError.currentRelaySnapshotMismatch
            }
            try dependencies.runtimeVerifier
                .verifyRelay(profile.fableProfile)
            let originPayload = try await originPayloadAsUnknown()
            let previousSecret = try dependencies
                .credentialStore.secret(
                    reference: profile.v011CredentialReference
                )
            var journal = try adoptionCoordinator.begin(
                profileID: profile.id,
                credentialReference: profile.v011CredentialReference,
                previousCredential: previousSecret
            )
            adoptionJournal = journal
            try dependencies.adoptionFaultInjector(.prepared)

            try dependencies.credentialStore.store(
                secret,
                reference: profile.v011CredentialReference
            )
            try adoptionCoordinator.update(
                &journal,
                phase: .credentialStored,
                message: "中转凭据已保存"
            )
            adoptionJournal = journal
            try dependencies.adoptionFaultInjector(.credentialStored)

            try originLedgerStore.save(originPayload)
            try adoptionCoordinator.update(
                &journal,
                phase: .ledgerWritten,
                message: "历史会话来源已记录"
            )
            adoptionJournal = journal
            try dependencies.adoptionFaultInjector(.ledgerWritten)

            var state = try stateStore.load()
            state.upsert(profile)
            state.activeProfileID = profile.id
            state.lastVerifiedConfigHash = live.configHash
            state.lastVerifiedProviderID = providerID
            state.lastVerifiedAt = Date()
            state.didMigrateFrom0103 = true
            try stateStore.save(state)
            try adoptionCoordinator.update(
                &journal,
                phase: .stateWritten,
                message: "当前中转档已建立"
            )
            adoptionJournal = journal
            try dependencies.adoptionFaultInjector(.stateWritten)

            let migration = try migrationCoordinator.prepareIfNeeded()
            let migrationMessage: String
            if let owner = migration.adoptedProfileID,
               owner != profile.id {
                migrationMessage = "0.10.3迁移档案已核验并保持原归属"
            } else {
                _ = try migrationCoordinator
                    .completeAfterSuccessfulAdoption(
                        profileID: profile.id
                    )
                migrationMessage = "0.10.3迁移档案已提交"
            }
            try adoptionCoordinator.update(
                &journal,
                phase: .manifestCompleted,
                message: migrationMessage
            )
            adoptionJournal = journal
            try dependencies.adoptionFaultInjector(.manifestCompleted)
            try dependencies.adoptionFaultInjector(.beforeCommit)
            try adoptionCoordinator.update(
                &journal,
                phase: .committed,
                message: "当前中转已无损接管"
            )
            adoptionJournal = journal
            return V011RelayAdoptionResult(
                managedState: state,
                liveState: live,
                profileName: profile.name
            )
        } catch {
            let primaryDescription = error.localizedDescription
            guard var journal = adoptionJournal else {
                throw V011RelayAdoptionFailure(
                    primaryDescription: primaryDescription,
                    recoveryDescription: nil,
                    disposition: .unchanged
                )
            }
            do {
                try adoptionCoordinator.rollback(&journal)
                let restoredState = try stateStore.load()
                throw V011RelayAdoptionFailure(
                    primaryDescription: primaryDescription,
                    recoveryDescription: nil,
                    disposition: .rolledBack(restoredState)
                )
            } catch let failure as V011RelayAdoptionFailure {
                throw failure
            } catch {
                throw V011RelayAdoptionFailure(
                    primaryDescription: primaryDescription,
                    recoveryDescription: error.localizedDescription,
                    disposition: .recoveryPending
                )
            }
        }
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }

    private var migrationCoordinator: V011MigrationCoordinator {
        V011MigrationCoordinator(
            controlRootURL: dependencies.controlRoot,
            codexHomeURL: dependencies.codexHome,
            keyProvider: dependencies.keyProvider
        )
    }

    private var adoptionCoordinator:
        V011AdoptionTransactionCoordinator {
        V011AdoptionTransactionCoordinator(
            codexHome: dependencies.codexHome,
            controlRoot: dependencies.controlRoot,
            credentialStore: dependencies.credentialStore,
            keyProvider: dependencies.keyProvider
        )
    }

    private var originLedgerStore:
        V011SessionOriginLedgerStore {
        V011SessionOriginLedgerStore(
            rootURL: dependencies.controlRoot
                .appendingPathComponent(
                    "SessionOriginLedger",
                    isDirectory: true
                ),
            keyProvider: dependencies.keyProvider
        )
    }

    private func currentConfigurationDocument()
        throws -> TOMLSemanticDocument {
        let url = dependencies.codexHome
            .appendingPathComponent("config.toml")
        try SessionSyncFileSafety.requireRegularFile(url)
        return try TOMLSemanticEngine.parse(
            String(
                decoding: try Data(
                    contentsOf: url,
                    options: .mappedIfSafe
                ),
                as: UTF8.self
            )
        )
    }

    private func originPayloadAsUnknown()
        async throws -> V011SessionOriginLedgerPayload {
        var sessions: [SessionCoreSession] = []
        var offset = 0
        while true {
            let page = try await dependencies.sessionCore.list(
                codexHome: dependencies.codexHome,
                limit: 50,
                offset: offset,
                provider: nil
            )
            sessions.append(contentsOf: page.sessions)
            guard page.hasMore else { break }
            guard !page.sessions.isEmpty else { break }
            offset += page.sessions.count
        }
        var payload = try originLedgerStore.load()
        payload = V011SessionOriginLedgerBuilder.merge(
            sessions: sessions,
            into: payload,
            knownProfilesByProvider: [:]
        )
        if payload.initializedAt == nil {
            payload.initializedAt = Date()
        }
        return payload
    }
}
