import Foundation

struct V011SavedRelayAddResult: @unchecked Sendable {
    let managedState: V011ManagedState
    let profileName: String
}

struct V011SavedRelayAddFailure: LocalizedError, @unchecked Sendable {
    let primaryDescription: String
    let recoveryDescription: String?

    var errorDescription: String? {
        guard let recoveryDescription else {
            return primaryDescription
        }
        return "\(primaryDescription)；凭据恢复未完成：\(recoveryDescription)"
    }
}

/// Owns saved-relay preflight, addition compensation, and deletion transaction
/// wiring. MainActor controller retains action eligibility; its façade delegate
/// owns Published presentation.
struct V011SavedRelayService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func preflight(
        _ profile: CodexRelayProfile
    ) async throws -> V011SavedRelayPreflightResult {
        let before = try stateStore.load()
        guard before.relayProfiles.contains(profile) else {
            throw V011SavedRelayPreflightError.profileChanged
        }
        guard let secret = try dependencies.credentialStore.secret(
            reference: profile.v011CredentialReference
        ), !secret.isEmpty else {
            throw V011SavedRelayPreflightError
                .credentialUnavailable
        }
        _ = try await dependencies.verifyDraft(profile, secret)
        let after = try stateStore.load()
        guard after.relayProfiles.contains(profile) else {
            throw V011SavedRelayPreflightError.profileChanged
        }
        return V011SavedRelayPreflightResult(
            profile: profile,
            outcome: .passed,
            checkedAt: dependencies.now(),
            detail: "切换前检测通过；当前模式未改变"
        )
    }

    func add(
        draft: CodexRelayProfile,
        apiKey: String
    ) async throws -> V011SavedRelayAddResult {
        var storedReference: String?
        var previousSecret: String?
        do {
            _ = try migrationCoordinator.prepareIfNeeded()
            let profile = try relayProfileService
                .normalizedNewProfile(draft)
            _ = try await dependencies.verifyDraft(profile, apiKey)
            previousSecret = try dependencies.credentialStore.secret(
                reference: profile.v011CredentialReference
            )
            try dependencies.credentialStore.store(
                apiKey,
                reference: profile.v011CredentialReference
            )
            storedReference = profile.v011CredentialReference
            var state = try stateStore.load()
            state.upsert(profile)
            try stateStore.save(state)
            return V011SavedRelayAddResult(
                managedState: state,
                profileName: profile.name
            )
        } catch {
            let primaryDescription = error.localizedDescription
            var recoveryDescription: String?
            if let storedReference {
                do {
                    try relayProfileService.restoreCredential(
                        previousSecret,
                        reference: storedReference
                    )
                } catch {
                    recoveryDescription = error.localizedDescription
                }
            }
            throw V011SavedRelayAddFailure(
                primaryDescription: primaryDescription,
                recoveryDescription: recoveryDescription
            )
        }
    }

    func delete(
        _ profile: CodexRelayProfile
    ) throws -> V011ManagedState {
        try deletionCoordinator.delete(profile)
    }

    func loadState() throws -> V011ManagedState {
        try stateStore.load()
    }

    func restoreCredential(
        _ previousSecret: String?,
        reference: String
    ) throws {
        try relayProfileService.restoreCredential(
            previousSecret,
            reference: reference
        )
    }

    func hasPendingDeletionRecovery() -> Bool {
        (try? deletionCoordinator.journalStore
            .pending().isEmpty) == false
    }

    var deletionCoordinator:
        V011RelayDeletionTransactionCoordinator {
        V011RelayDeletionTransactionCoordinator(
            controlRoot: dependencies.controlRoot,
            credentialStore: dependencies.credentialStore,
            keyProvider: dependencies.keyProvider,
            verifyInactive: { providerID in
                try Self.requireRelayInactive(
                    providerID,
                    dependencies: dependencies
                )
            }
        )
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }

    private var relayProfileService: V011RelayProfileService {
        V011RelayProfileService(
            stateStore: stateStore,
            credentialStore: dependencies.credentialStore
        )
    }

    private var migrationCoordinator: V011MigrationCoordinator {
        V011MigrationCoordinator(
            controlRootURL: dependencies.controlRoot,
            codexHomeURL: dependencies.codexHome,
            keyProvider: dependencies.keyProvider
        )
    }

    private static func requireRelayInactive(
        _ providerID: String,
        dependencies: V011AccessDependencies
    ) throws {
        let stateStore = V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
        let state = try stateStore.load()
        let installation = try dependencies
            .versionDiscovery.discover()
        let core = FableSwitchCore(
            codexHome: dependencies.codexHome,
            resolvedContractEntry: installation.contractEntry,
            credentialStore: dependencies.credentialStore,
            processController: dependencies.processController,
            runtimeVerifier: dependencies.runtimeVerifier,
            managedProviderIDs:
                state.managedProviderIDSet.union([providerID])
        )
        let live = try core.inspect(
            version: installation.identity
        )
        guard live.mode != .relay(providerID: providerID) else {
            throw V011RelayDeletionTransactionError.activeRelay
        }
    }
}
