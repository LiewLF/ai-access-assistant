import Foundation

/// Single construction boundary for switch coordinators and read/write core.
/// Keeps dependency wiring, migration preparation, and profile identity maps
/// consistent across UI-triggered workflows.
struct V011SwitchCoordinatorFactory: @unchecked Sendable {
    private let dependencies: V011AccessDependencies
    private let progress: @Sendable (String) -> Void

    init(
        dependencies: V011AccessDependencies,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dependencies = dependencies
        self.progress = progress
    }

    func make(
        runtimeVerifier: (any FableRuntimeVerifier)? = nil
    ) throws -> V011UnifiedSwitchCoordinator {
        let state = try stateStore.load()
        let known = Dictionary(
            uniqueKeysWithValues: state.relayProfiles.map {
                (
                    $0.v011ProviderID,
                    (id: $0.id, name: $0.name)
                )
            }
        )
        return V011UnifiedSwitchCoordinator(
            codexHome: dependencies.codexHome,
            controlRoot: dependencies.controlRoot,
            managedProviderIDs: state.managedProviderIDSet,
            knownProfilesByProvider: known,
            credentialStore: dependencies.credentialStore,
            processController: dependencies.processController,
            runtimeVerifier:
                runtimeVerifier ?? dependencies.runtimeVerifier,
            versionDiscovery: dependencies.versionDiscovery,
            relayPreflightVerifier: { profile, secret in
                _ = try await dependencies.verifyDraft(
                    profile,
                    secret
                )
            },
            preExecutionPreparation: {
                _ = try V011MigrationCoordinator(
                    controlRootURL: dependencies.controlRoot,
                    codexHomeURL: dependencies.codexHome,
                    keyProvider: dependencies.keyProvider
                ).prepareIfNeeded()
            },
            sessionCore: dependencies.sessionCore,
            keyProvider: dependencies.keyProvider,
            progress: progress
        )
    }

    func makePendingRecovery()
        -> V011UnifiedSwitchCoordinator {
        V011UnifiedSwitchCoordinator(
            codexHome: dependencies.codexHome,
            controlRoot: dependencies.controlRoot,
            managedProviderIDs: [],
            credentialStore: dependencies.credentialStore,
            processController: dependencies.processController,
            runtimeVerifier: dependencies.runtimeVerifier,
            versionDiscovery: dependencies.versionDiscovery,
            relayPreflightVerifier: { profile, secret in
                _ = try await dependencies.verifyDraft(
                    profile,
                    secret
                )
            },
            sessionCore: dependencies.sessionCore,
            keyProvider: dependencies.keyProvider
        )
    }

    func makeCore(
        managedProviderIDs: Set<String>,
        contractEntry: CodexVersionContract.Entry? = nil
    ) -> FableSwitchCore {
        FableSwitchCore(
            codexHome: dependencies.codexHome,
            resolvedContractEntry: contractEntry,
            credentialStore: dependencies.credentialStore,
            processController: dependencies.processController,
            runtimeVerifier: dependencies.runtimeVerifier,
            atomicWriter: dependencies.atomicWriter,
            managedProviderIDs: managedProviderIDs
        )
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }
}
