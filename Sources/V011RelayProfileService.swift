import Foundation

/// Owns saved-relay identity normalization and credential compensation.
/// The MainActor model remains responsible for UI state and task lifetime.
struct V011RelayProfileService {
    private let stateStore: V011ManagedStateStore
    private let credentialStore: any FableCredentialStore

    init(
        stateStore: V011ManagedStateStore,
        credentialStore: any FableCredentialStore
    ) {
        self.stateStore = stateStore
        self.credentialStore = credentialStore
    }

    func normalizedNewProfile(
        _ draft: CodexRelayProfile
    ) throws -> CodexRelayProfile {
        var state = try stateStore.load()
        let seed = "\(draft.name)|\(draft.baseURL)"
        let suffix = String(
            TOMLSemanticEngine.sha256(
                Data(seed.utf8)
            ).prefix(10)
        )
        let providerID =
            PreservingTOMLEditor.providerIdentifier(
                draft.name
            )
            + "_"
            + suffix
        if state.relayProfiles.contains(where: {
            $0.v011ProviderID == providerID || $0.id == "relay-\(suffix)"
        }) {
            throw V011AccessError.duplicateProvider
        }
        let capabilityProfile = draft.capabilityProfile?.rebased(
            providerID: providerID,
            displayName: draft.name,
            baseURL: draft.baseURL
        )
        if capabilityProfile?.validationIssues().isEmpty == false {
            throw V011AccessError.invalidCapabilityProfile
        }
        let profile = CodexRelayProfile(
            id: "relay-\(suffix)",
            providerID: providerID,
            name: draft.name,
            baseURL: draft.baseURL,
            wireProtocol: .responses,
            models: draft.models,
            defaultModel: draft.defaultModel,
            contextWindow: draft.contextWindow,
            autoCompactTokenLimit: draft.autoCompactTokenLimit,
            reasoningEffort: draft.reasoningEffort,
            localGatewayConfirmed: draft.localGatewayConfirmed,
            catalogEntryID: draft.catalogEntryID,
            capabilityProfile: capabilityProfile,
            additionalFields: draft.additionalFields
        )
        state.upsert(profile)
        return profile
    }

    func restoreCredential(
        _ previousSecret: String?,
        reference: String
    ) throws {
        if let previousSecret {
            try credentialStore.store(
                previousSecret,
                reference: reference
            )
        } else {
            try credentialStore.delete(
                reference: reference
            )
        }
    }
}
