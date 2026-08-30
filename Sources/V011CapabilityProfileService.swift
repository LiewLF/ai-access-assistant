// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011CapabilityProfileService {
    let controlRoot: URL
    let managedProviderIDs: Set<String>
    let credentialStore: any FableCredentialStore
    let versionDiscovery: any FableCodexVersionDiscovering
    let relayPreflightVerifier: @Sendable
        (CodexRelayProfile, String) async throws -> Void
    let prePlanHook: @Sendable () throws -> Void
    let managedStateStore: V011ManagedStateStore
    let coreFactory:
        (Set<String>, CodexVersionContract.Entry?) -> FableSwitchCore
    let captureBaseline: () throws -> V011ManagedStateBaseline
    let requireBaselineCurrent:
        (V011ManagedStateBaseline) throws -> Void
    let executeSwitch:
        (FableSwitchDestination, V011CapabilityProfileUpdate)
            async throws -> V011SwitchResult

    private func makeCore(
        managedProviderIDs: Set<String>,
        resolvedContractEntry: CodexVersionContract.Entry?
    ) -> FableSwitchCore {
        coreFactory(managedProviderIDs, resolvedContractEntry)
    }

    private func captureManagedStateBaseline() throws
        -> V011ManagedStateBaseline {
        try captureBaseline()
    }

    private func requireManagedStateBaselineCurrent(
        _ baseline: V011ManagedStateBaseline
    ) throws {
        try requireBaselineCurrent(baseline)
    }

    private func execute(
        destination: FableSwitchDestination,
        capabilityUpdate: V011CapabilityProfileUpdate
    ) async throws -> V011SwitchResult {
        try await executeSwitch(destination, capabilityUpdate)
    }

    func updateCapabilityProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile
    ) async throws -> V011CapabilityProfileUpdateResult {
        try await updateManagedRelayProfile(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile,
            allowsRelaySettings: false,
            requireInactiveSource: false
        )
    }

    func updateRelayProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        requireInactiveSource: Bool = false
    ) async throws -> V011CapabilityProfileUpdateResult {
        try await updateManagedRelayProfile(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile,
            allowsRelaySettings: true,
            requireInactiveSource: requireInactiveSource
        )
    }

    private func updateManagedRelayProfile(
        sourceProfile: CodexRelayProfile,
        targetProfile: CodexRelayProfile,
        allowsRelaySettings: Bool,
        requireInactiveSource: Bool
    ) async throws -> V011CapabilityProfileUpdateResult {
        let journalStore = V011SwitchJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "SwitchTransactions",
                isDirectory: true
            )
        )
        guard try journalStore.pendingConfigCutover().isEmpty else {
            throw V011SwitchError.pendingRecovery
        }
        let update = V011CapabilityProfileUpdate(
            sourceProfile: sourceProfile,
            targetProfile: targetProfile,
            allowsRelaySettings: allowsRelaySettings
        )
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
        let versionContractID =
            resolvedContractEntry.schemaID
        let managedStateBaseline = try
            captureManagedStateBaseline()
        var state = managedStateBaseline.state
        try validateCapabilityUpdate(
            update,
            destination: .relay(targetProfile.fableProfile),
            managedState: state,
            requireActiveProfile: false
        )
        try validateManagedModelCatalog(
            targetProfile,
            sourceProfile: sourceProfile,
            expectedCodexContractID:
                versionContractID
        )
        let effectiveManagedProviderIDs = managedProviderIDs
            .union(state.managedProviderIDSet)
        let core = makeCore(
            managedProviderIDs: effectiveManagedProviderIDs,
            resolvedContractEntry:
                resolvedContractEntry
        )
        let before = try core.inspect(
            version: installation.identity
        )
        if case let .relay(providerID) = before.mode,
           providerID == sourceProfile.v011ProviderID {
            guard !requireInactiveSource else {
                throw V011SwitchError.currentRelayChanged
            }
            guard V011RelaySemanticMatcher.matches(
                    live: before,
                    profile: sourceProfile
                  ) else {
                throw V011SwitchError.currentRelayChanged
            }
            if sourceProfile.fableProfile
                == targetProfile.fableProfile {
                return try saveManagedProfileWithoutLiveWrite(
                    update: update,
                    targetProfile: targetProfile,
                    managedStateBaseline:
                        managedStateBaseline,
                    state: &state,
                    before: before,
                    core: core,
                    installation: installation,
                    versionContractID: versionContractID,
                    requireActiveProfile: true
                )
            }
            let result = try await execute(
                destination: .relay(targetProfile.fableProfile),
                capabilityUpdate: update
            )
            return V011CapabilityProfileUpdateResult(
                liveState: result.state,
                managedState: try managedStateStore.load(),
                appliedToLiveConfiguration: true,
                switchTransactionID: result.journal.id
            )
        }

        if allowsRelaySettings {
            try await verifyRelayPreflight(targetProfile)
        }

        try validateInactiveCapabilityUpdateSource(
            live: before,
            managedState: state
        )
        return try saveManagedProfileWithoutLiveWrite(
            update: update,
            targetProfile: targetProfile,
            managedStateBaseline: managedStateBaseline,
            state: &state,
            before: before,
            core: core,
            installation: installation,
            versionContractID: versionContractID,
            requireActiveProfile: false
        )
    }

    private func saveManagedProfileWithoutLiveWrite(
        update: V011CapabilityProfileUpdate,
        targetProfile: CodexRelayProfile,
        managedStateBaseline: V011ManagedStateBaseline,
        state: inout V011ManagedState,
        before: LiveCodexState,
        core: FableSwitchCore,
        installation: FableCodexInstallation,
        versionContractID: String,
        requireActiveProfile: Bool
    ) throws -> V011CapabilityProfileUpdateResult {
        state.upsert(targetProfile)
        let targetStateData = try managedStateStore
            .preparedData(for: state)
        let targetStateHash = TOMLSemanticEngine.sha256(
            targetStateData
        )
        try prePlanHook()
        try requireManagedStateBaselineCurrent(
            managedStateBaseline
        )
        let reloaded = try managedStateStore.load()
        guard reloaded == managedStateBaseline.state else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        try validateCapabilityUpdate(
            update,
            destination: .relay(targetProfile.fableProfile),
            managedState: reloaded,
            requireActiveProfile: requireActiveProfile
        )
        try validateManagedModelCatalog(
            targetProfile,
            sourceProfile: update.sourceProfile,
            expectedCodexContractID: versionContractID
        )
        let immediatelyBefore = try core.inspect(
            version: installation.identity
        )
        guard immediatelyBefore.configHash == before.configHash,
              immediatelyBefore.mode == before.mode else {
            throw V011SwitchError.currentRelayChanged
        }
        try managedStateStore.writePrepared(
            targetStateData,
            expectedCurrentHash: managedStateBaseline.hash
        )
        do {
            let after = try core.inspect(
                version: installation.identity
            )
            guard after.configHash == before.configHash,
                  after.mode == before.mode else {
                throw V011SwitchError.currentRelayChanged
            }
            return V011CapabilityProfileUpdateResult(
                liveState: after,
                managedState: state,
                appliedToLiveConfiguration: false,
                switchTransactionID: nil
            )
        } catch {
            let primary = error
            do {
                try managedStateStore.restoreOriginal(
                    managedStateBaseline.data,
                    originalHash: managedStateBaseline.hash,
                    intendedHash: targetStateHash
                )
            } catch {
                throw V011SwitchError.rollbackFailed(
                    "能力档更新遇到并发变化，状态补偿未完成"
                )
            }
            throw primary
        }
    }

    func validateCapabilityUpdate(
        _ update: V011CapabilityProfileUpdate,
        destination: FableSwitchDestination,
        managedState: V011ManagedState,
        requireActiveProfile: Bool
    ) throws {
        let source = update.sourceProfile
        let target = update.targetProfile
        let updateShapeIsValid: Bool
        if update.allowsRelaySettings {
            let targetModelIDs = target.models
            let capabilityModelIDs = target.capabilityProfile?
                .models.map(\.modelID) ?? []
            updateShapeIsValid =
                source.id == target.id
                && source.providerID == target.providerID
                && source.wireProtocol == target.wireProtocol
                && source.localGatewayConfirmed
                    == target.localGatewayConfirmed
                && source.catalogEntryID == target.catalogEntryID
                && source.additionalFields == target.additionalFields
                && source.effectiveCapabilityProfile
                    .requiresOpenAIAuth
                    == target.capabilityProfile?
                        .requiresOpenAIAuth
                && target.wireProtocol == .responses
                && !target.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && !target.baseURL.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && !target.defaultModel.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && target.models.contains(target.defaultModel)
                && Set(targetModelIDs).count
                    == targetModelIDs.count
                && Set(capabilityModelIDs)
                    == Set(targetModelIDs)
        } else {
            updateShapeIsValid = source.updatingCapabilities(
                target.capabilityProfile,
                contextWindow: target.contextWindow,
                autoCompactTokenLimit:
                    target.autoCompactTokenLimit,
                reasoningEffort: target.reasoningEffort
            ) == target
        }
        guard updateShapeIsValid,
              let capability = target.capabilityProfile,
              capability.providerID == target.v011ProviderID,
              capability.displayName == target.name,
              capability.baseURL == target.baseURL,
              capability.defaultModel == target.defaultModel,
              capability.validationIssues().isEmpty,
              case let .relay(destinationProfile) = destination,
              destinationProfile == target.fableProfile else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let matches = managedState.relayProfiles.filter {
            $0 == source
        }
        guard matches.count == 1 else {
            throw V011SwitchError.currentRelayChanged
        }
        if requireActiveProfile {
            guard managedState.activeProfileID == source.id else {
                throw V011SwitchError.currentRelayChanged
            }
        }
    }

    func validateManagedModelCatalog(
        _ profile: CodexRelayProfile,
        sourceProfile: CodexRelayProfile?,
        expectedCodexContractID: String
    ) throws {
        guard let capability = profile.capabilityProfile,
              let path = capability.modelCatalogPath else {
            return
        }
        let store = ManagedModelCatalogStore(
            rootURL: controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "ManagedModelCatalogs",
                    isDirectory: true
                )
        )
        switch store.existingPathState(path) {
        case let .managed(receipt):
            let capabilityModelIDs = capability.models.map(\.modelID)
            let catalogModelIDs = Set(
                receipt.metadata.models.map(\.modelID)
            )
            guard receipt.catalogURL.path == path,
                  receipt.metadata.providerID
                    == profile.v011ProviderID,
                  receipt.metadata.codexContractID
                    == expectedCodexContractID,
                  !capabilityModelIDs.isEmpty,
                  Set(capabilityModelIDs).count
                    == capabilityModelIDs.count,
                  Set(capabilityModelIDs)
                    .isSubset(of: catalogModelIDs),
                  capabilityModelIDs.contains(
                    profile.defaultModel
                  ),
                  receipt.metadata.models.contains(
                    where: {
                        $0.modelID == profile.defaultModel
                    }
                  ) else {
                throw V011SwitchError
                    .invalidRecoveryJournal
            }
        case .externalExisting:
            guard sourceProfile == nil
                    || sourceProfile?.capabilityProfile?
                        .modelCatalogPath == path else {
                throw V011SwitchError
                    .invalidRecoveryJournal
            }
        case .absent, .managedInvalid,
             .externalMissing, .unsafe:
            throw V011SwitchError.invalidRecoveryJournal
        }
    }

    private func validateInactiveCapabilityUpdateSource(
        live: LiveCodexState,
        managedState: V011ManagedState
    ) throws {
        switch live.mode {
        case .official:
            guard managedState.activeProfileID == nil else {
                throw V011SwitchError.currentRelayChanged
            }
        case let .relay(providerID):
            guard let activeID = managedState.activeProfileID,
                  let active = managedState.relayProfiles.first(
                    where: {
                        $0.id == activeID
                            && $0.v011ProviderID == providerID
                    }
                  ),
                  V011RelaySemanticMatcher.matches(
                    live: live,
                    profile: active
                  ) else {
                throw V011SwitchError.currentRelayChanged
            }
        }
    }

    func verifyRelayPreflight(
        _ profile: CodexRelayProfile
    ) async throws {
        do {
            guard let secret = try credentialStore.secret(
                    reference:
                        profile.v011CredentialReference
                  ), !secret.isEmpty else {
                throw FableSwitchError.credentialUnavailable
            }
            try await relayPreflightVerifier(
                profile,
                secret
            )
        } catch let failure as V011RelayPreflightFailure {
            throw failure
        } catch {
            throw V011RelayPreflightFailure(
                detail: V011RecoveryErrorText.safeDetail(error)
            )
        }
    }
}
