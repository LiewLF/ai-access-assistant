import Foundation

struct V011OfficialRecoveryResult: @unchecked Sendable {
    let managedState: V011ManagedState
    let liveState: LiveCodexState
}

/// Establishes trusted official recovery material without UI state coupling.
struct V011OfficialRecoveryService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func establish() throws -> V011OfficialRecoveryResult {
        let installation = try dependencies.versionDiscovery.discover()
        var state = try stateStore.load()
        let core = V011SwitchCoordinatorFactory(
            dependencies: dependencies
        ).makeCore(
            managedProviderIDs: state.managedProviderIDSet,
            contractEntry: installation.contractEntry
        )
        let source = try core.inspect(version: installation.identity)
        guard case .official = source.mode else {
            throw FableSwitchError.officialRootOverlayUnavailable
        }
        guard case let .verified(schemaID) = source.versionSupport else {
            throw FableSwitchError.unsupportedVersion
        }
        try dependencies.runtimeVerifier.verifyOfficial()
        let overlay = try core.captureOfficialRootOverlay(
            version: installation.identity,
            expectedConfigHash: source.configHash
        )
        try dependencies.beforeOfficialRecoverySave()
        let verifiedSource = try core.inspect(
            version: installation.identity
        )
        guard case .official = verifiedSource.mode,
              verifiedSource.configHash == source.configHash else {
            throw FableSwitchError.sourceChanged
        }

        state = try stateStore.load()
        state.officialRootOverlay = V011OfficialRootOverlayRecord(
            overlay: overlay,
            capturedFromConfigHash: source.configHash,
            capturedAt: dependencies.now(),
            versionContractSchemaID: schemaID
        )
        try stateStore.save(state)
        return V011OfficialRecoveryResult(
            managedState: state,
            liveState: verifiedSource
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
